# Pre-Phase-2: CPU Burst Size Measurement

**Date:** 2026-04-12
**Purpose:** Measure average CPU time per request to anchor Phase 5's CFS boundary sweep design.

## Methodology

Read cgroup v2 `cpu.stat` (`usage_usec`, `nr_periods`, `nr_throttled`, `throttled_usec`) on the
worker node before and after sending 200 sequential requests. Compute delta / N for per-request averages.

- Requests: 200 sequential (same as Phase 1 methodology)
- Payload: `{"lines":100,"pattern":"ERROR"}`
- Both OC and Non-OC variants measured as control

## Raw Data

### log-filter-oc (206m CPU, worker-3)

| Field | Before | After | Delta |
|---|---|---|---|
| usage_usec | 1,805,591 | 3,357,791 | **1,552,200** |
| user_usec | 1,582,278 | 2,939,767 | 1,357,489 |
| system_usec | 223,312 | 418,023 | 194,711 |
| nr_periods | 308 | 383 | 75 |
| nr_throttled | 63 | 136 | 73 |
| throttled_usec | 5,942,784 | 16,308,664 | 10,365,880 |

### log-filter (Non-OC, 500m CPU, worker-2)

| Field | Before | After | Delta |
|---|---|---|---|
| usage_usec | 1,767,194 | 3,287,250 | **1,520,056** |
| user_usec | 1,572,569 | 2,938,690 | 1,366,121 |
| system_usec | 194,624 | 348,559 | 153,935 |
| nr_periods | 278 | 311 | 33 |
| nr_throttled | 1 | 12 | 11 |
| throttled_usec | 24,774 | 71,480 | 46,706 |

## Per-Request Averages

| Metric | OC (206m) | Non-OC (500m) |
|---|---|---|
| **Avg CPU/request** | **7,761 us (7.76 ms)** | **7,600 us (7.60 ms)** |
| User CPU | 6,787 us (6.79 ms) | 6,831 us (6.83 ms) |
| System CPU | 974 us (0.97 ms) | 770 us (0.77 ms) |
| Quota (us/period) | 20,600 | 50,000 |
| Throttle ratio | 73/75 = **97.3%** | 11/33 = 33.3% |
| Avg throttle duration | 142.0 ms | 4.2 ms |
| Burst/Quota ratio | 0.377 | 0.152 |

## Key Findings

### 1. Burst size is function-intrinsic

Both variants use **~7.7 ms CPU per request** (OC: 7.76 ms, Non-OC: 7.60 ms). The 2% difference
is within measurement noise. This confirms the burst size is determined by the workload, not by
the resource limit.

### 2. OC variant is at 100% quota utilization

- Total CPU demand: 1,552,200 us
- Total quota available: 75 periods x 20,600 us = 1,545,000 us
- **Utilization: 100.5%** — the function consumes essentially its entire quota

### 3. Bimodality mechanism

At 206m quota (20,600 us/period) with 7,681 us/request burst, the function processes
**~2.7 requests per CFS period** before exhausting its quota:

- Requests 1-2 in a period: complete fast (~8-16 ms wall time)
- Request 3 (partial): starts with remaining quota (~5,238 us), gets throttled mid-execution
  when quota exhausted, resumes in next period → **+80-100 ms added latency**

This creates the bimodal distribution observed in Phase 1:
- **Fast mode:** ~16-25 ms (request completes within available quota)
- **Slow mode:** ~50-97 ms (request straddles period boundary, waits for next period)

The 97.3% throttle ratio means nearly every period triggers throttling — the last request
in almost every period hits the boundary.

### 4. Non-OC throttling is minimal but non-zero

Even at 500m (50,000 us/period), the Non-OC variant shows 33% throttle ratio with 11 throttle
events. However, average throttle duration is only 4.2 ms (vs 142 ms for OC), explaining why
it doesn't produce observable bimodality. The function can process ~6.5 requests per period at
500m — the quota boundary is crossed less frequently and the wait time is much shorter.

## Implications for Phase 5

The burst size of ~7.7 ms means:

- **Phase 5 sweep range:** 50m to 300m in 10-25m increments
- **Transition zones** (where quota = integer multiples of burst):
  - ~77m (1 req/period — heavily throttled, most requests spill)
  - ~154m (2 req/period — every other request may straddle boundary)
  - ~231m (3 req/period — similar to current 206m)
  - ~308m (4 req/period — less frequent straddling)
- **Current 206m sits between the 2x and 3x transition** — the function fits 2.7 requests
  per period, meaning roughly every 3rd request straddles the boundary.
- The bimodality should shift as we move through these transitions — different fractions
  of requests will hit the slow path at each level.

## Phase 5 Recommended Design

Sweep 100m to 300m in 10m increments (21 data points):

| Range | Expected behavior |
|---|---|
| 50-70m | Most requests throttled, near-uniform slow |
| 80-150m | 1-2 req/period, high throttle ratio, strong bimodality |
| 150-230m | 2-3 req/period, moderate bimodality (current regime) |
| 230-300m | 3-4 req/period, bimodality weakening |
| 300m+ | Bimodality largely gone, fast-mode dominant |

Collect 200 requests + cpu.stat at each level to track how the throttle ratio
and bimodal split evolve across the sweep.
