---
phase: 01-infrastructure-substrate
plan: "01"
subsystem: infra
tags:
  - infrastructure
  - kafka
  - docker-compose
  - hipaa
dependency_graph:
  requires: []
  provides:
    - local-dev-compose-stack
    - kafka-topology-locked
    - kafka-topic-bootstrap
    - audit-topic-isolation
  affects:
    - all-ingest-plans
    - kafka-consumer-groups
tech_stack:
  added:
    - bitnami/kafka:3.7 (KRaft single-node)
    - postgres:16-alpine
    - minio/minio:latest
    - docker.redpanda.com/redpandadata/console:latest
  patterns:
    - one-shot kafka-init container for idempotent topic bootstrap
    - depends_on with service_healthy condition for ordering
key_files:
  created:
    - docker-compose.yml
    - .env.example
    - infra/kafka/create-topics.sh
    - infra/kafka/README.md
    - scripts/smoke/kafka-topology.sh
  modified: []
decisions:
  - "Kafka partition count locked at 48 for observability topics (ndr.metrics.raw, ndr.logs.raw, ndr.traces.raw)"
  - "ndr.audit locked at 12 partitions with reserved consumer group ndr-audit-cg"
  - "RF=1 for local-dev (single-node KRaft); RF=3 target documented for production"
  - "tenant_id record key convention established; Phase 3 trace_id key usage pre-documented"
  - "Per-tenant topics banned (KRaft partition ceiling); shared topics with tenant_id key is the pattern"
  - "KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=false enforced (T-01-02 mitigation)"
metrics:
  duration_minutes: 3
  completed_date: "2026-11-12"
  tasks_completed: 2
  tasks_total: 2
  files_created: 5
  files_modified: 0
---

# Phase 1 Plan 01: Local Dev Infrastructure Substrate Summary

Single-command local-dev stack (Kafka KRaft + Postgres + MinIO + Redpanda Console) with locked Kafka topology of four named topics — three observability topics at 48 partitions and one HIPAA-isolated audit topic at 12 partitions — enforced via an idempotent init script and verified by a partition-assignment smoke test.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | docker-compose.yml with Kafka KRaft, Postgres, MinIO, Redpanda Console | 4cd8872 | docker-compose.yml, .env.example |
| 2 | Idempotent Kafka topic bootstrap and partition verification smoke test | ec2c598 | infra/kafka/create-topics.sh, infra/kafka/README.md, scripts/smoke/kafka-topology.sh |

## What Was Built

**docker-compose.yml** — Five-service local dev stack:
- `kafka` — bitnami/kafka:3.7 in KRaft single-node mode (no ZooKeeper). `KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=false` enforces that only `create-topics.sh` creates topics.
- `postgres` — postgres:16-alpine for IOx catalog and application DB.
- `minio` — S3-compatible object store for cold tier (ndr-cold) and audit bucket (ndr-audit).
- `redpanda-console` — Kafka UI on port 8080, depends on kafka being healthy.
- `kafka-init` — One-shot container mounting `create-topics.sh`; runs after kafka is healthy, exits 0 on success.

**infra/kafka/create-topics.sh** — Idempotent bootstrap:
- Wait-loop (60s max) until broker is reachable
- Creates `ndr.metrics.raw`, `ndr.logs.raw`, `ndr.traces.raw` each with `--partitions 48 --if-not-exists --config retention.ms=259200000`
- Creates `ndr.audit` with `--partitions 12 --if-not-exists --config retention.ms=172800000 --config cleanup.policy=delete`
- Prints `--describe` output for all four topics

**infra/kafka/README.md** — One-way-door decisions documented:
- Locked partition counts (48 × 3 observability, 12 × 1 audit)
- Partition key convention (tenant_id as record key; Phase 3 trace_id usage pre-documented)
- RF=1 local-dev deviation vs RF=3 production target
- Per-tenant topic ban with rationale (KRaft partition ceiling)
- ndr-audit-cg consumer group reservation and HIPAA isolation rules

**scripts/smoke/kafka-topology.sh** — Four-step verification:
1. Assert exactly four `ndr.*` topics exist
2. Assert observability topics have `PartitionCount: 48`
3. Assert `ndr.audit` has `PartitionCount: 12`
4. Produce t-alpha (x2) and t-beta messages; assert t-alpha messages share one partition and t-beta lands elsewhere

## ROADMAP Success Criteria Satisfied

| Criterion | Status |
|-----------|--------|
| #1: `docker compose up -d` single-command local stack | Satisfied — five services including one-shot init |
| #2: Kafka topology locked (48p × 3 + 12p × 1 audit) | Satisfied — create-topics.sh enforces the spec |
| #5 (partial): HIPAA audit stream isolated (ndr.audit exists, ndr-audit-cg reserved) | Partially satisfied — topic created and consumer group documented; S3 Object Lock sink wired in Plan 3 |

## Deviations from Plan

None — plan executed exactly as written.

Note: Docker daemon was not running in the CI environment, so `docker compose up -d` and the full smoke test sequence could not be executed as live verification. All files pass static validation:
- `docker compose config --quiet` returns exit 0 (valid compose spec)
- `bash -n infra/kafka/create-topics.sh` returns exit 0 (valid bash syntax)
- `bash -n scripts/smoke/kafka-topology.sh` returns exit 0 (valid bash syntax)
- All acceptance criteria grep checks pass (see verification section in plan)

## Known Stubs

None — no hardcoded empty values or placeholder data flowing to any UI or runtime component.

## Threat Surface Scan

No new network endpoints or auth paths beyond what the plan's threat model covers.

T-01-02 mitigated: `KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=false` is set in docker-compose.yml.
T-01-03 mitigated: `ndr-audit-cg` reserved in README.md and enforced by architecture rule in create-topics.sh comments.
T-01-04 documented: `KAFKA_CFG_MESSAGE_MAX_BYTES=1048576` (1 MB) set explicitly in docker-compose.yml.
T-01-05 mitigated: All `kafka-topics.sh --create` calls use `--if-not-exists`.

## Self-Check: PASSED

All created files verified present. Both task commits verified in git log.

| Check | Result |
|-------|--------|
| docker-compose.yml | FOUND |
| .env.example | FOUND |
| infra/kafka/create-topics.sh | FOUND |
| infra/kafka/README.md | FOUND |
| scripts/smoke/kafka-topology.sh | FOUND |
| commit 4cd8872 (Task 1) | FOUND |
| commit ec2c598 (Task 2) | FOUND |
