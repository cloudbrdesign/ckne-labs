# Lab 1.3: IPAM and pod CIDRs

Lab for the course lesson **1.3 IPAM and pod CIDRs**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.3-ipam
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. The cluster's pod range, set on kube-controller-manager
2. Each node gets its own slice: spec.podCIDR
3. Pods get IPs from their node's slice
4. The IPAM plugin's own records on a node: host-local keeps one file per allocated IP
5. Services use a different range: the Service CIDR

## What the check looks for

- every ipam-demo pod's IP is inside its node's podCIDR
- no two nodes share a podCIDR
- ckne-worker has host-local records for its pods (in its host-local data directory)

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (73 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (50 s).
