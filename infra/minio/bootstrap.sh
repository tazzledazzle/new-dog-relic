#!/usr/bin/env bash
# infra/minio/bootstrap.sh
#
# Creates MinIO buckets per infra/minio/buckets.json.
# - ndr-cold:  standard bucket for Parquet cold-tier storage (no Object Lock)
# - ndr-audit: Object Lock in GOVERNANCE mode, 2190-day (6-year) default retention (HIPAA 45 CFR §164.312(b))
# - ndr-iox:   standard bucket used by IOx 3 Core as its object store
#
# Usage: bash infra/minio/bootstrap.sh
# Env:  S3_ENDPOINT (default: http://minio:9000)
#       S3_ACCESS_KEY (default: minioadmin)
#       S3_SECRET_KEY (default: minioadmin)
#
# Idempotent: safe to run multiple times. Object Lock buckets that already exist are detected
# and skipped (mc mb --with-lock fails on existing buckets; we pre-check with mc ls).
set -euo pipefail

S3_ENDPOINT="${S3_ENDPOINT:-http://minio:9000}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"

BUCKETS_JSON="$(dirname "$0")/buckets.json"
if [[ ! -f "$BUCKETS_JSON" ]]; then
  echo "ERROR: buckets.json not found at $BUCKETS_JSON" >&2
  exit 1
fi

# Run all mc commands inside a one-shot container on the ndr-local Docker network.
# This avoids installing mc on the host and aligns with the CI/CD pattern.
MC="docker run --rm --network ndr-local \
  -e MC_HOST_local=${S3_ENDPOINT} \
  minio/mc:latest"

echo "==> MinIO bootstrap: configuring alias..."
$MC alias set local "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" > /dev/null

echo "==> Reading bucket spec from $BUCKETS_JSON..."

# Parse bucket list using jq (must be available on host, or use docker run python:alpine)
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq / apt-get install jq" >&2
  exit 1
fi

BUCKET_COUNT=$(jq '.buckets | length' "$BUCKETS_JSON")
echo "==> Processing $BUCKET_COUNT buckets..."

for i in $(seq 0 $(( BUCKET_COUNT - 1 ))); do
  NAME=$(jq -r ".buckets[$i].name" "$BUCKETS_JSON")
  OBJ_LOCK=$(jq -r ".buckets[$i].object_lock" "$BUCKETS_JSON")
  RET_MODE=$(jq -r ".buckets[$i].retention_mode" "$BUCKETS_JSON")
  RET_DAYS=$(jq -r ".buckets[$i].retention_days" "$BUCKETS_JSON")

  echo ""
  echo "--- Bucket: $NAME ---"

  # Check if bucket already exists
  if $MC ls "local/$NAME" &>/dev/null; then
    echo "  SKIP: bucket '$NAME' already exists (idempotent run)"
  else
    if [[ "$OBJ_LOCK" == "true" ]]; then
      echo "  CREATE (with Object Lock): mc mb --with-lock local/$NAME"
      # Object Lock MUST be enabled at bucket creation — it cannot be enabled retroactively.
      # This is a one-way door: once a bucket is created without Object Lock, it cannot be added later.
      $MC mb --with-lock "local/$NAME"
    else
      echo "  CREATE (standard): mc mb --ignore-existing local/$NAME"
      $MC mb --ignore-existing "local/$NAME"
    fi
  fi

  # Apply default retention if specified
  if [[ "$RET_MODE" != "null" && "$RET_DAYS" != "0" ]]; then
    echo "  RETENTION: $RET_MODE for ${RET_DAYS} days (default for all objects in bucket)"
    $MC retention set --default "${RET_MODE}" "${RET_DAYS}d" "local/$NAME"
  fi
done

echo ""
echo "==> Bucket listing:"
$MC ls local/

echo ""
echo "==> Retention info per bucket:"
for i in $(seq 0 $(( BUCKET_COUNT - 1 ))); do
  NAME=$(jq -r ".buckets[$i].name" "$BUCKETS_JSON")
  echo "--- $NAME ---"
  $MC retention info "local/$NAME" || echo "  (no default retention — standard bucket)"
done

echo ""
echo "OK: MinIO bootstrap complete."
