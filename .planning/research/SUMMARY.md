# Project Research Summary

**Project:** NewDogRelic — Open-Source Observability Platform
**Domain:** APM / Observability SaaS (self-hosted + cloud, New Relic alternative)
**Researched:** 2026-11-12
**Confidence:** HIGH (all four research dimensions confirmed by multiple authoritative sources)

---

## Executive Summary

NewDogRelic is a multi-tenant observability platform that ingests traces, metrics, and logs via OTLP, stores them in a hot/warm/cold tiered architecture built on InfluxDB 3 Core (IOx) and S3-backed Parquet, and surfaces them through a full product UI with PromQL and SQL query APIs. Research confirms the pre-decided stack is sound. The highest-impact architectural clarification from research is that IOx is not an embeddable Rust crate — it is a standalone binary deployed as a Kubernetes pod, which simplifies the architecture by removing the need for a custom Rust storage wrapper. The Go ingest service writes to IOx via its HTTP API and the official Rust client is available for any future Rust services. The OTel Collector should function as a mandatory edge tier, not as an optional integration, because trace-affinity routing for tail sampling requires it.

The recommended build sequence is infrastructure-first, write-path-second, read-path-third, and product-surface-last. The dependency chain is strict: Kafka and IOx must exist before ingest can be proven, ingest must carry real data before query can be validated, query must be stable before alert evaluation can run, and all backend APIs must exist before the frontend is built out. Within the ingest phase, metrics and logs ETL should be built before trace ETL because trace ETL adds stateful complexity (the Pebble-backed span buffer for tail sampling) that is easier to introduce on top of a proven stateless pipeline. HIPAA requirements — dual audit log stream, attribute scrubbing, immutable cold storage — are not retrofittable and must enter the design in Phase 1 before any external data is accepted.

The five highest-consequence risks all have architectural solutions that are cheap to implement early and expensive to retrofit: cardinality enforcement at the ingest gate, Kafka partition keying on `tenant_id`, the two-tier OTel Collector topology for tail sampling, the cold tier S3 partition scheme (`tenant_id/dt=YYYY-MM-DD`), and the dual observability-vs-audit log stream for HIPAA. Each of these is a one-way door — once data flows through the wrong design, correcting it requires rewriting historical data or full pipeline redeployment. The roadmap must front-load these decisions in Phases 1 and 2.

---

## Key Findings

### Recommended Stack

The pre-decided technology choices are confirmed as correct across the board. The key validation is that the OTel Collector Contrib project should be used as the production-ready edge receiver rather than building a custom OTLP receiver in Go — this is what SigNoz, Elastic, and Grafana all do, and the Go ingest service's role is Kafka consumer and orchestrator, not OTLP protocol handler. The PromQL engine should be reused from `github.com/prometheus/prometheus` via the `storage.Queryable` interface — rewriting it takes 2–3 years to reach compliance and multiple major vendors have learned this lesson. Protobuf over Kafka (using the OTel Collector's native `otlp_proto` encoding) is correct and eliminates the need for a Schema Registry, since OTLP proto definitions are already the canonical schema.

The single revision to PROJECT.md's stack: replace Recharts with Apache ECharts (`echarts-for-react`) as the primary charting library. Recharts is SVG-only and degrades above ~10K data points, which is routine for a 5M spans/s design target. ECharts uses canvas rendering with progressive rendering and WebGL support. Nivo can supplement ECharts for Sankey/chord service topology visualizations.

**Core technologies:**

