# Lab 2.6: Troubleshooting Service traffic

Lab for the course lesson **2.6 Troubleshooting Service traffic**. It creates a fresh 3-node kind cluster named `ckne` (kind's default network plugin (kindnet) and kube-proxy in iptables mode), runs the steps below, and then checks the result the way an exam task is graded.

**This lab arrives broken.** Run `bash lab.sh up`, then `bash lab.sh check`, and fix namespace store until every check passes. The steps and the walkthrough below are spoilers.

## Run it

```bash
cd labs/m02/2.6-troubleshoot-services
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Symptoms, one per Service
2. web: endpoints exist, so compare the Service's targetPort with the port the pods listen on
3. Fix web: point targetPort at 8080
4. api: the pods run, but none is Ready, so the Service has no ready endpoints
5. Fix api: probe the port the app actually serves (8080)
6. front: the NodePort answers on one node only. Check externalTrafficPolicy and where the pod runs
7. Fix front: externalTrafficPolicy Cluster (any node forwards to any pod)

## What the check looks for

- client reaches web by name
- client reaches api by name
- front answers on ckne-worker2's NodePort
- front answers on ckne-worker's NodePort

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (69 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (67 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 065); names, IPs and ages will differ on your machine.

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

**Spoiler:** this sets up three broken Services in namespace store. Try `bash lab.sh up` and `bash lab.sh check` first, find the faults yourself, then come back here. The full setup is in [lab.sh](lab.sh) (`lab_setup`); copy the YAML from there if you want to build it by hand.

```bash
bash lab.sh up
```

### 1. Symptoms, one per Service

Start from what users see, one Service at a time.

```bash
kubectl -n store exec client -- wget -qO- -T 3 http://web/hostname
kubectl -n store exec client -- wget -qO- -T 3 http://api/hostname
NP=$(kubectl -n store get svc front -o jsonpath='{.spec.ports[0].nodePort}')
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
```

Our output:

```text
$ kubectl -n store exec client -- wget -qO- -T 3 http://web/hostname
wget: can't connect to remote host (10.96.167.215): Connection refused
command terminated with exit code 1
$ kubectl -n store exec client -- wget -qO- -T 3 http://api/hostname
wget: can't connect to remote host (10.96.176.104): Connection refused
command terminated with exit code 1
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
front-686c677cd9-p9kkf
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
(no answer from ckne-worker2)
```

**What to look for:** web and api both `Connection refused` (same symptom, different causes), and front answering on one node only.

### 2. web: endpoints exist, so compare the Service's targetPort with the port the pods listen on

Endpoints exist, so compare the port the Service sends to with the port the pods listen on.

```bash
kubectl -n store get endpointslices -l kubernetes.io/service-name=web
kubectl -n store get svc web -o jsonpath='{.spec.ports[0].port} -> {.spec.ports[0].targetPort}{"\n"}'
kubectl -n store logs deploy/web | head -3
```

Our output:

```text
$ kubectl -n store get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
web-x9sm2   IPv4          9090    10.244.2.2,10.244.1.2   14s
$ kubectl -n store get svc web -o jsonpath='{.spec.ports[0].port} -> {.spec.ports[0].targetPort}{"\n"}'
80 -> 9090
$ kubectl -n store logs deploy/web | head -3
Found 2 pods, using pod/web-6c5bb8f854-hbqrj
I1118 14:50:52.558364       1 log.go:245] Started HTTP server on port 8080
I1118 14:50:52.559269       1 log.go:245] Started UDP server on port  8081
```

**What to look for:** the slice's port is `9090`, but the app says `Started HTTP server on port 8080`.

### 3. Fix web: point targetPort at 8080

Point targetPort at 8080.

```bash
kubectl -n store patch svc web --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
kubectl -n store exec client -- wget -qO- -T 3 http://web/hostname; echo
```

Our output:

```text
$ kubectl -n store patch svc web --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
service/web patched
$ kubectl -n store exec client -- wget -qO- -T 3 http://web/hostname; echo
web-6c5bb8f854-hbqrj
```

**What to look for:** a pod name.

### 4. api: the pods run, but none is Ready, so the Service has no ready endpoints

The pods run but none is Ready, so no endpoint is ready.

```bash
kubectl -n store get pods -l app=api
kubectl -n store get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
kubectl -n store describe pod -l app=api | grep -m1 'Readiness:'
kubectl -n store get events --field-selector reason=Unhealthy -o custom-columns=POD:.involvedObject.name,MESSAGE:.message | head -3
```

Our output:

```text
$ kubectl -n store get pods -l app=api
NAME                   READY   STATUS    RESTARTS   AGE
api-7686d77cfb-p25sw   0/1     Running   0          14s
api-7686d77cfb-phfqz   0/1     Running   0          14s
$ kubectl -n store get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
10.244.2.3 ready=false
10.244.1.3 ready=false
$ kubectl -n store describe pod -l app=api | grep -m1 'Readiness:'
    Readiness:      http-get http://:8081/healthz delay=0s timeout=1s period=3s successThreshold=1 failureThreshold=3
