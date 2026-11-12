# Architecture Patterns: NewDogRelic

**Domain:** Open-source observability SaaS (self-hosted + cloud)
**Researched:** 2026-11-12
**Overall confidence:** HIGH (all 7 focus areas verified against official docs, production case studies, and OTel/IOx spec documentation)

---

## Recommended Architecture

### Top-Level Component Map

```
Instrumented Services
        |
        | OTLP/gRPC + OTLP/HTTP
        v
  ┌─────────────────┐
  │  OTel Collector  │  ← DaemonSet agents (edge tier)
  │  (Gateway Pool)  │    + centralized gateway pool
  └────────┬────────┘
           |
           | OTLP (fan-out per signal)
           v
  ┌─────────────────────────────────────────────┐
  │             Ingest API (Go)                  │
  │  OTLP/gRPC + OTLP/HTTP receiver             │
  │  Auth/rate-limit/tenant-key extraction       │
  │  PII scrubbing (HIPAA)                       │
  └────────────┬────────────────────────────────┘
               |
        ┌──────┴──────┐
        |             |
        | Kafka        | (3 signal-scoped topic families,
        |             |  per-tenant key partitioning)
        |             |
  ┌─────┴──┐  ┌──────┴──┐  ┌──────┴──┐
  │Traces   │  │Metrics  │  │Logs     │
  │Workers  │  │Workers  │  │Workers  │
  │(Go ETL) │  │(Go ETL) │  │(Go ETL) │
  └────┬────┘  └────┬────┘  └────┬────┘
       |             |             |
       └─────────────┼─────────────┘
                     |
              ┌──────┴──────┐
              │  IOx (Rust)  │  ← Hot tier (in-memory + SSD WAL)
              │  Ingester    │    3-day namespace-scoped retention
              └──────┬──────┘
                     |  flush Parquet
              ┌──────┴──────┐
              │  IOx Querier │  ← DataFusion SQL/PromQL
              │  + Compactor │
              └──────┬──────┘
                     |  cold path
              ┌──────┴──────┐
              │  S3/GCS      │  ← Cold tier (Parquet)
              │  Parquet     │    30-day warm + unlimited cold
              └─────────────┘
                     |
  ┌──────────────────┼──────────────────────┐
  │         Query Orchestrator (Go)          │
  │  PromQL API → IOx metrics namespace      │
  │  SQL API (DataFusion) → traces + logs    │
  │  Federated: hot (RecordBatchesExec)      │
  │           + cold (ParquetExec) → UnionExec│
  └──────────────────┬──────────────────────┘
                     |
  ┌──────────────────┼──────────────────────┐
  │             Alert Engine (Go)            │
  │  Rule eval, SLO tracking, state machine  │
  │  Notification: PagerDuty/Slack/Webhook   │
  └──────────────────┬──────────────────────┘
                     |
  ┌──────────────────┼──────────────────────┐
  │         Frontend (React + TS)            │
  │  Dashboards, Trace Explorer, Log Search  │
  │  Service Map, Alert Manager              │
  └─────────────────────────────────────────┘
```

---

## Component Boundaries

