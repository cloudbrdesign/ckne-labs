#!/usr/bin/env bash
# Mock exam 2: 15 tasks across the five CKNE domains, on one cluster (Cilium with L2 announcements, Istio ambient, Gateway API).
#   bash lab.sh up      build the exam cluster (with its faults), then read TASKS.md and start your 2-hour timer
#   bash lab.sh check   grade your cluster: one PASS/FAIL per task
#   bash lab.sh step N  our reference solution for task N (only after you've tried it)
#   bash lab.sh run     build, apply every reference solution, then grade (what our walkthrough video replays)
LAB_ID=6.3; LAB_TITLE="Mock exam 2"; CLUSTER_PROFILE=full
CILIUM_EXTRA="--set l2announcements.enabled=true --set k8sClientRateLimit.qps=10 --set k8sClientRateLimit.burst=20"
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"; ANS="$DIR/answers"
AG=registry.k8s.io/e2e-test-images/agnhost:2.52
NS_IMG=nicolaka/netshoot:v0.13
CDNS=registry.k8s.io/coredns/coredns:v1.12.1
EXT=ckne-ext; DNS=ckne-dns
PORT=9137
lab_down(){ docker rm -f "$EXT" "$DNS" >/dev/null 2>&1; }
cip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
pre(){ docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2; }
deploy(){ k -n "$1" create deployment "$2" --image=$AG -- /agnhost netexec --http-port=8080 >/dev/null
  [ -n "${3:-}" ] && k -n "$1" patch deployment "$2" -p "{\"spec\":{\"template\":{\"spec\":{\"nodeName\":\"$3\"}}}}" >/dev/null; return 0; }
podx(){ local o="{\"spec\":{${4:+\"nodeName\":\"$4\"}${4:+${5:+,}}${5:+\"serviceAccountName\":\"$5\"}}}"
  k -n "$1" run "$2" --image="${6:-busybox:1.36.1}" --labels="app=$3" --overrides="$o" -- sleep 36000 >/dev/null; }
