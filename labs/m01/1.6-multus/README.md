# Lab 1.6: Multi-interface pods with Multus

Lab for the course lesson **1.6 Multi-interface pods with Multus**. It creates a fresh 3-node kind cluster named `ckne` (kind with Cilium as the network plugin, replacing kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.6-multus
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Install the CNI reference plugins (bridge, macvlan, ...) on every node
2. Install Multus (version from lib/versions.env) (thick plugin): it becomes the first CNI and delegates to Cilium
3. Define a second network: a NetworkAttachmentDefinition (bridge + host-local, 192.168.50.0/24)
4. Two pods ask for it with an annotation, on the same node
5. Traffic on the second network: p1 -> p2 over net1

## What the check looks for

- Multus DaemonSet is ready
- NetworkAttachmentDefinition storage-net exists
- pod p1 has a second interface net1 in 192.168.50.0/24
- p1 reaches p2 over net1

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (180 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (155 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 022); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It has no kube-proxy and no default network plugin; Cilium is installed as the network plugin and replaces kube-proxy.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: true, kubeProxyMode: none}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm repo add cilium https://helm.cilium.io && helm repo update cilium
helm upgrade --install cilium cilium/cilium --version 1.20.5 -n kube-system \
  --set kubeProxyReplacement=true --set k8sServiceHost=ckne-control-plane --set k8sServicePort=6443 \
  --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true --set hubble.relay.enabled=true \
  --set gatewayAPI.enabled=true --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). `cni.exclusive=false` lets Multus (step 2) add its own config next to Cilium's.

### 1. Install the CNI reference plugins (bridge, macvlan, ...) on every node

kind nodes ship only four plugin programs. A second network with `bridge` needs the reference plugins on every node.

```bash
for n in ckne-control-plane ckne-worker ckne-worker2; do
  docker exec $n sh -c 'curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.10.0/cni-plugins-linux-$(dpkg --print-architecture)-v1.10.0.tgz | tar xz -C /opt/cni/bin ./bridge ./macvlan ./ipvlan ./static' && echo "plugins installed on $n"
done
docker exec ckne-worker ls /opt/cni/bin
```

Our output:

```text
plugins installed on ckne-control-plane
plugins installed on ckne-worker
plugins installed on ckne-worker2
$ docker exec ckne-worker ls /opt/cni/bin
bridge
cilium-cni
host-local
ipvlan
loopback
macvlan
portmap
ptp
static
```

**What to look for:** `bridge`, `macvlan`, `ipvlan` and `static` now sit next to `cilium-cni` and the four that were there.

### 2. Install Multus v4.3.2 (thick plugin): it becomes the first CNI and delegates to Cilium

Multus is a meta-plugin: it puts its own config in front of the existing one and calls Cilium for eth0, then any extra networks a pod asks for.

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.3.2/deployments/multus-daemonset-thick.yml
kubectl -n kube-system set resources ds/kube-multus-ds -c kube-multus --limits=memory=300Mi --requests=memory=100Mi
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=240s
docker exec ckne-worker ls /etc/cni/net.d
```

Our output:

```text
$ kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.3.2/deployments/multus-daemonset-thick.yml
customresourcedefinition.apiextensions.k8s.io/network-attachment-definitions.k8s.cni.cncf.io created
clusterrole.rbac.authorization.k8s.io/multus created
clusterrolebinding.rbac.authorization.k8s.io/multus created
serviceaccount/multus created
configmap/multus-daemon-config created
daemonset.apps/kube-multus-ds created
$ kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=240s
Waiting for daemon set "kube-multus-ds" rollout to finish: 0 of 3 updated pods are available...
Waiting for daemon set "kube-multus-ds" rollout to finish: 1 of 3 updated pods are available...
Waiting for daemon set "kube-multus-ds" rollout to finish: 2 of 3 updated pods are available...
daemon set "kube-multus-ds" successfully rolled out
$ docker exec ckne-worker ls /etc/cni/net.d
00-multus.conf
05-cilium.conflist
```

**What to look for:** `00-multus.conf` sorts before `05-cilium.conflist`, so the runtime calls Multus first. (The upstream manifest's 50Mi memory limit made the daemon restart on our Mac, so we raise it.)

### 3. Define a second network: a NetworkAttachmentDefinition (bridge + host-local, 192.168.50.0/24)

A NetworkAttachmentDefinition is a CNI config stored as a Kubernetes object.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: storage-net}
spec:
  config: '{"cniVersion": "1.0.0", "name": "storage-net", "type": "bridge", "bridge": "br-storage", "ipam": {"type": "host-local", "subnet": "192.168.50.0/24", "rangeStart": "192.168.50.10", "rangeEnd": "192.168.50.50"}}'
EOF
kubectl get network-attachment-definitions
```