| Component | Language | Responsibility | Communicates With |
|-----------|----------|----------------|-------------------|
| OTel Collector Pool | Go (OTel distrib) | Edge buffering, protocol fan-out, PII pre-scrub, trace-affinity load balancing | Ingest API (OTLP/gRPC) |
| Ingest API | Go | OTLP receiver, auth, rate-limit, tenant-key extraction, Kafka produce | Kafka (produce), Auth service |
| Kafka | — | Durable, ordered, signal-scoped buffers; absorbs ingest bursts | Ingest API (producer), ETL Workers (consumer) |
| ETL Workers — Traces | Go | Tail-sampling buffer, span assembly, span enrichment, IOx write | Kafka (consume), IOx Ingester, Span Buffer store |
| ETL Workers — Metrics | Go | Metric normalization, exemplar linking, IOx write | Kafka (consume), IOx Ingester |
| ETL Workers — Logs | Go | Log parsing, field extraction, IOx write | Kafka (consume), IOx Ingester |
| IOx Ingester | Rust (IOx embed) | WAL, in-memory Arrow buffer, Parquet flush to object store | IOx Catalog (Postgres), Object Store |
| IOx Compactor | Rust (IOx embed) | Small-file merging, deduplication, retention enforcement | IOx Catalog, Object Store |
| IOx Querier | Rust (IOx embed) | DataFusion plan execution, UnionExec over hot+cold | IOx Ingester (hot path RPC), Object Store, IOx Catalog |
| Object Store (S3/GCS) | — | Cold Parquet persistence; unlimited retention | IOx Ingester (write), IOx Querier (read) |
| IOx Catalog | Postgres | Namespace/table/column/file metadata; partition routing | IOx Ingester, Compactor, Querier |
| Query Orchestrator | Go | PromQL → IOx metrics, SQL (DataFusion) → traces+logs, query fan-out, result merge | IOx Querier, Auth/RBAC |
| Service Map Processor | Go | Derives service dependency graph from client/server span pairs; writes graph store | IOx Querier (trace reads), Graph DB (Redis or Postgres) |
| Alert Engine | Go | PromQL/SQL rule evaluation, SLO tracking, state machine, notification dispatch | Query Orchestrator, Notification channels |
| Auth/RBAC Service | Go | API key validation, org→project→resource RBAC, audit logging | Ingest API, Query Orchestrator, Frontend API |
| Frontend API (BFF) | Go | REST+GraphQL gateway, session management, dashboard CRUD | Query Orchestrator, Alert Engine, Auth service |
| Frontend | React/TypeScript | Dashboards, trace explorer, log search, service map, alert manager | Frontend API (HTTP/WS) |

---

## Focus Area Findings

### 1. Kafka Multi-Tenancy: Per-Tenant Topics vs. Shared Topics with Tenant-Key Partitioning

**Recommendation: Shared signal topics with tenant-key partitioning, not per-tenant topics.**

Production evidence from Datadog (hundreds of Kafka clusters, millions of partitions, terabytes/second), Grafana Tempo (single `tempo-traces` topic, partition ring), and SigNoz (separate signal topics, shared per signal) all converge on the same pattern: topics are scoped by **signal type**, not by **tenant**.

**Why not per-tenant topics:**
- KRaft-mode Kafka supports 10K–20K partitions/broker in practice. At 1,000 tenants × 3 signals × 6 partitions = 18,000 partitions per broker — you hit the ceiling at moderate tenant counts.
- Per-tenant topics create operational sprawl: topic creation/deletion lifecycle is complex, quota management is per-topic instead of per-principal, and consumer group rebalancing becomes expensive.
- Key-to-partition routing breaks if you resize a live topic. Per-tenant topics must be pre-sized.

**What production systems actually do:**
- One topic family per signal: `ndr.traces.raw`, `ndr.metrics.raw`, `ndr.logs.raw` (plus `*.normalized` and `*.dlq` variants).
- Partitioning key: `trace_id` for traces (affinity for tail sampling), `service.name` or tenant+service hash for metrics/logs.
- Tenant isolation via: Kafka ACLs + per-principal quotas + tenant ID propagated as a Kafka message header (not as the partition key).
- Tenant-level observability: JMX + header-tagged consumer group lag, per-topic `BytesInPerSec` summed by header filter.

**Start configuration:**
- 48 partitions per signal topic at launch (scales to 10M msg/s without resize).
- Replication factor 3; min ISR 2.
- Retention: 3 days (matches hot-tier TTL, enables replay on ETL failure).
- KRaft mode; no ZooKeeper dependency.

**Confidence:** HIGH — consistent with Datadog, Grafana Tempo, and SigNoz production architectures.

---

### 2. InfluxDB IOx Namespace/Multi-Tenancy Model

**How IOx handles multi-tenancy: namespaces as the logical tenant boundary.**

IOx maps each `(organization, database)` pair to a **namespace**. The Catalog (Postgres-backed) tracks namespaces, tables (one per measurement/signal type), columns, and Parquet file locations. The Querier, Ingester, and Compactor coordinate exclusively through the Catalog and Object Storage — no direct inter-service RPC except the Querier calling the Ingester for not-yet-persisted hot data.

