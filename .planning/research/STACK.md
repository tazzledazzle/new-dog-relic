# Technology Stack

**Project:** NewDogRelic — Open-Source Observability Platform
**Researched:** 2026-11-12
**Research Mode:** Ecosystem / Validation + Enrichment
**Overall Confidence:** HIGH (most pre-decisions confirmed; IOx embedding pattern is the key caveat)

---

## Pre-Decided Stack (Validated)

The following choices were validated as sound for 2025. Research findings are summarized inline.

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

---

## Recommended Full Stack

### Layer 1: Ingest Pipeline

#### OTLP Receiver (pre-ingest buffer)

**Use OTel Collector Contrib as the edge receiver — do not build a custom OTLP receiver in Go.**

The OpenTelemetry Collector Contrib ships a production-ready OTLP receiver (gRPC port 4317, HTTP port 4318) and a Kafka exporter. Use it as the stateless edge layer that accepts OTLP, applies a `memory_limiter` + `batch` processor, and writes to Kafka topics per signal type.

```yaml
# Canonical OTel Collector pipeline for NewDogRelic
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
  batch:
    send_batch_size: 1000
    timeout: 10s

exporters:
  kafka/traces:
    brokers: ["kafka:9092"]
    traces: { topic: otel-traces, encoding: otlp_proto }
    producer: { compression: snappy, linger: 10ms }
  kafka/metrics:
    brokers: ["kafka:9092"]
    metrics: { topic: otel-metrics, encoding: otlp_proto }
  kafka/logs:
    brokers: ["kafka:9092"]
    logs: { topic: otel-logs, encoding: otlp_proto }
```

Rationale: The OTel Collector is Apache 2.0, battle-tested at scale, and handles backpressure, retries, and schema normalization. Building an equivalent in Go would take months and replicate existing work.

**Confidence: HIGH** — official OTel Collector contrib docs, widely deployed pattern in SigNoz and similar stacks.

---

#### Go Ingest API (Kafka consumers + orchestration)

This is the Go service layer that consumes from Kafka and orchestrates writes to IOx.

| Library | Version | Purpose | Rationale |
|---|---|---|---|
| `github.com/twmb/franz-go` | v1.17+ | Kafka client | Pure Go, 4x faster producing than confluent-kafka-go, 100% KIP feature-complete including KIP-848, zero cgo dependency. Sarama has known idempotent producer correctness issues — do not use. confluent-kafka-go requires cgo, breaking static binary builds. franz-go is the 2024–2025 community consensus choice for new Go projects. |
| `github.com/go-chi/chi/v5` | v5.x | HTTP router (admin/health/query API) | net/http-compatible, zero vendor-lock, standard handler signature. For this project the HTTP API surface (health checks, admin endpoints, query forwarding) is secondary to gRPC; Chi adds routing without custom context types that complicate OTel instrumentation. Fiber is excluded: no HTTP/2 server support (fasthttp limitation), and incompatible with standard net/http middleware including otelhttp. |
| `google.golang.org/grpc` | v1.85.0 | gRPC server for OTLP + internal RPCs | The only production gRPC library for Go. No v2 exists. Use `StatsHandler`-based OTel instrumentation (`otelgrpc.NewServerHandler()`), not deprecated interceptors. |
| `go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc` | v0.72.0 | gRPC OTel instrumentation | Required for trace propagation across gRPC spans. |
| `go.uber.org/zap` | v1.27+ | Structured logging | 51 ns/op, zero allocs on critical paths. zerolog is marginally faster but zap's `zapcore.Core` composability, `AtomicLevel` for runtime log level changes, and `zaptest/observer` for unit testing are production-critical for a multi-tenant platform. |
| `github.com/prometheus/client_golang` | v1.19+ | Prometheus metrics exposition | Standard Prometheus Go client. Expose `/metrics` on each service for self-monitoring via Prometheus scrape. |

**Confidence: HIGH** — franz-go and Chi confirmed via multiple authoritative comparisons and official docs.

---

### Layer 2: Storage Engine (InfluxDB 3 Core / IOx)

#### Critical Architecture Note on IOx Embedding

**IOx is NOT an embeddable Rust crate for a custom application. It is a standalone binary/process.**

InfluxDB 3 Core (the successor to IOx, GA April 2025) is designed as a single-process binary deployed via Docker or Kubernetes. It exposes an HTTP API on port 8181 and a Flight SQL gRPC API. The internal Rust source code is in the InfluxDB monorepo under MIT/Apache 2, but InfluxData does not publish stable embeddable crate APIs — the in-tree `influxdb3_client` crate is explicitly marked as having an unstable API used only for CLI tooling and integration tests.

