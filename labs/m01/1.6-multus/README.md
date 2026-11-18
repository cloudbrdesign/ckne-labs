# Lab 1.6: Multi-interface pods with Multus

Lab for the course lesson **1.6 Multi-interface pods with Multus**. It creates a fresh 3-node kind cluster named `ckne` (kind with Cilium as the network plugin, replacing kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.6-multus
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. Install the CNI reference plugins (bridge, macvlan, ...) on every node
2. Install Multus (version from lib/versions.env) (thick plugin): it becomes the first CNI and delegates to Cilium
3. Define a second network: a NetworkAttachmentDefinition (bridge + host-local, 192.168.50.0/24)
4. Two pods ask for it with an annotation, on the same node
5. Traffic on the second network: p1 -> p2 over net1

## What the check looks for

- Multus DaemonSet is ready
- NetworkAttachmentDefinition storage-net exists
- pod p1 has a second interface net1 in 192.168.50.0/24
- p1 reaches p2 over net1

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (180 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (155 s).