**Namespace model for NewDogRelic:**
- Each customer org gets one or more IOx namespaces: `{org_id}.traces`, `{org_id}.metrics`, `{org_id}.logs`.
- Namespace isolation is logical within a cluster. For HIPAA-tier customers or dedicated cluster deployments, provision a physically separate IOx cluster (InfluxData's own guidance: "multiple dedicated clusters to avoid noisy neighbor issues").
- Token-scoped authorization at the IOx API layer enforces namespace access control.

**Noisy neighbor risk:** IOx does not enforce per-namespace CPU or I/O quotas within a single cluster. The recommended mitigation is **cluster-level tenant tiering**: shared cluster for standard tenants, dedicated clusters for enterprise/HIPAA tenants. This aligns with the OSS + Cloud monetization model.

**Compaction:** The Compactor runs as a background service, consuming the Catalog to find files needing consolidation. It merges small Parquet files into fewer, larger, non-overlapping files per namespace/table/partition. It is independently scalable — add Compactor replicas when ingestion rate spikes drive file fragmentation. InfluxDB 3 Enterprise includes distributed compaction (beta). For v1, a single Compactor with configurable worker concurrency is sufficient.

**Retention enforcement:** The Compactor also handles garbage collection — it deletes Parquet files for data older than the namespace's retention policy.

**Confidence:** HIGH — sourced from official InfluxData blog (IOx 3.0 System Architecture) and InfluxDB 3 Docs.

---

### 3. Tail-Based Sampling Architecture

**The fundamental constraint: every span of a trace must arrive at the same sampler instance.**

This drives all architectural decisions for tail sampling at scale.

**Standard approach (5M spans/s target):**

Use a **two-tier Collector architecture**:
- Tier 1 — Edge OTel Collector (DaemonSet): receives OTLP from application SDKs, applies cheap head-based sampling (drop trivially uninteresting traces), batches, and publishes to Kafka using `trace_id` as the partition key (trace affinity).
- Tier 2 — Tail Sampling ETL Workers: consume from `ndr.traces.raw` Kafka topic, keyed by `trace_id` so each trace always routes to the same worker instance. Workers maintain an in-memory span buffer per trace. After `decision_wait`, apply policies (error status, P99 latency, attribute match), then write kept traces to IOx.

**Buffer sizing at target scale:**
- 5M spans/s, average 8 spans/trace = 625K traces/s arriving at the tail sampler.
- With `decision_wait = 10s` and 95th-percentile trace completeness: buffer holds ~6.25M open traces.
- At ~2KB per span, 8 spans/trace: ~100 GB RAM required for pure in-memory buffering.
- **Mitigation:** Use disk-backed span buffer (Pebble / RocksDB) for the overflow, keeping hot (open) traces in memory and spilling completed-but-undecided traces to SSD. Elastic's upstream OTel Collector contribution (Pebble tail storage) achieves 65% memory reduction.

**OTel Collector's `tailsamplingprocessor` limits at this scale:**
- `num_traces` default is 50,000 — far too low. Set to 5,000,000+.
- `decision_wait` = 10–30s depending on P95 trace duration. Shorter = less memory but misses slow spans.
- `num_shards` = 256 (max) for parallelism.
- Monitor `sampling_trace_dropped_too_early` metric; this is the canary for under-provisioned buffers.
- The `tail_storage` extension (disk-backed) is production-usable as of recent releases but carries a "may have breaking changes" caveat.

**Recommended buffer implementation for NewDogRelic:** Build the tail-sampling ETL Worker in Go with an embedded Pebble store (not the OTel Collector's processor), giving full control over eviction policy, TTL, and spillover. The OTel Collector's tail sampler is excellent for <1M spans/s but becomes operationally difficult at 5M+ spans/s without the disk-backed extension.

**Confidence:** HIGH — sourced from OTel Collector contrib README, Elastic engineering blog (measured benchmarks), and production architecture guides.

---

### 4. Query Federation: Hot (IOx) + Cold (S3 Parquet)

**IOx handles this natively — no custom federation layer needed.**

The IOx Querier builds a DataFusion physical plan that **automatically unions** data from two sources:
- `RecordBatchesExec`: in-memory Arrow batches from the Ingester (hot, unsorted, most recent data, not yet persisted).
- `ParquetExec`: Parquet file scans from Object Store via Catalog (cold, sorted, persisted data).
- `UnionExec`: DataFusion UNION ALL merges both streams.
- `DeduplicateExec`: sits above the union; handles rows present in both streams (write in progress during flush), requires sorted input.

**The deduplication complexity is a real query plan challenge in IOx.** When unioning sorted (Parquet) and unsorted (Ingester) data, DataFusion cannot use `SortPreservingRepartitionExec` and may fall back to full re-sorts. This is an active optimization area in the IOx codebase. For NewDogRelic, it means: do not expect sub-10ms queries during active flush windows; the IOx team's own guidance is to co-locate Queriers with Ingesters to minimize RPC latency for the hot path.

**What this means for the product:**
- Do not build a separate "hot query service" and "cold query service." Let IOx Querier handle both and expose a single query endpoint.
- The Query Orchestrator (Go) translates PromQL → IOx SQL for metrics, routes SQL queries to IOx Querier for traces+logs, and handles result pagination and streaming.
- For queries spanning beyond IOx's cold Parquet reach (i.e., data already migrated to S3 beyond IOx's managed lifecycle), the Query Orchestrator can direct-query S3 Parquet via a DataFusion standalone instance or Trino — but this is a v2 concern.

**Confidence:** HIGH — sourced from official InfluxDB IOx query plan documentation and DataFusion SIGMOD 2024 paper.

---

### 5. Service Map Construction

**Use the OTel Collector Service Graph Connector + a downstream graph store.**

The OTel ecosystem provides the `servicegraph` connector (OTel Collector contrib) that:
- Correlates `CLIENT` and `SERVER` span pairs within a trace.
- Extracts directed edges: `(caller_service, callee_service, protocol, error_rate, latency_p99)`.
- Emits these as Prometheus-compatible metrics.

**Data flow for service map:**
1. Tail Sampling Workers emit kept traces to IOx.
2. A Service Map Processor (separate Go service, or Collector pipeline) also consumes the same traces from Kafka (`ndr.traces.raw`), runs the span-pair correlation, and writes edges to a graph store (Postgres `service_edges` table with upsert-on-conflict for idempotency, or Redis for real-time).
3. The Service Map API reads from the graph store and serves the frontend's D3-rendered map.

**Key span attributes used:**
- `service.name` (resource attribute) — node identity.
- `span.kind = CLIENT | SERVER` — determines edge direction.
- `parent_span_id` — links client-to-server across service boundaries.
- `http.route`, `db.system`, `messaging.system` — edge label (call type).

**Avoid:** Processing the full trace corpus synchronously on query. Precompute edges from the Kafka stream; the UI query hits a prebuilt graph table, not raw spans.

**Confidence:** HIGH — sourced from OTel Collector contrib servicegraph connector docs and multiple production observability platform guides.

---

### 6. OTel Collector Tier vs. Direct OTLP Ingest

**Use a two-tier OTel Collector architecture. Do not expose the Ingest API as a direct OTLP endpoint to instrumented services.**

**Recommendation:** OTel Collector Gateway Pool sits between instrumented services and the NewDogRelic Ingest API.

**Rationale:**
- **Decoupling:** Services speak OTLP to a local Collector endpoint. The backend can change sampling rates, PII redaction rules, signal routing, and credentials without touching application deployments.
- **Tail sampling affinity:** The Collector tier applies trace-affinity load balancing before Kafka, ensuring spans of the same trace route to the same partition. This is architecturally required for tail sampling.
- **Credential management:** Only the Collector gateway holds NewDogRelic API keys. Edge DaemonSet agents have no customer-facing secrets.
- **Buffering:** Persistent queues (WAL) on the gateway protect against Ingest API outages without data loss.
- **Head-based pre-filtering:** The gateway Collector can drop high-cardinality, low-value traces before they enter the Kafka pipeline, reducing storage and processing costs.
- **Multi-destination fan-out:** Enterprises can route to NewDogRelic + a secondary destination without application changes.

**Deployment model:**
- Kubernetes DaemonSet: one OTel Collector agent per node, receives OTLP from local pods.
- Gateway pool: 3–10 Collector instances (depending on scale), do batching, trace-affinity load balancing (by `trace_id`), PII pre-scrubbing, and OTLP export to Ingest API.
- The Ingest API accepts OTLP/gRPC + OTLP/HTTP as first-class protocols, but it is not intended to be the endpoint that instrumented services call directly (except for serverless/lambda scenarios where DaemonSet agents cannot run).

**Confidence:** HIGH — sourced from Elastic OTel reference architecture guide, Datadog OTel deployment documentation, and OTel official K8s blueprint.

---

### 7. Schema Evolution

**Use ingestion-time attribute transformation, not storage-layer schema migration.**

Observability schema evolution is driven by OpenTelemetry Semantic Convention upgrades (e.g., `method` → `http.request.method`, `environment` → `deployment.environment.name`). These renames break existing dashboards, alerts, and PromQL queries if not handled.

**Production pattern (Dash0, OpenSearch, Honeycomb):** Transform at ingestion time in the Collector pipeline or ETL Worker, not at query time and not via storage migrations.

**NewDogRelic recommended approach:**

1. **Collector Transform Processor:** Use OTel Collector's `transform` processor to normalize incoming spans/metrics/logs to the current semantic convention version. Old attribute names are rewritten before they enter Kafka. Example: rename `http.method` to `http.request.method` on ingest.

2. **Copy Mode During Migration Windows:** When a semantic convention rename is in progress, the ETL Worker writes **both** the old and new attribute names into IOx for a configurable migration window (e.g., 30 days). This keeps dashboards referencing the old name functional while teams migrate queries.

3. **IOx/Parquet Schema Evolution:** Parquet supports column addition without file rewrite. New attributes appear as new columns in IOx tables. Old files treat the new column as null for those rows — DataFusion handles this transparently in `ParquetExec` via schema merging. Column type changes require new column names (treat as a breaking rename, not in-place).

4. **Schema Registry (v2):** A centralized schema registry (OTel Weaver-compatible) validates incoming telemetry against expected schemas and surfaces drift in the UI. This is a differentiating feature but not required for v1 — defer to after the query layer is stable.

**Anti-pattern to avoid:** Relying on Parquet schema evolution to absorb renames silently. Consumers (alerts, dashboards) will silently produce wrong results if old attribute names return null instead of values.

**Confidence:** MEDIUM — sources agree on the approach; specific copy-mode implementation is a local pattern derived from Honeycomb's migration guidance, not a universal spec.

---

## Data Flow Summary

### Write Path (per signal)

```
SDK → OTel Collector Agent (DaemonSet)
    → OTel Collector Gateway (trace-affinity LB, PII scrub, batch)
    → Ingest API (Go) [auth, rate-limit, tenant-key extraction]
    → Kafka [signal-scoped topic, tenant_id as header, trace_id as partition key for traces]
    → ETL Worker [Go: normalize, schema-transform, enrich]
        → (Traces only) Span Buffer [in-memory + Pebble disk]
            → Tail Sampling Decision [after decision_wait]
    → IOx Ingester [Rust: WAL + Arrow in-memory]
    → Parquet flush → Object Store (S3/GCS)
    → IOx Compactor [background: merge, dedup, GC]
```

### Read Path

```
Frontend / API Client
    → Frontend API (Go BFF)
    → Query Orchestrator (Go)
        → PromQL API → IOx Querier [metrics namespace]
        → SQL API → IOx Querier [traces + logs namespaces]
            → DataFusion UnionExec [hot: RecordBatchesExec + cold: ParquetExec]
            → DeduplicateExec → result stream
        → Service Map API → graph store (Postgres/Redis)
    → Alert Engine (Go) [separate read path, runs PromQL/SQL rules on schedule]
```

### Service Map Derivation

```
Kafka (ndr.traces.raw)
    → Service Map Processor (Go)
        → servicegraph connector (CLIENT+SERVER span-pair correlation)
        → service_edges upsert → Postgres / Redis
    → Service Map API → Frontend
```

---

## Build Order (Dependency-Driven)

The dependency graph mandates this order. Each layer is a prerequisite for the next.

### Layer 1: Infrastructure Substrate
**What:** Kafka cluster (KRaft), IOx cluster (Ingester + Compactor + Querier + Catalog), Object Store, Postgres (Catalog + app DB), Auth Service skeleton.

**Why first:** Everything else depends on these. Kafka and IOx must be running before any data flows. Establish topic layout and IOx namespace conventions at this stage — these are expensive to change later.

**Deliverables:** Working Kafka (3 signal topics, 48 partitions each, RF=3), IOx cluster with per-org namespaces, Postgres with Catalog schema, local Dev environment (Docker Compose).

---

### Layer 2: Ingest Pipeline (Write Path)
**What:** Ingest API (Go, OTLP/gRPC + OTLP/HTTP), Kafka producers (per-signal topics), ETL Workers for metrics and logs (traces ETL is separate below), IOx write path.

**Why second:** Proves end-to-end data flow from OTLP → IOx before any query complexity is introduced. Build metrics and logs ETL first (simpler: no span assembly, no sampling buffer).

**Deliverables:** Metrics arriving in IOx `{org}.metrics` namespace. Logs in `{org}.logs` namespace. Kafka consumer lag observable. DLQ topics wired.

---

### Layer 3: Traces ETL + Tail Sampling
**What:** Trace ETL Worker (Go) with Pebble-backed span buffer, tail sampling decision engine (error policy, latency policy, rate-limit policy), trace assembly and IOx write.

**Why third:** Requires Kafka (Layer 1) and IOx write path (Layer 2) proven. The span buffer adds stateful complexity — build after the simpler stateless ETL workers are running and debugged.

**Deliverables:** Traces in IOx `{org}.traces` namespace. Tail sampling policies configurable per org. `sampling_trace_dropped_too_early` metric exported to Prometheus.

---

### Layer 4: Query Layer
**What:** IOx Querier integration, Query Orchestrator (Go) with PromQL → IOx SQL translation, SQL query API for traces+logs, hot+cold UnionExec validated, result streaming to callers.

**Why fourth:** Requires IOx with actual data (Layers 2+3). The DataFusion UnionExec behavior (sorted Parquet + unsorted Ingester) must be tested under real workload before exposing to the UI.

**Deliverables:** Working PromQL API returning metrics. Working SQL API returning traces and logs. Query P95 benchmarked (target: <1s hot, <10s cold).

---

### Layer 5: OTel Collector Tier + Multi-Tenant Auth
**What:** OTel Collector DaemonSet + Gateway configuration (trace-affinity LB, PII scrub, transform processor for semantic convention normalization), Auth/RBAC Service (org → project → resource, API key management, audit logging).

**Why fifth:** The Collector tier and Auth layer refine the ingest pipeline. These can be built in parallel with Layer 4 but must be complete before any customer-facing deployment. HIPAA audit logging is built here.

**Deliverables:** Collector-based PII scrubbing validated. RBAC enforced at Ingest API and Query Orchestrator. Audit log stream to IOx (append-only namespace). API key rotation working.

---

### Layer 6: Service Map + Derived Signals
**What:** Service Map Processor (Go, consuming `ndr.traces.raw`), graph store (Postgres `service_edges`), Service Map API, Span Metrics derivation (RED metrics from traces, written back to `{org}.metrics`).

**Why sixth:** Requires complete traces in IOx (Layer 3) and Query Orchestrator (Layer 4). Service map is a read-side projection — it does not block core write or query paths.

**Deliverables:** Service dependency graph queryable. RED metrics (rate, error, duration) per service-to-service edge derivable from traces.

---

### Layer 7: Alert Engine
**What:** Alert rule evaluation (PromQL + SQL), SLO tracking, state machine (OK/WARN/CRIT with flap detection), notification dispatch (PagerDuty, Slack, Webhook, Email).

**Why seventh:** Requires stable Query Orchestrator (Layer 4). Alerts run queries on a schedule — they are consumers of the query layer, not producers into storage.

**Deliverables:** Alert rules evaluating on configurable intervals. SLO burn rate alerts. Notification channels integrated and tested. Alert history queryable.

---

### Layer 8: Product UI
**What:** React/TypeScript frontend — dashboards, trace explorer, log search, service map visualization (D3), alert manager.

**Why eighth:** Frontend is the composition layer. Each UI feature depends on a backend API from prior layers. Build feature-by-feature as backend APIs are ready.

**Deliverables:** Metrics dashboards (Layer 4 required). Trace explorer (Layer 3+4). Log search (Layer 2+4). Service map (Layer 6). Alert manager (Layer 7).

---

### Layer 9: Kubernetes Hardening + Cloud Deployment
**What:** Production Helm chart, Kubernetes Operator (enterprise), autoscaling (HPA on Kafka consumer lag, IOx Querier on queue depth), multi-region, NewDogRelic Cloud onboarding.

**Why last:** Hardening requires a working, tested system. Kubernetes Operator complexity warrants deferral until the core platform is stable.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Per-Tenant Kafka Topics
**What:** Creating one Kafka topic (or topic set) per customer org.
**Why bad:** At 1,000 tenants × 3 signals × 6+ partitions, you approach KRaft broker partition limits. Topic lifecycle (create/delete at tenant onboarding/offboarding) is operationally complex. Consumer group rebalancing time grows with partition count.
**Instead:** Signal-scoped topics with tenant ID as a Kafka message header; isolate by per-principal quotas.

### Anti-Pattern 2: Building a Custom Query Federation Layer Before Using IOx's Native UnionExec
**What:** Writing custom code to query IOx for hot data and S3 directly for cold data, then merging results in Go.
**Why bad:** IOx's DataFusion Querier already handles hot+cold union, deduplication, and schema merging. Custom federation duplicates this, introduces consistency gaps during flush windows, and requires maintaining a parallel query plan engine.
**Instead:** Route all queries through the IOx Querier. Only add direct S3 DataFusion queries for data beyond IOx's managed lifecycle (v2+).

### Anti-Pattern 3: Storing Tail-Sampling Buffer in Kafka (Consumer Offset as State)
**What:** Using Kafka consumer replay to reconstruct trace state rather than a dedicated span buffer.
**Why bad:** Kafka is not a random-access store. Assembling a complete trace requires scanning across many partition offsets; at 5M spans/s this is prohibitively expensive.
**Instead:** Pebble/RocksDB embedded in the ETL Worker, keyed by `trace_id`. Kafka is the durable inbound queue only.

### Anti-Pattern 4: Skipping the OTel Collector Tier for Direct OTLP
**What:** Having instrumented services POST OTLP directly to the NewDogRelic Ingest API.
**Why bad:** Credentials in every service binary. No centralized PII scrubbing. No trace-affinity routing. No head-based pre-filtering. Backpressure from Ingest API propagates into application latency.
**Instead:** OTel Collector DaemonSet + Gateway pool as the mandatory ingestion tier. Ingest API accepts OTLP from Collectors only (verify by API key type).

### Anti-Pattern 5: Applying Semantic Convention Renames at Query Time
**What:** Storing old and new attribute names as-is and translating at query execution.
**Why bad:** Every query must carry a translation layer. Dashboards and alerts break when the translator is not updated. Query performance degrades from double-column scans.
**Instead:** Transform at ingestion (OTel Collector transform processor). Store normalized attribute names in IOx. Use copy-mode (write both names) during migration windows only.

### Anti-Pattern 6: IOx Noisy Neighbor in Shared Cluster for All Tiers
**What:** Running all tenants — standard, enterprise, and HIPAA — in the same IOx cluster.
**Why bad:** IOx has no per-namespace CPU or I/O quotas within a cluster. A burst from one large tenant degrades queries for all others. HIPAA isolation requires physical separation.
**Instead:** Tiered cluster model: shared IOx cluster for standard tenants; dedicated clusters for enterprise/HIPAA. This is also the cloud monetization hook.

---

## Scalability Considerations

| Concern | Standard Launch (10–100 tenants) | Growth (1K tenants) | Design Target (10K+ tenants) |
|---------|----------------------------------|---------------------|-------------------------------|
| Kafka throughput | 3 signal topics, 48 partitions each, 3-node cluster | Add brokers, increase partitions (new topics, not resize) | Multiple Kafka clusters per region; AutoMQ/Confluent tiered storage |
| IOx ingest | Single ingester pool | Horizontal ingester scaling (stateless WAL-per-instance) | Multiple IOx clusters by tenant tier |
| Tail sampling buffer | In-memory + Pebble (single ETL worker pool) | Scale ETL worker replicas; trace-affinity via Kafka partition key guarantees co-location | Dedicated sampling cluster; Pebble sharding |
| Query concurrency | IOx Querier pool (3–5 instances) | Increase Querier pool; add read-only replicas via Object Store | Query result cache (Redis); query queue depth autoscaling |
| Compaction | Single Compactor instance | Add Compactor replicas for high-ingest namespaces | Distributed compaction (IOx Enterprise feature) |
| Multi-region | Single region | Active-active ingest, single query region | Multi-region IOx with cross-region Parquet replication to S3 |

---

## Sources

- InfluxDB 3.0 System Architecture (official): https://www.influxdata.com/blog/influxdb-3-0-system-architecture/
- How InfluxDB IOx Manages the Data Lifecycle: https://www.influxdata.com/blog/how-influxdb-iox-manages-the-data-lifecycle-of-time-series-data/
- InfluxDB IOx Query Plans (official docs): https://docs.influxdata.com/influxdb3/clustered/reference/internals/query-plan/
- How to Read InfluxDB 3 Query Plans: https://www.influxdata.com/blog/how-read-influxdb-3-query-plans/
- OTel Collector Tail Sampling Processor README: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md
- Elastic: OTel tail sampling 65% less memory with disk storage: https://www.elastic.co/observability-labs/blog/tail-sampling-memory-opentelemetry
- Elastic: Composing OTel Reference Architectures: https://www.elastic.co/observability-labs/blog/opentelemetry-collector-reference-architectures
- Grafana Tempo Architecture (Kafka integration): https://grafana.com/docs/tempo/latest/reference-tempo-architecture/about-tempo-architecture/
- Grafana Tempo Kafka component: https://grafana.com/docs/tempo/latest/reference-tempo-architecture/components/kafka/
- OTel Collector Service Graph Connector: https://oneuptime.com/blog/post/2026-02-06-service-graph-connector-opentelemetry-collector/view
- Service Maps from OTel Trace Data: https://oneuptime.com/blog/post/2026-02-06-service-maps-opentelemetry-traces/view
- Datadog Kafka production architecture: https://factorhouse.io/articles/datadog-kafka-architecture/
- AutoMQ: Observability Pipelines on Kafka (Logs, Metrics, Traces): https://www.automq.com/blog/observability-pipelines-on-kafka-logs-metrics-traces
- SigNoz production-grade OTel pipeline: https://medium.com/@ShiveeGupta/building-a-production-grade-observability-platform-with-signoz-clickhouse-and-opentelemetry-d7f09a5250f5
- Conduktor: Multi-tenancy in Kafka: https://www.conduktor.io/blog/how-to-do-multi-tenancy-in-kafka
- Confluent: Choosing partitions per topic: https://www.confluent.io/blog/how-choose-number-topics-partitions-kafka-cluster/
- Honeycomb: Managing OTel Semantic Convention Migrations: https://www.honeycomb.io/blog/managing-opentelemetry-semantic-convention-migrations-collector
- OTel Weaver (official blog): https://opentelemetry.io/blog/2025/otel-weaver/
- Dash0 Semantic Convention Upgrades: https://dash0.com/documentation/dash0/semantic-conventions/opentelemetry-semantic-convention-upgrades
- DataFusion SIGMOD 2024 paper: https://andrew.nerdnetworks.org/pdf/SIGMOD-2024-lamb.pdf
- OTel Managed Telemetry Platforms (K8s blueprint): https://opentelemetry.io/docs/guidance/blueprints/managed-telemetry-platforms-for-k8s-workloads/
- Datadog: OTel deployment options: https://www.datadoghq.com/blog/otel-deployments/
