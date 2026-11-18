# Lab 1.5: Troubleshooting pod connectivity and DNS

Lab for the course lesson **1.5 Troubleshooting pod connectivity and DNS**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

**This lab arrives broken.** Try it yourself first: `bash lab.sh up` builds the cluster with the faults in namespace `shop`, and `bash lab.sh check` tells you what the grader expects. Fix it until the check passes, then run the steps to compare with how we did it.

## Run it

```bash
cd labs/m01/1.5-troubleshoot
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. Symptom: the client can't reach api by name
2. DNS first: what resolver does the pod use?
3. Fix 1: recreate the client with the cluster's DNS (dnsPolicy ClusterFirst)
4. Still failing: name resolves, but nothing answers. Check the Service's endpoints
5. Fix 2: point the Service's selector at the pods' real label

## What the check looks for

- client resolves api.shop.svc.cluster.local
- Service api has ready endpoints
- client reaches http://api

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (130 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (99 s).
