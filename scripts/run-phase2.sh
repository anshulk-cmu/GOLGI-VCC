#!/usr/bin/env bash
# run-phase2.sh — Phase 2: Multi-Level Degradation Curves
#
# Deploys each function at 5 CPU levels, measures latency (200 req × 3 reps),
# records CFS throttling stats, then tears down before the next level.
#
# Usage: Run on the master node (has kubectl + gateway access).
#   bash run-phase2.sh [GATEWAY_URL]
#
# Output:
#   /home/ec2-user/results/phase2/<func>_cpu<pct>_rep<N>.txt   — latency files
#   /home/ec2-user/results/phase2/<func>_cpu<pct>_cfs.txt      — CFS throttling stats

set -euo pipefail

GATEWAY="${1:-http://127.0.0.1:31112}"
NUM_REQUESTS=200
NUM_REPS=3
WARMUP_COUNT=10
RESULTS_DIR="/home/ec2-user/results/phase2"
TEMPLATE="/home/ec2-user/phase2-deploy-template.yaml"
SSH_KEY="/home/ec2-user/.ssh/golgi-key.pem"

mkdir -p "$RESULTS_DIR"

# ── Function configurations ──
# Format: base_name:image:base_cpu:mem_mi
FUNCTIONS=(
  "image-resize:golgi/image-resize:v1.0:1000:512"
  "db-query:golgi/db-query:v1.0:500:256"
  "log-filter:golgi/log-filter:v1.0:500:256"
)

CPU_PCTS=(100 80 60 40 20)

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── Select payload based on function name ──
get_payload() {
  local func="$1"
  case "$func" in
    image-resize*) echo '{"width":1920,"height":1080}' ;;
    db-query*)     echo '{"operation":"set","key":"bench","value":"payload"}' ;;
    log-filter*)   echo '{"lines":100,"pattern":"ERROR"}' ;;
  esac
}

# ── Deploy a function variant ──
deploy_variant() {
  local deploy_name="$1" func_label="$2" image="$3" cpu="$4" mem="$5"

  log "Deploying $deploy_name (CPU=${cpu}m, MEM=${mem}Mi)"

  # For db-query, we need to inject the REDIS_HOST env var.
  # We handle this by applying the template first, then patching if needed.
  export FUNC_NAME="$deploy_name"
  export FUNC_LABEL="$func_label"
  export FUNC_IMAGE="$image"
  export CPU_MILLI="$cpu"
  export MEM_MI="$mem"

  envsubst < "$TEMPLATE" | kubectl apply -f -

  # Patch db-query variants to add REDIS_HOST env var
  if [[ "$func_label" == "db-query" ]]; then
    kubectl set env deployment/"$deploy_name" -n openfaas-fn \
      REDIS_HOST=redis.openfaas-fn.svc.cluster.local
  fi

  # Wait for pod to be ready (timeout 120s)
  log "Waiting for pod to become Ready..."
  kubectl rollout status deployment/"$deploy_name" -n openfaas-fn --timeout=120s

  # Extra settle time for container startup
  sleep 3

  log "Deployed: $(kubectl get pods -n openfaas-fn -l faas_function=$deploy_name -o wide --no-headers)"
}

# ── Teardown a function variant ──
teardown_variant() {
  local deploy_name="$1"
  log "Tearing down $deploy_name"
  kubectl delete deployment "$deploy_name" -n openfaas-fn --ignore-not-found=true
  kubectl delete service "$deploy_name" -n openfaas-fn --ignore-not-found=true

  # Wait for pod to fully terminate
  local retries=0
  while kubectl get pods -n openfaas-fn -l "faas_function=$deploy_name" --no-headers 2>/dev/null | grep -q .; do
    retries=$((retries + 1))
    if [ $retries -gt 30 ]; then
      log "WARN: Pod still terminating after 30s, continuing anyway"
      break
    fi
    sleep 1
  done
  log "Teardown complete for $deploy_name"
}

# ── Warmup requests ──
do_warmup() {
  local func_url="$1" payload="$2"
  log "Warming up ($WARMUP_COUNT requests)..."
  for i in $(seq 1 $WARMUP_COUNT); do
    curl -s -o /dev/null -w "" "$GATEWAY/function/$func_url" -d "$payload" || true
  done
}

# ── Measure latency for one repetition ──
measure_rep() {
  local func_url="$1" payload="$2" outfile="$3"
  rm -f "$outfile"
  local errors=0

  for i in $(seq 1 $NUM_REQUESTS); do
    start=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 120 "$GATEWAY/function/$func_url" -d "$payload") || HTTP_CODE="000"
    end=$(date +%s%N)
    latency_ms=$(( (end - start) / 1000000 ))
    echo "$latency_ms" >> "$outfile"

    if [ "$HTTP_CODE" != "200" ]; then
      errors=$((errors + 1))
    fi

    if [ $((i % 50)) -eq 0 ]; then
      log "  Progress: $i/$NUM_REQUESTS — last: ${latency_ms}ms"
    fi
  done

  local count
  count=$(wc -l < "$outfile")
  log "  Completed: $count requests, $errors errors → $outfile"
}

