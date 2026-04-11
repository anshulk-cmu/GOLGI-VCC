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
  - [Step 1.1: Deploy Redis](#step-11-deploy-redis--completed-2026-04-11)
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
| SSH user | `ec2-user` (Amazon Linux 2023 default) |

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

### Step 1.1: Deploy Redis — COMPLETED (2026-04-11)

**What we did:** Deployed a Redis 7 instance (Deployment + Service) into the `openfaas-fn` namespace on the k3s cluster. Redis is needed because the `db-query` benchmark function (I/O-bound workload) reads and writes keys to it. Without Redis, the `db-query` function would have nothing to talk to.

**Why Redis?**
- It is lightweight — a single pod using only 64 Mi request / 128 Mi limit, tiny compared to the worker nodes' 16 GB RAM
- It provides pure network-bound I/O operations (connect, GET, SET) which is exactly what an I/O-bound benchmark function needs
- It is trivial to deploy as a Kubernetes Deployment + Service — no external database setup, no cloud-managed service costs
- The `db-query` function's latency will be dominated by the network round-trip to Redis (microseconds to low milliseconds within the cluster network), not by CPU — this is the defining characteristic of an I/O-bound function

**Why in the `openfaas-fn` namespace?**
OpenFaaS deploys all user functions into the `openfaas-fn` namespace. By placing Redis in the same namespace, the `db-query` function can reach it via the short DNS name `redis` (Kubernetes service discovery within the same namespace) or the fully qualified name `redis.openfaas-fn.svc.cluster.local`. Placing it in a different namespace would still work (cross-namespace DNS is supported) but would add unnecessary complexity.

---

#### Pre-flight Check: Verify AWS Instances Are Running

Before touching the cluster, we need to confirm all 5 EC2 instances are still running and their public IPs have not changed (public IPs are ephemeral — they change if instances are stopped and restarted).

**Command:**
```
"/c/Program Files/Amazon/AWSCLIV2/aws.exe" ec2 describe-instances \
  --filters "Name=tag:Name,Values=golgi-*" \
  --query "Reservations[].Instances[].{
    Name:Tags[?Key==\`Name\`].Value|[0],
    State:State.Name,
    PublicIP:PublicIpAddress,
    PrivateIP:PrivateIpAddress,
    Type:InstanceType
  }" --output table
```

**Why the full path?** On our Windows machine, the AWS CLI is installed at `C:\Program Files\Amazon\AWSCLIV2\aws.exe` but is not on the bash shell's PATH (it is on PowerShell's PATH but we are running inside Git Bash via VS Code). Using the full path ensures the command works regardless of PATH configuration.

**Output:**
```
----------------------------------------------------------------------------
|                             DescribeInstances                            |
+----------------+-------------+-----------------+-----------+-------------+
|      Name      |  PrivateIP  |    PublicIP     |   State   |    Type     |
+----------------+-------------+-----------------+-----------+-------------+
|  golgi-worker-3|  10.0.1.94  |  174.129.77.19  |  running  |  t3.xlarge  |
|  golgi-worker-2|  10.0.1.10  |  44.206.236.146 |  running  |  t3.xlarge  |
|  golgi-worker-1|  10.0.1.110 |  54.173.219.56  |  running  |  t3.xlarge  |
|  golgi-master  |  10.0.1.131 |  44.212.35.8    |  running  |  t3.medium  |
|  golgi-loadgen |  10.0.1.142 |  44.211.68.203  |  running  |  t3.medium  |
+----------------+-------------+-----------------+-----------+-------------+
```

**Result:** All 5 instances are in `running` state. Public IPs match the Phase 0 reference table exactly — the instances have not been stopped/restarted since Phase 0 was completed, so the IPs remain the same.

---

#### Pre-flight Check: Verify SSH Access and Cluster Health

**Command:**
```bash
ssh -o StrictHostKeyChecking=no -i /c/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "echo 'SSH OK' && kubectl get nodes -o wide"
```

**Important note on SSH user:** In Phase 0, we documented that Amazon Linux 2023 uses `ec2-user` as the default SSH username. During this session we initially tried `ubuntu` (the default for Ubuntu AMIs) which resulted in `Permission denied (publickey)`. The correct user for Amazon Linux is `ec2-user`. This is a common mistake when switching between AMI families.

