# Lab 5.2: End-to-end performance with tracing

Lab for the course lesson **5.2 End-to-end performance with tracing**. It creates a fresh kind cluster named `ckne` with Cilium plus Istio in ambient mode, with a Jaeger tracing provider in istiod's mesh config, and cert-manager. The lab adds Jaeger and Istio's Bookinfo sample (one reviews version) in an ambient `bookinfo` namespace, and a client pod, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m05/5.2-tracing
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Bookinfo in the ambient mesh: the page works, but nothing is traced
2. Add a waypoint and turn on tracing for the whole mesh
3. One request, one trace: a span for every hop through the waypoint
4. Make ratings slow: a 2-second delay injected at the waypoint
5. Remove the fault: the request is fast again

## What the check looks for

- productpage answers 200 through the mesh
- the bookinfo waypoint is Programmed
- a span mentions ratings

## Tested

20 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (328 s for `bash lab.sh run`).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 126, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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

`bash lab.sh up` also installs Istio and cert-manager (the full lab profile); the setup below shows the Istio part with this lab's tracing values.

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

Istio ambient with a Jaeger tracing provider, then Jaeger, Bookinfo (reviews-v2 only, so every request takes the same path) and a client pod.

```bash
cat > tracing-values.yaml <<'EOF'
meshConfig:
  enableTracing: true
  extensionProviders:
  - name: jaeger
    opentelemetry: {port: 4317, service: jaeger-collector.istio-system.svc.cluster.local}
EOF
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version 1.30.8 --wait
helm upgrade --install istiod istio/istiod -n istio-system --version 1.30.8 --set profile=ambient -f tracing-values.yaml --wait
helm upgrade --install istio-cni istio/cni -n istio-system --version 1.30.8 --set profile=ambient --wait
helm upgrade --install ztunnel istio/ztunnel -n istio-system --version 1.30.8 --wait
kubectl apply -f https://raw.githubusercontent.com/istio/istio/1.30.8/samples/addons/jaeger.yaml
kubectl create namespace bookinfo
kubectl label namespace bookinfo istio.io/dataplane-mode=ambient
kubectl -n bookinfo apply -f https://raw.githubusercontent.com/istio/istio/1.30.8/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl -n bookinfo delete deployment reviews-v1 reviews-v3
kubectl -n bookinfo run client --image=nicolaka/netshoot:v0.13 -- sleep 36000
kubectl -n istio-system rollout status deploy/jaeger --timeout=300s
kubectl -n bookinfo wait --for=condition=Available deploy --all --timeout=600s
kubectl -n bookinfo wait --for=condition=Ready pod/client --timeout=300s
# a small helper: print the newest trace for the waypoint as a timeline of spans
spans(){ kubectl -n bookinfo exec client -- curl -s "http://tracing.istio-system/jaeger/api/traces?service=waypoint.bookinfo&limit=1&lookback=2m" | jq -r '
  .data[0] as $t | ($t.spans | min_by(.startTime).startTime) as $t0 | "trace \($t.traceID[0:16])…  \($t.spans | length) spans",
  ($t.spans | sort_by(.startTime)[] | "  +\(((.startTime - $t0) / 1000) | floor) ms  \((.duration / 1000) | floor) ms  \($t.processes[.processID].serviceName)  \(.operationName)")'; }
```

### 1. Bookinfo in the ambient mesh: the page works, but nothing is traced

The app is in the ambient mesh, but only ztunnel handles its traffic. ztunnel is L4: it never sees an HTTP request, so it makes no spans.

```bash
kubectl -n bookinfo get pods
kubectl -n bookinfo exec client -- curl -s http://productpage:9080/productpage | grep -o '<title>.*</title>'
kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage
kubectl -n bookinfo exec client -- curl -s http://tracing.istio-system/jaeger/api/services | jq -c .data
```

Our output:

```text
$ kubectl -n bookinfo get pods
NAME                              READY   STATUS        RESTARTS   AGE
client                            1/1     Running       0          41s
details-v1-5b954d689-zz8m4        1/1     Running       0          41s
productpage-v1-695f6ddbcd-xmwps   1/1     Running       0          41s
ratings-v1-596d78db9c-hrfcq       1/1     Running       0          41s
reviews-v1-64dbc5d8f7-z7bfc       1/1     Terminating   0          41s
reviews-v2-6654685b49-mqhfw       1/1     Running       0          41s
reviews-v3-5c95cc9fbf-n5vd2       1/1     Terminating   0          41s
$ kubectl -n bookinfo exec client -- curl -s http://productpage:9080/productpage | grep -o '<title>.*</title>'
<title>Simple Bookstore App</title>
$ kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage
200 0.065502s
$ kubectl -n bookinfo exec client -- curl -s http://tracing.istio-system/jaeger/api/services | jq -c .data
[]
ztunnel is L4: it can't see HTTP requests, so it can't make spans. Tracing in ambient needs a waypoint.
```

**What to look for:** the page answers (`200`, about 60 ms) and Jaeger knows no services: `[]`.

### 2. Add a waypoint and turn on tracing for the whole mesh

