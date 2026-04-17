# Characterizing the Impact of Resource Overcommitment on Serverless Function Latency

An empirical study of how Linux CFS quota enforcement creates profile-dependent latency degradation under container resource overcommitment, tested across three workload profiles on real AWS infrastructure using k3s and OpenFaaS.

**Course:** CSL7510 — Cloud Computing  
**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056), Kirtiman Sarangi (G25AI1024)  
**Programme:** M.Tech Artificial Intelligence, IIT Jodhpur  
**Inspired by:** Golgi — Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing (ACM SoCC 2023, Best Paper Award)  
**Paper DOI:** [10.1145/3620678.3624645](https://doi.org/10.1145/3620678.3624645)

---

## Table of Contents

- [The Problem](#the-problem)
- [What We Do](#what-we-do)
- [Research Questions](#research-questions)
- [Infrastructure](#infrastructure)
- [Benchmark Functions](#benchmark-functions)
- [Overcommitment Resource Calculations](#overcommitment-resource-calculations)
- [Results](#results)
  - [Phase 1: Baseline Latency](#phase-1-baseline-latency-results)
  - [Pre-Phase 2: CPU Burst Measurement](#pre-phase-2-cpu-burst-measurement)
  - [Phase 2: Degradation Curve](#phase-2-degradation-curve)
- [Phase 1 Plots](#phase-1-plots)
- [Repository Structure](#repository-structure)
- [Progress](#progress)
- [Future Scope](#future-scope)
- [Reproducibility](#reproducibility)
- [References](#references)

---

## The Problem

Serverless functions waste resources. Studies show functions use only ~25% of their reserved CPU and memory on average — the remaining 75% sits idle. Cloud providers lose money, and users overpay.

The obvious fix — giving functions fewer resources (**overcommitment**) — causes latency spikes when multiple squeezed containers compete for shared hardware. Li et al. measured up to 183% P95 latency increase with blind overcommitment.

But is the impact uniform? The Linux CFS (Completely Fair Scheduler) enforces CPU limits via a quota-and-period mechanism that interacts differently with different workload profiles:

- **CPU-bound functions** exhaust their quota predictably — latency scales proportionally with CPU reduction.
- **I/O-bound functions** release quota during network waits — resilient to CPU cuts.
- **Mixed functions** can trigger non-linear throttling when their CPU burst size sits near the quota boundary, creating bimodal latency distributions.

The Golgi paper (SoCC 2023) builds an ML-guided routing system on the assumption that these profiles respond differently — but the underlying profile-dependent degradation behavior is assumed, not independently characterized.

**We provide that characterization.**

## What We Do

We systematically characterize how resource overcommitment affects serverless function latency across three workload profiles on real cloud infrastructure. Phase 1 establishes the cross-profile contrast at one overcommitment level, confirming that degradation is profile-dependent. Phase 2 then performs a deep multi-level characterization of the CPU-bound function (image-resize) across 4 CPU levels (100%, 80%, 60%, 40%) to map the degradation curve shape and validate the CFS throttling mechanism quantitatively. We also provide a mechanistic explanation of CFS quota boundary effects that drive the non-linear degradation in mixed workloads.

## Research Questions

| # | Research Question | Experiment |
|---|---|---|
| RQ1 | How does P95 latency degrade as CPU allocation decreases for a CPU-bound serverless function, and does CFS throttling explain the degradation? | Phase 1 cross-profile baseline + Phase 2 multi-level degradation curve |
| RQ2 | Can the bimodal latency behavior of mixed functions under overcommitment be explained by CFS quota boundary effects? | Phase 1 bimodality observation + Pre-Phase 2 CPU burst measurement |

---

## Infrastructure

All resources run on AWS in `us-east-1a` inside a dedicated VPC (`10.0.0.0/16`):

| Node | Instance Type | vCPU | RAM | Role |
|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway |
| golgi-worker-1 | t3.xlarge | 4 | 16 GB | Non-OC pods: `image-resize`, `redis` |
| golgi-worker-2 | t3.xlarge | 4 | 16 GB | Non-OC pods: `db-query`, `log-filter` |
| golgi-worker-3 | t3.xlarge | 4 | 16 GB | OC pods: `image-resize-oc`, `db-query-oc`, `log-filter-oc` |
| golgi-loadgen | t3.medium | 2 | 4 GB | Request generation, latency measurement |

**Running cost:** ~$0.58/hr ($14/day) when all instances are running.

**Technology Stack:**

| Component | Choice | Why |
|---|---|---|
| Cloud | AWS EC2 | Real hardware with full kernel access |
| Orchestration | k3s v1.34.6 | Lightweight Kubernetes — same cgroup/CFS behavior as production K8s |
| Serverless framework | OpenFaaS (Helm) | Container-level resource control via K8s manifests |
| Container runtime | containerd 2.2.2 | cgroup v2 native support |
| cgroup | v2 (`cgroup2fs`) | Direct kernel-level measurement via `cpu.stat` |
| Benchmarks | 3 functions (Python + Go) | CPU-bound, I/O-bound, mixed |
| Analysis | Python 3.9 (numpy, matplotlib) | Statistical computing and publication-quality plots |

---

## Benchmark Functions

Three functions covering three distinct resource profiles:

### image-resize (CPU-bound) — Python

Generates a random RGB image (1920x1080), then downscales it to 960x540 using Pillow's Lanczos resampling. All work is CPU-bound — no network I/O, no disk access. Latency is directly proportional to available CPU cycles, making this the control case for linear degradation.

### db-query (I/O-bound) — Python

Connects to a Redis instance (deployed as a K8s pod) and performs a GET -> SET -> GET sequence. Latency is dominated by network round-trips between the function container and Redis, not CPU. This function demonstrates resilience to CPU reduction since the CPU sits idle during I/O waits.

### log-filter (Mixed) — Go

Generates 1000 synthetic log lines with timestamps, IP addresses, and severity levels, then applies regex matching (`ERROR|WARN|CRITICAL`) and IP anonymization via string replacement. Exercises both CPU (regex matching, string operations) and memory allocation. Its per-request CPU burst size (7.7ms) sits near the CFS quota boundary under overcommitment, creating bimodal latency behavior — the key phenomenon we study.

Each function is deployed in two variants: **Non-OC** (full resources) and **OC** (overcommitted). OC allocations use the Golgi paper's formula: `OC = 0.3 x claimed + 0.7 x actual_usage`.

## Overcommitment Resource Calculations

| Function | Profile | Claimed CPU | OC CPU | CPU Reduction | Claimed Memory | OC Memory | Memory Reduction |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound | 1000m | 405m | 2.47x | 512 Mi | 210 Mi | 59% |
| db-query | I/O-bound | 500m | 185m | 2.70x | 256 Mi | 105 Mi | 59% |
| log-filter | Mixed | 500m | 206m | 2.43x | 256 Mi | 98 Mi | 62% |

---

## Results

### Phase 1: Baseline Latency Results

200 sequential requests per function, measured end-to-end from the load generator (nanosecond precision via `date +%s%N`, reported in milliseconds):

| Function | Profile | CPU | P50 | P95 (SLO) | P99 | Mean | Errors |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound (Non-OC) | 1000m | 4485ms | **4591ms** | 4762ms | 4499ms | 0/200 |
| image-resize-oc | CPU-bound (OC) | 405m | 11067ms | 11156ms | 11276ms | 11057ms | 0/200 |
| db-query | I/O-bound (Non-OC) | 500m | 18ms | **21ms** | 24ms | 19ms | 0/200 |
| db-query-oc | I/O-bound (OC) | 185m | 20ms | 28ms | 35ms | 21ms | 0/200 |
| log-filter | Mixed (Non-OC) | 500m | 16ms | **17ms** | 18ms | 16ms | 0/200 |
| log-filter-oc | Mixed (OC) | 206m | 25ms | 77ms | 96ms | 35ms | 0/200 |

**Key findings:**

- **CPU-bound (image-resize):** P95 degradation 4591ms -> 11156ms = **2.43x increase**, proportional to the 2.47x CPU reduction. Tight distribution, no bimodality. Linear degradation confirmed.
- **I/O-bound (db-query):** P95 degradation 21ms -> 28ms = **1.33x increase** despite 2.70x CPU reduction. Network round-trip time dominates — CPU reduction has minimal effect.
- **Mixed (log-filter):** P95 degradation 17ms -> 77ms = **4.53x increase** with only 2.43x CPU reduction. Exhibits bimodal distribution with a fast mode (~16-25ms) and a slow mode (~50-77ms). The non-linear, disproportionate degradation is driven by CFS quota boundary interactions.

### Pre-Phase 2: CPU Burst Measurement

Direct cgroup v2 `cpu.stat` measurement to determine per-request CPU consumption and throttling behavior:

| Metric | log-filter-oc (206m) | log-filter (500m) |
|---|---|---|
| Avg CPU per request | **7,761 us (7.76ms)** | **7,600 us (7.60ms)** |
| Throttle ratio | 97.3% of periods | 33.3% of periods |
| Avg throttle duration | 142.0ms | 4.2ms |
| Quota utilization | 100.5% | 30.4% |

**Bimodality mechanism explained (RQ2):** With a 206m quota (20,600 us per 100ms CFS period) and 7.7ms burst per request, ~2.7 requests fit per period. The first 2 complete within quota (fast mode). The 3rd request straddles the period boundary — it exhausts remaining quota mid-execution and must wait for the next period to resume, adding ~80ms of throttle penalty (slow mode). This is not random — it is a deterministic consequence of the burst-to-quota ratio.

**Cross-validation:** OC and Non-OC burst sizes match within 2.1% (7.76ms vs 7.60ms), confirming CPU burst is an intrinsic function property independent of the resource limit.

### Phase 2: Degradation Curve

image-resize deployed at 4 CPU levels (100%, 80%, 60%, 40%), 200 requests x 3 reps per level = 2,400 total measurements. CFS `cpu.stat` snapshots captured before and after each level.

| CPU % | CPU (m) | Mean P95 (ms) | Degradation | Predicted (1/x) | Deviation | CFS Throttle Ratio |
|---|---|---|---|---|---|---|
| 100% | 1000 | 4611 | 1.00x | 1.00x | -- | 14.8% |
| 80% | 800 | 5791 | 1.26x | 1.25x | +0.8% | 98.0% |
| 60% | 600 | 8053 | 1.75x | 1.67x | +4.8% | 99.93% |
| 40% | 400 | 11496 | 2.49x | 2.50x | -0.4% | 99.95% |

**Key findings (answering RQ1):**

- **Inverse-quota scaling confirmed.** Degradation tracks the theoretical 1/x model within 5% at all 4 levels, validating that CFS quota enforcement is the dominant mechanism for CPU-bound functions.
- **CFS throttle ratio phase transition.** At 100% CPU, only 14.8% of CFS periods are throttled. At 80% -- just a 20% cut -- the throttle ratio jumps to 98.0% and saturates at 99.9%+ for deeper levels. Even a modest overcommitment pushes a CPU-bound function past the CFS boundary in nearly every scheduling period.
- **Variance decreases under deep throttling.** Inter-rep P95 variance drops from ~50ms at 100% to just 3ms at 40%. CFS throttling at high saturation eliminates scheduler jitter -- a counter-intuitive but mechanistically explainable result.
- **Zero errors across 2,400 requests.** The 100% baseline (P95 = 4611ms) matches Phase 1 (P95 = 4591ms) within 0.7%, confirming infrastructure consistency.

---

## Phase 2 Plots

| Plot | Description |
|---|---|
| [Degradation Curve](results/phase2/plots/fig6_degradation_curve.png) | P95 latency at 4 CPU levels with inverse-quota model overlay — the key figure |
| [CFS Throttle vs Degradation](results/phase2/plots/fig7_throttle_vs_degradation.png) | Phase transition from 14.8% to 98%+ throttle ratio with first CPU cut |
| [Latency Distributions](results/phase2/plots/fig8_latency_distributions.png) | Violin + box plots showing distribution tightening under deep throttling |
| [Cross-Profile Comparison](results/phase2/plots/fig9_cross_profile_comparison.png) | Phase 1 degradation ratios by profile (CPU-bound, I/O-bound, Mixed) |
| [Combined Dual-Axis](results/phase2/plots/fig10_combined_degradation_throttle.png) | Degradation ratio + CFS throttle ratio on shared x-axis |
| [Rep Consistency Heatmap](results/phase2/plots/fig11_rep_consistency_heatmap.png) | P95 across 3 reps — variance drops from 21ms to 3ms under deep throttling |

**Statistical analysis:** R² = 0.9949 for inverse-quota model fit. Inter-rep coefficient of variation drops from 0.19% (100%) to 0.01% (40%).

---

## Phase 1 Plots

| Plot | Description |
|---|---|
| [P95 Latency — Non-OC vs OC](results/phase1/plots/fig3_p95_bar_chart.png) | Grouped bar chart showing P95 latency for all 6 variants, color-coded by profile |
| [Latency CDF — Fast Functions](results/phase1/plots/fig1_cdf_fast_functions.png) | CDF of db-query and log-filter, showing how I/O-bound barely shifts while mixed spreads |
| [Latency CDF — Per Function](results/phase1/plots/fig2_cdf_per_function.png) | 3 subplots with Non-OC vs OC CDFs and SLO threshold lines |
| [Latency Distribution — Box Plots](results/phase1/plots/fig4_box_plots.png) | Box plots revealing bimodal behavior in log-filter-oc |
| [Degradation Ratios](results/phase1/plots/fig5_degradation_ratios.png) | Bar chart of P95 OC/Non-OC ratios: 2.4x (CPU), 1.3x (I/O), 4.5x (mixed) |

---

## Repository Structure

```
.
├── README.md                          # This file
├── PROJECT_PLAN.md                    # Full experimental plan and methodology
├── execution_log_phase0.md            # Phase 0: AWS infrastructure setup (every command + output)
├── execution_log_phase1.md            # Phase 1: Benchmark deployment and baseline measurement
├── execution_log_phase2.md            # Phase 2: CPU burst measurement + degradation curve
│
├── docs/
│   ├── final_report.md                # Course report (complete, 8 sections)
│   ├── final_report.pdf               # PDF render (A3, 17 pages)
│   ├── analysis/
│   │   └── golgi-socc23-audit.md      # Paper-code audit of Golgi repository
│   └── paper/
│       ├── golgi_paper.pdf            # Original Golgi paper (reference)
│       └── golgi_paper.md             # Paper notes and extracts
│
├── infrastructure/                    # AWS and cluster setup scripts
│   ├── setup-vpc.sh                   #   VPC, subnet, IGW, route table, security group
│   ├── launch-instances.sh            #   5 EC2 instances (1 master, 3 workers, 1 loadgen)
│   ├── install-k3s-master.sh          #   k3s control plane installation
│   ├── install-k3s-worker.sh          #   Worker node join script
│   ├── install-openfaas.sh            #   OpenFaaS via Helm
│   ├── openfaas-values.yaml           #   Helm values for OpenFaaS configuration
│   └── teardown.sh                    #   Full resource cleanup
│
├── functions/                         # Benchmark serverless functions
│   ├── stack.yml                      #   OpenFaaS stack definition (6 variants)
│   ├── functions-deploy.yaml          #   Raw K8s Deployment + Service manifests
│   ├── phase2-deploy-template.yaml    #   Parameterized template for Phase 2 CPU levels
│   ├── redis-deployment.yaml          #   Redis 7 for db-query I/O target
│   ├── image-resize/                  #   CPU-bound benchmark (Python, Pillow)
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── db-query/                      #   I/O-bound benchmark (Python, Redis)
│   │   ├── handler.py
│   │   └── requirements.txt
│   └── log-filter/                    #   Mixed benchmark (Go, regex + string ops)
│       ├── handler.go
│       └── go.mod
│
├── build/                             # OpenFaaS build templates
│   ├── python3-http/                  #   Python function template (Dockerfile, index.py)
│   └── golang-http/                   #   Go function template (Dockerfile, main.go)
│
├── scripts/                           # Measurement and analysis tools
│   ├── benchmark-latency.sh           #   Sequential latency measurement (N requests per function)
│   ├── compute-stats.py               #   P50/P95/P99, mean, stddev computation
│   ├── generate-phase1-plots.py       #   5 publication-quality matplotlib plots
│   ├── generate-phase2-plots.py       #   Phase 2 analysis + 6 publication-quality plots
│   ├── report-to-pdf.py              #   Markdown-to-PDF converter (A3, xhtml2pdf)
│   ├── measure-cpu-burst.sh           #   cgroup v2 cpu.stat before/after measurement
│   ├── run-phase2.sh                  #   Phase 2 orchestrator (reference)
│   ├── run-level.sh                   #   Per-level runner (deploy, warmup, measure, CFS, teardown)
│   ├── read-cfs.sh                    #   Standalone CFS stat reader (master -> worker SSH)
│   ├── smoke-test.sh                  #   Health check for all 6 functions
│   ├── warmup.sh                      #   Cold-start elimination (5 requests per function)
│   └── test-concurrency.sh            #   Concurrency verification
│
└── results/
    ├── phase1/                        # Baseline latency data
    │   ├── image-resize_latencies.txt       # 200 Non-OC latencies (ms)
    │   ├── image-resize-oc_latencies.txt    # 200 OC latencies (ms)
    │   ├── db-query_latencies.txt           # 200 Non-OC latencies (ms)
    │   ├── db-query-oc_latencies.txt        # 200 OC latencies (ms)
    │   ├── log-filter_latencies.txt         # 200 Non-OC latencies (ms)
    │   ├── log-filter-oc_latencies.txt      # 200 OC latencies (ms)
    │   └── plots/                           # Publication-quality visualizations
    │       ├── fig1_cdf_fast_functions.png
    │       ├── fig2_cdf_per_function.png
    │       ├── fig3_p95_bar_chart.png
    │       ├── fig4_box_plots.png
    │       └── fig5_degradation_ratios.png
    ├── pre-phase2/
    │   └── cpu-burst-measurement.md   # CPU burst analysis and CFS throttling data
    └── phase2/                        # Multi-level degradation data
        ├── image-resize_cpu*_rep*.txt       # 200 latency samples per (level, rep)
        ├── image-resize_cpu*_cfs_before.txt # CFS snapshot before measurement
        ├── image-resize_cpu*_cfs_after.txt  # CFS snapshot after measurement
        └── plots/                           # Phase 2 visualizations
            ├── fig6_degradation_curve.png
            ├── fig7_throttle_vs_degradation.png
            ├── fig8_latency_distributions.png
            ├── fig9_cross_profile_comparison.png
            ├── fig10_combined_degradation_throttle.png
            └── fig11_rep_consistency_heatmap.png
```

---

## Progress

- [x] **Phase 0:** AWS infrastructure — VPC, 5 EC2 instances, k3s cluster, OpenFaaS gateway
- [x] **Phase 1:** Benchmark deployment and baseline characterization — 6 function variants, 1,200 latency measurements, SLO thresholds established, 5 plots generated
- [x] **Pre-Phase 2:** CPU burst measurement — 7.7ms burst size determined, bimodality mechanism validated (RQ2 answered)
- [x] **Phase 2:** Multi-level degradation curve — image-resize at 4 CPU levels x 200 requests x 3 reps = 2,400 measurements (RQ1 answered)
- [x] **Phase 3:** Analysis and visualization — 6 Phase 2 plots + statistical analysis (R² = 0.9949)
- [x] **Phase 4:** Final report complete (8 sections, 17 pages, 11 figures, PDF rendered)

**Total measurements collected:** 3,600 (1,200 in Phase 1 + 2,400 in Phase 2)

---

## Future Scope

The following experiments extend the characterization naturally and represent valuable directions for future work:

- **Multi-level sweeps for I/O-bound and mixed profiles.** Phase 1 confirmed profile-dependent degradation at one OC level. Sweeping db-query and log-filter across 4 CPU levels would produce their own degradation curves — we predict db-query would show a flat curve (I/O wait dominates) and log-filter would show step-function behavior at the CFS quota boundary predicted by the 7.7ms burst measurement.

- **Concurrency under overcommitment.** Does concurrent load amplify overcommitment-induced degradation? Multiple concurrent requests collectively exhaust the CFS quota faster — at 206m quota, four functions needing 7.7ms each = 30.8ms of CPU work per period against only 20.6ms of quota, creating effective serialization. A sweep of 1, 2, 4, 8 concurrent requests would reveal whether this amplification is superlinear for mixed functions.

- **Tail latency analysis.** How does overcommitment affect P99 and P99.9 compared to the median? The bimodal CFS behavior means fast-mode requests contribute to the median while slow-mode requests dominate the tail. Extended measurements (1000+ requests) would enable reliable tail estimation and Tail Amplification Factor computation across profiles.

- **Fine-grained CFS quota boundary sweep.** The measured 7.7ms burst size predicts transition points at integer multiples: ~77m, ~154m, ~231m, ~308m. A sweep of 50m-300m in 10m increments (26 data points) for log-filter would map exactly where latency transitions from unimodal to bimodal and back, providing high-resolution validation of the CFS boundary hypothesis.

---

## Reproducibility

Every command executed during this project is recorded in the execution logs with full output, explanations, and reasoning. The infrastructure scripts in `infrastructure/` can recreate the entire cluster from scratch:

1. `bash infrastructure/setup-vpc.sh` — creates VPC, subnet, internet gateway, route table, security group
2. `bash infrastructure/launch-instances.sh <subnet-id> <sg-id>` — provisions 5 EC2 instances
3. SSH into master -> run `install-k3s-master.sh` — installs k3s control plane
4. SSH into each worker -> run `install-k3s-worker.sh` — joins workers to cluster
5. SSH into master -> run `install-openfaas.sh` — deploys OpenFaaS via Helm
6. `kubectl apply -f functions/redis-deployment.yaml` — deploys Redis for db-query
7. Pull templates: `faas-cli template store pull python3-http && faas-cli template store pull golang-http`
8. Build and deploy functions: `faas-cli up -f functions/stack.yml` (see Phase 1 execution log for details)

**Cost:** ~$0.58/hr (~$14/day) when all instances are running. Stop instances with `aws ec2 stop-instances` when not actively working.

---

## References

1. Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). *Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing.* ACM SoCC 2023. [DOI](https://doi.org/10.1145/3620678.3624645)
2. Shahrad, M., et al. (2020). *Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider.* USENIX ATC 2020.
3. [Linux CFS Bandwidth Control](https://docs.kernel.org/scheduler/sched-bwc.html)
4. [cgroup v2 Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
5. [k3s Documentation](https://docs.k3s.io/)
6. [OpenFaaS Documentation](https://docs.openfaas.com/)
