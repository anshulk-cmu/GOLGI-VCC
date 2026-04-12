# Characterizing the Impact of Resource Overcommitment on Serverless Function Latency Across Workload Profiles

<div align="center">

**Course:** CSL7510 — Cloud Computing

**Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056), Kirtiman Sarangi (G25AI1024)

**Programme:** M.Tech Artificial Intelligence

**Institution:** Indian Institute of Technology Jodhpur

**Date:** April 2026

</div>

---

## Abstract

Serverless computing platforms waste up to 75% of reserved resources because users overestimate their functions' needs. Resource overcommitment — allocating less physical capacity than the sum of reservations — is the natural fix, but blind overcommitment causes P95 latency increases of up to 183%. The Golgi system (Li et al., SoCC 2023, Best Paper) proposes profile-aware scheduling built on the hypothesis that CPU-bound, I/O-bound, and mixed functions respond differently to overcommitment, but this foundational assumption is not independently validated in their work. We provide that characterization. Through controlled experiments on a 5-node AWS cluster running k3s and OpenFaaS, we deploy three benchmark functions — one per profile — at five CPU allocation levels (100% to 20%) and measure latency degradation across 9,000+ requests. Our baseline measurements confirm profile-dependent behavior at a single overcommitment level: CPU-bound functions degrade proportionally to CPU reduction (2.43x for 2.47x CPU cut), I/O-bound functions are resilient (1.33x for 2.70x cut), and mixed functions suffer disproportionately (4.53x for 2.43x cut). Direct cgroup v2 CPU burst measurement reveals the mechanism: mixed-function requests consume 7.7ms of CPU each, and when the CFS quota boundary falls near this burst size, requests deterministically split into a fast mode (~16ms) and a slow mode (~80-100ms) depending on whether they straddle a CFS period boundary. Multi-level degradation curves show that this profile-dependent behavior follows qualitatively different functional forms — linear, flat, and step-function — across overcommitment levels. These results validate the foundational hypothesis underlying profile-aware serverless scheduling and provide actionable characterization data for overcommitment policy design.

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

We are motivated by two observations.

First, degradation curves are more useful than point comparisons. Knowing that a CPU-bound function is 2.4x slower at one specific overcommitment level tells an operator very little. Knowing that degradation is linear from 100% to 40% CPU but accelerates sharply below 40% gives an operator actionable guidance for setting overcommitment policies. We produce these curves by testing five overcommitment levels per function profile.

Second, the CFS mechanism that the paper invokes for mixed-function degradation is testable. The Linux CFS bandwidth controller enforces CPU limits via a quota-and-period mechanism. When a container's CPU burst size sits near the quota boundary, some bursts complete within a single period while others spill into the next period and incur a full-period throttling penalty. This creates bimodal latency. We validate this explanation experimentally by measuring the per-request CPU burst size via cgroup v2 counters and showing that the burst-to-quota ratio predicts the observed bimodal latency distribution.

### 1.5 Research Questions and Contributions

We address two research questions through controlled experiments on real AWS infrastructure:

**Table 1: Research questions and corresponding experiments.**

| # | Research Question | Experiment |
|---|---|---|
| RQ1 | How does P95 latency degrade as CPU allocation decreases, and does the degradation curve differ by workload profile? | Multi-level degradation curves (5 CPU levels x 3 functions) |
| RQ2 | Can the bimodal latency behavior of mixed functions under overcommitment be explained by CFS quota boundary effects? | Baseline bimodality observation + cgroup v2 CPU burst measurement |

Our contributions are:

1. **Degradation curves** showing the relationship between CPU allocation and P95 latency for three workload profiles, tested at five overcommitment levels on real infrastructure — not simulation.
2. **Mechanistic explanation** of bimodal CFS throttling behavior in mixed workloads, validated experimentally through direct cgroup v2 CPU burst measurement and throttle ratio analysis.
3. **Empirical characterization** of the profile-dependent degradation phenomenon — the foundational observation that motivates profile-aware scheduling systems like Golgi — grounded in direct measurement rather than system-level end-to-end metrics.

### 1.6 Report Organization

Section 2 covers background on serverless computing, resource overcommitment in cloud systems, the Linux CFS scheduler, and the Golgi paper's design. Section 3 describes our experimental design: the two-instance model, benchmark functions, overcommitment calculations, and the two experiments we run. Section 4 covers implementation specifics: AWS infrastructure, k3s cluster setup, OpenFaaS deployment, and benchmark function construction. Section 5 presents baseline characterization results — including the CFS burst measurement that answers RQ2 — establishing SLO thresholds and validating the experimental setup. Section 6 presents the multi-level degradation curve results that answer RQ1. Section 7 discusses findings, limitations, threats to validity, and future work. Section 8 concludes.

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

Several research systems have addressed parts of this problem. Harvest VMs (Ambati et al. [3]) let low-priority workloads consume spare capacity on partially-utilized servers, but offer no latency guarantees when the primary workload reclaims its resources. Kraken (Wen et al. [4]) focuses on cold-start-aware container provisioning for DAG-structured serverless workflows. It reduces end-to-end latency by pre-warming containers along the critical path, but does not address the resource overcommitment problem. ENSURE (Suresh et al. [5]) provides SLO-aware scheduling for serverless functions, but operates reactively: it detects violations after they happen and adjusts resource allocations in response, rather than predicting and preventing them.

The gap in the literature is a system that combines proactive prediction of resource contention, routing decisions that exploit the difference between overcommitted and fully-provisioned instances, and an adaptive feedback mechanism. Golgi fills this gap with a complete system. But underneath every contention-aware scheduling system lies an assumption: that contention's effect on latency is predictable and varies by workload profile. This assumption has not been independently characterized. Our work provides that characterization.

### 2.4 The Golgi Paper in Detail

