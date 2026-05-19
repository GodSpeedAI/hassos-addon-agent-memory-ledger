-- ==============================================================================
-- Agent Memory Schema: Least-Privilege Security Roles
-- Defines four roles with narrow grants for external tools and bridge workers.
-- ==============================================================================
--
-- Idempotent: safe to run multiple times.
--
-- IMPORTANT: This file creates roles WITHOUT passwords and WITHOUT LOGIN.
-- Passwords and LOGIN privilege are applied by the init script
-- (004_setup_agent_memory.sh) using values from add-on configuration.
-- This separation ensures passwords never appear in SQL files.
--
-- Roles:
--   ledger_writer      — INSERT on canonical event/memory/governance tables
--   ledger_reader      — SELECT on all event, governance, memory, embeddings tables
--   projection_worker  — SELECT on canonical tables, INSERT/UPDATE on kg projection state
--   bridge_worker      — INSERT/UPDATE on inbox/outbox, INSERT on delivery_attempts,
--                        SELECT on canonical tables for outbound publishing
--
-- None of these roles have superuser, createdb, createrole, replication,
-- or bypassrls privileges.
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Helper: create a NOINHERIT NOLOGIN role if it does not already exist.
-- NOLOGIN prevents direct connection until the init script grants LOGIN
-- with a password. NOINHERIT ensures only explicitly granted privileges
-- are active.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- ledger_writer
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_writer') THEN
        CREATE ROLE ledger_writer NOINHERIT NOLOGIN;
        RAISE NOTICE 'Created role ledger_writer';
    ELSE
        RAISE NOTICE 'Role ledger_writer already exists — skipping creation';
    END IF;

    -- ledger_reader
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_reader') THEN
        CREATE ROLE ledger_reader NOINHERIT NOLOGIN;
        RAISE NOTICE 'Created role ledger_reader';
    ELSE
        RAISE NOTICE 'Role ledger_reader already exists — skipping creation';
    END IF;

    -- projection_worker
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'projection_worker') THEN
        CREATE ROLE projection_worker NOINHERIT NOLOGIN;
        RAISE NOTICE 'Created role projection_worker';
    ELSE
        RAISE NOTICE 'Role projection_worker already exists — skipping creation';
    END IF;

    -- bridge_worker
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bridge_worker') THEN
        CREATE ROLE bridge_worker NOINHERIT NOLOGIN;
        RAISE NOTICE 'Created role bridge_worker';
    ELSE
        RAISE NOTICE 'Role bridge_worker already exists — skipping creation';
    END IF;
END $$;

-- ===========================================================================
-- SCHEMA USAGE GRANTS
-- ===========================================================================
-- Each role gets USAGE only on the schemas it needs.

-- ledger_writer: writes to event_log, governance, memory
GRANT USAGE ON SCHEMA event_log   TO ledger_writer;
GRANT USAGE ON SCHEMA governance  TO ledger_writer;
GRANT USAGE ON SCHEMA memory      TO ledger_writer;

-- ledger_reader: reads from event_log, governance, memory, embeddings
GRANT USAGE ON SCHEMA event_log   TO ledger_reader;
GRANT USAGE ON SCHEMA governance  TO ledger_reader;
GRANT USAGE ON SCHEMA memory      TO ledger_reader;
GRANT USAGE ON SCHEMA embeddings  TO ledger_reader;

-- projection_worker: reads canonical tables, writes to kg
GRANT USAGE ON SCHEMA event_log   TO projection_worker;
GRANT USAGE ON SCHEMA governance  TO projection_worker;
GRANT USAGE ON SCHEMA memory      TO projection_worker;
GRANT USAGE ON SCHEMA kg          TO projection_worker;

-- bridge_worker: reads/writes inbox/outbox, reads canonical for publishing
GRANT USAGE ON SCHEMA event_log   TO bridge_worker;
GRANT USAGE ON SCHEMA governance  TO bridge_worker;
GRANT USAGE ON SCHEMA memory      TO bridge_worker;

-- ===========================================================================
-- ledger_writer GRANTS
-- ===========================================================================
-- Can INSERT into canonical event, governance, and memory tables.
-- Cannot UPDATE, DELETE, or administer schemas.

