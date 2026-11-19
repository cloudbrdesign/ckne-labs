# Lab 4.2: Default deny, egress and DNS: locking a namespace down

Lab for the course lesson **4.2 Default deny, egress and DNS: locking a namespace down**. It creates a fresh kind cluster named `ckne` with Cilium as the network plugin. It creates a namespace `locked` with one app pod, a web service in `shop`, and two servers outside the cluster on kind's Docker network (`ckne-ext`, `ckne-ext2`), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m04/4.2-default-deny
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Before: the app can reach everything
2. Default deny: one policy selects every pod in the namespace, both directions
3. Allow DNS: egress to CoreDNS on port 53, UDP and TCP
4. Allow the app to call web in namespace shop, on port 8080 only
5. Allow one outside address with ipBlock; everything else outside stays blocked

## What the check looks for

- a default-deny policy selects every pod in locked (Ingress and Egress)
- DNS works from locked/app
- locked/app reaches web.shop:8080
- locked/app reaches the allowed outside server
- locked/app cannot reach any other outside server

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (224 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (198 s).

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

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

Two servers outside the cluster on kind's Docker network, a web service in `shop`, and the app in `locked`.

```bash
docker run -d --name ckne-ext --network kind registry.k8s.io/e2e-test-images/agnhost:2.52 netexec --http-port=8080
docker run -d --name ckne-ext2 --network kind registry.k8s.io/e2e-test-images/agnhost:2.52 netexec --http-port=8080
EXT=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-ext); EXT2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-ext2)
kubectl create ns shop; kubectl create ns locked
kubectl -n shop create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080
kubectl -n shop expose deployment web --port=8080
kubectl -n locked run app --image=busybox:1.36.1 --labels=app=app -- sleep 36000
kubectl -n shop rollout status deploy/web --timeout=120s
kubectl -n locked wait --for=condition=Ready pod/app --timeout=120s
```

### 1. Before: the app can reach everything

The app can reach everything. The loop tests DNS, web.shop, and the two outside servers.

```bash
kubectl get networkpolicy -A
for t in 'timeout 4 nslookup web.shop.svc.cluster.local' 'wget -qO- -T 3 http://web.shop:8080/hostname' "wget -qO- -T 3 http://$EXT:8080/hostname" "wget -qO- -T 3 http://$EXT2:8080/hostname"; do echo "$(kubectl -n locked exec app -- sh -c "$t" >/dev/null 2>&1 && echo ok || echo blocked)  $t"; done
```

Our output:

```text
$ kubectl get networkpolicy -A
No resources found
FROM locked/app                      RESULT
DNS: nslookup web.shop               ok
web.shop:8080                        ok
ckne-ext 172.18.0.5:8080 (outside)   ok
ckne-ext2 172.18.0.6:8080 (outside)  ok
```

**What to look for:** all four `ok`.

### 2. Default deny: one policy selects every pod in the namespace, both directions

One policy, empty podSelector (every pod in locked), both directions, no rules.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
sleep 3
for t in 'timeout 4 nslookup web.shop.svc.cluster.local' 'wget -qO- -T 3 http://web.shop:8080/hostname' "wget -qO- -T 3 http://$EXT:8080/hostname" "wget -qO- -T 3 http://$EXT2:8080/hostname"; do echo "$(kubectl -n locked exec app -- sh -c "$t" >/dev/null 2>&1 && echo ok || echo blocked)  $t"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
FROM locked/app                      RESULT
DNS: nslookup web.shop               blocked
web.shop:8080                        blocked
ckne-ext 172.18.0.5:8080 (outside)   blocked
ckne-ext2 172.18.0.6:8080 (outside)  blocked
Egress deny blocks DNS too, so name lookups fail first. That's the most common surprise with default deny.
```

**What to look for:** everything blocked, starting with the name lookup.

### 3. Allow DNS: egress to CoreDNS on port 53, UDP and TCP

Egress to CoreDNS (namespace kube-system, k8s-app=kube-dns) on port 53, UDP and TCP.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
EOF
sleep 3
for t in 'timeout 4 nslookup web.shop.svc.cluster.local' 'wget -qO- -T 3 http://web.shop:8080/hostname' "wget -qO- -T 3 http://$EXT:8080/hostname" "wget -qO- -T 3 http://$EXT2:8080/hostname"; do echo "$(kubectl -n locked exec app -- sh -c "$t" >/dev/null 2>&1 && echo ok || echo blocked)  $t"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: locked}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
EOF
FROM locked/app                      RESULT
DNS: nslookup web.shop               ok
web.shop:8080                        blocked
ckne-ext 172.18.0.5:8080 (outside)   blocked
ckne-ext2 172.18.0.6:8080 (outside)  blocked
Names resolve again, but the connections are still denied.
```

**What to look for:** DNS `ok`, connections still blocked.

### 4. Allow the app to call web in namespace shop, on port 8080 only

Egress to app=web in namespace shop, port 8080 only.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-web, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: shop}}
      podSelector: {matchLabels: {app: web}}
    ports: [{protocol: TCP, port: 8080}]
