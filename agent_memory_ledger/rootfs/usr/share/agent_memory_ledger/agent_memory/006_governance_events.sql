-- ==============================================================================
-- Governed Agent Action Ledger — Part 2: Identity Events
-- ==============================================================================
--
-- Append-only identity event history. Every identity transition is recorded
-- here as a first-class event with causal ordering, provenance, and policy
-- context references.
--
-- Identity events are the canonical record of identity lifecycle changes.
-- The governance.identities table is a materialized current-state projection
-- derived from these events.
--
-- Event types:
--   create_identity, retire_identity, alias_identity, split_identity,
--   merge_identity, reclassify_identity, bind_role, unbind_role
--
-- Integration with event_log.agent_events:
--   identity_events may optionally reference a raw agent_event via
--   source_event_id, linking governance decisions back to the originating
--   agent action without duplicating the event schema.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Custom enum for identity event types
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_identity_event_type') THEN
        CREATE TYPE governance_identity_event_type AS ENUM (
            'create_identity',
            'retire_identity',
            'alias_identity',
            'split_identity',
            'merge_identity',
            'reclassify_identity',
            'bind_role',
            'unbind_role'
        );
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- governance.identity_events
-- Append-only. No UPDATE or DELETE permitted (enforced by trigger in
-- 011_governance_constraints.sql).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.identity_events (
    event_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type          governance_identity_event_type NOT NULL,
    occurred_at         TIMESTAMPTZ NOT NULL,
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Who performed this action (NULL for system-initiated events)
    actor_identity_id   UUID REFERENCES governance.identities(identity_id) DEFERRABLE INITIALLY DEFERRED,

    -- Which identity is the target of this event
    target_identity_id  UUID NOT NULL REFERENCES governance.identities(identity_id) DEFERRABLE INITIALLY DEFERRED,

    -- Policy context: which policy version governed this transition
    policy_version_id   UUID,  -- FK added after policy_versions table exists

    -- Optional link back to the raw agent event that triggered this
    source_event_id     UUID,  -- FK to event_log.agent_events(id) added separately

    -- Structured payload (event-type-specific data)
    payload             JSONB NOT NULL DEFAULT '{}',

    -- Provenance: who/what/where/why this event was created
    provenance          JSONB NOT NULL DEFAULT '{}',

    -- Additional metadata (correlation IDs, trace IDs, etc.)
    metadata            JSONB NOT NULL DEFAULT '{}',

    -- occurred_at is supplied by callers; recorded_at captures insert time.
    CONSTRAINT chk_identity_events_recorded_after_occurred
        CHECK (recorded_at >= occurred_at)
);

-- Index for querying events by target identity (temporal order)
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_target
    ON governance.identity_events (target_identity_id, occurred_at DESC);

-- Index for querying events by actor
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_actor
    ON governance.identity_events (actor_identity_id)
    WHERE actor_identity_id IS NOT NULL;

-- Index for querying events by type
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_type
    ON governance.identity_events (event_type);

-- Index for temporal queries
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_occurred_at
    ON governance.identity_events (occurred_at DESC);

-- GIN index for payload queries
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_payload_gin
    ON governance.identity_events USING GIN (payload jsonb_path_ops);

-- GIN index for provenance queries
CREATE INDEX IF NOT EXISTS idx_governance_identity_events_provenance_gin
    ON governance.identity_events USING GIN (provenance jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- Add FK from identity_role_bindings.binding_event_id to identity_events
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'governance'
          AND table_name = 'identity_role_bindings'
          AND column_name = 'binding_event_id'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_role_bindings_binding_event'
          AND table_schema = 'governance'
          AND table_name = 'identity_role_bindings'
    ) THEN
        ALTER TABLE governance.identity_role_bindings
            ADD CONSTRAINT fk_role_bindings_binding_event
            FOREIGN KEY (binding_event_id)
            REFERENCES governance.identity_events(event_id);
    END IF;
END $$;

COMMIT;
