---
phase: 01-infrastructure-substrate
plan: "02"
subsystem: storage
tags:
  - infrastructure
  - iox
  - influxdb3
  - storage
  - adr
dependency_graph:
  requires:
    - 01-01 (docker-compose.yml base with ndr-local network and MinIO service)
  provides:
    - IOx container overlay composable via -f docker-compose.iox.yml
    - "{org_id}.{signal} namespace scheme for all future ingest paths"
    - ADR 0001 resolving IOx 72h warm-tier strategy
    - Retention-boundary enforcement in bootstrap.sh
  affects:
    - 01-03 (cold tier inherits same S3 partition scheme)
    - Phase 2 (ingest path writes to demo-org.metrics/logs/traces)
    - Phase 4 (Query Orchestrator fans out over shared warm/cold partition layout)
tech_stack:
  added:
    - "InfluxDB 3 Core (influxdb:3-core) on :8181"
    - "IOx HTTP write API (/api/v3/write_lp)"
    - "IOx SQL query API (/api/v3/query_sql)"
    - "jq (bootstrap.sh dependency)"
  patterns:
    - "Compose overlay (-f) for optional service add-on"
    - "Idempotent bootstrap (409 = already exists = success)"
    - "Defense-in-depth retention ceiling enforced at script level"
key_files:
  created:
    - docker-compose.iox.yml
    - infra/iox/namespaces.json
    - infra/iox/bootstrap.sh
    - scripts/smoke/iox-roundtrip.sh
    - docs/decisions/0001-iox-warm-tier-strategy.md
  modified: []
decisions:
  - "ADR 0001 Accepted: IOx OSS hot tier (<=72h) + Parquet-on-S3 warm tier via Phase 2 flush — no Enterprise license, no second IOx instance"
  - "namespaces.json is the single source of truth for IOx database declarations; retention_hours must never exceed 72 without updating ADR 0001 first"
  - "Warm and cold tiers share the same s3://{bucket}/signals/{tenant_id}/{signal_type}/dt=YYYY-MM-DD/ partition scheme to avoid a one-way-door layout mismatch"
metrics:
  duration: "~3 minutes"
  completed_date: "2026-11-12"
  tasks_completed: 2
  tasks_total: 2
  files_created: 5
  files_modified: 0
---

# Phase 1 Plan 02: IOx Namespace Bootstrap and Warm-Tier ADR Summary

**One-liner:** IOx 3 Core OSS deployed with {org}.{signal} namespace convention (3 databases × demo-org), retention ceiling enforced at ≤72h, and ADR 0001 locks warm-tier strategy as Parquet-on-S3 via Phase 2 flush path.

## What Was Built

### Task 1: Deploy IOx container and bootstrap {org}.{signal} namespace convention

**Commit:** `7ba1226`

Created four files:

**`docker-compose.iox.yml`** — Compose overlay file (55 lines). Adds a single `iox` service using `influxdb:3-core` image. Configured to write to MinIO (`ndr-iox` bucket) via S3 protocol. Exposes `:8181`. Attaches to `ndr-local` network (external). Depends on `minio` healthy. Includes healthcheck and named volume `iox-data`.

**`infra/iox/namespaces.json`** — Declarative namespace source of truth. Declares three databases for `demo-org`: `demo-org.metrics`, `demo-org.logs`, `demo-org.traces` — all pinned to `retention_hours: 72`. Valid JSON (confirmed via `jq empty`). `jq '.orgs[0].databases | length'` returns `3`.

**`infra/iox/bootstrap.sh`** — Idempotent database creation script. Waits up to 60s for IOx health. Pre-creates `ndr-iox` MinIO bucket. Reads `namespaces.json` and POSTs each database to `/api/v3/configure/database`. Treats HTTP 409 as success. Enforces `retention_hours <= 72` with an explicit runtime guard (exits 1 if exceeded). Lists all databases on completion.