- **OTel Collector Contrib**: edge OTLP receiver, trace-affinity load balancer, PII pre-scrubber — use as-is; do not rebuild in Go
- **franz-go (v1.17+)**: Kafka client for Go ingest service — pure Go, 4x faster than confluent-kafka-go, zero CGO; replaces Sarama (correctness issues) and confluent-kafka-go (CGO breaks static builds)
- **Chi (v5)**: Go HTTP router for admin/health/query API — net/http-compatible; Fiber excluded (no HTTP/2 server support)
- **grpc-go (v1.85.0)**: gRPC server for OTLP + internal RPCs — only production gRPC library for Go; use `StatsHandler`-based OTel instrumentation
- **go.uber.org/zap (v1.27+)**: structured logging — 51 ns/op, `AtomicLevel` for runtime log level changes, `zaptest/observer` for unit tests
- **InfluxDB 3 Core (IOx)**: hot-tier columnar storage — deploy as Kubernetes pod, write via HTTP line protocol on port 8181; 72h data limit on free-tier Core is a confirmed constraint
- **Apache DataFusion + object_store crate**: cold-tier Parquet query engine for data beyond IOx's managed lifecycle — uses `ListingTable` with Hive-style partition pruning
- **prometheus/prometheus storage.Queryable**: PromQL engine — reuse directly; implementing the single-method interface is the established pattern (Thanos, Mimir, Cortex, VictoriaMetrics all do this)
- **Apache ECharts (echarts-for-react v5)**: primary charting — canvas rendering for 10K+ data point time-series; replaces Recharts
- **TanStack Query v5 + Zustand v4**: server state + client UI state — the 2024–2025 community standard for SaaS dashboards; Redux Toolkit excluded (13x heavier, no meaningful benefit)
- **External Secrets Operator + HashiCorp Vault + KMS v2**: HIPAA secrets and encryption stack — ESO syncs Vault into Kubernetes Secrets; KMS v2 (stable k8s 1.29+) encrypts etcd at rest
- **Bitnami/kafka Helm chart (KRaft mode)**: Kafka deployment — KRaft is production-ready since Kafka 3.3+; no ZooKeeper dependency

---

### Expected Features

The observability market in 2025 has high table-stakes requirements. The most important insight from feature research is that the #1 reason teams leave New Relic and Datadog is unpredictable billing — NewDogRelic's OSS + flat-tier pricing is a business-model differentiator that requires no engineering work but must be communicated clearly. The second-most important driver is NRQL lock-in: SQL portability is a genuine switching incentive. The OSS competitive landscape has three real gaps that NewDogRelic can fill: audit logs (SigNoz marks this "COMING SOON," Grafana gates it behind Enterprise), SAML/OIDC SSO in the free tier (every competitor gates this behind paid plans), and tail-based sampling (SigNoz is head-based only, Tempo has nothing built-in).

**Must have (table stakes):**
- Multi-signal OTLP ingest (traces + metrics + logs) — nothing else works without data flowing in
- PromQL-compatible metrics query API — SRE buyers test this on day 1; absence is a dealbreaker
- SQL query API (DataFusion) for logs and traces — the portability differentiator vs. NRQL
- Trace explorer (search, filter, waterfall view) — primary use case for the target buyer persona
- Log search (full-text + structured field filtering) — closes the third-pillar multi-signal story
- Service map (auto-generated from trace spans, with health status overlay) — table stakes in 2025; every competitor has it; absence loses evaluations
- Alert engine (threshold alerts, state machine OK/WARN/CRIT, deduplication, PagerDuty/Slack/Webhook/Email)
- Multi-window burn-rate SLO alerting — Google SRE Workbook standard; SigNoz alerting is explicitly weaker here
- Multi-tenant RBAC (Org → Project → role) with API key auth per tenant
- Attribute scrubbing / PII redaction in ingest pipeline — HIPAA non-negotiable; must be in-path, not at query time
- Audit logging (immutable, 6-year cold retention) — HIPAA 45 CFR §164.312(b); OSS competitors don't have it in free tier
- Auto-generated default dashboard on first service trace — first-run UX; empty UI on first trace kills evaluations
- Custom dashboards with panel layout (time-series, table, stat, top-list)
- Hot/warm/cold tiered retention (3d/30d/unlimited) — cost-sensitive self-hosters will not use a platform that offers no retention control

**Should have (competitive):**
- SSO via SAML/OIDC in OSS tier — genuine market gap; SigNoz and Grafana OSS gate this behind paid plans
- Tail-based trace sampling with configurable policies (error, latency, attribute) — head-based discards interesting traces; Honeycomb Refinery is the benchmark
- Cross-signal correlation by trace ID (jump trace → logs → metrics in one click) — the hardest UX problem in observability; directly differentiates from Grafana stack's multi-DSL experience
- In-product OTel instrumentation guide (language-specific SDK setup wizard) — reduces time-to-first-trace from hours to minutes
- Span-derived RED metrics per service-to-service edge (rate, error rate, duration) — builds on trace data already flowing; reduces instrumentation burden

