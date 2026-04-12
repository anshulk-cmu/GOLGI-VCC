#!/bin/bash
# run-level.sh — Run one function at one CPU level: deploy, warmup, measure x3, CFS stats, teardown.
# Usage: bash run-level.sh <func_label> <cpu_pct> <cpu_milli> <mem_mi> <image> [gateway]
# Example: bash run-level.sh image-resize 80 800 512 golgi/image-resize:v1.0

set -euo pipefail

FUNC_LABEL=$1
CPU_PCT=$2
CPU_MILLI=$3
MEM_MI=$4
IMAGE=$5
GATEWAY="${6:-http://127.0.0.1:31112}"

NUM_REQUESTS=200
NUM_REPS=3
RESULTS_DIR="/home/ec2-user/results/phase2"
TEMPLATE="/home/ec2-user/phase2-deploy-template.yaml"

DEPLOY_NAME="${FUNC_LABEL}-cpu${CPU_PCT}"

# Select payload
case "$FUNC_LABEL" in
  image-resize) PAYLOAD='{"width":1920,"height":1080}' ;;
  db-query)     PAYLOAD='{"operation":"set","key":"bench","value":"payload"}' ;;
  log-filter)   PAYLOAD='{"lines":100,"pattern":"ERROR"}' ;;
  *)            echo "Unknown function: $FUNC_LABEL"; exit 1 ;;
esac

echo "═══════════════════════════════════════════"
echo "$FUNC_LABEL @ ${CPU_PCT}% (${CPU_MILLI}m CPU, ${MEM_MI}Mi mem)"
echo "Deploy: $DEPLOY_NAME"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════"

# ── Deploy ──
export FUNC_NAME="$DEPLOY_NAME"
export FUNC_LABEL="$FUNC_LABEL"
export FUNC_IMAGE="$IMAGE"
export CPU_MILLI="$CPU_MILLI"
export MEM_MI="$MEM_MI"
envsubst < "$TEMPLATE" | kubectl apply -f -

if [[ "$FUNC_LABEL" == "db-query" ]]; then
  kubectl set env deployment/"$DEPLOY_NAME" -n openfaas-fn REDIS_HOST=redis.openfaas-fn.svc.cluster.local
fi

echo "Waiting for rollout..."
kubectl rollout status deployment/"$DEPLOY_NAME" -n openfaas-fn --timeout=120s
sleep 3
echo "Pod: $(kubectl get pods -n openfaas-fn -l faas_function=$DEPLOY_NAME -o wide --no-headers)"

# ── Warmup ──
echo "Warming up (10 requests)..."
for i in $(seq 1 10); do
  curl -s -o /dev/null --max-time 120 "$GATEWAY/function/$DEPLOY_NAME" -d "$PAYLOAD"
done
echo "Warmup done."

# ── CFS stats before ──
echo ""
echo "Recording CFS stats (before)..."
bash /tmp/read-cfs.sh "$DEPLOY_NAME" dummy > "$RESULTS_DIR/${FUNC_LABEL}_cpu${CPU_PCT}_cfs_before.txt" 2>&1 || true
cat "$RESULTS_DIR/${FUNC_LABEL}_cpu${CPU_PCT}_cfs_before.txt"

# ── Measure ──
for rep in $(seq 1 $NUM_REPS); do
  echo ""
  echo "=== Rep ${rep}/${NUM_REPS}: ${FUNC_LABEL} @ ${CPU_PCT}% ==="
  echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  OUTFILE="$RESULTS_DIR/${FUNC_LABEL}_cpu${CPU_PCT}_rep${rep}.txt"
  rm -f "$OUTFILE"
  ERRORS=0

  for i in $(seq 1 $NUM_REQUESTS); do
    start=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 120 \
      "$GATEWAY/function/$DEPLOY_NAME" -d "$PAYLOAD") || HTTP_CODE="000"
    end=$(date +%s%N)
    latency_ms=$(( (end - start) / 1000000 ))
    echo "$latency_ms" >> "$OUTFILE"
    if [ "$HTTP_CODE" != "200" ]; then ERRORS=$((ERRORS + 1)); fi
    if [ $((i % 50)) -eq 0 ]; then echo "  Progress: $i/$NUM_REQUESTS — last: ${latency_ms}ms"; fi
  done

  echo "End: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Errors: $ERRORS"
  sort -n "$OUTFILE" | awk -v r="$rep" \
    'BEGIN{n=0;s=0}{a[n]=$1;s+=$1;n++}END{printf "Rep%d: n=%d mean=%.0f p50=%d p95=%d p99=%d min=%d max=%d\n",r,n,s/n,a[int(n*0.50)],a[int(n*0.95)],a[int(n*0.99)],a[0],a[n-1]}'
done

# ── CFS stats after ──
echo ""
echo "Recording CFS stats (after)..."
bash /tmp/read-cfs.sh "$DEPLOY_NAME" dummy > "$RESULTS_DIR/${FUNC_LABEL}_cpu${CPU_PCT}_cfs_after.txt" 2>&1 || true
cat "$RESULTS_DIR/${FUNC_LABEL}_cpu${CPU_PCT}_cfs_after.txt"

# ── Teardown ──
echo ""
echo "Tearing down $DEPLOY_NAME..."
kubectl delete deployment "$DEPLOY_NAME" -n openfaas-fn --ignore-not-found=true
kubectl delete service "$DEPLOY_NAME" -n openfaas-fn --ignore-not-found=true
sleep 8
echo "Teardown complete. Remaining pods:"
kubectl get pods -n openfaas-fn --no-headers
echo ""
echo "═══════════════════════════════════════════"
echo "$FUNC_LABEL @ ${CPU_PCT}% — DONE"
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════"
