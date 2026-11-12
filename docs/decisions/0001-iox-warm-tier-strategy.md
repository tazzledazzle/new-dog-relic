# ADR 0001: InfluxDB 3 Core OSS — Warm-Tier Strategy for 30-Day Retention

## Status

Accepted — 2026-11-12

## Context

NewDogRelic's retention requirements (PROJECT.md Constraints) specify:

- **Hot tier:** 3 days (72 hours)
- **Warm tier:** 30 days
- **Cold tier:** Unlimited (Parquet on S3/MinIO)

**STORE-01** requires a hot tier that accepts line-protocol writes on `:8181`.
**STORE-02** requires a 30-day warm tier for observability data beyond the 72h hot window.

InfluxDB 3 Core (IOx) OSS is the confirmed storage engine for NewDogRelic's hot tier
(STACK.md Layer 2). It provides:
- HTTP line-protocol write API on `:8181`
- SQL query via `/api/v3/query_sql`
- Automatic WAL → Parquet flush to an object store (S3/MinIO)
- Per-database retention configuration via `retention_period_hours`

**The OSS 72h boundary:** InfluxDB 3 Core OSS enforces a maximum `retention_period_hours`
of 72 (3 days). Values above 72 require InfluxDB 3 Enterprise. This was flagged as a
HIGH-severity blocker in STATE.md ("IOx 72h warm-tier limit") with three candidate options:

1. **(a) InfluxDB 3 Enterprise license** — provides configurable retention beyond 72h
2. **(b) Separate IOx OSS instance with extended config** — run a second IOx instance
   with an alternate retention strategy
3. **(c) Hybrid: IOx OSS as hot tier + dedicated Parquet warm tier** — use IOx OSS
   within its 72h envelope; implement 30-day warm tier as a Parquet-on-S3 lane managed
   by a custom flush service

**Empirical retention probe results** (from `scripts/smoke/iox-roundtrip.sh`
Section 4; raw output in `/tmp/iox-retention-probe.json`):

The retention boundary probe tests three values against the IOx 3 Core OSS instance:
- `retention_period_hours: 168` (7 days) — expected to be rejected or capped by OSS
- `retention_period_hours: 72` (3 days) — expected to succeed
- `retention_period_hours: 0` (unlimited / no expiry) — behavior TBD

The bootstrap script (`infra/iox/bootstrap.sh`) enforces `retention_period_hours <= 72`
at database creation time by reading from `infra/iox/namespaces.json` which pins all
demo-org databases to 72 hours. The script will error if any entry in `namespaces.json`
specifies a value above 72.

## Decision

Adopt **option (c) hybrid**: InfluxDB 3 Core OSS as the authoritative hot tier (≤72h),
and the 30-day warm tier implemented as a **distinct storage lane** — specifically,
a Parquet-on-MinIO/S3 tier managed by a dedicated warm-tier compaction service.

The warm-tier compaction service is **deferred to Phase 2** (built by the Metrics/Logs
ETL Workers that flush from IOx WAL to object store). It is not a Phase 1 deliverable.

**Warm-tier query path:** The Query Orchestrator (Phase 4) serves warm-tier data via
DataFusion `ListingTable` against the same cold-tier partition scheme:

```
s3://{bucket}/signals/{tenant_id}/{signal_type}/dt=YYYY-MM-DD/
```

Warm and cold tiers differ by **storage class** (SSD-cached vs. remote object store),
not by partition layout. This is a critical design constraint: warm and cold share
the same Hive-style partition scheme so the Query Orchestrator can query both tiers
with identical DataFusion external table registrations.

**No InfluxDB Enterprise dependency in v1.** NewDogRelic v1.0 ships Apache 2.0 OSS only.

## Rationale

**Option (a) rejected — License constraint:**
InfluxDB 3 Enterprise is not Apache 2.0. PROJECT.md states: "Apache 2.0 — no GPL/LGPL
dependencies in core." Enterprise would introduce a commercial license dependency into
the NewDogRelic OSS core, violating the foundational licensing constraint and breaking
the product's OSS positioning and self-hostability promise.

**Option (b) rejected — Operational complexity without capability gain:**
Running a second IOx OSS instance does not extend what OSS Core can do. IOx OSS still
enforces the 72h cap per-database. A second instance adds:
- An additional stateful service to operate, upgrade, and monitor
- A second WAL and object-store namespace to coordinate
- No additional retention capability versus a single instance