**Defer (v2+):**
- Browser/mobile RUM SDK — SDK surface area is enormous (Web Vitals, session replay, Navigation Timing API); v1 should accept OTel browser spans passively
- Synthetic monitoring — geographically distributed probe infrastructure; separate product domain
- Continuous profiling — full product in its own right (Grafana Pyroscope); separate storage and query surface
- ML/AI anomaly detection — requires a mature data layer first; ship statistical anomaly aids in v2
- Kubernetes Operator — Helm chart serves v1 self-hosters; Operator adds enterprise lifecycle management in v2
- Sample data / demo mode — high evaluation value but not day-1 blocking

---

### Architecture Approach

The architecture is a streaming pipeline with a strict write-path/read-path separation: data flows OTel Collector → Go Ingest API → Kafka → Go ETL Workers → IOx → S3, while queries flow Frontend → Go BFF → Go Query Orchestrator → IOx Querier (which natively unions hot RecordBatchesExec + cold ParquetExec via DataFusion). The OTel Collector tier is mandatory, not optional — it provides trace-affinity routing (required for tail sampling), centralized PII scrubbing (required for HIPAA), and credential isolation (API keys never touch application pods). Kafka uses three signal-scoped topics (not per-tenant topics) with tenant ID propagated as a message header, and `trace_id` as the partition key for the traces topic to enforce trace affinity for tail sampling. The service map is a read-side projection derived by consuming the traces Kafka topic and writing precomputed edges to Postgres — do not compute service maps synchronously from raw spans at query time.

**Major components and build order:**

1. **Infrastructure substrate** (Kafka KRaft + IOx cluster + Postgres catalog + object store) — everything else depends on these; topology decisions set here are permanent
2. **Ingest API + Metrics/Logs ETL** (Go OTLP receiver → Kafka → IOx write) — proves write path before introducing stateful complexity
3. **Trace ETL + Tail Sampling** (Pebble-backed span buffer, two-tier Collector topology) — builds on proven ETL workers; Pebble for span buffer (not in-memory) to handle 5M spans/s scale
4. **OTel Collector Tier + Auth/RBAC** (DaemonSet + Gateway, PII scrubbing, audit logging) — refines ingest; establishes HIPAA controls and tenant identity
5. **Query Layer** (PromQL → IOx metrics, SQL → IOx traces+logs, hot+cold UnionExec) — requires real data in IOx to validate; test DataFusion UnionExec behavior under load before exposing to UI
6. **Service Map + Derived Signals** (span-pair correlation, graph store, RED metrics) — read-side projection; requires complete traces in IOx
7. **Alert Engine** (rule evaluation, SLO tracking, state machine, notification dispatch) — consumes query layer; state machine + deduplication are correctness requirements, not nice-to-have
8. **Frontend** (React + ECharts + TanStack Query) — composition layer; build feature-by-feature as backend APIs stabilize
9. **Kubernetes hardening + Cloud deployment** (production Helm chart, HPA, multi-region) — hardens a proven system

---

### Critical Pitfalls

1. **Cardinality explosion** — OTel SDKs make it trivial to add high-cardinality labels; without an attribute processor allowlist at the OTel Collector tier, one developer instrumenting by convention can produce billions of time series and trigger IOx WAL/compactor cascades. Gate with allowlist (service.name, service.version, environment, region, status_code only) + per-tenant series cap in the ingest API before accepting any external data. **Phase 1.**

2. **Kafka consumer lag cascade / data loss** — the ingest API returns 200 OK while data sits in Kafka; if consumer lag reaches the retention window, that data is silently lost. The root cause is downstream IOx slowness bleeding into consumer throughput. Prevention: implement `KafkaConsumer.pause()` on partitions when IOx write latency exceeds threshold, circuit-break to 503 on IOx write errors > N%, and alert at `consumer_lag_time > 30s`. **Phase 1 (partition keying), Phase 2 (backpressure logic).**

3. **IOx compaction storm** — the IOx compactor is a single-instance service (horizontal scaling is not safe) that is CPU+network bound; under-provision it and WAL growth backpressures writes for all tenants. Prevention: provision the compactor at 2× expected load on its own dedicated node with NVMe-backed WAL storage and guaranteed QoS. Alert at `compactor_uncompacted_file_count > 1000`. **Phase 2.**

4. **Tail-sampling memory exhaustion** — deploying tail-samplers with random OTLP load balancing means spans of the same trace land on different instances, causing either O(N) memory multiplication or incorrect sampling decisions on incomplete traces. The fix is a two-tier Collector topology — stateless DaemonSet agents emit to stateful gateway pods using `loadbalancingexporter` with `routing_key: traceID`. This is a topology decision, not a configuration decision; retrofitting it requires a full pipeline redeployment. **Phase 3 — must be designed before the trace pipeline is built.**

