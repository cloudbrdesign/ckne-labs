#!/usr/bin/env bash
# Lab 1.3: IPAM and pod CIDRs. Where pod IPs come from: the cluster CIDR, each node's slice of it, and the IPAM plugin's records.
LAB_ID=1.3; LAB_TITLE="Lab 1.3: IPAM and pod CIDRs"; CLUSTER_PROFILE=plain
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
step_1(){ title "The cluster's pod range, set on kube-controller-manager"
  run docker exec ckne-control-plane sh -c "grep -E 'cluster-cidr|allocate-node-cidrs|node-cidr-mask' /etc/kubernetes/manifests/kube-controller-manager.yaml"
}
step_2(){ title "Each node gets its own slice: spec.podCIDR"
  run k get nodes -o custom-columns=NODE:.metadata.name,PODCIDR:.spec.podCIDR
}
step_3(){ title "Pods get IPs from their node's slice"
  k create deployment ipam-demo --image=nginx:1.29 --replicas=6 >/dev/null 2>&1
  k rollout status deploy/ipam-demo --timeout=120s >/dev/null
  run k get pods -l app=ipam-demo -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP --sort-by=.spec.nodeName
}
ipamdir(){ # host-local stores its state in "dataDir" if the config sets one, else /var/lib/cni/networks
  docker exec ckne-worker sh -c 'd=$(grep -ho "\"dataDir\": *\"[^\"]*\"" /etc/cni/net.d/*.conflist | head -1 | cut -d\" -f4); echo ${d:-/var/lib/cni/networks}'
}
step_4(){ title "The IPAM plugin's own records on a node: host-local keeps one file per allocated IP"
  run docker exec ckne-worker sh -c 'grep -h -A3 "\"ipam\"" /etc/cni/net.d/*.conflist'
  local d; d=$(ipamdir); echo "host-local state directory on ckne-worker: $d"
  run docker exec ckne-worker sh -c "ls $d/*/"
}
step_5(){ title "Services use a different range: the Service CIDR"
  run docker exec ckne-control-plane sh -c "grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml"
  run k get servicecidrs
}
inrange(){ python3 - "$1" "$2" <<'P'
import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)
P
}
check_1(){ local bad=0 n ip cidr
  while read -r n ip; do cidr=$(k get node "$n" -o jsonpath='{.spec.podCIDR}'); inrange "$ip" "$cidr" || bad=1; done < <(k get pods -l app=ipam-demo -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.podIP}{"\n"}{end}')
  expect "every ipam-demo pod's IP is inside its node's podCIDR" test "$bad" = 0; }
check_2(){ expect "no two nodes share a podCIDR" sh -c "[ \$(kubectl --context $CTX get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{\"\\n\"}{end}' | sort | uniq -d | wc -l) = 0 ]"; }
check_3(){ local d; d=$(ipamdir); expect "ckne-worker has host-local records for its pods (in $d)" docker exec ckne-worker sh -c "ls $d/*/ | grep -q '^10\.'"; }
lab_main "$@"
