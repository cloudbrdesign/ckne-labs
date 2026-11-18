#!/usr/bin/env bash
# Lab 1.4: Linux tools on a node. Follow one pod's traffic with ip, iptables and tcpdump.
LAB_ID=1.4; LAB_TITLE="Lab 1.4: Linux tools on a node (ip, iptables, tcpdump)"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
NETSHOOT=nicolaka/netshoot:v0.13
lab_setup(){
  k run a --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 3600 >/dev/null
  k run b --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --labels=app=b --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=8080 >/dev/null
  k expose pod b --port=80 --target-port=8080 >/dev/null
  k wait --for=condition=Ready pod/a pod/b --timeout=120s >/dev/null
}
ipa(){ k get pod a -o jsonpath='{.status.podIP}'; }
# A node can have two iptables backends (nf_tables and legacy). Use whichever one holds kube-proxy's rules.
IPT=""
ipt(){ [ -n "$IPT" ] || IPT=$(docker exec ckne-worker sh -c 'for b in iptables-nft iptables-legacy; do $b -t nat -S KUBE-SERVICES >/dev/null 2>&1 && { echo $b; exit; }; done; echo iptables')
  docker exec ckne-worker sh -c "$IPT $*"; }
step_1(){ title "ip: the pod's side and the node's side of its veth pair"
  run k exec a -- ip addr show eth0
  run k exec a -- ip route
  echo "pod a is $(ipa); on the node, the route to it points at a veth:"
  run docker exec ckne-worker ip route get "$(ipa)"
}
step_2(){ title "ip route on the node: how traffic reaches other nodes' pods"
  run docker exec ckne-worker ip route
}
step_3(){ title "iptables: kube-proxy's rules for Service b (iptables mode)"
  run k get svc b -o wide
  ipt -V >/dev/null; echo "kube-proxy's rules are in: $IPT  ($(docker exec ckne-worker $IPT -V))"
  run docker exec ckne-worker sh -c "$IPT -t nat -S KUBE-SERVICES | grep 'default/b'"
  local chain; chain=$(ipt -t nat -S KUBE-SERVICES | grep 'default/b' | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1)
  run docker exec ckne-worker $IPT -t nat -S "$chain"
}
step_4(){ title "tcpdump: watch the packets (a debug pod on the node's network, with tcpdump in it)"
  k delete pod tcpdump --ignore-not-found >/dev/null 2>&1
  k run tcpdump --image=$NETSHOOT --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 600 >/dev/null
  k wait --for=condition=Ready pod/tcpdump --timeout=120s >/dev/null
  ( sleep 3; k exec a -- wget -qO- -T 3 http://b/hostname >/dev/null 2>&1 ) &
  run k exec tcpdump -- timeout 8 tcpdump -ni any -c 6 "tcp port 8080"
  wait
}
check_1(){ expect "node ckne-worker routes pod a's IP to a local veth interface" sh -c "docker exec ckne-worker ip route get $(ipa) | grep -q veth"; }
check_2(){ ipt -V >/dev/null; expect "kube-proxy has an iptables rule for Service default/b" sh -c "docker exec ckne-worker $IPT -t nat -S KUBE-SERVICES | grep -q 'default/b'"; }
check_3(){ expect "pod a reaches Service b by name" k exec a -- wget -qO- -T 3 http://b/hostname; }
lab_main "$@"
