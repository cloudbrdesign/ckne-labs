# Lab 3.3: Cross-cluster service discovery and load balancing (Cilium Cluster Mesh)

Lab for the course lesson **3.3 Cross-cluster service discovery and load balancing (Cilium Cluster Mesh)**. It creates two fresh kind clusters with 2 nodes each (`ckne` with pod range 10.1.0.0/16, `ckne2` with 10.2.0.0/16), each running Cilium; the lab joins them with Cluster Mesh, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m03/3.3-clustermesh
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster(s) and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Two separate clusters: same app, same Service name, different pod ranges
2. Trust: both clusters must use the same certificate authority
3. Turn on Cluster Mesh in both clusters and list the members
4. A global Service: the same name in both clusters, marked global
5. Prefer local, fail over to remote

## What the check looks for

- cluster ckne sees 1/1 remote clusters ready
- Service echo is global in both clusters
- a client in ckne reaches echo pods in ckne2 through the global Service

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (315 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (297 s).

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
nodes: [{role: control-plane}, {role: worker}]
EOF
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm repo add cilium https://helm.cilium.io && helm repo update cilium
helm upgrade --install cilium cilium/cilium --version 1.20.5 -n kube-system \
  --set kubeProxyReplacement=true --set k8sServiceHost=ckne-control-plane --set k8sServicePort=6443 \
  --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true --set hubble.relay.enabled=true \
  --set gatewayAPI.enabled=true \
  --set cluster.name=ckne --set cluster.id=1 --set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.1.0.0/16}' --wait --timeout 8m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

Two clusters on one machine, so 2 nodes each. Each cluster needs a unique name, id and pod range.

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env). (`cni.exclusive=false` leaves room for Multus in lab 1.6.)

### Set up the lab

A second cluster `ckne2`, the echo app in both clusters (pods report their cluster in their hostname), and a client in ckne.

```bash
# the second cluster: same shape, its own name, id and pod range
cat <<'EOF' | kind create cluster --name ckne2 --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: true, kubeProxyMode: none}
nodes: [{role: control-plane}, {role: worker}]
EOF
kubectl --context kind-ckne2 apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm --kube-context kind-ckne2 upgrade --install cilium cilium/cilium --version 1.20.5 -n kube-system \
  --set kubeProxyReplacement=true --set k8sServiceHost=ckne2-control-plane --set k8sServicePort=6443 \
  --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true --set hubble.relay.enabled=true --set gatewayAPI.enabled=true \
  --set cluster.name=ckne2 --set cluster.id=2 --set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.2.0.0/16}' --wait --timeout 8m
kubectl --context kind-ckne2 wait --for=condition=Ready nodes --all --timeout=5m
for c in ckne ckne2; do cat <<EOF | kubectl --context kind-$c apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      hostname: $c-echo
      containers: [{name: echo, image: registry.k8s.io/e2e-test-images/agnhost:2.52, args: [netexec, --http-port=8080]}]
---
apiVersion: v1
kind: Service
metadata: {name: echo}
spec: {selector: {app: echo}, ports: [{port: 80, targetPort: 8080}]}
EOF
done
kubectl run client --image=busybox:1.36.1 -- sleep 36000
kubectl rollout status deploy/echo; kubectl --context kind-ckne2 rollout status deploy/echo; kubectl wait --for=condition=Ready pod/client
```

### 1. Two separate clusters: same app, same Service name, different pod ranges

Same app, same Service name, different pod ranges. A client in ckne sends 20 requests.

```bash
kubectl get pods -l app=echo -o wide
kubectl --context kind-ckne2 get pods -l app=echo -o wide
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
```

Our output:

```text
$ kubectl get pods -l app=echo -o wide
NAME                    READY   STATUS    RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
echo-777dd8d99c-49w7m   1/1     Running   0          5s    10.1.1.189   ckne-worker   <none>           <none>
echo-777dd8d99c-7n5mp   1/1     Running   0          5s    10.1.1.66    ckne-worker   <none>           <none>
$ kubectl --context kind-ckne2 get pods -l app=echo -o wide
NAME                    READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
echo-6b959bb657-69n22   1/1     Running   0          5s    10.2.1.115   ckne2-worker   <none>           <none>
echo-6b959bb657-tql72   1/1     Running   0          5s    10.2.1.198   ckne2-worker   <none>           <none>
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
     20 ckne-echo
The client only reaches its own cluster's pods: ckne2's Service is invisible from here.
```

**What to look for:** pods in 10.1.x.x and 10.2.x.x, and `20 ckne-echo`: the other cluster is invisible.

### 2. Trust: both clusters must use the same certificate authority

Cluster Mesh uses mTLS between clusters; give ckne2 the same CA as ckne before turning the mesh on.

```bash
kubectl --context kind-ckne2 -n kube-system delete secret cilium-ca
kubectl --context kind-ckne -n kube-system get secret cilium-ca -o yaml | kubectl --context kind-ckne2 create -f - >/dev/null && echo copied
```

Our output:

```text
$ kubectl --context kind-ckne2 -n kube-system delete secret cilium-ca
secret "cilium-ca" deleted from kube-system namespace
$ kubectl --context kind-ckne -n kube-system get secret cilium-ca -o yaml | kubectl --context kind-ckne2 create -f - >/dev/null && echo copied
```

