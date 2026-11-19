#!/usr/bin/env bash
# Lab 3.1: Exposing networks. A LoadBalancer Service on a cluster with no cloud: Cilium LB IPAM hands out the address,
# then L2 announcements (ARP) or BGP (to a router outside the cluster) make the address reachable from outside.
LAB_ID=3.1; LAB_TITLE="Lab 3.1: LoadBalancer on bare metal: LB IPAM, L2 announcements and BGP"; CLUSTER_PROFILE=cilium
CILIUM_EXTRA="--set l2announcements.enabled=true --set bgpControlPlane.enabled=true --set k8sClientRateLimit.qps=10 --set k8sClientRateLimit.burst=20"
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
AGNHOST=registry.k8s.io/e2e-test-images/agnhost:2.52
FRR=ckne-frr; OUT=ckne-outside      # two plain containers on kind's Docker network, outside the cluster
lab_down(){ docker rm -f "$FRR" "$OUT" >/dev/null 2>&1; }
subnet(){ docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.'; }
pre(){ subnet | cut -d. -f1-2; }
cip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
lease(){ k -n kube-system get lease -o name 2>/dev/null | grep -m1 'cilium-l2announce-.*web-l2' | cut -d/ -f2; }
lbip(){ k get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }
lab_setup(){
  k create deployment web --image=$AGNHOST --replicas=2 -- /agnhost netexec --http-port=8080 >/dev/null
  k rollout status deploy/web --timeout=120s >/dev/null
  docker pull -q busybox:1.36.1 >/dev/null; docker pull -q "$FRR_IMAGE" >/dev/null
  docker run -d --name "$OUT" --network kind busybox:1.36.1 sleep 36000 >/dev/null
}
start_frr(){ # a small FRR router outside the cluster: ASN 65001, accepts BGP sessions from any node on kind's network
  local d; d=$(mktemp -d)
  printf 'zebra=yes\nbgpd=yes\nvtysh_enable=yes\nzebra_options="  -A 127.0.0.1 -s 90000000"\nbgpd_options="   -A 127.0.0.1"\n' > "$d/daemons"
  : > "$d/vtysh.conf"
  cat > "$d/frr.conf" <<F
frr defaults traditional
hostname ckne-frr
log stdout
router bgp 65001
 no bgp ebgp-requires-policy
 neighbor CILIUM peer-group
 neighbor CILIUM remote-as 65000
 bgp listen range $(subnet) peer-group CILIUM
!
F
  docker create --name "$FRR" --network kind --privileged "$FRR_IMAGE" >/dev/null
  docker cp "$d/." "$FRR:/etc/frr/" >/dev/null; docker start "$FRR" >/dev/null; rm -rf "$d"
}
step_1(){ title "A LoadBalancer Service on a cluster with no cloud: nobody hands out an address"
  runp "kubectl expose deployment web --name web-l2 --type LoadBalancer --port 80 --target-port 8080"
  k label svc web-l2 exposure=l2 >/dev/null
  sleep 5; run k get svc web-l2
  note "EXTERNAL-IP stays <pending>: Kubernetes asks for a load balancer but ships none."
}
step_2(){ title "LB IPAM: give Cilium a pool of addresses to hand out"
  local p; p=$(pre)
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec: {blocks: [{start: "$p.255.200", stop: "$p.255.220"}]}
Y
  printf '%s$ kubectl apply -f pool.yaml   %s# blocks: %s.255.200 - %s.255.220 (on kind'"'"'s Docker network)\n' "$Y" "$N" "$p" "$p"
  local i; for i in $(seq 1 30); do [ -n "$(lbip web-l2)" ] && break; sleep 2; done
  run k get ippools
  run k get svc web-l2
}
step_3(){ title "An address is not a route: from outside the cluster, nobody answers for it yet"
  local ip; ip=$(lbip web-l2)
  note "ckne-outside is a plain container on the same Docker network as the nodes, like a laptop on the office LAN."
  runp "docker exec $OUT wget -qO- -T 3 http://$ip/hostname || echo '(no answer)'"
  runp "docker exec $OUT ip neigh show $ip"
  note "No MAC address for $ip: no node answers ARP for it."
}
step_4(){ title "L2 announcements: one node answers ARP for the address"
  k apply -f - >/dev/null <<'Y'
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: l2-lab}
spec:
  serviceSelector: {matchLabels: {exposure: l2}}
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
Y
  printf '%s$ kubectl apply -f l2-policy.yaml%s\n' "$Y" "$N"
  local ip i; ip=$(lbip web-l2)
  for i in $(seq 1 30); do [ -n "$(lease)" ] && break; sleep 2; done
  runp "kubectl -n kube-system get lease | grep -E 'NAME|l2announce'"
  for i in $(seq 1 15); do docker exec $OUT wget -qO- -T 2 "http://$ip/hostname" >/dev/null 2>&1 && break; sleep 2; done
  runp "docker exec $OUT wget -qO- -T 3 http://$ip/hostname; echo"
  runp "docker exec $OUT ip neigh show $ip"
  local h; h=$(k -n kube-system get lease "$(lease)" -o jsonpath='{.spec.holderIdentity}')
  runp "docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' $h"
  note "The MAC that answered is the lease holder's: that node receives the traffic and load-balances it to a pod."
}
step_5(){ title "BGP: a router outside the cluster, ASN 65001"
  start_frr; sleep 3
  note "ckne-frr is a router at $(cip $FRR). The nodes (ASN 65000) will open BGP sessions to it."
  runp "kubectl expose deployment web --name web-bgp --type LoadBalancer --port 80 --target-port 8080"
  k label svc web-bgp exposure=bgp >/dev/null
  local i; for i in $(seq 1 30); do [ -n "$(lbip web-bgp)" ] && break; sleep 2; done
  run k get svc web-bgp
}
step_6(){ title "Peer the nodes with the router and advertise the Service's address"
  k apply -f - >/dev/null <<Y
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: lab-bgp}
spec:
  nodeSelector: {matchLabels: {kubernetes.io/os: linux}}
  bgpInstances:
  - name: instance-65000
    localASN: 65000
    peers:
    - {name: frr, peerASN: 65001, peerAddress: "$(cip $FRR)", peerConfigRef: {name: frr-peer}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: frr-peer}
