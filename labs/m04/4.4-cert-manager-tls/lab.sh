#!/usr/bin/env bash
# Lab 4.4: TLS for Gateway API with cert-manager. A private CA, a Gateway with an HTTPS listener and one annotation,
# and cert-manager issues, stores and re-issues the certificate the Gateway serves.
LAB_ID=4.4; LAB_TITLE="Lab 4.4: TLS certificates for Gateway API with cert-manager"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
NETSHOOT=nicolaka/netshoot:v0.13
HOST=shop.ckne.test
applyy(){ local y; y=$(cat); printf '%s$ kubectl apply -f %s%s\n' "$Y" "$1" "$N"; printf '%s\n' "$y" | sed 's/^/    /'; printf '%s\n' "$y" | k apply -f - >/dev/null; }
lab_setup(){
  note "installing cert-manager $CERT_MANAGER_VERSION with Gateway API support ..."
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1; helm repo update jetstack >/dev/null
  helm --kube-context "$CTX" upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --set config.gatewayAPI.enabled=true --wait >/dev/null || echo "cert-manager install failed"
  k create deployment echo --image=$AGNHOST -- /agnhost netexec --http-port=8080 >/dev/null
  k expose deployment echo --port=80 --target-port=8080 >/dev/null
  local pre; pre=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.' | cut -d. -f1-2)
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$pre.255.200", stop: "$pre.255.220"}]}
Y
  k run client --image=$NETSHOOT -- sleep 36000 >/dev/null
  k rollout status deploy/echo --timeout=120s >/dev/null
  k wait --for=condition=Ready pod/client --timeout=180s >/dev/null
}
gw(){ k get gateway web -o jsonpath='{.status.addresses[0].value}'; }
serial(){ k get secret shop-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial 2>/dev/null || k exec -i client -- sh -c 'base64 -d | openssl x509 -noout -serial' < <(k get secret shop-tls -o jsonpath='{.data.tls\.crt}'); }
step_1(){ title "A private CA in cert-manager: a self-signed root, then an Issuer that signs with it"
  applyy ca.yaml <<'Y'
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
Y
  k wait --for=condition=Ready certificate/lab-ca --timeout=120s >/dev/null
  k wait --for=condition=Ready issuer/ca-issuer --timeout=120s >/dev/null
  run k get issuers,certificates
}
step_2(){ title "A Gateway with an HTTPS listener and one annotation; cert-manager does the rest"
  applyy gateway.yaml <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  annotations: {cert-manager.io/issuer: ca-issuer}
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    hostname: $HOST
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
  hostnames: [$HOST]
  rules: [{backendRefs: [{name: echo, port: 80}]}]
Y
  local i; for i in $(seq 1 60); do k get certificate shop-tls >/dev/null 2>&1 && break; sleep 2; done
  k wait --for=condition=Ready certificate/shop-tls --timeout=180s >/dev/null
  k wait --for=condition=Programmed gateway/web --timeout=180s >/dev/null
  run k get certificate shop-tls
  run k get secret shop-tls
  run k get gateway web
  note "Nobody wrote a Certificate for the Gateway: cert-manager read the annotation and the listener, created it, and stored the key pair in Secret shop-tls."
}
step_3(){ title "Trust: the client fails without the CA, and succeeds with it"
  runp "kubectl get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d | kubectl exec -i client -- sh -c 'cat > /tmp/ca.crt'"
  runp "kubectl exec client -- curl -sS --resolve $HOST:443:$(gw) https://$HOST/hostname || true"
  runp "kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve $HOST:443:$(gw) https://$HOST/hostname; echo"
}
step_4(){ title "What the Gateway serves: subject, issuer, dates and the name it covers"
  runp "kubectl exec client -- sh -c 'openssl s_client -connect $(gw):443 -servername $HOST </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName'"
  runp "kubectl get certificate shop-tls -o jsonpath='{.status.renewalTime}'; echo"
}
step_5(){ title "Self-healing: delete the Secret, and cert-manager issues a new certificate"
  local before; before=$(serial)
  note "serial before: $before"
  run k delete secret shop-tls
  local i; for i in $(seq 1 60); do k get secret shop-tls >/dev/null 2>&1 && [ "$(serial)" != "$before" ] && break; sleep 2; done
  k wait --for=condition=Ready certificate/shop-tls --timeout=120s >/dev/null
  note "serial after:  $(serial)"
  run k get certificate shop-tls
  sleep 5
  runp "kubectl exec client -- curl -sS --cacert /tmp/ca.crt --resolve $HOST:443:$(gw) https://$HOST/hostname; echo"
}
check_1(){ expect "Issuer ca-issuer is Ready" sh -c "kubectl --context $CTX get issuer ca-issuer -o jsonpath='{.status.conditions[0].status}' | grep -q True"; }
check_2(){ expect "Certificate shop-tls (created from the Gateway) is Ready" sh -c "kubectl --context $CTX get certificate shop-tls -o jsonpath='{.status.conditions[0].status}' | grep -q True"; }
check_3(){ expect "HTTPS to $HOST works with the lab CA" sh -c "kubectl --context $CTX exec client -- curl -sf --cacert /tmp/ca.crt --resolve $HOST:443:$(gw) https://$HOST/hostname"; }
check_4(){ expect "HTTPS to $HOST is refused without the lab CA" sh -c "! kubectl --context $CTX exec client -- curl -sf --resolve $HOST:443:$(gw) https://$HOST/hostname"; }
lab_main "$@"