**Output:**
```
SSH OK
NAME             STATUS   ROLES           AGE   VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
golgi-master     Ready    control-plane   60m   v1.34.6+k3s1   10.0.1.131    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-1   Ready    <none>          58m   v1.34.6+k3s1   10.0.1.110    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-2   Ready    <none>          57m   v1.34.6+k3s1   10.0.1.10     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-3   Ready    <none>          56m   v1.34.6+k3s1   10.0.1.94     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
```

**Reading the output:**
- All 4 nodes show `STATUS: Ready` — the cluster is healthy and all nodes are accepting pods
- The master has been up for 60 minutes, workers joined 2-4 minutes after (58m, 57m, 56m) — consistent with Phase 0's sequential worker join
- All nodes run the same k3s version (`v1.34.6+k3s1`) — version consistency is important for cluster stability
- Container runtime is `containerd://2.2.2-bd1.34` on all nodes — this is the runtime that will execute our function containers

**OpenFaaS status check:**
```bash
ssh -o StrictHostKeyChecking=no -i /c/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl get pods -n openfaas -o wide && echo '---' && kubectl get pods -n openfaas-fn -o wide"
```

**Output:**
```
NAME                            READY   STATUS    RESTARTS      AGE   IP          NODE             NOMINATED NODE   READINESS GATES
alertmanager-fb97cfc46-shcnk    1/1     Running   0             40m   10.42.3.2   golgi-worker-3   <none>           <none>
gateway-5f8bf55dfb-2n59b        2/2     Running   1 (40m ago)   40m   10.42.2.2   golgi-worker-2   <none>           <none>
nats-5bf8cfb54-vr2c5            1/1     Running   0             40m   10.42.1.2   golgi-worker-1   <none>           <none>
prometheus-85cb68fd7b-vmfvh     1/1     Running   0             40m   10.42.3.3   golgi-worker-3   <none>           <none>
queue-worker-65bc696bcf-sd5rn   1/1     Running   1 (40m ago)   40m   10.42.2.3   golgi-worker-2   <none>           <none>
---
No resources found in openfaas-fn namespace.
```

**Reading the output:**
- All 5 OpenFaaS pods are `Running` with `READY` showing full readiness (`1/1` or `2/2` for the gateway which has 2 containers — the gateway itself and the faas-netes provider sidecar)
- The pods are distributed across workers: alertmanager + prometheus on worker-3, gateway + queue-worker on worker-2, NATS on worker-1. Kubernetes scheduled them across nodes for availability.
- The `openfaas-fn` namespace is empty — no functions deployed yet. This is expected; Redis will be the first resource deployed here.
- The gateway pod had 1 restart (`1 (40m ago)`) — this is normal; the gateway sometimes restarts once during initial OpenFaaS deployment while waiting for its dependencies (NATS, faas-netes) to become ready.

**What each OpenFaaS pod does:**

| Pod | Purpose |
|---|---|
| `gateway` | The HTTP entry point for all function invocations. Receives requests and routes them to function pods. Has 2 containers: the gateway HTTP server and the faas-netes Kubernetes provider. |
| `queue-worker` | Handles asynchronous function invocations (when you POST to `/async-function/...`). We use synchronous invocations, so this is mostly idle. |
| `nats` | A lightweight message broker used by the queue-worker for async invocations. Lightweight, ~30 MB RAM. |
| `alertmanager` | Handles alerts from Prometheus (e.g., function scaling triggers). Part of OpenFaaS's auto-scaling system. |
| `prometheus` | Collects metrics from the gateway (request counts, latency, function replica counts). Used by OpenFaaS for auto-scaling decisions. We may also use it later for our own monitoring. |

---

#### Deploying Redis

**What we deployed:** Two Kubernetes resources — a Deployment (manages the Redis pod) and a Service (provides a stable DNS name and IP for other pods to connect to).

**Why two resources?**
- The **Deployment** ensures exactly 1 Redis pod is always running. If the pod crashes, Kubernetes automatically recreates it. If the node it's on goes down, Kubernetes reschedules it to another node.
- The **Service** provides a stable network endpoint. Pods come and go (they get new IPs each time they restart), but the Service maintains a fixed ClusterIP (`10.43.x.x`) and DNS name (`redis.openfaas-fn.svc.cluster.local`). When the `db-query` function connects to `redis:6379`, Kubernetes DNS resolves it to the Service's ClusterIP, which then routes to the current Redis pod's IP.

