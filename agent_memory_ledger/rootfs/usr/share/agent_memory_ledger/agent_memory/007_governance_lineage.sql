-- ==============================================================================
-- Governed Agent Action Ledger — Part 3: Identity Lineage DAG
-- ==============================================================================
--
-- Implements lineage relationships between identities as a directed acyclic
-- graph (DAG). Lineage captures organizational identity evolution through
-- splits, merges, aliases, and reclassifications.
--
-- CRITICAL REQUIREMENT: The lineage graph MUST remain acyclic.
--
-- Cycle prevention strategy:
--   A BEFORE INSERT OR UPDATE trigger checks for cycles by performing a
--   recursive descendant traversal from the proposed child to see if it would
--   reach the proposed parent. If a cycle is detected, the write is rejected.
--
--   Tradeoffs:
--     - Pro: Immediate enforcement, no deferred constraint window.
--     - Pro: Simple to reason about — every write is validated.
--     - Con: O(depth) cost per insert. Acceptable because lineage depth
--       is expected to be shallow (typically < 20 levels).
--     - Con: Single-edge inserts only. Batch lineage imports must insert
--       edges one at a time.
--
--   Alternative considered: Deferred constraint using a materialized
--   transitive closure table. Rejected because it adds complexity and
--   requires a maintenance process, with no clear benefit for the expected
--   write volume.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Custom enum for lineage relationship types
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'governance_lineage_type') THEN
        CREATE TYPE governance_lineage_type AS ENUM (
            'split_parent',
            'merge_parent',
            'alias_parent',
            'reclassification_parent'
        );
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- governance.identity_lineage
-- Directed edges in the identity lineage DAG.
-- parent_identity_id → child_identity_id means "parent is an ancestor of child".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.identity_lineage (
    lineage_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_identity_id  UUID NOT NULL REFERENCES governance.identities(identity_id),
    child_identity_id   UUID NOT NULL REFERENCES governance.identities(identity_id),
    lineage_event_id    UUID NOT NULL REFERENCES governance.identity_events(event_id),
    relationship_type   governance_lineage_type NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Prevent self-loops
    CONSTRAINT chk_lineage_no_self_loop
        CHECK (parent_identity_id != child_identity_id),

    -- Prevent duplicate edges
    CONSTRAINT uq_lineage_edge UNIQUE (parent_identity_id, child_identity_id, relationship_type)
);

-- Index for finding all children of a parent
CREATE INDEX IF NOT EXISTS idx_governance_lineage_parent
    ON governance.identity_lineage (parent_identity_id);

-- Index for finding all parents of a child
CREATE INDEX IF NOT EXISTS idx_governance_lineage_child
    ON governance.identity_lineage (child_identity_id);

-- Index for relationship type queries
CREATE INDEX IF NOT EXISTS idx_governance_lineage_type
    ON governance.identity_lineage (relationship_type);

-- ---------------------------------------------------------------------------
-- Cycle prevention trigger
-- Uses a recursive CTE to walk descendants from the proposed child.
-- If the proposed parent is reachable from that child, a cycle would form.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.check_lineage_acyclic()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check: would adding parent→child create a cycle?
    -- A cycle exists if parent is already a descendant of child.
    IF EXISTS (
        WITH RECURSIVE descendants AS (
            -- Start from the proposed child, walk downward
            SELECT
                child_identity_id AS descendant_id,
                ARRAY[child_identity_id] AS path
            FROM governance.identity_lineage
            WHERE parent_identity_id = NEW.child_identity_id

            UNION ALL

            SELECT
                il.child_identity_id,
                d.path || il.child_identity_id
            FROM governance.identity_lineage il
            INNER JOIN descendants d ON il.parent_identity_id = d.descendant_id
            WHERE NOT il.child_identity_id = ANY(d.path)
        )
        SELECT 1 FROM descendants WHERE descendant_id = NEW.parent_identity_id
    ) THEN
        RAISE EXCEPTION 'Lineage cycle detected: adding parent % → child % would create a cycle',
            NEW.parent_identity_id, NEW.child_identity_id;
    END IF;

    RETURN NEW;
END;
$$;

-- Drop and recreate trigger to ensure idempotency
DROP TRIGGER IF EXISTS trg_check_lineage_acyclic ON governance.identity_lineage;
CREATE TRIGGER trg_check_lineage_acyclic
    BEFORE INSERT OR UPDATE ON governance.identity_lineage
    FOR EACH ROW
    EXECUTE FUNCTION governance.check_lineage_acyclic();

COMMIT;
