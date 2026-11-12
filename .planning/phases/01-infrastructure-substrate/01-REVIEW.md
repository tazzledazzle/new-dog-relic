---
phase: 01-infrastructure-substrate
reviewed: 2026-11-12T00:00:00Z
depth: standard
files_reviewed: 20
files_reviewed_list:
  - .env.example
  - docker-compose.audit.yml
  - docker-compose.iox.yml
  - docker-compose.yml
  - docs/decisions/0001-iox-warm-tier-strategy.md
  - docs/decisions/0002-cold-tier-partition-scheme.md
  - infra/audit/audit-router.yaml
  - infra/iox/bootstrap.sh
  - infra/iox/namespaces.json
  - infra/kafka/README.md
  - infra/kafka/create-topics.sh
  - infra/minio/bootstrap.sh
  - infra/minio/buckets.json
  - infra/postgres/bootstrap.sh
  - infra/postgres/migrations/0001_service_edges.sql
  - scripts/smoke/audit-isolation.sh
  - scripts/smoke/cold-partition.sh
  - scripts/smoke/iox-roundtrip.sh
  - scripts/smoke/kafka-topology.sh
  - scripts/smoke/phase1-full.sh
findings:
  critical: 7
  warning: 8
  info: 4
  total: 19
status: issues_found
---

# Phase 1: Code Review Report

**Reviewed:** 2026-11-12T00:00:00Z
**Depth:** standard
**Files Reviewed:** 20
**Status:** issues_found

## Summary

This review covers the Phase 1 infrastructure substrate: Docker Compose definitions, shell bootstrap scripts, Kafka topic creation, MinIO bucket provisioning, IOx namespace initialization, Postgres DDL, OTel Collector audit router config, and smoke test scripts.

The overall structure is intentional and well-documented. The critical findings cluster around three themes: (1) credential injection vulnerabilities in bootstrap scripts that construct JSON/shell strings directly from environment variables, (2) HIPAA compliance gaps in the audit pipeline that undermine the core security guarantee, and (3) correctness bugs in smoke test logic that allow failures to pass silently. Several warnings address idempotency gaps, unpinned image tags, and logic errors in health-check loops.

---

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: JSON Injection via Unquoted `$DB_NAME` and `$RETENTION_HOURS` in `infra/iox/bootstrap.sh`

**File:** `infra/iox/bootstrap.sh:113`
**Issue:** The JSON body is constructed by direct shell variable interpolation into a string:
```bash
-d "{\"db\": \"$DB_NAME\", \"retention_period_hours\": $RETENTION_HOURS}"
```
`$DB_NAME` is read from `namespaces.json` via `jq -r`. A database name containing a double-quote, backslash, or JSON control character (e.g., `foo","retention_period_hours":0,"extra":"` ) would break out of the JSON string and inject arbitrary fields into the API request body. While `namespaces.json` is currently developer-controlled, this is the same input path that future automation or multi-tenant provisioning flows will use. `$RETENTION_HOURS` is an integer passed without quotes, which is correct for numbers, but `$DB_NAME` must be JSON-escaped.

**Fix:** Use `jq` to construct the JSON body safely instead of string interpolation:
```bash
JSON_BODY=$(jq -n \
  --arg db "$DB_NAME" \
  --argjson hours "$RETENTION_HOURS" \
  '{"db": $db, "retention_period_hours": $hours}')

HTTP_STATUS=$(curl -s -o /tmp/iox-create-response.json -w "%{http_code}" \
  -X POST "$IOX_URL/api/v3/configure/database" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$JSON_BODY")
```

---

### CR-02: Credential Leakage via `$TOKEN` in Shell Argument List

**File:** `infra/iox/bootstrap.sh:109-114`, `scripts/smoke/iox-roundtrip.sh:42-45,56`
**Issue:** `$TOKEN` (the IOx auth bearer token) is passed directly in curl command-line arguments via `-H "Authorization: Bearer $TOKEN"`. On Linux, process arguments are visible in `/proc/<pid>/cmdline` and in the output of `ps aux` to any process on the same host (including other Docker containers with host PID namespace access). In a CI environment, build logs commonly capture process trees.