**Deployment pattern: Run InfluxDB 3 Core as a sidecar or dedicated pod in Kubernetes. The Go ingest service writes to it via its HTTP write API (line protocol) or the official Rust client crate for internal Rust services.**

This is not a risk — it simplifies the architecture by removing the need for a custom Rust service wrapping IOx. The "Rust for hot-path" decision holds because IOx *is* written in Rust and NewDogRelic benefits from that without needing to write Rust code for storage.

| Component | Integration Method | Notes |
|---|---|---|
| InfluxDB 3 Core (hot tier, 0–72h) | HTTP write API (line protocol) on :8181 + Flight SQL query | Single-process binary; deploy as Kubernetes pod. MIT/Apache 2 licensed. |
| InfluxDB 3 Core Rust client | `influxdb3-client` crate (crates.io) | For any Rust code that needs to write/query IOx — requires Rust 1.89+. Official crate, async. |
| IOx → Parquet flush | Automatic (built-in compactor) | IOx flushes WAL→Parquet→object store automatically. Configure flush interval and object store endpoint. |
| Warm tier (30d) | IOx with extended retention config | IOx supports configurable TTL windows; Enterprise adds historical query. For OSS Core + 30d warm, run a separate compaction-aware IOx instance or add a Postgres catalog + custom compactor derived from the open source IOx compactor service. |

**Confidence: MEDIUM** — IOx 3 Core GA confirmed at April 2025. The 72h "recent data" limit for free-tier Core is a confirmed architectural constraint (source: official InfluxData blog). The warm tier (30d) may require InfluxDB 3 Enterprise or a custom compactor derived from the open-source IOx ingester/compactor code. This needs phase-specific research.

---

### Layer 3: Cold Tier (Parquet on S3)

| Component | Technology | Rationale |
|---|---|---|
| Object store | AWS S3 / S3-compatible (MinIO for self-hosted) | Standard. DataFusion's `object_store` crate natively supports S3 via `AmazonS3Builder`. MinIO is the standard on-prem S3-compatible store for Kubernetes. |
| Query engine | Apache DataFusion (`datafusion` + `object_store` crates) | IOx already uses DataFusion internally. For the custom cold-tier querier, use DataFusion directly in a Rust query service. Supports `CREATE EXTERNAL TABLE ... STORED AS PARQUET LOCATION 's3://...'` with predicate pushdown, row-group pruning (`datafusion.execution.parquet.pruning = true`), and page-index pruning. |
| Partitioning scheme | `s3://{bucket}/signals/{tenant_id}/{signal_type}/{year}/{month}/{day}/{hour}/` | Hive-style partitioning. DataFusion's `ListingTable` applies partition pruning at the directory level before reading any files, essential at cold-tier latency targets. |
| Parquet metadata caching | `CachedParquetFileReaderFactory` (DataFusion) | Avoids per-query S3 metadata re-reads. Implement using `ParquetObjectReader` + a TTL cache over the row-group metadata bytes. |
| Postgres catalog | PostgreSQL (for partition-to-file mapping) | Standard IOx pattern: a lightweight Postgres catalog holds file-level metadata (min/max timestamps, tenant ID, partition key) so queries skip S3 `ListObjects` entirely. |

**Confidence: HIGH** — DataFusion object_store S3 integration is well-documented with official crate support. IOx uses this exact pattern (confirmed via InfluxDB 3 deep-dive).

---

### Layer 4: Query APIs

#### PromQL (Metrics)

**Do NOT rewrite the PromQL engine. Reuse Prometheus's engine via the `storage.Queryable` interface.**

The Prometheus storage subsystem decouples the PromQL engine from storage via a single-method interface in `github.com/prometheus/prometheus/storage`. Thanos, Mimir, Cortex, and VictoriaMetrics all reuse this engine by implementing `Queryable`. This is the established pattern — the only teams that rewrite PromQL (GreptimeDB, VictoriaMetrics MetricsQL) have dedicated eng resources and still take 2–3 years to reach high compliance.

```
// The seam: implement this interface over your IOx metric store
type Queryable interface {
    Querier(mint, maxt int64) (Querier, error)
}
```

