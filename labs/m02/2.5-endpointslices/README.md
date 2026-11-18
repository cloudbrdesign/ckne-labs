# Lab 2.5: Endpoint availability: readiness and EndpointSlice conditions

Lab for the course lesson **2.5 Endpoint availability: readiness and EndpointSlice conditions**. It creates a fresh 3-node kind cluster named `ckne` (kind's default network plugin (kindnet) and kube-proxy in iptables mode), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.5-endpointslices
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Pods running, none ready: the Service has endpoints, but none is ready
2. Make two pods ready: only those two get traffic
3. A ready pod fails its probe: it leaves the rotation, but stays in the slice
4. Terminating: a deleted pod is ready=false, but still serving while it shuts down

## What the check looks for

- Service web's EndpointSlice lists the web pods
- at least one endpoint is ready and at least one is not
- every answer through the Service comes from a ready pod

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (73 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (66 s).

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

Three small web servers (busybox httpd answering with their pod name). Each is Ready only once /tmp/ready exists. And a client pod.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - name: httpd
        image: busybox:1.36.1
        command: ["sh", "-c", "mkdir -p /www && hostname > /www/index.html && exec httpd -f -p 8080 -h /www"]
        readinessProbe: {exec: {command: ["cat", "/tmp/ready"]}, periodSeconds: 2}
        lifecycle: {preStop: {exec: {command: ["sleep", "45"]}}}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 8080}]
EOF
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. Pods running, none ready: the Service has endpoints, but none is ready

The pods are Running but their readiness probe fails (no /tmp/ready yet), so no endpoint is ready.

```bash
kubectl get pods -l app=web
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
kubectl exec client -- wget -qO- -T 3 http://web
```

Our output:

```text
$ kubectl get pods -l app=web
NAME                   READY   STATUS    RESTARTS   AGE
web-5db6755b9d-cwtlq   0/1     Running   0          2s
web-5db6755b9d-q28r9   0/1     Running   0          2s
web-5db6755b9d-v5t9h   0/1     Running   0          2s
$ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
web-5db6755b9d-q28r9	10.244.2.2	ready=false serving=false terminating=false
web-5db6755b9d-v5t9h	10.244.1.2	ready=false serving=false terminating=false
web-5db6755b9d-cwtlq	10.244.2.3	ready=false serving=false terminating=false
$ kubectl exec client -- wget -qO- -T 3 http://web
wget: can't connect to remote host (10.96.85.3): Connection refused
command terminated with exit code 1
```

**What to look for:** `0/1` READY, every endpoint `ready=false serving=false`, and the request refused: the Service has nothing to send to.

### 2. Make two pods ready: only those two get traffic

Create the file in two pods; within a probe period they turn Ready.

```bash
PODS=$(kubectl get pods -l app=web -o name --sort-by=.metadata.name | sed 's|pod/||')
kubectl exec $(echo "$PODS" | sed -n 1p) -- touch /tmp/ready
kubectl exec $(echo "$PODS" | sed -n 2p) -- touch /tmp/ready
sleep 6
kubectl get pods -l app=web
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://web; done' | sort | uniq -c
```

Our output:

```text
$ kubectl exec $(echo "$PODS" | sed -n 1p) -- touch /tmp/ready
$ kubectl exec $(echo "$PODS" | sed -n 2p) -- touch /tmp/ready
$ kubectl get pods -l app=web
NAME                   READY   STATUS    RESTARTS   AGE
web-5db6755b9d-cwtlq   1/1     Running   0          10s
web-5db6755b9d-q28r9   1/1     Running   0          10s
web-5db6755b9d-v5t9h   0/1     Running   0          10s
$ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
web-5db6755b9d-q28r9	10.244.2.2	ready=true serving=true terminating=false
web-5db6755b9d-v5t9h	10.244.1.2	ready=false serving=false terminating=false
web-5db6755b9d-cwtlq	10.244.2.3	ready=true serving=true terminating=false
20 requests through the Service, counted by the pod that answered:
      9 web-5db6755b9d-cwtlq
     11 web-5db6755b9d-q28r9
```

**What to look for:** two endpoints `ready=true`, one still `false` but listed, and all 20 requests answered by the two ready pods.

### 3. A ready pod fails its probe: it leaves the rotation, but stays in the slice

Remove the file from a ready pod: it leaves the rotation but stays in the slice.

```bash
P1=$(echo "$PODS" | head -1)
kubectl exec $P1 -- rm /tmp/ready
sleep 6
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://web; done' | sort | uniq -c
kubectl exec $P1 -- touch /tmp/ready
sleep 6
```

Our output:

```text
$ kubectl exec $P1 -- rm /tmp/ready
$ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
web-5db6755b9d-q28r9	10.244.2.2	ready=true serving=true terminating=false
web-5db6755b9d-v5t9h	10.244.1.2	ready=false serving=false terminating=false
web-5db6755b9d-cwtlq	10.244.2.3	ready=false serving=false terminating=false
20 requests:
     20 web-5db6755b9d-q28r9
$ kubectl exec $P1 -- touch /tmp/ready
```

**What to look for:** that pod `ready=false`; requests go only to the one ready pod left.

### 4. Terminating: a deleted pod is ready=false, but still serving while it shuts down

Delete a ready pod. Its preStop hook keeps it alive for 45 s: terminating, not ready, still serving.

```bash
kubectl delete pod $(echo "$PODS" | sed -n 2p) --wait=false
sleep 4
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
kubectl get pods -l app=web
```

Our output:

```text
$ kubectl delete pod $(echo "$PODS" | sed -n 2p) --wait=false
pod "web-5db6755b9d-q28r9" deleted from default namespace
$ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'
web-5db6755b9d-q28r9	10.244.2.2	ready=false serving=true terminating=true
web-5db6755b9d-v5t9h	10.244.1.2	ready=false serving=false terminating=false
web-5db6755b9d-cwtlq	10.244.2.3	ready=true serving=true terminating=false
web-5db6755b9d-mlvxn	10.244.2.4	ready=false serving=false terminating=false
$ kubectl get pods -l app=web
NAME                   READY   STATUS        RESTARTS   AGE
web-5db6755b9d-cwtlq   1/1     Running       0          27s
web-5db6755b9d-mlvxn   0/1     Running       0          4s
web-5db6755b9d-q28r9   1/1     Terminating   0          27s
web-5db6755b9d-v5t9h   0/1     Running       0          27s
```

**What to look for:** `ready=false serving=true terminating=true` for the deleted pod, and a new pod starting (not ready, as it has no /tmp/ready).

### 5. Check your work

Grade the cluster the way an exam task is graded. The check looks for the endpoints, a mix of ready and not-ready, and every answer coming from a ready pod.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Service web's EndpointSlice lists the web pods
PASS  at least one endpoint is ready and at least one is not
PASS  every answer through the Service comes from a ready pod
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
