#!/usr/bin/env bash
# smoke-test.sh — Quick health check for all 6 OpenFaaS functions.
# Sends one request to each function and prints the HTTP status code, response time, and body.
#
# Usage: bash smoke-test.sh [GATEWAY_URL]
# Example: bash smoke-test.sh http://127.0.0.1:31112

set -euo pipefail

GATEWAY="${1:-http://127.0.0.1:31112}"

echo "=== Smoke Test: All 6 Functions ==="
echo "Gateway: $GATEWAY"
echo ""

FUNCTIONS=(
  "image-resize|{\"width\":1920,\"height\":1080}"
  "image-resize-oc|{\"width\":1920,\"height\":1080}"
  "db-query|{\"operation\":\"set\",\"key\":\"smoke-test\",\"value\":\"hello\"}"
  "db-query-oc|{\"operation\":\"set\",\"key\":\"smoke-test\",\"value\":\"hello\"}"
  "log-filter|{\"lines\":100,\"pattern\":\"ERROR\"}"
  "log-filter-oc|{\"lines\":100,\"pattern\":\"ERROR\"}"
)

PASS=0
FAIL=0

for entry in "${FUNCTIONS[@]}"; do
  IFS='|' read -r func payload <<< "$entry"
  echo "=== $func ==="
  RESPONSE=$(curl -s -w "\nHTTP_CODE: %{http_code} | TIME: %{time_total}s" \
    "$GATEWAY/function/$func" -d "$payload")
  echo "$RESPONSE"
  echo ""

  # Extract HTTP code
  HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | awk '{print $2}')
  if [ "$HTTP_CODE" = "200" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo "=== Results: $PASS passed, $FAIL failed ==="
