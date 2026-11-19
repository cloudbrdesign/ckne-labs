#!/usr/bin/env bash
# Lab 3.3: Cross-cluster service discovery and load balancing. Two kind clusters, joined with Cilium Cluster Mesh,
# and one global Service whose backends live in both clusters.
LAB_ID=3.3; LAB_TITLE="Lab 3.3: Cross-cluster service discovery and load balancing (Cilium Cluster Mesh)"; CLUSTER_PROFILE=cilium
KIND_WORKERS=1   # two clusters on one machine: 2 nodes each
CILIUM_EXTRA="--set cluster.name=ckne --set cluster.id=1 --set ipam.operator.clusterPoolIPv4PodCIDRList={10.1.0.0/16}"
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
C2=ckne2; CTX2=kind-ckne2
k2(){ kubectl --context "$CTX2" "$@"; }
lab_down(){ kind delete cluster --name "$C2" >/dev/null 2>&1; }
cpip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1-control-plane"; }
echo_app(){ # kubectl-function cluster-label: the same Deployment and Service in each cluster; pods report which cluster they are in
  "$1" apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      hostname: $2-echo
      containers: [{name: echo, image: $AGNHOST, args: [netexec, --http-port=8080]}]
---
apiVersion: v1
kind: Service
metadata: {name: echo}
spec: {selector: {app: echo}, ports: [{port: 80, targetPort: 8080}]}
Y
}
lab_setup(){
  note "creating the second cluster '$C2' (2 nodes, pod CIDR 10.2.0.0/16) ..."
  kind_config cilium | kind create cluster --name "$C2" --config - --wait 0s >/dev/null || { echo "kind could not create $C2"; exit 1; }
  ( CLUSTER=$C2; CTX=$CTX2; CILIUM_EXTRA="--set cluster.name=$C2 --set cluster.id=2 --set ipam.operator.clusterPoolIPv4PodCIDRList={10.2.0.0/16}"
    k apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
    install_cilium ) || { echo "Cilium install on $C2 failed"; exit 1; }
  k2 wait --for=condition=Ready nodes --all --timeout=5m >/dev/null; k2 -n kube-system rollout status deploy/coredns --timeout=5m >/dev/null
  echo_app k ckne; echo_app k2 ckne2
  k run client --image=busybox:1.36.1 -- sleep 36000 >/dev/null
  k rollout status deploy/echo --timeout=120s >/dev/null; k2 rollout status deploy/echo --timeout=120s >/dev/null
  k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
hits(){ k exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://echo/hostname; echo; done' | sort | uniq -c; }
mesh(){ # helm values that turn on Cluster Mesh in one cluster ($1 = context, $2 = this cluster's NodePort for its mesh API server)
  local ip; ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${1#kind-}-control-plane")
  helm --kube-context "$1" upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --reuse-values -f - --wait --timeout 6m >/dev/null <<V
clustermesh:
  useAPIServer: true
  apiserver:
    service: {type: NodePort, nodePort: $2}
    tls: {auto: {enabled: true, method: helm}, server: {extraIpAddresses: ["$ip"]}}
  config:
    enabled: true
    clusters:
    - {name: ckne,  address: "$(cpip ckne)",  port: 32379}
    - {name: ckne2, address: "$(cpip ckne2)", port: 32380}
V
}
step_1(){ title "Two separate clusters: same app, same Service name, different pod ranges"
  run k get pods -l app=echo -o wide
  runp "kubectl --context $CTX2 get pods -l app=echo -o wide"
  printf '%s$ kubectl exec client -- wget -qO- http://echo/hostname   %s# x20, from cluster ckne\n' "$Y" "$N"
  hits
  note "The client only reaches its own cluster's pods: ckne2's Service is invisible from here."
}
step_2(){ title "Trust: both clusters must use the same certificate authority"
  runp "kubectl --context $CTX2 -n kube-system delete secret cilium-ca"
  runp "kubectl --context $CTX -n kube-system get secret cilium-ca -o yaml | kubectl --context $CTX2 create -f - >/dev/null && echo copied"
}
step_3(){ title "Turn on Cluster Mesh in both clusters and list the members"
  cat <<V
${D}# clustermesh values (each cluster gets its own NodePort: 32379 for ckne, 32380 for ckne2)
clustermesh:
  useAPIServer: true
  apiserver: {service: {type: NodePort, nodePort: 32379}, tls: {auto: {enabled: true, method: helm}}}
  config:
    enabled: true
    clusters:
    - {name: ckne,  address: $(cpip ckne),  port: 32379}
    - {name: ckne2, address: $(cpip ckne2), port: 32380}${N}
V
  printf '%s$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values -f clustermesh.yaml   %s# in each cluster\n' "$Y" "$N"
  mesh "$CTX" 32379 || echo "helm upgrade failed on ckne"; mesh "$CTX2" 32380 || echo "helm upgrade failed on ckne2"
  k -n kube-system rollout restart ds/cilium >/dev/null; k2 -n kube-system rollout restart ds/cilium >/dev/null
  k -n kube-system rollout status ds/cilium --timeout=5m >/dev/null; k2 -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
  local i; for i in $(seq 1 40); do k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -q 'ClusterMesh:.*1/1 remote clusters ready' && break; sleep 3; done
  run k -n kube-system get svc clustermesh-apiserver
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 ClusterMesh"
}
step_4(){ title "A global Service: the same name in both clusters, marked global"
  run k annotate svc echo service.cilium.io/global=true
  runp "kubectl --context $CTX2 annotate svc echo service.cilium.io/global=true"
  local i ip; ip=$(k get svc echo -o jsonpath='{.spec.clusterIP}')   # wait until the remote backends are programmed and answering
  for i in $(seq 1 30); do [ "$(k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A3 "$ip:80/TCP" | grep -c '=> 10.2.')" -ge 2 ] && break; sleep 2; done
  for i in $(seq 1 15); do k exec client -- sh -c 'for j in 1 2 3 4 5 6; do wget -qO- -T 2 http://echo/hostname >/dev/null || exit 1; done' >/dev/null 2>&1 && break; sleep 2; done
  printf '%s$ kubectl exec client -- wget -qO- http://echo/hostname   %s# x20, from cluster ckne\n' "$Y" "$N"
  hits
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A3 \"\$(kubectl get svc echo -o jsonpath='{.spec.clusterIP}'):80/TCP\""
}
step_5(){ title "Prefer local, fail over to remote"
  run k annotate svc echo service.cilium.io/affinity=local
  sleep 5; printf '%s$ kubectl exec client -- wget ... x20%s\n' "$Y" "$N"; hits
  note "Local backends are healthy, so they get every request."
  run k scale deploy echo --replicas=0
  k wait --for=delete pod -l app=echo --timeout=90s >/dev/null 2>&1; sleep 5
  printf '%s$ kubectl exec client -- wget ... x20%s\n' "$Y" "$N"; hits
  note "No local backends left: the same Service name now reaches ckne2."
}
check_1(){ expect "cluster ckne sees 1/1 remote clusters ready" sh -c "kubectl --context $CTX -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -q 'ClusterMesh:.*1/1 remote clusters ready'"; }
check_2(){ expect "Service echo is global in both clusters" sh -c "[ \"\$(kubectl --context $CTX get svc echo -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}')\" = true ] && [ \"\$(kubectl --context $CTX2 get svc echo -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}')\" = true ]"; }
check_3(){ expect "a client in ckne reaches echo pods in ckne2 through the global Service" sh -c "kubectl --context $CTX exec client -- sh -c 'for i in 1 2 3 4 5 6; do wget -qO- -T 2 http://echo/hostname; echo; done' | grep -q '^ckne2-echo'"; }
lab_main "$@"
