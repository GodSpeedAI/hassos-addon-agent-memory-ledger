# Implementation Plan: SEA Forge JetStream Event Bridge

**Status:** IN PROGRESS — Slices 1–5 complete, Slice 6 (integration testing) pending
**Date:** 2026-05-18
**Revised:** 2026-05-18
**Target:** SEA Forge / ZeroClaw integration
**Scope:** Add a governed NATS JetStream bridge to the Agent Memory Ledger add-on

---

## 1. Overview

This plan adds a SEA Forge JetStream event bridge that connects the Agent Memory
Ledger's Postgres-based canonical event store to external agent runtimes
(SEA Forge, ZeroClaw).

**Core principle:** Postgres remains the canonical source of truth. JetStream is
transport and replay surface. The bridge is a narrow, governed adapter — not a
second brain.

The bridge provides:

- **Outbox polling:** Postgres → NATS (publish canonical events to JetStream subjects)
- **Inbox ingestion:** NATS → Postgres (receive external events into `event_log.inbox_events`)
- **Subject-specific canonical mapping:** inbound messages are routed to the correct
  canonical table based on subject, not dumped generically
- **JSON envelope validation:** governance requests and decisions fail closed if malformed
- **Health endpoints:** `/healthz` and `/readyz` for container orchestration
- **Least-privilege DB roles:** four explicit roles with separate passwords

---

## 2. Files to Modify

| File                                                               | Change                                                                                    | Risk   |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- | ------ |
| `agent_memory_ledger/config.yaml`                                  | Add `sea_bridge`, `security`, `health`, `developer_mode` blocks                           | Low    |
| `agent_memory_ledger/Dockerfile`                                   | Add Python 3 + `nats-py` dependency                                                       | Medium |
| `agent_memory_ledger/rootfs/.../004_setup_agent_memory.sh`         | Add bridge DB role creation, grant statements, schema migration call                      | Medium |
| `agent_memory_ledger/rootfs/.../agent_memory/004_inbox_outbox.sql` | Add `source_subject` column to `inbox_events`, `target_subject` column to `outbox_events` | Low    |
| `README.md`                                                        | Document new configuration options                                                        | Low    |

---

## 3. New Files to Create

### 3.1 SQL Schema

| File                                                | Purpose                                                                                     |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `rootfs/.../agent_memory/013_sea_bridge_schema.sql` | JetStream stream/consumer tracking, bridge state, deduplication ledger, DB roles and GRANTs |

### 3.2 Bridge Service (Python)

| File                                                         | Purpose                                                               |
| ------------------------------------------------------------ | --------------------------------------------------------------------- |
| `rootfs/.../agent_memory_ledger/sea_bridge.py`               | Main bridge process: outbox poller + inbox subscriber + health server |
| `rootfs/.../agent_memory_ledger/sea_bridge_config.py`        | Config reader from bashio/environment                                 |
| `rootfs/.../agent_memory_ledger/sea_bridge_subjects.py`      | Subject taxonomy constants, validation, and canonical mapping         |
| `rootfs/.../agent_memory_ledger/sea_bridge_envelope.py`      | JSON envelope validation for governance and memory subjects           |
| `rootfs/.../agent_memory_ledger/sea_bridge_health.py`        | `/healthz` and `/readyz` HTTP endpoints                               |
| `rootfs/.../agent_memory_ledger/requirements-sea-bridge.txt` | Pinned Python deps: `nats-py`, `psycopg[binary]`                      |

### 3.3 s6-overlay Service

| File                                                                 | Purpose                                           |
| -------------------------------------------------------------------- | ------------------------------------------------- |
| `rootfs/etc/s6-overlay/s6-rc.d/sea-bridge/type`                      | `longrun`                                         |
| `rootfs/etc/s6-overlay/s6-rc.d/sea-bridge/run`                       | Service runner with config gating                 |
| `rootfs/etc/s6-overlay/s6-rc.d/sea-bridge/finish`                    | Exit handler (same pattern as oxigraph-projector) |
| `rootfs/etc/s6-overlay/s6-rc.d/sea-bridge/dependencies.d/postgres`   | Depends on postgres                               |
| `rootfs/etc/s6-overlay/s6-rc.d/sea-bridge/dependencies.d/init-addon` | Depends on init-addon                             |

### 3.4 Validation

| File                                                    | Purpose                                 |
| ------------------------------------------------------- | --------------------------------------- |
| `rootfs/.../agent_memory_ledger/validate_sea_bridge.sh` | Schema + connectivity validation script |

---

## 4. NATS Subject Taxonomy

