# Lab 3.4: Optimising LLM traffic: Gateway API Inference Extension

Lab for the course lesson **3.4 Optimising LLM traffic: Gateway API Inference Extension**. It creates a fresh kind cluster named `ckne` with Cilium, plus the Gateway API Inference Extension CRDs, Istio's control plane with the extension switched on, and three simulated vLLM model servers (no GPU needed), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m03/3.4-inference-gateway
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster(s) and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Three model servers behind a plain Service: it works, but the Service knows nothing about LLM load
2. What a smarter balancer would read: each server's queue and KV-cache metrics
3. An InferencePool and its endpoint picker (the llm-d router chart, provider: istio)
4. An Istio Gateway and an HTTPRoute whose backend is the InferencePool
5. A completion through the Gateway: the endpoint picker chose the server
6. How it fails: the picker is down. FailOpen or FailClose?

## What the check looks for

- an InferencePool selects the model servers in namespace $NS
- HTTPRoute completions is Accepted and ResolvedRefs
- a completion through the Gateway returns text

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (229 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (210 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 089, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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

The Inference Extension CRDs, Istio's control plane with the extension switched on, an address pool for the Gateway, three simulated model servers and a client.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/manifests.yaml
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version 1.30.8 --wait
helm upgrade --install istiod istio/istiod -n istio-system --version 1.30.8 \
  --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true --wait
PRE=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$PRE.255.200", stop: "$PRE.255.220"}]}
EOF
kubectl create ns llm
cat <<'EOF' | kubectl -n llm apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: model-server}
spec:
  replicas: 3
  selector: {matchLabels: {app: model-server}}
  template:
    metadata: {labels: {app: model-server}}
    spec:
      containers:
      - name: vllm-sim
        image: ghcr.io/llm-d/llm-d-inference-sim:v0.7.1
        args: [--model, meta-llama/Llama-3.1-8B-Instruct, --port, "8000", --max-loras, "2", --lora-modules, '{"name":"reviews-1"}']
        ports: [{name: http, containerPort: 8000}]
        resources: {requests: {cpu: 20m}}
---
apiVersion: v1
kind: Service
metadata: {name: model-server}
spec: {selector: {app: model-server}, ports: [{port: 8000, targetPort: 8000}]}
EOF
kubectl run client -n llm --image=curlimages/curl:8.11.1 -- sleep 36000
kubectl -n llm rollout status deploy/model-server --timeout=240s; kubectl -n llm wait --for=condition=Ready pod/client --timeout=120s
```

### 1. Three model servers behind a plain Service: it works, but the Service knows nothing about LLM load

Three simulated vLLM servers (no GPU). The OpenAI-style API works through an ordinary Service.

```bash
kubectl -n llm get pods -l app=model-server -o wide
kubectl -n llm exec client -- curl -s model-server:8000/v1/models; echo
kubectl -n llm exec client -- curl -s model-server:8000/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"Write one line about Kubernetes networking.","max_tokens":20,"temperature":0}'; echo
```

Our output:

```text
$ kubectl -n llm get pods -l app=model-server -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
model-server-7bd8c66ccc-298dq   1/1     Running   0          15s   10.0.1.134   ckne-worker    <none>           <none>
model-server-7bd8c66ccc-pd4tm   1/1     Running   0          15s   10.0.0.120   ckne-worker2   <none>           <none>
model-server-7bd8c66ccc-xzdqz   1/1     Running   0          15s   10.0.0.93    ckne-worker2   <none>           <none>
$ kubectl -n llm exec client -- curl -s model-server:8000/v1/models; echo
{"object":"list","data":[{"id":"meta-llama/Llama-3.1-8B-Instruct","object":"model","created":1795062999,"owned_by":"vllm","root":"meta-llama/Llama-3.…
$ kubectl -n llm exec client -- curl -s model-server:8000/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"Write one line about Kubernetes networking.","max_tokens":20,"temperature":0}'; echo
{"id":"cmpl-b357a84d-db8f-580c-b190-20ef0a1608e4","created":1795062999,"model":"reviews-1","usage":{"prompt_tokens":7,"completion_tokens":1,"total_to…
```

**What to look for:** two models (`meta-llama/Llama-3.1-8B-Instruct` and the LoRA adapter `reviews-1`) and a `text_completion`.

### 2. What a smarter balancer would read: each server's queue and KV-cache metrics

Each server exposes vLLM metrics: queue length and KV-cache use.

```bash
POD=$(kubectl -n llm get pod -l app=model-server -o jsonpath='{.items[0].status.podIP}')
kubectl -n llm exec client -- curl -s $POD:8000/metrics | grep -E '^vllm:(num_requests_waiting|num_requests_running|gpu_cache_usage_perc|kv_cache_usage_perc)'
```

Our output:

```text
$ kubectl -n llm exec client -- curl -s $POD:8000/metrics | grep -E '^vllm:(num_requests_waiting|num_requests_running|gpu_cache_usage_perc|kv_cache_usage_perc)'
vllm:kv_cache_usage_perc{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0
vllm:num_requests_running{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0
vllm:num_requests_waiting{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0
A Service picks a pod at random. The endpoint picker reads these numbers and picks the least loaded server for each request.
```

**What to look for:** `vllm:num_requests_waiting`, `vllm:num_requests_running` and `vllm:kv_cache_usage_perc`: the numbers the endpoint picker reads.

### 3. An InferencePool and its endpoint picker (the llm-d router chart, provider: istio)

llm-d's router chart creates the InferencePool, the endpoint picker (EPP) and Istio's settings for it.

```bash
helm install llm oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 -n llm --set router.modelServers.matchLabels.app=model-server --set provider.name=istio --set router.epp.resources.requests.cpu=100m --set router.epp.resources.requests.memory=128Mi --set router.epp.resources.limits.memory=1Gi --set router.epp.flags.v=4 --wait --timeout 5m >/dev/null && echo installed
kubectl -n llm get inferencepool
kubectl -n llm get deploy,svc
kubectl -n llm get inferencepool llm -o jsonpath='{.spec}' ; echo
```

Our output:

```text
$ helm install llm oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 -n llm --set router.modelServers.matchLabels.app=model-server --set provider.name=istio --set router.epp.resources.requests.cpu=100m --set router.epp.resources.requests.memory=128Mi --set router.epp.resources.limits.memory=1Gi --set router.epp.flags.v=4 --wait --timeout 5m >/dev/null && echo installed
installed
The chart sizes the picker for production (8 CPUs, 8 GiB). On a laptop we ask for 0.1 CPU and 128 MiB.
$ kubectl -n llm get inferencepool
NAME   AGE
llm    8s
$ kubectl -n llm get deploy,svc
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/llm-epp        1/1     1            1           8s
deployment.apps/model-server   3/3     3            3           26s
NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
service/llm-epp        ClusterIP   10.96.20.252   <none>        9002/TCP,9090/TCP   8s
service/model-server   ClusterIP   10.96.91.98    <none>        8000/TCP            25s
$ kubectl -n llm get inferencepool llm -o jsonpath='{.spec}' ; echo
{"appProtocol":"http","endpointPickerRef":{"failureMode":"FailOpen","group":"","kind":"Service","name":"llm-epp","port":{"number":9002}},"selector":{…
```

**What to look for:** `llm-epp` Ready, and a pool that selects `app: model-server` on port 8000 with `endpointPickerRef` → `llm-epp:9002`, `failureMode: FailOpen`. Without the resource settings the chart asks for 8 CPUs and 8 GiB, and the picker stays Pending on a laptop.

### 4. An Istio Gateway and an HTTPRoute whose backend is the InferencePool

Istio provides the Gateway; the route's backend is the InferencePool, not a Service.

```bash
cat <<'EOF' | kubectl -n llm apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: inference-gw}
spec:
  gatewayClassName: istio
  listeners: [{name: http, protocol: HTTP, port: 80}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: completions}
spec:
  parentRefs: [{name: inference-gw}]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1/completions}}]
    backendRefs: [{group: inference.networking.k8s.io, kind: InferencePool, name: llm}]
EOF
kubectl -n llm wait --for=condition=Programmed gateway/inference-gw --timeout=240s
kubectl -n llm get gateway inference-gw
kubectl -n llm get httproute completions -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
```

Our output:

```text
$ cat <<'EOF' | kubectl -n llm apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: inference-gw}
spec:
  gatewayClassName: istio
  listeners: [{name: http, protocol: HTTP, port: 80}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: completions}
spec:
  parentRefs: [{name: inference-gw}]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1/completions}}]
    backendRefs: [{group: inference.networking.k8s.io, kind: InferencePool, name: llm}]
EOF
$ kubectl -n llm wait --for=condition=Programmed gateway/inference-gw --timeout=240s
gateway.gateway.networking.k8s.io/inference-gw condition met
$ kubectl -n llm get gateway inference-gw
NAME           CLASS   ADDRESS          PROGRAMMED   AGE
inference-gw   istio   172.18.255.200   True         9s
$ kubectl -n llm get httproute completions -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
Accepted=True
ResolvedRefs=True
```

**What to look for:** an address from the pool, `Accepted=True` and `ResolvedRefs=True`.

### 5. A completion through the Gateway: the endpoint picker chose the server

Then read the picker's log: every scorer scores every server, and the highest total wins.

```bash
GW=$(kubectl -n llm get gateway inference-gw -o jsonpath='{.status.addresses[0].value}')
kubectl -n llm exec client -- curl -s http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"Write one line about Kubernetes networking.","max_tokens":20,"temperature":0}'; echo
kubectl -n llm logs deploy/llm-epp --tail=300 | grep '"Calculated score"' | tail -9 | jq -r '[.plugin, .endpoint.name, .score] | @tsv'
kubectl -n llm logs deploy/llm-epp --tail=300 | grep '"Request handled"' | tail -1 | jq -r '"chosen: " + .endpoint'
kubectl -n llm get pods -l app=model-server -o custom-columns=POD:.metadata.name,IP:.status.podIP
```

Our output:

```text
$ kubectl -n llm exec client -- curl -s http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"Write one line about Kubernetes networking.","max_tokens":20,"temperature":0}'; echo
{"id":"cmpl-c5b524bf-d67e-5b11-9b38-fe359d925af5","created":1795063021,"model":"reviews-1","usage":{"prompt_tokens":7,"completion_tokens":13,"total_t…
The picker's own log for that request: each scorer scores each server, then the highest total wins.
$ kubectl -n llm logs deploy/llm-epp --tail=300 | grep '"Calculated score"' | tail -9 | jq -r '[.plugin, .endpoint.name, .score] | @tsv'
queue-scorer/queue-scorer	model-server-7bd8c66ccc-298dq-rank-0	1
queue-scorer/queue-scorer	model-server-7bd8c66ccc-xzdqz-rank-0	1
queue-scorer/queue-scorer	model-server-7bd8c66ccc-pd4tm-rank-0	1
kv-cache-utilization-scorer/kv-cache-utilization-scorer	model-server-7bd8c66ccc-298dq-rank-0	1
kv-cache-utilization-scorer/kv-cache-utilization-scorer	model-server-7bd8c66ccc-xzdqz-rank-0	1
kv-cache-utilization-scorer/kv-cache-utilization-scorer	model-server-7bd8c66ccc-pd4tm-rank-0	1
prefix-cache-scorer/prefix-cache-scorer	model-server-7bd8c66ccc-298dq-rank-0	0
prefix-cache-scorer/prefix-cache-scorer	model-server-7bd8c66ccc-xzdqz-rank-0	0
prefix-cache-scorer/prefix-cache-scorer	model-server-7bd8c66ccc-pd4tm-rank-0	1
$ kubectl -n llm logs deploy/llm-epp --tail=300 | grep '"Request handled"' | tail -1 | jq -r '"chosen: " + .endpoint'
chosen: 10.0.0.120:8000
$ kubectl -n llm get pods -l app=model-server -o custom-columns=POD:.metadata.name,IP:.status.podIP
POD                             IP
model-server-7bd8c66ccc-298dq   10.0.1.134
model-server-7bd8c66ccc-pd4tm   10.0.0.120
model-server-7bd8c66ccc-xzdqz   10.0.0.93
```

**What to look for:** queue and KV-cache scores tied (all idle), a prefix-cache score of 1 for the server that has seen this prompt, and that server chosen.

### 6. How it fails: the picker is down. FailOpen or FailClose?

Stop the picker. Then ask for FailClose and check what the gateway actually did.

```bash
kubectl -n llm get inferencepool llm -o jsonpath='{.spec.endpointPickerRef.failureMode}'; echo
kubectl -n llm scale deploy/llm-epp --replicas=0
sleep 15
kubectl -n llm exec client -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 20 http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"hi","max_tokens":5}'
kubectl -n llm patch inferencepool llm --type merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailClose"}}}'
sleep 30
kubectl -n llm exec client -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 20 http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"hi","max_tokens":5}'
G=$(kubectl -n llm get pod -l gateway.networking.k8s.io/gateway-name=inference-gw -o name | head -1)
kubectl -n llm exec $G -- pilot-agent request GET config_dump 2>/dev/null | grep -m1 failure_mode_allow
kubectl -n llm patch inferencepool llm --type merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailOpen"}}}'
kubectl -n llm scale deploy/llm-epp --replicas=1
```

Our output:

```text
$ kubectl -n llm get inferencepool llm -o jsonpath='{.spec.endpointPickerRef.failureMode}'; echo
FailOpen
$ kubectl -n llm scale deploy/llm-epp --replicas=0
deployment.apps/llm-epp scaled
$ kubectl -n llm exec client -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 20 http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"hi","max_tokens":5}'
HTTP 200
FailOpen: with no picker, the gateway still serves the request, but picks a server the ordinary way.
$ kubectl -n llm patch inferencepool llm --type merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailClose"}}}'
inferencepool.inference.networking.k8s.io/llm patched
$ kubectl -n llm exec client -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 20 http://$GW/v1/completions -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"hi","max_tokens":5}'
HTTP 200
FailClose asks the gateway to refuse requests when the picker is gone. Did the gateway actually apply it? Ask its Envoy:
$ kubectl -n llm exec $G -- pilot-agent request GET config_dump 2>/dev/null | grep -m1 failure_mode_allow
               "failure_mode_allow": true,
The pool says FailClose; the gateway still allows. The InferencePool states the intent, the gateway enforces it: check the gateway.
$ kubectl -n llm scale deploy/llm-epp --replicas=1
deployment.apps/llm-epp scaled
```

**What to look for:** HTTP 200 with the picker gone (FailOpen). In our runs with Istio 1.30.8, still HTTP 200 after setting FailClose, and the gateway's Envoy still had `failure_mode_allow: true`: the pool states the intent, the gateway enforces it.

### 7. Check your work

Grade the cluster the way an exam task is graded. The check looks for the InferencePool, an Accepted route with resolved references, and a completion through the Gateway.

```bash
bash lab.sh check
```

Our output:

```text
PASS  an InferencePool selects the model servers in namespace llm
PASS  HTTPRoute completions is Accepted and ResolvedRefs
PASS  a completion through the Gateway returns text
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