A waypoint is an Envoy proxy for the namespace: L7, so it can trace. The Telemetry resource turns tracing on for the whole mesh, with the jaeger provider, for every request.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: waypoint, namespace: bookinfo, labels: {istio.io/waypoint-for: service}}
spec:
  gatewayClassName: istio-waypoint
  listeners: [{name: mesh, port: 15008, protocol: HBONE}]
---
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: {name: mesh-default, namespace: istio-system}
spec:
  tracing:
  - providers: [{name: jaeger}]
    randomSamplingPercentage: 100
EOF
kubectl label namespace bookinfo istio.io/use-waypoint=waypoint
kubectl -n bookinfo wait --for=condition=Programmed gateway/waypoint --timeout=180s
kubectl -n bookinfo get gateway waypoint
kubectl -n istio-system get telemetry
for i in 1 2 3 4 5; do kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage >/dev/null; done; sleep 10
kubectl -n bookinfo exec client -- curl -s http://tracing.istio-system/jaeger/api/services | jq -c .data
```

Our output:

```text
$ kubectl label namespace bookinfo istio.io/use-waypoint=waypoint
namespace/bookinfo labeled
$ kubectl -n bookinfo get gateway waypoint
NAME       CLASS            ADDRESS       PROGRAMMED   AGE
waypoint   istio-waypoint   10.96.43.26   True         7s
$ kubectl -n istio-system get telemetry
NAME           AGE
mesh-default   7s
$ for i in 1 2 3 4 5; do kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage >/dev/null; done; sleep 10
kubectl -n bookinfo exec client -- curl -s http://tracing.istio-system/jaeger/api/services | jq -c .data
["jaeger","waypoint.bookinfo"]
```

**What to look for:** the waypoint `PROGRAMMED True`, and a new service in Jaeger: `waypoint.bookinfo`.

### 3. One request, one trace: a span for every hop through the waypoint

Send one request and read the newest trace. Each span is one hop through the waypoint: when it started (+ms after the first), how long it took, and the operation (host:port/path).

```bash
kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage; sleep 8
spans
```

Our output:

```text
$ kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage; sleep 8
200 0.066029s
$ spans
trace e07d85ebaa03fd73…  4 spans
  +0 ms  63 ms  waypoint.bookinfo  productpage.bookinfo.svc.cluster.local:9080/*
  +13 ms  1 ms  waypoint.bookinfo  details.bookinfo.svc.cluster.local:9080/*
  +19 ms  19 ms  waypoint.bookinfo  reviews.bookinfo.svc.cluster.local:9080/*
  +32 ms  2 ms  waypoint.bookinfo  ratings.bookinfo.svc.cluster.local:9080/*
+ms: when the span started, after the first one. Then its duration, the service and the operation (host:port/path).
```

**What to look for:** 4 spans: productpage, details, reviews, ratings. productpage lasts the whole request; reviews contains ratings.

### 4. Make ratings slow: a 2-second delay injected at the waypoint

Inject a 2-second delay on every call to ratings. The waypoint applies it (VirtualService in ambient is alpha).

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: ratings-delay, namespace: bookinfo}
spec:
  hosts: [ratings]
  http:
  - fault: {delay: {percentage: {value: 100}, fixedDelay: 2s}}
    route: [{destination: {host: ratings}}]
EOF
kubectl -n bookinfo get virtualservice
sleep 5; kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage; sleep 8
spans
```

Our output:

```text
$ kubectl -n bookinfo get virtualservice
NAME            GATEWAYS   HOSTS         AGE
ratings-delay              ["ratings"]   0s
$ sleep 5; kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage; sleep 8
200 2.054040s
$ spans
trace ae75807c7d84be34…  4 spans
  +0 ms  2050 ms  waypoint.bookinfo  productpage.bookinfo.svc.cluster.local:9080/*
  +5 ms  2 ms  waypoint.bookinfo  details.bookinfo.svc.cluster.local:9080/*
  +13 ms  2032 ms  waypoint.bookinfo  reviews.bookinfo.svc.cluster.local:9080/*
  +24 ms  2008 ms  waypoint.bookinfo  ratings.bookinfo.svc.cluster.local:9080/*
The whole request got slower. The trace shows where: every span on the path to ratings grew by about 2 s.
```

**What to look for:** the page takes about 2 s, and productpage, reviews and ratings all grow by about 2 s: a parent span includes the time it waits for its children. The deepest span that is still slow, ratings, is where the time goes.

### 5. Remove the fault: the request is fast again

Delete the VirtualService and measure again.

```bash
kubectl -n bookinfo delete virtualservice ratings-delay
sleep 5; kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage
```

Our output:

```text
$ kubectl -n bookinfo delete virtualservice ratings-delay
virtualservice.networking.istio.io "ratings-delay" deleted from bookinfo namespace
$ sleep 5; kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://productpage:9080/productpage
200 0.045772s
```

**What to look for:** the page is back to tens of milliseconds.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check asks for a 200 from productpage, a Programmed waypoint, a trace with 4 or more spans, and a span for ratings.

```bash
bash lab.sh check
```

Our output:

```text
PASS  productpage answers 200 through the mesh
PASS  the bookinfo waypoint is Programmed
PASS  Jaeger has a trace with 4 or more spans
PASS  a span mentions ratings
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
