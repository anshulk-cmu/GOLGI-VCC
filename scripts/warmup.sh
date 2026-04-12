#!/usr/bin/env bash
# warmup.sh — Send 5 throwaway requests to each function to eliminate cold-start skew.
# Run on the master node (or any node with access to the OpenFaaS gateway).
#
# Usage: bash warmup.sh [GATEWAY_URL]
# Example: bash warmup.sh http://127.0.0.1:31112

set -euo pipefail

GATEWAY="${1:-http://127.0.0.1:31112}"
WARMUP_COUNT=5

echo "=== Warmup: $WARMUP_COUNT requests per function ==="
echo "Gateway: $GATEWAY"
echo ""

for func in image-resize image-resize-oc db-query db-query-oc log-filter log-filter-oc; do
  echo -n "Warming $func: "

  # Select appropriate payload based on function type
  if [[ "$func" == image-resize* ]]; then
    PAYLOAD='{"width":1920,"height":1080}'
  elif [[ "$func" == db-query* ]]; then
    PAYLOAD='{"operation":"set","key":"warmup","value":"test"}'
  else
    PAYLOAD='{"lines":100,"pattern":"ERROR"}'
  fi

  for i in $(seq 1 $WARMUP_COUNT); do
    curl -s -o /dev/null -w "%{time_total}s " \
      "$GATEWAY/function/$func" -d "$PAYLOAD"
  done
  echo "DONE"
done

echo ""
echo "=== Warmup complete ==="
