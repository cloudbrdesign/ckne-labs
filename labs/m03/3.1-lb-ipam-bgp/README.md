# Lab 3.1: LoadBalancer on bare metal: LB IPAM, L2 announcements and BGP

Lab for the course lesson **3.1 LoadBalancer on bare metal: LB IPAM, L2 announcements and BGP**. It creates a fresh kind cluster named `ckne` with Cilium with L2 announcements and the BGP Control Plane switched on. Outside the cluster it starts two plain containers on kind's Docker network: `ckne-outside` (a client on the LAN) and `ckne-frr` (an FRR router, ASN 65001), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m03/3.1-lb-ipam-bgp
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster(s) and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. A LoadBalancer Service on a cluster with no cloud: nobody hands out an address
2. LB IPAM: give Cilium a pool of addresses to hand out
3. An address is not a route: from outside the cluster, nobody answers for it yet
4. L2 announcements: one node answers ARP for the address
5. BGP: a router outside the cluster, ASN 65001
6. Peer the nodes with the router and advertise the Service's address
7. The router now forwards to the Service: its address is reachable through BGP

## What the check looks for

- Service web-l2 has an address from pool lab-pool
- a node holds the L2 announcement lease for web-l2
- a client outside the cluster reaches web-l2 at its LoadBalancer IP
- the BGP router has a route to web-bgp's address
- the router reaches web-bgp through that route

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (194 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (142 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 089, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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
  --set l2announcements.enabled=true --set bgpControlPlane.enabled=true --set k8sClientRateLimit.qps=10 --set k8sClientRateLimit.burst=20 --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

The extra Helm values switch on L2 announcements and the BGP Control Plane; the rate limit is the docs' advice for L2 announcements.

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

A web Deployment, and a plain container `ckne-outside` on kind's Docker network to play a laptop on the LAN.

```bash
kubectl create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --replicas=2 -- /agnhost netexec --http-port=8080
kubectl rollout status deploy/web --timeout=120s
docker run -d --name ckne-outside --network kind busybox:1.36.1 sleep 36000
```

### 1. A LoadBalancer Service on a cluster with no cloud: nobody hands out an address

Ask for a load balancer where nothing provides one.

```bash
kubectl expose deployment web --name web-l2 --type LoadBalancer --port 80 --target-port 8080
kubectl label svc web-l2 exposure=l2
sleep 5
kubectl get svc web-l2
```

Our output:

```text
$ kubectl expose deployment web --name web-l2 --type LoadBalancer --port 80 --target-port 8080
service/web-l2 exposed
$ kubectl get svc web-l2
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
web-l2   LoadBalancer   10.96.59.29   <pending>     80:30693/TCP   5s
EXTERNAL-IP stays <pending>: Kubernetes asks for a load balancer but ships none.
```

**What to look for:** `EXTERNAL-IP <pending>`: Kubernetes asks for a load balancer but ships none.

### 2. LB IPAM: give Cilium a pool of addresses to hand out

Give Cilium a pool of addresses from kind's Docker network. LB IPAM wakes up when the first pool exists.

```bash
PRE=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$PRE.255.200", stop: "$PRE.255.220"}]}
EOF
sleep 5
kubectl get ippools
kubectl get svc web-l2
```

Our output:

```text
$ cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$PRE.255.200", stop: "$PRE.255.220"}]}
EOF
$ kubectl get ippools
NAME       DISABLED   CONFLICTING   IPS AVAILABLE   AGE
lab-pool   false      False         20              3s
$ kubectl get svc web-l2
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)        AGE
web-l2   LoadBalancer   10.96.59.29   172.18.255.200   80:30693/TCP   8s
```

**What to look for:** the pool with 20 addresses available (21 minus the one just used, depending on timing), and `EXTERNAL-IP` set to `….255.200`.

### 3. An address is not a route: from outside the cluster, nobody answers for it yet

Call the address from a container outside the cluster, on the same network as the nodes.

```bash
IP=$(kubectl get svc web-l2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
docker exec ckne-outside wget -qO- -T 3 http://$IP/hostname || echo '(no answer)'
docker exec ckne-outside ip neigh show $IP
```

Our output:

```text
ckne-outside is a plain container on the same Docker network as the nodes, like a laptop on the office LAN.
$ docker exec ckne-outside wget -qO- -T 3 http://$IP/hostname || echo '(no answer)'
wget: download timed out
(no answer)
$ docker exec ckne-outside ip neigh show $IP
172.18.255.200 dev eth0  used 0/0/0 probes 6 FAILED
No MAC address for 172.18.255.200: no node answers ARP for it.
```

**What to look for:** a timeout, and `FAILED` in the neighbour table: no node answers ARP for that address yet.

### 4. L2 announcements: one node answers ARP for the address

A policy that says: answer ARP for Services labelled exposure=l2, on eth0.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: l2-lab}
spec:
  serviceSelector: {matchLabels: {exposure: l2}}
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
EOF
sleep 10
kubectl -n kube-system get lease | grep -E 'NAME|l2announce'
docker exec ckne-outside wget -qO- -T 3 http://$IP/hostname; echo
docker exec ckne-outside ip neigh show $IP
HOLDER=$(kubectl -n kube-system get lease -o name | grep l2announce | head -1 | xargs kubectl -n kube-system get -o jsonpath='{.spec.holderIdentity}')
docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' $HOLDER
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: l2-lab}
spec:
  serviceSelector: {matchLabels: {exposure: l2}}
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
EOF
$ kubectl -n kube-system get lease | grep -E 'NAME|l2announce'
NAME                                   HOLDER                                                                      AGE
cilium-l2announce-default.web-l2       ckne-worker2                                                                0s
$ docker exec ckne-outside wget -qO- -T 3 http://$IP/hostname; echo
web-5bfd9679bc-m8xjn
$ docker exec ckne-outside ip neigh show $IP
172.18.255.200 dev eth0 lladdr ce:f4:3e:70:0d:b5 ref 1 used 0/0/0 probes 6 DELAY
$ docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' $HOLDER
ce:f4:3e:70:0d:b5
The MAC that answered is the lease holder's: that node receives the traffic and load-balances it to a pod.
```

**What to look for:** a lease `cilium-l2announce-default.web-l2` (with a dot in Cilium 1.20) held by one node, a pod name from outside, and the same MAC in the neighbour table as the lease holder's.

### 5. BGP: a router outside the cluster, ASN 65001

Start an FRR router (ASN 65001) that accepts BGP sessions from the nodes, and a second Service for BGP.

```bash
mkdir -p frr && touch frr/vtysh.conf
printf 'zebra=yes\nbgpd=yes\nvtysh_enable=yes\nzebra_options="  -A 127.0.0.1 -s 90000000"\nbgpd_options="   -A 127.0.0.1"\n' > frr/daemons
SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
cat > frr/frr.conf <<EOF
frr defaults traditional
hostname ckne-frr
log stdout
router bgp 65001
 no bgp ebgp-requires-policy
 neighbor CILIUM peer-group
 neighbor CILIUM remote-as 65000
 bgp listen range $SUBNET peer-group CILIUM
