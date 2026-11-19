#!/usr/bin/env bash
# Lab 3.2: Egress gateway. Pods leave the cluster with their own node's address, which changes as pods move.
# A CiliumEgressGatewayPolicy sends one app's traffic to an outside server through one gateway node, with that node's IP.
LAB_ID=3.2; LAB_TITLE="Lab 3.2: Egress gateway for cluster exit traffic"; CLUSTER_PROFILE=cilium
CILIUM_EXTRA="--set egressGateway.enabled=true --set bpf.masquerade=true"
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
EXT=ckne-ext      # a server outside the cluster that reports the source address it sees (like a partner's firewall log)
lab_down(){ docker rm -f "$EXT" >/dev/null 2>&1; }
cip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
pod_on(){ # name node app
  k run "$1" --image=busybox:1.36.1 --labels="app=$3" --overrides="{\"spec\":{\"nodeName\":\"$2\"}}" -- sleep 36000 >/dev/null; }
seen(){ k exec "$1" -- wget -qO- -T 3 "http://$(cip $EXT):8080/clientip" 2>/dev/null | cut -d: -f1; }
lab_setup(){
  docker pull -q $AGNHOST >/dev/null
  docker run -d --name "$EXT" --network kind $AGNHOST netexec --http-port=8080 >/dev/null
  pod_on billing-1 ckne-worker billing; pod_on billing-2 ckne-worker2 billing; pod_on reports ckne-worker2 reports
  k wait --for=condition=Ready pod/billing-1 pod/billing-2 pod/reports --timeout=120s >/dev/null
}
table(){ local p; printf '%-10s %-14s %s\n' POD NODE "SOURCE SEEN BY $EXT"
  for p in billing-1 billing-2 reports; do printf '%-10s %-14s %s\n' "$p" "$(k get pod $p -o jsonpath='{.spec.nodeName}')" "$(seen $p)"; done; }
step_1(){ title "Who is calling? Today each pod leaves with its own node's address"
  run k get nodes -o custom-columns=NODE:.metadata.name,IP:.status.addresses[0].address
  note "$EXT is at $(cip $EXT), outside the cluster. It answers /clientip with the source address it sees."
  printf '%s$ kubectl exec <pod> -- wget -qO- http://%s:8080/clientip   %s# for each pod\n' "$Y" "$(cip $EXT)" "$N"
  table
  note "billing-1 and billing-2 are the same app, but the outside world sees two different addresses. Scale or reschedule, and it changes again."
}
step_2(){ title "Choose a gateway node: label it"
  run k label node ckne-worker egress-gateway=true
}
step_3(){ title "A CiliumEgressGatewayPolicy: billing's traffic to the server leaves through the gateway"
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata: {name: billing-egress}
spec:
  selectors:
  - podSelector: {matchLabels: {app: billing, io.kubernetes.pod.namespace: default}}
  destinationCIDRs: ["$(cip $EXT)/32"]
  egressGateway:
    nodeSelector: {matchLabels: {egress-gateway: "true"}}
    interface: eth0
Y
  printf '%s$ kubectl apply -f egress-policy.yaml   %s# pods app=billing -> %s/32 via the node labelled egress-gateway=true\n' "$Y" "$N" "$(cip $EXT)"
  local i; for i in $(seq 1 30); do [ "$(seen billing-2)" = "$(cip ckne-worker)" ] && break; sleep 2; done
  run k get ciliumegressgatewaypolicies
}
step_4(){ title "After: both billing pods leave with the gateway's address; reports is untouched"
  table
  note "billing-2 runs on ckne-worker2, yet the server sees ckne-worker ($(cip ckne-worker)): its traffic went through the gateway."
}
step_5(){ title "How it fails: no node matches the gateway selector"
  run k label node ckne-worker egress-gateway-
  sleep 5
  runp "kubectl exec billing-2 -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip || echo '(dropped)'"
  note "With no gateway, Cilium drops the matching traffic instead of letting it out with another address."
  run k label node ckne-worker egress-gateway=true
  local i; for i in $(seq 1 30); do [ "$(seen billing-2)" = "$(cip ckne-worker)" ] && break; sleep 2; done
  runp "kubectl exec billing-2 -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip; echo"
}
check_1(){ expect "CiliumEgressGatewayPolicy billing-egress exists" k get ciliumegressgatewaypolicy billing-egress; }
check_2(){ expect "billing-1 (on ckne-worker) reaches the server as the gateway node" sh -c "[ \"\$(kubectl --context $CTX exec billing-1 -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip | cut -d: -f1)\" = $(cip ckne-worker) ]"; }
check_3(){ expect "billing-2 (on ckne-worker2) reaches the server as the gateway node" sh -c "[ \"\$(kubectl --context $CTX exec billing-2 -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip | cut -d: -f1)\" = $(cip ckne-worker) ]"; }
check_4(){ expect "reports (not selected) still leaves as its own node" sh -c "[ \"\$(kubectl --context $CTX exec reports -- wget -qO- -T 3 http://$(cip $EXT):8080/clientip | cut -d: -f1)\" = $(cip ckne-worker2) ]"; }
lab_main "$@"
