# CKNE course labs

Lab files for the Cloud Brewery Academy course **CKNE Exam Prep: Kubernetes Networking with Real Labs**. Every lab runs on your own machine, for free, in a local 3-node Kubernetes cluster made by kind. Each lab folder has a README and one script, `lab.sh`.

**Tested on Ubuntu 24.04 and on an Apple silicon Mac.** Other systems may work, but we haven't tested them.

## Every lab, four ways

The first three use the lab's script:

```bash
bash lab.sh run       # a fresh cluster, every step, then the check
bash lab.sh steps     # list the steps; bash lab.sh step N runs one
bash lab.sh check     # grades your cluster like an exam task: PASS or FAIL per requirement
bash lab.sh down      # delete the cluster
```

`bash run-all.sh labs/m01/1.2-cni labs/m01/1.3-ipam` runs several labs in a row and prints a summary.

The fourth is by hand: each lab's README has a **Walkthrough: copy, paste, compare** section. Every step has a short explanation, the commands as plain `kubectl` and `docker` lines to copy and paste, our real output to compare with yours, and what to look for. It starts with creating the cluster and ends with `bash lab.sh check`.

## Labs

| Module | Lab |
|---|---|
| Module 0: Welcome | [Lab 0.3: Working like the exam](labs/m00/0.3-exam-workflow/) |
| Module 1: Core infrastructure and CNI | [Lab 1.2: How a pod gets its network (CNI by hand)](labs/m01/1.2-cni/) |
| Module 1: Core infrastructure and CNI | [Lab 1.3: IPAM and pod CIDRs](labs/m01/1.3-ipam/) |
| Module 1: Core infrastructure and CNI | [Lab 1.4: Linux tools on a node (ip, iptables, tcpdump)](labs/m01/1.4-linux-tools/) |
| Module 1: Core infrastructure and CNI | [Lab 1.5: Troubleshooting pod connectivity and DNS](labs/m01/1.5-troubleshoot/) |
| Module 1: Core infrastructure and CNI | [Lab 1.6: Multi-interface pods with Multus](labs/m01/1.6-multus/) |

## What you need

- Docker with about 8 GB of memory for it. On a Mac we use Colima: `colima start --cpu 4 --memory 8`.
- kind, kubectl, Helm and jq. The versions we tested are pinned in [lib/versions.env](lib/versions.env).
- **Mac with Colima, once:** a 3-node cluster needs more file watchers than the VM allows by default. Without this, kube-proxy crashed on one node with "too many open files". Run:

```bash
colima ssh -- sudo sh -c 'printf "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n" > /etc/sysctl.d/99-kind.conf && sysctl --system'
```

## Licence

Code and configuration: Apache-2.0. Guides and other educational content: CC-BY-4.0. See [LICENSING.md](LICENSING.md).

This is an independent course, not affiliated with or endorsed by the Linux Foundation, the Cloud Native Computing Foundation, the Cilium project or the Istio project.
