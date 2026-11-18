# Lab 1.2: How a pod gets its network (CNI by hand)

Lab for the course lesson **1.2 CNI: how a pod gets its network**. It creates a fresh 3-node kind cluster named `ckne` (kind with no network plugin: you install one by hand), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.2-cni
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. A cluster with no network plugin: nodes are NotReady
2. What every node already has: CNI plugin binaries, and a pod CIDR from Kubernetes
3. Write a CNI config on each node: ptp plugin + host-local IPAM for that node's pod CIDR
4. Route each node's pod CIDR to that node (the part a real CNI automates)
5. Nodes turn Ready; CoreDNS starts
6. Two pods on different nodes reach each other directly, without NAT

## What the check looks for

- all nodes Ready
- every node has a CNI config in /etc/cni/net.d
- CoreDNS is available
- pod a (ckne-worker) can ping pod b (ckne-worker2)
- pod b sees pod a's own IP as the source, not a node IP (no NAT)

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (50 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (41 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 014); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It has **no network plugin**: building the pod network is the lab.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: true, kubeProxyMode: iptables}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env).

### 1. A cluster with no network plugin: nodes are NotReady

With no CNI configured, the nodes can't be Ready and pods that need the network can't start.

```bash
kubectl get nodes
kubectl get node ckne-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
docker exec ckne-worker sh -c 'ls -la /etc/cni/net.d/'
```

Our output:

```text
$ kubectl get nodes
NAME                 STATUS     ROLES           AGE   VERSION
ckne-control-plane   NotReady   control-plane   16s   v1.37.0
ckne-worker          NotReady   <none>          1s    v1.37.0
ckne-worker2         NotReady   <none>          1s    v1.37.0
$ kubectl get node ckne-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
[container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialize…
$ docker exec ckne-worker sh -c 'ls -la /etc/cni/net.d/'
total 8
drwx------ 2 root root 4096 Aug 26 21:01 .
drwxr-xr-x 3 root root 4096 Aug 26 21:01 ..
```

**What to look for:** `NotReady` on every node, the reason `cni plugin not initialized`, and an empty `/etc/cni/net.d`.

### 2. What every node already has: CNI plugin binaries, and a pod CIDR from Kubernetes

The plugin programs are already on the node, and Kubernetes has already given each node its slice of pod addresses.

```bash
docker exec ckne-worker ls /opt/cni/bin
kubectl get nodes -o custom-columns=NODE:.metadata.name,PODCIDR:.spec.podCIDR,IP:.status.addresses[0].address
```

Our output:

```text
$ docker exec ckne-worker ls /opt/cni/bin
host-local
loopback
portmap
ptp
ckne-control-plane  podCIDR=10.244.0.0/24  nodeIP=172.18.0.2
ckne-worker  podCIDR=10.244.1.0/24  nodeIP=172.18.0.3
ckne-worker2  podCIDR=10.244.2.0/24  nodeIP=172.18.0.4
```

**What to look for:** four binaries (`host-local`, `loopback`, `portmap`, `ptp`; no `bridge`), and a different `/24` per node. Our script printed the node table in its own format, shown in the output.

### 3. Write a CNI config on each node: ptp plugin + host-local IPAM for that node's pod CIDR

One config file per node: `ptp` connects each pod with a veth pair, and `host-local` hands out addresses from that node's podCIDR.

```bash
for n in ckne-control-plane ckne-worker ckne-worker2; do
  cidr=$(kubectl get node $n -o jsonpath='{.spec.podCIDR}')
  cat <<EOF | docker exec -i $n sh -c 'cat > /etc/cni/net.d/10-ckne-ptp.conflist'
{ "cniVersion": "1.0.0", "name": "ckne-ptp", "plugins": [
  { "type": "ptp", "ipMasq": false, "mtu": 1500,
    "ipam": { "type": "host-local", "ranges": [[{ "subnet": "$cidr" }]], "routes": [{ "dst": "0.0.0.0/0" }] } },
  { "type": "portmap", "capabilities": { "portMappings": true } } ] }
EOF
  echo "wrote config on $n (subnet $cidr)"
done
docker exec ckne-worker sh -c 'cat /etc/cni/net.d/10-ckne-ptp.conflist'
```

Our output:

```text
wrote /etc/cni/net.d/10-ckne-ptp.conflist on ckne-control-plane (subnet 10.244.0.0/24)
wrote /etc/cni/net.d/10-ckne-ptp.conflist on ckne-worker (subnet 10.244.1.0/24)
wrote /etc/cni/net.d/10-ckne-ptp.conflist on ckne-worker2 (subnet 10.244.2.0/24)
$ docker exec ckne-worker sh -c 'cat /etc/cni/net.d/10-ckne-ptp.conflist'
{
  "cniVersion": "1.0.0",
  "name": "ckne-ptp",
  "plugins": [
    { "type": "ptp", "ipMasq": false, "mtu": 1500,
      "ipam": { "type": "host-local", "ranges": [[{ "subnet": "10.244.1.0/24" }]], "routes": [{ "dst": "0.0.0.0/0" }] } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

**What to look for:** each node's file has its own `subnet`. `"ipMasq": false` keeps pod addresses unchanged (no NAT).

### 4. Route each node's pod CIDR to that node (the part a real CNI automates)

`ptp` only connects pods to their own node. For pods on other nodes, each node needs a route to every other node's podCIDR, via that node's address. A real CNI does this for you.

```bash
for a in ckne-control-plane ckne-worker ckne-worker2; do for b in ckne-control-plane ckne-worker ckne-worker2; do
  [ $a = $b ] && continue
  docker exec $a ip route replace $(kubectl get node $b -o jsonpath='{.spec.podCIDR}') via \
    $(kubectl get node $b -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
done; echo "$a:"; docker exec $a ip route | grep '^10\.244'; done
```

Our output:

```text
ckne-control-plane:
   10.244.0.2 dev veth65070351 scope host
   10.244.0.3 dev veth3f7f614c scope host
   10.244.0.4 dev vethbd7d4f43 scope host
   10.244.1.0/24 via 172.18.0.3 dev eth0
   10.244.2.0/24 via 172.18.0.4 dev eth0
ckne-worker:
   10.244.0.0/24 via 172.18.0.2 dev eth0
   10.244.2.0/24 via 172.18.0.4 dev eth0
ckne-worker2:
   10.244.0.0/24 via 172.18.0.2 dev eth0
   10.244.1.0/24 via 172.18.0.3 dev eth0
```

**What to look for:** on every node, one `10.244.x.0/24 via 172.18.0.y` line per other node, plus `scope host` routes to its own pods' veths.

### 5. Nodes turn Ready; CoreDNS starts

With a CNI config in place, the runtime can set up pod networks, so the nodes turn Ready and CoreDNS can start.

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl -n kube-system rollout status deploy/coredns --timeout=180s
kubectl get nodes
```

Our output:

```text
$ kubectl wait --for=condition=Ready nodes --all --timeout=120s
node/ckne-control-plane condition met
node/ckne-worker condition met
node/ckne-worker2 condition met
$ kubectl -n kube-system rollout status deploy/coredns --timeout=180s
deployment "coredns" successfully rolled out
$ kubectl get nodes
NAME                 STATUS   ROLES           AGE   VERSION
ckne-control-plane   Ready    control-plane   21s   v1.37.0
ckne-worker          Ready    <none>          6s    v1.37.0
ckne-worker2         Ready    <none>          6s    v1.37.0
```

**What to look for:** all three nodes `Ready` and CoreDNS rolled out.

### 6. Two pods on different nodes reach each other directly, without NAT

Pod a on one worker, pod b on the other. b runs Kubernetes' test server, whose `/clientip` answers with the address a request came from.

```bash
kubectl run a --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 3600
kubectl run b --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=8080
kubectl wait --for=condition=Ready pod/a pod/b --timeout=120s
kubectl get pods -o wide
B=$(kubectl get pod b -o jsonpath='{.status.podIP}')
kubectl exec a -- ping -c 2 $B
kubectl exec a -- ip addr show eth0
kubectl exec a -- wget -qO- http://$B:8080/clientip; echo
```

Our output:

```text
$ kubectl run a --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 3600
pod/a created
$ kubectl run b --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=8080
pod/b created
$ kubectl get pods -o wide
NAME   READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
a      1/1     Running   0          3s    10.244.1.2   ckne-worker    <none>           <none>
b      1/1     Running   0          3s    10.244.2.2   ckne-worker2   <none>           <none>
$ kubectl exec a -- ping -c 2 $B
PING 10.244.2.2 (10.244.2.2): 56 data bytes
64 bytes from 10.244.2.2: seq=0 ttl=62 time=0.226 ms
64 bytes from 10.244.2.2: seq=1 ttl=62 time=0.110 ms
--- 10.244.2.2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.110/0.168/0.226 ms
$ kubectl exec a -- ip addr show eth0
2: eth0@if3: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue qlen 1000
    link/ether 9e:86:d9:59:62:c1 brd ff:ff:ff:ff:ff:ff
    inet 10.244.1.2/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::9c86:d9ff:fe59:62c1/64 scope link
       valid_lft forever preferred_lft forever
$ kubectl exec a -- wget -qO- http://$B:8080/clientip; echo
10.244.1.2:44512
pod a is 10.244.1.2; a connection from a arrives at b from: 10.244.1.2
```

**What to look for:** `/clientip` answers with **pod a's own IP** (the same address `ip addr` shows in a): the request crossed nodes without address translation. That's the Kubernetes network model's no-NAT rule.

### 7. Check your work

Grade the cluster the way an exam task is graded. The check looks for Ready nodes, a CNI config on every node, CoreDNS available, a working ping, and no NAT between the pods.

```bash
bash lab.sh check
```

Our output:

```text
PASS  all nodes Ready
PASS  ckne-control-plane has a CNI config in /etc/cni/net.d
PASS  ckne-worker has a CNI config in /etc/cni/net.d
PASS  ckne-worker2 has a CNI config in /etc/cni/net.d
PASS  CoreDNS is available
PASS  pod a (ckne-worker) can ping pod b (ckne-worker2)
PASS  pod b sees pod a's own IP (10.244.1.2) as the source, not a node IP (no NAT)
7 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