Subjects follow the `sea.{domain}.{action}.{qualifier}` pattern.

### 4.1 Single JetStream Stream: `SEA_LEDGER`

One configurable stream named `SEA_LEDGER` by default, capturing all subjects:

```
sea.agent.event.>
sea.governance.request.>
sea.governance.decision.>
sea.memory.write.>
sea.memory.lifecycle.>
sea.ledger.outbox.>
```

Multiple streams can be a future enhancement. For the first version, one stream
keeps the operational surface small and the replay model simple.

### 4.2 Outbound Subjects (Postgres → NATS)

The bridge publishes to these subjects when canonical events are created:

| Subject                                   | Payload Source                                                 | Description                               |
| ----------------------------------------- | -------------------------------------------------------------- | ----------------------------------------- |
| `sea.agent.event.created`                 | `event_log.agent_events` INSERT                                | Raw agent event appended to canonical log |
| `sea.governance.decision.accepted`        | `governance.action_decisions` WHERE decision='accepted'        | Governance admission accepted             |
| `sea.governance.decision.rejected`        | `governance.action_decisions` WHERE decision='rejected'        | Governance admission rejected             |
| `sea.governance.decision.deferred`        | `governance.action_decisions` WHERE decision='deferred'        | Governance admission deferred             |
| `sea.governance.decision.review_required` | `governance.action_decisions` WHERE decision='requires_review' | Governance admission needs review         |
| `sea.memory.lifecycle.observed`           | `memory.lifecycle_audit` WHERE new_status='observed'           | Memory item observed                      |
| `sea.memory.lifecycle.candidate`          | `memory.lifecycle_audit` WHERE new_status='candidate'          | Memory promoted to candidate              |
| `sea.memory.lifecycle.accepted`           | `memory.lifecycle_audit` WHERE new_status='accepted'           | Memory promoted to accepted               |
| `sea.memory.lifecycle.verified`           | `memory.lifecycle_audit` WHERE new_status='verified'           | Memory verified                           |
| `sea.memory.lifecycle.superseded`         | `memory.lifecycle_audit` WHERE new_status='superseded'         | Memory superseded                         |
| `sea.memory.lifecycle.rejected`           | `memory.lifecycle_audit` WHERE new_status='rejected'           | Memory rejected                           |
| `sea.memory.lifecycle.expired`            | `memory.lifecycle_audit` WHERE new_status='expired'            | Memory expired                            |
| `sea.ledger.outbox.dispatched`            | `event_log.outbox_events` WHERE status='delivered'             | Outbox event dispatched to broker         |
| `sea.identity.event.created`              | `governance.identity_events` INSERT                            | Identity lifecycle event                  |

### 4.3 Inbound Subjects (NATS → Postgres) with Canonical Mapping

The bridge subscribes to inbound subjects and routes each message to the correct
canonical table based on subject:

| Subject Pattern                      | Canonical Target                                             | Description                                                         |
| ------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------- |
| `sea.agent.event.>`                  | `event_log.agent_events` or `event_log.inbox_events`         | Agent events — mapped to canonical event table if envelope is valid |
| `sea.governance.request.>`           | `governance.action_requests`                                 | Governance action requests from external runtimes                   |
| `sea.governance.decision.>`          | `governance.action_decisions`                                | Governance decisions from external runtimes                         |
| `sea.memory.write.>`                 | `memory.items` (candidate flow)                              | External memory write proposals                                     |
| `sea.memory.lifecycle.>`             | `event_log.inbox_events`                                     | External lifecycle transition requests                              |
| Unknown valid `sea.*` subject        | `event_log.inbox_events` or dead-letter based on config      | Catch-all for recognized but unmapped subjects                      |
| Invalid subject or malformed payload | `event_log.inbox_events` with status `failed` or dead-letter | Rejected messages                                                   |

### 4.4 Subject Validation Rules

- All subjects MUST match `sea.{domain}.{action}.{qualifier}` pattern
- Domain must be one of: `agent`, `governance`, `memory`, `ledger`, `identity`
- The bridge MUST reject messages with invalid subjects (dead-letter them)
- Subject mapping is configurable via `config.yaml` but defaults to the taxonomy above

---

## 5. JetStream Stream Configuration

### 5.1 Single Stream: `SEA_LEDGER`