For local dev this is acceptable by design (the token is `local-dev-token`), but the pattern will be copy-pasted into production scripts verbatim (Phase 2+) unless it is flagged now.

**Fix:** Pass credentials via a file or environment variable read by curl, never as a command-line argument visible to `ps`:
```bash
# Write a curl config file
CURL_CFG=$(mktemp)
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CURL_CFG"
trap 'rm -f "$CURL_CFG"' EXIT

HTTP_STATUS=$(curl -s -K "$CURL_CFG" -o /tmp/iox-create-response.json -w "%{http_code}" \
  -X POST "$IOX_URL/api/v3/configure/database" \
  -H "Content-Type: application/json" \
  -d "$JSON_BODY")
```

---

### CR-03: `aws-sigv4` Fallback in `infra/iox/bootstrap.sh` Passes Credentials on Command Line

**File:** `infra/iox/bootstrap.sh:65-68`
**Issue:** The `--user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}"` curl argument places the MinIO access key and secret key on the process command line. On Linux these are visible in `/proc/<pid>/cmdline` and `ps aux`. This is distinct from CR-02: here the values are `S3_ACCESS_KEY` and `S3_SECRET_KEY`, not the IOx token. Additionally, `--aws-sigv4` with `--user` is a curl 7.75+ feature; older curl versions on some CI images will silently ignore it and produce unsigned (and thus rejected) requests, returning HTTP 403 that the script treats as a warning rather than an error.

**Fix:** Use the AWS CLI environment variables pattern instead (which is already used in the primary path), or write credentials to `~/.aws/credentials` / a temp file and clean up:
```bash
RESPONSE=$(AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket ndr-iox --region us-east-1 2>&1 \
  || true)
```
Since `aws` is checked for in the `if` branch above, the fallback should also attempt `awscurl` or document the minimum curl version requirement clearly.

---

### CR-04: `minio/minio:latest` Image Tag — Uncontrolled Upgrade Risk and MinIO Object Lock Regression

**File:** `docker-compose.yml:87`
**Issue:** `image: minio/minio:latest` is an unpinned tag. MinIO has broken S3 API compatibility in minor releases (notably the RELEASE.2022-10-24 series changed Object Lock behavior). An uncontrolled upgrade of the MinIO image can silently change Object Lock semantics, potentially causing the `ndr-audit` GOVERNANCE mode retention test in `audit-isolation.sh` to pass locally but fail against an older or newer version. For a HIPAA-grade system, the exact MinIO version must be reproducible and validated.

This is classified Critical — not Warning — because the HIPAA audit Object Lock guarantee is a data-loss/compliance risk if the wrong MinIO version is pulled in a shared or CI environment.

**Fix:** Pin to a specific MinIO release digest or dated tag:
```yaml
image: minio/minio:RELEASE.2024-10-13T13-34-11Z
```
Check the MinIO GitHub releases page for the latest stable tag. Use a dated release tag, not `latest`.

---

### CR-05: Postgres `bootstrap.sh` Logs Full Connection URL Including Password

**File:** `infra/postgres/bootstrap.sh:16`
**Issue:**
```bash
echo "==> Postgres bootstrap: target $POSTGRES_URL"
```
`$POSTGRES_URL` is `postgres://ndr:ndr@localhost:5432/ndr_catalog`. This prints the plaintext password to stdout. In CI/CD pipelines, build logs are stored and may be accessible to developers without DBA access. For the Phase 1 dev value this is benign, but bootstrap scripts are templates — this exact line will be copy-pasted into staging/production bootstrap automation with real credentials.

**Fix:** Redact the password before logging:
```bash
SAFE_URL=$(echo "$POSTGRES_URL" | sed 's|://[^:]*:[^@]*@|://***:***@|')
echo "==> Postgres bootstrap: target $SAFE_URL"
```

---

