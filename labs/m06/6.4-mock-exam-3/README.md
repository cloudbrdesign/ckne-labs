# Mock exam 3

Fifteen exam-style tasks across the five CKNE domains, on one kind cluster called `ckne` (Cilium, Istio ambient, Gateway API, cert-manager). Sit it like the real exam: two hours, then the grader.

## Sit it

```bash
cd labs/m06/6.4-mock-exam-3
bash lab.sh up        # build the exam cluster, with its faults (about 6–7 minutes)
# open TASKS.md, start a 2-hour timer, write file answers in answers/
bash lab.sh check     # one PASS/FAIL per task
bash lab.sh step 7    # our solution for one task (after you've tried it)
bash lab.sh down      # delete the cluster
```

The tasks are in [TASKS.md](TASKS.md). Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

## Tested

20 November 2026, versions from `lib/versions.env`, Ubuntu 24.04 (job 145): before any solution 0/15; after our solutions 15/15. The build took 395 s and the whole run 527 s.

## Tasks at a glance

| Task | Domain | What it tests | Where it's taught |
|---|---|---|---|
| 1 | Core infrastructure and CNI | The encapsulation Cilium uses between nodes | 1.2 |
| 2 | Core infrastructure and CNI | The MTU of eth0 in net/probe | docs only |
| 3 | Service networking and DNS | Service shop/cart sends traffic to the wrong port | 2.1 |
| 4 | Service networking and DNS | Sticky sessions on shop/web | docs only |
| 5 | Service networking and DNS | A pod with its own DNS settings | 1.5 |
| 6 | Advanced traffic management | Redirect http://secure.ckne.test to HTTPS | 2.7 |
| 7 | Advanced traffic management | A response header from the Gateway | 2.7 |
| 8 | Advanced traffic management | A waypoint for namespace mesh | 4.5 |
| 9 | Advanced traffic management | In the mesh: x-user: tester goes to echo-v2 | 5.2 |
| 10 | Network security and policy | bank accepts traffic only from its own namespace | 4.1 |
| 11 | Network security and policy | In the mesh: echo accepts only GET | 4.5 |
| 12 | Network security and policy | Block attacker inside bank, whatever else allows it | 4.2 |
| 13 | Network security and policy | A 30-day certificate for api.ckne.test | 4.4 |
| 14 | Observability | The name ops/bot keeps failing to resolve | lab 5.1 |
| 15 | Observability | Hubble metrics for DNS, drops and HTTP | 5.1 |

## Solutions (spoilers)

Sit the mock first. Each solution shows the YAML we applied and our real output (job 145, Ubuntu 24.04); names, addresses and ages will differ on your cluster.

### Task 1 · The encapsulation Cilium uses between nodes

*Core infrastructure and CNI · lesson 1.2.* Cilium in this cluster sends pod traffic between nodes through a tunnel. Write the tunnel protocol it uses (lowercase, one word) into `answers/t1.txt`.

Our run:

```text
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.routing-mode}{" "}{.data.tunnel-protocol}{"\n"}'
tunnel vxlan
$ echo vxlan | tee answers/t1.txt
vxlan
```

### Task 2 · The MTU of eth0 in net/probe

*Core infrastructure and CNI · not in a lesson: see the Kubernetes or tool docs.* Write the MTU of the interface `eth0` inside the pod `probe` in namespace `net` into `answers/t2.txt` (a number only).

Our run:

```text
$ kubectl -n net exec probe -- ip link show eth0
16: eth0@if17: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether 0e:ea:02:04:d3:ce brd ff:ff:ff:ff:ff:ff link-netnsid 0
    altname cilium_cni:eth0
$ kubectl -n net exec probe -- cat /sys/class/net/eth0/mtu | tr -d '\r' | tee answers/t2.txt
1500
```

### Task 3 · Service shop/cart sends traffic to the wrong port

*Service networking and DNS · lesson 2.1.* In namespace `shop`, requests to `http://cart` fail although the `cart` pods are running. Fix the Service `cart` without changing the Deployment.

Our run:

