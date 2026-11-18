# Lab 0.3: Working like the exam

Lab for the course lesson **0.3 Working like the exam**. It creates a fresh 3-node kind cluster named `ckne` (kind with its default network (kindnet) and kube-proxy), runs the steps below, and then checks the result the way an exam task is graded.

## Run it

```bash
cd labs/m00/0.3-exam-workflow
bash lab.sh run       # fresh cluster, every step, then the check
bash lab.sh steps     # list the steps
bash lab.sh step 3    # run one step and look
bash lab.sh check     # grade your cluster
bash lab.sh down      # delete the cluster
```

## Steps

1. Which cluster am I talking to? (every exam task starts here)
2. Get onto a node: in the exam you ssh to a named host; in our lab the nodes are containers
3. Look up a field without leaving the terminal: kubectl explain
4. Generate YAML instead of writing it: --dry-run=client -o yaml
5. Verify like the grader: test from inside the cluster, not from your laptop

## What the check looks for

- deployment web has 2 ready replicas
- service web exposes port 80
- service web has 2 ready endpoints
- web answers from inside the cluster

## Tested

18 November 2026, versions from `lib/versions.env`: all checks passed on Ubuntu 24.04 (74 s for `bash lab.sh run`) and on an Apple silicon Mac with Colima (55 s).
