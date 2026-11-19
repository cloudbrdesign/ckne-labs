#!/usr/bin/env bash
# Lab 3.4: Optimising LLM traffic with the Gateway API Inference Extension. Three simulated model servers (vLLM API),
# an InferencePool with llm-d's endpoint picker, and an Istio Gateway whose HTTPRoute sends completions to the pool.
LAB_ID=3.4; LAB_TITLE="Lab 3.4: Optimising LLM traffic: Gateway API Inference Extension"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
SIM=$LLMD_SIM_IMAGE
NS=llm
lab_setup(){
  note "installing the Inference Extension CRDs $GIE_VERSION and Istio $ISTIO_VERSION (istiod with the extension switched on) ..."
  k apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$GIE_VERSION/manifests.yaml" >/dev/null || echo "CRD install failed"
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1; helm repo update istio >/dev/null
  helm --kube-context "$CTX" upgrade --install istio-base istio/base -n istio-system --create-namespace --version "$ISTIO_VERSION" --wait >/dev/null
  helm --kube-context "$CTX" upgrade --install istiod istio/istiod -n istio-system --version "$ISTIO_VERSION" \
    --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true --wait >/dev/null || echo "istiod install failed"
  local p; p=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$p.255.200", stop: "$p.255.220"}]}
Y
  k create ns $NS >/dev/null
  k -n $NS apply -f - >/dev/null <<Y
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
        image: $SIM
        args: [--model, meta-llama/Llama-3.1-8B-Instruct, --port, "8000", --max-loras, "2", --lora-modules, '{"name":"reviews-1"}']
        ports: [{name: http, containerPort: 8000}]
        resources: {requests: {cpu: 20m}}
---
apiVersion: v1
kind: Service
metadata: {name: model-server}
spec: {selector: {app: model-server}, ports: [{port: 8000, targetPort: 8000}]}
Y
  k run client -n $NS --image=curlimages/curl:8.11.1 -- sleep 36000 >/dev/null
  k -n $NS rollout status deploy/model-server --timeout=240s >/dev/null; k -n $NS wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
complete(){ # $1 url
  k -n $NS exec client -- curl -s -m 20 "$1/v1/completions" -H 'Content-Type: application/json' \
    -d '{"model":"reviews-1","prompt":"Write one line about Kubernetes networking.","max_tokens":20,"temperature":0}'; }
epp(){ k -n $NS get deploy -o name | grep -v model-server | grep -m1 -E "epp|router|llm"; }
pool(){ k -n $NS get inferencepool -o jsonpath='{.items[0].metadata.name}'; }
gw(){ k -n $NS get gateway inference-gw -o jsonpath='{.status.addresses[0].value}'; }
step_1(){ title "Three model servers behind a plain Service: it works, but the Service knows nothing about LLM load"
  run k -n $NS get pods -l app=model-server -o wide
  runp "kubectl -n $NS exec client -- curl -s model-server:8000/v1/models"; echo
  printf '%s$ kubectl -n %s exec client -- curl -s model-server:8000/v1/completions -d %s%s\n' "$Y" "$NS" "'{\"model\":\"reviews-1\",...}'" "$N"
  complete http://model-server:8000; echo
}
step_2(){ title "What a smarter balancer would read: each server's queue and KV-cache metrics"
  local pod; pod=$(k -n $NS get pod -l app=model-server -o jsonpath='{.items[0].status.podIP}')
  runp "kubectl -n $NS exec client -- curl -s $pod:8000/metrics | grep -E '^vllm:(num_requests_waiting|num_requests_running|gpu_cache_usage_perc|kv_cache_usage_perc)'"
  note "A Service picks a pod at random. The endpoint picker reads these numbers and picks the least loaded server for each request."
}
step_3(){ title "An InferencePool and its endpoint picker (the llm-d router chart, provider: istio)"
  runp "helm install llm oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version $LLMD_ROUTER_VERSION -n $NS --set router.modelServers.matchLabels.app=model-server --set provider.name=istio --set router.epp.resources.requests.cpu=100m --set router.epp.resources.requests.memory=128Mi --set router.epp.resources.limits.memory=1Gi --set router.epp.flags.v=4 --wait --timeout 5m >/dev/null && echo installed"
  note "The chart sizes the picker for production (8 CPUs, 8 GiB). On a laptop we ask for 0.1 CPU and 128 MiB."
  run k -n $NS get inferencepool
  run k -n $NS get deploy,svc
  runp "kubectl -n $NS get inferencepool $(pool) -o jsonpath='{.spec}' ; echo"
}
step_4(){ title "An Istio Gateway and an HTTPRoute whose backend is the InferencePool"
  k -n $NS apply -f - >/dev/null <<Y
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
    backendRefs: [{group: inference.networking.k8s.io, kind: InferencePool, name: $(pool)}]
Y
  printf '%s$ kubectl -n %s apply -f gateway-and-route.yaml%s\n' "$Y" "$NS" "$N"
  run k -n $NS wait --for=condition=Programmed gateway/inference-gw --timeout=240s
  run k -n $NS get gateway inference-gw
  run k -n $NS get httproute completions -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
}
step_5(){ title "A completion through the Gateway: the endpoint picker chose the server"
  local a i; a=$(gw)
  for i in $(seq 1 20); do complete "http://$a" 2>/dev/null | grep -q text_completion && break; sleep 3; done
  printf '%s$ kubectl -n %s exec client -- curl -s http://%s/v1/completions -d %s%s\n' "$Y" "$NS" "$a" "'{\"model\":\"reviews-1\",...}'" "$N"
  complete "http://$a"; echo
  note "The picker's own log for that request: each scorer scores each server, then the highest total wins."
  runp "kubectl -n $NS logs $(epp) --tail=300 | grep '\"Calculated score\"' | tail -9 | jq -r '[.plugin, .endpoint.name, .score] | @tsv'"
  runp "kubectl -n $NS logs $(epp) --tail=300 | grep '\"Request handled\"' | tail -1 | jq -r '\"chosen: \" + .endpoint'"
  run k -n $NS get pods -l app=model-server -o custom-columns=POD:.metadata.name,IP:.status.podIP
}
try(){ k -n $NS exec client -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 20 "http://$(gw)/v1/completions" -H 'Content-Type: application/json' -d '{"model":"reviews-1","prompt":"hi","max_tokens":5}'; }
step_6(){ title "How it fails: the picker is down. FailOpen or FailClose?"
  local e p; e=$(epp); p=$(pool)
  runp "kubectl -n $NS get inferencepool $p -o jsonpath='{.spec.endpointPickerRef.failureMode}'; echo"
  run k -n $NS scale "$e" --replicas=0
  sleep 15
  printf '%s$ kubectl -n %s exec client -- curl ... http://%s/v1/completions%s\n' "$Y" "$NS" "$(gw)" "$N"; try
  note "FailOpen: with no picker, the gateway still serves the request, but picks a server the ordinary way."
  runp "kubectl -n $NS patch inferencepool $p --type merge -p '{\"spec\":{\"endpointPickerRef\":{\"failureMode\":\"FailClose\"}}}'"
  sleep 30
  printf '%s$ kubectl -n %s exec client -- curl ... http://%s/v1/completions%s\n' "$Y" "$NS" "$(gw)" "$N"; try
  note "FailClose asks the gateway to refuse requests when the picker is gone. Did the gateway actually apply it? Ask its Envoy:"
  local g; g=$(k -n $NS get pod -l gateway.networking.k8s.io/gateway-name=inference-gw -o name | head -1)
  runp "kubectl -n $NS exec $g -- pilot-agent request GET config_dump 2>/dev/null | grep -m1 failure_mode_allow"
  note "The pool says FailClose; the gateway still allows. The InferencePool states the intent, the gateway enforces it: check the gateway."
  k -n $NS patch inferencepool "$p" --type merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailOpen"}}}' >/dev/null
  run k -n $NS scale "$e" --replicas=1
  k -n $NS rollout status "$e" --timeout=180s >/dev/null
}
check_1(){ expect "an InferencePool selects the model servers in namespace $NS" sh -c "kubectl --context $CTX -n $NS get inferencepool -o jsonpath='{.items[0].spec.selector}' | grep -q model-server"; }
check_2(){ expect "HTTPRoute completions is Accepted and ResolvedRefs" sh -c "c=\$(kubectl --context $CTX -n $NS get httproute completions -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}'); echo \$c | grep -q 'Accepted=True' && echo \$c | grep -q 'ResolvedRefs=True'"; }
check_3(){ expect "a completion through the Gateway returns text" sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do kubectl --context $CTX -n $NS exec client -- curl -s -m 20 http://\$(kubectl --context $CTX -n $NS get gateway inference-gw -o jsonpath='{.status.addresses[0].value}')/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"reviews-1\",\"prompt\":\"hi\",\"max_tokens\":5}' | grep -q text_completion && exit 0; sleep 3; done; exit 1"; }
lab_main "$@"