**The YAML manifest:**

```yaml
# redis-deployment.yaml (saved at functions/redis-deployment.yaml in our repo)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
```

**Explanation of every field in the Deployment:**

| Field | Value | Meaning |
|---|---|---|
| `apiVersion: apps/v1` | — | The Kubernetes API group and version for Deployments |
| `kind: Deployment` | — | This is a Deployment object (manages ReplicaSets which manage Pods) |
| `metadata.name: redis` | — | The deployment's name in Kubernetes |
| `metadata.namespace: openfaas-fn` | — | Deploy into the function namespace (same as our OpenFaaS functions) |
| `spec.replicas: 1` | — | Run exactly 1 Redis pod. We don't need Redis HA — it's a simple benchmark dependency |
| `spec.selector.matchLabels.app: redis` | — | The deployment manages pods with label `app=redis` |
| `spec.template.metadata.labels.app: redis` | — | Pods created by this deployment get label `app=redis` (must match selector) |
| `spec.template.spec.containers[0].name: redis` | — | Container name within the pod |
| `spec.template.spec.containers[0].image: redis:7-alpine` | — | Redis 7.x on Alpine Linux — minimal image (~30 MB vs ~130 MB for Debian-based `redis:7`). Alpine uses musl libc and BusyBox, keeping the image tiny. |
| `containerPort: 6379` | — | Redis's standard port. This is informational (Kubernetes doesn't enforce it) but documents which port the container listens on. |
| `resources.requests.memory: "64Mi"` | — | Kubernetes guarantees at least 64 MiB of memory for this container. The scheduler uses this when deciding which node to place the pod on. |
| `resources.requests.cpu: "100m"` | — | Kubernetes guarantees at least 100 millicores (0.1 vCPU). `1000m` = 1 full vCPU. |
| `resources.limits.memory: "128Mi"` | — | The container cannot use more than 128 MiB. If it tries (e.g., a memory leak), the kernel's OOM killer terminates it. |
| `resources.limits.cpu: "200m"` | — | The container cannot burst above 200 millicores. CFS (Completely Fair Scheduler) throttles it if it tries. |

**Why these resource values?**
Redis at idle uses ~5-10 MB of memory. Under our light benchmark load (a few hundred GET/SET operations per second), it uses ~20-40 MB. Setting requests at 64 Mi and limits at 128 Mi gives generous headroom without wasting cluster resources. The CPU request of 100m is similarly conservative — Redis is single-threaded and our workload is light.

**Explanation of the Service:**

