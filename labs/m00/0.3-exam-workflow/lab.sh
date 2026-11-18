#!/usr/bin/env bash
# Lab 0.3: Working like the exam. Reach a node's shell, find things fast with kubectl, generate YAML instead of typing it.
LAB_ID=0.3; LAB_TITLE="Lab 0.3: Working like the exam"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
step_1(){ title "Which cluster am I talking to? (every exam task starts here)"
  run kubectl config get-contexts
  run kubectl config current-context
}
step_2(){ title "Get onto a node: in the exam you ssh to a named host; in our lab the nodes are containers"
  run docker exec ckne-worker hostname
  run docker exec ckne-worker sh -c 'crictl ps --name kindnet -q | head -1; ip -br addr | head -5'
}
step_3(){ title "Look up a field without leaving the terminal: kubectl explain"
  run k explain service.spec.internalTrafficPolicy
  run k explain networkpolicy.spec.policyTypes
}
step_4(){ title "Generate YAML instead of writing it: --dry-run=client -o yaml"
  run k create deployment web --image=nginx:1.29 --replicas=2 --dry-run=client -o yaml
  run k create deployment web --image=nginx:1.29 --replicas=2
  run k expose deployment web --port=80 --target-port=80
  k rollout status deploy/web --timeout=120s >/dev/null
  run k get deploy,svc,endpointslices -l app=web -o wide
}
step_5(){ title "Verify like the grader: test from inside the cluster, not from your laptop"
  # a probe pod that stays up; on a slow laptop a pod's very first packets can be dropped while the network catches up,
  # so we wait for it to be Ready and then test from it
  k run probe --image=busybox:1.36.1 -- sleep 3600 >/dev/null 2>&1; k wait --for=condition=Ready pod/probe --timeout=120s >/dev/null
  run k exec probe -- wget -qO- -T 3 http://web | head -4
}
check_1(){ expect "deployment web has 2 ready replicas" sh -c "[ \"\$(kubectl --context $CTX get deploy web -o jsonpath='{.status.readyReplicas}')\" = 2 ]"; }
check_2(){ expect "service web exposes port 80" sh -c "[ \"\$(kubectl --context $CTX get svc web -o jsonpath='{.spec.ports[0].port}')\" = 80 ]"; }
check_3(){ expect "service web has 2 ready endpoints" sh -c "[ \$(kubectl --context $CTX get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}' | wc -c) = 2 ]"; }
check_4(){ k run probe --image=busybox:1.36.1 -- sleep 3600 >/dev/null 2>&1; k wait --for=condition=Ready pod/probe --timeout=120s >/dev/null 2>&1
  expect "web answers from inside the cluster" k exec probe -- wget -qO- -T 3 http://web; }
lab_main "$@"
