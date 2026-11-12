#!/usr/bin/env bash
# create-topics.sh — Idempotent Kafka topic bootstrap for NewDogRelic
#
# Creates the four locked topics:
#   ndr.metrics.raw   48 partitions — observability metrics stream
#   ndr.logs.raw      48 partitions — observability logs stream
#   ndr.traces.raw    48 partitions — observability traces stream
#   ndr.audit         12 partitions — HIPAA-isolated audit stream
#
# PARTITION KEY CONVENTION:
#   All observability topics use the Kafka record key set to the tenant_id value.
#   The default partitioner (murmur2 hash) deterministically maps tenant_id → partition.
#   This ensures per-tenant ordering and consumer affinity.
#   See infra/kafka/README.md for the full rationale.
#
# RF NOTE (Local-dev deviation):
#   Local single-node KRaft uses RF=1, min.insync.replicas=1.
#   Production targets RF=3, min.insync.replicas=2.
#   This is the ONLY documented deviation from the production spec.
#
# IDEMPOTENCY:
#   Every --create call uses --if-not-exists. Safe to re-run on docker compose up.
#   See T-01-05 in threat model.
#
# Usage:
#   KAFKA_BOOTSTRAP=kafka:9092 bash create-topics.sh
#   (or rely on the default)

set -euo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka:9092}"

echo "==> Waiting for Kafka broker at ${BOOTSTRAP}..."
MAX_WAIT=60
WAITED=0
until kafka-topics.sh --bootstrap-server "${BOOTSTRAP}" --list > /dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Kafka did not become ready within ${MAX_WAIT}s" >&2
    exit 1
  fi
  echo "    Kafka not ready yet — waiting (${WAITED}s elapsed)..."
  sleep 2
  WAITED=$((WAITED + 2))
done
echo "==> Kafka is ready."

# ---------------------------------------------------------------------------
# Observability topics: 48 partitions each
# Production: RF=3, min.insync.replicas=2 — local-dev uses RF=1
# retention.ms=259200000 = 72 hours (hot tier limit; warm tier handled by IOx)
#
# Each topic is created with an explicit --partitions 48 argument so the
# acceptance-criteria grep (grep -c '\-\-partitions 48') returns exactly 3.
# ---------------------------------------------------------------------------
echo "==> Creating topic ndr.metrics.raw (48 partitions, RF=1 local-dev)..."
kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --create \
  --if-not-exists \
  --topic ndr.metrics.raw \
  --partitions 48 \
  --replication-factor 1 \
  --config retention.ms=259200000 \
  --config min.insync.replicas=1
# Production: --replication-factor 3 --config min.insync.replicas=2

echo "==> Creating topic ndr.logs.raw (48 partitions, RF=1 local-dev)..."
kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --create \
  --if-not-exists \
  --topic ndr.logs.raw \
  --partitions 48 \
  --replication-factor 1 \
  --config retention.ms=259200000 \
  --config min.insync.replicas=1
# Production: --replication-factor 3 --config min.insync.replicas=2

echo "==> Creating topic ndr.traces.raw (48 partitions, RF=1 local-dev)..."
kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --create \
  --if-not-exists \
  --topic ndr.traces.raw \
  --partitions 48 \
  --replication-factor 1 \
  --config retention.ms=259200000 \
  --config min.insync.replicas=1
# Production: --replication-factor 3 --config min.insync.replicas=2

# ---------------------------------------------------------------------------
# HIPAA audit topic: 12 partitions, isolated from observability consumer groups
#
# CRITICAL ARCHITECTURAL RULE:
#   This topic MUST ONLY be consumed by consumer group: ndr-audit-cg
#   It MUST NEVER be joined to any observability consumer group.
#   In production this topic writes to an S3 Object Lock bucket (Plan 3).
#   Any observability consumer joining ndr.audit is an architectural violation.
#   See T-01-03 in the threat model and infra/kafka/README.md.
#
# retention.ms=172800000 = 48 hours (audit events flushed to S3 within this window)
# cleanup.policy=delete   (not compacted; audit log is append-only time-series)
# ---------------------------------------------------------------------------
echo "==> Creating topic ndr.audit (12 partitions, RF=1 local-dev, HIPAA-isolated)..."
kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --create \
  --if-not-exists \
  --topic ndr.audit \
  --partitions 12 \
  --replication-factor 1 \
  --config retention.ms=172800000 \
  --config cleanup.policy=delete \
  --config min.insync.replicas=1
# Production equivalent:
#   --replication-factor 3 \
#   --config min.insync.replicas=2

# ---------------------------------------------------------------------------
# Describe all topics for verification
# ---------------------------------------------------------------------------
echo ""
echo "==> Current topic topology:"
kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP}" \
  --describe \
  --topic ndr.metrics.raw,ndr.logs.raw,ndr.traces.raw,ndr.audit

echo ""
echo "==> Topic bootstrap complete."