| Property             | Value                                                                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name                 | `SEA_LEDGER` (configurable via `sea_bridge.stream_name`)                                                                                            |
| Subjects             | `sea.agent.event.>`, `sea.governance.request.>`, `sea.governance.decision.>`, `sea.memory.write.>`, `sea.memory.lifecycle.>`, `sea.ledger.outbox.>` |
| Retention            | limits                                                                                                                                              |
| Max age              | 7 days (configurable)                                                                                                                               |
| Max msgs per subject | 1,000,000                                                                                                                                           |
| Storage              | file (durable across restarts)                                                                                                                      |
| Discard policy       | old                                                                                                                                                 |
| Duplicate window     | 2 minutes                                                                                                                                           |
| Replicas             | 1                                                                                                                                                   |

### 5.2 Durable Consumers

| Consumer Name        | Stream       | Filter Subject | Deliver Policy | Description                                    |
| -------------------- | ------------ | -------------- | -------------- | ---------------------------------------------- |
| `sea_bridge_inbound` | `SEA_LEDGER` | `sea.>`        | all            | Inbound message consumer for canonical mapping |

### 5.3 Future Enhancement: Multiple Streams

If operational experience shows that governance decisions need longer retention
than agent events, the single stream can be split. This is explicitly deferred.

---

## 6. JSON Envelope Validation

Envelope validation is part of the implementation path, not a future enhancement.

### 6.1 Required Envelope Fields

All messages on `sea.governance.request.*` and `sea.governance.decision.*` subjects
MUST include:

```json
{
  "envelope_version": "1.0",
  "message_id": "uuid-v4",
  "occurred_at": "ISO-8601-timestamp",
  "identity_id": "uuid-v4",
  "payload": { ... },
  "provenance": { ... }
}
```

### 6.2 Validation Rules

| Subject Pattern             | Required Fields                                                                       | Failure Behavior               |
| --------------------------- | ------------------------------------------------------------------------------------- | ------------------------------ |
| `sea.governance.request.*`  | `envelope_version`, `message_id`, `occurred_at`, `identity_id`, `payload`             | Fail closed → dead-letter      |
| `sea.governance.decision.*` | `envelope_version`, `message_id`, `occurred_at`, `identity_id`, `payload`, `decision` | Fail closed → dead-letter      |
| `sea.memory.write.*`        | `envelope_version`, `message_id`, `source_agent`, `content`                           | Fail closed → dead-letter      |
| `sea.agent.event.*`         | `message_id`, `source_agent`, `event_type`                                            | Fail open → inbox with warning |
| Other `sea.*`               | `message_id`                                                                          | Fail open → inbox              |

### 6.3 Fail-Closed Semantics

Governance subjects (`sea.governance.*`) MUST fail closed:

- Missing required fields → message is NOT written to canonical tables
- Message is recorded in `event_log.inbox_events` with status `failed`
- A `delivery_attempt` record captures the validation error
- The NATS message is ACKed (not redelivered) to prevent loops
- Operator must inspect `event_log.inbox_events WHERE status = 'failed'` to diagnose

---

## 7. Database Role Model

### 7.1 Roles

| Role                | Purpose                                      | Scope                                                                                                                                     |
| ------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `ledger_writer`     | Canonical event writes                       | INSERT on `event_log.agent_events`, `governance.action_requests`, `governance.action_decisions`, `memory.items`, `event_log.inbox_events` |
| `ledger_reader`     | Read-only access for queries and projections | SELECT on all `event_log`, `governance`, `memory` tables                                                                                  |
| `projection_worker` | Oxigraph projection reads                    | SELECT on tables needed for RDF projection                                                                                                |
| `bridge_worker`     | Bridge-specific operations                   | SELECT on outbox, INSERT/UPDATE on inbox, INSERT on delivery_attempts                                                                     |

### 7.2 Password Management

Passwords are configured explicitly under the `security:` config block:

```yaml
security:
  ledger_writer_password: "changeme-writer"
  ledger_reader_password: "changeme-reader"
  projection_worker_password: "changeme-projection"
  bridge_worker_password: "changeme-bridge"
```

**Trade-off analysis:**

Explicit config passwords are visible in the Home Assistant add-on configuration
UI and stored in the add-on options JSON. This is the same security posture as
the existing `postgres` user with password `homeassistant` — the add-on is a
single-tenant local-first system.

Generated password files would be more secure (not visible in UI) but add
operational complexity: users cannot see or copy passwords for external tool
configuration, password rotation requires file deletion + restart, and backup
restore must preserve the password file.

For this add-on's threat model (local network, single tenant), explicit config
is acceptable. If the add-on is ever exposed to untrusted networks, generated
passwords should replace this approach.

### 7.3 Grant Details

