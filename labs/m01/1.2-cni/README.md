# Lab 1.2: How a pod gets its network (CNI by hand)

Lab for the course lesson **1.2 CNI: how a pod gets its network**. It creates a fresh 3-node kind cluster named `ckne` (kind with no network plugin: you install one by hand), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.2-cni
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. A cluster with no network plugin: nodes are NotReady
2. What every node already has: CNI plugin binaries, and a pod CIDR from Kubernetes
3. Write a CNI config on each node: ptp plugin + host-local IPAM for that node's pod CIDR
4. Route each node's pod CIDR to that node (the part a real CNI automates)
5. Nodes turn Ready; CoreDNS starts
6. Two pods on different nodes reach each other directly, without NAT

## What the check looks for

- all nodes Ready
- every node has a CNI config in /etc/cni/net.d
- CoreDNS is available
- pod a (ckne-worker) can ping pod b (ckne-worker2)
- pod b sees pod a's own IP as the source, not a node IP (no NAT)

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (50 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (41 s).
