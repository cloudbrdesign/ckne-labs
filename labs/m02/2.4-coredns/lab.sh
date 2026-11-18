#!/usr/bin/env bash
# Lab 2.4: Customising CoreDNS. Send one domain (corp.example) to a separate DNS server: a stub domain.
LAB_ID=2.4; LAB_TITLE="Lab 2.4: Customising CoreDNS: stub domains and forwarders"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
lab_setup(){
  # A stand-in for a company DNS server: its own CoreDNS, answering for corp.example only.
  local img; img=$(k -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}')
  k create ns corp-dns >/dev/null
  k -n corp-dns apply -f - >/dev/null <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: corp-dns}
data:
  Corefile: |
    corp.example:53 {
        hosts {
            10.10.10.42 app.corp.example
        }
        log
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: corp-dns}
spec:
  selector: {matchLabels: {app: corp-dns}}
  template:
    metadata: {labels: {app: corp-dns}}
    spec:
      containers:
      - name: coredns
        image: $img
        args: ["-conf", "/etc/coredns/Corefile"]
        volumeMounts: [{name: cfg, mountPath: /etc/coredns}]
      volumes: [{name: cfg, configMap: {name: corp-dns}}]
---
apiVersion: v1
kind: Service
metadata: {name: corp-dns}
spec:
  selector: {app: corp-dns}
  ports: [{name: dns, port: 53, protocol: UDP}, {name: dns-tcp, port: 53, protocol: TCP}]
Y
  k run client --image=busybox:1.36.1 -- sleep 3600 >/dev/null
  k -n corp-dns rollout status deploy/corp-dns --timeout=120s >/dev/null; k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
corpip(){ k -n corp-dns get svc corp-dns -o jsonpath='{.spec.clusterIP}'; }
step_1(){ title "Before: the cluster's DNS doesn't know corp.example"
  run k exec client -- nslookup -timeout=2 app.corp.example || true
  run k -n corp-dns get svc corp-dns
  run k exec client -- nslookup app.corp.example "$(corpip)"
}
step_2(){ title "CoreDNS's config: the Corefile in ConfigMap coredns"
  run k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
}
step_3(){ title "Add a stub domain: send corp.example to the corp DNS server"
  local ip; ip=$(corpip)
  echo "We add this server block to the Corefile (in the exam: kubectl -n kube-system edit cm coredns):"
  printf 'corp.example:53 {\n    errors\n    cache 30\n    forward . %s\n}\n' "$ip"
  k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/ckne-Corefile
  printf '%s\n' "corp.example:53 {" "    errors" "    cache 30" "    forward . $ip" "}" >> /tmp/ckne-Corefile
  runp "kubectl -n kube-system create cm coredns --from-file=Corefile=/tmp/ckne-Corefile --dry-run=client -o yaml | kubectl replace -f -"
  echo "The reload plugin picks up the change by itself; each CoreDNS pod reloads on its own timer. Waiting until every CoreDNS pod answers ..."
  local i ip ok; for i in $(seq 1 60); do ok=1
    for ip in $(k -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do
      k exec client -- nslookup -timeout=2 app.corp.example "$ip" 2>/dev/null | grep -q 10.10.10.42 || ok=0; done
    [ $ok = 1 ] && break; sleep 3; done
  echo "all CoreDNS pods answered after about $((i * 3)) s"
}
step_4(){ title "After: the name resolves through the cluster's DNS, and cluster names still work"
  run k exec client -- nslookup app.corp.example
  run k exec client -- nslookup kubernetes.default.svc.cluster.local
  runp "kubectl -n corp-dns logs deploy/corp-dns | grep app.corp.example | tail -2"
}
step_5(){ title "Forwarders: everything else goes upstream (the forward line in the default block)"
  runp "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -n forward"
}
check_1(){ expect "ConfigMap coredns has a corp.example server block" sh -c "kubectl --context $CTX -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -q '^corp.example:53'"; }
check_2(){ expect "pod client resolves app.corp.example to 10.10.10.42 through cluster DNS" sh -c "kubectl --context $CTX exec client -- nslookup -timeout=2 app.corp.example | grep -q 10.10.10.42"; }
check_3(){ expect "cluster names still resolve" k exec client -- nslookup -timeout=2 kubernetes.default.svc.cluster.local; }
lab_main "$@"
