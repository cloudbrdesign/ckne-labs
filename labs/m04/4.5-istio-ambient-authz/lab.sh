#!/usr/bin/env bash
# Lab 4.5: Pod-level authentication and authorisation with Istio ambient. ztunnel gives every pod an identity and mTLS,
# PeerAuthentication STRICT refuses plain text, and an AuthorizationPolicy decides which identity may call the service.
LAB_ID=4.5; LAB_TITLE="Lab 4.5: Pod-level authentication and authorisation: Istio ambient mTLS + AuthorizationPolicy"; CLUSTER_PROFILE=full
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
NETSHOOT=nicolaka/netshoot:v0.13
SECRET=acct-0042-balance
CLIENTS="bank/frontend bank/intruder legacy/oldapp"
applyy(){ local y; y=$(cat); printf '%s$ kubectl apply -f %s%s\n' "$Y" "$1" "$N"; printf '%s\n' "$y" | sed 's/^/    /'; printf '%s\n' "$y" | k apply -f - >/dev/null; }
client(){ # ns name serviceaccount
  k -n "$1" create serviceaccount "$3" >/dev/null 2>&1
  k -n "$1" run "$2" --image=busybox:1.36.1 --overrides="{\"spec\":{\"serviceAccountName\":\"$3\",\"nodeName\":\"ckne-worker\"}}" -- sleep 36000 >/dev/null; }
lab_setup(){
  k create ns bank >/dev/null; k create ns legacy >/dev/null
  k -n bank create serviceaccount ledger >/dev/null
  k apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: ledger, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  template:
    metadata: {labels: {app: ledger}}
    spec:
      serviceAccountName: ledger
      nodeName: ckne-worker2
      containers: [{name: ledger, image: $AGNHOST, args: [netexec, --http-port=8080]}]
Y
  k -n bank expose deployment ledger --port=8080 >/dev/null
  client bank frontend frontend; client bank intruder intruder; client legacy oldapp default
  k run tcpdump --image=$NETSHOOT --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 36000 >/dev/null
  k -n bank rollout status deploy/ledger --timeout=120s >/dev/null
  k -n bank wait --for=condition=Ready pod/frontend pod/intruder --timeout=120s >/dev/null
  k -n legacy wait --for=condition=Ready pod/oldapp --timeout=120s >/dev/null
  k wait --for=condition=Ready pod/tcpdump --timeout=180s >/dev/null
}
call(){ k -n "${1%/*}" exec "${1#*/}" -- wget -qO- -T 3 "http://ledger.bank:8080/echo?msg=$SECRET" 2>/dev/null; }
matrix(){ local c; printf '%-16s %s\n' CLIENT "-> ledger.bank:8080"
  for c in $CLIENTS; do printf '%-16s %s\n' "$c" "$(call "$c" >/dev/null && echo allowed || echo denied)"; done; }
CAP=$(mktemp)
capture(){ k exec tcpdump -- sh -c "timeout 8 tcpdump -ni any -A -s0 'tcp port 8080 or tcp port 15008' 2>/dev/null" > "$CAP" &
  sleep 2; local i; for i in 1 2 3; do call bank/frontend >/dev/null; sleep 0.5; done; wait; }
summary(){ printf 'packets to port 8080: %s   to port 15008 (HBONE): %s   lines containing "%s": %s\n' \
  "$(grep -c ' IP .*\.8080: ' "$CAP")" "$(grep -c ' IP .*\.15008: ' "$CAP")" "$SECRET" "$(grep -c "$SECRET" "$CAP")"; }
step_1(){ title "Before the mesh: everyone reaches ledger, in clear text"
  run k get pods -n bank -o wide
  matrix
  printf '%s$ kubectl exec tcpdump -- tcpdump -ni any -A "tcp port 8080 or tcp port 15008"   %s# on ckne-worker2, while frontend calls ledger\n' "$Y" "$N"
  capture; grep -m1 "$SECRET" "$CAP" | cut -c1-110; summary
}
step_2(){ title "Join the mesh: one namespace label, and ztunnel carries the traffic over mTLS"
  run k label namespace bank istio.io/dataplane-mode=ambient
  sleep 8
  printf '%s$ kubectl exec tcpdump -- tcpdump -ni any -A "tcp port 8080 or tcp port 15008"%s\n' "$Y" "$N"
  capture; grep -m2 ' IP .*\.15008: ' "$CAP" | cut -c1-110; summary
  local zt; zt=$(k -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=ckne-worker2 -o name)
  runp "kubectl -n istio-system logs $zt --since=2m | grep 'connection complete' | grep -o 'src.identity=\"[^\"]*\"\|dst.identity=\"[^\"]*\"' | sort -u"
  matrix
  note "Every pod in bank now has an identity (its service account) and talks over mTLS. The default is PERMISSIVE: plain text from outside the mesh still gets in."
}
step_3(){ title "PeerAuthentication STRICT: only mTLS is accepted in bank"
  applyy strict.yaml <<'Y'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: bank}
spec:
  mtls: {mode: STRICT}
Y
  sleep 5; matrix
  note "oldapp is outside the mesh: it can't present an identity, so ledger's ztunnel refuses it."
}
step_4(){ title "AuthorizationPolicy: only the frontend identity may call ledger"
  applyy ledger-allow-frontend.yaml <<'Y'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
Y
  sleep 5; matrix
  note "Same namespace, same network, but intruder runs as a different service account, so it's denied."
}
step_5(){ title "How it fails: an HTTP rule that ztunnel can't evaluate denies everyone"
  applyy ledger-allow-frontend.yaml <<'Y'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
    to:
    - operation: {methods: [GET]}
Y
  sleep 5; matrix
  note "methods is an L7 attribute. ztunnel works at L4, skips the rule, and an ALLOW policy with no matching rule denies. L7 rules need a waypoint."
  applyy ledger-allow-frontend.yaml <<'Y'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
Y
  sleep 5; matrix
}
check_1(){ expect "namespace bank is in the ambient mesh" sh -c "kubectl --context $CTX get ns bank -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' | grep -q ambient"; }
check_2(){ expect "frontend (sa frontend) reaches ledger" sh -c "kubectl --context $CTX -n bank exec frontend -- wget -qO- -T 3 http://ledger.bank:8080/hostname"; }
check_3(){ expect "intruder (sa intruder) is denied" sh -c "! kubectl --context $CTX -n bank exec intruder -- wget -qO- -T 3 http://ledger.bank:8080/hostname"; }
check_4(){ expect "oldapp (outside the mesh) is denied" sh -c "! kubectl --context $CTX -n legacy exec oldapp -- wget -qO- -T 3 http://ledger.bank:8080/hostname"; }
check_5(){ capture; expect "frontend's request is not visible in clear text on ckne-worker2" sh -c "grep -q '15008' '$CAP' && ! grep -q '$SECRET' '$CAP'"; }
lab_main "$@"
