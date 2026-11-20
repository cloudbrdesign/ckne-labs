# Mock exam 1

Fifteen exam-style tasks across the five CKNE domains, on one kind cluster called `ckne` (Cilium, Istio ambient, Gateway API, cert-manager). Sit it like the real exam: two hours, then the grader.

## Sit it

```bash
cd labs/m06/6.2-mock-exam-1
bash lab.sh up        # build the exam cluster, with its faults (about 6–7 minutes)
# open TASKS.md, start a 2-hour timer, write file answers in answers/
bash lab.sh check     # one PASS/FAIL per task
bash lab.sh step 7    # our solution for one task (after you've tried it)
bash lab.sh down      # delete the cluster
```

The tasks are in [TASKS.md](TASKS.md). Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

## Tested

20 November 2026, versions from `lib/versions.env`, Ubuntu 24.04 (job 140): before any solution 0/15; after our solutions 15/15. The build took 400 s and the whole run 524 s.

## Tasks at a glance

| Task | Domain | What it tests | Where it's taught |
|---|---|---|---|
| 1 | Core infrastructure and CNI | The pod CIDR Cilium allocated to ckne-worker2 | 1.3 |
| 2 | Core infrastructure and CNI | The CNI configuration file on ckne-worker | 1.2 |
| 3 | Service networking and DNS | Service shop/web has no endpoints | 2.1 |
| 4 | Service networking and DNS | NodePort Service shop/api-np on port 30080 | 2.1 |
| 5 | Service networking and DNS | legacy.corp.internal resolves to 10.10.10.10 for every pod | 2.4 |
| 6 | Service networking and DNS | HTTPRoute shop: /api to api, everything else to web | 2.7 |
| 7 | Advanced traffic management | Canary: 80% web, 20% web-v2 on canary.ckne.test | 2.7 |
| 8 | Advanced traffic management | LoadBalancer Service shop/edge gets an address from edge-pool | 3.1 |
| 9 | Advanced traffic management | shop/batch reaches ckne-ext through ckne-worker, with ckne-worker's address | 3.2 |
| 10 | Network security and policy | Only frontend may reach bank/ledger on 8080 | 4.1 |
| 11 | Network security and policy | locked/app can resolve names again, and nothing else | 4.2 |
| 12 | Network security and policy | HTTPS for shop.ckne.test on shop-gw, with a certificate from ckne-ca | 4.4 |
| 13 | Network security and policy | pay in the ambient mesh; only checkout may call payments | 4.5 |
| 14 | Observability | Who keeps being dropped on the way to vault/secrets? | 5.3 |
| 15 | Observability | Hubble exporter: only DROPPED flows, to /var/run/cilium/hubble/drops.log | 5.3 |

## Solutions (spoilers)

Sit the mock first. Each solution shows the YAML we applied and our real output (job 140, Ubuntu 24.04); names, addresses and ages will differ on your cluster.

### Task 1 · The pod CIDR Cilium allocated to ckne-worker2

*Core infrastructure and CNI · lesson 1.3.* Cilium allocates each node its own range of pod addresses. Write the pod CIDR that Cilium allocated to node `ckne-worker2` into `answers/t1.txt` (for example `10.0.9.0/24`).

Our run:

```text
$ kubectl get ciliumnode ckne-worker2 -o jsonpath='{.spec.ipam.podCIDRs[0]}' | tee answers/t1.txt; echo
10.0.2.0/24
```

### Task 2 · The CNI configuration file on ckne-worker

*Core infrastructure and CNI · lesson 1.2.* Write the file name (name only, no path) of the CNI configuration that Cilium installed on node `ckne-worker` into `answers/t2.txt`. (The nodes are containers: `docker exec ckne-worker …` takes you onto one.)

Our run:

```text
$ docker exec ckne-worker ls /etc/cni/net.d/
05-cilium.conflist
$ docker exec ckne-worker ls /etc/cni/net.d/ | grep cilium | tee answers/t2.txt
05-cilium.conflist
```

### Task 3 · Service shop/web has no endpoints

*Service networking and DNS · lesson 2.1.* In namespace `shop`, the Service `web` should send traffic to the pods of Deployment `web`, but requests to `http://web.shop` fail. Fix it without changing the Deployment.

Our run:

```text
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
web-rdmhp   IPv4          <unset>   <unset>     2m3s
$ kubectl -n shop get svc web -o jsonpath='{.spec.selector}'; echo
{"app":"wbe"}
$ kubectl -n shop get deploy web -o jsonpath='{.spec.template.metadata.labels}'; echo
{"app":"web"}
$ kubectl -n shop set selector service web app=web
service/web selector updated
$ kubectl -n shop exec client -- curl -s -m 3 http://web/hostname; echo
web-5bfd9679bc-5fdmt
```

### Task 4 · NodePort Service shop/api-np on port 30080

*Service networking and DNS · lesson 2.1.* In namespace `shop`, create a Service named `api-np` of type NodePort that exposes the pods of Deployment `api` (container port 8080) on node port **30080** of every node.

Our run:

```text
$ kubectl -n shop create service nodeport api-np --tcp=8080:8080 --node-port=30080
service/api-np created
$ kubectl -n shop set selector service api-np app=api
service/api-np selector updated
$ kubectl -n shop get svc api-np
NAME     TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)          AGE
api-np   NodePort   10.96.67.44   <none>        8080:30080/TCP   0s
$ docker exec ckne-control-plane curl -s -m 3 http://172.18.0.2:30080/hostname; echo
api-677758794f-zjcqd
```

### Task 5 · legacy.corp.internal resolves to 10.10.10.10 for every pod

*Service networking and DNS · lesson 2.4.* Every pod in the cluster must resolve `legacy.corp.internal` to `10.10.10.10` (test with the fully qualified name `legacy.corp.internal.`). Configure this in CoreDNS. Don't change any pod.

Our run:

```text
$ kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | head -3
.:53 {
    errors
    health {
$ kubectl -n kube-system edit cm coredns   # add a hosts block inside .:53 { … }
$ kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | head -6
.:53 {
    hosts {
        10.10.10.10 legacy.corp.internal
        fallthrough
    }
    errors
$ kubectl -n kube-system rollout restart deploy/coredns
deployment.apps/coredns restarted
$ kubectl -n shop exec client -- nslookup -type=A legacy.corp.internal. | tail -2
Address: 10.10.10.10
```

### Task 6 · HTTPRoute shop: /api to api, everything else to web

*Service networking and DNS · lesson 2.7.* The Gateway `shop-gw` in namespace `shop` listens for HTTP on port 80. Create an HTTPRoute named `shop` in `shop` so that requests for host `shop.ckne.test` with a path starting with `/api` go to Service `api` (port 8080) **with the `/api` prefix removed** (so `/api/hostname` reaches the app as `/hostname`), and all other requests for that host go to Service `web` (port 80).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: shop, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [shop.ckne.test]
  rules:
  - matches: [{path: {type: PathPrefix, value: /api}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: api, port: 8080}]
  - backendRefs: [{name: web, port: 80}]
```

Our run:

```text
$ kubectl apply -f httproute-shop.yaml   # hostnames: [shop.ckne.test]; /api -> api:8080 with the /api prefix replaced by /; / -> web:80
$ kubectl -n shop get httproute shop
NAME   HOSTNAMES            AGE
shop   ["shop.ckne.test"]   5s
$ kubectl -n shop exec client -- curl -s -m 3 -H 'Host: shop.ckne.test' http://172.18.255.200/api/hostname; echo
api-677758794f-zjcqd
$ kubectl -n shop exec client -- curl -s -m 3 -H 'Host: shop.ckne.test' http://172.18.255.200/hostname; echo
web-5bfd9679bc-5fdmt
```

### Task 7 · Canary: 80% web, 20% web-v2 on canary.ckne.test

*Advanced traffic management · lesson 2.7.* Create an HTTPRoute named `canary` in namespace `shop`, attached to `shop-gw`, for host `canary.ckne.test`. It must send 80% of requests to Service `web` and 20% to Service `web-v2` (both port 80).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: canary, namespace: shop}
spec:
  parentRefs: [{name: shop-gw}]
  hostnames: [canary.ckne.test]
  rules: [{backendRefs: [{name: web, port: 80, weight: 80}, {name: web-v2, port: 80, weight: 20}]}]
```

Our run:

```text
$ kubectl apply -f httproute-canary.yaml   # backendRefs: web weight 80, web-v2 weight 20
$ kubectl -n shop exec client -- sh -c 'for i in $(seq 1 50); do curl -s -m 3 -H "Host: canary.ckne.test" http://172.18.255.200/hostname; echo; done' | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c
     39 web
     11 web-v2
```

### Task 8 · LoadBalancer Service shop/edge gets an address from edge-pool

