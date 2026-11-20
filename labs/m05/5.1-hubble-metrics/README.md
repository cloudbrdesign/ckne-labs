# Lab 5.1: Network health from metrics: Hubble and Prometheus

Lab for the course lesson **5.1 Network health from metrics: Hubble and Prometheus**. It creates a fresh kind cluster named `ckne` with Cilium, with Cilium's own metrics and a set of Hubble metrics switched on; the lab adds a server, a client and an intruder pod, Prometheus from Cilium's example, and two policies with DNS and HTTP rules, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m05/5.1-hubble-metrics
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Where the numbers come from: every Cilium agent serves metrics over HTTP
2. Prometheus: pull every source every 10 seconds and keep the history
3. Turn on L7 visibility: DNS and HTTP metrics come from Cilium's proxies
4. Make traffic: healthy, refused by L7, wrong names, and an intruder
5. Read the health of the network from Prometheus
6. From a number to the flows behind it: hubble observe

## What the check looks for

- Prometheus has Hubble flow metrics
- Prometheus counts drops denied by policy
- Prometheus counts DNS answers that aren't 'No Error'
- Prometheus counts HTTP 403s refused by the L7 rule
- hubble observe shows the intruder's dropped flows
- the client's GET /echo still gets through (200)

## Tested

20 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (218 s for `bash lab.sh run`).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 123, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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
  --set prometheus.enabled=true --set operator.prometheus.enabled=true --set hubble.enabled=true \
  --set 'hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp,httpV2:labelsContext=source_workload\,destination_workload}' --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

A server pinned to ckne-worker2, and a client and an intruder on ckne-worker.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: server}
spec:
  selector: {matchLabels: {app: server}}
  template:
    metadata: {labels: {app: server}}
    spec:
      nodeName: ckne-worker2
      containers: [{name: server, image: registry.k8s.io/e2e-test-images/agnhost:2.52, args: [netexec, --http-port=8080]}]
