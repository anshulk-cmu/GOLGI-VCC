#!/usr/bin/env bash
# measure-cpu-burst.sh — Measure average CPU microseconds per request for a function.
#
# Reads cgroup v2 cpu.stat (usage_usec) before and after N requests,
# computes delta(usage_usec) / N = average CPU time per request.
#
# This measurement anchors Phase 5's CFS boundary sweep design by telling us
# the actual CPU burst size per invocation.
#
# Usage: Run from the master node (or any node with kubectl + curl access).
#   bash measure-cpu-burst.sh [FUNCTION] [NUM_REQUESTS] [GATEWAY_URL]
#
# Example:
#   bash measure-cpu-burst.sh log-filter-oc 200 http://127.0.0.1:31112

set -euo pipefail

FUNCTION="${1:-log-filter-oc}"
NUM_REQUESTS="${2:-200}"
GATEWAY="${3:-http://127.0.0.1:31112}"

echo "=== CPU Burst Size Measurement ==="
echo "Function:  $FUNCTION"
echo "Requests:  $NUM_REQUESTS"
echo "Gateway:   $GATEWAY"
echo "Started:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Step 1: Find the pod and its worker node ---
echo "--- Step 1: Locating pod and worker node ---"

POD_INFO=$(kubectl get pods -n openfaas-fn -l "faas_function=$FUNCTION" \
  -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.uid} {.items[0].spec.nodeName}')

POD_NAME=$(echo "$POD_INFO" | awk '{print $1}')
POD_UID=$(echo "$POD_INFO" | awk '{print $2}')
NODE_NAME=$(echo "$POD_INFO" | awk '{print $3}')

echo "Pod:    $POD_NAME"
echo "UID:    $POD_UID"
echo "Node:   $NODE_NAME"

# Get the worker node's internal IP for SSH
NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "NodeIP: $NODE_IP"
echo ""

# --- Step 2: Find the cgroup path on the worker node ---
echo "--- Step 2: Finding cgroup path on $NODE_NAME ---"

# k3s uses containerd; cgroup v2 path follows the pattern:
#   /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/
# or for Guaranteed QoS (requests == limits):
#   /sys/fs/cgroup/kubepods.slice/kubepods-pod<uid>.slice/
# The UID in the path has dashes replaced with underscores.
POD_UID_UNDERSCORED=$(echo "$POD_UID" | tr '-' '_')

# Try Guaranteed QoS path first (our pods have requests == limits)
CGROUP_BASE="/sys/fs/cgroup/kubepods.slice/kubepods-pod${POD_UID_UNDERSCORED}.slice"

