# Domain Pitfalls: NewDogRelic Observability Platform

**Domain:** New Relic-style APM / observability SaaS (multi-tenant, HIPAA, OTLP ingest, IOx storage)
**Researched:** 2026-11-12
**Overall confidence:** HIGH (all 10 areas verified against official docs and production postmortems)

---

## Critical Pitfalls

Mistakes that cause data loss, system outages, or mandatory rewrites.

---

### Pitfall 1: Cardinality Explosion

**What goes wrong:**
Every unique combination of a metric name and its label values creates a separate time series. When developers add high-cardinality labels (user IDs, request IDs, session tokens, unbounded HTTP routes), the series count multiplies combinatorially — 5,000 pipelines × 3 environments × 5 status codes × 4 regions × 10,000 partition values = 3 billion time series. Prometheus OOMs, IOx ingester WAL fills, compaction storms begin, and query latency goes from milliseconds to timeouts. The pipeline appears "green" on traditional success/failure metrics while doing 10x the intended work.

**Why it happens:**
Developers instrument by convention — they add every available attribute to every metric. The OpenTelemetry SDK makes it trivially easy to include span attributes as metric dimensions, so without deliberate policy, attribute sets grow unbounded. The failure is silent: the monitoring system degrades gradually rather than failing with an error.

**Consequences:**
- IOx ingester WAL grows until `max_wal_bytes_per_partition` cap is hit, backpressuring writes
- Compaction storms: 10,000+ Parquet files backlogged, compactor falls behind with exponential retry
- Query fan-out: PromQL must scan millions of series to answer simple queries
- Multi-tenant blast: one tenant's cardinality explosion degrades query performance for all tenants

**Warning signs (detect early):**
- Distinct series count growing faster than traffic (not linearly correlated to new services)
- IOx WAL size growing between compaction cycles
- PromQL query duration P95 increasing over days without traffic change
- Compactor file backlog metric rising above 1,000 files
- A new deployment causes an immediate spike in time series count

**Prevention strategy:**
1. **Gate at ingest**: OTel Collector `attributes` processor as the first pipeline stage — allowlist low-cardinality label values, delete or hash high-cardinality ones (user_id → hash, request_id → drop)
2. **Per-tenant series limits**: Enforce a configurable hard cap on active series per tenant at the ingester level; return HTTP 429 with a clear error message rather than silently degrading
3. **Cardinality API**: Ship a `/api/v1/cardinality` endpoint showing top-N metrics by series count per tenant (Mimir has this — build an equivalent against IOx metadata)
4. **Baseline alerting**: Alert when a single metric name exceeds 10,000 unique series, or when total series count grows > 20% in 1 hour
5. **SDK guidance**: Document in the developer guide that only `service.name`, `service.version`, `environment`, `region`, and `status_code` are acceptable metric dimensions

**Build phase:** Phase 1 (ingest pipeline). The OTel Collector attribute processor gating must be in place before any public data is accepted. The per-tenant series cap belongs in the ingester's write path.

---

### Pitfall 2: Kafka Consumer Lag Cascade

**What goes wrong:**
During an ingest spike, Kafka consumers fall behind. Because the ingest pipeline is the only path to durable storage, lag means data is not being written to IOx — which means the system is accepting OTLP writes (returning 200 OK to SDKs) while that data sits in Kafka with no guarantee of when it will be consumed. If lag grows to the Kafka retention window (default 7 days), data is permanently lost without warning.

**Why it happens:**
Kafka decouples producers from consumers via persistent partitioned logs, so there is no built-in backpressure signal from consumer to producer. The ingest API layer continues accepting at full speed while consumers stall. The root cause is usually downstream storage slowness (IOx ingester I/O saturation, compaction storms) causing the consumer processing loop to slow, with the consumer thread still polling Kafka before the previous batch is processed — filling memory with an in-process backlog, then hitting GC pressure, then slowing further.

**Consequences:**
- Data loss if lag exceeds retention window (silent, no alerts unless explicitly configured)
- Memory exhaustion in consumer pods (OOM kill cascades with cold restarts, increasing lag further)
- SLA violation: OTLP clients receive 200 OK for writes that may be lost

**Warning signs (detect early):**
- `records-lag-max` rising across partitions (not just a single partition)
- `records-lag` measured in time (not just count) exceeding 60 seconds
- Consumer `fetch-rate` dropping while producer rate is stable
- Consumer pod memory usage trending toward limits
- IOx ingester write latency P99 rising above 50ms