### CR-06: `audit-isolation.sh` Step 4 — Object Lock Check Is Non-Fatal (Silent Compliance Bypass)

**File:** `scripts/smoke/audit-isolation.sh:81-88`
**Issue:** The Object Lock check deliberately downgrades a failed assertion to a warning:
```bash
if ! echo "$HEAD_OUTPUT" | grep -qi "ObjectLockMode\|GOVERNANCE"; then
  echo "WARN: ObjectLockMode not found in head-object response."
  ...
  echo "  Continuing with WORM-delete test..."
fi
```
If `head-object` does not return `ObjectLockMode` (which happens when MinIO was started from a volume that existed before Object Lock was configured, or with certain MinIO versions), the script continues and may still pass the WORM-delete test due to unrelated 403 errors (e.g., missing permissions). The Object Lock mode assertion is part of the HIPAA compliance verification. Making it non-fatal means the audit smoke test can pass even if Object Lock is not active.

**Fix:** Make the Object Lock mode assertion fatal, with a clear remediation message:
```bash
if ! echo "$HEAD_OUTPUT" | grep -qi "ObjectLockMode\|GOVERNANCE"; then
  echo "FAIL: ObjectLockMode GOVERNANCE not confirmed on audit object." >&2
  echo "  The ndr-audit bucket may not have Object Lock enabled." >&2
  echo "  Remediation: docker compose down -v && bash infra/minio/bootstrap.sh" >&2
  exit 1
fi
```

---

### CR-07: `iox-roundtrip.sh` Constructs SQL Query String Without Escaping — SQL Injection in Smoke Test

**File:** `scripts/smoke/iox-roundtrip.sh:52-56`
**Issue:** The `iox_query` function takes a raw SQL string and inlines it directly into a JSON body:
```bash
-d "{\"db\": \"${db}\", \"q\": ${sql}, \"format\": \"json\"}"
```
The `sql` parameter itself is a bare shell string passed at the call site with embedded single-quoted values. While this is a smoke test rather than production code, smoke tests are frequently adapted into integration test harnesses or operational tooling. Additionally, the IOx endpoint receives this JSON and may interpret malformed input differently across versions. Any test value with a double-quote in the measurement name or field value will produce malformed JSON sent to IOx, making failures hard to diagnose.

More importantly, the `$db` variable (the database name) is also interpolated directly without JSON escaping, creating the same injection vector as CR-01 for the query endpoint.

**Fix:** Use `jq` to construct the query JSON safely:
```bash
iox_query() {
  local db="$1"
  local sql="$2"
  local body
  body=$(jq -n --arg db "$db" --arg q "$sql" '{"db": $db, "q": $q, "format": "json"}')
  curl -s \
    -X POST "${IOX_URL}/api/v3/query_sql" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body"
}
```

---

## Warnings

### WR-01: `docker-compose.yml` and `docker-compose.iox.yml` — Unpinned Image Tags for `bitnami/kafka` and `influxdb:3-core`

**File:** `docker-compose.yml:24`, `docker-compose.iox.yml:16`
**Issue:** `image: bitnami/kafka:3.7` pins a minor version but not a patch version or digest. `image: influxdb:3-core` pins only a stream tag, not a release. Both are noted in comments as "replace with pinned digest before shared environment deployment," but that future action is not enforced or tracked. In a team setting, `docker compose pull` will silently pick up new patch releases, which may change behavior. For a Kafka version bump, this risks partition format changes or KRaft protocol changes that invalidate the `kafka-data` volume.

**Fix:** Pin both to a specific digest or patch tag and add a comment tracking the pinning ticket:
```yaml
image: bitnami/kafka:3.7.1   # pin patch; update via tracked PR
image: influxdb:3.0.1-core   # pin patch; update via tracked PR
```

---

### WR-02: `infra/minio/bootstrap.sh` — `mc alias set` Passes Credentials as Command-Line Arguments