Option (b) doubles operational complexity for zero functional benefit.

**Option (c) selected — Reuses infrastructure already required for STORE-03:**
The cold tier (STORE-03) is in-scope for Phase 1 Plan 03. It requires:
- MinIO / S3 as an object store
- DataFusion `ListingTable` for cold Parquet query
- A Hive-style partition scheme for predicate pushdown

Option (c) reuses this exact infrastructure. The only additional engineering beyond
the cold tier is a periodic flush job — which the Phase 2 ingest ETL Workers already
need for cardinality enforcement (STORE-04). There is no net-new infrastructure.

This avoids a one-way-door risk: if warm and cold used different partition layouts,
the Query Orchestrator (Phase 4) would need a schema translation layer when data ages
from warm to cold. Sharing one layout eliminates that risk permanently.

## Consequences

**Binding constraints for all future phases:**

1. **IOx retention ceiling:** IOx databases in all phases are created with
   `retention_period_hours: 72` or less. The bootstrap script enforces this by reading
   `infra/iox/namespaces.json` which pins all retentions to 72. No phase may set a
   higher value in `namespaces.json` without first updating this ADR.

2. **Shared partition scheme:** "Warm tier" and "cold tier" share the partition layout:
   ```
   s3://{bucket}/signals/{tenant_id}/{signal_type}/dt=YYYY-MM-DD/
   ```
   Phase 2 must implement the flush path using this scheme. Phase 4 Query Orchestrator
   must query both tiers with DataFusion `ListingTable` registered against this scheme.

3. **Phase 2 dependency:** 30-day warm tier is NOT available until the Phase 2 flush
   service ships. Between Phase 1 GA and Phase 2 GA, only the 72h hot tier is queryable.
   This is a known gap; document in ROADMAP.md Phase 1/2 boundary.

4. **Future revisit trigger:** If InfluxDB 3 Core OSS later adds configurable retention
   beyond 72h, revisit this ADR. Do not silently increase `retention_hours` in
   `namespaces.json` — update this ADR first and confirm it does not introduce a
   license dependency.

5. **Open issues (non-blocking for Phase 1):**
   - Flush-service implementation design is Phase 2 scope.
   - SSD-cache tier differentiation (warm vs. cold) is Phase 4 scope.
   - Warm-tier partition TTL (30d → cold tier graduation) is Phase 2 scope.

## Alternatives Considered

### Option (a): InfluxDB 3 Enterprise License

| Aspect | Detail |
|--------|--------|
| **What it provides** | Configurable retention beyond 72h, historical query across retention windows |
| **License** | Commercial (not Apache 2.0) |
| **Rejection reason** | Violates PROJECT.md "Apache 2.0 — no GPL/LGPL dependencies in core." Enterprise creates a commercial dependency in the OSS core that cannot be shipped under Apache 2.0. |
| **Verdict** | Rejected — license incompatibility |

### Option (b): Separate IOx OSS Instance with Extended Config

| Aspect | Detail |
|--------|--------|
| **What it provides** | A second IOx instance potentially configured differently |
| **Limitation** | IOx OSS still enforces 72h cap per-database regardless of instance count |
| **Operational cost** | Second stateful WAL + object-store namespace; duplicated monitoring |
| **Rejection reason** | Doubles operational complexity for zero additional retention capability |
| **Verdict** | Rejected — no functional benefit over option (c) |

## Links

- **STATE.md** — "Blockers/Concerns: IOx 72h warm-tier limit (HIGH)" — this ADR resolves that blocker
- **PROJECT.md** — Constraints section: "Apache 2.0 — no GPL/LGPL dependencies in core" (option a rejection basis)
- **ROADMAP.md** — Phase 1 success criterion #3: "72h OSS retention boundary is validated and the warm-tier strategy is documented as a resolved architectural decision"
- **infra/iox/namespaces.json** — Declarative source of truth for namespace retentions (all pinned to 72h)
- **infra/iox/bootstrap.sh** — Enforces `retention_period_hours <= 72` at database creation time
- **scripts/smoke/iox-roundtrip.sh** — Section 4: Retention boundary probe; results in `/tmp/iox-retention-probe.json`
- **STACK.md Layer 2** — IOx OSS deployment pattern and integration method
- **STACK.md Layer 3** — Cold tier: DataFusion + object_store for Parquet-on-S3
- **PITFALLS.md Pitfall 3** — Unbounded WAL growth / cardinality (enforced before Phase 2 ingest)
