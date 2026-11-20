# Mock exam 2

Fifteen exam-style tasks across the five CKNE domains, on one kind cluster called `ckne` (Cilium, Istio ambient, Gateway API, cert-manager). Sit it like the real exam: two hours, then the grader.

## Sit it

```bash
cd labs/m06/6.3-mock-exam-2
bash lab.sh up        # build the exam cluster, with its faults (about 6–7 minutes)
# open TASKS.md, start a 2-hour timer, write file answers in answers/
bash lab.sh check     # one PASS/FAIL per task
bash lab.sh step 7    # our solution for one task (after you've tried it)
bash lab.sh down      # delete the cluster
```

The tasks are in [TASKS.md](TASKS.md). Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

## Tested

20 November 2026, versions from `lib/versions.env`, Ubuntu 24.04 (job 140): before any solution 0/15; after our solutions 15/15. The build took 361 s and the whole run 458 s.

## Tasks at a glance

| Task | Domain | What it tests | Where it's taught |
|---|---|---|---|
| 1 | Core infrastructure and CNI | The host-side interface of the api pod | 1.4 |
| 2 | Core infrastructure and CNI | The port caller uses to reach mystery, seen with tcpdump on ckne-worker2 | 1.4 |
| 3 | Service networking and DNS | A headless Service so db-0.db.data resolves | 2.1 |
| 4 | Service networking and DNS | ExternalName Service shop/partner for partner.example.org | 2.1 |
| 5 | Service networking and DNS | Forward corp.internal to the company DNS server | 2.4 |
| 6 | Service networking and DNS | Service shop/api: node-local traffic only for in-cluster clients | docs only |
| 7 | Advanced traffic management | Header routing: x-version: v2 goes to web-v2 | 2.7 |
| 8 | Advanced traffic management | Make shop/edge reachable from outside the cluster with L2 announcements | 3.1 |
| 9 | Advanced traffic management | Add the request header X-Env: prod on the way to web | 2.7 |
| 10 | Network security and policy | Only GET /public from client to api; everything else refused | lab 5.1 |
| 11 | Network security and policy | out/fetcher may reach only DNS and the partner machine | 4.2 |
| 12 | Network security and policy | Encrypt pod traffic between nodes with WireGuard | 4.3 |
| 13 | Network security and policy | pay accepts only mTLS | 4.5 |
| 14 | Observability | Envoy access logs for the whole mesh | 5.3 |
| 15 | Observability | Put vault/secrets into policy audit mode | 5.3 |

## Solutions (spoilers)

Sit the mock first. Each solution shows the YAML we applied and our real output (job 140, Ubuntu 24.04); names, addresses and ages will differ on your cluster.

### Task 1 · The host-side interface of the api pod

*Core infrastructure and CNI · lesson 1.4.* Each pod's `eth0` is one end of a veth pair; the other end lives on the node. Find the name of the node-side interface for the pod of Deployment `api` in namespace `shop`, and write it into `answers/t1.txt` (for example `lxc1a2b3c4d5e6f`).

Our run:

```text
$ kubectl -n shop get pod -l app=api -o wide
NAME                   READY   STATUS    RESTARTS   AGE    IP           NODE           NOMINATED NODE   READINESS GATES
api-6f8494bcdc-mhs52   1/1     Running   0          113s   10.0.0.228   ckne-worker2   <none>           <none>
$ kubectl -n shop exec api-6f8494bcdc-mhs52 -- cat /sys/class/net/eth0/iflink
23
$ docker exec ckne-worker2 ip -o link | grep "^$(kubectl -n shop exec api-6f8494bcdc-mhs52 -- cat /sys/class/net/eth0/iflink | tr -d '\r'):" | cut -d: -f2 | cut -d@ -f1 | tr -d ' ' | tee answers/t1.txt
lxcdcd4a82d8b10
```

### Task 2 · The port caller uses to reach mystery, seen with tcpdump on ckne-worker2

