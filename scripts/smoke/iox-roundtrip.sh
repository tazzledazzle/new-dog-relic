#!/usr/bin/env bash
# iox-roundtrip.sh — Write-then-read smoke test against IOx HTTP + SQL endpoints.
#
# Tests:
#   1. Line-protocol write + SQL query roundtrip for demo-org.metrics (cpu measurement)
#   2. Line-protocol write + SQL query roundtrip for demo-org.logs (app_log measurement)
#   3. Line-protocol write + SQL query roundtrip for demo-org.traces (span measurement)
#   4. Retention-boundary probe: test which retention_period_hours values IOx accepts
#
# Usage:
#   # Run against local dev (IOx must be up and databases bootstrapped):
#   bash scripts/smoke/iox-roundtrip.sh
#
#   # Run against a custom IOx URL:
#   IOX_URL=http://iox.example.com:8181 bash scripts/smoke/iox-roundtrip.sh
#
# Exit codes:
#   0  — All roundtrip assertions passed and retention probe completed
#   1  — One or more assertions failed
#
# T-01-08: Every write and query uses an explicit db= parameter (enforced below).

set -euo pipefail

IOX_URL="${IOX_URL:-http://localhost:8181}"
TOKEN="${INFLUXDB3_AUTH_TOKEN:-local-dev-token}"
PROBE_OUTPUT="${RETENTION_PROBE_OUTPUT:-/tmp/iox-retention-probe.json}"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
iox_write() {
  local db="$1"
  local lp="$2"
  local timestamp_ns
  timestamp_ns="$(date +%s)000000000"

  HTTP_STATUS=$(curl -s -o /tmp/iox-write-response.txt -w "%{http_code}" \
    -X POST "${IOX_URL}/api/v3/write_lp?db=${db}&precision=nanosecond" \
    -H "Authorization: Bearer ${TOKEN}" \
    --data-binary "${lp} ${timestamp_ns}")
  echo "$HTTP_STATUS"
}

iox_query() {
  local db="$1"
  local sql="$2"
  curl -s \
    -X POST "${IOX_URL}/api/v3/query_sql" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"db\": \"${db}\", \"q\": ${sql}, \"format\": \"json\"}"
}

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if echo "$haystack" | grep -q "$needle"; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "    Expected to find: $needle"
    echo "    In response:      $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_http() {
  local description="$1"
  local actual="$2"
  local expected="$3"

  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $description (HTTP $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description (HTTP $actual, expected $expected)"
    if [ -f /tmp/iox-write-response.txt ]; then
      echo "    Response body: $(cat /tmp/iox-write-response.txt)"
    fi
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Section 1: demo-org.metrics (cpu measurement)
# ---------------------------------------------------------------------------
echo "==> [1/3] Roundtrip: demo-org.metrics (cpu measurement)"

WRITE_STATUS=$(iox_write "demo-org.metrics" "cpu,host=smoke-test usage=0.42")
assert_http "Write cpu record to demo-org.metrics" "$WRITE_STATUS" "204"

echo "    Sleeping 2s for WAL flush..."
sleep 2

QUERY_RESULT=$(iox_query "demo-org.metrics" '"SELECT * FROM cpu WHERE host = '\''smoke-test'\'' ORDER BY time DESC LIMIT 1"')
assert_contains "Response contains host=smoke-test" "$QUERY_RESULT" '"smoke-test"'
assert_contains "Response contains usage=0.42" "$QUERY_RESULT" '0.42'

# ---------------------------------------------------------------------------
# Section 2: demo-org.logs (app_log measurement)
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/3] Roundtrip: demo-org.logs (app_log measurement)"

WRITE_STATUS=$(iox_write "demo-org.logs" "app_log,service=smoke-test level=\"info\",message=\"smoke test log entry\"")
assert_http "Write app_log record to demo-org.logs" "$WRITE_STATUS" "204"

echo "    Sleeping 2s for WAL flush..."
sleep 2

QUERY_RESULT=$(iox_query "demo-org.logs" '"SELECT * FROM app_log WHERE service = '\''smoke-test'\'' ORDER BY time DESC LIMIT 1"')
assert_contains "Response contains service=smoke-test" "$QUERY_RESULT" '"smoke-test"'
assert_contains "Response contains level=info" "$QUERY_RESULT" '"info"'

# ---------------------------------------------------------------------------
# Section 3: demo-org.traces (span measurement)
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/3] Roundtrip: demo-org.traces (span measurement)"

WRITE_STATUS=$(iox_write "demo-org.traces" "span,service=smoke-test,trace_id=abc123 duration_ms=12,status=\"ok\"")
assert_http "Write span record to demo-org.traces" "$WRITE_STATUS" "204"

echo "    Sleeping 2s for WAL flush..."
sleep 2

QUERY_RESULT=$(iox_query "demo-org.traces" '"SELECT * FROM span WHERE service = '\''smoke-test'\'' ORDER BY time DESC LIMIT 1"')
assert_contains "Response contains service=smoke-test" "$QUERY_RESULT" '"smoke-test"'
assert_contains "Response contains trace_id=abc123" "$QUERY_RESULT" '"abc123"'

# ---------------------------------------------------------------------------
# Section 4: Retention boundary probe (for ADR 0001)
#
# This section does NOT fail the script regardless of IOx responses.
# It records observed behavior so ADR 0001 can cite empirical evidence.
# Results written to $PROBE_OUTPUT (default: /tmp/iox-retention-probe.json).
#
# T-01-07: Databases created here use name prefix "retention-probe-" to
#          distinguish them from production namespaces; bootstrap.sh never
#          creates these.
# ---------------------------------------------------------------------------
echo ""
echo "==> [Retention Probe] Testing IOx OSS 72h retention boundary..."
echo "    Results will be written to: $PROBE_OUTPUT"

probe_retention() {
  local hours="$1"
  local db_name="retention-probe-${hours}h"

  HTTP_STATUS=$(curl -s -o /tmp/probe-response.json -w "%{http_code}" \
    -X POST "${IOX_URL}/api/v3/configure/database" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"db\": \"${db_name}\", \"retention_period_hours\": ${hours}}" 2>/dev/null || echo "000")

  BODY=$(cat /tmp/probe-response.json 2>/dev/null || echo "")
  echo "{\"retention_hours\": ${hours}, \"http_status\": \"${HTTP_STATUS}\", \"body\": $(echo "$BODY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${BODY}\"")}"
}

echo "    Testing retention_period_hours=168 (7 days — above OSS 72h limit)..."
PROBE_168=$(probe_retention 168)
echo "    Result: $PROBE_168"

echo "    Testing retention_period_hours=72 (3 days — OSS limit)..."
PROBE_72=$(probe_retention 72)
echo "    Result: $PROBE_72"

echo "    Testing retention_period_hours=0 (unlimited / no expiry)..."
PROBE_0=$(probe_retention 0)
echo "    Result: $PROBE_0"

# Write all three probe results to the output file
printf '[%s, %s, %s]\n' "$PROBE_168" "$PROBE_72" "$PROBE_0" > "$PROBE_OUTPUT"

echo "    OK: Retention boundary probe complete; results in $PROBE_OUTPUT"

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo ""
echo "==> Roundtrip test summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: IOx roundtrip smoke test failed ($FAIL assertion(s) failed)"
  exit 1
fi

echo "OK: IOx 3-signal roundtrip verified"