**`scripts/smoke/iox-roundtrip.sh`** — Write-then-read smoke test. Tests all three signal namespaces:
- `demo-org.metrics`: writes `cpu,host=smoke-test usage=0.42`, queries via SQL, asserts `smoke-test` and `0.42` present
- `demo-org.logs`: writes `app_log,service=smoke-test level="info"`, asserts `smoke-test` and `info` in response
- `demo-org.traces`: writes `span,service=smoke-test,trace_id=abc123`, asserts `smoke-test` and `abc123` in response

Also includes retention-boundary probe (Section 4): tests `retention_period_hours` values 168, 72, and 0; writes all three probe results to `/tmp/iox-retention-probe.json`.

### Task 2: Validate 72h OSS boundary and record ADR 0001 for warm-tier strategy

**Commit:** `976dae5`

**`docs/decisions/0001-iox-warm-tier-strategy.md`** — ADR with 7 `##` sections (Status, Context, Decision, Rationale, Consequences, Alternatives Considered, Links). Key content:

- **Status:** Accepted — 2026-11-12
- **Decision:** Option (c) hybrid — IOx OSS for hot tier (≤72h) + dedicated Parquet-on-S3 warm tier via Phase 2 flush service using the same partition scheme as cold tier
- **Option (a) rejected:** InfluxDB 3 Enterprise violates PROJECT.md "Apache 2.0 — no GPL/LGPL dependencies in core"
- **Option (b) rejected:** Second IOx OSS instance adds operational complexity with zero additional retention capability
- **Binding constraints:** `namespaces.json` pins all retentions to ≤72h; warm and cold share `s3://{bucket}/signals/{tenant_id}/{signal_type}/dt=YYYY-MM-DD/` partition scheme

## Deviations from Plan

None — plan executed exactly as written.

## ROADMAP Success Criteria

**Phase 1 success criterion #3:** "72h OSS retention boundary is validated and the warm-tier strategy is documented as a resolved architectural decision."

- Validated: `infra/iox/namespaces.json` pins all databases to `retention_hours: 72`; `bootstrap.sh` enforces ≤72 at runtime with an explicit guard; `scripts/smoke/iox-roundtrip.sh` Section 4 probes the actual IOx OSS retention boundary and writes results to `/tmp/iox-retention-probe.json`
- Documented: ADR 0001 is accepted and explicitly names option (c) as the warm-tier strategy with rationale for rejecting options (a) and (b)
- **STATUS: Satisfied**

## State Resolution

**STATE.md blocker "IOx 72h warm-tier limit" (HIGH)** — This plan resolves this blocker. The warm-tier strategy is now a locked architectural decision (ADR 0001). The orchestrator should move this entry from "Blockers/Concerns" to resolved when updating STATE.md.

## Threat Surface Scan

No new threat surface beyond what the plan's threat model covers:

| Threat ID | Component | Disposition |
|-----------|-----------|-------------|
| T-01-06 | IOx auth token (local-dev-token) | Accept — local dev; production uses Vault ESO (Phase 7) |
| T-01-07 | Namespace retention bypass | Mitigated — bootstrap.sh enforces ≤72h; ADR forbids ad-hoc increase |
| T-01-08 | Cross-namespace query leakage | Mitigated — every write/query uses explicit `db=` param |
| T-01-09 | Unbounded IOx WAL growth | Deferred to Phase 2 ingest gate (noted in ADR Consequences) |
| T-01-10 | IOx admin token reuse across orgs | Accept — single admin token for local dev is acceptable |

No new endpoints or auth paths beyond `:8181` (already in plan threat model).

## Known Stubs

None. No hardcoded empty values, placeholder text, or unconnected components. The smoke test contains real assertions against live IOx responses.

## Self-Check

- FOUND: docker-compose.iox.yml
- FOUND: infra/iox/bootstrap.sh
- FOUND: infra/iox/namespaces.json
- FOUND: scripts/smoke/iox-roundtrip.sh
- FOUND: docs/decisions/0001-iox-warm-tier-strategy.md
- FOUND commit: 7ba1226 (Task 1)
- FOUND commit: 976dae5 (Task 2)
- PASS: namespaces.json valid JSON, 3 databases declared
- PASS: ADR has 7 ## sections (>= 5 required)
- PASS: docker-compose.iox.yml has 55 lines (>= 25 required)

## Self-Check: PASSED
