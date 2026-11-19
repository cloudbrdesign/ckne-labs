# Lab 4.1: NetworkPolicy: how selectors and rules combine

Lab for the course lesson **4.1 NetworkPolicy: how selectors and rules combine**. It creates a fresh kind cluster named `ckne` with Cilium as the network plugin, which enforces NetworkPolicy. It creates two namespaces, `shop` (db, web, api) and `other` (outsider, monitor), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m04/4.1-networkpolicy
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. No policy yet: every pod, in any namespace, reaches db
2. A policy that selects db and allows only api
3. Allow the monitor from another namespace: one entry, two selectors (AND)
4. The two-dash mistake: two entries (OR) let the whole namespace in
5. Fix it back to AND, and read the policy the way the API sees it

## What the check looks for

- api (shop) reaches db
- web (shop) is blocked
- monitor (other, role=monitor) reaches db
- outsider (other, no label) is blocked

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (204 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (174 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 103, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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

Two namespaces: `shop` with a db server and two clients, `other` with two clients (one labelled role=monitor).

```bash
kubectl create ns shop; kubectl create ns other
kubectl -n shop create deployment db --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080
kubectl -n shop expose deployment db --port=8080
kubectl -n shop run web --image=busybox:1.36.1 --labels=app=web -- sleep 36000
kubectl -n shop run api --image=busybox:1.36.1 --labels=app=api -- sleep 36000
kubectl -n other run outsider --image=busybox:1.36.1 -- sleep 36000
kubectl -n other run monitor --image=busybox:1.36.1 --labels=role=monitor -- sleep 36000
kubectl -n shop rollout status deploy/db --timeout=120s
kubectl -n shop wait --for=condition=Ready pod/web pod/api --timeout=120s
kubectl -n other wait --for=condition=Ready pod/outsider pod/monitor --timeout=120s
```

### 1. No policy yet: every pod, in any namespace, reaches db

Before any policy, every pod reaches db. The loop at the end tests each client.

```bash
kubectl get networkpolicy -A
kubectl get pods -n shop --show-labels
kubectl get pods -n other --show-labels
for c in shop/web shop/api other/outsider other/monitor; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
```

Our output:

```text
$ kubectl get networkpolicy -A
No resources found
$ kubectl get pods -n shop --show-labels
NAME                  READY   STATUS    RESTARTS   AGE   LABELS
api                   1/1     Running   0          5s    app=api
db-7fd5b6946c-68lwc   1/1     Running   0          6s    app=db,pod-template-hash=7fd5b6946c
web                   1/1     Running   0          5s    app=web
$ kubectl get pods -n other --show-labels
NAME       READY   STATUS    RESTARTS   AGE   LABELS
monitor    1/1     Running   0          6s    role=monitor
outsider   1/1     Running   0          6s    run=outsider
CLIENT           -> db.shop:8080
shop/web         allowed
shop/api         allowed
other/outsider   allowed
other/monitor    allowed
Kubernetes allows all traffic until a policy selects a pod.
```

**What to look for:** `No resources found`, and all four clients `allowed`.

### 2. A policy that selects db and allows only api

Select db and allow ingress only from app=api in the same namespace, on port 8080.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-api, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: api}}
    ports: [{protocol: TCP, port: 8080}]
EOF
sleep 3
for c in shop/web shop/api other/outsider other/monitor; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-api, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: api}}
    ports: [{protocol: TCP, port: 8080}]
EOF
CLIENT           -> db.shop:8080
shop/web         blocked
shop/api         allowed
other/outsider   blocked
other/monitor    blocked
Once a policy selects db, only what some policy allows gets in. A podSelector alone in 'from' means: in the policy's own namespace.
```

**What to look for:** only shop/api allowed.

### 3. Allow the monitor from another namespace: one entry, two selectors (AND)

One `from` entry with a namespaceSelector AND a podSelector: role=monitor pods in namespace other.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
EOF
sleep 3
for c in shop/web shop/api other/outsider other/monitor; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
EOF
CLIENT           -> db.shop:8080
shop/web         blocked
shop/api         allowed
other/outsider   blocked
other/monitor    allowed
One list item holding both selectors: pods labelled role=monitor AND in namespace other. Policies add up: api is still allowed.
```

**What to look for:** api and monitor allowed; outsider (same namespace as monitor, no label) still blocked.

### 4. The two-dash mistake: two entries (OR) let the whole namespace in

The same policy with a second dash: now two entries, combined with OR.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
    - podSelector: {matchLabels: {role: monitor}}
EOF
sleep 3
for c in shop/web shop/api other/outsider other/monitor; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
    - podSelector: {matchLabels: {role: monitor}}
EOF
CLIENT           -> db.shop:8080
shop/web         blocked
shop/api         allowed
other/outsider   allowed
other/monitor    allowed
Two list items: any pod in namespace other, OR pods labelled role=monitor in shop. outsider is now allowed.
```

**What to look for:** outsider allowed too: any pod in namespace other matches the first entry.

### 5. Fix it back to AND, and read the policy the way the API sees it

Back to one entry, then read the policy the way the API sees it.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
EOF
kubectl -n shop describe networkpolicy db-allow-monitor
sleep 3
for c in shop/web shop/api other/outsider other/monitor; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
EOF
$ kubectl -n shop describe networkpolicy db-allow-monitor
Name:         db-allow-monitor
Namespace:    shop
Created on:   2026-11-19 10:36:29 +0000 UTC
Labels:       <none>
Annotations:  <none>
Spec:
  PodSelector:     app=db
  Allowing ingress traffic:
    To Port: <any> (traffic allowed to all ports)
    From:
      NamespaceSelector: kubernetes.io/metadata.name=other
      PodSelector: role=monitor
  Not affecting egress traffic
  Policy Types: Ingress
CLIENT           -> db.shop:8080
shop/web         blocked
shop/api         allowed
other/outsider   blocked
other/monitor    allowed
```

**What to look for:** in `describe`, one `From:` block with both selectors; outsider blocked again.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for api and monitor allowed, web and outsider blocked.

```bash
bash lab.sh check
```

Our output:

```text
PASS  api (shop) reaches db
PASS  web (shop) is blocked
PASS  monitor (other, role=monitor) reaches db
PASS  outsider (other, no label) is blocked
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
