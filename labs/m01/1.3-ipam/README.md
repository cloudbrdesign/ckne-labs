# Lab 1.3: IPAM and pod CIDRs

Lab for the course lesson **1.3 IPAM and pod CIDRs**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.3-ipam
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. The cluster's pod range, set on kube-controller-manager
2. Each node gets its own slice: spec.podCIDR
3. Pods get IPs from their node's slice
4. The IPAM plugin's own records on a node: host-local keeps one file per allocated IP
5. Services use a different range: the Service CIDR

## What the check looks for

- every ipam-demo pod's IP is inside its node's podCIDR
- no two nodes share a podCIDR
- ckne-worker has host-local records for its pods (in its host-local data directory)

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (73 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (50 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 022); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It uses kind's default network plugin (kindnet) and kube-proxy in iptables mode.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: false, kubeProxyMode: iptables}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env).

### 1. The cluster's pod range, set on kube-controller-manager

Layer one: the cluster has one large pod range, set on the controller manager, which also hands each node a slice.

```bash
docker exec ckne-control-plane sh -c "grep -E 'cluster-cidr|allocate-node-cidrs|node-cidr-mask' /etc/kubernetes/manifests/kube-controller-manager.yaml"
```

Our output:

```text
$ docker exec ckne-control-plane sh -c "grep -E 'cluster-cidr|allocate-node-cidrs|node-cidr-mask' /etc/kubernetes/manifests/kube-controller-manager.yaml"
    - --allocate-node-cidrs=true
    - --cluster-cidr=10.244.0.0/16
```

**What to look for:** `--allocate-node-cidrs=true` and `--cluster-cidr=10.244.0.0/16`.

### 2. Each node gets its own slice: spec.podCIDR

Layer two: each node's slice is recorded on the Node object.

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,PODCIDR:.spec.podCIDR
```

Our output:

```text
$ kubectl get nodes -o custom-columns=NODE:.metadata.name,PODCIDR:.spec.podCIDR
NODE                 PODCIDR
ckne-control-plane   10.244.0.0/24
ckne-worker          10.244.1.0/24
ckne-worker2         10.244.2.0/24
```

**What to look for:** a different `/24` per node. Which node gets which slice can vary between runs.

### 3. Pods get IPs from their node's slice

Layer three: on each node, the IPAM plugin hands out single addresses from that node's slice.

```bash
kubectl create deployment ipam-demo --image=nginx:1.29 --replicas=6
kubectl rollout status deploy/ipam-demo --timeout=120s
kubectl get pods -l app=ipam-demo -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP --sort-by=.spec.nodeName
```

Our output:

```text
$ kubectl get pods -l app=ipam-demo -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP --sort-by=.spec.nodeName
POD                          NODE           IP
ipam-demo-5b45b6c7d5-kkwhc   ckne-worker    10.244.1.4
ipam-demo-5b45b6c7d5-nw728   ckne-worker    10.244.1.2
ipam-demo-5b45b6c7d5-zn6z8   ckne-worker    10.244.1.3
ipam-demo-5b45b6c7d5-hs5sv   ckne-worker2   10.244.2.2
ipam-demo-5b45b6c7d5-kpplj   ckne-worker2   10.244.2.3
ipam-demo-5b45b6c7d5-zl6kq   ckne-worker2   10.244.2.4
```

**What to look for:** every pod's IP sits inside its own node's `/24`.

### 4. The IPAM plugin's own records on a node: host-local keeps one file per allocated IP

host-local keeps one file per address in use, in the directory the CNI config names.

```bash
docker exec ckne-worker sh -c 'grep -h -A3 "\"ipam\"" /etc/cni/net.d/*.conflist'
docker exec ckne-worker sh -c 'ls /run/cni-ipam-state/*/'
```

Our output:

```text
$ docker exec ckne-worker sh -c 'grep -h -A3 "\"ipam\"" /etc/cni/net.d/*.conflist'
		"ipam": {
			"type": "host-local",
			"dataDir": "/run/cni-ipam-state",
			"routes": [
host-local state directory on ckne-worker: /run/cni-ipam-state
$ docker exec ckne-worker sh -c 'ls /run/cni-ipam-state/*/'
10.244.1.2
10.244.1.3
10.244.1.4
last_reserved_ip.0
lock
```

**What to look for:** `"dataDir": "/run/cni-ipam-state"` in kind's config, and one file named after each pod IP on that node (plus `last_reserved_ip` and `lock`). Without a `dataDir`, host-local uses `/var/lib/cni/networks`.

### 5. Services use a different range: the Service CIDR

ClusterIPs come from a separate Service range, set on the API server and shown as a ServiceCIDR object.

```bash
docker exec ckne-control-plane sh -c 'grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml'
kubectl get servicecidrs
```

Our output:

```text
$ docker exec ckne-control-plane sh -c 'grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml'
    - --service-cluster-ip-range=10.96.0.0/16
$ kubectl get servicecidrs
NAME         CIDRS          AGE
kubernetes   10.96.0.0/16   45s
```

**What to look for:** `10.96.0.0/16`: it must not overlap the pod range or networks your pods need to reach.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for every pod inside its node's slice, no shared slices, and host-local records on ckne-worker.

```bash
bash lab.sh check
```

Our output:

```text
PASS  every ipam-demo pod's IP is inside its node's podCIDR
PASS  no two nodes share a podCIDR
PASS  ckne-worker has host-local records for its pods (in /run/cni-ipam-state)
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