```text
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=cart
NAME         ADDRESSTYPE   PORTS   ENDPOINTS    AGE
cart-7dt88   IPv4          9090    10.0.0.150   2m5s
$ kubectl -n shop get deploy cart -o jsonpath='{.spec.template.spec.containers[0].command}'; echo
["/agnhost","netexec","--http-port=8080"]
$ kubectl -n shop patch svc cart --type=json -p [{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]
service/cart patched
$ kubectl -n shop exec client -- curl -s -m 3 http://cart/hostname; echo
cart-5bdf46c8c-v2v7x
```

### Task 4 · Sticky sessions on shop/web

*Service networking and DNS · not in a lesson: see the Kubernetes or tool docs.* In namespace `shop`, make the Service `web` send every request from the same client to the same pod.

Our run:

```text
$ kubectl -n shop patch svc web -p {"spec":{"sessionAffinity":"ClientIP"}}
service/web patched
$ kubectl -n shop scale deploy web --replicas=3 >/dev/null; kubectl -n shop rollout status deploy web >/dev/null; for i in 1 2 3 4 5 6; do kubectl -n shop exec client -- curl -s -m 3 http://web/hostname; echo; done | sort | uniq -c
      6 web-5bfd9679bc-sm88m
```

### Task 5 · A pod with its own DNS settings

*Service networking and DNS · lesson 1.5.* In namespace `net`, create a pod named `resolver` (image `busybox:1.36.1`, command `sleep 36000`) whose DNS settings add the search domain `corp.internal` and use `ndots` 2. Keep the cluster DNS as its name server.

```yaml
apiVersion: v1
kind: Pod
metadata: {name: resolver, namespace: net}
spec:
  dnsConfig:
    searches: [corp.internal]
    options: [{name: ndots, value: "2"}]
  containers: [{name: c, image: busybox:1.36.1, command: [sleep, "36000"]}]
```

Our run:

```text
$ kubectl apply -f resolver.yaml   # dnsConfig: searches [corp.internal]; options ndots "2"
$ kubectl -n net exec resolver -- cat /etc/resolv.conf
search net.svc.cluster.local svc.cluster.local cluster.local ec2.internal corp.internal
nameserver 10.96.0.10
options ndots:2
```

### Task 6 · Redirect http://secure.ckne.test to HTTPS

*Advanced traffic management · lesson 2.7.* On Gateway `shop-gw` in namespace `shop`, every HTTP request for host `secure.ckne.test` must be redirected to the same URL over HTTPS with status code **301**. Name the HTTPRoute `secure-redirect`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: secure-redirect, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [secure.ckne.test]
  rules:
  - filters: [{type: RequestRedirect, requestRedirect: {scheme: https, statusCode: 301}}]
```

Our run:

```text
$ kubectl apply -f secure-redirect.yaml   # RequestRedirect: scheme https, statusCode 301
$ kubectl -n shop exec client -- curl -s -o /dev/null -m 3 -w '%{http_code} %{redirect_url}\n' -H 'Host: secure.ckne.test' http://172.18.255.200/cart
301 https://secure.ckne.test:443/cart
```

### Task 7 · A response header from the Gateway

*Advanced traffic management · lesson 2.7.* Create an HTTPRoute named `info` in namespace `shop`, attached to `shop-gw`, for host `info.ckne.test`, that sends requests to Service `web` (port 80) and adds the **response** header `X-Served-By: ckne`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: info, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [info.ckne.test]
  rules:
  - filters: [{type: ResponseHeaderModifier, responseHeaderModifier: {add: [{name: X-Served-By, value: ckne}]}}]
    backendRefs: [{name: web, port: 80}]
```

Our run:

```text
$ kubectl apply -f info.yaml   # ResponseHeaderModifier: add X-Served-By: ckne
$ kubectl -n shop exec client -- curl -s -m 3 -D - -o /dev/null -H 'Host: info.ckne.test' http://172.18.255.200/hostname | grep -i -e '^HTTP' -e '^x-served-by'
HTTP/1.1 200 OK
x-served-by: ckne
```

### Task 8 · A waypoint for namespace mesh

*Advanced traffic management · lesson 4.5.* Namespace `mesh` is in the Istio ambient mesh, without a waypoint. Deploy a waypoint named `waypoint` in `mesh` that handles traffic for Services, and make the whole namespace use it.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: waypoint, namespace: mesh, labels: {istio.io/waypoint-for: service}}
spec:
  gatewayClassName: istio-waypoint
  listeners: [{name: mesh, port: 15008, protocol: HBONE}]
