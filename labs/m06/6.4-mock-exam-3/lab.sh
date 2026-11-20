#!/usr/bin/env bash
# Mock exam 3: 15 tasks across the five CKNE domains, on one cluster (Cilium, Istio ambient with waypoints, Gateway API, cert-manager).
#   bash lab.sh up      build the exam cluster (with its faults), then read TASKS.md and start your 2-hour timer
#   bash lab.sh check   grade your cluster: one PASS/FAIL per task
#   bash lab.sh step N  our reference solution for task N (only after you've tried it)
#   bash lab.sh run     build, apply every reference solution, then grade (what our walkthrough video replays)
LAB_ID=6.4; LAB_TITLE="Mock exam 3"; CLUSTER_PROFILE=full
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"; ANS="$DIR/answers"
AG=registry.k8s.io/e2e-test-images/agnhost:2.52
NS_IMG=nicolaka/netshoot:v0.13
BAD=ledger-db.corp.invalid
deploy(){ k -n "$1" create deployment "$2" --image=$AG -- /agnhost netexec --http-port=8080 >/dev/null
  [ -n "${3:-}" ] && k -n "$1" patch deployment "$2" -p "{\"spec\":{\"template\":{\"spec\":{\"nodeName\":\"$3\"}}}}" >/dev/null; return 0; }