*Core infrastructure and CNI · lesson 1.4.* In namespace `net`, the pod `caller` keeps connecting to the pod `mystery`. Capture the traffic with `tcpdump` on the node that runs `mystery` and write the destination TCP port into `answers/t2.txt`. (The kind node has no tcpdump; `docker run --rm --net container:<node> nicolaka/netshoot:v0.13 tcpdump …` runs one inside the node's network.)

Our run:

```text
$ docker run --rm --net container:ckne-worker2 nicolaka/netshoot:v0.13 timeout 8 tcpdump -nni any -c 3 'tcp[tcpflags] & tcp-syn != 0 and dst host 10.0.0.22' 2>/dev/null
10:52:46.901666 cilium_vxlan P   IP 10.0.2.14.55600 > 10.0.0.22.9137: Flags [S], seq 136337958, win 64860, options [mss 1410,sackOK,TS val 3563974140 ecr 0,nop,wscale 10], length 0
10:52:46.901714 lxc4cdc23e0879d Out IP 10.0.2.14.55600 > 10.0.0.22.9137: Flags [S], seq 136337958, win 64860, options [mss 1410,sackOK,TS val 3563974140 ecr 0,nop,wscale 10], length 0
10:52:48.905410 cilium_vxlan P   IP 10.0.2.14.56560 > 10.0.0.22.9137: Flags [S], seq 2871153975, win 64860, options [mss 1410,sackOK,TS val 43302405 ecr 0,nop,wscale 10], length 0
$ echo 9137 | tee answers/t2.txt
9137
```

### Task 3 · A headless Service so db-0.db.data resolves

*Service networking and DNS · lesson 2.1.* The StatefulSet `db` in namespace `data` expects a Service named `db`, which doesn't exist. Create it so that every pod gets its own DNS name, such as `db-0.db.data.svc.cluster.local`, resolving to that pod's address. Port 5432.

Our run:

```text
$ kubectl -n data create service clusterip db --clusterip=None --tcp=5432:5432
service/db created
$ kubectl -n data set selector service db app=db
service/db selector updated
$ kubectl -n shop exec client -- nslookup -type=A db-0.db.data.svc.cluster.local | tail -2
Address: 10.0.2.116
```

### Task 4 · ExternalName Service shop/partner for partner.example.org

*Service networking and DNS · lesson 2.1.* In namespace `shop`, create a Service named `partner` so that pods calling `partner.shop` are sent to the external name `partner.example.org` by DNS.

Our run:

```text
$ kubectl -n shop create service externalname partner --external-name=partner.example.org
service/partner created
$ kubectl -n shop exec client -- dig +short partner.shop.svc.cluster.local CNAME
partner.example.org.
```

### Task 5 · Forward corp.internal to the company DNS server

*Service networking and DNS · lesson 2.4.* The company's DNS server runs in the Docker container `ckne-dns` (find its address with `docker inspect ckne-dns`). It answers for the zone `corp.internal`. Configure CoreDNS so that every pod resolves names in `corp.internal` through that server; test with `app.corp.internal.`. Don't change any pod.

Our run:

```text
$ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-dns
172.18.0.6
$ kubectl -n kube-system edit cm coredns   # add a server block for corp.internal
$ kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | tail -5
corp.internal:53 {
    errors
    cache 30
    forward . 172.18.0.6
}
$ kubectl -n kube-system rollout restart deploy/coredns
deployment.apps/coredns restarted
$ kubectl -n shop exec client -- nslookup -type=A app.corp.internal. | tail -2
Address: 10.20.30.40
```

### Task 6 · Service shop/api: node-local traffic only for in-cluster clients

*Service networking and DNS · not in a lesson: see the Kubernetes or tool docs.* The pods in `shop` that call Service `api` run on the same node as the `api` pod. Configure Service `api` so that traffic from inside the cluster only goes to endpoints on the caller's own node.

Our run:

```text
$ kubectl -n shop patch svc api -p {"spec":{"internalTrafficPolicy":"Local"}}
service/api patched
$ kubectl -n shop get svc api -o jsonpath='{.spec.internalTrafficPolicy}'; echo
Local
```

### Task 7 · Header routing: x-version: v2 goes to web-v2

*Advanced traffic management · lesson 2.7.* Create an HTTPRoute named `versions` in namespace `shop`, attached to Gateway `shop-gw`, for host `versions.ckne.test`. Requests with the header `x-version: v2` go to Service `web-v2`; all other requests go to Service `web` (both port 80).

```yaml
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
```

Our run:

```text
$ kubectl apply -f httproute-versions.yaml   # match header x-version: v2 -> web-v2; everything else -> web
$ kubectl -n shop exec client -- curl -s -m 3 -H 'Host: versions.ckne.test' -H 'x-version: v2' http://172.18.255.201/hostname; echo
web-v2-db56f6d66-sd8rp
$ kubectl -n shop exec client -- curl -s -m 3 -H 'Host: versions.ckne.test' http://172.18.255.201/hostname; echo
web-5bfd9679bc-s5x69
```

### Task 8 · Make shop/edge reachable from outside the cluster with L2 announcements

*Advanced traffic management · lesson 3.1.* The LoadBalancer Service `edge` in namespace `shop` has an address, but nothing outside the cluster can reach it: from the container `ckne-ext`, `curl http://<address>/hostname` times out. Make it reachable with Cilium **L2 announcements**, from the worker nodes only, on interface `eth0`. (L2 announcements are already enabled in this cluster.)

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: edge-l2}
spec:
  serviceSelector: {matchLabels: {app: edge}}
  nodeSelector: {matchExpressions: [{key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}]}
  interfaces: [^eth0$]
  loadBalancerIPs: true
