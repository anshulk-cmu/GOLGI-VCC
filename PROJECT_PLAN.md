# Characterizing the Impact of Resource Overcommitment on Serverless Function Latency Across Workload Profiles

> **Course:** CSL7510 — Cloud Computing
> **Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056), Kirtiman Sarangi (G25AI1024)
> **Programme:** M.Tech Artificial Intelligence, IIT Jodhpur
> **Inspired by:** Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing (ACM SoCC 2023, Best Paper Award)
> **Paper DOI:** [10.1145/3620678.3624645](https://doi.org/10.1145/3620678.3624645)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Motivation and Research Questions](#2-motivation-and-research-questions)
3. [Background](#3-background)
4. [Experimental Design Overview](#4-experimental-design-overview)
5. [Phase 0 — AWS Infrastructure Setup](#5-phase-0--aws-infrastructure-setup) ✅
6. [Phase 1 — Benchmark Deployment and Baseline Characterization](#6-phase-1--benchmark-deployment-and-baseline-characterization) ✅
7. [Phase 2 — Multi-Level Degradation Curves](#7-phase-2--multi-level-degradation-curves) 🔄
8. [Phase 3 — Analysis and Visualization](#8-phase-3--analysis-and-visualization)
9. [Phase 4 — Report Writing and Demo](#9-phase-4--report-writing-and-demo)
10. [Future Scope](#10-future-scope)
11. [Appendix A — Cost Estimation](#11-appendix-a--cost-estimation)
12. [Appendix B — Troubleshooting Guide](#12-appendix-b--troubleshooting-guide)
13. [Appendix C — File and Directory Structure](#13-appendix-c--file-and-directory-structure)
14. [Appendix D — Mathematical Foundations](#14-appendix-d--mathematical-foundations)
15. [Appendix E — References and Resources](#15-appendix-e--references-and-resources)

> **Execution Logs:** Step-by-step execution details with commands, outputs, and reasoning are tracked separately per phase:
> - Phase 0 (Infrastructure): [`execution_log_phase0.md`](execution_log_phase0.md)
> - Phase 1 (Benchmark Functions): [`execution_log_phase1.md`](execution_log_phase1.md)

---

## 1. Executive Summary

### 1.1 The Problem

Serverless functions waste resources. Studies show functions use only ~25% of their reserved CPU and memory on average — the remaining 75% sits idle. Cloud providers lose revenue, and users overpay.

The obvious fix is **resource overcommitment**: allocate less physical capacity than the sum of all reservations, betting that not everyone will spike at once. This is standard practice in virtualization (VMware routinely overcommits memory by 2-4x). But serverless functions are short-lived, bursty, and densely co-located — when a provider blindly squeezes resource allocations, multiple co-located functions can spike simultaneously, causing latency degradation of up to 183% at P95.

### 1.2 The Hypothesis We Test

The Golgi paper (Li et al., SoCC 2023) proposes a profile-aware scheduling system built on a foundational hypothesis:

> **Different function workload profiles respond differently to resource overcommitment. CPU-bound functions degrade proportionally to CPU reduction, I/O-bound functions are resilient, and mixed functions exhibit non-linear degradation from Linux CFS scheduler interactions.**

The Golgi paper uses this hypothesis as the motivation for building an ML-guided routing system, but their evaluation focuses on end-to-end system performance. The hypothesis itself — that overcommitment impact is profile-dependent and predictable — is assumed, not independently validated.

**We provide that characterization.** This project is a systematic empirical study of how Linux CFS quota enforcement creates profile-dependent latency degradation under container resource overcommitment. We measure this across three workload profiles (CPU-bound, I/O-bound, mixed) on real cloud infrastructure, going beyond a single-point comparison to produce degradation curves across multiple overcommitment levels and provide a mechanistic explanation of CFS quota boundary effects on mixed workloads.

### 1.3 Research Questions

| # | Research Question | Experiment |
|---|---|---|
| RQ1 | How does P95 latency degrade as CPU allocation decreases, and does the shape differ by workload profile? | Phase 2: Multi-Level Degradation Curves |
| RQ2 | Can the bimodal latency behavior of mixed functions under overcommitment be explained by CFS quota boundary effects? | Phase 1 bimodality observation + Pre-Phase 2 CPU burst measurement |

### 1.4 Target Contributions

1. **Degradation curves** showing the relationship between CPU allocation and P95 latency for three workload profiles, tested at 5 overcommitment levels on real infrastructure (not simulation)
2. **Mechanistic explanation** of bimodal CFS throttling behavior in mixed workloads, validated experimentally through direct cgroup v2 CPU burst measurement and throttle ratio analysis
3. **Empirical characterization** of the profile-dependent degradation phenomenon that motivates profile-aware scheduling systems like Golgi — grounded in direct measurement on real infrastructure

### 1.5 Technology Stack

| Component | Choice | Why |
|---|---|---|
| Cloud | AWS EC2 (t3.xlarge workers) | Real hardware with full kernel access |
| Orchestration | k3s | Lightweight Kubernetes — same cgroup/CFS behavior as production K8s |
| Serverless framework | OpenFaaS | Gives us container-level resource control via K8s manifests |
| Benchmarks | 3 functions (Python + Go) | CPU-bound, I/O-bound, mixed — covering the three major profiles |
| Metrics | cgroup v2 + /proc | Direct kernel-level measurement, no abstraction layers |
| Analysis | Python (numpy, matplotlib) | Standard scientific computing stack |

---

## 2. Motivation and Research Questions

### 2.1 The Serverless Resource Problem

Serverless computing lets developers deploy individual functions without managing servers. The cloud provider handles scaling, container lifecycle, and infrastructure. Users write a function, push it, and pay per invocation.

The pricing model works like this: a user declares how much memory their function needs (say, 512 MB), and the platform allocates CPU proportionally. The platform then reserves those resources on a physical machine for the lifetime of each invocation. This reservation is a guarantee — if the user asks for 512 MB, the platform sets a hard cgroup limit at 512 MB, and no other container can touch that memory.

The problem is that users are terrible at estimating what they actually need:

```
AWS Lambda: 54% of functions configured with >= 512 MB
             Average actual usage: 65 MB
             Median actual usage: 29 MB

AliCloud:    Most instances use 20-60% of allocated memory

Average:     Functions use ~25% of reserved resources
```

This means 75% of reserved resources sit idle. If a cloud provider runs 1 million function instances, 750,000 instances worth of resources are wasted.

### 2.2 Why Blind Overcommitment Fails

The obvious fix is overcommitment: allocate less physical memory and CPU than the sum of all reservations. This is standard practice in virtualization. VMware ESXi routinely overcommits memory by 2-4x using ballooning, transparent page sharing, and swap. It works because VM workloads are relatively stable and long-lived.

Serverless functions are different. They are short-lived (milliseconds to seconds), bursty (zero to thousands of concurrent invocations in seconds), and densely co-located (dozens of different functions share the same physical host). When a provider blindly squeezes resource allocations, multiple co-located functions can spike simultaneously. They compete for shared CPU cycles, memory bandwidth, and last-level cache. The result is contention, and contention means latency degradation.

Li et al. [1] measured this directly: blind overcommitment caused P95 latency to increase by up to 183%. For a function serving an API endpoint with a 200ms SLO, that kind of degradation is a contract violation.

### 2.3 The Golgi Hypothesis

The Golgi paper proposes that overcommitment can work — but only if the system understands which functions can tolerate reduced resources and which cannot. Their key insight is that the impact of overcommitment depends on the function's resource profile:

- **CPU-bound functions** (e.g., image processing, model inference): Latency scales roughly linearly with CPU reduction. Cut CPU by 2x, expect ~2x slower execution.
- **I/O-bound functions** (e.g., database queries, API calls): Latency is dominated by network round-trips, not CPU. Significant CPU reduction causes minimal latency increase.
- **Mixed functions** (e.g., log parsing with regex + string manipulation): Exhibit non-linear, sometimes disproportionate degradation due to interactions with the Linux CFS (Completely Fair Scheduler) quota mechanism.

The Golgi paper builds an entire ML-guided routing system on top of this hypothesis. But the hypothesis itself — that the three profiles respond differently and predictably to overcommitment — is not isolated and tested independently. Their evaluation measures end-to-end system metrics (cost reduction, SLO violation rate), not the underlying profile-dependent degradation behavior.

### 2.4 What We Do Differently

We isolate and test the hypothesis directly:

1. **Multiple overcommitment levels.** Instead of testing one OC configuration per function, we test 5 levels (100%, 80%, 60%, 40%, 20% of original CPU). This produces degradation curves, not just point comparisons. Knowing that a CPU-bound function is 2.4x slower at one specific overcommitment level tells an operator very little. Knowing that degradation is linear from 100% to 40% CPU but accelerates sharply below 40% gives an operator actionable guidance for setting overcommitment policies.

2. **CFS mechanistic analysis.** We experimentally validate that the bimodal latency distribution in mixed functions comes from CFS quota boundary crossings, not from other sources of variance. We do this by measuring the per-request CPU burst size via cgroup v2 `cpu.stat` counters and showing that the burst size relative to the CFS quota boundary predicts the observed bimodal latency distribution.

### 2.5 Why AWS?

| Reason | Detail |
|---|---|
| Educational access | AWS Academy / free tier available |
| EC2 flexibility | Full Linux VMs with kernel access (unlike Lambda) |
| k3s compatibility | k3s runs on any Linux EC2 instance |
| cgroup v2 | Amazon Linux 2023 ships with cgroup v2 — modern, well-documented |
| OpenFaaS support | OpenFaaS is cloud-agnostic; works on any K8s |

**Why NOT AWS Lambda?** Lambda is a black box. You cannot read cgroup files (no kernel access), control CPU allocation precisely, or observe CFS scheduler behavior. We need raw Linux VMs to access the kernel interfaces that control and expose overcommitment effects.

### 2.6 Why This Matters for Cloud Computing Education

This project sits at the intersection of four core cloud computing topics:

1. **Resource management** — overcommitment, bin packing, utilization optimization
2. **Linux kernel scheduling** — CFS, cgroups, CPU quotas, throttling
3. **Serverless computing** — FaaS architecture, container resource control, OpenFaaS
4. **Empirical systems research** — controlled experiments, statistical analysis, reproducibility

Understanding how the kernel scheduler interacts with container resource limits is fundamental to reasoning about performance in containerized cloud environments. This project forces that understanding through direct measurement, not just theory.

---

## 3. Background

### 3.1 Linux CFS and CPU Quotas

The Linux Completely Fair Scheduler (CFS) is the default CPU scheduler in the Linux kernel. CFS maintains a virtual runtime for each runnable task and always picks the task with the smallest virtual runtime to run next. This provides proportional CPU sharing.

For containers, Kubernetes uses the CFS bandwidth controller to enforce CPU limits. The controller works with two parameters:

- **cpu.max period** (default: 100,000 µs = 100ms): The length of one CFS period
- **cpu.max quota**: How many microseconds of CPU time the container can use within each period

For example, a container with `cpu.max = "40000 100000"` gets 40ms of CPU time per 100ms period — equivalent to 0.4 CPU cores (400m in Kubernetes notation).

**The throttling mechanism:**

When a container exhausts its CPU quota within a period, the kernel marks it as throttled. All threads in the container are paused until the next period begins. The container then gets a fresh quota and resumes execution.

This creates a critical behavioral difference:

```
Scenario A: Function uses 35ms of CPU per request, quota = 40ms
  → Completes within one period. Latency ≈ 35ms wall-clock.

Scenario B: Function uses 45ms of CPU per request, quota = 40ms
  → Uses 40ms, gets throttled, waits 60ms for next period,
    uses remaining 5ms. Latency ≈ 40 + 60 + 5 = 105ms wall-clock.

The difference between 35ms and 45ms of CPU work is 10ms.
The difference in wall-clock latency is 70ms.
```

This step-function behavior at the quota boundary is the key mechanism behind bimodal latency in mixed functions. A function whose CPU burst size is near the quota boundary will sometimes complete within one period (fast mode) and sometimes spill into the next (slow mode), producing a bimodal latency distribution.

### 3.2 cgroup v2 and Resource Control

cgroup v2 (unified hierarchy) is the modern Linux control group interface. Amazon Linux 2023 uses cgroup v2 by default. Key files for CPU and memory measurement:

**CPU metrics:**
```
/sys/fs/cgroup/<pod-path>/cpu.stat
  usage_usec 123456789      # Total CPU time consumed (microseconds)
  user_usec 100000000       # User-space CPU time
  system_usec 23456789      # Kernel-space CPU time
  nr_periods 1000           # Number of CFS periods elapsed
  nr_throttled 50           # Number of periods where container was throttled
  throttled_usec 5000000    # Total time spent throttled (microseconds)

/sys/fs/cgroup/<pod-path>/cpu.max
  40000 100000              # quota period (microseconds)
```

**Memory metrics:**
```
/sys/fs/cgroup/<pod-path>/memory.current  # Current usage in bytes
/sys/fs/cgroup/<pod-path>/memory.max      # Configured limit in bytes
```

The `nr_throttled` and `throttled_usec` counters are particularly important for this study — they directly measure CFS throttling events, which are the mechanism behind overcommitment-induced latency degradation.

### 3.3 The Overcommitment Formula

Following the Golgi paper (Section 2.3), we compute overcommitted resource allocations using:

```
OC_allocation = alpha × claimed + (1 - alpha) × actual_usage

Where:
  alpha       = 0.3 (slack factor — 30% safety margin above actual usage)
  claimed     = resource level declared by the user
  actual_usage = measured peak usage under normal load

Example:
  CPU claimed = 1000m, CPU actual = 150m
  OC_CPU = 0.3 × 1000 + 0.7 × 150 = 300 + 105 = 405m

  Memory claimed = 512 Mi, Memory actual = 80 Mi
  OC_Memory = 0.3 × 512 + 0.7 × 80 = 153.6 + 56 = 210 Mi
```

This formula produces a single OC level per function — the "default" overcommitment that a system like Golgi would use. In Phase 1, we measure latency at this default OC level. In Phase 2, we go further by testing multiple levels between full allocation and aggressive overcommitment.

### 3.4 The Golgi Paper's Two-Instance Model

For context, the Golgi system maintains two sets of container replicas per function:

- **Non-OC instances:** Full resources as configured by the user. Safe but expensive.
- **OC instances:** Reduced resources per the overcommitment formula. Cheap but risky.

An ML classifier predicts whether an OC instance can handle a request without violating the latency SLO, and a router directs traffic accordingly. The result: ~42% memory cost reduction while maintaining P95 latency SLOs.

Our study characterizes the foundational observation that makes this system design sensible — that overcommitment impact varies predictably by workload profile. If all functions degraded identically under overcommitment, there would be no reason to build a profile-aware scheduler. Our data shows they do not degrade identically, and the differences are both large and mechanistically explainable.

---

## 4. Experimental Design Overview

### 4.1 Experiment Matrix

Our study consists of two experiments, each answering one research question. The experiments build on each other — Phase 1 establishes the baseline and reveals the bimodal latency phenomenon in mixed functions, the Pre-Phase 2 CPU burst measurement provides the mechanistic explanation (answering RQ2), and Phase 2 varies the independent variable (CPU allocation) to produce degradation curves (answering RQ1).

```
Phase 0: Infrastructure Setup (AWS, k3s, OpenFaaS)              ✅ COMPLETED
Phase 1: Baseline Characterization (Non-OC vs default OC)       ✅ COMPLETED
  └─ Pre-Phase 2: CPU Burst Measurement (cgroup v2 analysis)    ✅ COMPLETED
Phase 2: Degradation Curves (5 CPU levels × 3 functions)        🔄 IN PROGRESS
Phase 3: Analysis and Visualization
Phase 4: Report Writing and Demo
```

### 4.2 Function Selection

We deploy 3 functions covering three distinct resource profiles:

| Function | Profile | Language | Key Characteristic |
|---|---|---|---|
| image-resize | CPU-bound | Python | Latency dominated by CPU cycles (Pillow Lanczos resampling) |
| db-query | I/O-bound | Python | Latency dominated by network round-trips (Redis GET/SET/GET) |
| log-filter | Mixed | Go | CPU bursts (regex + string ops) near CFS quota boundary |

Each function is deployed in multiple variants with different CPU/memory limits. The Non-OC variant gets full resources; OC variants get reduced resources at various levels.

### 4.3 Measurement Methodology

All latency measurements follow a consistent protocol:

1. **Warm-up:** 10 requests discarded (fills caches, establishes connections)
2. **Measurement:** 200 sequential requests, each timed end-to-end from the load generator
3. **Isolation:** One function variant measured at a time — no concurrent load on other functions
4. **Repetition:** Each measurement repeated 3 times to assess variance
5. **Timing:** `date +%s%N` on the client side (nanosecond wall-clock, converted to milliseconds)
6. **Environment:** All measurements from the same load generator instance (t3.medium) to the same cluster, same time of day to minimize EC2 neighbor noise

### 4.4 Independent and Dependent Variables

| Variable | Type | Values |
|---|---|---|
| Function profile | Independent (categorical) | CPU-bound, I/O-bound, Mixed |
| CPU allocation | Independent (continuous) | 100%, 80%, 60%, 40%, 20% of Non-OC level |
| P50 latency | Dependent | Measured per experiment |
| P95 latency | Dependent | Measured per experiment |
| P99 latency | Dependent | Measured per experiment |
| CFS throttled periods | Dependent | Read from cgroup `cpu.stat` |
| CFS throttled time | Dependent | Read from cgroup `cpu.stat` |

---

## 5. Phase 0 — AWS Infrastructure Setup ✅ COMPLETED

> **Status:** Completed on 2026-04-11. Full execution details in [`execution_log_phase0.md`](execution_log_phase0.md).

### 5.1 AWS Account Preparation

**Step 0.1: Create or access an AWS account**

You need an AWS account with EC2 permissions. If using AWS Academy:
- Go to AWS Academy LMS
- Launch the Learner Lab
- Note: Academy accounts have restrictions (no IAM changes, limited regions)

If using a personal account:
- Enable MFA on root account
- Create an IAM user with programmatic access
- Attach `AmazonEC2FullAccess` and `AmazonVPCFullAccess` policies

**Step 0.2: Install AWS CLI**

```bash
# On your local machine (Linux/Mac)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output (json)
```

**Step 0.3: Generate SSH key pair**

```bash
# Generate a key pair for EC2 access
aws ec2 create-key-pair \
  --key-name golgi-key \
  --query 'KeyMaterial' \
  --output text > golgi-key.pem

chmod 400 golgi-key.pem
```

### 5.2 Network Setup

**Design choice:** We use a single VPC with one public subnet. All nodes communicate
over the private network. The load generator sends requests to the master node's public IP.

```bash
# Step 0.4: Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' \
  --output text)

aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=golgi-vpc

# Step 0.5: Create subnet
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' \
  --output text)

# Step 0.6: Create and attach internet gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Step 0.7: Create route table with internet access
RTB_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id $RTB_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET_ID

# Step 0.8: Enable auto-assign public IP
aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET_ID \
  --map-public-ip-on-launch
```

**Step 0.9: Create security group**

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name golgi-sg \
  --description "Experiment cluster security group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

# Allow SSH from your IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 \
  --cidr "${MY_IP}/32"

# Allow all traffic within the VPC (inter-node communication)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol all \
  --cidr 10.0.0.0/16

# Allow HTTP/HTTPS from your IP (for OpenFaaS gateway)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 8080 \
  --cidr "${MY_IP}/32"

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 31112 \
  --cidr "${MY_IP}/32"

# Allow NodePort range (for K8s services)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 30000-32767 \
  --cidr "${MY_IP}/32"
```

### 5.3 EC2 Instance Provisioning

**Design choice:** We use 5 EC2 instances total.

| Role | Instance Type | vCPUs | RAM | Purpose | Count |
|---|---|---|---|---|---|
| Master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway | 1 |
| Worker | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement | 3 |
| Load Gen | t3.medium | 2 | 4 GB | Request generation, latency measurement | 1 |

**Why t3.xlarge for workers?** Each worker needs to run multiple function containers with different resource limits. With 4 vCPUs and 16 GB RAM, each worker can host approximately 15-20 function instances simultaneously. The t3.xlarge also provides enough CPU headroom that our overcommitment experiments are not confounded by host-level CPU contention.

**Step 0.10: Launch instances**

```bash
# Amazon Linux 2023 AMI (us-east-1)
AMI_ID="ami-0c101f26f147fa7fd"  # Amazon Linux 2023, x86_64

# Launch master node
MASTER_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name golgi-key \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-master}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

# Launch 3 worker nodes
for i in 1 2 3; do
  aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.xlarge \
    --key-name golgi-key \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=golgi-worker-${i}}]"
done

# Launch load generator
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name golgi-key \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-loadgen}]'
```

**Step 0.11: Record IP addresses**

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=golgi-*" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table
```

### 5.4 Install k3s

**Why k3s over full Kubernetes?**
- Single binary (~50 MB vs ~300 MB for kubeadm)
- Built-in containerd (no separate Docker install)
- Built-in CoreDNS
- Same K8s API — `kubectl` commands are identical
- Same CFS/cgroup behavior — the kernel scheduler is identical
- Installs in under 30 seconds

**Step 0.12: Install k3s on master**

```bash
ssh -i golgi-key.pem ec2-user@$MASTER_PUBLIC_IP

# Install k3s server
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --node-name golgi-master

# Get the join token for workers
sudo cat /var/lib/rancher/k3s/server/node-token

# Verify
sudo kubectl get nodes
```

**Step 0.13: Join worker nodes**

On each worker node:
```bash
ssh -i golgi-key.pem ec2-user@$WORKER_PUBLIC_IP

curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_PRIVATE_IP}:6443 \
  K3S_TOKEN=${K3S_TOKEN} sh -s - \
  --node-name golgi-worker-N
```

**Step 0.14: Verify cluster**

```bash
sudo kubectl get nodes -o wide
# Expected: 1 master + 3 workers, all Ready
```

**Step 0.15: Label worker nodes**

```bash
kubectl label node golgi-worker-1 role=worker node-type=function-host
kubectl label node golgi-worker-2 role=worker node-type=function-host
kubectl label node golgi-worker-3 role=worker node-type=function-host
```

### 5.5 Install OpenFaaS

**Step 0.16: Install OpenFaaS via Helm**

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update

kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

OPENFAAS_PASSWORD=$(head -c 16 /dev/urandom | sha256sum | head -c 32)
kubectl -n openfaas create secret generic basic-auth \
  --from-literal=basic-auth-user=admin \
  --from-literal=basic-auth-password="$OPENFAAS_PASSWORD"

helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=false \
  --set gateway.replicas=1 \
  --set queueWorker.replicas=1 \
  --set basic_auth=true \
  --set serviceType=NodePort

kubectl -n openfaas rollout status deployment/gateway

curl -sL https://cli.openfaas.com | sudo sh

export OPENFAAS_URL=http://127.0.0.1:31112
echo -n $OPENFAAS_PASSWORD | faas-cli login --username admin --password-stdin
```

### 5.6 Install Dependencies on All Nodes

```bash
# On each worker node:
sudo yum install -y python3 python3-pip

# On master node:
pip3 install --user flask requests numpy scikit-learn pandas matplotlib
```

### 5.7 Verify cgroup Version

```bash
# On a worker node:
stat -fc %T /sys/fs/cgroup/
# "cgroup2fs" = cgroup v2 ✓

# Verify unified hierarchy
ls /sys/fs/cgroup/
# Should show: cgroup.controllers, cgroup.subtree_control, cpu.stat, memory.stat, etc.
```

**Result:** Amazon Linux 2023 uses cgroup v2. All CPU metric paths use the unified hierarchy (`/sys/fs/cgroup/<path>/cpu.stat`). The `nr_throttled` and `throttled_usec` counters needed for CFS throttling analysis are available in `cpu.stat`.

### 5.8 Checkpoint: Phase 0 Complete ✅

```
[x] AWS VPC, subnet, and security group created
[x] 5 EC2 instances running (1 master, 3 workers, 1 loadgen)
[x] k3s cluster operational with 4 nodes (1 server + 3 agents)
[x] OpenFaaS installed and gateway accessible
[x] faas-cli authenticated
[x] Python + dependencies installed on all nodes
[x] cgroup v2 confirmed on all workers
[x] All SSH connections working
[x] All private IPs recorded
```

---

## 6. Phase 1 — Benchmark Deployment and Baseline Characterization ✅ COMPLETED

> **Status:** Completed on 2026-04-12. Full execution details in [`execution_log_phase1.md`](execution_log_phase1.md).

### 6.1 Function Implementation

> **Template Signature Note:** The pseudocode below shows simplified handler signatures for
> readability. The actual OpenFaaS templates require specific signatures:
> - **python3-http:** `def handle(event, context)` where `event.body` has the request data,
>   returning `{"statusCode": 200, "body": "...", "headers": {...}}`
> - **golang-http:** `func Handle(req handler.Request) (handler.Response, error)` using the
>   `github.com/openfaas/templates-sdk/go-http` SDK package
>
> See [`execution_log_phase1.md`](execution_log_phase1.md) Step 1.2 for the exact handler code
> and the rationale behind each template's signature design.

#### F1: image-resize (CPU-bound, Python)

```python
# Pseudocode for image-resize function
# 1. Receive HTTP request with image dimensions (width × height)
# 2. Generate a random RGB image in memory (simulates receiving an image)
# 3. Resize the image using PIL/Pillow Lanczos resampling (CPU-intensive)
# 4. Return the resized image dimensions and processing time

def handle(req):
    params = json.loads(req)
    width = params.get("width", 1920)
    height = params.get("height", 1080)

    # Generate random image
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    for i in range(width):
        for j in range(height):
            pixels[i, j] = (random.randint(0, 255),
                           random.randint(0, 255),
                           random.randint(0, 255))

    # CPU-intensive resize
    resized = img.resize((width // 2, height // 2), Image.LANCZOS)

    return json.dumps({
        "original": f"{width}x{height}",
        "resized": f"{width//2}x{height//2}",
        "timestamp": time.time()
    })
```

**Why this design?** `Image.LANCZOS` resampling applies a windowed sinc interpolation kernel across every output pixel, making execution time directly proportional to available CPU cycles. Latency scales predictably with CPU contention — exactly the behavior we want from a CPU-bound benchmark.

#### F2: db-query (I/O-bound, Python)

```python
# Pseudocode for db-query function
# 1. Connect to Redis
# 2. Perform GET → SET → GET sequence (network-bound operations)
# 3. Return result with timing info

def handle(req):
    params = json.loads(req)
    key = params.get("key", "default_key")

    r = redis.Redis(host=REDIS_HOST, port=6379, db=0)

    value = r.get(key)
    r.set(f"result:{key}", json.dumps({
        "value": value.decode() if value else "null",
        "timestamp": time.time()
    }))
    result = r.get(f"result:{key}")

    return result.decode()
```

**Why Redis?** Lightweight (runs as a single K8s pod, ~50 MB memory), and the function's latency is dominated by three network round-trips to Redis, not by CPU processing. On an OC instance with reduced CPU, the function behaves almost identically to Non-OC — network latency is independent of CPU allocation.

#### F3: log-filter (Mixed, Go)

```go
// Pseudocode for log-filter function
// 1. Generate 1000 synthetic log lines
// 2. Apply regex matching to filter ERROR/WARN/CRITICAL entries (CPU)
// 3. Run IP anonymization on each match (string manipulation, CPU)
// 4. Return filtered count and sample

func Handle(w http.ResponseWriter, r *http.Request) {
    logLines := generateLogLines(1000)

    pattern := regexp.MustCompile(`ERROR|WARN|CRITICAL`)
    var filtered []string
    for _, line := range logLines {
        if pattern.MatchString(line) {
            sanitized := anonymizeIPs(line)
            filtered = append(filtered, sanitized)
        }
    }

    result := map[string]interface{}{
        "total_lines":    len(logLines),
        "filtered_count": len(filtered),
        "sample":         filtered[:min(5, len(filtered))],
    }
    json.NewEncoder(w).Encode(result)
}
```

**Why this is "mixed":** The function exercises both CPU (regex engine, string manipulation) and memory (holding 1000 strings, building filtered output). Its CPU burst size is close to the CFS quota boundary at typical OC levels, creating bimodal latency behavior — sometimes the work completes within one CFS period, sometimes it spills into the next.

### 6.2 Resource Configurations

**Non-OC (baseline):** Full resources as a user would typically configure.

| Function | CPU | Memory |
|---|---|---|
| image-resize | 1000m | 512 Mi |
| db-query | 500m | 256 Mi |
| log-filter | 500m | 256 Mi |

**Default OC level:** Computed using the overcommitment formula `OC = 0.3 × claimed + 0.7 × actual`:

| Function | Claimed CPU | Actual CPU | OC CPU | Claimed Mem | Actual Mem | OC Mem | CPU Reduction |
|---|---|---|---|---|---|---|---|
| image-resize | 1000m | ~150m | 405m | 512 Mi | ~80 Mi | 210 Mi | 2.47× |
| db-query | 500m | ~50m | 185m | 256 Mi | ~40 Mi | 105 Mi | 2.70× |
| log-filter | 500m | ~80m | 206m | 256 Mi | ~30 Mi | 98 Mi | 2.43× |

### 6.3 Deployment

**Step 1.1: Deploy Redis**

```yaml
# redis-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
```

**Step 1.2: Create OpenFaaS function YAML**

```yaml
# stack.yml
version: 1.0
provider:
  name: openfaas
  gateway: http://127.0.0.1:31112

functions:
  image-resize:
    lang: python3-http
    handler: ./functions/image-resize
    image: golgi/image-resize:latest
    environment:
      write_timeout: 60s
      read_timeout: 60s
      exec_timeout: 60s
      max_inflight: 4
    requests:
      memory: 512Mi
      cpu: "1000m"
    limits:
      memory: 512Mi
      cpu: "1000m"

  image-resize-oc:
    lang: python3-http
    handler: ./functions/image-resize
    image: golgi/image-resize:latest
    environment:
      write_timeout: 60s
      read_timeout: 60s
      exec_timeout: 60s
      max_inflight: 4
    requests:
      memory: 210Mi
      cpu: "405m"
    limits:
      memory: 210Mi
      cpu: "405m"

  db-query:
    lang: python3-http
    handler: ./functions/db-query
    image: golgi/db-query:latest
    environment:
      REDIS_HOST: redis.openfaas-fn.svc.cluster.local
      max_inflight: 4
    requests:
      memory: 256Mi
      cpu: "500m"
    limits:
      memory: 256Mi
      cpu: "500m"

  db-query-oc:
    lang: python3-http
    handler: ./functions/db-query
    image: golgi/db-query:latest
    environment:
      REDIS_HOST: redis.openfaas-fn.svc.cluster.local
      max_inflight: 4
    requests:
      memory: 105Mi
      cpu: "185m"
    limits:
      memory: 105Mi
      cpu: "185m"

  log-filter:
    lang: golang-http
    handler: ./functions/log-filter
    image: golgi/log-filter:latest
    environment:
      max_inflight: 4
    requests:
      memory: 256Mi
      cpu: "500m"
    limits:
      memory: 256Mi
      cpu: "500m"

  log-filter-oc:
    lang: golang-http
    handler: ./functions/log-filter
    image: golgi/log-filter:latest
    environment:
      max_inflight: 4
    requests:
      memory: 98Mi
      cpu: "206m"
    limits:
      memory: 98Mi
      cpu: "206m"
```

**Step 1.3: Build and deploy**

```bash
faas-cli build -f stack.yml

for img in image-resize db-query log-filter; do
  docker save golgi/${img}:latest | sudo k3s ctr images import -
done

faas-cli deploy -f stack.yml

faas-cli list
# Should show 6 functions (3 Non-OC + 3 OC)
```

### 6.4 Baseline Latency Measurement

**Step 1.4: Measure Non-OC and OC latencies (200 requests each)**

```bash
for func in image-resize db-query log-filter image-resize-oc db-query-oc log-filter-oc; do
  echo "Testing $func..."
  for i in $(seq 1 200); do
    start=$(date +%s%N)
    curl -s http://127.0.0.1:31112/function/$func \
      -d '{"width":1920,"height":1080}' > /dev/null
    end=$(date +%s%N)
    echo "$(( (end - start) / 1000000 ))" >> /tmp/${func}_latencies.txt
  done
done
```

### 6.5 Baseline Results ✅

Measured from 200 sequential requests per function on 2026-04-12:

| Function | Profile | CPU | P50 | P95 (SLO) | P99 | Mean | StdDev | Errors |
|---|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound (Non-OC) | 1000m | 4485ms | **4591ms** | 4762ms | 4499ms | 45ms | 0/200 |
| image-resize-oc | CPU-bound (OC) | 405m | 11067ms | 11156ms | 11276ms | 11057ms | 54ms | 0/200 |
| db-query | I/O-bound (Non-OC) | 500m | 18ms | **21ms** | 24ms | 19ms | 1ms | 0/200 |
| db-query-oc | I/O-bound (OC) | 185m | 20ms | 28ms | 35ms | 21ms | 4ms | 0/200 |
| log-filter | Mixed (Non-OC) | 500m | 16ms | **17ms** | 18ms | 16ms | 1ms | 0/200 |
| log-filter-oc | Mixed (OC) | 206m | 25ms | 77ms | 96ms | 35ms | 23ms | 0/200 |

**SLO Thresholds** (Non-OC P95, used for all subsequent experiments):

```
SLO_image_resize = 4591 ms
SLO_db_query     = 21 ms
SLO_log_filter   = 17 ms
```

**Degradation ratios at the default OC level:**

| Function | Profile | CPU Reduction | P95 Degradation | Mean Degradation |
|---|---|---|---|---|
| image-resize | CPU-bound | 2.47× | **2.43×** | 2.46× |
| db-query | I/O-bound | 2.70× | **1.33×** | 1.14× |
| log-filter | Mixed | 2.43× | **4.53×** | 2.17× |

**Key observations from baseline:**

1. **CPU-bound degradation is proportional.** image-resize P95 degradation (2.43×) closely matches CPU reduction (2.47×). The function's latency is CPU-cycle-limited, so halving CPU approximately doubles latency.

2. **I/O-bound degradation is minimal.** db-query absorbs a 2.70× CPU cut with only 1.33× P95 degradation. Most request time is spent waiting on Redis network round-trips, which are independent of CPU allocation.

3. **Mixed degradation is disproportionate.** log-filter shows 4.53× P95 degradation from only a 2.43× CPU cut. The mean degradation (2.17×) is moderate, but the P95 is extreme — suggesting bimodal behavior where some requests hit the fast path and others hit a slow path. The large standard deviation (23ms vs 1ms for Non-OC) confirms this.

4. **Zero errors across all 1,200 requests** confirms infrastructure stability.

These baseline results demonstrate profile-dependent degradation behavior at a single overcommitment level. Phase 2 extends this to multiple levels to produce full degradation curves.

### 6.6 Pre-Phase 2: CPU Burst Measurement ✅

> **Status:** Completed on 2026-04-12. Full execution details in [`execution_log_phase2.md`](execution_log_phase2.md).

Phase 1 revealed bimodal latency in log-filter-oc (P95 = 77ms vs P50 = 25ms, σ = 23ms). Before sweeping CPU levels in Phase 2, we measured the intrinsic CPU burst size of log-filter to understand the CFS mechanism driving this bimodality.

**Method:** Read cgroup v2 `cpu.stat` counters (usage_usec, nr_periods, nr_throttled, throttled_usec) before and after 200 sequential requests. Compute per-request CPU burst from the delta.

**Results:**

| Variant | CPU Limit | Per-Request CPU | Quota/Period | Throttle Ratio |
|---|---|---|---|---|
| log-filter (Non-OC) | 500m | 7.60ms | 50ms/100ms | 33.3% |
| log-filter-oc (OC) | 206m | 7.76ms | 20.6ms/100ms | 97.3% |

**Key findings (answering RQ2):**

1. **CPU burst size is intrinsic to the function, not the CPU limit.** Both variants use ~7.7ms of CPU per request — the limit changes wall-clock latency, not CPU work done.

2. **The CFS mechanism is now quantitatively explained.** At 206m quota (20.6ms per 100ms period), approximately 2.7 requests fit per CFS period. Requests 1-2 complete fast (~16ms wall-clock). Request 3 straddles the quota boundary — it begins execution but exhausts the remaining ~5ms of quota, gets throttled, waits ~80ms for the next period, then finishes with a fresh quota. This creates the bimodal latency distribution: fast mode (~16-25ms) vs slow mode (~80-100ms).

3. **Throttle ratio confirms the mechanism.** At 97.3% throttle ratio (OC) vs 33.3% (Non-OC), nearly every CFS period under overcommitment experiences throttling. The 33.3% Non-OC throttling corresponds to ~1 in 3 requests hitting the boundary even at 500m, which is consistent with 7.7ms burst × 3 requests = 23.1ms against a 50ms quota — the third request occasionally straddles.

4. **CFS boundary transition points predicted.** The 7.7ms burst measurement predicts bimodal transitions at integer multiples of burst size: 77m (1 req/period), 154m (2 req/period), 231m (3 req/period), 308m (4 req/period). Phase 2's CPU sweep at 100m, 200m, 300m, 400m, 500m will cross several of these boundaries.

This mechanistic analysis provides the direct experimental evidence for RQ2: the bimodal latency behavior of mixed functions under overcommitment is caused by CFS quota boundary crossings, where the function's CPU burst size (~7.7ms) straddles the CFS period quota, causing some requests to spill into the next period and incur a full-period throttling penalty.

### 6.7 Phase 1 Plots

Five publication-quality plots generated from baseline data (see `results/phase1/plots/`):

| Plot | File | Description |
|---|---|---|
| Fig 1 | `fig1_cdf_fast_functions.png` | CDF of fast functions (db-query, log-filter) with SLO lines |
| Fig 2 | `fig2_cdf_per_function.png` | Per-function CDF: Non-OC vs OC with SLO violation shading |
| Fig 3 | `fig3_p95_bar_chart.png` | Horizontal grouped P95 bar chart with degradation ratios |
| Fig 4 | `fig4_box_plots.png` | Box plots showing distribution shape and bimodal behavior |
| Fig 5 | `fig5_degradation_ratios.png` | Degradation ratio comparison (P95, mean, CPU reduction) |

### 6.8 Checkpoint: Phase 1 Complete ✅

```
[x] 3 Non-OC functions deployed and responding
[x] 3 OC functions deployed and responding
[x] Redis service running and accessible from db-query functions
[x] Baseline P95 latency measured for all 6 variants (SLO thresholds established)
[x] Resource configurations match the overcommitment formula
[x] All functions handle concurrent requests (max_inflight = 4)
[x] Degradation ratios computed — profile-dependent behavior confirmed
[x] 5 baseline plots generated
[x] Zero errors across all measurements
[x] CPU burst measurement completed — CFS mechanism quantified (RQ2)
[x] Bimodal latency in log-filter-oc explained by CFS quota boundary crossings
```

---

## 7. Phase 2 — Multi-Level Degradation Curves

> **Status:** In progress. Depends on Phase 1 (completed).

### 7.1 Objective

Phase 1 showed that degradation differs by profile at a single OC level. Phase 2 asks: **what is the shape of the degradation curve as CPU allocation decreases?** Is CPU-bound degradation truly linear? Does I/O-bound stay flat until some threshold? Where exactly does the mixed function hit the CFS boundary?

This experiment produces the most important figure in the study: three degradation curves diverging from the same starting point, showing that overcommitment impact is not only profile-dependent but follows qualitatively different functional forms.

### 7.2 Experimental Design

For each function, deploy 5 variants with different CPU allocations spanning from full allocation to aggressive overcommitment:

| Level | Label | image-resize CPU | db-query CPU | log-filter CPU |
|---|---|---|---|---|
| L1 | 100% (Non-OC) | 1000m | 500m | 500m |
| L2 | 80% | 800m | 400m | 400m |
| L3 | 60% | 600m | 300m | 300m |
| L4 | 40% | 400m | 200m | 200m |
| L5 | 20% | 200m | 100m | 100m |

Memory allocations are kept at the Non-OC level for all variants. This isolates the effect of CPU reduction from memory pressure — we want to measure CPU overcommitment impact, not OOM-kill behavior.

**Total deployments:** 5 levels × 3 functions = 15 function variants
**Total measurements:** 15 variants × 200 requests × 3 repetitions = 9,000 requests

### 7.3 Deployment Strategy

We cannot run all 15 variants simultaneously (worker nodes have limited CPU). Instead, we deploy and measure one function at a time, cycling through CPU levels:

```bash
for func in image-resize db-query log-filter; do
  for cpu_pct in 100 80 60 40 20; do
    # 1. Compute CPU allocation
    cpu_milli=$(compute_cpu $func $cpu_pct)

    # 2. Deploy the function with this CPU limit
    deploy_function $func $cpu_milli

    # 3. Warm up (10 requests, discarded)
    warmup $func 10

    # 4. Measure (200 requests × 3 repetitions)
    for rep in 1 2 3; do
      measure $func 200 > results/phase2/${func}_cpu${cpu_pct}_rep${rep}.txt
    done

    # 5. Record CFS throttling counters from cgroup
    record_cfs_stats $func > results/phase2/${func}_cpu${cpu_pct}_cfs.txt

    # 6. Delete the deployment
    delete_function $func
  done
done
```

### 7.4 Detailed Steps

**Step 2.1: Create parameterized deployment manifest**

We need a K8s deployment template that accepts CPU limit as a parameter. Since OpenFaaS stack.yml doesn't support parameterization, we use raw K8s manifests with `envsubst` or `sed`:

```yaml
# functions-deploy-template.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${FUNC_NAME}-cpu${CPU_PCT}
  namespace: openfaas-fn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${FUNC_NAME}-cpu${CPU_PCT}
  template:
    metadata:
      labels:
        app: ${FUNC_NAME}-cpu${CPU_PCT}
    spec:
      containers:
      - name: ${FUNC_NAME}
        image: golgi/${FUNC_IMAGE}:latest
        resources:
          requests:
            cpu: "${CPU_MILLI}m"
            memory: "${MEM_MI}Mi"
          limits:
            cpu: "${CPU_MILLI}m"
            memory: "${MEM_MI}Mi"
        env:
        - name: max_inflight
          value: "4"
        ports:
        - containerPort: 8080
```

**Step 2.2: Measurement script**

```bash
#!/bin/bash
# benchmark-multi-level.sh
# Measures latency for a function at a given CPU level

FUNC=$1
NUM_REQUESTS=${2:-200}
GATEWAY="http://127.0.0.1:31112"

# Determine request payload based on function
case $FUNC in
  image-resize*) PAYLOAD='{"width":1920,"height":1080}' ;;
  db-query*)     PAYLOAD='{"key":"bench_key"}' ;;
  log-filter*)   PAYLOAD='{}' ;;
esac

# Warm-up
for i in $(seq 1 10); do
  curl -s -o /dev/null "$GATEWAY/function/$FUNC" -d "$PAYLOAD"
done

# Measurement
for i in $(seq 1 $NUM_REQUESTS); do
  START=$(date +%s%N)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "$GATEWAY/function/$FUNC" -d "$PAYLOAD")
  END=$(date +%s%N)
  LATENCY_MS=$(( (END - START) / 1000000 ))
  echo "$LATENCY_MS"
done
```

**Step 2.3: Record CFS throttling metrics**

After each measurement batch, read the CFS throttling counters from cgroup to correlate latency degradation with actual throttling:

```bash
#!/bin/bash
# record-cfs-stats.sh
# Reads CFS throttling metrics for a function's pod

FUNC=$1
POD=$(kubectl get pods -n openfaas-fn -l app=$FUNC -o jsonpath='{.items[0].metadata.name}')
CONTAINER_ID=$(kubectl get pod $POD -n openfaas-fn \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')

# Find cgroup path on the node where the pod runs
NODE=$(kubectl get pod $POD -n openfaas-fn -o jsonpath='{.spec.nodeName}')
ssh $NODE "cat /sys/fs/cgroup/kubepods.slice/*/cri-containerd-${CONTAINER_ID}.scope/cpu.stat"
```

Output includes:
```
nr_periods 4000        # Total CFS periods elapsed
nr_throttled 1250      # Periods where container was throttled
throttled_usec 75000000  # Total microseconds spent throttled
```

The **throttle ratio** = `nr_throttled / nr_periods` directly measures what fraction of time the container was CPU-starved. We expect this to correlate strongly with latency degradation.

### 7.5 Expected Results

Based on Phase 1 observations and CFS theory:

**CPU-bound (image-resize):** Near-linear degradation. At 20% CPU (200m), we expect ~5× latency increase relative to 100% (1000m). The CFS quota at 200m is 20ms per 100ms period — the function needs ~4500ms of CPU time, so it will require roughly 45 CFS periods of 100ms each = ~4500ms execution time even at full speed. With only 20% of the CPU, the function will be throttled in every period, but the total CPU time needed doesn't change — only the wall-clock time stretches proportionally.

**I/O-bound (db-query):** Flat until extreme overcommitment. Even at 20% CPU (100m), the function's CPU work (JSON parsing, Redis client library) should complete within the 10ms CFS quota. Degradation will appear only if the CPU quota is so low that the Python interpreter itself struggles to start the request processing. We expect the curve to stay flat until ~100m and then rise sharply.

**Mixed (log-filter):** Step-function behavior. As CPU decreases, the function's CPU burst size remains constant (~7.7ms of CPU work based on Pre-Phase 2 measurement), but the CFS quota shrinks. At some point, the quota drops below the burst size, and requests start spilling into the next CFS period, adding ~60-80ms of wait time. The curve should show:
- 500m-300m: latency stays ~16ms (burst fits within quota)
- 300m-200m: transition zone (some requests spill, some don't — bimodal)
- Below 200m: most requests spill — latency jumps to ~80-100ms

### 7.6 Plots to Generate

**Plot P2.1: Degradation Curves (the key figure)**
```
X-axis: CPU allocation (% of Non-OC)
Y-axis: P95 latency (ms)
Lines:  image-resize (blue), db-query (green), log-filter (orange)
Error bars: min/max across 3 repetitions
```

This plot should show three qualitatively different curve shapes:
- Blue (CPU-bound): steep, roughly linear decline from left to right
- Green (I/O-bound): flat until the rightmost point, then steep rise
- Orange (Mixed): flat, then step-function jump at the CFS boundary

**Plot P2.2: Throttle Ratio vs Degradation**
```
X-axis: CFS throttle ratio (nr_throttled / nr_periods)
Y-axis: P95 degradation ratio (OC P95 / Non-OC P95)
Points: one per (function, CPU level) combination, colored by profile
```

This shows whether CFS throttling is a universal predictor of latency degradation across profiles.

**Plot P2.3: Latency Distributions at Each Level**
```
Grid of violin plots: 3 columns (functions) × 5 rows (CPU levels)
Each violin shows the full latency distribution (200 samples)
```

This reveals how the distribution shape changes — particularly the bimodal transition for log-filter.

### 7.7 Checkpoint: Phase 2 Complete

```
[~] 15 function variants deployed and measured (5 levels × 3 functions)
    [x] image-resize @ 100% (1000m) — Mean P95 4611 ms (1.00× baseline)
    [x] image-resize @ 80%  (800m)  — Mean P95 5791 ms (1.26×)
    [~] image-resize @ 60%  (600m)  — Reps 1-2 P95 ≈ 8066 ms (1.75×, Rep 3 running)
    [ ] image-resize @ 40%, @ 20%
    [ ] db-query  @ 5 levels
    [ ] log-filter @ 5 levels
[~] 200 requests × 3 repetitions per variant = 9,000 total requests (1000+ done)
[~] CFS throttling metrics recorded for all variants (image-resize 100/80% complete)
[ ] Degradation curves plotted for all three profiles
[ ] Throttle ratio vs degradation correlation computed
[ ] Bimodal transition identified for log-filter
[~] All raw latency data saved to results/phase2/ (image-resize partial)
```

**Early findings (image-resize, 2026-04-12):**

| CPU % | CPU (m) | Mean P95 (ms) | Degradation | Predicted (1/x) | CFS throttle ratio |
|---|---|---|---|---|---|
| 100% | 1000 | 4611 | 1.00× | 1.00× | 14.8% |
| 80%  | 800  | 5791 | 1.26× | 1.25× | 98.0% |
| 60%  | 600  | ~8066 (reps 1-2) | 1.75× | 1.67× | TBD |

The 100% baseline matches Phase 1 (4591 ms) within 0.7%, validating Phase 2 infrastructure. The 80% point matches the linear inverse-quota prediction within 1%, and the CFS throttle ratio jumps from 14.8% → 98% — direct evidence that CFS bandwidth enforcement is the mechanism (RQ2). The 60% point shows the **first super-linear deviation** (+6% over linear), suggesting queueing effects begin compounding throttling once the quota drops well below natural CPU demand.

**Estimated time: 1-2 days**

---

## 8. Phase 3 — Analysis and Visualization

> **Status:** Not started. Depends on Phase 2 (in progress).

### 8.1 Summary of All Plots

| # | Plot | Source Phase | Key Message |
|---|---|---|---|
| P1.1 | CDF fast functions | Phase 1 ✅ | Baseline latency distributions |
| P1.2 | CDF per function | Phase 1 ✅ | Non-OC vs OC with SLO shading |
| P1.3 | P95 bar chart | Phase 1 ✅ | Degradation ratios by profile |
| P1.4 | Box plots | Phase 1 ✅ | Distribution shape, bimodality |
| P1.5 | Degradation ratios | Phase 1 ✅ | P95 vs mean vs CPU reduction |
| P2.1 | **Degradation curves** | Phase 2 | **The key figure** — three diverging curves |
| P2.2 | Throttle ratio vs degradation | Phase 2 | CFS throttling as degradation predictor |
| P2.3 | Violin plots grid | Phase 2 | Distribution shape across levels |

### 8.2 Statistical Analysis

For each research question, compute:

**RQ1 (Degradation curves):**
- Pearson correlation between CPU allocation and P95 latency for each profile
- Slope of linear fit for CPU-bound (should be ~1.0 in normalized space)
- R² of linear fit (high for CPU-bound, low for I/O-bound and mixed)
- Identification of transition points where the curve shape changes (particularly for mixed profile)

**RQ2 (CFS mechanism):**
- Correlation between throttle ratio and slow-mode fraction across Phase 2 CPU levels
- Verification that the bimodal transition in log-filter occurs near the predicted CFS quota boundary (where quota ≈ 7.7ms burst size, i.e., ~77m CPU)
- Comparison of observed distribution shapes (unimodal vs bimodal) at each CPU level against CFS theory predictions

### 8.3 Comparison with Golgi Paper's Assumed Behavior

| Assumed Behavior | Our Evidence | Finding |
|---|---|---|
| CPU-bound functions degrade proportionally to CPU cut | Phase 2 degradation curve slope | Confirmed / Nuanced / Contradicted |
| I/O-bound functions are resilient to overcommitment | Phase 2 flat curve for db-query | Confirmed / Nuanced / Contradicted |
| Mixed functions show variable degradation | Phase 1 bimodality + Pre-Phase 2 CFS analysis + Phase 2 curves | Characterized + mechanistic explanation |
| Different profiles need different overcommitment treatment | All phases | Characterized with degradation curves |

### 8.4 Checkpoint: Phase 3 Complete

```
[ ] All 8 plots generated at publication quality (300 DPI)
[ ] Statistical tests computed for both RQs
[ ] Comparison table with Golgi claims completed
[ ] All figures have captions and are referenced in the report
[ ] Raw data organized in results/ directory
```

**Estimated time: 1-2 days**

---

## 9. Phase 4 — Report Writing and Demo

> **Status:** In progress (Sections 1-3 drafted).

### 9.1 Report Structure

| Section | Content | Status |
|---|---|---|
| 1. Introduction | Overcommitment problem, Golgi hypothesis, what we test | Drafted |
| 2. Background | CFS, cgroups, overcommitment formula, Golgi overview | Drafted |
| 3. Experimental Design | Infrastructure, functions, measurement methodology | Drafted |
| 4. Implementation | AWS infrastructure, k3s cluster, OpenFaaS, function construction | Drafted |
| 5. Baseline Characterization | Phase 1 results — single OC level comparison + CFS burst measurement | Write from Phase 1 data |
| 6. Results and Analysis | Phase 2 results — multi-level degradation curves, throttle correlation | Write from Phase 2 data |
| 7. Discussion | Implications, comparison with Golgi claims, limitations, future work | Write after all data |
| 8. Conclusion | Summary, contributions | Write last |
| 9. References | All cited papers and tools | Mostly done |

### 9.2 Literature References

| # | Paper | Relevance |
|---|---|---|
| 1 | Golgi (Li et al., SoCC 2023) | Profile-dependent degradation hypothesis we characterize |
| 2 | Azure Function Trace (Shahrad et al., ATC 2020) | Workload characterization, resource waste numbers |
| 3 | Mondrian Forest (Lakshminarayanan et al., NeurIPS 2014) | ML model in Golgi (background) |
| 4 | Harvest VMs (Ambati et al., OSDI 2020) | Alternative approach to resource efficiency |
| 5 | Kraken (Wen et al., SoCC 2021) | Container provisioning for serverless |
| 6 | ENSURE (Suresh et al., ACSOS 2020) | SLO-aware serverless scheduling |
| 7 | Power of Two Choices (Mitzenmacher, TPDS 2001) | Load balancing theory (Golgi's routing) |

### 9.3 Presentation Outline

```
~12-15 slides

Slide 1:     Title — project name, team, course
Slide 2:     The problem — serverless resource waste (75% idle), overcommitment risk
Slide 3:     Golgi hypothesis — profile-dependent degradation, assumed but not validated
Slide 4:     Our approach — 2 RQs, 3 profiles, 5 CPU levels, real AWS infrastructure
Slide 5:     Infrastructure — cluster topology diagram (5 EC2, k3s, OpenFaaS)
Slide 6:     Benchmark functions — image-resize, db-query, log-filter (table + rationale)
Slide 7:     Phase 1 results — baseline degradation ratios (2.43×, 1.33×, 4.53×)
Slide 8:     CFS mechanism — burst measurement (7.7ms), quota boundary diagram, throttle ratios
Slide 9:     Phase 2 results — degradation curves (the key figure, P2.1)
Slide 10:    Phase 2 results — throttle ratio vs degradation correlation (P2.2)
Slide 11:    Phase 2 results — violin plot grid showing distribution shape changes (P2.3)
Slide 12:    Comparison with Golgi claims — what we confirmed, what we added
Slide 13:    Future work — concurrency, tail latency, fine-grained CFS sweep
Slide 14:    Conclusion — contributions summary
```

---

## 10. Future Scope

The following experiments extend the characterization naturally but are outside the scope of the current study. They represent valuable future work for anyone building on this foundation.

### 10.1 Concurrency Under Overcommitment

**Research question:** Does concurrent load amplify overcommitment-induced degradation, and is the amplification profile-dependent?

In production, functions handle multiple concurrent requests. Overcommitment and concurrency both consume CPU — a function at 40% CPU allocation handling 4 concurrent requests faces double contention: reduced allocation AND shared execution. The question is whether these effects add linearly or multiply.

**Proposed design:** For each function at its default OC level, measure latency at 4 concurrency levels (1, 2, 4, 8 simultaneous requests). Run the same sweep on Non-OC variants to establish expected concurrency scaling. Compute the amplification factor — values above 1.0 mean concurrency amplifies overcommitment degradation.

**Expected outcome:** CPU-bound and I/O-bound functions should show linear scaling (~1.0× amplification). Mixed functions should show superlinear amplification at concurrency ≥ 4 because multiple concurrent requests collectively exhaust the CFS quota faster — at 206m quota (20.6ms), four functions needing 7.7ms each = 30.8ms of CPU work per period, but only 20.6ms of quota available. All four will be throttled, creating effective serialization under CFS throttling.

### 10.2 Tail Latency Analysis

**Research question:** How does overcommitment affect tail latency (P99, P99.9) compared to median behavior?

Mean or even P95 might look acceptable while the worst 0.1% of requests experience catastrophic degradation. This matters for SLO design: if a cloud provider overcommits functions that appear "safe" based on P95 but have 10× P99.9 degradation, the worst user experience is much worse than the SLO suggests.

**Proposed design:** Collect extended measurements (1000 requests per function variant) for reliable P99.9 estimation. Compute the Tail Amplification Factor (TAF) at each percentile: TAF(p) = OC_percentile(p) / NonOC_percentile(p). If TAF increases with percentile rank, overcommitment disproportionately affects tail latency.

**Expected outcome:** CPU-bound functions should show roughly constant TAF across percentiles (uniform degradation). Mixed functions should show strongly increasing TAF because the bimodal CFS behavior means fast-mode requests contribute to the median while slow-mode requests dominate the tail.

### 10.3 Fine-Grained CFS Quota Boundary Sweep

**Research question:** Can the bimodal transition be mapped precisely by sweeping CPU allocations in fine-grained steps around the quota boundary?

Our Pre-Phase 2 burst measurement (7.7ms per request) predicts transition points at integer multiples: 77m, 154m, 231m, 308m. A fine-grained sweep (50m–300m in 10m increments, 26 data points) would map exactly where the distribution transitions from unimodal to bimodal and back, validating the CFS boundary hypothesis at high resolution.

**Proposed design:** Deploy log-filter at 9+ CPU levels around the predicted transition points (100m–300m in 20-25m increments). For each level, collect latency distributions (200 requests × 3 reps), CFS throttling counters, and apply bimodality tests (Hartigan's dip test, Gaussian Mixture Model fitting). Plot the throttle ratio vs CPU level curve and the slow-mode fraction S-curve.

**Expected outcome:** At high CPU (300-250m), unimodal distribution centered at ~16ms. At transition CPU (220-180m), bimodal distribution with peaks at ~16ms and ~80-100ms. At low CPU (140-100m), unimodal distribution centered at ~80-100ms. The transition should be sharp (reflecting the hard CFS quota boundary), and the transition CPU level should correspond to where quota ≈ burst size (~77m for single-request and ~154m for two-request scenarios).

---

## 11. Appendix A — Cost Estimation

### AWS Cost Breakdown

| Resource | Type | Hourly Cost | Daily (8h) | Weekly |
|---|---|---|---|---|
| Master node | t3.medium on-demand | $0.0416 | $0.33 | $2.33 |
| Worker 1 | t3.xlarge spot (~70% off) | $0.05 | $0.40 | $2.80 |
| Worker 2 | t3.xlarge spot | $0.05 | $0.40 | $2.80 |
| Worker 3 | t3.xlarge spot | $0.05 | $0.40 | $2.80 |
| Load generator | t3.medium spot | $0.013 | $0.10 | $0.73 |
| **Total** | | **$0.204/hr** | **$1.63/day** | **$11.46/week** |

**Cost-saving tips:**
- Stop all instances when not working (`aws ec2 stop-instances`)
- Use spot instances for workers and load generator
- Run experiments in bursts (all phases in one long session)
- Estimated total project cost: **$15-25 over 2-3 weeks**

---

## 12. Appendix B — Troubleshooting Guide

### Common Issues and Fixes

| Problem | Cause | Fix |
|---|---|---|
| k3s agent can't join cluster | Security group blocks port 6443 | Ensure VPC-internal traffic is allowed |
| OpenFaaS functions stuck in Pending | Insufficient node resources | Check `kubectl describe pod` for scheduling failures |
| Latency variance too high | EC2 neighbor noise (t3 burstable) | Check CPU credits, repeat measurements, discard outliers |
| Function returns 500 | Handler crash or timeout | Check pod logs with `kubectl logs` |
| cgroup path not found | Container uses different QoS class | Check all QoS dirs: guaranteed, burstable, besteffort |
| CFS counters not updating | Reading wrong cgroup path | Verify container ID → cgroup path mapping |
| Redis connection refused | Redis pod not running or DNS not resolved | `kubectl get pods -n openfaas-fn`, check service DNS |
| Inconsistent latency across reps | EC2 CPU throttling (T3 credit exhaustion) | Monitor CPU credits via CloudWatch, use unlimited mode |
| CFS stats show zero throttling | CPU limit not applied to pod | Verify `cpu.max` file shows correct quota |

### Debugging Commands

```bash
# Check function logs
kubectl logs -n openfaas-fn deployment/image-resize --tail=50

# Check CFS throttling directly
kubectl exec -n openfaas-fn deployment/image-resize -- cat /sys/fs/cgroup/cpu.stat

# Verify CPU limits are applied
kubectl exec -n openfaas-fn deployment/image-resize -- cat /sys/fs/cgroup/cpu.max
# Expected output: "40000 100000" for 400m CPU

# Check resource allocations
kubectl describe pod -n openfaas-fn -l app=image-resize | grep -A5 "Limits\|Requests"

# Monitor resource usage
kubectl top pods -n openfaas-fn
kubectl top nodes

# Test function endpoint
curl -w "\n%{time_total}\n" http://127.0.0.1:31112/function/image-resize \
  -d '{"width":1920,"height":1080}'

# Check OpenFaaS function status
faas-cli describe image-resize
```

---

## 13. Appendix C — File and Directory Structure

```
golgi_vcc/
│
├── PROJECT_PLAN.md                    # This file — project plan
├── execution_log_phase0.md            # Phase 0 execution log (infrastructure)
├── execution_log_phase1.md            # Phase 1 execution log (benchmarks)
├── execution_log_phase2.md            # Pre-Phase 2 execution log (CPU burst measurement)
│
├── docs/
│   ├── final_report.md                # Course report (in progress)
│   └── analysis/
│       └── golgi-socc23-audit.md      # Paper-code audit analysis
│
├── infrastructure/                    # Phase 0
│   ├── setup-vpc.sh                   # VPC, subnet, security group creation
│   ├── launch-instances.sh            # EC2 instance provisioning
│   ├── install-k3s-master.sh          # k3s server setup
│   ├── install-k3s-worker.sh          # k3s agent setup
│   ├── install-openfaas.sh            # OpenFaaS deployment
│   └── teardown.sh                    # Clean up all AWS resources
│
├── functions/                         # Phase 1
│   ├── image-resize/
│   │   ├── handler.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── db-query/
│   │   ├── handler.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── log-filter/
│   │   ├── handler.go
│   │   ├── go.mod
│   │   └── Dockerfile
│   ├── stack.yml                      # OpenFaaS deployment config
│   ├── functions-deploy.yaml          # Raw K8s manifests (6 variants)
│   ├── phase2-deploy-template.yaml    # Phase 2 parameterized template
│   └── redis-deployment.yaml          # Redis service for db-query
│
├── build/                             # OpenFaaS function templates
│   ├── python3-http/
│   └── golang-http/
│
├── scripts/                           # Measurement and analysis
│   ├── benchmark-latency.sh           # Sequential latency measurement
│   ├── compute-stats.py               # P50/P95/P99/mean/stddev computation
│   ├── generate-phase1-plots.py       # Phase 1 plot generation
│   ├── generate-phase2-plots.py       # Phase 2 degradation curve plots
│   ├── measure-cpu-burst.sh           # cgroup v2 CPU burst measurement
│   ├── run-phase2.sh                  # Phase 2 orchestrator (9,000 requests)
│   ├── run-level.sh                   # Single CPU level runner
│   ├── smoke-test.sh                  # Function health check
│   ├── warmup.sh                      # Cold-start elimination
│   └── test-concurrency.sh            # Concurrency verification
│
├── results/
│   ├── phase1/                        # Baseline measurements
│   │   ├── *_latencies.txt            # Raw latency data (6 files)
│   │   └── plots/                     # 5 baseline plots
│   ├── pre-phase2/                    # CPU burst measurement
│   │   └── cpu-burst-measurement.md   # Burst size and CFS analysis
│   └── phase2/                        # Multi-level measurements
│       ├── *_cpu*_rep*.txt            # Latency data per (func, level, rep)
│       ├── *_cpu*_cfs.txt             # CFS throttling counters
│       └── plots/                     # Degradation curve plots
│
└── report/                            # Final deliverables
    ├── report.pdf
    └── presentation.pdf
```

---

## 14. Appendix D — Mathematical Foundations

### D.1 The Overcommitment Formula

```
OC_allocation = alpha × claimed + (1 - alpha) × actual

Where:
  alpha       = 0.3 (slack factor, from Golgi paper)
  claimed     = resource level declared by the user (e.g., 512 MB)
  actual      = measured peak usage (e.g., 65 MB)

Interpretation:
  - alpha = 0: OC allocation = actual usage (maximum savings, maximum risk)
  - alpha = 1: OC allocation = claimed (no savings, no risk)
  - alpha = 0.3: 30% safety margin above actual usage

Example:
  claimed = 512 MB, actual = 65 MB
  OC = 0.3 × 512 + 0.7 × 65 = 153.6 + 45.5 = 199.1 MB
  Savings = (512 - 199.1) / 512 = 61.1% per instance
```

### D.2 CFS Quota Computation

```
For a Kubernetes CPU limit of X millicores:

  CFS quota = X × (period / 1000)

  Where period = 100,000 µs (default CFS period = 100ms)

  Example: CPU limit = 200m
    quota = 200 × 100 = 20,000 µs = 20ms per 100ms period

Throttling occurs when:
  CPU work per request > quota per period

  If CPU work = 7.7ms and quota = 20ms:
    No throttling (7.7 < 20) → fast path
    But with ~2.7 requests per period: 2.7 × 7.7 = 20.8ms > 20ms
    → 3rd request straddles boundary, gets throttled

  If CPU work = 7.7ms and quota = 10ms:
    Single request fits (7.7 < 10) → fast path
    But 2nd request: 2 × 7.7 = 15.4ms > 10ms → spills to next period

  The ratio of slow-path latency to fast-path latency ≈ 4-6×
  (one extra CFS period wait = ~80ms added to a ~16ms request)
```

### D.3 P95 Latency Computation

```
Given N sorted latencies: L[1] ≤ L[2] ≤ ... ≤ L[N]

P95 = L[⌈0.95 × N⌉]

Example with N = 200:
  P95 = L[190] (the 190th smallest latency)

Why P95 and not mean?
  Mean is sensitive to outliers but hides tail behavior.
  P95 captures the experience of the worst 5% of requests.
  Cloud SLOs are typically defined at P95 or P99.

  Example:
    Latencies: [10, 12, 11, 13, 10, 11, 12, 10, 11, 5000] ms
    Mean = 510 ms (looks terrible!)
    P95  = 13 ms  (most users are fine)
    P99  = 5000 ms (the outlier appears here)
```

### D.4 CPU Burst Size Computation

```
From cgroup v2 cpu.stat, read before and after N requests:

  delta_usage_usec = usage_usec_after - usage_usec_before
  cpu_per_request = delta_usage_usec / N / 1000  (convert to ms)

Example (log-filter, 200 requests):
  usage_usec_before = 1,234,000
  usage_usec_after  = 2,786,000
  delta = 1,552,000 µs
  cpu_per_request = 1,552,000 / 200 / 1000 = 7.76 ms

This value is intrinsic to the function — it does not change
with the CPU limit. The limit only controls how much quota
is available per CFS period, not how much CPU work the function does.

Throttle ratio = nr_throttled / nr_periods
  At 206m (20.6ms quota): 97.3% throttled
  At 500m (50ms quota):   33.3% throttled

The throttle ratio directly measures the fraction of CFS periods
in which the container exhausted its CPU quota.
```

---

## 15. Appendix E — References and Resources

### Paper References

1. **Golgi paper:** Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing. *ACM SoCC 2023*.
   - DOI: https://doi.org/10.1145/3620678.3624645

2. **Azure Function Trace:** Shahrad, M., et al. (2020). Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider. *USENIX ATC 2020*.
   - Data: https://github.com/Azure/AzurePublicDataset

3. **Harvest VMs:** Ambati, P., et al. (2020). Providing SLOs for Resource-Harvesting VMs in Cloud Platforms. *USENIX OSDI 2020*.

4. **Kraken:** Wen, J., et al. (2021). Kraken: Adaptive Container Provisioning for Deploying Dynamic DAGs in Serverless Platforms. *ACM SoCC 2021*.

5. **ENSURE:** Suresh, A., et al. (2020). ENSURE: Efficient Scheduling and Autonomous Resource Management in Serverless Environments. *IEEE ACSOS 2020*.

6. **Mondrian Forest:** Lakshminarayanan, B., et al. (2014). Mondrian Forests: Efficient Online Random Forests. *NeurIPS 2014*.

7. **Power of Two Choices:** Mitzenmacher, M. (2001). The power of two choices in randomized load balancing. *IEEE TPDS*.

### Software Resources

| Tool | URL | Version Used |
|---|---|---|
| k3s | https://k3s.io | v1.34.6+k3s1 |
| OpenFaaS | https://www.openfaas.com | Latest (Helm) |
| faas-cli | https://github.com/openfaas/faas-cli | v0.18.8 |
| Pillow | https://python-pillow.org | 10.2.0 |
| Redis | https://redis.io | 7-alpine |
| Helm | https://helm.sh | 3.x |
| AWS CLI | https://aws.amazon.com/cli/ | 2.x |
| matplotlib | https://matplotlib.org | 3.9+ |
| numpy | https://numpy.org | 1.26+ |

### Useful Documentation

- k3s quickstart: https://docs.k3s.io/quick-start
- OpenFaaS on Kubernetes: https://docs.openfaas.com/deployment/kubernetes/
- cgroup v2 documentation: https://docs.kernel.org/admin-guide/cgroup-v2.html
- CFS bandwidth control: https://docs.kernel.org/scheduler/sched-bwc.html
- /proc filesystem: https://www.kernel.org/doc/html/latest/filesystems/proc.html

---

## Timeline Summary

| Week | Phase | Deliverable |
|---|---|---|
| Week 1 | Phase 0 + Phase 1 | Running cluster, deployed functions, baseline measurements, CFS mechanism ✅ |
| Week 2 | Phase 2 + Phase 3 + Phase 4 | Degradation curves, all plots, statistical analysis, final report, demo |

---

## Progress Summary

```
[x] Phase 0 — Infrastructure Setup (completed 2026-04-11)
[x] Phase 1 — Benchmark Deployment and Baseline Characterization (completed 2026-04-12)
  [x] Pre-Phase 2 — CPU Burst Measurement and CFS Mechanism (completed 2026-04-12)
[~] Phase 2 — Multi-Level Degradation Curves (in progress)
[ ] Phase 3 — Analysis and Visualization
[ ] Phase 4 — Report Writing and Demo
```

**Phase 2 progress:** image-resize 100% ✅, 80% ✅, 60% 🔄 (Reps 1-2 done), 40%/20% pending; db-query and log-filter pending.
**Total measurement effort remaining:** ~8,000 requests (Phase 2)
**Estimated time remaining:** ~1 week
**Target:** Characterize how CFS quota enforcement creates profile-dependent latency degradation under overcommitment, and determine whether the degradation patterns are mechanistically explainable

---

*End of Project Plan*
*Empirical study of resource overcommitment effects on serverless function latency*
