#!/usr/bin/env bash
# Lab 5.1: Network health from metrics. Hubble and Cilium metrics, scraped by Prometheus, read with PromQL, traced back to flows with hubble observe.
LAB_ID=5.1; LAB_TITLE="Lab 5.1: Network health from metrics: Hubble and Prometheus"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
MON_URL="https://raw.githubusercontent.com/cilium/cilium/v${CILIUM_VERSION}/examples/kubernetes/addons/prometheus/monitoring-example.yaml"
# This lab's Cilium: agent and operator metrics on, plus a set of Hubble metrics (what the docs' example enables)
VALS=$(mktemp); cat > "$VALS" <<V
prometheus: {enabled: true}
operator: {prometheus: {enabled: true}}
hubble:
  enabled: true
  relay: {enabled: true}
  metrics:
    enabled: [dns, drop, tcp, flow, port-distribution, icmp, "httpV2:labelsContext=source_workload,destination_workload"]
V
CILIUM_EXTRA="-f $VALS"
lab_setup(){
  k apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: server}
spec:
  selector: {matchLabels: {app: server}}
  template:
    metadata: {labels: {app: server}}
    spec:
      nodeName: ckne-worker2
      containers: [{name: server, image: $AGNHOST, args: [netexec, --http-port=8080]}]
Y
  k expose deployment server --port=8080 >/dev/null
  k run client --image=busybox:1.36.1 --labels=app=client --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000 >/dev/null
  k run intruder --image=busybox:1.36.1 --labels=app=intruder --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000 >/dev/null
  k rollout status deploy/server --timeout=300s >/dev/null || k get pods -o wide
  k wait --for=condition=Ready pod/client pod/intruder --timeout=300s >/dev/null || k get pods -o wide
}
W2IP(){ k get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
RELAY(){ echo "$(k -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80"; }
# PromQL against the Prometheus HTTP API, from inside the Prometheus pod; prints "labels  value" per series
promraw(){ k -n cilium-monitoring exec deploy/prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')"; }
prom(){ printf '%s$ promql: %s%s\n' "$Y" "$1" "$N"
  promraw "$1" | jq -r '.data.result[] | "  \(.metric | to_entries | map("\(.key)=\(.value)") | join(" ") | if .=="" then "(total)" else . end)   \(.value[1] | tonumber | . * 1000 | round / 1000)"'; }
has(){ local n; n=$(promraw "$1" 2>/dev/null | jq '.data.result | length' 2>/dev/null); [ "${n:-0}" -gt 0 ]; }
wait_for(){ local i; for i in $(seq 1 ${2:-40}); do has "$1" && return 0; sleep 3; done; return 1; }

step_1(){ title "Where the numbers come from: every Cilium agent serves metrics over HTTP"
  run k get pods -o wide
  note "Two kinds: Cilium's own health on port 9962 (cilium_*), and Hubble's view of your traffic on port 9965 (hubble_*)."
  runp "kubectl -n kube-system get svc hubble-metrics -o jsonpath='{.metadata.annotations}'; echo"
  runp "kubectl exec client -- wget -qO- http://$(W2IP):9965/metrics | grep '^hubble_flows_processed_total' | head -4"
  runp "kubectl exec client -- wget -qO- http://$(W2IP):9962/metrics | grep '^cilium_forward_count_total'"
  note "Each line is a counter: a name, labels in braces, and a number that only goes up."
}
step_2(){ title "Prometheus: pull every source every 10 seconds and keep the history"
  note "We use the example stack from Cilium's repository (Prometheus and Grafana; Grafana is scaled to 0 to save memory)."
  printf '%s$ kubectl apply -f %s%s\n' "$Y" "$MON_URL" "$N"
  k apply -f "$MON_URL" >/dev/null
  k -n cilium-monitoring scale deploy/grafana --replicas=0 >/dev/null
  k -n cilium-monitoring rollout status deploy/prometheus --timeout=240s >/dev/null
  run k -n cilium-monitoring get pods
  wait_for 'hubble_flows_processed_total' 60 || note "(Prometheus has no Hubble data yet)"
  prom 'count by (job) (up == 1)'
  note "kubernetes-pods: the agents and operator (pod annotations). kubernetes-endpoints: hubble-metrics (Service annotations)."
}
step_3(){ title "Turn on L7 visibility: DNS and HTTP metrics come from Cilium's proxies"
  note "Hubble only sees DNS names and HTTP status codes for traffic that passes a DNS or HTTP rule."
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: client-egress}
spec:
  endpointSelector: {matchLabels: {app: client}}
  egress:
  - toEndpoints: [{matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}}]
    toPorts: [{ports: [{port: "53", protocol: ANY}], rules: {dns: [{matchPattern: "*"}]}}]
  - toEndpoints: [{matchLabels: {app: server}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: server-ingress}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}], rules: {http: [{method: GET, path: "/echo.*"}]}}]