```

Our run:

```text
$ kubectl -n shop get svc edge
NAME   TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)        AGE
edge   LoadBalancer   10.96.24.96   172.18.255.200   80:31231/TCP   2m10s
$ docker exec ckne-ext curl -s -m 3 http://172.18.255.200/hostname || echo unreachable
unreachable
$ kubectl apply -f edge-l2.yaml   # serviceSelector app=edge; worker nodes; interface eth0; loadBalancerIPs: true
$ docker exec ckne-ext curl -s -m 3 http://172.18.255.200/hostname; echo
edge-5bc4987766-2jfjg
```

### Task 9 · Add the request header X-Env: prod on the way to web

*Advanced traffic management · lesson 2.7.* Create an HTTPRoute named `env` in namespace `shop`, attached to `shop-gw`, for host `env.ckne.test`, that sends requests to Service `web` (port 80) with the request header `X-Env: prod` added by the Gateway.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: env, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [env.ckne.test]
  rules:
  - filters: [{type: RequestHeaderModifier, requestHeaderModifier: {set: [{name: X-Env, value: prod}]}}]
    backendRefs: [{name: web, port: 80}]
```

Our run:

```text
$ kubectl apply -f httproute-env.yaml   # RequestHeaderModifier: set X-Env: prod
$ kubectl -n shop exec client -- curl -s -m 3 -H 'Host: env.ckne.test' 'http://172.18.255.201/header?key=X-Env'; echo
prod
```

### Task 10 · Only GET /public from client to api; everything else refused

*Network security and policy · lab 5.1.* In namespace `shop`, pods labelled `app=client` may send only `GET /public` requests to the `api` pods on port 8080. Any other request from them, such as `GET /hostname`, must be refused with HTTP 403. Name the policy `api-l7`.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: api-l7, namespace: shop}
spec:
  endpointSelector: {matchLabels: {app: api}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "8080", protocol: TCP}], rules: {http: [{method: GET, path: "/public"}]}}]