# ── Record CFS throttling stats ──
record_cfs_stats() {
  local deploy_name="$1" outfile="$2"

  # Get pod UID and node
  local pod_info
  pod_info=$(kubectl get pods -n openfaas-fn -l "faas_function=$deploy_name" \
    -o jsonpath='{.items[0].metadata.uid} {.items[0].spec.nodeName}')
  local pod_uid node_name
  pod_uid=$(echo "$pod_info" | awk '{print $1}')
  node_name=$(echo "$pod_info" | awk '{print $2}')

  # Get node internal IP
  local node_ip
  node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

  # Convert UID format for cgroup path (dashes → underscores)
  local pod_uid_cgroup
  pod_uid_cgroup=$(echo "$pod_uid" | tr '-' '_')

  log "Recording CFS stats from $node_name ($node_ip)"

  # Read cpu.stat from the function container's cgroup
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -i "$SSH_KEY" ec2-user@"$node_ip" "
    BASE='/sys/fs/cgroup/kubepods.slice/kubepods-pod${pod_uid_cgroup}.slice'
    if [ ! -d \"\$BASE\" ]; then
      echo 'ERROR: cgroup path not found'
      exit 1
    fi
    # Find function container (highest CPU usage, not the pause container)
    for d in \"\$BASE\"/cri-containerd-*.scope; do
      if [ -f \"\$d/cpu.stat\" ]; then
        usage=\$(grep usage_usec \"\$d/cpu.stat\" | awk '{print \$2}')
        if [ \"\$usage\" -gt 500000 ]; then
          echo \"cgroup_path: \$d\"
          echo '---'
          cat \"\$d/cpu.stat\"
          echo '---'
          cat \"\$d/cpu.max\"
          break
        fi
      fi
    done
  " > "$outfile" 2>&1

  log "  CFS stats → $outfile"
}

# ── Compute stats from a latency file ──
compute_stats() {
  local file="$1"
  sort -n "$file" | awk '
    BEGIN { n=0; sum=0; sumsq=0 }
    { a[n]=$1; sum+=$1; sumsq+=$1*$1; n++ }
    END {
      mean=sum/n
      p50=a[int(n*0.50)]
      p95=a[int(n*0.95)]
      p99=a[int(n*0.99)]
      min=a[0]; max=a[n-1]
      printf "n=%d mean=%.0f p50=%d p95=%d p99=%d min=%d max=%d", n, mean, p50, p95, p99, min, max
    }'
}

# ════════════════════════════════════════════════════════
# MAIN LOOP
# ════════════════════════════════════════════════════════

log "=== Phase 2: Multi-Level Degradation Curves ==="
log "Gateway:     $GATEWAY"
log "Requests:    $NUM_REQUESTS × $NUM_REPS reps per variant"
log "CPU levels:  ${CPU_PCTS[*]}%"
log "Results dir: $RESULTS_DIR"
echo ""

# First, tear down existing Phase 1 deployments to free resources
log "=== Tearing down Phase 1 deployments to free worker resources ==="
for old_deploy in image-resize image-resize-oc db-query db-query-oc log-filter log-filter-oc; do
  kubectl delete deployment "$old_deploy" -n openfaas-fn --ignore-not-found=true
  kubectl delete service "$old_deploy" -n openfaas-fn --ignore-not-found=true
done

# Wait for all old pods to terminate
log "Waiting for old pods to terminate..."
sleep 10
remaining=$(kubectl get pods -n openfaas-fn --no-headers 2>/dev/null | grep -v redis | wc -l)
while [ "$remaining" -gt 0 ]; do
  log "  $remaining pods still terminating..."
  sleep 5
  remaining=$(kubectl get pods -n openfaas-fn --no-headers 2>/dev/null | grep -v redis | wc -l)
done
log "All old function pods terminated. Redis still running."
echo ""

# Loop through each function
for func_config in "${FUNCTIONS[@]}"; do
  IFS=':' read -r func_label image_base image_tag base_cpu mem_mi <<< "$func_config"
  func_image="${image_base}:${image_tag}"
  payload=$(get_payload "$func_label")

  log "══════════════════════════════════════════"
  log "Function: $func_label (image=$func_image, base_cpu=${base_cpu}m, mem=${mem_mi}Mi)"
  log "══════════════════════════════════════════"
  echo ""

  for cpu_pct in "${CPU_PCTS[@]}"; do
    cpu_milli=$(( base_cpu * cpu_pct / 100 ))
    deploy_name="${func_label}-cpu${cpu_pct}"

    log "────────────────────────────────────────"
    log "Level: ${cpu_pct}% → ${cpu_milli}m CPU"
    log "Deploy name: $deploy_name"
    log "────────────────────────────────────────"

    # 1. Deploy
    deploy_variant "$deploy_name" "$func_label" "$func_image" "$cpu_milli" "$mem_mi"

    # 2. Warmup
    do_warmup "$deploy_name" "$payload"

    # 3. Record CFS stats BEFORE measurement
    record_cfs_stats "$deploy_name" "$RESULTS_DIR/${func_label}_cpu${cpu_pct}_cfs_before.txt"

    # 4. Measure (3 repetitions)
    for rep in $(seq 1 $NUM_REPS); do
      log "Rep $rep/$NUM_REPS:"
      measure_rep "$deploy_name" "$payload" \
        "$RESULTS_DIR/${func_label}_cpu${cpu_pct}_rep${rep}.txt"

      # Print quick stats
      stats=$(compute_stats "$RESULTS_DIR/${func_label}_cpu${cpu_pct}_rep${rep}.txt")
      log "  Stats: $stats"
    done

    # 5. Record CFS stats AFTER measurement
    record_cfs_stats "$deploy_name" "$RESULTS_DIR/${func_label}_cpu${cpu_pct}_cfs_after.txt"

    # 6. Teardown
    teardown_variant "$deploy_name"

    echo ""
  done

  log "Completed all levels for $func_label"
  echo ""
done

log "=== Phase 2 Complete ==="
log "Results saved to: $RESULTS_DIR/"
log "Files:"
ls -la "$RESULTS_DIR/"
