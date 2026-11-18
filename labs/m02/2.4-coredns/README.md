# Lab 2.4: Customising CoreDNS: stub domains and forwarders

Lab for the course lesson **2.4 Customising CoreDNS: stub domains and forwarders**. It creates a fresh 3-node kind cluster named `ckne` (kind's default network plugin (kindnet) and kube-proxy in iptables mode), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m02/2.4-coredns
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. Before: the cluster's DNS doesn't know corp.example
2. CoreDNS's config: the Corefile in ConfigMap coredns
3. Add a stub domain: send corp.example to the corp DNS server
4. After: the name resolves through the cluster's DNS, and cluster names still work
5. Forwarders: everything else goes upstream (the forward line in the default block)

## What the check looks for

- ConfigMap coredns has a corp.example server block
- pod client resolves app.corp.example to 10.10.10.42 through cluster DNS
- cluster names still resolve

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (140 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (110 s).

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

A stand-in for a company DNS server: its own CoreDNS in namespace corp-dns, answering for corp.example only. And a client pod.

```bash
kubectl create ns corp-dns
IMG=$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}')
cat <<EOF | kubectl -n corp-dns apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: corp-dns}
data:
  Corefile: |
    corp.example:53 {
        hosts {
            10.10.10.42 app.corp.example
        }
        log
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: corp-dns}
spec:
  selector: {matchLabels: {app: corp-dns}}
  template:
    metadata: {labels: {app: corp-dns}}
    spec:
      containers:
      - name: coredns
        image: $IMG
        args: ["-conf", "/etc/coredns/Corefile"]
        volumeMounts: [{name: cfg, mountPath: /etc/coredns}]
      volumes: [{name: cfg, configMap: {name: corp-dns}}]
---
apiVersion: v1
kind: Service
metadata: {name: corp-dns}
spec:
  selector: {app: corp-dns}
  ports: [{name: dns, port: 53, protocol: UDP}, {name: dns-tcp, port: 53, protocol: TCP}]
EOF
kubectl run client --image=busybox:1.36.1 -- sleep 3600
kubectl -n corp-dns rollout status deploy/corp-dns --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
```

### 1. Before: the cluster's DNS doesn't know corp.example

The cluster's DNS forwards corp.example upstream, where nobody knows it. The corp DNS server does.

```bash
kubectl exec client -- nslookup -timeout=2 app.corp.example
kubectl -n corp-dns get svc corp-dns
kubectl exec client -- nslookup app.corp.example $(kubectl -n corp-dns get svc corp-dns -o jsonpath='{.spec.clusterIP}')
```

Our output:

```text
$ kubectl exec client -- nslookup -timeout=2 app.corp.example
Server:		10.96.0.10
Address:	10.96.0.10:53
** server can't find app.corp.example: NXDOMAIN
** server can't find app.corp.example: NXDOMAIN
command terminated with exit code 1
$ kubectl -n corp-dns get svc corp-dns
NAME       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)         AGE
corp-dns   ClusterIP   10.96.196.82   <none>        53/UDP,53/TCP   2s
$ kubectl exec client -- nslookup app.corp.example $(kubectl -n corp-dns get svc corp-dns -o jsonpath='{.spec.clusterIP}')
Server:		10.96.196.82
Address:	10.96.196.82:53
Name:	app.corp.example
Address: 10.10.10.42
```

**What to look for:** `NXDOMAIN` through the cluster DNS, `10.10.10.42` when you ask the corp server directly.

### 2. CoreDNS's config: the Corefile in ConfigMap coredns

The Corefile lives in ConfigMap coredns in kube-system.

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

Our output:

```text
$ kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

**What to look for:** one `.:53` block with `kubernetes`, `forward . /etc/resolv.conf`, `cache`, `loop` and `reload`.

### 3. Add a stub domain: send corp.example to the corp DNS server

Append a server block for corp.example that forwards to the corp server. In the exam you'd use `kubectl -n kube-system edit cm coredns`; here we script it.

```bash
CORP=$(kubectl -n corp-dns get svc corp-dns -o jsonpath='{.spec.clusterIP}')
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > Corefile
printf 'corp.example:53 {\n    errors\n    cache 30\n    forward . %s\n}\n' "$CORP" >> Corefile
kubectl -n kube-system create cm coredns --from-file=Corefile=Corefile --dry-run=client -o yaml | kubectl replace -f -
# wait until every CoreDNS pod answers (reload runs on each pod's own timer; allow up to 2 minutes)
for ip in $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do kubectl exec client -- nslookup app.corp.example $ip; done
```

Our output:

```text
We add this server block to the Corefile (in the exam: kubectl -n kube-system edit cm coredns):
corp.example:53 {
    errors
    cache 30
    forward . 10.96.196.82
}
$ kubectl -n kube-system create cm coredns --from-file=Corefile=Corefile --dry-run=client -o yaml | kubectl replace -f -
configmap/coredns replaced
The reload plugin picks up the change by itself; each CoreDNS pod reloads on its own timer. Waiting until every CoreDNS pod answers ...
all CoreDNS pods answered after about 84 s
```

**What to look for:** `configmap/coredns replaced`. Then repeat the last line until both CoreDNS pods answer `10.10.10.42`; in our run that took about a minute.

### 4. After: the name resolves through the cluster's DNS, and cluster names still work

The name now resolves through the cluster's own DNS, cluster names still work, and the corp server logs the forwarded queries.

```bash
kubectl exec client -- nslookup app.corp.example
kubectl exec client -- nslookup kubernetes.default.svc.cluster.local
kubectl -n corp-dns logs deploy/corp-dns | grep app.corp.example | tail -2
```

Our output:

```text
$ kubectl exec client -- nslookup app.corp.example
Server:		10.96.0.10
Address:	10.96.0.10:53
Name:	app.corp.example
Address: 10.10.10.42
$ kubectl exec client -- nslookup kubernetes.default.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53
Name:	kubernetes.default.svc.cluster.local
Address: 10.96.0.1
$ kubectl -n corp-dns logs deploy/corp-dns | grep app.corp.example | tail -2
[INFO] 10.244.0.4:45718 - 740 "A IN app.corp.example. udp 34 false 512" NOERROR qr,aa,rd 66 0.000159878s
[INFO] 10.244.0.4:43859 - 42047 "AAAA IN app.corp.example. udp 34 false 512" NOERROR qr,aa,rd 34 0.000231363s
```

**What to look for:** `Address: 10.10.10.42` from server `10.96.0.10`, and `NOERROR` lines in the corp server's log, coming from a CoreDNS pod's IP.

### 5. Forwarders: everything else goes upstream (the forward line in the default block)

The default block's `forward` line is the upstream for every other name.

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -n forward
```

Our output:

```text
$ kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -n forward
13:    forward . /etc/resolv.conf {
27:    forward . 10.96.196.82
```

**What to look for:** two forward lines: `/etc/resolv.conf` for everything, and the corp server for corp.example.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the corp.example block, the name resolving through cluster DNS, and cluster names still resolving.

```bash
bash lab.sh check
```

Our output:

```text
PASS  ConfigMap coredns has a corp.example server block
PASS  pod client resolves app.corp.example to 10.10.10.42 through cluster DNS
PASS  cluster names still resolve
3 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