**File:** `infra/minio/bootstrap.sh:35`
**Issue:**
```bash
$MC alias set local "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" > /dev/null
```
The `mc` command is run via `docker run` with the access key and secret key as positional arguments. These are visible in `docker inspect` for the exited container and in the host's process table during execution. A `docker events` listener or `/proc` reader on the host could capture them.

**Fix:** Pass credentials via the `MC_HOST_<alias>` environment variable, which the script already sets correctly in the `MC` variable definition (line 30). Remove the `mc alias set` call entirely — the `MC_HOST_local` env var is sufficient:
```bash
# MC_HOST_local is already set in the $MC docker run invocation.
# The explicit 'mc alias set' call is redundant and leaks credentials on the CLI.
# Remove line 35 entirely.
```

---

### WR-03: `infra/postgres/bootstrap.sh` — `ls` in Command Substitution Is Not Portable and Fails on Spaces

**File:** `infra/postgres/bootstrap.sh:36`
**Issue:**
```bash
for SQL_FILE in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
```
Parsing `ls` output in a shell loop is a known anti-pattern (ShellCheck SC2045). File names containing spaces or glob characters will cause word-splitting failures. With `set -euo pipefail`, if `$MIGRATIONS_DIR/*.sql` matches no files, `ls` exits non-zero, terminating the script before the verification step.

**Fix:** Use a glob directly:
```bash
for SQL_FILE in $(echo "$MIGRATIONS_DIR"/*.sql | tr ' ' '\n' | sort); do
```
Or more robustly with `find` or a glob array:
```bash
while IFS= read -r -d '' SQL_FILE; do
  echo "  Applying: $(basename "$SQL_FILE")"
  psql "$POSTGRES_URL" -f "$SQL_FILE"
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -name '*.sql' -print0 | sort -z)
```

---

### WR-04: `audit-router.yaml` — `disable_ssl: true` Is a HIPAA Compliance Risk

**File:** `infra/audit/audit-router.yaml:37`
**Issue:**
```yaml
disable_ssl: true
```
The audit router writes HIPAA audit events to the MinIO bucket over HTTP (not HTTPS), because `disable_ssl: true` disables TLS for the S3 uploader. For local dev this is intentional, but this config file is a template that will be carried into staging/production. HIPAA 45 CFR §164.312(e)(1) requires encryption of PHI in transit. Audit log events may contain PHI-adjacent data (tenant IDs, actor IDs, accessed resource identifiers). Without TLS between the audit-router and the object store, audit events transit in plaintext.

The file contains no environment-variable substitution for `disable_ssl`, making it impossible to toggle this behavior between environments without editing the file.

**Fix:** Make `disable_ssl` an environment-variable-driven flag and default it to `false`. The OTel Collector Contrib `awss3exporter` does not currently support env-var substitution for all fields, so the recommended approach is to maintain a separate `audit-router.prod.yaml` with `disable_ssl: false` and enforce its use in production via Helm/Kustomize. Add a comment:
```yaml
      # LOCAL DEV ONLY — set disable_ssl: false and configure cert-manager TLS in production.
      # See CLAUDE.md Layer 8 (TLS everywhere: cert-manager + Let's Encrypt / internal CA).
      disable_ssl: true
```
And track the production config override as a Phase 7 deliverable in STATE.md.

---

### WR-05: `phase1-full.sh` Service Health Check Uses `python3` Inline Script That Silently Returns `unknown` on Parse Failure

**File:** `scripts/smoke/phase1-full.sh:70-89`
**Issue:** The service health check embeds a Python 3 script inside a shell `$()` substitution. The Python script has a bare `except:` clause that swallows all exceptions and falls through to `print(state)` where `state` defaults to `'missing'`. If `docker compose ps --format json` changes output format between Docker Compose versions (e.g., v2.20+ changed the JSON schema for `Health` vs `State`), the Python script will silently return `'missing'` for every service, causing the outer loop to spin until timeout — with no indication of what went wrong.

