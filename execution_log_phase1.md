# Golgi Replication — Execution Log: Phase 1

> **Plan document:** [`GOLGI_REPLICATION_PLAN.md`](GOLGI_REPLICATION_PLAN.md)
> **Previous phase:** [`execution_log_phase0.md`](execution_log_phase0.md)
> **Course:** CSL7510 — Cloud Computing
> **Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)
> **Programme:** M.Tech Artificial Intelligence, IIT Jodhpur
> **Started:** 2026-04-11

This document tracks the execution of Phase 1 — Benchmark Functions. For Phase 0 (AWS infrastructure, k3s, OpenFaaS), see [`execution_log_phase0.md`](execution_log_phase0.md).

---

## Table of Contents

- [Phase 1 — Benchmark Functions](#phase-1--benchmark-functions)
  - [Step 1.1: Deploy Redis](#step-11-deploy-redis--not-started)
  - [Step 1.2: Create OpenFaaS Function YAML](#step-12-create-openfaas-function-yaml--not-started)
  - [Step 1.3: Build and Deploy Functions](#step-13-build-and-deploy-functions--not-started)
  - [Step 1.4: Baseline Latency Measurement](#step-14-baseline-latency-measurement--not-started)
  - [Phase 1 Checkpoint](#phase-1-checkpoint)

---

## Infrastructure Reference (from Phase 0)

Quick reference of resources provisioned in Phase 0 that Phase 1 builds on:

| Resource | Details |
|---|---|
| Master node | `golgi-master` / `44.212.35.8` / `10.0.1.131` / t3.medium |
| Worker-1 | `golgi-worker-1` / `54.173.219.56` / `10.0.1.110` / t3.xlarge |
| Worker-2 | `golgi-worker-2` / `44.206.236.146` / `10.0.1.10` / t3.xlarge |
| Worker-3 | `golgi-worker-3` / `174.129.77.19` / `10.0.1.94` / t3.xlarge |
| LoadGen | `golgi-loadgen` / `44.211.68.203` / `10.0.1.142` / t3.medium |
| OpenFaaS Gateway | `http://127.0.0.1:31112` (on master) / admin / `888c7417424edcbe2a7de236be0fa023` |
| k3s Version | v1.34.6+k3s1 |
| faas-cli | v0.18.8 |
| cgroup | v2 (`cgroup2fs`) |
| SSH key | `C:\Users\worka\.ssh\golgi-key.pem` |

> **Note:** Public IPs may change if instances are stopped and restarted. Always verify with `aws ec2 describe-instances` before starting a session.

---

## Phase 1 — Benchmark Functions

**Goal of Phase 1:** Deploy 3 serverless functions (each in Non-OC and OC variants = 6 total) to OpenFaaS, along with a Redis instance, and measure baseline latency to establish SLO thresholds.

**What gets built in this phase:**
1. A Redis deployment in the `openfaas-fn` namespace (Step 1.1)
2. Three function implementations: `image-resize` (CPU-bound), `db-query` (I/O-bound), `log-filter` (mixed) (Step 1.2)
3. Six OpenFaaS function deployments (3 Non-OC + 3 OC with reduced resources) (Step 1.3)
4. Baseline P95 latency measurements that become the SLO thresholds for the ML classifier (Step 1.4)

**Functions and their resource configurations:**

| Function | Profile | Non-OC Memory | Non-OC CPU | OC Memory | OC CPU |
|---|---|---|---|---|---|
| image-resize | CPU-bound | 512 Mi | 1000m | 210 Mi | 405m |
| db-query | I/O-bound | 256 Mi | 500m | 105 Mi | 185m |
| log-filter | Mixed | 256 Mi | 500m | 98 Mi | 206m |

OC allocations use the paper's formula: `OC = 0.3 × claimed + 0.7 × actual_usage`

---
