-- ==============================================================================
-- Governed Agent Action Ledger — Parts 8 & 9: Replayability Support
--                                                   and Audit Projections
-- ==============================================================================
--
-- Part 8 — Replayability Support:
--   SQL views and functions to reconstruct governance state at any point in
--   time (identity status, role bindings, active policy, lineage ancestry).
--
--   Limitations:
--     - These are governance replay only. They do NOT reconstruct the full
--       environmental state (file system, network, external services).
--     - Replay is based on recorded event timestamps. If events were recorded
--       out of order, replay may not perfectly reflect real-time ordering.
--     - Hypertable compression or retention policies may limit how far back
--       replay is possible.
--
-- Part 9 — Audit Projections:
--   Derived views that provide convenient query patterns for audit and
--   compliance reporting.
--
--   CRITICAL PRINCIPLE:
--     These projections are DERIVED and NON-CANONICAL. They reference
--     canonical event IDs but must NEVER replace the canonical event history.
--     All audit reports can be traced back to the original events.
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

-- ===========================================================================
-- PART 8: REPLAYABILITY VIEWS AND FUNCTIONS
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- View: Identity status at a given point in time
-- Reconstructs identity status by replaying identity events up to time T.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW governance.replay_identity_status AS
SELECT
    i.identity_id,
    i.identity_type,
    i.display_name,
    ie.event_id       AS last_event_id,
    ie.event_type     AS last_event_type,
    ie.occurred_at    AS last_event_at,
    i.status          AS current_status,
    i.created_at,
    i.retired_at
FROM governance.identities i
LEFT JOIN LATERAL (
    SELECT event_id, event_type, occurred_at
    FROM governance.identity_events
    WHERE target_identity_id = i.identity_id
    ORDER BY occurred_at DESC
    LIMIT 1
) ie ON true;

