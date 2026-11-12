# Kafka Topology — NewDogRelic

This document records the **locked, one-way-door decisions** for the NewDogRelic Kafka topology.
These decisions are set before any ingest path is written and MUST NOT change without an explicit
ADR and migration plan.

## Locked Topology

| Topic | Partitions | RF (local-dev) | RF (production) | Purpose |
|-------|-----------|-----------------|-----------------|---------|
| `ndr.metrics.raw` | 48 | 1 | 3 | OTLP metrics ingested from OTel Collector |
| `ndr.logs.raw` | 48 | 1 | 3 | OTLP logs ingested from OTel Collector |
| `ndr.traces.raw` | 48 | 1 | 3 | OTLP traces ingested from OTel Collector |
| `ndr.audit` | 12 | 1 | 3 | HIPAA audit stream — isolated, Object Lock sink |

**Why 48 partitions for observability topics?**
Sized for the 5M spans/s, 20M metric samples/s, and 2 GB/s log design targets from PROJECT.md.
48 partitions allows 48 parallel consumers per consumer group without rebalancing. This matches
the target Go ingest service worker count per signal type.

**Why 12 partitions for `ndr.audit`?**
Audit events are low-volume relative to observability signals. 12 partitions provides sufficient
parallelism for the dedicated audit consumer group without over-provisioning.

## Partition Key Convention

**Record key = `tenant_id` value** for all four topics.

The Kafka broker's default partitioner (murmur2 hash of the record key) deterministically maps
each `tenant_id` to a fixed partition. This ensures:
1. Per-tenant ordering within a partition.
2. Consumer-side tenant affinity — a consumer owning partition N always processes the same set
   of tenants, enabling efficient per-tenant buffering and batch writes to IOx.
3. Deterministic partition assignment, verifiable via `scripts/smoke/kafka-topology.sh`.

**Future usage for `ndr.traces.raw` (Phase 3):**
Phase 3 will additionally use `trace_id` as the Kafka message key for trace-affinity routing
(all spans of the same trace land on the same partition, enabling tail-based sampling without
cross-partition scatter/gather). This is a planned usage locked here so Phase 3 does not
re-decide the key strategy.

## Replication Factor Deviation

| Environment | RF | min.insync.replicas | Notes |
|-------------|-----|---------------------|-------|
| Local-dev (`docker-compose.yml`) | 1 | 1 | Single-node KRaft; RF>1 not possible |
| Staging / Production (Helm) | 3 | 2 | Standard production HA; write ACKs from 2/3 replicas |

**This is the ONLY documented RF deviation from the production spec.**
All other topology parameters (partition counts, retention, cleanup policy) are identical
between local-dev and production.

## HIPAA Audit Topic Isolation — `ndr.audit`

`ndr.audit` is **architecturally isolated** from the observability pipeline. It has its own
dedicated consumer group identity:

> **Reserved consumer group: `ndr-audit-cg`**

Rules enforced by architecture (not just documentation):

1. `ndr-audit-cg` is the ONLY consumer group that may subscribe to `ndr.audit`.
2. No observability consumer group (`ndr-metrics-cg`, `ndr-logs-cg`, `ndr-traces-cg`) may ever
   join `ndr.audit`. This would constitute an architectural violation flagged in code review.
3. In production, `ndr.audit` writes to an S3 Object Lock bucket (immutable, versioned) —
   wired in Plan 3. Local-dev uses a standard MinIO bucket.
4. Audit events include: ingest authorization decisions, tenant API key validation, RBAC access
   checks, schema validation failures, and any PHI-adjacent attribute scrubbing actions.

**Reference:** Threat model T-01-03; PITFALLS.md Pitfall 5 (HIPAA audit stream must be separate).

## Why Per-Tenant Topics Are Banned

Per-tenant topics (e.g., `ndr.metrics.raw.tenant-abc`) are explicitly prohibited.

**Root cause:** KRaft has a practical partition ceiling (community guidance: ~100k partitions per
cluster, with degraded performance above ~50k). At 1,000 tenants × 3 signal topics × 48 partitions
= 144,000 partitions — already above the ceiling. At 10,000 tenants the cluster becomes
inoperable.

**Solution:** Shared topics with `tenant_id` as the record key. The broker's default partitioner
deterministically co-locates a tenant's messages into a fixed partition set without requiring
per-tenant topic provisioning.

**Reference:** PITFALLS.md Pitfall 2 (consumer lag cascade from hot tenants);
ARCHITECTURE.md Kafka multi-tenancy section.

## Message Size Ceiling

Default broker `message.max.bytes` = 1 MB (Kafka default). This is the per-record ceiling.
One tenant's oversized span payload cannot exceed 1 MB; payloads larger than this are rejected
at the producer with a `MessageSizeTooLarge` error that the ingest service must handle and
route to a dead-letter topic (implemented in Plan 2).

**Reference:** Threat model T-01-04.