5. **HIPAA audit log blast radius** — routing audit logs to the same storage system as operational telemetry violates HIPAA in two ways: wrong retention (observability stores delete; HIPAA requires 6 years) and wrong access control (developers should not see PHI access patterns). Prevention: dual-stream from the initial Kafka architecture — separate topics and storage backends for observability vs. audit events; audit writes to S3 with Object Lock (WORM) + SSE-KMS. **Phase 1 — cannot be retrofitted.**

---

## Implications for Roadmap

The architecture research provides a clear 9-layer dependency chain. Research from all four files converges on the same ordering: infrastructure before data flow, write path before read path, single-signal before multi-signal, backend before frontend. The pitfalls research adds urgency to front-loading specific "one-way door" decisions — partition keying, audit stream split, Collector topology, and cold tier partition scheme. Suggested phases below compress the 9 architecture layers into 6 roadmap phases that group naturally dependent work.

---

### Phase 1: Infrastructure and Foundations

**Rationale:** Everything downstream depends on Kafka, IOx, Postgres, and the security substrate being correct from the start. Partition layout, audit stream design, and OTel Collector tier topology are one-way doors — wrong choices here require full data rewrites or pipeline redeployments to fix. This phase has no user-visible output but validates the entire build order.

**Delivers:**
- Kafka cluster (KRaft mode, 3 signal-scoped topics, 48 partitions each, RF=3, `tenant_id` partition key)
- InfluxDB 3 Core cluster (Ingester + Compactor on dedicated node with NVMe + Querier, Postgres catalog)
- Object store (S3/MinIO, cold tier partition scheme: `tenant_id/dt=YYYY-MM-DD/`)
- Dual Kafka stream split: `ndr.{signal}.raw` (observability) + `ndr.audit` (HIPAA, separate consumer group, S3 Object Lock destination)
- Auth/RBAC skeleton: API key management, org/project/resource model, audit log writer
- Local dev environment (Docker Compose with all infra components)
- SCA in CI: approved license list (MIT, Apache 2.0, BSD), blocked list (GPL, AGPL, SSPL); CLA process established
- OTel Collector Contrib pinned version + OTLP smoke test suite in CI

**Addresses:** Multi-tenant isolation, HIPAA from inception, API key auth, OSS licensing hygiene
**Avoids:** Kafka consumer lag cascade (partition keying), HIPAA audit blast radius (dual stream), cardinality explosion (Collector gate placeholder), OSS licensing traps, cold tier partition mistakes

---

### Phase 2: Ingest Pipeline (Metrics + Logs)

**Rationale:** Build the simpler stateless ETL workers (metrics, logs) before introducing the stateful complexity of trace tail sampling. Proves the end-to-end write path from OTLP to IOx with real data before the query layer needs to be validated. Per-tenant cardinality enforcement and Kafka backpressure logic belong here — these are write-path correctness requirements.

**Delivers:**
- Go Ingest API: OTLP/gRPC + OTLP/HTTP receiver, tenant-key extraction, rate limiting, attribute scrubbing (PII allowlist)
- OTel Collector Gateway pool: DaemonSet agents + gateway Deployment with PII pre-scrub `transform` processor, semantic convention normalization, Kafka export via `otlp_proto` encoding
- Metrics ETL Worker (Go): Kafka consumer, metric normalization, exemplar linking, IOx write, per-tenant series cardinality cap enforcement
- Logs ETL Worker (Go): Kafka consumer, structured field extraction, IOx write
- Kafka backpressure: `pause()`/`resume()` on IOx write latency threshold, circuit breaker on IOx error rate
- DLQ topics wired for all signal types
- IOx compactor provisioned at 2× load on dedicated node; compactor lag alerting

**Addresses:** Metrics ingest, logs ingest, PII scrubbing in ingest path, per-tenant rate limits
**Avoids:** Cardinality explosion (attribute allowlist at Collector + series cap at ingester), Kafka consumer lag cascade (backpressure), IOx compaction storm (compactor provisioning)

---

### Phase 3: Trace Pipeline + Tail Sampling

**Rationale:** Trace ETL is separated from metrics/logs because tail sampling requires a stateful span buffer (Pebble-backed) and a two-tier Collector topology for trace-affinity routing. These must be designed from scratch as a new component, not bolted onto the stateless workers. Building traces third means the IOx write path is already proven.

