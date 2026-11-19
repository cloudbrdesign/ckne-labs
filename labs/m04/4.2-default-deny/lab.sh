#!/usr/bin/env bash
# Lab 4.2: Default deny, egress and DNS. Lock a namespace down, see DNS break first, then open exactly what the app needs.
LAB_ID=4.2; LAB_TITLE="Lab 4.2: Default deny, egress and DNS: locking a namespace down"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
EXT=ckne-ext; EXT2=ckne-ext2   # two servers outside the cluster (think: a payment API and something else on the internet)
lab_down(){ docker rm -f "$EXT" "$EXT2" >/dev/null 2>&1; }
cip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
applyy(){ local y; y=$(cat); printf '%s$ kubectl apply -f %s%s\n' "$Y" "$1" "$N"; printf '%s\n' "$y" | sed 's/^/    /'; printf '%s\n' "$y" | k apply -f - >/dev/null; }
lab_setup(){
  docker pull -q $AGNHOST >/dev/null
  docker run -d --name "$EXT" --network kind $AGNHOST netexec --http-port=8080 >/dev/null
  docker run -d --name "$EXT2" --network kind $AGNHOST netexec --http-port=8080 >/dev/null
  k create ns shop >/dev/null; k create ns locked >/dev/null
  k -n shop create deployment web --image=$AGNHOST -- /agnhost netexec --http-port=8080 >/dev/null
  k -n shop expose deployment web --port=8080 >/dev/null
  k -n locked run app --image=busybox:1.36.1 --labels=app=app -- sleep 36000 >/dev/null
  k -n shop rollout status deploy/web --timeout=120s >/dev/null
  k -n locked wait --for=condition=Ready pod/app --timeout=120s >/dev/null
}
x(){ k -n locked exec app -- sh -c "$1" >/dev/null 2>&1 && echo ok || echo blocked; }
table(){ printf '%-36s %s\n' "FROM locked/app" RESULT
  printf '%-36s %s\n' "DNS: nslookup web.shop" "$(x 'timeout 4 nslookup web.shop.svc.cluster.local')"
  printf '%-36s %s\n' "web.shop:8080" "$(x 'wget -qO- -T 3 http://web.shop:8080/hostname')"
  printf '%-36s %s\n' "$EXT $(cip $EXT):8080 (outside)" "$(x "wget -qO- -T 3 http://$(cip $EXT):8080/hostname")"
  printf '%-36s %s\n' "$EXT2 $(cip $EXT2):8080 (outside)" "$(x "wget -qO- -T 3 http://$(cip $EXT2):8080/hostname")"; }
step_1(){ title "Before: the app can reach everything"
  run k get networkpolicy -A
  table
}
step_2(){ title "Default deny: one policy selects every pod in the namespace, both directions"
  applyy default-deny.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
Y
  sleep 3; table
  note "Egress deny blocks DNS too, so name lookups fail first. That's the most common surprise with default deny."
}
step_3(){ title "Allow DNS: egress to CoreDNS on port 53, UDP and TCP"
  applyy allow-dns.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
Y
  sleep 3; table
  note "Names resolve again, but the connections are still denied."
}
step_4(){ title "Allow the app to call web in namespace shop, on port 8080 only"
  applyy allow-web.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-web, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: shop}}
      podSelector: {matchLabels: {app: web}}
    ports: [{protocol: TCP, port: 8080}]
Y
  sleep 3; table
}
step_5(){ title "Allow one outside address with ipBlock; everything else outside stays blocked"
  applyy allow-ext.yaml <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-ext, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: $(cip $EXT)/32}}]
    ports: [{protocol: TCP, port: 8080}]
Y
  sleep 3; table
  run k -n locked get networkpolicy
}
check_1(){ expect "a default-deny policy selects every pod in locked (Ingress and Egress)" sh -c "kubectl --context $CTX -n locked get networkpolicy default-deny -o jsonpath='{.spec.policyTypes}' | grep -q Egress"; }
check_2(){ expect "DNS works from locked/app" sh -c "kubectl --context $CTX -n locked exec app -- timeout 4 nslookup web.shop.svc.cluster.local"; }
check_3(){ expect "locked/app reaches web.shop:8080" sh -c "kubectl --context $CTX -n locked exec app -- wget -qO- -T 3 http://web.shop:8080/hostname"; }
check_4(){ expect "locked/app reaches the allowed outside server" sh -c "kubectl --context $CTX -n locked exec app -- wget -qO- -T 3 http://$(cip $EXT):8080/hostname"; }
check_5(){ expect "locked/app cannot reach any other outside server" sh -c "! kubectl --context $CTX -n locked exec app -- wget -qO- -T 3 http://$(cip $EXT2):8080/hostname"; }
lab_main "$@"
