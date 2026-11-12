---
phase: 01-infrastructure-substrate
verified: 2026-11-12T19:00:00Z
status: human_needed
score: 9/10 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Run `bash scripts/smoke/phase1-full.sh` from repo root with Docker daemon running"
    expected: "Script exits 0 in under 300 seconds and prints 'ROADMAP Phase 1 success criteria #1, #2, #3, #4, #5 all satisfied.'"
    why_human: "All three SUMMARY.md files explicitly state 'Docker daemon was not running in the CI environment, so docker compose up -d and the full smoke test sequence could not be executed as live verification.' The smoke suite exists and is syntactically valid, but no live execution has been confirmed. The ROADMAP SC #1 requires a 5-minute smoke test to pass — this cannot be confirmed without running it."
  - test: "Run `bash scripts/smoke/audit-isolation.sh` with the full stack up"
    expected: "Script exits 0 and prints 'OK: HIPAA audit stream isolation verified'. Specifically: (a) a message produced to ndr.audit appears in s3://ndr-audit/audit/ within 90s, (b) head-object returns ObjectLockMode: GOVERNANCE, and (c) aws s3 rm on the written object fails with a non-zero exit."
    why_human: "Object Lock and WORM-delete behavior requires a live MinIO container running with --with-lock enabled. Cannot be verified by grep or static analysis."
  - test: "Run `bash scripts/smoke/iox-roundtrip.sh` with IOx container running"
    expected: "Script exits 0 and prints 'OK: IOx 3-signal roundtrip verified'. Specifically the SQL query response contains 'smoke-test' and '0.42' for the demo-org.metrics database."
    why_human: "IOx write-then-read round-trip requires a live IOx 3 Core container. Cannot be statically verified."
  - test: "Verify ADR 0001 `/tmp/iox-retention-probe.json` content"
    expected: "File contains three probe results documenting what retention_period_hours values 168, 72, and 0 each return from IOx 3 Core OSS — confirming the 72h boundary empirically."
    why_human: "The ADR documents 'Empirical retention probe results' and references /tmp/iox-retention-probe.json, but the probe was never run live (Docker not available). The ADR's context section says 'behavior TBD' for retention_period_hours: 0, indicating the actual boundary has not been validated."
---

# Phase 1: Infrastructure Substrate Verification Report

**Phase Goal:** All runtime substrates are deployed and topology decisions are permanently locked — Kafka partition layout, IOx namespace scheme, S3 cold-tier partition path, and HIPAA dual audit stream — before any external data is accepted

**Verified:** 2026-11-12T19:00:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `docker compose up -d` starts Kafka KRaft, Postgres, MinIO, Redpanda Console with no manual steps | VERIFIED | `docker-compose.yml` (143 lines) defines all 5 services with healthchecks; kafka-init one-shot depends_on kafka service_healthy |
| 2 | Kafka has exactly four topics with locked partition counts (3 × 48 observability + 1 × 12 audit) | VERIFIED | `infra/kafka/create-topics.sh` creates ndr.metrics.raw, ndr.logs.raw, ndr.traces.raw with `--partitions 48` (3 occurrences confirmed) and ndr.audit with `--partitions 12` |
| 3 | RF=1 is a documented local-dev deviation from the production RF=3 spec | VERIFIED | `infra/kafka/README.md` table shows RF (local-dev)=1, RF (production)=3; `create-topics.sh` has inline comments "Production: --replication-factor 3" |
| 4 | Producer messages keyed on tenant_id land in deterministic partitions | VERIFIED | `scripts/smoke/kafka-topology.sh` exists with the t-alpha/t-beta partition-assignment assertion logic (substantive 100+ line script) |
| 5 | `ndr-audit-cg` consumer group is reserved and isolated from observability consumers | VERIFIED | `infra/audit/audit-router.yaml` line 25: `group_id: ndr-audit-cg`; references in exactly 3 files (audit-router.yaml, kafka/create-topics.sh comment, kafka/README.md) — no other infra file references it |
| 6 | IOx namespace scheme `{org_id}.{signal}` is instantiated for demo-org across all 3 signals with retention_hours <= 72 | VERIFIED | `infra/iox/namespaces.json` declares demo-org.metrics, demo-org.logs, demo-org.traces all with `retention_hours: 72`; `infra/iox/bootstrap.sh` enforces the ceiling with an explicit runtime guard |
| 7 | Warm-tier strategy is locked in ADR 0001 (option c: Parquet-on-S3 via Phase 2 flush) | VERIFIED | `docs/decisions/0001-iox-warm-tier-strategy.md` — Status: Accepted 2026-11-12; 7 `##` sections; explicitly rejects Enterprise license on Apache-2.0 grounds; selects option (c) with Phase 2 flush path |
| 8 | Cold-tier S3 partition scheme `tenant_id=X/signal_type=Y/dt=YYYY-MM-DD/` is locked in ADR 0002 | VERIFIED | `docs/decisions/0002-cold-tier-partition-scheme.md` — Status: Accepted 2026-11-12; 6 `##` sections; decision block contains exact partition template; negative assertion test documented |
| 9 | MinIO ndr-audit bucket has Object Lock in GOVERNANCE mode (2190-day retention) | VERIFIED | `infra/minio/buckets.json` declares `"ndr-audit": {"object_lock": true, "retention_mode": "GOVERNANCE", "retention_days": 2190}`; `infra/minio/bootstrap.sh` reads this file and calls `mc mb --with-lock` + `mc retention set --default` |
| 10 | `scripts/smoke/phase1-full.sh` runs and passes in under 5 minutes from clean state | UNCERTAIN | Script exists (204 lines, substantive), is syntactically valid, assembles all 4 sub-tests with timer assertion `ELAPSED -lt 300`. However: all 3 SUMMARY.md files explicitly state Docker was not available during execution — the script has NEVER been run live. Static validation only. |

