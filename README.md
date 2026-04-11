# Golgi Replication on AWS

A replication of **Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing** (ACM SoCC 2023, Best Paper Award) on AWS infrastructure using k3s and OpenFaaS.

**Course:** CSL7510 — Cloud Computing  
**Student:** Anshul Kumar (M25AI2036)  
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
├── infra/                           # AWS infrastructure scripts (coming)
├── functions/                       # Benchmark serverless functions (coming)
│   ├── image-resize/                #   CPU-bound: PIL image processing
│   ├── db-query/                    #   I/O-bound: Redis read/write
│   └── log-filter/                  #   Mixed: regex parsing + filtering (Go)
├── collector/                       # Metric collection DaemonSet (coming)
├── ml/                              # ML classifier module (coming)
├── router/                          # Golgi routing logic (coming)
└── loadgen/                         # Locust load generation scripts (coming)
```

## Progress

- [x] Phase 0: AWS account, IAM user, CLI, SSH key pair
- [x] Phase 0: VPC, subnet, internet gateway, route table, security group
- [x] Phase 0: 5 EC2 instances provisioned and verified
- [x] Phase 0: k3s cluster (1 server + 3 agents) operational
- [x] Phase 0: OpenFaaS deployed via Helm (gateway, prometheus, NATS, queue-worker)
- [x] Phase 0: Python + dependencies installed on all nodes, cgroup v2 verified
- [ ] Phase 1: Benchmark functions (3 functions x 2 variants = 6 deployments)
- [ ] Phase 2: Metric collector (cgroup v2 DaemonSet)
- [ ] Phase 3: ML module (Random Forest classifier)
- [ ] Phase 4: Router (Nginx + Python prediction sidecar)
- [ ] Phase 5: Vertical scaling (concurrency limit adjustment)
- [ ] Phase 6: Load generator (Locust trace replay)
- [ ] Phase 7: End-to-end integration
- [ ] Phase 8: Evaluation and metrics collection
- [ ] Phase 9: Results analysis and visualization
- [ ] Phase 10: Report writing and demo

## References

- Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). *Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing.* ACM SoCC 2023. [DOI](https://doi.org/10.1145/3620678.3624645)
- [k3s Documentation](https://docs.k3s.io/)
- [OpenFaaS Documentation](https://docs.openfaas.com/)
- [Locust Load Testing](https://locust.io/)
- [Azure Functions Trace (2019)](https://github.com/Azure/AzurePublicDataset) — used as basis for synthetic workload generation
