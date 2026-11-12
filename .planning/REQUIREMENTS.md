# Requirements — NewDogRelic

## v1 Requirements

### INGEST — OTel Ingest Pipeline

- [ ] **INGEST-01**: User can send spans, metrics, and logs to NewDogRelic via OTLP/gRPC
- [ ] **INGEST-02**: User can send signals via OTLP/HTTP (protobuf + JSON encodings)
- [ ] **INGEST-03**: Operator can deploy OTel Collector as a DaemonSet agent (node-level collection) + centralized gateway pool (trace-affinity routing for tail sampling)
- [ ] **INGEST-04**: Ingest pipeline strips or hashes PII attributes via OTel Collector attribute allowlist processor before data is written to storage (HIPAA)
- [ ] **INGEST-05**: Ingest API applies backpressure and circuit-breaking when Kafka consumer lag exceeds threshold (prevents cascade failure at ingest spikes)

### STORAGE — Tiered Data Store

- [ ] **STORE-01**: Hot tier: InfluxDB 3 Core (IOx) stores all signals for the most recent 3 days in a columnar, queryable format
- [ ] **STORE-02**: Warm tier: compacted IOx segments or Parquet files retain signals for 30 days on attached/local SSD
- [ ] **STORE-03**: Cold tier: Parquet files flushed to object store (S3/GCS) with `tenant_id/signal_type/dt=YYYY-MM-DD` partition scheme for unlimited retention
- [ ] **STORE-04**: Ingest write path enforces a per-tenant series cardinality cap; requests exceeding the cap are rejected with a 429 and tenant-specific error (prevents compaction storms)

### TRACES — Distributed Tracing

- [ ] **TRACE-01**: Tail-based sampler buffers spans in a Pebble-backed disk store; retains traces containing errors or P99+ duration spans; discards the rest after configurable TTL
- [ ] **TRACE-02**: Head-based sampling fallback applies a configurable rate limit for services where tail-sampling buffer cost is too high
- [ ] **TRACE-03**: Service map derives upstream/downstream service edges from OTel Collector servicegraph connector; edges are precomputed into a Postgres `service_edges` table (not computed at query time)
- [ ] **TRACE-04**: Trace explorer lets users search traces by service, endpoint, status code, duration range, and arbitrary span attributes; results show a waterfall / flamegraph view

### QUERY — Query Layer

- [ ] **QUERY-01**: PromQL API endpoint (compatible with `prometheus/prometheus storage.Queryable`) lets SREs query metrics using standard PromQL expressions
- [ ] **QUERY-02**: SQL query API (powered by Apache DataFusion) lets users run SQL against logs and traces across hot and cold tiers
- [ ] **QUERY-03**: A single query request spanning the hot and cold tiers is served transparently via DataFusion UnionExec; users do not need to know which tier holds their data
- [ ] **QUERY-04**: Per-tenant query QPS limits prevent any single tenant's query workload from degrading performance for others

### AUTH — Authentication, Authorization & Multi-Tenancy

- [ ] **AUTH-01**: User can create an organization and generate scoped API keys for ingest and query endpoints
- [ ] **AUTH-02**: RBAC model enforces org → project → role boundaries; roles: Owner, Editor, Viewer; enforced on dashboards, queries, and alert rule management
- [ ] **AUTH-03**: SSO / SAML 2.0 is available in the OSS tier (not gated behind a commercial license — differentiator vs Grafana Enterprise)
- [ ] **AUTH-04**: All data access events (reads and writes) are written to a separate HIPAA audit Kafka topic with append-only semantics, tamper-evident checksums, and 6-year retention in cold tier

### ALERTING — Alert Engine

- [ ] **ALERT-01**: Users can create alert rules using PromQL (metrics) or SQL (logs/traces) with configurable evaluation intervals and threshold conditions
- [ ] **ALERT-02**: Alert engine tracks SLO definitions and fires burn-rate alerts when error budget consumption rate indicates SLO breach is imminent
- [ ] **ALERT-03**: Alert state machine (OK → PENDING → FIRING → RESOLVED) with configurable pending duration, deduplication by fingerprint, grouping, and inhibition rules (implicit dependency of notification delivery)
- [ ] **ALERT-04**: Alert engine delivers notifications to PagerDuty, Slack, Webhook, and Email channels with per-tenant rate limiting and deduplication

### UI — Product Interface

