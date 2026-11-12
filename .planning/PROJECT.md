# NewDogRelic

## What This Is

NewDogRelic is an Apache 2.0 open-source observability platform for enterprise and platform teams who want a self-hostable New Relic alternative. It ingests distributed traces, metrics, logs, and events via OTLP/OTel, stores them across a hot/warm/cold tiered architecture, and surfaces them through a full product UI (dashboards, trace explorer, log search, alert manager, service maps) with PromQL for metrics and SQL for logs/traces. The monetization model is OSS core + NewDogRelic Cloud managed SaaS (similar to Grafana/SigNoz).

## Core Value

A platform/SRE team can instrument any service with an OpenTelemetry SDK, point it at NewDogRelic, and get correlated traces + metrics + logs in a single query interface — self-hosted or cloud — without vendor lock-in.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Multi-signal ingest (traces, metrics, logs) via OTLP/gRPC + OTLP/HTTP
- [ ] Self-hosted Kafka streaming backbone for durable, ordered ingest pipelines
- [ ] Influx IOx (Apache Arrow/DataFusion) as the hot-path columnar storage engine
- [ ] 3-tier retention: 3-day hot (IOx memory+SSD), 30-day warm (compressed segments), unlimited cold (Parquet on S3/GCS)
- [ ] PromQL-compatible API for metrics queries
- [ ] SQL query API (DataFusion/Trino) for logs and cross-signal analytics
- [ ] Tail-based trace sampling with head-based fallback
- [ ] Multi-tenant isolation: per-tenant API keys, rate limits, sharded storage
- [ ] HIPAA-grade security: TLS everywhere, KMS-managed at-rest encryption, attribute scrubbing (PII), full audit logging
- [ ] RBAC: orgs → projects → dashboards/queries/alerts with role-based access
- [ ] Full product UI: dashboards, trace explorer, log search, alert manager, service map
- [ ] Alert engine: rule evaluation, SLO tracking, state machine (OK/WARN/CRIT), notification channels (PagerDuty, Slack, Webhook, Email)
- [ ] Kubernetes-native deployment: Helm chart for self-hosted, Operator for enterprise
- [ ] NewDogRelic Cloud: managed SaaS offering built on the OSS core

### Out of Scope (v1)

- Synthetic monitoring — complex separate domain, defer post-launch
- Browser/mobile RUM — SDK surface area too large for v1
- Continuous profiling — deferred to v2
- Custom gRPC agent protocol — OTLP covers all needed signals
- StatsD/Telegraf legacy protocol — backward compat only, not v1 priority
- ML anomaly detection — deferred, build query layer first

## Context

**Architecture DNA:**
- OTLP/OTel as the canonical ingest protocol; no proprietary agent required
- Streaming backbone: self-hosted Kafka (not MSK/Confluent) — full control, HIPAA-compatible
- Storage: Influx IOx (Rust + Apache Arrow + DataFusion) handles metrics and traces; columnar layout with high compression suits our retention model
- Services: Go for ingest API, alert engine, query orchestration; Rust for hot-path storage engine (via IOx embedding)
- Frontend: React + TypeScript, D3/Recharts for data visualization
- Deployment: Kubernetes-first with Helm chart; Docker Compose for local dev

**Scale targets (design for, not day-1 ops):**
- 5M spans/s, 20M metric samples/s, 2 GB/s logs
- Ingest P95 < 200ms (edge → durable write)
- Query P95 < 1-2s hot, <10s cold
- Durability: ≥3 replicas before ACK; RPO≈0, RTO <15 min

**OSS model:**
- Core platform: Apache 2.0
- NewDogRelic Cloud: closed managed SaaS running the OSS core
- Enterprise self-host: HIPAA-grade customers run via Kubernetes Operator

**Competitive landscape:**
- Closest OSS competitors: SigNoz, Grafana + Tempo/Loki/Mimir stack
- Closed competitors: New Relic, Datadog, Honeycomb
- Differentiator: single-platform (not assembled Grafana stack), Apache Arrow-native query engine, HIPAA from day one

## Constraints

- **Tech Stack**: Go + Rust services; React/TypeScript UI; self-hosted Kafka; Influx IOx — these choices are fixed; no alternatives in planning
- **Protocol**: OTLP/OTel only for ingest; PromQL + SQL for query — no custom wire protocols
- **License**: Apache 2.0 — no GPL/LGPL dependencies in core
- **Compliance**: HIPAA-grade from architecture inception, not bolted on later
- **Retention**: 3d hot / 30d warm / unlimited cold — sizing and flush intervals derive from this
- **Query Language**: PromQL for metrics (SRE familiarity), SQL via DataFusion for logs/traces (unified analytics)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Influx IOx over ClickHouse | Arrow-native, Rust-based, single engine for metrics + traces via DataFusion SQL; avoids JVM overhead | — Pending |
| Self-hosted Kafka over MSK | Full control over partition layout and config, HIPAA-compatible without cloud provider dependency | — Pending |
| PromQL + SQL over custom NRQL | PromQL familiar to SREs (Prometheus migration path); SQL via DataFusion handles cross-signal analytics without a custom DSL | — Pending |
| Go + Rust split | Go handles ingest API/orchestration (fast iteration, strong stdlib); Rust handles hot-path storage engine via IOx embedding (throughput ceiling, memory safety) | — Pending |
| Apache 2.0 + Cloud hosting | OSS core drives adoption, cloud hosting monetizes it without vendor lock-in concerns from customers | — Pending |
| HIPAA from inception | Target enterprise platform teams; retrofitting HIPAA is expensive and architecturally disruptive | — Pending |
| Tail-based sampling primary | Preserves interesting traces (errors, P99 outliers) that head-based would discard; buffering cost justified by insight quality | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-11-12 after initialization*