| Component | Library | Notes |
|---|---|---|
| PromQL engine | `github.com/prometheus/prometheus/promql` | Reuse directly. Apache 2.0 licensed. Implements the query engine over any `storage.Queryable`. |
| Remote Write receiver | Implement `/api/v1/write` endpoint | Accept Prometheus remote_write protobuf, parse, write to IOx via line protocol. Needed for Prometheus scrape → NewDogRelic migration path. |
| Remote Read endpoint | Optional — `/api/v1/read` | Allows Prometheus itself to proxy queries to NewDogRelic for mixed deployments. Low priority; most users query NewDogRelic directly. |
| PromQL compliance testing | PromLabs compliance suite | Run against the query API before GA. This is table stakes for marketing as "PromQL compatible." |

**Confidence: HIGH** — Prometheus storage.Queryable interface and engine reuse is a well-established pattern with multiple major implementations.

---

#### SQL for Logs/Traces (DataFusion)

The Go query orchestration service translates incoming SQL queries to DataFusion execution plans via the Flight SQL protocol. For hot-tier data in IOx, forward SQL directly to IOx's Flight SQL endpoint. For cold-tier data in S3, execute via the Rust DataFusion query service.

| Component | Technology | Notes |
|---|---|---|
| Hot-tier SQL | IOx Flight SQL (port 8183) | IOx exposes Arrow Flight + SQL natively. Query via `arrow-flight` Go client. |
| Cold-tier SQL | DataFusion Rust service with `object_store` crate | Custom service: register S3 as `ObjectStore`, register Parquet partitions as external tables, execute SQL, return Arrow batches via Flight. |
| Cross-tier fan-out | Go query orchestrator | Go service fans out queries to hot (IOx) + cold (DataFusion) tiers, merges Arrow results, returns unified response. |
| Wire protocol to frontend | Arrow Flight SQL | Use Flight SQL as the internal query protocol; translate to JSON/REST at the API gateway for the browser client. |

**Confidence: HIGH**

---

### Layer 5: Kafka Schema Format

**Recommendation: Protobuf (otlp_proto encoding), not Avro.**

Rationale:
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

**Confidence: HIGH** — The OTel Collector Kafka exporter uses `otlp_proto` as default; Protobuf is the native format of OTel signals.

---

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

**Confidence: HIGH** — ECharts canvas rendering advantage confirmed by multiple benchmarks. TanStack Query v5 + Zustand combo confirmed as 2024–2025 standard for SaaS dashboards.

---

### Layer 7: Kubernetes & Deployment

#### Helm Chart Pattern

Follow the VictoriaMetrics operator pattern, not the SigNoz bundled-chart pattern:

| Approach | SigNoz (avoid for ours) | VictoriaMetrics / NewDogRelic (recommended) |
|---|---|---|
| Chart structure | Monolithic chart bundles ClickHouse + ZooKeeper + OTel Collector | Separate chart per component; Operator chart installs CRDs + operator controller |
| Scaling | Helm values for replica counts | Kubernetes Custom Resources (CRDs) consumed by operator — declarative, GitOps-compatible |
| ArgoCD/Flux compatibility | Manual annotations required | Native: `compare-options` and `sync-options` for CRDs |
| Component upgrades | Full chart upgrade required | Per-component CRD update |

**Recommended chart structure:**
```
charts/
  newdogrelic-operator/   # Installs CRDs + operator controller
  newdogrelic-core/       # Installs the core stack using CRs (consumed by operator)
  newdogrelic-stack/      # Umbrella chart: wraps core + kafka + influxdb3 for quick-start
```

| Component | Helm/Operator Source | Notes |
|---|---|---|
| Apache Kafka | `bitnami/kafka` Helm chart | Bitnami charts are Apache 2.0, well-maintained, include Zookeeper/KRaft options. KRaft mode (no ZooKeeper) is production-ready as of Kafka 3.3+ — use it. |
| InfluxDB 3 Core | Custom Helm chart (InfluxData does not publish an operator) | Deploy as a Deployment + PersistentVolume. Use `initContainer` for catalog bootstrap (Postgres). |
| Postgres (catalog) | `bitnami/postgresql` | IOx catalog; also for alert engine state. |
| OTel Collector | `open-telemetry/opentelemetry-collector` Helm chart | Official chart; configure per-signal pipelines. |
| NewDogRelic services | Custom operator (CRD-based) | Define `NewDogRelicCluster` CRD; operator manages component lifecycle, scaling, and config. |

**Confidence: MEDIUM** — VictoriaMetrics operator pattern is well-documented. InfluxDB 3 Core has no official Helm chart or Kubernetes operator yet (confirmed: GA April 2025, operator not yet published). Custom chart required.

