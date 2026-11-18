#!/usr/bin/env bash
# Lab 1.5: Troubleshooting pod connectivity and DNS. The setup breaks two things; you find and fix them.
LAB_ID=1.5; LAB_TITLE="Lab 1.5: Troubleshooting pod connectivity and DNS"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
lab_setup(){
  k create ns shop >/dev/null
  k -n shop create deployment api --image=registry.k8s.io/e2e-test-images/agnhost:2.52 -- /agnhost netexec --http-port=8080 >/dev/null
  k -n shop expose deploy api --port=80 --target-port=8080 >/dev/null
  # break 1: the client pod points at a DNS server that doesn't exist
  k -n shop apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  dnsPolicy: None
  dnsConfig: {nameservers: ["10.96.0.53"], searches: ["shop.svc.cluster.local", "svc.cluster.local", "cluster.local"], options: [{name: ndots, value: "5"}]}
  containers: [{name: c, image: "busybox:1.36.1", command: ["sleep", "3600"]}]
Y
  # break 2: the Service selects a label no pod has
  k -n shop patch svc api -p '{"spec":{"selector":{"app":"api-v2"}}}' >/dev/null
  k -n shop rollout status deploy/api --timeout=120s >/dev/null; k -n shop wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  echo "setup done: something in namespace shop is broken. 'bash lab.sh check' shows what the grader expects."
}
step_1(){ title "Symptom: the client can't reach api by name"
  run k -n shop exec client -- wget -qO- -T 3 http://api/hostname || true
}
step_2(){ title "DNS first: what resolver does the pod use?"
  run k -n shop exec client -- cat /etc/resolv.conf
  run k -n kube-system get svc kube-dns
  run k -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local || true
  run k -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local 10.96.0.10 || true
}
step_3(){ title "Fix 1: recreate the client with the cluster's DNS (dnsPolicy ClusterFirst)"
  k -n shop delete pod client --wait=true >/dev/null
  run k -n shop run client --image=busybox:1.36.1 -- sleep 3600
  k -n shop wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  run k -n shop exec client -- nslookup api.shop.svc.cluster.local
}
step_4(){ title "Still failing: name resolves, but nothing answers. Check the Service's endpoints"
  run k -n shop exec client -- wget -qO- -T 3 http://api/hostname || true
  run k -n shop get endpointslices -l kubernetes.io/service-name=api
  run k -n shop get svc api -o jsonpath='{.spec.selector}{"\n"}'
  run k -n shop get pods --show-labels
}
step_5(){ title "Fix 2: point the Service's selector at the pods' real label"
  run k -n shop patch svc api -p '{"spec":{"selector":{"app":"api"}}}' --type=merge
  run k -n shop get endpointslices -l kubernetes.io/service-name=api
  run k -n shop exec client -- wget -qO- -T 3 http://api/hostname; echo
}
check_1(){ expect "client resolves api.shop.svc.cluster.local" k -n shop exec client -- nslookup -timeout=2 api.shop.svc.cluster.local; }
check_2(){ expect "Service api has ready endpoints" sh -c "kubectl --context $CTX -n shop get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[*].addresses[*]}' | grep -q ."; }
check_3(){ expect "client reaches http://api" k -n shop exec client -- wget -qO- -T 3 http://api/hostname; }
lab_main "$@"