*Advanced traffic management · lesson 3.1.* The LoadBalancer Service `edge` in namespace `shop` has no external address. Create a `CiliumLoadBalancerIPPool` named `edge-pool` with the addresses `X.Y.255.240` to `X.Y.255.250`, where `X.Y` are the first two numbers of the kind Docker network (for example `172.18`), that serves **only** Services labelled `pool=edge`. Make sure `edge` gets its address from this pool.

```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: edge-pool}
spec:
  blocks: [{start: "172.18.255.240", stop: "172.18.255.250"}]
  serviceSelector: {matchLabels: {pool: edge}}
```

Our run:

```text
$ kubectl -n shop get svc edge
NAME   TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
edge   LoadBalancer   10.96.235.100   <pending>     80:31665/TCP   2m29s
$ kubectl apply -f edge-pool.yaml   # blocks: 172.18.255.240-250; serviceSelector: pool=edge
$ kubectl -n shop label service edge pool=edge
service/edge labeled
$ kubectl -n shop get svc edge
NAME   TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
edge   LoadBalancer   10.96.235.100   172.18.255.240   80:31665/TCP   2m35s
```

### Task 9 · shop/batch reaches ckne-ext through ckne-worker, with ckne-worker's address

*Advanced traffic management · lesson 3.2.* A partner server outside the cluster runs in the Docker container `ckne-ext` (find its address with `docker inspect ckne-ext`). Traffic from pods labelled `app=batch` in namespace `shop` to that server must leave the cluster through node `ckne-worker`, using `ckne-worker`'s own IP address as the source. Configure it with Cilium. (Egress gateway is already enabled in this cluster.)

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata: {name: batch-egress}
spec:
  selectors: [{podSelector: {matchLabels: {app: batch, io.kubernetes.pod.namespace: shop}}}]
  destinationCIDRs: ["<ckne-ext IP>/32"]
  egressGateway: {nodeSelector: {matchLabels: {egress-node: "true"}}, egressIP: "<ckne-worker IP>"}
```

Our run:

```text
$ kubectl -n shop exec batch -- wget -qO- -T 3 http://172.18.0.5:8080/clientip; echo
172.18.0.3:48018
$ kubectl label node ckne-worker egress-node=true
node/ckne-worker labeled
$ kubectl apply -f batch-egress.yaml   # podSelector app=batch in shop; destination 172.18.0.5/32; gateway: egress-node=true, egressIP 172.18.0.2
$ kubectl -n shop exec batch -- wget -qO- -T 3 http://172.18.0.5:8080/clientip; echo
172.18.0.2:48024
```

### Task 10 · Only frontend may reach bank/ledger on 8080

*Network security and policy · lesson 4.1.* In namespace `bank`, only pods labelled `app=frontend` may connect to the `ledger` pods, and only on TCP port 8080. All other ingress traffic to `ledger` must be blocked. Name the policy `ledger-ingress`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ledger-ingress, namespace: bank}
spec:
  podSelector: {matchLabels: {app: ledger}}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {matchLabels: {app: frontend}}}], ports: [{protocol: TCP, port: 8080}]}]
```

Our run:

```text
$ kubectl apply -f ledger-ingress.yaml   # podSelector app=ledger; from app=frontend; TCP 8080
$ for p in frontend intruder; do echo "$p $(kubectl -n bank exec $p -- wget -qO- -T 2 http://ledger:8080/hostname >/dev/null 2>&1 && echo allowed || echo blocked)"; done
frontend allowed
intruder blocked
```

### Task 11 · locked/app can resolve names again, and nothing else

*Network security and policy · lesson 4.2.* In namespace `locked`, a default-deny egress policy already exists. The pod `app` can no longer resolve any name. Allow it to use the cluster DNS (Service `kube-dns` in `kube-system`) on port 53, without allowing any other egress traffic.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

Our run:

```text
$ kubectl -n locked exec app -- nslookup web.shop.svc.cluster.local 2>&1 | tail -1
command terminated with exit code 1
$ kubectl apply -f allow-dns.yaml   # egress to kube-system/kube-dns on 53 UDP and TCP
$ kubectl -n locked exec app -- nslookup web.shop.svc.cluster.local 2>&1 | tail -2
$ kubectl -n locked exec app -- wget -qO- -T 2 http://web.shop/hostname 2>&1 | head -1
wget: download timed out
```

### Task 12 · HTTPS for shop.ckne.test on shop-gw, with a certificate from ckne-ca

