# Paper-Code Audit: Golgi (ACM SoCC 2023)

> **Paper:** Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing
> **Authors:** Suyi Li, Wei Wang (HKUST), Jun Yang, Guangzhen Chen, Daohe Lu (WeBank)
> **Venue:** ACM SoCC 2023 — Best Paper Award
> **DOI:** https://doi.org/10.1145/3620678.3624645
> **PDF:** https://www.cse.ust.hk/~weiwa/papers/golgi-socc23.pdf

---

## 1. Code Availability Verdict

### **No public implementation exists.**

The paper does not provide a code repository link. Exhaustive searches confirm:

| Search Target | Result | URL |
|---|---|---|
| Golgi source code (GitHub) | **NOT FOUND** | Searched: "golgi serverless", "golgi scheduling", "golgi openfaas", "golgi faas" |
| Author repos (Suyi Li) | **NOT FOUND** | No public GitHub profile with relevant code |
| Author repos (Wei Wang) | **NOT FOUND** | [github.com/weiwangtool](https://github.com/weiwangtool) — only 2 unrelated repos |
| Owl source code [37] (predecessor, same group) | **NOT FOUND** | Same HKUST group; no public release |
| Owl benchmark applications [37] | **NOT FOUND** | 8 benchmark apps described in Table 1 but not published |

**Impact:** The entire system — scheduler, ML module, metric collector, watchdog modifications, routing logic — must be reimplemented from the paper description alone. The 8 benchmark applications from Owl must also be reconstructed.

---

## 2. Dependency Availability

### 2.1 Available Dependencies

| Dependency | Status | URL | Notes |
|---|---|---|---|
| **Azure Function Trace** [34] | **AVAILABLE** | [github.com/Azure/AzurePublicDataset](https://github.com/Azure/AzurePublicDataset) | 14-day trace from July 2019. CC-BY license. CSV format. Paper uses days 10 (weekday) and 13 (weekend). |
| **Mondrian Forest (Python)** | **AVAILABLE** | [github.com/scikit-garden/scikit-garden](https://github.com/scikit-garden/scikit-garden) | `MondrianForestClassifier` with `partial_fit()` for online learning. **Caveat:** Last release May 2017 (v0.1). May need patching for modern sklearn. Alternative: [github.com/balajiln/mondrianforest](https://github.com/balajiln/mondrianforest) (original NeurIPS 2014 code). |
| **OpenFaaS faas-netes** | **AVAILABLE** | [github.com/openfaas/faas-netes](https://github.com/openfaas/faas-netes) | Go codebase. Implements provider interface. Paper says "We plug our routing policy in OpenFaaS's faas-netes module" (S7). Requires forking and modifying Go code — not a plugin system. |
| **OpenFaaS of-watchdog** | **PARTIALLY AVAILABLE** | [github.com/openfaas/of-watchdog](https://github.com/openfaas/of-watchdog) | Has static `max_inflight` env var (PR #54). **No runtime concurrency adjustment.** Paper's vertical scaling (S5) requires modifying the watchdog to accept dynamic concurrency changes. Has existing `http_requests_in_flight` Prometheus gauge for inflight tracking. |
| **Kubernetes Scheduling Framework** | **AVAILABLE** | [kubernetes.io/docs](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/) | Paper uses "customized plugin in the Kubernetes scheduler" (S7) for first-fit placement. K8s scheduling framework supports custom plugins. |

### 2.2 Unavailable Dependencies

| Dependency | Status | Impact |
|---|---|---|
| **Owl benchmark apps** (Table 1) | **NOT PUBLIC** | Must reconstruct 8 apps: GMI, SP, DA, ID, CI, DO, AL, FL from descriptions in Table 1. Languages: Python, Go, JavaScript, C++, Rust. External deps: Object Store, Key-Value Store, Database, TF Serving, Message Queue. |
| **Owl collocation profiles** [37] | **NOT PUBLIC** | Not needed for Golgi (Golgi replaces this with ML), but useful for comparison. |

---

## 3. Claim-vs-Implementation Audit

### C1: 9 Metrics from cgroup + /proc/net + perf stat (Section 3.2)

| Metric | Source Claimed | Verification | Verdict |
|---|---|---|---|
| CPU utilization | cgroup pseudo-files | cgroup v1: `/sys/fs/cgroup/cpu,cpuacct/.../cpuacct.usage` and `cpuacct.stat`. cgroup v2: `/sys/fs/cgroup/.../cpu.stat` (`usage_usec`). Compute utilization as delta(usage) / delta(wall_time) / cpu_quota. | **VERIFIED** |
| Memory utilization | cgroup pseudo-files | cgroup v1: `/sys/fs/cgroup/memory/.../memory.usage_in_bytes` and `memory.limit_in_bytes`. cgroup v2: `memory.current` / `memory.max`. | **VERIFIED** |
| Inflight requests | Atomic integer counter in watchdog | of-watchdog already has `http_requests_in_flight` Prometheus gauge using atomic ops. Paper's approach is consistent. | **VERIFIED** |
| NetRx, NetTx (container) | /proc/net/ directory | `/proc/<container-pid>/net/dev` within container's network namespace gives per-interface byte counts. | **PARTIALLY VERIFIED** — paper says "/proc/net/" generically without specifying `/proc/net/dev` or namespace handling |
| NodeNetRx, NodeNetTx | /proc/net/ directory | Host-level `/proc/net/dev` (or `/proc/1/net/dev`) gives node-wide stats. | **PARTIALLY VERIFIED** — same imprecision |
| LLCM (container) | Linux perf stat | `perf stat -e LLC-load-misses -G <cgroup>` or `-p <pid>` for per-container. Requires `CAP_SYS_ADMIN` or `CAP_PERFMON` (Linux 5.8+), or `perf_event_paranoid <= 1`. | **PARTIALLY VERIFIED** — feasible but paper omits privilege requirements |
| NodeLLCM | Linux perf stat | `perf stat -a -e LLC-load-misses` for system-wide. Requires `perf_event_paranoid <= 0`. | **PARTIALLY VERIFIED** — same privilege omission |

**K8s pod-to-cgroup mapping:**
- cgroup v1: `/sys/fs/cgroup/cpu/kubepods/[burstable|besteffort]/<pod-uid>/<container-id>/`
- cgroup v2: `/sys/fs/cgroup/kubepods.slice/kubepods-<qos>.slice/cri-containerd-<container-id>.scope/`

**Missing detail:** The paper's "node metric monitor" (S4.1) likely runs as a privileged DaemonSet with `CAP_SYS_ADMIN` to collect LLC misses and node-level network stats. This architectural detail is implied but never stated.

---

### C2: Mondrian Forest with Online Stratified Sampling — Algorithm 1 (Section 4.4)

**Paper claim:** Algorithm 1 implements online stratified reservoir sampling maintaining balanced N/2 positive + N/2 negative batches.

**Verification:**

- The algorithm is a standard reservoir sampling (Vitter 1985, ref [39]) applied independently to two class-stratified streams. The pseudocode is correct.
- Batch size N is not specified in the paper. This is a missing hyperparameter.
- scikit-garden's `MondrianForestClassifier.partial_fit()` accepts batches — compatible with this approach.
- **Key gap:** The paper says "less than 50 model updates" for bootstrapping (S4.4, Fig 9 left). But if positive samples are rare (10:1 ratio), collecting N/2 positive samples requires ~5N real invocations per batch. With 50 batches, that's ~250N total invocations. **Wall-clock bootstrapping time is never reported.**

**Verdict:** Algorithm is **CORRECT** but batch size N and real-world bootstrapping time are **UNSPECIFIED**.

---

### C3: Label Tag Update Every 82.2ms for Group Size 100 (Section 4.3)

**Paper claim:** "Our measurements show that the Label tag is updated every 82.2ms, when the group size is 100."

**Verification:**

- The relay collects 9 metrics from 100 instances via gRPC, sends batch inference, caches results.
- 82.2ms for 100 instances = ~0.82ms per instance (collection + inference + cache write).
- gRPC round-trip on localhost is ~0.1-0.5ms. Batch inference on 100x9 matrix with Mondrian Forest: ~10-50ms (sklearn RF on 100 samples with 9 features is sub-millisecond; MF is similar).
- **Plausible** if relay, ML module, and instances are co-located on the same node or within the same cluster network.

**Verdict: PLAUSIBLE** but not independently reproducible without the relay implementation.

---

### C4: Vertical Scaling via Atomic Concurrency Counter (Section 5)

**Paper claim:** "We scale an instance's maximum request concurrency... the scaling up/down operates atomically."

**Verification:**

- of-watchdog's `max_inflight` is set via environment variable at startup — **NOT modifiable at runtime**.
- The paper says they "implement the watchdog by extending OpenFaaS's of-watchdog module" (S7).
- Atomic integer modification in Go: `atomic.AddInt32(&maxConcurrency, -1)` — trivial to implement.
- No container restart needed — correct, since it's just changing an in-memory variable.

**Verdict: VERIFIED in principle** — requires a ~10-line modification to of-watchdog to expose `max_inflight` as a mutable atomic variable instead of a startup-time env var. The paper is correct that this is simple and restartless.

---

### C5: First-Fit Placement via K8s Scheduler Plugin (Section 7)

**Paper claim:** "We implement a first-fit container placement strategy by adding a customized plugin in the Kubernetes scheduler."

**Verification:**

- K8s Scheduling Framework supports custom plugins at Filter, Score, Reserve, and Bind extension points.
- First-fit bin packing can be implemented as a Score plugin that prioritizes nodes with existing function instances.
- This is a well-documented pattern in the K8s ecosystem.

**Verdict: VERIFIED** — standard K8s scheduling framework capability.

---

### C6: 42% Memory Reduction, 35% VM Time Reduction (Section 8.2)

**Paper claim:** "Golgi achieves a 42% reduction in memory footprint and a 35% reduction in VM time."

**Cross-check with Figure 7 (left):**
- Golgi relative memory cost: 0.58 → 1.0 - 0.58 = 42% reduction. **Matches.**
- Golgi relative VM cost: 0.65 → 1.0 - 0.65 = 35% reduction. **Matches.**
- BASE absolute: ~742 TB*Sec memory footprint, ~18,000 sec VM time.
- OC (naive): 43% memory / 44% VM — but violates SLO (up to 183% P95 increase).

**Concerns:**
1. **7-node cluster** (c5.9xlarge, 36 vCPU, 72GB each) — small scale.
2. **8 benchmark functions** — limited diversity.
3. **Trace scaling** from Azure day-long to 1 hour — interference patterns may not preserve.
4. **5 repetitions** — minimal statistical rigor; no error bars or confidence intervals reported.
5. **Comparison gap:** Owl [37] is absent from baselines despite being the most directly comparable work.

**Verdict: NUMBERS MATCH** the paper's own figures. **External validity is limited** by small cluster and narrow benchmark set.

---

### C7: F1 Scores 0.70-0.84 for Online MF (Section 8.4)

**Paper claim:** "Across all functions, the F1 scores range from 0.70 to 0.84, rivaling the performance of its batch counterpart from sklearn: 0.71 to 0.84."

**Analysis:**
- Online MF nearly matches batch RF (off by 0.01 on the low end). This is consistent with the theoretical result in [18] that MF converges to batch RF performance.
- Balanced F1 = 0.78 vs imbalanced F1 = 0.26 (Fig 9 left) — demonstrates stratified sampling is critical.
- **Missing:** Per-function F1 breakdown (only range given), no precision/recall tradeoff analysis, no error bars across multiple training runs.
- **Missing:** The neural network comparison ("F1 scores from 0.0 to 0.73") is described without any hyperparameter details. Was it fairly tuned?

**Verdict: CLAIMS ARE INTERNALLY CONSISTENT** but lacking detail for independent reproduction.

---

### C8: Handles 5139 RPS with <20ms Routing Latency (Section 8.6)

**Paper claim:** "During a request spike of 6000 RPS, Golgi can make a routing decision within 20ms."

**Cross-check with Figure 10:**
- At 6000 RPS: routing latency ~6-7ms, total end-to-end ~25ms (including execution).
- At 1000 RPS: routing latency ~4ms.
- The 20ms budget comes from AWS Lambda's requirement (ref [7]).

**Plausibility:** Tag lookup is O(1) (cached label read). Power-of-two-choices is O(1). The routing path is: read Safe tag → pick 2 random instances → read their Label tags → apply MRU. All cached reads — sub-millisecond per request is expected.

**Verdict: PLAUSIBLE** — the off-path inference design makes routing O(1) in cached metadata.

---

### C9: 30% Savings in Production Cluster (Section 8.7)

**Paper claim:** "Golgi is effective in a production deployment, reducing 30% memory usage under performance SLOs."

**Critical assessment:**
- **Cluster size:** "small production cluster" — no specifics given (node count, CPU/memory).
- **Functions:** Only 2 applications (executor monitor, log processing) — both WeBank internal.
- **Comparison:** Only against BASE (non-OC). No comparison against OC, Orion, or E&E in production.
- **Duration:** Not specified.
- **Variance:** No statistical analysis, no error bars, no confidence intervals.
- **Verification:** No independent verification possible — internal WeBank deployment.
- **Coexisting workloads:** "function instances coexist with other data analytics tasks" — good for realism, but makes it harder to attribute savings specifically to Golgi.

**Verdict: PROMISING BUT WEAK** — a case study, not a rigorous production evaluation. Treat as preliminary evidence.

---

## 4. Unjustified Hyperparameters

The following hyperparameters are used throughout the paper without ablation studies:

| Parameter | Value | Where | Justification Given |
|---|---|---|---|
| Overcommitment ratio (alpha) | 0.3 | S2.3 | "Inherited from Owl [37]" — no Golgi-specific tuning |
| Stratified sampling batch size (N) | 16 (only in one experiment) | S8.4 | Mentioned only for the label imbalance experiment; unclear if used system-wide |
| Mondrian Forest lifetime (lambda) | Not stated | S4.4 | Critical hyperparameter for tree depth — never mentioned |
| Number of Mondrian Trees | Not stated | S4.4 | Batch validation uses "100 decision trees" (S3.3) but online MF ensemble size unspecified |
| Vertical scaling down threshold | 0.05 | S5 | No justification |
| Vertical scaling up threshold | 0.03 | S5 | No justification |
| Monitoring window size (W) | Not stated | S5 | Controls responsiveness vs stability — never specified |
| Relay group size | 100 | S4.3 | Chosen to match "average RPS of popular functions" — but this is a deployment-specific number |
| Power-of-two-choices sample size | 2 (implied) | S4.2 | Standard algorithm — justified by [25] |
| Initial concurrency limit | 4 | S8.1 | "Set according to [37]" — no Golgi-specific tuning |

**Impact:** 6 of 10 key hyperparameters are either inherited from Owl without re-validation or completely unspecified. This makes exact reproduction impossible without trial-and-error tuning.

---

## 5. Missing Implementation Details

| Detail | Section | Impact on Reproduction |
|---|---|---|
| How the Safe flag transition works (1→0→1) | S4.1-4.2 | "ML module monitors requests' latencies to set Safe accordingly" — over what window? What threshold? Rolling P95 or fixed window? |
| gRPC interface between relay and ML model | S7 | Proto definitions not provided. Must design from scratch. |
| How metric collection daemon maps container IDs to cgroups | S3.2, S4.1 | Critical for cgroup scraping. Paper says nothing about this mapping. |
| How OC resource configurations are calculated per function | S2.3 | Uses alpha=0.3 formula, but "actual usage" is measured over what period? At deployment time? Rolling average? |
| How the ML module handles function code updates | — | Not discussed. Model may be invalid after function update. |
| Cold start interaction | — | Entirely absent. Cold starts are a major serverless latency component. |
| Model size growth over time | — | Mondrian Trees grow with data. Is there pruning? Memory bounds? |
| Multi-function ML module management | S6 | "For each type of user function, we deploy an ML module." Lifecycle management (creation, deletion, resource overhead) is handwaved. |

---

## 6. Reproduction Risk Assessment

### Risk Matrix for AWS Replication

| Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|
| scikit-garden incompatible with modern Python/sklearn | Medium | High | Pin Python 3.6 + sklearn 0.19, or port MF code manually |
| perf stat unavailable inside containers | High | High | Run as privileged DaemonSet, or skip LLC metrics (use 7 of 9) |
| cgroup v2 on modern EC2 AMIs | Medium | High | Amazon Linux 2023 uses cgroup v2; metric paths differ from paper's likely cgroup v1 environment |
| of-watchdog modification complexity | Medium | Medium | ~10-line change to make max_inflight mutable; well-scoped |
| faas-netes routing modification | High | Medium | Requires Go expertise; need to intercept request routing path |
| Benchmark app reconstruction | High | High | 8 apps in 5 languages with external deps; significant effort |
| Hyperparameter tuning without guidance | Medium | High | 6+ unspecified params; expect weeks of tuning |
| Azure trace scaling methodology unclear | Medium | Medium | Paper doesn't detail how day→hour scaling preserves patterns |

### Feasibility Summary

| Component | Difficulty | Estimated Effort |
|---|---|---|
| Infrastructure (K8s + OpenFaaS on EC2) | Medium | 2-3 days |
| Benchmark functions (2-3 simplified) | Medium | 3-5 days |
| Metric collector (7 metrics, skip LLC) | Hard | 5-7 days |
| ML module (RF with stratified sampling) | Medium | 3-4 days |
| Router (middleware on OpenFaaS) | Hard | 5-7 days |
| Vertical scaling (of-watchdog mod) | Easy-Medium | 1-2 days |
| End-to-end integration + testing | Hard | 5-7 days |
| **Total (simplified replication)** | | **~25-35 days** |

---

## 7. Final Audit Verdict

### Scorecard

| Dimension | Score | Notes |
|---|---|---|
| **Code availability** | 0/5 | No code released. No artifacts. |
| **Dependency availability** | 3/5 | Azure trace + Mondrian Forest libs + OpenFaaS available. Benchmark apps missing. |
| **Claim correctness** | 4/5 | All technical mechanisms are sound. Numbers internally consistent. |
| **Reproducibility** | 1/5 | 6+ unspecified hyperparameters, missing implementation details, no public code. |
| **Evaluation rigor** | 2/5 | Small cluster (7 nodes), 8 functions, 5 runs, no error bars, missing Owl baseline, weak production eval. |

### Key Takeaways

1. **The science is sound.** The 9-metric approach, Mondrian Forest choice, stratified sampling, conservative routing, and vertical scaling are all technically valid and well-motivated.

2. **The engineering is opaque.** Critical implementation details (cgroup mapping, gRPC interfaces, Safe flag logic, hyperparameter choices) are missing or underspecified.

3. **Reproduction is feasible but expensive.** A simplified replication (2-3 functions, 7 metrics, sklearn RF instead of MF) is achievable in ~4-5 weeks. A full replication matching the paper's setup would take significantly longer.

4. **The results should be treated as directionally correct but not precisely reproducible.** The 42% cost saving is likely in the right ballpark for the specific workload tested, but expect variance with different functions, traces, or cluster sizes.

5. **For the CSL7510 project:** This audit informed the decision to focus on empirical characterization of the overcommitment hypothesis rather than a full system replication. The profile-dependent degradation behavior is the testable foundation — validating it is a standalone contribution.

---

## Sources

- **Paper PDF:** https://www.cse.ust.hk/~weiwa/papers/golgi-socc23.pdf
- **Paper DOI:** https://doi.org/10.1145/3620678.3624645
- **Azure Function Trace:** https://github.com/Azure/AzurePublicDataset
- **scikit-garden (Mondrian Forest):** https://github.com/scikit-garden/scikit-garden
- **Original Mondrian Forest code:** https://github.com/balajiln/mondrianforest
- **OpenFaaS faas-netes:** https://github.com/openfaas/faas-netes
- **OpenFaaS of-watchdog:** https://github.com/openfaas/of-watchdog
- **Owl paper (predecessor):** https://cse.hkust.edu.hk/~weiwa/papers/owl-socc2022.pdf
- **Owl tech report:** https://www.cse.ust.hk/~weiwa/papers/owl-techreport.pdf
- **K8s Scheduling Framework:** https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/