```sql
-- Created in 013_sea_bridge_schema.sql
CREATE ROLE ledger_writer NOINHERIT LOGIN PASSWORD '<from config>';
CREATE ROLE ledger_reader NOINHERIT LOGIN PASSWORD '<from config>';
CREATE ROLE projection_worker NOINHERIT LOGIN PASSWORD '<from config>';
CREATE ROLE bridge_worker NOINHERIT LOGIN PASSWORD '<from config>';

-- Schema access
GRANT USAGE ON SCHEMA event_log TO ledger_writer, ledger_reader, bridge_worker;
GRANT USAGE ON SCHEMA governance TO ledger_writer, ledger_reader, bridge_worker;
GRANT USAGE ON SCHEMA memory TO ledger_writer, ledger_reader, bridge_worker;
GRANT USAGE ON SCHEMA embeddings TO ledger_reader, projection_worker;

-- ledger_writer: canonical event writes
GRANT INSERT ON event_log.agent_events TO ledger_writer;
GRANT INSERT ON event_log.inbox_events TO ledger_writer;
GRANT INSERT ON event_log.outbox_events TO ledger_writer;
GRANT INSERT ON governance.action_requests TO ledger_writer;
GRANT INSERT ON governance.action_decisions TO ledger_writer;
GRANT INSERT ON memory.items TO ledger_writer;

-- ledger_reader: read-only
GRANT SELECT ON ALL TABLES IN SCHEMA event_log TO ledger_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA governance TO ledger_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA memory TO ledger_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA embeddings TO ledger_reader;

-- projection_worker: Oxigraph projection reads
GRANT SELECT ON governance.identities TO projection_worker;
GRANT SELECT ON governance.identity_events TO projection_worker;
GRANT SELECT ON governance.identity_lineage TO projection_worker;
GRANT SELECT ON governance.identity_role_bindings TO projection_worker;
GRANT SELECT ON governance.roles TO projection_worker;
GRANT SELECT ON governance.action_requests TO projection_worker;
GRANT SELECT ON governance.action_decisions TO projection_worker;
GRANT SELECT ON governance.policy_versions TO projection_worker;
GRANT SELECT ON memory.items TO projection_worker;
GRANT SELECT ON memory.lifecycle_audit TO projection_worker;
GRANT SELECT ON event_log.agent_events TO projection_worker;

-- bridge_worker: bridge-specific operations
GRANT SELECT ON event_log.outbox_events TO bridge_worker;
GRANT UPDATE ON event_log.outbox_events TO bridge_worker;
GRANT INSERT ON event_log.inbox_events TO bridge_worker;
GRANT UPDATE ON event_log.inbox_events TO bridge_worker;
GRANT INSERT ON event_log.delivery_attempts TO bridge_worker;
GRANT SELECT ON event_log.agent_events TO bridge_worker;
GRANT SELECT ON governance.action_decisions TO bridge_worker;
GRANT SELECT ON governance.action_requests TO bridge_worker;
GRANT SELECT ON governance.identity_events TO bridge_worker;
GRANT SELECT ON memory.items TO bridge_worker;
GRANT SELECT ON memory.lifecycle_audit TO bridge_worker;
```

---

## 8. Configuration Schema

### 8.1 config.yaml Additions

Three new top-level blocks plus one new top-level option:

```yaml
options:
  developer_mode: false
  security:
    ledger_writer_password: ""
    ledger_reader_password: ""
    projection_worker_password: ""
    bridge_worker_password: ""
  sea_bridge:
    enabled: false
  health:
    bind: 127.0.0.1
    port: 8099

schema:
  developer_mode: bool?
  security:
    ledger_writer_password: str?
    ledger_reader_password: str?
    projection_worker_password: str?
    bridge_worker_password: str?
  sea_bridge:
    enabled: bool
    url: str?
    seed: str?
    stream_name: str?
    max_memory_stream: bool?
    inbox_poll_interval_ms: int(100,60000)?
    outbox_poll_interval_ms: int(100,60000)?
    max_batch_size: int(1,1000)?
    max_retries: int(0,100)?
    retry_delay_ms: int(100,300000)?
    dead_letter_after_retries: int(1,100)?
    tls_enabled: bool?
    tls_ca: str?
    tls_cert: str?
    tls_key: str?
  health:
    bind: str?
    port: port?
```

### 8.2 Configuration Options

#### `developer_mode` (top-level)

| Option           | Default | Description                                                                             |
| ---------------- | ------- | --------------------------------------------------------------------------------------- |
| `developer_mode` | `false` | Enables unsafe options: `system_packages`, `init_commands`, and relaxed bridge security |

When `developer_mode=false`:

- `system_packages` is ignored (no packages installed)
- `init_commands` is ignored (no arbitrary commands executed)
- `sea_bridge` requires `security.bridge_worker_password` to be set

When `developer_mode=true`:

- `system_packages` and `init_commands` work as before
- `sea_bridge` allows anonymous NATS connections for local development

#### `security`

| Option                         | Default   | Description                                  |
| ------------------------------ | --------- | -------------------------------------------- |
| `require_password_change`      | `true`    | Warn if default postgres password unchanged  |
| `create_least_privilege_roles` | `true`    | Create DB roles when passwords provided      |
| `ledger_writer_password`       | _(empty)_ | Password for the `ledger_writer` DB role     |
| `ledger_reader_password`       | _(empty)_ | Password for the `ledger_reader` DB role     |
| `projection_worker_password`   | _(empty)_ | Password for the `projection_worker` DB role |
| `bridge_worker_password`       | _(empty)_ | Password for the `bridge_worker` DB role     |

If a password is empty, the corresponding role is not created. This allows
incremental adoption: start with no roles, add them as external tools need access.

#### `sea_bridge`

| Option    | Default         | Description                                          |
| --------- | --------------- | ---------------------------------------------------- |
| `enabled` | `false`         | Master switch for the SEA Forge bridge               |
| `mode`    | `external_nats` | Bridge mode: `external_nats`, `embedded`, `disabled` |

##### `sea_bridge.nats` (NATS Connection)

| Option                    | Default                 | Description                                        |
| ------------------------- | ----------------------- | -------------------------------------------------- |
| `url`                     | `nats://127.0.0.1:4222` | NATS server URL                                    |
| `creds_file`              | _(empty)_               | Path to NATS credentials file                      |
| `token`                   | _(empty)_               | NATS authentication token                          |
| `name`                    | `agent-memory-ledger`   | Client connection name                             |
| `connect_timeout_seconds` | `5`                     | Connection timeout (1–300 seconds)                 |
| `reconnect_wait_seconds`  | `2`                     | Wait between reconnection attempts (1–300 seconds) |
| `max_reconnect_attempts`  | `-1`                    | Max reconnection attempts (-1 for unlimited)       |

##### `sea_bridge.nats.jetstream` (JetStream Configuration)

| Option                  | Default                      | Description                                  |
| ----------------------- | ---------------------------- | -------------------------------------------- |
| `enabled`               | `true`                       | Enable JetStream integration                 |
| `stream_name`           | `SEA_LEDGER`                 | JetStream stream name                        |
| `durable_name`          | `agent_memory_ledger_bridge` | Durable consumer name                        |
| `subjects`              | _(see config.yaml)_          | Subjects to bind to stream                   |
| `outbox_subject_prefix` | `sea.ledger.outbox`          | Prefix for outbox dispatch subjects          |
| `ack_wait_seconds`      | `30`                         | ACK timeout for consumed messages (1–600)    |
| `max_deliver`           | `10`                         | Max redelivery attempts per message (1–1000) |
| `batch_size`            | `100`                        | Messages per pull batch (1–10000)            |
| `poll_interval_seconds` | `2`                          | Seconds between outbox polls (1–3600)        |

##### `sea_bridge.bridge` (Bridge Behavior)

