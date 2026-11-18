#!/usr/bin/env bash
# Lab 1.6: Multi-interface pods with Multus. Install the CNI reference plugins on the nodes, install Multus,
# define a second network (bridge + host-local), and attach it to two pods as net1.
LAB_ID=1.6; LAB_TITLE="Lab 1.6: Multi-interface pods with Multus"; CLUSTER_PROFILE=cilium
source "$(cd "$(dirname "$0")/../../.." && pwd)/lib/lab.sh"
step_1(){ title "Install the CNI reference plugins (bridge, macvlan, ...) on every node"
  for n in ckne-control-plane ckne-worker ckne-worker2; do
    docker exec "$n" sh -c "curl -fsSL https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-\$(dpkg --print-architecture)-$CNI_PLUGINS_VERSION.tgz | tar xz -C /opt/cni/bin ./bridge ./macvlan ./ipvlan ./static" && echo "plugins installed on $n"
  done
  run docker exec ckne-worker ls /opt/cni/bin
}
step_2(){ title "Install Multus $MULTUS_VERSION (thick plugin): it becomes the first CNI and delegates to Cilium"
  run k apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$MULTUS_VERSION/deployments/multus-daemonset-thick.yml"
  # the upstream manifest limits the daemon to 50Mi of memory; on our Mac run it kept restarting, so give it room
  run k -n kube-system set resources ds/kube-multus-ds -c kube-multus --limits=memory=300Mi --requests=memory=100Mi
  run k -n kube-system rollout status ds/kube-multus-ds --timeout=240s
  run docker exec ckne-worker ls /etc/cni/net.d
}
step_3(){ title "Define a second network: a NetworkAttachmentDefinition (bridge + host-local, 192.168.50.0/24)"
  k apply -f - <<Y
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: storage-net}
spec:
  config: '{"cniVersion": "1.0.0", "name": "storage-net", "type": "bridge", "bridge": "br-storage", "ipam": {"type": "host-local", "subnet": "192.168.50.0/24", "rangeStart": "192.168.50.10", "rangeEnd": "192.168.50.50"}}'
Y
  run k get network-attachment-definitions
}
step_4(){ title "Two pods ask for it with an annotation, on the same node"
  for p in p1 p2; do k apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: $p, annotations: {k8s.v1.cni.cncf.io/networks: storage-net}}
spec:
  nodeName: ckne-worker
  containers: [{name: c, image: "busybox:1.36.1", command: ["sleep", "3600"]}]
Y
  done
  k wait --for=condition=Ready pod/p1 pod/p2 --timeout=120s >/dev/null
  run k exec p1 -- ip addr
  run k get pod p1 -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'; echo
  run docker exec ckne-worker ls -l /etc/cni/net.d
}
step_5(){ title "Traffic on the second network: p1 -> p2 over net1"
  local ip2; ip2=$(k exec p2 -- ip -4 -o addr show net1 | awk '{print $4}' | cut -d/ -f1)
  run k exec p1 -- ping -c 2 -I net1 "$ip2"
}
check_1(){ expect "Multus DaemonSet is ready" k -n kube-system rollout status ds/kube-multus-ds --timeout=5s; }
check_2(){ expect "NetworkAttachmentDefinition storage-net exists" k get network-attachment-definitions storage-net; }
check_3(){ expect "pod p1 has a second interface net1 in 192.168.50.0/24" sh -c "kubectl --context $CTX exec p1 -- ip -4 -o addr show net1 | grep -q 'inet 192.168.50.'"; }
check_4(){ expect "p1 reaches p2 over net1" sh -c "ip2=\$(kubectl --context $CTX exec p2 -- ip -4 -o addr show net1 | awk '{print \$4}' | cut -d/ -f1); kubectl --context $CTX exec p1 -- ping -c 1 -W 2 -I net1 \$ip2"; }
lab_main "$@"