!
EOF
docker create --name ckne-frr --network kind --privileged quay.io/frrouting/frr:10.2.1
docker cp frr/. ckne-frr:/etc/frr/ && docker start ckne-frr
kubectl expose deployment web --name web-bgp --type LoadBalancer --port 80 --target-port 8080
kubectl label svc web-bgp exposure=bgp
sleep 5
kubectl get svc web-bgp
```

Our output:

```text
ckne-frr is a router at 172.18.0.6. The nodes (ASN 65000) will open BGP sessions to it.
$ kubectl expose deployment web --name web-bgp --type LoadBalancer --port 80 --target-port 8080
service/web-bgp exposed
$ kubectl get svc web-bgp
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
web-bgp   LoadBalancer   10.96.110.243   172.18.255.201   80:32092/TCP   0s
```

**What to look for:** web-bgp gets the next address from the pool.

### 6. Peer the nodes with the router and advertise the Service's address

Three Cilium objects: who to peer with, how, and which addresses to advertise.

```bash
FRR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-frr)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: lab-bgp}
spec:
  nodeSelector: {matchLabels: {kubernetes.io/os: linux}}
  bgpInstances:
  - name: instance-65000
    localASN: 65000
    peers:
    - {name: frr, peerASN: 65001, peerAddress: "$FRR", peerConfigRef: {name: frr-peer}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: frr-peer}