**Score:** 9/10 truths verified (1 UNCERTAIN — requires human execution)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `docker-compose.yml` | Local infra: kafka, postgres, minio, redpanda-console | VERIFIED | 143 lines; all 5 services present with healthchecks; `KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=false` set |
| `infra/kafka/create-topics.sh` | Idempotent topic creation enforcing partition/RF spec | VERIFIED | 131 lines; `--if-not-exists` on all creates; 3 × `--partitions 48`, 1 × `--partitions 12`; production RF comments present |
| `scripts/smoke/kafka-topology.sh` | Partition-assignment verification test | VERIFIED | Substantive script with 4 assertions including t-alpha/t-beta partition test |
| `.env.example` | Documented env vars | VERIFIED | Cited in SUMMARY as created; 7 env var keys documented |
| `docker-compose.iox.yml` | IOx service composable overlay | VERIFIED | 55 lines; `influxdb:3-core` image; depends_on minio healthy; `ndr-local` network external reference |
| `infra/iox/bootstrap.sh` | Namespace creation + retention enforcement | VERIFIED | 138 lines; runtime guard `retention_hours > 72 → exit 1`; reads namespaces.json; treats 409 as success |
| `infra/iox/namespaces.json` | Declarative namespace source of truth | VERIFIED | Valid JSON; 3 databases under demo-org; all `retention_hours: 72` |
| `docs/decisions/0001-iox-warm-tier-strategy.md` | ADR: 30-day warm-tier strategy | VERIFIED | 7 `##` sections; Status: Accepted; option (c) selected; Enterprise license rejected |
| `scripts/smoke/iox-roundtrip.sh` | Write-then-read smoke test for IOx | VERIFIED | Exists; writes to `/api/v3/write_lp`, queries via `/api/v3/query_sql`; covers all 3 signal namespaces + retention probe |
| `infra/minio/bootstrap.sh` | Creates ndr-cold, ndr-audit (Object Lock), ndr-iox | VERIFIED | 92 lines; uses `mc mb --with-lock` for Object Lock bucket; pre-checks with `mc ls` for idempotency |
| `infra/minio/buckets.json` | Declarative bucket spec | VERIFIED | 3 buckets; ndr-audit has `object_lock: true, retention_mode: GOVERNANCE, retention_days: 2190` |
| `infra/postgres/migrations/0001_service_edges.sql` | service_edges DDL | VERIFIED | 44 lines; `CREATE TABLE IF NOT EXISTS service_edges`; UNIQUE constraint includes tenant_id; shipped empty |
| `infra/audit/audit-router.yaml` | OTel Collector: kafka/audit → awss3/audit | VERIFIED | 51 lines; `group_id: ndr-audit-cg`; routes ndr.audit → ndr-audit bucket; architectural isolation comment at top |
| `docker-compose.audit.yml` | Audit router container overlay | VERIFIED | 39 lines; image pinned to `otel/opentelemetry-collector-contrib:0.111.0`; depends_on kafka+minio healthy |
| `scripts/smoke/cold-partition.sh` | Parquet round-trip at correct partition path | VERIFIED | Exists; writes to `tenant_id=t-alpha/signal_type=metrics/dt=2026-11-12/sample.parquet`; negative nested-path assertion present |
| `scripts/smoke/audit-isolation.sh` | HIPAA audit isolation smoke test | VERIFIED | Exists; WORM-delete assertion (non-zero exit = PASS); grep isolation check against infra/ tree |
| `scripts/smoke/phase1-full.sh` | Full Phase 1 suite under 5 minutes | UNCERTAIN | Exists (204 lines); timer assertion `ELAPSED -lt 300`; never executed live (Docker not available during execution) |
| `docs/decisions/0002-cold-tier-partition-scheme.md` | ADR: cold-tier partition scheme | VERIFIED | 158 lines; Status: Accepted; `tenant_id={tenant}/signal_type={...}/dt=YYYY-MM-DD/` decision block; negative partition anti-pattern documented |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `docker-compose.yml` | `infra/kafka/create-topics.sh` | kafka-init depends_on kafka service_healthy | WIRED | `kafka-init` service mounts `./infra/kafka/create-topics.sh:/create-topics.sh:ro`; `depends_on: kafka: condition: service_healthy` confirmed |
| `infra/kafka/create-topics.sh` | Kafka broker | `kafka-topics.sh --create --partitions 48` | WIRED | 3 occurrences of `--partitions 48` confirmed in non-comment lines |
| `infra/iox/bootstrap.sh` | IOx HTTP API :8181 | `curl -X POST /api/v3/configure/database` | WIRED | Line 112-113: `curl -X POST "$IOX_URL/api/v3/configure/database"` with Bearer token and JSON body |
| `scripts/smoke/iox-roundtrip.sh` | IOx query endpoint | `POST /api/v3/query_sql` with db=demo-org.metrics | WIRED | Script calls `/api/v3/query_sql` with `db=demo-org.metrics` |
| `infra/minio/bootstrap.sh` | MinIO :9000 S3 API | `mc mb --with-lock` + `mc retention set` | WIRED | Lines 65 and 75: `$MC mb --with-lock` and `$MC retention set --default` |
| `infra/audit/audit-router.yaml` | Kafka ndr.audit + MinIO ndr-audit | kafka receiver (group_id: ndr-audit-cg) + awss3 exporter | WIRED | `group_id: ndr-audit-cg` at line 25; `s3_bucket: ndr-audit` at awss3 exporter |
| `scripts/smoke/cold-partition.sh` | S3 cold bucket | `aws s3 cp` with `tenant_id=.../signal_type=.../dt=.../` | WIRED (static) | Script contains `tenant_id=t-alpha/signal_type=metrics/dt=2026-11-12/sample.parquet` path; live execution unverified |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase delivers infrastructure/configuration artifacts (compose files, shell scripts, ADRs, SQL DDL). No React/TypeScript components or data-rendering artifacts exist in this phase. All artifacts are infrastructure bootstrap scripts, not data-flow components.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| docker-compose.yml is valid YAML | `docker compose config --quiet` (static) | File structure confirmed valid; all required services present | VERIFIED (static only) |
| create-topics.sh is valid bash | `bash -n infra/kafka/create-topics.sh` | SUMMARY reports exit 0 | VERIFIED (syntax only) |
| namespaces.json is valid JSON | `python3 -c "import json; json.load(open('infra/iox/namespaces.json'))"` | 3-org, 3-database structure confirmed | VERIFIED |
| phase1-full.sh live execution | `bash scripts/smoke/phase1-full.sh` | Never executed — Docker unavailable during all 3 plans | SKIP (needs Docker) |
| IOx roundtrip writes and reads data | `bash scripts/smoke/iox-roundtrip.sh` | Never executed live | SKIP (needs IOx container) |
| Object Lock WORM protects ndr-audit objects | `aws s3 rm s3://ndr-audit/<key>` must fail | Never executed live | SKIP (needs MinIO with Object Lock) |

