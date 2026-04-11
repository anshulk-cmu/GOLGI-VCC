# Replicating Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing

**Course:** CSL7510 — Cloud Computing  
**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)  
**Programme:** M.Tech Artificial Intelligence  
**Institution:** Indian Institute of Technology Jodhpur  
**Date:** April 2026

---

## Abstract

<!-- ~200 words. Write after all experiments are complete. -->
<!-- Structure: Problem → Golgi's solution → What we replicated → Key results (cost reduction %, SLO violation rate) → One-line conclusion -->

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background and Related Work](#2-background-and-related-work)
3. [System Design](#3-system-design)
4. [Implementation](#4-implementation)
5. [Experimental Setup](#5-experimental-setup)
6. [Results and Analysis](#6-results-and-analysis)
7. [Discussion](#7-discussion)
8. [Conclusion](#8-conclusion)
9. [References](#9-references)

---

## 1. Introduction

<!-- Pages 2–3, ~1500 words -->

### 1.1 The Serverless Resource Problem

<!-- 
- Define serverless computing (FaaS): users deploy functions, cloud handles scaling/infra
- The resource reservation model: users specify memory (e.g., 512 MB), CPU is allocated proportionally
- The waste problem: studies (Shahrad et al. 2020) show functions use only ~25% of reserved resources on average
- Scale of the problem: millions of function invocations per day on major platforms
- Cost implications: providers over-provision hardware to guarantee reserved resources; users overpay for resources they never use
- This is the fundamental tension: safety vs efficiency
-->

### 1.2 Why Overcommitment Alone Fails

<!--
- Define overcommitment: allocating less physical resources than the sum of all reservations
- Common in VMs (VMware routinely overcommits 2-4x), but serverless is different
- The contention problem: when multiple co-located functions spike simultaneously, they compete for shared CPU/memory
- Paper's finding: blind overcommitment causes up to 183% P95 latency increase
- Why this is unacceptable: serverless users have latency SLOs (e.g., API responses must complete in < 200ms)
- The challenge: how to overcommit safely — save resources without violating latency guarantees
-->

### 1.3 The Golgi Approach

<!--
- Two-instance model: Non-OC (safe, expensive) and OC (cheap, risky)
- Key insight: not all requests experience contention — most of the time, OC instances are fine
- ML classifier trained on real-time container metrics predicts when contention will cause SLO violations
- Router directs requests based on predictions: OC if safe, Non-OC if risky
- Vertical scaling as safety net: adjust concurrency limits when predictions are wrong
- Result: 42% memory cost reduction, <5% SLO violation rate
- Won Best Paper at ACM SoCC 2023
-->

### 1.4 Motivation for Replication

<!--
- Why replicate? (a) Validate claims independently on different hardware/software
- (b) Understand system trade-offs that the paper glosses over (implementation complexity, sensitivity to parameters)
- (c) Course learning objectives: hands-on with K8s, ML systems, cloud infrastructure, performance engineering
- (d) IMPORTANT: The paper has NO public GitHub repository or source code available. The authors did not release their implementation. This means:
  - Every component must be built from scratch based solely on the paper's descriptions
  - Ambiguities in the paper must be resolved through our own engineering judgment
  - Certain implementation details (exact metric collection paths, model hyperparameters, routing logic) are inferred from the paper's text, figures, and evaluation section
  - This makes the replication both more challenging and more valuable — it tests whether the paper provides sufficient detail for independent reproduction
- (e) Scope adjusted to match course project requirements: limited time (1 semester), limited budget (personal AWS), limited team size (2 students) — see Section 1.5 for specific simplifications
-->

### 1.5 Scope and Contributions

<!--
- IMPORTANT FRAMING: Since no source code is publicly available, this is a clean-room replication built entirely from the paper's descriptions. We adjusted the scope to match:
  (a) Course project constraints: 2 students, 1 semester, personal AWS budget (~$50-100 total)
  (b) Replication feasibility: certain details (exact Mondrian Forest implementation, proprietary Azure Function traces, WeBank internal infrastructure) are not reproducible — we make justified substitutions
  (c) Academic requirements: demonstrate understanding of the core contributions, not pixel-perfect reproduction

- What we built: complete end-to-end system on AWS (5 EC2 instances, k3s, OpenFaaS)
- What we simplified and why:
  - 3 functions instead of 8 (sufficient to cover CPU-bound, I/O-bound, and mixed profiles)
  - Random Forest instead of Mondrian Forest (no open-source Mondrian Forest for Python; RF achieves comparable accuracy per paper's own comparison)
  - 7 metrics instead of 9 (hardware perf counters like LLC cache miss require perf_event_open privileges and kernel configuration that conflicts with containerized environments)
  - 3 workers instead of 7 (budget constraint; principle of overcommitment still holds at smaller scale)
  - Synthetic Locust workload instead of Azure trace replay (Azure traces are available but lack the exact arrival patterns used in the paper)
- What claims we test: (1) cost reduction with ML-guided routing, (2) SLO maintenance, (3) vertical scaling effectiveness
- Our contributions: (a) first known independent replication of Golgi on commodity hardware, (b) cgroup v2 implementation (paper likely used v1 — we document the differences), (c) empirical comparison showing Random Forest is a viable substitute for Mondrian Forest in this domain
-->

### 1.6 Report Organization

<!--
- Section 2: Background on serverless, overcommitment, related scheduling work
- Section 3: System design and architecture
- Section 4: Implementation details
- Section 5: Experimental methodology
- Section 6: Results
- Section 7: Discussion and limitations
- Section 8: Conclusion
-->

---

## 2. Background and Related Work

<!-- Pages 4–5, ~1500 words -->

### 2.1 Serverless Computing Model

<!--
- FaaS abstraction: stateless functions triggered by events (HTTP, queue, timer)
- Execution model: cold start → warm container → execute → idle → evict
- Billing: per-invocation + per-GB-second of memory allocated
- Key platforms: AWS Lambda, Azure Functions, Google Cloud Functions, OpenFaaS (self-hosted)
- Resource model: user specifies memory (128 MB – 10 GB), CPU allocated proportionally
- Scaling: platform auto-scales instances (0 to N) based on incoming request rate
- The container lifecycle: why short-lived containers make resource management different from long-running VMs
-->

### 2.2 Resource Overcommitment in Cloud Systems

<!--
- VM-level overcommitment: hypervisors (VMware ESXi, KVM) routinely overcommit memory 1.5-4x using ballooning, page sharing, swap
- Container-level overcommitment: Kubernetes requests vs limits — requests are guaranteed minimum, limits are the ceiling
- The difference in serverless: (a) functions are short-lived (ms to seconds), (b) workloads are bursty and unpredictable, (c) cold starts add latency penalty, (d) many co-located functions from different users
- Why serverless overcommitment is harder: can't use VM techniques (ballooning takes seconds, functions complete in milliseconds)
- Prior work: Shahrad et al. (2020) characterize Azure Function traces — show temporal patterns that could enable prediction
-->

### 2.3 Existing Scheduling Approaches

<!--
- Round-robin: simple, no awareness of resource state — poor under heterogeneous load
- Least-connections: better load balancing but no resource awareness
- Kubernetes default scheduler: bin-packing based on resource requests — static, doesn't adapt to runtime contention
- Harvest VMs (Ambati et al. 2020): use spare capacity but no latency guarantees
- Kraken (Wen et al. 2021): cold-start aware scheduling but doesn't address overcommitment
- ENSURE (Suresh et al. 2020): SLO-aware but reactive (responds to violations after they happen)
- Gap: no existing system combines (a) proactive ML prediction with (b) overcommitment-aware routing and (c) adaptive safety nets
-->

### 2.4 The Golgi Paper in Detail

<!--
- System architecture: client → gateway → router → function instances (OC/Non-OC)
- Metrics collected (9): CPU utilization, memory utilization, memory bandwidth, network I/O (send/recv), disk I/O (read/write), inflight requests, LLC cache miss rate
- Mondrian Forest: online random forest variant that updates incrementally without full retraining
- Labeling: a request is labeled SLO-violating if its latency exceeds the P95 of the Non-OC baseline
- Routing: Power of Two Choices — sample 2 instances, pick the one with lower violation probability
- Vertical scaling: AIMD (Additive Increase, Multiplicative Decrease) on max_inflight per container
- Evaluation: 8 functions, 7 workers (c5.9xlarge, 36 vCPU each), Azure Function Trace replay
- Results: 42% memory reduction, 35% VM time reduction, <5% SLO violations
-->

### 2.5 Differences from the Original

<!--
- Table comparing: cluster size, instance types, ML model, metrics count, functions, workload, routing implementation
- Why each simplification is acceptable: preserves the core contribution (ML-guided OC routing)
- What we expect to differ in results: lower cost savings (smaller cluster, fewer functions), slightly higher violation rate (simpler model)
-->

---

## 3. System Design

<!-- Pages 5–6, ~1400 words -->

### 3.1 Architecture Overview

<!--
- Full system diagram (same as README but with more detail)
- Data flow: request arrives → router queries ML module → routing decision → function executes → response returned
- Control flow: metric collector → ML module (training data) → model update → router (prediction API)
- Separation of concerns: data plane (request handling) vs control plane (metric collection, ML training)
-->

### 3.2 Two-Instance Model

<!--
- Overcommitment formula: OC_allocation = α × claimed + (1 - α) × actual
- Why α = 0.3: paper's choice — gives 70% weight to actual usage, 30% safety margin
- Our resource configurations:
  - image-resize: Non-OC (512Mi, 1000m CPU) → OC (210Mi, 405m CPU)
  - db-query: Non-OC (256Mi, 500m) → OC (105Mi, 185m)
  - log-filter: Non-OC (256Mi, 500m) → OC (98Mi, 206m)
- How "actual usage" is measured: deploy Non-OC, send 100 requests, record P75 of cgroup memory.current
- Both variants run the same code — only Kubernetes resource requests/limits differ
-->

### 3.3 Metric Collector

<!--
- Deployment: DaemonSet (one pod per worker node)
- Collection interval: 500ms (paper uses 500ms)
- 7 metrics collected:
  1. CPU utilization: from cgroup cpu.stat (usage_usec / elapsed_usec)
  2. Memory utilization: from cgroup memory.current / memory.max
  3. Network bytes sent: from /proc/[pid]/net/dev or cgroup
  4. Network bytes received: same
  5. Disk I/O: from cgroup io.stat
  6. Inflight requests: from OpenFaaS gateway prometheus metric
  7. Invocation rate: from OpenFaaS gateway prometheus metric (rate of http_requests_total)
- cgroup v2 paths: /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/...
- Container discovery: list pods via K8s API → get container ID → find cgroup directory
- Data format: JSON metric snapshots pushed to ML module via HTTP POST
-->

### 3.4 ML Classifier

<!--
- Model: scikit-learn RandomForestClassifier
- Why Random Forest over Mondrian Forest:
  - Mondrian Forest requires custom implementation (not in scikit-learn)
  - Random Forest achieves comparable accuracy for this task (paper reports RF baseline)
  - Trade-off: we retrain periodically (every 5 min) instead of updating online
- Feature vector: 7 metrics normalized to [0, 1]
- Label: binary — 1 if the request's latency exceeded the SLO threshold, 0 otherwise
- Training data: collected during initial profiling + accumulated during runtime
- Hyperparameters: n_estimators=100, max_depth=10, class_weight='balanced'
- Output: P(SLO violation) — a probability between 0 and 1
- Model serving: Flask API on master node, responds to /predict endpoint in <5ms
-->

### 3.5 Router

<!--
- Entry point: all function invocations go through the router (runs on master node)
- Decision logic:
  1. Receive request for function F
  2. Query ML module: GET /predict?function=F&instance_type=oc → returns P(violation)
  3. If P(violation) < threshold (0.3): route to OC instance
  4. Else: route to Non-OC instance
- Power of Two Choices: if multiple OC replicas exist, sample 2, pick the one with lower P(violation)
- Implementation: Nginx as reverse proxy + Python sidecar that handles prediction logic
- Fallback: if ML module is unreachable, default to Non-OC (safe fallback)
-->

### 3.6 Vertical Scaling

<!--
- What it controls: max_inflight parameter on each OpenFaaS function (limits concurrent requests per container)
- Why it's needed: ML predictions aren't perfect — when they're wrong, OC instances get overloaded
- Algorithm: AIMD (Additive Increase, Multiplicative Decrease)
  - Every 30 seconds, check SLO violation rate for each function
  - If violation_rate > 5%: decrease max_inflight by 1 (multiplicative decrease to floor of 1)
  - If violation_rate < 2% for 3 consecutive checks: increase max_inflight by 1 (additive increase)
- Effect: fewer concurrent requests → less CPU/memory contention → lower latency → fewer violations
- Trade-off: lower concurrency means more containers needed (or higher queue wait times)
- This is the "safety net" — it corrects for systematic ML prediction errors
-->

---

## 4. Implementation

<!-- Pages 7–8, ~1500 words -->

### 4.1 Infrastructure Setup

<!--
- AWS setup: dedicated VPC (10.0.0.0/16), single subnet (10.0.1.0/24), Internet Gateway
- Security group: SSH (22), K8s API (6443), OpenFaaS (31112), NodePort range (30000-32767), inter-node (all traffic within VPC)
- EC2 instances: 1 t3.medium master, 3 t3.xlarge workers, 1 t3.medium loadgen
- Why t3.xlarge for workers: 4 vCPU, 16 GB RAM — enough to run multiple function containers with resource contention
- k3s deployment: lightweight Kubernetes (single binary, uses containerd, embeds etcd)
- Why k3s over kubeadm: faster setup (single command), lower memory overhead, same K8s API
- OpenFaaS deployment: Helm chart, NodePort service type, 5 components (gateway, prometheus, NATS, alertmanager, queue-worker)
- Networking: NodePort 31112 for gateway access, internal cluster DNS for service discovery
-->

### 4.2 Benchmark Functions

<!--
- Function 1: image-resize (Python)
  - What it does: generates random image → resizes using PIL LANCZOS filter
  - Why CPU-bound: LANCZOS resampling is compute-intensive (convolution kernel per pixel)
  - Configurable: image dimensions control workload intensity
  - Maps to paper's: classify-image, detect-object
  
- Function 2: db-query (Python)
  - What it does: connects to Redis → GET key → SET result → return
  - Why I/O-bound: latency dominated by network round-trip to Redis, minimal CPU
  - Redis deployment: single pod in openfaas-fn namespace, 64Mi request / 128Mi limit
  - Maps to paper's: query-vacancy, ingest-data
  
- Function 3: log-filter (Go)
  - What it does: generates 1000 synthetic log lines → regex filter (ERROR|WARN|CRITICAL) → anonymize IPs
  - Why mixed: regex matching is CPU-intensive, string allocation is memory-intensive
  - Written in Go: demonstrates language diversity, lower overhead than Python
  - Maps to paper's: filter-log, anonymize-log

- OC/Non-OC variants: same container image, different K8s resource requests/limits in stack.yml
-->

### 4.3 Metric Collection Implementation

<!--
- DaemonSet specification: one pod per worker, hostPID access, volume mount to /sys/fs/cgroup
- Container discovery:
  1. Query K8s API for pods in openfaas-fn namespace
  2. Extract container ID from pod status (containerd://abc123...)
  3. Map to cgroup path: /sys/fs/cgroup/kubepods.slice/.../cri-containerd-abc123.scope/
- Metric reading (cgroup v2):
  - CPU: parse cpu.stat → usage_usec, compute delta over 500ms interval
  - Memory: read memory.current (bytes), divide by memory.max for utilization
  - I/O: parse io.stat → rbytes, wbytes per device
- Prometheus scraping: query OpenFaaS's built-in Prometheus for http_requests_in_flight and invocation rate
- Push mechanism: HTTP POST to master every 500ms with JSON payload
- Error handling: if cgroup file disappears (container killed), skip and log
-->

### 4.4 ML Module Implementation

<!--
- Flask server running on master node (port 5001)
- Endpoints:
  - POST /metrics — receive metric snapshots from collectors (training data accumulation)
  - POST /label — receive latency labels from the router (matched to metric snapshots by timestamp)
  - GET /predict?function=X — return P(SLO violation) for function X's OC instance
  - GET /model/stats — return model accuracy, feature importance, training data size
- Training pipeline:
  1. Accumulate metric+label pairs in a pandas DataFrame (in memory)
  2. Every 5 minutes (or when 500 new samples arrive): retrain the RandomForest
  3. Replace the live model atomically (no downtime)
- Feature engineering: raw metrics + derived features (CPU delta, memory delta over last 3 intervals)
- Cold start problem: for the first 5 minutes (before enough training data), default to conservative routing (all Non-OC)
-->

### 4.5 Router Implementation

<!--
- Architecture: Nginx (layer 7 reverse proxy) + Python sidecar (prediction logic)
- Request flow:
  1. Client sends POST to /function/<name> on Nginx (port 8080)
  2. Nginx forwards to Python sidecar (via auth_request or upstream decision)
  3. Python sidecar: queries ML module → decides OC or Non-OC → returns upstream name
  4. Nginx proxies to the chosen OpenFaaS function variant
- Why Nginx: handles connection pooling, timeouts, retries — we only add routing logic
- Latency overhead: prediction adds ~3-5ms (acceptable for functions with 50-500ms latency)
- Metrics emission: router logs every decision (function, chosen_instance, ML_probability, actual_latency) for analysis
-->

### 4.6 Load Generator

<!--
- Tool: Locust (Python-based, distributed load testing)
- Runs on dedicated golgi-loadgen instance (avoids interfering with cluster)
- Workload profiles:
  1. Steady: constant 20 req/s per function for 10 minutes
  2. Bursty: alternating 5 req/s and 50 req/s in 30-second intervals
  3. Ramp: linear increase from 5 to 60 req/s over 10 minutes
- Request distribution: equal split across 3 functions (or configurable weights)
- Measurement: Locust records per-request latency, status code, timestamp
- Warm-up: first 60 seconds of each experiment discarded (allows model to stabilize)
-->

---

## 5. Experimental Setup

<!-- Pages 9–10, ~1400 words -->

### 5.1 Hardware and Software Configuration

<!--
- Table of all instance specs: type, vCPU, RAM, network bandwidth, EBS volume
- Software versions: Amazon Linux 2023, kernel 6.1.166, k3s v1.34.6, Python 3.9.25, scikit-learn 1.6.1, OpenFaaS (Helm revision 1), Locust 2.34.0
- Network: all instances in same subnet (10.0.1.0/24), <1ms inter-node latency
- Storage: gp3 EBS volumes (default 8 GB), sufficient for logs and temporary data
-->

### 5.2 Workload Description

<!--
- Three workload patterns defined in detail:
  - Steady-state: 20 RPS per function (60 RPS total), 10-minute duration
  - Bursty: alternating low (5 RPS) and high (50 RPS) phases, 30s each, 10-minute total
  - Gradual ramp: linear increase from 5 to 60 RPS over 10 minutes
- Request payloads:
  - image-resize: {"width": 1920, "height": 1080} (standard HD)
  - db-query: {"key": "user:<random_id>"} (uniform random keys)
  - log-filter: empty body (function generates synthetic logs internally)
- Why these patterns: steady tests baseline behavior, bursty tests adaptation speed, ramp tests scaling limits
-->

### 5.3 Baselines

<!--
- Baseline A — Non-OC Only: all requests go to Non-OC instances
  - Expected: best latency, highest cost, zero SLO violations
  - Purpose: establishes the latency SLO threshold and the cost ceiling
  
- Baseline B — OC Only: all requests go to OC instances
  - Expected: worst latency under load, lowest cost, highest SLO violations
  - Purpose: shows the cost floor and the latency penalty of blind overcommitment
  
- Baseline C — Random 50/50: each request randomly routed to OC or Non-OC with equal probability
  - Expected: middling performance — demonstrates that ML adds value over randomness
  - Purpose: controls for the "half the requests go to safe instances" effect
  
- Baseline D — Golgi (our system): ML-guided routing with vertical scaling
  - Expected: near Non-OC latency with near OC cost
  - Purpose: demonstrates the paper's core claim
-->

### 5.4 Metrics Measured

<!--
- Latency: P50, P95, P99 end-to-end (measured at load generator)
- SLO violation rate: % of requests exceeding the SLO threshold (P95 of Non-OC baseline)
- Memory cost: sum of (allocated_memory_MB × active_seconds) across all function containers
- CPU cost: sum of (allocated_cpu_millicores × active_seconds) across all function containers
- Throughput: successful requests per second
- Cold start count: number of container scale-up events during experiment
- Routing decisions: % of requests sent to OC vs Non-OC over time
- ML model accuracy: classification accuracy, precision, recall measured on held-out data
-->

### 5.5 SLO Definition

<!--
- Methodology: deploy Non-OC function, send 200 requests with no concurrent load, record latencies
- SLO threshold = P95 latency of this baseline measurement
- Per-function SLO values: (to be filled after Step 1.4)
  - SLO_image_resize = ??? ms
  - SLO_db_query = ??? ms
  - SLO_log_filter = ??? ms
- A request "violates" the SLO if its latency exceeds this threshold
- This matches the paper's methodology (Section 5.1)
-->

### 5.6 Repeatability

<!--
- Each experiment configuration run 3 times
- Results reported as mean ± standard deviation across runs
- Between runs: restart all function pods (fresh containers), clear ML model state
- Warm-up: first 60 seconds of each run discarded from measurement
- Total experiment time: 4 baselines × 3 workloads × 3 runs × 10 min = 6 hours of experiments
- All raw data (latency logs, metric snapshots, routing decisions) saved for post-hoc analysis
-->

---

## 6. Results and Analysis

<!-- Pages 10–12, ~2000 words -->

### 6.1 Overall Cost Reduction

<!--
- Bar chart: memory cost (MB-seconds) for each baseline across all functions
- Table: % cost reduction of Golgi vs Non-OC Only
- Expected: 25-35% reduction (paper achieved 42%)
- Analysis: where does the savings come from? (proportion of requests successfully routed to OC)
- Breakdown by function: which function benefits most from overcommitment?
-->

### 6.2 Latency Distribution

<!--
- CDF plots: one per function, all 4 baselines overlaid
- Highlight P95 threshold (SLO line) on each plot
- Key observations:
  - Non-OC: tight distribution, well below SLO
  - OC Only: long tail extending past SLO
  - Random: bimodal (mix of OC and Non-OC latencies)
  - Golgi: similar to Non-OC for most requests, small tail from OC misrouting
-->

### 6.3 SLO Violation Rate

<!--
- Time-series: violation rate (10-second rolling window) over experiment duration
- Table: final violation rates per function per baseline
- Expected:
  - Non-OC: 0% (by definition, since SLO is set from this baseline)
  - OC Only: 15-30%
  - Random: 8-15%
  - Golgi: <10% (our target)
- Analysis: when do violations cluster? (during burst phases? at ramp peak?)
-->

### 6.4 Classifier Performance

<!--
- Accuracy, precision, recall, F1 score
- Confusion matrix: TP (correctly predicted violation), FP (predicted violation but was fine), FN (missed violation), TN
- FP rate matters: too many false positives → unnecessary Non-OC routing → reduced cost savings
- FN rate matters: missed violations → SLO breaches
- Feature importance: bar chart ranking 7 metrics by Random Forest importance score
- Expected: CPU utilization and inflight_requests will be most predictive
- Discussion: does the model improve over time as more training data arrives?
-->

### 6.5 Vertical Scaling Effectiveness

<!--
- Compare: Golgi without vertical scaling vs Golgi with vertical scaling
- Show: violation rate time-series for both
- Show: max_inflight trajectory over time (how it adapts)
- Expected: vertical scaling reduces violation rate by 2-5 percentage points
- Analysis: how quickly does it react? (latency of the AIMD control loop)
-->

### 6.6 Impact of Workload Pattern

<!--
- Compare results across steady, bursty, ramp workloads
- Which pattern is hardest for the ML model? (likely bursty — sudden transitions)
- Which pattern shows most cost savings? (likely steady — stable predictions)
- Discussion: the trade-off between prediction confidence and routing aggressiveness
-->

### 6.7 Comparison with Paper's Results

<!--
- Side-by-side table: paper's numbers vs our numbers for each metric
- Expected gaps and explanations:
  - Lower cost savings: fewer functions (less opportunity for statistical multiplexing)
  - Higher violation rate: Random Forest vs Mondrian Forest (no online adaptation)
  - Different absolute latencies: t3.xlarge (4 vCPU) vs c5.9xlarge (36 vCPU)
- What we can and cannot conclude from the comparison
-->

---

## 7. Discussion

<!-- Pages 12–13, ~1400 words -->

### 7.1 Key Findings

<!--
- Finding 1: ML-guided routing does reduce cost while maintaining SLOs (validates paper's core claim)
- Finding 2: [which metric is most predictive — likely CPU util or inflight requests]
- Finding 3: Vertical scaling provides meaningful safety net (X% violation reduction)
- Finding 4: The system works even with a simpler ML model (Random Forest vs Mondrian Forest)
- Finding 5: [any surprising result or unexpected behavior]
-->

### 7.2 Limitations of Our Replication

<!--
- Smaller cluster (3 workers vs 7): less resource contention diversity, fewer scheduling options
- Fewer functions (3 vs 8): less statistical multiplexing, simpler interaction patterns
- Random Forest vs Mondrian Forest: no online learning, 5-minute staleness window
- t3.xlarge vs c5.9xlarge: burstable instances have CPU credits — may affect contention patterns differently
- Simplified workload: synthetic traces lack the autocorrelation and diurnal patterns of real Azure traces
- Single AZ: no cross-AZ latency considerations
- No hardware perf counters: skipped LLC cache miss rate and memory bandwidth (2 of 9 metrics)
-->

### 7.3 Threats to Validity

<!--
- Internal validity:
  - Implementation bugs in metric collection (timing issues, cgroup path discovery)
  - Measurement noise (network jitter, EBS latency spikes, t3 CPU throttling)
  - Model training instability (random seed sensitivity)
  
- External validity:
  - Different hardware (t3 vs c5 — different CPU microarchitecture, memory bandwidth)
  - Different Kubernetes version (k3s v1.34 vs likely K8s 1.24-1.26 in paper)
  - Different OS (Amazon Linux 2023 / cgroup v2 vs likely Ubuntu / cgroup v1)
  - Different OpenFaaS version
  
- Construct validity:
  - Our SLO definition matches the paper's methodology, but absolute latency values differ
  - Our "cost" metric (MB-seconds) may not perfectly reflect real billing
  - Our simplified functions may not exhibit the same resource patterns as the paper's real-world functions
-->

### 7.4 Lessons Learned

<!--
- cgroup v2 vs v1: different file paths, unified hierarchy simplifies some things but documentation is sparse
- k3s quirks: KUBECONFIG not set by default for Helm, svclb instead of MetalLB, traefik conflicts
- OpenFaaS scaling: need to disable auto-scaling to maintain our fixed OC/Non-OC instances
- ML model cold start: system is blind for the first few minutes — need a safe default
- Monitoring overhead: 500ms metric collection adds measurable CPU usage on workers
- Container discovery: matching K8s pod → containerd container → cgroup path is fragile
-->

### 7.5 Potential Improvements

<!--
- Online learning: implement Mondrian Forest for true online adaptation (no retraining delay)
- More functions: add GPU-bound (inference), memory-bound (in-memory sort), and chained functions
- Larger cluster: more workers would enable better statistical multiplexing
- Real traces: replay actual Azure Function Trace with realistic arrival patterns
- Multi-model: different classifiers per function (specialized vs general)
- Cost-aware routing: factor in instance cost explicitly, not just violation probability
- Horizontal scaling integration: combine with OpenFaaS auto-scaler for dynamic replica count
-->

---

## 8. Conclusion

<!-- Page 14, ~700 words -->

<!--
Paragraph 1: Restate the problem and Golgi's solution (2-3 sentences)
Paragraph 2: What we built — end-to-end system on AWS with k3s, OpenFaaS, 3 functions, ML classifier, router, vertical scaling
Paragraph 3: Key quantitative results:
  - Achieved X% memory cost reduction (vs paper's 42%)
  - Maintained <Y% SLO violation rate (vs paper's <5%)
  - Vertical scaling reduced violations by Z percentage points
Paragraph 4: Which paper claims are validated:
  - Claim 1 (cost reduction via ML routing): validated / partially validated
  - Claim 2 (SLO maintenance): validated / partially validated
  - Claim 3 (vertical scaling as safety net): validated
Paragraph 5: Broader significance:
  - ML-guided resource management is practical for serverless platforms
  - The two-instance model is a sound architectural pattern
  - Even simplified implementations achieve meaningful savings
Paragraph 6: Future work (1-2 sentences pointing to Section 7.5)
-->

---

## 9. References

<!-- Page 15 -->

1. Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing. *Proceedings of the ACM Symposium on Cloud Computing (SoCC '23)*. https://doi.org/10.1145/3620678.3624645

2. Shahrad, M., Fung, R., Gruber, N., Goiri, I., Chaudhry, G., Cooke, J., Laureano, E., Tresness, C., Russinovich, M., & Bianchini, R. (2020). Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider. *USENIX ATC '20*. https://www.usenix.org/conference/atc20/presentation/shahrad

3. Lakshminarayanan, B., Roy, D. M., & Teh, Y. W. (2014). Mondrian Forests: Efficient Online Random Forests. *Advances in Neural Information Processing Systems (NeurIPS) 27*. https://arxiv.org/abs/1406.2673

4. Ambati, P., Goiri, I., Frujeri, F., Gun, A., Wang, K., Dolan, B., Corell, B., Pasupuleti, S., Moscibroda, T., Elnikety, S., Fontoura, M., & Bianchini, R. (2020). Providing SLOs for Resource-Harvesting VMs in Cloud Platforms. *14th USENIX Symposium on Operating Systems Design and Implementation (OSDI '20)*. https://www.usenix.org/conference/osdi20/presentation/ambati

5. Wen, J., Chen, Z., Jin, Y., & Liu, H. (2021). Kraken: Adaptive Container Provisioning for Deploying Dynamic DAGs in Serverless Platforms. *ACM SoCC '21*. https://doi.org/10.1145/3472883.3486992

6. Suresh, A., Somashekar, G., Varadarajan, A., Kakarla, V.R., Upadhyay, H.R., & Gandhi, A. (2020). ENSURE: Efficient Scheduling and Autonomous Resource Management in Serverless Environments. *IEEE ACSOS 2020*. https://doi.org/10.1109/ACSOS49614.2020.00036

7. k3s — Lightweight Kubernetes. https://k3s.io/

8. OpenFaaS — Serverless Functions Made Simple. https://www.openfaas.com/

9. Locust — An Open Source Load Testing Tool. https://locust.io/

10. Azure Functions Trace 2019. https://github.com/Azure/AzurePublicDataset

11. Pedregosa, F., Varoquaux, G., Gramfort, A., Michel, V., Thirion, B., Grisel, O., Blondel, M., Prettenhofer, P., Weiss, R., Dubourg, V., Vanderplas, J., Passos, A., Cournapeau, D., Brucher, M., Perrot, M., & Duchesnay, E. (2011). Scikit-learn: Machine Learning in Python. *Journal of Machine Learning Research, 12*, 2825–2830. https://jmlr.org/papers/v12/pedregosa11a.html

12. Linux Kernel cgroup v2 Documentation. https://docs.kernel.org/admin-guide/cgroup-v2.html

---

## Appendix A: Resource Configuration Tables

<!-- Complete resource allocations for all functions, OC formula calculations -->

---

## Appendix B: Reproducibility Commands

<!-- Key CLI commands for someone replicating our replication -->

---

## Appendix C: Raw Experimental Data

<!-- Tables of per-run measurements, or pointer to data files in the repo -->
