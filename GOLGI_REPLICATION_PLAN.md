# Golgi Replication: Complete Implementation Plan

> **Course:** CSL7510 — Cloud Computing
> **Student:** Anshul Kumar (M25AI2036)
> **Paper:** Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing
> **Authors:** Suyi Li, Wei Wang (HKUST), Jun Yang, Guangzhen Chen, Daohe Lu (WeBank)
> **Venue:** ACM SoCC 2023 — Best Paper Award
> **DOI:** https://doi.org/10.1145/3620678.3624645

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [What We Are Replicating and Why](#2-what-we-are-replicating-and-why)
3. [Architecture Overview](#3-architecture-overview)
4. [Simplifications and Justifications](#4-simplifications-and-justifications)
5. [Phase 0 — AWS Infrastructure Setup](#5-phase-0--aws-infrastructure-setup)
6. [Phase 1 — Benchmark Functions](#6-phase-1--benchmark-functions)
7. [Phase 2 — Metric Collector](#7-phase-2--metric-collector)
8. [Phase 3 — ML Module](#8-phase-3--ml-module)
9. [Phase 4 — The Router](#9-phase-4--the-router)
10. [Phase 5 — Vertical Scaling](#10-phase-5--vertical-scaling)
11. [Phase 6 — Load Generator and Trace Replay](#11-phase-6--load-generator-and-trace-replay)
12. [Phase 7 — End-to-End Integration](#12-phase-7--end-to-end-integration)
13. [Phase 8 — Evaluation and Metrics Collection](#13-phase-8--evaluation-and-metrics-collection)
14. [Phase 9 — Results Analysis and Visualization](#14-phase-9--results-analysis-and-visualization)
15. [Phase 10 — Report Writing and Demo](#15-phase-10--report-writing-and-demo)
16. [Appendix A — Cost Estimation](#16-appendix-a--cost-estimation)
17. [Appendix B — Troubleshooting Guide](#17-appendix-b--troubleshooting-guide)
18. [Appendix C — File and Directory Structure](#18-appendix-c--file-and-directory-structure)
19. [Appendix D — Mathematical Foundations](#19-appendix-d--mathematical-foundations)
20. [Appendix E — References and Resources](#20-appendix-e--references-and-resources)

> **Execution Logs:** Step-by-step execution details with commands, outputs, and reasoning are tracked separately per phase:
> - Phase 0 (Infrastructure): [`execution_log_phase0.md`](execution_log_phase0.md)
> - Phase 1 (Benchmark Functions): [`execution_log_phase1.md`](execution_log_phase1.md)

---

## 1. Executive Summary

### 1.1 What Is Golgi?

Golgi is a scheduling system for serverless functions that reduces infrastructure cost by
~42% while maintaining performance guarantees (SLOs). It does this by intelligently routing
requests between two types of container instances:

- **Non-OC (Non-Overcommitted):** Full resources as claimed by the user. Safe, expensive.
- **OC (Overcommitted):** Reduced resources based on actual usage. Cheap, risky.

An ML classifier (Mondrian Forest) predicts in real-time whether an OC instance can handle
a request without violating the latency SLO. A vertical scaling safety net corrects prediction
errors by adjusting per-container concurrency limits.

### 1.2 What Are We Building?

A simplified but faithful replication of Golgi on AWS, demonstrating:

1. The two-instance model (OC and Non-OC)
2. Runtime metric collection from containers (7 of the 9 paper metrics)
3. An ML classifier predicting SLO violations
4. A smart router using the classifier's predictions
5. A vertical scaling mechanism as a safety net
6. End-to-end evaluation showing cost reduction with SLO maintenance

### 1.3 Target Outcome

| Metric | Paper's Result | Our Target | Justification |
|---|---|---|---|
| Memory cost reduction | 42% | 25-35% | Fewer functions, simpler classifier |
| VM time reduction | 35% | 20-30% | Same reasoning |
| P95 latency SLO met | Yes (< 5% violation) | Yes (< 10% violation) | Wider tolerance for simplified system |
| Functions tested | 8 | 3 | Sufficient to show the principle |
| Cluster size | 7 workers | 3 workers | Cost constraint; principle still holds |

### 1.4 Technology Stack

| Component | Paper's Choice | Our Choice | Why |
|---|---|---|---|
| Cloud | AWS EC2 (c5.9xlarge) | AWS EC2 (t3.xlarge) | Cost: $0.05/hr spot vs $1.53/hr on-demand |
| Orchestration | Kubernetes (kubeadm) | k3s | Lightweight, faster setup, same K8s API |
| Serverless framework | OpenFaaS | OpenFaaS | Same as paper |
| ML model | Mondrian Forest (online) | scikit-learn Random Forest (periodic retrain) | Simpler, well-documented, same principle |
| ML language | Python (MF model) + Go (relay) | Python (Flask API) | Single language simplifies development |
| Routing | Modified faas-netes (Go) | Nginx reverse proxy + Python sidecar | Avoids Go development; same routing logic |
| Metric collection | Custom daemon (Go) | Python daemon + shell scripts | Faster to develop; same metrics |
| Load generator | Custom (from Azure trace) | Locust (Python) | Industry-standard, scriptable |

---

## 2. What We Are Replicating and Why

### 2.1 The Problem

Serverless functions waste resources. The numbers from production:

```
AWS Lambda: 54% of functions configured with >= 512 MB
             Average actual usage: 65 MB
             Median actual usage: 29 MB

AliCloud:    Most instances use 20-60% of allocated memory

Average:     Functions use ~25% of reserved resources
```

This means 75% of reserved resources sit idle. If a cloud provider runs 1 million function
instances, 750,000 instances worth of resources are wasted.

**Why not just give functions less?** Because naive overcommitment (blindly reducing
allocations) causes resource contention. When many squeezed functions share a server,
they fight over CPU, memory, network, and cache. The paper shows P95 latency increases
by up to 183% with naive overcommitment.

**Why not profile functions to find optimal sizing?** Orion [24] does this, but:
- Profiling takes 25 minutes of SLO-violating exploration
- It ignores collocation interference (functions affecting each other)
- Re-profiling needed when workload changes (up to 3.5 hours)

**Why not profile collocations?** Owl [37] does this, but:
- Only handles 2-function collocations
- Extending to 3 functions increases profiling by 26,742x
- Does not scale to real platform diversity

### 2.2 Golgi's Core Insight

> "Don't predict offline what you can observe online."

Instead of profiling functions in advance, Golgi watches 9 runtime metrics from each
container in real-time and uses an ML classifier to answer one binary question:

> "If I send a request to this OC instance right now, will it be too slow?"

This is elegant because:
1. It is function-agnostic (same 9 metrics work for any function)
2. It handles collocation interference (node-level metrics capture cross-container effects)
3. It adapts in real-time (online learning updates the model continuously)
4. It is conservative (defaults to safe Non-OC; only explores OC when ML says it is safe)

### 2.3 Why This Paper Matters for Cloud Computing Education

This paper sits at the intersection of four core cloud computing topics:

1. **Resource management** — overcommitment, bin packing, utilization optimization
2. **Scheduling** — real-time routing decisions under latency constraints
3. **Machine learning for systems** — using ML to make infrastructure decisions
4. **Serverless computing** — FaaS architecture, cold starts, auto-scaling

Replicating it forces you to understand all four deeply, not just theoretically.

### 2.4 Why AWS?

| Reason | Detail |
|---|---|
| Educational access | AWS Academy / free tier available |
| EC2 flexibility | Full Linux VMs with kernel access (unlike Lambda) |
| Spot instances | 60-90% cheaper than on-demand for development |
| k3s compatibility | k3s runs on any Linux EC2 instance |
| OpenFaaS support | OpenFaaS is cloud-agnostic; works on any K8s |

**Why NOT AWS Lambda?** Lambda is a black box. You cannot:
- Read cgroup files (no kernel access)
- Run perf stat (no hardware counter access)
- Control routing (Lambda manages this internally)
- Modify concurrency atomically (Lambda's concurrency is API-controlled, not in-process)

We need raw Linux VMs to access the kernel interfaces Golgi depends on.

---

## 3. Architecture Overview

### 3.1 System Architecture Diagram

```
                    +-------------------+
                    |   Load Generator  |
                    |   (Locust on EC2) |
                    +--------+----------+
                             |
                             | HTTP requests
                             v
                    +-------------------+
                    |   Golgi Router    |
                    | (Nginx + Python)  |
                    |                   |
                    | 1. Check Safe flag|
                    | 2. Read Labels    |
                    | 3. Power of 2    |
                    | 4. Route request  |
                    +--------+----------+
                             |
              +--------------+--------------+
              |                             |
              v                             v
   +-------------------+        +-------------------+
   |   Non-OC Instances |       |    OC Instances    |
   |   (Full resources) |       | (Reduced resources)|
   |                    |       |                    |
   | +----+ +----+     |       | +----+ +----+     |
   | | F1 | | F2 |     |       | | F1 | | F2 |     |
   | +----+ +----+     |       | +----+ +----+     |
   |        +----+     |       |        +----+     |
   |        | F3 |     |       |        | F3 |     |
   |        +----+     |       |        +----+     |
   +-------------------+        +-------------------+
              |                             |
              +-------------+---------------+
                            |
                            v
                 +---------------------+
                 |   Metric Collector   |
                 |  (DaemonSet per node)|
                 |                      |
                 |  Scrapes:            |
                 |  - cgroup (CPU/Mem)  |
                 |  - /proc/net (Net)   |
                 |  - Watchdog (Inflight)|
                 +----------+----------+
                            |
                            v
                 +---------------------+
                 |     ML Module       |
                 |  (Python Flask API) |
                 |                      |
                 |  - Stratified sample |
                 |  - Train RF model   |
                 |  - Predict Labels   |
                 |  - Set Safe flag    |
                 +---------------------+
```

### 3.2 Data Flow — Complete Request Lifecycle

```
Step 1: Request arrives at Golgi Router
        |
Step 2: Router reads Safe flag from ML Module cache
        |
        +-- If Safe = 0 --> Route to Non-OC instance (skip to Step 6)
        |
        +-- If Safe = 1 --> Continue to Step 3
        |
Step 3: Router picks 2 random OC instances (Power of Two Choices)
        Reads their cached Label tags
        |
        +-- If both Label = 1 (unsafe) --> Route to Non-OC instance
        |
        +-- If at least one Label = 0 (safe) --> Pick the safe one
        |
Step 4: Apply MRU tiebreaker (if both are safe, pick most recently used)
        |
Step 5: Route request to selected instance
        |
Step 6: Instance's watchdog receives request
        - Increments inflight counter (atomic)
        - Executes function
        - Records execution latency
        - Decrements inflight counter
        |
Step 7: Watchdog sends metrics + latency to ML Module asynchronously
        Context vector: [CPU, Mem, Inflight, NetRx, NetTx, NodeNetRx, NodeNetTx]
        Label: 1 if latency > SLO_threshold, else 0
        |
Step 8: ML Module buffers the sample
        - If positive (SLO violated): add to positive reservoir
        - If negative (SLO met): add to negative reservoir
        |
Step 9: When reservoir is full (N/2 positive + N/2 negative):
        - Combine into balanced batch of size N
        - Retrain/update classifier
        - Run batch inference on all OC instances
        - Update cached Label tags
        - Update Safe flag based on rolling P95
        |
Step 10: Vertical scaler inside OC watchdog checks:
         - violation_ratio = slow_requests / total_requests
         - If ratio > 0.05: decrement max_concurrency by 1
         - If ratio < 0.03: increment max_concurrency by 1
         - Reset counters
```

### 3.3 Component Communication Map

```
+----------+     HTTP      +--------+     HTTP      +----------+
|  Locust  | ----------->  | Router | ----------->  | Function |
|  (load)  |               |        |               | Instance |
+----------+               +---+----+               +----+-----+
                                |                         |
                           gRPC/HTTP                 Async HTTP POST
                           (read tags)               (metrics + latency)
                                |                         |
                                v                         v
                          +----------+              +-----------+
                          | ML Module| <----------- |  Metric   |
                          | (Flask)  |   push       | Collector |
                          +----------+   metrics    +-----------+
```

---

## 4. Simplifications and Justifications

### 4.1 What We Simplify and Why

| # | Paper's Approach | Our Simplification | Why It Is Acceptable |
|---|---|---|---|
| S1 | Mondrian Forest (online, incremental) | scikit-learn Random Forest (periodic batch retrain) | Paper shows batch RF achieves F1 0.71-0.84, nearly identical to online MF 0.70-0.84. The online property helps in production (continuous adaptation) but for a 1-hour evaluation, periodic retraining every N requests achieves the same effect. |
| S2 | 9 metrics including LLC cache misses | 7 metrics (skip LLCM and NodeLLCM) | LLC metrics require CAP_SYS_ADMIN privileges and perf stat. Paper's own CDF analysis (Fig 3) shows CPU, Memory, Inflight, and Network are the strongest discriminators. LLC adds value but is not essential for demonstrating the principle. |
| S3 | 8 benchmark functions in 5 languages | 3 functions in Python/Go | 3 functions covering CPU-bound, I/O-bound, and mixed workloads are sufficient to demonstrate routing differentiation. Reducing from 8 to 3 cuts development time by 60% without losing the core demonstration. |
| S4 | 7 worker nodes (c5.9xlarge: 36 vCPU, 72 GB) | 3 worker nodes (t3.xlarge: 4 vCPU, 16 GB) | Cost reduction from ~$75/day to ~$10/day. Fewer nodes still show collocation interference. The principle of OC vs Non-OC routing is node-count-independent. |
| S5 | Modified faas-netes in Go | Nginx reverse proxy + Python routing sidecar | Avoids forking and modifying Go code. Nginx handles request proxying; a Python sidecar implements the routing logic (Safe flag check, Power of Two Choices, Label check). Same routing decisions, different implementation vehicle. |
| S6 | Go relay for metric collection | Python daemon (DaemonSet) | Slower than Go but sufficient for our request rates (~100 RPS vs paper's 5000+ RPS). Python's cgroup/proc file parsing is straightforward. |
| S7 | Azure Function Trace (day 10 + day 13) | Synthetic trace via Locust mimicking diurnal pattern | The Azure trace is publicly available but requires processing. A synthetic trace with configurable RPS patterns (ramp, steady, spike, cool-down) demonstrates the same system behaviors with full control. |
| S8 | gRPC between relay and ML model | HTTP REST (Flask) | Lower throughput but simpler. At our scale (~100 RPS), HTTP latency (~1-5ms) is negligible compared to function execution time (~100-500ms). |

### 4.2 What We Do NOT Simplify

These elements are essential to the paper's contribution and must be implemented faithfully:

| Element | Why It Cannot Be Simplified |
|---|---|
| **Two-instance model (OC + Non-OC)** | This IS the paper's core idea. Without it, there is nothing to route between. |
| **Stratified reservoir sampling (50/50 balance)** | Without this, F1 drops from 0.78 to 0.26. The classifier becomes useless. This is the single most important implementation detail. |
| **Conservative routing (Safe flag + Labels)** | The two-level safety mechanism (global Safe flag + per-instance Labels) is what prevents SLO violations. Removing either level breaks the guarantee. |
| **Power of Two Choices** | This is the instance selection algorithm. Using random or round-robin instead would not match the paper's approach. |
| **MRU tiebreaker** | Most Recently Used routing is the paper's default. It complements keep-alive by allowing idle instances to be reclaimed. |
| **Vertical scaling (concurrency adjustment)** | The paper shows vertical scaling adds 8% additional memory savings and improves robustness. It is a stated contribution of the paper. |
| **Overcommitment formula** | `new_alloc = 0.3 * claimed + 0.7 * actual` is the exact formula. Changing alpha changes the experiment. |

### 4.3 Impact Analysis of Simplifications

```
Expected impact on results:

Paper's 42% memory reduction
  - Fewer functions:        -5% (less diversity in routing opportunities)
  - No LLC metrics:         -3% (slightly less accurate predictions)
  - RF vs MF:               -1% (nearly equivalent performance)
  - Smaller cluster:        -3% (less collocation diversity)
  - HTTP vs gRPC overhead:  -0% (routing latency still < 20ms at our scale)
  ────────────────────────
  Estimated reduction:      ~30% (vs paper's 42%)

Paper's SLO maintenance (< 5% violation)
  - No LLC metrics:         +2% more violations (less signal)
  - RF vs MF:               +1% more violations (no continuous adaptation)
  ────────────────────────
  Estimated violation rate: ~8% (vs paper's < 5%)

Both are acceptable for a course project demonstrating the principle.
```

---

## 5. Phase 0 — AWS Infrastructure Setup

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
  --description "Golgi cluster security group" \
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

# Allow HTTP/HTTPS from your IP (for OpenFaaS gateway and load generator)
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
| Master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway, Golgi router | 1 |
| Worker | t3.xlarge | 4 | 16 GB | Function instances, metric collector | 3 |
| Load Gen | t3.medium | 2 | 4 GB | Locust load generator | 1 |

**Why t3.xlarge for workers?** Each worker needs to run multiple function containers
(both OC and Non-OC). With 4 vCPUs and 16 GB RAM, each worker can host approximately:
- Non-OC instance at 512 MB: ~30 instances per node (memory-limited)
- OC instance at ~200 MB: ~75 instances per node
- Practical limit with system overhead: ~15-20 function instances per node

**Step 0.10: Launch instances**

```bash
# Amazon Linux 2023 AMI (us-east-1) — check current AMI ID
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
# Get public and private IPs for all instances
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=golgi-*" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table
```

Save these IPs — you will need them throughout the project:
```
MASTER_PUBLIC_IP=<...>
MASTER_PRIVATE_IP=<...>
WORKER1_PRIVATE_IP=<...>
WORKER2_PRIVATE_IP=<...>
WORKER3_PRIVATE_IP=<...>
LOADGEN_PUBLIC_IP=<...>
```

### 5.4 Install k3s

**Why k3s over full Kubernetes?**
- Single binary (~50 MB vs ~300 MB for kubeadm)
- Built-in containerd (no separate Docker install)
- Built-in Traefik ingress and CoreDNS
- Same K8s API — `kubectl` commands are identical
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
# Save this token as K3S_TOKEN

# Verify
sudo kubectl get nodes
# Should show: golgi-master  Ready  control-plane,master
```

**Why `--disable traefik`?** We use our own Nginx-based router. Traefik would conflict.

**Step 0.13: Join worker nodes**

On each worker node:
```bash
ssh -i golgi-key.pem ec2-user@$WORKER_PUBLIC_IP

# Join the cluster
curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_PRIVATE_IP}:6443 \
  K3S_TOKEN=${K3S_TOKEN} sh -s - \
  --node-name golgi-worker-N
```

**Step 0.14: Verify cluster**

Back on the master:
```bash
sudo kubectl get nodes -o wide
# Expected output:
# NAME              STATUS   ROLES                  AGE   VERSION   INTERNAL-IP
# golgi-master      Ready    control-plane,master   5m    v1.28.x   10.0.1.x
# golgi-worker-1    Ready    <none>                 2m    v1.28.x   10.0.1.x
# golgi-worker-2    Ready    <none>                 2m    v1.28.x   10.0.1.x
# golgi-worker-3    Ready    <none>                 2m    v1.28.x   10.0.1.x
```

**Step 0.15: Label worker nodes**

```bash
# Label workers for scheduling control
kubectl label node golgi-worker-1 role=worker node-type=function-host
kubectl label node golgi-worker-2 role=worker node-type=function-host
kubectl label node golgi-worker-3 role=worker node-type=function-host
```

### 5.5 Install OpenFaaS

**Step 0.16: Install OpenFaaS via Helm**

```bash
# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add OpenFaaS Helm repo
helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update

# Create namespaces
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

# Generate a password for the gateway
OPENFAAS_PASSWORD=$(head -c 16 /dev/urandom | sha256sum | head -c 32)
kubectl -n openfaas create secret generic basic-auth \
  --from-literal=basic-auth-user=admin \
  --from-literal=basic-auth-password="$OPENFAAS_PASSWORD"

echo "OpenFaaS password: $OPENFAAS_PASSWORD"  # Save this!

# Install OpenFaaS
helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=false \
  --set gateway.replicas=1 \
  --set queueWorker.replicas=1 \
  --set basic_auth=true \
  --set serviceType=NodePort

# Wait for pods to be ready
kubectl -n openfaas rollout status deployment/gateway

# Install faas-cli
curl -sL https://cli.openfaas.com | sudo sh

# Login
export OPENFAAS_URL=http://127.0.0.1:31112
echo -n $OPENFAAS_PASSWORD | faas-cli login --username admin --password-stdin
```

**Step 0.17: Verify OpenFaaS**

```bash
faas-cli list
# Should return empty list (no functions deployed yet)

# Check gateway is accessible
curl -s http://127.0.0.1:31112/healthz
# Should return: OK
```

### 5.6 Install Dependencies on All Nodes

**Step 0.18: Install Python and monitoring tools on worker nodes**

```bash
# On each worker node:
sudo yum install -y python3 python3-pip perf

# Install Python packages for metric collector
pip3 install --user flask requests psutil numpy
```

**Step 0.19: Install Python and ML packages on master node**

```bash
# On master node:
pip3 install --user flask requests numpy scikit-learn pandas matplotlib locust
```

### 5.7 Verify cgroup Version

**Why this matters:** The paper was likely developed on cgroup v1 (standard before 2022).
Amazon Linux 2023 uses cgroup v2. The metric collection paths differ.

```bash
# On a worker node:
stat -fc %T /sys/fs/cgroup/
# "cgroup2fs" = cgroup v2
# "tmpfs" = cgroup v1

# If cgroup v2, verify the unified hierarchy
ls /sys/fs/cgroup/
# Should show: cgroup.controllers, cgroup.subtree_control, cpu.stat, memory.stat, etc.
```

**Record this result.** Phase 2 (Metric Collector) uses different file paths depending on the
cgroup version. We will handle both but expect cgroup v2.

### 5.8 Checkpoint: Phase 0 Complete

Verify all of these before proceeding:

```
[ ] AWS VPC, subnet, and security group created
[ ] 5 EC2 instances running (1 master, 3 workers, 1 loadgen)
[ ] k3s cluster operational with 4 nodes (1 server + 3 agents)
[ ] OpenFaaS installed and gateway accessible
[ ] faas-cli authenticated
[ ] Python + dependencies installed on all nodes
[ ] cgroup version identified
[ ] All SSH connections working
[ ] All private IPs recorded
```

**Estimated time: 2-3 hours**
**Estimated AWS cost: ~$2 (if using spot instances)**

---

## 6. Phase 1 — Benchmark Functions

### 6.1 Function Selection

We deploy 3 functions covering three distinct resource profiles:

| Function | Name | Profile | Language | External Dep | Paper Analog |
|---|---|---|---|---|---|
| F1 | image-resize | CPU-bound | Python | None (PIL) | classify-image / detect-object |
| F2 | db-query | I/O-bound (network) | Python | Redis | query-vacancy / ingest-data |
| F3 | log-filter | Mixed (CPU + I/O) | Go | None | filter-log / anonymize-log |

**Design reasoning:**

- **image-resize (CPU-bound):** Resizing images using PIL/Pillow is CPU-intensive. It has
  predictable latency that degrades linearly with CPU contention. This maps to the paper's
  detect-object and classify-image functions (which use TF Serving for model inference).
  We use PIL instead of TF Serving to avoid the complexity of deploying a model server.

- **db-query (I/O-bound):** Querying a Redis database is network-bound. Latency depends
  on network bandwidth and Redis response time. This maps to query-vacancy (which
  accesses a key-value store). Redis is lightweight to deploy as a K8s service.

- **log-filter (Mixed):** Parsing and filtering log lines involves both string processing (CPU)
  and reading from an input source. This maps to filter-log and anonymize-log. We
  implement it in Go to demonstrate language diversity and because Go has low overhead.

### 6.2 Resource Configurations

Following the paper's overcommitment formula (Section 2.3):

```
OC_allocation = alpha * claimed + (1 - alpha) * actual
Where alpha = 0.3
```

| Function | Claimed Memory | Actual Usage (measured) | OC Memory | OC CPU |
|---|---|---|---|---|
| image-resize | 512 MB | ~80 MB | 0.3*512 + 0.7*80 = 209.6 MB | 0.3*1.0 + 0.7*0.15 = 0.405 CPU |
| db-query | 256 MB | ~40 MB | 0.3*256 + 0.7*40 = 104.8 MB | 0.3*0.5 + 0.7*0.05 = 0.185 CPU |
| log-filter | 256 MB | ~30 MB | 0.3*256 + 0.7*30 = 97.8 MB | 0.3*0.5 + 0.7*0.08 = 0.206 CPU |

**How to measure "actual usage":** Deploy the function with full resources, send 100
requests, and record peak memory from `cgroup memory.current`. Use the 75th percentile
as "actual usage" to be conservative.

### 6.3 Function Implementation

#### F1: image-resize (Python)

**Directory structure:**
```
functions/image-resize/
  handler.py
  requirements.txt
  Dockerfile
```

**handler.py logic:**
```python
# Pseudocode for image-resize function
# 1. Receive HTTP request with image dimensions (width x height)
# 2. Generate a random image in memory (simulates receiving an image)
# 3. Resize the image using PIL/Pillow (CPU-intensive operation)
# 4. Return the resized image dimensions and processing time

def handle(req):
    # Parse request: desired width and height
    params = json.loads(req)
    width = params.get("width", 1920)
    height = params.get("height", 1080)
    
    # Generate a random image (simulates download from storage)
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    for i in range(width):
        for j in range(height):
            pixels[i, j] = (random.randint(0, 255),
                           random.randint(0, 255),
                           random.randint(0, 255))
    
    # Resize (CPU-intensive)
    target_width = width // 2
    target_height = height // 2
    resized = img.resize((target_width, target_height), Image.LANCZOS)
    
    # Return result
    return json.dumps({
        "original": f"{width}x{height}",
        "resized": f"{target_width}x{target_height}",
        "timestamp": time.time()
    })
```

**requirements.txt:**
```
Pillow==10.2.0
```

**Why this design?**
- `Image.LANCZOS` resampling is computationally expensive (high-quality downscaling)
- Random pixel generation simulates variable input processing
- Latency scales predictably with image size and CPU contention
- No external dependencies (self-contained)

#### F2: db-query (Python)

**handler.py logic:**
```python
# Pseudocode for db-query function
# 1. Receive HTTP request with a query key
# 2. Connect to Redis
# 3. Perform a read + write operation
# 4. Return the result with timing info

def handle(req):
    params = json.loads(req)
    key = params.get("key", "default_key")
    
    # Connect to Redis (network operation)
    r = redis.Redis(host=REDIS_HOST, port=6379, db=0)
    
    # Read operation
    value = r.get(key)
    
    # Write operation (simulate update)
    r.set(f"result:{key}", json.dumps({
        "value": value.decode() if value else "null",
        "timestamp": time.time()
    }))
    
    # Small compute (parse and format)
    result = r.get(f"result:{key}")
    
    return result.decode()
```

**Why Redis?**
- Lightweight (runs as a single K8s pod, ~50 MB memory)
- Network-bound operations (connect, get, set)
- Latency dominated by network round-trip, not CPU
- Easy to deploy and manage

#### F3: log-filter (Go)

**handler.go logic:**
```go
// Pseudocode for log-filter function
// 1. Receive HTTP request with log text
// 2. Parse log lines (CPU-bound string processing)
// 3. Filter lines matching pattern (mixed CPU + memory)
// 4. Return filtered count and sample

func Handle(w http.ResponseWriter, r *http.Request) {
    body, _ := io.ReadAll(r.Body)
    
    // Generate synthetic log data if none provided
    logLines := generateLogLines(1000) // 1000 log lines
    
    // CPU-intensive: regex matching on each line
    pattern := regexp.MustCompile(`ERROR|WARN|CRITICAL`)
    var filtered []string
    for _, line := range logLines {
        if pattern.MatchString(line) {
            // String manipulation (CPU)
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

### 6.4 Deploying Functions to OpenFaaS

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

```bash
kubectl apply -f redis-deployment.yaml
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
      max_inflight: 4           # Initial concurrency limit (paper: S8.1)
    requests:
      memory: 512Mi             # Non-OC allocation
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
      memory: 210Mi             # OC allocation: 0.3*512 + 0.7*80
      cpu: "405m"               # OC allocation: 0.3*1000 + 0.7*150
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
      memory: 105Mi             # OC: 0.3*256 + 0.7*40
      cpu: "185m"               # OC: 0.3*500 + 0.7*50
    limits:
      memory: 105Mi
      cpu: "185m"

  log-filter:
    lang: go-http
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
    lang: go-http
    handler: ./functions/log-filter
    image: golgi/log-filter:latest
    environment:
      max_inflight: 4
    requests:
      memory: 98Mi              # OC: 0.3*256 + 0.7*30
      cpu: "206m"               # OC: 0.3*500 + 0.7*80
    limits:
      memory: 98Mi
      cpu: "206m"
```

**Step 1.3: Build and deploy**

```bash
# Build all functions
faas-cli build -f stack.yml

# Push to a registry (or use local images with k3s)
# For k3s, you can import images directly:
for img in image-resize db-query log-filter; do
  docker save golgi/${img}:latest | sudo k3s ctr images import -
done

# Deploy
faas-cli deploy -f stack.yml

# Verify
faas-cli list
# Should show 6 functions (3 non-OC + 3 OC)
```

**Step 1.4: Baseline latency measurement**

```bash
# Measure Non-OC P95 latency for each function (this becomes the SLO)
# Send 200 requests to each Non-OC function and record latency

for func in image-resize db-query log-filter; do
  echo "Testing $func..."
  for i in $(seq 1 200); do
    start=$(date +%s%N)
    curl -s http://127.0.0.1:31112/function/$func \
      -d '{"width":1920,"height":1080}' > /dev/null
    end=$(date +%s%N)
    echo "$(( (end - start) / 1000000 ))" >> /tmp/${func}_latencies.txt
  done
  
  # Calculate P95
  sort -n /tmp/${func}_latencies.txt | \
    awk 'NR==int(0.95*NR_TOTAL)+1{print "P95:", $1, "ms"}' NR_TOTAL=200
done
```

**Record these P95 values as the SLO thresholds:**

```
SLO_image_resize = <measured P95 from Non-OC> ms
SLO_db_query     = <measured P95 from Non-OC> ms
SLO_log_filter   = <measured P95 from Non-OC> ms
```

### 6.5 Checkpoint: Phase 1 Complete

```
[ ] 3 Non-OC functions deployed and responding
[ ] 3 OC functions deployed and responding
[ ] Redis service running and accessible from db-query functions
[ ] Baseline P95 latency measured for each function (SLO thresholds)
[ ] Resource configurations match the overcommitment formula
[ ] All functions handle concurrent requests (max_inflight = 4)
```

**Estimated time: 4-6 hours**

---

## 7. Phase 2 — Metric Collector

### 7.1 Design Overview

The metric collector is a daemon that runs on each worker node (deployed as a K8s
DaemonSet). It scrapes 7 metrics per function instance every 500ms and pushes them to
the ML Module.

### 7.2 The 7 Metrics We Collect

| # | Metric | Source | Type | Unit |
|---|---|---|---|---|
| 1 | CPU utilization | cgroup | Intra-container | Percentage (0-100) |
| 2 | Memory utilization | cgroup | Intra-container | Percentage (0-100) |
| 3 | Inflight requests | Watchdog HTTP endpoint | Intra-container | Integer (0-N) |
| 4 | NetRx (container) | /proc/net/dev | Collocation | Bytes/sec |
| 5 | NetTx (container) | /proc/net/dev | Collocation | Bytes/sec |
| 6 | NodeNetRx | /proc/net/dev (host) | Collocation | Bytes/sec |
| 7 | NodeNetTx | /proc/net/dev (host) | Collocation | Bytes/sec |

**Why 7 and not 9?** We skip LLCM and NodeLLCM (LLC cache miss metrics) because:
1. They require `CAP_SYS_ADMIN` or `CAP_PERFMON` privileges
2. `perf stat` may not be available on all EC2 instance types
3. Paper's CDF analysis shows CPU, Memory, and Inflight are the strongest discriminators
4. Network metrics capture most collocation interference

### 7.3 Metric Collection: Exact Linux Paths and Methods

#### 7.3.1 CPU Utilization (cgroup v2)

**Source file:** `/sys/fs/cgroup/<pod-cgroup-path>/cpu.stat`

**Contents of cpu.stat:**
```
usage_usec 123456789
user_usec 100000000
system_usec 23456789
nr_periods 1000
nr_throttled 50
throttled_usec 5000000
```

**How to compute CPU utilization:**

```
CPU utilization = delta(usage_usec) / (delta(wall_time_usec) * num_cpus) * 100

Where:
  delta(usage_usec)     = cpu.stat[usage_usec] at time T2 - cpu.stat[usage_usec] at time T1
  delta(wall_time_usec) = (T2 - T1) in microseconds
  num_cpus              = allocated CPU cores for this container
```

**Example:**
```
At T1 = 0s:     usage_usec = 100,000,000  (100 seconds of CPU time used)
At T2 = 0.5s:   usage_usec = 100,250,000  (100.25 seconds of CPU time used)

delta(usage_usec) = 250,000 usec = 0.25 seconds of CPU in 0.5 seconds of wall time
If container has 1 CPU: utilization = 250,000 / (500,000 * 1) * 100 = 50%
If container has 0.4 CPU: utilization = 250,000 / (500,000 * 0.4) * 100 = 125% (throttled)
```

**Finding the cgroup path for a Kubernetes pod:**

```bash
# Method 1: From the container runtime
# Get container ID from kubectl
CONTAINER_ID=$(kubectl get pod <pod-name> -n openfaas-fn \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')

# cgroup v2 path:
# /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/
#   cri-containerd-<CONTAINER_ID>.scope/cpu.stat

# Method 2: From /proc/<pid>/cgroup
# Find the PID of the function process
PID=$(crictl inspect $CONTAINER_ID | jq '.info.pid')
cat /proc/$PID/cgroup
# Output (cgroup v2): 0::/kubepods.slice/kubepods-burstable.slice/cri-containerd-<id>.scope
```

**Programmatic approach in Python:**

```python
# Pseudocode: find_cgroup_path(container_id)
def find_cgroup_path(container_id):
    """
    Given a container ID, find its cgroup v2 path.
    
    Logic:
    1. Search /sys/fs/cgroup/kubepods.slice/ recursively
    2. Look for directories containing the container ID
    3. Return the full path
    """
    base = "/sys/fs/cgroup/kubepods.slice"
    for qos in ["kubepods-burstable.slice", "kubepods-besteffort.slice", ""]:
        search_dir = os.path.join(base, qos) if qos else base
        for entry in os.listdir(search_dir):
            if container_id[:12] in entry:
                return os.path.join(search_dir, entry)
    return None

def read_cpu_utilization(cgroup_path, prev_usage, prev_time, num_cpus):
    """
    Read CPU utilization as a percentage.
    
    Returns: (utilization_percent, current_usage, current_time)
    """
    cpu_stat_path = os.path.join(cgroup_path, "cpu.stat")
    with open(cpu_stat_path, 'r') as f:
        for line in f:
            if line.startswith("usage_usec"):
                current_usage = int(line.split()[1])
                break
    
    current_time = time.time_ns() // 1000  # microseconds
    
    if prev_usage is not None:
        delta_usage = current_usage - prev_usage
        delta_time = current_time - prev_time
        utilization = (delta_usage / (delta_time * num_cpus)) * 100
        utilization = max(0, min(utilization, 100))  # clamp to [0, 100]
    else:
        utilization = 0.0  # first reading, no delta yet
    
    return utilization, current_usage, current_time
```

#### 7.3.2 Memory Utilization (cgroup v2)

**Source files:**
- `/sys/fs/cgroup/<pod-cgroup-path>/memory.current` — current usage in bytes
- `/sys/fs/cgroup/<pod-cgroup-path>/memory.max` — configured limit in bytes

```python
def read_memory_utilization(cgroup_path):
    """
    Read memory utilization as a percentage of the limit.
    
    memory.current includes RSS + cache. For a more precise working-set
    measurement, read memory.stat and use (anon + file) instead.
    For our purposes, memory.current / memory.max is sufficient.
    """
    current_path = os.path.join(cgroup_path, "memory.current")
    max_path = os.path.join(cgroup_path, "memory.max")
    
    with open(current_path, 'r') as f:
        current = int(f.read().strip())
    
    with open(max_path, 'r') as f:
        content = f.read().strip()
        if content == "max":
            # No limit set — use node total memory as denominator
            mem_max = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
        else:
            mem_max = int(content)
    
    utilization = (current / mem_max) * 100
    return utilization
```

#### 7.3.3 Inflight Requests

**Source:** HTTP endpoint exposed by the watchdog or a Prometheus metric.

The OpenFaaS of-watchdog exposes a Prometheus metric `http_requests_in_flight` on
each function pod's metrics port (typically :8081). We can scrape this directly.

```python
def read_inflight_requests(pod_ip, metrics_port=8081):
    """
    Read inflight request count from the watchdog's Prometheus endpoint.
    
    Alternative: if we modify the watchdog, expose a simple /inflight
    endpoint that returns the atomic counter value.
    """
    try:
        response = requests.get(
            f"http://{pod_ip}:{metrics_port}/metrics",
            timeout=0.5
        )
        for line in response.text.split('\n'):
            if line.startswith('http_requests_in_flight'):
                return int(float(line.split()[-1]))
    except Exception:
        return 0
    return 0
```

#### 7.3.4 Network I/O (Container-Level)

**Source file:** `/proc/<container-pid>/net/dev`

```
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets ...
    lo: 12345678  54321    0    0    0     0          0         0 12345678  54321 ...
  eth0: 98765432  87654    0    0    0     0          0         0 45678901  34567 ...
```

**How to get per-container network stats:**

Each container has its own network namespace (in Kubernetes, all containers in a pod
share a network namespace). Reading `/proc/<any-pid-in-container>/net/dev` gives
stats isolated to that container's namespace.

```python
def read_container_network(container_pid, prev_rx, prev_tx, prev_time):
    """
    Read NetRx and NetTx in bytes/sec for a container.
    
    Uses /proc/<pid>/net/dev to read from the container's network namespace.
    """
    net_dev_path = f"/proc/{container_pid}/net/dev"
    rx_bytes = 0
    tx_bytes = 0
    
    with open(net_dev_path, 'r') as f:
        lines = f.readlines()
        for line in lines[2:]:  # Skip header lines
            parts = line.split()
            iface = parts[0].rstrip(':')
            if iface == 'lo':
                continue  # Skip loopback
            rx_bytes += int(parts[1])   # Receive bytes (column 1)
            tx_bytes += int(parts[9])   # Transmit bytes (column 9)
    
    current_time = time.time()
    
    if prev_rx is not None:
        delta_time = current_time - prev_time
        net_rx_rate = (rx_bytes - prev_rx) / delta_time  # bytes/sec
        net_tx_rate = (tx_bytes - prev_tx) / delta_time
    else:
        net_rx_rate = 0.0
        net_tx_rate = 0.0
    
    return net_rx_rate, net_tx_rate, rx_bytes, tx_bytes, current_time
```

#### 7.3.5 Network I/O (Node-Level)

**Source file:** `/proc/net/dev` (from host namespace)

Same format as container-level but reads from the host's network namespace.
The DaemonSet runs in the host network namespace (hostNetwork: true) to access this.

```python
def read_node_network(prev_rx, prev_tx, prev_time):
    """
    Read NodeNetRx and NodeNetTx in bytes/sec for the entire node.
    
    Uses /proc/net/dev from the host namespace.
    Since DaemonSet runs with hostNetwork: true, /proc/net/dev
    gives the host's network stats.
    """
    # Same parsing logic as container-level, but reading /proc/net/dev
    # (host namespace) and summing all non-loopback interfaces
    return read_container_network(1, prev_rx, prev_tx, prev_time)
    # PID 1 on host = init process = host namespace
```

### 7.4 Container Discovery

The metric collector needs to know which containers are running on its node and which
are OC vs Non-OC instances.

```python
def discover_containers():
    """
    Discover all function containers on this node.
    
    Returns a list of:
    {
        "pod_name": "image-resize-oc-abc123",
        "function_name": "image-resize",
        "is_oc": True,
        "container_id": "abc123def456...",
        "pid": 12345,
        "cgroup_path": "/sys/fs/cgroup/kubepods.slice/...",
        "pod_ip": "10.42.1.5"
    }
    
    Logic:
    1. Query kubectl (or K8s API) for pods on this node in openfaas-fn namespace
    2. For each pod, determine if it's OC (name ends with "-oc")
    3. Get container ID and PID from container runtime
    4. Map to cgroup path
    """
    # Use kubectl to list pods on this node
    node_name = socket.gethostname()
    pods = kubectl_get_pods(namespace="openfaas-fn", field_selector=f"spec.nodeName={node_name}")
    
    containers = []
    for pod in pods:
        name = pod["metadata"]["name"]
        function_name = name.rsplit("-", 2)[0]  # Remove K8s suffix
        is_oc = "-oc" in function_name
        base_function = function_name.replace("-oc", "")
        
        container_id = pod["status"]["containerStatuses"][0]["containerID"].split("//")[1]
        pid = get_container_pid(container_id)  # via crictl inspect
        cgroup_path = find_cgroup_path(container_id)
        pod_ip = pod["status"]["podIP"]
        
        containers.append({
            "pod_name": name,
            "function_name": base_function,
            "is_oc": is_oc,
            "container_id": container_id,
            "pid": pid,
            "cgroup_path": cgroup_path,
            "pod_ip": pod_ip
        })
    
    return containers
```

### 7.5 The Collection Loop

```python
def collection_loop(ml_module_url, interval_ms=500):
    """
    Main metric collection loop.
    
    Runs every interval_ms milliseconds.
    For each container on this node:
      1. Read 7 metrics
      2. Construct context vector
      3. Push to ML Module
    
    Also reads node-level metrics once per cycle.
    """
    # State tracking for delta calculations
    cpu_state = {}    # container_id -> (prev_usage, prev_time)
    net_state = {}    # container_id -> (prev_rx, prev_tx, prev_time)
    node_net_state = {"prev_rx": None, "prev_tx": None, "prev_time": None}
    
    while True:
        cycle_start = time.time()
        
        # Step 1: Discover containers (re-discover every 10 cycles for new/removed pods)
        if cycle_count % 10 == 0:
            containers = discover_containers()
        
        # Step 2: Read node-level network metrics (once per cycle)
        node_net_rx, node_net_tx, node_net_state["prev_rx"], \
            node_net_state["prev_tx"], node_net_state["prev_time"] = \
            read_node_network(
                node_net_state["prev_rx"],
                node_net_state["prev_tx"],
                node_net_state["prev_time"]
            )
        
        # Step 3: For each container, collect metrics
        batch = []
        for container in containers:
            cid = container["container_id"]
            
            # CPU utilization
            cpu_util, cpu_state[cid] = read_cpu_utilization(
                container["cgroup_path"],
                cpu_state.get(cid, {}).get("prev_usage"),
                cpu_state.get(cid, {}).get("prev_time"),
                container.get("cpu_limit", 1.0)
            )
            
            # Memory utilization
            mem_util = read_memory_utilization(container["cgroup_path"])
            
            # Inflight requests
            inflight = read_inflight_requests(container["pod_ip"])
            
            # Container network
            net_rx, net_tx, net_state[cid] = read_container_network(
                container["pid"],
                net_state.get(cid, {}).get("prev_rx"),
                net_state.get(cid, {}).get("prev_tx"),
                net_state.get(cid, {}).get("prev_time")
            )
            
            # Construct 7-D context vector
            context_vector = [
                cpu_util,       # 0: CPU utilization (%)
                mem_util,       # 1: Memory utilization (%)
                inflight,       # 2: Inflight requests (count)
                net_rx,         # 3: NetRx (bytes/sec)
                net_tx,         # 4: NetTx (bytes/sec)
                node_net_rx,    # 5: NodeNetRx (bytes/sec)
                node_net_tx     # 6: NodeNetTx (bytes/sec)
            ]
            
            batch.append({
                "pod_name": container["pod_name"],
                "function_name": container["function_name"],
                "is_oc": container["is_oc"],
                "context_vector": context_vector,
                "timestamp": time.time()
            })
        
        # Step 4: Push batch to ML Module
        try:
            requests.post(
                f"{ml_module_url}/metrics",
                json={"metrics": batch},
                timeout=1.0
            )
        except Exception as e:
            logging.warning(f"Failed to push metrics: {e}")
        
        # Step 5: Sleep until next interval
        elapsed = time.time() - cycle_start
        sleep_time = max(0, (interval_ms / 1000.0) - elapsed)
        time.sleep(sleep_time)
```

### 7.6 DaemonSet Deployment

```yaml
# metric-collector-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: golgi-metric-collector
  namespace: openfaas-fn
spec:
  selector:
    matchLabels:
      app: golgi-metric-collector
  template:
    metadata:
      labels:
        app: golgi-metric-collector
    spec:
      hostNetwork: true         # Access host /proc/net/dev
      hostPID: true             # Access container PIDs via /proc
      nodeSelector:
        role: worker
      tolerations:
      - operator: Exists
      containers:
      - name: collector
        image: golgi/metric-collector:latest
        securityContext:
          privileged: true       # Required for reading cgroup files of other containers
        env:
        - name: ML_MODULE_URL
          value: "http://golgi-master:5000"
        - name: COLLECTION_INTERVAL_MS
          value: "500"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: cgroup
          mountPath: /sys/fs/cgroup
          readOnly: true
        - name: proc
          mountPath: /host-proc
          readOnly: true
      volumes:
      - name: cgroup
        hostPath:
          path: /sys/fs/cgroup
      - name: proc
        hostPath:
          path: /proc
```

### 7.7 Checkpoint: Phase 2 Complete

```
[ ] Metric collector reads CPU utilization from cgroup v2 (verified with manual check)
[ ] Metric collector reads memory utilization from cgroup v2
[ ] Metric collector reads inflight requests from watchdog metrics endpoint
[ ] Metric collector reads per-container network I/O from /proc/<pid>/net/dev
[ ] Metric collector reads node-level network I/O from /proc/net/dev
[ ] Container discovery correctly identifies OC vs Non-OC pods
[ ] DaemonSet runs on all 3 worker nodes
[ ] Metrics are pushed to ML Module endpoint every 500ms
[ ] Context vectors are 7-dimensional and correctly ordered
```

**Estimated time: 5-7 days**

---

## 8. Phase 3 — ML Module

### 8.1 Design Overview

The ML Module is a Python Flask service running on the master node. It:

1. Receives metric vectors + latency data from function instances
2. Labels each data point (positive if SLO violated, negative otherwise)
3. Maintains balanced training data via stratified reservoir sampling
4. Trains/updates a Random Forest classifier
5. Periodically runs batch inference on all OC instances
6. Caches Label tags and the Safe flag for the router to read

### 8.2 The Mathematics

#### 8.2.1 Binary Classification Problem

For each incoming request to an OC instance, we want to predict:

```
y = f(x) where:
  x = [CPU, Mem, Inflight, NetRx, NetTx, NodeNetRx, NodeNetTx]  (7-D vector)
  y ∈ {0, 1}
  y = 0 means "this request will meet the SLO" (negative)
  y = 1 means "this request will violate the SLO" (positive)
```

**Ground truth labeling:**
```
Given: SLO_threshold (P95 latency from Non-OC baseline)
For each completed request with measured latency L:
  if L > SLO_threshold:
    label = 1 (positive — SLO violated)
  else:
    label = 0 (negative — SLO met)
```

#### 8.2.2 The Class Imbalance Problem

In normal operation, most OC requests meet the SLO. The paper reports a 10:1
negative-to-positive ratio. This means:

```
Naive dataset:  [0, 0, 0, 0, 0, 0, 0, 0, 0, 1]  (10% positive)

If a classifier always predicts 0 (negative):
  Accuracy = 90%     (looks great!)
  Recall   = 0%      (catches zero SLO violations — useless)
  F1       = 0.0     (harmonic mean penalizes zero recall)
```

The paper shows this directly: imbalanced training yields F1 = 0.26 (Section 8.4).

#### 8.2.3 Stratified Reservoir Sampling — Algorithm 1

The fix: maintain two separate reservoirs, one for positive and one for negative examples.
Always combine them in 50/50 ratio for training.

**Algorithm (from the paper, Section 4.4):**

```
Input:
  N = batch size (we use N = 32)
  pos = [] (positive reservoir, max size N/2)
  neg = [] (negative reservoir, max size N/2)
  posCntr = 0 (total positive samples seen)
  negCntr = 0 (total negative samples seen)

For each arriving data point (x, y):
  if y == 1:     # Positive sample
    posCntr += 1
    if len(pos) < N/2:
      pos.append((x, y))              # Fill reservoir
    else:
      j = random.randint(0, posCntr)  # Reservoir sampling
      if j < len(pos):
        pos[j] = (x, y)              # Replace with probability N/(2*posCntr)
  
  else:          # Negative sample (y == 0)
    negCntr += 1
    if len(neg) < N/2:
      neg.append((x, y))
    else:
      j = random.randint(0, negCntr)
      if j < len(neg):
        neg[j] = (x, y)

  # Check if both reservoirs are full
  if len(pos) >= N/2 and len(neg) >= N/2:
    training_batch = pos + neg        # Balanced batch of size N
    model.partial_fit(training_batch) # or model.fit() for full retrain
    pos = []                          # Reset reservoirs
    neg = []
    posCntr = 0
    negCntr = 0
```

**Why reservoir sampling and not just collecting N/2 of each?**

Reservoir sampling gives each arriving sample an equal probability of being in the
final training set, regardless of when it arrived. This prevents temporal bias — without
it, early samples would dominate the training set, and the model would not adapt to
changing conditions.

**The math of reservoir sampling probability:**

For the k-th arriving sample (where k > N/2), the probability that it replaces
an existing sample in the reservoir is:

```
P(replacement) = (N/2) / k
```

This decreases as more samples arrive, ensuring:
1. All samples have equal probability of being in the final reservoir
2. The reservoir represents a uniform random sample of the entire stream
3. Memory usage is bounded (exactly N/2 slots per class)

#### 8.2.4 Random Forest Classifier

**Why Random Forest?**

| Property | Random Forest | Neural Network | Logistic Regression |
|---|---|---|---|
| Works on tabular data | Excellent | Mediocre | Good |
| Training time | Fast | Slow | Fast |
| Handles non-linear boundaries | Yes | Yes | No |
| Requires hyperparameter tuning | Minimal | Extensive | Minimal |
| Paper's F1 score | 0.71-0.84 | 0.0-0.73 | Not tested |

**Configuration:**

```python
from sklearn.ensemble import RandomForestClassifier

model = RandomForestClassifier(
    n_estimators=100,         # Paper uses 100 trees (S3.3)
    max_depth=10,             # Prevent overfitting on small batches
    min_samples_split=5,      # Minimum samples to split a node
    min_samples_leaf=2,       # Minimum samples in a leaf
    class_weight="balanced",  # Additional class balancing (belt + suspenders)
    random_state=42,          # Reproducibility
    n_jobs=-1                 # Use all CPU cores
)
```

**Training strategy:**

Since sklearn's RandomForest does not support `partial_fit`, we use periodic full retraining:

```
1. Collect samples into stratified reservoir (Algorithm 1)
2. When reservoir is full (N/2 positive + N/2 negative):
   a. Combine into balanced batch of size N
   b. Add to a rolling training buffer (keep last M batches)
   c. Retrain the model on the entire buffer
3. Repeat
```

The rolling buffer ensures the model sees recent data while retaining some history.

```python
BATCH_SIZE = 32           # N in Algorithm 1
MAX_BUFFER_SIZE = 500     # Keep last 500 samples for training
RETRAIN_INTERVAL = 32     # Retrain every time a new balanced batch arrives
```

### 8.3 The Bootstrapping Problem

**Problem:** At startup, there are zero positive examples (SLO violations are rare).
The model cannot learn what "bad" looks like without seeing any bad examples.

**Solution: Intentional overload seeding.**

Before starting normal evaluation:
1. Route ALL requests to OC instances for 60 seconds at high load (2x normal RPS)
2. This forces contention and generates SLO violations (positive samples)
3. Collect these samples to seed the positive reservoir
4. After seeding, switch to normal routing

```python
def bootstrap_model(functions, oc_instances, load_rps=50, duration_sec=60):
    """
    Generate initial training data by intentionally overloading OC instances.
    
    This creates the positive examples needed to bootstrap the classifier.
    Without this, the model has zero positive examples and always predicts 0.
    """
    print("=== BOOTSTRAPPING: Overloading OC instances for training data ===")
    
    training_data = []
    for func in functions:
        # Send high traffic to OC instances only
        for _ in range(int(load_rps * duration_sec)):
            instance = random.choice(oc_instances[func])
            start_time = time.time()
            context_vector = get_current_metrics(instance)
            
            response = send_request(instance)
            latency = time.time() - start_time
            
            label = 1 if latency > SLO_THRESHOLDS[func] else 0
            training_data.append((context_vector, label))
    
    # Count positive vs negative
    positives = sum(1 for _, y in training_data if y == 1)
    negatives = sum(1 for _, y in training_data if y == 0)
    print(f"Bootstrapping complete: {positives} positive, {negatives} negative samples")
    
    # Train initial model
    X = np.array([x for x, _ in training_data])
    y = np.array([y for _, y in training_data])
    
    # Balance the initial dataset
    min_class = min(positives, negatives)
    pos_indices = np.where(y == 1)[0][:min_class]
    neg_indices = np.where(y == 0)[0][:min_class]
    balanced_indices = np.concatenate([pos_indices, neg_indices])
    
    model.fit(X[balanced_indices], y[balanced_indices])
    print(f"Initial model trained on {len(balanced_indices)} balanced samples")
```

### 8.4 Safe Flag Logic

The Safe flag is a global per-function indicator that tells the router whether it is safe
to explore OC instances.

```python
class SafeFlagManager:
    """
    Manages the Safe flag for each function.
    
    Safe = 1: Overall SLO is being met. Router may explore OC instances.
    Safe = 0: Overall SLO is violated. Router must use Non-OC only.
    
    The paper says Safe starts at 1 (first request goes to OC for exploration).
    
    Logic:
    - Maintain a rolling window of the last W request latencies
    - Compute rolling P95
    - If rolling P95 > SLO threshold * 1.0: Safe = 0
    - If rolling P95 < SLO threshold * 0.9: Safe = 1 (with hysteresis)
    
    The 0.9 factor provides hysteresis to prevent oscillation.
    """
    
    def __init__(self, slo_thresholds, window_size=200):
        self.slo_thresholds = slo_thresholds  # per-function SLO
        self.latency_windows = {}  # function -> deque of latencies
        self.safe_flags = {}       # function -> bool
        self.window_size = window_size
        
        # Initialize all functions as Safe (paper: S4.2)
        for func in slo_thresholds:
            self.safe_flags[func] = True
            self.latency_windows[func] = deque(maxlen=window_size)
    
    def record_latency(self, function_name, latency):
        self.latency_windows[function_name].append(latency)
        self._update_safe_flag(function_name)
    
    def _update_safe_flag(self, function_name):
        window = self.latency_windows[function_name]
        if len(window) < 20:  # Need minimum samples
            return
        
        # Compute rolling P95
        sorted_latencies = sorted(window)
        p95_index = int(0.95 * len(sorted_latencies))
        rolling_p95 = sorted_latencies[p95_index]
        
        slo = self.slo_thresholds[function_name]
        
        if rolling_p95 > slo:
            # SLO violated — stop exploring
            self.safe_flags[function_name] = False
        elif rolling_p95 < slo * 0.9:
            # SLO comfortably met — resume exploring
            # The 0.9 factor provides hysteresis
            self.safe_flags[function_name] = True
        # else: in the [0.9*SLO, SLO] band — keep current state (hysteresis)
    
    def is_safe(self, function_name):
        return self.safe_flags.get(function_name, True)
```

### 8.5 Label Prediction Loop

The ML Module periodically runs inference on all OC instances and caches their labels.

```python
class LabelPredictor:
    """
    Periodically predicts Label tags for all OC instances.
    
    Paper approach: Relay collects metrics from groups of 100 instances,
    runs batch inference, updates labels every ~82ms.
    
    Our approach: Every 500ms (matching our metric collection interval),
    read the latest metrics for all OC instances and run batch inference.
    
    Label = 0: Instance is predicted safe (route requests here)
    Label = 1: Instance is predicted unsafe (avoid routing here)
    """
    
    def __init__(self, model, interval_sec=0.5):
        self.model = model
        self.interval_sec = interval_sec
        self.labels = {}  # pod_name -> label (0 or 1)
        self.latest_metrics = {}  # pod_name -> context_vector
    
    def update_metrics(self, pod_name, context_vector):
        """Called by metric collector when new metrics arrive."""
        self.latest_metrics[pod_name] = context_vector
    
    def predict_labels(self):
        """
        Run batch inference on all OC instances.
        
        Returns: dict of pod_name -> predicted_label
        """
        oc_pods = {k: v for k, v in self.latest_metrics.items() if "-oc" in k}
        
        if not oc_pods or self.model is None:
            return self.labels
        
        pod_names = list(oc_pods.keys())
        X = np.array([oc_pods[name] for name in pod_names])
        
        predictions = self.model.predict(X)  # Batch inference
        
        for name, pred in zip(pod_names, predictions):
            self.labels[name] = int(pred)
        
        return self.labels
    
    def get_label(self, pod_name):
        """Get cached label for a specific instance."""
        return self.labels.get(pod_name, 1)  # Default: unsafe (conservative)
```

### 8.6 Complete ML Module Service

```python
# ml_module.py — Flask service

from flask import Flask, request, jsonify
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from collections import deque
import threading
import time

app = Flask(__name__)

# --- Global State ---
model = None                        # RandomForestClassifier
training_buffer_X = []              # Feature vectors
training_buffer_y = []              # Labels
pos_reservoir = []                  # Positive reservoir (Algorithm 1)
neg_reservoir = []                  # Negative reservoir
pos_counter = 0
neg_counter = 0
BATCH_SIZE = 32
MAX_TRAINING_BUFFER = 500
labels_cache = {}                   # pod_name -> label
safe_flags = {}                     # function_name -> bool
slo_thresholds = {}                 # function_name -> threshold_ms
latency_windows = {}                # function_name -> deque
latest_metrics = {}                 # pod_name -> context_vector

# --- Endpoints ---

@app.route('/metrics', methods=['POST'])
def receive_metrics():
    """Receive metric batch from DaemonSet collectors."""
    data = request.json
    for entry in data.get("metrics", []):
        pod_name = entry["pod_name"]
        latest_metrics[pod_name] = entry["context_vector"]
    return jsonify({"status": "ok"})

@app.route('/training_sample', methods=['POST'])
def receive_training_sample():
    """Receive completed request data for model training."""
    data = request.json
    context_vector = data["context_vector"]
    latency = data["latency"]
    function_name = data["function_name"]
    
    # Label the sample
    slo = slo_thresholds.get(function_name, float('inf'))
    label = 1 if latency > slo else 0
    
    # Record latency for Safe flag
    record_latency(function_name, latency)
    
    # Stratified reservoir sampling (Algorithm 1)
    add_to_reservoir(context_vector, label)
    
    return jsonify({"status": "ok"})

@app.route('/labels', methods=['GET'])
def get_labels():
    """Return cached Label tags for all OC instances."""
    return jsonify(labels_cache)

@app.route('/safe/<function_name>', methods=['GET'])
def get_safe_flag(function_name):
    """Return Safe flag for a function."""
    return jsonify({"safe": safe_flags.get(function_name, True)})

@app.route('/config', methods=['POST'])
def set_config():
    """Set SLO thresholds and function configurations."""
    data = request.json
    for func, threshold in data.get("slo_thresholds", {}).items():
        slo_thresholds[func] = threshold
        safe_flags[func] = True  # Paper: Safe starts at 1
        latency_windows[func] = deque(maxlen=200)
    return jsonify({"status": "configured"})

# --- Background prediction loop ---
def prediction_loop():
    """Run batch inference every 500ms."""
    global labels_cache
    while True:
        if model is not None:
            oc_pods = {k: v for k, v in latest_metrics.items() if "-oc" in k}
            if oc_pods:
                pod_names = list(oc_pods.keys())
                X = np.array([oc_pods[n] for n in pod_names])
                try:
                    predictions = model.predict(X)
                    for name, pred in zip(pod_names, predictions):
                        labels_cache[name] = int(pred)
                except Exception as e:
                    pass
        time.sleep(0.5)

threading.Thread(target=prediction_loop, daemon=True).start()
```

### 8.7 Checkpoint: Phase 3 Complete

```
[ ] Flask ML Module service running on master node
[ ] /metrics endpoint receives context vectors from DaemonSet
[ ] /training_sample endpoint receives latency + context for labeling
[ ] Stratified reservoir sampling correctly balances 50/50
[ ] Random Forest trains on balanced batches
[ ] Batch prediction runs every 500ms on all OC instances
[ ] Label cache is populated and queryable via /labels
[ ] Safe flag is maintained per function via rolling P95
[ ] Bootstrap seeding generates initial positive samples
[ ] F1 score exceeds 0.50 after bootstrapping (target: 0.65+)
```

**Estimated time: 3-5 days**

---

## 9. Phase 4 — The Router

### 9.1 Routing Algorithm

The router implements the paper's conservative exploration-exploitation strategy.

**Algorithm (from Section 4.2):**

```
def route_request(function_name, request):
    """
    Route an incoming request to either OC or Non-OC instance.
    
    Paper: Section 4.2 — Conservative Routing
    
    1. Check Safe flag
    2. If unsafe, route to Non-OC (exploit)
    3. If safe, use Power of Two Choices on OC instances
    4. If any OC candidate has Label=0, route there (explore)
    5. If all candidates Label=1, route to Non-OC (exploit)
    6. Among safe OC candidates, use MRU tiebreaker
    """
    
    # Step 1: Check global Safe flag
    safe = get_safe_flag(function_name)
    
    if not safe:
        # Step 2: SLO is violated globally — use Non-OC only
        instance = select_non_oc_instance(function_name, strategy="MRU")
        return instance, "exploit_unsafe"
    
    # Step 3: Power of Two Choices
    # Randomly pick 2 OC instances
    oc_instances = get_available_oc_instances(function_name)
    
    if len(oc_instances) < 2:
        # Not enough OC instances — fall back to Non-OC
        instance = select_non_oc_instance(function_name, strategy="MRU")
        return instance, "exploit_no_oc"
    
    candidate1, candidate2 = random.sample(oc_instances, 2)
    
    # Step 4: Check Label tags
    label1 = get_label(candidate1)
    label2 = get_label(candidate2)
    
    if label1 == 0 and label2 == 0:
        # Both safe — use MRU tiebreaker
        instance = mru_select(candidate1, candidate2)
        return instance, "explore_both_safe"
    
    elif label1 == 0:
        return candidate1, "explore_one_safe"
    
    elif label2 == 0:
        return candidate2, "explore_one_safe"
    
    else:
        # Both unsafe — fall back to Non-OC
        instance = select_non_oc_instance(function_name, strategy="MRU")
        return instance, "exploit_both_unsafe"
```

### 9.2 Power of Two Choices — Why 2?

The "Power of Two Choices" is a classic result in load balancing (Mitzenmacher 2001, ref [25]).

**The math:**
- With 1 random choice: expected maximum load on any instance = O(log n / log log n)
- With 2 random choices (pick the less loaded): expected maximum load = O(log log n)

This is an exponential improvement from choosing just 1 additional candidate.
The insight is that you don't need to check ALL instances — checking just 2 random ones
and picking the better one gives near-optimal load distribution.

**Why not 3 or more?** Diminishing returns. Going from 1 to 2 choices is a massive
improvement. Going from 2 to 3 is marginal. And more choices means more label
lookups (more network calls to the label cache).

### 9.3 MRU (Most Recently Used) Tiebreaker

**Why MRU and not LRU or Random?**

MRU keeps traffic concentrated on recently-used instances. This means:
- Idle instances stay idle longer
- Idle instances reach their keep-alive timeout sooner
- Resources from terminated idle instances are freed
- Fewer instances needed overall = lower cost

```python
class MRUTracker:
    """
    Tracks most recently used instances for MRU routing.
    
    Data structure: ordered dict sorted by last-used timestamp.
    Most recently used = highest timestamp = preferred for routing.
    """
    
    def __init__(self):
        self.last_used = {}  # instance_name -> timestamp
    
    def touch(self, instance_name):
        """Mark an instance as just used."""
        self.last_used[instance_name] = time.time()
    
    def select(self, candidate1, candidate2):
        """
        Between two candidates, return the most recently used one.
        If neither has been used, pick randomly.
        """
        t1 = self.last_used.get(candidate1, 0)
        t2 = self.last_used.get(candidate2, 0)
        
        if t1 >= t2:
            return candidate1
        else:
            return candidate2
```

### 9.4 Router Implementation (Nginx + Python Sidecar)

**Architecture:**

```
                        Internet
                            |
                     +------v------+
                     |   Nginx     |
                     | (port 8080) |
                     |             |
                     | proxy_pass  |
                     | to Python   |
                     +------+------+
                            |
                     +------v------+
                     | Python      |
                     | Router      |
                     | (port 5001) |
                     |             |
                     | Makes       |
                     | routing     |
                     | decision    |
                     +------+------+
                            |
              +-------------+-------------+
              |                           |
    +---------v----------+    +-----------v--------+
    | Non-OC Instance    |    | OC Instance        |
    | (full resources)   |    | (reduced resources)|
    +--------------------+    +--------------------+
```

**Why Nginx + Python instead of modifying faas-netes?**

1. faas-netes is written in Go — modifying it requires Go expertise
2. Our routing logic is < 100 lines of Python
3. Nginx handles HTTP proxying efficiently (connection pooling, timeouts)
4. The Python sidecar only makes the routing DECISION; Nginx handles the request FORWARDING
5. At our scale (~100 RPS), the Python overhead is negligible

**router.py:**

```python
# router.py — Routing decision service

from flask import Flask, request, jsonify
import requests as http_requests
import random
import time
import threading

app = Flask(__name__)

# --- Configuration ---
ML_MODULE_URL = "http://localhost:5000"
OPENFAAS_GATEWAY = "http://localhost:31112"

# Instance registry (populated by querying K8s API)
oc_instances = {}       # function_name -> [list of pod IPs]
non_oc_instances = {}   # function_name -> [list of pod IPs]
mru_tracker = MRUTracker()

@app.route('/invoke/<function_name>', methods=['POST'])
def invoke(function_name):
    """
    Main routing endpoint.
    
    Receives a request, makes a routing decision, forwards to the
    selected instance, records the result for training.
    """
    start_time = time.time()
    
    # Get request body
    body = request.get_data()
    
    # Make routing decision
    instance, decision_type = route_request(function_name)
    
    # Forward request to selected instance
    try:
        response = http_requests.post(
            f"http://{instance['ip']}:8080",
            data=body,
            timeout=30
        )
        latency = time.time() - start_time
        
        # Record for MRU
        mru_tracker.touch(instance['name'])
        
        # Send training data to ML Module (async)
        threading.Thread(target=send_training_data, args=(
            instance, function_name, latency
        )).start()
        
        return response.content, response.status_code
        
    except Exception as e:
        return jsonify({"error": str(e)}), 502

def send_training_data(instance, function_name, latency):
    """Asynchronously send completed request data to ML Module."""
    try:
        # Get the context vector that was captured at routing time
        context_vector = get_latest_metrics(instance['name'])
        http_requests.post(
            f"{ML_MODULE_URL}/training_sample",
            json={
                "context_vector": context_vector,
                "latency": latency,
                "function_name": function_name,
                "instance_name": instance['name'],
                "is_oc": instance['is_oc']
            },
            timeout=1.0
        )
    except Exception:
        pass  # Best-effort; don't block on training data delivery
```

### 9.5 Checkpoint: Phase 4 Complete

```
[ ] Router receives requests and makes routing decisions
[ ] Safe flag check works (routes to Non-OC when unsafe)
[ ] Power of Two Choices selects 2 random OC candidates
[ ] Label tag lookup works (reads from ML Module cache)
[ ] MRU tiebreaker selects most recently used instance
[ ] Request forwarding works to both OC and Non-OC instances
[ ] Latency recording and async training data submission works
[ ] Routing decision logging captures decision type for analysis
[ ] End-to-end latency overhead from routing < 5ms
```

**Estimated time: 5-7 days**

---

## 10. Phase 5 — Vertical Scaling

### 10.1 Mechanism

Vertical scaling adjusts the maximum concurrency of each OC instance based on its
observed SLO violation rate. This is the paper's safety net for ML prediction errors.

**The math (from Section 5):**

```
For each OC instance, maintain within a rolling window of size W:
  slow_count  = number of requests with latency > SLO
  total_count = total number of requests served

  violation_ratio = slow_count / total_count

  if violation_ratio > 0.05:          # >5% of requests are slow
    max_concurrency -= 1              # Accept fewer simultaneous requests
    reset counters

  elif violation_ratio < 0.03:        # <3% of requests are slow
    max_concurrency += 1              # Try to handle more
    reset counters

  # The 0.02 gap (0.05 - 0.03) prevents oscillation
  # This is a hysteresis band: avoids rapid scale-up/scale-down cycles
```

**Why these specific thresholds?**

The paper uses 0.05 (5%) and 0.03 (3%) without justification. Our analysis:

- The SLO is typically P95 latency — meaning 5% violations is exactly the SLO boundary
- Setting scale-down at 5% means: "act when we are at the SLO boundary"
- Setting scale-up at 3% means: "only increase load when we have clear headroom"
- The 2% gap prevents the control loop from oscillating:
  - Without gap: at exactly 4% violations, the system would scale down, then violations
    drop to 3%, so it scales up, then violations rise to 5%, so it scales down... forever
  - With gap: the system stays stable between 3% and 5% (dead zone)

### 10.2 Implementation

Since we cannot modify the of-watchdog binary at runtime, we implement vertical scaling
as a sidecar that controls request admission.

**Approach: Concurrency limiter sidecar**

```python
# vertical_scaler.py — runs inside each OC function pod as a sidecar

import threading
import time
from collections import deque

class VerticalScaler:
    """
    Controls the effective concurrency of an OC function instance.
    
    Paper: Section 5
    
    Instead of modifying of-watchdog's max_inflight at runtime,
    we implement a request gate that tracks inflight requests and
    rejects excess requests with HTTP 429.
    
    The max_concurrency starts at the initial value (4, per paper S8.1)
    and is adjusted based on the SLO violation ratio.
    """
    
    def __init__(self, initial_concurrency=4, slo_threshold_ms=200,
                 window_size=100, scale_down_threshold=0.05,
                 scale_up_threshold=0.03, min_concurrency=1, max_max_concurrency=8):
        self.max_concurrency = initial_concurrency
        self.current_inflight = 0
        self.lock = threading.Lock()
        
        self.slo_threshold = slo_threshold_ms / 1000.0  # Convert to seconds
        self.window_size = window_size
        self.scale_down_threshold = scale_down_threshold
        self.scale_up_threshold = scale_up_threshold
        self.min_concurrency = min_concurrency
        self.max_max_concurrency = max_max_concurrency
        
        # Counters (within current monitoring window)
        self.slow_count = 0
        self.total_count = 0
        
        # Speculative scaling trigger
        self.speculative_threshold = int(0.05 * window_size)
    
    def try_admit(self):
        """
        Try to admit a new request.
        Returns True if admitted, False if concurrency limit reached.
        
        Thread-safe via lock (paper says "atomic operations" — 
        Python's threading.Lock achieves the same).
        """
        with self.lock:
            if self.current_inflight >= self.max_concurrency:
                return False
            self.current_inflight += 1
            return True
    
    def complete_request(self, latency):
        """
        Record a completed request and check if scaling is needed.
        
        Called after each request completes.
        """
        with self.lock:
            self.current_inflight -= 1
            self.total_count += 1
            
            if latency > self.slo_threshold:
                self.slow_count += 1
            
            # Check speculative scaling (paper: S5)
            # "speculative scaling will also be initiated once the
            #  first counter exceeds 0.05 * W"
            if self.slow_count >= self.speculative_threshold:
                self._scale_down()
                return
            
            # Check window-based scaling
            if self.total_count >= self.window_size:
                violation_ratio = self.slow_count / self.total_count
                
                if violation_ratio > self.scale_down_threshold:
                    self._scale_down()
                elif violation_ratio < self.scale_up_threshold:
                    self._scale_up()
                else:
                    # In hysteresis band — do nothing, just reset counters
                    self._reset_counters()
    
    def _scale_down(self):
        """Decrease max concurrency by 1."""
        if self.max_concurrency > self.min_concurrency:
            self.max_concurrency -= 1
        self._reset_counters()
    
    def _scale_up(self):
        """Increase max concurrency by 1."""
        if self.max_concurrency < self.max_max_concurrency:
            self.max_concurrency += 1
        self._reset_counters()
    
    def _reset_counters(self):
        """Reset monitoring counters after a scaling decision."""
        self.slow_count = 0
        self.total_count = 0
```

### 10.3 Integration with Function Pods

The vertical scaler runs as a sidecar container in each OC function pod:

```yaml
# Modified OC function pod spec (added to stack.yml annotations)
# The scaler wraps the function's HTTP endpoint

# Sidecar approach: request flow is
# Router -> Scaler (port 8080) -> Function (port 8081)

# The scaler:
# 1. Checks try_admit() — returns 429 if over limit
# 2. Forwards to function on port 8081
# 3. Records latency via complete_request()
# 4. Returns function response
```

### 10.4 Checkpoint: Phase 5 Complete

```
[ ] Vertical scaler correctly tracks inflight requests
[ ] Concurrency decreases when violation ratio > 5%
[ ] Concurrency increases when violation ratio < 3%
[ ] Speculative scaling triggers early on burst violations
[ ] Hysteresis prevents oscillation (stable in 3-5% band)
[ ] HTTP 429 returned when concurrency limit reached
[ ] Router handles 429 by retrying on Non-OC instance
[ ] Scaling operations logged for analysis
```

**Estimated time: 1-2 days**

---

## 11. Phase 6 — Load Generator and Trace Replay

### 11.1 Load Pattern Design

We simulate the Azure Function Trace's diurnal pattern with a 30-minute compressed trace.

```
Time (minutes):  0     5     10    15    20    25    30
                 |     |     |     |     |     |     |
RPS pattern:     ▂▃▅▇█▇▅▃▂▃▅▇████████▇▅▃▂▁▁▂
                 |     |     |     |     |     |     |
                ramp  peak  dip   steady high  cool  end
                up    1           state        down
```

**Phases:**
| Phase | Duration | RPS | Purpose |
|---|---|---|---|
| Bootstrap | 0-2 min | 20 RPS (OC only) | Seed positive training examples |
| Ramp up | 2-5 min | 10 → 40 RPS | Gradual load increase |
| Peak 1 | 5-8 min | 40-50 RPS | First high-load period |
| Dip | 8-12 min | 15-20 RPS | Low-load recovery |
| Steady state | 12-20 min | 30-40 RPS | Main evaluation period |
| Spike | 20-22 min | 60-80 RPS | Stress test (burst) |
| Cool down | 22-28 min | 10-15 RPS | Recovery observation |
| End | 28-30 min | 5 RPS | Drain |

### 11.2 Locust Configuration

```python
# locustfile.py

from locust import HttpUser, task, between, events
import json
import random
import time

class GolgiUser(HttpUser):
    wait_time = between(0.01, 0.05)  # Controlled by RPS shaping
    
    @task(4)  # Weight: 40% of requests
    def invoke_image_resize(self):
        width = random.choice([1280, 1920, 2560])
        height = random.choice([720, 1080, 1440])
        self.client.post(
            "/invoke/image-resize",
            json={"width": width, "height": height},
            name="image-resize"
        )
    
    @task(4)  # Weight: 40% of requests
    def invoke_db_query(self):
        key = f"user:{random.randint(1, 10000)}"
        self.client.post(
            "/invoke/db-query",
            json={"key": key},
            name="db-query"
        )
    
    @task(2)  # Weight: 20% of requests
    def invoke_log_filter(self):
        self.client.post(
            "/invoke/log-filter",
            json={"lines": 1000},
            name="log-filter"
        )
```

**Run command:**
```bash
# From the load generator EC2 instance
locust -f locustfile.py \
  --host http://${MASTER_PRIVATE_IP}:8080 \
  --headless \
  --users 50 \
  --spawn-rate 5 \
  --run-time 30m \
  --csv results/golgi_run
```

### 11.3 Running Baselines

We need to run 4 experiments (matching the paper's baselines):

| Experiment | Routing | OC Enabled | Vertical Scaling | Duration |
|---|---|---|---|---|
| **BASE** | MRU only | No (Non-OC only) | No | 30 min |
| **OC** | MRU only | Yes (OC only) | No | 30 min |
| **E&E** | Golgi router | Yes (OC + Non-OC) | No | 30 min |
| **Golgi** | Golgi router | Yes (OC + Non-OC) | Yes | 30 min |

Each experiment is run 3 times (paper uses 5; we use 3 for time constraints).

---

## 12. Phase 7 — End-to-End Integration

### 12.1 Startup Sequence

```
Step 1: Start infrastructure (k3s, OpenFaaS)
        Wait: kubectl get nodes shows all Ready

Step 2: Deploy Redis
        Wait: redis pod is Running

Step 3: Deploy all 6 functions (3 Non-OC + 3 OC)
        Wait: all pods are Running, functions respond to test requests

Step 4: Start Metric Collector DaemonSet
        Wait: collectors running on all 3 worker nodes, metrics flowing

Step 5: Start ML Module on master
        Wait: Flask API responding on port 5000

Step 6: Configure ML Module with SLO thresholds
        POST /config with measured baseline P95 latencies

Step 7: Run Bootstrap phase (2 minutes, high load to OC)
        Wait: ML Module reports sufficient positive samples

Step 8: Start Router on master
        Wait: Router responding on port 8080

Step 9: Verify end-to-end flow
        Send 10 test requests, verify routing decisions logged

Step 10: Start Locust load generator
         Monitor: dashboard or CSV output
```

### 12.2 Health Checks

```bash
# Check all components are running
kubectl get pods -n openfaas-fn         # Functions and Redis
kubectl get pods -n openfaas            # OpenFaaS gateway
kubectl get ds -n openfaas-fn           # Metric collector DaemonSet

# Check ML Module
curl http://localhost:5000/labels       # Should return label cache
curl http://localhost:5000/safe/image-resize  # Should return {"safe": true}

# Check Router
curl -X POST http://localhost:8080/invoke/image-resize \
  -d '{"width":1920,"height":1080}'     # Should return function result
```

### 12.3 Monitoring During Experiments

```python
# monitoring.py — Collect experiment metrics in real-time

class ExperimentMonitor:
    """
    Records all data needed for results analysis:
    - Per-request: function, instance, OC/Non-OC, latency, timestamp, routing decision
    - Per-interval: resource usage, label distributions, Safe flag state
    - Per-scaling-event: instance, old_concurrency, new_concurrency, violation_ratio
    """
    
    def __init__(self, output_dir):
        self.request_log = []      # Every request
        self.resource_log = []     # Sampled every 5 seconds
        self.scaling_log = []      # Every scaling event
        self.output_dir = output_dir
    
    def log_request(self, function_name, instance_name, is_oc, latency,
                    routing_decision, timestamp):
        self.request_log.append({
            "function": function_name,
            "instance": instance_name,
            "is_oc": is_oc,
            "latency_ms": latency * 1000,
            "decision": routing_decision,
            "timestamp": timestamp
        })
    
    def save(self):
        """Save all logs to CSV files for analysis."""
        pd.DataFrame(self.request_log).to_csv(
            f"{self.output_dir}/requests.csv", index=False)
        pd.DataFrame(self.resource_log).to_csv(
            f"{self.output_dir}/resources.csv", index=False)
        pd.DataFrame(self.scaling_log).to_csv(
            f"{self.output_dir}/scaling.csv", index=False)
```

---

## 13. Phase 8 — Evaluation and Metrics Collection

### 13.1 Metrics to Compute

**Performance metrics (per function):**

| Metric | Formula | Target |
|---|---|---|
| P95 latency | 95th percentile of all request latencies | <= SLO threshold |
| P99 latency | 99th percentile | No target (informational) |
| Mean latency | Sum of latencies / count | No target |
| SLO violation rate | Count(latency > SLO) / Total count | < 10% |

**Cost metrics (aggregate):**

| Metric | Formula | Paper's Unit |
|---|---|---|
| Memory footprint | Sum over all instances: (memory_allocated_MB * active_seconds) | MB * Sec |
| VM time | Sum over all nodes: active_seconds_of_node | Seconds |
| OC instance ratio | OC_requests / Total_requests | Percentage |
| Non-OC instance ratio | Non_OC_requests / Total_requests | Percentage |

**ML metrics:**

| Metric | Formula |
|---|---|
| F1 score | 2 * (precision * recall) / (precision + recall) |
| Precision | True_positives / (True_positives + False_positives) |
| Recall | True_positives / (True_positives + False_negatives) |
| Label distribution | Count of Label=0 vs Label=1 per prediction cycle |

### 13.2 Computing Memory Footprint

```python
def compute_memory_footprint(request_log, resource_log):
    """
    Compute total memory footprint in MB*Sec.
    
    Paper definition (Section 8.2):
    "The memory footprint of a 128MB function running for 0.1 seconds is 12.8MB*Sec"
    
    For each function instance:
      footprint = allocated_memory_MB * active_time_seconds
    
    Where active_time = time from first request to last request + keep_alive_buffer
    """
    instance_lifetimes = {}  # instance -> (first_seen, last_seen, memory_mb)
    
    for entry in request_log:
        inst = entry["instance"]
        ts = entry["timestamp"]
        # Determine allocated memory based on OC/Non-OC
        if entry["is_oc"]:
            mem = OC_MEMORY_CONFIG[entry["function"]]
        else:
            mem = NON_OC_MEMORY_CONFIG[entry["function"]]
        
        if inst not in instance_lifetimes:
            instance_lifetimes[inst] = {"first": ts, "last": ts, "memory": mem}
        else:
            instance_lifetimes[inst]["last"] = max(instance_lifetimes[inst]["last"], ts)
    
    total_footprint = 0
    for inst, data in instance_lifetimes.items():
        active_time = data["last"] - data["first"] + 60  # 60s keep-alive buffer
        total_footprint += data["memory"] * active_time
    
    return total_footprint
```

### 13.3 Computing VM Time

```python
def compute_vm_time(resource_log, nodes):
    """
    Compute total VM time in seconds.
    
    VM time = sum of time each node was actively serving function instances.
    A node is "active" if it has at least one function instance running.
    """
    node_active_periods = {node: [] for node in nodes}
    
    # From resource_log, determine when each node had active instances
    for entry in resource_log:
        node = entry["node"]
        if entry["active_instances"] > 0:
            node_active_periods[node].append(entry["timestamp"])
    
    total_vm_time = 0
    for node, timestamps in node_active_periods.items():
        if timestamps:
            active_duration = max(timestamps) - min(timestamps)
            total_vm_time += active_duration
    
    return total_vm_time
```

### 13.4 Running the Full Evaluation

```bash
# Run all 4 experiments, 3 repetitions each

for experiment in BASE OC E_E GOLGI; do
  for rep in 1 2 3; do
    echo "=== Running $experiment, repetition $rep ==="
    
    # Configure routing mode
    configure_experiment $experiment
    
    # Wait for system to stabilize
    sleep 30
    
    # Run bootstrap (only for E_E and GOLGI)
    if [ "$experiment" == "E_E" ] || [ "$experiment" == "GOLGI" ]; then
      run_bootstrap
    fi
    
    # Run load test
    locust -f locustfile.py \
      --host http://${MASTER_PRIVATE_IP}:8080 \
      --headless \
      --users 50 \
      --spawn-rate 5 \
      --run-time 30m \
      --csv results/${experiment}_rep${rep}
    
    # Save experiment data
    save_experiment_data results/${experiment}_rep${rep}
    
    # Cool down
    sleep 60
  done
done
```

---

## 14. Phase 9 — Results Analysis and Visualization

### 14.1 Plots to Generate

**Plot 1: P95 Latency Comparison (matches paper's Figure 5)**
```
Bar chart: 4 groups (one per experiment) x 3 functions
X-axis: Functions (image-resize, db-query, log-filter)
Y-axis: P95 latency (ms)
Bars: BASE, OC, E&E, Golgi
Annotations: % increase over BASE
```

**Plot 2: Cost Comparison (matches paper's Figure 7 left)**
```
Grouped bar chart:
X-axis: Experiments (OC, E&E, Golgi)
Y-axis: Relative cost (normalized to BASE = 1.0)
Two bars per group: Memory Footprint, VM Time
```

**Plot 3: Memory Footprint Breakdown (matches paper's Figure 7 right)**
```
Stacked bar chart:
X-axis: Experiments (BASE, OC, E&E, Golgi)
Y-axis: Memory footprint (MB*Sec)
Stacks: Non-OC usage, OC usage
```

**Plot 4: Vertical Scaling Illustration (matches paper's Figure 8)**
```
Time series for one OC instance:
X-axis: Time (seconds)
Y-axis (left): P95 latency (blue line) + SLO threshold (red dashed)
Y-axis (right): Max concurrency (green line)
```

**Plot 5: ML Model Performance (matches paper's Figure 9 left)**
```
Line chart:
X-axis: Number of model updates
Y-axis: F1 score
Lines: Balanced (our stratified sampling), Imbalanced (no balancing)
```

**Plot 6: Routing Decision Distribution**
```
Stacked area chart over time:
X-axis: Time (minutes)
Y-axis: Percentage of requests
Areas: OC-safe, OC-unsafe (rerouted), Non-OC (safe flag off)
```

### 14.2 Analysis Code

```python
# analysis.py — Generate all plots and tables

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

def plot_p95_comparison(results_dir):
    """
    Generate Figure 5 equivalent: P95 latency comparison across baselines.
    """
    experiments = ['BASE', 'OC', 'E_E', 'GOLGI']
    functions = ['image-resize', 'db-query', 'log-filter']
    colors = ['#2ecc71', '#e74c3c', '#3498db', '#9b59b6']
    
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    
    for idx, func in enumerate(functions):
        p95_values = []
        for exp in experiments:
            # Load all repetitions
            latencies = []
            for rep in range(1, 4):
                df = pd.read_csv(f"{results_dir}/{exp}_rep{rep}/requests.csv")
                func_data = df[df['function'] == func]
                latencies.extend(func_data['latency_ms'].tolist())
            
            p95 = np.percentile(latencies, 95)
            p95_values.append(p95)
        
        bars = axes[idx].bar(experiments, p95_values, color=colors)
        axes[idx].set_title(func)
        axes[idx].set_ylabel('P95 Latency (ms)')
        
        # Annotate with % increase over BASE
        base_p95 = p95_values[0]
        for i, (bar, val) in enumerate(zip(bars, p95_values)):
            if i > 0:
                pct = ((val - base_p95) / base_p95) * 100
                axes[idx].annotate(f'{pct:+.0f}%',
                    xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                    ha='center', va='bottom', fontsize=9)
    
    plt.tight_layout()
    plt.savefig(f"{results_dir}/figure5_p95_comparison.png", dpi=150)
    plt.close()

def plot_cost_comparison(results_dir):
    """
    Generate Figure 7 equivalent: Relative cost comparison.
    """
    # ... similar structure, computing memory footprint and VM time
    # for each experiment, normalized to BASE
    pass

def generate_comparison_table(results_dir):
    """
    Generate the comparison table for the report:
    
    | Metric | Paper (Golgi) | Our Replication | Difference |
    """
    paper_results = {
        'memory_reduction': 42,
        'vm_reduction': 35,
        'p95_violation': '< 5%',
        'f1_score': '0.70-0.84'
    }
    
    our_results = compute_our_results(results_dir)
    
    table = pd.DataFrame({
        'Metric': ['Memory reduction (%)', 'VM time reduction (%)',
                   'P95 SLO violation rate', 'ML F1 score'],
        'Paper': [42, 35, '< 5%', '0.70-0.84'],
        'Ours': [our_results['memory_reduction'],
                 our_results['vm_reduction'],
                 f"{our_results['violation_rate']:.1f}%",
                 f"{our_results['f1_score']:.2f}"],
    })
    
    return table
```

---

## 15. Phase 10 — Report Writing and Demo

### 15.1 Report Structure Mapping

| Course Requirement | Source |
|---|---|
| 1. Problem Statement | Section 2 of this plan + golgi.md Pass 1 |
| 2. Literature Reference | golgi.md references + 3-5 papers from Section 9 of paper |
| 3. Existing Results | Paper's Figure 5 and Figure 7 (original numbers) |
| 4. Your Implementation | Phases 0-7 of this plan, with architecture diagram |
| 5. Your Results | Phase 8-9 outputs (plots, tables) |
| 6. Comparison and Analysis | Phase 9 comparison table + discussion |
| 7. Conclusion | Summary of achieved vs target results |
| 8. Architecture Diagram | Section 3.1 of this plan (refined) |
| 9. Future Scope | golgi.md Section 3.4 research ideas |

### 15.2 Literature References for the Report

| # | Paper | Relevance |
|---|---|---|
| 1 | Golgi (Li et al., SoCC 2023) | The paper we replicate |
| 2 | Owl (Tian et al., SoCC 2022) | Predecessor — collocation profiles approach |
| 3 | Orion (Mahgoub et al., OSDI 2022) | Right-sizing approach — primary baseline |
| 4 | Mondrian Forest (Lakshminarayanan et al., NeurIPS 2014) | ML model theory |
| 5 | Azure Function Trace (Shahrad et al., ATC 2020) | Workload characterization |

### 15.3 Demo Recording Outline

```
Duration: 10-12 minutes

00:00 - 01:00  Introduction: Problem statement and Golgi overview
01:00 - 03:00  Architecture walkthrough (diagram + component explanation)
03:00 - 04:00  Show running cluster (kubectl get nodes, pods)
04:00 - 06:00  Live demo: Start load test, show routing decisions in real-time
06:00 - 07:00  Show ML Module: labels updating, Safe flag changing
07:00 - 08:00  Show vertical scaling: concurrency adjusting in OC instances
08:00 - 10:00  Results: Show plots comparing BASE, OC, E&E, Golgi
10:00 - 11:00  Comparison with paper's results
11:00 - 12:00  Conclusion and future scope
```

---

## 16. Appendix A — Cost Estimation

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
- Run experiments in bursts (all 4 experiments in one long session)
- Estimated total project cost: **$25-40 over 4-5 weeks**

---

## 17. Appendix B — Troubleshooting Guide

### Common Issues and Fixes

| Problem | Cause | Fix |
|---|---|---|
| k3s agent can't join cluster | Security group blocks port 6443 | Ensure VPC-internal traffic is allowed |
| OpenFaaS functions stuck in Pending | Insufficient node resources | Check `kubectl describe pod` for scheduling failures |
| Metric collector can't read cgroup | Incorrect cgroup version paths | Verify cgroup v1 vs v2 and adjust paths |
| ML Module F1 score stays at 0 | No positive samples | Run bootstrap phase to generate SLO violations |
| Router returns 502 | Function instance crashed or unreachable | Check pod logs with `kubectl logs` |
| High routing latency (>20ms) | Python GIL contention | Use gunicorn with multiple workers |
| Vertical scaler oscillates | Thresholds too close | Increase hysteresis gap (e.g., 0.07 down, 0.02 up) |
| Locust can't connect to router | Security group blocks port 8080 | Add inbound rule for load generator IP |
| cgroup path not found | Container uses different QoS class | Check all QoS dirs: guaranteed, burstable, besteffort |
| /proc/net/dev shows only loopback | DaemonSet missing hostNetwork:true | Add `hostNetwork: true` to pod spec |

### Debugging Commands

```bash
# Check function logs
kubectl logs -n openfaas-fn deployment/image-resize --tail=50

# Check ML Module logs
kubectl logs deployment/golgi-ml-module --tail=50

# Check metric collector logs
kubectl logs -n openfaas-fn daemonset/golgi-metric-collector --tail=50

# Verify cgroup paths exist
ls /sys/fs/cgroup/kubepods.slice/

# Test metric collection manually
cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/*/cpu.stat

# Test network metrics manually
cat /proc/1/net/dev

# Check OpenFaaS function status
faas-cli describe image-resize

# Monitor resource usage
kubectl top pods -n openfaas-fn
kubectl top nodes
```

---

## 18. Appendix C — File and Directory Structure

```
golgi_vcc/
|
+-- GOLGI_REPLICATION_PLAN.md          # This file
+-- golgi.md                           # Paper analysis (600 lines)
+-- outputs/
|   +-- golgi-socc23-audit.md          # Paper-code audit report
|   +-- .plans/
|       +-- golgi-socc23-audit.md      # Audit plan
|
+-- infrastructure/                    # Phase 0
|   +-- setup-vpc.sh                   # VPC, subnet, security group creation
|   +-- launch-instances.sh            # EC2 instance provisioning
|   +-- install-k3s-master.sh          # k3s server setup
|   +-- install-k3s-worker.sh          # k3s agent setup
|   +-- install-openfaas.sh            # OpenFaaS deployment
|   +-- teardown.sh                    # Clean up all AWS resources
|
+-- functions/                         # Phase 1
|   +-- image-resize/
|   |   +-- handler.py
|   |   +-- requirements.txt
|   |   +-- Dockerfile
|   +-- db-query/
|   |   +-- handler.py
|   |   +-- requirements.txt
|   |   +-- Dockerfile
|   +-- log-filter/
|   |   +-- handler.go
|   |   +-- go.mod
|   |   +-- Dockerfile
|   +-- stack.yml                      # OpenFaaS deployment config
|   +-- redis-deployment.yaml          # Redis service for db-query
|
+-- metric-collector/                  # Phase 2
|   +-- collector.py                   # Main collection daemon
|   +-- cgroup_reader.py               # cgroup v1/v2 CPU and memory reading
|   +-- network_reader.py              # /proc/net/dev parsing
|   +-- container_discovery.py         # K8s pod -> container -> cgroup mapping
|   +-- daemonset.yaml                 # K8s DaemonSet manifest
|   +-- Dockerfile
|   +-- requirements.txt
|
+-- ml-module/                         # Phase 3
|   +-- ml_module.py                   # Flask API (main service)
|   +-- reservoir_sampling.py          # Algorithm 1 implementation
|   +-- model_manager.py               # RF training and prediction
|   +-- safe_flag.py                   # Safe flag management
|   +-- bootstrap.py                   # Initial overload seeding
|   +-- deployment.yaml                # K8s deployment manifest
|   +-- Dockerfile
|   +-- requirements.txt
|
+-- router/                            # Phase 4
|   +-- router.py                      # Routing decision service
|   +-- mru_tracker.py                 # MRU instance tracking
|   +-- nginx.conf                     # Nginx reverse proxy config
|   +-- deployment.yaml                # K8s deployment manifest
|   +-- Dockerfile
|   +-- requirements.txt
|
+-- vertical-scaler/                   # Phase 5
|   +-- scaler.py                      # Concurrency adjustment logic
|   +-- sidecar.py                     # HTTP proxy with admission control
|   +-- Dockerfile
|
+-- load-generator/                    # Phase 6
|   +-- locustfile.py                  # Locust load test definition
|   +-- trace_shaper.py                # Diurnal pattern generator
|   +-- run_experiments.sh             # Script to run all 4 baselines x 3 reps
|
+-- monitoring/                        # Phase 7-8
|   +-- experiment_monitor.py          # Real-time data collection
|   +-- save_results.py               # Export to CSV
|
+-- analysis/                          # Phase 9
|   +-- analysis.py                    # Generate all plots and tables
|   +-- plot_p95_comparison.py         # Figure 5 equivalent
|   +-- plot_cost_comparison.py        # Figure 7 equivalent
|   +-- plot_vertical_scaling.py       # Figure 8 equivalent
|   +-- plot_ml_performance.py         # Figure 9 equivalent
|   +-- generate_report_tables.py      # Tables for the report
|
+-- results/                           # Phase 8-9 outputs
|   +-- BASE_rep1/
|   |   +-- requests.csv
|   |   +-- resources.csv
|   |   +-- scaling.csv
|   +-- BASE_rep2/
|   +-- BASE_rep3/
|   +-- OC_rep1/
|   +-- ... (12 directories total: 4 experiments x 3 reps)
|   +-- figures/
|       +-- figure5_p95_comparison.png
|       +-- figure7_cost_comparison.png
|       +-- figure7_breakdown.png
|       +-- figure8_vertical_scaling.png
|       +-- figure9_ml_performance.png
|       +-- figure_routing_distribution.png
|
+-- report/                            # Phase 10
|   +-- report.pdf
|   +-- presentation.pdf
|   +-- demo_link.txt
|
+-- .claude/
    +-- skills/                        # Research skills framework
```

---

## 19. Appendix D — Mathematical Foundations

### D.1 The Overcommitment Formula

```
OC_memory = alpha * M_claimed + (1 - alpha) * M_actual

Where:
  alpha       = 0.3 (slack factor, inherited from Owl [37])
  M_claimed   = memory the user specified (e.g., 512 MB)
  M_actual    = measured peak memory usage (e.g., 65 MB)

Interpretation:
  - alpha = 0: OC allocation = actual usage (maximum savings, maximum risk)
  - alpha = 1: OC allocation = claimed (no savings, no risk, same as Non-OC)
  - alpha = 0.3: OC allocation = 30% safety margin above actual usage

Example:
  M_claimed = 512 MB, M_actual = 65 MB
  OC_memory = 0.3 * 512 + 0.7 * 65 = 153.6 + 45.5 = 199.1 MB
  Savings = (512 - 199.1) / 512 = 61.1% memory per instance
```

### D.2 Reservoir Sampling Probability

```
For a stream of n items, maintaining a reservoir of size k:

The probability that the i-th item is in the final reservoir:
  P(i in reservoir) = k / n    for all i

Proof sketch:
  - First k items: always included (probability 1)
  - k+1-th item: included with probability k/(k+1), replaces one of the k items
  - i-th item (i > k): included with probability k/i
  - If included, each existing item is replaced with probability 1/k
  - Net survival probability of existing item: (1 - 1/i)
  
By induction: after all n items, P(item i in reservoir) = k/n for all i.

In Golgi's stratified version:
  Two independent reservoirs of size N/2 each
  P(positive sample i in reservoir) = (N/2) / n_pos
  P(negative sample j in reservoir) = (N/2) / n_neg
  Combined batch: exactly N/2 of each class = perfectly balanced
```

### D.3 F1 Score Computation

```
F1 = 2 * (Precision * Recall) / (Precision + Recall)

Where:
  Precision = TP / (TP + FP)
    "Of all instances I predicted as unsafe (Label=1), how many were actually unsafe?"
    High precision = few false alarms
  
  Recall = TP / (TP + FN)
    "Of all instances that were actually unsafe, how many did I catch?"
    High recall = few missed violations

  TP = True Positive  = predicted 1 (unsafe), actually 1 (SLO violated)
  FP = False Positive = predicted 1 (unsafe), actually 0 (SLO met)
  FN = False Negative = predicted 0 (safe), actually 1 (SLO violated) ← DANGEROUS
  TN = True Negative  = predicted 0 (safe), actually 0 (SLO met)

In Golgi's context:
  FP (false alarm) → routes to Non-OC unnecessarily → costs more but safe
  FN (missed detection) → routes to overloaded OC → SLO violation! ← THE BAD ONE

  Golgi MUST have high recall (catch most violations) even at cost of lower precision.
  The conservative routing (default to Non-OC) handles FP gracefully.
```

### D.4 P95 Latency Computation

```
Given N sorted latencies: L[1] <= L[2] <= ... <= L[N]

P95 = L[ceil(0.95 * N)]

Example with N = 100:
  P95 = L[95]  (the 95th smallest latency)

Why P95 and not mean?
  Mean is sensitive to outliers but hides tail behavior.
  P95 captures the experience of the worst 5% of requests.
  Cloud SLOs are typically defined at P95 or P99.
  
  Example:
    Latencies: [10, 12, 11, 13, 10, 11, 12, 10, 11, 5000] ms
    Mean = 510 ms  (looks terrible!)
    P95  = 13 ms   (most users are fine, one outlier)
    P99  = 5000 ms (the outlier shows up here)
```

### D.5 Power of Two Choices: Expected Load Analysis

```
Given n servers, m = n*c requests (load factor c):

Random placement (1 choice):
  Max load on any server = O(log n / log log n)  (w.h.p.)
  With n=100, max ≈ 4-5x average

Two random choices (pick less loaded):
  Max load on any server = O(log log n)  (w.h.p.)
  With n=100, max ≈ 1.5-2x average

Improvement: exponential reduction in maximum load

Why it works intuitively:
  With 1 choice, you might unluckily hit the most loaded server.
  With 2 choices, both being highly loaded is much less probable.
  P(both servers above threshold T) = P(one above T)^2
  Squaring a small probability makes it tiny.
```

---

## 20. Appendix E — References and Resources

### Paper References

1. **Golgi paper:** Li et al., "Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing," ACM SoCC 2023.
   - PDF: https://www.cse.ust.hk/~weiwa/papers/golgi-socc23.pdf
   - DOI: https://doi.org/10.1145/3620678.3624645

2. **Owl (predecessor):** Tian et al., "Owl: Performance-Aware Scheduling for Resource-Efficient Function-as-a-Service Cloud," ACM SoCC 2022.
   - PDF: https://cse.hkust.edu.hk/~weiwa/papers/owl-socc2022.pdf

3. **Orion (baseline):** Mahgoub et al., "ORION and the Three Rights," OSDI 2022.

4. **Mondrian Forest:** Lakshminarayanan et al., "Mondrian Forests: Efficient Online Random Forests," NeurIPS 2014.
   - Code: https://github.com/balajiln/mondrianforest

5. **Azure Function Trace:** Shahrad et al., "Serverless in the Wild," USENIX ATC 2020.
   - Data: https://github.com/Azure/AzurePublicDataset

6. **Power of Two Choices:** Mitzenmacher, "The power of two choices in randomized load balancing," IEEE TPDS 2001.

### Software Resources

| Tool | URL | Version |
|---|---|---|
| k3s | https://k3s.io | v1.28+ |
| OpenFaaS | https://www.openfaas.com | Latest |
| faas-netes | https://github.com/openfaas/faas-netes | Latest |
| of-watchdog | https://github.com/openfaas/of-watchdog | Latest |
| scikit-learn | https://scikit-learn.org | 1.3+ |
| scikit-garden (MF) | https://github.com/scikit-garden/scikit-garden | 0.1 |
| Locust | https://locust.io | 2.20+ |
| Helm | https://helm.sh | 3.x |
| AWS CLI | https://aws.amazon.com/cli/ | 2.x |

### Useful Documentation

- k3s quickstart: https://docs.k3s.io/quick-start
- OpenFaaS on Kubernetes: https://docs.openfaas.com/deployment/kubernetes/
- cgroup v2 documentation: https://docs.kernel.org/admin-guide/cgroup-v2.html
- /proc filesystem: https://www.kernel.org/doc/html/latest/filesystems/proc.html
- Linux perf stat: https://man7.org/linux/man-pages/man1/perf-stat.1.html
- Reservoir sampling (Vitter 1985): Algorithm R in the original paper
- sklearn RandomForestClassifier: https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.RandomForestClassifier.html

---

## Timeline Summary

| Week | Phase | Deliverable |
|---|---|---|
| Week 1 | Phase 0 + Phase 1 | Running cluster with deployed functions |
| Week 2 | Phase 2 + Phase 3 | Metric collector + ML Module |
| Week 3 | Phase 4 + Phase 5 | Router + Vertical Scaler |
| Week 4 | Phase 6 + Phase 7 | Load generator + Integration |
| Week 5 | Phase 8 + Phase 9 + Phase 10 | Evaluation + Report + Demo |

---

*End of Golgi Replication Plan*
*Total implementation effort: ~25-35 days*
*Target: Demonstrate 25-35% cost reduction while maintaining P95 SLO*