spec:
  families:
  - {afi: ipv4, safi: unicast, advertisements: {matchLabels: {advertise: bgp}}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata: {name: lb-ips, labels: {advertise: bgp}}
spec:
  advertisements:
  - advertisementType: Service
    service: {addresses: [LoadBalancerIP]}
    selector: {matchLabels: {exposure: bgp}}
EOF
sleep 30
docker exec ckne-frr vtysh -c 'show bgp summary'
docker exec ckne-frr vtysh -c 'show ip route bgp'
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg shell -- bgp/peers
```

Our output:

```text
$ FRR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-frr)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: lab-bgp}
spec:
  nodeSelector: {matchLabels: {kubernetes.io/os: linux}}
  bgpInstances:
  - name: instance-65000
    localASN: 65000
    peers:
    - {name: frr, peerASN: 65001, peerAddress: "$FRR", peerConfigRef: {name: frr-peer}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: frr-peer}
spec:
  families:
  - {afi: ipv4, safi: unicast, advertisements: {matchLabels: {advertise: bgp}}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata: {name: lb-ips, labels: {advertise: bgp}}
spec:
  advertisements:
  - advertisementType: Service
    service: {addresses: [LoadBalancerIP]}
    selector: {matchLabels: {exposure: bgp}}
EOF
$ docker exec ckne-frr vtysh -c 'show bgp summary'
IPv4 Unicast Summary:
BGP router identifier 172.18.0.6, local AS number 65001 VRF default vrf-id 0
BGP table version 2
RIB entries 1, using 128 bytes of memory
Peers 3, using 50 KiB of memory
Peer groups 1, using 64 bytes of memory
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
*172.18.0.2     4      65000         3         2        0    0    0 00:00:01            1        0 N/A
*172.18.0.3     4      65000         3         2        0    0    0 00:00:00            1        0 N/A
*172.18.0.4     4      65000         3         2        0    0    0 00:00:01            1        0 N/A
Total number of neighbors 3
* - dynamic neighbor
3 dynamic neighbor(s), limit 100
$ docker exec ckne-frr vtysh -c 'show ip route bgp'
Codes: K - kernel route, C - connected, L - local, S - static,
       R - RIP, O - OSPF, I - IS-IS, B - BGP, E - EIGRP, N - NHRP,
       T - Table, v - VNC, V - VNC-Direct, A - Babel, F - PBR,
       f - OpenFabric, t - Table-Direct,
       > - selected route, * - FIB route, q - queued, r - rejected, b - backup
       t - trapped, o - offload failure
B>* 172.18.255.201/32 [20/0] via 172.18.0.2, eth0, weight 1, 00:00:00
  *                          via 172.18.0.3, eth0, weight 1, 00:00:00
  *                          via 172.18.0.4, eth0, weight 1, 00:00:00
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg shell -- bgp/peers
Instance         Peer   Session State   Uptime   Family         Received   Accepted   Advertised
instance-65000   frr    established     0s       ipv4-unicast   0          0          1
```

**What to look for:** three dynamic neighbours, one route `…/32` with three next hops (one per node), and `established` on the Cilium side.

### 7. The router now forwards to the Service: its address is reachable through BGP

The router forwards to the address it learned.

```bash
IP2=$(kubectl get svc web-bgp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
docker exec ckne-frr wget -qO- -T 3 http://$IP2/hostname; echo
```

Our output:

```text
$ docker exec ckne-frr wget -qO- -T 3 http://$IP2/hostname; echo
web-5bfd9679bc-cgc4x
web-bgp has no L2 policy: only the router knows where 172.18.255.201 lives, because the nodes told it over BGP.
```

**What to look for:** a pod name. web-bgp has no L2 policy: only the router knows where its address lives.

### 8. Check your work

Grade the cluster the way an exam task is graded. The check looks for an address from the pool, an L2 lease, the outside client's answer, and the router's route and answer.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Service web-l2 has an address from pool lab-pool
PASS  a node holds the L2 announcement lease for web-l2
PASS  a client outside the cluster reaches web-l2 at its LoadBalancer IP
PASS  the BGP router has a route to web-bgp's address
PASS  the router reaches web-bgp through that route
5 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