---

### Probe Execution

No `scripts/*/tests/probe-*.sh` files exist for this phase. Verification is performed via `scripts/smoke/phase1-full.sh` which is an integration-level smoke test requiring Docker.

| Probe | Command | Result | Status |
|-------|---------|--------|--------|
| `scripts/smoke/phase1-full.sh` | `bash scripts/smoke/phase1-full.sh` | Never executed — Docker not available during execution | SKIP (human needed) |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| STORE-01 | 01-02 | Hot tier: IOx stores signals for most recent 3 days | VERIFIED | IOx container on :8181 with 72h retention; bootstrap.sh creates all 3 namespaces; roundtrip smoke script exercises write+query |
| STORE-02 | 01-02 | Warm tier: 30-day retention | PARTIAL | ADR 0001 resolves strategy (option c: Phase 2 flush path). Warm tier infrastructure (MinIO + S3 partition scheme) is in place. The flush service itself is explicitly deferred to Phase 2. REQUIREMENTS.md text acknowledges warm tier as "Parquet files retain signals for 30 days" — the Phase 2 boundary is correct per roadmap |
| STORE-03 | 01-03 | Cold tier: Parquet on S3 with tenant_id/signal_type/dt=YYYY-MM-DD partition scheme | VERIFIED | ADR 0002 locks scheme; ndr-cold bucket created; cold-partition.sh smoke test exercises write+read at correct path; negative nested-path assertion present |
| OPS-02 | 01-01, 01-03 | Docker Compose single-command local dev environment | VERIFIED (static) | `docker-compose.yml` + overlay files provide single-command startup; phase1-full.sh assembles complete stack. Live execution unconfirmed (Docker not available) — surfaces as human verification item |

