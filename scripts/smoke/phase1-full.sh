#!/usr/bin/env bash
# scripts/smoke/phase1-full.sh
#
# Phase 1 Full-Stack Smoke Test Suite
#
# Brings up the complete Phase 1 infrastructure stack from a clean state,
# runs all bootstrap scripts and smoke tests in sequence, and verifies every
# ROADMAP Phase 1 success criterion — in under 5 minutes.
#
# ROADMAP Phase 1 success criteria verified:
#   #1: 5-minute single-command smoke (this script itself)
#   #2: Kafka topology locked (3 × 48 partitions + ndr.audit × 12)
#   #3: IOx 3-signal roundtrip + 72h retention boundary validated
#   #4: Cold-tier partition scheme active (tenant_id=X/signal_type=Y/dt=YYYY-MM-DD/)
#   #5: HIPAA audit isolation verified (ndr.audit -> Object Lock bucket, WORM-protected)
#
# Usage:
#   bash scripts/smoke/phase1-full.sh          # Run all tests, tear down on completion
#   bash scripts/smoke/phase1-full.sh --keep   # Keep stack running after tests (for inspection)
#
# Requirements: Docker, Docker Compose, aws CLI, jq on PATH
set -euo pipefail

KEEP_STACK=false
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP_STACK=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

COMPOSE_BASE="-f docker-compose.yml -f docker-compose.iox.yml -f docker-compose.audit.yml"

# Start wall-clock timer
START=$(date +%s)

echo "============================================================"
echo "  NewDogRelic Phase 1 Full-Stack Smoke Test Suite"
echo "  Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Clean slate — tear down any existing stack with volumes
# ---------------------------------------------------------------------------
echo "[1/6] Tearing down any existing stack (clean slate)..."
docker compose $COMPOSE_BASE down -v --remove-orphans 2>/dev/null || true
echo "  Done."

# ---------------------------------------------------------------------------
# Step 2: Bring up the full stack
# ---------------------------------------------------------------------------
echo ""
echo "[2/6] Starting full Phase 1 stack..."
docker compose $COMPOSE_BASE up -d
echo "  Services starting..."

# ---------------------------------------------------------------------------
# Step 3: Wait for all required services to be healthy
# ---------------------------------------------------------------------------
echo ""
echo "[3/6] Waiting for all services to be healthy (max 90s)..."
MAX_WAIT=90
WAITED=0
REQUIRED_SERVICES="kafka postgres minio iox audit-router"

while true; do
  ALL_HEALTHY=true
  for SVC in $REQUIRED_SERVICES; do
    SVC_STATE=$(docker compose $COMPOSE_BASE ps --format json 2>/dev/null | \
      python3 -c "
import sys, json
lines = sys.stdin.read().strip()
# docker compose ps --format json may output one JSON object per line
state = 'missing'
for line in lines.split('\n'):
  line = line.strip()
  if not line:
    continue
  try:
    obj = json.loads(line)
    name = obj.get('Service', obj.get('Name', ''))
    if name == '$SVC' or name.endswith('-$SVC'):
      state = obj.get('Health', obj.get('State', 'unknown'))
      break
  except:
    pass
print(state)
" 2>/dev/null || echo "unknown")
    if [[ "$SVC_STATE" != "healthy" ]]; then
      ALL_HEALTHY=false
      break
    fi
  done

  if $ALL_HEALTHY; then
    echo "  All required services healthy."
    break
  fi

  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "  TIMEOUT: Not all services healthy after ${MAX_WAIT}s. Current state:"
    docker compose $COMPOSE_BASE ps
    echo ""
    echo "FAIL: Startup timeout. Check docker compose logs for details." >&2
    exit 1
  fi
  echo "  ...waiting (${WAITED}s elapsed)..."
  sleep 5
  WAITED=$(( WAITED + 5 ))
done

# ---------------------------------------------------------------------------
# Step 4: Run bootstrap scripts
# ---------------------------------------------------------------------------
echo ""
echo "[4/6] Running bootstrap scripts..."

echo "  --> MinIO buckets..."
bash infra/minio/bootstrap.sh
echo "  MinIO: OK"

echo ""
echo "  --> Postgres migrations..."
bash infra/postgres/bootstrap.sh
echo "  Postgres: OK"

echo ""
echo "  --> IOx namespaces..."
bash infra/iox/bootstrap.sh
echo "  IOx: OK"

# Note: Kafka topics are created by the kafka-init one-shot container during `up -d`
echo ""
echo "  --> Kafka topics: created by kafka-init one-shot during up -d (no manual step needed)"

# ---------------------------------------------------------------------------
# Step 5: Run all smoke tests (fail-fast)
# ---------------------------------------------------------------------------
echo ""
echo "[5/6] Running smoke tests (fail-fast on first failure)..."
SMOKE_PASS=0
SMOKE_FAIL=0

run_smoke() {
  local name="$1"
  local script="$2"
  echo ""
  echo "  === $name ==="
  if bash "$script"; then
    echo "  PASS: $name"
    SMOKE_PASS=$(( SMOKE_PASS + 1 ))
  else
    echo "  FAIL: $name" >&2
    SMOKE_FAIL=$(( SMOKE_FAIL + 1 ))
    return 1
  fi
}

run_smoke "Kafka Topology (criterion #2)" "scripts/smoke/kafka-topology.sh"
run_smoke "IOx Round-Trip (criterion #3)" "scripts/smoke/iox-roundtrip.sh"
run_smoke "Cold Partition Scheme (criterion #4)" "scripts/smoke/cold-partition.sh"
run_smoke "HIPAA Audit Isolation (criterion #5)" "scripts/smoke/audit-isolation.sh"

# ---------------------------------------------------------------------------
# Step 6: Check elapsed time
# ---------------------------------------------------------------------------
echo ""
echo "[6/6] Checking elapsed time..."
ELAPSED=$(( $(date +%s) - START ))
echo "  Elapsed: ${ELAPSED}s"
if [[ $ELAPSED -ge 300 ]]; then
  echo "FAIL: Phase 1 smoke suite exceeded 5-minute budget (${ELAPSED}s > 300s)" >&2
  exit 1
fi
echo "  Within 5-minute budget: OK"

# ---------------------------------------------------------------------------
# Cleanup (unless --keep)
# ---------------------------------------------------------------------------
if ! $KEEP_STACK; then
  echo ""
  echo "Tearing down stack..."
  docker compose $COMPOSE_BASE down -v --remove-orphans
  echo "  Stack removed."
else
  echo ""
  echo "NOTE: Stack kept running (--keep flag). Services:"
  docker compose $COMPOSE_BASE ps
fi

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  OK: Phase 1 smoke suite passed in ${ELAPSED}s"
echo "    - Kafka topology verified (3 observability topics + ndr.audit isolated)"
echo "    - IOx 3-signal roundtrip verified (demo-org.{metrics,logs,traces})"
echo "    - Cold-tier partition scheme verified (tenant_id=X/signal_type=Y/dt=YYYY-MM-DD/)"
echo "    - HIPAA audit isolation verified (ndr.audit -> Object Lock bucket, WORM-protected)"
echo ""
echo "  ROADMAP Phase 1 success criteria #1, #2, #3, #4, #5 all satisfied."
echo "============================================================"