-- event_log writes
GRANT INSERT ON event_log.agent_events     TO ledger_writer;
GRANT INSERT ON event_log.inbox_events     TO ledger_writer;
GRANT INSERT ON event_log.outbox_events    TO ledger_writer;

-- governance writes
GRANT INSERT ON governance.action_requests  TO ledger_writer;
GRANT INSERT ON governance.action_decisions TO ledger_writer;
GRANT INSERT ON governance.identity_events  TO ledger_writer;
GRANT INSERT ON governance.identities       TO ledger_writer;
GRANT INSERT ON governance.identity_lineage TO ledger_writer;
GRANT INSERT ON governance.identity_role_bindings TO ledger_writer;
GRANT INSERT ON governance.roles            TO ledger_writer;
GRANT INSERT ON governance.inheritance_policies  TO ledger_writer;
GRANT INSERT ON governance.policy_versions  TO ledger_writer;
GRANT INSERT ON governance.admission_contexts TO ledger_writer;

-- memory writes
GRANT INSERT ON memory.items            TO ledger_writer;
GRANT INSERT ON memory.lifecycle_audit  TO ledger_writer;

-- USAGE on sequences (for DEFAULT gen_random_uuid() — not strictly required
-- for UUID columns, but included for completeness if any serial columns exist)
-- No sequences are currently used, so this is a no-op safety net.

-- ===========================================================================
-- ledger_reader GRANTS
-- ===========================================================================
-- Read-only access to all canonical and derived tables.

-- event_log reads
GRANT SELECT ON event_log.agent_events      TO ledger_reader;
GRANT SELECT ON event_log.inbox_events      TO ledger_reader;
GRANT SELECT ON event_log.outbox_events     TO ledger_reader;
GRANT SELECT ON event_log.delivery_attempts TO ledger_reader;

-- governance reads
GRANT SELECT ON governance.identities              TO ledger_reader;
GRANT SELECT ON governance.roles                   TO ledger_reader;
GRANT SELECT ON governance.identity_role_bindings  TO ledger_reader;
GRANT SELECT ON governance.identity_events         TO ledger_reader;
GRANT SELECT ON governance.identity_lineage        TO ledger_reader;
GRANT SELECT ON governance.inheritance_policies    TO ledger_reader;
GRANT SELECT ON governance.policy_versions         TO ledger_reader;
GRANT SELECT ON governance.action_requests         TO ledger_reader;
GRANT SELECT ON governance.action_decisions        TO ledger_reader;
GRANT SELECT ON governance.admission_contexts      TO ledger_reader;

-- memory reads
GRANT SELECT ON memory.items            TO ledger_reader;
GRANT SELECT ON memory.lifecycle_audit   TO ledger_reader;

-- embeddings reads (table may not exist without RuVector extension)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'embeddings' AND table_name = 'memory_embeddings') THEN
        GRANT SELECT ON embeddings.memory_embeddings TO ledger_reader;
    END IF;
END $$;

-- ===========================================================================
-- projection_worker GRANTS
-- ===========================================================================
-- Reads canonical tables for RDF projection.
-- Writes projection state to kg.oxigraph_projection_state only.

-- Canonical table reads (same scope as ledger_reader minus embeddings)
GRANT SELECT ON event_log.agent_events      TO projection_worker;
GRANT SELECT ON event_log.inbox_events      TO projection_worker;
GRANT SELECT ON event_log.outbox_events     TO projection_worker;

GRANT SELECT ON governance.identities              TO projection_worker;
GRANT SELECT ON governance.roles                   TO projection_worker;
GRANT SELECT ON governance.identity_role_bindings  TO projection_worker;
GRANT SELECT ON governance.identity_events         TO projection_worker;
GRANT SELECT ON governance.identity_lineage        TO projection_worker;
GRANT SELECT ON governance.policy_versions         TO projection_worker;
GRANT SELECT ON governance.action_requests         TO projection_worker;
GRANT SELECT ON governance.action_decisions        TO projection_worker;

GRANT SELECT ON memory.items            TO projection_worker;
GRANT SELECT ON memory.lifecycle_audit   TO projection_worker;

-- Projection state writes (kg schema)
GRANT SELECT, INSERT, UPDATE ON kg.oxigraph_projection_state TO projection_worker;

