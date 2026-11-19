#!/usr/bin/env bash
# Lab 4.1: NetworkPolicy. How a policy selects pods, and how its from/to rules combine (AND inside one entry, OR between entries).
LAB_ID=4.1; LAB_TITLE="Lab 4.1: NetworkPolicy: how selectors and rules combine"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
CLIENTS="shop/web shop/api other/outsider other/monitor"
applyy(){ local y; y=$(cat); printf '%s$ kubectl apply -f %s%s\n' "$Y" "$1" "$N"; printf '%s\n' "$y" | sed 's/^/    /'; printf '%s\n' "$y" | k apply -f - >/dev/null; }
lab_setup(){
  k create ns shop >/dev/null; k create ns other >/dev/null
  k -n shop create deployment db --image=$AGNHOST -- /agnhost netexec --http-port=8080 >/dev/null
  k -n shop expose deployment db --port=8080 >/dev/null
  k -n shop run web --image=busybox:1.36.1 --labels=app=web -- sleep 36000 >/dev/null
  k -n shop run api --image=busybox:1.36.1 --labels=app=api -- sleep 36000 >/dev/null
  k -n other run outsider --image=busybox:1.36.1 -- sleep 36000 >/dev/null
  k -n other run monitor --image=busybox:1.36.1 --labels=role=monitor -- sleep 36000 >/dev/null
  k -n shop rollout status deploy/db --timeout=120s >/dev/null
  k -n shop wait --for=condition=Ready pod/web pod/api --timeout=120s >/dev/null
  k -n other wait --for=condition=Ready pod/outsider pod/monitor --timeout=120s >/dev/null
}
reach(){ k -n "${1%/*}" exec "${1#*/}" -- wget -qO- -T 2 http://db.shop:8080/hostname >/dev/null 2>&1; }
matrix(){ local c; printf '%-16s %s\n' CLIENT "-> db.shop:8080"
  for c in $CLIENTS; do printf '%-16s %s\n' "$c" "$(reach "$c" && echo allowed || echo blocked)"; done; }
step_1(){ title "No policy yet: every pod, in any namespace, reaches db"
  run k get networkpolicy -A
  run k get pods -n shop --show-labels
  run k get pods -n other --show-labels
  matrix
  note "Kubernetes allows all traffic until a policy selects a pod."
}
step_2(){ title "A policy that selects db and allows only api"
  applyy db-allow-api.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-api, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: api}}
    ports: [{protocol: TCP, port: 8080}]
Y
  sleep 3; matrix
  note "Once a policy selects db, only what some policy allows gets in. A podSelector alone in 'from' means: in the policy's own namespace."
}
step_3(){ title "Allow the monitor from another namespace: one entry, two selectors (AND)"
  applyy db-allow-monitor.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
Y
  sleep 3; matrix
  note "One list item holding both selectors: pods labelled role=monitor AND in namespace other. Policies add up: api is still allowed."
}
step_4(){ title "The two-dash mistake: two entries (OR) let the whole namespace in"
  applyy db-allow-monitor.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
    - podSelector: {matchLabels: {role: monitor}}
Y
  sleep 3; matrix
  note "Two list items: any pod in namespace other, OR pods labelled role=monitor in shop. outsider is now allowed."
}
step_5(){ title "Fix it back to AND, and read the policy the way the API sees it"
  applyy db-allow-monitor.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-allow-monitor, namespace: shop}
spec:
  podSelector: {matchLabels: {app: db}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: other}}
      podSelector: {matchLabels: {role: monitor}}
Y
  run k -n shop describe networkpolicy db-allow-monitor
  sleep 3; matrix
}
check_1(){ expect "api (shop) reaches db" reach shop/api; }
check_2(){ expect "web (shop) is blocked" sh -c "! kubectl --context $CTX -n shop exec web -- wget -qO- -T 2 http://db.shop:8080/hostname"; }
check_3(){ expect "monitor (other, role=monitor) reaches db" reach other/monitor; }
check_4(){ expect "outsider (other, no label) is blocked" sh -c "! kubectl --context $CTX -n other exec outsider -- wget -qO- -T 2 http://db.shop:8080/hostname"; }
lab_main "$@"