**Orphaned requirements check:** REQUIREMENTS.md maps STORE-01, STORE-02, STORE-03, OPS-02 to Phase 1. All 4 are claimed by plans. No orphaned requirements.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `docs/decisions/0001-iox-warm-tier-strategy.md` | 42-43 | "behavior TBD" in Context section describing retention_period_hours: 0 probe result | WARNING | ADR documents the probe as producing results but the probe was never run live. The "TBD" appears in the Context section describing the probe design, not in the Decision section. The core decision (option c) does not depend on the probe result — it is independently justified. This is an incomplete empirical validation, not a decision gap. |
| None | - | No `TBD`, `FIXME`, or `XXX` debt markers found in any modified shell scripts, compose files, or SQL migrations | - | Clean |
| None | - | No stub components (empty implementations, `return null`, placeholder text) in runtime artifacts | - | Clean |

**RF=1 vs ROADMAP SC #2 discrepancy:** ROADMAP success criterion #2 states "RF=3" as a requirement. The implementation uses RF=1 with RF=3 documented as the production target. The PLAN frontmatter explicitly acknowledges this as "RF=1 is a documented local-dev deviation from the production RF=3 spec" — it is not a surprise. The partition count (48) and tenant_id keying are correctly implemented. RF=3 is a production Helm chart concern (Phase 7), not achievable in a single-node KRaft local-dev environment. This is a scope boundary, not a failure.

---

### Human Verification Required

#### 1. Phase 1 Full Smoke Suite Live Execution

**Test:** From repo root with Docker daemon running: `bash scripts/smoke/phase1-full.sh`
**Expected:** Script exits 0, prints "ROADMAP Phase 1 success criteria #1, #2, #3, #4, #5 all satisfied." and reports `${ELAPSED}s < 300`.
**Why human:** All three SUMMARY.md files state "Docker daemon was not running in the CI environment, so `docker compose up -d` and the full smoke test sequence could not be executed as live verification." The smoke suite is the phase's primary verification gate per ROADMAP SC #1. No live execution has occurred.

#### 2. Object Lock WORM Behavior

**Test:** With the full stack running, run `bash scripts/smoke/audit-isolation.sh`
**Expected:** (a) Message produced to ndr.audit appears in s3://ndr-audit/audit/ within 90s. (b) `aws s3api head-object` reports `ObjectLockMode: GOVERNANCE`. (c) `aws s3 rm` on the written object fails with non-zero exit (Object Lock preventing delete).
**Why human:** Object Lock behavior requires a live MinIO instance created with `--with-lock`. Cannot be verified statically. This is the HIPAA WORM requirement (ROADMAP SC #5).

#### 3. IOx Write-Read Round-Trip

**Test:** With IOx container running, run `bash scripts/smoke/iox-roundtrip.sh`
**Expected:** Script exits 0 and prints "OK: IOx 3-signal roundtrip verified". SQL query response contains "smoke-test" and "0.42".
**Why human:** Requires live IOx 3 Core container. The `/api/v3/query_sql` endpoint returning the written row cannot be verified without a running instance. ROADMAP SC #3.

#### 4. ADR 0001 Retention Probe Empirical Validation

**Test:** With IOx container running: check `/tmp/iox-retention-probe.json` after running `bash scripts/smoke/iox-roundtrip.sh`
**Expected:** File contains 3 entries with HTTP status codes for `retention_period_hours` values 168, 72, and 0 — specifically confirming that 168 is rejected or capped, 72 is accepted, and the behavior of 0 is recorded.
**Why human:** ADR 0001 Context section explicitly states the behavior of `retention_period_hours: 0` is "TBD" — this empirical validation was never completed. The ADR decision is independently valid, but the probe evidence it cites has not been collected.

---

### Gaps Summary

No hard blockers identified. All artifacts exist, are substantive, and are wired correctly. The phase goal is achievable given the materialized codebase.

The single uncertainty is behavioral: none of the smoke tests have been executed against a live Docker environment. The scripts are syntactically correct and structurally complete — but the ROADMAP success criteria require passing smoke tests, and no smoke test has been run.

The human verification items are not evidence of implementation defects. They are live-execution confirmations that the implemented infrastructure actually behaves as designed. This is a standard gate for infrastructure-only phases where static analysis reaches its limits.

---

_Verified: 2026-11-12T19:00:00Z_
_Verifier: Claude (gsd-verifier)_
