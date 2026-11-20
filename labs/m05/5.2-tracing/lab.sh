#!/usr/bin/env bash
# Lab 5.2: End-to-end performance with tracing. Istio ambient + waypoint send spans to Jaeger; find the slow hop in one request.
LAB_ID=5.2; LAB_TITLE="Lab 5.2: End-to-end performance with tracing"; CLUSTER_PROFILE=full
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
NETSHOOT=nicolaka/netshoot:v0.13
SAMPLES="https://raw.githubusercontent.com/istio/istio/$ISTIO_VERSION/samples"
# istiod: one tracing provider, Jaeger's OpenTelemetry (OTLP gRPC) collector
VALS=$(mktemp); cat > "$VALS" <<V
meshConfig:
  enableTracing: true
  extensionProviders:
  - name: jaeger
    opentelemetry: {port: 4317, service: jaeger-collector.istio-system.svc.cluster.local}
V
ISTIOD_EXTRA="-f $VALS"
lab_setup(){
  k apply -f "$SAMPLES/addons/jaeger.yaml" >/dev/null
  k create namespace bookinfo >/dev/null
  k label namespace bookinfo istio.io/dataplane-mode=ambient >/dev/null
  k -n bookinfo apply -f "$SAMPLES/bookinfo/platform/kube/bookinfo.yaml" >/dev/null
  k -n bookinfo delete deployment reviews-v1 reviews-v3 >/dev/null      # keep one path: productpage -> reviews-v2 -> ratings
  k -n bookinfo wait --for=delete pod -l app=reviews,version!=v2 --timeout=120s >/dev/null 2>&1
  k -n bookinfo run client --image=$NETSHOOT -- sleep 36000 >/dev/null
  k -n istio-system rollout status deploy/jaeger --timeout=300s >/dev/null || k -n istio-system get pods
  k -n bookinfo wait --for=condition=Available deploy --all --timeout=600s >/dev/null || k -n bookinfo get pods
  k -n bookinfo wait --for=condition=Ready pod/client --timeout=300s >/dev/null
}
B(){ k -n bookinfo "$@"; }
page(){ B exec client -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://productpage:9080/productpage; }
J="http://tracing.istio-system/jaeger/api"
jq_spans='.data[0] as $t | ($t.spans | min_by(.startTime).startTime) as $t0 | "trace \($t.traceID[0:16])…  \($t.spans | length) spans",
  ($t.spans | sort_by(.startTime)[] | "  +\(((.startTime - $t0) / 1000) | floor | tostring | .[0:6]) ms  \((.duration / 1000) | floor) ms  \($t.processes[.processID].serviceName)  \(.operationName)")'
svc(){ B exec client -- curl -s "$J/services" | jq -r '.data[]' | grep -v '^jaeger' | grep -m1 -E 'productpage|waypoint'; }
latest(){ B exec client -- curl -s "$J/traces?service=$(svc)&limit=1&lookback=2m"; }
waypoint_ready(){ B get gateway waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' | grep -q True; }

step_1(){ title "Bookinfo in the ambient mesh: the page works, but nothing is traced"
  run k -n bookinfo get pods
  runp "kubectl -n bookinfo exec client -- curl -s http://productpage:9080/productpage | grep -o '<title>.*</title>'"
  printf '%s$ kubectl -n bookinfo exec client -- curl -s -o /dev/null -w "%%{http_code} %%{time_total}s\\n" http://productpage:9080/productpage%s\n' "$Y" "$N"; page
  runp "kubectl -n bookinfo exec client -- curl -s $J/services | jq -c .data"
  note "ztunnel is L4: it can't see HTTP requests, so it can't make spans. Tracing in ambient needs a waypoint."
}
step_2(){ title "Add a waypoint and turn on tracing for the whole mesh"
  k apply -f - >/dev/null <<Y
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
Y
  run k label namespace bookinfo istio.io/use-waypoint=waypoint
  local i; for i in $(seq 1 60); do waypoint_ready && break; sleep 3; done
  B rollout status deploy/waypoint --timeout=180s >/dev/null 2>&1
  run k -n bookinfo get gateway waypoint
  run k -n istio-system get telemetry
  sleep 5; for i in 1 2 3 4 5; do page >/dev/null; done; sleep 10
  runp "kubectl -n bookinfo exec client -- curl -s $J/services | jq -c .data"
}
step_3(){ title "One request, one trace: a span for every hop through the waypoint"
  printf '%s$ kubectl -n bookinfo exec client -- curl … /productpage%s\n' "$Y" "$N"; page; sleep 8
  printf '%s$ curl -s "%s/traces?service=%s&limit=1&lookback=2m" | jq …%s\n' "$Y" "$J" "$(svc)" "$N"
  latest | jq -r "$jq_spans"
  note "+ms: when the span started, after the first one. Then its duration, the service and the operation (host:port/path)."
}
step_4(){ title "Make ratings slow: a 2-second delay injected at the waypoint"
  k apply -f - >/dev/null <<Y
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: ratings-delay, namespace: bookinfo}
spec:
  hosts: [ratings]
  http:
  - fault: {delay: {percentage: {value: 100}, fixedDelay: 2s}}
    route: [{destination: {host: ratings}}]
Y
  run k -n bookinfo get virtualservice
  sleep 5
  printf '%s$ kubectl -n bookinfo exec client -- curl … /productpage%s\n' "$Y" "$N"; page; sleep 8
  printf '%s$ curl -s "%s/traces?service=%s&limit=1&lookback=2m" | jq …%s\n' "$Y" "$J" "$(svc)" "$N"
  latest | jq -r "$jq_spans"
  note "The whole request got slower. The trace shows where: every span on the path to ratings grew by about 2 s."
}
step_5(){ title "Remove the fault: the request is fast again"
  run k -n bookinfo delete virtualservice ratings-delay
  sleep 5
  printf '%s$ kubectl -n bookinfo exec client -- curl … /productpage%s\n' "$Y" "$N"; page
}
check_1(){ expect "productpage answers 200 through the mesh" sh -c "kubectl --context $CTX -n bookinfo exec client -- curl -s -o /dev/null -w '%{http_code}' http://productpage:9080/productpage | grep -q 200"; }
check_2(){ expect "the bookinfo waypoint is Programmed" waypoint_ready; }
check_3(){ page >/dev/null; sleep 8
  expect "Jaeger has a trace with 4 or more spans" sh -c "[ \$(kubectl --context $CTX -n bookinfo exec client -- curl -s '$J/traces?service=$(svc)&limit=1&lookback=2m' | jq '.data[0].spans | length') -ge 4 ]"; }
check_4(){ expect "a span mentions ratings" sh -c "kubectl --context $CTX -n bookinfo exec client -- curl -s '$J/traces?service=$(svc)&limit=1&lookback=2m' | jq -r '.data[0].spans[].operationName' | grep -q ratings"; }
lab_main "$@"
