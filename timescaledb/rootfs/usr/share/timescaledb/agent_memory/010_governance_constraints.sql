-- ==============================================================================
-- Governed Agent Action Ledger — Parts 7 & 10: Admission Predicates
--                                                   and Validation Constraints
-- ==============================================================================
--
-- Part 7 — Admission Predicate Infrastructure:
--   Stores the inputs that fed into each admission decision, preserving
--   enough context to replay governance reasoning later.
--   This is NOT a policy engine — it is a provenance store.
--
-- Part 10 — Validation Constraints:
--   - Append-only protection for event tables (prevent UPDATE/DELETE)
--   - Identity must exist before acting
--   - Retired identities cannot submit actions (unless explicitly allowed)
--   - Action decisions must reference valid policy versions
--   - Lineage entries must reference valid identity events
--
-- Idempotent: safe to run multiple times.
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Part 7: governance.admission_contexts
-- Snapshots the governance state at the time of an admission decision.
-- This enables full replay of why a decision was made.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.admission_contexts (
    context_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_id         UUID NOT NULL REFERENCES governance.action_decisions(decision_id),
    identity_status     TEXT NOT NULL,           -- Status of requesting identity at decision time
    active_roles        JSONB NOT NULL DEFAULT '[]',  -- Role IDs active at decision time
    lineage_ancestors   JSONB NOT NULL DEFAULT '[]',  -- Ancestor identity IDs at decision time
    policy_snapshot     JSONB NOT NULL DEFAULT '{}',   -- The policy definition used
    evaluation_inputs   JSONB NOT NULL DEFAULT '{}',   -- Any additional inputs to the decision
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_admission_contexts_decision UNIQUE (decision_id)
);

CREATE INDEX IF NOT EXISTS idx_governance_admission_contexts_decision
    ON governance.admission_contexts (decision_id);

-- ---------------------------------------------------------------------------
-- Part 10: Append-only protection for identity_events
-- Prevents UPDATE and DELETE on the identity_events table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.enforce_append_only_identity_events()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'identity_events is append-only: UPDATE is not permitted on event_id %', OLD.event_id;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'identity_events is append-only: DELETE is not permitted on event_id %', OLD.event_id;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_append_only_identity_events ON governance.identity_events;
CREATE TRIGGER trg_enforce_append_only_identity_events
    BEFORE UPDATE OR DELETE ON governance.identity_events
    FOR EACH ROW
    EXECUTE FUNCTION governance.enforce_append_only_identity_events();

-- ---------------------------------------------------------------------------
-- Append-only protection for action_requests
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.enforce_append_only_action_requests()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'action_requests is append-only: UPDATE is not permitted on request_id %', OLD.request_id;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'action_requests is append-only: DELETE is not permitted on request_id %', OLD.request_id;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_append_only_action_requests ON governance.action_requests;
CREATE TRIGGER trg_enforce_append_only_action_requests
    BEFORE UPDATE OR DELETE ON governance.action_requests
    FOR EACH ROW
    EXECUTE FUNCTION governance.enforce_append_only_action_requests();

-- ---------------------------------------------------------------------------
-- Append-only protection for action_decisions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.enforce_append_only_action_decisions()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'action_decisions is append-only: UPDATE is not permitted on decision_id %', OLD.decision_id;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'action_decisions is append-only: DELETE is not permitted on decision_id %', OLD.decision_id;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_append_only_action_decisions ON governance.action_decisions;
CREATE TRIGGER trg_enforce_append_only_action_decisions
    BEFORE UPDATE OR DELETE ON governance.action_decisions
    FOR EACH ROW
    EXECUTE FUNCTION governance.enforce_append_only_action_decisions();

-- ---------------------------------------------------------------------------
-- Validation: identities cannot act before creation
-- Trigger on action_requests checks that the requesting identity existed
-- at the time the action was requested.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.validate_identity_exists_for_action()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_created_at TIMESTAMPTZ;
    v_status     governance_identity_status;
BEGIN
    SELECT created_at, status INTO v_created_at, v_status
    FROM governance.identities
    WHERE identity_id = NEW.requesting_identity_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Identity % does not exist — cannot submit action requests',
            NEW.requesting_identity_id;
    END IF;

    IF v_created_at > NEW.occurred_at THEN
        RAISE EXCEPTION 'Identity % was created at % but action occurred at % — identity did not exist at action time',
            NEW.requesting_identity_id, v_created_at, NEW.occurred_at;
    END IF;

    -- Retired identities cannot submit actions unless explicitly allowed
    -- via payload -> allow_retired = true
    IF v_status = 'retired' AND
       COALESCE((NEW.payload ->> 'allow_retired')::boolean, FALSE) = FALSE THEN
        RAISE EXCEPTION 'Identity % is retired and cannot submit action requests (set payload.allow_retired=true to override)',
            NEW.requesting_identity_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_identity_exists_for_action ON governance.action_requests;
CREATE TRIGGER trg_validate_identity_exists_for_action
    BEFORE INSERT ON governance.action_requests
    FOR EACH ROW
    EXECUTE FUNCTION governance.validate_identity_exists_for_action();

-- ---------------------------------------------------------------------------
-- Validation: identity_events must reference valid target identities
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION governance.validate_identity_event_target()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM governance.identities WHERE identity_id = NEW.target_identity_id
    ) INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Target identity % does not exist — cannot record identity event',
            NEW.target_identity_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_identity_event_target ON governance.identity_events;
CREATE CONSTRAINT TRIGGER trg_validate_identity_event_target
    AFTER INSERT ON governance.identity_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION governance.validate_identity_event_target();

COMMIT;