-- ---------------------------------------------------------------------------
-- Function: Get identity status at a specific point in time
-- Returns the status an identity had at time T by replaying events.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.identity_status_at(
    p_identity_id UUID,
    p_at_time     TIMESTAMPTZ
)
RETURNS TABLE (
    identity_id    UUID,
    identity_type  governance_identity_type,
    display_name   TEXT,
    status         governance_identity_status,
    determined_by  UUID,        -- event_id that last changed status before p_at_time
    determined_at  TIMESTAMPTZ  -- when that event occurred
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_created_at TIMESTAMPTZ;
BEGIN
    -- Identity must have existed at the requested time
    SELECT created_at INTO v_created_at
    FROM governance.identities
    WHERE identity_id = p_identity_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Identity % does not exist', p_identity_id;
    END IF;

    IF v_created_at > p_at_time THEN
        -- Identity did not exist yet
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        i.identity_id,
        i.identity_type,
        i.display_name,
        -- Derive status from events up to p_at_time
        COALESCE(
            (SELECT
                CASE ie.event_type
                    WHEN 'create_identity'    THEN 'active'::governance_identity_status
                    WHEN 'retire_identity'    THEN 'retired'::governance_identity_status
                    WHEN 'alias_identity'     THEN 'aliased'::governance_identity_status
                    WHEN 'split_identity'     THEN 'split'::governance_identity_status
                    WHEN 'merge_identity'     THEN 'merged'::governance_identity_status
                    WHEN 'reclassify_identity' THEN COALESCE(
                        (SELECT
                            CASE prev.event_type
                                WHEN 'create_identity' THEN 'active'::governance_identity_status
                                WHEN 'retire_identity' THEN 'retired'::governance_identity_status
                                WHEN 'alias_identity' THEN 'aliased'::governance_identity_status
                                WHEN 'split_identity' THEN 'split'::governance_identity_status
                                WHEN 'merge_identity' THEN 'merged'::governance_identity_status
                                ELSE NULL
                            END
                         FROM governance.identity_events prev
                         WHERE prev.target_identity_id = i.identity_id
                           AND prev.occurred_at <= p_at_time
                           AND prev.event_type IN (
                               'create_identity', 'retire_identity',
                               'alias_identity', 'split_identity',
                               'merge_identity'
                           )
                         ORDER BY prev.occurred_at DESC
                         LIMIT 1),
                        'active'::governance_identity_status
                    )
                    ELSE i.status
                END
             FROM governance.identity_events ie
             WHERE ie.target_identity_id = i.identity_id
               AND ie.occurred_at <= p_at_time
               AND ie.event_type IN (
                   'create_identity', 'retire_identity', 'alias_identity',
                   'split_identity', 'merge_identity', 'reclassify_identity'
               )
             ORDER BY ie.occurred_at DESC
             LIMIT 1),
            'active'::governance_identity_status
        ) AS status,
        (SELECT ie.event_id
         FROM governance.identity_events ie
         WHERE ie.target_identity_id = i.identity_id
           AND ie.occurred_at <= p_at_time
         ORDER BY ie.occurred_at DESC
         LIMIT 1) AS determined_by,
        (SELECT ie.occurred_at
         FROM governance.identity_events ie
         WHERE ie.target_identity_id = i.identity_id
           AND ie.occurred_at <= p_at_time
         ORDER BY ie.occurred_at DESC
         LIMIT 1) AS determined_at
    FROM governance.identities i
    WHERE i.identity_id = p_identity_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Function: Get role bindings at a specific point in time
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.role_bindings_at(
    p_identity_id UUID,
    p_at_time     TIMESTAMPTZ
)
RETURNS TABLE (
    binding_id  UUID,
    role_id     UUID,
    role_name   TEXT,
    bound_at    TIMESTAMPTZ
)
LANGUAGE sql STABLE
AS $$
    SELECT
        irb.binding_id,
        irb.role_id,
        r.role_name,
        irb.bound_at
    FROM governance.identity_role_bindings irb
    JOIN governance.roles r ON r.role_id = irb.role_id
    WHERE irb.identity_id = p_identity_id
      AND irb.bound_at <= p_at_time
      AND (irb.unbound_at IS NULL OR irb.unbound_at > p_at_time);
$$;

-- ---------------------------------------------------------------------------
-- Function: Get active policy version at a specific point in time
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.active_policy_at(
    p_policy_name TEXT,
    p_at_time     TIMESTAMPTZ
)
RETURNS TABLE (
    policy_version_id  UUID,
    policy_name        TEXT,
    version            TEXT,
    effective_at       TIMESTAMPTZ,
    policy_definition  JSONB
)
LANGUAGE sql STABLE
AS $$
    SELECT
        pv.policy_version_id,
        pv.policy_name,
        pv.version,
        pv.effective_at,
        pv.policy_definition
    FROM governance.policy_versions pv
    WHERE pv.policy_name = p_policy_name
      AND pv.effective_at <= p_at_time
      AND (pv.retired_at IS NULL OR pv.retired_at > p_at_time)
    ORDER BY pv.effective_at DESC
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Function: Get lineage ancestry for an identity (all ancestors)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.lineage_ancestors(
    p_identity_id UUID,
    p_max_depth   INT DEFAULT 100
)
RETURNS TABLE (
    ancestor_id      UUID,
    relationship_type governance_lineage_type,
    depth            INT,
    path             UUID[]
)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE ancestors AS (
        -- Base case: direct parents
        SELECT
            il.parent_identity_id AS ancestor_id,
            il.relationship_type,
            1 AS depth,
            ARRAY[il.parent_identity_id] AS path
        FROM governance.identity_lineage il
        WHERE il.child_identity_id = p_identity_id

        UNION ALL

        -- Recursive case: parents of parents
        SELECT
            il.parent_identity_id,
            il.relationship_type,
            a.depth + 1,
            a.path || il.parent_identity_id
        FROM governance.identity_lineage il
        INNER JOIN ancestors a ON il.child_identity_id = a.ancestor_id
        WHERE a.depth < p_max_depth
          AND NOT il.parent_identity_id = ANY(a.path)
    )
    SELECT * FROM ancestors;
$$;

-- ===========================================================================
-- PART 9: AUDIT PROJECTION VIEWS
-- ===========================================================================
-- CRITICAL: These views are DERIVED and NON-CANONICAL.
-- They reference canonical event IDs but must NEVER replace canonical history.
-- All data in these views can be reconstructed from the raw event tables.

-- ---------------------------------------------------------------------------
-- View: Action timeline with identity and decision context
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW governance.audit_action_timeline AS
SELECT
    ar.request_id,
    ar.requesting_identity_id,
    i.display_name       AS requester_name,
    i.identity_type      AS requester_type,
    i.status             AS requester_status,
    ar.requested_action_type,
    ar.requested_resource,
    ar.occurred_at,
    ad.decision_id,
    ad.decision,
    ad.decided_at,
    ad.decision_reason,
    pv.policy_version_id,
    pv.policy_name       AS governing_policy,
    pv.version           AS governing_policy_version,
    ad.reviewed_by,
    reviewer.display_name AS reviewer_name
FROM governance.action_requests ar
JOIN governance.identities i
    ON i.identity_id = ar.requesting_identity_id
LEFT JOIN governance.action_decisions ad
    ON ad.request_id = ar.request_id
LEFT JOIN governance.policy_versions pv
    ON pv.policy_version_id = ad.policy_version_id
LEFT JOIN governance.identities reviewer
    ON reviewer.identity_id = ad.reviewed_by;

-- ---------------------------------------------------------------------------
-- View: Identity lineage with human-readable names
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW governance.audit_identity_lineage AS
SELECT
    il.lineage_id,
    il.relationship_type,
    parent.display_name   AS parent_name,
    parent.identity_type  AS parent_type,
    il.parent_identity_id,
    child.display_name    AS child_name,
    child.identity_type   AS child_type,
    il.child_identity_id,
    il.lineage_event_id,
    il.created_at
FROM governance.identity_lineage il
JOIN governance.identities parent
    ON parent.identity_id = il.parent_identity_id
JOIN governance.identities child
    ON child.identity_id = il.child_identity_id;

-- ---------------------------------------------------------------------------
-- View: Policy usage statistics
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW governance.audit_policy_usage AS
SELECT
    pv.policy_version_id,
    pv.policy_name,
    pv.version,
    pv.effective_at,
    pv.retired_at,
    COUNT(ad.decision_id) AS decision_count,
    COUNT(ad.decision_id) FILTER (WHERE ad.decision = 'accepted')  AS accepted_count,
    COUNT(ad.decision_id) FILTER (WHERE ad.decision = 'rejected')  AS rejected_count,
    COUNT(ad.decision_id) FILTER (WHERE ad.decision = 'requires_review') AS review_count,
    COUNT(ad.decision_id) FILTER (WHERE ad.decision = 'deferred')  AS deferred_count
FROM governance.policy_versions pv
LEFT JOIN governance.action_decisions ad
    ON ad.policy_version_id = pv.policy_version_id
GROUP BY pv.policy_version_id, pv.policy_name, pv.version, pv.effective_at, pv.retired_at;

-- ---------------------------------------------------------------------------
-- View: Rejected actions with full context
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW governance.audit_rejected_actions AS
SELECT
    ar.request_id,
    ar.requesting_identity_id,
    i.display_name        AS requester_name,
    ar.requested_action_type,
    ar.requested_resource,
    ar.occurred_at,
    ad.decision_id,
    ad.decided_at,
    ad.decision_reason,
    pv.policy_name        AS governing_policy,
    pv.version            AS governing_policy_version,
    ac.admission_context
FROM governance.action_requests ar
JOIN governance.action_decisions ad
    ON ad.request_id = ar.request_id AND ad.decision = 'rejected'
JOIN governance.identities i
    ON i.identity_id = ar.requesting_identity_id
LEFT JOIN governance.policy_versions pv
    ON pv.policy_version_id = ad.policy_version_id
LEFT JOIN governance.admission_contexts ac
    ON ac.decision_id = ad.decision_id;

COMMIT;