---

### Layer 8: HIPAA / Security Stack

**Encryption at Rest (etcd)**

```
API Server EncryptionConfiguration:
  - aescbc/aesgcm: dev/test only
  - kms (v2, stable since K8s 1.29): production / HIPAA
    Provider: AWS KMS / GCP KMS / Azure Key Vault
```

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

**Confidence: HIGH** — KMS v2, ESO, and Vault pattern confirmed by multiple authoritative Kubernetes HIPAA compliance sources and official docs.

---

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

---

## Installation (Core Go Dependencies)

```bash
# Go ingest service
go get github.com/twmb/franz-go@v1.17.1
go get github.com/go-chi/chi/v5@v5.1.0
go get google.golang.org/grpc@v1.85.0
go get go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc@v0.72.0
go get go.uber.org/zap@v1.27.0
go get github.com/prometheus/prometheus@v0.300.0  # for storage.Queryable + promql.Engine
go get github.com/prometheus/client_golang/prometheus@v1.19.0
go get google.golang.org/protobuf@v1.34.0

# OTel SDK (if writing internal spans)
go get go.opentelemetry.io/otel@v1.33.0
go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@v1.33.0
```

```bash
# Rust IOx client + DataFusion cold tier
cargo add influxdb3-client          # Official InfluxDB 3 Rust client
cargo add datafusion                # Apache DataFusion
cargo add object_store --features aws  # S3 object store
cargo add arrow                     # Apache Arrow for record batches
cargo add arrow-flight              # Flight SQL protocol
cargo add tokio --features full     # Async runtime
cargo add prost                     # Protobuf for OTel protos
```

```bash
# Frontend
npm install echarts echarts-for-react
npm install @tanstack/react-query@^5
npm install zustand@^4
npm install react-router-dom@^6
npm install -D @types/react @typescript-eslint/eslint-plugin
```

---

## Open Questions / Phase-Specific Research Flags

| Question | Impact | Suggested Phase |
|---|---|---|
| InfluxDB 3 Core 72h hot-tier limit: does the OSS Core support configurable retention beyond 72h, or is 30d warm tier Enterprise-only? | HIGH — affects warm tier architecture | Phase 1 (storage) |
| IOx 3 Core Kubernetes HA: is there a community Helm chart or operator? Must we write one from scratch? | MEDIUM — affects Phase 1 Helm chart | Phase 1 (k8s) |
| PromQL engine reuse: does `github.com/prometheus/prometheus` promql.Engine work without running a full Prometheus server, or does it require a full Prometheus boot? | HIGH — affects query service design | Phase 2 (query) |
| Thanos Ruler for alert evaluation: can it be deployed standalone against NewDogRelic's PromQL endpoint without a full Thanos deployment? | MEDIUM — affects alert engine architecture | Phase 3 (alerts) |
| Kafka KRaft mode: is bitnami/kafka v3.x stable for KRaft (no ZooKeeper) in production Kubernetes? | LOW — Kafka operational concern | Phase 1 (infra) |
| PII scrubbing completeness: what HIPAA PHI attributes appear in real OTel trace data from common frameworks (Spring, Rails, .NET)? | HIGH — HIPAA compliance | Phase 1 (security) |

---

## Sources