EOF
kubectl expose deployment server --port=8080
kubectl run client --image=busybox:1.36.1 --labels=app=client --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000
kubectl run intruder --image=busybox:1.36.1 --labels=app=intruder --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000
kubectl rollout status deploy/server --timeout=300s
kubectl wait --for=condition=Ready pod/client pod/intruder --timeout=300s
# a small helper: run a PromQL query inside the Prometheus pod and print "labels  value" per series
prom(){ kubectl -n cilium-monitoring exec deploy/prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" \
  | jq -r '.data.result[] | "  \(.metric | to_entries | map("\(.key)=\(.value)") | join(" ") | if .=="" then "(total)" else . end)   \(.value[1])"'; }
```

### 1. Where the numbers come from: every Cilium agent serves metrics over HTTP

Each Cilium agent serves two sets of counters over plain HTTP: Cilium's own on port 9962, Hubble's view of your pods' traffic on 9965. The chart annotates the hubble-metrics Service so Prometheus can find it.

```bash
kubectl get pods -o wide
kubectl -n kube-system get svc hubble-metrics -o jsonpath='{.metadata.annotations}'; echo
W2=$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
kubectl exec client -- wget -qO- http://$W2:9965/metrics | grep '^hubble_flows_processed_total' | head -4
kubectl exec client -- wget -qO- http://$W2:9962/metrics | grep '^cilium_forward_count_total'
```

Our output:

```text
$ kubectl get pods -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP          NODE           NOMINATED NODE   READINESS GATES
client                    1/1     Running   0          5s    10.0.1.95   ckne-worker    <none>           <none>
intruder                  1/1     Running   0          5s    10.0.1.79   ckne-worker    <none>           <none>
server-7d595f9dd8-8ttmv   1/1     Running   0          5s    10.0.2.80   ckne-worker2   <none>           <none>
Two kinds: Cilium's own health on port 9962 (cilium_*), and Hubble's view of your traffic on port 9965 (hubble_*).
$ kubectl -n kube-system get svc hubble-metrics -o jsonpath='{.metadata.annotations}'; echo
{"meta.helm.sh/release-name":"cilium","meta.helm.sh/release-namespace":"kube-system","prometheus.io/port":"9965","prometheus.io/scrape":"true"}
$ W2=$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
kubectl exec client -- wget -qO- http://$W2:9965/metrics | grep '^hubble_flows_processed_total' | head -4
hubble_flows_processed_total{protocol="ICMPv4",subtype="to-endpoint",type="Trace",verdict="FORWARDED"} 2
hubble_flows_processed_total{protocol="ICMPv4",subtype="to-overlay",type="Trace",verdict="FORWARDED"} 1
hubble_flows_processed_total{protocol="ICMPv4",subtype="to-stack",type="Trace",verdict="FORWARDED"} 1
hubble_flows_processed_total{protocol="ICMPv6",subtype="",type="Drop",verdict="DROPPED"} 5
$ kubectl exec client -- wget -qO- http://$W2:9962/metrics | grep '^cilium_forward_count_total'
cilium_forward_count_total{direction="EGRESS"} 2506
cilium_forward_count_total{direction="INGRESS"} 4745
Each line is a counter: a name, labels in braces, and a number that only goes up.
```

**What to look for:** `prometheus.io/scrape: true` and port `9965` on the Service, `hubble_flows_processed_total` lines with protocol, type and verdict labels, and Cilium's own `cilium_forward_count_total`.

### 2. Prometheus: pull every source every 10 seconds and keep the history

Install Prometheus (and Grafana, scaled to 0 here) from Cilium's example. It scrapes every 10 seconds; give it a minute to collect.

```bash
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.20.5/examples/kubernetes/addons/prometheus/monitoring-example.yaml
kubectl -n cilium-monitoring scale deploy/grafana --replicas=0
kubectl -n cilium-monitoring rollout status deploy/prometheus --timeout=240s
kubectl -n cilium-monitoring get pods
sleep 60; prom 'count by (job) (up == 1)'
```

Our output:

```text
We use the example stack from Cilium's repository (Prometheus and Grafana; Grafana is scaled to 0 to save memory).
$ kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.20.5/examples/kubernetes/addons/prometheus/monitoring-example.yaml
$ kubectl -n cilium-monitoring get pods
NAME                          READY   STATUS    RESTARTS   AGE
prometheus-68f4f54567-7wcj9   1/1     Running   0          3s
$ sleep 60; prom 'count by (job) (up == 1)'
  job=kubernetes-endpoints   2
  job=kubernetes-pods   3
  job=kubernetes-cadvisor   2
kubernetes-pods: the agents and operator (pod annotations). kubernetes-endpoints: hubble-metrics (Service annotations).
```

**What to look for:** the Prometheus pod Running, and targets up for `kubernetes-endpoints` (hubble-metrics) and `kubernetes-pods` (the agents).

### 3. Turn on L7 visibility: DNS and HTTP metrics come from Cilium's proxies

Hubble only sees DNS names and HTTP status codes for traffic that passes a DNS or HTTP rule. These rules also restrict traffic: the client may only talk DNS and port 8080 to the server, and the server only accepts GET on /echo from the client. The path is a regular expression that has to match the whole path, query string included, hence `/echo.*`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: client-egress}
spec:
  endpointSelector: {matchLabels: {app: client}}
  egress:
  - toEndpoints: [{matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}}]
    toPorts: [{ports: [{port: "53", protocol: ANY}], rules: {dns: [{matchPattern: "*"}]}}]
  - toEndpoints: [{matchLabels: {app: server}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: server-ingress}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}], rules: {http: [{method: GET, path: "/echo.*"}]}}]
EOF
kubectl get cnp
```

Our output:

```text
Hubble only sees DNS names and HTTP status codes for traffic that passes a DNS or HTTP rule.
$ kubectl get cnp
NAME             AGE   VALID
client-egress    0s    True
server-ingress   0s    True
client-egress: DNS (seen by the DNS proxy) and port 8080 to server. server-ingress: only the client, only GET on /echo (the path is a regular express…
```

**What to look for:** both policies `VALID True`.

### 4. Make traffic: healthy, refused by L7, wrong names, and an intruder

One example of each kind, then the same in a loop: 20 good requests, 10 to a refused path, 10 lookups of a name that doesn't exist, 5 attempts from the intruder.

```bash
kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=hello'; echo
kubectl exec client -- wget -qO- -T 3 http://server:8080/hostname 2>&1 | head -1
kubectl exec client -- nslookup no-such-svc.default.svc.cluster.local. 2>&1 | grep -m1 NXDOMAIN
kubectl exec intruder -- wget -qO- -T 2 http://server:8080/echo?msg=hi 2>&1 | head -1
for i in $(seq 1 20); do kubectl exec client -- wget -qO- -T 3 "http://server:8080/echo?msg=$i" >/dev/null; done
for i in $(seq 1 10); do kubectl exec client -- wget -qO- -T 3 http://server:8080/hostname >/dev/null 2>&1; done
for i in $(seq 1 10); do kubectl exec client -- nslookup no-such-svc.default.svc.cluster.local. >/dev/null 2>&1; done
for i in $(seq 1 5); do kubectl exec intruder -- wget -qO- -T 2 "http://server:8080/echo?msg=$i" >/dev/null 2>&1; done
sleep 30   # let Prometheus scrape
```

Our output:

```text
$ kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=hello'; echo
hello
$ kubectl exec client -- wget -qO- -T 3 http://server:8080/hostname 2>&1 | head -1
wget: server returned error: HTTP/1.1 403 Forbidden
$ kubectl exec client -- nslookup no-such-svc.default.svc.cluster.local. 2>&1 | grep -m1 NXDOMAIN
** server can't find no-such-svc.default.svc.cluster.local.: NXDOMAIN
$ kubectl exec intruder -- wget -qO- -T 2 http://server:8080/echo?msg=hi 2>&1 | head -1
wget: download timed out
sent: 20 good requests, 10 refused paths, 10 lookups of a name that doesn't exist, 5 intruder attempts that timed out
waiting 30 s for Prometheus to scrape the new counts ...
```

**What to look for:** `hello` comes back; `/hostname` gets `403 Forbidden` from Cilium's Envoy; the lookup gets `NXDOMAIN`; the intruder times out (its packets are dropped).

### 5. Read the health of the network from Prometheus

Ask Prometheus four questions: what verdict, what's dropped and why, are lookups failing, are requests failing and how slow.

```bash
prom 'sum by (verdict) (hubble_flows_processed_total)'
prom 'sum by (reason) (hubble_drop_total)'
prom 'sum by (rcode) (hubble_dns_responses_total)'
prom 'sum by (status) (hubble_http_requests_total)'
prom 'sum by (status) (rate(hubble_http_requests_total[2m]))'
prom 'histogram_quantile(0.95, sum by (le) (rate(hubble_http_request_duration_seconds_bucket[2m])))'
```

Our output:

```text
$ prom 'sum by (verdict) (hubble_flows_processed_total)'
  verdict=FORWARDED   2533
  verdict=DROPPED   73
  verdict=REDIRECTED   75
$ prom 'sum by (reason) (hubble_drop_total)'
  reason=DROP_REASON_UNKNOWN   11
  reason=UNSUPPORTED_L3_PROTOCOL   38
  reason=POLICY_DENIED   24
$ prom 'sum by (rcode) (hubble_dns_responses_total)'
  rcode=Non-Existent Domain   22
  rcode=No Error   64
$ prom 'sum by (status) (hubble_http_requests_total)'
  status=200   21
  status=403   11
$ prom 'sum by (status) (rate(hubble_http_requests_total[2m]))'
  status=200   0.076
  status=403   0
$ prom 'histogram_quantile(0.95, sum by (le) (rate(hubble_http_request_duration_seconds_bucket[2m])))'
  (total)   0.005
Counters only go up, so we ask rate() for 'per second over the last 2 minutes' when we want the trend.
```

**What to look for:** `POLICY_DENIED` drops (the intruder), `Non-Existent Domain` answers, HTTP `200` and `403` counts, and a 95th percentile in milliseconds. Some drops are background noise: `UNSUPPORTED_L3_PROTOCOL` came from ICMPv6 packets in our run. A `rate()` of 0 for a series that has only just appeared is normal: it needs at least two scrapes that show an increase (our reading).

### 6. From a number to the flows behind it: hubble observe

A metric says how much; the flow log says who, to whom and why. Hubble Relay gathers flows from every node; the hubble CLI is already inside each Cilium agent.

```bash
RELAY=$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --verdict DROPPED --from-pod default/intruder --last 3
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --http-status 403 --last 3
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --type l7 --protocol dns --last 2
```

Our output:

```text
A metric says how much. Hubble's flow log says who, to whom, and why. Hubble Relay gathers flows from every node.
$ RELAY=$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --verdict DROPPED --from-pod default/intruder --last 3
Nov 19 20:17:00.152: default/intruder:51542 (ID:16971) <> default/server-7d595f9dd8-8ttmv:8080 (ID:59838) Policy denied DROPPED (TCP Flags: SYN)
Nov 19 20:17:01.171: default/intruder:51542 (ID:16971) <> default/server-7d595f9dd8-8ttmv:8080 (ID:59838) policy-verdict:none INGRESS DENIED (TCP Fla…
Nov 19 20:17:01.171: default/intruder:51542 (ID:16971) <> default/server-7d595f9dd8-8ttmv:8080 (ID:59838) Policy denied DROPPED (TCP Flags: SYN)
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --http-status 403 --last 3
Nov 19 20:16:47.751: default/client:39584 (ID:44437) <- default/server-7d595f9dd8-8ttmv:8080 (ID:59838) http-response FORWARDED (HTTP/1.1 403 0ms (GE…
Nov 19 20:16:47.881: default/client:39590 (ID:44437) <- default/server-7d595f9dd8-8ttmv:8080 (ID:59838) http-response FORWARDED (HTTP/1.1 403 0ms (GE…
Nov 19 20:16:48.003: default/client:39602 (ID:44437) <- default/server-7d595f9dd8-8ttmv:8080 (ID:59838) http-response FORWARDED (HTTP/1.1 403 0ms (GE…
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $RELAY --type l7 --protocol dns --last 2
Nov 19 20:16:49.402: default/client:52568 (ID:44437) <- kube-system/coredns-559f6c778d-fpxqt:53 (ID:19374) dns-response proxy FORWARDED (DNS Answer R…
Nov 19 20:16:49.402: default/client:52568 (ID:44437) <- kube-system/coredns-559f6c778d-fpxqt:53 (ID:19374) dns-response proxy FORWARDED (DNS Answer R…
```

**What to look for:** `Policy denied DROPPED (TCP Flags: SYN)` for the intruder, `http-response … 403 … GET http://server:8080/hostname`, and `RCode: Non-Existent Domain`.

### 7. Check your work

Grade the cluster the way an exam task is graded. The check asks Prometheus for Hubble flows, policy drops, DNS errors and HTTP 403s, looks for the intruder's dropped flows in hubble observe, and makes sure a good request still gets 200.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Prometheus has Hubble flow metrics
PASS  Prometheus counts drops denied by policy
PASS  Prometheus counts DNS answers that aren't 'No Error'
PASS  Prometheus counts HTTP 403s refused by the L7 rule
PASS  hubble observe shows the intruder's dropped flows
PASS  the client's GET /echo still gets through (200)
6 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