lab_setup(){
  mkdir -p "$ANS"; rm -f "$ANS"/*.txt
  docker pull -q $AG >/dev/null; docker pull -q $NS_IMG >/dev/null; docker pull -q $CDNS >/dev/null
  docker rm -f "$EXT" "$DNS" >/dev/null 2>&1
  docker run -d --name "$EXT" --network kind $NS_IMG sleep 36000 >/dev/null          # a machine outside the cluster
  local cf; cf=$(mktemp -d); printf 'corp.internal:53 {\n    hosts {\n        10.20.30.40 app.corp.internal\n    }\n}\n' > "$cf/Corefile"; chmod -R a+rX "$cf"
  docker run -d --name "$DNS" --network kind -v "$cf:/etc/coredns:ro" $CDNS -conf /etc/coredns/Corefile >/dev/null   # the company DNS server
  local p; p=$(pre)
  for n in net data shop out pay vault; do k create namespace $n >/dev/null; done
  # net: a caller that keeps calling mystery on an unusual port (task 2)
  k -n net run mystery --image=$AG --labels=app=mystery --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=$PORT >/dev/null
  # data: a StatefulSet whose Service is missing (task 3)
  k -n data apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: db}
spec:
  serviceName: db
  replicas: 2
  selector: {matchLabels: {app: db}}
  template:
    metadata: {labels: {app: db}}
    spec: {containers: [{name: db, image: $AG, args: [netexec, --http-port=5432]}]}
Y
  # shop: web, web-v2, api, edge (LoadBalancer), a Gateway, a client
  deploy shop web; deploy shop web-v2; deploy shop api ckne-worker2; deploy shop edge
  k -n shop expose deployment web --port=80 --target-port=8080 >/dev/null
  k -n shop expose deployment web-v2 --port=80 --target-port=8080 >/dev/null
  k -n shop expose deployment api --port=8080 >/dev/null
  k -n shop expose deployment edge --port=80 --target-port=8080 --type=LoadBalancer >/dev/null
  podx shop client client ckne-worker2 "" $NS_IMG   # same node as api (task 6)
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
Y
  # out: a fetcher that may only talk to the partner (task 11)
  podx out fetcher fetcher
  # pay: in the mesh already, PERMISSIVE; a caller outside the mesh (task 13)
  k label namespace pay istio.io/dataplane-mode=ambient >/dev/null
  deploy pay payments ckne-worker2; k -n pay expose deployment payments --port=8080 >/dev/null
  podx pay checkout checkout ckne-worker; podx shop legacy legacy ckne-worker
  # vault: a service to audit (task 15)
  deploy vault secrets ckne-worker2; k -n vault expose deployment secrets --port=8080 >/dev/null
  note "waiting for the exam workloads ..."
  local n; for n in shop pay vault; do k -n $n rollout status deploy --timeout=300s >/dev/null 2>&1 || k -n $n get pods; done
  k -n data rollout status sts/db --timeout=300s >/dev/null
  k wait --for=condition=Ready pod --all -A --timeout=300s >/dev/null 2>&1
  k -n net run caller --image=busybox:1.36.1 --labels=app=caller --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- \
    sh -c "while true; do wget -qO- -T 2 http://$(k -n net get pod mystery -o jsonpath='{.status.podIP}'):$PORT/hostname >/dev/null; sleep 2; done" >/dev/null
  note "The exam cluster is ready. Open TASKS.md, start a 2-hour timer, and write file answers in $ANS/."
}
gwip(){ k -n shop get gateway shop-gw -o jsonpath='{.status.addresses[0].value}'; }
can(){ k -n "$1" exec "$2" -- wget -qO- -T 3 "$3" >/dev/null 2>&1; }
retry(){ local i; for i in 1 2 3 4 5; do "$@" && return 0; sleep 4; done; return 1; }
apiveth(){ local p n idx; p=$(k -n shop get pod -l app=api -o jsonpath='{.items[0].metadata.name}'); n=$(k -n shop get pod "$p" -o jsonpath='{.spec.nodeName}')
  idx=$(k -n shop exec "$p" -- cat /sys/class/net/eth0/iflink | tr -d '\r'); docker exec "$n" ip -o link | awk -F': ' -v i="$idx" '$1==i{print $2}' | cut -d@ -f1; }
# ---------------------------------------------------------------- reference solutions (step N = task N)
step_1(){ title "Task 1 · The host-side interface of the api pod"
  runp "kubectl -n shop get pod -l app=api -o wide"
  local p; p=$(k -n shop get pod -l app=api -o jsonpath='{.items[0].metadata.name}')
  runp "kubectl -n shop exec $p -- cat /sys/class/net/eth0/iflink"
  runp "docker exec ckne-worker2 ip -o link | grep \"^\$(kubectl -n shop exec $p -- cat /sys/class/net/eth0/iflink | tr -d '\\r'):\" | cut -d: -f2 | cut -d@ -f1 | tr -d ' ' | tee $ANS/t1.txt"
}
step_2(){ title "Task 2 · The port caller uses to reach mystery, seen with tcpdump on ckne-worker2"
  runp "docker run --rm --net container:ckne-worker2 $NS_IMG timeout 8 tcpdump -nni any -c 3 'tcp[tcpflags] & tcp-syn != 0 and dst host $(k -n net get pod mystery -o jsonpath='{.status.podIP}')' 2>/dev/null"
  runp "echo $PORT | tee $ANS/t2.txt"
}
step_3(){ title "Task 3 · A headless Service so db-0.db.data resolves"
  run k -n data create service clusterip db --clusterip=None --tcp=5432:5432
  run k -n data set selector service db app=db
  sleep 3; runp "kubectl -n shop exec client -- nslookup -type=A db-0.db.data.svc.cluster.local | tail -2"
}
step_4(){ title "Task 4 · ExternalName Service shop/partner for partner.example.org"
  run k -n shop create service externalname partner --external-name=partner.example.org
  runp "kubectl -n shop exec client -- dig +short partner.shop.svc.cluster.local CNAME"
}
step_5(){ title "Task 5 · Forward corp.internal to the company DNS server"
  runp "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $DNS"
  k -n kube-system get cm coredns -o json | jq --arg ip "$(cip $DNS)" '.data.Corefile += "corp.internal:53 {\n    errors\n    cache 30\n    forward . \($ip)\n}\n"' | k replace -f - >/dev/null
  printf '%s$ kubectl -n kube-system edit cm coredns   %s# add a server block for corp.internal\n' "$Y" "$N"
  runp "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | tail -5"
  run k -n kube-system rollout restart deploy/coredns; k -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  local i; for i in $(seq 1 20); do c5 && break; sleep 3; done
  runp "kubectl -n shop exec client -- nslookup -type=A app.corp.internal. | tail -2"
}
step_6(){ title "Task 6 · Service shop/api: node-local traffic only for in-cluster clients"
  run k -n shop patch svc api -p '{"spec":{"internalTrafficPolicy":"Local"}}'
  runp "kubectl -n shop get svc api -o jsonpath='{.spec.internalTrafficPolicy}'; echo"
}
step_7(){ title "Task 7 · Header routing: x-version: v2 goes to web-v2"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: versions, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [versions.ckne.test]
  rules:
  - matches: [{headers: [{name: x-version, value: v2}]}]
    backendRefs: [{name: web-v2, port: 80}]
  - backendRefs: [{name: web, port: 80}]
Y
  printf '%s$ kubectl apply -f httproute-versions.yaml   %s# match header x-version: v2 -> web-v2; everything else -> web\n' "$Y" "$N"
  sleep 4
  runp "kubectl -n shop exec client -- curl -s -m 3 -H 'Host: versions.ckne.test' -H 'x-version: v2' http://$(gwip)/hostname; echo"
  runp "kubectl -n shop exec client -- curl -s -m 3 -H 'Host: versions.ckne.test' http://$(gwip)/hostname; echo"
}
step_8(){ title "Task 8 · Make shop/edge reachable from outside the cluster with L2 announcements"
  run k -n shop get svc edge
  runp "docker exec $EXT curl -s -m 3 http://$(k -n shop get svc edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/hostname || echo unreachable"
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: edge-l2}
spec:
  serviceSelector: {matchLabels: {app: edge}}
  nodeSelector: {matchExpressions: [{key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}]}
  interfaces: [^eth0$]
  loadBalancerIPs: true
Y
  printf '%s$ kubectl apply -f edge-l2.yaml   %s# serviceSelector app=edge; worker nodes; interface eth0; loadBalancerIPs: true\n' "$Y" "$N"
  local i; for i in $(seq 1 20); do c8 && break; sleep 3; done
  runp "docker exec $EXT curl -s -m 3 http://$(k -n shop get svc edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/hostname; echo"
}
step_9(){ title "Task 9 · Add the request header X-Env: prod on the way to web"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: env, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [env.ckne.test]
  rules:
  - filters: [{type: RequestHeaderModifier, requestHeaderModifier: {set: [{name: X-Env, value: prod}]}}]
    backendRefs: [{name: web, port: 80}]
Y
  printf '%s$ kubectl apply -f httproute-env.yaml   %s# RequestHeaderModifier: set X-Env: prod\n' "$Y" "$N"
  sleep 4
  runp "kubectl -n shop exec client -- curl -s -m 3 -H 'Host: env.ckne.test' 'http://$(gwip)/header?key=X-Env'; echo"
}
step_10(){ title "Task 10 · Only GET /public from client to api; everything else refused"
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-l7, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}], rules: {http: [{method: GET, path: "/public"}]}}]
Y
  printf '%s$ kubectl apply -f api-l7.yaml   %s# from app=client; port 8080; http: GET /public\n' "$Y" "$N"
  sleep 5
  runp "kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\\n' -m 3 http://api:8080/public"
  runp "kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\\n' -m 3 http://api:8080/hostname"
}
step_11(){ title "Task 11 · out/fetcher may reach only DNS and the partner machine"
  k apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: fetcher-egress, namespace: out}
spec:
  podSelector: {matchLabels: {app: fetcher}}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
  - to: [{ipBlock: {cidr: $(cip $EXT)/32}}]
Y
  printf '%s$ kubectl apply -f fetcher-egress.yaml   %s# egress: kube-dns on 53; ipBlock %s/32\n' "$Y" "$N" "$(cip $EXT)"
  sleep 3
  runp "kubectl -n out exec fetcher -- ping -c1 -W2 $(cip $EXT) | tail -2 | head -1"
  runp "kubectl -n out exec fetcher -- wget -qO- -T 2 http://web.shop/hostname 2>&1 | head -1"
}
step_12(){ title "Task 12 · Encrypt pod traffic between nodes with WireGuard"
  printf '%s$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard%s\n' "$Y" "$N"
  helm --kube-context "$CTX" upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --reuse-values \
    --set encryption.enabled=true --set encryption.type=wireguard --wait --timeout 8m >/dev/null
  run k -n kube-system rollout restart ds/cilium; k -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption"
  local i; for i in $(seq 1 30); do retry c7_ >/dev/null 2>&1 && break; sleep 4; done
}
step_13(){ title "Task 13 · pay accepts only mTLS"
  k apply -f - >/dev/null <<Y
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: pay}
spec: {mtls: {mode: STRICT}}
Y
  printf '%s$ kubectl apply -f strict.yaml   %s# PeerAuthentication default, namespace pay, mtls: STRICT\n' "$Y" "$N"
  sleep 6
  runp "for p in pay/checkout shop/legacy; do echo \"\$p \$(kubectl -n \${p%/*} exec \${p#*/} -- wget -qO- -T 3 http://payments.pay:8080/hostname >/dev/null 2>&1 && echo allowed || echo refused)\"; done"
}
step_14(){ title "Task 14 · Envoy access logs for the whole mesh"
  k apply -f - >/dev/null <<Y
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: {name: mesh-default, namespace: istio-system}
spec:
  accessLogging: [{providers: [{name: envoy}]}]
Y
  printf '%s$ kubectl apply -f telemetry.yaml   %s# namespace istio-system; accessLogging: providers envoy\n' "$Y" "$N"
  run k -n istio-system get telemetry
}
step_15(){ title "Task 15 · Put vault/secrets into policy audit mode"
  local p n cp ep; p=$(k -n vault get pod -l app=secrets -o jsonpath='{.items[0].metadata.name}'); n=$(k -n vault get pod "$p" -o jsonpath='{.spec.nodeName}')
  cp=$(k -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$n -o jsonpath='{.items[0].metadata.name}'); ep=$(k -n vault get cep "$p" -o jsonpath='{.status.id}')
  runp "kubectl -n vault get cep $p -o jsonpath='{.status.id}'; echo"
  run k -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint config "$ep" PolicyAuditMode=Enabled
  runp "kubectl -n kube-system exec $cp -c cilium-agent -- cilium-dbg endpoint get $ep -o jsonpath='{[*].spec.options.PolicyAuditMode}'; echo"
}
# ---------------------------------------------------------------- the grader
c3(){ local ip; ip=$(k -n data get pod db-0 -o jsonpath='{.status.podIP}'); k -n shop exec client -- nslookup -type=A db-0.db.data.svc.cluster.local 2>/dev/null | grep -q "Address: $ip"; }
c4(){ [ "$(k -n shop get svc partner -o jsonpath='{.spec.type}/{.spec.externalName}')" = ExternalName/partner.example.org ]; }
c5(){ k -n shop exec client -- nslookup -type=A app.corp.internal. 2>/dev/null | grep -q 'Address: 10.20.30.40'; }
c6(){ [ "$(k -n shop get svc api -o jsonpath='{.spec.internalTrafficPolicy}')" = Local ] && [ -n "$(k -n shop get svc api -o jsonpath='{.spec.selector.app}')" ]; }
c7_(){ local g; g=$(gwip); k -n shop exec client -- curl -sf -m 3 -H 'Host: versions.ckne.test' -H 'x-version: v2' "http://$g/hostname" | grep -q '^web-v2-' &&
       k -n shop exec client -- curl -sf -m 3 -H 'Host: versions.ckne.test' "http://$g/hostname" | grep -q '^web-[a-z0-9]*-[a-z0-9]*$'; }
