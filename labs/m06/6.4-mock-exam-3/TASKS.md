# Mock exam 3: tasks

**Time: 2 hours.** Start a timer when `bash lab.sh up` has finished. Fifteen tasks across the five CKNE domains, weighted roughly like the exam. Do them in any order. Some tasks ask for an answer in a file: write it to `answers/tN.txt` in this folder, on one line.

Everything runs on one kind cluster called `ckne` (context `kind-ckne`). In the real exam each task names a host to `ssh` into; here every task runs from your own terminal. The nodes are containers: `docker exec ckne-worker …` takes you onto one. Allowed help, as in the exam: kubernetes.io/docs and blog, docs.cilium.io, istio.io/latest/docs, and `--help`/`kubectl explain`.

When you're done (or the timer ends): `bash lab.sh check`. Each task is PASS or FAIL, graded on what the cluster does. Then compare with the walkthrough video, or run one reference solution with `bash lab.sh step N`.

---

## Core infrastructure and CNI

**Task 1.** Cilium in this cluster sends pod traffic between nodes through a tunnel. Write the tunnel protocol it uses (lowercase, one word) into `answers/t1.txt`.

**Task 2.** Write the MTU of the interface `eth0` inside the pod `probe` in namespace `net` into `answers/t2.txt` (a number only).

## Service networking and DNS

**Task 3.** In namespace `shop`, requests to `http://cart` fail although the `cart` pods are running. Fix the Service `cart` without changing the Deployment.

**Task 4.** In namespace `shop`, make the Service `web` send every request from the same client to the same pod.

**Task 5.** In namespace `net`, create a pod named `resolver` (image `busybox:1.36.1`, command `sleep 36000`) whose DNS settings add the search domain `corp.internal` and use `ndots` 2. Keep the cluster DNS as its name server.

## Advanced traffic management

**Task 6.** On Gateway `shop-gw` in namespace `shop`, every HTTP request for host `secure.ckne.test` must be redirected to the same URL over HTTPS with status code **301**. Name the HTTPRoute `secure-redirect`.

**Task 7.** Create an HTTPRoute named `info` in namespace `shop`, attached to `shop-gw`, for host `info.ckne.test`, that sends requests to Service `web` (port 80) and adds the **response** header `X-Served-By: ckne`.

**Task 8.** Namespace `mesh` is in the Istio ambient mesh, without a waypoint. Deploy a waypoint named `waypoint` in `mesh` that handles traffic for Services, and make the whole namespace use it.

**Task 9.** In namespace `mesh`, requests from inside the mesh to Service `echo` (port 8080) that carry the header `x-user: tester` must go to Service `echo-v2`; all other requests stay on `echo`. Use the Gateway API. Name the route `echo-testers`.

## Network security and policy

**Task 10.** Pods in namespace `bank` must accept traffic only from pods in `bank` itself. Name the policy `same-ns-only`.

**Task 11.** In namespace `mesh`, Service `echo` must accept only `GET` requests; any other method, such as `POST`, must be refused with HTTP 403. Use Istio. Name the policy `echo-get-only`.

**Task 12.** In namespace `bank`, the pod `attacker` must not reach the `web` pods, even though Task 10 allows traffic from inside `bank`. Use a Cilium deny rule; the `frontend` pod must still reach `web`. Name the policy `deny-attacker`.

**Task 13.** In namespace `certs`, create a Certificate named `api-cert` for `api.ckne.test`, stored in the Secret `api-cert`, issued by the ClusterIssuer `ckne-selfsigned`. It must be valid for **30 days** and be renewed **10 days** before it expires.

## Observability

**Task 14.** The pod `bot` in namespace `ops` keeps trying to resolve a name that doesn't exist. Using Hubble, find the name and write it into `answers/t14.txt`.

**Task 15.** Turn on Cilium's Hubble metrics for **DNS**, **drops** and **HTTP** (the `httpV2` metric) on every node, so that each node serves them on port 9965.
