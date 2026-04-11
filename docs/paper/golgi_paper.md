# 📄 Deep Analysis: Golgi — Performance-Aware, Resource-Efficient Function Scheduling for Serverless Computing

> **Reading Framework:** Ramdas 3-Pass Methodology (CMU)
> **Audience:** Grade 12 student with basic calculus and cloud awareness
> **Stance:** Explanatory + Critical (Devil's Advocate throughout)
> **Paper Venue:** ACM SoCC 2023 — Best Paper Award
> **Authors:** Suyi Li, Wei Wang (HKUST), Jun Yang, Guangzhen Chen, Daohe Lu (WeBank)

---

## 📋 Table of Contents

1. [Pre-Reading: What Kind of Paper Is This?](#pre-reading)
2. [Background: Concepts You Need to Know First](#background)
3. [PASS 1 — The Jigsaw: What Does This Paper Do?](#pass1)
4. [PASS 2 — The Scuba Dive: How Does It Work?](#pass2)
   - [The Problem in Depth](#problem-depth)
   - [Golgi's Three Core Ideas](#three-ideas)
   - [The ML Model: Mondrian Forest](#mondrian)
   - [The Routing Logic](#routing)
   - [Vertical Scaling](#vertical)
   - [Devil's Advocate — Critical Analysis](#devils)
5. [PASS 3 — The Swamp: Deep Design Examination](#pass3)
   - [Design Choices Under the Microscope](#design-choices)
   - [Experimental Methodology Scrutiny](#exp-scrutiny)
   - [Stress Testing the Logic](#stress)
   - [Research Ideas Generated](#research-ideas)
6. [Final Verdict and Summary Table](#verdict)

---

<a name="pre-reading"></a>
## 🔭 Pre-Reading: What Kind of Paper Is This?

Before diving in, let's figure out *what we're dealing with*.

**Paper Type:** This is an **Empirical/Systems paper**. It proposes a new system (Golgi), builds a prototype, and evaluates it with experiments on real cloud hardware. There are no mathematical theorems being proved in the traditional sense — instead, the "proof" is in the experimental results showing the system works.

**Why this matters for reading strategy:** For empirical papers, the *figures and tables ARE the argument*. If the numbers don't hold up, the text narrative doesn't matter. So we should be especially critical of:
- Are the baselines (the things they compare against) fair and strong?
- Are the experiments run in realistic conditions?
- Do the claimed improvements actually follow from the design, or could something else explain them?

**Credibility check:**
- ✅ Peer-reviewed at ACM SoCC — a top-tier systems conference
- ✅ Won Best Paper Award at SoCC 2023
- ✅ Authors from HKUST (top Asian tech university) + WeBank (real production deployment)
- ✅ Evaluated on both EC2 clusters AND a real production deployment (§8.7)
- ⚠️ No public code repository mentioned in the paper (soft red flag for reproducibility)
- ⚠️ The "production cluster" evaluation (§8.7) is small and under-described

---

<a name="background"></a>
## 🧱 Background: Concepts You Need to Know First

Before the paper makes sense, you need to understand a few terms. Let's define them with plain-English analogies.

### ☁️ Cloud Computing (the basics)
Think of cloud computing like renting electricity instead of buying a generator. Instead of buying your own servers, you rent computing power from AWS, Google Cloud, or Azure. You use what you need and pay for it.

### 🔧 Serverless Computing / Function-as-a-Service (FaaS)
Serverless takes renting a step further. Imagine instead of renting a whole apartment (a server), you just rent a *single room for a few minutes* whenever you need it.

In serverless computing:
- You write a small piece of code called a **"function"** (like "resize this photo" or "check if this user is logged in")
- You upload it to a platform like **AWS Lambda**, **Azure Functions**, or **Google Cloud Functions**
- The platform runs it whenever someone calls it, automatically starts/stops the hardware, and charges you **only for the milliseconds it runs**

**Why developers love it:** You don't think about servers at all. The cloud handles everything.

**Why it's hard to manage (for the cloud provider):** The cloud provider now has to juggle *thousands of these tiny functions* from millions of customers on physical servers in their data centres. That juggling act — deciding which function runs on which server — is called **scheduling**, and it's the core problem this paper tackles.

### 📦 Containers and Sandboxes
Each function runs in an isolated environment called a **container** (think of it like a sealed box). The container ensures that your function doesn't interfere with someone else's function running on the same physical server. Docker containers are the most famous example.

### 💾 Resource Configuration: Memory and CPU
When you deploy a function, you tell the platform "I need 512 MB of memory." The platform reserves exactly that. Based on memory, it also allocates CPU proportionally (more memory = more CPU). This is the standard billing unit for AWS Lambda, Azure Functions, etc.

### 📊 Latency and SLO
**Latency** = how long it takes for your function to respond. If you send a request at time 0 and get a response at time 200ms, your latency is 200ms.

**P95 latency** = the 95th percentile latency. If you process 100 requests, P95 is the latency of the 95th slowest request. It's used instead of "average" because it captures the *tail* — the worst experiences your users might have.

**SLO (Service Level Objective)** = a performance target. Example: "my function's P95 latency must not exceed 200ms." This is the *promise* the cloud provider makes to you.

### 🗜️ Resource Overcommitment
Imagine a hotel with 100 rooms. The hotel knows from experience that on any given night, about 10-15% of reservations are no-shows. So they sell 110 reservations for 100 rooms — this is **overbooking** (overcommitment). Usually it works fine. Occasionally it causes problems.

In cloud computing: a function says it needs 512 MB, but actually only uses 65 MB. If the cloud provider *reduces the actual allocation* to something closer to 65 MB (but still reserves 512 MB on paper for billing), they can fit *more functions* onto the same physical server. More functions per server = less hardware needed = lower costs for the provider.

**The risk:** If too many functions are crammed on one server and they all get busy at the same time, they fight over CPU, memory, network — and everyone slows down. This is **resource contention**.

### 🤖 Machine Learning Classifier
A program that takes in some numbers (called "features" or "inputs") and outputs a category (class). The simplest example: spam vs. not-spam email detection. In Golgi's case: "will this function be slow (positive)?" vs. "will it be fine (negative)?".

**Random Forest** = an ensemble of many simple decision trees that each vote on the answer. Like asking 100 people and taking the majority vote — more reliable than asking one person.

---

<a name="pass1"></a>
## 🧩 PASS 1 — The Jigsaw: What Does This Paper Do?

```
PAPER: Golgi: Performance-Aware, Resource-Efficient Function Scheduling
       for Serverless Computing
AUTHORS: Suyi Li, Wei Wang (HKUST), Jun Yang, Guangzhen Chen, Daohe Lu (WeBank)
VENUE: ACM SoCC 2023 (Best Paper Award)
TYPE: Empirical / Systems Paper
PURPOSE: Understand the problem, solution, and whether results are credible.
PEER-REVIEWED: Yes ✅

PROBLEM:
  In serverless platforms, functions use only ~25% of their reserved resources
  on average, causing massive waste. Simply packing more functions onto servers
  (overcommitment) degrades performance by up to 3×. No existing system can
  do both: reduce costs AND maintain performance guarantees.

WHY HARD:
  You can't profile functions offline (it would corrupt user data), you can't
  predict interference patterns between arbitrary function combinations in
  advance, and scheduling decisions must be made in under 20ms.

MAIN CLAIM:
  Golgi uses 9 low-level runtime metrics + an online ML classifier (Mondrian
  Forest) to predict which overcommitted instances are safe to use, achieving
  42% memory cost reduction and 35% VM time reduction while meeting SLOs —
  outperforming the prior state-of-the-art (Orion) by a large margin.

VERDICT: Proceed to Pass 2 ✅
PRIORITY: High (core paper for the CSL7510 term project)
```

### What is Golgi in one paragraph?

Golgi is a smart traffic cop for serverless cloud functions. It manages two lanes: a "safe but expensive" lane (full resources) and a "cheap but risky" lane (reduced resources). An AI model constantly watches 9 signals from each server and function instance to decide: is the cheap lane safe right now? If yes, send traffic there. If no, stay in the safe lane. A vertical scaling safety net can adjust how many requests each instance handles simultaneously. The result: 42% cheaper operation with virtually no performance loss.

---

<a name="pass2"></a>
## 🤿 PASS 2 — The Scuba Dive: How Does It Work?

<a name="problem-depth"></a>
### 2.1 The Problem in Depth

#### 2.1.1 Why do functions waste so many resources?

The paper identifies two root causes, and both are worth questioning:

**Root Cause 1: Users over-claim memory to get more CPU.**
On platforms like AWS Lambda, CPU is allocated proportionally to memory. If you want 2x more CPU, you must request 2x more memory — even if you don't need the memory. This is a pricing model design flaw on AWS's part, not a user stupidity problem. It creates *structural* overprovisioning.

> 🤔 **Critical Question:** If AWS simply let users specify CPU and memory independently, this root cause would disappear. Why is Golgi solving a *symptom* of a bad pricing model rather than fixing the pricing model? The paper never asks this. It just accepts the current model as a given constraint.

**Root Cause 2: Keep-alive policy causes idle resource waste.**
Serverless platforms keep function containers alive for a few minutes after a request finishes, anticipating more requests soon. This avoids "cold start" delays (the time to launch a new container from scratch). But 91.7% of functions are invoked *less than once per minute*, meaning the container sits idle most of the time, consuming reserved resources.

> 🤔 **Critical Question:** A shorter keep-alive window would reduce idle waste directly. Why not reduce it? The paper acknowledges this but doesn't explain why it can't be the solution. Likely because shorter keep-alive = more cold starts = worse latency. There's a genuine tradeoff here that the paper glosses over.

#### 2.1.2 The Scale of the Problem

The paper cites:
- AWS Lambda: 54% of functions configured with ≥512 MB, but average actual usage = 65 MB (median = 29 MB)
- AliCloud: Most instances use only 20–60% of allocated memory
- Functions use ~25% of reserved resources on average

**Bottom line:** If you could perfectly right-size all functions, you could fit 4× as many functions on the same hardware — a massive cost reduction.

#### 2.1.3 Why Existing Solutions Fail

The paper discusses three existing approaches:

| Approach | What it does | Why it fails |
|---|---|---|
| **Naive Overcommitment** | Just give functions less than they asked for | P95 latency increases by up to 183% — unacceptable |
| **Orion (right-sizing)** | Profile functions over ~25 minutes to find optimal memory size | Takes 25 minutes of SLO violation; doesn't account for colocation interference; P95 latency still increases by 35–132% |
| **Owl (collocation profiles)** | Record which function types can safely be placed together | Only works for 2-function collocations; extending to N functions requires *exponentially* more profiling; doesn't scale |

> 🤔 **Critical thought on Owl:** The paper says extending Owl to 3 function types increases profiling by 26,742×. This number sounds dramatic. Let's verify the logic: If you have N=288 instances of M=2 function types, extending to M=3 function types means you'd need to profile many more combinations. The combinatorial explosion is real — this criticism of Owl is mathematically valid.

> 🤔 **Critical thought on Orion:** The paper says Orion takes 25 minutes of SLO-violating profiling. But Orion only needs to do this once per function deployment (and re-profiles when workload changes, taking up to 3.5 hours). Is it really that bad to have a 25-minute warmup? For long-running deployments, this might be acceptable. The paper is framing this as worse than it might be in practice.

---

<a name="three-ideas"></a>
### 2.2 Golgi's Three Core Ideas

Golgi's architecture has three interlocking pieces. Let's understand each one carefully.

#### 2.2.1 The Two-Instance Model

Golgi maintains two types of instances for every function:

```
┌─────────────────────────────────────────────────────────────────┐
│  For every function, Golgi keeps:                               │
│                                                                 │
│  [Non-OC Instance]              [OC Instance]                  │
│  • Full resources (what user    • Reduced resources            │
│    asked for)                     (based on actual usage)      │
│  • Safe — always meets SLO      • Cheap — but risky            │
│  • Like business class          • Like economy class           │
└─────────────────────────────────────────────────────────────────┘
```

The overcommitted (OC) resource calculation:
```
New allocation = α × (claimed resources) + (1 - α) × (actual usage)
```
Where α ∈ [0, 1]. The paper uses α = 0.3, meaning:
```
New allocation = 0.3 × claimed + 0.7 × actual
```

**Example:** If a function claims 512 MB but actually uses 65 MB:
```
New allocation = 0.3 × 512 + 0.7 × 65 = 153.6 + 45.5 = 199.1 MB
```
So the OC instance gets ~200 MB instead of 512 MB. The server can now fit about 2.5× more instances of this function.

> 🤔 **Critical Question:** Where does α = 0.3 come from? The paper inherits this from Owl [37] and uses it throughout. But is 0.3 optimal? What if it should be 0.5 for some functions and 0.1 for others? The paper doesn't explore this. This is a fixed hyperparameter that is quietly assumed optimal without justification specific to Golgi's context.

---

<a name="mondrian"></a>
### 2.3 The ML Model: Mondrian Forest

This is the heart of Golgi's intelligence. Let's break it down carefully.

#### What problem does the ML model solve?

For each incoming request, Golgi needs to answer: **"If I send this request to that OC instance right now, will the response be too slow?"**

This is a **binary classification problem**:
- Class 1 (Positive): The request will violate the SLO (be too slow) ⛔
- Class 0 (Negative): The request will be fine ✅

The model reads 9 metrics and outputs 0 or 1.

#### The 9 Metrics — A Detailed Look

**Intra-container metrics** (watching what's happening INSIDE the function's container):

| Metric | What it measures | Analogy |
|---|---|---|
| **CPU utilization** | % of allocated CPU currently being used | How hard the kitchen is working |
| **Memory utilization** | % of allocated RAM currently in use | How full the kitchen's pantry is |
| **Inflight requests** | Number of requests currently being processed | How many orders are on the cook's counter right now |

**Collocation interference metrics** (watching what's happening across the WHOLE SERVER):

| Metric | What it measures | Why it matters |
|---|---|---|
| **NetRx** (container) | Bytes received by THIS container per second | Function's own network demand |
| **NetTx** (container) | Bytes sent by THIS container per second | Function's own network output |
| **NodeNetRx** | Total bytes received by the WHOLE SERVER | How congested the shared network is |
| **NodeNetTx** | Total bytes sent by the WHOLE SERVER | Same — shared resource contention |
| **LLCM** (container) | CPU Last-Level Cache misses for THIS container | Memory access speed for this function |
| **NodeLLCM** | CPU LLC misses for the WHOLE NODE | Overall cache pressure from all collocated functions |

**Why LLC cache misses matter (explained simply):**
Your CPU has a small, ultra-fast memory called a "cache." When it needs data, it checks the cache first. If the data isn't there (a "cache miss"), it has to go to slower RAM — taking ~100× longer. When many functions share the same physical CPU, they compete for cache space. One function's data gets evicted to make room for another's, causing more cache misses and slower execution for everyone.

> 🤔 **Critical Question on Metric Selection:** The paper says these 9 metrics "collectively indicate if the request execution can complete within the specified latency." But how were these 9 chosen? The paper just describes them — it never shows that these 9 are *optimal* or *minimal*. What about disk I/O? What about inter-process signal latency? What about memory bandwidth (not just utilization)? The authors don't prove that these 9 are sufficient or that no simpler subset would work equally well.

> 🤔 **Validity concern:** The authors show CDFs (graphs of how these metrics differ between "slow" and "fast" outcomes) in Figure 3. But CDF separation is a *necessary* but not *sufficient* condition for a metric to be useful for classification. Two distributions can look separated visually but still be hard to use for prediction (overlapping tails). The validation test (F1 = 0.71–0.84) is the real evidence, but even that depends on the benchmark functions chosen — which brings us to the next concern.

#### Why Mondrian Forest?

A standard Random Forest is trained in **batch mode**: you collect all training data, train once, then use the model. If the data distribution changes, you retrain.

A **Mondrian Forest** is an *online* version — it can update its model one data point at a time as new requests come in. This is crucial because:

1. You can't pre-profile user functions (would corrupt their data)
2. The runtime conditions change dynamically (more/less traffic, different colocations)
3. You need the model to start working quickly with very little data

**How does a Mondrian Tree work (simplified)?**

Think of a decision tree as a flowchart:
```
Is CPU > 80%?
  → Yes: Is LLCM > 1,000,000?
         → Yes: SLOW (positive)
         → No: MIGHT BE OK, check inflight requests...
  → No: Probably FAST (negative)
```

A regular decision tree picks split points (like "CPU > 80%") by finding the split that best separates slow from fast outcomes in your training data. A Mondrian Tree instead picks split points *randomly*, but proportionally to how wide the data range is in each dimension. This randomness makes the tree:
- Faster to build and update
- Easier to update incrementally with new data
- Theoretically equivalent to batch training as more data arrives (proven in [18])

**The Stratified Sampling trick:**

There's a subtle but important problem: most of the time, OC instances work fine. So the training data has many "negative" labels (everything OK) and few "positive" labels (SLO violation). In the paper's data: negatives outnumber positives by ~10:1.

Training a classifier on heavily imbalanced data is like teaching a spam detector where 95% of emails are legitimate. The easiest strategy for the model is to just say "not spam" for everything — it's right 95% of the time, but completely useless.

Golgi's fix: **reservoir sampling** to artificially balance the data to 50/50 before each training update.

The algorithm (Algorithm 1 in the paper):
- Maintain two separate reservoirs: one for positive examples, one for negative
- Fill each reservoir to N/2 using random replacement
- Combine for a balanced training batch of size N

Effect: F1 score goes from 0.26 (imbalanced) to 0.78 (balanced). This is the single most important engineering detail in the ML design.

> 🤔 **Critical Question:** Reservoir sampling introduces randomness. Different random seeds produce different training sets. Does performance vary significantly across runs? The paper reports single-run F1 scores without error bars on the ML component. This is a gap.

> 🤔 **Model choice question:** The paper tries neural networks and reports worse results (F1: 0.0–0.73 vs. 0.71–0.84 for Mondrian Forest). But neural networks are sensitive to hyperparameter choices, and the paper doesn't describe how the neural network was tuned. Was it given a fair shot? The comparison may be stacked in favor of the Mondrian Forest.

---

<a name="routing"></a>
### 2.4 The Routing Logic — Conservative Exploration

Golgi's routing works at two levels: a **global safety check** and a **per-instance ML prediction**.

```
┌─────────────────────────────────────────────────────────────┐
│                   Request arrives                           │
│                        ↓                                   │
│          Is global "Safe" flag = 1?                        │
│          (Is overall SLO currently being met?)             │
│         ↙ Yes                         ↘ No                │
│   Can we find an OC             Route to Non-OC            │
│   instance with Label=0?        instance (safe lane)       │
│   (ML says it'll be fine?)                                 │
│   ↙ Yes          ↘ No                                     │
│ Route to OC    Route to Non-OC                             │
│ instance       instance                                    │
└─────────────────────────────────────────────────────────────┘
```

The "Safe" flag is managed by the ML module monitoring P95 latency globally. When overall SLO is violated, Safe → 0 and ALL traffic goes to Non-OC until things stabilize.

**"Power of Two Choices" for OC instance selection:**
Instead of checking all OC instances (expensive), Golgi randomly picks 2 candidates and chooses the better one. This is a well-known algorithm that provides near-optimal load balancing with very low overhead.

**Off-path inference:**
Model inference takes ~100ms — too slow to do per-request (which would make scheduling take 100ms itself, violating the 20ms budget). Solution: a "relay" component runs inference in background batches every ~82ms and caches the result as a "Label tag" on each instance. The router just reads the cached tag — essentially free.

> 🤔 **Staleness problem:** If inference runs every 82ms, a tag can be up to 82ms stale when read. In 82ms at high load, a lot can change (many requests arrive, contention suddenly increases). The paper acknowledges this but dismisses it by noting 82ms is "comparable to the median function execution latency of 152ms." This is not a rigorous justification — it's hand-waving. The staleness could still cause the router to send requests to instances that became overloaded after the last prediction.

> 🤔 **Group size assumption:** The relay manages groups of 100 instances. The paper says the tag update latency is 82.2ms for groups of 100. What about groups of 500 or 1000? The paper briefly mentions a "shared-nothing sharding" strategy for large deployments but doesn't evaluate it beyond saying the latency scales linearly. This is an untested claim at production scale.

---

<a name="vertical"></a>
### 2.5 Vertical Scaling — The Safety Net

Even the best ML model makes mistakes. Vertical scaling is Golgi's error-correction mechanism.

**The idea:** Instead of changing how much CPU/memory a function gets (which would require restarting the container), Golgi changes how many requests the container handles simultaneously (its **concurrency limit**).

```
Monitor two counters per container:
  Counter A = requests that violated SLO (too slow)
  Counter B = total requests served
  Ratio = A / B (within a monitoring window)

  If Ratio > 0.05 (>5% of requests are slow):
    → Scale DOWN concurrency by 1 (accept fewer simultaneous requests)
    → Reset counters

  If Ratio < 0.03 (<3% of requests are slow):
    → Scale UP concurrency by 1 (try to handle more at once)
    → Reset counters
```

The 2% buffer (0.05 - 0.03) prevents oscillation — you don't want the system to rapidly scale up then down then up in a loop.

**Why this works without downtime:** Changing the concurrency limit is just changing a counter variable inside the running container — no restart needed.

> 🤔 **Critical question on thresholds:** 5% for scale-down and 3% for scale-up are presented without justification. Why not 10% and 8%? Why not 2% and 1%? These are engineering choices with real performance implications. The paper doesn't include an ablation study on these thresholds. This is a genuine gap.

> 🤔 **Concurrency reduction vs. load shedding:** Reducing concurrency means the instance will queue excess requests, potentially increasing their latency even more. If the problem is resource contention, turning away some requests might not help — the requests are still running, just serialized. The paper doesn't discuss queuing effects explicitly.

---

<a name="devils"></a>
### 2.6 Devil's Advocate — Critical Analysis of Claims and Evidence

#### Claim 1: "Functions only use ~25% of reserved resources"
**The paper's evidence:** Cites production traces from AWS Lambda [26,30], AliCloud [37], and Azure [34].

**Critical assessment:** ✅ This is well-established. Multiple independent production studies confirm it. This premise is solid.

#### Claim 2: "Naive overcommitment increases P95 latency by up to 183%"
**The paper's evidence:** Figure 5, detect-anomaly function under the naive OC strategy.

**Critical assessment:** ⚠️ The worst-case number (183%) is for one specific function (detect-anomaly). The average across all 8 benchmark functions is much lower. Using the worst case in the abstract to represent the whole system is a framing choice that makes naive overcommitment look worse than it is on average.

> The honest statement would be: "Naive overcommitment increases P95 latency by an average of ~50-60% across our benchmark, with a worst case of 183% for one function."

#### Claim 3: "Golgi reduces memory footprint by 42% and VM time by 35%"
**The paper's evidence:** Figure 7, 5 experimental repetitions.

**Critical assessment:** ⚠️ Several concerns:

1. **Small cluster:** 7 worker nodes with 36 vCPUs and 72 GB each. Real serverless platforms run on thousands of servers. Interference patterns in small clusters may differ from large ones (fewer diverse functions, less varied colocation patterns).

2. **Only 8 benchmark functions:** The benchmark applications (GMI, SP, DA, ID, CI, DO, AL, FL) are from a specific paper [37]. They represent "popular business domains" but they're not the full diversity of real-world serverless workloads. A system trained and tested on the same 8 functions may not generalize to hundreds of different function types.

3. **Trace scaling:** The Azure Function trace is "scaled down" from real production. The paper doesn't detail how this scaling preserves interference patterns. Scaled traces may not capture true production load distributions.

4. **5 repetitions:** Statistically, 5 runs is the bare minimum. Error bars should be prominent, but the paper doesn't discuss variance across runs.

#### Claim 4: "Golgi outperforms Orion (the state of the art)"
**Critical assessment:** ⚠️ The comparison deserves scrutiny:

Orion is described as "the state of the art" in serverless scheduling. But Orion's goal is slightly different — it aims to *right-size* functions (find the optimal memory configuration), not to do real-time interference-aware routing. They're solving related but distinct problems. Golgi's framing of Orion as the primary competitor is valid, but calling Orion "state of the art" for Golgi's exact problem is a stretch — Orion wasn't designed to handle colocation interference.

The more apples-to-apples comparison is against Owl [37], which is the most similar prior work. But the paper primarily uses Owl's infrastructure and benchmark (not Owl itself) as a baseline — Owl is conspicuously absent from the baseline comparison in Figure 5. The paper explains that Owl only handles pairwise collocations and doesn't scale, which is a legitimate criticism, but not including it as a baseline at all (even on the small scale where it works) is a gap.

#### Claim 5: "30% cost savings in production deployment"
**The paper's evidence:** Section 8.7, Figure 11.

**Critical assessment:** ⚠️ The production evaluation is the most exciting result but also the least rigorous:
- "Small production cluster" — no specific cluster size given
- Only 2 applications tested: executor monitor and log processing
- These are both WeBank internal applications — we have no independent verification
- The comparison is between Golgi and BASE (non-OC), not against Orion or OC
- No statistical analysis of variance

This result should be treated as a promising case study, not a definitive validation.

---

<a name="pass3"></a>
## 🌊 PASS 3 — The Swamp: Deep Design Examination

<a name="design-choices"></a>
### 3.1 Design Choices Under the Microscope

#### 3.1.1 Why Binary Classification and Not Regression?

The ML model predicts "will this be slow?" (yes/no), not "how slow will it be?" (a number). The paper justifies this in §4.4: "we care more about whether a request's latency exceeds specified requirements."

**Is this the right choice?**

Arguments FOR binary classification:
- Simpler model → faster training and inference
- Online Mondrian Forest works beautifully for binary problems
- The SLO is itself binary: either you meet it or you don't

Arguments AGAINST (regression might be better):
- Binary classification loses information. If a request's predicted latency is 199ms vs. 201ms (just above a 200ms SLO), binary treats them identically. But if you knew it's *just barely* violating SLO, you might still choose the OC instance rather than defaulting to Non-OC.
- The routing decision is currently a binary exploit/explore. A regression model could enable more nuanced decisions: "route to OC if predicted latency < 0.9 × SLO, else use Non-OC."
- The paper doesn't evaluate whether regression would yield better results. This is a missed experiment.

#### 3.1.2 The "Conservative" in Conservative Routing — Is It Calibrated?

The paper calls the routing "conservative" because it defaults to Non-OC. But "conservative" is a relative term.

The key decision gate: Golgi explores OC only when:
1. The global Safe flag = 1 (overall SLO is being met)
2. The per-instance Label = 0 (ML says this instance is fine)

Consider what happens during a sudden traffic spike:
- Old labels (from 82ms ago) say "this OC instance is fine"
- Spike arrives, suddenly the instance becomes overloaded
- But the label hasn't been updated yet
- Result: Golgi sends a wave of requests to an overloaded instance before the label updates

The Safe flag provides a global backstop — if enough requests start failing SLO, Safe → 0. But this is reactive, not proactive. There's an inherent lag between performance degradation and protection activation. How large is this lag in practice? The paper doesn't characterize it.

#### 3.1.3 What Does "Online Learning" Actually Mean Here?

The Mondrian Forest updates its model with each new batch of data (size N, balanced 50/50). Let's trace this through:

1. Request arrives → routed somewhere → executes → latency recorded
2. Latency + context vector (9 metrics) sent asynchronously to ML module
3. ML module buffers these samples
4. When buffer has N samples (N/2 negative, N/2 positive), update the Mondrian Forest
5. Run new inference on all monitored instances → update Label tags

**Where are the bottlenecks?**
- Step 3: Buffer filling takes time. If the function has very low traffic (most functions are invoked <1/min), it might take a very long time to collect N/2 positive samples (because positive = SLO violation = rare).
- The paper says "less than 50 model updates" for bootstrapping. But if positive samples are rare (10:1 imbalance), you might need hundreds of real data points before you get 50 updates worth of balanced batches. The bootstrapping time in practice could be much longer than the 50-update claim implies.

> 🔬 This is a subtle but important gap. The paper's Figure 9 (left) shows F1 score vs. number of updates and claims "short bootstrapping." But "number of updates" ≠ "number of real invocations." If you need 10 negative samples for every 1 positive, you need ~20N real invocations per batch of N balanced training data. The actual wall-clock bootstrapping time is not reported.

#### 3.1.4 The Vertical Scaling Mechanism — Is It Really Novel?

The paper presents vertical scaling of concurrency as a contribution specific to FaaS settings. Let's examine this claim.

The mechanism: change the concurrency limit integer atomically. This is indeed simpler and faster than vertical pod autoscaling (VPA) in Kubernetes, which requires restarting pods.

**But:** AWS Lambda itself has had per-function concurrency limits (reserved concurrency, provisioned concurrency) for years. Azure Functions has a similar model. The paper's specific contribution is the *automatic, reactive* adjustment of this limit based on tail latency monitoring — not the mechanism itself. The paper could be clearer about this distinction.

**What's genuinely novel:** The tight integration of concurrency adjustment with the ML-based routing. When the ML model makes a mistake and an OC instance gets overloaded, vertical scaling *automatically corrects* without waiting for the ML model to update. This closed-loop correction is the real contribution.

---

<a name="exp-scrutiny"></a>
### 3.2 Experimental Methodology Scrutiny

#### 3.2.1 Baseline Fairness Analysis

| Baseline | Fair? | Concern |
|---|---|---|
| BASE (non-OC + MRU) | ✅ | Correct — this is the status quo |
| OC (naive overcommit + MRU) | ✅ | Correct — the "dumb" version of Golgi |
| Orion | ⚠️ | Orion is right-sizing, not colocation-aware routing — different problem |
| E&E (Golgi without vertical scaling) | ✅ | Good ablation for vertical scaling contribution |
| Golgi (full) | ✅ | The proposed system |
| **Missing: Owl** | ❌ | Most directly comparable prior work — absent from comparison |

**The Owl problem explained:** Owl [37] is from the same research group (HKUST). The paper critiques Owl's scaling limitations but then uses Owl's benchmark applications and traces for evaluation. This creates a conflict of interest appearance. The paper should either include Owl as a baseline (even at reduced scale) or explicitly acknowledge why direct comparison is impossible.

#### 3.2.2 What Experiments Are Missing?

1. **Heterogeneous function mix:** All 8 benchmark functions run simultaneously, but are the functions from *different users*? In production, different users' functions are collocated. The paper doesn't study privacy or performance isolation between user functions.

2. **Cold start interaction:** Golgi's paper entirely ignores cold starts (the delay when a new container must be launched). In real serverless, cold starts are a major latency contributor. How does Golgi interact with cold start events?

3. **Hyperparameter sensitivity:** α = 0.3, monitoring window W, threshold 0.05/0.03, batch size N — none of these are ablated. A system with this many unvalidated hyperparameters is harder to deploy in practice than the paper suggests.

4. **Long-term stability:** The experiments run for 1 hour (scaled from a day-long trace). What happens over days or weeks? Do Mondrian Forest models grow indefinitely? Is there model drift? Memory leaks in the ML module? The paper is silent.

5. **Function update/redeployment:** When a user updates their function code, the learned model may no longer be valid. How does Golgi detect and handle this? Not discussed.

---

<a name="stress"></a>
### 3.3 Stress Testing the Logic

Let's push Golgi's logic to its limits with thought experiments.

#### Scenario 1: A New, Unusual Function
Imagine a user deploys a function that does GPU-intensive video transcoding. Golgi's 9 metrics don't include GPU utilization. The Mondrian Forest has never seen a GPU-bound workload in its training data. What happens?

**Likely outcome:** The model bootstraps on the wrong features. CPU and memory utilization are low (work is on GPU), but the function is very slow. The model learns that "low CPU + low memory = good performance," but this is wrong for this function type. Golgi might keep routing to OC instances thinking they're fine, while actually violating SLO consistently.

**Paper's defense:** The paper only uses CPU/memory/network/cache metrics that are "function-agnostic." But "function-agnostic" is only true if all functions are bound by the same resources (CPU, memory, network). The 9 metrics were selected based on observations of 8 specific benchmark functions — they may not cover the full space of real-world bottlenecks.

#### Scenario 2: Viral Traffic Spike
A function normally gets 10 requests/second. Suddenly it gets 10,000 requests/second (think: a viral app). Golgi creates new instances to scale out. New instances start as Non-OC by default. But to explore OC instances, the ML model needs training data from the current traffic pattern. During the spike, the model is frantically bootstrapping on the new load pattern.

**Likely outcome:** During the spike, Golgi stays in Non-OC mode (safe but expensive) because Label tags are untrustworthy. This is actually the correct conservative behavior. But it means Golgi's cost savings are essentially *zero* during traffic spikes, which is often when cost savings would be most valuable (spikes create the most resource pressure).

The paper shows scalability to 6000 RPS, but doesn't discuss *how long it stays in conservative mode* during such spikes. This is a cost-efficiency gap.

#### Scenario 3: The Adversarial Workload
Imagine a function whose latency spikes in precise bursts every 100 milliseconds (perhaps due to garbage collection in the JVM). Golgi's label update cycle is ~82ms. The label might always be sampled during a "good" window (between GC pauses), leading the model to always think the OC instance is fine.

**Likely outcome:** Systematic underestimation of SLO violations. The paper doesn't analyze how Golgi's performance correlates with the workload's temporal patterns. This is a genuine vulnerability.

---

<a name="research-ideas"></a>
### 3.4 Research Ideas Generated

Reading this paper critically generates several interesting directions:

**Idea 1: GPU-aware serverless scheduling**
Extend Golgi's 9-metric framework to include GPU utilization, memory bandwidth, and PCIe contention metrics. As AI inference workloads move to serverless (e.g., AWS Lambda with GPU), this is increasingly important.

**Idea 2: Adaptive α — per-function overcommitment ratios**
Instead of a fixed α = 0.3 for all functions, learn the optimal α per function based on its observed variance. A function with very stable, low resource usage could use α = 0.1 (more aggressive overcommit). A highly variable function should use α = 0.8 (conservative). This is a natural extension of the online learning framework.

**Idea 3: Proactive scaling using short-term workload prediction**
Golgi is reactive — it responds to measured SLO violations. A proactive version could predict traffic spikes 10–30 seconds ahead using time series models (LSTM, Prophet) on the request arrival pattern, and pre-emptively move traffic back to Non-OC before SLO violations occur.

**Idea 4: Fair multi-tenant interference management**
In production, multiple users' functions share a server. If User A's function is CPU-intensive and starts degrading User B's function, Golgi routes away from the overloaded instance — but doesn't provide any guarantee of *fairness*. User B is harmed by User A's behavior. A fairness-aware extension would be valuable.

---

<a name="verdict"></a>
## 🏁 Final Verdict and Summary

### Summary Table

| Aspect | Rating | Commentary |
|---|---|---|
| **Problem motivation** | ⭐⭐⭐⭐⭐ | Very well supported with real production data |
| **Core idea (9 metrics + MF)** | ⭐⭐⭐⭐ | Clever and practical; metric selection needs deeper justification |
| **ML design** | ⭐⭐⭐⭐ | Online learning + stratified sampling is solid; bootstrapping time uncharacterized |
| **Routing logic** | ⭐⭐⭐ | Conservative is good; staleness and spike behavior need more analysis |
| **Vertical scaling** | ⭐⭐⭐⭐ | Effective safety net; threshold choices unjustified |
| **Experiment quality** | ⭐⭐⭐ | Small cluster, 8 functions, missing Owl comparison, no hyperparameter ablations |
| **Production deployment** | ⭐⭐⭐ | Promising but under-described; 2 functions at one company |
| **Writing clarity** | ⭐⭐⭐⭐ | Clear architecture; some framing choices favor the authors |
| **Overall contribution** | ⭐⭐⭐⭐ | Meaningful advance over prior work; real cost savings demonstrated |

### The Paper in One Sentence
Golgi cleverly combines online machine learning with a conservative routing strategy to safely exploit the gap between what serverless functions *claim* to need and what they *actually* use, achieving meaningful cost reductions without meaningfully degrading performance — but the validation evidence, while compelling, falls short of proving this would generalize to the full diversity of real-world production deployments.

### What to Remember for the Term Project (CSL7510)

If you're implementing something inspired by Golgi on AWS with OpenFaaS and Kubernetes:

1. **The core loop to implement:** Collect 9 metrics per container → feed to a classifier → cache prediction → use prediction in routing
2. **Start with a simpler classifier** (logistic regression or a shallow decision tree) before jumping to Mondrian Forest — verify the metrics are informative first
3. **The stratified sampling trick is critical** — without it, the model will be useless on imbalanced data
4. **Vertical scaling is the safety net** — implement it as the last defense against prediction errors
5. **Be honest about hyperparameters** — α = 0.3, thresholds 0.05/0.03, etc. are not proven optimal; you'll need to tune them or at least justify them

---

*Analysis completed using the Ramdas 3-Pass Methodology. Pre-reading → Pass 1 (Jigsaw) → Pass 2 (Scuba Dive) → Pass 3 (Empirical Swamp). Devil's Advocate protocol applied throughout Pass 2 and Pass 3.*