spec:
  families:
  - {afi: ipv4, safi: unicast, advertisements: {matchLabels: {advertise: bgp}}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata: {name: lb-ips, labels: {advertise: bgp}}
spec:
  advertisements:
  - advertisementType: Service
    service: {addresses: [LoadBalancerIP]}
    selector: {matchLabels: {exposure: bgp}}
Y
  printf '%s$ kubectl apply -f bgp.yaml   %s# CiliumBGPClusterConfig, CiliumBGPPeerConfig, CiliumBGPAdvertisement\n' "$Y" "$N"
  local ip i; ip=$(lbip web-bgp)
  for i in $(seq 1 45); do docker exec $FRR vtysh -c "show ip route $ip/32" 2>/dev/null | grep -q bgp && break; sleep 2; done
  runp "docker exec $FRR vtysh -c 'show bgp summary'"
  runp "docker exec $FRR vtysh -c 'show ip route bgp'"
  runp "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg shell -- bgp/peers"
}
step_7(){ title "The router now forwards to the Service: its address is reachable through BGP"
  local ip; ip=$(lbip web-bgp)
  runp "docker exec $FRR wget -qO- -T 3 http://$ip/hostname; echo"
  note "web-bgp has no L2 policy: only the router knows where $ip lives, because the nodes told it over BGP."
}
check_1(){ expect "Service web-l2 has an address from pool lab-pool" sh -c "kubectl --context $CTX get svc web-l2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q '\.255\.2[0-2][0-9]$'"; }
check_2(){ expect "a node holds the L2 announcement lease for web-l2" sh -c "kubectl --context $CTX -n kube-system get lease \$(kubectl --context $CTX -n kube-system get lease -o name | grep -m1 'cilium-l2announce-.*web-l2' | cut -d/ -f2) -o jsonpath='{.spec.holderIdentity}' | grep -q ."; }
check_3(){ expect "a client outside the cluster reaches web-l2 at its LoadBalancer IP" sh -c "docker exec $OUT wget -qO- -T 3 http://\$(kubectl --context $CTX get svc web-l2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/hostname"; }
check_4(){ expect "the BGP router has a route to web-bgp's address" sh -c "docker exec $FRR vtysh -c \"show ip route \$(kubectl --context $CTX get svc web-bgp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/32\" | grep -q bgp"; }
check_5(){ expect "the router reaches web-bgp through that route" sh -c "docker exec $FRR wget -qO- -T 3 http://\$(kubectl --context $CTX get svc web-bgp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/hostname"; }
lab_main "$@"
