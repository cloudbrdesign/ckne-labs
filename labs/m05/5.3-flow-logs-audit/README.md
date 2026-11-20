# Lab 5.3: Auditing traffic with logs: flow logs and policy audit mode

Lab for the course lesson **5.3 Auditing traffic with logs: flow logs and policy audit mode**. It creates a fresh kind cluster named `ckne` with Cilium, with the Hubble exporter writing flows to `/var/run/cilium/hubble/events.log` on every node (kube-system left out). The lab adds a `shop` namespace with an `api` service on ckne-worker2 and three clients on ckne-worker: `web`, `batch` and `intruder`, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m05/5.3-flow-logs-audit
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Flow logs: every flow, written as JSON lines to a file on each node
2. Policy audit mode: apply a policy, but only log what it would drop
3. Read the audit: batch is a real client the policy forgot
4. Enforce: turn audit mode off, and the log shows real drops

## What the check looks for

- the flow log file on ckne-worker2 has flows to api
- the flow log recorded AUDIT verdicts
- web and batch reach api, intruder is blocked
- the flow log shows intruder DROPPED with POLICY_DENIED

## Tested

20 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (205 s for `bash lab.sh run`).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 131, Ubuntu 24.04); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It has no kube-proxy and no default network plugin; Cilium is installed as the network plugin and replaces kube-proxy.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: true, kubeProxyMode: none}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm repo add cilium https://helm.cilium.io && helm repo update cilium
helm upgrade --install cilium cilium/cilium --version 1.20.5 -n kube-system \
  --set kubeProxyReplacement=true --set k8sServiceHost=ckne-control-plane --set k8sServicePort=6443 \
  --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true --set hubble.relay.enabled=true \
  --set gatewayAPI.enabled=true \
  --set hubble.export.static.enabled=true --set hubble.export.static.filePath=/var/run/cilium/hubble/events.log \
  --set 'hubble.export.static.denyList[0]={"source_pod":["kube-system/"]}' --set 'hubble.export.static.denyList[1]={"destination_pod":["kube-system/"]}' --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

The shop namespace: api on ckne-worker2, three clients on ckne-worker; then the helpers used below.

```bash
kubectl create namespace shop
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: shop}
spec:
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      nodeName: ckne-worker2
      containers: [{name: api, image: registry.k8s.io/e2e-test-images/agnhost:2.52, args: [netexec, --http-port=8080]}]
EOF
kubectl -n shop expose deployment api --port=8080
for p in web batch intruder; do kubectl -n shop run $p --image=busybox:1.36.1 --labels=app=$p --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000; done
kubectl -n shop rollout status deploy/api --timeout=300s
kubectl -n shop wait --for=condition=Ready pod/web pod/batch pod/intruder --timeout=300s
# helpers: the Cilium pod on api's node, api's endpoint ID, a test from each client, and the newest new connections to api in the flow log
CP=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=ckne-worker2 -o jsonpath='{.items[0].metadata.name}')
EP=$(kubectl -n shop get cep -l app=api -o jsonpath='{.items[0].status.id}')
calls(){ for p in web batch intruder; do printf '%-9s %s\n' $p $(kubectl -n shop exec $p -- wget -qO- -T 2 http://api:8080/hostname >/dev/null 2>&1 && echo ok || echo blocked); done; }
flows(){ kubectl -n kube-system exec $CP -c cilium-agent -- tail -n 400 /var/run/cilium/hubble/events.log | jq -r --arg v "${1:-.}" '
  select(.flow.destination.pod_name // "" | startswith("api")) | select(.flow.l4.TCP.flags.SYN and (.flow.l4.TCP.flags.ACK | not))
  | select(.flow.verdict | test($v)) | "\(.flow.time[11:19])  \(.flow.source.namespace)/\(.flow.source.pod_name) -> api:\(.flow.l4.TCP.destination_port)  \(.flow.verdict)\(if .flow.drop_reason_desc then "  " + .flow.drop_reason_desc else "" end)"' | tail -n ${2:-6}; }
```

### 1. Flow logs: every flow, written as JSON lines to a file on each node

The Hubble exporter in each Cilium agent writes every flow it sees as one JSON line. The file is on the node that saw the flow: for api, ckne-worker2.

```bash
kubectl -n shop get pods -o wide
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}'; echo
calls >/dev/null; sleep 3
kubectl -n kube-system exec $CP -c cilium-agent -- tail -n 200 /var/run/cilium/hubble/events.log | jq -c 'select(.flow.destination.pod_name // "" | startswith("api")) | .flow | {time, verdict, source: .source.pod_name, destination: .destination.pod_name, port: .l4.TCP.destination_port}' | tail -n 1
flows
```

Our output:

```text
$ kubectl -n shop get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
api-7f96b758b4-gtxtz   1/1     Running   0          18s   10.0.1.158   ckne-worker2   <none>           <none>
batch                  1/1     Running   0          17s   10.0.0.6     ckne-worker    <none>           <none>
intruder               1/1     Running   0          17s   10.0.0.181   ckne-worker    <none>           <none>
web                    1/1     Running   0          17s   10.0.0.131   ckne-worker    <none>           <none>
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}'; echo
/var/run/cilium/hubble/events.log
$ kubectl -n kube-system exec $CP -c cilium-agent -- tail -n 200 /var/run/cilium/hubble/events.log | jq -c 'select(.flow.destination.pod_name // "" | startswith("api")) | .flow | {time, verdict, source: .source.pod_name, destination: .destination.pod_name, port: .l4.TCP.destination_port}' | tail -n 1
{"time":"2026-11-20T02:09:36.177403285Z","verdict":"FORWARDED","source":"intruder","destination":"api-7f96b758b4-gtxtz","port":8080}
One JSON object per flow, on the node that saw it (here ckne-worker2, where api runs). A log shipper would collect this file.
$ flows
02:09:35  shop/web -> api:8080  FORWARDED
02:09:36  shop/batch -> api:8080  FORWARDED
02:09:36  shop/intruder -> api:8080  FORWARDED
```

