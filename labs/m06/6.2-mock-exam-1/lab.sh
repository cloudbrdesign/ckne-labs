#!/usr/bin/env bash
# Mock exam 1: 15 tasks across the five CKNE domains, on one cluster (Cilium, Istio ambient, cert-manager, Gateway API).
#   bash lab.sh up      build the exam cluster (with its faults), then read TASKS.md and start your 2-hour timer
#   bash lab.sh check   grade your cluster: one PASS/FAIL per task
#   bash lab.sh step N  our reference solution for task N (only after you've tried it)
#   bash lab.sh run     build, apply every reference solution, then grade (what our walkthrough video replays)
LAB_ID=6.2; LAB_TITLE="Mock exam 1"; CLUSTER_PROFILE=full
CILIUM_EXTRA="--set egressGateway.enabled=true --set bpf.masquerade=true"
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"; ANS="$DIR/answers"
AG=registry.k8s.io/e2e-test-images/agnhost:2.52
NS_IMG=nicolaka/netshoot:v0.13
EXT=ckne-ext
HOST=shop.ckne.test
lab_down(){ docker rm -f "$EXT" >/dev/null 2>&1; }
cip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
nip(){ k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
pre(){ docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2; }
deploy(){ # ns name [node]
  k -n "$1" create deployment "$2" --image=$AG -- /agnhost netexec --http-port=8080 >/dev/null
  [ -n "${3:-}" ] && k -n "$1" patch deployment "$2" -p "{\"spec\":{\"template\":{\"spec\":{\"nodeName\":\"$3\"}}}}" >/dev/null; return 0; }
podx(){ # ns name label [node] [sa] [image]
  local o="{\"spec\":{${4:+\"nodeName\":\"$4\"}${4:+${5:+,}}${5:+\"serviceAccountName\":\"$5\"}}}"
  k -n "$1" run "$2" --image="${6:-busybox:1.36.1}" --labels="app=$3" --overrides="$o" -- sleep 36000 >/dev/null; }
lab_setup(){
  mkdir -p "$ANS"; rm -f "$ANS"/*.txt
  docker pull -q $AG >/dev/null; docker rm -f "$EXT" >/dev/null 2>&1
  docker run -d --name "$EXT" --network kind $AG netexec --http-port=8080 >/dev/null
  local p; p=$(pre)
  for n in shop bank locked pay vault ops net; do k create namespace $n >/dev/null; done
  # shop: web (Service with a broken selector), web-v2, api, edge (LoadBalancer waiting for a pool), a gateway, clients
  deploy shop web; deploy shop web-v2; deploy shop api; deploy shop edge
  k -n shop create service clusterip web --tcp=80:8080 >/dev/null; k -n shop set selector service web app=wbe >/dev/null
  k -n shop expose deployment web-v2 --port=80 --target-port=8080 >/dev/null
  k -n shop expose deployment api --port=8080 >/dev/null
  k -n shop expose deployment edge --port=80 --target-port=8080 --type=LoadBalancer >/dev/null
  podx shop client client "" "" $NS_IMG; podx shop batch batch ckne-worker2
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: gateway-pool}
spec:
  blocks: [{start: "$p.255.200", stop: "$p.255.210"}]
  serviceSelector: {matchExpressions: [{key: io.cilium.gateway/owning-gateway, operator: Exists}]}
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
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: ckne-ca, namespace: cert-manager}
spec: {isCA: true, commonName: CKNE Mock CA, secretName: ckne-ca, privateKey: {algorithm: ECDSA, size: 256}, issuerRef: {name: ckne-selfsigned, kind: ClusterIssuer}}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: ckne-ca}
spec: {ca: {secretName: ckne-ca}}
Y
  # bank: ledger, frontend, intruder (task 10)
  deploy bank ledger ckne-worker2; k -n bank expose deployment ledger --port=8080 >/dev/null
  podx bank frontend frontend ckne-worker; podx bank intruder intruder ckne-worker
  # locked: an app behind an egress default deny that also blocks DNS (task 11)
  podx locked app app
  k -n locked apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-egress}
spec: {podSelector: {}, policyTypes: [Egress]}
Y
  # pay: payments and two callers with their own service accounts, not yet in the mesh (task 13)
  for s in payments checkout refund; do k -n pay create serviceaccount $s >/dev/null; done
  deploy pay payments ckne-worker2; k -n pay patch deployment payments -p '{"spec":{"template":{"spec":{"serviceAccountName":"payments"}}}}' >/dev/null
  k -n pay expose deployment payments --port=8080 >/dev/null
  podx pay checkout checkout ckne-worker checkout; podx pay refund refund ckne-worker refund
  # vault + ops: a guarded service and a pod that keeps knocking (task 14)
  deploy vault secrets ckne-worker2; k -n vault expose deployment secrets --port=8080 >/dev/null
  k -n vault apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: secrets-readers}
spec:
  endpointSelector: {matchLabels: {app: secrets}}
  ingress: [{fromEndpoints: [{matchLabels: {app: reader}}]}]
Y
  k -n ops run scanner --image=busybox:1.36.1 --labels=app=scanner -- sh -c 'while true; do wget -qO- -T 2 http://secrets.vault:8080/hostname; sleep 3; done' >/dev/null
  k -n ops run reporter --image=busybox:1.36.1 --labels=app=reporter -- sleep 36000 >/dev/null
  note "waiting for the exam workloads ..."
  local n; for n in shop bank pay vault; do k -n $n rollout status deploy --timeout=300s >/dev/null 2>&1 || k -n $n get pods; done
  k wait --for=condition=Ready pod --all -A --timeout=300s >/dev/null 2>&1
  k wait --for=condition=Ready certificate/ckne-ca -n cert-manager --timeout=180s >/dev/null
  k get secret ckne-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ANS/ckne-ca.crt"
  note "The exam cluster is ready. Open TASKS.md, start a 2-hour timer, and write file answers in $ANS/."
}
# ---------------------------------------------------------------- helpers for solutions and checks
gwip(){ k -n shop get gateway shop-gw -o jsonpath='{.status.addresses[0].value}'; }
ans(){ cat "$ANS/$1" 2>/dev/null | tr -d ' \n'; }
can(){ k -n "$1" exec "$2" -- wget -qO- -T 3 "$3" >/dev/null 2>&1; }       # ns pod url
cacert(){ k -n shop exec -i client -- sh -c 'cat > /tmp/ca.crt' < "$ANS/ckne-ca.crt"; }
# ---------------------------------------------------------------- reference solutions (step N = task N)
step_1(){ title "Task 1 · The pod CIDR Cilium allocated to ckne-worker2"
  runp "kubectl get ciliumnode ckne-worker2 -o jsonpath='{.spec.ipam.podCIDRs[0]}' | tee $ANS/t1.txt; echo"
}
step_2(){ title "Task 2 · The CNI configuration file on ckne-worker"
  runp "docker exec ckne-worker ls /etc/cni/net.d/"
  runp "docker exec ckne-worker ls /etc/cni/net.d/ | grep cilium | tee $ANS/t2.txt"
}
step_3(){ title "Task 3 · Service shop/web has no endpoints"
  run k -n shop get endpointslices -l kubernetes.io/service-name=web
  runp "kubectl -n shop get svc web -o jsonpath='{.spec.selector}'; echo"
  runp "kubectl -n shop get deploy web -o jsonpath='{.spec.template.metadata.labels}'; echo"
  run k -n shop set selector service web app=web
  sleep 3; runp "kubectl -n shop exec client -- curl -s -m 3 http://web/hostname; echo"
}
step_4(){ title "Task 4 · NodePort Service shop/api-np on port 30080"
  run k -n shop create service nodeport api-np --tcp=8080:8080 --node-port=30080
  run k -n shop set selector service api-np app=api
  run k -n shop get svc api-np
  sleep 3; runp "docker exec ckne-control-plane curl -s -m 3 http://$(nip ckne-worker):30080/hostname; echo"
}
step_5(){ title "Task 5 · legacy.corp.internal resolves to 10.10.10.10 for every pod"
  runp "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | head -3"
  k -n kube-system get cm coredns -o json | jq '.data.Corefile |= sub("\\.:53 \\{\n"; ".:53 {\n    hosts {\n        10.10.10.10 legacy.corp.internal\n        fallthrough\n    }\n")' | k replace -f - >/dev/null
  printf '%s$ kubectl -n kube-system edit cm coredns   %s# add a hosts block inside .:53 { … }\n' "$Y" "$N"
  runp "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | head -6"
  run k -n kube-system rollout restart deploy/coredns; k -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  local i; for i in $(seq 1 20); do c5 && break; sleep 3; done   # old CoreDNS pods can answer for a few seconds after the restart
  runp "kubectl -n shop exec client -- nslookup -type=A legacy.corp.internal. | tail -2"
}
step_6(){ title "Task 6 · HTTPRoute shop: /api to api, everything else to web"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: shop, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [$HOST]
  rules:
  - matches: [{path: {type: PathPrefix, value: /api}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: api, port: 8080}]
  - backendRefs: [{name: web, port: 80}]
Y
  printf '%s$ kubectl apply -f httproute-shop.yaml   %s# hostnames: [%s]; /api -> api:8080 with the /api prefix replaced by /; / -> web:80\n' "$Y" "$N" "$HOST"
  sleep 4; run k -n shop get httproute shop
  runp "kubectl -n shop exec client -- curl -s -m 3 -H 'Host: $HOST' http://$(gwip)/api/hostname; echo"
  runp "kubectl -n shop exec client -- curl -s -m 3 -H 'Host: $HOST' http://$(gwip)/hostname; echo"
}
step_7(){ title "Task 7 · Canary: 80% web, 20% web-v2 on canary.ckne.test"
  k apply -f - >/dev/null <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: canary, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [canary.ckne.test]
  rules: [{backendRefs: [{name: web, port: 80, weight: 80}, {name: web-v2, port: 80, weight: 20}]}]
Y
  printf '%s$ kubectl apply -f httproute-canary.yaml   %s# backendRefs: web weight 80, web-v2 weight 20\n' "$Y" "$N"
  sleep 4
  runp "kubectl -n shop exec client -- sh -c 'for i in \$(seq 1 50); do curl -s -m 3 -H \"Host: canary.ckne.test\" http://$(gwip)/hostname; echo; done' | sed 's/-[a-z0-9]*-[a-z0-9]*\$//' | sort | uniq -c"
}
step_8(){ title "Task 8 · LoadBalancer Service shop/edge gets an address from edge-pool"
  run k -n shop get svc edge
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: edge-pool}
spec:
  blocks: [{start: "$(pre).255.240", stop: "$(pre).255.250"}]
  serviceSelector: {matchLabels: {pool: edge}}
Y
  printf '%s$ kubectl apply -f edge-pool.yaml   %s# blocks: %s.255.240-250; serviceSelector: pool=edge\n' "$Y" "$N" "$(pre)"
  run k -n shop label service edge pool=edge
  sleep 5; run k -n shop get svc edge
}
step_9(){ title "Task 9 · shop/batch reaches ckne-ext through ckne-worker, with ckne-worker's address"
  runp "kubectl -n shop exec batch -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip; echo"
  run k label node ckne-worker egress-node=true
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata: {name: batch-egress}
spec:
  selectors: [{podSelector: {matchLabels: {app: batch, io.kubernetes.pod.namespace: shop}}}]
  destinationCIDRs: ["$(cip $EXT)/32"]
  egressGateway: {nodeSelector: {matchLabels: {egress-node: "true"}}, egressIP: "$(nip ckne-worker)"}
Y
  printf '%s$ kubectl apply -f batch-egress.yaml   %s# podSelector app=batch in shop; destination %s/32; gateway: egress-node=true, egressIP %s\n' "$Y" "$N" "$(cip $EXT)" "$(nip ckne-worker)"
  local i; for i in $(seq 1 20); do [ "$(k -n shop exec batch -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip 2>/dev/null | cut -d: -f1)" = "$(nip ckne-worker)" ] && break; sleep 2; done
  runp "kubectl -n shop exec batch -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip; echo"
}
step_10(){ title "Task 10 · Only frontend may reach bank/ledger on 8080"
  k apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ledger-ingress, namespace: bank}
spec:
  podSelector: {matchLabels: {app: ledger}}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {matchLabels: {app: frontend}}}], ports: [{protocol: TCP, port: 8080}]}]
Y
  printf '%s$ kubectl apply -f ledger-ingress.yaml   %s# podSelector app=ledger; from app=frontend; TCP 8080\n' "$Y" "$N"
  sleep 3
  runp "for p in frontend intruder; do echo \"\$p \$(kubectl -n bank exec \$p -- wget -qO- -T 2 http://ledger:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)\"; done"
}
step_11(){ title "Task 11 · locked/app can resolve names again, and nothing else"
  runp "kubectl -n locked exec app -- nslookup web.shop.svc.cluster.local 2>&1 | tail -1"
  k apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
Y
  printf '%s$ kubectl apply -f allow-dns.yaml   %s# egress to kube-system/kube-dns on 53 UDP and TCP\n' "$Y" "$N"
  sleep 3
  runp "kubectl -n locked exec app -- nslookup web.shop.svc.cluster.local 2>&1 | grep Address | tail -1"
  runp "kubectl -n locked exec app -- wget -qO- -T 2 http://web.shop/hostname 2>&1 | head -1"
}
step_12(){ title "Task 12 · HTTPS for shop.ckne.test on shop-gw, with a certificate from ckne-ca"
  k apply -f - >/dev/null <<Y
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: shop-tls, namespace: shop}
spec:
  secretName: shop-tls
  dnsNames: [$HOST]
  issuerRef: {name: ckne-ca, kind: ClusterIssuer}
Y
  printf '%s$ kubectl apply -f shop-tls.yaml   %s# Certificate: secretName shop-tls, dnsNames [%s], issuerRef ClusterIssuer ckne-ca\n' "$Y" "$N" "$HOST"
  k -n shop wait --for=condition=Ready certificate/shop-tls --timeout=120s >/dev/null
  run k -n shop patch gateway shop-gw --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/listeners/-\",\"value\":{\"name\":\"https\",\"port\":443,\"protocol\":\"HTTPS\",\"hostname\":\"$HOST\",\"tls\":{\"mode\":\"Terminate\",\"certificateRefs\":[{\"name\":\"shop-tls\"}]}}}]"
  sleep 6; cacert
  runp "kubectl -n shop exec client -- curl -s -m 3 --cacert /tmp/ca.crt --resolve $HOST:443:$(gwip) https://$HOST/hostname; echo"
}
step_13(){ title "Task 13 · pay in the ambient mesh; only checkout may call payments"
  run k label namespace pay istio.io/dataplane-mode=ambient
  k apply -f - >/dev/null <<Y
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: payments-allow-checkout, namespace: pay}
spec:
  selector: {matchLabels: {app: payments}}
  action: ALLOW
  rules: [{from: [{source: {principals: [cluster.local/ns/pay/sa/checkout]}}]}]
Y
  printf '%s$ kubectl apply -f payments-authz.yaml   %s# ALLOW principals cluster.local/ns/pay/sa/checkout\n' "$Y" "$N"
  sleep 8
  runp "for p in checkout refund; do echo \"\$p \$(kubectl -n pay exec \$p -- wget -qO- -T 3 http://payments:8080/hostname >/dev/null 2>&1 && echo allowed || echo denied)\"; done"
}
step_14(){ title "Task 14 · Who keeps being dropped on the way to vault/secrets?"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server \$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80 --verdict DROPPED --to-namespace vault --last 2"
  runp "echo ops/scanner | tee $ANS/t14.txt"
}
step_15(){ title "Task 15 · Hubble exporter: only DROPPED flows, to /var/run/cilium/hubble/drops.log"
  printf '%s$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set hubble.export.static.enabled=true --set hubble.export.static.filePath=/var/run/cilium/hubble/drops.log --set-json '"'"'hubble.export.static.allowList=["{\\"verdict\\":[\\"DROPPED\\"]}"]'"'"'%s\n' "$Y" "$N"
  helm --kube-context "$CTX" upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --reuse-values \
    --set hubble.export.static.enabled=true --set hubble.export.static.filePath=/var/run/cilium/hubble/drops.log \
    --set-json 'hubble.export.static.allowList=["{\"verdict\":[\"DROPPED\"]}"]' --wait --timeout 8m >/dev/null
  run k -n kube-system rollout restart ds/cilium; k -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
  runp "kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}{\"\\n\"}{.data.hubble-export-allowlist}{\"\\n\"}'"
  note "Restarting the agents also restarts what they program, such as the Gateway's Envoy listeners: give it a minute before re-testing."
  local i; for i in $(seq 1 30); do c6_ >/dev/null 2>&1 && break; sleep 4; done
}
# ---------------------------------------------------------------- the grader (check N = task N)
c3(){ k -n shop exec client -- curl -sf -m 3 http://web.shop/hostname | grep -q '^web-[a-z0-9]*-[a-z0-9]*$'; }
c4(){ [ "$(k -n shop get svc api-np -o jsonpath='{.spec.type}/{.spec.ports[0].nodePort}')" = NodePort/30080 ] && docker exec ckne-control-plane curl -sf -m 3 "http://$(nip ckne-worker):30080/hostname" | grep -q '^api-'; }
c5(){ k -n shop exec client -- nslookup legacy.corp.internal. 2>/dev/null | grep -q 'Address: 10.10.10.10'; }
retry(){ local i; for i in 1 2 3 4 5; do "$@" && return 0; sleep 4; done; return 1; }
c6(){ retry c6_; }
c7(){ retry c7_; }
c6_(){ local g; g=$(gwip); k -n shop exec client -- curl -sf -m 3 -H "Host: $HOST" "http://$g/api/hostname" | grep -q '^api-' &&
      k -n shop exec client -- curl -sf -m 3 -H "Host: $HOST" "http://$g/hostname" | grep -q '^web-[a-z0-9]*-[a-z0-9]*$'; }
c7_(){ local w; w=$(k -n shop get httproute canary -o jsonpath='{range .spec.rules[*].backendRefs[*]}{.name}={.weight} {end}')
      echo "$w" | grep -q 'web=80' && echo "$w" | grep -q 'web-v2=20' &&
      local out; out=$(k -n shop exec client -- sh -c "for i in \$(seq 1 40); do curl -s -m 3 -H 'Host: canary.ckne.test' http://$(gwip)/hostname; echo; done")
      echo "$out" | grep -q '^web-v2-' && echo "$out" | grep -q '^web-[a-z0-9]*-[a-z0-9]*$'; }   # (pipefail: read all output before grep -q)
c8(){ k -n shop get svc edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -qE "^$(pre | sed 's/\./\\./')\.255\.(24[0-9]|250)$"; }
c9(){ [ "$(k -n shop exec batch -- wget -qO- -T 3 "http://$(cip $EXT):8080/clientip" 2>/dev/null | cut -d: -f1)" = "$(nip ckne-worker)" ]; }
c10(){ can bank frontend http://ledger:8080/hostname && ! can bank intruder http://ledger:8080/hostname; }
c11(){ k -n locked exec app -- nslookup web.shop.svc.cluster.local >/dev/null 2>&1 && ! can locked app http://web.shop/hostname; }
c12(){ cacert; k -n shop exec client -- curl -sf -m 3 --cacert /tmp/ca.crt --resolve "$HOST:443:$(gwip)" "https://$HOST/hostname" | grep -q '^web-'; }
c13(){ k get ns pay -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' | grep -q ambient && can pay checkout http://payments:8080/hostname && ! can pay refund http://payments:8080/hostname; }
c15(){ local f a; f=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}'); a=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-allowlist}')
       [ "$f" = /var/run/cilium/hubble/drops.log ] && echo "$a" | grep -q DROPPED; }
check_1(){ expect "Task 1 · pod CIDR of ckne-worker2 in answers/t1.txt" sh -c "[ \"\$(cat '$ANS/t1.txt' 2>/dev/null | tr -d ' \n')\" = \"$(k get ciliumnode ckne-worker2 -o jsonpath='{.spec.ipam.podCIDRs[0]}')\" ]"; }
check_2(){ expect "Task 2 · CNI config file name in answers/t2.txt" sh -c "[ \"\$(cat '$ANS/t2.txt' 2>/dev/null | tr -d ' \n')\" = \"$(docker exec ckne-worker sh -c 'ls /etc/cni/net.d/ | grep cilium')\" ]"; }
check_3(){ expect "Task 3 · Service shop/web reaches the web pods" c3; }
check_4(){ expect "Task 4 · NodePort shop/api-np on 30080 answers" c4; }
check_5(){ expect "Task 5 · legacy.corp.internal resolves to 10.10.10.10" c5; }
check_6(){ expect "Task 6 · HTTPRoute shop: /api -> api, / -> web" c6; }
check_7(){ expect "Task 7 · canary.ckne.test splits 80/20 between web and web-v2" c7; }
check_8(){ expect "Task 8 · shop/edge has an address from edge-pool" c8; }
check_9(){ expect "Task 9 · shop/batch leaves through ckne-worker's address" c9; }
check_10(){ expect "Task 10 · bank/ledger: frontend allowed, intruder blocked" c10; }
check_11(){ expect "Task 11 · locked/app resolves names, other egress still blocked" c11; }
check_12(){ expect "Task 12 · HTTPS for $HOST with a ckne-ca certificate" c12; }
check_13(){ expect "Task 13 · pay in the mesh; checkout allowed, refund denied" c13; }
check_14(){ expect "Task 14 · the dropped caller in answers/t14.txt" sh -c "[ \"\$(cat '$ANS/t14.txt' 2>/dev/null | tr -d ' \n')\" = ops/scanner ]"; }
check_15(){ expect "Task 15 · Hubble exporter writes only DROPPED flows to drops.log" c15; }
lab_main "$@"
