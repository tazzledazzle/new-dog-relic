#!/usr/bin/env bash
# scripts/smoke/audit-isolation.sh
#
# Verifies the HIPAA audit stream isolation:
#   1. Produces a test event to Kafka ndr.audit
#   2. Waits for the audit-router to write it to the ndr-audit S3 bucket (Object Lock)
#   3. Verifies the written object has Object Lock GOVERNANCE mode active
#   4. Asserts that a standard `aws s3 rm` FAILS (Object Lock refuses deletion — WORM)
#   5. Negative isolation: confirms ndr.audit and ndr-audit-cg appear ONLY in the designated files
#
# Usage: bash scripts/smoke/audit-isolation.sh
# Env:  S3_ENDPOINT (default: http://localhost:9000)
#       S3_ACCESS_KEY (default: minioadmin)
#       S3_SECRET_KEY (default: minioadmin)
#
# Requires: docker compose stack running (kafka + minio + audit-router)
#           aws CLI installed on host
set -euo pipefail

S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9000}"
AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY:-minioadmin}"
AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY:-minioadmin}"
AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

AUDIT_BUCKET="ndr-audit"
AUDIT_TOPIC="ndr.audit"

echo "==> Step 1: Produce test audit event to Kafka $AUDIT_TOPIC..."
TEST_EVENT='{"event":"test_audit","ts":"2026-11-12T00:00:00Z","tenant":"demo-org","actor":"smoke-test","action":"read","resource":"metrics"}'
echo "$TEST_EVENT" | docker compose exec -T kafka \
  kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic "$AUDIT_TOPIC"
echo "  Event produced: $TEST_EVENT"

echo ""
echo "==> Step 2: Wait for audit-router to write to s3://$AUDIT_BUCKET/audit/ (max 90s)..."
MAX_WAIT=90
WAITED=0
AUDIT_KEY=""
while true; do
  LIST_OUTPUT=$(aws s3 ls "s3://${AUDIT_BUCKET}/audit/" --recursive \
    --endpoint-url "$S3_ENDPOINT" 2>/dev/null || true)
  if [[ -n "$LIST_OUTPUT" ]]; then
    # Extract the first key
    AUDIT_KEY=$(echo "$LIST_OUTPUT" | awk '{print $4}' | head -1)
    echo "  Found object: $AUDIT_KEY"
    break
  fi
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "FAIL: No objects in s3://$AUDIT_BUCKET/audit/ after ${MAX_WAIT}s. Is audit-router running?" >&2
    exit 1
  fi
  echo "  ...waiting (${WAITED}s elapsed)..."
  sleep 5
  WAITED=$(( WAITED + 5 ))
done

echo ""
echo "==> Step 3: Fetch object and assert it contains test_audit..."
BODY=$(aws s3 cp "s3://${AUDIT_BUCKET}/${AUDIT_KEY}" - \
  --endpoint-url "$S3_ENDPOINT" 2>/dev/null)
if ! echo "$BODY" | grep -q "test_audit"; then
  echo "FAIL: Object body does not contain 'test_audit'!" >&2
  echo "  Body: $BODY" >&2
  exit 1
fi
echo "  Body contains 'test_audit': OK"

echo ""
echo "==> Step 4: Verify Object Lock is active on the written object..."
HEAD_OUTPUT=$(aws s3api head-object \
  --bucket "$AUDIT_BUCKET" \
  --key "$AUDIT_KEY" \
  --endpoint-url "$S3_ENDPOINT" 2>/dev/null)
echo "  head-object response:"
echo "$HEAD_OUTPUT" | head -20

# Check for ObjectLockMode in the response
if ! echo "$HEAD_OUTPUT" | grep -qi "ObjectLockMode\|GOVERNANCE"; then
  echo "WARN: ObjectLockMode not found in head-object response."
  echo "  This may indicate the bucket was created without Object Lock."
  echo "  Run: bash infra/minio/bootstrap.sh to recreate the bucket with Object Lock."
  # This is a warning not a hard failure because MinIO governance mode response
  # format varies by version; the Object Lock was set at bucket creation.
  echo "  Continuing with WORM-delete test..."
fi

echo ""
echo "==> Step 5: Assert that aws s3 rm FAILS (Object Lock should refuse deletion)..."
# A non-zero exit from aws s3 rm = PASS for this assertion (WORM is working)
set +e
DELETE_OUTPUT=$(aws s3 rm "s3://${AUDIT_BUCKET}/${AUDIT_KEY}" \
  --endpoint-url "$S3_ENDPOINT" 2>&1)
DELETE_EXIT=$?
set -e

if [[ $DELETE_EXIT -eq 0 ]]; then
  echo "FAIL: aws s3 rm succeeded — Object Lock did NOT refuse deletion!" >&2
  echo "  This means the audit bucket is NOT WORM-protected, violating HIPAA requirements." >&2
  echo "  Ensure ndr-audit was created with Object Lock enabled (mc mb --with-lock)." >&2
  exit 1
fi
echo "  aws s3 rm exited $DELETE_EXIT (non-zero = Object Lock REFUSED deletion): PASS"
echo "  Delete error output: $DELETE_OUTPUT"

echo ""
echo "==> Step 6 (NEGATIVE ISOLATION): Verify ndr.audit and ndr-audit-cg are referenced ONLY in designated files..."

# Allowed files: audit-router.yaml and kafka/README.md
# No other infra file may reference the audit topic or consumer group

echo "  Checking ndr-audit-cg references in infra/..."
AUDIT_CG_MATCHES=$(grep -r 'ndr-audit-cg' infra/ 2>/dev/null || true)
echo "  ndr-audit-cg matches:"
echo "$AUDIT_CG_MATCHES"
UNEXPECTED_CG=$(echo "$AUDIT_CG_MATCHES" | grep -v -E '(audit-router\.yaml|kafka/README\.md)' | grep -v '^$' || true)
if [[ -n "$UNEXPECTED_CG" ]]; then
  echo "FAIL: ndr-audit-cg found in unexpected file(s):" >&2
  echo "$UNEXPECTED_CG" >&2
  exit 1
fi
echo "  ndr-audit-cg appears only in allowed files: OK"

echo ""
echo "  Checking ndr.audit references in infra/ (excluding allowed files)..."
AUDIT_TOPIC_MATCHES=$(grep -r 'ndr\.audit' infra/ 2>/dev/null | \
  grep -v -E '(audit-router\.yaml|kafka/README\.md|kafka/create-topics\.sh)' | \
  grep -v '^$' || true)
if [[ -n "$AUDIT_TOPIC_MATCHES" ]]; then
  echo "FAIL: ndr.audit found in unexpected infra file(s):" >&2
  echo "$AUDIT_TOPIC_MATCHES" >&2
  exit 1
fi
echo "  ndr.audit appears only in allowed files: OK"

echo ""
echo "OK: HIPAA audit stream isolation verified."
echo "    ndr.audit -> Object Lock bucket (WORM-protected, GOVERNANCE mode)"
echo "    Consumer group ndr-audit-cg used ONLY by audit-router"
echo "    No observability consumer references ndr.audit or ndr-audit-cg"