EOF
sleep 3
for t in 'timeout 4 nslookup web.shop.svc.cluster.local' 'wget -qO- -T 3 http://web.shop:8080/hostname' "wget -qO- -T 3 http://$EXT:8080/hostname" "wget -qO- -T 3 http://$EXT2:8080/hostname"; do echo "$(kubectl -n locked exec app -- sh -c "$t" >/dev/null 2>&1 && echo ok || echo blocked)  $t"; done
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-web, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: shop}}
      podSelector: {matchLabels: {app: web}}
    ports: [{protocol: TCP, port: 8080}]
EOF
FROM locked/app                      RESULT
DNS: nslookup web.shop               ok
web.shop:8080                        ok
ckne-ext 172.18.0.5:8080 (outside)   blocked
ckne-ext2 172.18.0.6:8080 (outside)  blocked
```

**What to look for:** web.shop `ok`; both outside servers blocked.

### 5. Allow one outside address with ipBlock; everything else outside stays blocked

An ipBlock for one outside server; the other stays blocked.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-ext, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: $EXT/32}}]
    ports: [{protocol: TCP, port: 8080}]
EOF
sleep 3
for t in 'timeout 4 nslookup web.shop.svc.cluster.local' 'wget -qO- -T 3 http://web.shop:8080/hostname' "wget -qO- -T 3 http://$EXT:8080/hostname" "wget -qO- -T 3 http://$EXT2:8080/hostname"; do echo "$(kubectl -n locked exec app -- sh -c "$t" >/dev/null 2>&1 && echo ok || echo blocked)  $t"; done
kubectl -n locked get networkpolicy
```

Our output:

```text
$ cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-ext, namespace: locked}
spec:
  podSelector: {matchLabels: {app: app}}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: $EXT/32}}]
    ports: [{protocol: TCP, port: 8080}]
EOF
FROM locked/app                      RESULT
DNS: nslookup web.shop               ok
web.shop:8080                        ok
ckne-ext 172.18.0.5:8080 (outside)   ok
ckne-ext2 172.18.0.6:8080 (outside)  blocked
$ kubectl -n locked get networkpolicy
NAME           POD-SELECTOR   AGE
allow-dns      <none>         29s
allow-ext      app=app        7s
allow-web      app=app        16s
default-deny   <none>         63s
```

**What to look for:** ckne-ext `ok`, ckne-ext2 `blocked`, and four policies in locked.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the default deny, working DNS, web and the allowed outside server, and the other outside server blocked.

```bash
bash lab.sh check
```

Our output:

```text
PASS  a default-deny policy selects every pod in locked (Ingress and Egress)
PASS  DNS works from locked/app
PASS  locked/app reaches web.shop:8080
PASS  locked/app reaches the allowed outside server
PASS  locked/app cannot reach any other outside server
5 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