podx(){ k -n "$1" run "$2" --image="${4:-busybox:1.36.1}" --labels="app=$3" -- sleep 36000 >/dev/null; }
pre(){ docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2; }
lab_setup(){
  mkdir -p "$ANS"; rm -f "$ANS"/*.txt
  docker pull -q $AG >/dev/null; docker pull -q $NS_IMG >/dev/null
  local p; p=$(pre)
  for n in net shop mesh bank ops certs; do k create namespace $n >/dev/null; done
  podx net probe probe $NS_IMG                                                       # tasks 1-2
  # shop: cart (Service points at the wrong port), web, a Gateway, a client
  deploy shop cart; k -n shop create service clusterip cart --tcp=80:9090 >/dev/null  # task 3: the pods listen on 8080
  deploy shop web; k -n shop expose deployment web --port=80 --target-port=8080 >/dev/null
  podx shop client client $NS_IMG
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: mock-pool}
spec: {blocks: [{start: "$p.255.200", stop: "$p.255.220"}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: shop-gw, namespace: shop}
spec:
  gatewayClassName: cilium
  listeners: [{name: http, port: 80, protocol: HTTP}]
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: ckne-selfsigned}
spec: {selfSigned: {}}
Y
  # mesh: in the ambient mesh, no waypoint yet (tasks 8, 9, 11)
  k label namespace mesh istio.io/dataplane-mode=ambient >/dev/null
  deploy mesh echo ckne-worker2; deploy mesh echo-v2 ckne-worker2
  k -n mesh expose deployment echo --port=8080 >/dev/null; k -n mesh expose deployment echo-v2 --port=8080 >/dev/null
  podx mesh client client $NS_IMG
  # bank: web and three callers (tasks 10, 12)
  deploy bank web; k -n bank expose deployment web --port=80 --target-port=8080 >/dev/null
  podx bank frontend frontend; podx bank attacker attacker
  # ops: DNS visibility for every pod, and a bot that keeps asking for a name that doesn't exist (task 14)
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: dns-visibility, namespace: ops}
spec:
  endpointSelector: {}
  egress:
  - toEndpoints: [{matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}}]
    toPorts: [{ports: [{port: "53", protocol: ANY}], rules: {dns: [{matchPattern: "*"}]}}]
Y
  k -n ops run bot --image=busybox:1.36.1 --labels=app=bot -- sh -c "while true; do nslookup $BAD. >/dev/null 2>&1; nslookup kubernetes.default.svc.cluster.local. >/dev/null 2>&1; sleep 3; done" >/dev/null
  note "waiting for the exam workloads ..."
  local n; for n in shop mesh bank; do k -n $n rollout status deploy --timeout=300s >/dev/null 2>&1 || k -n $n get pods; done
  k wait --for=condition=Ready pod --all -A --timeout=300s >/dev/null 2>&1
  note "The exam cluster is ready. Open TASKS.md, start a 2-hour timer, and write file answers in $ANS/."
}
gwip(){ k -n shop get gateway shop-gw -o jsonpath='{.status.addresses[0].value}'; }
ans(){ cat "$ANS/$1" 2>/dev/null | tr -d ' \n'; }
can(){ k -n "$1" exec "$2" -- wget -qO- -T 3 "$3" >/dev/null 2>&1; }
retry(){ local i; for i in 1 2 3 4 5; do "$@" && return 0; sleep 4; done; return 1; }
tunnel(){ local t; t=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.tunnel-protocol}'); echo "${t:-vxlan}"; }
waypoint_ready(){ k -n mesh get gateway waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null | grep -q True; }
# ---------------------------------------------------------------- reference solutions (step N = task N)
step_1(){ title "Task 1 · The encapsulation Cilium uses between nodes"
  runp "kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.routing-mode}{\" \"}{.data.tunnel-protocol}{\"\\n\"}'"
  runp "echo $(tunnel) | tee $ANS/t1.txt"
}
step_2(){ title "Task 2 · The MTU of eth0 in net/probe"
  runp "kubectl -n net exec probe -- ip link show eth0"
  runp "kubectl -n net exec probe -- cat /sys/class/net/eth0/mtu | tr -d '\\r' | tee $ANS/t2.txt"
}
step_3(){ title "Task 3 · Service shop/cart sends traffic to the wrong port"
  runp "kubectl -n shop get endpointslices -l kubernetes.io/service-name=cart"
  runp "kubectl -n shop get deploy cart -o jsonpath='{.spec.template.spec.containers[0].command}'; echo"
  run k -n shop patch svc cart --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
  runp "kubectl -n shop exec client -- curl -s -m 3 http://cart/hostname; echo"
}
step_4(){ title "Task 4 · Sticky sessions on shop/web"
  run k -n shop patch svc web -p '{"spec":{"sessionAffinity":"ClientIP"}}'
  runp "kubectl -n shop scale deploy web --replicas=3 >/dev/null; kubectl -n shop rollout status deploy web >/dev/null; for i in 1 2 3 4 5 6; do kubectl -n shop exec client -- curl -s -m 3 http://web/hostname; echo; done | sort | uniq -c"
}
step_5(){ title "Task 5 · A pod with its own DNS settings"
  k apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: resolver, namespace: net}
spec:
  dnsConfig:
    searches: [corp.internal]
    options: [{name: ndots, value: "2"}]
  containers: [{name: c, image: busybox:1.36.1, command: [sleep, "36000"]}]
Y
  printf '%s$ kubectl apply -f resolver.yaml   %s# dnsConfig: searches [corp.internal]; options ndots "2"\n' "$Y" "$N"
  k -n net wait --for=condition=Ready pod/resolver --timeout=120s >/dev/null
  runp "kubectl -n net exec resolver -- cat /etc/resolv.conf"
}
step_6(){ title "Task 6 · Redirect http://secure.ckne.test to HTTPS"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: secure-redirect, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [secure.ckne.test]
  rules:
  - filters: [{type: RequestRedirect, requestRedirect: {scheme: https, statusCode: 301}}]
Y
  printf '%s$ kubectl apply -f secure-redirect.yaml   %s# RequestRedirect: scheme https, statusCode 301\n' "$Y" "$N"
  sleep 4
  runp "kubectl -n shop exec client -- curl -s -o /dev/null -m 3 -w '%{http_code} %{redirect_url}\\n' -H 'Host: secure.ckne.test' http://$(gwip)/cart"
}
step_7(){ title "Task 7 · A response header from the Gateway"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: info, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [info.ckne.test]
  rules:
  - filters: [{type: ResponseHeaderModifier, responseHeaderModifier: {add: [{name: X-Served-By, value: ckne}]}}]
    backendRefs: [{name: web, port: 80}]
Y
  printf '%s$ kubectl apply -f info.yaml   %s# ResponseHeaderModifier: add X-Served-By: ckne\n' "$Y" "$N"
  sleep 4
  runp "kubectl -n shop exec client -- curl -s -m 3 -D - -o /dev/null -H 'Host: info.ckne.test' http://$(gwip)/hostname | grep -i -e '^HTTP' -e '^x-served-by'"
}
step_8(){ title "Task 8 · A waypoint for namespace mesh"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: waypoint, namespace: mesh, labels: {istio.io/waypoint-for: service}}
spec:
  gatewayClassName: istio-waypoint
  listeners: [{name: mesh, port: 15008, protocol: HBONE}]
Y
  printf '%s$ kubectl apply -f waypoint.yaml   %s# gatewayClassName istio-waypoint; listener mesh 15008 HBONE; waypoint-for: service\n' "$Y" "$N"
  run k label namespace mesh istio.io/use-waypoint=waypoint
  local i; for i in $(seq 1 60); do waypoint_ready && break; sleep 3; done
  run k -n mesh get gateway waypoint
}
step_9(){ title "Task 9 · In the mesh: x-user: tester goes to echo-v2"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo-testers, namespace: mesh}
spec:
  parentRefs: [{group: "", kind: Service, name: echo, port: 8080}]
  rules:
  - matches: [{headers: [{name: x-user, value: tester}]}]
    backendRefs: [{name: echo-v2, port: 8080}]
  - backendRefs: [{name: echo, port: 8080}]
Y
  printf '%s$ kubectl apply -f echo-testers.yaml   %s# parentRefs: the Service echo (not a Gateway); header x-user: tester -> echo-v2\n' "$Y" "$N"
  local i; for i in $(seq 1 20); do c9_ && break; sleep 3; done
  runp "kubectl -n mesh exec client -- curl -s -m 3 -H 'x-user: tester' http://echo:8080/hostname; echo"
  runp "kubectl -n mesh exec client -- curl -s -m 3 http://echo:8080/hostname; echo"
}
step_10(){ title "Task 10 · bank accepts traffic only from its own namespace"
  k apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: same-ns-only, namespace: bank}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {}}]}]
Y
  printf '%s$ kubectl apply -f same-ns-only.yaml   %s# podSelector {} ; ingress from podSelector {} (this namespace only)\n' "$Y" "$N"
  sleep 3
  runp "for p in bank/frontend shop/client; do echo \"\$p \$(kubectl -n \${p%/*} exec \${p#*/} -- wget -qO- -T 2 http://web.bank/hostname >/dev/null 2>&1 && echo allowed || echo blocked)\"; done"
}
step_11(){ title "Task 11 · In the mesh: echo accepts only GET"
  k apply -f - >/dev/null <<Y
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: echo-get-only, namespace: mesh}
spec:
  targetRefs: [{kind: Service, group: "", name: echo}]
  action: ALLOW
  rules: [{to: [{operation: {methods: [GET]}}]}]
