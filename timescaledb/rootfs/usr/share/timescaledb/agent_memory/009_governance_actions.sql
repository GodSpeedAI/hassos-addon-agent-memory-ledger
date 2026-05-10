-- ==============================================================================
-- Governed Agent Action Ledger — Part 6: Action Requests + Admission Decisions
-- ==============================================================================
--
-- Action requests represent governed operations that an identity wants to
-- perform. Every request results in an admission decision that references
-- the identity state, lineage state, policy version, and request payload.
--
-- This design preserves sufficient context to replay governance reasoning
-- later without implementing a full policy engine.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS governance;

-- ---------------------------------------------------------------------------
-- Custom enums
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_action_type') THEN
        CREATE TYPE governance_action_type AS ENUM (
            'tool_call',
            'memory_write',
            'file_write',
            'network_request',
            'email_send',
            'command_execute',
            'policy_override_request'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_decision') THEN
        CREATE TYPE governance_decision AS ENUM (
            'accepted',
            'rejected',
            'requires_review',
            'deferred'
        );
    END IF;
END $$;

DO $$
BEGIN
    IF to_regclass('governance.identities') IS NULL THEN
        RAISE EXCEPTION 'governance.identities must exist before applying 009_governance_actions.sql';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- governance.action_requests
-- Append-only record of governed action requests.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.action_requests (
    request_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requesting_identity_id  UUID NOT NULL REFERENCES governance.identities(identity_id),
    requested_action_type   governance_action_type NOT NULL,
    requested_resource      TEXT,
    payload                 JSONB NOT NULL DEFAULT '{}',
    occurred_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    provenance              JSONB NOT NULL DEFAULT '{}',
    metadata                JSONB NOT NULL DEFAULT '{}'
);

-- Index for querying requests by identity
CREATE INDEX IF NOT EXISTS idx_governance_action_requests_identity
    ON governance.action_requests (requesting_identity_id, occurred_at DESC);

-- Index for querying requests by action type
CREATE INDEX IF NOT EXISTS idx_governance_action_requests_type
    ON governance.action_requests (requested_action_type);

-- Index for temporal queries
CREATE INDEX IF NOT EXISTS idx_governance_action_requests_occurred_at
    ON governance.action_requests (occurred_at DESC);

-- GIN index for payload queries
CREATE INDEX IF NOT EXISTS idx_governance_action_requests_payload_gin
    ON governance.action_requests USING GIN (payload jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- governance.action_decisions
-- Append-only admission decisions. Each decision references the exact policy
-- version used, preserving replayability.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.action_decisions (
    decision_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id          UUID NOT NULL REFERENCES governance.action_requests(request_id),
    decision            governance_decision NOT NULL,
    policy_version_id   UUID NOT NULL REFERENCES governance.policy_versions(policy_version_id),
    decided_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    decision_reason     TEXT,
    admission_context   JSONB NOT NULL DEFAULT '{}',
    reviewed_by         UUID REFERENCES governance.identities(identity_id),

    -- One decision per request.
    CONSTRAINT uq_action_decisions_request UNIQUE (request_id)
);

-- Index for querying decisions by policy version
CREATE INDEX IF NOT EXISTS idx_governance_action_decisions_policy
    ON governance.action_decisions (policy_version_id);

-- Index for querying decisions by type
CREATE INDEX IF NOT EXISTS idx_governance_action_decisions_decision
    ON governance.action_decisions (decision);

-- Index for temporal queries
CREATE INDEX IF NOT EXISTS idx_governance_action_decisions_decided_at
    ON governance.action_decisions (decided_at DESC);

-- Index for finding decisions reviewed by a specific identity
CREATE INDEX IF NOT EXISTS idx_governance_action_decisions_reviewer
    ON governance.action_decisions (reviewed_by)
    WHERE reviewed_by IS NOT NULL;

COMMIT;
