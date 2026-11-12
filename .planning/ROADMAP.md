# Roadmap: NewDogRelic

## Overview

NewDogRelic is built infrastructure-first, write-path-second, read-path-third, and product-surface-last. The dependency chain is strict and driven by one-way-door decisions: Kafka partition keying, IOx namespace layout, S3 cold-tier partition scheme, and HIPAA dual-stream must be locked in before a single byte of external data flows. From that foundation, stateless ETL (metrics + logs) proves the write path before stateful trace tail-sampling is introduced. The query layer validates against real data volumes before the alert engine consumes it. All UI surfaces are built as a composition layer once backend APIs have stabilized. Production hardening and cloud deployment close the milestone on a system that is known to work correctly.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Infrastructure Substrate** - Kafka KRaft + IOx + Postgres + object store + HIPAA dual-stream — one-way-door decisions locked before any data flows
- [ ] **Phase 2: Ingest Pipeline (Metrics + Logs)** - Stateless ETL from OTLP → Kafka → IOx; cardinality enforcement; backpressure; PII scrubbing; tenant API keys
- [ ] **Phase 3: Trace Pipeline + Tail Sampling** - Two-tier OTel Collector topology; Pebble-backed span buffer; head-based fallback; service-edge precomputation
- [ ] **Phase 4: Query Layer + Full Auth/RBAC** - PromQL + SQL APIs; hot+cold DataFusion UnionExec; RBAC enforcement; SSO; HIPAA audit log wired through query path
- [ ] **Phase 5: Alert Engine + Service Map + Trace Explorer** - Rule evaluation; SLO burn-rate; alert state machine; notification dispatch; service map topology; trace search and waterfall
- [ ] **Phase 6: Product UI** - React + ECharts frontend: dashboards, trace explorer, log search, service map, alert manager — composition layer over stable backend APIs
- [ ] **Phase 7: Hardening, Helm Chart, and Cloud Deployment** - Production Helm chart; autoscaling; self-observability pipeline; NewDogRelic Cloud managed SaaS

## Phase Details

### Phase 1: Infrastructure Substrate
**Goal**: All runtime substrates are deployed and topology decisions are permanently locked — Kafka partition layout, IOx namespace scheme, S3 cold-tier partition path, and HIPAA dual audit stream — before any external data is accepted
**Depends on**: Nothing (first phase)
**Requirements**: STORE-01, STORE-02, STORE-03, OPS-02
**Success Criteria** (what must be TRUE):
  1. A local Docker Compose environment starts all infrastructure components (Kafka KRaft, IOx, Postgres, MinIO) with a single `docker compose up` command and passes a smoke test suite within 5 minutes
  2. Kafka has three signal-scoped topics (`ndr.metrics.raw`, `ndr.logs.raw`, `ndr.traces.raw`) with 48 partitions each, RF=3, and `tenant_id` as the partition key — confirmed by a partition-assignment verification test
  3. IOx accepts line-protocol writes on port 8181 and retains data queryable via its HTTP query endpoint; the 72h OSS retention boundary is validated and the warm-tier strategy (OSS extended config vs. Enterprise) is documented as a resolved architectural decision
  4. Cold-tier S3 partition scheme (`tenant_id/signal_type/dt=YYYY-MM-DD/`) is active and a test Parquet file written to MinIO is retrievable via the partition path
  5. A separate HIPAA audit Kafka topic (`ndr.audit`) with an independent consumer group exists, routes to an S3 Object Lock bucket (WORM), and is confirmed isolated from the observability data path
**Plans**: TBD