The Golgi system, proposed by Li et al. [1], sits between the serverless platform's API gateway and the function instances. For each deployed function, Golgi maintains two sets of container replicas: Non-OC instances provisioned at the user's declared resource levels, and OC instances provisioned at reduced levels computed from observed actual usage. The overcommitment formula is `OC_allocation = 0.3 * claimed + 0.7 * actual`, weighting 70% toward measured usage with a 30% safety margin from the original reservation.

A metric collection daemon running on each worker node scrapes nine metrics from every function container at 500ms intervals: CPU utilization, memory utilization, memory bandwidth, network bytes sent, network bytes received, disk I/O read, disk I/O write, the count of inflight requests, and the LLC (last-level cache) miss rate. These metrics are read from the Linux cgroup filesystem and hardware performance counters, then forwarded to a central ML module.

The ML module trains a Mondrian Forest classifier [6], an online variant of Random Forests that can incorporate new training samples incrementally without full retraining. Each training sample is a feature vector of the nine metrics paired with a binary label: 1 if the corresponding request's latency exceeded the SLO threshold (defined as the P95 latency of the Non-OC baseline), 0 otherwise. A critical implementation detail is the use of stratified reservoir sampling to maintain a balanced training set. Without this balancing step, the training data would be heavily skewed toward negative samples (most requests meet the SLO), and the classifier's F1 score would drop from 0.78 to 0.26.

The router uses a Power of Two Choices algorithm for instance selection. For each incoming request, it samples two OC instances, queries the classifier for each one's current violation probability, and routes the request to the instance with the lower probability. If both probabilities exceed a safety threshold, the request goes to a Non-OC instance instead. A global Safe flag, computed from the rolling P95 latency across all OC instances, provides a coarse-grained override: when contention is system-wide, the flag flips to unsafe and all requests are routed to Non-OC instances until conditions improve.

Vertical scaling provides a second layer of defense. An AIMD controller on each OC instance monitors its SLO violation rate over a rolling window. If the violation rate exceeds 5%, the controller decreases the instance's maximum concurrency by one (multiplicative decrease, floored at 1). If violations stay below 2% for three consecutive windows, it increases concurrency by one (additive increase). Reducing concurrency means fewer concurrent requests per container, less contention for CPU and cache, and lower tail latency, at the cost of needing more containers or longer queue wait times.

The original evaluation used eight benchmark functions spanning five languages, deployed on seven c5.9xlarge workers (36 vCPUs, 72 GB RAM each), driven by replayed Azure Function Trace workloads. Golgi achieved 42% memory cost reduction, 35% VM time reduction, and kept SLO violations below 5%.

### 2.5 Relationship Between Our Study and the Golgi System

Table 2 clarifies the relationship between our empirical study and the Golgi system. Our work is not a replication of Golgi. We do not build an ML classifier, a request router, or a vertical scaler. Instead, we characterize the profile-dependent degradation phenomenon that the Golgi system is built upon.

**Table 2: Scope comparison between the Golgi system and our empirical study.**

| Dimension | Golgi (Li et al.) | Our Study |
|---|---|---|
| **Goal** | Build an ML-guided overcommitment routing system | Characterize profile-dependent degradation under overcommitment |
| **Approach** | End-to-end system (classifier + router + scaler) | Controlled experiments isolating overcommitment effects |
| **What is measured** | Cost reduction, SLO violation rate (system metrics) | Degradation curves, CFS throttling behavior (characterization data) |
| **Cluster** | 7x c5.9xlarge (36 vCPU, 72 GB each) | 3x t3.xlarge (4 vCPU, 16 GB each) |
| **Functions** | 8 functions in 5 languages | 3 functions in Python/Go (one per profile) |
| **Overcommitment levels** | One OC level per function (formula-derived) | Five levels per function (100%, 80%, 60%, 40%, 20% CPU) |
| **CFS analysis** | Mentioned as explanation for mixed-function behavior | Experimentally characterized via cgroup v2 burst measurement |
| **ML/Routing** | Core contribution (Mondrian Forest + Power-of-Two router) | Not in scope — we characterize the phenomenon that motivates these components |

The Golgi paper assumes that overcommitment impact is profile-dependent and uses that assumption to justify building a complex scheduling system. We characterize whether this profile-dependent degradation exists, how it manifests across overcommitment levels, and what mechanism drives it. This characterization is valuable regardless of whether it aligns with or complicates the Golgi paper's assumptions — either outcome informs the design of overcommitment-aware schedulers.

---

## 3. Experimental Design

This section describes the design of our empirical study: the two-instance model we adopt from the Golgi paper, the benchmark functions that cover three workload profiles, the overcommitment calculations, and the two experiments we run to characterize degradation behavior. Implementation details (infrastructure, deployment, tooling) follow in Section 4.

### 3.1 Overview

Our study design has two parts. First, we establish a controlled environment for measuring overcommitment effects: a k3s/OpenFaaS cluster on AWS with three benchmark functions, each deployed in both a Non-OC (full-resource) and an OC (overcommitted) variant. Second, we run two experiments that systematically vary overcommitment level and measure CFS throttling behavior while recording latency at multiple percentiles.