```

Our run:

```text
$ kubectl apply -f api-l7.yaml   # from app=client; port 8080; http: GET /public
$ kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' -m 3 http://api:8080/public
200
$ kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' -m 3 http://api:8080/hostname
403
```

### Task 11 · out/fetcher may reach only DNS and the partner machine

*Network security and policy · lesson 4.2.* In namespace `out`, the pod `fetcher` may reach only the cluster DNS (port 53) and the partner machine in the container `ckne-ext`. All other egress, including to other pods, must be blocked. Name the policy `fetcher-egress`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: fetcher-egress, namespace: out}
spec:
  podSelector: {matchLabels: {app: fetcher}}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
  - to: [{ipBlock: {cidr: <ckne-ext IP>/32}}]
```

Our run:

```text
$ kubectl apply -f fetcher-egress.yaml   # egress: kube-dns on 53; ipBlock 172.18.0.5/32
$ kubectl -n out exec fetcher -- ping -c1 -W2 172.18.0.5 | tail -2 | head -1
1 packets transmitted, 1 packets received, 0% packet loss
$ kubectl -n out exec fetcher -- wget -qO- -T 2 http://web.shop/hostname 2>&1 | head -1
wget: download timed out
```

### Task 12 · Encrypt pod traffic between nodes with WireGuard

*Network security and policy · lesson 4.3.* Pod traffic between nodes must be encrypted. Turn on Cilium's transparent encryption with **WireGuard** on every node. Existing applications must keep working.

Our run:

```text
$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption
Encryption:              Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: MonE+yjivyU7fw4FP1cRrTMiQzEJRV5Np5o5PIux6C8=, Port: 51871, Peers: 2)]
```

### Task 13 · pay accepts only mTLS

*Network security and policy · lesson 4.5.* Namespace `pay` is already in the Istio ambient mesh. Make the `payments` workload accept **only mutual TLS**: the `checkout` pod (in the mesh) must still reach it, and plain-text callers from outside the mesh, such as the pod `legacy` in `shop`, must be refused.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: pay}
spec: {mtls: {mode: STRICT}}
```

Our run:

```text
$ kubectl apply -f strict.yaml   # PeerAuthentication default, namespace pay, mtls: STRICT
$ for p in pay/checkout shop/legacy; do echo "$p $(kubectl -n ${p%/*} exec ${p#*/} -- wget -qO- -T 3 http://payments.pay:8080/hostname >/dev/null 2>&1 && echo allowed || echo refused)"; done
pay/checkout allowed
shop/legacy refused
```

### Task 14 · Envoy access logs for the whole mesh

*Observability · lesson 5.3.* Turn on Envoy access logs for the whole mesh with the Istio Telemetry API.

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: {name: mesh-default, namespace: istio-system}
spec:
  accessLogging: [{providers: [{name: envoy}]}]
```

Our run:

```text
$ kubectl apply -f telemetry.yaml   # namespace istio-system; accessLogging: providers envoy
$ kubectl -n istio-system get telemetry
NAME           AGE
mesh-default   1s
```

### Task 15 · Put vault/secrets into policy audit mode

*Observability · lesson 5.3.* The team wants to test a new policy for the `secrets` pod in namespace `vault` without breaking it. Put **only that pod's endpoint** into Cilium policy audit mode.

Our run:

```text
$ kubectl -n vault get cep secrets-7765bc488d-n7djv -o jsonpath='{.status.id}'; echo
346
$ kubectl -n kube-system exec cilium-df69v -c cilium-agent -- cilium-dbg endpoint config 346 PolicyAuditMode=Enabled
Endpoint 346 configuration updated successfully
$ kubectl -n kube-system exec cilium-df69v -c cilium-agent -- cilium-dbg endpoint get 346 -o jsonpath='{[*].spec.options.PolicyAuditMode}'; echo
Enabled
```

## Traps we hit

- Task 6: `internalTrafficPolicy: Local` has no fallback; a caller on a node without an endpoint gets no answer.
- Task 12 resets task 15: enabling WireGuard restarts the Cilium agents, and per-endpoint audit mode lasts only until the Cilium pod restarts. Do 12 first, or redo 15.
- Task 8: an assigned LoadBalancer address isn't reachable from outside until a node answers for it (L2 announcements). *Our reading.*