**What to look for:** `copied`.

### 3. Turn on Cluster Mesh in both clusters and list the members

In each cluster: a clustermesh API server (NodePort 32379 and 32380, different per cluster as the chart advises) and the list of members.

```bash
CP1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-control-plane); CP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne2-control-plane)
for c in "kind-ckne 32379 $CP1" "kind-ckne2 32380 $CP2"; do set -- $c
cat <<EOF | helm --kube-context $1 upgrade cilium cilium/cilium --version 1.20.5 -n kube-system --reuse-values -f - --wait
clustermesh:
  useAPIServer: true
  apiserver:
    service: {type: NodePort, nodePort: $2}
    tls: {auto: {enabled: true, method: helm}, server: {extraIpAddresses: ["$3"]}}
  config:
    enabled: true
    clusters:
    - {name: ckne,  address: "$CP1", port: 32379}
    - {name: ckne2, address: "$CP2", port: 32380}
EOF
kubectl --context $1 -n kube-system rollout restart ds/cilium; kubectl --context $1 -n kube-system rollout status ds/cilium
done
kubectl -n kube-system get svc clustermesh-apiserver
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 ClusterMesh
```

Our output:

```text
# clustermesh values (each cluster gets its own NodePort: 32379 for ckne, 32380 for ckne2)
clustermesh:
  useAPIServer: true
  apiserver: {service: {type: NodePort, nodePort: 32379}, tls: {auto: {enabled: true, method: helm}}}
  config:
    enabled: true
    clusters:
    - {name: ckne,  address: 172.18.0.3,  port: 32379}
    - {name: ckne2, address: 172.18.0.5, port: 32380}
$ CP1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne-control-plane); CP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ckne2-control-plane)
for c in "kind-ckne 32379 $CP1" "kind-ckne2 32380 $CP2"; do set -- $c
cat <<EOF | helm --kube-context $1 upgrade cilium cilium/cilium --version 1.20.5 -n kube-system --reuse-values -f - --wait
clustermesh:
  useAPIServer: true
  apiserver:
    service: {type: NodePort, nodePort: $2}
    tls: {auto: {enabled: true, method: helm}, server: {extraIpAddresses: ["$3"]}}
  config:
    enabled: true
    clusters:
    - {name: ckne,  address: "$CP1", port: 32379}
    - {name: ckne2, address: "$CP2", port: 32380}
EOF
kubectl --context $1 -n kube-system rollout restart ds/cilium; kubectl --context $1 -n kube-system rollout status ds/cilium
done
$ kubectl -n kube-system get svc clustermesh-apiserver
NAME                    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
clustermesh-apiserver   NodePort   10.96.159.131   <none>        2379:32379/TCP   56s
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 ClusterMesh
ClusterMesh:             1/1 remote clusters ready
IPv4 BIG TCP:            Disabled
IPv6 BIG TCP:            Disabled
```

**What to look for:** `ClusterMesh: 1/1 remote clusters ready`.

### 4. A global Service: the same name in both clusters, marked global

Annotate the Service as global in both clusters.

```bash
kubectl annotate svc echo service.cilium.io/global=true
kubectl --context kind-ckne2 annotate svc echo service.cilium.io/global=true
sleep 10
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A3 "$(kubectl get svc echo -o jsonpath='{.spec.clusterIP}'):80/TCP"
```

Our output:

```text
$ kubectl annotate svc echo service.cilium.io/global=true
service/echo annotated
$ kubectl --context kind-ckne2 annotate svc echo service.cilium.io/global=true
service/echo annotated
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
wget: download timed out
wget: download timed out
      2
      7 ckne-echo
     11 ckne2-echo
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A3 "$(kubectl get svc echo -o jsonpath='{.spec.clusterIP}'):80/TCP"
7    10.96.243.244:80/TCP     ClusterIP      1 => 10.1.1.66:8080/TCP (active)
                                             2 => 10.1.1.189:8080/TCP (active)
                                             3 => 10.2.1.115:8080/TCP (active)
                                             4 => 10.2.1.198:8080/TCP (active)
```

**What to look for:** requests split between ckne-echo and ckne2-echo, and four backends for echo's ClusterIP: two 10.1 and two 10.2. Right after the annotation a request or two may time out while the remote backends are programmed (two did in this run): wait a few seconds and repeat.

### 5. Prefer local, fail over to remote

Affinity local keeps traffic home while local pods exist.

```bash
kubectl annotate svc echo service.cilium.io/affinity=local
sleep 5
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
kubectl scale deploy echo --replicas=0
sleep 15
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
```

Our output:

```text
$ kubectl annotate svc echo service.cilium.io/affinity=local
service/echo annotated
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
     20 ckne-echo
Local backends are healthy, so they get every request.
$ kubectl scale deploy echo --replicas=0
deployment.apps/echo scaled
$ kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c
     20 ckne2-echo
No local backends left: the same Service name now reaches ckne2.
```

**What to look for:** `20 ckne-echo`, then after scaling to zero `20 ckne2-echo`.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the mesh being ready, the global annotation in both clusters, and the client reaching ckne2's pods.

```bash
bash lab.sh check
```

Our output:

```text
PASS  cluster ckne sees 1/1 remote clusters ready
PASS  Service echo is global in both clusters
PASS  a client in ckne reaches echo pods in ckne2 through the global Service
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
