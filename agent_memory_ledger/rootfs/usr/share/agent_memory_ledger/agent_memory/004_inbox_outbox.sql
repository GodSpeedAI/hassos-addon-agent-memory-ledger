-- ==============================================================================
-- Agent Memory Schema: Inbox/Outbox for Message Bridge
-- Tables for RabbitMQ/NATS bridge integration
-- ==============================================================================
-- Idempotent: safe to run multiple times

BEGIN;

-- Enum-like type for delivery status
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'delivery_status') THEN
        CREATE TYPE delivery_status AS ENUM (
            'pending',
            'in_progress',
            'delivered',
            'failed',
            'dead_letter'
        );
    END IF;
END $$;

-- Inbox: incoming events from external message brokers
CREATE TABLE IF NOT EXISTS event_log.inbox_events (
	    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
	    source_queue    TEXT NOT NULL,
	    message_id      TEXT NOT NULL,
    headers         JSONB NOT NULL DEFAULT '{}',
    payload         JSONB NOT NULL DEFAULT '{}',
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ,
    status          delivery_status NOT NULL DEFAULT 'pending',

    -- Idempotent: one event per message_id per source
    CONSTRAINT uq_inbox_events_message UNIQUE (source_queue, message_id)
);

-- Index for processing pending inbox events
CREATE INDEX IF NOT EXISTS idx_inbox_events_status
    ON event_log.inbox_events (status, received_at);

-- Index for source_queue lookups
CREATE INDEX IF NOT EXISTS idx_inbox_events_source_queue
    ON event_log.inbox_events (source_queue);

-- GIN index for payload queries
CREATE INDEX IF NOT EXISTS idx_inbox_events_payload_gin
    ON event_log.inbox_events USING GIN (payload jsonb_path_ops);

-- Outbox: outgoing events to external message brokers
CREATE TABLE IF NOT EXISTS event_log.outbox_events (
	    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
	    target_queue    TEXT NOT NULL,
	    message_id      TEXT NOT NULL,
    headers         JSONB NOT NULL DEFAULT '{}',
    payload         JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    dispatched_at   TIMESTAMPTZ,
    status          delivery_status NOT NULL DEFAULT 'pending',

    -- Idempotent: one event per message_id per target
    CONSTRAINT uq_outbox_events_message UNIQUE (target_queue, message_id)
);

-- Index for processing pending outbox events
CREATE INDEX IF NOT EXISTS idx_outbox_events_status
    ON event_log.outbox_events (status, created_at);

-- Index for target_queue lookups
CREATE INDEX IF NOT EXISTS idx_outbox_events_target_queue
    ON event_log.outbox_events (target_queue);

-- GIN index for payload queries
CREATE INDEX IF NOT EXISTS idx_outbox_events_payload_gin
    ON event_log.outbox_events USING GIN (payload jsonb_path_ops);

-- Delivery attempts audit trail
CREATE TABLE IF NOT EXISTS event_log.delivery_attempts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    direction       TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    parent_event_id UUID NOT NULL,
    target_queue    TEXT,
    attempt_number  INT NOT NULL DEFAULT 1,
    status          delivery_status NOT NULL DEFAULT 'pending',
    error_message   TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ
);

-- Index for tracking delivery attempts for a specific event
CREATE INDEX IF NOT EXISTS idx_delivery_attempts_parent
    ON event_log.delivery_attempts (parent_event_id, attempt_number DESC);

-- Index for finding failed deliveries for retry
CREATE INDEX IF NOT EXISTS idx_delivery_attempts_status
    ON event_log.delivery_attempts (status, started_at)
    WHERE status = 'failed';

CREATE OR REPLACE FUNCTION event_log.validate_delivery_attempt_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.direction = 'inbound' THEN
        IF NOT EXISTS (
            SELECT 1 FROM event_log.inbox_events
            WHERE id = NEW.parent_event_id
        ) THEN
            RAISE EXCEPTION 'Inbound delivery_attempt parent_event_id % does not exist in event_log.inbox_events',
                NEW.parent_event_id;
        END IF;
    ELSIF NEW.direction = 'outbound' THEN
        IF NOT EXISTS (
            SELECT 1 FROM event_log.outbox_events
            WHERE id = NEW.parent_event_id
        ) THEN
            RAISE EXCEPTION 'Outbound delivery_attempt parent_event_id % does not exist in event_log.outbox_events',
                NEW.parent_event_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_delivery_attempt_parent ON event_log.delivery_attempts;
CREATE TRIGGER trg_validate_delivery_attempt_parent
    BEFORE INSERT OR UPDATE ON event_log.delivery_attempts
    FOR EACH ROW
    EXECUTE FUNCTION event_log.validate_delivery_attempt_parent();

CREATE OR REPLACE FUNCTION event_log.delete_inbox_delivery_attempts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM event_log.delivery_attempts
    WHERE direction = 'inbound'
      AND parent_event_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION event_log.delete_outbox_delivery_attempts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM event_log.delivery_attempts
    WHERE direction = 'outbound'
      AND parent_event_id = OLD.id;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_inbox_delivery_attempts ON event_log.inbox_events;
CREATE TRIGGER trg_delete_inbox_delivery_attempts
    BEFORE DELETE ON event_log.inbox_events
    FOR EACH ROW
    EXECUTE FUNCTION event_log.delete_inbox_delivery_attempts();

DROP TRIGGER IF EXISTS trg_delete_outbox_delivery_attempts ON event_log.outbox_events;
CREATE TRIGGER trg_delete_outbox_delivery_attempts
    BEFORE DELETE ON event_log.outbox_events
    FOR EACH ROW
    EXECUTE FUNCTION event_log.delete_outbox_delivery_attempts();

COMMIT;