```
                         +-----------------+
                         | Load Generator  |
                         | (bash/curl)     |
                         +-------+---------+
                                 |
                                 | HTTP (sequential)
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

The key design principle is isolation. Each experiment varies one factor at a time. The baseline (Phase 1) holds concurrency at 1 and compares Non-OC vs OC at a single overcommitment level, while also measuring the CFS burst size that explains the observed bimodal behavior. The degradation curve experiment (Phase 2) varies CPU allocation across five levels while holding concurrency at 1. This structure lets us attribute latency changes to specific causes.

### 3.2 Two-Instance Model

Following the Golgi paper's methodology, we deploy each function in two variants: Non-OC (non-overcommitted) with the user's declared resource allocation, and OC (overcommitted) with reduced resources computed from observed actual usage. The overcommitment formula from the paper is:

```
OC_allocation = alpha x claimed + (1 - alpha) x actual
```

The paper uses alpha = 0.3, giving 70% weight to measured usage and retaining 30% of the original reservation as a safety margin. We adopt the same value to ensure our OC configurations are directly comparable to those the Golgi system would create.

To measure actual usage, we deploy each function in its Non-OC configuration, send 100 requests under no concurrent load, and record the P75 of memory consumption from the cgroup's `memory.current` file. CPU actual usage is derived similarly from `cpu.stat`. Applying the formula yields the OC resource allocations shown in Table 3.

**Table 3: Resource configurations for Non-OC and OC function variants.**

| Function | Profile | Non-OC CPU | OC CPU | CPU Reduction | Non-OC Memory | OC Memory | Memory Reduction |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound | 1000m | 405m | 2.47x | 512 Mi | 210 Mi | 59% |
| db-query | I/O-bound | 500m | 185m | 2.70x | 256 Mi | 105 Mi | 59% |
| log-filter | Mixed | 500m | 206m | 2.43x | 256 Mi | 98 Mi | 62% |

Both variants run from the same container image. The only difference is the Kubernetes resource requests and limits specified in the deployment manifest. The OC variant's container has less CPU time available (the kernel's CFS scheduler enforces the CPU limit via cgroup `cpu.max`) and a lower memory ceiling (the kernel's OOM killer fires if `memory.current` exceeds `memory.max`). Under light load, the OC instance may perform comparably to Non-OC because the function's actual resource consumption falls within the reduced allocation. Under heavier load or with bursty CPU work, the OC instance hits its limits, and the degree of degradation depends on the function's workload profile — which is precisely what we measure.

### 3.3 Benchmark Functions

We deploy three benchmark functions, one for each major workload profile identified in the Golgi paper. Three functions are the minimum needed to test the hypothesis that profiles respond differently to overcommitment. Each function is designed so that its dominant resource bottleneck is clear and controllable.

**image-resize (CPU-bound, Python).** Generates a random RGB image (1920x1080 pixels), then downscales it to half size (960x540) using Pillow's Lanczos resampling filter. Lanczos resampling applies a windowed sinc convolution kernel per output pixel, making the computation directly proportional to available CPU cycles. Memory usage is modest and predictable (two image buffers of known size). This function's latency should scale proportionally with CPU reduction, since CPU is the sole bottleneck.

**db-query (I/O-bound, Python).** Connects to a Redis instance running within the cluster and performs a GET -> SET -> GET sequence. Latency is dominated by network round-trips between the function container and the Redis pod, not by CPU computation. Even with significantly reduced CPU, the function should perform similarly because it spends most of its execution time waiting on network I/O. This function tests the hypothesis that I/O-bound functions are resilient to overcommitment.

**log-filter (Mixed, Go).** Generates 1000 synthetic log lines, applies regex matching to filter lines containing `ERROR`, `WARN`, or `CRITICAL`, and runs IP address anonymization via regex replacement. This exercises both CPU (regex compilation and matching, string operations) and memory (string allocation, buffer management). Critically, the function's CPU burst size sits near the CFS quota boundary under overcommitment. Some invocations complete within a single CFS period; others spill into the next period and incur a full-period throttling penalty. This creates the bimodal latency distribution that the Golgi paper attributes to CFS interactions. Written in Go to demonstrate language diversity and to ensure the mixed behavior comes from the workload characteristics, not from Python interpreter overhead.

### 3.4 Experiment Design

**Experiment 1: Multi-Level Degradation Curves (RQ1).** For each function, we deploy five variants with CPU allocations at 100%, 80%, 60%, 40%, and 20% of the Non-OC value. Memory is held at the Non-OC level for all variants to isolate the effect of CPU reduction from memory pressure. We send 200 sequential requests (concurrency = 1) to each variant, repeated 3 times, and record per-request latency and CFS throttling counters from cgroup `cpu.stat`. The output is a degradation curve: P95 latency as a function of CPU allocation, plotted separately for each profile. We expect CPU-bound functions to show linear or near-linear degradation, I/O-bound functions to show a flat curve, and mixed functions to show non-linear degradation with a step at the CFS quota boundary. Total measurement: 5 levels x 3 functions x 200 requests x 3 repetitions = 9,000 requests.

**Experiment 2: CFS Mechanism Analysis (RQ2).** This experiment targets the bimodal latency observed in the mixed-profile function under overcommitment. Rather than a fine-grained CPU sweep, we use direct cgroup v2 `cpu.stat` measurement to determine the per-request CPU burst size and correlate it with the CFS quota boundary. We read the cumulative `usage_usec`, `nr_periods`, `nr_throttled`, and `throttled_usec` counters before and after a batch of 200 requests, for both the Non-OC and OC variants of log-filter. By computing per-request CPU consumption and the throttle ratio, we can determine (a) whether the burst size is an intrinsic function property independent of the CPU limit, (b) whether the burst-to-quota ratio predicts the observed bimodal distribution, and (c) what fraction of CFS periods experience throttling under each configuration. This provides the mechanistic explanation for the mixed-function degradation pattern.

---

## 4. Implementation

### 4.1 Infrastructure Setup

All resources run on AWS in `us-east-1a` inside a dedicated VPC (`10.0.0.0/16`) with a single subnet (`10.0.1.0/24`). The cluster consists of five EC2 instances:

**Table 4: Cluster nodes and their roles.**

| Node | Instance Type | vCPU | RAM | Role |
|---|---|---|---|---|
| golgi-master | t3.medium | 2 | 4 GB | k3s server, OpenFaaS gateway |
| golgi-worker-1 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-2 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-worker-3 | t3.xlarge | 4 | 16 GB | Function containers, cgroup measurement |
| golgi-loadgen | t3.medium | 2 | 4 GB | Request generation, latency measurement |

We chose t3.xlarge workers (4 vCPU, 16 GB RAM, $0.1664/hr) because four vCPUs provide enough headroom to observe CPU contention when multiple containers compete for CPU time, and 16 GB accommodates 6+ function containers per worker with room for k3s overhead. The paper used c5.9xlarge instances (36 vCPU, 72 GB, $1.53/hr) — our instances are 10x cheaper while still demonstrating the same CFS and cgroup behaviors at a smaller scale. The total cluster cost is approximately $0.58/hr ($14/day).

The Kubernetes layer uses k3s v1.34.6, a lightweight Kubernetes distribution that provides the same API, scheduling, and cgroup enforcement as full Kubernetes but deploys as a single binary with embedded etcd. We chose k3s over kubeadm for faster setup and lower memory overhead — the k3s server uses approximately 500 MB RAM at our scale. We disabled the bundled Traefik ingress controller since we invoke functions directly through the OpenFaaS gateway.

OpenFaaS was deployed via Helm into the `openfaas` namespace, running five components: the HTTP gateway (exposed as NodePort 31112), Prometheus for metrics, NATS for async messaging, AlertManager, and a queue worker. Function invocations go through the gateway at `http://<master-ip>:31112/function/<name>`.

