#!/usr/bin/env bash
# Lab 1.2: CNI by hand. A cluster with no network plugin, then a pod network built from the CNI reference plugins:
# a CNI config file on every node (ptp + host-local IPAM) and one route per node.
# (kind nodes ship only these CNI binaries: host-local, loopback, portmap, ptp. Our first run used "bridge" and every pod
#  stuck in ContainerCreating, because that binary isn't on the node.)
LAB_ID=1.2; LAB_TITLE="Lab 1.2: How a pod gets its network (CNI by hand)"; CLUSTER_PROFILE=nocni
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
NODES(){ k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
podcidr(){ k get node "$1" -o jsonpath='{.spec.podCIDR}'; }
nodeip(){ k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }

step_1(){ title "A cluster with no network plugin: nodes are NotReady"
  run k get nodes
  run k get node ckne-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
  run node_sh ckne-worker 'ls -la /etc/cni/net.d/ || true'
}
step_2(){ title "What every node already has: CNI plugin binaries, and a pod CIDR from Kubernetes"
  run node_sh ckne-worker 'ls /opt/cni/bin'
  for n in $(NODES); do echo "$n  podCIDR=$(podcidr "$n")  nodeIP=$(nodeip "$n")"; done
}
step_3(){ title "Write a CNI config on each node: ptp plugin + host-local IPAM for that node's pod CIDR"
  for n in $(NODES); do
    cidr=$(podcidr "$n")
    conf=$(cat <<C
{
  "cniVersion": "1.0.0",
  "name": "ckne-ptp",
  "plugins": [
    { "type": "ptp", "ipMasq": false, "mtu": 1500,
      "ipam": { "type": "host-local", "ranges": [[{ "subnet": "$cidr" }]], "routes": [{ "dst": "0.0.0.0/0" }] } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
C
)
    printf '%s\n' "$conf" | docker exec -i "$n" sh -c 'cat > /etc/cni/net.d/10-ckne-ptp.conflist'
    echo "wrote /etc/cni/net.d/10-ckne-ptp.conflist on $n (subnet $cidr)"
  done
  run node_sh ckne-worker 'cat /etc/cni/net.d/10-ckne-ptp.conflist'
}
step_4(){ title "Route each node's pod CIDR to that node (the part a real CNI automates)"
  for a in $(NODES); do for b in $(NODES); do [ "$a" = "$b" ] && continue
    docker exec "$a" ip route replace "$(podcidr "$b")" via "$(nodeip "$b")"; done
    echo "$a:"; docker exec "$a" ip route | grep -E '^10\.244' | sed 's/^/   /'
  done
}
step_5(){ title "Nodes turn Ready; CoreDNS starts"
  run k wait --for=condition=Ready nodes --all --timeout=120s
  run k -n kube-system rollout status deploy/coredns --timeout=180s || { k -n kube-system get pods -o wide; k -n kube-system describe pods -l k8s-app=kube-dns | sed -n '/Events:/,$p' | tail -8; }
  run k get nodes
}
step_6(){ title "Two pods on different nodes reach each other directly, without NAT"
  k delete pod a b --ignore-not-found --wait=false >/dev/null 2>&1
  run k run a --image=busybox:1.36.1 --overrides='{"spec":{"nodeName":"ckne-worker"}}' -- sleep 3600
  run k run b --image=registry.k8s.io/e2e-test-images/agnhost:2.52 --overrides='{"spec":{"nodeName":"ckne-worker2"}}' -- netexec --http-port=8080
  k wait --for=condition=Ready pod/a pod/b --timeout=120s >/dev/null || k describe pod a | sed -n '/Events:/,$p' | tail -6
  run k get pods -o wide
  run k exec a -- ping -c 2 "$(k get pod b -o jsonpath='{.status.podIP}')"
  run k exec a -- ip addr show eth0
  run k exec a -- wget -qO- "http://$(k get pod b -o jsonpath='{.status.podIP}'):8080/clientip"; echo
  echo "pod a is $(k get pod a -o jsonpath='{.status.podIP}'); a connection from a arrives at b from: $(seen_by_b)"
}
check_1(){ expect "all nodes Ready" sh -c "[ \$(kubectl --context $CTX get nodes --no-headers | grep -vc ' Ready ') = 0 ]"; }
check_2(){ for n in $(NODES); do expect "$n has a CNI config in /etc/cni/net.d" docker exec "$n" sh -c 'ls /etc/cni/net.d/*.conflist'; done; }
check_3(){ expect "CoreDNS is available" k -n kube-system wait --for=condition=Available deploy/coredns --timeout=5s; }
check_4(){ expect "pod a (ckne-worker) can ping pod b (ckne-worker2)" k exec a -- ping -c 1 -W 2 "$(k get pod b -o jsonpath='{.status.podIP}' 2>/dev/null)"; }
seen_by_b(){ # pod b runs Kubernetes' test server (agnhost netexec); /clientip answers with the address the request came from
  k exec a -- wget -qO- -T 3 "http://$(k get pod b -o jsonpath='{.status.podIP}'):8080/clientip" 2>/dev/null | cut -d: -f1
}
check_5(){ local seen ipa; ipa=$(k get pod a -o jsonpath='{.status.podIP}' 2>/dev/null); seen=$(seen_by_b 2>/dev/null)
  expect "pod b sees pod a's own IP ($ipa) as the source, not a node IP (no NAT)" test -n "$seen" -a "$seen" = "$ipa"; }
lab_main "$@"