```

Our run:

```text
$ kubectl apply -f waypoint.yaml   # gatewayClassName istio-waypoint; listener mesh 15008 HBONE; waypoint-for: service
$ kubectl label namespace mesh istio.io/use-waypoint=waypoint
namespace/mesh labeled
$ kubectl -n mesh get gateway waypoint
NAME       CLASS            ADDRESS         PROGRAMMED   AGE
waypoint   istio-waypoint   10.96.228.149   True         6s
```

### Task 9 · In the mesh: x-user: tester goes to echo-v2

*Advanced traffic management · lesson 5.2.* In namespace `mesh`, requests from inside the mesh to Service `echo` (port 8080) that carry the header `x-user: tester` must go to Service `echo-v2`; all other requests stay on `echo`. Use the Gateway API. Name the route `echo-testers`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo-testers, namespace: mesh}
spec:
  parentRefs: [{group: "", kind: Service, name: echo, port: 8080}]
  rules:
  - matches: [{headers: [{name: x-user, value: tester}]}]
    backendRefs: [{name: echo-v2, port: 8080}]
  - backendRefs: [{name: echo, port: 8080}]
```

Our run:

```text
$ kubectl apply -f echo-testers.yaml   # parentRefs: the Service echo (not a Gateway); header x-user: tester -> echo-v2
command terminated with exit code 56
command terminated with exit code 56
$ kubectl -n mesh exec client -- curl -s -m 3 -H 'x-user: tester' http://echo:8080/hostname; echo
echo-v2-7848f7855f-hh2xv
$ kubectl -n mesh exec client -- curl -s -m 3 http://echo:8080/hostname; echo
echo-8db6df4c6-6z2bd
```

### Task 10 · bank accepts traffic only from its own namespace

*Network security and policy · lesson 4.1.* Pods in namespace `bank` must accept traffic only from pods in `bank` itself. Name the policy `same-ns-only`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: same-ns-only, namespace: bank}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {}}]}]
```

Our run:

```text
$ kubectl apply -f same-ns-only.yaml   # podSelector {} ; ingress from podSelector {} (this namespace only)
$ for p in bank/frontend shop/client; do echo "$p $(kubectl -n ${p%/*} exec ${p#*/} -- wget -qO- -T 2 http://web.bank/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
bank/frontend allowed
shop/client blocked
```

### Task 11 · In the mesh: echo accepts only GET

*Network security and policy · lesson 4.5.* In namespace `mesh`, Service `echo` must accept only `GET` requests; any other method, such as `POST`, must be refused with HTTP 403. Use Istio. Name the policy `echo-get-only`.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: echo-get-only, namespace: mesh}
spec:
  targetRefs: [{kind: Service, group: "", name: echo}]
  action: ALLOW
  rules: [{to: [{operation: {methods: [GET]}}]}]
```

Our run:

```text
$ kubectl apply -f echo-get-only.yaml   # targetRefs: Service echo (enforced by the waypoint); ALLOW methods [GET]
$ kubectl -n mesh exec client -- curl -s -m 3 -w ' %{http_code}\n' 'http://echo:8080/echo?msg=hello'
hello 200
$ kubectl -n mesh exec client -- curl -s -m 3 -X POST -w ' %{http_code}\n' 'http://echo:8080/echo?msg=hello'
RBAC: access denied 403
```

### Task 12 · Block attacker inside bank, whatever else allows it

*Network security and policy · lesson 4.2.* In namespace `bank`, the pod `attacker` must not reach the `web` pods, even though Task 10 allows traffic from inside `bank`. Use a Cilium deny rule; the `frontend` pod must still reach `web`. Name the policy `deny-attacker`.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: deny-attacker, namespace: bank}
spec:
  endpointSelector: {matchLabels: {app: web}}
  ingressDeny: [{fromEndpoints: [{matchLabels: {app: attacker}}]}]