Y
  printf '%s$ kubectl apply -f echo-get-only.yaml   %s# targetRefs: Service echo (enforced by the waypoint); ALLOW methods [GET]\n' "$Y" "$N"
  local i; for i in $(seq 1 20); do c11 && break; sleep 3; done
  runp "kubectl -n mesh exec client -- curl -s -m 3 -w ' %{http_code}\\n' 'http://echo:8080/echo?msg=hello'"
  runp "kubectl -n mesh exec client -- curl -s -m 3 -X POST -w ' %{http_code}\\n' 'http://echo:8080/echo?msg=hello'"
}
step_12(){ title "Task 12 · Block attacker inside bank, whatever else allows it"
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: deny-attacker, namespace: bank}
spec:
  endpointSelector: {matchLabels: {app: web}}
  ingressDeny: [{fromEndpoints: [{matchLabels: {app: attacker}}]}]
Y
  printf '%s$ kubectl apply -f deny-attacker.yaml   %s# endpointSelector app=web; ingressDeny fromEndpoints app=attacker\n' "$Y" "$N"
  sleep 3
  runp "for p in frontend attacker; do echo \"\$p \$(kubectl -n bank exec \$p -- wget -qO- -T 2 http://web/hostname >/dev/null 2>&1 && echo allowed || echo blocked)\"; done"
}
step_13(){ title "Task 13 · A 30-day certificate for api.ckne.test"
  k apply -f - >/dev/null <<Y
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: api-cert, namespace: certs}
spec:
  secretName: api-cert
  dnsNames: [api.ckne.test]
  duration: 720h
  renewBefore: 240h
  issuerRef: {name: ckne-selfsigned, kind: ClusterIssuer}
