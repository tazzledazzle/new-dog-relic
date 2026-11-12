# Feature Landscape

**Domain:** APM / Observability Platform (New Relic alternative, OSS + SaaS)
**Researched:** 2026-11-12
**Research Mode:** Ecosystem

---

## Research Scope Answered

This file addresses all eight research questions:

1. Table stakes in 2025 across New Relic, Datadog, Honeycomb, SigNoz, Grafana
2. Features that cause teams to switch away from New Relic
3. Features not delivered by OSS alternatives (SigNoz, Grafana stack)
4. HIPAA-grade observability compliance non-negotiables
5. Onboarding / first-run experience table stakes
6. Alert engine: MVA vs. differentiator
7. Service map / dependency graph positioning
8. Browser/mobile RUM and synthetic monitoring expectations (v2 scope)

---

## Table Stakes

Features users expect. Missing = product feels incomplete or uncompetitive.

### Signal Ingest and Storage

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Traces ingestion via OTLP/gRPC + HTTP | OTLP is the de facto standard; every major SDK supports it | Medium | Already planned; no proprietary agent required |
| Metrics ingestion via OTLP | Replaces Prometheus push; complements scrape | Medium | Same pipeline as traces |
| Logs ingestion via OTLP | Closes the third pillar; prevents use of a separate log shipper | Medium | Structured logs critical for SQL query layer |
| Multi-signal correlation by trace ID | Users must jump trace → logs → metrics in one click without losing context | High | The single hardest UX problem in observability; directly differentiates from Grafana stack |
| Hot/warm/cold tiered retention | Cost-sensitive users will not pay per GB indefinitely; self-hosters need control | High | 3d/30d/unlimited already defined in PROJECT.md |
| OpenTelemetry Collector compatibility | The Collector is the standard fan-out/buffering layer; not supporting it blocks adoption | Low | Passive — just accept OTLP; Collector routes to us |

### Query and Analytics

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| PromQL-compatible metrics query API | SRE teams know PromQL; it is the migration path from Prometheus; absence is a dealbreaker for SRE buyers | High | Already planned |
| SQL query API for logs and traces | NRQL lock-in is the top reason teams leave New Relic; SQL is portable and familiar | High | DataFusion already chosen |
| Trace search and filter (trace explorer) | Cannot use a tracing platform that cannot query traces; minimum: filter by service, status, duration, trace ID, span attributes | Medium | Core UI surface |
| Log search with full-text and structured field filtering | Logs without search are useless; must support both free-text and field-level predicates | Medium | Core UI surface |
| Metrics graphing with time-range selection | Every monitoring tool since Nagios has had this; absence is disqualifying | Low | Dashboards subsystem |

### Dashboards and Visualization

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Custom dashboards with panel layout | Users build org-specific views; without this, the platform is a read-only product | Medium | React + Recharts/D3 already in stack |
| Out-of-box default dashboards (RED metrics per service) | Users who connect a service expect to see something immediately; empty UI on first run kills evaluation | Medium | Auto-generated from service topology; critical for onboarding |
| Time-range picker and dashboard variables | Cannot use a dashboard that cannot be parameterized by environment/service/time | Low | Standard UI component |
| Panel types: time-series, table, stat, top-list | Cover 95% of observability use cases | Low | Standard charting primitives |

### Alerting

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Threshold-based metric alerts | The simplest form; every platform has it | Low | Baseline alerting |
| Multi-window burn-rate SLO alerts | Google SRE Workbook standard; SRE buyers specifically look for this | Medium | Requires SLO definition model |
| Alert state machine (OK / WARN / CRIT) | Expected since Nagios; absence signals product immaturity | Low | Already in PROJECT.md |
| Deduplication and alert grouping | Without this, an outage produces N alerts per service; alert fatigue kills adoption | Medium | Critical for on-call UX |
| Notification channels: PagerDuty, Slack, Webhook, Email | These four cover 95%+ of on-call workflows | Low | Already in PROJECT.md |
| Alert history / timeline | Users need to know when an alert fired, resolved, and re-fired; absence makes post-mortems impossible | Low | Audit and compliance also benefit |

