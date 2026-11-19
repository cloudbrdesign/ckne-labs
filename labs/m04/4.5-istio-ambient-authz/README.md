# Lab 4.5: Pod-level authentication and authorisation: Istio ambient mTLS + AuthorizationPolicy

Lab for the course lesson **4.5 Pod-level authentication and authorisation: Istio ambient mTLS + AuthorizationPolicy**. It creates a fresh kind cluster named `ckne` with Cilium plus Istio in ambient mode (istiod, istio-cni, ztunnel) and cert-manager. It creates a `bank` namespace with a ledger service and two clients, a `legacy` namespace outside the mesh, and a tcpdump pod, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m04/4.5-istio-ambient-authz
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Before the mesh: everyone reaches ledger, in clear text
2. Join the mesh: one namespace label, and ztunnel carries the traffic over mTLS
3. PeerAuthentication STRICT: only mTLS is accepted in bank
4. AuthorizationPolicy: only the frontend identity may call ledger
5. How it fails: an HTTP rule that ztunnel can't evaluate denies everyone

## What the check looks for

- namespace bank is in the ambient mesh
- frontend (sa frontend) reaches ledger
- intruder (sa intruder) is denied
- oldapp (outside the mesh) is denied
- frontend's request is not visible in clear text on ckne-worker2

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (274 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (253 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (job 103, Ubuntu 24.04); names, IPs and ages will differ on your machine.

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

`bash lab.sh up` also installs cert-manager (the full lab profile); this lab doesn't use it.

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

Istio in ambient mode, then a `bank` namespace with a ledger service and two clients with their own service accounts, a `legacy` namespace outside the mesh, and a tcpdump pod on ledger's node.

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version 1.30.8 --wait
helm upgrade --install istiod istio/istiod -n istio-system --version 1.30.8 --set profile=ambient --wait
helm upgrade --install istio-cni istio/cni -n istio-system --version 1.30.8 --set profile=ambient --wait
helm upgrade --install ztunnel istio/ztunnel -n istio-system --version 1.30.8 --wait
kubectl create ns bank; kubectl create ns legacy
kubectl -n bank create serviceaccount ledger; kubectl -n bank create serviceaccount frontend; kubectl -n bank create serviceaccount intruder
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: ledger, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  template:
    metadata: {labels: {app: ledger}}
    spec:
      serviceAccountName: ledger
      nodeName: ckne-worker2
      containers: [{name: ledger, image: registry.k8s.io/e2e-test-images/agnhost:2.52, args: [netexec, --http-port=8080]}]
EOF
kubectl -n bank expose deployment ledger --port=8080
kubectl -n bank run frontend --image=busybox:1.36.1 --overrides='{"spec":{"serviceAccountName":"frontend","nodeName":"ckne-worker"}}' -- sleep 36000
kubectl -n bank run intruder --image=busybox:1.36.1 --overrides='{"spec":{"serviceAccountName":"intruder","nodeName":"ckne-worker"}}' -- sleep 36000
kubectl -n legacy run oldapp --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000
kubectl run tcpdump --image=nicolaka/netshoot:v0.13 --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 36000
kubectl -n bank rollout status deploy/ledger --timeout=120s
kubectl -n bank wait --for=condition=Ready pod/frontend pod/intruder --timeout=120s
kubectl -n legacy wait --for=condition=Ready pod/oldapp --timeout=120s
kubectl wait --for=condition=Ready pod/tcpdump --timeout=180s
```

### 1. Before the mesh: everyone reaches ledger, in clear text

Everyone reaches ledger, and tcpdump on ledger's node reads the request.

```bash
kubectl get pods -n bank -o wide
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
kubectl exec tcpdump -- timeout 8 tcpdump -ni any -A -s0 'tcp port 8080 or tcp port 15008' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl -n bank exec frontend -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null; done; wait
echo "packets to port 8080: $(grep -c ' IP .*\.8080: ' cap.txt)   to port 15008 (HBONE): $(grep -c ' IP .*\.15008: ' cap.txt)   lines containing \"acct-0042-balance\": $(grep -c acct-0042-balance cap.txt)"
```

Our output:

```text
$ kubectl get pods -n bank -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
frontend                 1/1     Running   0          13s   10.0.0.60    ckne-worker    <none>           <none>
intruder                 1/1     Running   0          13s   10.0.0.205   ckne-worker    <none>           <none>
ledger-5b56445b8-tl4cn   1/1     Running   0          13s   10.0.2.144   ckne-worker2   <none>           <none>
CLIENT           -> ledger.bank:8080
bank/frontend    allowed
bank/intruder    allowed
legacy/oldapp    allowed
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni any -A -s0 'tcp port 8080 or tcp port 15008' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl -n bank exec frontend -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null; done; wait
echo "packets to port 8080: $(grep -c ' IP .*\.8080: ' cap.txt)   to port 15008 (HBONE): $(grep -c ' IP .*\.15008: ' cap.txt)   lines containing \"acct-0042-balance\": $(grep -c acct-0042-balance cap.txt)"
10:50:51.723384 cilium_vxlan P   IP 10.0.0.60.55140 > 10.0.2.144.8080: Flags [P.], seq 1:106, ack 1, win 64, o
packets to port 8080: 36   to port 15008 (HBONE): 0   lines containing "acct-0042-balance": 18
```

**What to look for:** all three `allowed`, and the account number in clear text on port 8080.

### 2. Join the mesh: one namespace label, and ztunnel carries the traffic over mTLS

One namespace label; ztunnel now carries bank's traffic over mTLS (HBONE, port 15008).

```bash
kubectl label namespace bank istio.io/dataplane-mode=ambient
sleep 8
kubectl exec tcpdump -- timeout 8 tcpdump -ni any -A -s0 'tcp port 8080 or tcp port 15008' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl -n bank exec frontend -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null; done; wait
echo "packets to port 8080: $(grep -c ' IP .*\.8080: ' cap.txt)   to port 15008 (HBONE): $(grep -c ' IP .*\.15008: ' cap.txt)   lines containing \"acct-0042-balance\": $(grep -c acct-0042-balance cap.txt)"
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=ckne-worker2 -o name)
kubectl -n istio-system logs $ZT --since=2m | grep 'connection complete' | grep -o 'src.identity="[^"]*"\|dst.identity="[^"]*"' | sort -u
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
```

Our output:

```text
$ kubectl label namespace bank istio.io/dataplane-mode=ambient
namespace/bank labeled
$ kubectl exec tcpdump -- timeout 8 tcpdump -ni any -A -s0 'tcp port 8080 or tcp port 15008' > cap.txt 2>/dev/null &
sleep 2; for i in 1 2 3; do kubectl -n bank exec frontend -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null; done; wait
echo "packets to port 8080: $(grep -c ' IP .*\.8080: ' cap.txt)   to port 15008 (HBONE): $(grep -c ' IP .*\.15008: ' cap.txt)   lines containing \"acct-0042-balance\": $(grep -c acct-0042-balance cap.txt)"
10:51:07.980498 cilium_vxlan P   IP 10.0.0.60.37120 > 10.0.2.144.15008: Flags [S], seq 3488603645, win 64860,
10:51:07.980531 lxc34c7c4064585 Out IP 10.0.0.60.37120 > 10.0.2.144.15008: Flags [S], seq 3488603645, win 6486
packets to port 8080: 0   to port 15008 (HBONE): 38   lines containing "acct-0042-balance": 0
$ kubectl -n istio-system logs $ZT --since=2m | grep 'connection complete' | grep -o 'src.identity="[^"]*"\|dst.identity="[^"]*"' | sort -u
dst.identity="spiffe://cluster.local/ns/bank/sa/ledger"
src.identity="spiffe://cluster.local/ns/bank/sa/frontend"
CLIENT           -> ledger.bank:8080
bank/frontend    allowed
bank/intruder    allowed
legacy/oldapp    allowed
Every pod in bank now has an identity (its service account) and talks over mTLS. The default is PERMISSIVE: plain text from outside the mesh still ge…
```

**What to look for:** 0 packets on 8080, packets on 15008, no account number; the frontend and ledger identities in ztunnel's log; everyone still allowed (PERMISSIVE).

### 3. PeerAuthentication STRICT: only mTLS is accepted in bank

Only mTLS is accepted in bank.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: bank}
spec:
  mtls: {mode: STRICT}
EOF
sleep 5
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: bank}
spec:
  mtls: {mode: STRICT}
EOF
CLIENT           -> ledger.bank:8080
bank/frontend    allowed
bank/intruder    allowed
legacy/oldapp    denied
oldapp is outside the mesh: it can't present an identity, so ledger's ztunnel refuses it.
```

**What to look for:** oldapp (outside the mesh) denied.

### 4. AuthorizationPolicy: only the frontend identity may call ledger

Only the frontend's service account may call ledger.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
EOF
sleep 5
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
EOF
CLIENT           -> ledger.bank:8080
bank/frontend    allowed
bank/intruder    denied
legacy/oldapp    denied
Same namespace, same network, but intruder runs as a different service account, so it's denied.
```

**What to look for:** intruder denied: same namespace, different identity.

### 5. How it fails: an HTTP rule that ztunnel can't evaluate denies everyone

Add an HTTP method to the rule: ztunnel can't evaluate it. Then put the L4-only policy back.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
    to:
    - operation: {methods: [GET]}
EOF
sleep 5
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
EOF
sleep 5
for c in bank/frontend bank/intruder legacy/oldapp; do echo "$c $(kubectl -n ${c%/*} exec ${c#*/} -- wget -qO- -T 3 'http://ledger.bank:8080/echo?msg=acct-0042-balance' >/dev/null 2>&1 && echo allowed || echo denied)"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
    to:
    - operation: {methods: [GET]}
EOF
CLIENT           -> ledger.bank:8080
bank/frontend    denied
bank/intruder    denied
legacy/oldapp    denied
methods is an L7 attribute. ztunnel works at L4, skips the rule, and an ALLOW policy with no matching rule denies. L7 rules need a waypoint.
$ cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ledger-allow-frontend, namespace: bank}
spec:
  selector: {matchLabels: {app: ledger}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: [cluster.local/ns/bank/sa/frontend]}
EOF
CLIENT           -> ledger.bank:8080
bank/frontend    allowed
bank/intruder    denied
legacy/oldapp    denied
```

**What to look for:** everyone denied with the L7 rule, frontend allowed again after the fix.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for bank in the mesh, frontend allowed, intruder and oldapp denied, and no clear text on the wire.

```bash
bash lab.sh check
```

Our output:

```text
PASS  namespace bank is in the ambient mesh
PASS  frontend (sa frontend) reaches ledger
PASS  intruder (sa intruder) is denied
PASS  oldapp (outside the mesh) is denied
PASS  frontend's request is not visible in clear text on ckne-worker2
5 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
