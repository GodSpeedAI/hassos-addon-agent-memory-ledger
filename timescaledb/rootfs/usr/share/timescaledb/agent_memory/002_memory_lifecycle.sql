-- ==============================================================================
-- Agent Memory Schema: Memory Lifecycle Tables
-- observed → candidate → accepted → verified → superseded/rejected/expired
-- ==============================================================================
-- Idempotent: safe to run multiple times

BEGIN;

CREATE SCHEMA IF NOT EXISTS memory;

-- Enum-like type for memory item status
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'memory_status') THEN
        CREATE TYPE memory_status AS ENUM (
            'observed',
            'candidate',
            'accepted',
            'verified',
            'superseded',
            'rejected',
            'expired'
        );
    END IF;
END $$;

-- Core memory items table
CREATE TABLE IF NOT EXISTS memory.items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_event_id UUID REFERENCES event_log.agent_events(id) ON DELETE SET NULL,
    source_agent    TEXT NOT NULL,
    memory_type     TEXT NOT NULL DEFAULT 'fact',
    content         TEXT NOT NULL,
    summary         TEXT,
    status          memory_status NOT NULL DEFAULT 'observed',
    confidence      REAL DEFAULT 0.0 CHECK (confidence >= 0.0 AND confidence <= 1.0),
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,

    -- Prevent duplicate memory items from the same source event
    CONSTRAINT uq_memory_items_source_event UNIQUE (source_event_id)
);

-- Index for status-based queries (lifecycle transitions)
CREATE INDEX IF NOT EXISTS idx_memory_items_status
    ON memory.items (status);

-- Index for source_agent lookups
CREATE INDEX IF NOT EXISTS idx_memory_items_source_agent
    ON memory.items (source_agent);

-- Index for memory_type lookups
CREATE INDEX IF NOT EXISTS idx_memory_items_memory_type
    ON memory.items (memory_type);

-- Index for time-range queries
CREATE INDEX IF NOT EXISTS idx_memory_items_created_at
    ON memory.items (created_at DESC);

-- Index for confidence threshold queries
CREATE INDEX IF NOT EXISTS idx_memory_items_confidence
    ON memory.items (confidence DESC);

-- GIN index for metadata JSONB queries
CREATE INDEX IF NOT EXISTS idx_memory_items_metadata_gin
    ON memory.items USING GIN (metadata jsonb_path_ops);

-- Index for expiration cleanup
CREATE INDEX IF NOT EXISTS idx_memory_items_expires_at
    ON memory.items (expires_at) WHERE expires_at IS NOT NULL;

-- Memory lifecycle audit trail
CREATE TABLE IF NOT EXISTS memory.lifecycle_audit (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_item_id  UUID NOT NULL REFERENCES memory.items(id) ON DELETE CASCADE,
    old_status      memory_status,
    new_status      memory_status NOT NULL,
    changed_by      TEXT NOT NULL DEFAULT 'system',
    reason          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for auditing a specific memory item's history
CREATE INDEX IF NOT EXISTS idx_lifecycle_audit_memory_item_id
    ON memory.lifecycle_audit (memory_item_id, created_at DESC);

COMMIT;