**Go Kafka Clients:**
- [Kafka Go Clients: franz-go vs kafka-go vs Sarama — kafma.app](https://kafma.app/blog/kafka-golang-clients)
- [franz-go GitHub](https://github.com/twmb/franz-go)
- [Confluent Kafka Go Context7 docs](https://pkg.go.dev/github.com/confluentinc/confluent-kafka-go)

**InfluxDB IOx / 3 Core:**
- [The Plan for InfluxDB 3 Open Source — InfluxData](https://www.influxdata.com/blog/the-plan-for-influxdb-3-0-open-source/)
- [InfluxDB 3 Core GA announcement — InfluxData](https://www.influxdata.com/blog/influxdata-announces-influxdb-3-OSS-GA/)
- [InfluxDB 3 Core & Enterprise Architecture — InfluxData](https://www.influxdata.com/blog/influxdb3-core-enterprise-architecture/)
- [influxdb3-client crate — docs.rs](https://docs.rs/influxdb3-client/latest/influxdb3_client/)
- [InfluxDB 3 IOx Deep Dive — pipecode.ai](https://pipecode.ai/blogs/influxdb-3-iox-rust-datafusion-parquet)

**Go HTTP Frameworks:**
- [Go Web Frameworks in 2026 — glukhov.org](https://www.glukhov.org/app-architecture/api-architecture/go-web-frameworks-stdlib-chi-gin-echo-fiber/)
- [Fiber docs — Context7 / gofiber/fiber](https://pkg.go.dev/github.com/gofiber/fiber/v2)
- [HTTP servers in Go: stdlib vs chi vs Gin — taqnihub](https://taqnihub.com/blog/production-http-server-go)

**gRPC + OTel:**
- [grpc package — pkg.go.dev](https://pkg.go.dev/google.golang.org/grpc)
- [otelgrpc package — pkg.go.dev](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc)
- [gRPC Best Practices Go SME Guide](https://go.codeguides.io/grpc-protobuf/best-practices/)

**PromQL / Prometheus Remote Storage:**
- [Prometheus Long-Term Storage 2026 — greptime.com](https://greptime.com/tech-content/2026-06-17-prometheus-long-term-storage-options)
- [Prometheus Interfaces (storage.Queryable) — panos-zamos.github.io](https://panos-zamos.github.io/go/docs/projects/prometheus/interfaces/)
- [PromLabs PromQL Compatibility](https://promlabs.com/blog/2020/11/26/an-update-on-promql-compatibility-across-vendors/)

**DataFusion + S3:**
- [Apache DataFusion External Parquet Indexes — datafusion.apache.org](https://datafusion.apache.org/blog/2025/08/15/external-parquet-indexes/)
- [DataFusion Data Sources — Python docs](https://datafusion.apache.org/python/user-guide/data-sources.html)
- [Airtable archive tier with DataFusion + S3](https://medium.com/airtable-eng/how-we-reduced-archive-storage-costs-by-100x-and-saved-millions-21754b5a6c8e)
- [TimeFusion — observability store on S3 + DataFusion](https://github.com/monoscope-tech/timefusion)

**OTel Collector Kafka Exporter:**
- [kafkaexporter README — opentelemetry-collector-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/kafkaexporter/README.md)
- [OTel Collector Configuration — opentelemetry.io](https://opentelemetry.io/docs/collector/configuration/)

**Kafka Schema (Protobuf vs Avro):**
- [Avro vs Protobuf vs JSON for Kafka — risingwave.com](https://risingwave.com/blog/avro-vs-protobuf-vs-json-streaming/)
- [Avro vs Protobuf for Kafka Schema Registry — sivaro.in](https://sivaro.in/articles/avro-vs-protobuf-for-kafka-schema-registry-the-real-world/)

**React Charting:**
- [Best React chart libraries 2026 — blog.logrocket.com](https://blog.logrocket.com/best-react-chart-libraries-2026/)
- [Recharts vs ECharts vs Nivo — chenguangliang.com](https://chenguangliang.com/en/posts/blog152_react-chart-libraries-comparison/)

**React State Management:**
- [Zustand vs Redux Toolkit — theroadtoenterprise.com](https://theroadtoenterprise.com/blog/zustand-vs-redux-toolkit)
- [TanStack Query v5 — tanstack.com](https://tanstack.com/query/latest)
- [Building SaaS with TanStack Query — dev.to](https://dev.to/uaslimcreate/building-saas-with-react-and-tanstack-query-a-complete-architecture-guide-203)

**SigNoz / VictoriaMetrics Kubernetes Patterns:**
- [VictoriaMetrics Kubernetes Operator docs](https://docs.victoriametrics.com/operator/)
- [SigNoz Kubernetes install — signoz.io](https://signoz.io/docs/install/kubernetes/others/)
- [VictoriaMetrics k8s-stack Helm chart](https://docs.victoriametrics.com/helm/victoriametrics-k8s-stack/index.html)

**HIPAA / Kubernetes Security:**
- [Kubernetes HIPAA compliance — thnkbig.com](https://thnkbig.com/blog/hipaa-kubernetes)
- [External Secrets Operator + Vault — external-secrets.io](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [Kubernetes Secrets Security — nhimg.org](https://nhimg.org/kubernetes-secrets-security-guide)
- [AWS EKS data encryption best practices](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html)

**Go Logging:**
- [uber-go/zap vs zerolog — betterstack.com](https://betterstack.com/community/guides/logging/best-golang-logging-libraries/)
- [Dash0 Go logging libraries 2026](https://www.dash0.com/guides/golang-logging-libraries)
