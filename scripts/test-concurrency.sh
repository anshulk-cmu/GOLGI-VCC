#!/usr/bin/env bash
# test-concurrency.sh — Verify all functions handle concurrent requests (max_inflight=4).
# Sends 4 concurrent requests to each function and verifies all return HTTP 200.
#
# Usage: bash test-concurrency.sh [GATEWAY_URL]
# Example: bash test-concurrency.sh http://127.0.0.1:31112

set -euo pipefail

GATEWAY="${1:-http://127.0.0.1:31112}"
CONCURRENT=4

echo "=== Concurrency Test (max_inflight=$CONCURRENT) ==="
echo "Gateway: $GATEWAY"
echo ""

for func in image-resize image-resize-oc db-query db-query-oc log-filter log-filter-oc; do
  echo -n "Testing $func with $CONCURRENT concurrent requests... "

  # Select appropriate payload based on function type
  if [[ "$func" == image-resize* ]]; then
    PAYLOAD='{"width":1920,"height":1080}'
  elif [[ "$func" == db-query* ]]; then
    PAYLOAD='{"operation":"set","key":"concurrency-test","value":"test"}'
  else
    PAYLOAD='{"lines":100,"pattern":"ERROR"}'
  fi

  # Launch N concurrent requests in background, capture HTTP codes
  PIDS=()
  TMPDIR_CONC=$(mktemp -d)
  for i in $(seq 1 $CONCURRENT); do
    curl -s -o /dev/null -w "%{http_code}" \
      "$GATEWAY/function/$func" -d "$PAYLOAD" > "$TMPDIR_CONC/result_$i" &
    PIDS+=($!)
  done

  # Wait for all to complete
  ALL_OK=true
  for pid in "${PIDS[@]}"; do
    wait "$pid" || ALL_OK=false
  done

  # Check results
  CODES=""
  FAILURES=0
  for i in $(seq 1 $CONCURRENT); do
    CODE=$(cat "$TMPDIR_CONC/result_$i")
    CODES="$CODES $CODE"
    if [ "$CODE" != "200" ]; then
      FAILURES=$((FAILURES + 1))
    fi
  done
  rm -rf "$TMPDIR_CONC"

  if [ $FAILURES -eq 0 ]; then
    echo "PASS (all $CONCURRENT returned 200)"
  else
    echo "FAIL ($FAILURES/$CONCURRENT non-200: $CODES)"
  fi
done

echo ""
echo "=== Concurrency test complete ==="