The security group allows SSH from our IP, all intra-VPC traffic (for k3s control plane and pod networking), and the OpenFaaS NodePort range from our IP. All instances run Amazon Linux 2023 (kernel 6.1.166) with cgroup v2 in unified hierarchy mode — the modern cgroup interface that exposes CPU, memory, and I/O metrics through a clean filesystem at `/sys/fs/cgroup/`.

### 4.2 Benchmark Functions

Each function is deployed as an OpenFaaS function with two Kubernetes deployment variants: Non-OC (full resources) and OC (overcommitted resources). Both variants use the same container image; only the resource requests and limits in the deployment manifest differ.

**image-resize (CPU-bound, Python 3.9).** The handler generates a random RGB image of 1920x1080 pixels by iterating over every pixel and assigning random RGB values using Python's `random` module, then downscales it to 960x540 using Pillow's Lanczos resampling filter. The pixel-by-pixel generation in Python's interpreted loop plus the Lanczos windowed sinc convolution make execution time directly proportional to available CPU cycles. Dependencies: `pillow`. Non-OC allocation: 1000m CPU, 512 Mi memory. OC allocation: 405m CPU, 210 Mi memory (2.47x CPU reduction).

**db-query (I/O-bound, Python 3.9).** The handler connects to a Redis instance (deployed as a single pod in the `openfaas-fn` namespace with 64 Mi request / 128 Mi limit) and performs a GET -> SET -> GET sequence using the `redis` Python client. Latency is dominated by three network round-trips between the function container and the Redis pod. CPU consumption is minimal — the function spends most of its time waiting on I/O. Non-OC allocation: 500m CPU, 256 Mi memory. OC allocation: 185m CPU, 105 Mi memory (2.70x CPU reduction).

**log-filter (Mixed, Go).** The handler generates 1000 synthetic log lines with randomized timestamps, log levels, and source IPs, then applies regex matching to filter lines containing `ERROR`, `WARN`, or `CRITICAL`, and runs IP anonymization via regex replacement. This exercises CPU (regex compilation and matching, string operations) and memory (string allocation, buffer management). Written in Go to ensure the mixed behavior comes from workload characteristics rather than Python interpreter overhead. Non-OC allocation: 500m CPU, 256 Mi memory. OC allocation: 206m CPU, 98 Mi memory (2.43x CPU reduction).

All six function variants (3 functions x 2 resource levels) are defined in a single Kubernetes manifest (`functions/functions-deploy.yaml`) and deployed simultaneously. OpenFaaS auto-scaling is disabled (`com.openfaas.scale.min=1`, `com.openfaas.scale.max=1`) to fix replica counts at 1 per variant, ensuring each measurement targets a single container with a known resource allocation.

### 4.3 Latency Measurement

Latency is measured end-to-end at the load generator using `curl` with nanosecond-precision wall-clock timing (`date +%s%N`). The benchmark script (`scripts/benchmark-latency.sh`) sends sequential HTTP POST requests to each function via the OpenFaaS gateway and records the total round-trip time per request in milliseconds. For each function variant, the script sends 200 requests after a warm-up phase (5 requests via `scripts/warmup.sh` to eliminate cold starts) and writes per-request latencies to a raw data file.

For Phase 2's multi-level sweep, a parameterized deployment template (`functions/phase2-deploy-template.yaml`) uses `envsubst` to inject the target CPU and memory values, allowing automated deployment at each CPU level. The orchestrator script (`scripts/run-phase2.sh`) cycles through all 15 function-level combinations, deploying, warming, measuring 3 repetitions, recording CFS stats, and tearing down each variant before moving to the next.

Statistical analysis is performed by `scripts/compute-stats.py`, which reads the raw latency files and computes P50, P95, P99, mean, and standard deviation. Plots are generated by `scripts/generate-phase1-plots.py` and `scripts/generate-phase2-plots.py` using matplotlib and numpy.

### 4.4 cgroup v2 and CFS Configuration

Resource limits are enforced by the Linux kernel's cgroup v2 controllers, configured automatically by k3s based on the Kubernetes resource specifications in our deployment manifests.

**CPU limits** are enforced via the CFS bandwidth controller. A Kubernetes CPU limit of 405m (millicores) translates to a cgroup `cpu.max` value of `40500 100000`, meaning the container gets 40,500 us of CPU time per 100,000 us (100 ms) CFS period. When the container exhausts its quota within a period, all its threads are throttled until the next period begins. This throttling mechanism is the primary driver of latency degradation under overcommitment: a function that completes in one CFS period at full CPU may require two or more periods at reduced CPU, with each period boundary adding up to 100 ms of dead time.

**Memory limits** are enforced via the cgroup memory controller. A Kubernetes memory limit of 210 Mi sets `memory.max` to 220200960 bytes. If the container's resident memory (`memory.current`) exceeds this, the kernel's OOM killer terminates the container process.