Our output:

```text
networkattachmentdefinition.k8s.cni.cncf.io/storage-net created
$ kubectl get network-attachment-definitions
NAME          AGE
storage-net   0s
```

**What to look for:** `storage-net` listed.

### 4. Two pods ask for it with an annotation, on the same node

Pods ask for extra networks by name, in the `k8s.v1.cni.cncf.io/networks` annotation.

```bash
for p in p1 p2; do cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: $p, annotations: {k8s.v1.cni.cncf.io/networks: storage-net}}
spec:
  nodeName: ckne-worker
  containers: [{name: c, image: "busybox:1.36.1", command: ["sleep", "3600"]}]
EOF
done
kubectl wait --for=condition=Ready pod/p1 pod/p2 --timeout=120s
kubectl exec p1 -- ip addr
kubectl get pod p1 -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'; echo
docker exec ckne-worker ls -l /etc/cni/net.d
```

Our output:

```text
$ kubectl exec p1 -- ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: net1@if15: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue qlen 1000
    link/ether 22:6d:d2:5f:49:ac brd ff:ff:ff:ff:ff:ff
    inet 192.168.50.10/24 brd 192.168.50.255 scope global net1
       valid_lft forever preferred_lft forever
    inet6 fe80::206d:d2ff:fe5f:49ac/64 scope link
       valid_lft forever preferred_lft forever
10: eth0@if11: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue
    link/ether b2:e2:fb:78:bb:62 brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.212/32 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::b0e2:fbff:fe78:bb62/64 scope link
       valid_lft forever preferred_lft forever
$ kubectl get pod p1 -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'; echo
[{
    "name": "cilium",
    "interface": "eth0",
    "ips": [
        "10.0.0.212"
    ],
    "mac": "b2:e2:fb:78:bb:62",
    "default": true,
    "dns": {},
    "gateway": [
        "10.0.0.237"
    ]
},{
    "name": "default/storage-net",
    "interface": "net1",
    "ips": [
        "192.168.50.10"
    ],
    "mac": "22:6d:d2:5f:49:ac",
    "dns": {}
}]
$ docker exec ckne-worker ls -l /etc/cni/net.d
total 8
-rw------- 1 root root 169 Nov 18 04:54 00-multus.conf
-rw------- 1 root root 191 Nov 18 04:53 05-cilium.conflist
```

**What to look for:** two interfaces in p1: `eth0` from Cilium and `net1` with a `192.168.50.x` address from the bridge. The network-status annotation lists both; Kubernetes itself only knows the eth0 address.

### 5. Traffic on the second network: p1 -> p2 over net1

Send traffic over net1 only.

```bash
IP2=$(kubectl exec p2 -- ip -4 -o addr show net1 | awk '{print $4}' | cut -d/ -f1)
kubectl exec p1 -- ping -c 2 -I net1 $IP2
```

Our output:

```text
$ kubectl exec p1 -- ping -c 2 -I net1 $IP2
PING 192.168.50.11 (192.168.50.11): 56 data bytes
64 bytes from 192.168.50.11: seq=0 ttl=64 time=0.117 ms
64 bytes from 192.168.50.11: seq=1 ttl=64 time=0.152 ms
--- 192.168.50.11 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.117/0.134/0.152 ms
```

**What to look for:** `0% packet loss` from `192.168.50.10` to p2's net1 address.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the Multus DaemonSet, the NetworkAttachmentDefinition, p1's net1 address and a ping over net1.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Multus DaemonSet is ready
PASS  NetworkAttachmentDefinition storage-net exists
PASS  pod p1 has a second interface net1 in 192.168.50.0/24
PASS  p1 reaches p2 over net1
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