**Prevention strategy:**
1. **Partition-per-tenant keying**: Use `tenant_id` as the Kafka partition key so one tenant's spike fills their partition, not shared partitions. Consumers process partitions round-robin with bounded per-partition poll budgets.
2. **Pause/Resume backpressure**: Implement `KafkaConsumer.pause()` on partitions when downstream IOx write latency exceeds threshold; `resume()` when latency recovers. This is the canonical Go/Kafka pattern.
3. **Priority lanes**: Use separate Kafka topics for different signal types (traces, metrics, logs) with independent consumer groups so a log flood cannot starve trace ingestion
4. **Circuit breaker on IOx**: If IOx ingester returns errors > N% over 30s, open circuit, stop consuming, alert, and return 503 on new OTLP writes rather than accepting data you cannot store
5. **Lag time alerting**: Alert at `consumer_lag_time > 30s` (warning) and `> 5m` (critical). Do not alert only on message count lag — a low-volume tenant with 1,000 messages might have minutes of lag while a high-volume tenant with 1M messages is healthy.
6. **Retention window guard**: Set Kafka retention to 48 hours minimum (not the default 7 days) but alert at 25% of retention window consumption to give human intervention time

**Build phase:** Phase 1 (Kafka infrastructure). Partition keying and consumer group design must be correct from the first commit — these cannot be changed without data loss once partitions are populated. Backpressure and circuit breaker logic belongs in Phase 2 (ingest hardening).

---

### Pitfall 3: IOx Compaction Storm

**What goes wrong:**
IOx (InfluxDB 3) uses a write-ahead log (WAL) on ingester nodes that is periodically snapshotted to Parquet files in object storage, then compacted by the compactor service. When the compactor falls behind — due to S3 degradation, ingester overload, or compactor resource starvation — the number of uncompacted Parquet files grows. Query performance degrades because the querier must merge thousands of small files at query time. If the backlog exceeds ~10,000 files, the compactor enters exponential backoff and the system enters a self-reinforcing failure state.

**Why it happens:**
The compactor is a single-instance service (InfluxData recommends exactly 1 compactor pod — horizontal scaling is not safe, only vertical). It is CPU + network-bound. When ingestion rate spikes and the compactor is under-provisioned, file count grows faster than the compactor can process. Object storage API rate limits (S3 has a 5,500 GET/s per prefix limit) become a secondary bottleneck in large clusters.

**Consequences:**
- Query P99 degradation: querier must fan-out to hundreds of small Parquet files per query
- Ingester WAL growth: when compactor is behind, WAL is not flushed, growing until `max_wal_bytes_per_partition` cap, which then backpressures writes
- In older TSM-based versions: OOM kills, infinite compaction loops, data loss on shards > 16GB — IOx's Parquet-on-object-storage architecture largely eliminates data loss risk, but performance degradation remains a real operational failure

**Warning signs (detect early):**
- Compactor file backlog > 1,000 (alert), > 5,000 (critical)
- Compactor job duration P99 increasing over days
- Ingester WAL size growing between snapshot cycles
- Querier cache-miss latency increasing while cache-hit latency is stable
- S3 GET/PUT rate approaching prefix limits

**Prevention strategy:**
1. **Vertical-scale the compactor early**: 32+ CPU cores, 64GB+ RAM. Compactor concurrency scales with memory, not CPU count. Never try to horizontal-scale the compactor — only 1 instance holds the lease.
2. **Dedicated compactor node**: Put the compactor on its own Kubernetes node with guaranteed QoS (`requests == limits`). Never co-locate it with ingesters or queriers.
3. **S3 prefix sharding**: Distribute object storage writes across multiple S3 key prefixes (partition by tenant or time bucket) to avoid the 5,500 req/s per-prefix limit
4. **Compactor lag alerting**: Instrument `compactor_uncompacted_file_count` and alert at defined thresholds before exponential backoff kicks in
5. **WAL size limits and backpressure**: Configure `max_wal_bytes_per_partition` conservatively (default 5-10 GB). When WAL pressure triggers, surface this as an ingester metric so the ingest API can apply backpressure before accepting new writes
6. **Ingester WAL on NVMe**: WAL I/O is on the critical write path. Use NVMe-backed storage volumes, not network-attached EBS `gp2`. Use `gp3` with provisioned IOPS or local NVMe.

**Build phase:** Phase 2 (storage engine). IOx cluster topology (ingester / querier / compactor node separation) must be established during the initial IOx integration phase. Alerting on compactor backlog belongs in Phase 3 (operational hardening).

---

### Pitfall 4: Tail-Based Sampling Memory Exhaustion

**What goes wrong:**
Tail-based sampling requires the collector to buffer all spans from every in-flight trace until `decision_wait` expires, then evaluate the complete trace against sampling policies. At 5M spans/s with an average trace depth of 20 spans and a 30-second `decision_wait`, the theoretical buffer is: 5,000,000 / 20 = 250,000 traces × 30s × (20 spans × 1KB/span) = 150 GB. This cannot fit in a single collector instance. Without proper architecture, OTel Collector pods OOM during traffic spikes, dropping spans silently with no feedback to the SDK.

