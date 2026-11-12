#!/usr/bin/env bash
# scripts/smoke/cold-partition.sh
#
# Verifies the cold-tier S3 partition scheme is correct per ADR 0002.
#
# Scheme: s3://ndr-cold/tenant_id={tenant}/signal_type={type}/dt=YYYY-MM-DD/{file}.parquet
#
# Tests:
#   1. Generate a minimal Parquet file (pyarrow in a one-shot container)
#   2. Upload to the exact partition path
#   3. Download back and verify SHA-256 match (round-trip integrity)
#   4. List the partition path and confirm sample.parquet appears
#   5. NEGATIVE: list year=.../month=.../day=.../ path — must be empty (confirms no nested partitioning)
#
# Usage: bash scripts/smoke/cold-partition.sh
# Env:  S3_ENDPOINT (default: http://localhost:9000)
#       S3_ACCESS_KEY (default: minioadmin)
#       S3_SECRET_KEY (default: minioadmin)
set -euo pipefail

S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9000}"
AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY:-minioadmin}"
AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY:-minioadmin}"
AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

BUCKET="ndr-cold"
TENANT="t-alpha"
SIGNAL_TYPE="metrics"
DATE="2026-11-12"
PARTITION_PREFIX="tenant_id=${TENANT}/signal_type=${SIGNAL_TYPE}/dt=${DATE}"
OBJECT_KEY="${PARTITION_PREFIX}/sample.parquet"
LOCAL_PARQUET="/tmp/cold-smoke-sample.parquet"
ROUNDTRIP_PARQUET="/tmp/cold-smoke-roundtrip.parquet"

echo "==> Step 1: Generate test Parquet file using pyarrow in one-shot container..."
docker run --rm \
  -v /tmp:/out \
  python:3.12-slim \
  bash -c "
    pip install -q --no-deps 'pyarrow==17.0.0' 2>&1 | tail -3
    python3 -c \"
import pyarrow as pa
import pyarrow.parquet as pq
import datetime

schema = pa.schema([
  pa.field('ts', pa.timestamp('ms')),
  pa.field('service', pa.string()),
  pa.field('value', pa.float64()),
])
base_ts = datetime.datetime(2026, 11, 12, 0, 0, 0)
data = pa.table({
  'ts':      pa.array([base_ts.timestamp() * 1000 + i*1000 for i in range(10)], type=pa.timestamp('ms')),
  'service': pa.array(['smoke-test'] * 10, type=pa.string()),
  'value':   pa.array([float(i) * 0.1 for i in range(10)], type=pa.float64()),
}, schema=schema)
pq.write_table(data, '/out/cold-smoke-sample.parquet')
print('Generated /out/cold-smoke-sample.parquet rows=' + str(len(data)))
\"
  "
echo "  Generated: $LOCAL_PARQUET"
ls -lh "$LOCAL_PARQUET"

echo ""
echo "==> Step 2: Upload to cold bucket at partition path: s3://$BUCKET/$OBJECT_KEY"
aws s3 cp "$LOCAL_PARQUET" "s3://${BUCKET}/${OBJECT_KEY}" \
  --endpoint-url "$S3_ENDPOINT"
echo "  Upload complete."

echo ""
echo "==> Step 3: Download back for round-trip integrity check..."
aws s3 cp "s3://${BUCKET}/${OBJECT_KEY}" "$ROUNDTRIP_PARQUET" \
  --endpoint-url "$S3_ENDPOINT"

echo "  Computing SHA-256..."
ORIG_SHA=$(sha256sum "$LOCAL_PARQUET" | awk '{print $1}')
ROUNDTRIP_SHA=$(sha256sum "$ROUNDTRIP_PARQUET" | awk '{print $1}')
echo "  Original:   $ORIG_SHA"
echo "  Round-trip: $ROUNDTRIP_SHA"
if [[ "$ORIG_SHA" != "$ROUNDTRIP_SHA" ]]; then
  echo "FAIL: SHA-256 mismatch — data corruption in round-trip!" >&2
  exit 1
fi
echo "  SHA-256 match: OK"

echo ""
echo "==> Step 4: List partition path and assert sample.parquet appears..."
LIST_OUTPUT=$(aws s3 ls "s3://${BUCKET}/${PARTITION_PREFIX}/" \
  --endpoint-url "$S3_ENDPOINT")
echo "$LIST_OUTPUT"
if ! echo "$LIST_OUTPUT" | grep -q "sample.parquet"; then
  echo "FAIL: sample.parquet not visible at partition path!" >&2
  exit 1
fi
echo "  sample.parquet found at correct partition path: OK"

echo ""
echo "==> Step 5 (NEGATIVE): Assert nested year=.../month=.../day=.../ does NOT exist..."
NESTED_OUTPUT=$(aws s3 ls "s3://${BUCKET}/year=2026/month=11/day=12/" \
  --endpoint-url "$S3_ENDPOINT" 2>/dev/null || true)
if [[ -n "$NESTED_OUTPUT" ]]; then
  echo "FAIL: Objects found at nested year/month/day partition path — this violates ADR 0002!" >&2
  echo "  Found: $NESTED_OUTPUT" >&2
  exit 1
fi
echo "  Nested year/month/day path is empty: OK (no accidental nested writes)"

echo ""
echo "OK: Cold partition scheme verified: tenant_id=X/signal_type=Y/dt=YYYY-MM-DD/"
echo "    ADR 0002 partition layout confirmed correct."

# Cleanup temp files
rm -f "$LOCAL_PARQUET" "$ROUNDTRIP_PARQUET"
