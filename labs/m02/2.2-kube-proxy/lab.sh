#!/usr/bin/env bash
# Lab 2.2: kube-proxy's rules, read on a node. This cluster runs kube-proxy in nftables mode.
LAB_ID=2.2; LAB_TITLE="Lab 2.2: kube-proxy: iptables and nftables rules, read on a node"; CLUSTER_PROFILE=nft
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
lab_setup(){
  k create deployment web --image=$AGNHOST --replicas=2 -- /agnhost netexec --http-port=8080 >/dev/null
  k expose deployment web --port=80 --target-port=8080 >/dev/null
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k rollout status deploy/web --timeout=120s >/dev/null; k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
# kube-proxy runs in a pod on every node, with the node's network; its image has the nft tool.
kp(){ k -n kube-system get pod -l k8s-app=kube-proxy --field-selector spec.nodeName=ckne-worker -o name | head -1; }
nftk(){ k -n kube-system exec "$(kp)" -- nft "$@"; }
svcip(){ k get svc web -o jsonpath='{.spec.clusterIP}'; }
svcchain(){ nftk list map ip kube-proxy service-ips 2>/dev/null | grep "$(svcip) . tcp . 80" | grep -o 'service-[A-Za-z0-9_/-]*' | head -1; }
step_1(){ title "Which mode is kube-proxy in?"
  runp "kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\\.conf}' | grep -E '^mode:'"
  runp "kubectl -n kube-system logs $(kp) | grep -i -m2 nftables"
}
step_2(){ title "The service-ips map: ClusterIP + protocol + port -> one chain per Service"
  run k get svc web
  run k -n kube-system exec "$(kp)" -- nft list map ip kube-proxy service-ips
}
step_3(){ title "The Service's chain: DNAT to one endpoint, picked at random (numgen)"
  local c; c=$(svcchain); echo "Service web's chain: $c"
  run k -n kube-system exec "$(kp)" -- nft list chain ip kube-proxy "$c"
  run k get endpointslices -l kubernetes.io/service-name=web
}
step_4(){ title "Scale to 3: kube-proxy rewrites the Service's chain"
  run k scale deploy web --replicas=3
  k rollout status deploy/web --timeout=120s >/dev/null; sleep 3
  run k -n kube-system exec "$(kp)" -- nft list chain ip kube-proxy "$(svcchain)"
}
step_5(){ title "No endpoints at all: the Service is rejected, not silently dropped"
  run k scale deploy web --replicas=0
  sleep 5
  runp "kubectl -n kube-system exec $(kp) -- nft list map ip kube-proxy no-endpoint-services | grep '$(svcip)'"
  run k exec client -- wget -qO- -T 3 http://web/hostname || true
  run k scale deploy web --replicas=3
  k rollout status deploy/web --timeout=120s >/dev/null; sleep 3
}
check_1(){ expect "kube-proxy runs in nftables mode" sh -c "kubectl --context $CTX -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -q '^mode: nftables'"; }
check_2(){ local ip; ip=$(svcip); expect "the service-ips map has Service web's ClusterIP" sh -c "kubectl --context $CTX -n kube-system exec $(kp) -- nft list map ip kube-proxy service-ips | grep -q '$ip . tcp . 80'"; }
check_3(){ local c; c=$(svcchain); expect "Service web's chain picks among 3 endpoints" sh -c "kubectl --context $CTX -n kube-system exec $(kp) -- nft list chain ip kube-proxy $c | grep -q 'numgen random mod 3'"; }
check_4(){ expect "pod client reaches web by name" k exec client -- wget -qO- -T 3 http://web/hostname; }
lab_main "$@"