**Delivers:**
- Two-tier OTel Collector architecture: stateless DaemonSet agents → `loadbalancingexporter` with `routing_key: traceID` → stateful gateway pool with `tailsamplingprocessor`
- Trace ETL Worker (Go): Pebble-backed span buffer, `decision_wait`-based sampling (error policy, latency policy, rate-limit policy), trace assembly, IOx write
- 1% head-based sampling floor as OOM fallback
- Tail sampling monitoring: `sampling_trace_dropped_too_early` exported to Prometheus; buffer fill alerts

**Addresses:** Tail-based trace sampling, trace storage in IOx
**Avoids:** Tail-sampling memory exhaustion (two-tier topology with trace-affinity routing + Pebble buffer), incomplete trace decisions (single-tier random LB anti-pattern eliminated)

---

### Phase 4: Query Layer + Multi-Tenant Auth

**Rationale:** The query layer requires real data in IOx to validate DataFusion's hot+cold UnionExec behavior under realistic conditions. Auth and RBAC are built here (expanded from the skeleton in Phase 1) because they gate all customer-facing query access. PromQL compliance testing belongs at the end of this phase before any external announcement.

**Delivers:**
- Query Orchestrator (Go): PromQL → IOx SQL translation for metrics, SQL query API for traces + logs, hot+cold result federation, result pagination and streaming
- PromQL engine reuse via `prometheus/prometheus storage.Queryable` interface
- SQL query API (DataFusion) for traces + logs
- Full Auth/RBAC service: org → project → resource hierarchy, role enforcement at Query Orchestrator, audit logging integrated
- Per-tenant query limits: 30s timeout, 500K max series per query, 5 concurrent queries per tenant (HTTP 429 on exceed)
- Cross-signal correlation by trace ID (jump trace → logs → metrics)
- PromQL compliance suite (PromLabs) run; compliance gaps documented

**Addresses:** PromQL API, SQL API, cross-signal analytics, multi-tenant query isolation
**Avoids:** Multi-tenant noisy neighbor (per-tenant query limits), custom query federation before IOx UnionExec (use IOx natively)

---

### Phase 5: Service Map, Alert Engine, and Product UI

**Rationale:** Service map, alert engine, and the frontend are all consumers of the write and query layers. They can be built in parallel but all depend on Phase 4 stability. Service map is a read-side projection from the trace Kafka topic. The alert engine is a scheduled query runner with a state machine. The frontend is the composition layer built feature-by-feature as backend APIs stabilize.

**Delivers:**
- Service Map Processor (Go): consumes `ndr.traces.raw`, CLIENT+SERVER span-pair correlation, edge upsert to Postgres `service_edges`, real-time update (last 5 minutes)
- Service Map API + RED metrics derivation per service-to-service edge (rate, error rate, duration)
- Alert engine: PromQL + SQL rule evaluation on configurable intervals, SLO definition model (SLI + target + window), multi-window burn-rate alerts (5m + 1h), state machine (OK → PENDING → FIRING → RESOLVED), flap detection, deduplication via fingerprint-based dedup_key, grouping with configurable wait windows, inhibition rules, PagerDuty/Slack/Webhook/Email notification dispatch
- Alert history queryable; per-tenant notification rate limits
- Frontend (React + TypeScript + ECharts + TanStack Query v5 + Zustand): metrics dashboards, trace explorer (search/filter/waterfall), log search, service map visualization, alert manager
- Auto-generated default dashboard on first trace receipt per service (first-run onboarding)
- In-product OTel instrumentation guide (language-specific SDK setup wizard)
- SSO via SAML/OIDC in OSS tier

**Addresses:** Service map (table stakes), alert engine (threshold + SLO burn-rate), all core UI surfaces, HIPAA audit review UI, onboarding first-run experience, SSO
**Avoids:** Alert storm / notification flooding (fingerprint dedup + grouping + inhibition are correctness requirements, not nice-to-have)

---

### Phase 6: Hardening, Helm Chart, and Cloud Deployment

**Rationale:** Production hardening requires a working, tested system. Kubernetes Operator complexity warrants deferral to after the core platform is stable. The Helm chart pattern follows VictoriaMetrics (CRD-first, component-per-chart), not SigNoz (monolithic bundled chart).

