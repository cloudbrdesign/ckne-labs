#!/usr/bin/env bash
# Lab 5.3: Auditing traffic with logs. Hubble flow logs to a file, and policy audit mode: try a policy without dropping anything, read the log, then enforce.
LAB_ID=5.3; LAB_TITLE="Lab 5.3: Auditing traffic with logs: flow logs and policy audit mode"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
LOGF=/var/run/cilium/hubble/events.log
# This lab's Cilium: the Hubble exporter writes every flow (except kube-system's) as one JSON line to a file on each node
VALS=$(mktemp); cat > "$VALS" <<V
hubble:
  export:
    static:
      enabled: true
      filePath: $LOGF
      denyList: ['{"source_pod":["kube-system/"]}', '{"destination_pod":["kube-system/"]}']
V
CILIUM_EXTRA="-f $VALS"
lab_setup(){
  k create namespace shop >/dev/null
  k -n shop apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      nodeName: ckne-worker2
      containers: [{name: api, image: $AGNHOST, args: [netexec, --http-port=8080]}]
Y
  k -n shop expose deployment api --port=8080 >/dev/null
  local p; for p in web batch intruder; do
    k -n shop run $p --image=busybox:1.36.1 --labels=app=$p --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000 >/dev/null; done
  k -n shop rollout status deploy/api --timeout=300s >/dev/null || k -n shop get pods -o wide
  k -n shop wait --for=condition=Ready pod/web pod/batch pod/intruder --timeout=300s >/dev/null
}
CP(){ k -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=ckne-worker2 -o jsonpath='{.items[0].metadata.name}'; }
EP(){ k -n shop get cep -l app=api -o jsonpath='{.items[0].status.id}'; }
calls(){ local p; for p in web batch intruder; do
  printf '%-9s %s\n' "$p" "$(k -n shop exec $p -- wget -qO- -T 2 http://api:8080/hostname >/dev/null 2>&1 && echo ok || echo blocked)"; done; }
# the newest flow-log lines towards api: time, source, destination port, verdict, drop reason
flows(){ k -n kube-system exec "$(CP)" -c cilium-agent -- tail -n 400 $LOGF | jq -r --arg v "${1:-.}" '
  select(.flow.destination.pod_name // "" | startswith("api")) | select(.flow.l4.TCP.flags.SYN and (.flow.l4.TCP.flags.ACK | not))
  | select(.flow.verdict | test($v)) | "\(.flow.time[11:19])  \(.flow.source.namespace)/\(.flow.source.pod_name) -> api:\(.flow.l4.TCP.destination_port)  \(.flow.verdict)\(if .flow.drop_reason_desc then "  " + .flow.drop_reason_desc else "" end)"' | tail -n ${2:-6}; }
audit(){ k -n kube-system exec "$(CP)" -c cilium-agent -- cilium-dbg endpoint config "$(EP)" PolicyAuditMode=$1; }

step_1(){ title "Flow logs: every flow, written as JSON lines to a file on each node"
  run k -n shop get pods -o wide
  runp "kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}'; echo"
  calls >/dev/null; sleep 3
  printf '%s$ kubectl -n kube-system exec %s -c cilium-agent -- tail -n 1 %s | jq -c '"'"'.flow | {time, verdict, source: .source.pod_name, destination: .destination.pod_name, port: .l4.TCP.destination_port}'"'"'%s\n' "$Y" "$(CP)" "$LOGF" "$N"
  k -n kube-system exec "$(CP)" -c cilium-agent -- tail -n 200 $LOGF | jq -c 'select(.flow.destination.pod_name // "" | startswith("api")) | .flow | {time, verdict, source: .source.pod_name, destination: .destination.pod_name, port: .l4.TCP.destination_port}' | tail -n 1
  note "One JSON object per flow, on the node that saw it (here ckne-worker2, where api runs). A log shipper would collect this file."
  printf '%s$ flows   # our helper: the newest new connections to api, from the flow log%s\n' "$Y" "$N"; flows
}
step_2(){ title "Policy audit mode: apply a policy, but only log what it would drop"
  printf '%s$ kubectl -n kube-system exec %s -c cilium-agent -- cilium-dbg endpoint config %s PolicyAuditMode=Enabled%s\n' "$Y" "$(CP)" "$(EP)" "$N"; audit Enabled
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-allow-web, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: web}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
Y
  run k -n shop get cnp
  local i t0=$(date +%s); for i in $(seq 1 30); do calls >/dev/null; sleep 2; [ -n "$(flows AUDIT 1)" ] && break; done
  note "The lab re-tested quietly until the new policy was in place (AUDIT lines appeared): $(( $(date +%s) - t0 )) s."
  printf '%s$ for p in web batch intruder; do … wget http://api:8080/hostname …; done%s\n' "$Y" "$N"; calls; sleep 3
  printf '%s$ flows AUDIT%s\n' "$Y" "$N"; flows AUDIT 4
  runp "kubectl -n kube-system exec $(CP) -c cilium-agent -- hubble observe --type policy-verdict --to-namespace shop --last 4"
  note "Nothing was blocked. But the log says batch and intruder would have been: AUDIT, policy-verdict:none."
}
step_3(){ title "Read the audit: batch is a real client the policy forgot"
  note "Our story: batch is the nightly report job, it must keep working; intruder must not."
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-allow-web, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: web}}, {matchLabels: {app: batch}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
Y
  printf '%s$ kubectl apply -f api-allow-web.yaml   # fromEndpoints: app=web, app=batch%s\n' "$Y" "$N"
  sleep 3; calls >/dev/null; sleep 3
  printf '%s$ flows%s\n' "$Y" "$N"; flows . 4
  note "Only intruder would still be dropped. The policy is ready to enforce."
}
step_4(){ title "Enforce: turn audit mode off, and the log shows real drops"
  printf '%s$ kubectl -n kube-system exec %s -c cilium-agent -- cilium-dbg endpoint config %s PolicyAuditMode=Disabled%s\n' "$Y" "$(CP)" "$(EP)" "$N"; audit Disabled
  sleep 3
  printf '%s$ for p in web batch intruder; do … wget http://api:8080/hostname …; done%s\n' "$Y" "$N"; calls; sleep 3
  printf '%s$ flows DROPPED%s\n' "$Y" "$N"; flows DROPPED 2
}
check_1(){ expect "the flow log file on ckne-worker2 has flows to api" sh -c "kubectl --context $CTX -n kube-system exec $(CP) -c cilium-agent -- tail -n 2000 $LOGF | grep -q '\"pod_name\":\"api-'"; }
check_2(){ expect "the flow log recorded AUDIT verdicts" sh -c "kubectl --context $CTX -n kube-system exec $(CP) -c cilium-agent -- tail -n 2000 $LOGF | grep -q '\"verdict\":\"AUDIT\"'"; }
want3(){ [ "$(calls)" = "$(printf 'web       ok\nbatch     ok\nintruder  blocked')" ]; }
check_3(){ expect "web and batch reach api, intruder is blocked" want3; }
check_4(){ expect "the flow log shows intruder DROPPED with POLICY_DENIED" sh -c "kubectl --context $CTX -n kube-system exec $(CP) -c cilium-agent -- tail -n 2000 $LOGF | grep '\"pod_name\":\"intruder\"' | grep -q POLICY_DENIED"; }
lab_main "$@"
