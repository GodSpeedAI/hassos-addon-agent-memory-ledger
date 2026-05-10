-- ==============================================================================
-- Agent Memory Schema: Oxigraph Projection State Tracking
-- Tracks RDF projection progress for resumable, idempotent projection
-- ==============================================================================
-- Idempotent: safe to run multiple times
--
-- CRITICAL: This table tracks projection state ONLY.
-- It does NOT store canonical data. Canonical data lives in event_log,
-- governance, and memory schemas. Oxigraph is a rebuildable derived projection.
-- ==============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS kg;

-- ---------------------------------------------------------------------------
-- kg.oxigraph_projection_state
-- Tracks the last projected event/record for each projection category.
-- Used by the projection worker to resume from the last checkpoint.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kg.oxigraph_projection_state (
    projection_name   TEXT PRIMARY KEY,
    last_event_time   TIMESTAMPTZ,
    last_event_id     UUID,
    last_projected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status            TEXT NOT NULL DEFAULT 'idle',
    error             TEXT,
    metadata          JSONB NOT NULL DEFAULT '{}',

    -- Status must be one of the known states
    CONSTRAINT chk_projection_status CHECK (
        status IN ('idle', 'running', 'completed', 'error', 'disabled')
    )
);

-- Index for finding projections that need attention
CREATE INDEX IF NOT EXISTS idx_oxigraph_projection_status
    ON kg.oxigraph_projection_state (status)
    WHERE status IN ('error', 'running');

COMMIT;
