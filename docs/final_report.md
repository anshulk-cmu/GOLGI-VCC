# Characterizing the Impact of Resource Overcommitment on Serverless Function Latency Across Workload Profiles

**Course:** CSL7510 — Cloud Computing  
**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)  
**Programme:** M.Tech Artificial Intelligence  
**Institution:** Indian Institute of Technology Jodhpur  
**Date:** April 2026

---

## Abstract

<!-- ~200 words. Write after all experiments are complete. -->
<!-- Structure: Problem (serverless resource waste, overcommitment risk) → Untested assumption (profile-dependent degradation) → What we did (empirical characterization across 3 profiles, 4 experiments) → Key results (degradation curves, concurrency amplification, tail latency, CFS boundary effects) → One-line conclusion (profile-dependent degradation confirmed and mechanistically explained) -->

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background and Related Work](#2-background-and-related-work)
3. [Experimental Design](#3-experimental-design)
4. [Implementation](#4-implementation)
5. [Baseline Characterization](#5-baseline-characterization)
6. [Results and Analysis](#6-results-and-analysis)
7. [Discussion](#7-discussion)
8. [Conclusion](#8-conclusion)
9. [References](#9-references)

---

## 1. Introduction

### 1.1 The Serverless Resource Problem

Serverless computing, often called Function-as-a-Service (FaaS), lets developers deploy individual functions without managing servers. The cloud provider handles scaling, container lifecycle, and infrastructure. Users write a function, push it, and pay per invocation. AWS Lambda, Azure Functions, and Google Cloud Functions process millions of invocations per day on this model.

The pricing and scheduling model works like this: a user declares how much memory their function needs (say, 512 MB), and the platform allocates CPU proportionally. The platform then reserves those resources on a physical machine for the lifetime of each invocation. This reservation is a guarantee. If the user asks for 512 MB, the platform sets a hard cgroup limit at 512 MB, and no other container can touch that memory.

The problem is that users are terrible at estimating what they actually need. Shahrad et al. [2] analyzed production traces from Azure Functions and found that functions use roughly 25% of their reserved resources on average. The median memory consumption was 29 MB for functions configured with 512 MB or more. Three-quarters of all reserved resources sit idle.

This waste compounds at scale. A cloud provider running a million concurrent function instances, with each instance holding resources it will never touch, is leaving enormous capacity on the table. Users, meanwhile, pay for memory they never use. The fundamental tension is between safety (guaranteeing reserved resources so functions never get starved) and efficiency (not wasting 75% of a data center's capacity on empty reservations).

### 1.2 Why Overcommitment Alone Fails

The obvious fix is overcommitment: allocate less physical memory and CPU than the sum of all reservations, and bet that not everyone will spike at once. This is standard practice in virtualization. VMware ESXi routinely overcommits memory by 2-4x using techniques like ballooning, transparent page sharing, and swap. It works because VM workloads are relatively stable and long-lived, giving the hypervisor time to react when pressure rises.

Serverless functions are a different animal. They are short-lived (milliseconds to seconds), bursty (a function might go from zero to a thousand concurrent invocations in seconds), and densely co-located (dozens of different functions from different users share the same physical host). When a provider blindly squeezes resource allocations across the board, multiple co-located functions can spike simultaneously. They compete for shared CPU cycles, memory bandwidth, and last-level cache. The result is contention, and contention means latency.

Li et al. [1] measured this directly. Blind overcommitment on their test cluster caused P95 latency to increase by up to 183%. For a function serving an API endpoint with a 200ms SLO, that kind of degradation is a contract violation. Users choose serverless precisely because they don't want to think about infrastructure. If the platform silently makes their functions 2.8x slower during peak load, the abstraction has broken its promise.

The challenge, then, is not whether to overcommit, but how to overcommit intelligently. Understanding which functions tolerate reduced resources and which do not is a prerequisite for any safe overcommitment strategy.

### 1.3 The Golgi Hypothesis

Golgi, proposed by Li et al. [1] at ACM SoCC 2023 (where it won the Best Paper award), addresses this challenge with an ML-guided routing system. The full system includes a two-instance model (Non-OC and OC variants of each function), a Mondrian Forest classifier that predicts SLO violations from real-time cgroup metrics, a request router that directs traffic to OC or Non-OC instances based on predictions, and an AIMD vertical scaler that adjusts concurrency limits. On seven c5.9xlarge workers running eight benchmark functions under Azure Function trace replay, Golgi achieved 42% memory cost reduction while keeping SLO violations below 5%.

But the Golgi system is built on a foundational hypothesis that is assumed rather than independently validated:

> **Different function workload profiles respond differently to resource overcommitment. CPU-bound functions degrade proportionally to CPU reduction, I/O-bound functions are resilient, and mixed functions exhibit non-linear degradation from Linux CFS scheduler interactions.**

The Golgi paper's evaluation focuses on end-to-end system metrics — cost reduction percentages and SLO violation rates. These results demonstrate that the full system works, but they do not isolate and characterize the underlying profile-dependent degradation behavior that the system relies upon. The hypothesis is the foundation on which the ML classifier, the routing logic, and the two-instance architecture all rest. If the hypothesis is wrong — if all profiles degrade similarly, or if the degradation is not predictable — the entire Golgi architecture loses its rationale.

### 1.4 Motivation for This Study

We characterize how Linux CFS quota enforcement creates profile-dependent latency degradation under container resource overcommitment — the phenomenon that motivates profile-aware scheduling systems like Golgi. Rather than rebuilding the Golgi system, we design controlled experiments that isolate overcommitment's effect on latency across three workload profiles: CPU-bound, I/O-bound, and mixed. Our approach goes beyond the single-point OC-vs-Non-OC comparison implicit in the Golgi paper and produces detailed characterization data that the paper does not provide.

We are motivated by three observations.

First, the profile-dependent degradation phenomenon deserves standalone characterization. The Golgi paper treats it as a given and moves directly to building a system that exploits it. If the underlying behavior is more nuanced than the paper assumes — if, for example, mixed functions degrade at some overcommitment levels but not others, or if concurrent load changes the degradation pattern — those nuances matter for anyone designing overcommitment-aware schedulers.

Second, the CFS mechanism that the paper invokes for mixed-function degradation is testable. The Linux CFS bandwidth controller enforces CPU limits via a quota-and-period mechanism. When a container's CPU burst size sits near the quota boundary, some bursts complete within a single period while others spill into the next period and incur a full-period throttling penalty. This creates bimodal latency. We can validate this explanation experimentally by varying the quota boundary relative to the function's burst size and observing whether the bimodal distribution appears and disappears as predicted.

Third, degradation curves are more useful than point comparisons. Knowing that a CPU-bound function is 2.4x slower at one specific overcommitment level tells an operator very little. Knowing that degradation is linear from 100% to 40% CPU but accelerates sharply below 40% gives an operator actionable guidance for setting overcommitment policies. We produce these curves.

### 1.5 Research Questions and Contributions

We address four research questions through four controlled experiments on real AWS infrastructure:

| # | Research Question | Experiment |
|---|---|---|
| RQ1 | How does P95 latency degrade as CPU allocation decreases, and does the degradation curve differ by workload profile? | Multi-level degradation curves (5 CPU levels × 3 functions) |
| RQ2 | Does concurrent load amplify overcommitment-induced degradation, and is the amplification profile-dependent? | Concurrency sweep (4 concurrency levels × 6 function variants) |
| RQ3 | How does overcommitment affect tail latency (P99, P99.9) compared to median behavior? | Tail latency analysis |
| RQ4 | Can the bimodal latency behavior of mixed functions under overcommitment be explained by CFS quota boundary effects? | CFS boundary analysis (fine-grained CPU sweep) |

Our contributions are:

1. **Degradation curves** showing the relationship between CPU allocation and P95 latency for three workload profiles, tested at five overcommitment levels on real infrastructure — not simulation.
2. **Contention analysis** demonstrating how concurrent load interacts with overcommitment, revealing whether superlinear degradation occurs for specific profiles.
3. **Tail latency characterization** showing whether overcommitment amplifies tail latency disproportionately for profiles near CFS quota boundaries.
4. **Mechanistic validation** of bimodal CFS throttling behavior in mixed workloads, tested experimentally by manipulating the quota boundary.
5. **Empirical characterization** of the profile-dependent degradation phenomenon — the foundational observation that motivates profile-aware scheduling systems like Golgi — grounded in direct measurement rather than system-level end-to-end metrics.

### 1.6 Report Organization

Section 2 covers background on serverless computing, resource overcommitment in cloud systems, the Linux CFS scheduler, and the Golgi paper's design. Section 3 describes our experimental design: the two-instance model, benchmark functions, overcommitment calculations, and the four experiments. Section 4 covers implementation specifics: AWS infrastructure, k3s cluster setup, OpenFaaS deployment, and benchmark function construction. Section 5 presents baseline characterization results that establish SLO thresholds and validate the experimental setup. Section 6 will present results from the four main experiments. Section 7 discusses findings, limitations, and threats to validity. Section 8 concludes.

---

## 2. Background and Related Work

### 2.1 Serverless Computing Model

Serverless computing abstracts away infrastructure entirely. A developer writes a stateless function, deploys it to a platform (AWS Lambda, Azure Functions, Google Cloud Functions, or a self-hosted system like OpenFaaS), and the platform takes care of everything else: provisioning containers, scaling replicas up and down, routing requests, and recycling idle instances. Functions are triggered by events, typically HTTP requests, message queue entries, or timers.

The execution lifecycle of a single invocation follows a predictable pattern. If no warm container exists for the function, the platform performs a cold start: it pulls the container image, creates a new container, initializes the runtime, and loads the function code. This takes anywhere from tens of milliseconds (for lightweight Go binaries) to several seconds (for Python functions with large dependency trees). Once the container is warm, subsequent requests reuse it, skipping the cold start. After a period of inactivity, the platform evicts the container to free resources.

Billing follows two dimensions: a flat per-invocation fee and a per-GB-second charge based on the memory the user configures. On AWS Lambda, for example, a user selects a memory size between 128 MB and 10,240 MB, and the platform allocates CPU proportionally. A function configured with 1,769 MB gets one full vCPU; half the memory gets half the CPU. The user pays for this configured memory for the entire duration of each invocation, regardless of how much memory the function actually touches.

This billing model creates a perverse incentive. Users configure conservatively, choosing higher memory to avoid out-of-memory kills, but then use only a fraction of what they reserve. The platform, bound to honor those reservations, cannot schedule other work into the unused capacity. The result, quantified by Shahrad et al. [2] in their analysis of Azure Functions production traces, is that functions consume roughly 25% of their reserved resources on average. The remaining 75% is effectively stranded.

### 2.2 Resource Overcommitment in Cloud Systems

Overcommitment addresses this waste by allocating less physical capacity than the sum of all reservations, gambling that not all tenants will peak at the same time. The technique is well-established in virtualization. VMware ESXi routinely overcommits memory by 1.5-4x using a combination of ballooning (a guest-level driver that reclaims unused pages), transparent page sharing (deduplicating identical memory pages across VMs), and swap (spilling excess to disk). KVM-based hypervisors use similar mechanisms. These techniques work because VM workloads are long-lived and change slowly enough for the hypervisor to adjust.

In Kubernetes, the distinction between resource requests and limits serves a similar purpose. A container's resource request is a guaranteed minimum that the scheduler uses for bin-packing decisions. Its limit is a ceiling enforced by the kernel's cgroup controller. Setting limits higher than requests allows the container to burst into unused capacity on the node. The ratio between the sum of all limits and the node's physical capacity determines the overcommitment factor.

Serverless functions make overcommitment harder for several reasons. Functions are short-lived, often completing in tens of milliseconds, which means the system has no time to react to individual resource spikes using ballooning or similar feedback mechanisms. Workloads are bursty and unpredictable: a function might receive zero invocations for minutes, then thousands in a second. Cold starts add a latency penalty that compounds under resource pressure, because spinning up a new container itself requires CPU and memory. And dense co-location means dozens of different functions from different users share the same physical host, increasing the probability that multiple functions spike simultaneously.

Shahrad et al. [2] showed that despite these challenges, Azure Function traces exhibit temporal patterns (diurnal cycles, periodic triggers, correlated bursts) that are in principle predictable. This observation opened the door for prediction-based overcommitment: instead of statically squeezing all allocations, use runtime signals to decide when overcommitment is safe and when it is not.

### 2.3 Existing Scheduling Approaches

Traditional load balancing strategies operate without awareness of resource state. Round-robin distributes requests evenly across instances regardless of how loaded each one is, which works well when all instances are identical and equally busy, but fails when workloads are heterogeneous or when some instances are under contention. Least-connections improves on this by tracking active request counts, but still has no visibility into CPU utilization, memory pressure, or cache interference on the underlying host.

The Kubernetes default scheduler takes a bin-packing approach based on declared resource requests. When a new pod needs to be placed, the scheduler scores candidate nodes by how well the pod's resource requests fit into the node's remaining allocable capacity. This is a static, placement-time decision. Once a pod is running, the scheduler does not move it or adapt to runtime contention. If five functions happen to spike on the same node, the scheduler is unaware.

Several research systems have addressed parts of this problem. Harvest VMs (Ambati et al. [4]) let low-priority workloads consume spare capacity on partially-utilized servers, but offer no latency guarantees when the primary workload reclaims its resources. Kraken (Wen et al. [5]) focuses on cold-start-aware container provisioning for DAG-structured serverless workflows. It reduces end-to-end latency by pre-warming containers along the critical path, but does not address the resource overcommitment problem. ENSURE (Suresh et al. [6]) provides SLO-aware scheduling for serverless functions, but operates reactively: it detects violations after they happen and adjusts resource allocations in response, rather than predicting and preventing them.

The gap in the literature is a system that combines proactive prediction of resource contention, routing decisions that exploit the difference between overcommitted and fully-provisioned instances, and an adaptive feedback mechanism. Golgi fills this gap with a complete system. But underneath every contention-aware scheduling system lies an assumption: that contention's effect on latency is predictable and varies by workload profile. This assumption has not been independently characterized. Our work provides that characterization.

### 2.4 The Golgi Paper in Detail

The Golgi system, proposed by Li et al. [1], sits between the serverless platform's API gateway and the function instances. For each deployed function, Golgi maintains two sets of container replicas: Non-OC instances provisioned at the user's declared resource levels, and OC instances provisioned at reduced levels computed from observed actual usage. The overcommitment formula is `OC_allocation = 0.3 * claimed + 0.7 * actual`, weighting 70% toward measured usage with a 30% safety margin from the original reservation.

A metric collection daemon running on each worker node scrapes nine metrics from every function container at 500ms intervals: CPU utilization, memory utilization, memory bandwidth, network bytes sent, network bytes received, disk I/O read, disk I/O write, the count of inflight requests, and the LLC (last-level cache) miss rate. These metrics are read from the Linux cgroup filesystem and hardware performance counters, then forwarded to a central ML module.

The ML module trains a Mondrian Forest classifier [3], an online variant of Random Forests that can incorporate new training samples incrementally without full retraining. Each training sample is a feature vector of the nine metrics paired with a binary label: 1 if the corresponding request's latency exceeded the SLO threshold (defined as the P95 latency of the Non-OC baseline), 0 otherwise. A critical implementation detail is the use of stratified reservoir sampling to maintain a balanced training set. Without this balancing step, the training data would be heavily skewed toward negative samples (most requests meet the SLO), and the classifier's F1 score would drop from 0.78 to 0.26.

The router uses a Power of Two Choices algorithm for instance selection. For each incoming request, it samples two OC instances, queries the classifier for each one's current violation probability, and routes the request to the instance with the lower probability. If both probabilities exceed a safety threshold, the request goes to a Non-OC instance instead. A global Safe flag, computed from the rolling P95 latency across all OC instances, provides a coarse-grained override: when contention is system-wide, the flag flips to unsafe and all requests are routed to Non-OC instances until conditions improve.

Vertical scaling provides a second layer of defense. An AIMD controller on each OC instance monitors its SLO violation rate over a rolling window. If the violation rate exceeds 5%, the controller decreases the instance's maximum concurrency by one (multiplicative decrease, floored at 1). If violations stay below 2% for three consecutive windows, it increases concurrency by one (additive increase). Reducing concurrency means fewer concurrent requests per container, less contention for CPU and cache, and lower tail latency, at the cost of needing more containers or longer queue wait times.

The original evaluation used eight benchmark functions spanning five languages, deployed on seven c5.9xlarge workers (36 vCPUs, 72 GB RAM each), driven by replayed Azure Function Trace workloads. Golgi achieved 42% memory cost reduction, 35% VM time reduction, and kept SLO violations below 5%.

### 2.5 Relationship Between Our Study and the Golgi System

Table 1 clarifies the relationship between our empirical study and the Golgi system. Our work is not a replication of Golgi. We do not build an ML classifier, a request router, or a vertical scaler. Instead, we characterize the profile-dependent degradation phenomenon that the Golgi system is built upon.

**Table 1: Scope comparison between the Golgi system and our empirical study.**

| Dimension | Golgi (Li et al.) | Our Study |
|---|---|---|
| **Goal** | Build an ML-guided overcommitment routing system | Characterize profile-dependent degradation under overcommitment |
| **Approach** | End-to-end system (classifier + router + scaler) | Controlled experiments isolating overcommitment effects |
| **What is measured** | Cost reduction, SLO violation rate (system metrics) | Degradation curves, tail latency, CFS throttling behavior (characterization data) |
| **Cluster** | 7× c5.9xlarge (36 vCPU, 72 GB each) | 3× t3.xlarge (4 vCPU, 16 GB each) |
| **Functions** | 8 functions in 5 languages | 3 functions in Python/Go (one per profile) |
| **Overcommitment levels** | One OC level per function (formula-derived) | Five levels per function (100%, 80%, 60%, 40%, 20% CPU) |
| **Concurrency** | Replayed Azure traces (variable) | Controlled sweep (1, 2, 4, 8 concurrent requests) |
| **CFS analysis** | Mentioned as explanation for mixed-function behavior | Experimentally characterized via fine-grained quota manipulation |
| **ML/Routing** | Core contribution (Mondrian Forest + Power-of-Two router) | Not in scope — we characterize the phenomenon that motivates these components |

The Golgi paper assumes that overcommitment impact is profile-dependent and uses that assumption to justify building a complex scheduling system. We characterize whether this profile-dependent degradation exists, how it manifests across overcommitment levels and concurrency, and what mechanism drives it. This characterization is valuable regardless of whether it aligns with or complicates the Golgi paper's assumptions — either outcome informs the design of overcommitment-aware schedulers.

---

## 3. Experimental Design

This section describes the design of our empirical study: the two-instance model we adopt from the Golgi paper, the benchmark functions that cover three workload profiles, the overcommitment calculations, and the four experiments we run to characterize degradation behavior. Implementation details (infrastructure, deployment, tooling) follow in Section 4.

### 3.1 Overview

Our study design has two parts. First, we establish a controlled environment for measuring overcommitment effects: a k3s/OpenFaaS cluster on AWS with three benchmark functions, each deployed in both a Non-OC (full-resource) and an OC (overcommitted) variant. Second, we run four experiments that systematically vary overcommitment level, concurrency, and CFS quota parameters while measuring latency at multiple percentiles.

```
                         +-----------------+
                         | Load Generator  |
                         | (bash/curl)     |
                         +-------+---------+
                                 |
                                 | HTTP (sequential or concurrent)
                                 v
                         +-----------------+
                         | OpenFaaS Gateway|
                         | (port 31112)    |
                         +--+-----------+--+
                            |           |
                   Non-OC   |           |   OC
                            v           v
                      +-----------+ +-----------+
                      | Function  | | Function  |
                      | (full CPU | | (reduced  |
                      |  & memory)| |  CPU/mem) |
                      +-----------+ +-----------+
                            |           |
                            v           v
                      [Latency recorded per request]
                      [cgroup metrics: cpu.stat, memory.current]
```

The key design principle is isolation. Each experiment varies one factor at a time. The baseline (Phase 1) holds concurrency at 1 and compares Non-OC vs OC at a single overcommitment level. The degradation curve experiment (Phase 2) varies CPU allocation across five levels while holding concurrency at 1. The concurrency sweep (Phase 3) crosses two overcommitment levels with four concurrency levels. The CFS boundary analysis (Phase 5) performs a fine-grained CPU sweep on a single function. This factorial structure lets us attribute latency changes to specific causes.

### 3.2 Two-Instance Model

Following the Golgi paper's methodology, we deploy each function in two variants: Non-OC (non-overcommitted) with the user's declared resource allocation, and OC (overcommitted) with reduced resources computed from observed actual usage. The overcommitment formula from the paper is:

```
OC_allocation = α × claimed + (1 - α) × actual
```

The paper uses α = 0.3, giving 70% weight to measured usage and retaining 30% of the original reservation as a safety margin. We adopt the same value to ensure our OC configurations are directly comparable to those the Golgi system would create.

To measure actual usage, we deploy each function in its Non-OC configuration, send 100 requests under no concurrent load, and record the P75 of memory consumption from the cgroup's `memory.current` file. CPU actual usage is derived similarly from `cpu.stat`. Applying the formula yields the OC resource allocations shown in Table 2.

**Table 2: Resource configurations for Non-OC and OC function variants.**

| Function | Profile | Non-OC CPU | OC CPU | CPU Reduction | Non-OC Memory | OC Memory | Memory Reduction |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound | 1000m | 405m | 2.47× | 512 Mi | 210 Mi | 59% |
| db-query | I/O-bound | 500m | 185m | 2.70× | 256 Mi | 105 Mi | 59% |
| log-filter | Mixed | 500m | 206m | 2.43× | 256 Mi | 98 Mi | 62% |

Both variants run from the same container image. The only difference is the Kubernetes resource requests and limits specified in the deployment manifest. The OC variant's container has less CPU time available (the kernel's CFS scheduler enforces the CPU limit via cgroup `cpu.max`) and a lower memory ceiling (the kernel's OOM killer fires if `memory.current` exceeds `memory.max`). Under light load, the OC instance may perform comparably to Non-OC because the function's actual resource consumption falls within the reduced allocation. Under heavier load or with concurrent requests, the OC instance hits its limits, and the degree of degradation depends on the function's workload profile — which is precisely what we measure.

### 3.3 Benchmark Functions

We deploy three benchmark functions, one for each major workload profile identified in the Golgi paper. Three functions are the minimum needed to test the hypothesis that profiles respond differently to overcommitment. Each function is designed so that its dominant resource bottleneck is clear and controllable.

**image-resize (CPU-bound, Python).** Generates a random RGB image (1920×1080 pixels), then downscales it to half size (960×540) using Pillow's Lanczos resampling filter. Lanczos resampling applies a windowed sinc convolution kernel per output pixel, making the computation directly proportional to available CPU cycles. Memory usage is modest and predictable (two image buffers of known size). This function's latency should scale proportionally with CPU reduction, since CPU is the sole bottleneck.

**db-query (I/O-bound, Python).** Connects to a Redis instance running within the cluster and performs a GET → SET → GET sequence. Latency is dominated by network round-trips between the function container and the Redis pod, not by CPU computation. Even with significantly reduced CPU, the function should perform similarly because it spends most of its execution time waiting on network I/O. This function tests the hypothesis that I/O-bound functions are resilient to overcommitment.

**log-filter (Mixed, Go).** Generates 1000 synthetic log lines, applies regex matching to filter lines containing `ERROR`, `WARN`, or `CRITICAL`, and runs IP address anonymization via regex replacement. This exercises both CPU (regex compilation and matching, string operations) and memory (string allocation, buffer management). Critically, the function's CPU burst size sits near the CFS quota boundary under overcommitment. Some invocations complete within a single CFS period; others spill into the next period and incur a full-period throttling penalty. This creates the bimodal latency distribution that the Golgi paper attributes to CFS interactions. Written in Go to demonstrate language diversity and to ensure the mixed behavior comes from the workload characteristics, not from Python interpreter overhead.

### 3.4 Experiment Design

**Experiment 1: Multi-Level Degradation Curves (Phase 2).** For each function, we deploy five variants with CPU allocations at 100%, 80%, 60%, 40%, and 20% of the Non-OC value. We send 200 sequential requests (concurrency = 1) to each variant and record per-request latency. The output is a degradation curve: P95 latency as a function of CPU allocation, plotted separately for each profile. We expect CPU-bound functions to show linear or near-linear degradation, I/O-bound functions to show a flat curve, and mixed functions to show non-linear degradation with a knee at the CFS quota boundary.

**Experiment 2: Concurrency Sweep (Phase 3).** We test all six function variants (3 functions × {Non-OC, OC}) at four concurrency levels: 1, 2, 4, and 8 simultaneous requests. For each combination, we send 200 total requests and measure latency. This experiment answers whether concurrent load amplifies overcommitment-induced degradation. If degradation is additive (OC penalty + concurrency penalty), the lines on the degradation-vs-concurrency plot will be parallel. If degradation is superlinear (OC and concurrency compound), the OC line will diverge from Non-OC as concurrency increases.

**Experiment 3: Tail Latency Analysis (Phase 4).** Using the data from Experiments 1 and 2, we analyze P50, P95, P99, and P99.9 latencies separately. The question is whether overcommitment amplifies tail latency disproportionately. A function whose median latency increases by 2x but whose P99.9 increases by 10x under overcommitment is far more dangerous for SLO compliance than one where all percentiles scale uniformly. We expect mixed functions to show the most disproportionate tail amplification due to the bimodal CFS throttling.

**Experiment 4: CFS Boundary Analysis (Phase 5).** This experiment targets the log-filter function specifically. We deploy it with CPU limits swept in fine increments (e.g., 50m steps from 100m to 500m), creating a series of CFS quota boundaries. For each configuration, we send 200 requests and analyze the latency distribution. If the bimodal hypothesis is correct, we should observe: (a) unimodal distributions when the quota is well above or well below the burst size, and (b) bimodal distributions when the quota boundary falls near the burst size. This provides a mechanistic explanation for the mixed-function degradation pattern, grounded in the CFS bandwidth controller's quota-and-period enforcement.

---

## 4. Implementation

### 4.1 Infrastructure Setup

All resources run on AWS in `us-east-1a` inside a dedicated VPC (`10.0.0.0/16`) with a single subnet (`10.0.1.0/24`). The cluster consists of five EC2 instances:

**Table 3: Cluster nodes and their roles.**

| Node | Instance Type | vCPU | RAM | Role |
|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway |
| golgi-worker-1 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-2 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-3 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-loadgen | t3.medium | 2 | 4 GB | Request generation, latency measurement |

We chose t3.xlarge workers (4 vCPU, 16 GB RAM, $0.1664/hr) because four vCPUs provide enough headroom to observe CPU contention when multiple containers compete for CPU time, and 16 GB accommodates 6+ function containers per worker with room for k3s overhead. The paper used c5.9xlarge instances (36 vCPU, 72 GB, $1.53/hr) — our instances are 10× cheaper while still demonstrating the same CFS and cgroup behaviors at a smaller scale. The total cluster cost is approximately $0.58/hr ($14/day).

The Kubernetes layer uses k3s v1.34.6, a lightweight Kubernetes distribution that provides the same API, scheduling, and cgroup enforcement as full Kubernetes but deploys as a single binary with embedded etcd. We chose k3s over kubeadm for faster setup and lower memory overhead — the k3s server uses approximately 500 MB RAM at our scale. We disabled the bundled Traefik ingress controller since we invoke functions directly through the OpenFaaS gateway.

OpenFaaS was deployed via Helm into the `openfaas` namespace, running five components: the HTTP gateway (exposed as NodePort 31112), Prometheus for metrics, NATS for async messaging, AlertManager, and a queue worker. Function invocations go through the gateway at `http://<master-ip>:31112/function/<name>`.

The security group allows SSH from our IP, all intra-VPC traffic (for k3s control plane and pod networking), and the OpenFaaS NodePort range from our IP. All instances run Amazon Linux 2023 (kernel 6.1.166) with cgroup v2 in unified hierarchy mode — the modern cgroup interface that exposes CPU, memory, and I/O metrics through a clean filesystem at `/sys/fs/cgroup/`.

### 4.2 Benchmark Functions

Each function is deployed as an OpenFaaS function with two Kubernetes deployment variants: Non-OC (full resources) and OC (overcommitted resources). Both variants use the same container image; only the resource requests and limits in the deployment manifest differ.

**image-resize (CPU-bound, Python 3.9).** The handler generates a random RGB image of 1920×1080 pixels by iterating over every pixel and assigning random RGB values using Python's `random` module, then downscales it to 960×540 using Pillow's Lanczos resampling filter. The pixel-by-pixel generation in Python's interpreted loop plus the Lanczos windowed sinc convolution make execution time directly proportional to available CPU cycles. Dependencies: `pillow`. Non-OC allocation: 1000m CPU, 512 Mi memory. OC allocation: 405m CPU, 210 Mi memory (2.47× CPU reduction).

**db-query (I/O-bound, Python 3.9).** The handler connects to a Redis instance (deployed as a single pod in the `openfaas-fn` namespace with 64 Mi request / 128 Mi limit) and performs a GET → SET → GET sequence using the `redis` Python client. Latency is dominated by three network round-trips between the function container and the Redis pod. CPU consumption is minimal — the function spends most of its time waiting on I/O. Non-OC allocation: 500m CPU, 256 Mi memory. OC allocation: 185m CPU, 105 Mi memory (2.70× CPU reduction).

**log-filter (Mixed, Go).** The handler generates 1000 synthetic log lines with randomized timestamps, log levels, and source IPs, then applies regex matching to filter lines containing `ERROR`, `WARN`, or `CRITICAL`, and runs IP anonymization via regex replacement. This exercises CPU (regex compilation and matching, string operations) and memory (string allocation, buffer management). Written in Go to ensure the mixed behavior comes from workload characteristics rather than Python interpreter overhead. Non-OC allocation: 500m CPU, 256 Mi memory. OC allocation: 206m CPU, 98 Mi memory (2.43× CPU reduction).

All six function variants (3 functions × 2 resource levels) are defined in a single Kubernetes manifest (`functions/functions-deploy.yaml`) and deployed simultaneously. OpenFaaS auto-scaling is disabled (`com.openfaas.scale.min=1`, `com.openfaas.scale.max=1`) to fix replica counts at 1 per variant, ensuring each measurement targets a single container with a known resource allocation.

### 4.3 Latency Measurement

Latency is measured end-to-end at the load generator using `curl` with timing output. The benchmark script (`scripts/benchmark-latency.sh`) sends sequential HTTP POST requests to each function via the OpenFaaS gateway and records the total round-trip time per request. For each function variant, the script sends 200 requests, discards no warm-up period (functions are pre-warmed with 5 requests before measurement begins via `scripts/warmup.sh`), and writes per-request latencies to a raw data file.

For concurrent experiments (Phase 3), the script launches multiple `curl` processes in parallel using bash background jobs, collecting latencies from all concurrent streams.

Statistical analysis is performed by `scripts/compute-stats.py`, which reads the raw latency files and computes P50, P95, P99, P99.9, mean, standard deviation, and error counts. Plots are generated by `scripts/generate-phase1-plots.py` using matplotlib and numpy.

### 4.4 cgroup v2 and CFS Configuration

Resource limits are enforced by the Linux kernel's cgroup v2 controllers, configured automatically by k3s based on the Kubernetes resource specifications in our deployment manifests.

**CPU limits** are enforced via the CFS bandwidth controller. A Kubernetes CPU limit of 405m (millicores) translates to a cgroup `cpu.max` value of `40500 100000`, meaning the container gets 40,500 µs of CPU time per 100,000 µs (100 ms) CFS period. When the container exhausts its quota within a period, all its threads are throttled until the next period begins. This throttling mechanism is the primary driver of latency degradation under overcommitment: a function that completes in one CFS period at full CPU may require two or more periods at reduced CPU, with each period boundary adding up to 100 ms of dead time.

**Memory limits** are enforced via the cgroup memory controller. A Kubernetes memory limit of 210 Mi sets `memory.max` to 220200960 bytes. If the container's resident memory (`memory.current`) exceeds this, the kernel's OOM killer terminates the container process.

For the CFS boundary analysis (Phase 5), we deploy the log-filter function with CPU limits swept in fine increments. Each CPU limit creates a different quota-to-period ratio, placing the CFS quota boundary at different points relative to the function's CPU burst size. This is how we experimentally test whether bimodal latency arises from CFS quota boundary crossings.

---

## 5. Baseline Characterization

Before running the four main experiments, we establish baseline latency profiles for all six function variants (3 functions × {Non-OC, OC}). This baseline serves two purposes: it defines the SLO thresholds used throughout the study, and it provides the first evidence for whether the Golgi hypothesis holds.

### 5.1 Hardware and Software Configuration

**Table 4: Software stack versions.**

| Component | Version | Notes |
|---|---|---|
| OS | Amazon Linux 2023 | Kernel 6.1.166 |
| k3s | v1.34.6+k3s1 | Containerd 2.2.2 |
| OpenFaaS | Helm revision 1 | Gateway on NodePort 31112 |
| Python | 3.9.25 | On all nodes |
| Go | (built into log-filter image) | golang-http template |
| cgroup | v2 (unified) | `/sys/fs/cgroup/` |
| faas-cli | v0.18.8 | Function build and deploy |

All instances are in the same subnet (`10.0.1.0/24`) and availability zone (`us-east-1a`), giving sub-millisecond inter-node latency. This eliminates cross-AZ network jitter as a confound in our measurements.

### 5.2 Methodology

For each of the six function variants, we send 200 sequential HTTP POST requests (concurrency = 1) through the OpenFaaS gateway from the load generator node. Before measurement, each function is warmed with 5 invocations to ensure no cold starts appear in the data. Per-request round-trip latency is recorded by `curl` on the load generator.

We define the SLO threshold for each function as the P95 latency of its Non-OC variant under this sequential, no-contention workload, matching the methodology described in Section 5.1 of the Golgi paper. A request "violates" the SLO if its latency exceeds this threshold.

### 5.3 Baseline Results

**Table 5: Baseline latency measurements (200 sequential requests per variant, measured 2026-04-12).**

| Function | Profile | CPU | P50 | P95 (SLO) | P99 | Mean | Errors |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound (Non-OC) | 1000m | 4485 ms | **4591 ms** | 4762 ms | 4499 ms | 0/200 |
| image-resize-oc | CPU-bound (OC) | 405m | 11067 ms | 11156 ms | 11276 ms | 11057 ms | 0/200 |
| db-query | I/O-bound (Non-OC) | 500m | 18 ms | **21 ms** | 24 ms | 19 ms | 0/200 |
| db-query-oc | I/O-bound (OC) | 185m | 20 ms | 28 ms | 35 ms | 21 ms | 0/200 |
| log-filter | Mixed (Non-OC) | 500m | 16 ms | **17 ms** | 18 ms | 16 ms | 0/200 |
| log-filter-oc | Mixed (OC) | 206m | 25 ms | 77 ms | 96 ms | 35 ms | 0/200 |

The SLO thresholds (bolded P95 values) are: 4591 ms for image-resize, 21 ms for db-query, and 17 ms for log-filter.

### 5.4 Degradation Analysis

The baseline results already reveal a profile-dependent degradation pattern consistent with the CFS quota enforcement mechanism:

**CPU-bound (image-resize): near-proportional degradation at this OC level.** The OC variant's P95 (11156 ms) is 2.43× the Non-OC P95 (4591 ms). The CPU reduction factor is 2.47× (1000m → 405m). The degradation ratio (2.43×) closely matches the CPU reduction ratio (2.47×), indicating that at this overcommitment level, image-resize latency scales proportionally with available CPU. The latency distribution is tight — P99/P50 ratio is 1.06 for Non-OC and 1.02 for OC — indicating consistent, predictable behavior with no CFS boundary effects. Whether this linear relationship holds across all CPU levels is tested in Phase 2; the literature suggests CFS throttling artifacts may introduce superlinear degradation at extreme overcommitment levels.

**I/O-bound (db-query): resilient to overcommitment.** The OC variant's P95 (28 ms) is only 1.33× the Non-OC P95 (21 ms), despite a 2.70× CPU reduction (500m → 185m). The function absorbs nearly three-quarters of the CPU cut with minimal latency impact because network round-trips to Redis dominate execution time, not CPU computation. This is consistent with the expectation that I/O-bound functions tolerate aggressive overcommitment, since their bottleneck is network latency rather than CPU cycles.

**Mixed (log-filter): disproportionate, non-linear degradation.** The OC variant's P95 (77 ms) is 4.53× the Non-OC P95 (17 ms), despite only a 2.43× CPU reduction (500m → 206m). The degradation is nearly double what proportional scaling would predict. More telling is the distribution shape: the Non-OC variant is tight (P99/P50 = 1.13), while the OC variant shows extreme spread (P99/P50 = 3.84). The OC median (25 ms) is only 1.56× the Non-OC median (16 ms), but the tail explodes. This is the signature of bimodal CFS throttling: most invocations complete within a single CFS period (fast mode), but a fraction spill into the next period and incur a full throttling penalty (slow mode).

**Table 6: Degradation summary.**

| Function | CPU Reduction | P95 Degradation | Proportional? |
|---|---|---|---|
| image-resize | 2.47× | 2.43× | Yes — degradation matches CPU cut |
| db-query | 2.70× | 1.33× | No — resilient (I/O-dominated) |
| log-filter | 2.43× | 4.53× | No — disproportionate (CFS throttling) |

### 5.5 Baseline Figures

Figure 1 shows CDF curves for the fast functions (db-query and log-filter), with the SLO threshold marked for each. The separation between Non-OC and OC curves is small for db-query but dramatic for log-filter, with the OC curve developing a long tail.

<p align="center">
  <img src="../results/phase1/plots/fig1_cdf_fast_functions.png" width="72%" />
</p>

*Figure 1: Latency CDF for I/O-bound and mixed functions. Solid lines are Non-OC, dashed lines are OC. Vertical dotted lines mark the SLO threshold.*

Figure 2 shows per-function CDF comparisons of Non-OC vs OC variants with the SLO violation region shaded.

<p align="center">
  <img src="../results/phase1/plots/fig2_cdf_per_function.png" width="65%" />
</p>

*Figure 2: Per-function CDF comparison. The red-shaded region marks the SLO violation zone. CPU-bound functions show a clean rightward shift under OC; mixed functions show a long tail from bimodal CFS throttling.*

Figure 3 compares P95 latency across all functions, separated into CPU-bound and fast (I/O-bound, mixed) panels to accommodate the two-order-of-magnitude scale difference.

<p align="center">
  <img src="../results/phase1/plots/fig3_p95_bar_chart.png" width="80%" />
</p>

*Figure 3: P95 latency comparison. CPU-bound functions degrade proportionally to CPU reduction (2.4×), I/O-bound functions are resilient (1.3×), and mixed functions suffer disproportionately (4.5×) from CFS throttling.*

Figure 4 shows the latency distributions as box plots, revealing the spread difference between profiles under overcommitment.

<p align="center">
  <img src="../results/phase1/plots/fig4_box_plots.png" width="65%" />
</p>

*Figure 4: Box plots showing distribution shape. The log-filter OC variant exhibits wide spread from bimodal CFS behavior, while image-resize and db-query maintain tight distributions.*

Figure 5 summarizes the degradation ratios alongside CPU reduction ratios, visualizing the core finding that different function profiles respond differently to overcommitment.

<p align="center">
  <img src="../results/phase1/plots/fig5_degradation_ratios.png" width="72%" />
</p>

*Figure 5: Degradation ratio comparison. CPU-bound degradation matches CPU reduction (2.4× ≈ 2.5×). I/O-bound functions absorb a 2.7× CPU cut with only 1.3× degradation. Mixed functions show disproportionate degradation from CFS quota boundary effects.*

### 5.6 Implications for Subsequent Experiments

These baseline results establish that profile-dependent degradation exists at a single overcommitment level with zero concurrent load. The four main experiments (Phases 2–5) will characterize whether this pattern holds across multiple overcommitment levels, under concurrent load, at extreme tail percentiles, and whether the CFS quota boundary mechanism can be confirmed as the causal driver of the mixed-function behavior.

---

## 6. Results and Analysis

<!-- Sections 6.1–6.4 correspond to the four main experiments (Phases 2–5). To be written as each experiment completes. -->

### 6.1 Multi-Level Degradation Curves (RQ1)

<!--
- Phase 2 results: 5 CPU levels × 3 functions, 200 requests each
- Plot: P95 latency vs CPU allocation (% of Non-OC), one line per function profile
- Expected shapes:
  - image-resize: linear or near-linear (CPU-bound, direct proportionality)
  - db-query: flat curve (I/O-bound, resilient to CPU reduction)
  - log-filter: non-linear with a knee (mixed, CFS boundary crossing at some CPU level)
- Table: P95 latency at each level for each function
- Analysis: at what CPU level does each profile start degrading significantly?
- Actionable insight: safe overcommitment thresholds per profile
-->

### 6.2 Concurrency Under Overcommitment (RQ2)

<!--
- Phase 3 results: 4 concurrency levels × 6 function variants
- Plot: P95 latency vs concurrency, Non-OC and OC lines per function
- Key question: are the lines parallel (additive) or diverging (superlinear)?
- Expected:
  - image-resize: near-parallel (CPU contention adds linearly)
  - db-query: near-parallel (I/O wait dominates, concurrency adds queueing)
  - log-filter: diverging (CFS throttling + concurrency compound)
- Table: degradation ratio at each concurrency level
- Analysis: does concurrent load change which profiles are safe to overcommit?
-->

### 6.3 Tail Latency Analysis (RQ3)

<!--
- Phase 4 results: P50, P95, P99, P99.9 across all configurations
- Plot: tail latency amplification factor (P99/P50, P99.9/P50) per profile under OC
- Key question: does overcommitment amplify tail latency disproportionately?
- Expected:
  - CPU-bound: uniform amplification (all percentiles scale similarly)
  - I/O-bound: minimal amplification (tail stays tight)
  - Mixed: disproportionate amplification (P99.9 >> P50 under OC)
- Analysis: implications for SLO design — P95 vs P99 as the right threshold
-->

### 6.4 CFS Quota Boundary Analysis (RQ4)

<!--
- Phase 5 results: log-filter at fine-grained CPU levels (50m steps from 100m to 500m)
- Plot: latency distribution (histogram or violin) at each CPU level
- Key question: does the bimodal distribution appear/disappear predictably?
- Expected:
  - High CPU (>350m): unimodal, fast (burst fits in one CFS period)
  - Medium CPU (~200-300m): bimodal (burst sometimes spills into next period)
  - Low CPU (<150m): unimodal, slow (burst always requires multiple periods)
- Analysis: identify the exact CFS boundary crossing point
- Mechanistic explanation: relate burst size (µs) to quota (µs) to period (100ms)
-->

### 6.5 Summary of Findings

<!--
- Synthesis table: which aspects of the Golgi hypothesis are validated/nuanced/contradicted
- Overall conclusion: does the empirical evidence support profile-aware overcommitment?
- Implications for system design: what would a scheduler need to know about each profile?
-->

---

## 7. Discussion

<!-- To be written after all experiments complete. -->

### 7.1 Key Findings

<!--
- Finding 1: The Golgi hypothesis holds — different profiles respond differently to overcommitment (validated)
- Finding 2: CPU-bound degradation is proportional and predictable (linear curve)
- Finding 3: I/O-bound functions tolerate aggressive overcommitment (flat curve down to X% CPU)
- Finding 4: Mixed-function degradation is driven by CFS quota boundary effects (mechanistic validation)
- Finding 5: Concurrent load amplifies degradation superlinearly for mixed functions (system design implication)
- Finding 6: Tail latency amplification is profile-dependent (P99.9 behavior differs from P95)
-->

### 7.2 Implications for Overcommitment-Aware Schedulers

<!--
- What our characterization data tells scheduler designers:
  - I/O-bound functions are safe to overcommit aggressively (up to X× CPU reduction)
  - CPU-bound functions require proportional resource guarantees (degradation is predictable)
  - Mixed functions need special treatment — CFS boundary awareness is essential
- How Golgi's design aligns with our findings:
  - The two-instance model is well-motivated: profiles genuinely respond differently
  - An ML classifier needs to distinguish profiles, not just predict violations
  - The CFS explanation justifies fine-grained CPU limit control, not just binary OC/Non-OC
-->

### 7.3 Limitations

<!--
- Smaller cluster (3 workers vs paper's 7): less co-location diversity
- Fewer functions (3 vs 8): one function per profile — no within-profile variance
- t3.xlarge (burstable): CPU credits may mask throttling during short experiments
- Synthetic functions: designed to be pure examples of each profile — real functions are messier
- Sequential measurement: Phases 1-2 use concurrency=1, which understates real-world contention
- Single overcommitment formula: we use Golgi's α=0.3 formula, not exploring other formulas
-->

### 7.4 Threats to Validity

<!--
- Internal validity:
  - Measurement noise: network jitter, EBS latency spikes, t3 CPU credit throttling
  - Warm-up adequacy: 5 warmup requests may not fully stabilize JIT, caches, etc.
  - Sample size: 200 requests per configuration — sufficient for P95/P99 but marginal for P99.9
  
- External validity:
  - Different hardware from paper (t3 vs c5 — different CPU microarchitecture, memory bandwidth)
  - cgroup v2 vs paper's likely cgroup v1 (different throttling behavior possible)
  - k3s v1.34 vs paper's likely K8s 1.24-1.26 (scheduler differences)
  - Amazon Linux 2023 vs paper's likely Ubuntu (kernel configuration differences)
  
- Construct validity:
  - SLO thresholds are infrastructure-specific — absolute values differ from paper
  - Our benchmark functions are purpose-built; real-world functions may show hybrid profiles
  - "Mixed" is a broad category — different types of mixed workloads may behave differently
-->

### 7.5 Lessons Learned

<!--
- cgroup v2 vs v1: unified hierarchy simplifies cgroup management, but documentation is sparse
- k3s operational quirks: KUBECONFIG not set by default for Helm, svclb conflicts, traefik disabling
- OpenFaaS scaling: must explicitly disable auto-scaling to fix replica counts for controlled experiments
- CFS period visibility: throttle counts in cpu.stat are essential for understanding bimodal behavior
- t3 burstable instances: CPU credit monitoring needed to ensure experiments run at full capacity
-->

### 7.6 Future Work

<!--
- More functions per profile: multiple CPU-bound, I/O-bound, and mixed functions to test within-profile variance
- Multi-node contention: co-locate OC functions on same worker to measure cross-function interference
- Memory overcommitment: this study focuses on CPU — memory overcommitment has different dynamics
- Real-world functions: test with production-like functions (ML inference, web scraping, ETL pipelines)
- Longer experiments: sustained load to exhaust t3 CPU credits and observe steady-state behavior
- Dynamic overcommitment: vary CPU limits at runtime and measure adaptation latency
-->

---

## 8. Conclusion

<!-- To be written after all experiments complete. -->

<!--
Paragraph 1: Restate the problem — serverless resource waste, overcommitment as the fix, but blind overcommitment causes latency degradation (2-3 sentences)
Paragraph 2: The Golgi hypothesis — profile-dependent degradation is assumed but not independently validated (2 sentences)
Paragraph 3: What we did — systematic empirical characterization across 3 profiles, 4 experiments, on real AWS infrastructure (2-3 sentences)
Paragraph 4: Key quantitative findings:
  - CPU-bound: degradation proportional to CPU reduction (2.4× at Golgi's OC level)
  - I/O-bound: resilient — only 1.3× degradation despite 2.7× CPU cut
  - Mixed: disproportionate 4.5× degradation from CFS quota boundary effects
  - [Degradation curve shapes from Phase 2]
  - [Concurrency amplification results from Phase 3]
  - [CFS boundary validation from Phase 5]
Paragraph 5: What this means for overcommitment-aware schedulers:
  - The hypothesis is validated — profiles genuinely require different treatment
  - I/O-bound functions are safe targets for aggressive overcommitment
  - Mixed functions need CFS-aware resource allocation, not just reduced CPU
  - Characterization data like ours is a prerequisite for designing safe overcommitment policies
Paragraph 6: Future work (1-2 sentences pointing to Section 7.6)
-->

---

## 9. References

1. Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing. *Proceedings of the ACM Symposium on Cloud Computing (SoCC '23)*. https://doi.org/10.1145/3620678.3624645

2. Shahrad, M., Fung, R., Gruber, N., Goiri, I., Chaudhry, G., Cooke, J., Laureano, E., Tresness, C., Russinovich, M., & Bianchini, R. (2020). Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider. *USENIX ATC '20*. https://www.usenix.org/conference/atc20/presentation/shahrad

3. Ambati, P., Goiri, I., Frujeri, F., Gun, A., Wang, K., Dolan, B., Corell, B., Pasupuleti, S., Moscibroda, T., Elnikety, S., Fontoura, M., & Bianchini, R. (2020). Providing SLOs for Resource-Harvesting VMs in Cloud Platforms. *14th USENIX Symposium on Operating Systems Design and Implementation (OSDI '20)*. https://www.usenix.org/conference/osdi20/presentation/ambati

4. Wen, J., Chen, Z., Jin, Y., & Liu, H. (2021). Kraken: Adaptive Container Provisioning for Deploying Dynamic DAGs in Serverless Platforms. *ACM SoCC '21*. https://doi.org/10.1145/3472883.3486992

5. Suresh, A., Somashekar, G., Varadarajan, A., Kakarla, V.R., & Gandhi, A. (2020). ENSURE: Efficient Scheduling and Autonomous Resource Management in Serverless Environments. *IEEE ACSOS 2020*. https://doi.org/10.1109/ACSOS49614.2020.00036

6. Linux Kernel CFS Bandwidth Control Documentation. https://docs.kernel.org/scheduler/sched-bwc.html

7. Linux Kernel cgroup v2 Documentation. https://docs.kernel.org/admin-guide/cgroup-v2.html

8. k3s — Lightweight Kubernetes. https://k3s.io/

9. OpenFaaS — Serverless Functions Made Simple. https://www.openfaas.com/

---

## Appendix A: Resource Configuration Tables

<!-- Complete resource allocations for all functions, OC formula calculations -->

---

## Appendix B: Reproducibility Commands

<!-- Key CLI commands for reproducing our experiments -->

---

## Appendix C: Raw Experimental Data

<!-- Tables of per-run measurements, or pointer to data files in the repo -->
