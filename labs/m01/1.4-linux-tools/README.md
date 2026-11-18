# Lab 1.4: Linux tools on a node (ip, iptables, tcpdump)

Lab for the course lesson **1.4 Linux tools on a node**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m01/1.4-linux-tools
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. ip: the pod's side and the node's side of its veth pair
2. ip route on the node: how traffic reaches other nodes' pods
3. iptables: kube-proxy's rules for Service b (iptables mode)
4. tcpdump: watch the packets (a debug pod on the node's network, with tcpdump in it)

## What the check looks for

- node ckne-worker routes pod a's IP to a local veth interface
- kube-proxy has an iptables rule for Service default/b
- pod a reaches Service b by name

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (102 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (67 s).