### Phase 2: Ingest Pipeline (Metrics + Logs)
**Goal**: Operators and service teams can send metrics and logs to NewDogRelic via OTLP; data flows end-to-end from OTel Collector through Kafka to IOx; PII is scrubbed at the edge; per-tenant API keys and cardinality caps are enforced at the write gate
**Depends on**: Phase 1
**Requirements**: INGEST-01, INGEST-02, INGEST-03, INGEST-04, INGEST-05, STORE-04, AUTH-01
**Success Criteria** (what must be TRUE):
  1. A service instrumented with any OpenTelemetry SDK can send metrics and logs to NewDogRelic via both OTLP/gRPC and OTLP/HTTP (protobuf + JSON), and the data appears queryable in IOx within 10 seconds
  2. An operator can deploy an OTel Collector DaemonSet (node-level) feeding a centralized gateway Deployment; the gateway applies an attribute allowlist transform processor that strips non-allowlisted fields before forwarding to Kafka — verified by injecting a PII attribute and confirming it does not appear in IOx
  3. A tenant that exceeds its configured series cardinality cap receives a 429 response with a tenant-specific error message; data stops flowing to that tenant's IOx namespace until the cap is lowered
  4. When IOx write latency exceeds the configured threshold, Kafka consumers pause affected partitions and the ingest API returns 503 to callers; when latency recovers, consumers resume automatically
  5. An operator can create an organization and generate scoped API keys for ingest endpoints; requests without a valid key are rejected with 401
**Plans**: TBD

### Phase 3: Trace Pipeline + Tail Sampling
**Goal**: Distributed traces flow through a two-tier OTel Collector topology with trace-affinity routing; the tail sampler retains traces containing errors or P99+ latency spans and discards the rest; head-based sampling is available as a fallback; service dependency edges are precomputed into Postgres
**Depends on**: Phase 2
**Requirements**: TRACE-01, TRACE-02, TRACE-03
**Success Criteria** (what must be TRUE):
  1. All spans of a single trace are routed to the same tail-sampler gateway instance via `loadbalancingexporter` with `routing_key: traceID` — verified by injecting a multi-span trace and confirming all spans land on a single gateway pod
  2. A trace containing at least one error span is retained in IOx after the `decision_wait` TTL; a trace with no errors and sub-P99 latency is discarded — verified by the sampling policy test suite
  3. Services can configure a head-based sampling rate as a fallback; traces sampled at the head-based rate appear in IOx regardless of tail-sampler state
  4. The Postgres `service_edges` table is populated with upstream/downstream service pairs derived from OTel Collector servicegraph connector within 60 seconds of a trace being ingested
**Plans**: TBD

### Phase 4: Query Layer + Full Auth/RBAC
**Goal**: SREs can query metrics via PromQL and operators can run SQL against logs and traces; queries transparently span the hot and cold tiers; RBAC enforces org/project/role boundaries on all query access; SSO is available in the OSS tier; all data access events are written to the HIPAA audit log
**Depends on**: Phase 3
**Requirements**: QUERY-01, QUERY-02, QUERY-03, QUERY-04, AUTH-02, AUTH-03, AUTH-04
**Success Criteria** (what must be TRUE):
  1. A PromQL query against the metrics API returns correct results consistent with the PromLabs compliance suite; the query endpoint implements `prometheus/prometheus storage.Queryable` and does not require a running Prometheus server
  2. A SQL query against the logs or traces API spans data in both the hot tier (IOx) and cold tier (S3 Parquet) transparently via DataFusion UnionExec — the caller receives a single merged result set without specifying tier selection
  3. A tenant that exceeds its per-tenant query QPS limit receives HTTP 429; queries from other tenants continue unaffected — verified with a concurrent load test across two tenants
  4. An RBAC Viewer role can read dashboards and run queries but cannot create or delete alert rules; an Owner role can manage all resources within their org — enforced at the Query Orchestrator middleware layer
  5. All data read and write events appear in the `ndr.audit` Kafka topic with tamper-evident checksums; a 6-year cold-tier retention policy is active on the audit S3 bucket
**Plans**: TBD
**UI hint**: yes

