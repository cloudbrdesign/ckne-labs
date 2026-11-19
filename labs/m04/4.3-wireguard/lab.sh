#!/usr/bin/env bash
# Lab 4.3: Transparent encryption with WireGuard. Capture pod-to-pod traffic between nodes before and after, and prove what changed.
LAB_ID=4.3; LAB_TITLE="Lab 4.3: Node and pod encryption: WireGuard, proven with tcpdump"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
NETSHOOT=nicolaka/netshoot:v0.13
SECRET=card-4111-1111      # a "secret" the client sends in its request
lab_setup(){
  k apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: server}
spec:
  selector: {matchLabels: {app: server}}
  template:
    metadata: {labels: {app: server}}
    spec:
      nodeName: ckne-worker2
      containers: [{name: server, image: $AGNHOST, args: [netexec, --http-port=8080]}]
Y
  k expose deployment server --port=8080 >/dev/null
  k run client --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 36000 >/dev/null
  k run tcpdump --image=$NETSHOOT --overrides='{"spec":{"nodeName":"ckne-worker2","hostNetwork":true}}' -- sleep 36000 >/dev/null
  k rollout status deploy/server --timeout=120s >/dev/null
  k wait --for=condition=Ready pod/client pod/tcpdump --timeout=180s >/dev/null
}
send(){ k exec client -- wget -qO- -T 3 "http://server:8080/echo?msg=$SECRET"; }
CAP=$(mktemp)
capture(){ # $1 interface, $2 filter: capture on ckne-worker2 while the client sends 3 requests
  k exec tcpdump -- sh -c "timeout 8 tcpdump -ni $1 -A -s0 '$2' 2>/dev/null" > "$CAP" &
  sleep 2; local i; for i in 1 2 3; do send >/dev/null; sleep 0.5; done; wait
}
settle(){ local i; for i in $(seq 1 30); do capture eth0 'udp port 8472 or udp port 51871'; grep -q "$SECRET" "$CAP" || return 0; sleep 2; done; return 1; }
allpeers_wait(){ local i; for i in $(seq 1 20); do allpeers && return 0; sleep 3; done; return 1; }
summary(){ printf 'packets captured: %s   lines containing "%s": %s\n' "$(grep -c ' IP ' "$CAP")" "$SECRET" "$(grep -c "$SECRET" "$CAP")"; }
allpeers(){ local p; for p in $(k -n kube-system get pod -l k8s-app=cilium -o name); do
  k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -q 'Wireguard.*Peers: 2' || return 1; done; }
step_1(){ title "A client on ckne-worker calls a server on ckne-worker2; encryption is off"
  run k get pods -o wide
  runp "kubectl exec client -- wget -qO- http://server:8080/echo?msg=$SECRET; echo"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption"
}
step_2(){ title "On the wire: tcpdump on ckne-worker2's eth0 sees the request in clear text"
  note "Between nodes, Cilium wraps pod traffic in VXLAN (UDP 8472). The tcpdump pod uses the node's own network."
  printf '%s$ kubectl exec tcpdump -- tcpdump -ni eth0 -A "udp port 8472 or udp port 51871"   %s# while the client sends 3 requests\n' "$Y" "$N"
  capture eth0 'udp port 8472 or udp port 51871'
  grep -m2 "$SECRET" "$CAP" | cut -c1-120
  summary
}
step_3(){ title "Turn on WireGuard: every node gets a key pair and a tunnel to every other node"
  printf '%s$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard%s\n' "$Y" "$N"
  helm --kube-context "$CTX" upgrade cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --reuse-values \
    --set encryption.enabled=true --set encryption.type=wireguard --wait --timeout 8m >/dev/null
  run k -n kube-system rollout restart ds/cilium
  k -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
  local i t0; for i in $(seq 1 60); do allpeers && break; sleep 3; done
  t0=$(date +%s); settle
  note "Every agent has its tunnels. The lab then re-tested quietly until no clear text was left on the wire: $(( $(date +%s) - t0 )) s."
  runp "for p in \$(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do kubectl -n kube-system exec \$p -c cilium-agent -- cilium-dbg status | grep -o 'Wireguard.*Peers: [0-9]*' | sed 's/(Pubkey.*Port/(Port/'; done"
  runp "kubectl get ciliumnode ckne-worker2 -o jsonpath='{.metadata.annotations.network\.cilium\.io/wg-pub-key}'; echo"
  run docker exec ckne-worker2 ip -br link show cilium_wg0
}
step_4(){ title "On the wire again: only WireGuard packets (UDP 51871), no clear text"
  printf '%s$ kubectl exec tcpdump -- tcpdump -ni eth0 -A "udp port 8472 or udp port 51871"%s\n' "$Y" "$N"
  capture eth0 'udp port 8472 or udp port 51871'
  grep -m2 ' IP ' "$CAP" | cut -c1-120
  summary
  runp "kubectl exec client -- wget -qO- http://server:8080/echo?msg=$SECRET; echo"
  note "The app still works and nothing in it changed: the encryption is transparent."
}
step_5(){ title "Inside the tunnel: cilium_wg0 sees the traffic before it's encrypted"
  printf '%s$ kubectl exec tcpdump -- tcpdump -ni cilium_wg0 -A "udp port 8472 or tcp port 8080"%s\n' "$Y" "$N"
  capture cilium_wg0 'udp port 8472 or tcp port 8080'
  grep -m1 "$SECRET" "$CAP" | cut -c1-120
  summary
  note "Anyone with root on a node can still read the traffic there. WireGuard protects it between nodes, on the wire."
}
check_1(){ expect "every Cilium agent reports WireGuard with 2 peers" allpeers_wait; }
check_2(){ expect "ckne-worker and ckne-worker2 have a cilium_wg0 device" sh -c "docker exec ckne-worker ip link show cilium_wg0 && docker exec ckne-worker2 ip link show cilium_wg0"; }
check_3(){ capture eth0 'udp port 8472 or udp port 51871'
  expect "the request's text is not visible on ckne-worker2's eth0" sh -c "grep -q ' IP ' '$CAP' && ! grep -q '$SECRET' '$CAP'"; }
check_4(){ expect "the client still reaches the server" sh -c "kubectl --context $CTX exec client -- wget -qO- -T 3 'http://server:8080/echo?msg=$SECRET' | grep -q $SECRET"; }
lab_main "$@"