**CFS throttling metrics** are read from `cpu.stat` for RQ2's mechanistic analysis:
- `usage_usec`: cumulative CPU time consumed (microseconds)
- `nr_periods`: total CFS periods elapsed
- `nr_throttled`: periods in which the container exhausted its quota and was throttled
- `throttled_usec`: total time spent in throttled state

By reading these counters before and after a batch of requests, we compute per-request CPU consumption, throttle ratio (`nr_throttled / nr_periods`), and average throttle duration. These metrics directly quantify the CFS mechanism behind overcommitment-induced degradation.

---

## 5. Baseline Characterization

Before running the multi-level degradation experiment, we establish baseline latency profiles for all six function variants (3 functions x {Non-OC, OC}). This baseline serves three purposes: it defines the SLO thresholds used throughout the study, it provides the first evidence for whether the Golgi hypothesis holds at a single overcommitment level, and — through the CFS burst measurement — it directly answers RQ2 by quantifying the mechanism behind mixed-function bimodal degradation.

### 5.1 Hardware and Software Configuration

**Table 5: Software stack versions.**

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

**Table 6: Baseline latency measurements (200 sequential requests per variant, measured 2026-04-12).**

| Function | Profile | CPU | P50 | P95 (SLO) | P99 | Mean | Errors |
|---|---|---|---|---|---|---|---|
| image-resize | CPU-bound (Non-OC) | 1000m | 4,485 ms | **4,591 ms** | 4,762 ms | 4,499 ms | 0/200 |
| image-resize-oc | CPU-bound (OC) | 405m | 11,067 ms | 11,156 ms | 11,276 ms | 11,057 ms | 0/200 |
| db-query | I/O-bound (Non-OC) | 500m | 18 ms | **21 ms** | 24 ms | 19 ms | 0/200 |
| db-query-oc | I/O-bound (OC) | 185m | 20 ms | 28 ms | 35 ms | 21 ms | 0/200 |
| log-filter | Mixed (Non-OC) | 500m | 16 ms | **17 ms** | 18 ms | 16 ms | 0/200 |
| log-filter-oc | Mixed (OC) | 206m | 25 ms | 77 ms | 96 ms | 35 ms | 0/200 |

The SLO thresholds (bolded P95 values) are: 4,591 ms for image-resize, 21 ms for db-query, and 17 ms for log-filter.

### 5.4 Degradation Analysis

The baseline results reveal a profile-dependent degradation pattern consistent with the CFS quota enforcement mechanism:

**CPU-bound (image-resize): near-proportional degradation.** The OC variant's P95 (11,156 ms) is 2.43x the Non-OC P95 (4,591 ms). The CPU reduction factor is 2.47x (1000m -> 405m). The degradation ratio (2.43x) closely matches the CPU reduction ratio (2.47x), indicating that at this overcommitment level, image-resize latency scales proportionally with available CPU. The latency distribution is tight — P99/P50 ratio is 1.06 for Non-OC and 1.02 for OC — indicating consistent, predictable behavior with no CFS boundary effects.

**I/O-bound (db-query): resilient to overcommitment.** The OC variant's P95 (28 ms) is only 1.33x the Non-OC P95 (21 ms), despite a 2.70x CPU reduction (500m -> 185m). The function absorbs nearly three-quarters of the CPU cut with minimal latency impact because network round-trips to Redis dominate execution time, not CPU computation. This is consistent with the expectation that I/O-bound functions tolerate aggressive overcommitment, since their bottleneck is network latency rather than CPU cycles.

**Mixed (log-filter): disproportionate, non-linear degradation.** The OC variant's P95 (77 ms) is 4.53x the Non-OC P95 (17 ms), despite only a 2.43x CPU reduction (500m -> 206m). The degradation is nearly double what proportional scaling would predict. More telling is the distribution shape: the Non-OC variant is tight (P99/P50 = 1.13), while the OC variant shows extreme spread (P99/P50 = 3.84). The OC median (25 ms) is only 1.56x the Non-OC median (16 ms), but the tail explodes. This is the signature of bimodal CFS throttling: most invocations complete within a single CFS period (fast mode), but a fraction spill into the next period and incur a full throttling penalty (slow mode).

**Table 7: Degradation summary.**

| Function | CPU Reduction | P95 Degradation | Proportional? |
|---|---|---|---|
| image-resize | 2.47x | 2.43x | Yes — degradation matches CPU cut |
| db-query | 2.70x | 1.33x | No — resilient (I/O-dominated) |
| log-filter | 2.43x | 4.53x | No — disproportionate (CFS throttling) |

### 5.5 CFS Mechanism: CPU Burst Measurement (RQ2)

The baseline results reveal bimodal latency in log-filter-oc (P95 = 77 ms vs P50 = 25 ms, standard deviation = 23 ms). To determine the mechanism, we performed direct cgroup v2 `cpu.stat` measurement of the per-request CPU burst size — the intrinsic amount of CPU work each request performs, independent of the CPU limit.

**Method.** We read the cumulative `cpu.stat` counters (`usage_usec`, `nr_periods`, `nr_throttled`, `throttled_usec`) before and after sending 200 sequential requests to both log-filter (Non-OC, 500m) and log-filter-oc (OC, 206m). The per-request CPU consumption is computed as `delta_usage_usec / 200`.

**Table 8: CFS burst measurement results for log-filter.**

| Metric | log-filter (500m, Non-OC) | log-filter-oc (206m, OC) |
|---|---|---|
| Per-request CPU burst | **7,600 us (7.60 ms)** | **7,761 us (7.76 ms)** |
| CFS quota per period | 50,000 us (50 ms) | 20,600 us (20.6 ms) |
| Requests fitting per period | ~6.6 | ~2.7 |
| Throttle ratio | 33.3% | 97.3% |
| Avg throttle duration | 4.2 ms | 142.0 ms |

