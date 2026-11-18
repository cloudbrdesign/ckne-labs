#!/usr/bin/env bash
# Lab 2.1: L4 Services. One set of pods behind ClusterIP, NodePort, LoadBalancer, ExternalName and headless Services.
LAB_ID=2.1; LAB_TITLE="Lab 2.1: L4 Services: ClusterIP, NodePort, LoadBalancer, ExternalName"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
lab_setup(){
  k create deployment web --image=$AGNHOST --replicas=2 -- /agnhost netexec --http-port=8080 >/dev/null
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k rollout status deploy/web --timeout=120s >/dev/null; k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
nodeip(){ k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
nodeport(){ k get svc "$1" -o jsonpath='{.spec.ports[0].nodePort}'; }
step_1(){ title "ClusterIP: a stable virtual IP and name, reachable inside the cluster"
  run k expose deployment web --name=web --port=80 --target-port=8080
  run k get svc web -o wide
  run k get endpointslices -l kubernetes.io/service-name=web
  run k exec client -- wget -qO- -T 3 http://web/hostname; echo
  run k exec client -- wget -qO- -T 3 http://web.default.svc.cluster.local/hostname; echo
}
step_2(){ title "NodePort: the same Service, also open on a port of every node"
  run k expose deployment web --name=web-np --type=NodePort --port=80 --target-port=8080
  run k get svc web-np
  local p; p=$(nodeport web-np); sleep 3   # give kube-proxy a moment to program the new port
  echo "from outside the pod network (the control-plane node itself), call each worker's IP on port $p:"
  for n in ckne-worker ckne-worker2; do run docker exec ckne-control-plane curl -s -m 3 "http://$(nodeip $n):$p/hostname"; echo; done
}
step_3(){ title "LoadBalancer: asks for an external load balancer; with none installed, it stays pending"
  run k expose deployment web --name=web-lb --type=LoadBalancer --port=80 --target-port=8080
  sleep 5
  run k get svc web-lb
  echo "EXTERNAL-IP is <pending>: kind has no load-balancer controller (module 3 adds one). It still got a ClusterIP and a NodePort:"
  run docker exec ckne-control-plane curl -s -m 3 "http://$(nodeip ckne-worker):$(nodeport web-lb)/hostname"; echo
}
step_4(){ title "ExternalName: a DNS alias (CNAME), no proxying and no endpoints"
  run k create service externalname web-alias --external-name=web.default.svc.cluster.local
  run k get svc web-alias
  run k exec client -- nslookup web-alias.default.svc.cluster.local
}
step_5(){ title "Headless (clusterIP: None): DNS returns the pod IPs themselves"
  run k expose deployment web --name=web-headless --cluster-ip=None --port=80 --target-port=8080
  run k get svc web-headless
  run k exec client -- nslookup web-headless.default.svc.cluster.local
  run k get pods -l app=web -o wide
}
check_1(){ expect "Service web is a ClusterIP Service on port 80" sh -c "[ \"\$(kubectl --context $CTX get svc web -o jsonpath='{.spec.type} {.spec.ports[0].port}')\" = 'ClusterIP 80' ]"; }
check_2(){ expect "pod client reaches web by name" k exec client -- wget -qO- -T 3 http://web/hostname; }
check_3(){ expect "web-np answers on a worker node's IP and NodePort" sh -c "docker exec ckne-control-plane curl -sf -m 3 http://$(nodeip ckne-worker2):$(nodeport web-np 2>/dev/null)/hostname"; }
check_4(){ expect "web-lb is type LoadBalancer and has a NodePort" sh -c "[ \"\$(kubectl --context $CTX get svc web-lb -o jsonpath='{.spec.type}')\" = LoadBalancer ] && [ -n \"\$(kubectl --context $CTX get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}')\" ]"; }
check_5(){ expect "web-alias resolves as a CNAME to web.default.svc.cluster.local" sh -c "kubectl --context $CTX exec client -- nslookup web-alias.default.svc.cluster.local | grep -q 'canonical name = web.default.svc.cluster.local'"; }
check_6(){ expect "web-headless has no ClusterIP and DNS returns 2 pod IPs" sh -c "[ \"\$(kubectl --context $CTX get svc web-headless -o jsonpath='{.spec.clusterIP}')\" = None ] && [ \$(kubectl --context $CTX exec client -- nslookup web-headless.default.svc.cluster.local | grep -c '^Address: 10\.244\.') -ge 2 ]"; }
lab_main "$@"