*Network security and policy · lesson 4.4.* Serve `https://shop.ckne.test` on Gateway `shop-gw` (namespace `shop`), port 443. Use a certificate for `shop.ckne.test` issued by the ClusterIssuer `ckne-ca`, stored in a Secret named `shop-tls` in `shop`. Requests over HTTPS must reach the same backends as Task 6 (the HTTPRoute from Task 6 can stay as it is if it attaches to the whole Gateway). The CA certificate is in `answers/ckne-ca.crt` if you want to test with curl.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: shop-tls, namespace: shop}
spec:
  secretName: shop-tls
  dnsNames: [shop.ckne.test]
  issuerRef: {name: ckne-ca, kind: ClusterIssuer}
```

Our run:

```text
$ kubectl apply -f shop-tls.yaml   # Certificate: secretName shop-tls, dnsNames [shop.ckne.test], issuerRef ClusterIssuer ckne-ca
$ kubectl -n shop patch gateway shop-gw --type=json -p [{"op":"add","path":"/spec/listeners/-","value":{"name":"https","port":443,"protocol":"HTTPS","hostname":"shop.ckne.test","tls":{"mode":"Terminate","certificateRefs":[{"name":"shop-tls"}]}}}]
gateway.gateway.networking.k8s.io/shop-gw patched
$ kubectl -n shop exec client -- curl -s -m 3 --cacert /tmp/ca.crt --resolve shop.ckne.test:443:172.18.255.200 https://shop.ckne.test/hostname; echo
web-5bfd9679bc-5fdmt
```

### Task 13 · pay in the ambient mesh; only checkout may call payments

*Network security and policy · lesson 4.5.* Add namespace `pay` to the Istio **ambient** mesh. Then allow only workloads running as service account `checkout` (namespace `pay`) to call the `payments` pods; calls from any other identity, such as the `refund` pod, must be denied.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: payments-allow-checkout, namespace: pay}
spec:
  selector: {matchLabels: {app: payments}}
  action: ALLOW
  rules: [{from: [{source: {principals: [cluster.local/ns/pay/sa/checkout]}}]}]
```

Our run:

```text
$ kubectl label namespace pay istio.io/dataplane-mode=ambient
namespace/pay labeled
$ kubectl apply -f payments-authz.yaml   # ALLOW principals cluster.local/ns/pay/sa/checkout
$ for p in checkout refund; do echo "$p $(kubectl -n pay exec $p -- wget -qO- -T 3 http://payments:8080/hostname >/dev/null 2>&1 && echo allowed || echo denied)"; done
checkout allowed
refund denied
```

### Task 14 · Who keeps being dropped on the way to vault/secrets?

*Observability · lesson 5.3.* Something keeps trying to reach the Service `secrets` in namespace `vault`, and its connections are dropped by a network policy. Using Hubble, find which pod it is and write it as `namespace/pod` into `answers/t14.txt`.

Our run:

```text
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server $(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80 --verdict DROPPED --to-namespace vault --last 2
Nov 20 10:45:36.341: ops/scanner:34018 (ID:14842) <> vault/secrets-7765bc488d-zzphg:8080 (ID:6627) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Nov 20 10:45:36.342: ops/scanner:34018 (ID:14842) <> vault/secrets-7765bc488d-zzphg:8080 (ID:6627) Policy denied DROPPED (TCP Flags: SYN)
$ echo ops/scanner | tee answers/t14.txt
ops/scanner
```

### Task 15 · Hubble exporter: only DROPPED flows, to /var/run/cilium/hubble/drops.log

*Observability · lesson 5.3.* Configure Cilium's Hubble exporter on every node to write **only dropped flows** to the file `/var/run/cilium/hubble/drops.log`.

Our run:

```text
$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set hubble.export.static.enabled=true --set hubble.export.static.filePath=/var/run/cilium/hubble/drops.log --set-json 'hubble.export.static.allowList=["{\"verdict\":[\"DROPPED\"]}"]'
$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}{"\n"}{.data.hubble-export-allowlist}{"\n"}'
/var/run/cilium/hubble/drops.log
{"verdict":["DROPPED"]}
Restarting the agents also restarts what they program, such as the Gateway's Envoy listeners: give it a minute before re-testing.
```

## Traps we hit

- Task 5: in our run 135 the CoreDNS edit was piped through `apply` and an error was swallowed; the task failed. Read back what you changed.
- Task 6: agnhost answers unknown paths, so a route without the prefix rewrite *looks* fine; check which pod answered.
- Task 15: restarting the Cilium agents restarts the Gateway's Envoy listeners; in run 135 tasks 6 and 7 were checked during that restart and failed. Wait, then re-check.
