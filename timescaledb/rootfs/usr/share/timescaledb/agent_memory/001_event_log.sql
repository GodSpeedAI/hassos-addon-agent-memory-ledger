-- ==============================================================================
-- Agent Memory Schema: Event Log
-- Append-only agent event ledger with idempotent ingestion
-- ==============================================================================
-- Idempotent: safe to run multiple times (CREATE IF NOT EXISTS pattern)

BEGIN;

-- Create the event_log schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS event_log;

-- Append-only agent event ledger
CREATE TABLE IF NOT EXISTS event_log.agent_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_agent    TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}',
    idempotency_key TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Ensure idempotent ingestion: one event per idempotency_key per source
    CONSTRAINT uq_agent_events_idempotency UNIQUE (source_agent, idempotency_key)
);

-- GIN index for fast JSONB queries
CREATE INDEX IF NOT EXISTS idx_agent_events_payload_gin
    ON event_log.agent_events USING GIN (payload jsonb_path_ops);

-- Index for time-range queries
CREATE INDEX IF NOT EXISTS idx_agent_events_created_at
    ON event_log.agent_events (created_at DESC);

-- Index for source_agent lookups
CREATE INDEX IF NOT EXISTS idx_agent_events_source_agent
    ON event_log.agent_events (source_agent);

-- Index for event_type lookups
CREATE INDEX IF NOT EXISTS idx_agent_events_event_type
    ON event_log.agent_events (event_type);

-- Convert to hypertable if TimescaleDB is available
-- This is done separately in the init script after checking extension availability

COMMIT;
