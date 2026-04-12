# Characterizing the Impact of Resource Overcommitment on Serverless Function Latency

An empirical study of how resource overcommitment affects serverless function latency across different workload profiles, conducted on real AWS infrastructure using k3s and OpenFaaS. Inspired by the Golgi paper (ACM SoCC 2023, Best Paper Award).

**Course:** CSL7510 — Cloud Computing  
**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)  
**Programme:** M.Tech Artificial Intelligence, IIT Jodhpur  
**Paper DOI:** [10.1145/3620678.3624645](https://doi.org/10.1145/3620678.3624645)

---

## The Problem

Serverless functions waste resources. Studies show functions use only ~25% of their reserved CPU and memory on average — the remaining 75% sits idle. Cloud providers lose money, and users overpay.

The obvious fix — giving functions fewer resources (overcommitment) — causes latency spikes when multiple squeezed containers compete for shared hardware. The Golgi paper reports up to 183% P95 latency increase with blind overcommitment.

But is the impact uniform? The Golgi paper hypothesizes that different workload profiles respond differently to overcommitment — CPU-bound functions degrade proportionally, I/O-bound functions are resilient, and mixed functions exhibit non-linear degradation from CFS scheduler interactions. They build an ML-guided routing system on this hypothesis, but the hypothesis itself is assumed, not independently validated.

**We provide that validation.**

## What We Do

We systematically characterize how resource overcommitment affects serverless function latency across three workload profiles through four experiments:

| Experiment | Research Question |
|---|---|
| **Degradation Curves** | How does P95 latency degrade as CPU allocation decreases? Does the shape differ by profile? |
| **Concurrency Sweep** | Does concurrent load amplify overcommitment-induced degradation? |
| **Tail Latency Analysis** | How does overcommitment affect P99/P99.9 compared to median behavior? |
| **CFS Boundary Analysis** | Can bimodal latency in mixed functions be explained by CFS quota boundary effects? |

## Infrastructure

All resources run on AWS in `us-east-1a` inside a dedicated VPC (`10.0.0.0/16`):

| Node | Instance Type | vCPU | RAM | Role |
|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway |
| golgi-worker-1 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-2 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-3 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-loadgen | t3.medium | 2 | 4 GB | Request generation, latency measurement |

**Running cost:** ~$0.58/hr ($14/day) when all instances are running.

**Stack:** AWS EC2, k3s v1.34.6, OpenFaaS (Helm), Python 3.9, cgroup v2, matplotlib/numpy

## Benchmark Functions

Three functions covering three distinct resource profiles:

**image-resize (CPU-bound):** Generates a random RGB image (1920×1080), then downscales it to half size using Pillow's Lanczos resampling. Latency is directly proportional to available CPU cycles.

**db-query (I/O-bound):** Connects to a Redis instance and performs a GET → SET → GET sequence. Latency is dominated by network round-trips, not CPU. Resilient to CPU reduction.

**log-filter (Mixed):** Written in Go. Generates 1000 synthetic log lines, applies regex matching, and runs IP anonymization. Exercises both CPU (regex, string ops) and memory. Its CPU burst size sits near the CFS quota boundary under overcommitment, creating bimodal latency behavior.

Each function is deployed in two variants: **Non-OC** (full resources) and **OC** (overcommitted). OC allocations use the Golgi paper's formula `OC = 0.3 × claimed + 0.7 × actual_usage`.

## Overcommitment Resource Calculations

| Function | Claimed CPU | OC CPU | Reduction | Claimed Memory | OC Memory | Reduction |
|---|---|---|---|---|---|---|
| image-resize | 1000m | 405m | 2.47× | 512 Mi | 210 Mi | 59% |
| db-query | 500m | 185m | 2.70× | 256 Mi | 105 Mi | 59% |
| log-filter | 500m | 206m | 2.43× | 256 Mi | 98 Mi | 62% |

## Baseline Latency Results (Phase 1)

Measured from 200 sequential requests per function on 2026-04-12:

| Function | Profile | CPU | P50 | P95 (SLO) | P99 | Mean | Errors |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound (Non-OC) | 1000m | 4485ms | **4591ms** | 4762ms | 4499ms | 0/200 |
| image-resize-oc | CPU-bound (OC) | 405m | 11067ms | 11156ms | 11276ms | 11057ms | 0/200 |
| db-query | I/O-bound (Non-OC) | 500m | 18ms | **21ms** | 24ms | 19ms | 0/200 |
| db-query-oc | I/O-bound (OC) | 185m | 20ms | 28ms | 35ms | 21ms | 0/200 |
| log-filter | Mixed (Non-OC) | 500m | 16ms | **17ms** | 18ms | 16ms | 0/200 |
| log-filter-oc | Mixed (OC) | 206m | 25ms | 77ms | 96ms | 35ms | 0/200 |

**Key finding:** Overcommitment impact varies by profile — CPU-bound functions degrade 2.4× (proportional to CPU cut), I/O-bound degrade only 1.3×, and mixed functions show 4.5× degradation from bimodal CFS throttling. This validates the Golgi paper's core hypothesis that different function profiles respond differently to overcommitment.

### Phase 1 Plots

- [P95 Latency — Non-OC vs OC](results/phase1/plots/fig3_p95_bar_chart.png)
- [Latency CDF — Fast Functions](results/phase1/plots/fig1_cdf_fast_functions.png)
- [Latency CDF — Per Function](results/phase1/plots/fig2_cdf_per_function.png)
- [Latency Distribution — Box Plots](results/phase1/plots/fig4_box_plots.png)
- [Degradation Ratios](results/phase1/plots/fig5_degradation_ratios.png)

## Repository Structure

```
.
├── README.md                        # This file
├── PROJECT_PLAN.md                  # Project plan (all phases)
├── execution_log_phase0.md          # Phase 0 execution log (infrastructure setup)
├── execution_log_phase1.md          # Phase 1 execution log (baseline characterization)
├── docs/
│   ├── final_report.md              # Final course report (in progress)
│   └── golgi-socc23-audit.md        # Paper-code audit and analysis
├── infrastructure/                  # AWS infrastructure scripts
│   ├── setup-vpc.sh
│   ├── launch-instances.sh
│   ├── install-k3s-master.sh
│   ├── install-k3s-worker.sh
│   ├── install-openfaas.sh
│   └── teardown.sh
├── functions/                       # Benchmark serverless functions
│   ├── stack.yml                    #   OpenFaaS deployment config (6 variants)
│   ├── functions-deploy.yaml        #   Raw K8s manifests
│   ├── redis-deployment.yaml        #   Redis for db-query
│   ├── image-resize/                #   CPU-bound (Python)
│   ├── db-query/                    #   I/O-bound (Python)
│   └── log-filter/                  #   Mixed (Go)
├── scripts/                         # Benchmark and analysis scripts
│   ├── benchmark-latency.sh         #   Sequential latency measurement
│   ├── compute-stats.py             #   Statistics computation
│   ├── generate-phase1-plots.py     #   Phase 1 plot generation
│   ├── smoke-test.sh                #   Health check for all functions
│   ├── warmup.sh                    #   Warmup requests
│   └── test-concurrency.sh          #   Concurrency verification
└── results/
    └── phase1/                      #   Baseline measurements and plots
```

## Progress

- [x] Phase 0: AWS infrastructure (VPC, 5 EC2 instances, k3s cluster, OpenFaaS)
- [x] Phase 1: Benchmark deployment and baseline characterization (6 function variants, SLO thresholds established)
- [x] Report: Sections 1-3 drafted (Introduction, Background, System Design)
- [ ] Phase 2: Multi-level degradation curves (5 CPU levels × 3 functions)
- [ ] Phase 3: Concurrency under overcommitment (4 concurrency levels × 6 variants)
- [ ] Phase 4: Tail latency analysis (P99/P99.9 deep dive)
- [ ] Phase 5: CFS quota boundary analysis (fine-grained CPU sweep for log-filter)
- [ ] Phase 6: Analysis and visualization (17+ plots, statistical tests)
- [ ] Phase 7: Final report and demo

## Reproducibility

Every command executed during this project is recorded in the execution logs with full output, explanations, and reasoning. The infrastructure scripts in `infrastructure/` can recreate the entire cluster from scratch. To rebuild:

1. `bash infrastructure/setup-vpc.sh` — creates the VPC and networking
2. `bash infrastructure/launch-instances.sh <subnet-id> <sg-id>` — provisions 5 EC2 instances
3. SSH into master and run `install-k3s-master.sh`, then `install-k3s-worker.sh` on each worker
4. SSH into master and run `install-openfaas.sh` — deploys the serverless platform
5. `kubectl apply -f functions/redis-deployment.yaml` — deploys Redis
6. Pull OpenFaaS templates: `faas-cli template store pull python3-http && faas-cli template store pull golang-http`
7. Build and deploy functions per Phase 1 instructions

Total infrastructure cost is approximately $0.58/hr (~$14/day) when all instances are running. Stop instances with `aws ec2 stop-instances` when not actively working to avoid charges.

## References

- Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). *Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing.* ACM SoCC 2023. [DOI](https://doi.org/10.1145/3620678.3624645)
- Shahrad, M., et al. (2020). *Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider.* USENIX ATC 2020.
- [k3s Documentation](https://docs.k3s.io/)
- [OpenFaaS Documentation](https://docs.openfaas.com/)
- [Linux CFS Bandwidth Control](https://docs.kernel.org/scheduler/sched-bwc.html)
- [cgroup v2 Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