| Option                | Default                 | Description                                    |
| --------------------- | ----------------------- | ---------------------------------------------- |
| `inbound_enabled`     | `true`                  | Enable NATS → Postgres ingestion               |
| `outbound_enabled`    | `true`                  | Enable Postgres → NATS publishing              |
| `dead_letter_enabled` | `true`                  | Enable dead-letter handling                    |
| `dead_letter_subject` | `sea.ledger.deadletter` | Dead-letter subject name                       |
| `idempotency_header`  | `Nats-Msg-Id`           | Header name for idempotency                    |
| `source_name`         | `sea-forge`             | Source identifier for bridge operations        |
| `fail_closed`         | `true`                  | Fail closed on errors (reject if can't verify) |

#### `health`

| Option | Default     | Description                                                        |
| ------ | ----------- | ------------------------------------------------------------------ |
| `bind` | `127.0.0.1` | Network interface for health endpoints (localhost = internal only) |
| `port` | `8099`      | HTTP health check port                                             |

### 8.3 Gating Rules

- `sea_bridge.enabled=false` → bridge service sleeps (same pattern as oxigraph)
- `sea_bridge.enabled=true` AND `agent_memory.enabled=false` → bridge refuses to start
- `sea_bridge.enabled=true` AND `developer_mode=false` AND `security.bridge_worker_password` is empty → bridge logs warning, role not created, bridge uses postgres superuser (with warning)
- `sea_bridge.enabled=true` AND `developer_mode=true` → allows anonymous NATS connection
- `developer_mode=false` → `system_packages` and `init_commands` are silently ignored

---

## 9. Health Checks

### 9.1 HTTP Endpoints

| Endpoint   | Method | Success                  | Failure                                     |
| ---------- | ------ | ------------------------ | ------------------------------------------- |
| `/healthz` | GET    | `200 {"status":"ok"}`    | `503 {"status":"unhealthy","checks":{...}}` |
| `/readyz`  | GET    | `200 {"status":"ready"}` | `503 {"status":"not_ready","checks":{...}}` |

### 9.2 Health Check Details

**`/healthz`** (liveness):

- Bridge process is alive and not deadlocked
- Last poll completed within 2x poll interval

**`/readyz`** (readiness):

- NATS connection is alive (if bridge enabled)
- Postgres connection is alive
- JetStream stream exists (if bridge enabled)
- DB role can authenticate (if roles configured)

### 9.3 Configuration

Health endpoints are configured under the `health:` block:

```yaml
health:
  bind: 127.0.0.1
  port: 8099
```

Default bind is `127.0.0.1` (internal only). The health server runs in the same
Python process as the bridge. If the bridge is disabled, the health server still
runs and reports Postgres connectivity only.

---

## 10. Bridge Architecture

### 10.1 Outbox Poller (Postgres → NATS)

```
Every outbox_poll_interval_ms:
  1. SELECT from event_log.outbox_events WHERE status = 'pending'
     ORDER BY created_at LIMIT max_batch_size
  2. For each event:
     a. Map target_queue to NATS subject
     b. Validate envelope (if governance or memory subject)
     c. Publish to NATS with message_id for dedup
     d. Record delivery_attempt
     e. UPDATE status = 'delivered', dispatched_at = now()
  3. If publish fails:
     a. Record delivery_attempt with error
     b. If attempts >= max_retries: UPDATE status = 'dead_letter'
     c. Else: leave as 'pending' for next poll
```

### 10.2 Inbox Subscriber (NATS → Postgres) with Canonical Mapping

```
On startup:
  1. Subscribe to inbound subjects via durable consumer on SEA_LEDGER
  2. For each message:
     a. Validate subject against taxonomy
     b. Route to canonical table based on subject:
        - sea.governance.request.* → governance.action_requests
        - sea.governance.decision.* → governance.action_decisions
        - sea.memory.write.* → memory.items (candidate flow)
        - sea.agent.event.* → event_log.agent_events or inbox_events
        - unknown valid sea.* → event_log.inbox_events
        - invalid → dead-letter
     c. Validate JSON envelope (fail-closed for governance)
     d. INSERT into target table (idempotent by message_id)
     e. Record delivery_attempt
     f. ACK the message
  3. On validation failure (governance):
     a. INSERT into inbox_events with status 'failed'
     b. Record delivery_attempt with validation error
     c. ACK the message (prevent redelivery loops)
  4. On duplicate message_id:
     a. ACK the message (idempotent)
  5. On other failure:
     a. NACK the message for redelivery
     b. Record delivery_attempt with error
```

### 10.3 Canonical Event Fan-out (Postgres triggers → Outbox)

New SQL trigger functions that automatically create outbox entries when canonical
events are inserted:

| Trigger                          | Source Table                               | Outbox target_queue                        |
| -------------------------------- | ------------------------------------------ | ------------------------------------------ |
| `trg_outbox_agent_event`         | `event_log.agent_events` AFTER INSERT      | `sea.agent.event.created`                  |
| `trg_outbox_governance_decision` | `governance.action_decisions` AFTER INSERT | `sea.governance.decision.{decision_value}` |
| `trg_outbox_memory_lifecycle`    | `memory.lifecycle_audit` AFTER INSERT      | `sea.memory.lifecycle.{new_status}`        |
| `trg_outbox_identity_event`      | `governance.identity_events` AFTER INSERT  | `sea.identity.event.created`               |

These triggers are the **only** mechanism that populates the outbox for canonical
events. External systems writing directly to the outbox is not supported.

---

## 11. Schema Migration: 013_sea_bridge_schema.sql

### 11.1 New Tables

```sql
CREATE TABLE IF NOT EXISTS event_log.sea_bridge_streams (
    stream_name     TEXT PRIMARY KEY,
    subjects        TEXT[] NOT NULL,
    retention       TEXT NOT NULL DEFAULT 'limits',
    max_age         INTERVAL NOT NULL DEFAULT '7 days',
    max_msgs        BIGINT NOT NULL DEFAULT 1000000,
    storage_type    TEXT NOT NULL DEFAULT 'file',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_reconciled TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS event_log.sea_bridge_consumers (
    consumer_name   TEXT PRIMARY KEY,
    stream_name     TEXT NOT NULL REFERENCES event_log.sea_bridge_streams(stream_name),
    deliver_policy  TEXT NOT NULL DEFAULT 'all',
    filter_subject  TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_reconciled TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS event_log.bridge_dedup (
    message_id      TEXT PRIMARY KEY,
    direction       TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 11.2 Schema Changes to Existing Tables

```sql
ALTER TABLE event_log.inbox_events
    ADD COLUMN IF NOT EXISTS source_subject TEXT;

ALTER TABLE event_log.outbox_events
    ADD COLUMN IF NOT EXISTS target_subject TEXT;

CREATE INDEX IF NOT EXISTS idx_inbox_events_source_subject
    ON event_log.inbox_events (source_subject)
    WHERE source_subject IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_outbox_events_target_subject
    ON event_log.outbox_events (target_subject)
    WHERE target_subject IS NOT NULL;
```

### 11.3 Outbox Fan-out Triggers

```sql
CREATE OR REPLACE FUNCTION event_log.fanout_agent_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO event_log.outbox_events (target_queue, target_subject, message_id, headers, payload)
    VALUES (
        'sea.agent.event.created',
        'sea.agent.event.created',
        'agent_event_' || NEW.id,
        jsonb_build_object('source', 'agent_events', 'event_id', NEW.id),
        to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$;
```

### 11.4 Role Creation

Role creation happens in `004_setup_agent_memory.sh` (not in SQL) because
password values come from bashio config. Roles are only created when the
corresponding password is non-empty.

---

## 12. Dockerfile Changes

### 12.1 Python 3 Installation

```dockerfile
RUN apk add --no-cache python3 py3-pip
```

### 12.2 Python Dependencies

Uses `nats-py` (modern JetStream client), NOT `asyncio-nats-streaming`:

```dockerfile
COPY rootfs/usr/share/agent_memory_ledger/requirements-sea-bridge.txt /tmp/
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements-sea-bridge.txt && \
    rm /tmp/requirements-sea-bridge.txt
```

`requirements-sea-bridge.txt`:

```
nats-py>=2.7.0,<3
psycopg[binary]>=3.1.0,<4
```

---

## 13. Service Dependency Graph (Updated)

```
base
 └── init-user
      └── init-addon
           └── postgres
                ├── pgagent
                ├── oxigraph
                │    └── oxigraph-projector
                └── sea-bridge  ← NEW
```

The `sea-bridge` service:

- Depends on `postgres` (needs DB connection)
- Does NOT depend on `oxigraph` (independent subsystem)
- Gates on `sea_bridge.enabled=true` (sleeps otherwise)
- Gates on `agent_memory.enabled=true` (requires agent_memory schema)

---

## 14. Test Strategy

### 14.1 SQL Schema Tests

| Test                                                            | Validates                        |
| --------------------------------------------------------------- | -------------------------------- |
| Idempotent re-run of `013_sea_bridge_schema.sql`                | No errors on duplicate execution |
| `bridge_worker` role can SELECT from outbox                     | Reader grants work               |
| `bridge_worker` role can INSERT into inbox                      | Writer grants work               |
| `bridge_worker` role can UPDATE outbox status                   | Outbox grants work               |
| `bridge_worker` role CANNOT INSERT into `governance.identities` | Least privilege enforced         |
| `bridge_worker` role CANNOT DROP tables                         | No DDL privileges                |
| `ledger_writer` can INSERT into `event_log.agent_events`        | Writer grants work               |
| `ledger_reader` can SELECT but not INSERT                       | Read-only enforced               |
| Fan-out triggers create outbox entries on agent_events INSERT   | Trigger correctness              |
| Duplicate message_id in inbox is rejected                       | Idempotency constraint           |

### 14.2 Envelope Validation Tests

| Test                                                     | Validates            |
| -------------------------------------------------------- | -------------------- |
| Valid governance request envelope passes validation      | Happy path           |
| Governance request missing `identity_id` is rejected     | Fail-closed          |
| Governance decision missing `decision` field is rejected | Fail-closed          |
| Memory write missing `content` is rejected               | Fail-closed          |
| Agent event missing optional fields passes (fail-open)   | Graceful degradation |

### 14.3 Bridge Integration Tests (requires NATS server)

| Test                                                                        | Validates                 |
| --------------------------------------------------------------------------- | ------------------------- |
| Bridge connects to NATS and creates `SEA_LEDGER` stream                     | Connection + stream setup |
| Bridge creates durable consumer                                             | Consumer setup            |
| Outbox poller publishes pending events to NATS                              | Outbound flow             |
| Inbox subscriber routes governance requests to `governance.action_requests` | Canonical mapping         |
| Inbox subscriber routes memory writes to `memory.items`                     | Canonical mapping         |
| Malformed governance message is dead-lettered                               | Fail-closed               |
| Duplicate NATS message is ACKed without re-insert                           | Idempotent ingestion      |
| Health endpoint returns 200 when healthy                                    | Health check              |
| Bridge reconnects after NATS server restart                                 | Resilience                |

---

## 15. Risks and Technical Debt

### 15.1 Risks

| Risk                                                | Likelihood | Impact | Mitigation                                               |
| --------------------------------------------------- | ---------- | ------ | -------------------------------------------------------- |
| Python dependency conflicts with Alpine musl        | Medium     | High   | Pin all deps, test on both architectures                 |
| NATS connection instability in HA network           | Medium     | Medium | Exponential backoff, health checks, auto-reconnect       |
| Single stream becomes bottleneck                    | Low        | Medium | Configurable; split into multiple streams in future      |
| Envelope validation too strict for evolving schemas | Medium     | Medium | Version the envelope; fail-closed on unknown versions    |
| DB role passwords visible in HA add-on config       | Low        | Medium | Document trade-off; generated passwords as future option |

### 15.2 Technical Debt (Accepted)

| Item                                                 | Reason                                 | Resolution Path                                        |
| ---------------------------------------------------- | -------------------------------------- | ------------------------------------------------------ |
| Polling-based outbox instead of LISTEN/NOTIFY        | Simpler initial implementation         | Add LISTEN/NOTIFY as optional enhancement              |
| Python bridge instead of compiled binary             | Faster development in HA addon context | Consider Rust if performance becomes critical          |
| Single bridge process (no horizontal scaling)        | HA addon runs single instance          | Accept; scaling requires distributed locking           |
| Explicit config passwords instead of generated files | Simpler UX for local-first add-on      | Add generated password option in future                |
| Single JetStream stream                              | Simpler operational model              | Split into multiple streams if retention needs diverge |

### 15.3 Future Enhancements (Out of Scope)

- LISTEN/NOTIFY for real-time outbox push
- WebSocket bridge for browser-based dashboards
- Dead-letter queue management UI
- Stream snapshot/backup integration
- Multi-tenant subject namespacing
- Prometheus metrics endpoint
- Distributed tracing (OpenTelemetry)
- Multiple JetStream streams with per-subject retention

---

## 16. Implementation Order

| Slice       | Scope                                                                      | Status        |
| ----------- | -------------------------------------------------------------------------- | ------------- |
| **Slice 1** | config.yaml, schema/options, developer_mode gating, README docs            | **COMPLETED** |
| **Slice 2** | SQL schema (`013_security_roles.sql`), role setup in init script           | **COMPLETED** |
| **Slice 3** | Bridge Python modules (core logic, envelope validation, canonical mapping) | **COMPLETED** |
| **Slice 4** | s6 service, Dockerfile changes                                             | **COMPLETED** |
| **Slice 5** | Health endpoints, validation script                                        | **COMPLETED** |
| Slice 6     | Integration testing                                                        | **PENDING**   |

---

## 17. Acceptance Criteria

- [ ] `sea_bridge.enabled=false` → bridge sleeps, no errors, no NATS connection attempted
- [ ] `sea_bridge.enabled=true` + `agent_memory.enabled=true` → bridge starts and connects
- [ ] Canonical events in Postgres automatically appear on NATS subjects
- [ ] Inbound messages are routed to correct canonical tables by subject
- [ ] Governance requests/decisions fail closed if envelope is malformed
- [ ] Duplicate messages are handled idempotently
- [ ] Failed deliveries retry with exponential backoff
- [ ] Dead-lettered events are queryable in `event_log.delivery_attempts`
- [ ] `/healthz` returns 200 when healthy, 503 when degraded
- [ ] `/readyz` returns 200 when ready, 503 when not ready
- [ ] DB roles have least-privilege access (no superuser)
- [ ] `developer_mode=false` gates `system_packages` and `init_commands`
- [ ] All existing tests continue to pass
- [ ] CI pipeline passes on both amd64 and aarch64
- [ ] Schema migration is idempotent and additive
- [ ] Fan-out triggers preserve append-only guarantees on source tables
