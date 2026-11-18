# Lab 0.3: Working like the exam

Lab for the course lesson **0.3 Working like the exam**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m00/0.3-exam-workflow
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Which cluster am I talking to? (every exam task starts here)
2. Get onto a node: in the exam you ssh to a named host; in our lab the nodes are containers
3. Look up a field without leaving the terminal: kubectl explain
4. Generate YAML instead of writing it: --dry-run=client -o yaml
5. Verify like the grader: test from inside the cluster, not from your laptop

## What the check looks for

- deployment web has 2 ready replicas
- service web exposes port 80
- service web has 2 ready endpoints
- web answers from inside the cluster

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (74 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (55 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Apple silicon Mac with Colima, 18 Nov 2026, job 026); names, IPs and ages will differ on your machine.

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

### 1. Which cluster am I talking to? (every exam task starts here)

Every exam task starts by making sure you're on the right cluster: a perfect answer on the wrong one scores nothing.

```bash
kubectl config get-contexts
kubectl config current-context
```

Our output:

```text
$ kubectl config get-contexts
CURRENT   NAME                                                          CLUSTER                                                       AUTHINFO       …
          arn:aws:eks:af-south-1:117133899410:cluster/eks-experiments   arn:aws:eks:af-south-1:117133899410:cluster/eks-experiments   arn:aws:eks:af-…
          arn:aws:eks:af-south-1:697051637339:cluster/wfs-eks-qa        arn:aws:eks:af-south-1:697051637339:cluster/wfs-eks-qa        arn:aws:eks:af-…
          arn:aws:eks:eu-west-1:697051637339:cluster/EKSDemoCluster     arn:aws:eks:eu-west-1:697051637339:cluster/EKSDemoCluster     arn:aws:eks:eu-…
          kind-assure                                                   kind-assure                                                   kind-assure
*         kind-ckne                                                     kind-ckne                                                     kind-ckne
          kind-hami-lab                                                 kind-hami-lab                                                 kind-hami-lab
          orbstack                                                      orbstack                                                      orbstack
          wfs-eks-qa                                                    arn:aws:eks:af-south-1:697051637339:cluster/wfs-eks-qa        arn:aws:eks:af-…
$ kubectl config current-context
kind-ckne
```

**What to look for:** the `*` marks the current context; here it's `kind-ckne`. In the exam, switch with `kubectl config use-context <name>` before anything else.

### 2. Get onto a node: in the exam you ssh to a named host; in our lab the nodes are containers

In the exam you `ssh` to the host a task names. Our nodes are containers, so `docker exec` takes you onto one.

```bash
docker exec ckne-worker hostname
docker exec ckne-worker sh -c 'crictl ps --name kindnet -q | head -1; ip -br addr | head -5'
```

Our output:

```text
$ docker exec ckne-worker hostname
ckne-worker
$ docker exec ckne-worker sh -c 'crictl ps --name kindnet -q | head -1; ip -br addr | head -5'
b824e2723741eb6800dffc037d1d67d47043dfab6b9e4158785e037072c10cf0
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if111       UP             172.18.0.4/16 fc00:f853:ccd:e793::4/64 fe80::c891:f9ff:febb:905d/64
```

**What to look for:** you're now running commands on the node itself: its container runtime (`crictl`) and its own interfaces (`eth0` with the node's address).

### 3. Look up a field without leaving the terminal: kubectl explain

`kubectl explain` prints any field of any object, with what it means, without opening a browser.

```bash
kubectl explain service.spec.internalTrafficPolicy
kubectl explain networkpolicy.spec.policyTypes
```

Our output:

```text
$ kubectl explain service.spec.internalTrafficPolicy
KIND:       Service
VERSION:    v1
FIELD: internalTrafficPolicy <string>
ENUM:
    Cluster
    Local
DESCRIPTION:
    InternalTrafficPolicy describes how nodes distribute service traffic they
    receive on the ClusterIP. If set to "Local", the proxy will assume that pods
    only want to talk to endpoints of the service on the same node as the pod,
    dropping the traffic if there are no local endpoints. The default value,
    "Cluster", uses the standard behavior of routing to all endpoints evenly
    (possibly modified by topology and other features).
    Possible enum values:
     - `"Cluster"` routes traffic to all endpoints.
     - `"Local"` routes traffic only to endpoints on the same node as the client
    pod (dropping the traffic if there are no local endpoints).
$ kubectl explain networkpolicy.spec.policyTypes
GROUP:      networking.k8s.io
KIND:       NetworkPolicy
VERSION:    v1
FIELD: policyTypes <[]string>
DESCRIPTION:
    policyTypes is a list of rule types that the NetworkPolicy relates to. Valid
    options are ["Ingress"], ["Egress"], or ["Ingress", "Egress"]. If this field
    is not specified, it will default based on the existence of ingress or
    egress rules; policies that contain an egress section are assumed to affect
    egress, and all policies (whether or not they contain an ingress section)
    are assumed to affect ingress. If you want to write an egress-only policy,
    you must explicitly specify policyTypes [ "Egress" ]. Likewise, if you want
    to write a policy that specifies that no egress is allowed, you must specify
    a policyTypes value that include "Egress" (since such a policy would not
    include an egress section and would otherwise default to just [ "Ingress"
    ]). This field is beta-level in 1.8
```

**What to look for:** the field's type, its allowed values and the default. Add `--recursive` to see a whole subtree.

### 4. Generate YAML instead of writing it: --dry-run=client -o yaml

Let kubectl write a correct starting file, then edit only what the task asks for.

```bash
kubectl create deployment web --image=nginx:1.29 --replicas=2 --dry-run=client -o yaml
kubectl create deployment web --image=nginx:1.29 --replicas=2
kubectl expose deployment web --port=80 --target-port=80
kubectl rollout status deploy/web --timeout=120s
kubectl get deploy,svc,endpointslices -l app=web -o wide
```

Our output:

```text
$ kubectl create deployment web --image=nginx:1.29 --replicas=2 --dry-run=client -o yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: web
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  strategy: {}
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - image: nginx:1.29
        name: nginx
        resources: {}
status: {}
$ kubectl create deployment web --image=nginx:1.29 --replicas=2
deployment.apps/web created
$ kubectl expose deployment web --port=80 --target-port=80
service/web exposed
$ kubectl get deploy,svc,endpointslices -l app=web -o wide
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
deployment.apps/web   2/2     2            2           14s   nginx        nginx:1.29   app=web
NAME          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
service/web   ClusterIP   10.96.212.164   <none>        80/TCP    14s   app=web
NAME                                       ADDRESSTYPE   PORTS   ENDPOINTS               AGE
endpointslice.discovery.k8s.io/web-hmtjl   IPv4          80      10.244.2.2,10.244.1.2   14s
```

**What to look for:** `--dry-run=client -o yaml` creates nothing; it only prints. In the exam, redirect it to a file (`> web.yaml`), edit, then `kubectl apply -f web.yaml`. The EndpointSlice lists two pod IPs: the Service has its two endpoints.

### 5. Verify like the grader: test from inside the cluster, not from your laptop

The grader checks what the cluster does. A small probe pod inside the cluster sees what the grader sees.

```bash
kubectl run probe --image=busybox:1.36.1 -- sleep 3600
kubectl wait --for=condition=Ready pod/probe --timeout=120s
kubectl exec probe -- wget -qO- -T 3 http://web | head -4
```

Our output:

```text
$ kubectl exec probe -- wget -qO- -T 3 http://web | head -4
<!DOCTYPE html>
<html>
<head>
```

**What to look for:** the start of nginx's welcome page: the Service name resolved and the request reached a pod. Wait for the probe to be Ready before testing from it.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for 2 ready replicas, port 80 on the Service, 2 ready endpoints, and an answer from inside the cluster.

```bash
bash lab.sh check
```

Our output:

```text
PASS  deployment web has 2 ready replicas
PASS  service web exposes port 80
PASS  service web has 2 ready endpoints
PASS  web answers from inside the cluster
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