### Access Control and Multi-Tenancy

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| API key auth per org/project | Required to separate tenants; absence is a security failure | Low | Already in PROJECT.md |
| Role-based access control (Viewer / Editor / Admin) | Enterprise buyers will not onboard without it | Medium | Org → Project → Resource hierarchy |
| Per-tenant rate limiting and resource quotas | Multi-tenant SaaS without quotas becomes a noisy-neighbor problem | Medium | Required for Cloud tier |
| Data isolation between tenants | Cross-tenant query must be impossible by construction, not configuration | High | Schema-level or shard-level separation |

### Service Map

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Auto-generated service dependency graph from trace data | Service maps are table stakes in 2025; every New Relic, Datadog, Honeycomb, SigNoz user expects one | Medium | Derived from span relationships; no additional instrumentation |
| Node health status overlaid on map (error rate, latency) | A service map without health status is a static diagram; must show live state | Medium | Integrates alert/SLO state |
| Clickthrough from service node to traces/logs | The map is navigation, not just visualization; must be interactive | Low | Deep link to trace explorer |

---

## Differentiators

Features that cause teams to choose NewDogRelic over alternatives or stay when they otherwise would not.

### Switching Triggers from New Relic / Datadog

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Predictable, transparent pricing (no per-seat + per-GB surprise billing) | The #1 reason teams leave New Relic and Datadog; both use multi-dimensional billing that produces quarterly surprises | Low (business model, not engineering) | OSS self-hosted = free; Cloud = flat or volume-tiered pricing; communicate pricing model clearly on day one |
| Data ownership / self-hosted option | Datadog is SaaS-only; New Relic has weak self-host story; enterprise platform teams with data-residency requirements have no good option | High | Self-hosted Kubernetes Helm chart already planned |
| No proprietary query language lock-in | NRQL makes every dashboard and alert non-portable; PromQL + SQL keeps portability | Medium | Already designed; needs to be communicated as a migration benefit |
| HIPAA-grade self-hosted option from day one | Healthcare/fintech platform teams need HIPAA; Grafana gates SSO/RBAC behind Enterprise; SigNoz has no audit logs yet | High | See HIPAA section below; this is a genuine market gap |
| Single-platform multi-signal (not assembled Grafana stack) | Grafana LGTM requires operating 4 distributed systems and 3 query languages; NewDogRelic is a single binary deployment story | High | The core product thesis |
| Apache 2.0 license (not BSL, not SSPL, not open-core with gated enterprise features) | SigNoz gates RBAC behind paid tiers; Grafana Enterprise gates SSO/SAML; Apache 2.0 builds trust with self-hosters | Low (licensing decision already made) | Communicate explicitly; competitors' licensing has become a pain point |

### Technical Differentiators vs. OSS Alternatives

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Tail-based trace sampling with configurable rules | Head-based sampling (SigNoz default) discards interesting traces; tail-based preserves errors, P99 outliers, slow traces | High | Already in PROJECT.md; Honeycomb Refinery does this; a meaningful gap vs. SigNoz |
| Cross-signal SQL analytics (JOIN traces + metrics + logs in one query) | Grafana requires 3 query languages to do what one DataFusion SQL query does; huge debugging DX improvement | High | DataFusion already chosen; needs query builder UI surface |
| Column-native storage with high compression (Arrow/Parquet) | Lower storage cost at scale vs. ClickHouse row-oriented; important for self-hosters who pay their own cloud bills | High | Influx IOx already chosen |
| Kubernetes-native deployment with Helm + Operator | Platform teams live in Kubernetes; a Docker-only deployment story loses the enterprise buyer | Medium | Already planned |
| OTel-native without remapping | Some platforms (Datadog, historically) remap OTel attributes to proprietary schemas; NewDogRelic stores OTel semantics natively | Medium | Architectural decision; must be enforced in storage schema |

### Onboarding and First-Run Experience (Differentiating if Done Well)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Auto-generated default dashboard on first trace/metric receipt | Datadog wins evaluations partly because dashboards populate fast with zero configuration; SigNoz requires manual setup | Medium | Trigger: first span ingested for a service → auto-create RED metrics dashboard |
| Sample data / demo mode for evaluation | Empty UI kills evaluation; a one-click "load sample microservices" mode lets evaluators see the product before they instrument anything | Medium | OpenObserve does this well; critical for self-hosted evals |
| In-product instrumentation guide (OTel SDK setup per language) | Reduces time-to-first-trace from hours to minutes; Middleware achieves first full-stack view in under 1 hour | Medium | Wizard UI: select language → copy OTel SDK snippet → see first span |
| Service auto-labeling from OTel resource attributes | OTel SDKs emit `service.name`, `deployment.environment`, `k8s.pod.name`; auto-populate service registry from these | Low | Piggybacks on OTel semantic conventions |

