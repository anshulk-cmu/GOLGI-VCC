# Golgi Replication on AWS

A replication of **Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing** (ACM SoCC 2023, Best Paper Award) on AWS infrastructure using k3s and OpenFaaS.

**Course:** CSL7510 — Cloud Computing  
**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)  
**Programme:** M.Tech Artificial Intelligence, IIT Jodhpur  
**Paper DOI:** [10.1145/3620678.3624645](https://doi.org/10.1145/3620678.3624645)

---

## What is Golgi?

Serverless functions waste resources. Studies show functions use only ~25% of their reserved CPU and memory on average — the remaining 75% sits idle. Cloud providers lose money, and users overpay.

The naive fix — giving functions fewer resources (overcommitment) — causes latency spikes when multiple squeezed containers compete for shared hardware. The paper reports up to 183% P95 latency increase with blind overcommitment.

Golgi solves this with a two-instance model:

- **Non-OC instances** get full resources as configured by the user. Safe but expensive.
- **OC (Overcommitted) instances** get reduced resources based on actual usage. Cheap but risky.

An ML classifier (trained on 7 real-time container metrics) predicts whether an OC instance can handle a request without violating the latency SLO. A router directs each request to OC or Non-OC based on the prediction. A vertical scaling safety net adjusts per-container concurrency when predictions are wrong.

The result: ~42% memory cost reduction while maintaining P95 latency SLOs.

## What We Are Building

A simplified but faithful replication on AWS demonstrating:

1. The two-instance model (OC and Non-OC containers on Kubernetes)
2. Runtime metric collection from containers (CPU, memory, network, inflight requests)
3. An ML classifier (Random Forest) predicting SLO violations
4. A smart router using the classifier's predictions with Power of Two Choices
5. A vertical scaling mechanism adjusting concurrency limits
6. End-to-end evaluation showing cost reduction with SLO maintenance

### Simplifications

We make deliberate simplifications to fit a course project scope while preserving the paper's core contributions:

| Aspect | Paper | Our Replication |
|---|---|---|
| ML model | Mondrian Forest (online) | scikit-learn Random Forest (periodic retrain) |
| Metrics | 9 (including LLC cache misses) | 7 (skip hardware counters) |
| Functions | 8 in 5 languages | 3 (CPU-bound, I/O-bound, mixed) |
| Cluster | 7 workers (c5.9xlarge) | 3 workers (t3.xlarge) |
| Routing | Modified faas-netes (Go) | Nginx + Python sidecar |
| Load gen | Azure Function Trace replay | Locust with synthetic trace |

### Target Results

| Metric | Paper | Our Target |
|---|---|---|
| Memory cost reduction | 42% | 25-35% |
| P95 SLO violation rate | < 5% | < 10% |
| Functions tested | 8 | 3 |

## Architecture

```
                  +-------------------+
                  |   Load Generator  |
                  |   (Locust on EC2) |
                  +--------+----------+
                           |
                           v
                  +-------------------+
                  |   Golgi Router    |
                  | (Nginx + Python)  |
                  +--------+----------+
                           |
              +------------+------------+
              v                         v
   +------------------+     +------------------+
   | Non-OC Instances |     |  OC Instances    |
   | (Full resources) |     | (Reduced alloc)  |
   +------------------+     +------------------+
              |                         |
              +------------+------------+
                           v
                  +-------------------+
                  |  Metric Collector |
                  |  (DaemonSet)      |
                  +--------+----------+
                           v
                  +-------------------+
                  |    ML Module      |
                  | (Flask + sklearn) |
                  +-------------------+
```

## Infrastructure

All resources run on AWS in `us-east-1a` inside a dedicated VPC (`10.0.0.0/16`):

| Node | Instance Type | vCPU | RAM | Private IP | Role |
|---|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | 10.0.1.131 | k3s server, OpenFaaS gateway, Golgi router, ML module |
| golgi-worker-1 | t3.xlarge | 4 | 16 GB | 10.0.1.110 | Function containers, metric collector DaemonSet |
| golgi-worker-2 | t3.xlarge | 4 | 16 GB | 10.0.1.10 | Function containers, metric collector DaemonSet |
| golgi-worker-3 | t3.xlarge | 4 | 16 GB | 10.0.1.94 | Function containers, metric collector DaemonSet |
| golgi-loadgen | t3.medium | 2 | 4 GB | 10.0.1.142 | Locust load generator, trace replay |

**Running cost:** ~$0.58/hr ($14/day) when all instances are running. Instances should be stopped when not in active use.

**Stack:** AWS EC2, k3s v1.34.6 (Kubernetes), OpenFaaS (Helm), Python 3.9, scikit-learn, Locust, Nginx

## How It Works

The system operates as a closed feedback loop across four stages:

**1. Metric Collection (Phase 2):** A DaemonSet running on each worker node reads cgroup v2 files every 500ms to collect 7 per-container metrics: CPU utilization, memory usage, network I/O (bytes sent/received), disk I/O, inflight request count, and function invocation rate. These raw metrics are pushed to the ML module on the master node.

**2. ML Prediction (Phase 3):** The ML module maintains a Random Forest classifier trained on historical metric snapshots labeled with whether the corresponding request met or violated the latency SLO. Given a real-time metric vector, it outputs a probability that the OC instance will violate the SLO. The classifier is retrained periodically (every 5 minutes) as new labeled data arrives, approximating the paper's online Mondrian Forest.

**3. Routing (Phase 4):** When a function invocation arrives, the router queries the ML module for the current SLO violation probability of each available OC instance. If the probability is below a configurable threshold (default: 0.3), the request goes to the cheaper OC instance. Otherwise, it falls back to the Non-OC instance. The router uses a Power of Two Choices strategy — it samples two candidate instances and picks the one with lower predicted violation probability, balancing load without requiring global state.

**4. Vertical Scaling (Phase 5):** Even with good predictions, some requests will land on overloaded OC instances. The vertical scaling safety net monitors the recent SLO violation rate per function and adjusts the `max_inflight` concurrency limit on each container. If violations spike above 5%, concurrency is reduced (fewer concurrent requests per container = less resource contention). If violations stay low, concurrency is gradually increased to improve throughput. This acts as a corrective mechanism when the ML model's predictions drift.

## Repository Structure

```
.
├── README.md                        # This file
├── GOLGI_REPLICATION_PLAN.md        # Detailed implementation plan (all 10 phases)
├── execution_log_phase0.md          # Phase 0 execution log (infrastructure setup)
├── execution_log_phase1.md          # Phase 1 execution log (benchmark functions)
├── docs/
│   ├── paper/
│   │   ├── golgi_paper.pdf          # Original paper (Li et al., SoCC 2023)
│   │   ├── golgi_paper.md           # Paper notes in markdown
│   │   └── golgi_paper_text.txt     # Extracted paper text
│   ├── analysis/
│   │   └── golgi-socc23-audit.md    # Paper-code audit and analysis
│   └── final_report.md              # Final course report (in progress)
├── infrastructure/                  # AWS infrastructure scripts
│   ├── setup-vpc.sh                 #   VPC, subnet, IGW, route table, security group
│   ├── launch-instances.sh          #   EC2 instance provisioning (5 nodes)
│   ├── install-k3s-master.sh        #   k3s server setup on master
│   ├── install-k3s-worker.sh        #   k3s agent join for workers
│   ├── install-openfaas.sh          #   Helm + OpenFaaS + faas-cli + node labels
│   └── teardown.sh                  #   Full cleanup (instances, VPC, networking)
├── functions/                       # Benchmark serverless functions
│   ├── stack.yml                    #   OpenFaaS deployment config (6 function variants)
│   ├── redis-deployment.yaml        #   Redis K8s manifest for db-query
│   ├── image-resize/                #   CPU-bound: PIL Lanczos resampling
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── db-query/                    #   I/O-bound: Redis GET/SET operations
│   │   ├── handler.py
│   │   └── requirements.txt
│   └── log-filter/                  #   Mixed: regex parsing + IP anonymization (Go)
│       ├── handler.go
│       └── go.mod
├── collector/                       # Metric collection DaemonSet (Phase 2)
├── ml/                              # ML classifier module (Phase 3)
├── router/                          # Golgi routing logic (Phase 4)
└── loadgen/                         # Locust load generation scripts (Phase 6)
```

## Progress

- [x] Phase 0: AWS account, IAM user, CLI, SSH key pair
- [x] Phase 0: VPC, subnet, internet gateway, route table, security group
- [x] Phase 0: 5 EC2 instances provisioned and verified
- [x] Phase 0: k3s cluster (1 server + 3 agents) operational
- [x] Phase 0: OpenFaaS deployed via Helm (gateway, prometheus, NATS, queue-worker)
- [x] Phase 0: Python + dependencies installed on all nodes, cgroup v2 verified
- [x] Phase 1.1: Redis deployed to openfaas-fn namespace (PING verified)
- [x] Phase 1.2: Function code written (image-resize, db-query, log-filter)
- [ ] Phase 1.3: Build and deploy 6 function variants to OpenFaaS
- [ ] Phase 1.4: Baseline P95 latency measurement (SLO thresholds)
- [ ] Phase 2: Metric collector (cgroup v2 DaemonSet)
- [ ] Phase 3: ML module (Random Forest classifier)
- [ ] Phase 4: Router (Nginx + Python prediction sidecar)
- [ ] Phase 5: Vertical scaling (concurrency limit adjustment)
- [ ] Phase 6: Load generator (Locust trace replay)
- [ ] Phase 7: End-to-end integration
- [ ] Phase 8: Evaluation and metrics collection
- [ ] Phase 9: Results analysis and visualization
- [ ] Phase 10: Report writing and demo

## Benchmark Functions

Phase 1 implements three serverless functions, each chosen to represent a distinct resource profile found in production serverless workloads. The paper categorizes functions by which resource bottleneck dominates their latency, and our three benchmarks cover the major categories:

**image-resize (CPU-bound):** Generates a random RGB image at the requested resolution (default 1920×1080), then downscales it to half size using Pillow's Lanczos resampling algorithm. Lanczos is computationally expensive — it applies a windowed sinc interpolation kernel across every output pixel, making execution time directly proportional to available CPU cycles. When this function runs on an OC instance with reduced CPU (405m instead of 1000m), latency increases predictably with CPU contention, giving the ML classifier a clear signal to learn from.

**db-query (I/O-bound):** Connects to a Redis instance running in the same Kubernetes namespace and performs a read-write-read sequence (GET → SET → GET). The function's latency is dominated by network round-trips to Redis, not by CPU processing. On an OC instance with reduced resources (185m CPU, 105 Mi memory), the function behaves almost identically to the Non-OC variant under normal conditions — network latency is independent of CPU allocation. Degradation only appears under extreme memory pressure or when TCP socket buffers are constrained, which is exactly the kind of subtle boundary the classifier must learn.

**log-filter (Mixed CPU + I/O):** Written in Go for variety and to match the paper's multi-language setup. Generates 1000 synthetic log lines, applies regex matching to filter ERROR/WARN/CRITICAL entries, then runs IP anonymization (string splitting and replacement) on each match. This exercises both CPU (regex engine, string manipulation) and memory (holding 1000 strings, building the filtered output). The mixed profile creates a more complex decision surface for the classifier — sometimes CPU contention matters, sometimes memory pressure matters, and sometimes neither does.

Each function is deployed in two variants: **Non-OC** (full resources) and **OC** (overcommitted). The OC resource allocations use the paper's formula `OC = 0.3 × claimed + 0.7 × actual_usage`, which weights actual measured usage more heavily than the user's claim. This produces aggressive but data-driven resource reduction — for example, image-resize claims 512 Mi memory but actually uses ~80 Mi, so the OC allocation is only 210 Mi (a 59% reduction).

## Overcommitment Resource Calculations

| Function | Claimed Memory | Actual Usage | OC Memory | Reduction |
|---|---|---|---|---|
| image-resize | 512 Mi | ~80 Mi | 210 Mi (0.3×512 + 0.7×80) | 59% |
| db-query | 256 Mi | ~40 Mi | 105 Mi (0.3×256 + 0.7×40) | 59% |
| log-filter | 256 Mi | ~30 Mi | 98 Mi (0.3×256 + 0.7×30) | 62% |

The same formula applies to CPU: image-resize drops from 1000m to 405m, db-query from 500m to 185m, log-filter from 500m to 206m. These reductions are the source of cost savings — if the ML classifier can correctly predict when OC instances are safe to use, the cluster runs the same workload with ~60% fewer reserved resources.

## Reproducibility

Every command executed during this project is recorded in the execution logs with full output, explanations, and reasoning. The infrastructure scripts in `infrastructure/` can recreate the entire cluster from scratch. To rebuild:

1. `bash infrastructure/setup-vpc.sh` — creates the VPC and networking
2. `bash infrastructure/launch-instances.sh <subnet-id> <sg-id>` — provisions 5 EC2 instances
3. SSH into master and run `install-k3s-master.sh`, then `install-k3s-worker.sh` on each worker
4. SSH into master and run `install-openfaas.sh` — deploys the serverless platform
5. `kubectl apply -f functions/redis-deployment.yaml` — deploys Redis
6. Continue with Phase 1.3+ for function deployment

Total infrastructure cost is approximately $0.58/hr (~$14/day) when all instances are running. Stop instances with `aws ec2 stop-instances` when not actively working to avoid charges.

## References

- Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). *Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing.* ACM SoCC 2023. [DOI](https://doi.org/10.1145/3620678.3624645)
- [k3s Documentation](https://docs.k3s.io/)
- [OpenFaaS Documentation](https://docs.openfaas.com/)
- [Locust Load Testing](https://locust.io/)
- [Azure Functions Trace (2019)](https://github.com/Azure/AzurePublicDataset) — used as basis for synthetic workload generation
