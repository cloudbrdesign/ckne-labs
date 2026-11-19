# Lab 4.3: Node and pod encryption: WireGuard, proven with tcpdump

Lab for the course lesson **4.3 Node and pod encryption: WireGuard, proven with tcpdump**. It creates a fresh kind cluster named `ckne` with Cilium, without encryption at first: the lab switches on WireGuard half-way. It runs a client and a server on different nodes and a tcpdump pod on the server's node network, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m04/4.3-wireguard
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. A client on ckne-worker calls a server on ckne-worker2; encryption is off
2. On the wire: tcpdump on ckne-worker2's eth0 sees the request in clear text
3. Turn on WireGuard: every node gets a key pair and a tunnel to every other node
4. On the wire again: only WireGuard packets (UDP 51871), no clear text
5. Inside the tunnel: cilium_wg0 sees the traffic before it's encrypted

## What the check looks for

- every Cilium agent reports WireGuard with 2 peers
- ckne-worker and ckne-worker2 have a cilium_wg0 device
- the request's text is not visible on ckne-worker2's eth0
- the client still reaches the server

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (271 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (232 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 107, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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
  --set gatewayAPI.enabled=true --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

A server pinned to ckne-worker2, a client on ckne-worker, and a netshoot pod on ckne-worker2's own network for tcpdump.

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
kubectl run client --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000
kubectl run tcpdump --image=nicolaka/netshoot:v0.13 --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 36000
kubectl rollout status deploy/server --timeout=120s
kubectl wait --for=condition=Ready pod/client pod/tcpdump --timeout=180s
```

### 1. A client on ckne-worker calls a server on ckne-worker2; encryption is off

Client and server on different nodes; encryption is off.

```bash
kubectl get pods -o wide
kubectl exec client -- wget -qO- http://server:8080/echo?msg=card-4111-1111; echo
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption
```

Our output:

```text
$ kubectl get pods -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
client                    1/1     Running   0          20s   10.0.0.5     ckne-worker    <none>           <none>
server-7d595f9dd8-fhshd   1/1     Running   0          20s   10.0.1.89    ckne-worker2   <none>           <none>
tcpdump                   1/1     Running   0          20s   172.18.0.4   ckne-worker2   <none>           <none>
$ kubectl exec client -- wget -qO- http://server:8080/echo?msg=card-4111-1111; echo
card-4111-1111
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption
Encryption:              Disabled
```

**What to look for:** server on ckne-worker2, client on ckne-worker, and `Encryption: Disabled`.

### 2. On the wire: tcpdump on ckne-worker2's eth0 sees the request in clear text

Capture on ckne-worker2's eth0 (VXLAN, UDP 8472) while the client sends three requests.

```bash
kubectl exec tcpdump -- timeout 8 tcpdump -ni eth0 -A -s0 'udp port 8472 or udp port 51871' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
```

Our output:

```text
Between nodes, Cilium wraps pod traffic in VXLAN (UDP 8472). The tcpdump pod uses the node's own network.
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni eth0 -A -s0 'udp port 8472 or udp port 51871' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
IP 10.0.0.5.47358 > 10.0.1.89.8080: Flags [P.], seq 1:98, ack 1, win 64, options [nop,nop,TS val 1155229550 ecr 24129503
D.gn...{GET /echo?msg=card-4111-1111 HTTP/1.1
packets captured: 43   lines containing "card-4111-1111": 9
```

**What to look for:** the card number in the captured packets, in clear text.

### 3. Turn on WireGuard: every node gets a key pair and a tunnel to every other node

Two Helm values, then restart the agents and check the status: peers = nodes - 1.

```bash
helm upgrade cilium cilium/cilium --version 1.20.5 -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard --wait
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
# wait until a capture on the wire has no clear text left (on our Ubuntu box: 29 s)
until ! (kubectl exec tcpdump -- timeout 8 tcpdump -ni eth0 -A -s0 'udp port 8472' 2>/dev/null & sleep 2; kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; wait) | grep -q card-4111-1111; do sleep 2; done
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg status | grep -o 'Wireguard.*Peers: [0-9]*' | sed 's/(Pubkey.*Port/(Port/'; done
kubectl get ciliumnode ckne-worker2 -o jsonpath='{.metadata.annotations.network\.cilium\.io/wg-pub-key}'; echo
docker exec ckne-worker2 ip -br link show cilium_wg0
```

Our output:

```text
$ helm upgrade cilium cilium/cilium --version 1.20.5 -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard --wait
$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
Every agent has its tunnels. The lab then re-tested quietly until no clear text was left on the wire: 29 s.
$ for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg status | grep -o 'Wireguard.*Peers: [0-9]*' | sed 's/(Pubkey.*Port/(Port/'; done
Wireguard       [NodeEncryption: Disabled, cilium_wg0 (Port: 51871, Peers: 2
Wireguard       [NodeEncryption: Disabled, cilium_wg0 (Port: 51871, Peers: 2
Wireguard       [NodeEncryption: Disabled, cilium_wg0 (Port: 51871, Peers: 2
$ kubectl get ciliumnode ckne-worker2 -o jsonpath='{.metadata.annotations.network\.cilium\.io/wg-pub-key}'; echo
punbDJvkJFJ8ZEBHOOBTypzQet2MPgqrGArBGfgWBGQ=
$ docker exec ckne-worker2 ip -br link show cilium_wg0
cilium_wg0       UNKNOWN        <POINTOPOINT,NOARP,UP,LOWER_UP>
```

**What to look for:** `Peers: 2` on all three agents, the node's public key, and a `cilium_wg0` device. Agents reporting their peers isn't the end of it: on our Ubuntu box the client's node still sent clear text for about 29 seconds, which is why the `until` loop waits for a clean capture.

### 4. On the wire again: only WireGuard packets (UDP 51871), no clear text

The same capture on eth0.

```bash
kubectl exec tcpdump -- timeout 8 tcpdump -ni eth0 -A -s0 'udp port 8472 or udp port 51871' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
kubectl exec client -- wget -qO- http://server:8080/echo?msg=card-4111-1111; echo
```

Our output:

```text
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni eth0 -A -s0 'udp port 8472 or udp port 51871' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
11:27:59.698483 IP 172.18.0.3.51871 > 172.18.0.4.51871: UDP, length 160
11:27:59.698535 IP 172.18.0.3.51871 > 172.18.0.4.51871: UDP, length 160
packets captured: 43   lines containing "card-4111-1111": 0
$ kubectl exec client -- wget -qO- http://server:8080/echo?msg=card-4111-1111; echo
card-4111-1111
The app still works and nothing in it changed: the encryption is transparent.
```

**What to look for:** only UDP 51871 packets, zero lines with the card number, and the app still answers.

### 5. Inside the tunnel: cilium_wg0 sees the traffic before it's encrypted

Capture on the cilium_wg0 device itself: the traffic before encryption.

```bash
kubectl exec tcpdump -- timeout 8 tcpdump -ni cilium_wg0 -A -s0 'udp port 8472 or tcp port 8080' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
```

Our output:

```text
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni cilium_wg0 -A -s0 'udp port 8472 or tcp port 8080' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=card-4111-1111' >/dev/null; done; wait
grep -m2 'card-4111-1111' cap.txt | cut -c1-120; echo "packets captured: $(grep -c ' IP ' cap.txt)   lines containing \"card-4111-1111\": $(grep -c card-4111-1111 cap.txt)"
IP 10.0.0.5.51838 > 10.0.1.89.8080: Flags [P.], seq 1:98, ack 1, win 63, options [nop,nop,TS val 751196221 ecr 201409900
packets captured: 43   lines containing "card-4111-1111": 9
Anyone with root on a node can still read the traffic there. WireGuard protects it between nodes, on the wire.
```

**What to look for:** the card number again: WireGuard protects the wire, not the node.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for WireGuard with 2 peers, cilium_wg0 on both workers, no clear text on eth0, and a working app.

```bash
bash lab.sh check
```

Our output:

```text
PASS  every Cilium agent reports WireGuard with 2 peers
PASS  ckne-worker and ckne-worker2 have a cilium_wg0 device
PASS  the request's text is not visible on ckne-worker2's eth0
PASS  the client still reaches the server
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
