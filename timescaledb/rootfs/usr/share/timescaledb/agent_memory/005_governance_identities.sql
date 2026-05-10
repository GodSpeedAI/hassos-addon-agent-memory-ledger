-- ==============================================================================
-- Governed Agent Action Ledger — Part 1: Identity Ledger
-- ==============================================================================
--
-- Creates the governance schema with identity primitives:
--   governance.identities           — governed identity records
--   governance.roles                — named role definitions
--   governance.identity_role_bindings — role-to-identity assignments
--
-- Design principles:
--   - Identity is NOT immutable. Identities may be created, retired, aliased,
--     merged, split, or reclassified. Organizational identity is preserved
--     through lineage (see 007_governance_lineage.sql), not immutability.
--   - Status transitions are governed by identity events (see 006_governance_events.sql).
--   - The identities table is a materialized current-state view. The canonical
--     history lives in governance.identity_events.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS governance;

-- ---------------------------------------------------------------------------
-- Custom enum types
-- ---------------------------------------------------------------------------
-- Existing enum types are not changed by CREATE TYPE. Add future labels with
-- explicit versioned ALTER TYPE ... ADD VALUE migrations.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_identity_status') THEN
        CREATE TYPE governance_identity_status AS ENUM (
            'active',
            'retired',
            'merged',
            'split',
            'aliased',
            'suspended'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_identity_type') THEN
        CREATE TYPE governance_identity_type AS ENUM (
            'agent',
            'human',
            'tool',
            'service',
            'workspace',
            'role',
            'resource'
        );
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- governance.identities
-- Current-state materialized view of governed identities.
-- Updated via identity events; never mutated directly by application code.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.identities (
    identity_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    identity_type   governance_identity_type NOT NULL,
    display_name    TEXT,
    status          governance_identity_status NOT NULL DEFAULT 'active',
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at      TIMESTAMPTZ,

    -- An identity must not be retired before it was created
    CONSTRAINT chk_identities_retired_after_created
        CHECK (retired_at IS NULL OR retired_at >= created_at)
);

-- Index for status-based lookups
CREATE INDEX IF NOT EXISTS idx_governance_identities_status
    ON governance.identities (status);

-- Index for type-based lookups
CREATE INDEX IF NOT EXISTS idx_governance_identities_type
    ON governance.identities (identity_type);

-- Index for display_name search
CREATE INDEX IF NOT EXISTS idx_governance_identities_display_name
    ON governance.identities (display_name)
    WHERE display_name IS NOT NULL;

-- GIN index for metadata queries
CREATE INDEX IF NOT EXISTS idx_governance_identities_metadata_gin
    ON governance.identities USING GIN (metadata jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- governance.roles
-- Named role definitions. Roles are themselves governable identities
-- (identity_type = 'role'), but this table provides a convenient
-- human-readable catalogue separate from the identity ledger.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.roles (
    role_id         UUID PRIMARY KEY REFERENCES governance.identities(identity_id) ON DELETE RESTRICT,
    role_name       TEXT NOT NULL,
    description     TEXT,
    permissions     JSONB NOT NULL DEFAULT '{}',
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at      TIMESTAMPTZ,

    CONSTRAINT uq_roles_role_name UNIQUE (role_name),
    CONSTRAINT chk_roles_retired_after_created
        CHECK (retired_at IS NULL OR retired_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_governance_roles_retired
    ON governance.roles (retired_at)
    WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------------
-- governance.identity_role_bindings
-- Assigns roles to identities with temporal validity.
-- Bindings are created/removed via identity events (bind_role / unbind_role).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.identity_role_bindings (
    binding_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    identity_id     UUID NOT NULL REFERENCES governance.identities(identity_id) ON DELETE RESTRICT,
    role_id         UUID NOT NULL REFERENCES governance.roles(role_id) ON DELETE RESTRICT,
    bound_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    unbound_at      TIMESTAMPTZ,
    binding_event_id UUID,  -- FK added after identity_events table exists
    metadata        JSONB NOT NULL DEFAULT '{}',

    CONSTRAINT chk_role_bindings_unbound_after_bound
        CHECK (unbound_at IS NULL OR unbound_at >= bound_at)
);

-- Index for finding active role bindings for an identity
CREATE INDEX IF NOT EXISTS idx_governance_role_bindings_identity_active
    ON governance.identity_role_bindings (identity_id, role_id)
    WHERE unbound_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_identity_role_active
    ON governance.identity_role_bindings (identity_id, role_id)
    WHERE unbound_at IS NULL;

-- Index for finding all identities with a given role
CREATE INDEX IF NOT EXISTS idx_governance_role_bindings_role
    ON governance.identity_role_bindings (role_id);

CREATE OR REPLACE FUNCTION governance.validate_role_identity_type()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM governance.identities
        WHERE identity_id = NEW.role_id
          AND identity_type = 'role'
    ) THEN
        RAISE EXCEPTION 'Role % must reference a governance.identities row with identity_type = role',
            NEW.role_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_role_identity_type ON governance.roles;
CREATE TRIGGER trg_validate_role_identity_type
    BEFORE INSERT OR UPDATE ON governance.roles
    FOR EACH ROW
    EXECUTE FUNCTION governance.validate_role_identity_type();

COMMIT;
