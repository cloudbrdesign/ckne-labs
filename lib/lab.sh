#!/usr/bin/env bash
# Shared lab framework for the CKNE labs. A lab defines:
#   LAB_ID, LAB_TITLE, CLUSTER_PROFILE (plain | nft | nocni | cilium | full)
#   step_1 .. step_N   (each starts with: title "what this step does")
#   check_1 .. check_M (each calls: expect "description" <command...>)
# and ends with:  lab_main "$@"
# Usage of any lab:  bash lab.sh run | step N | steps | check | up | down | reset
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$LIB/versions.env"
CLUSTER="ckne"; CTX="kind-$CLUSTER"
B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
[ -t 1 ] || { B=; G=; R=; Y=; D=; N=; }
k(){ kubectl --context "$CTX" "$@"; }
title(){ printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
note(){ printf '%s%s%s\n' "$D" "$*" "$N"; }
run(){ printf '%s$ %s%s\n' "$Y" "$(printf '%s ' "$@" | sed 's/^k /kubectl /')" "$N"; "$@"; }
runp(){ printf '%s$ %s%s\n' "$Y" "$1" "$N"; eval "${1//kubectl /k }"; }   # a pipeline, shown as typed: runp "kubectl get pods | grep web"
node_sh(){ docker exec "$1" sh -c "$2"; }            # "ssh" into a kind node: node_sh ckne-worker 'ip route'
PASS=0; FAIL=0
expect(){ local what=$1; shift; if "$@" >/dev/null 2>&1; then printf '%sPASS%s  %s\n' "$G" "$N" "$what"; PASS=$((PASS+1)); else printf '%sFAIL%s  %s\n' "$R" "$N" "$what"; FAIL=$((FAIL+1)); fi; }
nsteps(){ declare -F | awk '{print $3}' | grep -c '^step_[0-9]*$'; }
nchecks(){ declare -F | awk '{print $3}' | grep -c '^check_[0-9]*$'; }

need(){ for t in docker kind kubectl helm jq; do command -v "$t" >/dev/null || { echo "missing tool: $t (see lab 0.2)"; exit 1; }; done
        docker info >/dev/null 2>&1 || { echo "Docker isn't running. Start it (Mac: colima start --cpu 4 --memory 8), then run this again."; exit 1; }; }

kind_config(){ # $1 profile
  local cni="false" kp="iptables"
  case "$1" in nocni) cni=true ;; nft) kp=nftables ;; cilium|full) cni=true; kp=none ;; plain) ;; esac
  cat <<K
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: {disableDefaultCNI: $cni, kubeProxyMode: $kp}
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
K
}
install_cilium(){
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1; helm repo update cilium >/dev/null
  helm --kube-context "$CTX" upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system \
    --set kubeProxyReplacement=true --set k8sServiceHost="$CLUSTER-control-plane" --set k8sServicePort=6443 \
    --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true --set hubble.relay.enabled=true \
    --set gatewayAPI.enabled=true --wait --timeout 8m >/dev/null
}
install_istio_ambient(){
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1; helm repo update istio >/dev/null
  for c in "istio-base istio/base" "istiod istio/istiod --set profile=ambient" "istio-cni istio/cni --set profile=ambient" "ztunnel istio/ztunnel"; do
    # shellcheck disable=SC2086
    helm --kube-context "$CTX" upgrade --install $c -n istio-system --create-namespace --version "$ISTIO_VERSION" --wait >/dev/null || return 1
  done
}
install_cert_manager(){
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1; helm repo update jetstack >/dev/null
  helm --kube-context "$CTX" upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait >/dev/null
}
cluster_up(){ # fresh cluster for this lab's profile
  need
  note "creating a fresh kind cluster '$CLUSTER' (profile: $CLUSTER_PROFILE) ..."
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  kind_config "$CLUSTER_PROFILE" | kind create cluster --name "$CLUSTER" --config - --wait 0s >/dev/null || { echo "kind could not create the cluster"; exit 1; }
  case "$CLUSTER_PROFILE" in
    cilium|full)
      k apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
      note "installing Cilium $CILIUM_VERSION ..."; install_cilium || { echo "Cilium install failed"; exit 1; } ;;
  esac
  if [ "$CLUSTER_PROFILE" = full ]; then
    note "installing Istio ambient $ISTIO_VERSION and cert-manager $CERT_MANAGER_VERSION ..."
    install_istio_ambient || { echo "Istio install failed"; exit 1; }
    install_cert_manager || { echo "cert-manager install failed"; exit 1; }
  fi
  if [ "$CLUSTER_PROFILE" != nocni ]; then   # nodes Ready AND cluster DNS answering before any step runs (slower machines need this)
    k wait --for=condition=Ready nodes --all --timeout=5m >/dev/null
    k -n kube-system rollout status deploy/coredns --timeout=5m >/dev/null
  fi
  if k -n kube-system get ds kube-proxy >/dev/null 2>&1 && ! k -n kube-system rollout status ds/kube-proxy --timeout=90s >/dev/null 2>&1; then
    echo "WARNING: kube-proxy is not running on every node, so Services won't work from pods there."
    k -n kube-system logs -l k8s-app=kube-proxy --tail=1 --prefix 2>/dev/null | grep -i "too many open files" >/dev/null &&
      echo "Cause: the Docker VM's inotify limits are too low for a 3-node kind cluster. Fix it once (see lab 0.2):" &&
      echo "  colima ssh -- sudo sh -c 'printf \"fs.inotify.max_user_watches=524288\\nfs.inotify.max_user_instances=512\\n\" > /etc/sysctl.d/99-kind.conf && sysctl --system'"
  fi
  k get nodes -o wide
  declare -F lab_setup >/dev/null && lab_setup
  return 0
}
cluster_down(){ kind delete cluster --name "$CLUSTER"; }

lab_main(){
  case "${1:-}" in
    up)    cluster_up ;;
    run)   cluster_up; for i in $(seq 1 "$(nsteps)"); do "step_$i"; done; echo; lab_main check ;;
    step)  [ -n "${2:-}" ] && declare -F "step_$2" >/dev/null || { echo "usage: bash lab.sh step N  (1..$(nsteps))"; exit 1; }
           kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || cluster_up
           "step_$2" ;;
    steps) for i in $(seq 1 "$(nsteps)"); do printf '%2d  %s\n' "$i" "$(declare -f "step_$i" | grep -m1 -o 'title "[^"]*"' | sed 's/title "//;s/"$//')"; done ;;
    check) title "check: $LAB_TITLE"; for i in $(seq 1 "$(nchecks)"); do "check_$i"; done
           printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$N"; [ "$FAIL" = 0 ] ;;
    down)  cluster_down ;;
    reset) cluster_up ;;
    *) printf '%s\n\nusage: bash lab.sh run | steps | step N | check | up | reset | down\n' "$LAB_TITLE"; exit 1 ;;
  esac
}
