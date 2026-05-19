-- ==============================================================================
-- Agent Memory Schema: Migration Tracking
-- Tracks which schema versions have been applied to the database.
-- ==============================================================================
--
-- Idempotent: safe to run multiple times.
--
-- This is the FIRST schema file applied (000). It must be applied before any
-- numbered migration (001-NNN) so the tracking table exists when the init
-- script checks migration state.
--
-- Migration discipline:
--   - Each numbered SQL file (001, 002, ...) is a migration.
--   - The init script computes a sha256 checksum before applying.
--   - If a version is not recorded, it is applied and recorded.
--   - If a version is recorded with the same checksum, it is skipped.
--   - If a version is recorded with a different checksum, the init script
--     fails closed (production) or warns loudly (developer_mode).
--   - Future schema changes MUST add new numbered SQL files, not edit
--     existing ones.
--
-- This table is append-only. Do not DELETE or UPDATE rows.
-- ==============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS agent_memory;

CREATE TABLE IF NOT EXISTS agent_memory.schema_migrations (
    version     TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    checksum    TEXT NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for quick version lookups (primary key already provides this,
-- but explicit for clarity)
CREATE UNIQUE INDEX IF NOT EXISTS idx_schema_migrations_version
    ON agent_memory.schema_migrations (version);

COMMIT;
