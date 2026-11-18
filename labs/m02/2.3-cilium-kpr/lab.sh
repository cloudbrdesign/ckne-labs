#!/usr/bin/env bash
# Lab 2.3: Replacing kube-proxy with Cilium. No kube-proxy, no Service iptables rules: Cilium's eBPF programs do the work.
LAB_ID=2.3; LAB_TITLE="Lab 2.3: Replacing kube-proxy with Cilium"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
lab_setup(){
  k create deployment web --image=$AGNHOST --replicas=2 -- /agnhost netexec --http-port=8080 >/dev/null
  k expose deployment web --port=80 --target-port=8080 >/dev/null
  k expose deployment web --name=web-np --type=NodePort --port=80 --target-port=8080 >/dev/null
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k rollout status deploy/web --timeout=120s >/dev/null; k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
# The Cilium agent on ckne-worker (cilium-dbg is the agent's own debug tool).
cpod(){ k -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=ckne-worker -o name | head -1; }
nodeip(){ k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
svcip(){ k get svc web -o jsonpath='{.spec.clusterIP}'; }
step_1(){ title "No kube-proxy in this cluster"
  run k -n kube-system get ds
  run k -n kube-system get ds kube-proxy || true
}
step_2(){ title "Cilium says it has taken over kube-proxy's job"
  runp "kubectl -n kube-system exec $(cpod) -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading'"
  runp "kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'kube-proxy-replacement|bpf-lb-sock'"
}
step_3(){ title "No Service rules in iptables on the node"
  runp "docker exec ckne-worker sh -c 'iptables-save | grep -c KUBE-SVC'" || true
  runp "docker exec ckne-worker sh -c 'iptables-save | grep -c CILIUM'"
}
step_4(){ title "Cilium's own Service table: frontend (ClusterIP:port) -> backends (pod IP:port)"
  run k get svc web web-np
  run k get endpointslices -l kubernetes.io/service-name=web
  runp "kubectl -n kube-system exec $(cpod) -c cilium-agent -- cilium-dbg service list | grep -A1 '$(svcip):80/TCP'"
}
step_5(){ title "It still works: ClusterIP from a pod, NodePort from outside the pod network"
  run k exec client -- wget -qO- -T 3 http://web/hostname; echo
  local p; p=$(k get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')
  run docker exec ckne-control-plane curl -s -m 3 "http://$(nodeip ckne-worker):$p/hostname"; echo
}
check_1(){ expect "no kube-proxy DaemonSet" sh -c "! kubectl --context $CTX -n kube-system get ds kube-proxy"; }
check_2(){ expect "Cilium reports KubeProxyReplacement: True" sh -c "kubectl --context $CTX -n kube-system exec $(cpod) -c cilium-agent -- cilium-dbg status | grep -q 'KubeProxyReplacement:.*True'"; }
check_3(){ expect "Cilium's Service table has Service web's ClusterIP" sh -c "kubectl --context $CTX -n kube-system exec $(cpod) -c cilium-agent -- cilium-dbg service list | grep -q '$(svcip):80'"; }
check_4(){ expect "no KUBE-SVC iptables rules on ckne-worker" sh -c "! docker exec ckne-worker sh -c 'iptables-save | grep -q KUBE-SVC'"; }
check_5(){ expect "pod client reaches web by name" k exec client -- wget -qO- -T 3 http://web/hostname; }
check_6(){ local p; p=$(k get svc web-np -o jsonpath='{.spec.ports[0].nodePort}'); expect "web-np answers on a worker's IP and NodePort" docker exec ckne-control-plane curl -sf -m 3 "http://$(nodeip ckne-worker2):$p/hostname"; }
lab_main "$@"