### Phase 5: Alert Engine + Service Map + Trace Explorer
**Goal**: SREs can define alert rules (PromQL and SQL), track SLO burn rates, receive notifications via PagerDuty/Slack/Webhook/Email, and explore the service topology with per-edge health metrics; trace search and waterfall view are available via the backend explorer API
**Depends on**: Phase 4
**Requirements**: ALERT-01, ALERT-02, ALERT-03, ALERT-04, TRACE-04
**Success Criteria** (what must be TRUE):
  1. A user can create a PromQL-based alert rule with a configurable evaluation interval and threshold; the alert transitions OK → PENDING → FIRING → RESOLVED as the threshold is crossed and cleared — verified against the state machine test suite
  2. An SLO burn-rate alert fires when the multi-window (5m + 1h) error budget consumption rate indicates an imminent SLO breach; the alert resolves when the burn rate recovers below the threshold
  3. Alert notifications are delivered to at least one of PagerDuty, Slack, Webhook, or Email within 60 seconds of an alert entering FIRING state; duplicate alerts for the same fingerprint are suppressed by the deduplication logic
  4. The service map API returns a graph of service-to-service edges with per-edge request rate, error rate, and P50/P99 latency derived from the precomputed `service_edges` table — data refreshes within 60 seconds of new trace data flowing
  5. A user can search traces by service name, endpoint, status code, duration range, and arbitrary span attributes via the trace explorer API; results include span waterfall data sufficient to render a flamegraph
**Plans**: TBD

### Phase 6: Product UI
**Goal**: Users can interact with all platform capabilities through a React-based product UI: composing dashboards, exploring traces and logs, navigating the service map, managing alert rules, and reviewing alert history
**Depends on**: Phase 5
**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05
**Success Criteria** (what must be TRUE):
  1. A user can compose a dashboard by dragging PromQL time-series panels and SQL table/stat/heatmap panels onto a canvas; the layout persists across sessions
  2. A user can search and filter traces in the trace explorer, click into a trace result, and view an interactive span waterfall with correlated metrics and logs for the same time window in a single screen
  3. A user can run full-text log searches with faceted filtering on `level`, `service`, `trace_id`, and arbitrary key/value attributes; results update as filter criteria change
  4. A user can author an alert rule, view alert history with state transitions (OK/PENDING/FIRING/RESOLVED), and configure notification channels — all without leaving the alert manager UI
  5. The service map renders an interactive topology graph with per-edge request rate, error rate, and P50/P99 overlays; a user can click any node and navigate to upstream/downstream dependencies
**Plans**: TBD
**UI hint**: yes

### Phase 7: Hardening, Helm Chart, and Cloud Deployment
**Goal**: NewDogRelic ships a production-grade Kubernetes Helm chart for self-hosted enterprise deployment; autoscaling responds to load; the self-observability pipeline surfaces internal health metrics; NewDogRelic Cloud accepts managed SaaS customer onboarding
**Depends on**: Phase 6
**Requirements**: OPS-01, OPS-03, OPS-04
**Success Criteria** (what must be TRUE):
  1. An enterprise customer can install NewDogRelic in their own Kubernetes cluster using `helm install newdogrelic newdogrelic/newdogrelic-stack` and have all services running and ingest-ready within 15 minutes, following the HIPAA self-host deployment guide
  2. ETL worker replica counts scale up automatically when Kafka consumer lag exceeds the configured threshold and scale down when lag clears — verified with a synthetic ingest spike test
  3. Internal metrics (ingest lag, queue depth, dropped batches, IOx compactor status) are visible in a dedicated ops dashboard under the internal observability tenant; a self-observability alert fires when compactor uncompacted file count exceeds 1000
  4. A NewDogRelic Cloud customer can create an account, receive cloud ingest endpoint credentials, point their OTel Collector at the cloud endpoint, and see their first metrics appear in the managed UI within 10 minutes
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Infrastructure Substrate | 2/3 | In Progress|  |
| 2. Ingest Pipeline (Metrics + Logs) | 0/TBD | Not started | - |
| 3. Trace Pipeline + Tail Sampling | 0/TBD | Not started | - |
| 4. Query Layer + Full Auth/RBAC | 0/TBD | Not started | - |
| 5. Alert Engine + Service Map + Trace Explorer | 0/TBD | Not started | - |
| 6. Product UI | 0/TBD | Not started | - |
| 7. Hardening, Helm Chart, and Cloud Deployment | 0/TBD | Not started | - |