**Why it happens:**
The common mistake is deploying a single layer of OTel Collector pods with the `tailsamplingprocessor` and load-balancing OTLP traffic randomly across them. When spans from the same trace land on different collector instances, no single instance has the complete trace to make a sampling decision — so either all instances keep all spans (memory × N) or decisions are made on incomplete traces (incorrect sampling).

**Consequences:**
- OOM kills on collector pods drop spans silently (SDK gets 200 OK before the drop happens)
- Incomplete trace storage: a decision to "keep" a trace is made but only 60% of spans are on that instance
- Memory pressure causes GC pauses that increase tail latency across the whole ingest path

**Warning signs (detect early):**
- `otelcol_processor_tail_sampling_policy_decision_count{decision="sampled_too_late"}` rising (spans arriving after the decision was already made)
- Collector pod memory at > 70% of limit
- `otelcol_processor_tail_sampling_buffer_filling_up` alert firing
- Traces in storage with inconsistent span counts (some spans missing)
- `eviction_rate` for trace buffer > 5%

**Prevention strategy:**
1. **Two-tier collector architecture**: Tier 1 = stateless OTel Collector agents (DaemonSet) that do zero sampling, only emit to Tier 2 using `loadbalancingexporter` with `routing_key: traceID`. Tier 2 = stateful gateway Collector Deployment (3-5 pods) with `tailsamplingprocessor`. Each gateway pod receives all spans for its assigned trace IDs via consistent hashing.
2. **Horizontal sharding, not vertical scaling**: Scale the Tier 2 gateway pool horizontally. Each pod handles a shard of the trace ID space. Memory per pod = shard_fraction × total_in_flight_traces × avg_trace_size × 1.5 safety margin.
3. **Memory limiter as first processor**: Place `memorylimiter` as the first processor in the gateway pipeline with `limit_percentage: 80` and `spike_limit_percentage: 15`. When the limit is hit, the processor returns a retriable error to the upstream agent, which re-buffers and retries.
4. **Short `decision_wait` for P50 traces**: Set `decision_wait` to 2-3× P99 trace latency, not P99.9. Spans arriving after `decision_wait` are sampled by head-based fallback rules.
5. **Head-based fallback**: Always maintain a 1% head-based sampling floor so that even if the tail sampler drops all spans for a trace (e.g., under OOM pressure), there is still a baseline sample rate for capacity planning.

**Build phase:** Phase 3 (trace pipeline). The two-tier architecture must be designed before the trace sampling system is built. This is a topology decision, not a configuration decision — retrofitting trace ID routing into an existing single-tier deployment requires a full redeployment.

---

## Moderate Pitfalls

---

### Pitfall 5: HIPAA Audit Log Blast Radius

**What goes wrong:**
HIPAA requires logging every access to PHI (45 CFR 164.312(b)) AND reviewing those logs regularly (45 CFR 164.308(a)(1)(ii)(D)). An observability platform that handles health data generates audit events for every query, every dashboard load, every API call that touches patient-adjacent data. At scale, the audit log volume rivals the operational telemetry volume — creating a secondary data infrastructure problem. The trap is treating audit logs as an observability problem (short retention, broad developer access, optimized for search speed) when they are actually a compliance artifact (long retention, restricted access, optimized for tamper-evidence and legal defensibility).

