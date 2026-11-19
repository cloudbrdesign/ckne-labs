# Lab 4.4: TLS certificates for Gateway API with cert-manager

Lab for the course lesson **4.4 TLS certificates for Gateway API with cert-manager**. It creates a fresh kind cluster named `ckne` with Cilium (Gateway API and LB IPAM) and cert-manager with Gateway API support. It runs an echo app and a client pod with curl and openssl, runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m04/4.4-cert-manager-tls
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster and the lab's containers
```

Prefer to type it yourself? Jump to [the walkthrough](#walkthrough-copy-paste-compare): every command, our output, and what to look for.

## Steps

1. A private CA in cert-manager: a self-signed root, then an Issuer that signs with it
2. A Gateway with an HTTPS listener and one annotation; cert-manager does the rest
3. Trust: the client fails without the CA, and succeeds with it
4. What the Gateway serves: subject, issuer, dates and the name it covers
5. Self-healing: delete the Secret, and cert-manager issues a new certificate

## What the check looks for

- Issuer ca-issuer is Ready
- Certificate shop-tls (created from the Gateway) is Ready
- HTTPS to $HOST works with the lab CA
- HTTPS to $HOST is refused without the lab CA

## Tested

19 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (173 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (200 s).

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

cert-manager with its Gateway API support switched on, an echo app, an address pool for the Gateway, and a client with curl and openssl.

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.21.3 \
  --set crds.enabled=true --set config.gatewayAPI.enabled=true --wait
kubectl create deployment echo --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080
kubectl expose deployment echo --port=80 --target-port=8080
PRE=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$PRE.255.200", stop: "$PRE.255.220"}]}
EOF
kubectl run client --image=nicolaka/netshoot:v0.13 -- sleep 36000
kubectl rollout status deploy/echo --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=180s
```

### 1. A private CA in cert-manager: a self-signed root, then an Issuer that signs with it

A self-signed root certificate, then a CA Issuer that signs with it.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: lab-ca}
spec:
  isCA: true
  commonName: CKNE Lab CA
  secretName: lab-ca
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: selfsigned, kind: Issuer}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: ca-issuer}
spec: {ca: {secretName: lab-ca}}
EOF
kubectl wait --for=condition=Ready certificate/lab-ca issuer/ca-issuer --timeout=120s
kubectl get issuers,certificates
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: lab-ca}
spec:
  isCA: true
  commonName: CKNE Lab CA
  secretName: lab-ca
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: selfsigned, kind: Issuer}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: ca-issuer}
spec: {ca: {secretName: lab-ca}}
EOF
$ kubectl get issuers,certificates
NAME                                READY   AGE
issuer.cert-manager.io/ca-issuer    True    1s
issuer.cert-manager.io/selfsigned   True    1s
NAME                                 READY   SECRET   AGE
certificate.cert-manager.io/lab-ca   True    lab-ca   1s
```

**What to look for:** both Issuers and the lab-ca Certificate `True`.

### 2. A Gateway with an HTTPS listener and one annotation; cert-manager does the rest

One annotation on the Gateway; cert-manager creates the Certificate and fills Secret shop-tls.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  annotations: {cert-manager.io/issuer: ca-issuer}
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    hostname: shop.ckne.test
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs: [{name: shop-tls}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo}
spec:
  parentRefs: [{name: web}]
  hostnames: [shop.ckne.test]
  rules: [{backendRefs: [{name: echo, port: 80}]}]
EOF
sleep 10; kubectl wait --for=condition=Ready certificate/shop-tls --timeout=180s
kubectl wait --for=condition=Programmed gateway/web --timeout=180s
kubectl get certificate shop-tls
kubectl get secret shop-tls
kubectl get gateway web
```

Our output:

```text
$ cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  annotations: {cert-manager.io/issuer: ca-issuer}
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    hostname: shop.ckne.test
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs: [{name: shop-tls}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo}
spec:
  parentRefs: [{name: web}]
  hostnames: [shop.ckne.test]
  rules: [{backendRefs: [{name: echo, port: 80}]}]
EOF
$ kubectl get certificate shop-tls
NAME       READY   SECRET     AGE
shop-tls   True    shop-tls   1s
$ kubectl get secret shop-tls
NAME       TYPE                DATA   AGE
shop-tls   kubernetes.io/tls   3      1s
$ kubectl get gateway web
NAME   CLASS    ADDRESS          PROGRAMMED   AGE
web    cilium   172.18.255.200   True         1s
Nobody wrote a Certificate for the Gateway: cert-manager read the annotation and the listener, created it, and stored the key pair in Secret shop-tls.
```

**What to look for:** Certificate shop-tls `True` (nobody wrote it), a `kubernetes.io/tls` Secret with 3 keys, and the Gateway programmed with an address.

### 3. Trust: the client fails without the CA, and succeeds with it

Copy the CA into the client, then call the Gateway without and with it.

```bash
GW=$(kubectl get gateway web -o jsonpath='{.status.addresses[0].value}')
kubectl get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d | kubectl exec -i client -- sh -c 'cat > /tmp/ca.crt'
kubectl exec client -- curl -sS --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname || true
kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname; echo
```

Our output:

```text
$ kubectl get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d | kubectl exec -i client -- sh -c 'cat > /tmp/ca.crt'
$ kubectl exec client -- curl -sS --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname || true
curl: (60) SSL certificate problem: unable to get local issuer certificate
More details here: https://curl.se/docs/sslcerts.html
curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.
command terminated with exit code 60
$ kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname; echo
echo-568796b5cd-vgzd8
```

**What to look for:** `curl: (60) … unable to get local issuer certificate` without the CA, a pod name with it.

### 4. What the Gateway serves: subject, issuer, dates and the name it covers

Read the certificate the Gateway presents for the name.

```bash
kubectl exec client -- sh -c 'openssl s_client -connect $GW:443 -servername shop.ckne.test </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName'
kubectl get certificate shop-tls -o jsonpath='{.status.renewalTime}'; echo
```

Our output:

```text
$ kubectl exec client -- sh -c 'openssl s_client -connect $GW:443 -servername shop.ckne.test </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName'
subject=
issuer=CN=CKNE Lab CA
notBefore=Nov 19 10:46:56 2026 GMT
notAfter=Feb 17 10:46:56 2027 GMT
X509v3 Subject Alternative Name: critical
    DNS:shop.ckne.test
$ kubectl get certificate shop-tls -o jsonpath='{.status.renewalTime}'; echo
2027-01-18T10:46:56Z
```

**What to look for:** issuer `CN=CKNE Lab CA`, 90 days of validity, the name shop.ckne.test in the SAN, and a renewal time about two-thirds of the way through.

### 5. Self-healing: delete the Secret, and cert-manager issues a new certificate

Delete the Secret and watch cert-manager issue a new certificate.

```bash
kubectl get secret shop-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial
kubectl delete secret shop-tls
sleep 15
kubectl get secret shop-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial
kubectl get certificate shop-tls
kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname; echo
```

Our output:

```text
serial before: serial=24ED72BEB6D4E9807236A55DBF708B30BADE7279
$ kubectl delete secret shop-tls
secret "shop-tls" deleted from default namespace
serial after:  serial=1A319DB761C7FDD15A171DB4C8A070387483800C
$ kubectl get certificate shop-tls
NAME       READY   SECRET     AGE
shop-tls   True    shop-tls   5s
$ kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve shop.ckne.test:443:$GW https://shop.ckne.test/hostname; echo
echo-568796b5cd-vgzd8
```

**What to look for:** a different serial number after the delete, the Certificate `True` again, and HTTPS still working.

### 6. Check your work

Grade the cluster the way an exam task is graded. The check looks for the CA Issuer and the Gateway's Certificate Ready, and HTTPS that works with the CA and fails without it.

```bash
bash lab.sh check
```

Our output:

```text
PASS  Issuer ca-issuer is Ready
PASS  Certificate shop-tls (created from the Gateway) is Ready
PASS  HTTPS to shop.ckne.test works with the lab CA
PASS  HTTPS to shop.ckne.test is refused without the lab CA
4 passed, 0 failed
```

When you're done: `kind delete cluster --name ckne`.
