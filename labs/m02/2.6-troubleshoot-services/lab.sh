#!/usr/bin/env bash
# Lab 2.6: Troubleshooting Service traffic. The setup breaks three Services in namespace store; you find and fix them.
LAB_ID=2.6; LAB_TITLE="Lab 2.6: Troubleshooting Service traffic"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
lab_setup(){
  k create ns store >/dev/null
  k -n store apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec: {containers: [{name: web, image: "$AGNHOST", args: ["netexec", "--http-port=8080"]}]}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 9090}]       # break 1: the pods listen on 8080
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: "$AGNHOST"
        args: ["netexec", "--http-port=8080"]
        readinessProbe: {httpGet: {path: /healthz, port: 8081}, periodSeconds: 3}   # break 2: nothing listens on 8081
---
apiVersion: v1
kind: Service
metadata: {name: api}
spec:
  selector: {app: api}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: front}
spec:
  replicas: 1
  selector: {matchLabels: {app: front}}
  template:
    metadata: {labels: {app: front}}
    spec:
      nodeSelector: {kubernetes.io/hostname: ckne-worker}
      containers: [{name: front, image: "$AGNHOST", args: ["netexec", "--http-port=8080"]}]
---
apiVersion: v1
kind: Service
metadata: {name: front}
spec:
  type: NodePort
  externalTrafficPolicy: Local                 # break 3: the only pod is on ckne-worker
  selector: {app: front}
  ports: [{port: 80, targetPort: 8080}]
Y
  k -n store run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k -n store rollout status deploy/web --timeout=120s >/dev/null; k -n store rollout status deploy/front --timeout=120s >/dev/null
  k -n store wait --for=condition=Ready pod/client --timeout=120s >/dev/null; sleep 5
  echo "setup done: three Services in namespace store don't work as the team expects. 'bash lab.sh check' shows what the grader expects."
}
nodeip(){ k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
np(){ k -n store get svc front -o jsonpath='{.spec.ports[0].nodePort}'; }
step_1(){ title "Symptoms, one per Service"
  run k -n store exec client -- wget -qO- -T 3 http://web/hostname || true
  run k -n store exec client -- wget -qO- -T 3 http://api/hostname || true
  for n in ckne-worker ckne-worker2; do run docker exec ckne-control-plane curl -s -m 3 "http://$(nodeip $n):$(np)/hostname" && echo || echo "(no answer from $n)"; done
}
step_2(){ title "web: endpoints exist, so compare the Service's targetPort with the port the pods listen on"
  run k -n store get endpointslices -l kubernetes.io/service-name=web
  run k -n store get svc web -o jsonpath='{.spec.ports[0].port} -> {.spec.ports[0].targetPort}{"\n"}'
  runp "kubectl -n store logs deploy/web | head -3"
}
step_3(){ title "Fix web: point targetPort at 8080"
  run k -n store patch svc web --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
  run k -n store exec client -- wget -qO- -T 3 http://web/hostname; echo
}
step_4(){ title "api: the pods run, but none is Ready, so the Service has no ready endpoints"
  run k -n store get pods -l app=api
  runp "kubectl -n store get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{\"\\n\"}{end}'"
  runp "kubectl -n store describe pod -l app=api | grep -m1 'Readiness:'"
  runp "kubectl -n store get events --field-selector reason=Unhealthy -o custom-columns=POD:.involvedObject.name,MESSAGE:.message | head -3"
}
step_5(){ title "Fix api: probe the port the app actually serves (8080)"
  run k -n store patch deploy api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":8080}]'
  k -n store rollout status deploy/api --timeout=120s >/dev/null
  run k -n store get pods -l app=api
  run k -n store exec client -- wget -qO- -T 3 http://api/hostname; echo
}
step_6(){ title "front: the NodePort answers on one node only. Check externalTrafficPolicy and where the pod runs"
  run k -n store get svc front -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
  run k -n store get pods -l app=front -o wide
  echo "Local means: a node only forwards to pods on itself, and keeps the client's source IP. ckne-worker2 has no front pod."
}
step_7(){ title "Fix front: externalTrafficPolicy Cluster (any node forwards to any pod)"
  run k -n store patch svc front -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
  sleep 2
  for n in ckne-worker ckne-worker2; do run docker exec ckne-control-plane curl -s -m 3 "http://$(nodeip $n):$(np)/hostname"; echo; done
}
check_1(){ expect "client reaches web by name" k -n store exec client -- wget -qO- -T 3 http://web/hostname; }
check_2(){ expect "client reaches api by name" k -n store exec client -- wget -qO- -T 3 http://api/hostname; }
check_3(){ expect "front answers on ckne-worker2's NodePort" docker exec ckne-control-plane curl -sf -m 3 "http://$(nodeip ckne-worker2):$(np)/hostname"; }
check_4(){ expect "front answers on ckne-worker's NodePort" docker exec ckne-control-plane curl -sf -m 3 "http://$(nodeip ckne-worker):$(np)/hostname"; }
lab_main "$@"