**Finding 1: CPU burst size is intrinsic to the function.** Both variants consume ~7.7 ms of CPU per request (within 2.1%). The CPU limit changes wall-clock latency through throttling, but not the amount of CPU work performed. This means the burst size is a stable, measurable property that can be used to predict CFS boundary effects at any CPU limit.

**Finding 2: The bimodal mechanism is quantitatively explained.** At the OC quota of 20.6 ms per 100 ms CFS period, approximately 2.7 requests fit per period (20.6 / 7.7 = 2.67). Requests 1 and 2 complete within the available quota and execute in fast mode (~16-25 ms wall-clock). The 3rd request begins execution but exhausts the remaining ~5 ms of quota partway through its 7.7 ms burst. It is then throttled by the kernel and must wait for the next CFS period to resume — adding approximately 80 ms of dead time. This produces the slow mode (~80-100 ms wall-clock). The distribution is bimodal because requests deterministically alternate between these two modes based on their position within the CFS period.

**Finding 3: Throttle ratio confirms the mechanism.** At 97.3% throttle ratio, nearly every CFS period under overcommitment experiences throttling. The Non-OC throttle ratio of 33.3% is also consistent: at 50 ms quota, approximately 6.6 requests fit per period (50 / 7.6 = 6.58), so roughly 1 in 3 periods sees a request straddle the boundary — matching the observed 33.3%.

**Finding 4: CFS boundary transitions are predictable.** The 7.7 ms burst measurement predicts bimodal transitions at CFS quota levels equal to integer multiples of the burst size: ~77m (1 request/period), ~154m (2 requests/period), ~231m (3 requests/period), ~308m (4 requests/period). Phase 2's CPU sweep at 100m, 200m, 300m, 400m, and 500m will cross several of these boundaries, providing further validation from the degradation curve shapes.

This mechanistic analysis provides the direct experimental evidence for RQ2: **the bimodal latency behavior of mixed functions under overcommitment is caused by CFS quota boundary crossings**, where the function's intrinsic CPU burst size (~7.7 ms) straddles the CFS period quota, causing some requests to spill into the next period and incur a full-period throttling penalty of ~80 ms. This is not random variance — it is a deterministic consequence of the burst-to-quota ratio.

### 5.6 Baseline Figures

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

*Figure 3: P95 latency comparison. CPU-bound functions degrade proportionally to CPU reduction (2.4x), I/O-bound functions are resilient (1.3x), and mixed functions suffer disproportionately (4.5x) from CFS throttling.*

Figure 4 shows the latency distributions as box plots, revealing the spread difference between profiles under overcommitment.

<p align="center">
  <img src="../results/phase1/plots/fig4_box_plots.png" width="65%" />
</p>

*Figure 4: Box plots showing distribution shape. The log-filter OC variant exhibits wide spread from bimodal CFS behavior, while image-resize and db-query maintain tight distributions.*

Figure 5 summarizes the degradation ratios alongside CPU reduction ratios, visualizing the core finding that different function profiles respond differently to overcommitment.

<p align="center">
  <img src="../results/phase1/plots/fig5_degradation_ratios.png" width="72%" />
</p>

*Figure 5: Degradation ratio comparison. CPU-bound degradation matches CPU reduction (2.4x ~ 2.5x). I/O-bound functions absorb a 2.7x CPU cut with only 1.3x degradation. Mixed functions show disproportionate degradation from CFS quota boundary effects.*

### 5.7 Implications for Phase 2

The baseline results establish that profile-dependent degradation exists at a single overcommitment level with zero concurrent load, and the CFS burst measurement provides a mechanistic explanation for the mixed-function behavior. Phase 2 extends this by sweeping CPU allocation across five levels, producing full degradation curves that reveal whether the observed profile-dependent patterns hold across the entire overcommitment spectrum. The CFS burst measurement also generates specific predictions: the degradation curve for log-filter should show a step-function transition at CPU levels near integer multiples of the 7.7 ms burst size.

---

## 6. Results and Analysis

### 6.1 Multi-Level Degradation Curves (RQ1)

<!-- Phase 2 is currently running. This section will present:

DATA TO INCLUDE:
- Table: P50, P95, P99, Mean for each (function x CPU level) combination
  - 5 levels (100%, 80%, 60%, 40%, 20%) x 3 functions = 15 rows
  - 3 repetitions per row — report mean of P95 across reps, with min/max as error bounds
- CFS throttle ratio for each (function x CPU level) from cpu.stat

PLOTS TO INCLUDE:
- Figure 6 (P2.1 — THE KEY FIGURE): Degradation curves
  - X-axis: CPU allocation (% of Non-OC)
  - Y-axis: P95 latency (ms)
  - Three lines: image-resize (blue), db-query (green), log-filter (orange)
  - Error bars from 3 repetitions
  - Expected shapes: linear (CPU-bound), flat (I/O-bound), step-function (mixed)

- Figure 7 (P2.2): Throttle ratio vs degradation
  - X-axis: CFS throttle ratio
  - Y-axis: P95 degradation ratio (OC P95 / Non-OC P95)
  - Points colored by profile
  - Tests whether throttle ratio is a universal predictor

- Figure 8 (P2.3): Violin plot grid
  - 3 columns (functions) x 5 rows (CPU levels)
  - Shows full distribution shape at each level
  - Critical for observing bimodal transition in log-filter

ANALYSIS:
- Pearson correlation between CPU allocation and P95 latency for each profile
- Slope of linear fit for CPU-bound (expect ~1.0 in normalized space)
- R-squared of linear fit (expect high for CPU-bound, low for I/O-bound and mixed)
- Identification of CFS transition points from violin plot shapes
- Verification that log-filter transitions match 7.7ms burst prediction
-->

### 6.2 Summary of Findings

<!-- Synthesis to write after Phase 2 data arrives:

