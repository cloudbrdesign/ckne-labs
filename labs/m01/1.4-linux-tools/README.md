# Lab 1.4: Linux tools on a node (ip, iptables, tcpdump)

Lab for the course lesson **1.4 Linux tools on a node**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.4-linux-tools
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. ip: the pod's side and the node's side of its veth pair
2. ip route on the node: how traffic reaches other nodes' pods
3. iptables: kube-proxy's rules for Service b (iptables mode)
4. tcpdump: watch the packets (a debug pod on the node's network, with tcpdump in it)

## What the check looks for

- node ckne-worker routes pod a's IP to a local veth interface
- kube-proxy has an iptables rule for Service default/b
- pod a reaches Service b by name

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (102 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (67 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 022); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It uses kind's default network plugin (kindnet) and kube-proxy in iptables mode.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: false, kubeProxyMode: iptables}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env).

### Set up the lab

Two pods and a Service: pod a on ckne-worker, pod b (a test server) on ckne-worker2, and Service b in front of it.

```bash
kubectl run a --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 3600
kubectl run b --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --labels=app=b --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=8080
kubectl expose pod b --port=80 --target-port=8080
kubectl wait --for=condition=Ready pod/a pod/b --timeout=120s
```

### 1. ip: the pod's side and the node's side of its veth pair

Inside the pod, one interface and a default route. On the node, the route to the pod's IP names the veth it lives behind.

```bash
kubectl exec a -- ip addr show eth0
kubectl exec a -- ip route
A=$(kubectl get pod a -o jsonpath='{.status.podIP}')
docker exec ckne-worker ip route get $A
```

Our output:

```text
$ kubectl exec a -- ip addr show eth0
2: eth0@if3: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue qlen 1000
    link/ether 4a:7f:30:17:ee:2e brd ff:ff:ff:ff:ff:ff
    inet 10.244.1.2/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::487f:30ff:fe17:ee2e/64 scope link
       valid_lft forever preferred_lft forever
$ kubectl exec a -- ip route
default via 10.244.1.1 dev eth0
10.244.1.0/24 via 10.244.1.1 dev eth0  src 10.244.1.2
10.244.1.1 dev eth0 scope link  src 10.244.1.2
pod a is 10.244.1.2; on the node, the route to it points at a veth:
$ docker exec ckne-worker ip route get $A
10.244.1.2 dev veth98bd7e8d src 10.244.1.1 uid 0
    cache
```

**What to look for:** `dev veth…` in the last command: that's the node's end of pod a's veth pair.

### 2. ip route on the node: how traffic reaches other nodes' pods

The node's routing table: one route per other node's pod range.

```bash
docker exec ckne-worker ip route
```

Our output:

```text
$ docker exec ckne-worker ip route
default via 172.18.0.1 dev eth0
10.244.0.0/24 via 172.18.0.4 dev eth0
10.244.1.2 dev veth98bd7e8d scope host
10.244.2.0/24 via 172.18.0.3 dev eth0
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.2
```

**What to look for:** `10.244.x.0/24 via 172.18.0.y` lines for the other nodes, and `scope host` routes to local pods.

### 3. iptables: kube-proxy's rules for Service b (iptables mode)

A ClusterIP is on no interface: kube-proxy programs rules that capture the Service's IP and port and send them to an endpoint. Nodes can carry two iptables back ends, so first find the one with kube-proxy's rules.

```bash
kubectl get svc b -o wide
for b in iptables-nft iptables-legacy; do docker exec ckne-worker $b -t nat -S KUBE-SERVICES >/dev/null 2>&1 && { echo "kube-proxy's rules are in: $b"; break; }; done
docker exec ckne-worker sh -c "iptables-nft -t nat -S KUBE-SERVICES | grep 'default/b'"
docker exec ckne-worker iptables-nft -t nat -S KUBE-SVC-W2ANRT3464REVKG6
```

Our output:

```text
$ kubectl get svc b -o wide
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
b      ClusterIP   10.96.46.146   <none>        80/TCP    8s    app=b
kube-proxy's rules are in: iptables-nft  (iptables v1.8.11 (nf_tables))
$ docker exec ckne-worker sh -c "iptables-nft -t nat -S KUBE-SERVICES | grep 'default/b'"
-A KUBE-SERVICES -d 10.96.46.146/32 -p tcp -m comment --comment "default/b cluster IP" -m tcp --dport 80 -j KUBE-SVC-W2ANRT3464REVKG6
$ docker exec ckne-worker iptables-nft -t nat -S KUBE-SVC-W2ANRT3464REVKG6
-N KUBE-SVC-W2ANRT3464REVKG6
-A KUBE-SVC-W2ANRT3464REVKG6 ! -s 10.244.0.0/16 -d 10.96.46.146/32 -p tcp -m comment --comment "default/b cluster IP" -m tcp --dport 80 -j KUBE-MARK-…
-A KUBE-SVC-W2ANRT3464REVKG6 -m comment --comment "default/b -> 10.244.2.2:8080" -j KUBE-SEP-ZJWLSXNXQA3DAFQA
```

**What to look for:** the Service's IP and port jump to a `KUBE-SVC-…` chain, which jumps to a `KUBE-SEP-…` rule for the pod (`default/b -> 10.244.x.x:8080`). Use the `KUBE-SVC-` name from your own output. If `iptables-nft` shows nothing, try `iptables-legacy`.

### 4. tcpdump: watch the packets (a debug pod on the node's network, with tcpdump in it)

A debug pod on node 2's own network (hostNetwork) runs tcpdump while pod a sends one request to Service b.

```bash
kubectl run tcpdump --image=nicolaka/netshoot:v0.13 --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 600
kubectl wait --for=condition=Ready pod/tcpdump --timeout=120s
( sleep 3; kubectl exec a -- wget -qO- -T 3 http://b/hostname >/dev/null ) &
kubectl exec tcpdump -- timeout 8 tcpdump -ni any -c 6 "tcp port 8080"
```

Our output:

```text
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni any -c 6 "tcp port 8080"
tcpdump: data link type LINUX_SLL2
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on any, link-type LINUX_SLL2 (Linux cooked v2), snapshot length 262144 bytes
04:49:40.842609 eth0  In  IP 10.244.1.2.52118 > 10.244.2.2.8080: Flags [S], seq 1072153996, win 64240, options [mss 1460,sackOK,TS val 2330279001 ecr…
04:49:40.842662 vethe169396a Out IP 10.244.1.2.52118 > 10.244.2.2.8080: Flags [S], seq 1072153996, win 64240, options [mss 1460,sackOK,TS val 2330279…
04:49:40.842682 vethe169396a In  IP 10.244.2.2.8080 > 10.244.1.2.52118: Flags [S.], seq 1086035426, ack 1072153997, win 65160, options [mss 1460,sack…
04:49:40.842692 eth0  Out IP 10.244.2.2.8080 > 10.244.1.2.52118: Flags [S.], seq 1086035426, ack 1072153997, win 65160, options [mss 1460,sackOK,TS v…
04:49:40.842728 eth0  In  IP 10.244.1.2.52118 > 10.244.2.2.8080: Flags [.], ack 1, win 63, options [nop,nop,TS val 2330279001 ecr 3211563631], length…
04:49:40.842731 vethe169396a Out IP 10.244.1.2.52118 > 10.244.2.2.8080: Flags [.], ack 1, win 63, options [nop,nop,TS val 2330279001 ecr 3211563631],…
```

**What to look for:** six packets: the SYN arrives on `eth0` and goes out through b's veth, the SYN-ACK comes back the same way, then the ACK. The destination is already b's pod IP and port 8080: kube-proxy rewrote it on node 1.

### 5. Check your work

Grade the cluster the way an exam task is graded. The check looks for the veth route to pod a, kube-proxy's rule for Service b, and a working request to b by name.

```bash
bash lab.sh check
```

Our output:

```text
6 packets captured
20 packets received by filter
0 packets dropped by kernel
PASS  node ckne-worker routes pod a's IP to a local veth interface
PASS  kube-proxy has an iptables rule for Service default/b
PASS  pod a reaches Service b by name
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
