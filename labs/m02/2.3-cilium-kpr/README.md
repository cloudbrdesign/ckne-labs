# Lab 2.3: Replacing kube-proxy with Cilium

Lab for the course lesson **2.3 Replacing kube-proxy with Cilium**. It creates a fresh 3-node kind cluster named `ckne` (Cilium as the network plugin, replacing kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.3-cilium-kpr
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. No kube-proxy in this cluster
2. Cilium says it has taken over kube-proxy's job
3. No Service rules in iptables on the node
4. Cilium's own Service table: frontend (ClusterIP:port) -> backends (pod IP:port)
5. It still works: ClusterIP from a pod, NodePort from outside the pod network

## What the check looks for

- no kube-proxy DaemonSet
- Cilium reports KubeProxyReplacement: True
- Cilium's Service table has Service web's ClusterIP
- no KUBE-SVC iptables rules on ckne-worker
- pod client reaches web by name
- web-np answers on a worker's IP and NodePort

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (142 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (116 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 065); names, IPs and ages will differ on your machine.

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

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

Two web pods, a ClusterIP and a NodePort Service, and a client pod.

```bash
kubectl create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --replicas=2 -- /agnhost netexec --http-port=8080
kubectl expose deployment web --port=80 --target-port=8080
kubectl expose deployment web --name=web-np --type=NodePort --port=80 --target-port=8080
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl rollout status deploy/web --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. No kube-proxy in this cluster

This cluster was created with kube-proxy off; Cilium does the Service work.

```bash
kubectl -n kube-system get ds
kubectl -n kube-system get ds kube-proxy
```

Our output:

```text
$ kubectl -n kube-system get ds
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
cilium         3         3         3       3            3           kubernetes.io/os=linux   101s
cilium-envoy   3         3         3       3            3           kubernetes.io/os=linux   101s
$ kubectl -n kube-system get ds kube-proxy
Error from server (NotFound): daemonsets.apps "kube-proxy" not found
```

**What to look for:** `cilium` and `cilium-envoy` DaemonSets, and `NotFound` for kube-proxy.

### 2. Cilium says it has taken over kube-proxy's job

The agent's status and Cilium's config both confirm the kube-proxy replacement.

```bash
CP=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=ckne-worker -o name)
kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading'
kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'kube-proxy-replacement|bpf-lb-sock'
```

Our output:

```text
$ kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading'
KubeProxyReplacement:    True   [eth0    172.18.0.2 fc00:f853:ccd:e793::2 fe80::b0e4:73ff:fe1c:8842 (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]
$ kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'kube-proxy-replacement|bpf-lb-sock'
  bpf-lb-sock: "false"
  bpf-lb-sock-hostns-only: "true"
  kube-proxy-replacement: "true"
  kube-proxy-replacement-healthz-bind-address: ""
```

**What to look for:** `KubeProxyReplacement: True`, and `bpf-lb-sock-hostns-only: "true"` (pods skip the socket-level step; see the lesson).

### 3. No Service rules in iptables on the node

No kube-proxy means no KUBE-SVC rules; Cilium keeps a few rules of its own.

```bash
docker exec ckne-worker sh -c 'iptables-save | grep -c KUBE-SVC'
docker exec ckne-worker sh -c 'iptables-save | grep -c CILIUM'
```

Our output:

```text
$ docker exec ckne-worker sh -c 'iptables-save | grep -c KUBE-SVC'
0
$ docker exec ckne-worker sh -c 'iptables-save | grep -c CILIUM'
42
```

**What to look for:** `0` KUBE-SVC rules. That's success, not a fault.

### 4. Cilium's own Service table: frontend (ClusterIP:port) -> backends (pod IP:port)

Each Service is a frontend (ClusterIP:port) with backends (pod IP:port), stored in eBPF maps.

```bash
kubectl get svc web web-np
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg service list | grep -A1 "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}'):80/TCP"
```

Our output:

```text
$ kubectl get svc web web-np
NAME     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web      ClusterIP   10.96.29.213    <none>        80/TCP         8s
web-np   NodePort    10.96.235.193   <none>        80:31075/TCP   8s
$ kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS              AGE
web-mmkbd   IPv4          8080    10.0.2.184,10.0.1.66   8s
$ kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg service list | grep -A1 "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}'):80/TCP"
7    10.96.29.213:80/TCP    ClusterIP      1 => 10.0.1.66:8080/TCP (active)
                                           2 => 10.0.2.184:8080/TCP (active)
```

**What to look for:** web's ClusterIP with both pod IPs as backends. With Cilium's IPAM, pod IPs come from 10.0.0.0/8, not kind's 10.244.0.0/16.

### 5. It still works: ClusterIP from a pod, NodePort from outside the pod network

ClusterIP from a pod, NodePort from outside the pod network.

```bash
kubectl exec client -- wget -qO- -T 3 http://web/hostname; echo
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
```

Our output:

```text
$ kubectl exec client -- wget -qO- -T 3 http://web/hostname; echo
web-5bfd9679bc-vcrcn
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
web-5bfd9679bc-vcrcn
```

**What to look for:** a pod name from each.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for no kube-proxy, KubeProxyReplacement True, web in Cilium's table, no KUBE-SVC rules, and working ClusterIP and NodePort.

```bash
bash lab.sh check
```

Our output:

```text
PASS  no kube-proxy DaemonSet
PASS  Cilium reports KubeProxyReplacement: True
PASS  Cilium's Service table has Service web's ClusterIP
PASS  no KUBE-SVC iptables rules on ckne-worker
PASS  pod client reaches web by name
PASS  web-np answers on a worker's IP and NodePort
6 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
