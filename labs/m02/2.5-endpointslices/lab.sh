#!/usr/bin/env bash
# Lab 2.5: Endpoint availability. Readiness decides which pods get Service traffic; EndpointSlice conditions show it.
LAB_ID=2.5; LAB_TITLE="Lab 2.5: Endpoint availability: readiness and EndpointSlice conditions"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
lab_setup(){
  # 3 small web servers (busybox httpd) that answer with their pod name. A pod is Ready only once /tmp/ready exists.
  k apply -f - >/dev/null <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - name: httpd
        image: busybox:1.36.1
        command: ["sh", "-c", "mkdir -p /www && hostname > /www/index.html && exec httpd -f -p 8080 -h /www"]
        readinessProbe: {exec: {command: ["cat", "/tmp/ready"]}, periodSeconds: 2}
        lifecycle: {preStop: {exec: {command: ["sleep", "45"]}}}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 8080}]
Y
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  k wait --for=jsonpath='{.status.phase}'=Running pod -l app=web --timeout=120s >/dev/null
}
slice(){ k get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{" serving="}{.conditions.serving}{" terminating="}{.conditions.terminating}{"\n"}{end}'; }
showslice(){ printf '%s$ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath=...%s\n' "$Y" "$N"; slice; }
pods(){ k get pods -l app=web -o name --sort-by=.metadata.name | sed 's|pod/||'; }
hits(){ k exec client -- sh -c 'for i in $(seq 1 20); do wget -qO- -T 2 http://web; done' | sort | uniq -c; }
step_1(){ title "Pods running, none ready: the Service has endpoints, but none is ready"
  run k get pods -l app=web
  showslice
  run k exec client -- wget -qO- -T 3 http://web || true
}
step_2(){ title "Make two pods ready: only those two get traffic"
  local p; for p in $(pods | head -2); do run k exec "$p" -- touch /tmp/ready; done
  sleep 6
  run k get pods -l app=web
  showslice
  echo "20 requests through the Service, counted by the pod that answered:"; hits
}
step_3(){ title "A ready pod fails its probe: it leaves the rotation, but stays in the slice"
  local p; p=$(pods | head -1)
  run k exec "$p" -- rm /tmp/ready
  sleep 6
  showslice
  echo "20 requests:"; hits
  run k exec "$p" -- touch /tmp/ready; sleep 6
}
step_4(){ title "Terminating: a deleted pod is ready=false, but still serving while it shuts down"
  local p; p=$(pods | sed -n 2p)
  run k delete pod "$p" --wait=false
  sleep 4
  showslice
  run k get pods -l app=web
}
check_1(){ expect "Service web's EndpointSlice lists the web pods" sh -c "[ \$(kubectl --context $CTX get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{\"\\n\"}{end}' | grep -c .) -ge 3 ]"; }
check_2(){ expect "at least one endpoint is ready and at least one is not" sh -c "s=\$(kubectl --context $CTX get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{\"\\n\"}{end}'); echo \"\$s\" | grep -q true && echo \"\$s\" | grep -q false"; }
check_3(){ expect "every answer through the Service comes from a ready pod" sh -c "
  ready=\$(kubectl --context $CTX get pods -l app=web -o go-template='{{range .items}}{{\$n := .metadata.name}}{{range .status.conditions}}{{if and (eq .type \"Ready\") (eq .status \"True\")}}{{\$n}}{{\"\\n\"}}{{end}}{{end}}{{end}}')
  for h in \$(kubectl --context $CTX exec client -- sh -c 'for i in \$(seq 1 10); do wget -qO- -T 2 http://web; done'); do echo \"\$ready\" | grep -qx \"\$h\" || exit 1; done"; }
lab_main "$@"