**Why it happens:**
Teams route audit logs to the same ELK/Loki stack they use for application logs because it is already there. This violates HIPAA in two ways: application log stores have short retention (not HIPAA's 6-year requirement) and they are accessible to developers who should not have access to PHI access patterns.

**Consequences:**
- Compliance audit failure: audit logs in the wrong store with wrong retention are not compliant even if technically present
- Cost explosion: PHI audit events at high volume stored at observability data pricing (expensive per GB)
- Security failure: PHI access logs visible to developers who should not see which users accessed which records
- Review gap: terabytes of audit data with no tooling to actually review it (logging without reviewing fails 164.308)

**Warning signs (detect early):**
- Audit log destination is the same Kafka topic / storage system as application logs
- Audit log entries include raw PHI attributes (patient names, diagnosis codes) rather than opaque identifiers
- No scheduled audit log review process exists (the second HIPAA requirement)
- Audit log retention < 6 years

**Prevention strategy:**
1. **Separate audit log stream**: The gateway emits two streams: a sanitized observability stream (latency, error rates, no PHI context) and a HIPAA audit stream with structured, immutable schema. These are different Kafka topics with different consumer groups, different storage backends, and different ACLs.
2. **Immutable append-only store**: Audit log storage must be an INSERT-only append table with `prev_hash` chaining for tamper evidence (not an observability DB with retention policies that delete). Write to S3 with SSE-KMS + Object Lock (WORM mode), then index a summary in a restricted-access Postgres.
3. **Attribute scrubbing at ingest**: The OTLP ingest pipeline must strip known PII attributes (patient IDs, names, DOBs, diagnosis codes from span attributes) before data reaches the hot tier. Maintain a PHI attribute allowlist — if an attribute is not on the allowlist, drop it.
4. **Audit log tiering**: Hot path (last 90 days) in a restricted-access Postgres. Cold archive (90 days–6 years) in S3 Glacier with lifecycle policies. This separates cost from compliance without sacrificing retrievability.
5. **Review tooling must ship**: A HIPAA-compliant platform that cannot answer "who accessed what records in the last 30 days" does not satisfy 164.308. Ship a minimal audit review UI alongside the HIPAA feature, not as a future milestone.

**Build phase:** Phase 1 (architecture). The dual-stream split (observability vs. audit) must be in the initial ingest architecture. This cannot be retrofitted — it requires changes to the Kafka topic design, the storage schema, and the access control model.

---

### Pitfall 6: Multi-Tenant Noisy Neighbor

**What goes wrong:**
In a shared-infrastructure multi-tenant deployment, a single tenant with high ingest volume or expensive queries can degrade the experience for all other tenants. This manifests in three distinct layers: Kafka (one tenant's partition fills, consumer spends disproportionate time on it), IOx ingester (one tenant's high cardinality saturates the WAL), and query layer (one tenant's PromQL query does a full series scan, consuming all DataFusion threads).

**Why it happens:**
Global rate limits are insufficient — a single tenant can consume the entire global budget before the limit kicks in. Without per-tenant isolation in every pipeline layer, a legitimately well-behaving large tenant degrades the platform for smaller tenants by simply being large.

**Consequences:**
- P99 query latency degradation platform-wide during one tenant's report export
- Ingest lag for all tenants when one tenant has a cardinality explosion
- SLA violations affecting tenants who are themselves behaving correctly

**Warning signs (detect early):**
- Per-tenant ingest rate metrics showing one tenant at > 30% of total platform ingest
- Query P99 rising while per-tenant query rate is stable (one expensive query masking in aggregate)
- Kafka per-partition lag showing one partition consistently behind others
- IOx compactor backlog dominated by one tenant's namespace

**Prevention strategy:**
1. **Per-tenant Kafka quotas**: Set producer and consumer byte-rate quotas per `tenant_id` ACL in Kafka. The `kafka.server:ThrottleTimeMs` metric per client ID makes quota enforcement visible.
2. **Partition-per-tenant routing**: Key all messages on `tenant_id` so each tenant's data is in isolated partitions. Use per-partition worker threads (the Elastic OTel fix pattern) so one slow tenant's partition worker blocks only itself.
3. **Per-tenant series cardinality cap at ingester**: IOx does not natively enforce per-tenant series limits — build this in the ingest API layer as a write path guard.
4. **Query resource limits**: At the PromQL / SQL query layer, enforce per-tenant query timeouts (default 30s), maximum series per query (default 500K), and concurrent query limits (default 5 per tenant). Return HTTP 429 with a `Retry-After` header when limits are exceeded.
5. **Tenant-scoped observability**: Instrument every component with `tenant_id` label. Build a per-tenant health dashboard (ingest rate, query latency, series count, error rate). Only with this visibility can operators detect noisy neighbors before they become incidents.

**Build phase:** Phase 2 (multi-tenancy). Kafka quota configuration and partition keying belong in the initial Kafka setup (Phase 1). Per-tenant query limits belong in the query gateway (Phase 2). Per-tenant observability dashboards belong in Phase 3.

---

### Pitfall 7: Cold Tier Query Performance Failure

**What goes wrong:**
S3/Parquet queries can degrade from seconds to minutes when the partition layout defeats pruning. The two most common mistakes are: (1) nested time partitioning (`year/month/day/hour`) where the query engine cannot prune efficiently unless all keys are present in the filter, and (2) small file proliferation (thousands of 1KB files) where per-file S3 API call overhead dominates over actual data transfer time.

**Why it happens:**
The nested partition structure looks logical and is recommended in older Hive/Spark documentation. In S3-backed DataFusion/Trino query engines, partition pruning requires the full partition path to be specified. A query with `WHERE time > 2025-01-01` and no month/day filter causes the engine to enumerate every month and day in that year — O(365) S3 LIST calls before reading a byte of data. Additionally, IOx compaction produces Parquet files sized for hot-path write performance (small), not cold-path read performance (large). Without a secondary compaction pass for the cold tier, file counts grow into the tens of thousands.

**Consequences:**
- Cold queries taking minutes instead of the target < 10s P95
- S3 LIST API rate limits hit (severe in multi-tenant scenarios where many tenants query cold tier simultaneously)
- DataFusion query planner taking longer than the actual data scan
- Unexpected S3 cost spikes from excessive GET/LIST operations

**Warning signs (detect early):**
- Cold tier query P95 > 10s (the stated SLA)
- S3 request metrics showing LIST calls >> GET calls (partition enumeration dominating)
- Cold file count in object storage > 100,000 per tenant per week (too many small files)
- Query planner time (not execution time) is the dominant component of query duration

**Prevention strategy:**
1. **Single-column date partition key**: Use `dt=YYYY-MM-DD` as the top-level partition, not `year=YYYY/month=MM/day=DD`. DataFusion can prune a single-key BETWEEN filter in O(1) metadata lookups. Benchmarks show 200x fewer metadata lookups vs. nested partitioning.
2. **Cold-tier compaction target**: Target 64–256 MB Parquet files in the cold tier. Write a secondary compaction job (separate from the IOx hot compactor) that merges small Parquet files in S3 during off-peak hours.
3. **Column + partition pruning**: Use Parquet column statistics (min/max per row group) to push predicates into file scans. DataFusion supports this natively — ensure IOx Parquet writes include statistics in the footer.
4. **Cold tier read cache**: Warm a local SSD cache for recently-accessed cold tier files. Cold-to-warm cache misses are expensive; warm-tier hits are cheap. Use a file-level LRU cache in the querier, not in-memory row cache.
5. **Speculative retry disabled for cold reads**: S3's higher latency variance can trigger speculative retries in distributed query engines, causing duplicate reads and amplified cost. Disable speculative execution for cold-tier scans.
6. **Partition by both time and tenant**: The cold partition scheme should be `tenant_id=X/dt=YYYY-MM-DD/` so queries for a single tenant never scan other tenants' files, regardless of time range.

**Build phase:** Phase 2 (storage engine — cold tier). The partition layout is set at the first write to S3; changing it later requires rewriting all historical data. This decision must be made before the warm→cold flush is implemented.

---

### Pitfall 8: OSS Licensing Traps

**What goes wrong:**
Apache 2.0 is safe to use but it invites hyperscaler free-riding — AWS, GCP, and Azure can offer NewDogRelic as a managed service without contributing back and without paying a license. The historical pattern (Elasticsearch → OpenSearch, Redis → RSALv2+SSPL, HashiCorp → BUSL) shows successful open source observability projects eventually facing this exact choice.

The secondary trap is dependency licenses: a single AGPL or SSPL-licensed dependency in the dependency tree can impose viral open-source obligations on the entire codebase.

**Why it happens:**
Apache 2.0 is chosen for community adoption. The licensing trap is not visible at launch — it only becomes a problem when the platform is successful enough that cloud providers want to offer it. SSPL is tempting as a counter-measure but it is not OSI-recognized and can restrict the company's own SaaS operations.

**Consequences:**
- Cloud providers offering a competing managed version without contributing to the project
- AGPL dependency discovered late requires either replacing the dependency or releasing proprietary code
- SSPL adoption closes off "open source" positioning and may deter enterprise adoption (many enterprises ban SSPL in procurement)

**Warning signs (detect early):**
- Any dependency with SSPL, AGPL, LGPL, Commons Clause, or BUSL 1.1 in the license field
- A cloud provider builds a hosted version and markets it as equivalent
- Enterprise procurement teams raising license compatibility questions

**Prevention strategy:**
1. **SCA (Software Composition Analysis) from day 1**: Run `license-checker` or `FOSSA` in CI on every dependency addition. Block merges that introduce AGPL/SSPL/LGPL dependencies into the core platform. Document an approved license list (MIT, Apache 2.0, BSD-2, BSD-3, ISC) and a blocked list (GPL, AGPL, SSPL, BUSL, Commons Clause).
2. **Keep cloud/enterprise features out of core**: The monetization model is OSS core + Cloud hosted + Enterprise self-host. Put HIPAA audit tools, SSO integration, advanced RBAC, and SLO analytics in a separate `enterprise/` module that is not Apache 2.0 — this is the open-core model that Grafana, HashiCorp (pre-BUSL), and Elastic used successfully.
3. **CLA (Contributor License Agreement)**: Require contributors to sign a CLA (or DCO) that grants the company the right to relicense their contributions. This is essential if the company ever needs to change the license for the closed/enterprise components.
4. **Acceptable use clauses in Cloud ToS**: Apache 2.0 does not prevent cloud hosting, but the NewDogRelic Cloud ToS can restrict competing managed services without changing the OSS license. This is not a legal guarantee but a friction layer.
5. **Patent retaliation awareness**: Apache 2.0's patent retaliation clause terminates rights if any licensee sues NewDogRelic over patents. Understand this before filing patents on core protocols.

**Build phase:** Phase 1 (project setup). CLA, SCA in CI, and the core/enterprise module boundary must be established before the first external contributor PR is merged.

---

### Pitfall 9: OpenTelemetry Spec Churn

**What goes wrong:**
The core OTLP protocol signals (traces, metrics, logs) are stable, but the surrounding ecosystem — configuration schemas, profiling signals, SDK versions, and collector internals — has seen significant breaking changes. In Collector v0.119.0 (early 2025), the `protocol` field in OTLP exporter configuration no longer accepted `grpc/protobuf` (only `grpc`), causing startup failures across deployments that had used `grpc/protobuf` as the documented value. Auto-merge of Renovate PRs for OTel SDK upgrades has caused production instrumentation failures at multiple teams.

**Why it happens:**
OpenTelemetry's alpha/beta components (profiling signal, declarative config, semantic conventions for new domains) continue to evolve rapidly. The project uses `-alpha` and `-experimental` suffixes to signal instability, but these are easy to miss during dependency updates. The `opentelemetry-collector-contrib` repository has hundreds of community-maintained receivers and processors, each on their own stability maturity model.

**Consequences:**
- Collector startup failure after routine dependency upgrade (cascading restart loop in Kubernetes)
- Silent dashboard/alert breakage from attribute schema changes (internal logs now use scope attributes instead of log attributes)
- Profiling signal breakage across OTLP protocol refactors
- Canonical signature changes in collector-contrib causing data integrity divergence

**Warning signs (detect early):**
- OTel Collector pods restarting after a dependency update
- Dashboard panels showing "No data" after a collector upgrade
- Alert rules referencing attributes that no longer exist on new collector versions
- Spans arriving with unexpected attribute key names after SDK upgrade

**Prevention strategy:**
1. **Pin collector versions explicitly**: Never use floating `latest` or minor-version pinned OTel Collector images. Pin to exact patch versions. Test upgrades in staging with smoke tests before promoting to production.
2. **Gate Renovate PRs for OTel packages**: Require a human reviewer (not auto-merge) for any PR that updates `go.opentelemetry.io/*`, `opentelemetry-collector`, or `opentelemetry-collector-contrib`. Add a comment template: "Verify OTLP connectivity still works in staging before merging."
3. **OTLP smoke tests in CI**: After each collector upgrade, run a smoke test that sends a test span, metric, and log through the full pipeline and verifies it appears in the query API with the expected schema. This catches attribute schema changes before they reach production.
4. **Stability tier policy**: Only use `stable` or `beta` stability components in the production pipeline. Explicitly ban `alpha` components from the core ingest path. If a capability requires an alpha component (e.g., profiling), isolate it in a separate pipeline with an explicit `alpha; may break` label in documentation.
5. **Semantic convention pinning**: Pin the OTel semantic convention version used for attribute naming. When upgrading semantic conventions, run a migration script that back-fills old attribute names in queries and dashboards before cutting over.
6. **Monitor OTel changelogs**: Subscribe to the `opentelemetry-collector` and `opentelemetry-collector-contrib` GitHub release feeds. Breaking changes are documented in `CHANGELOG.md` but require active monitoring.

**Build phase:** Phase 1 (ingest pipeline setup). Version pinning policy and Renovate PR gates should be in the CI/CD configuration from day one. OTLP smoke tests belong in Phase 2 when the full pipeline is wired together.

---

## Minor Pitfalls

---

### Pitfall 10: Alert Storm and Notification Flooding

**What goes wrong:**
An alert engine that fires per-rule, per-violation without grouping or deduplication causes notification floods. A database cluster with 50 nodes going offline generates 50 PagerDuty incidents if alerts are not grouped. At scale (thousands of tenants, hundreds of alert rules per tenant, frequent service deployments causing transient violations), the alert engine fan-out can produce thousands of notifications per minute. On-call engineers stop trusting alerts and begin ignoring them — the classic alert fatigue failure mode.

**Why it happens:**
Alert engines are typically built first with correctness (every violation fires) and grouping/deduplication is treated as a "nice to have" that is added later. At low scale (tens of alerts), flooding is not a problem. At platform scale (thousands of tenant alert rules evaluated per minute), the missing deduplication logic becomes a critical operational failure.

**Consequences:**
- PagerDuty API rate limits hit during alert storms
- On-call engineers receive notification floods that mask the root cause in noise
- Alert → incident correlation breaks down when multiple incidents are opened for the same root cause
- Customer trust erosion when their alert channels flood from a single incident

**Warning signs (detect early):**
- PagerDuty incident count > 10 for a single deployment event
- On-call engineers reporting "too many alerts, can't tell what's real"
- PagerDuty API rate limit errors in alert sender logs
- Alert rule evaluation latency growing (engine falling behind its evaluation schedule)

**Prevention strategy:**
1. **Fingerprint-based deduplication**: Assign every alert a stable `fingerprint` derived from the alert rule ID + label set (excluding value fields). Use the fingerprint as the PagerDuty `dedup_key`. Subsequent firings of the same alert within the resolution window deduplicate into the existing incident rather than opening new ones.
2. **Grouping with configurable wait windows**: Group related alerts (same `service`, same `environment`, same time window) into a single notification batch. Ship with sensible defaults: `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`. Allow per-tenant customization.
3. **Inhibition rules**: When a high-severity alert fires (e.g., service fully down), suppress lower-severity alerts for the same service (e.g., high error rate, slow response time). These are symptoms of the same root cause and add noise, not signal.
4. **Alert state machine**: Implement OK → PENDING → FIRING → RESOLVED state machine. Only notify on state transitions, not on each evaluation cycle. Require N consecutive violations before transitioning to FIRING (configurable `for` duration, as in Prometheus alerting rules).
5. **Per-tenant notification rate limits**: Cap PagerDuty/Slack API calls per tenant per hour to prevent one tenant's misconfigured alert from exhausting shared notification infrastructure.
6. **High-cardinality group_by trap**: Never use a high-cardinality label as a `group_by` field in the alert router — this recreates the alert storm with no error message, just noise. Validate that `group_by` labels have < 100 distinct values per tenant.

**Build phase:** Phase 4 (alert engine). The state machine and deduplication logic are core requirements, not optional features. Grouping, inhibition, and notification rate limits must be in the initial alert engine design. Shipping an alert engine without these patterns will generate immediate customer complaints.

---

## Phase-Specific Warnings Summary

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Kafka infrastructure setup | Partition keying decisions are permanent; wrong key = noisy neighbor forever | Key on `tenant_id` from day one; never repartition live data |
| OTel Collector ingest pipeline | First version without cardinality enforcement accepts unbounded series | Add attribute processor allowlist before accepting any external data |
| IOx cluster deployment | Underprovisioned compactor causes cascading WAL growth | Provision compactor at 2× expected load from day one; NVMe for WAL |
| Dual-stream (observability vs audit) | Audit logs routed to observability store violates HIPAA | Separate Kafka topics and storage backends from initial architecture |
| Cold tier S3/Parquet design | Partition layout set at first write; wrong layout requires full data rewrite | Decide `tenant_id/dt=YYYY-MM-DD` partition scheme before first flush |
| Trace sampling system | Single-tier tail sampler OOMs at scale; retrofitting two-tier is a full redeployment | Build two-tier (agent → gateway with traceID routing) from the start |
| Multi-tenancy API layer | Per-tenant rate limits added later instead of from initial design | Query gateway must enforce per-tenant limits on first request |
| Alert engine | State machine and deduplication are not "nice to have" | They are correctness requirements; ship or the alert engine is not production-safe |
| Dependency management | OTel library upgrade silently breaks collector config | Pin exact versions; block Renovate auto-merge for OTel packages |
| OSS core vs enterprise boundary | Unclear module boundary makes it hard to enforce later | Define `core/` vs `enterprise/` package structure before first external PR |

---

## Sources

- [Cardinality Explosion — hydrolix.io](https://hydrolix.io/glossary/cardinality-explosion/)
- [How We Reduced OpenTelemetry Metric Cardinality in Production](https://fromdevtoops.substack.com/p/how-we-reduced-opentelemetry-metric)
- [Cardinality Explosions and Other Silent Pipeline Killers — logiciel.io](https://logiciel.io/blog/cardinality-explosions-silent-pipeline-killers/)
- [Kafka Consumer Lag Handling — Conduktor](https://www.conduktor.io/glossary/consumer-lag-monitoring)
- [Backpressure Handling in Streaming Systems — Conduktor](https://www.conduktor.io/glossary/backpressure-handling-in-streaming-systems)
- [We Were Drowning in Kafka Messages — Medium](https://codefarm0.medium.com/we-were-drowning-in-kafka-messages-until-backpressure-saved-the-day-88d898948744)
- [Cut Kafka Lag: 12 Consumer Patterns — Medium](https://medium.com/@Modexa/cut-kafka-lag-12-consumer-patterns-that-work-00e2d4c23d4e)
- [InfluxDB 3 Storage Engine Architecture — InfluxData Docs](https://docs.influxdata.com/influxdb3/cloud-dedicated/reference/internals/storage-engine/)
- [InfluxDB 3.0 System Architecture — InfluxData Blog](https://www.influxdata.com/blog/influxdb-3-0-system-architecture/)
- [InfluxDB 3 (IOx) Deep Dive: Rust + DataFusion + Parquet — pipecode.ai](https://pipecode.ai/blogs/influxdb-3-iox-rust-datafusion-parquet)
- [Scale your InfluxDB cluster — InfluxData Docs](https://docs.influxdata.com/influxdb3/clustered/admin/scale-cluster/)
- [Advanced InfluxDB Troubleshooting for High-Volume Workloads — Mindful Chase](https://mindfulchase.com/explore/troubleshooting-tips/databases/advanced-influxdb-troubleshooting-for-high-volume-time-series-workloads.html)
- [Neverending compaction — InfluxDB GitHub Issue #14426](https://github.com/influxdata/influxdb/issues/14426)
- [Tail Sampling with OpenTelemetry, Measured — DEV Community](https://dev.to/jgomezdev/tail-sampling-with-opentelemetry-measured-it-keeps-what-matters-until-you-scale-it-or-shrink-it-46m5)
- [How to Create Tail-Based Sampling — OneUptime](https://oneuptime.com/blog/post/2026-01-30-tail-based-sampling/view)
- [Stateless OpenTelemetry Collector Architectures — OneUptime](https://oneuptime.com/blog/post/2026-02-06-stateless-opentelemetry-collector-rapid-recovery-scaling/view)
- [HIPAA Audit Logging & Monitoring in SaaS — Trussed.ai](https://feeds.trussed.ai/blog/hipaa-audit-logging-monitoring-saas-applications)
- [5 HIPAA Audit Failures That Kill Healthcare SaaS — OktoPeak](https://oktopeak.com/blog/healthcare-saas-hipaa-audit-failures/)
- [HIPAA Audit Log Requirements — Kiteworks](https://www.kiteworks.com/hipaa-compliance/hipaa-audit-log-requirements/)
- [Noisy neighbors in the OpenTelemetry Kafka receiver — Elastic](https://www.elastic.co/observability-labs/blog/opentelemetry-kafka-receiver-tenant-isolation)
- [Secure Multi-Tenant Kafka: Isolation Patterns — AutoMQ](https://www.automq.com/blog/secure-multi-tenant-kafka-isolation-patterns-platform-teams)
- [The noisy tenants: Engineering fairness in multi-tenant SIEM — CSO Online](https://www.csoonline.com/article/4154546/the-noisy-tenants-engineering-fairness-in-multi-tenant-siem-solutions.html)
- [How I Broke (and Then Fixed) My S3 Data Lake — Medium](https://medium.com/@amar.kumar2013/how-i-broke-and-then-fixed-my-s3-data-lake-a-hard-lesson-in-partitioning-b6c2b5388f07)
- [How Not to Partition Data in S3 — Luminous Men Substack](https://luminousmen.substack.com/p/how-not-to-partition-data-in-s3-and)
- [Supercharging Observability with Parquet — Medium](https://medium.com/@narenreddy.sanikommu/leveraging-parquet-columnar-format-for-observability-data-a-comprehensive-analysis-419ad7208a7a)
- [TimeSeries Tiered Storage Journey — Netflix Tech Blog](https://netflixtechblog.com/timeseries-tiered-storage-journey-kafka-flink-streams-to-native-cassandra-cold-reads-e59d597c9d60)
- [Open Source License Traps For SaaS — Promise Legal](https://blog.promise.legal/startup-central/open-source-license-traps-for-saas-businesses/)
- [BSL and SSPL: the traps of source-available licenses — Servorbit](https://servorbit.com/en/blog/bsl-and-sspl-the-traps-of-source-available-licenses)
- [ClickHouse is Apache 2.0 — Altinity](https://altinity.com/blog/clickhouse-is-apache-2-0)
- [Breaking change: periodic exporter otlp.protocol — OTel Collector GitHub Issue #12332](https://github.com/open-telemetry/opentelemetry-collector/issues/12332)
- [OpenTelemetry Collector CHANGELOG](https://github.com/open-telemetry/opentelemetry-collector/blob/main/CHANGELOG.md)
- [Alert Deduplication and Grouping for OpenTelemetry — OneUptime](https://oneuptime.com/blog/post/2026-02-06-alert-deduplication-grouping-opentelemetry/view)
- [Alertmanager Deep Dive — Medium](https://medium.com/@sre999/alertmanager-deep-dive-mastering-reliable-noise-free-alerting-in-modern-systems-3eb9cb5698d8)
- [Alert Deduplication: How It Works — ITOC 360](https://www.itoc360.com/alert-deduplication/)
- [How to Deploy Grafana Mimir for Multi-Tenant Metrics — OneUptime](https://oneuptime.com/blog/post/2026-02-09-grafana-mimir-multi-tenant/view)