**Delivers:**
- Production Helm chart (component-per-chart: `newdogrelic-operator`, `newdogrelic-core`, `newdogrelic-stack` umbrella)
- HPA autoscaling: Kafka consumer lag → ETL worker replicas, IOx Querier queue depth → Querier replicas
- Per-tenant observability dashboards (ingest rate, query latency, series count, error rate per tenant)
- Multi-region active-active ingest with single query region
- IOx tiered cluster model: shared cluster for standard tenants, dedicated clusters for Enterprise/HIPAA tenants
- S3 prefix sharding to avoid 5,500 req/s per-prefix limit
- NewDogRelic Cloud: managed SaaS onboarding, Cloud ToS with acceptable use clause
- Cold-tier secondary compaction job (merge small Parquet files to 64–256 MB targets during off-peak hours)

**Addresses:** Kubernetes-native deployment, cloud monetization, enterprise/HIPAA tier isolation, cold tier read performance
**Avoids:** IOx noisy neighbor across all tiers (physical cluster separation), cold tier query performance failure (secondary compaction + partition pruning)

---

### Phase Ordering Rationale

- **Infrastructure before data**: Kafka partition keying and cold-tier partition scheme are set at the first write; they cannot be changed without rewriting all data. Must decide before anything flows.
- **Metrics/logs before traces**: Tail sampling introduces a stateful span buffer (Pebble) and a two-tier Collector topology; building simpler stateless ETL workers first lets the team validate the IOx write path before adding that complexity.
- **Write path before read path**: DataFusion's UnionExec hot+cold behavior must be tested under realistic data volumes; building the query layer on an empty IOx instance does not reveal the deduplication edge cases during flush windows.
- **Backend before frontend**: The frontend is a composition layer; building it before backend APIs stabilize creates rework. Build feature-by-feature as APIs are ready.
- **Hardening last**: Production Helm chart, autoscaling, and multi-region require a system that is known to work correctly; hardening an unstable system is wasted effort.
- **HIPAA controls in Phase 1 and 2**: Attribute scrubbing, dual audit stream, and immutable audit storage must enter the pipeline before any external data is accepted. These are not retrofittable.

---

### Research Flags

**Phases needing deeper research during planning:**

- **Phase 1 (IOx retention):** InfluxDB 3 Core has a confirmed 72h hot-tier limit for the free-tier OSS release. The warm tier (30d) may require InfluxDB 3 Enterprise or a custom compactor derived from open-source IOx ingester/compactor code. This is HIGH impact — it affects whether the warm tier can be built on OSS Core or requires a fork. Needs phase-specific research before architecture is finalized.
- **Phase 1 (IOx Kubernetes):** InfluxDB 3 Core has no official Helm chart or Kubernetes operator (GA April 2025, operator not yet published). Custom chart required. Research existing community charts before writing from scratch.
- **Phase 4 (PromQL engine bootstrap):** Confirm whether `github.com/prometheus/prometheus` promql.Engine can run standalone without booting a full Prometheus server. This is HIGH impact — the query service design depends on it.
- **Phase 5 (Thanos Ruler for alert evaluation):** Thanos Ruler can evaluate PromQL alerts against any Prometheus-compatible endpoint; confirm whether it can be deployed standalone without a full Thanos deployment. MEDIUM impact — may simplify alert engine implementation significantly.

**Phases with standard patterns (skip research-phase):**

- **Phase 2 (OTel Collector configuration):** OTel Collector Contrib is well-documented with official config references. The `transform` processor, `memory_limiter`, `batch`, and `kafkaexporter` are all stable `beta`+ components with extensive production usage.
- **Phase 3 (Pebble span buffer):** Pebble (the LevelDB successor from CockroachDB) is well-documented. The tail-sampling buffer pattern with disk-backed storage is confirmed in Elastic's production benchmarks.
- **Phase 5 (Alert state machine):** Prometheus Alertmanager's state machine is a well-documented reference implementation. The deduplication/grouping/inhibition patterns are established; no novel research needed.
- **Phase 6 (Helm chart structure):** VictoriaMetrics operator pattern is fully documented and serves as a direct model.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Pre-decided stack validated against official docs and production comparisons; IOx deployment pattern (sidecar/pod, not embedded crate) is the key clarification. ECharts over Recharts is a clear recommendation backed by canvas vs. SVG benchmarks. |
| Features | HIGH | Competitive landscape well-researched across New Relic, Datadog, SigNoz, Grafana, OpenObserve; HIPAA requirements traced to specific CFR citations; feature dependencies mapped explicitly. |
| Architecture | HIGH | All 7 architecture focus areas confirmed against official docs and production postmortems (Datadog, Grafana Tempo, Elastic, IOx official blog). The IOx UnionExec/DeduplicateExec behavior during flush windows is a known caveat, not a surprise. |
| Pitfalls | HIGH | All 10 pitfalls sourced from official docs, GitHub issues, and production postmortems. Phase assignments are specific. The critical/moderate/minor tiering reflects actual consequence severity. |

