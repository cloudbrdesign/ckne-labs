# Lab 2.2: kube-proxy: iptables and nftables rules, read on a node

Lab for the course lesson **2.2 kube-proxy: iptables and nftables rules, read on a node**. It creates a fresh 3-node kind cluster named `ckne` (kind's default network plugin (kindnet) and kube-proxy in nftables mode), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.2-kube-proxy
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Which mode is kube-proxy in?
2. The service-ips map: ClusterIP + protocol + port -> one chain per Service
3. The Service's chain: DNAT to one endpoint, picked at random (numgen)
4. Scale to 3: kube-proxy rewrites the Service's chain
5. No endpoints at all: the Service is rejected, not silently dropped

## What the check looks for

- kube-proxy runs in nftables mode
- the service-ips map has Service web's ClusterIP
- Service web's chain picks among 3 endpoints
- pod client reaches web by name

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (67 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (67 s).

## Walkthrough: copy, paste, compare

The fourth way to do this lab: run each command yourself, compare with our output, and read what to look for. Outputs are from our real run (Ubuntu 24.04, 18 Nov 2026, job 065); names, IPs and ages will differ on your machine.

### 0. Create the cluster

A fresh 3-node kind cluster called `ckne` (one control plane, two workers). It uses kind's default network plugin (kindnet) and runs kube-proxy in **nftables** mode.

```bash
kind delete cluster --name ckne 2>/dev/null
cat <<'EOF' | kind create cluster --name ckne --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: false, kubeProxyMode: nftables}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl get nodes -o wide
```

`bash lab.sh up` does exactly this. Versions are pinned in [lib/versions.env](../../../lib/versions.env).

### Set up the lab

Two web pods behind Service web, and a client pod.

```bash
kubectl create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --replicas=2 -- /agnhost netexec --http-port=8080
kubectl expose deployment web --port=80 --target-port=8080
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl rollout status deploy/web --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. Which mode is kube-proxy in?

kube-proxy's mode is in its ConfigMap, and it says which proxier it started in its log.

```bash
KP=$(kubectl -n kube-system get pod -l k8s-app=kube-proxy --field-selector spec.nodeName=ckne-worker -o name)
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:'
kubectl -n kube-system logs $KP | grep -i -m2 nftables
```

Our output:

```text
$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:'
mode: nftables
$ kubectl -n kube-system logs $KP | grep -i -m2 nftables
I1118 14:43:23.435407       1 server_linux.go:231] "Using nftables Proxier"
```

**What to look for:** `mode: nftables` and `Using nftables Proxier`. kube-proxy's pod runs on the node's network and has the `nft` tool, so we read the node's rules through it.

### 2. The service-ips map: ClusterIP + protocol + port -> one chain per Service

One nftables map holds every ClusterIP + protocol + port, each pointing at that Service's chain: one lookup instead of a list to walk.

```bash
kubectl get svc web
kubectl -n kube-system exec $KP -- nft list map ip kube-proxy service-ips
```

Our output:

```text
$ kubectl get svc web
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.36.218   <none>        80/TCP    4s
$ kubectl -n kube-system exec $KP -- nft list map ip kube-proxy service-ips
table ip kube-proxy {
	map service-ips {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
		elements = { 10.96.0.10 . tcp . 53 : goto service-NWBZK7IH-kube-system/kube-dns/tcp/dns-tcp,
			     10.96.0.10 . udp . 53 : goto service-FY5PMXPG-kube-system/kube-dns/udp/dns,
			     10.96.36.218 . tcp . 80 : goto service-PFISGYVC-default/web/tcp/,
			     10.96.0.1 . tcp . 443 : goto service-2QRHZV4L-default/kubernetes/tcp/https,
			     10.96.0.10 . tcp . 9153 : goto service-AS2KJYAD-kube-system/kube-dns/tcp/metrics }
	}
}
```

**What to look for:** a line `<web's ClusterIP> . tcp . 80 : goto service-…-default/web/tcp/`, next to kube-dns and the API server's own Service.

### 3. The Service's chain: DNAT to one endpoint, picked at random (numgen)

Inside the chain, one rule rewrites the destination to one of the endpoints, picked at random.

```bash
CHAIN=$(kubectl -n kube-system exec $KP -- nft list map ip kube-proxy service-ips | grep "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}') . tcp . 80" | grep -o 'service-[^ ,]*')
kubectl -n kube-system exec $KP -- nft list chain ip kube-proxy "$CHAIN"
kubectl get endpointslices -l kubernetes.io/service-name=web
```

Our output:

```text
Service web's chain: service-PFISGYVC-default/web/tcp/
$ kubectl -n kube-system exec $KP -- nft list chain ip kube-proxy "$CHAIN"
table ip kube-proxy {
	chain service-PFISGYVC-default/web/tcp/ {
		meta l4proto tcp dnat ip to numgen random mod 2 map { 0 : 10.244.1.2 . 8080, 1 : 10.244.2.2 . 8080 }
	}
}
$ kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
web-fvsfm   IPv4          8080    10.244.2.2,10.244.1.2   5s
```

**What to look for:** `dnat ip to numgen random mod 2 map { 0 : <pod1> . 8080, 1 : <pod2> . 8080 }`: the same two addresses as the EndpointSlice.

### 4. Scale to 3: kube-proxy rewrites the Service's chain

Change the endpoints and kube-proxy rewrites the rule.

```bash
kubectl scale deploy web --replicas=3
kubectl rollout status deploy/web --timeout=120s; sleep 3
kubectl -n kube-system exec $KP -- nft list chain ip kube-proxy "$CHAIN"
```

Our output:

```text
$ kubectl scale deploy web --replicas=3
deployment.apps/web scaled
$ kubectl -n kube-system exec $KP -- nft list chain ip kube-proxy "$CHAIN"
table ip kube-proxy {
	chain service-PFISGYVC-default/web/tcp/ {
		meta l4proto tcp dnat ip to numgen random mod 3 map { 0 : 10.244.1.2 . 8080, 1 : 10.244.2.2 . 8080, 2 : 10.244.2.3 . 8080 }
	}
}
```

**What to look for:** `mod 3` and a third address.

### 5. No endpoints at all: the Service is rejected, not silently dropped

With no endpoints, the Service moves to a map that rejects connections, so clients fail fast.

```bash
kubectl scale deploy web --replicas=0
sleep 5
kubectl -n kube-system exec $KP -- nft list map ip kube-proxy no-endpoint-services | grep "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')"
kubectl exec client -- wget -qO- -T 3 http://web/hostname
kubectl scale deploy web --replicas=3
```

Our output:

```text
$ kubectl scale deploy web --replicas=0
deployment.apps/web scaled
$ kubectl -n kube-system exec $KP -- nft list map ip kube-proxy no-endpoint-services | grep "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')"
		elements = { 10.96.36.218 . tcp . 80 comment "default/web" : goto reject-chain }
$ kubectl exec client -- wget -qO- -T 3 http://web/hostname
wget: can't connect to remote host (10.96.36.218): Connection refused
command terminated with exit code 1
$ kubectl scale deploy web --replicas=3
deployment.apps/web scaled
```

**What to look for:** `goto reject-chain` and `Connection refused` straight away (not a timeout). Scale back to 3 before the check.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for nftables mode, web in the service-ips map, a chain that picks among 3 endpoints, and a working request.

```bash
bash lab.sh check
```

Our output:

```text
PASS  kube-proxy runs in nftables mode
PASS  the service-ips map has Service web's ClusterIP
PASS  Service web's chain picks among 3 endpoints
PASS  pod client reaches web by name
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