### Enterprise / HIPAA Differentiators (Genuine Market Gap)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| SSO via SAML/OIDC in OSS tier | SigNoz gates SAML behind $49/mo Teams; OpenObserve gates SAML behind Enterprise; Apache 2.0 OSS with SAML is a genuine gap | Medium | Important for enterprise self-host adoption |
| Audit logs (who accessed what, when) in v1 | SigNoz Enterprise ($4k/mo) marks audit logs as "COMING SOON" with no timeline; this is a critical gap in the OSS ecosystem | Medium | Required for HIPAA; see HIPAA section |
| Attribute scrubbing / PII redaction pipeline | PHI in traces/logs must be stripped before storage; most OSS platforms do not have this built-in | High | HIPAA non-negotiable; must be in ingest pipeline |
| Immutable audit trail for HIPAA (6-year retention) | HIPAA 45 CFR §164.312(b) requires tamper-evident logs of all ePHI access; cold tier (Parquet on S3) enables this | Medium | Architecture supports this; needs enforcement layer |
| Burn-rate SLO alerting (not just threshold alerts) | SigNoz alerting is less mature; burn-rate alerts reduce 3am noise for SRE teams | Medium | Google SRE Workbook standard; clearly communicable value proposition |

---

## Anti-Features

Features to deliberately NOT build in v1, with rationale.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Proprietary query language (like NRQL) | Creates the exact lock-in that is the #1 reason teams leave New Relic; building one would contradict the core value proposition | PromQL for metrics, SQL (DataFusion) for logs/traces; both are portable and familiar |
| Browser/mobile RUM SDK (v1) | SDK surface area is enormous (Performance Timeline API, Navigation Timing API, Resource Timing API, Web Vitals, session replay); building it properly takes months; building it poorly creates a liability | Defer to v2; document that OTLP-based browser SDKs (like @opentelemetry/sdk-trace-web) can forward to NewDogRelic today |
| Synthetic monitoring (v1) | Distinct technical domain; requires geographically distributed probe infrastructure; the complexity is orthogonal to core ingest | Defer to v2; already in PROJECT.md Out of Scope |
| Continuous profiling (v1) | Flame graph generation and profile storage are a separate engineering surface; Grafana Pyroscope shows this is a full product | Defer to v2; already in PROJECT.md Out of Scope |
| ML anomaly detection / AI root cause analysis | Dynatrace Davis AI is years of training data; building a credible version requires a mature data layer first; shipping a weak version destroys trust | Build the query layer first; add statistical anomaly detection (not ML) in v2 as a threshold aid |
| Agent protocol beyond OTLP | Custom gRPC agent protocols (like Datadog's proprietary agent protocol) add maintenance overhead and re-create lock-in | OTLP covers all signals; already decided in PROJECT.md |
| Infrastructure monitoring via SNMP/WMI | Legacy protocol coverage adds years of integration work for diminishing enterprise value; not the buyer persona | Accept OTel host metrics receiver output; document that the OTel Collector covers SNMP translation |
| Log parsing rules engine (Grok/Regex pipeline in UI) | Logstash-style log parsing pipelines are a full product; they conflict with structured OTel logs (which are already parsed) | Recommend OTel Collector processors for log transformation before ingest; SQL handles field extraction at query time |
| Multi-cloud managed Kubernetes Operator in v1 | Supporting EKS + GKE + AKS operator variants simultaneously is months of QA; self-host via Helm chart serves the same buyer initially | Helm chart for v1; Operator for v2 when enterprise customers demonstrate the need |
| Feature parity sprint vs. Datadog's 23 products | Competitor-parity paranoia ("they have X, we need X") leads directly to feature bloat and alert fatigue in the roadmap | Each feature must answer a real question; prioritize by user pain, not by competitor checklist |

---

## Feature Dependencies

```
OTel ingest (OTLP) → all downstream features (nothing else works without data flowing in)

Trace ingest → trace explorer → service map (map is derived from trace relationships)
Trace ingest → cross-signal correlation → log search (correlation by trace ID requires trace presence)
Trace ingest → tail-based sampling (sampling evaluates complete traces)

Metrics ingest → PromQL query API → metrics dashboards → SLO tracking
SLO tracking → burn-rate alert evaluation → PagerDuty/Slack notification

API key auth → multi-tenant isolation → RBAC
RBAC → SSO/SAML (SSO is the identity source; RBAC maps identities to roles)
RBAC → audit logging (audit logs record who accessed what; "who" requires RBAC identity)

Attribute scrubbing pipeline → HIPAA compliance (must be in ingest path, not query path)
Audit logging → HIPAA compliance (45 CFR §164.312(b) requirement)
Immutable cold storage (Parquet/S3) → 6-year HIPAA audit retention

Default dashboards → onboarding success (empty UI on first trace = failed evaluation)
In-product OTel guide → first trace receipt → default dashboard auto-creation
```

---

## MVP Recommendation

### Prioritize for v1 (table stakes + key differentiators)

1. **Multi-signal OTLP ingest** — table stakes; nothing else works without it
2. **Trace explorer** (search, filter, waterfall) — primary use case for the target buyer
3. **Log search** (full-text + field filter) — required to close the multi-signal story
4. **PromQL metrics API + basic dashboards** — SRE buyers test PromQL compatibility in day 1 of evaluation
5. **SQL query API** (DataFusion) — the differentiator vs. NRQL; communicate explicitly
6. **Service map** (auto-generated from traces) — table stakes in 2025; absence loses evaluations
7. **Alert engine** (threshold + burn-rate SLO, state machine, dedup, PagerDuty/Slack/Webhook/Email)
8. **Multi-tenant RBAC** (Org → Project → role) — required for Cloud tier and enterprise self-host
9. **API key auth per tenant** — prerequisite for RBAC and Cloud
10. **Attribute scrubbing / PII redaction** — HIPAA non-negotiable; must be in ingest path
11. **Audit logging** (immutable, 6-year cold retention) — HIPAA non-negotiable; OSS competitors don't have it
12. **SSO via SAML/OIDC in OSS tier** — genuine market gap; differentiates from SigNoz and Grafana OSS
13. **Auto-generated default dashboard on first service trace** — first-run UX; critical for evaluation success
14. **In-product OTel instrumentation guide** — reduces time-to-first-trace; wins evaluations on ease of onboarding
15. **Tail-based sampling** — technical differentiator; preserves errors/P99 outliers that head-based discards

### Defer to v2

- **Browser/mobile RUM** — large SDK surface area; defer per PROJECT.md
- **Synthetic monitoring** — geographically distributed probe infrastructure; separate product domain
- **Continuous profiling** — full product in its own right (Pyroscope); defer per PROJECT.md
- **ML/AI anomaly detection** — requires mature data layer; ship statistical anomaly aids in v2
- **Kubernetes Operator** — Helm chart serves v1 self-hosters; Operator adds enterprise lifecycle management in v2
- **Sample data / demo mode** — high value for evaluation but not day-1 blocking; v1.1 or v2

---

## HIPAA Compliance Non-Negotiables (Research Question 4)

These features are architecturally required from day one. Retrofitting them is expensive and disruptive.

| Requirement | Regulatory Basis | Implementation Note |
|-------------|-----------------|---------------------|
| Attribute scrubbing (PHI/PII redaction) in ingest pipeline | HIPAA Security Rule; storing raw PHI in observability tools creates secondary compliance surface | Go ingest service: scrubbing rules evaluated before write to IOx |
| Immutable audit log of all ePHI-touching access | 45 CFR §164.312(b) Audit Controls standard | Append-only write path; cold tier (Parquet/S3) provides tamper-evident storage |
| 6-year minimum audit log retention | HIPAA documentation retention requirement | Cold tier (unlimited retention on S3/GCS) already supports this architecturally |
| TLS everywhere (in-transit encryption) | HIPAA Technical Safeguards | Already planned in PROJECT.md |
| KMS-managed at-rest encryption | HIPAA Technical Safeguards | Already planned in PROJECT.md |
| Access control with identity-linked audit trail | 45 CFR §164.308(a)(1)(ii)(D) Information System Activity Review | RBAC + SSO + audit logs must be integrated |
| BAA-eligible deployment model | HIPAA Business Associate Agreement requirement for covered entities | Self-hosted option removes cloud provider from BAA scope; Cloud tier requires BAA |
| Data residency controls | HIPAA + GDPR overlap for US+EU healthcare customers | Per-tenant storage namespace; self-hosted eliminates cloud provider residency concern |

---

## RUM and Synthetic Monitoring (Research Question 8 — v2 Context)

Although deferred to v2, understanding what customers expect prevents architectural mistakes in v1 that make v2 harder.

### Browser RUM — What Customers Expect

| Feature | Customer Expectation | Why |
|---------|---------------------|-----|
| Core Web Vitals (LCP, INP, CLS, TTFB) | Expected by all web teams post-Google ranking update | Web Vitals are the common language of frontend performance |
| JavaScript error tracking with stack traces | Error tracking is the minimum viable RUM capability | Without this, frontend errors are invisible |
| Session-level trace correlation (frontend span → backend trace) | The killer feature; connects user clicks to backend latency | Full-stack visibility = APM + RUM correlated by trace ID |
| Geographic performance segmentation | Enterprise buyers monitor user experience by region | CDN and ISP issues surface here |
| Resource load timing (XHR, fetch, assets) | Identifying slow API calls and large payloads requires this | Complements backend APM |

### Synthetic Monitoring — What Customers Expect

| Feature | Customer Expectation | Why |
|---------|---------------------|-----|
| Multi-step browser transaction monitoring | Testing checkout flows, login flows; Playwright-based execution is the standard | Uptime probes alone are insufficient for enterprise |
| API endpoint probing (HTTP checks, DNS, SSL expiry) | The simplest form; teams expect it as a lightweight substitute when RUM is not instrumented | Low complexity; high value for first-hour experience |
| Public and private monitoring locations | Private locations allow testing internal services behind VPNs | Enterprise self-hosters specifically need private probes |
| Alert on synthetic failure | A synthetic monitor that cannot alert is a dashboard toy | Integrates with alert engine |

### V1 Architecture Guidance for Future V2 Compatibility

The v1 OTLP ingest pipeline should accept browser spans from `@opentelemetry/sdk-trace-web` today. This provides basic RUM trace data at zero cost and means v2 adds a RUM dashboard layer, not a new ingest path. Do not build a proprietary RUM JavaScript SDK in v1.

---

## Alerting Engine: MVA vs. Differentiator (Research Question 6)

### Minimum Viable Alert Engine (must ship in v1)

| Capability | Why Minimum |
|-----------|-------------|
| Threshold alerts on metrics (PromQL condition + threshold) | Every APM product has this; absence is disqualifying |
| Alert state machine: OK → FIRING → RESOLVED | Prevents duplicate pages; required for PagerDuty integration |
| Deduplication by alert rule + labels | A single bad deployment should fire one alert, not 50 |
| Routing to PagerDuty, Slack, Webhook, Email | Covers 95%+ of on-call workflows |
| Alert history with timestamps | Post-mortem and HIPAA audit use cases |
| Multi-condition alert rules | Real-world alerts are `error_rate > 5% AND traffic > 100 rps` |

### Differentiating Alert Capabilities (v1 or early v2)

| Capability | Why Differentiating |
|-----------|---------------------|
| SLO definition (SLI + target + window) | Moves alerting from arbitrary thresholds to user-impact-based reliability targets; SRE buyers specifically evaluate this |
| Multi-window burn-rate alerts (5m + 1h confirmation) | Google SRE Workbook standard; reduces 3am noise by requiring both short spike and sustained burn; SigNoz alerting is explicitly noted as less mature in this area |
| Error budget tracking and burn visualization | Error budget burn dashboards are a leading signal for release decisions; Datadog and New Relic both offer this; SigNoz does not yet |
| Alert suppression / maintenance windows | Required for planned deployments; absence causes alert storm during maintenance |
| Alert routing by team/service ownership | Large platform teams have sub-teams; routing by service label reduces misrouted pages |

---

## Service Map Positioning (Research Question 7)

**Verdict: Table stakes in 2025.** A static or missing service map loses enterprise evaluations. The differentiator is not having a service map — it is how the service map behaves.

| Capability | Table Stakes or Differentiator |
|-----------|-------------------------------|
| Auto-generated topology from trace spans | Table stakes — every New Relic, Datadog, SigNoz, Honeycomb user expects this |
| Health status overlaid on nodes (error rate, p99 latency) | Table stakes — a topology diagram without live state is useless |
| Clickthrough from node to traces and logs | Table stakes — the map is navigation, not just visualization |
| Real-time update (reflects last 5 minutes of data) | Table stakes — a stale map misleads during incidents |
| Upstream/downstream impact analysis during incident | Differentiator — shows blast radius propagation; reduces MTTR |
| Team/owner annotation on services | Differentiator — reduces "who owns this?" friction during incidents |
| AI-driven change tracking (flag services that recently changed) | Differentiator (v2) — correlates deploys with performance shifts |

---

## Competitive Gaps Summary

This table shows what the OSS ecosystem is missing that NewDogRelic can fill.

| Gap | SigNoz | Grafana OSS | OpenObserve | NewDogRelic Position |
|----|--------|------------|------------|---------------------|
| Audit logs | Not yet (marked COMING SOON) | Gated (Enterprise) | Available (Enterprise) | v1 — Apache 2.0 OSS |
| SAML/OIDC SSO in free tier | Paid only ($49/mo Teams) | Gated (Enterprise) | Gated (Enterprise) | v1 — Apache 2.0 OSS |
| Tail-based trace sampling | Head-based only | Tempo: none built-in | None | v1 — planned |
| Single query language (no multi-DSL) | ClickHouse SQL | PromQL + LogQL + TraceQL | SQL + PromQL | v1 — PromQL + SQL (DataFusion) |
| HIPAA from inception | Partial | No | Partial | v1 — architecture requirement |
| Apache 2.0 OSS | MIT (EE is commercial) | AGPLv3 (Loki); mixed | Apache 2.0 | v1 |
| Single-platform (not assembled stack) | Yes (single ClickHouse) | No (4 systems) | Yes | v1 |
| Cross-signal SQL analytics | ClickHouse SQL | No | Partial | v1 — DataFusion |

---

## Sources

- Competitive landscape and pricing pain points: [Best New Relic Alternatives 2026 — CubeAPM](https://cubeapm.com/blog/top-new-relic-alternatives-features-pricing-review/), [Datadog Alternatives — Groundcover](https://www.groundcover.com/guides/datadog-alternatives-for-full-stack-observability), [Practical Guide for Teams Outgrowing New Relic](https://freemail.ai/blog/new-relic-alternatives/), [New Relic Alternatives — ScoutAPM](https://www.scoutapm.com/blog/best-new-relic-alternatives-2026)
- Table stakes features: [Top Observability Tools 2026 — OpenObserve](https://openobserve.ai/blog/top-10-observability-tools/), [Observability Platform Comparison — Codilime](https://codilime.com/blog/which-observability-tool-is-right-for-you/), [Best Observability Platforms — Honeybadger](https://www.honeybadger.io/blog/observability-platforms/)
- SigNoz vs. Grafana gaps: [Grafana Problems — SiriusOpenSource](https://www.siriusopensource.com/en-us/blog/grafana-problems), [Grafana Cloud vs. SigNoz — BetterStack](https://betterstack.com/community/comparisons/grafana-cloud-vs-signoz/), [SigNoz vs. Grafana — MatterAI](https://www.matterai.so/guides/grafana-stack-vs-signoz-choosing-an-opentelemetry-native-observability-platform)
- SigNoz/OpenObserve enterprise feature gaps: [OpenObserve vs. SigNoz — CubeAPM](https://cubeapm.com/blog/openobserve-vs-signoz/), [Best SigNoz Alternative — OpenObserve](https://openobserve.ai/signoz-alternative/), [OpenObserve vs. SigNoz — RFP Wiki](https://www.rfp.wiki/it-security/observability-platforms/openobserve/signoz)
- HIPAA compliance: [Observability in HIPAA-Compliant Environments — Epsagon](https://epsagon.com/observability/observability-in-hipaa/), [HIPAA Audit Log Requirements — Medcurity](https://medcurity.com/hipaa-audit-log-requirements/), [HIPAA Observability Data Retention — Grepr](https://www.grepr.ai/blog/hipaa-data-retention), [HIPAA-Compliant Log Management — Datadog](https://www.datadoghq.com/blog/hipaa-compliant-log-management/)
- Alert engine and SLO: [Implementing SLOs — Adyen](https://www.adyen.com/knowledge-hub/implementing-service-level-objectives), [SLO-Based Alerting — OpenObserve](https://openobserve.ai/blog/slo-based-alerting/), [SLO-Driven Alerting That Does Not Page at 3am](https://kokil.com.np/blog/slo-driven-alerting-that-does-not-page-at-3am), [Grafana SLO Best Practices](https://grafana.com/docs/grafana-cloud/alerting-and-irm/slo/best-practices/)
- Service map: [Service Dependency Graphs from Traces](https://adhdecode.com/observability/distributed-tracing/service-dependency-graphs-traces-topology/), [What is Service Map 2026 — AiOpsSchool](https://aiopsschool.com/blog/service-map/)
- Onboarding/first-run: [Top 7 Platforms That Auto-Discover Services — Last9](https://last9.io/blog/observability-platforms-that-auto-discover-services/), [Best Cloud Observability Tools 2026 — CloudChipr](https://cloudchipr.com/blog/best-cloud-observability-tools-2026)
- Distributed tracing and sampling: [Distributed Tracing at Enterprise Scale — CIOPages](https://www.ciopages.com/articles/distributed-tracing-enterprise-scale), [Mastering Distributed Tracing — Datadog](https://www.datadoghq.com/architecture/mastering-distributed-tracing-data-volume-challenges-and-datadogs-approach-to-efficient-sampling/), [Distributed Tracing System Design](https://medium.com/engineering-playbook/distributed-tracing-system-design-opentelemetry-jaeger-sampling-at-scale-4aff9ed8fad9)
- Honeycomb high-cardinality differentiators: [Honeycomb vs. Datadog — SigNoz](https://signoz.io/comparisons/honeycomb-vs-datadog/), [Honeycomb Guide — HashHackers](https://blog.hashhackers.com/blog/honeycomb-guide/)
- RUM and synthetic monitoring: [RUM Tools 2025 — IP-Label](https://ip-label.com/best-real-user-monitoring-rum-tools/), [Synthetic vs. RUM — IP-Label](https://ip-label.com/synthetic-monitoring-vs-real-user-monitoring/), [Top Synthetic Monitoring Tools — CubeAPM](https://cubeapm.com/blog/top-synthetic-monitoring-tools/)
- Anti-features and feature bloat: [The APM Paradox — Honeybadger](https://www.honeybadger.io/blog/apm-paradox/), [The $3.4B Observability Tax — OneUptime](https://oneuptime.com/blog/post/2026-03-26-the-3-billion-observability-tax/view), [Bad Observability — SquaredUp](https://squaredup.com/blog/bad-observability/)
- OpenTelemetry: [OpenTelemetry in 2025 — Medium](https://medium.com/@serverwalainfra/opentelemetry-in-2025-the-backbone-of-full-stack-observability-for-container-environments-619d44135a5a), [OTel Collector K8s Discovery — OTel Blog](https://opentelemetry.io/blog/2025/otel-collector-k8s-discovery/), [Cost-Effective OTel — CNCF Blog](https://www.cncf.io/blog/2025/12/16/how-to-build-a-cost-effective-observability-platform-with-opentelemetry/)
- Multi-tenant RBAC: [Enterprise-Grade Security — OpenObserve](https://openobserve.ai/security-compliance/), [Multi-Tenant Observability Architecture — BugFree](https://bugfree.ai/knowledge-hub/multi-tenant-observability-platform-architecture)
- Query language lock-in: [New Relic Alternatives 2026 — ClickHouse](https://clickhouse.com/resources/engineering/new-relic-alternatives), [OpenTelemetry vs. New Relic — Modern Data Tools](https://www.modern-datatools.com/compare/opentelemetry-vs-new-relic)