Y
  printf '%s$ kubectl apply -f api-cert.yaml   %s# secretName api-cert; dnsNames [api.ckne.test]; duration 720h; renewBefore 240h; ClusterIssuer ckne-selfsigned\n' "$Y" "$N"
  k -n certs wait --for=condition=Ready certificate/api-cert --timeout=120s >/dev/null
  runp "kubectl -n certs get certificate api-cert -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}  notBefore={.status.notBefore}  notAfter={.status.notAfter}  renewalTime={.status.renewalTime}{\"\\n\"}'"
}
step_14(){ title "Task 14 · The name ops/bot keeps failing to resolve"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server \$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80 --namespace ops --protocol dns --type l7 --last 40 | grep -e 'corp.invalid' | tail -3"
  runp "echo $BAD | tee $ANS/t14.txt"
}
step_15(){ title "Task 15 · Hubble metrics for DNS, drops and HTTP"
  printf '%s$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set hubble.metrics.enabled="{dns,drop,httpV2}"%s\n' "$Y" "$N"
  helm --kube-context "$CTX" upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --reuse-values \
    --set hubble.metrics.enabled="{dns,drop,httpV2}" --wait --timeout 8m >/dev/null
  run k -n kube-system rollout restart ds/cilium; k -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
  runp "kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-metrics}{\"\\n\"}'"
  local i; for i in $(seq 1 30); do c15 && break; sleep 4; done
  runp "for ip in \$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[0].address}'); do echo \"== \$ip:9965\"; kubectl -n net exec probe -- curl -s -m 3 http://\$ip:9965/metrics | grep -o '^hubble_[a-z_]*' | sort -u; done"
  note "Restarting the agents also restarts the Gateway's listeners: give it a minute before re-testing."
  for i in $(seq 1 30); do c6_ >/dev/null 2>&1 && break; sleep 4; done
}
# ---------------------------------------------------------------- the grader
c3(){ local o; o=$(k -n shop exec client -- curl -sf -m 3 http://cart/hostname); echo "$o" | grep -q '^cart-'; }
c4(){ [ "$(k -n shop get svc web -o jsonpath='{.spec.sessionAffinity}')" = ClientIP ]; }
c5(){ local r; r=$(k -n net exec resolver -- cat /etc/resolv.conf 2>/dev/null); echo "$r" | grep -q 'ndots:2' && echo "$r" | grep -q '^search.*corp\.internal'; }
c6_(){ local o; o=$(k -n shop exec client -- curl -s -o /dev/null -m 3 -w '%{http_code} %{redirect_url}' -H 'Host: secure.ckne.test' "http://$(gwip)/cart"); echo "$o" | grep -q '^301 https://secure\.ckne\.test\(:443\)\?/cart'; }
c7_(){ local h; h=$(k -n shop exec client -- curl -s -m 3 -D - -o /dev/null -H 'Host: info.ckne.test' "http://$(gwip)/hostname"); echo "$h" | grep -qi '^x-served-by: ckne'; }
c8(){ waypoint_ready && [ "$(k get ns mesh -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = waypoint ]; }
c9_(){ local a b; a=$(k -n mesh exec client -- curl -s -m 3 -H 'x-user: tester' http://echo:8080/hostname); b=$(k -n mesh exec client -- curl -s -m 3 http://echo:8080/hostname)
       echo "$a" | grep -q '^echo-v2-' && echo "$b" | grep -q '^echo-[a-z0-9]*-[a-z0-9]*$'; }
c10(){ can bank frontend http://web.bank/hostname && ! can shop client http://web.bank/hostname; }
c11(){ [ "$(k -n mesh exec client -- curl -s -o /dev/null -m 3 -w '%{http_code}' 'http://echo:8080/echo?msg=hi')" = 200 ] &&
       [ "$(k -n mesh exec client -- curl -s -o /dev/null -m 3 -X POST -w '%{http_code}' 'http://echo:8080/echo?msg=hi')" = 403 ]; }
c12(){ can bank frontend http://web/hostname && ! can bank attacker http://web/hostname; }
c13(){ local s a b r d e; s=$(k -n certs get certificate api-cert -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') || return 1; [ "$s" = True ] || return 1
       [ "$(k -n certs get certificate api-cert -o jsonpath='{.spec.dnsNames[0]}')" = api.ckne.test ] || return 1
       a=$(date -d "$(k -n certs get certificate api-cert -o jsonpath='{.status.notBefore}')" +%s); b=$(date -d "$(k -n certs get certificate api-cert -o jsonpath='{.status.notAfter}')" +%s)
       r=$(date -d "$(k -n certs get certificate api-cert -o jsonpath='{.status.renewalTime}')" +%s)
       d=$((b-a-2592000)); e=$((b-r-864000)); [ ${d#-} -le 300 ] && [ ${e#-} -le 300 ]; }
c15(){ local m; m=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-metrics}'); for w in dns drop httpV2; do echo "$m" | grep -qw "$w" || return 1; done
       local ip; for ip in $(k get nodes -o jsonpath='{.items[*].status.addresses[0].address}'); do
         local o; o=$(k -n net exec probe -- curl -s -m 3 "http://$ip:9965/metrics" 2>/dev/null); echo "$o" | grep -q '^hubble_dns_' && return 0; done; return 1; }   # (pipefail: read all output before grep -q)
check_1(){ expect "Task 1 · Cilium's tunnel protocol in answers/t1.txt" sh -c "[ \"\$(cat '$ANS/t1.txt' 2>/dev/null | tr -d ' \n')\" = $(tunnel) ]"; }
check_2(){ expect "Task 2 · MTU of net/probe's eth0 in answers/t2.txt" sh -c "[ \"\$(cat '$ANS/t2.txt' 2>/dev/null | tr -d ' \n')\" = \"$(k -n net exec probe -- cat /sys/class/net/eth0/mtu 2>/dev/null | tr -d '\r\n')\" ]"; }
check_3(){ expect "Task 3 · Service shop/cart reaches the cart pods" c3; }
check_4(){ expect "Task 4 · shop/web uses ClientIP session affinity" c4; }
check_5(){ expect "Task 5 · net/resolver: search corp.internal, ndots 2" c5; }
check_6(){ expect "Task 6 · http://secure.ckne.test redirects to https with 301" retry c6_; }
check_7(){ expect "Task 7 · info.ckne.test responses carry X-Served-By: ckne" retry c7_; }
check_8(){ expect "Task 8 · mesh has a ready waypoint and uses it" c8; }
check_9(){ expect "Task 9 · x-user: tester goes to echo-v2, the rest to echo" retry c9_; }
check_10(){ expect "Task 10 · bank: own namespace allowed, others blocked" c10; }
check_11(){ expect "Task 11 · echo: GET 200, POST 403" retry c11; }
check_12(){ expect "Task 12 · bank: attacker blocked, frontend allowed" c12; }
check_13(){ expect "Task 13 · api-cert: ready, 720h, renews 240h before expiry" c13; }
check_14(){ expect "Task 14 · the failing name in answers/t14.txt" sh -c "[ \"\$(cat '$ANS/t14.txt' 2>/dev/null | tr -d ' \n' | sed 's/\\.\$//')\" = $BAD ]"; }
check_15(){ expect "Task 15 · Hubble metrics dns, drop and httpV2 are served" c15; }
lab_main "$@"
