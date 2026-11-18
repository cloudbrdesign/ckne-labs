# Lab 2.1: L4 Services: ClusterIP, NodePort, LoadBalancer, ExternalName

Lab for the course lesson **2.1 L4 Services: ClusterIP, NodePort, LoadBalancer, ExternalName**. It creates a fresh 3-node kind cluster named `ckne` (kind's default network plugin (kindnet) and kube-proxy in iptables mode), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.1-services
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. ClusterIP: a stable virtual IP and name, reachable inside the cluster
2. NodePort: the same Service, also open on a port of every node
3. LoadBalancer: asks for an external load balancer; with none installed, it stays pending
4. ExternalName: a DNS alias (CNAME), no proxying and no endpoints
5. Headless (clusterIP: None): DNS returns the pod IPs themselves

## What the check looks for

- Service web is a ClusterIP Service on port 80
- pod client reaches web by name
- web-np answers on a worker node's IP and NodePort
- web-lb is type LoadBalancer and has a NodePort
- web-alias resolves as a CNAME to web.default.svc.cluster.local
- web-headless has no ClusterIP and DNS returns 2 pod IPs

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (68 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (74 s).

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

Two web pods (Kubernetes' test server, which answers `/hostname` with its pod name) and a client pod.

```bash
kubectl create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --replicas=2 -- /agnhost netexec --http-port=8080
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl rollout status deploy/web --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. ClusterIP: a stable virtual IP and name, reachable inside the cluster

The default type: a virtual IP and a DNS name, reachable only from inside the cluster.

```bash
kubectl expose deployment web --name=web --port=80 --target-port=8080
kubectl get svc web -o wide
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl exec client -- wget -qO- -T 3 http://web/hostname; echo
kubectl exec client -- wget -qO- -T 3 http://web.default.svc.cluster.local/hostname; echo
```

Our output:

```text
$ kubectl expose deployment web --name=web --port=80 --target-port=8080
service/web exposed
$ kubectl get svc web -o wide
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.96.107.215   <none>        80/TCP    0s    app=web
$ kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
web-mkb8r   IPv4          8080    10.244.3.2,10.244.1.2   0s
$ kubectl exec client -- wget -qO- -T 3 http://web/hostname; echo
web-5bfd9679bc-pndq4
$ kubectl exec client -- wget -qO- -T 3 http://web.default.svc.cluster.local/hostname; echo
web-5bfd9679bc-pndq4
```

**What to look for:** a ClusterIP from the Service range, an EndpointSlice with both pod IPs on port 8080, and an answer from one of the pods (by short name and by full name).

### 2. NodePort: the same Service, also open on a port of every node

The same Service, also opened on one port of every node. We call it from the control-plane node, which is outside the pod network.

```bash
kubectl expose deployment web --name=web-np --type=NodePort --port=80 --target-port=8080
kubectl get svc web-np
sleep 3
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
```

Our output:

```text
$ kubectl expose deployment web --name=web-np --type=NodePort --port=80 --target-port=8080
service/web-np exposed
$ kubectl get svc web-np
NAME     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-np   NodePort   10.96.227.160   <none>        80:30439/TCP   0s
from outside the pod network (the control-plane node itself), call each worker's IP on port 30439:
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
web-5bfd9679bc-pndq4
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
web-5bfd9679bc-pndq4
```

**What to look for:** `80:3xxxx/TCP` in PORT(S): the second number is the node port (30000-32767 by default). Both workers answer, even the one without the pod that replied.

### 3. LoadBalancer: asks for an external load balancer; with none installed, it stays pending

Asks for an external load balancer. kind has none, so the address stays pending, but the ClusterIP and NodePort still work.

```bash
kubectl expose deployment web --name=web-lb --type=LoadBalancer --port=80 --target-port=8080
sleep 5
kubectl get svc web-lb
docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
```

Our output:

```text
$ kubectl expose deployment web --name=web-lb --type=LoadBalancer --port=80 --target-port=8080
service/web-lb exposed
$ kubectl get svc web-lb
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-lb   LoadBalancer   10.96.110.141   <pending>     80:30095/TCP   5s
EXTERNAL-IP is <pending>: kind has no load-balancer controller (module 3 adds one). It still got a ClusterIP and a NodePort:
$ docker exec ckne-control-plane curl -s -m 3 http://$(kubectl get node ckne-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):$(kubectl get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}')/hostname; echo
web-5bfd9679bc-t7sk5
```

**What to look for:** `EXTERNAL-IP <pending>`, and the NodePort answering anyway: the types are nested. Module 3 adds a load-balancer controller.

### 4. ExternalName: a DNS alias (CNAME), no proxying and no endpoints

A DNS alias: the cluster DNS answers with a CNAME. No proxying, no endpoints.

```bash
kubectl create service externalname web-alias --external-name=web.default.svc.cluster.local
kubectl get svc web-alias
kubectl exec client -- nslookup web-alias.default.svc.cluster.local
```

Our output:

```text
$ kubectl create service externalname web-alias --external-name=web.default.svc.cluster.local
service/web-alias created
$ kubectl get svc web-alias
NAME        TYPE           CLUSTER-IP   EXTERNAL-IP                     PORT(S)   AGE
web-alias   ExternalName   <none>       web.default.svc.cluster.local   <none>    0s
$ kubectl exec client -- nslookup web-alias.default.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53
web-alias.default.svc.cluster.local	canonical name = web.default.svc.cluster.local
Name:	web.default.svc.cluster.local
Address: 10.96.107.215
```

**What to look for:** `canonical name = web.default.svc.cluster.local`, then the address of that name. In real use the target is usually outside the cluster (a managed database, say).

### 5. Headless (clusterIP: None): DNS returns the pod IPs themselves

No ClusterIP at all: DNS returns the pod IPs, and the client chooses.

```bash
kubectl expose deployment web --name=web-headless --cluster-ip=None --port=80 --target-port=8080
kubectl get svc web-headless
kubectl exec client -- nslookup web-headless.default.svc.cluster.local
kubectl get pods -l app=web -o wide
```

Our output:

```text
$ kubectl expose deployment web --name=web-headless --cluster-ip=None --port=80 --target-port=8080
service/web-headless exposed
$ kubectl get svc web-headless
NAME           TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
web-headless   ClusterIP   None         <none>        80/TCP    1s
$ kubectl exec client -- nslookup web-headless.default.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53
Name:	web-headless.default.svc.cluster.local
Address: 10.244.3.2
Name:	web-headless.default.svc.cluster.local
Address: 10.244.1.2
$ kubectl get pods -l app=web -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
web-5bfd9679bc-pndq4   1/1     Running   0          16s   10.244.1.2   ckne-worker    <none>           <none>
web-5bfd9679bc-t7sk5   1/1     Running   0          16s   10.244.3.2   ckne-worker2   <none>           <none>
```

**What to look for:** `CLUSTER-IP None`, and one `Address:` line per pod, matching the pod IPs.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for each Service type and tests it the way a client would use it.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Service web is a ClusterIP Service on port 80
PASS  pod client reaches web by name
PASS  web-np answers on a worker node's IP and NodePort
PASS  web-lb is type LoadBalancer and has a NodePort
PASS  web-alias resolves as a CNAME to web.default.svc.cluster.local
PASS  web-headless has no ClusterIP and DNS returns 2 pod IPs
6 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
