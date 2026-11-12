#!/usr/bin/env bash
# infra/postgres/bootstrap.sh
#
# Applies Phase 1 Postgres migrations to the ndr_catalog database.
# Currently applies: 0001_service_edges.sql (shipped empty, ready for Phase 3)
#
# Usage: bash infra/postgres/bootstrap.sh
# Env:  POSTGRES_URL (default: postgres://ndr:ndr@localhost:5432/ndr_catalog)
#
# Idempotent: all DDL uses CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT EXISTS.
set -euo pipefail

POSTGRES_URL="${POSTGRES_URL:-postgres://ndr:ndr@localhost:5432/ndr_catalog}"
MIGRATIONS_DIR="$(dirname "$0")/migrations"

echo "==> Postgres bootstrap: target $POSTGRES_URL"

# Wait for Postgres to be ready (max 60s)
echo "==> Waiting for Postgres to be ready..."
MAX_WAIT=60
WAITED=0
until psql "$POSTGRES_URL" -c '\q' 2>/dev/null; do
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "ERROR: Postgres not reachable after ${MAX_WAIT}s. Is it running?" >&2
    exit 1
  fi
  echo "  ...waiting (${WAITED}s elapsed)..."
  sleep 2
  WAITED=$(( WAITED + 2 ))
done
echo "  Postgres is ready."

# Apply migrations in order
echo ""
echo "==> Applying migrations from $MIGRATIONS_DIR..."
for SQL_FILE in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
  echo "  Applying: $(basename "$SQL_FILE")"
  psql "$POSTGRES_URL" -f "$SQL_FILE"
done

# Verify service_edges table exists
echo ""
echo "==> Verifying schema..."
TABLE_CHECK=$(psql "$POSTGRES_URL" -tAc "\dt service_edges" 2>/dev/null || true)
if [[ -z "$TABLE_CHECK" ]]; then
  echo "ERROR: service_edges table was not created!" >&2
  exit 1
fi
echo "  service_edges: $TABLE_CHECK"

# Verify table is empty (shipped empty)
ROW_COUNT=$(psql "$POSTGRES_URL" -tAc "SELECT COUNT(*) FROM service_edges")
ROW_COUNT=$(echo "$ROW_COUNT" | tr -d '[:space:]')
echo "  Row count: $ROW_COUNT (expected: 0)"
if [[ "$ROW_COUNT" != "0" ]]; then
  echo "ERROR: service_edges is not empty — unexpected rows in Phase 1!" >&2
  exit 1
fi

echo ""
echo "OK: Postgres bootstrap complete. service_edges table ready (empty, awaiting Phase 3)."
