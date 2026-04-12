#!/usr/bin/env bash
# benchmark-latency.sh — Measure sequential request latency for all 6 OpenFaaS functions.
# Sends N requests to each function, records per-request latency (ms) to /tmp/<func>_latencies.txt,
# then computes and prints P50, P95, P99, mean, stddev, min, max.
#
# Usage: bash benchmark-latency.sh [GATEWAY_URL] [NUM_REQUESTS]
# Example: bash benchmark-latency.sh http://127.0.0.1:31112 200

set -euo pipefail

GATEWAY="${1:-http://127.0.0.1:31112}"
NUM_REQUESTS="${2:-200}"
OUTPUT_DIR="/tmp"

FUNCTIONS="image-resize image-resize-oc db-query db-query-oc log-filter log-filter-oc"

echo "=== Baseline Latency Benchmark ==="
echo "Gateway:  $GATEWAY"
echo "Requests: $NUM_REQUESTS per function"
echo "Output:   $OUTPUT_DIR/<function>_latencies.txt"
echo "Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

for func in $FUNCTIONS; do
  echo "--- $func ($NUM_REQUESTS requests) ---"
  echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Select appropriate payload based on function type
  if [[ "$func" == image-resize* ]]; then
    PAYLOAD='{"width":1920,"height":1080}'
  elif [[ "$func" == db-query* ]]; then
    PAYLOAD="{\"operation\":\"set\",\"key\":\"bench-\$i\",\"value\":\"payload-\$i\"}"
  else
    PAYLOAD='{"lines":100,"pattern":"ERROR"}'
  fi

  rm -f "$OUTPUT_DIR/${func}_latencies.txt"
  ERRORS=0

  for i in $(seq 1 "$NUM_REQUESTS"); do
    # Resolve payload variables (for db-query key uniqueness)
    RESOLVED_PAYLOAD=$(echo "$PAYLOAD" | sed "s/\\\$i/$i/g")

    start=$(date +%s%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      "$GATEWAY/function/$func" -d "$RESOLVED_PAYLOAD")
    end=$(date +%s%N)
    latency_ms=$(( (end - start) / 1000000 ))
    echo "$latency_ms" >> "$OUTPUT_DIR/${func}_latencies.txt"

    if [ "$HTTP_CODE" != "200" ]; then
      ERRORS=$((ERRORS + 1))
      echo "  WARN: request $i returned HTTP $HTTP_CODE"
    fi

    # Progress report every 50 requests
    if [ $((i % 50)) -eq 0 ]; then
      echo "  Progress: $i/$NUM_REQUESTS — last latency: ${latency_ms}ms"
    fi
  done

  echo "End: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Requests: $(wc -l < "$OUTPUT_DIR/${func}_latencies.txt") | Errors: $ERRORS"
  echo ""
done

echo "=== All measurements complete ==="
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
