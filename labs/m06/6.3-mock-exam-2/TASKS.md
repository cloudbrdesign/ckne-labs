# Mock exam 2: tasks

**Time: 2 hours.** Start a timer when `bash lab.sh up` has finished. Fifteen tasks across the five CKNE domains, weighted roughly like the exam. Do them in any order. Some tasks ask for an answer in a file: write it to `answers/tN.txt` in this folder, on one line.

Everything runs on one kind cluster called `ckne` (context `kind-ckne`). In the real exam each task names a host to `ssh` into; here every task runs from your own terminal. The nodes are containers: `docker exec ckne-worker2 …` takes you onto one. Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

When you're done (or the timer ends): `bash lab.sh check`. Each task is PASS or FAIL, graded on what the cluster does. Then compare with the walkthrough video, or run one reference solution with `bash lab.sh step N`.

---

## Core infrastructure and CNI

**Task 1.** Each pod's `eth0` is one end of a veth pair; the other end lives on the node. Find the name of the node-side interface for the pod of Deployment `api` in namespace `shop`, and write it into `answers/t1.txt` (for example `lxc1a2b3c4d5e6f`).

**Task 2.** In namespace `net`, the pod `caller` keeps connecting to the pod `mystery`. Capture the traffic with `tcpdump` on the node that runs `mystery` and write the destination TCP port into `answers/t2.txt`. (The kind node has no tcpdump; `docker run --rm --net container:<node> nicolaka/netshoot:v0.13 tcpdump …` runs one inside the node's network.)

## Service networking and DNS

**Task 3.** The StatefulSet `db` in namespace `data` expects a Service named `db`, which doesn't exist. Create it so that every pod gets its own DNS name, such as `db-0.db.data.svc.cluster.local`, resolving to that pod's address. Port 5432.

**Task 4.** In namespace `shop`, create a Service named `partner` so that pods calling `partner.shop` are sent to the external name `partner.example.org` by DNS.

**Task 5.** The company's DNS server runs in the Docker container `ckne-dns` (find its address with `docker inspect ckne-dns`). It answers for the zone `corp.internal`. Configure CoreDNS so that every pod resolves names in `corp.internal` through that server; test with `app.corp.internal.`. Don't change any pod.

**Task 6.** The pods in `shop` that call Service `api` run on the same node as the `api` pod. Configure Service `api` so that traffic from inside the cluster only goes to endpoints on the caller's own node.

## Advanced traffic management

**Task 7.** Create an HTTPRoute named `versions` in namespace `shop`, attached to Gateway `shop-gw`, for host `versions.ckne.test`. Requests with the header `x-version: v2` go to Service `web-v2`; all other requests go to Service `web` (both port 80).

**Task 8.** The LoadBalancer Service `edge` in namespace `shop` has an address, but nothing outside the cluster can reach it: from the container `ckne-ext`, `curl http://<address>/hostname` times out. Make it reachable with Cilium **L2 announcements**, from the worker nodes only, on interface `eth0`. (L2 announcements are already enabled in this cluster.)

**Task 9.** Create an HTTPRoute named `env` in namespace `shop`, attached to `shop-gw`, for host `env.ckne.test`, that sends requests to Service `web` (port 80) with the request header `X-Env: prod` added by the Gateway.

## Network security and policy

**Task 10.** In namespace `shop`, pods labelled `app=client` may send only `GET /public` requests to the `api` pods on port 8080. Any other request from them, such as `GET /hostname`, must be refused with HTTP 403. Name the policy `api-l7`.

**Task 11.** In namespace `out`, the pod `fetcher` may reach only the cluster DNS (port 53) and the partner machine in the container `ckne-ext`. All other egress, including to other pods, must be blocked. Name the policy `fetcher-egress`.

**Task 12.** Pod traffic between nodes must be encrypted. Turn on Cilium's transparent encryption with **WireGuard** on every node. Existing applications must keep working.

**Task 13.** Namespace `pay` is already in the Istio ambient mesh. Make the `payments` workload accept **only mutual TLS**: the `checkout` pod (in the mesh) must still reach it, and plain-text callers from outside the mesh, such as the pod `legacy` in `shop`, must be refused.

## Observability

**Task 14.** Turn on Envoy access logs for the whole mesh with the Istio Telemetry API.

**Task 15.** The team wants to test a new policy for the `secrets` pod in namespace `vault` without breaking it. Put **only that pod's endpoint** into Cilium policy audit mode.
