# Lab 2.7: Gateway API: Gateway and HTTPRoute

Lab for the course lesson **2.7 Gateway API: Gateway and HTTPRoute**. It creates a fresh 3-node kind cluster named `ckne` (Cilium as the network plugin, replacing kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.7-gateway-api
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. The GatewayClass: Cilium registered itself as a Gateway API implementation
2. A Gateway: one HTTP listener on port 80 (the platform team's object)
3. An HTTPRoute: /v1 and /v2 by path, and / split 80/20 (the app team's object)
4. Route by path, through the Gateway's address
5. Weighted split on /: 20 requests

## What the check looks for

- Gateway web is Programmed
- HTTPRoute echo is Accepted by Gateway web
- /v1 reaches an echo-v1 pod
- /v2 reaches an echo-v2 pod

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (152 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (129 s).

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

Two backends (echo-v1, echo-v2), an address pool for the Gateway, and a client pod.

```bash
for v in v1 v2; do kubectl create deployment echo-$v --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080; kubectl expose deployment echo-$v --port=80 --target-port=8080; done
# a small pool of load-balancer addresses from kind's Docker network, for Cilium's LB IPAM (module 3)
PRE=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$PRE.255.200", stop: "$PRE.255.220"}]}
EOF
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl rollout status deploy/echo-v1 --timeout=120s; kubectl rollout status deploy/echo-v2 --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. The GatewayClass: Cilium registered itself as a Gateway API implementation

Cilium registers a GatewayClass when Gateway API support is on; the CRDs come from the Gateway API release.

```bash
kubectl get gatewayclass
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
```

Our output:

```text
$ kubectl get gatewayclass
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       108s
$ kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
NAME                                   SCOPE        VERSIONS              CREATED AT
gateways.gateway.networking.k8s.io     Namespaced   v1(storage),v1beta1   2026-11-18T14:51:48Z
httproutes.gateway.networking.k8s.io   Namespaced   v1(storage),v1beta1   2026-11-18T14:51:49Z
```

**What to look for:** GatewayClass `cilium`, controller `io.cilium/gateway-controller`, `ACCEPTED True`.

### 2. A Gateway: one HTTP listener on port 80 (the platform team's object)

One HTTP listener on port 80. Cilium gives it a LoadBalancer Service, which gets an address from the pool.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: web}
spec:
  gatewayClassName: cilium
  listeners: [{name: http, protocol: HTTP, port: 80, allowedRoutes: {namespaces: {from: Same}}}]
EOF
kubectl wait --for=condition=Programmed gateway/web --timeout=180s
kubectl get gateway web
kubectl get svc -l io.cilium.gateway/owning-gateway=web
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: web}
spec:
  gatewayClassName: cilium
  listeners: [{name: http, protocol: HTTP, port: 80, allowedRoutes: {namespaces: {from: Same}}}]
EOF
$ kubectl wait --for=condition=Programmed gateway/web --timeout=180s
gateway.gateway.networking.k8s.io/web condition met
$ kubectl get gateway web
NAME   CLASS    ADDRESS          PROGRAMMED   AGE
web    cilium   172.18.255.200   True         0s
$ kubectl get svc -l io.cilium.gateway/owning-gateway=web
NAME                 TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
cilium-gateway-web   LoadBalancer   10.96.37.252   172.18.255.200   80:30488/TCP   0s
```

**What to look for:** `PROGRAMMED True` and an `ADDRESS` from the pool, the same as the `cilium-gateway-web` Service's EXTERNAL-IP.

### 3. An HTTPRoute: /v1 and /v2 by path, and / split 80/20 (the app team's object)

Two path rules with a rewrite, and a weighted default rule.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo}
spec:
  parentRefs: [{name: web}]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: echo-v1, port: 80}]
  - matches: [{path: {type: PathPrefix, value: /v2}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: echo-v2, port: 80}]
  - backendRefs: [{name: echo-v1, port: 80, weight: 80}, {name: echo-v2, port: 80, weight: 20}]
EOF
sleep 5
kubectl get httproute echo -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo}
spec:
  parentRefs: [{name: web}]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: echo-v1, port: 80}]
  - matches: [{path: {type: PathPrefix, value: /v2}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: echo-v2, port: 80}]
  - backendRefs: [{name: echo-v1, port: 80, weight: 80}, {name: echo-v2, port: 80, weight: 20}]
EOF
$ kubectl get httproute echo -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'
Accepted=True ResolvedRefs=True
```

**What to look for:** `Accepted=True ResolvedRefs=True`: attached to the Gateway, and both backends exist.

### 4. Route by path, through the Gateway's address

Call the Gateway's address from a pod.

```bash
GW=$(kubectl get gateway web -o jsonpath='{.status.addresses[0].value}')
kubectl exec client -- wget -qO- -T 3 http://$GW/v1/hostname; echo
kubectl exec client -- wget -qO- -T 3 http://$GW/v2/hostname; echo
```

Our output:

```text
Gateway address: 172.18.255.200
$ kubectl exec client -- wget -qO- -T 3 http://$GW/v1/hostname; echo
echo-v1-5d64668b66-xr5tj
$ kubectl exec client -- wget -qO- -T 3 http://$GW/v2/hostname; echo
echo-v2-74988d969c-7fp5x
```

**What to look for:** an echo-v1 pod name for /v1, an echo-v2 pod name for /v2 (the rewrite turned /v1/hostname into /hostname).

### 5. Weighted split on /: 20 requests

20 requests to /hostname, counted by Deployment.

```bash
kubectl exec client -- sh -c "for i in \$(seq 1 20); do wget -qO- -T 2 http://$GW/hostname; echo; done" | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c
```

Our output:

```text
     15 echo-v1
      5 echo-v2
```

**What to look for:** roughly 16 to 4. Weights are proportions, so a small sample wanders.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for a Programmed Gateway, an Accepted route, and /v1 and /v2 reaching the right backends.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Gateway web is Programmed
PASS  HTTPRoute echo is Accepted by Gateway web
PASS  /v1 reaches an echo-v1 pod
PASS  /v2 reaches an echo-v2 pod
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