- [ ] **UI-01**: Dashboard builder lets users compose dashboards from PromQL (line/bar charts) and SQL (table, stat, heatmap) widgets with drag-and-drop layout
- [ ] **UI-02**: Trace explorer provides full-text trace search and an interactive span waterfall / flamegraph view correlated with metrics and logs for the same time window
- [ ] **UI-03**: Log search provides full-text search with faceted filtering on parsed log fields (level, service, trace_id, arbitrary key/value attributes)
- [ ] **UI-04**: Alert manager lets users author alert rules, view alert history with state transitions, and configure notification channels
- [ ] **UI-05**: Service map displays an interactive topology graph with per-edge request rate, error rate, and P50/P99 latency overlays; supports upstream/downstream blast-radius navigation

### OPS — Deployment & Operations

- [ ] **OPS-01**: NewDogRelic ships a Kubernetes Helm chart for self-hosted deployment; enterprise customers can install it in their own cluster (HIPAA self-host use case)
- [ ] **OPS-02**: Docker Compose configuration provides a single-command local development environment (Kafka + IOx + Postgres + object store emulator + all services)
- [ ] **OPS-03**: NewDogRelic Cloud: a managed SaaS offering runs the OSS core; customers point OTel Collector at cloud ingest endpoints; billing is usage-based
- [ ] **OPS-04**: Self-observability pipeline emits internal metrics (ingest lag, queue depth, dropped batches, IOx compactor status, GC pauses) to a dedicated internal tenant visible in the ops dashboard

---

## v2 Requirements (Deferred)

- Browser/mobile RUM SDK (OTel web SDK ingest works in v1; full RUM dashboard deferred)
- Continuous profiling (CPU/memory flame graphs from profiling agents)
- Synthetic monitoring (HTTP/DNS probes, uptime checks)
- ML-based anomaly detection
- Custom proprietary agent protocol
- StatsD/Telegraf legacy protocol support
- Cold-only Trino/DuckDB query path (beyond IOx managed lifecycle)
- Mobile SDK for iOS/Android
- Notebook / exploratory analysis API (Jupyter-like)

---

## Out of Scope

- **Custom wire protocol**: OTLP covers all needed signals — building a proprietary agent format adds SDK maintenance with no user benefit
- **Grok / regex log parser**: OTel Collector transform processor handles log parsing at ingest; no Kibana-style parser builder
- **GPL/LGPL dependencies in core**: Apache 2.0 license constraint — all dependencies must be compatible
- **Proprietary query language (NRQL-style DSL)**: PromQL + SQL provides SRE familiarity + SQL power without a custom language maintenance burden

---

## Traceability

| REQ-ID | Phase | Status |
|--------|-------|--------|
| INGEST-01 | Phase 2 | Pending |
| INGEST-02 | Phase 2 | Pending |
| INGEST-03 | Phase 2 | Pending |
| INGEST-04 | Phase 2 | Pending |
| INGEST-05 | Phase 2 | Pending |
| STORE-01 | Phase 1 | Pending |
| STORE-02 | Phase 1 | Pending |
| STORE-03 | Phase 1 | Pending |
| STORE-04 | Phase 2 | Pending |
| TRACE-01 | Phase 3 | Pending |
| TRACE-02 | Phase 3 | Pending |
| TRACE-03 | Phase 3 | Pending |
| TRACE-04 | Phase 5 | Pending |
| QUERY-01 | Phase 4 | Pending |
| QUERY-02 | Phase 4 | Pending |
| QUERY-03 | Phase 4 | Pending |
| QUERY-04 | Phase 4 | Pending |
| AUTH-01 | Phase 2 | Pending |
| AUTH-02 | Phase 4 | Pending |
| AUTH-03 | Phase 4 | Pending |
| AUTH-04 | Phase 4 | Pending |
| ALERT-01 | Phase 5 | Pending |
| ALERT-02 | Phase 5 | Pending |
| ALERT-03 | Phase 5 | Pending |
| ALERT-04 | Phase 5 | Pending |
| UI-01 | Phase 6 | Pending |
| UI-02 | Phase 6 | Pending |
| UI-03 | Phase 6 | Pending |
| UI-04 | Phase 6 | Pending |
| UI-05 | Phase 6 | Pending |
| OPS-01 | Phase 7 | Pending |
| OPS-02 | Phase 1 | Pending |
| OPS-03 | Phase 7 | Pending |
| OPS-04 | Phase 7 | Pending |

*Traceability mapped 2026-11-12. All 34 v1 requirements assigned to exactly one phase.*

---

## Definition of Done (v1 Ship Criteria)

A service team can:
1. Install NewDogRelic via Helm chart in their Kubernetes cluster
2. Configure their OTel Collector to point at NewDogRelic ingest
3. See correlated traces + metrics + logs in a single query interface within 5 minutes
4. Create a dashboard, set an alert rule, and receive a notification — without any data leaving their infrastructure
5. Pass a HIPAA audit log review for data access over a 30-day window