**Fix:** Use `docker compose ps` with `--filter` and `--format` flags that are more version-stable, or directly check `docker inspect`:
```bash
SVC_STATE=$(docker inspect "ndr-${SVC}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
```
This avoids the embedded Python script entirely.

---

### WR-06: `create-topics.sh` — `retention.ms` for Observability Topics Hardcodes a Value That Conflicts With the Stated Retention Model

**File:** `infra/kafka/create-topics.sh:62-63`
**Issue:**
```bash
--config retention.ms=259200000 \  # 72 hours
```
The comment says "hot tier limit; warm tier handled by IOx." However, `ndr.metrics.raw`, `ndr.logs.raw`, and `ndr.traces.raw` are Kafka ingest topics — they are upstream of IOx, not downstream. Kafka's `retention.ms` on these topics controls how long unconsumed messages are retained on the broker. A consumer lag event (the IOx ingest worker falls behind) causes messages older than 72 hours to be permanently deleted from Kafka before they are written to IOx, resulting in silent data loss.

For an ingest topic, the Kafka retention should be generous enough to cover consumer lag recovery windows, not tied to storage tier retention. The industry standard for ingest topics is 7 days (168 hours) or longer, with the IOx 72h hot-tier boundary enforced at the write path (the consumer), not at the Kafka broker.

**Fix:** Increase `retention.ms` for observability ingest topics to at least 7 days (or make it configurable). Keep `ndr.audit` retention at 48h:
```bash
--config retention.ms=604800000  # 7 days — ingest buffer; IOx enforces 72h hot-tier at write time
```
Update `infra/kafka/README.md` to document this distinction explicitly.

---

### WR-07: `minio/bootstrap.sh` — Retention Not Applied When Bucket Already Exists on First Run After Volume Loss

**File:** `infra/minio/bootstrap.sh:58-76`
**Issue:** The script's idempotency logic is:
```bash
if $MC ls "local/$NAME" &>/dev/null; then
  echo "  SKIP: bucket '$NAME' already exists (idempotent run)"
else
  # create bucket
fi

# Apply default retention if specified
if [[ "$RET_MODE" != "null" && "$RET_DAYS" != "0" ]]; then
  $MC retention set --default ...
fi
```
On an existing bucket (the `SKIP` branch), the script still runs `mc retention set --default` unconditionally after the if/else block. This is actually correct for re-applying retention on existing buckets. However, if `mc mb --with-lock` succeeds but the subsequent `mc retention set --default` fails (network hiccup, MinIO restart), the bucket exists with Object Lock enabled but no default retention period. On the next run, the `SKIP` branch executes, the retention set command is retried — but `mc retention set` on an existing Object Lock bucket may fail silently if the bucket is non-empty or if the MinIO version requires `--bypass-governance-mode` for existing objects.

There is no verification step that confirms the GOVERNANCE/2190d retention is actually active after the script completes. The `mc retention info` call at the end (line 87-89) prints but does not assert.

**Fix:** Assert the expected retention after setting it:
```bash
RETENTION_INFO=$($MC retention info "local/$NAME" 2>&1)
if ! echo "$RETENTION_INFO" | grep -qi "${RET_MODE}"; then
  echo "ERROR: Retention mode ${RET_MODE} not confirmed on bucket $NAME after set!" >&2
  exit 1
fi
```

---

### WR-08: `audit-isolation.sh` Negative Grep Check Has Incorrect Path Scope

**File:** `scripts/smoke/audit-isolation.sh:115`
**Issue:**
```bash
AUDIT_CG_MATCHES=$(grep -r 'ndr-audit-cg' infra/ 2>/dev/null || true)
```
This `grep` is run from the current working directory without specifying the repo root. If the script is invoked from any directory other than the repo root (e.g., `bash scripts/smoke/audit-isolation.sh` from within `scripts/smoke/`), the path `infra/` will not resolve and `grep` will silently find nothing, causing the negative check to always pass. The same issue applies to the `grep -r 'ndr\.audit' infra/` call on line 128.

