#!/usr/bin/env bash
# Lab 2.7: Gateway API. One Gateway (Cilium's implementation), one HTTPRoute that routes by path and splits by weight.
LAB_ID=2.7; LAB_TITLE="Lab 2.7: Gateway API: Gateway and HTTPRoute"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
lab_setup(){
  local v; for v in v1 v2; do
    k create deployment echo-$v --image=$AGNHOST -- /agnhost netexec --http-port=8080 >/dev/null
    k expose deployment echo-$v --port=80 --target-port=8080 >/dev/null
  done
  # Gateways get a LoadBalancer address. Give Cilium a small pool from kind's Docker network to hand out (module 3 explains LB IPAM).
  local sub; sub=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  local pre; pre=$(echo "$sub" | cut -d. -f1-2)
  k apply -f - >/dev/null <<Y || echo "could not create the LB IP pool"
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$pre.255.200", stop: "$pre.255.220"}]}
Y
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k rollout status deploy/echo-v1 --timeout=120s >/dev/null; k rollout status deploy/echo-v2 --timeout=120s >/dev/null
  k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
gwaddr(){ k get gateway web -o jsonpath='{.status.addresses[0].value}'; }
hits(){ local a; a=$(gwaddr); k exec client -- sh -c "for i in \$(seq 1 20); do wget -qO- -T 2 http://$a$1; echo; done" | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c; }
step_1(){ title "The GatewayClass: Cilium registered itself as a Gateway API implementation"
  run k get gatewayclass
  run k get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
}
step_2(){ title "A Gateway: one HTTP listener on port 80 (the platform team's object)"
  k apply -f - >/dev/null <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: web}
spec:
  gatewayClassName: cilium
  listeners: [{name: http, protocol: HTTP, port: 80, allowedRoutes: {namespaces: {from: Same}}}]
Y
  printf '%s$ kubectl apply -f gateway.yaml%s\n' "$Y" "$N"
  run k wait --for=condition=Programmed gateway/web --timeout=180s
  run k get gateway web
  run k get svc -l io.cilium.gateway/owning-gateway=web
}
step_3(){ title "An HTTPRoute: /v1 and /v2 by path, and / split 80/20 (the app team's object)"
  k apply -f - >/dev/null <<'Y'
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
Y
  printf '%s$ kubectl apply -f httproute.yaml%s\n' "$Y" "$N"
  sleep 5
  runp "kubectl get httproute echo -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{\"\\n\"}'"
}
step_4(){ title "Route by path, through the Gateway's address"
  local a; a=$(gwaddr); echo "Gateway address: $a"
  run k exec client -- wget -qO- -T 3 "http://$a/v1/hostname"; echo
  run k exec client -- wget -qO- -T 3 "http://$a/v2/hostname"; echo
}
step_5(){ title "Weighted split on /: 20 requests"
  hits /hostname
}
check_1(){ expect "Gateway web is Programmed" sh -c "[ \"\$(kubectl --context $CTX get gateway web -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}')\" = True ]"; }
check_2(){ expect "HTTPRoute echo is Accepted by Gateway web" sh -c "[ \"\$(kubectl --context $CTX get httproute echo -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].status}')\" = True ]"; }
check_3(){ local a; a=$(gwaddr); expect "/v1 reaches an echo-v1 pod" sh -c "kubectl --context $CTX exec client -- wget -qO- -T 3 http://$a/v1/hostname | grep -q '^echo-v1-'"; }
check_4(){ local a; a=$(gwaddr); expect "/v2 reaches an echo-v2 pod" sh -c "kubectl --context $CTX exec client -- wget -qO- -T 3 http://$a/v2/hostname | grep -q '^echo-v2-'"; }
lab_main "$@"
