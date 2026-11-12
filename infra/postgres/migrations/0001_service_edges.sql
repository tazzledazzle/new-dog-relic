-- infra/postgres/migrations/0001_service_edges.sql
--
-- Creates the service_edges table for the Phase 3 Service Map Processor.
--
-- This table is shipped EMPTY in Phase 1 so Phase 3 does not need a schema migration PR.
-- The table will be populated by the OTel Collector servicegraph connector in Phase 3.
--
-- SECURITY NOTE (T-01-16): The table has a tenant_id column in its UNIQUE constraint.
-- The query layer (Phase 4) MUST scope every read by tenant_id — do NOT allow cross-tenant
-- queries on this table. Without tenant_id scoping, a query for one tenant would reveal
-- service names from other tenants (Information Disclosure).

CREATE TABLE IF NOT EXISTS service_edges (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       TEXT NOT NULL,
  caller_service  TEXT NOT NULL,
  callee_service  TEXT NOT NULL,
  protocol        TEXT NOT NULL,
  call_kind       TEXT,
  last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  first_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  request_count   BIGINT NOT NULL DEFAULT 0,
  error_count     BIGINT NOT NULL DEFAULT 0,
  UNIQUE (tenant_id, caller_service, callee_service, protocol)
);

CREATE INDEX IF NOT EXISTS idx_service_edges_tenant_last_seen
  ON service_edges (tenant_id, last_seen DESC);

COMMENT ON TABLE service_edges IS
  'Precomputed service dependency edges; populated by Phase 3 Service Map Processor from OTel Collector servicegraph connector. Table shipped empty in Phase 1 so Phase 3 does not need a schema migration PR. SECURITY: query layer MUST always filter by tenant_id (see T-01-16 in Phase 1 threat model).';

COMMENT ON COLUMN service_edges.tenant_id IS
  'Tenant identifier. Part of the UNIQUE constraint — no row can represent a cross-tenant edge.';

COMMENT ON COLUMN service_edges.call_kind IS
  'OTel span kind (e.g., CLIENT, SERVER, INTERNAL). Nullable — populated when available from servicegraph connector.';

COMMENT ON COLUMN service_edges.request_count IS
  'Cumulative call count since first_seen. Incremented by UPSERT in Phase 3.';

COMMENT ON COLUMN service_edges.error_count IS
  'Cumulative error count since first_seen. An error is any span with status code ERROR.';
