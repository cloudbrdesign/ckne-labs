# Lab 3.2: Egress gateway for cluster exit traffic

Lab for the course lesson **3.2 Egress gateway for cluster exit traffic**. It creates a fresh kind cluster named `ckne` with Cilium with the egress gateway and BPF masquerading switched on. Outside the cluster it starts `ckne-ext`, a server that reports the caller's address, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m03/3.2-egress-gateway
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster(s) and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Who is calling? Today each pod leaves with its own node's address
2. Choose a gateway node: label it
3. A CiliumEgressGatewayPolicy: billing's traffic to the server leaves through the gateway
4. After: both billing pods leave with the gateway's address; reports is untouched
5. How it fails: no node matches the gateway selector

## What the check looks for

- CiliumEgressGatewayPolicy billing-egress exists
- billing-1 (on ckne-worker) reaches the server as the gateway node
- billing-2 (on ckne-worker2) reaches the server as the gateway node
- reports (not selected) still leaves as its own node

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (151 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (146 s).

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
  --set egressGateway.enabled=true --set bpf.masquerade=true --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

Egress gateway needs the kube-proxy replacement and BPF masquerading, as the extra Helm values set.

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

An outside server `ckne-ext` that reports the caller's address, two billing pods on different workers, and a reports pod.

```bash
docker run -d --name ckne-ext --network kind registry.k8s.io/e2e-test-images/agnhost:2.52 netexec --http-port=8080
EXT=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-ext)
kubectl run billing-1 --image=busybox:1.36.1 --labels=app=billing --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000
kubectl run billing-2 --image=busybox:1.36.1 --labels=app=billing --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- sleep 36000
kubectl run reports --image=busybox:1.36.1 --labels=app=reports --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- sleep 36000
kubectl wait --for=condition=Ready pod/billing-1 pod/billing-2 pod/reports --timeout=120s
```

### 1. Who is calling? Today each pod leaves with its own node's address

Each pod leaves the cluster with its own node's address. The outside server reports the source it sees.

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,IP:.status.addresses[0].address
for p in billing-1 billing-2 reports; do echo "$p $(kubectl get pod $p -o jsonpath='{.spec.nodeName}') $(kubectl exec $p -- wget -qO- -T 3 http://$EXT:8080/clientip)"; done
```

Our output:

```text
$ kubectl get nodes -o custom-columns=NODE:.metadata.name,IP:.status.addresses[0].address
NODE                 IP
ckne-control-plane   172.18.0.3
ckne-worker          172.18.0.4
ckne-worker2         172.18.0.2
ckne-ext is at 172.18.0.5, outside the cluster. It answers /clientip with the source address it sees.
$ for p in billing-1 billing-2 reports; do echo "$p $(kubectl get pod $p -o jsonpath='{.spec.nodeName}') $(kubectl exec $p -- wget -qO- -T 3 http://$EXT:8080/clientip)"; done
POD        NODE           SOURCE SEEN BY ckne-ext
billing-1  ckne-worker    172.18.0.4
billing-2  ckne-worker2   172.18.0.2
reports    ckne-worker2   172.18.0.2
billing-1 and billing-2 are the same app, but the outside world sees two different addresses. Scale or reschedule, and it changes again.
```

**What to look for:** billing-1 and billing-2 seen as two different node addresses.

### 2. Choose a gateway node: label it

Label the node whose address the outside world should see.

```bash
kubectl label node ckne-worker egress-gateway=true
```

Our output:

```text
$ kubectl label node ckne-worker egress-gateway=true
node/ckne-worker labeled
```

**What to look for:** `node/ckne-worker labeled`.

### 3. A CiliumEgressGatewayPolicy: billing's traffic to the server leaves through the gateway

Pods app=billing, going to the server, leave through the labelled node using its eth0 address.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata: {name: billing-egress}
spec:
  selectors:
  - podSelector: {matchLabels: {app: billing, io.kubernetes.pod.namespace: default}}
  destinationCIDRs: ["$EXT/32"]
  egressGateway:
    nodeSelector: {matchLabels: {egress-gateway: "true"}}
    interface: eth0
EOF
sleep 10
kubectl get ciliumegressgatewaypolicies
```

Our output:

```text
$ cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata: {name: billing-egress}
spec:
  selectors:
  - podSelector: {matchLabels: {app: billing, io.kubernetes.pod.namespace: default}}
  destinationCIDRs: ["$EXT/32"]
  egressGateway:
    nodeSelector: {matchLabels: {egress-gateway: "true"}}
    interface: eth0
EOF
$ kubectl get ciliumegressgatewaypolicies
NAME             AGE
billing-egress   3s
```

**What to look for:** the policy `billing-egress`.

### 4. After: both billing pods leave with the gateway's address; reports is untouched

The same table again.

```bash
for p in billing-1 billing-2 reports; do echo "$p $(kubectl get pod $p -o jsonpath='{.spec.nodeName}') $(kubectl exec $p -- wget -qO- -T 3 http://$EXT:8080/clientip)"; done
```

Our output:

```text
POD        NODE           SOURCE SEEN BY ckne-ext
billing-1  ckne-worker    172.18.0.4
billing-2  ckne-worker2   172.18.0.4
reports    ckne-worker2   172.18.0.2
billing-2 runs on ckne-worker2, yet the server sees ckne-worker (172.18.0.4): its traffic went through the gateway.
```

**What to look for:** both billing pods seen as ckne-worker, even billing-2 on ckne-worker2; reports unchanged.

### 5. How it fails: no node matches the gateway selector

Take the label away, try, and put it back.

```bash
kubectl label node ckne-worker egress-gateway-
sleep 5
kubectl exec billing-2 -- wget -qO- -T 3 http://$EXT:8080/clientip || echo '(dropped)'
kubectl label node ckne-worker egress-gateway=true
sleep 10
kubectl exec billing-2 -- wget -qO- -T 3 http://$EXT:8080/clientip; echo
```

Our output:

```text
$ kubectl label node ckne-worker egress-gateway-
node/ckne-worker unlabeled
$ kubectl exec billing-2 -- wget -qO- -T 3 http://$EXT:8080/clientip || echo '(dropped)'
wget: download timed out
command terminated with exit code 1
(dropped)
With no gateway, Cilium drops the matching traffic instead of letting it out with another address.
$ kubectl label node ckne-worker egress-gateway=true
node/ckne-worker labeled
$ kubectl exec billing-2 -- wget -qO- -T 3 http://$EXT:8080/clientip; echo
172.18.0.4:56562
```

**What to look for:** a timeout while no node matches (Cilium drops matching traffic), then ckne-worker's address again.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the policy, both billing pods seen as the gateway node, and reports seen as its own node.

```bash
bash lab.sh check
```

Our output:

```text
PASS  CiliumEgressGatewayPolicy billing-egress exists
PASS  billing-1 (on ckne-worker) reaches the server as the gateway node
PASS  billing-2 (on ckne-worker2) reaches the server as the gateway node
PASS  reports (not selected) still leaves as its own node
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
