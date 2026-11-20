# Mock exam 1: tasks

**Time: 2 hours.** Start a timer when `bash lab.sh up` has finished. Fifteen tasks across the five CKNE domains, weighted roughly like the exam. Do them in any order. Some tasks ask for an answer in a file: write it to `answers/tN.txt` in this folder, on one line.

Everything runs on one kind cluster called `ckne` (context `kind-ckne`). In the real exam each task names a host to `ssh` into; here every task runs from your own terminal. Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

When you're done (or the timer ends): `bash lab.sh check`. Each task is PASS or FAIL, graded on what the cluster does. Then compare with the walkthrough video, or run one reference solution with `bash lab.sh step N`.

---

## Core infrastructure and CNI

**Task 1.** Cilium allocates each node its own range of pod addresses. Write the pod CIDR that Cilium allocated to node `ckne-worker2` into `answers/t1.txt` (for example `10.0.9.0/24`).

**Task 2.** Write the file name (name only, no path) of the CNI configuration that Cilium installed on node `ckne-worker` into `answers/t2.txt`. (The nodes are containers: `docker exec ckne-worker …` takes you onto one.)

## Service networking and DNS

**Task 3.** In namespace `shop`, the Service `web` should send traffic to the pods of Deployment `web`, but requests to `http://web.shop` fail. Fix it without changing the Deployment.

**Task 4.** In namespace `shop`, create a Service named `api-np` of type NodePort that exposes the pods of Deployment `api` (container port 8080) on node port **30080** of every node.

**Task 5.** Every pod in the cluster must resolve `legacy.corp.internal` to `10.10.10.10` (test with the fully qualified name `legacy.corp.internal.`). Configure this in CoreDNS. Don't change any pod.

**Task 6.** The Gateway `shop-gw` in namespace `shop` listens for HTTP on port 80. Create an HTTPRoute named `shop` in `shop` so that requests for host `shop.ckne.test` with a path starting with `/api` go to Service `api` (port 8080) **with the `/api` prefix removed** (so `/api/hostname` reaches the app as `/hostname`), and all other requests for that host go to Service `web` (port 80).

## Advanced traffic management

**Task 7.** Create an HTTPRoute named `canary` in namespace `shop`, attached to `shop-gw`, for host `canary.ckne.test`. It must send 80% of requests to Service `web` and 20% to Service `web-v2` (both port 80).

**Task 8.** The LoadBalancer Service `edge` in namespace `shop` has no external address. Create a `CiliumLoadBalancerIPPool` named `edge-pool` with the addresses `X.Y.255.240` to `X.Y.255.250`, where `X.Y` are the first two numbers of the kind Docker network (for example `172.18`), that serves **only** Services labelled `pool=edge`. Make sure `edge` gets its address from this pool.

**Task 9.** A partner server outside the cluster runs in the Docker container `ckne-ext` (find its address with `docker inspect ckne-ext`). Traffic from pods labelled `app=batch` in namespace `shop` to that server must leave the cluster through node `ckne-worker`, using `ckne-worker`'s own IP address as the source. Configure it with Cilium. (Egress gateway is already enabled in this cluster.)

## Network security and policy

**Task 10.** In namespace `bank`, only pods labelled `app=frontend` may connect to the `ledger` pods, and only on TCP port 8080. All other ingress traffic to `ledger` must be blocked. Name the policy `ledger-ingress`.

**Task 11.** In namespace `locked`, a default-deny egress policy already exists. The pod `app` can no longer resolve any name. Allow it to use the cluster DNS (Service `kube-dns` in `kube-system`) on port 53, without allowing any other egress traffic.

**Task 12.** Serve `https://shop.ckne.test` on Gateway `shop-gw` (namespace `shop`), port 443. Use a certificate for `shop.ckne.test` issued by the ClusterIssuer `ckne-ca`, stored in a Secret named `shop-tls` in `shop`. Requests over HTTPS must reach the same backends as Task 6 (the HTTPRoute from Task 6 can stay as it is if it attaches to the whole Gateway). The CA certificate is in `answers/ckne-ca.crt` if you want to test with curl.

**Task 13.** Add namespace `pay` to the Istio **ambient** mesh. Then allow only workloads running as service account `checkout` (namespace `pay`) to call the `payments` pods; calls from any other identity, such as the `refund` pod, must be denied.

## Observability

**Task 14.** Something keeps trying to reach the Service `secrets` in namespace `vault`, and its connections are dropped by a network policy. Using Hubble, find which pod it is and write it as `namespace/pod` into `answers/t14.txt`.

**Task 15.** Configure Cilium's Hubble exporter on every node to write **only dropped flows** to the file `/var/run/cilium/hubble/drops.log`.
