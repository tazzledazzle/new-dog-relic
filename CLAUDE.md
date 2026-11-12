<!-- GSD:project-start source:PROJECT.md -->
## Project

**NewDogRelic**

NewDogRelic is an Apache 2.0 open-source observability platform for enterprise and platform teams who want a self-hostable New Relic alternative. It ingests distributed traces, metrics, logs, and events via OTLP/OTel, stores them across a hot/warm/cold tiered architecture, and surfaces them through a full product UI (dashboards, trace explorer, log search, alert manager, service maps) with PromQL for metrics and SQL for logs/traces. The monetization model is OSS core + NewDogRelic Cloud managed SaaS (similar to Grafana/SigNoz).

**Core Value:** A platform/SRE team can instrument any service with an OpenTelemetry SDK, point it at NewDogRelic, and get correlated traces + metrics + logs in a single query interface — self-hosted or cloud — without vendor lock-in.

### Constraints

- **Tech Stack**: Go + Rust services; React/TypeScript UI; self-hosted Kafka; Influx IOx — these choices are fixed; no alternatives in planning
- **Protocol**: OTLP/OTel only for ingest; PromQL + SQL for query — no custom wire protocols
- **License**: Apache 2.0 — no GPL/LGPL dependencies in core
- **Compliance**: HIPAA-grade from architecture inception, not bolted on later
- **Retention**: 3d hot / 30d warm / unlimited cold — sizing and flush intervals derive from this
- **Query Language**: PromQL for metrics (SRE familiarity), SQL via DataFusion for logs/traces (unified analytics)
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Pre-Decided Stack (Validated)
| Decision | Validation Status | Notes |
|---|---|---|
| OTLP/gRPC + HTTP ingest | CONFIRMED | Standard OTel Collector contrib pattern; well-documented |
| Self-hosted Apache Kafka | CONFIRMED | franz-go is the right Go client (see below) |
| InfluxDB IOx / 3 Core as storage engine | CONFIRMED with caveat | IOx = single-process binary; not an embeddable Rust crate — run as a sidecar/subprocess |
| Go for ingest API + orchestration | CONFIRMED | grpc-go v1.85.0 is the standard; Chi is the right HTTP router |
| Rust for hot-path | CONFIRMED | IOx Core is Rust-native; `influxdb3-client` crate for the client side |
| React + TypeScript frontend | CONFIRMED | Apache ECharts for time-series; TanStack Query v5 for server state |
| PromQL for metrics query | CONFIRMED | Reuse Prometheus `storage.Queryable` interface; do NOT rewrite PromQL engine |
| SQL via DataFusion for logs/traces | CONFIRMED | `object_store` crate + `datafusion` for cold Parquet-on-S3 |
| Kubernetes + Helm + Docker Compose | CONFIRMED | Follow VictoriaMetrics operator pattern (CRD-first) |
| HIPAA from inception | CONFIRMED | KMS v2 + External Secrets Operator + etcd encryption is the standard stack |
## Recommended Full Stack
### Layer 1: Ingest Pipeline
#### OTLP Receiver (pre-ingest buffer)
# Canonical OTel Collector pipeline for NewDogRelic
#### Go Ingest API (Kafka consumers + orchestration)
| Library | Version | Purpose | Rationale |
|---|---|---|---|
| `github.com/twmb/franz-go` | v1.17+ | Kafka client | Pure Go, 4x faster producing than confluent-kafka-go, 100% KIP feature-complete including KIP-848, zero cgo dependency. Sarama has known idempotent producer correctness issues — do not use. confluent-kafka-go requires cgo, breaking static binary builds. franz-go is the 2024–2025 community consensus choice for new Go projects. |
| `github.com/go-chi/chi/v5` | v5.x | HTTP router (admin/health/query API) | net/http-compatible, zero vendor-lock, standard handler signature. For this project the HTTP API surface (health checks, admin endpoints, query forwarding) is secondary to gRPC; Chi adds routing without custom context types that complicate OTel instrumentation. Fiber is excluded: no HTTP/2 server support (fasthttp limitation), and incompatible with standard net/http middleware including otelhttp. |
| `google.golang.org/grpc` | v1.85.0 | gRPC server for OTLP + internal RPCs | The only production gRPC library for Go. No v2 exists. Use `StatsHandler`-based OTel instrumentation (`otelgrpc.NewServerHandler()`), not deprecated interceptors. |
| `go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc` | v0.72.0 | gRPC OTel instrumentation | Required for trace propagation across gRPC spans. |
| `go.uber.org/zap` | v1.27+ | Structured logging | 51 ns/op, zero allocs on critical paths. zerolog is marginally faster but zap's `zapcore.Core` composability, `AtomicLevel` for runtime log level changes, and `zaptest/observer` for unit testing are production-critical for a multi-tenant platform. |
| `github.com/prometheus/client_golang` | v1.19+ | Prometheus metrics exposition | Standard Prometheus Go client. Expose `/metrics` on each service for self-monitoring via Prometheus scrape. |
### Layer 2: Storage Engine (InfluxDB 3 Core / IOx)
#### Critical Architecture Note on IOx Embedding
| Component | Integration Method | Notes |
|---|---|---|
| InfluxDB 3 Core (hot tier, 0–72h) | HTTP write API (line protocol) on :8181 + Flight SQL query | Single-process binary; deploy as Kubernetes pod. MIT/Apache 2 licensed. |
| InfluxDB 3 Core Rust client | `influxdb3-client` crate (crates.io) | For any Rust code that needs to write/query IOx — requires Rust 1.89+. Official crate, async. |
| IOx → Parquet flush | Automatic (built-in compactor) | IOx flushes WAL→Parquet→object store automatically. Configure flush interval and object store endpoint. |
| Warm tier (30d) | IOx with extended retention config | IOx supports configurable TTL windows; Enterprise adds historical query. For OSS Core + 30d warm, run a separate compaction-aware IOx instance or add a Postgres catalog + custom compactor derived from the open source IOx compactor service. |
### Layer 3: Cold Tier (Parquet on S3)
| Component | Technology | Rationale |
|---|---|---|
| Object store | AWS S3 / S3-compatible (MinIO for self-hosted) | Standard. DataFusion's `object_store` crate natively supports S3 via `AmazonS3Builder`. MinIO is the standard on-prem S3-compatible store for Kubernetes. |
| Query engine | Apache DataFusion (`datafusion` + `object_store` crates) | IOx already uses DataFusion internally. For the custom cold-tier querier, use DataFusion directly in a Rust query service. Supports `CREATE EXTERNAL TABLE ... STORED AS PARQUET LOCATION 's3://...'` with predicate pushdown, row-group pruning (`datafusion.execution.parquet.pruning = true`), and page-index pruning. |
| Partitioning scheme | `s3://{bucket}/signals/{tenant_id}/{signal_type}/{year}/{month}/{day}/{hour}/` | Hive-style partitioning. DataFusion's `ListingTable` applies partition pruning at the directory level before reading any files, essential at cold-tier latency targets. |
| Parquet metadata caching | `CachedParquetFileReaderFactory` (DataFusion) | Avoids per-query S3 metadata re-reads. Implement using `ParquetObjectReader` + a TTL cache over the row-group metadata bytes. |
| Postgres catalog | PostgreSQL (for partition-to-file mapping) | Standard IOx pattern: a lightweight Postgres catalog holds file-level metadata (min/max timestamps, tenant ID, partition key) so queries skip S3 `ListObjects` entirely. |
### Layer 4: Query APIs
#### PromQL (Metrics)
| Component | Library | Notes |
|---|---|---|
| PromQL engine | `github.com/prometheus/prometheus/promql` | Reuse directly. Apache 2.0 licensed. Implements the query engine over any `storage.Queryable`. |
| Remote Write receiver | Implement `/api/v1/write` endpoint | Accept Prometheus remote_write protobuf, parse, write to IOx via line protocol. Needed for Prometheus scrape → NewDogRelic migration path. |
| Remote Read endpoint | Optional — `/api/v1/read` | Allows Prometheus itself to proxy queries to NewDogRelic for mixed deployments. Low priority; most users query NewDogRelic directly. |
| PromQL compliance testing | PromLabs compliance suite | Run against the query API before GA. This is table stakes for marketing as "PromQL compatible." |
#### SQL for Logs/Traces (DataFusion)
| Component | Technology | Notes |
|---|---|---|
| Hot-tier SQL | IOx Flight SQL (port 8183) | IOx exposes Arrow Flight + SQL natively. Query via `arrow-flight` Go client. |
| Cold-tier SQL | DataFusion Rust service with `object_store` crate | Custom service: register S3 as `ObjectStore`, register Parquet partitions as external tables, execute SQL, return Arrow batches via Flight. |
| Cross-tier fan-out | Go query orchestrator | Go service fans out queries to hot (IOx) + cold (DataFusion) tiers, merges Arrow results, returns unified response. |
| Wire protocol to frontend | Arrow Flight SQL | Use Flight SQL as the internal query protocol; translate to JSON/REST at the API gateway for the browser client. |
### Layer 5: Kafka Schema Format
- OTLP signals are already defined as Protobuf in the OpenTelemetry specification. Using `otlp_proto` encoding in the Kafka exporter is zero additional schema work — the schemas are the OTel proto definitions.
- Avro's mandatory Schema Registry adds infrastructure overhead (another stateful service) that is unnecessary when the schema source of truth is already the OTel proto repository.
- Protobuf benchmarks: ~357k msg/sec vs Avro ~244k msg/sec — meaningful at 5M spans/s design target.
- The `otlp_proto` encoding is the default and recommended encoding for the OTel Collector Kafka exporter.
- Pure-Go Protobuf serialization is `google.golang.org/protobuf` — no CGO, no registry dependency.
| Concern | Decision |
|---|---|
| Schema evolution | OTel proto versioning handles this; pin proto versions in go.mod |
| Schema registry | Not needed; OTel protos are the registry |
| Observability of Kafka payloads | Use `otelcol` debug exporter in dev; production decode via OTel proto definitions |
### Layer 6: Frontend
| Technology | Version | Purpose | Rationale |
|---|---|---|---|
| React | 18.x | UI framework | Pre-decided; confirmed correct. |
| TypeScript | 5.x | Type safety | Pre-decided; confirmed correct. |
| Apache ECharts (via `echarts-for-react`) | 5.x | Time-series charts, heatmaps, service maps | Canvas rendering handles 10k+ data points (5M spans/s design target means large time-series result sets). SVG libraries (Recharts, Nivo) degrade at this cardinality. ECharts: 66k stars, progressive rendering, WebGL support for extreme datasets. `echarts-for-react` wrapper provides idiomatic React integration. Bundle: ~100-300kb gzip depending on tree-shaking, offset by canvas rendering win. Recharts (the PROJECT.md suggestion) is SVG-only and will struggle with dense real-time dashboards. |
| Nivo (supplemental) | 0.87+ | Sankey/chord charts for service dependency maps | ECharts is primary; Nivo's Sankey and chord charts are superior for service topology visualizations. Use alongside ECharts — not a replacement. |
| TanStack Query (React Query) | v5 | Server state: metrics data, trace lists, alert rules | Standard for SaaS data fetching. 13KB gzip. Handles polling/refresh for live dashboards via `refetchInterval`. Background sync, deduplication, loading/error states. The correct tool for the query API → component boundary. |
| Zustand | 4.x | Client-side UI state: selected time range, dashboard layout, active filters | Zustand (1.1KB) for client state, TanStack Query for server state. This hybrid is the 2024–2025 community standard for observability dashboard UIs. Redux Toolkit is 13x heavier with no meaningful benefit for this use case. |
| React Router | v6 | Routing | Standard SPA routing; no server-side rendering needed for this product. |
| Tailwind CSS | 3.x | Styling | Low-configuration, utility-first. No strong alternative needed. |
### Layer 7: Kubernetes & Deployment
#### Helm Chart Pattern
| Approach | SigNoz (avoid for ours) | VictoriaMetrics / NewDogRelic (recommended) |
|---|---|---|
| Chart structure | Monolithic chart bundles ClickHouse + ZooKeeper + OTel Collector | Separate chart per component; Operator chart installs CRDs + operator controller |
| Scaling | Helm values for replica counts | Kubernetes Custom Resources (CRDs) consumed by operator — declarative, GitOps-compatible |
| ArgoCD/Flux compatibility | Manual annotations required | Native: `compare-options` and `sync-options` for CRDs |
| Component upgrades | Full chart upgrade required | Per-component CRD update |
| Component | Helm/Operator Source | Notes |
|---|---|---|
| Apache Kafka | `bitnami/kafka` Helm chart | Bitnami charts are Apache 2.0, well-maintained, include Zookeeper/KRaft options. KRaft mode (no ZooKeeper) is production-ready as of Kafka 3.3+ — use it. |
| InfluxDB 3 Core | Custom Helm chart (InfluxData does not publish an operator) | Deploy as a Deployment + PersistentVolume. Use `initContainer` for catalog bootstrap (Postgres). |
| Postgres (catalog) | `bitnami/postgresql` | IOx catalog; also for alert engine state. |
| OTel Collector | `open-telemetry/opentelemetry-collector` Helm chart | Official chart; configure per-signal pipelines. |
| NewDogRelic services | Custom operator (CRD-based) | Define `NewDogRelicCluster` CRD; operator manages component lifecycle, scaling, and config. |
### Layer 8: HIPAA / Security Stack
| Concern | Solution | Notes |
|---|---|---|
| etcd encryption | Kubernetes KMS v2 provider (stable k8s 1.29+) | AES-GCM-256 with externally-held keys. Mandatory: without this, Kubernetes Secrets are base64 only. |
| GitOps secrets (bootstrap) | Bitnami Sealed Secrets | Asymmetric encryption; sealed secrets safe to commit to Git. Used for bootstrap secrets that must exist before the operator runs. |
| Runtime secret management | External Secrets Operator (ESO) + HashiCorp Vault | ESO is the de facto standard for syncing Vault / AWS Secrets Manager / GCP Secret Manager into Kubernetes Secrets. Vault provides audit logs, dynamic secrets, and automatic rotation — required for HIPAA audit trail. |
| PersistentVolume encryption | StorageClass with KMS-backed CSI driver | AWS EBS CSI with KMS CMK, or GCP Persistent Disk with CMEK. Set `encrypted: "true"` on StorageClass. |
| Pod-level secret mounting | Secrets Store CSI Driver | For secrets that must not touch etcd at all. Mount directly from Vault into pod filesystem. |
| TLS everywhere | cert-manager + Let's Encrypt / internal CA | Automate TLS cert rotation for all inter-service and ingest endpoints. |
| PII scrubbing at ingest | OTel Collector `transform` processor | Scrub known PHI attributes (e.g., patient IDs in span attributes) at the Collector layer before Kafka write. Use `replace_match` on attribute keys. |
| Audit logging | Kubernetes audit policy + Vault audit log | K8s API server audit logs (all RBAC decisions), Vault audit logs (all secret access). Ship both to the NewDogRelic log pipeline itself. |
## Alternatives Considered
| Category | Recommended | Alternative | Why Not |
|---|---|---|---|
| Go Kafka client | franz-go | IBM/sarama | Sarama has known idempotent producer correctness issues; can cause data loss |
| Go Kafka client | franz-go | confluent-kafka-go | Requires CGO; breaks static binary builds in containers |
| Go HTTP router | Chi | Fiber | Fiber (fasthttp) has no HTTP/2 server support; incompatible with standard net/http middleware and OTel otelhttp |
| Go HTTP router | Chi | Gin | Gin uses custom context type, complicating OTel instrumentation; 65MB memory vs Chi 52MB under load |
| Data viz | Apache ECharts | Recharts | Recharts is SVG-only; degrades at 10k+ points which is routine for 5M span/s ingest |
| State management | Zustand + TanStack Query | Redux Toolkit | RTK is 13x heavier; no benefit for a small-to-medium team; Zustand selective subscriptions reduce dashboard re-renders by ~40ms |
| PromQL | Reuse `prometheus/prometheus` engine | Rewrite in Rust (GreptimeDB style) | Rewrite takes 2–3 years to reach compliance; `storage.Queryable` interface makes reuse straightforward |
| Kafka schemas | Protobuf (otlp_proto) | Avro + Schema Registry | Avro requires a Schema Registry (extra stateful service); OTLP protos are already the canonical schema source |
| Secrets | External Secrets Operator + Vault | Native K8s Secrets | Native secrets are base64, not encrypted, in etcd; violates HIPAA |
| IOx integration | Sidecar process (HTTP API) | Embedded Rust crate | IOx is not published as an embeddable crate; in-tree `influxdb3_client` has unstable API |
## Installation (Core Go Dependencies)
# Go ingest service
# OTel SDK (if writing internal spans)
# Rust IOx client + DataFusion cold tier
# Frontend
## Open Questions / Phase-Specific Research Flags
| Question | Impact | Suggested Phase |
|---|---|---|
| InfluxDB 3 Core 72h hot-tier limit: does the OSS Core support configurable retention beyond 72h, or is 30d warm tier Enterprise-only? | HIGH — affects warm tier architecture | Phase 1 (storage) |
| IOx 3 Core Kubernetes HA: is there a community Helm chart or operator? Must we write one from scratch? | MEDIUM — affects Phase 1 Helm chart | Phase 1 (k8s) |
| PromQL engine reuse: does `github.com/prometheus/prometheus` promql.Engine work without running a full Prometheus server, or does it require a full Prometheus boot? | HIGH — affects query service design | Phase 2 (query) |
| Thanos Ruler for alert evaluation: can it be deployed standalone against NewDogRelic's PromQL endpoint without a full Thanos deployment? | MEDIUM — affects alert engine architecture | Phase 3 (alerts) |
| Kafka KRaft mode: is bitnami/kafka v3.x stable for KRaft (no ZooKeeper) in production Kubernetes? | LOW — Kafka operational concern | Phase 1 (infra) |
| PII scrubbing completeness: what HIPAA PHI attributes appear in real OTel trace data from common frameworks (Spring, Rails, .NET)? | HIGH — HIPAA compliance | Phase 1 (security) |
## Sources
- [Kafka Go Clients: franz-go vs kafka-go vs Sarama — kafma.app](https://kafma.app/blog/kafka-golang-clients)
- [franz-go GitHub](https://github.com/twmb/franz-go)
- [Confluent Kafka Go Context7 docs](https://pkg.go.dev/github.com/confluentinc/confluent-kafka-go)
- [The Plan for InfluxDB 3 Open Source — InfluxData](https://www.influxdata.com/blog/the-plan-for-influxdb-3-0-open-source/)
- [InfluxDB 3 Core GA announcement — InfluxData](https://www.influxdata.com/blog/influxdata-announces-influxdb-3-OSS-GA/)
- [InfluxDB 3 Core & Enterprise Architecture — InfluxData](https://www.influxdata.com/blog/influxdb3-core-enterprise-architecture/)
- [influxdb3-client crate — docs.rs](https://docs.rs/influxdb3-client/latest/influxdb3_client/)
- [InfluxDB 3 IOx Deep Dive — pipecode.ai](https://pipecode.ai/blogs/influxdb-3-iox-rust-datafusion-parquet)
- [Go Web Frameworks in 2026 — glukhov.org](https://www.glukhov.org/app-architecture/api-architecture/go-web-frameworks-stdlib-chi-gin-echo-fiber/)
- [Fiber docs — Context7 / gofiber/fiber](https://pkg.go.dev/github.com/gofiber/fiber/v2)
- [HTTP servers in Go: stdlib vs chi vs Gin — taqnihub](https://taqnihub.com/blog/production-http-server-go)
- [grpc package — pkg.go.dev](https://pkg.go.dev/google.golang.org/grpc)
- [otelgrpc package — pkg.go.dev](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc)
- [gRPC Best Practices Go SME Guide](https://go.codeguides.io/grpc-protobuf/best-practices/)
- [Prometheus Long-Term Storage 2026 — greptime.com](https://greptime.com/tech-content/2026-06-17-prometheus-long-term-storage-options)
- [Prometheus Interfaces (storage.Queryable) — panos-zamos.github.io](https://panos-zamos.github.io/go/docs/projects/prometheus/interfaces/)
- [PromLabs PromQL Compatibility](https://promlabs.com/blog/2020/11/26/an-update-on-promql-compatibility-across-vendors/)
- [Apache DataFusion External Parquet Indexes — datafusion.apache.org](https://datafusion.apache.org/blog/2025/08/15/external-parquet-indexes/)
- [DataFusion Data Sources — Python docs](https://datafusion.apache.org/python/user-guide/data-sources.html)
- [Airtable archive tier with DataFusion + S3](https://medium.com/airtable-eng/how-we-reduced-archive-storage-costs-by-100x-and-saved-millions-21754b5a6c8e)
- [TimeFusion — observability store on S3 + DataFusion](https://github.com/monoscope-tech/timefusion)
- [kafkaexporter README — opentelemetry-collector-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/kafkaexporter/README.md)
- [OTel Collector Configuration — opentelemetry.io](https://opentelemetry.io/docs/collector/configuration/)
- [Avro vs Protobuf vs JSON for Kafka — risingwave.com](https://risingwave.com/blog/avro-vs-protobuf-vs-json-streaming/)
- [Avro vs Protobuf for Kafka Schema Registry — sivaro.in](https://sivaro.in/articles/avro-vs-protobuf-for-kafka-schema-registry-the-real-world/)
- [Best React chart libraries 2026 — blog.logrocket.com](https://blog.logrocket.com/best-react-chart-libraries-2026/)
- [Recharts vs ECharts vs Nivo — chenguangliang.com](https://chenguangliang.com/en/posts/blog152_react-chart-libraries-comparison/)
- [Zustand vs Redux Toolkit — theroadtoenterprise.com](https://theroadtoenterprise.com/blog/zustand-vs-redux-toolkit)
- [TanStack Query v5 — tanstack.com](https://tanstack.com/query/latest)
- [Building SaaS with TanStack Query — dev.to](https://dev.to/uaslimcreate/building-saas-with-react-and-tanstack-query-a-complete-architecture-guide-203)
- [VictoriaMetrics Kubernetes Operator docs](https://docs.victoriametrics.com/operator/)
- [SigNoz Kubernetes install — signoz.io](https://signoz.io/docs/install/kubernetes/others/)
- [VictoriaMetrics k8s-stack Helm chart](https://docs.victoriametrics.com/helm/victoriametrics-k8s-stack/index.html)
- [Kubernetes HIPAA compliance — thnkbig.com](https://thnkbig.com/blog/hipaa-kubernetes)
- [External Secrets Operator + Vault — external-secrets.io](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [Kubernetes Secrets Security — nhimg.org](https://nhimg.org/kubernetes-secrets-security-guide)
- [AWS EKS data encryption best practices](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html)
- [uber-go/zap vs zerolog — betterstack.com](https://betterstack.com/community/guides/logging/best-golang-logging-libraries/)
- [Dash0 Go logging libraries 2026](https://www.dash0.com/guides/golang-logging-libraries)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