**What to look for:** the file path in cilium-config, a JSON flow with `verdict`, source, destination and port, and three `FORWARDED` connections.

### 2. Policy audit mode: apply a policy, but only log what it would drop

Turn on audit mode for api's endpoint only, then apply a policy that allows only web. Wait until the policy is in place (the first AUDIT line), then test.

```bash
kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg endpoint config $EP PolicyAuditMode=Enabled
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-allow-web, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: web}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
EOF
kubectl -n shop get cnp
until [ -n "$(flows AUDIT 1)" ]; do calls >/dev/null; sleep 2; done   # on our Ubuntu box: 9 s
calls; sleep 3
flows AUDIT 4
kubectl -n kube-system exec $CP -c cilium-agent -- hubble observe --type policy-verdict --to-namespace shop --last 4
```

Our output:

```text
$ kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg endpoint config $EP PolicyAuditMode=Enabled
Endpoint 557 configuration updated successfully
$ kubectl -n shop get cnp
NAME            AGE   VALID
api-allow-web   0s    True
The lab re-tested quietly until the new policy was in place (AUDIT lines appeared): 9 s.
$ calls; sleep 3
web       ok
batch     ok
intruder  ok
$ flows AUDIT 4
02:09:47  shop/intruder -> api:8080  AUDIT
02:09:50  shop/batch -> api:8080  AUDIT
02:09:50  shop/intruder -> api:8080  AUDIT
$ kubectl -n kube-system exec $CP -c cilium-agent -- hubble observe --type policy-verdict --to-namespace shop --last 4
Nov 20 02:09:47.874: shop/intruder:43648 (ID:18652) -> shop/api-7f96b758b4-gtxtz:8080 (ID:59490) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
Nov 20 02:09:50.367: shop/web:47522 (ID:24661) -> shop/api-7f96b758b4-gtxtz:8080 (ID:59490) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
Nov 20 02:09:50.573: shop/batch:58530 (ID:373) -> shop/api-7f96b758b4-gtxtz:8080 (ID:59490) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
Nov 20 02:09:50.747: shop/intruder:43656 (ID:18652) -> shop/api-7f96b758b4-gtxtz:8080 (ID:59490) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
Nothing was blocked. But the log says batch and intruder would have been: AUDIT, policy-verdict:none.
```

**What to look for:** everyone still gets through (`ok`), but batch and intruder are logged as `AUDIT`, and hubble observe shows `policy-verdict:none INGRESS AUDITED` for them and `L3-L4 INGRESS ALLOWED` for web.

### 3. Read the audit: batch is a real client the policy forgot

batch is a real client (in our story, the nightly report job). Add it to the policy and look again, still in audit mode.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-allow-web, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: web}}, {matchLabels: {app: batch}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
EOF
sleep 3; calls >/dev/null; sleep 3
flows . 4
```

Our output:

```text
Our story: batch is the nightly report job, it must keep working; intruder must not.
$ cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-allow-web, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: web}}, {matchLabels: {app: batch}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
EOF
$ flows . 4
02:09:59  shop/batch -> api:8080  FORWARDED
02:09:59  shop/batch -> api:8080  FORWARDED
02:09:59  shop/intruder -> api:8080  AUDIT
02:09:59  shop/intruder -> api:8080  FORWARDED
Only intruder would still be dropped. The policy is ready to enforce.
```

**What to look for:** batch is `FORWARDED`; only intruder is still `AUDIT` (each audited connection shows an AUDIT and a FORWARDED event).

### 4. Enforce: turn audit mode off, and the log shows real drops

Turn audit mode off. The policy now drops what it doesn't allow.

```bash
kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg endpoint config $EP PolicyAuditMode=Disabled
sleep 3; calls; sleep 3
flows DROPPED 2
```

Our output:

```text
$ kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg endpoint config $EP PolicyAuditMode=Disabled
Endpoint 557 configuration updated successfully
$ sleep 3; calls; sleep 3
web       ok
batch     ok
intruder  blocked
$ flows DROPPED 2
02:10:09  shop/intruder -> api:8080  DROPPED  POLICY_DENIED
02:10:09  shop/intruder -> api:8080  DROPPED  POLICY_DENIED
```

**What to look for:** web and batch `ok`, intruder `blocked`, and `DROPPED  POLICY_DENIED` in the flow log.

### 5. Check your work

Grade the cluster the way an exam task is graded. The check looks for flows and AUDIT verdicts in the log file, web and batch allowed with intruder blocked, and intruder's POLICY_DENIED drop in the log.

```bash
bash lab.sh check
```

Our output:

```text
PASS  the flow log file on ckne-worker2 has flows to api
PASS  the flow log recorded AUDIT verdicts
PASS  web and batch reach api, intruder is blocked
PASS  the flow log shows intruder DROPPED with POLICY_DENIED
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
