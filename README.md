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

All resources run on AWS in `us-east-1a`:

| Node | Instance Type | vCPU | RAM | Role |
|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway, Golgi router |
| golgi-worker-1/2/3 | t3.xlarge | 4 | 16 GB | Function containers, metric collector |
| golgi-loadgen | t3.medium | 2 | 4 GB | Locust load generator |

**Stack:** AWS EC2, k3s (Kubernetes), OpenFaaS, Python, Nginx, scikit-learn

## Repository Structure

```
.
├── README.md                      # This file
├── GOLGI_REPLICATION_PLAN.md      # Detailed implementation plan (all phases)
├── execution_log.md               # Step-by-step execution log with commands and outputs
├── docs/
│   ├── paper/
│   │   ├── golgi_paper.pdf        # Original paper (Li et al., SoCC 2023)
│   │   ├── golgi_paper.md         # Paper notes in markdown
│   │   └── golgi_paper_text.txt   # Extracted paper text
│   ├── analysis/
│   │   └── golgi-socc23-audit.md  # Paper-code audit and analysis
│   └── final_report.md            # Final course report (in progress)
├── infra/                         # AWS infrastructure scripts (coming)
├── functions/                     # Benchmark serverless functions (coming)
├── collector/                     # Metric collection daemon (coming)
├── ml/                            # ML classifier module (coming)
├── router/                        # Golgi routing logic (coming)
└── loadgen/                       # Load generation scripts (coming)
```

## Progress

- [x] Phase 0: AWS account, CLI, SSH key pair
- [x] Phase 0: VPC, subnet, internet gateway, security group
- [x] Phase 0: 5 EC2 instances launched and verified
- [x] Phase 0: k3s cluster (4 nodes) operational
- [ ] Phase 0: OpenFaaS deployment
- [ ] Phase 1: Benchmark functions
- [ ] Phase 2: Metric collector
- [ ] Phase 3: ML module
- [ ] Phase 4: Router
- [ ] Phase 5: Vertical scaling
- [ ] Phase 6: Load generator
- [ ] Phase 7: Integration
- [ ] Phase 8-10: Evaluation, analysis, report

## References

- Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). *Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing.* ACM SoCC 2023. [DOI](https://doi.org/10.1145/3620678.3624645)
- [k3s Documentation](https://docs.k3s.io/)
- [OpenFaaS Documentation](https://docs.openfaas.com/)
