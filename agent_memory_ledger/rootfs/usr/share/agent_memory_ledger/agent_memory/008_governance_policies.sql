-- ==============================================================================
-- Governed Agent Action Ledger — Parts 4 & 5: Inheritance Policies
--                                              and Policy Versions
-- ==============================================================================
--
-- Part 4 — Inheritance Policies:
--   Lightweight policy references that define how identity attributes,
--   permissions, and context propagate through lineage edges.
--   The system stores policy references and provenance only.
--   It does NOT execute inheritance logic — that is left to the application
--   layer or a future policy engine.
--
-- Part 5 — Policy Versions:
--   Replayable governance context. Every action decision references the exact
--   policy version that governed it, enabling full replay of governance
--   reasoning at any point in time.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Part 4: governance.inheritance_policies
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_inheritance_type') THEN
        CREATE TYPE governance_inheritance_type AS ENUM (
            'full_inheritance',
            'reference_only',
            'partitioned',
            'summarized',
            'none'
        );
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS governance.inheritance_policies (
    policy_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_name     TEXT NOT NULL,
    inheritance_type governance_inheritance_type NOT NULL DEFAULT 'none',
    description     TEXT,
    policy_definition JSONB NOT NULL DEFAULT '{}',
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_inheritance_policies_name UNIQUE (policy_name)
);

-- ---------------------------------------------------------------------------
-- Part 5: governance.policy_versions
-- Replayable governance context.
-- Each version captures the complete policy definition that was active
-- during a specific time window.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.policy_versions (
    policy_version_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_name         TEXT NOT NULL,
    version             TEXT NOT NULL,
    effective_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at          TIMESTAMPTZ,
    policy_definition   JSONB NOT NULL DEFAULT '{}',
    created_by          UUID REFERENCES governance.identities(identity_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A policy version must not be retired before it became effective
    CONSTRAINT chk_policy_versions_retired_after_effective
        CHECK (retired_at IS NULL OR retired_at > effective_at),

    -- Version must be unique within a policy name
    CONSTRAINT uq_policy_versions_name_version UNIQUE (policy_name, version),
    CONSTRAINT fk_policy_versions_policy_name
        FOREIGN KEY (policy_name)
        REFERENCES governance.inheritance_policies(policy_name)
);

-- Index for finding the active policy version at a given time
CREATE INDEX IF NOT EXISTS idx_governance_policy_versions_effective
    ON governance.policy_versions (policy_name, effective_at DESC)
    WHERE retired_at IS NULL;

-- Index for finding all versions of a policy
CREATE INDEX IF NOT EXISTS idx_governance_policy_versions_name
    ON governance.policy_versions (policy_name);

-- ---------------------------------------------------------------------------
-- Add FK from identity_events.policy_version_id to policy_versions
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_identity_events_policy_version'
          AND table_schema = 'governance'
          AND table_name = 'identity_events'
    ) THEN
        ALTER TABLE governance.identity_events
            ADD CONSTRAINT fk_identity_events_policy_version
            FOREIGN KEY (policy_version_id)
            REFERENCES governance.policy_versions(policy_version_id);
    END IF;
END $$;

COMMIT;
