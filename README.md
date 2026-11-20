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
| Module 2: Service networking and DNS | [Lab 2.1: L4 Services: ClusterIP, NodePort, LoadBalancer, ExternalName](labs/m02/2.1-services/) |
| Module 2: Service networking and DNS | [Lab 2.2: kube-proxy: iptables and nftables rules, read on a node](labs/m02/2.2-kube-proxy/) |
| Module 2: Service networking and DNS | [Lab 2.3: Replacing kube-proxy with Cilium](labs/m02/2.3-cilium-kpr/) |
| Module 2: Service networking and DNS | [Lab 2.4: Customising CoreDNS: stub domains and forwarders](labs/m02/2.4-coredns/) |
| Module 2: Service networking and DNS | [Lab 2.5: Endpoint availability: readiness and EndpointSlice conditions](labs/m02/2.5-endpointslices/) |
| Module 2: Service networking and DNS | [Lab 2.6: Troubleshooting Service traffic](labs/m02/2.6-troubleshoot-services/) |
| Module 2: Service networking and DNS | [Lab 2.7: Gateway API: Gateway and HTTPRoute](labs/m02/2.7-gateway-api/) |
| Module 3: Advanced traffic management | [Lab 3.1: LoadBalancer on bare metal: LB IPAM, L2 announcements and BGP](labs/m03/3.1-lb-ipam-bgp/) |
| Module 3: Advanced traffic management | [Lab 3.2: Egress gateway for cluster exit traffic](labs/m03/3.2-egress-gateway/) |
| Module 3: Advanced traffic management | [Lab 3.3: Cross-cluster service discovery and load balancing (two clusters)](labs/m03/3.3-clustermesh/) |
| Module 3: Advanced traffic management | [Lab 3.4: Optimising LLM traffic: Gateway API Inference Extension](labs/m03/3.4-inference-gateway/) |
| Module 4: Network security and policy | [Lab 4.1: NetworkPolicy: how selectors and rules combine](labs/m04/4.1-networkpolicy/) |
| Module 4: Network security and policy | [Lab 4.2: Default deny, egress and DNS: locking a namespace down](labs/m04/4.2-default-deny/) |
| Module 4: Network security and policy | [Lab 4.3: Node and pod encryption: WireGuard, proven with tcpdump](labs/m04/4.3-wireguard/) |
| Module 4: Network security and policy | [Lab 4.4: TLS certificates for Gateway API with cert-manager](labs/m04/4.4-cert-manager-tls/) |
| Module 4: Network security and policy | [Lab 4.5: Pod-level authentication and authorisation: Istio ambient mTLS + AuthorizationPolicy](labs/m04/4.5-istio-ambient-authz/) |
| Module 5: Observability | [Lab 5.1: Network health from metrics: Hubble and Prometheus](labs/m05/5.1-hubble-metrics/) |
| Module 5: Observability | [Lab 5.2: End-to-end performance with tracing](labs/m05/5.2-tracing/) |
| Module 5: Observability | [Lab 5.3: Auditing traffic with logs: flow logs and policy audit mode](labs/m05/5.3-flow-logs-audit/) |
| Module 6: Exam practice | [Mock exam 1: 15 tasks, 2 hours](labs/m06/6.2-mock-exam-1/) |
| Module 6: Exam practice | [Mock exam 2: 15 tasks, 2 hours](labs/m06/6.3-mock-exam-2/) |
| Module 6: Exam practice | [Mock exam 3: 15 tasks, 2 hours](labs/m06/6.4-mock-exam-3/) |

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