```

Our run:

```text
$ kubectl apply -f deny-attacker.yaml   # endpointSelector app=web; ingressDeny fromEndpoints app=attacker
$ for p in frontend attacker; do echo "$p $(kubectl -n bank exec $p -- wget -qO- -T 2 http://web/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
frontend allowed
attacker blocked
```

### Task 13 · A 30-day certificate for api.ckne.test

*Network security and policy · lesson 4.4.* In namespace `certs`, create a Certificate named `api-cert` for `api.ckne.test`, stored in the Secret `api-cert`, issued by the ClusterIssuer `ckne-selfsigned`. It must be valid for **30 days** and be renewed **10 days** before it expires.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: api-cert, namespace: certs}
spec:
  secretName: api-cert
  dnsNames: [api.ckne.test]
  duration: 720h
  renewBefore: 240h
  issuerRef: {name: ckne-selfsigned, kind: ClusterIssuer}
```

Our run:

```text
$ kubectl apply -f api-cert.yaml   # secretName api-cert; dnsNames [api.ckne.test]; duration 720h; renewBefore 240h; ClusterIssuer ckne-selfsigned
$ kubectl -n certs get certificate api-cert -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}  notBefore={.status.notBefore}  notAfter={.status.notAfter}  renewalTime={.status.renewalTime}{"\n"}'
Ready=True  notBefore=2026-11-20T12:36:30Z  notAfter=2026-12-20T12:36:30Z  renewalTime=2026-12-10T12:36:30Z
```

### Task 14 · The name ops/bot keeps failing to resolve

*Observability · lab 5.1.* The pod `bot` in namespace `ops` keeps trying to resolve a name that doesn't exist. Using Hubble, find the name and write it into `answers/t14.txt`.

Our run:

```text
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80 --namespace ops --protocol dns --type l7 --last 40 | grep -e 'corp.invalid' | tail -3
Nov 20 12:36:30.810: ops/bot:51031 (ID:37193) -> kube-system/coredns-559f6c778d-vg7wj:53 (ID:35894) dns-request proxy FORWARDED (DNS Query ledger-db.corp.invalid. AAAA)
Nov 20 12:36:30.815: ops/bot:51031 (ID:37193) <- kube-system/coredns-559f6c778d-vg7wj:53 (ID:35894) dns-response proxy FORWARDED (DNS Answer RCode: Non-Existent Domain TTL: 4294967295 (Proxy ledger-db.corp.invalid. A))
Nov 20 12:36:30.816: ops/bot:51031 (ID:37193) <- kube-system/coredns-559f6c778d-vg7wj:53 (ID:35894) dns-response proxy FORWARDED (DNS Answer RCode: Non-Existent Domain TTL: 4294967295 (Proxy ledger-db.corp.invalid. AAAA))
$ echo ledger-db.corp.invalid | tee answers/t14.txt
ledger-db.corp.invalid
```

### Task 15 · Hubble metrics for DNS, drops and HTTP

*Observability · lesson 5.1.* Turn on Cilium's Hubble metrics for **DNS**, **drops** and **HTTP** (the `httpV2` metric) on every node, so that each node serves them on port 9965.

Our run:

```text
$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set hubble.metrics.enabled="{dns,drop,httpV2}"
$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-metrics}{"\n"}'
dns drop httpV2
$ for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[0].address}'); do echo "== $ip:9965"; kubectl -n net exec probe -- curl -s -m 3 http://$ip:9965/metrics | grep -o '^hubble_[a-z_]*' | sort -u; done
== 172.18.0.3:9965
hubble_lost_events_total
hubble_metrics_http_handler_request_duration_seconds_bucket
hubble_metrics_http_handler_request_duration_seconds_count
hubble_metrics_http_handler_request_duration_seconds_sum
hubble_metrics_http_handler_requests_total
== 172.18.0.2:9965
hubble_lost_events_total
…
hubble_metrics_http_handler_request_duration_seconds_sum
hubble_metrics_http_handler_requests_total
Restarting the agents also restarts the Gateway's listeners: give it a minute before re-testing.
```

## Traps we hit

- Task 3: the EndpointSlice isn't empty, so the selector is fine; compare its port with the port the container listens on.
- Task 9: right after the route was applied, the first two requests failed (curl exit code 56) while the waypoint picked it up; a few seconds later it worked. *Cause: our reading.*
- Task 15: a node lists a Hubble metric only once it has traffic to count; in our run only one node had DNS series right after the restart. *Our reading.*