| Field | Value | Meaning |
|---|---|---|
| `kind: Service` | — | A Kubernetes Service provides a stable network endpoint |
| `spec.selector.app: redis` | — | Routes traffic to pods with label `app=redis` (the Redis pod) |
| `spec.ports[0].port: 6379` | — | The port the Service listens on (other pods connect to `redis:6379`) |
| `spec.ports[0].targetPort: 6379` | — | The port on the target pod to forward to (Redis's listening port) |
| (no `type` specified) | — | Defaults to `ClusterIP` — only accessible within the cluster (not from outside). This is correct — Redis should not be exposed to the internet. |

**How the Service routing works:**
```
db-query pod                 Service                    Redis pod
  |                            |                           |
  | connect to redis:6379      |                           |
  | ----------------------->   |                           |
  |   (DNS resolves to         |                           |
  |    ClusterIP 10.43.x.x)   |                           |
  |                            | forward to pod IP:6379    |
  |                            | ------------------------> |
  |                            |                           |
  |           <--- response ---|--- response --------------|
```

**Command to apply:**
```bash
ssh -o StrictHostKeyChecking=no -i /c/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  'cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: openfaas-fn
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF'
```

**Why `cat <<EOF | kubectl apply -f -` instead of copying a file?**
We pipe the YAML directly into `kubectl apply` via a heredoc. This avoids needing to first `scp` a file to the master node and then run `kubectl apply -f <file>`. For small manifests like this, inline application is simpler. The `-f -` flag tells kubectl to read from stdin (the pipe). The `EOF` heredoc delimiter is quoted (`'EOF'`) to prevent shell variable expansion in the YAML.

**Output:**
```
deployment.apps/redis created
service/redis created
```

**What `kubectl apply` does:**
1. Parses the YAML into Kubernetes API objects (one Deployment, one Service)
2. Sends HTTP POST requests to the API server (`https://127.0.0.1:6443/apis/apps/v1/namespaces/openfaas-fn/deployments` and `.../v1/namespaces/openfaas-fn/services`)
3. The API server validates the objects (correct apiVersion, required fields present, resource values parseable)
4. Stores them in etcd
5. The Deployment controller (running inside the API server) notices the new Deployment and creates a ReplicaSet
6. The ReplicaSet controller creates 1 Pod (because `replicas: 1`)
7. The scheduler assigns the Pod to a node (picks the node with the most available resources that satisfies the resource requests)
8. The kubelet on the chosen node pulls the `redis:7-alpine` image from Docker Hub and starts the container
9. The Service controller creates iptables/nftables rules on all nodes so that traffic to the ClusterIP is forwarded to the Redis pod

---

#### Verifying Redis Is Running

**Command:**
```bash
ssh -o StrictHostKeyChecking=no -i /c/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl get pods -n openfaas-fn -o wide && echo '---' && kubectl get svc -n openfaas-fn"
```

**Output:**
```
NAME                     READY   STATUS    RESTARTS   AGE   IP          NODE             NOMINATED NODE   READINESS GATES
redis-84d559556f-cg478   1/1     Running   0          23s   10.42.1.3   golgi-worker-1   <none>           <none>
---
NAME    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
redis   ClusterIP   10.43.105.234   <none>        6379/TCP   24s
```

**Reading the pod output:**
- `redis-84d559556f-cg478` — the pod name. The format is `<deployment>-<replicaset-hash>-<pod-hash>`. The `84d559556f` is the ReplicaSet hash (changes when the Deployment spec changes), and `cg478` is the unique pod suffix.
- `READY: 1/1` — the pod has 1 container and it is ready (passed health checks). If it showed `0/1`, the container would still be starting up.
- `STATUS: Running` — the container is executing. Other possible states: `Pending` (waiting for scheduling or image pull), `CrashLoopBackOff` (container keeps crashing), `ImagePullBackOff` (cannot download the image).
- `RESTARTS: 0` — the container has not crashed and restarted. Good.
- `AGE: 23s` — created 23 seconds ago.
- `IP: 10.42.1.3` — the pod's internal IP address. This is in the `10.42.x.x` range, which is the pod CIDR managed by k3s's Flannel CNI (Container Network Interface). The `10.42.1.x` prefix means it's on `golgi-worker-1` (each node gets its own /24 pod subnet: master gets 10.42.0.x, worker-1 gets 10.42.1.x, worker-2 gets 10.42.2.x, worker-3 gets 10.42.3.x).
- `NODE: golgi-worker-1` — Kubernetes scheduled the Redis pod on worker-1. The scheduler chose this node based on available resources and affinity rules.

**Reading the service output:**
- `TYPE: ClusterIP` — internal-only service (not exposed outside the cluster). This is the default service type and correct for Redis.
- `CLUSTER-IP: 10.43.105.234` — the stable virtual IP assigned to this service. Any pod in the cluster can connect to `10.43.105.234:6379` and reach Redis. The `10.43.x.x` range is the service CIDR, separate from the pod CIDR (`10.42.x.x`).
- `PORT(S): 6379/TCP` — the service listens on TCP port 6379 and forwards to the Redis pod's port 6379.

**How DNS resolution works for the Service:**
When the `db-query` function connects to `redis.openfaas-fn.svc.cluster.local:6379`:
1. The pod's `/etc/resolv.conf` points to CoreDNS (running on the master)
2. CoreDNS looks up `redis.openfaas-fn.svc.cluster.local` in its in-memory cache (populated from the Kubernetes API)
3. It returns the ClusterIP: `10.43.105.234`
4. The pod connects to `10.43.105.234:6379`
5. kube-proxy's iptables/nftables rules on the node intercept this traffic and DNAT (Destination NAT) it to the Redis pod's actual IP (`10.42.1.3:6379`)

Since both the `db-query` function and Redis are in the `openfaas-fn` namespace, the function can use the short name `redis` instead of the full `redis.openfaas-fn.svc.cluster.local` — Kubernetes automatically appends the namespace suffix for same-namespace lookups.

---

#### Verifying Redis Is Responding to Commands

The pod is running, but we need to confirm Redis is actually accepting commands — not just that the container started. A container can be `Running` but the application inside could have failed to initialize (e.g., a config error, a port conflict).

**Command:**
```bash
ssh -o StrictHostKeyChecking=no -i /c/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl run redis-test --rm -it --restart=Never --namespace=openfaas-fn \
    --image=redis:7-alpine -- redis-cli -h redis.openfaas-fn.svc.cluster.local PING"
```

**Explanation of the command:**
- `kubectl run redis-test` — creates a temporary pod named `redis-test`
- `--rm` — automatically delete the pod after it exits (cleanup)
- `-it` — interactive + allocate a TTY (so we see the output)
- `--restart=Never` — run the command once and exit (don't restart on completion)
- `--namespace=openfaas-fn` — run in the same namespace as Redis (for DNS resolution)
- `--image=redis:7-alpine` — use the Redis image, which includes the `redis-cli` tool
- `-- redis-cli -h redis.openfaas-fn.svc.cluster.local PING` — everything after `--` is the command to run inside the container. `redis-cli` connects to the Redis service and sends the `PING` command.

**What the PING command does:**
`PING` is the simplest Redis command. It takes no arguments and returns `PONG` if the server is alive and accepting connections. It tests the full network path: DNS resolution → TCP connection → Redis protocol handshake → command execution → response.

**Output:**
```
PONG
pod "redis-test" deleted from openfaas-fn namespace
```

**Result:** Redis responded with `PONG` — the server is alive, accepting connections, and the DNS resolution for `redis.openfaas-fn.svc.cluster.local` works correctly. The test pod was automatically deleted after the command completed.

---

#### Step 1.1 Summary

| Check | Result | Details |
|---|---|---|
| All 5 EC2 instances running | PASS | IPs unchanged from Phase 0 |
| SSH to master works | PASS | User is `ec2-user` (Amazon Linux), key at `/c/Users/worka/.ssh/golgi-key.pem` |
| k3s cluster healthy (4 nodes) | PASS | All nodes `Ready`, all running v1.34.6+k3s1 |
| OpenFaaS pods running | PASS | All 5 pods `Running` (gateway, queue-worker, NATS, alertmanager, prometheus) |
| Redis Deployment created | PASS | Pod `redis-84d559556f-cg478` running on `golgi-worker-1` |
| Redis Service created | PASS | ClusterIP `10.43.105.234`, port `6379/TCP` |
| Redis PING test | PASS | Returned `PONG` — server accepting connections |
| Redis DNS resolution | PASS | `redis.openfaas-fn.svc.cluster.local` resolves correctly from within the cluster |

**Resources deployed:**

| Resource | Type | Namespace | Node | IP |
|---|---|---|---|---|
| `redis` Deployment | `apps/v1/Deployment` | `openfaas-fn` | — | — |
| `redis-84d559556f-cg478` | Pod | `openfaas-fn` | `golgi-worker-1` | `10.42.1.3` |
| `redis` Service | `v1/Service` | `openfaas-fn` | — | `10.43.105.234` (ClusterIP) |

**Resource consumption:**
- Memory: 64 Mi requested, 128 Mi limit (actual usage at idle: ~5-10 Mi)
- CPU: 100m requested, 200m limit (actual usage at idle: near zero)
- Image: `redis:7-alpine` (~30 MB compressed, ~80 MB on disk)

**Files saved to repo:**
- [`functions/redis-deployment.yaml`](functions/redis-deployment.yaml) — the exact YAML manifest applied to the cluster

**Step 1.1 is complete.** Redis is live at `redis.openfaas-fn.svc.cluster.local:6379` and ready for the `db-query` function to connect to in Step 1.2.

---

### Step 1.2: Create OpenFaaS Function YAML — NOT STARTED

*(To be completed next)*

---

### Step 1.3: Build and Deploy Functions — NOT STARTED

*(To be completed after Step 1.2)*

---

### Step 1.4: Baseline Latency Measurement — NOT STARTED

*(To be completed after Step 1.3)*

---

### Phase 1 Checkpoint

```
[x] Redis service running and accessible from within the cluster (PONG confirmed)
[ ] 3 Non-OC functions deployed and responding
[ ] 3 OC functions deployed and responding
[ ] Redis accessible from db-query functions
[ ] Baseline P95 latency measured for each function (SLO thresholds)
[ ] Resource configurations match the overcommitment formula
[ ] All functions handle concurrent requests (max_inflight = 4)
```