$ kubectl -n store get events --field-selector reason=Unhealthy -o custom-columns=POD:.involvedObject.name,MESSAGE:.message | head -3
POD                    MESSAGE
api-7686d77cfb-p25sw   Readiness probe failed: Get "http://10.244.2.3:8081/healthz": dial tcp 10.244.2.3:8081: connect: connection refused
api-7686d77cfb-phfqz   Readiness probe failed: Get "http://10.244.1.3:8081/healthz": dial tcp 10.244.1.3:8081: connect: connection refused
```

**What to look for:** `0/1`, `ready=false`, and `Readiness probe failed: … :8081 … connection refused`: the probe checks a port nothing listens on.

### 5. Fix api: probe the port the app actually serves (8080)

Probe the port the app serves.

```bash
kubectl -n store patch deploy api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":8080}]'
kubectl -n store rollout status deploy/api --timeout=120s
kubectl -n store get pods -l app=api
kubectl -n store exec client -- wget -qO- -T 3 http://api/hostname; echo
```

Our output:

```text
$ kubectl -n store patch deploy api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":8080}]'
deployment.apps/api patched
$ kubectl -n store get pods -l app=api
NAME                   READY   STATUS        RESTARTS   AGE
api-65749c4799-65rgx   1/1     Running       0          5s
api-65749c4799-fqtsh   1/1     Running       0          4s
api-7686d77cfb-phfqz   0/1     Terminating   0          20s
$ kubectl -n store exec client -- wget -qO- -T 3 http://api/hostname; echo
api-65749c4799-fqtsh
```

**What to look for:** new pods `1/1`, and an answer.

### 6. front: the NodePort answers on one node only. Check externalTrafficPolicy and where the pod runs

The NodePort answers on one node only: check the traffic policy and where the pod runs.

```bash
kubectl -n store get svc front -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
kubectl -n store get pods -l app=front -o wide
```

Our output:

```text
$ kubectl -n store get svc front -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
Local
$ kubectl -n store get pods -l app=front -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
front-686c677cd9-p9kkf   1/1     Running   0          20s   10.244.1.4   ckne-worker   <none>           <none>
Local means: a node only forwards to pods on itself, and keeps the client's source IP. ckne-worker2 has no front pod.
```

**What to look for:** `Local`, and the only pod on ckne-worker. Local means a node forwards only to pods on itself (and keeps the client's source IP).

### 7. Fix front: externalTrafficPolicy Cluster (any node forwards to any pod)

Use Cluster, so any node forwards to any pod. (Or keep Local and run a pod on every node, if you need the client IP.)

```bash
kubectl -n store patch svc front -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
sleep 2
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
```

Our output:

```text
$ kubectl -n store patch svc front -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
service/front patched
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
front-686c677cd9-p9kkf
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$NP/hostname; echo
front-686c677cd9-p9kkf
```

**What to look for:** both nodes answer.

### 8. Check your work

Grade the cluster the way an exam task is graded. The check looks for web and api answering by name from the client, and front answering on both nodes' NodePort.

```bash
bash lab.sh check
```

Our output:

```text
PASS  client reaches web by name
PASS  client reaches api by name
PASS  front answers on ckne-worker2's NodePort
PASS  front answers on ckne-worker's NodePort
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