Y
  run k get cnp
  note "client-egress: DNS (seen by the DNS proxy) and port 8080 to server. server-ingress: only the client, only GET on /echo (the path is a regular expression that must match the whole path, query included, so /echo.*; seen by Envoy)."
  sleep 5
}
step_4(){ title "Make traffic: healthy, refused by L7, wrong names, and an intruder"
  local i ok=0 l7=0 nx=0 dr=0
  runp "kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=hello'; echo"
  for i in $(seq 1 20); do k exec client -- wget -qO- -T 3 "http://server:8080/echo?msg=$i" >/dev/null 2>&1 && ok=$((ok+1)); done
  runp "kubectl exec client -- wget -qO- -T 3 http://server:8080/hostname 2>&1 | head -1"
  for i in $(seq 1 10); do k exec client -- wget -qO- -T 3 http://server:8080/hostname >/dev/null 2>&1 || l7=$((l7+1)); done
  runp "kubectl exec client -- nslookup no-such-svc.default.svc.cluster.local. 2>&1 | grep -m1 NXDOMAIN"
  for i in $(seq 1 10); do k exec client -- nslookup no-such-svc.default.svc.cluster.local. >/dev/null 2>&1 || nx=$((nx+1)); done
  runp "kubectl exec intruder -- wget -qO- -T 2 http://server:8080/echo?msg=hi 2>&1 | head -1"
  for i in $(seq 1 5); do k exec intruder -- wget -qO- -T 2 "http://server:8080/echo?msg=$i" >/dev/null 2>&1 || dr=$((dr+1)); done
  note "sent: $ok good requests, $l7 refused paths, $nx lookups of a name that doesn't exist, $dr intruder attempts that timed out"
  note "waiting 30 s for Prometheus to scrape the new counts ..."; sleep 30
}
step_5(){ title "Read the health of the network from Prometheus"
  prom 'sum by (verdict) (hubble_flows_processed_total)'
  prom 'sum by (reason) (hubble_drop_total)'
  prom 'sum by (rcode) (hubble_dns_responses_total)'
  prom 'sum by (status) (hubble_http_requests_total)'
  prom 'sum by (status) (rate(hubble_http_requests_total[2m]))'
  prom 'histogram_quantile(0.95, sum by (le) (rate(hubble_http_request_duration_seconds_bucket[2m])))'
  note "Counters only go up, so we ask rate() for 'per second over the last 2 minutes' when we want the trend."
}
step_6(){ title "From a number to the flows behind it: hubble observe"
  note "A metric says how much. Hubble's flow log says who, to whom, and why. Hubble Relay gathers flows from every node."
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(RELAY) --verdict DROPPED --from-pod default/intruder --last 3"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(RELAY) --http-status 403 --last 3"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(RELAY) --type l7 --protocol dns --last 2"
}
check_1(){ expect "Prometheus has Hubble flow metrics" has 'hubble_flows_processed_total'; }
check_2(){ expect "Prometheus counts drops denied by policy" has 'sum(hubble_drop_total{reason=~".*POLICY.*"}) > 0'; }
check_3(){ expect "Prometheus counts DNS answers that aren't 'No Error'" has 'sum(hubble_dns_responses_total{rcode!~"No Error|NOERROR"}) > 0'; }
check_6(){ expect "the client's GET /echo still gets through (200)" sh -c "kubectl --context $CTX exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=ok' | grep -q ok"; }
check_4(){ expect "Prometheus counts HTTP 403s refused by the L7 rule" has 'sum(hubble_http_requests_total{status="403"}) > 0'; }
check_5(){ expect "hubble observe shows the intruder's dropped flows" sh -c "kubectl --context $CTX -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(RELAY) --verdict DROPPED --from-pod default/intruder --last 5 | grep -q DROPPED"; }
lab_main "$@"
