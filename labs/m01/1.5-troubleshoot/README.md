# Lab 1.5: Troubleshooting pod connectivity and DNS

Lab for the course lesson **1.5 Troubleshooting pod connectivity and DNS**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

**This lab arrives broken.** Try it yourself first: `bash lab.sh up` builds the cluster with the faults in namespace `shop`, and `bash lab.sh check` tells you what the grader expects. Fix it until the check passes, then run the steps to compare with how we did it.

## Run it

```bash
cd labs/m01/1.5-troubleshoot
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Symptom: the client can't reach api by name
2. DNS first: what resolver does the pod use?
3. Fix 1: recreate the client with the cluster's DNS (dnsPolicy ClusterFirst)
4. Still failing: name resolves, but nothing answers. Check the Service's endpoints
5. Fix 2: point the Service's selector at the pods' real label

## What the check looks for

- client resolves api.shop.svc.cluster.local
- Service api has ready endpoints
- client reaches http://api

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (130 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (99 s).

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

### Set up the lab

**Spoiler:** these commands create the two faults. Try `bash lab.sh up` and find them yourself first; come back here to compare.

```bash
kubectl create ns shop
kubectl -n shop create deployment api --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080
kubectl -n shop expose deploy api --port=80 --target-port=8080
cat <<'EOF' | kubectl -n shop apply -f -
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  dnsPolicy: None
  dnsConfig: {nameservers: ["10.96.0.53"], searches: ["shop.svc.cluster.local", "svc.cluster.local", "cluster.local"], options: [{name: ndots, value: "5"}]}
  containers: [{name: c, image: "busybox:1.36.1", command: ["sleep", "3600"]}]
EOF
kubectl -n shop patch svc api -p '{"spec":{"selector":{"app":"api-v2"}}}'
kubectl -n shop rollout status deploy/api --timeout=120s
kubectl -n shop wait --for=condition=Ready pod/client --timeout=120s
```

### 1. Symptom: the client can't reach api by name

Start from what the user sees.

```bash
kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname
```

Our output:

```text
$ kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname
```

**What to look for:** `bad address 'api'`: the name didn't resolve. Layer one (DNS) first.

### 2. DNS first: what resolver does the pod use?

Read the pod's resolver config, then ask the cluster's DNS Service directly.

```bash
kubectl -n shop exec client -- cat /etc/resolv.conf
kubectl -n kube-system get svc kube-dns
kubectl -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local
kubectl -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local 10.96.0.10
```

Our output:

```text
$ kubectl -n shop exec client -- cat /etc/resolv.conf
wget: bad address 'api'
command terminated with exit code 1
search shop.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.53
options ndots:5
$ kubectl -n kube-system get svc kube-dns
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   60s
$ kubectl -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local
;; connection timed out; no servers could be reached
command terminated with exit code 1
$ kubectl -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local 10.96.0.10
Server:		10.96.0.10
Address:	10.96.0.10:53
Name:	api.shop.svc.cluster.local
Address: 10.96.67.229
```

**What to look for:** the pod's `nameserver` is `10.96.0.53`, but kube-dns is `10.96.0.10`. Asking 10.96.0.10 directly works: cluster DNS is fine, the pod asks the wrong server.

### 3. Fix 1: recreate the client with the cluster's DNS (dnsPolicy ClusterFirst)

A pod's `dnsConfig` can't be edited in place: recreate it with the default `dnsPolicy` (ClusterFirst).

```bash
kubectl -n shop delete pod client
kubectl -n shop run client --image=busybox:1.36.1 -- sleep 3600
kubectl -n shop wait --for=condition=Ready pod/client --timeout=120s
kubectl -n shop exec client -- nslookup api.shop.svc.cluster.local
```

Our output:

```text
$ kubectl -n shop run client --image=busybox:1.36.1 -- sleep 3600
pod/client created
$ kubectl -n shop exec client -- nslookup api.shop.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53
Name:	api.shop.svc.cluster.local
Address: 10.96.67.229
```

**What to look for:** the answer now comes from `10.96.0.10`.

### 4. Still failing: name resolves, but nothing answers. Check the Service's endpoints

The name resolves but nothing answers: layer two, the Service and its endpoints.

```bash
kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname
kubectl -n shop get endpointslices -l kubernetes.io/service-name=api
kubectl -n shop get svc api -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n shop get pods --show-labels
```

Our output:

```text
$ kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname
wget: can't connect to remote host (10.96.67.229): Connection refused
command terminated with exit code 1
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
api-74hws   IPv4          <unset>   <unset>     64s
$ kubectl -n shop get svc api -o jsonpath='{.spec.selector}{"\n"}'
{"app":"api-v2"}
$ kubectl -n shop get pods --show-labels
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
api-677758794f-mcxpf   1/1     Running   0          64s   app=api,pod-template-hash=677758794f
client                 1/1     Running   0          3s    run=client
```

**What to look for:** the EndpointSlice has no endpoints (`<unset>`), because the Service selects `app=api-v2` and the pods are labelled `app=api`. Kubernetes reports no error for this.

### 5. Fix 2: point the Service's selector at the pods' real label

Point the selector at the pods' real label.

```bash
kubectl -n shop patch svc api -p '{"spec":{"selector":{"app":"api"}}}' --type=merge
kubectl -n shop get endpointslices -l kubernetes.io/service-name=api
kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname; echo
```

Our output:

```text
$ kubectl -n shop patch svc api -p '{"spec":{"selector":{"app":"api"}}}' --type=merge
service/api patched
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS   ENDPOINTS    AGE
api-74hws   IPv4          8080    10.244.1.2   64s
$ kubectl -n shop exec client -- wget -qO- -T 3 http://api/hostname; echo
api-677758794f-mcxpf
```

**What to look for:** the EndpointSlice now lists the pod's IP, and the request returns the pod's name.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for name resolution, ready endpoints and a working request, all from the client pod.

```bash
bash lab.sh check
```

Our output:

```text
PASS  client resolves api.shop.svc.cluster.local
PASS  Service api has ready endpoints
PASS  client reaches http://api
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