# SSH to the worker to find the exact cgroup path
# The pod-level cgroup contains the container cgroup(s) inside it
CGROUP_PATH=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  -i /c/Users/worka/.ssh/golgi-key.pem ec2-user@"$NODE_IP" \
  "if [ -d '$CGROUP_BASE' ]; then
     # Find the container cgroup (not the pause container)
     # Look for the one with significant cpu usage
     for d in $CGROUP_BASE/cri-containerd-*.scope; do
       if [ -f \"\$d/cpu.stat\" ]; then
         usage=\$(grep usage_usec \"\$d/cpu.stat\" | awk '{print \$2}')
         if [ \"\$usage\" -gt 1000000 ]; then
           echo \"\$d\"
           break
         fi
       fi
     done
   else
     # Try burstable path
     BURSTABLE_BASE='/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${POD_UID_UNDERSCORED}.slice'
     if [ -d \"\$BURSTABLE_BASE\" ]; then
       for d in \"\$BURSTABLE_BASE\"/cri-containerd-*.scope; do
         if [ -f \"\$d/cpu.stat\" ]; then
           usage=\$(grep usage_usec \"\$d/cpu.stat\" | awk '{print \$2}')
           if [ \"\$usage\" -gt 1000000 ]; then
             echo \"\$d\"
             break
           fi
         fi
       done
     else
       echo 'NOT_FOUND'
     fi
   fi")

if [ "$CGROUP_PATH" = "NOT_FOUND" ] || [ -z "$CGROUP_PATH" ]; then
  echo "ERROR: Could not find cgroup path for pod $POD_NAME"
  echo "Attempting to list available cgroup paths..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    -i /c/Users/worka/.ssh/golgi-key.pem ec2-user@"$NODE_IP" \
    "ls -d /sys/fs/cgroup/kubepods.slice/kubepods-pod${POD_UID_UNDERSCORED}.slice/ 2>/dev/null || echo 'Guaranteed path not found'
     ls -d /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${POD_UID_UNDERSCORED}.slice/ 2>/dev/null || echo 'Burstable path not found'
     echo '--- All pod slices ---'
     ls /sys/fs/cgroup/kubepods.slice/ 2>/dev/null | head -20"
  exit 1
fi

echo "Cgroup: $CGROUP_PATH"
echo ""

# --- Step 3: Read cpu.stat BEFORE requests ---
echo "--- Step 3: Reading cpu.stat before benchmark ---"

BEFORE_STATS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  -i /c/Users/worka/.ssh/golgi-key.pem ec2-user@"$NODE_IP" \
  "cat '$CGROUP_PATH/cpu.stat'")

echo "$BEFORE_STATS"

BEFORE_USAGE=$(echo "$BEFORE_STATS" | grep "^usage_usec" | awk '{print $2}')
BEFORE_THROTTLED=$(echo "$BEFORE_STATS" | grep "^nr_throttled" | awk '{print $2}')
BEFORE_THROTTLED_USEC=$(echo "$BEFORE_STATS" | grep "^throttled_usec" | awk '{print $2}')
BEFORE_PERIODS=$(echo "$BEFORE_STATS" | grep "^nr_periods" | awk '{print $2}')

echo ""
echo "Before — usage_usec: $BEFORE_USAGE, nr_periods: $BEFORE_PERIODS, nr_throttled: $BEFORE_THROTTLED, throttled_usec: $BEFORE_THROTTLED_USEC"
echo ""

# --- Step 4: Send N requests ---
echo "--- Step 4: Sending $NUM_REQUESTS requests to $FUNCTION ---"

# Select payload
if [[ "$FUNCTION" == image-resize* ]]; then
  PAYLOAD='{"width":1920,"height":1080}'
elif [[ "$FUNCTION" == db-query* ]]; then
  PAYLOAD='{"operation":"set","key":"burst-test","value":"payload"}'
else
  PAYLOAD='{"lines":100,"pattern":"ERROR"}'
fi

ERRORS=0
rm -f /tmp/burst_latencies.txt

for i in $(seq 1 "$NUM_REQUESTS"); do
  start=$(date +%s%N)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "$GATEWAY/function/$FUNCTION" -d "$PAYLOAD")
  end=$(date +%s%N)
  latency_ms=$(( (end - start) / 1000000 ))
  echo "$latency_ms" >> /tmp/burst_latencies.txt

  if [ "$HTTP_CODE" != "200" ]; then
    ERRORS=$((ERRORS + 1))
    echo "  WARN: request $i returned HTTP $HTTP_CODE"
  fi

  if [ $((i % 50)) -eq 0 ]; then
    echo "  Progress: $i/$NUM_REQUESTS — last latency: ${latency_ms}ms"
  fi
done

echo "Requests sent: $NUM_REQUESTS | Errors: $ERRORS"
echo ""

# --- Step 5: Read cpu.stat AFTER requests ---
echo "--- Step 5: Reading cpu.stat after benchmark ---"

AFTER_STATS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  -i /c/Users/worka/.ssh/golgi-key.pem ec2-user@"$NODE_IP" \
  "cat '$CGROUP_PATH/cpu.stat'")

echo "$AFTER_STATS"

AFTER_USAGE=$(echo "$AFTER_STATS" | grep "^usage_usec" | awk '{print $2}')
AFTER_THROTTLED=$(echo "$AFTER_STATS" | grep "^nr_throttled" | awk '{print $2}')
AFTER_THROTTLED_USEC=$(echo "$AFTER_STATS" | grep "^throttled_usec" | awk '{print $2}')
AFTER_PERIODS=$(echo "$AFTER_STATS" | grep "^nr_periods" | awk '{print $2}')

echo ""
echo "After — usage_usec: $AFTER_USAGE, nr_periods: $AFTER_PERIODS, nr_throttled: $AFTER_THROTTLED, throttled_usec: $AFTER_THROTTLED_USEC"
echo ""

# --- Step 6: Compute deltas and per-request averages ---
echo "=== Results ==="
echo ""

DELTA_USAGE=$((AFTER_USAGE - BEFORE_USAGE))
DELTA_PERIODS=$((AFTER_PERIODS - BEFORE_PERIODS))
DELTA_THROTTLED=$((AFTER_THROTTLED - BEFORE_THROTTLED))
DELTA_THROTTLED_USEC=$((AFTER_THROTTLED_USEC - BEFORE_THROTTLED_USEC))

AVG_CPU_PER_REQUEST=$((DELTA_USAGE / NUM_REQUESTS))
AVG_CPU_MS=$(echo "scale=2; $AVG_CPU_PER_REQUEST / 1000" | bc)

echo "Delta usage_usec:     $DELTA_USAGE"
echo "Delta nr_periods:     $DELTA_PERIODS"
echo "Delta nr_throttled:   $DELTA_THROTTLED"
echo "Delta throttled_usec: $DELTA_THROTTLED_USEC"
echo ""
echo "Avg CPU per request:  ${AVG_CPU_PER_REQUEST} µs  (${AVG_CPU_MS} ms)"
echo ""

if [ "$DELTA_PERIODS" -gt 0 ]; then
  THROTTLE_RATIO=$(echo "scale=4; $DELTA_THROTTLED / $DELTA_PERIODS" | bc)
  echo "Throttle ratio:       $DELTA_THROTTLED / $DELTA_PERIODS = $THROTTLE_RATIO"
fi

if [ "$DELTA_THROTTLED" -gt 0 ]; then
  AVG_THROTTLE_DURATION=$(echo "scale=1; $DELTA_THROTTLED_USEC / $DELTA_THROTTLED / 1000" | bc)
  echo "Avg throttle duration: ${AVG_THROTTLE_DURATION} ms per throttle event"
fi

echo ""
echo "--- Interpretation ---"
echo "CFS period:   100ms (100,000 µs)"
echo "CPU quota:    $(kubectl get deploy "$FUNCTION" -n openfaas-fn -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')"
echo ""
echo "If avg CPU per request (~${AVG_CPU_MS}ms) is close to the quota per period,"
echo "then requests that happen to use slightly more CPU than the quota will spill"
echo "into the next CFS period, creating bimodal latency (fast mode + slow mode)."
echo ""
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