**Fix:** Anchor the path to the script's directory using `SCRIPT_DIR`:
```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_CG_MATCHES=$(grep -r 'ndr-audit-cg' "${REPO_ROOT}/infra/" 2>/dev/null || true)
```

---

## Info

### IN-01: `docker-compose.yml` — `redpanda-console` Uses `latest` Tag

**File:** `docker-compose.yml:112`
**Issue:** `image: docker.redpanda.com/redpandadata/console:latest` is unpinned. This is lower severity than CR-04 (MinIO) because Redpanda Console is a read-only Kafka UI with no effect on data durability or HIPAA compliance. However, an uncontrolled console upgrade could break the UI for developers or introduce security vulnerabilities.

**Fix:** Pin to a specific Redpanda Console version, e.g. `docker.redpanda.com/redpandadata/console:v2.6.1`.

---

### IN-02: `iox-roundtrip.sh` — `sleep 2` WAL Flush Assumption Is Fragile Under Load

**File:** `scripts/smoke/iox-roundtrip.sh:99,113,127`
**Issue:** Each write is followed by `sleep 2` before the read-back query. This assumes IOx flushes the WAL to queryable state within 2 seconds. Under CPU or I/O contention (e.g., CI runners), WAL flush may take longer, causing the query to return empty results and the test to fail transiently. The `assert_contains` function counts this as `FAIL=$((FAIL + 1))` but continues rather than failing fast, so the test may report 2-3 assertion failures that are entirely timing-related.

**Fix:** Add a retry loop with backoff for the query instead of a fixed sleep:
```bash
query_with_retry() {
  local db="$1" sql="$2" needle="$3" max_attempts=5
  for attempt in $(seq 1 $max_attempts); do
    result=$(iox_query "$db" "$sql")
    if echo "$result" | grep -q "$needle"; then
      echo "$result"; return 0
    fi
    sleep $(( attempt * 2 ))
  done
  echo "$result"
  return 1
}
```

---

### IN-03: `service_edges` Table Missing Row-Level Security (RLS) for Multi-Tenant Isolation

**File:** `infra/postgres/migrations/0001_service_edges.sql:13-25`
**Issue:** The `service_edges` table has a `tenant_id` column and a security note in the comment requiring the query layer to filter by `tenant_id`. However, there is no Postgres Row Level Security (RLS) policy enforcing this. If the Phase 4 query layer ever issues a query without a `tenant_id` predicate (a programming mistake or SQL injection), all tenants' service edges are exposed. The comment at line 10 documents the risk but does not enforce it at the database layer.

**Fix:** Enable RLS on the table and add a policy that restricts rows to the current setting of a Postgres session variable (which the query layer sets per-request):
```sql
ALTER TABLE service_edges ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON service_edges
  USING (tenant_id = current_setting('app.current_tenant_id', true));
```
Document that the Phase 4 connection pool must call `SET LOCAL app.current_tenant_id = $1` on each query. This is defense-in-depth for T-01-16.

---

### IN-04: `kafka-topology.sh` — `grep -oP` Uses Perl Regex Which Is Not POSIX and Fails on macOS Default `grep`

**File:** `scripts/smoke/kafka-topology.sh:134-135`
**Issue:**
```bash
ALPHA_PARTITIONS=$(echo "$CONSUME_OUTPUT" | grep "t-alpha" | grep -oP 'Partition:\K[0-9]+' | sort -u)
```
`grep -oP` requires Perl-compatible regex support. macOS ships BSD `grep` which does not support `-P`. Running this script from a macOS dev machine (the stated environment is Darwin) will produce `grep: invalid option -- P` and `$ALPHA_PARTITIONS` will be empty, causing the subsequent assertion on line 141 to fail with "No t-alpha messages found."

**Fix:** Use `sed` or `awk` for the extraction instead:
```bash
ALPHA_PARTITIONS=$(echo "$CONSUME_OUTPUT" | grep "t-alpha" | sed -n 's/Partition:\([0-9]*\).*/\1/p' | sort -u)
```

---

_Reviewed: 2026-11-12T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