c8(){ local ip; ip=$(k -n shop get svc edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); [ -n "$ip" ] && docker exec $EXT curl -sf -m 3 "http://$ip/hostname" | grep -q '^edge-'; }
c9_(){ [ "$(k -n shop exec client -- curl -sf -m 3 -H 'Host: env.ckne.test' "http://$(gwip)/header?key=X-Env")" = prod ]; }
c10(){ [ "$(k -n shop exec client -- curl -s -o /dev/null -w '%{http_code}' -m 3 http://api:8080/public)" = 200 ] && [ "$(k -n shop exec client -- curl -s -o /dev/null -w '%{http_code}' -m 3 http://api:8080/hostname)" = 403 ]; }
c11(){ k -n out exec fetcher -- ping -c1 -W2 "$(cip $EXT)" >/dev/null 2>&1 && ! can out fetcher http://web.shop/hostname && k -n out exec fetcher -- nslookup web.shop.svc.cluster.local >/dev/null 2>&1; }
c12(){ local p; for p in $(k -n kube-system get pod -l k8s-app=cilium -o name); do k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -q 'Encryption:.*Wireguard' || return 1; done; }
c13(){ can pay checkout http://payments.pay:8080/hostname && ! can shop legacy http://payments.pay:8080/hostname; }
c14(){ k -n istio-system get telemetry -o json | jq -e '[.items[].spec.accessLogging[]?.providers[]?.name] | index("envoy")' >/dev/null; }
c15(){ local p n cp ep; p=$(k -n vault get pod -l app=secrets -o jsonpath='{.items[0].metadata.name}'); n=$(k -n vault get pod "$p" -o jsonpath='{.spec.nodeName}')
       cp=$(k -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$n -o jsonpath='{.items[0].metadata.name}'); ep=$(k -n vault get cep "$p" -o jsonpath='{.status.id}')
       k -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint get "$ep" -o jsonpath='{[*].spec.options.PolicyAuditMode}' | grep -q Enabled; }
check_1(){ expect "Task 1 · host-side interface of the api pod in answers/t1.txt" sh -c "[ \"\$(cat '$ANS/t1.txt' 2>/dev/null | tr -d ' \n')\" = \"$(apiveth)\" ]"; }
check_2(){ expect "Task 2 · the port caller uses, in answers/t2.txt" sh -c "[ \"\$(cat '$ANS/t2.txt' 2>/dev/null | tr -d ' \n')\" = $PORT ]"; }
check_3(){ expect "Task 3 · db-0.db.data resolves to the db-0 pod" c3; }
check_4(){ expect "Task 4 · ExternalName shop/partner -> partner.example.org" c4; }
check_5(){ expect "Task 5 · app.corp.internal resolves through the company DNS" c5; }
check_6(){ expect "Task 6 · shop/api uses internalTrafficPolicy: Local" c6; }
check_7(){ expect "Task 7 · x-version: v2 goes to web-v2, the rest to web" retry c7_; }
check_8(){ expect "Task 8 · shop/edge answers from outside the cluster" retry c8; }
check_9(){ expect "Task 9 · requests via env.ckne.test carry X-Env: prod" retry c9_; }
check_10(){ expect "Task 10 · client: GET /public allowed, other paths 403" c10; }
check_11(){ expect "Task 11 · out/fetcher: DNS and the partner only" c11; }
check_12(){ expect "Task 12 · WireGuard encryption on every node" c12; }
check_13(){ expect "Task 13 · pay: mesh callers allowed, plain text refused" c13; }
check_14(){ expect "Task 14 · Envoy access logs enabled mesh-wide" c14; }
check_15(){ expect "Task 15 · vault/secrets is in policy audit mode" c15; }
lab_main "$@"