**Overall confidence:** HIGH

---

### Gaps to Address

- **IOx 72h warm-tier limit**: The OSS Core's 72h retention limit is confirmed. Whether the 30d warm tier requires InfluxDB 3 Enterprise (licensing cost) or can be implemented via a custom compactor (engineering cost) is unresolved. Address in Phase 1 planning before storage architecture is finalized. Options: (a) accept Enterprise dependency for warm tier, (b) run a separate IOx instance with extended config, (c) implement a custom compactor from open-source IOx ingester code.
- **PromQL engine standalone boot**: Confirmed that Thanos, Mimir, Cortex all reuse `prometheus/prometheus promql.Engine` without running a full Prometheus server. The `storage.Queryable` interface is the seam. However, the exact initialization sequence (without a full Prometheus config file) needs a code-level validation in Phase 4 planning.
- **IOx Kubernetes HA for production**: No official InfluxDB 3 Core Kubernetes operator exists as of April 2025 GA. The custom Helm chart for IOx is a known engineering task; the question is whether any community chart is mature enough to build on. Research this before Phase 1 Helm chart work begins.
- **Schema evolution during OTel semantic convention upgrades**: The copy-mode (write both old and new attribute names during migration windows) approach is derived from Honeycomb's internal guidance. The specific implementation in IOx (Parquet column addition without file rewrite + DataFusion schema merging) is architecturally sound but the exact ETL Worker implementation pattern needs design during Phase 2.

---

## Sources

### Primary (HIGH confidence — official docs, production case studies)

- InfluxDB 3.0 System Architecture — https://www.influxdata.com/blog/influxdb-3-0-system-architecture/
- InfluxDB 3 Core GA announcement — https://www.influxdata.com/blog/influxdata-announces-influxdb-3-OSS-GA/
- OTel Collector Tail Sampling Processor README — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md
- Prometheus storage.Queryable interface — https://panos-zamos.github.io/go/docs/projects/prometheus/interfaces/
- DataFusion SIGMOD 2024 paper — https://andrew.nerdnetworks.org/pdf/SIGMOD-2024-lamb.pdf
- OTel Managed Telemetry Platforms K8s Blueprint — https://opentelemetry.io/docs/guidance/blueprints/managed-telemetry-platforms-for-k8s-workloads/
- VictoriaMetrics Kubernetes Operator docs — https://docs.victoriametrics.com/operator/
- Elastic OTel tail sampling 65% less memory with disk storage — https://www.elastic.co/observability-labs/blog/tail-sampling-memory-opentelemetry

### Secondary (MEDIUM confidence — community consensus, multiple sources agree)

- franz-go vs Sarama vs confluent-kafka-go comparison — https://kafma.app/blog/kafka-golang-clients
- ECharts vs Recharts vs Nivo canvas/SVG benchmarks — https://blog.logrocket.com/best-react-chart-libraries-2026/
- TanStack Query v5 + Zustand for SaaS dashboards — https://dev.to/uaslimcreate/building-saas-with-react-and-tanstack-query-a-complete-architecture-guide-203
- Multi-tenancy in Kafka (signal-scoped topics) — https://www.conduktor.io/blog/how-to-do-multi-tenancy-in-kafka
- S3 partition layout and pruning — https://luminousmen.substack.com/p/how-not-to-partition-data-in-s3-and
- HIPAA audit log requirements (45 CFR citations) — https://medcurity.com/hipaa-audit-log-requirements/

### Tertiary (MEDIUM-LOW — noted for validation during planning)

- IOx warm-tier 30d / Enterprise boundary — InfluxData blog (April 2025 GA post); needs confirmation via InfluxData support or GitHub issues before Phase 1 architecture decision
- Thanos Ruler standalone deployment — referenced in multiple observability guides but needs code-level validation for the Phase 4 alert engine design

---

*Research completed: 2026-11-12*
*Ready for roadmap: yes*