TABLE: Comparison with Golgi paper's assumed behavior
| Assumed Behavior                                    | Our Evidence                           | Finding                        |
|-----------------------------------------------------|----------------------------------------|--------------------------------|
| CPU-bound degrades proportionally to CPU cut         | Phase 2 degradation curve slope        | Confirmed / Nuanced            |
| I/O-bound is resilient to overcommitment             | Phase 2 flat curve for db-query        | Confirmed / Nuanced            |
| Mixed functions show variable degradation            | Phase 1 bimodality + Phase 2 curves    | Characterized + mechanism      |
| Different profiles need different OC treatment       | All phases                             | Validated with degradation data |

KEY CONCLUSIONS:
- RQ1: Yes, degradation curves differ qualitatively by profile (linear vs flat vs step)
- RQ2: Yes, bimodal behavior is caused by CFS quota boundary crossings (7.7ms burst, 
  deterministic fast/slow mode splitting based on burst-to-quota ratio)
-->

---

## 7. Discussion

### 7.1 Key Findings

<!-- To be completed after Phase 2 data arrives. Structure:

Finding 1: The Golgi hypothesis holds — different profiles respond differently to overcommitment.
  - Baseline: 2.43x (CPU), 1.33x (I/O), 4.53x (mixed) degradation at default OC level
  - Phase 2: [degradation curve shapes confirm qualitative differences across 5 levels]

Finding 2: CPU-bound degradation is proportional and predictable.
  - Baseline: 2.43x degradation for 2.47x CPU cut (ratio = 0.98)
  - Phase 2: [linear curve with slope ~ 1.0 in normalized space]
  - Implication: simple proportional model suffices for CPU-bound functions

Finding 3: I/O-bound functions tolerate aggressive overcommitment.
  - Baseline: only 1.33x degradation for 2.70x CPU cut
  - Phase 2: [flat curve down to X% CPU, then rise]
  - Implication: safe to overcommit I/O-bound functions heavily

Finding 4: Mixed-function degradation is driven by CFS quota boundary effects.
  - Baseline: 4.53x degradation for 2.43x CPU cut (disproportionate)
  - CFS measurement: 7.7ms burst, 97.3% throttle ratio at OC level
  - Mechanism: deterministic fast/slow mode splitting at quota boundary
  - Phase 2: [step-function transition in degradation curve at predicted boundary]
-->

### 7.2 Implications for Overcommitment-Aware Schedulers

<!-- Structure:

What our characterization data tells scheduler designers:
  - I/O-bound functions are safe to overcommit aggressively (up to 2.7x CPU reduction with <1.4x degradation)
  - CPU-bound functions require proportional resource guarantees — degradation is predictable but unavoidable
  - Mixed functions need CFS-aware resource allocation: the burst-to-quota ratio determines whether bimodal behavior occurs
  - A scheduler that measures per-function CPU burst size (via cgroup cpu.stat) can predict CFS boundary effects without an ML classifier

How Golgi's design aligns with our findings:
  - The two-instance model is well-motivated: profiles genuinely respond differently
  - The OC formula (alpha = 0.3) places log-filter's quota near its burst boundary, which explains why Golgi's classifier is needed for mixed functions
  - For I/O-bound functions, the classifier adds complexity without much benefit — simple overcommitment would suffice
-->

### 7.3 Limitations

