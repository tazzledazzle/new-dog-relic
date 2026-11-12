#!/usr/bin/env bash
# bootstrap.sh — Idempotent IOx namespace (database) creation for NewDogRelic local dev.
#
# Usage: bash infra/iox/bootstrap.sh
#
# Environment:
#   IOX_URL               — IOx HTTP API base URL (default: http://localhost:8181)
#   INFLUXDB3_AUTH_TOKEN  — IOx bearer token (default: local-dev-token)
#   S3_ACCESS_KEY         — MinIO/S3 access key for ndr-iox bucket creation (default: minioadmin)
#   S3_SECRET_KEY         — MinIO/S3 secret key (default: minioadmin)
#   S3_ENDPOINT           — MinIO/S3 endpoint URL (default: http://localhost:9000)
#
# T-01-07: All databases are created with retention_period_hours <= 72 (from namespaces.json).
#          This script reads ONLY from namespaces.json — do not set retention > 72 inline.
# T-01-08: Cross-namespace query leakage — every write/query must pass an explicit db param.
#          The bootstrap does not create catch-all or wildcard namespaces.
#
# Idempotent: 409 "already exists" responses from IOx are treated as success.
# Safe to run on every `docker compose up -d` or manually during development.

set -euo pipefail

IOX_URL="${IOX_URL:-http://localhost:8181}"
TOKEN="${INFLUXDB3_AUTH_TOKEN:-local-dev-token}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"
S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9000}"
NAMESPACES_FILE="$(dirname "$0")/namespaces.json"

echo "==> IOx Bootstrap starting"
echo "    IOX_URL:          $IOX_URL"
echo "    Namespaces file:  $NAMESPACES_FILE"

# ---------------------------------------------------------------------------
# Step 1: Wait for IOx to be healthy (max 60s)
# ---------------------------------------------------------------------------
echo "==> Waiting for IOx health endpoint..."
MAX_WAIT=60
WAITED=0
until curl -sf "$IOX_URL/health" > /dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: IOx did not become healthy within ${MAX_WAIT}s. Is the container running?"
    exit 1
  fi
  echo "    Waiting... (${WAITED}s elapsed)"
  sleep 3
  WAITED=$((WAITED + 3))
done
echo "    IOx is healthy after ${WAITED}s"

# ---------------------------------------------------------------------------
# Step 2: Pre-create the ndr-iox MinIO bucket (skip if already exists)
# ---------------------------------------------------------------------------
echo "==> Pre-creating ndr-iox bucket in MinIO at $S3_ENDPOINT..."
# Use aws cli if available; otherwise fall back to curl + MinIO admin API
if command -v aws > /dev/null 2>&1; then
  AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  aws s3api create-bucket \
    --endpoint-url "$S3_ENDPOINT" \
    --bucket ndr-iox \
    --region us-east-1 2>&1 | grep -v "already owned by you\|BucketAlreadyOwnedByYou" || true
else
  # Minimal bucket creation via MinIO admin REST endpoint (no aws cli required)
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "$S3_ENDPOINT/ndr-iox" \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" 2>/dev/null || echo "000")
  if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "409" ]; then
    echo "    Bucket ndr-iox: OK (HTTP $RESPONSE)"
  else
    echo "    WARNING: Could not create bucket via aws-sigv4 curl (HTTP $RESPONSE). IOx will create it on first write if MinIO allows."
  fi
fi
echo "    Bucket step complete"

# ---------------------------------------------------------------------------
# Step 3: Create IOx databases from namespaces.json
# ---------------------------------------------------------------------------
# T-01-07: All retentions are read from namespaces.json which pins them <= 72h.
#          Never pass retention_period_hours > 72 to this API.

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)"
  exit 1
fi

echo "==> Creating IOx databases from $NAMESPACES_FILE..."

NUM_ORGS=$(jq '.orgs | length' "$NAMESPACES_FILE")
for org_idx in $(seq 0 $((NUM_ORGS - 1))); do
  ORG_ID=$(jq -r ".orgs[$org_idx].org_id" "$NAMESPACES_FILE")
  NUM_DBS=$(jq ".orgs[$org_idx].databases | length" "$NAMESPACES_FILE")
  echo "  Org: $ORG_ID ($NUM_DBS databases)"

  for db_idx in $(seq 0 $((NUM_DBS - 1))); do
    DB_NAME=$(jq -r ".orgs[$org_idx].databases[$db_idx].name" "$NAMESPACES_FILE")
    RETENTION_HOURS=$(jq -r ".orgs[$org_idx].databases[$db_idx].retention_hours" "$NAMESPACES_FILE")

    # Enforce retention <= 72h (T-01-07 defense in depth)
    if [ "$RETENTION_HOURS" -gt 72 ]; then
      echo "ERROR: Database $DB_NAME has retention_hours=$RETENTION_HOURS which exceeds the OSS 72h limit."
      echo "       Per ADR 0001 (docs/decisions/0001-iox-warm-tier-strategy.md), retention > 72h is forbidden."
      echo "       Warm tier is handled by the Phase 2 Parquet flush path, not by IOx retention settings."
      exit 1
    fi

    echo -n "    Creating database: $DB_NAME (retention: ${RETENTION_HOURS}h)... "
    HTTP_STATUS=$(curl -s -o /tmp/iox-create-response.json -w "%{http_code}" \
      -X POST "$IOX_URL/api/v3/configure/database" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"db\": \"$DB_NAME\", \"retention_period_hours\": $RETENTION_HOURS}")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "204" ]; then
      echo "CREATED (HTTP $HTTP_STATUS)"
    elif [ "$HTTP_STATUS" = "409" ]; then
      echo "ALREADY EXISTS (HTTP 409 — idempotent)"
    else
      echo "ERROR (HTTP $HTTP_STATUS)"
      echo "    Response body: $(cat /tmp/iox-create-response.json)"
      exit 1
    fi
  done
done

# ---------------------------------------------------------------------------
# Step 4: List all databases to confirm
# ---------------------------------------------------------------------------
echo ""
echo "==> Current IOx database list:"
curl -s "$IOX_URL/api/v3/configure/database" \
  -H "Authorization: Bearer $TOKEN" | jq . 2>/dev/null || \
curl -s "$IOX_URL/api/v3/configure/database" \
  -H "Authorization: Bearer $TOKEN"

echo ""
echo "==> Bootstrap complete. All databases are ready."