-- ===========================================================================
-- bridge_worker GRANTS
-- ===========================================================================
-- Reads canonical tables for outbound publishing.
-- Writes to inbox/outbox for bridge operations.
-- Writes delivery_attempts for audit trail.
--
-- For governance action_requests and action_decisions, bridge_worker can
-- INSERT only — these are the inbound canonical mapping targets for
-- sea.governance.request.* and sea.governance.decision.* subjects.

-- Outbox: poll pending events and mark dispatched
GRANT SELECT ON event_log.outbox_events     TO bridge_worker;
GRANT UPDATE ON event_log.outbox_events     TO bridge_worker;
GRANT INSERT ON event_log.outbox_events     TO bridge_worker;

-- Inbox: ingest external events
GRANT SELECT ON event_log.inbox_events      TO bridge_worker;
GRANT INSERT ON event_log.inbox_events      TO bridge_worker;
GRANT UPDATE ON event_log.inbox_events      TO bridge_worker;

-- Delivery attempts audit trail
GRANT SELECT ON event_log.delivery_attempts TO bridge_worker;
GRANT INSERT ON event_log.delivery_attempts TO bridge_worker;

-- Canonical agent events (for inbound sea.agent.event.* mapping)
GRANT INSERT ON event_log.agent_events      TO bridge_worker;
GRANT SELECT ON event_log.agent_events      TO bridge_worker;

-- Governance: inbound canonical mapping targets
GRANT INSERT ON governance.action_requests  TO bridge_worker;
GRANT INSERT ON governance.action_decisions TO bridge_worker;
GRANT SELECT ON governance.action_requests  TO bridge_worker;
GRANT SELECT ON governance.action_decisions TO bridge_worker;

-- Governance: read identity/policy context for envelope validation
GRANT SELECT ON governance.identities       TO bridge_worker;
GRANT SELECT ON governance.identity_events  TO bridge_worker;
GRANT SELECT ON governance.policy_versions  TO bridge_worker;

-- Memory: inbound canonical mapping for sea.memory.write.* subjects
GRANT INSERT ON memory.items                TO bridge_worker;
GRANT SELECT ON memory.items                TO bridge_worker;
GRANT INSERT ON memory.lifecycle_audit      TO bridge_worker;
GRANT SELECT ON memory.lifecycle_audit      TO bridge_worker;

-- Schema migration tracking (for health checks)
GRANT USAGE ON SCHEMA agent_memory          TO bridge_worker;
GRANT SELECT ON agent_memory.schema_migrations TO bridge_worker;

-- ===========================================================================
-- REVOKE dangerous privileges (defense in depth)
-- ===========================================================================
-- These should already be absent since roles are created NOINHERIT NOLOGIN
-- without explicit grants. Revoke explicitly only if the attributes exist.
DO $$
BEGIN
    -- Revoke dangerous attributes from each role if present.
    -- ALTER ROLE ... NOCREATEDB etc. is idempotent and safe even if the
    -- attribute was already absent.
    ALTER ROLE ledger_writer   NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    ALTER ROLE ledger_reader   NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    ALTER ROLE projection_worker NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    ALTER ROLE bridge_worker   NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN others THEN RAISE NOTICE 'REVOKE defense-in-depth: %', SQLERRM;
END $$;

-- ===========================================================================
-- Default privileges for future tables in these schemas
-- ===========================================================================
-- Ensure that tables created in the future by postgres in these schemas
-- are automatically readable by ledger_reader and projection_worker.
-- This prevents new tables from being invisible to read-only roles.

ALTER DEFAULT PRIVILEGES IN SCHEMA event_log
    GRANT SELECT ON TABLES TO ledger_reader, projection_worker;

ALTER DEFAULT PRIVILEGES IN SCHEMA governance
    GRANT SELECT ON TABLES TO ledger_reader, projection_worker;

ALTER DEFAULT PRIVILEGES IN SCHEMA memory
    GRANT SELECT ON TABLES TO ledger_reader, projection_worker;

ALTER DEFAULT PRIVILEGES IN SCHEMA embeddings
    GRANT SELECT ON TABLES TO ledger_reader;

COMMIT;