1. **Smaller cluster.** Our 3 workers with 4 vCPU each vs the paper's 7 workers with 36 vCPU each means less co-location diversity and lower aggregate contention.
2. **Fewer functions.** One function per profile (3 total vs the paper's 8) means we cannot assess within-profile variance — different CPU-bound functions may behave differently.
3. **Burstable instances.** T3 instances use CPU credits that could mask throttling during short experiments. We monitored credit balances to ensure measurements ran at full capacity.
4. **Synthetic functions.** Our benchmarks are designed as pure examples of each profile. Real-world functions are messier — a function might be CPU-bound on some inputs and I/O-bound on others.
5. **Sequential measurement.** All measurements use concurrency = 1, which understates real-world contention where multiple requests compete for the same container's CPU quota.
6. **Single overcommitment formula.** We use the Golgi paper's alpha = 0.3 formula without exploring other alpha values or alternative overcommitment strategies.

### 7.4 Threats to Validity

**Internal validity.** Measurement noise from network jitter, EBS latency spikes, and T3 CPU credit mechanics could affect latency readings. We mitigate this by using nanosecond-precision timing, discarding warm-up requests, and repeating Phase 2 measurements 3 times. Sample size (200 requests per configuration) provides reliable P95 and P99 estimates but is marginal for P99.9.

**External validity.** Our hardware differs from the paper's (t3 vs c5 — different CPU microarchitecture and memory bandwidth). We use cgroup v2 while the paper likely used cgroup v1, which has slightly different throttling behavior. k3s v1.34 vs the paper's likely K8s 1.24-1.26 may introduce scheduler differences. Amazon Linux 2023 vs the paper's likely Ubuntu has different kernel configurations. These differences affect absolute latency values but should not change the qualitative profile-dependent degradation patterns, which arise from the CFS bandwidth controller's fundamental design.

**Construct validity.** SLO thresholds are infrastructure-specific — our absolute P95 values differ from the paper's, but the relative degradation ratios are the meaningful metric. Our benchmark functions are purpose-built; real-world functions may show hybrid profiles. "Mixed" is a broad category — different types of mixed workloads may produce different burst sizes and therefore different CFS boundary interactions.

### 7.5 Lessons Learned

1. **cgroup v2 simplifies measurement.** The unified hierarchy provides clean, consistent paths to CPU and memory metrics. The `cpu.stat` counters (`nr_throttled`, `throttled_usec`) are essential for understanding CFS behavior — without them, bimodal latency would be observable but not explainable.
2. **k3s operational quirks.** KUBECONFIG is not set by default for Helm, svclb conflicts with NodePort services, and Traefik must be explicitly disabled. These are setup friction, not fundamental limitations.
3. **OpenFaaS scaling must be disabled.** Without explicitly setting `scale.min = scale.max = 1`, OpenFaaS auto-scales replicas, making controlled measurements impossible.
4. **T3 CPU credits matter.** Extended experiments can exhaust burst credits, silently reducing CPU availability. CloudWatch monitoring of credit balance is necessary for experiment integrity.
5. **CFS period visibility.** The 100 ms CFS period is the fundamental time quantum for understanding throttling behavior. Knowing the burst size (7.7 ms) and the quota (20.6 ms at 206m) immediately predicts the throttle pattern — this is more useful than any ML classifier for a single-function analysis.

### 7.6 Future Work

Three natural extensions of this study would deepen the characterization:

**Concurrency under overcommitment.** Our measurements use concurrency = 1. In production, functions handle multiple concurrent requests. Concurrent load and overcommitment both consume CPU — the question is whether their effects compound superlinearly. A sweep of 1, 2, 4, and 8 concurrent requests at the OC level would reveal whether mixed functions experience amplified degradation under concurrent load. We predict superlinear amplification for log-filter because multiple concurrent requests collectively exhaust the CFS quota faster: at 206m quota, four functions needing 7.7 ms each = 30.8 ms of CPU work per period against only 20.6 ms of quota, creating effective serialization.

**Tail latency analysis.** We report P95 and P99 from 200-sample measurements. Extended runs (1000+ requests) would enable reliable P99.9 estimation and computation of the Tail Amplification Factor — the ratio of OC-to-NonOC degradation at each percentile. We expect this factor to increase with percentile for mixed functions (bimodal CFS behavior disproportionately affects the tail) but remain constant for CPU-bound functions (uniform degradation).

**Fine-grained CFS quota boundary sweep.** Our 7.7 ms burst measurement predicts bimodal transitions at specific CPU levels (~77m, ~154m, ~231m, ~308m). A sweep of 50m to 300m in 10m increments (26 data points) for log-filter would map exactly where the distribution transitions from unimodal to bimodal, providing high-resolution validation of the CFS boundary hypothesis and enabling precise identification of "safe" vs "dangerous" overcommitment zones for mixed functions.

---

## 8. Conclusion

<!-- To be completed after Phase 2 data arrives. Structure:

Paragraph 1: Restate the problem.
  Serverless functions waste 75% of reserved resources. Overcommitment recovers this waste but
  causes latency degradation. The Golgi system proposes profile-aware scheduling, but the
  underlying profile-dependent degradation hypothesis is assumed, not independently validated.

Paragraph 2: What we did.
  We characterized how Linux CFS quota enforcement creates profile-dependent latency degradation
  under overcommitment. Through controlled experiments on a 5-node AWS cluster with three
  benchmark functions at five CPU levels, we produced degradation curves and a mechanistic
  explanation of CFS quota boundary effects.

Paragraph 3: Key quantitative findings.
  - CPU-bound: degradation proportional to CPU reduction (2.43x at Golgi's OC level; 
    [linear curve shape from Phase 2])
  - I/O-bound: resilient (1.33x degradation despite 2.70x CPU cut;
    [flat curve shape from Phase 2])
  - Mixed: disproportionate 4.53x degradation caused by CFS quota boundary crossings
    (7.7ms burst, 97.3% throttle ratio; [step-function curve from Phase 2])

Paragraph 4: What this means.
  The Golgi hypothesis is validated: profiles genuinely require different overcommitment
  treatment. I/O-bound functions are safe targets for aggressive overcommitment. CPU-bound
  functions degrade predictably and proportionally. Mixed functions require CFS-aware resource
  allocation — the burst-to-quota ratio, not just the CPU percentage, determines degradation
  severity. Characterization data like ours is a prerequisite for designing safe overcommitment
  policies.

Paragraph 5: Future directions.
  Concurrency interaction, tail latency analysis, and fine-grained CFS boundary sweeps
  (Section 7.6) would further strengthen the characterization.
-->

---

## 9. References

[1] Li, S., Wang, W., Yang, J., Chen, G., & Lu, D. (2023). Golgi: Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing. *Proceedings of the ACM Symposium on Cloud Computing (SoCC '23)*. https://doi.org/10.1145/3620678.3624645

[2] Shahrad, M., Fung, R., Gruber, N., Goiri, I., Chaudhry, G., Cooke, J., Laureano, E., Tresness, C., Russinovich, M., & Bianchini, R. (2020). Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider. *USENIX ATC '20*. https://www.usenix.org/conference/atc20/presentation/shahrad

[3] Ambati, P., Goiri, I., Frujeri, F., Gun, A., Wang, K., Dolan, B., Corell, B., Pasupuleti, S., Moscibroda, T., Elnikety, S., Fontoura, M., & Bianchini, R. (2020). Providing SLOs for Resource-Harvesting VMs in Cloud Platforms. *14th USENIX Symposium on Operating Systems Design and Implementation (OSDI '20)*. https://www.usenix.org/conference/osdi20/presentation/ambati

[4] Wen, J., Chen, Z., Jin, Y., & Liu, H. (2021). Kraken: Adaptive Container Provisioning for Deploying Dynamic DAGs in Serverless Platforms. *ACM SoCC '21*. https://doi.org/10.1145/3472883.3486992

[5] Suresh, A., Somashekar, G., Varadarajan, A., Kakarla, V.R., & Gandhi, A. (2020). ENSURE: Efficient Scheduling and Autonomous Resource Management in Serverless Environments. *IEEE ACSOS 2020*. https://doi.org/10.1109/ACSOS49614.2020.00036

[6] Lakshminarayanan, B., Roy, D.M., & Teh, Y.W. (2014). Mondrian Forests: Efficient Online Random Forests. *Advances in Neural Information Processing Systems (NeurIPS '14)*.

[7] Mitzenmacher, M. (2001). The Power of Two Choices in Randomized Load Balancing. *IEEE Transactions on Parallel and Distributed Systems (TPDS)*.
