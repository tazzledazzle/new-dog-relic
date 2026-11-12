# ADR 0002: Cold-Tier S3 Partition Scheme

**Status:** Accepted — 2026-11-12

**Authors:** Phase 1 infrastructure substrate

---

## Context

STORE-03 requires Parquet files on object store with a partition scheme for unlimited cold-tier
retention. The partition layout is a one-way-door decision: once writes begin, changing the scheme
requires rewriting all historical data at potentially petabyte scale.

PITFALLS.md documents two anti-patterns that have caused production incidents in similar systems:

**Pitfall 7 — Nested date partitioning:** The pattern `year/month/day/hour/` creates a
multi-level directory tree where filtering by date requires recursing through all year directories
first. When a query filters `WHERE dt BETWEEN ...` with no year constraint, this forces
O(N) S3 LIST calls across the year hierarchy — benchmarks show 200x cost increase vs. single-column
partitioning. DataFusion's `ListingTable` can only prune partitions it can statically evaluate at
the directory level; nested date partitions require all four levels to match before pruning applies.

**Pitfall 5 — HIPAA audit stream Object Lock:** Audit events must land in a separate S3 bucket
with Object Lock enabled. If audit events were mixed into the cold-tier cold bucket, a governance
failure (Object Lock disabled) could affect observability data. This ADR therefore governs the
`ndr-cold` bucket; `ndr-audit` is governed separately by the HIPAA audit stream architecture.

Additionally, STACK.md Layer 3 shows a `{year}/{month}/{day}/{hour}/` example for cold-tier
partitioning. This ADR explicitly supersedes that example for NewDogRelic. The single-column
`dt=YYYY-MM-DD` Hive-style scheme is the authoritative layout.

---

## Decision

The cold-tier S3 key layout for NewDogRelic is permanently:

```
s3://{bucket}/tenant_id={tenant}/signal_type={metrics|logs|traces}/dt=YYYY-MM-DD/{file}.parquet
```

Where:
- `{bucket}` is `ndr-cold` for observability data, `ndr-audit` for HIPAA audit events
- `{tenant}` is the tenant identifier (e.g., `t-alpha`, `demo-org`)
- `signal_type` is one of `metrics`, `logs`, or `traces`
- `dt` is the ISO 8601 date of the data (not the write date — the event timestamp date)
- `{file}` is a UUID or timestamp-prefixed filename to avoid collisions within a partition

**Example:**
```
s3://ndr-cold/tenant_id=demo-org/signal_type=metrics/dt=2026-11-12/550e8400-metrics.parquet
```

This is Hive-style partitioning with tenant-first column ordering and a single-column date
partition (not nested year/month/day).

---

## Rationale

**Tenant-first ordering:** Placing `tenant_id` first ensures a single-tenant query never
causes S3 LIST operations in another tenant's prefix. This is the foundation for the per-tenant
prefix IAM policies added in Phase 4 (AUTH-02). Without tenant-first ordering, those IAM policies
would require wildcard prefixes that expose cross-tenant visibility.

**Single-column `dt=YYYY-MM-DD`:** DataFusion's `ListingTable` applies partition pruning at the
directory level. A `WHERE dt BETWEEN '2026-11-01' AND '2026-11-12'` predicate on a single-column
`dt` partition evaluates in O(days) directory lookups. The same query on a nested
`year=2026/month=11/day=01...12/` layout requires iterating through the year directory to find
month directories to find day directories — O(years × months × days) lookups — before any file
metadata is read.

**No hour-level partitioning:** Sub-day granularity via `/hr=HH/` multiplies the small-file
count by 24x without providing partition-level pruning that DataFusion cannot achieve from
Parquet footer min/max statistics on the `ts` column (`datafusion.execution.parquet.pruning = true`
enables row-group pruning from the Parquet file footer — this is equivalent to hour-level
directory pruning without the directory overhead).

**Consistency with warm tier:** ADR 0001 established that the warm tier uses the same S3 layout.
Sharing the scheme means the Phase 2 flush service and cold archiver can use identical path
construction logic, and the Phase 4 query orchestrator fans out over the same partition structure
at both tiers.

---

## Consequences

**Binding constraints on all future phases:**

1. All writers (IOx WAL flush path, warm-tier compactor, cold archiver) MUST emit files under
   the template `tenant_id={tenant}/signal_type={type}/dt=YYYY-MM-DD/{file}.parquet`. Deviation
   from this template is a breaking change requiring an ADR amendment.

2. Any future need for hour-level query granularity MUST be solved via Parquet footer min/max
   statistics on the `ts` column — NOT by adding a `/hr=HH/` partition level. Enabling
   `datafusion.execution.parquet.pruning = true` (the DataFusion default) already handles this.

3. The `tenant_id` column is partition column 1 in every file. Phase 4 IAM policies scope access
   by the `tenant_id=...` key prefix. Any change to column ordering invalidates those policies.

4. The smoke test `scripts/smoke/cold-partition.sh` includes a negative assertion that the path
   `year=2026/month=11/day=12/` does not exist in the cold bucket. This test is a regression
   guard: if any writer introduces nested date partitioning, this test will fail.

5. `ndr-iox` bucket (used by IOx 3 Core) is managed by IOx internally. IOx may use its own
   internal layout within that bucket. The partition scheme in this ADR applies ONLY to data
   written directly by NewDogRelic services (flush service, archiver) into `ndr-cold` and `ndr-audit`.

---

## Alternatives Considered

### Nested `year/month/day/hour` (Rejected)

```
s3://{bucket}/{tenant_id}/{signal_type}/{year}/{month}/{day}/{hour}/{file}.parquet
```

Rejected because:
- O(N) S3 LIST calls for date-range queries (PITFALLS.md Pitfall 7, 200x cost benchmark)
- DataFusion cannot prune at the first column (`tenant_id`) when the date is four levels deep
- Requires changing all four directory components to shift query boundaries
- Already documented in STACK.md as the wrong pattern for this use case

### Flat `dt=YYYY-MM-DDTHH` hour-level (Rejected)

```
s3://{bucket}/tenant_id={tenant}/signal_type={type}/dt=YYYY-MM-DDTHH/{file}.parquet
```

Rejected because:
- 24x more partitions per day, 24x more S3 LIST operations for day-level queries
- Hour-level pruning is achievable via Parquet statistics (no partition advantage)
- Complicates retention policy enforcement (must list 24 prefixes per day to delete old data)

### signal_type-first ordering (Rejected)

```
s3://{bucket}/signal_type={type}/tenant_id={tenant}/dt=YYYY-MM-DD/{file}.parquet
```

Rejected because:
- Phase 4 IAM policies cannot scope to a single tenant's data without wildcard `signal_type=*` prefix
- Cross-signal queries (e.g., "all data for tenant X") require scatter/gather across three signal prefixes

---

## Links

- PITFALLS.md Pitfall 7 (Nested date partitioning anti-pattern)
- PITFALLS.md Pitfall 5 (HIPAA audit Object Lock)
- ARCHITECTURE.md component boundaries (cold tier section)
- STACK.md Layer 3 (DataFusion + object_store crate)
- ADR 0001 (IOx warm-tier strategy; establishes shared partition layout)
- ROADMAP Phase 1 success criterion #4 (cold partition scheme active)
- `infra/minio/buckets.json` (bucket spec with Object Lock settings)
- `scripts/smoke/cold-partition.sh` (live verification + negative regression test)
