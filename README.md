# Agent Memory Ledger

## Local-First Governance Substrate for SEA Forge and ZeroClaw

Agent Memory Ledger is a local-first persistence, governance, memory, and
event-bridge substrate for [SEA Forge](https://github.com/GodSpeedAI) and
ZeroClaw governed agent runtimes. It runs as a Home Assistant add-on for
convenient installation and local operation on home and lab infrastructure.

It provides:

- **Canonical event ledger** — PostgreSQL/TimescaleDB append-only event history
- **Governed action admission** — policy-versioned, identity-aware action
  acceptance and rejection
- **Qualified memory lifecycle** — governed promotion from observation to memory
- **Identity lineage** — acyclic DAG of identity creation, merge, split, and
  delegation
- **NATS JetStream bridge** — bidirectional event transport for SEA Forge
- **Semantic graph projection** — optional Oxigraph RDF/SPARQL layer
- **RuVector embeddings** — vector similarity search over qualified memory
- **Audit-grade provenance** — replayable governance reconstruction at any point
  in time

This is not a casual Home Assistant automation add-on. It is infrastructure for
governed autonomous state evolution — complex by design because SEA Forge is
complex.

### What This Is Not

- Not a standalone policy engine — it records governance decisions, it does not
  make them
- Not a workflow orchestrator — it persists events, it does not sequence them
- Not a general-purpose graph database — Oxigraph is a rebuildable projection,
  not a primary store
- Not making NATS or Oxigraph canonical truth — PostgreSQL is always the
  authority
- Not a replacement for Home Assistant core — it runs alongside it

## Architecture

```text
ZeroClaw / SEA Forge Agents
        |
        | NATS JetStream (transport)
        v
  SEA NATS Bridge (sea_nats_bridge.py)
        |
        | INSERT / UPDATE
        v
  PostgreSQL Canonical Ledger
  (event_log, governance, memory, embeddings schemas)
        |
        +---> RuVector (semantic retrieval over qualified memory)
        |
        +---> Oxigraph (rebuildable RDF/SPARQL projection)
        |
        +---> Backup/Replay (pg_dumpall, migration replay)
```

**PostgreSQL is canonical.** Everything else is derived or transport.

| Component      | Role                                           | Canonical? |
| -------------- | ---------------------------------------------- | ---------- |
| PostgreSQL     | Append-only event and governance persistence   | Yes        |
| TimescaleDB    | Temporal scaling for event hypertables         | Yes        |
| NATS JetStream | Transport and replay surface for SEA Forge     | No         |
| Oxigraph       | Rebuildable RDF/SPARQL semantic projection     | No         |
| RuVector       | Vector similarity search over qualified memory | No         |
| Audit views    | Derived evidence views over canonical history  | No         |

## Quick Start for SEA Forge / ZeroClaw

### 1. Install the Add-on

Add this repository URL in the Home Assistant add-on store:

```text
https://github.com/GodSpeedAI/hassos-addon-agent-memory-ledger
```

Select **Agent Memory Ledger**, install, and start it.

The add-on supports `amd64` and `aarch64`. Images are published to GHCR:

```text
ghcr.io/godspeedai/agent-memory-ledger/amd64:<version>
ghcr.io/godspeedai/agent-memory-ledger/aarch64:<version>
```

If installation fails with `error from registry: denied`, the GHCR package is
private. Make the `agent-memory-ledger/amd64` and `agent-memory-ledger/aarch64`
packages public in the GodSpeedAI organization package settings.

### 2. Enable Agent Memory

```yaml
agent_memory:
  enabled: true
  database: agent_memory
  create_default_schema: true
  enable_ruvector: true
  enable_timescaledb: true
  enable_retention_policy: false
  retention_days: 90
  embedding_dimension: 1536
  include_embeddings_in_backup: true
```

### 3. Configure Secure Passwords

Change the default `postgres` password immediately. Then set least-privilege
role passwords for external tools:

```yaml
security:
  require_password_change: true
  create_least_privilege_roles: true
  ledger_writer_password: "your-strong-password"
  ledger_reader_password: "your-strong-password"
  projection_worker_password: "your-strong-password"
  bridge_worker_password: "your-strong-password"
```

If a password is empty, the corresponding role is not created. This allows
incremental adoption.

### 4. Enable the SEA Forge Bridge

```yaml
sea_bridge:
  enabled: true
  mode: "external_nats"
  nats:
    url: "nats://your-nats-server:4222"
    name: "agent-memory-ledger"
    jetstream:
      enabled: true
      stream_name: "SEA_LEDGER"
      subjects:
        - "sea.agent.event.>"
        - "sea.governance.request.>"
        - "sea.governance.decision.>"
        - "sea.memory.write.>"
        - "sea.memory.lifecycle.>"
  bridge:
    inbound_enabled: true
    outbound_enabled: true
    fail_closed: true
```

Prerequisites:

- `agent_memory.enabled` must be `true`
- A NATS server with JetStream enabled must be reachable at the configured URL
- For production: set `security.bridge_worker_password` and configure NATS
  authentication

### 5. Verify Health

From the Home Assistant terminal:

```bash
# Liveness check
wget -qO- http://127.0.0.1:8099/healthz

# Readiness (shows all dependency checks)
wget -qO- http://127.0.0.1:8099/readyz

# Operational metrics
wget -qO- http://127.0.0.1:8099/metrics-lite
```

### 6. Publish a Test Event

From your NATS client, publish a test agent event:

```bash
nats pub sea.agent.event.test '{"event_type":"test","agent_id":"test-agent"}'
```

### 7. Query the Canonical Table

Connect to PostgreSQL and verify the event was ingested:

```sql
SELECT event_id, event_type, payload, occurred_at
FROM event_log.agent_events
ORDER BY occurred_at DESC
LIMIT 5;
```

## Core Principles

### 1. Canonical History Is Sacred

Raw events are canonical. Derived artifacts are not.

```text
canonical_history != derived_state
```

Derived artifacts include summaries, embeddings, dashboards, audit reports,
reflections, projections, and analytics. Embeddings never replace facts.
Summaries never replace memory. Audit views never replace events.

### 2. Governance Is Transition Admissibility

Every meaningful action is modeled as a transition. A transition is valid only
when admitted under the active governance context.

The system records the request, admission decision, policy version, acting
identity, lineage/provenance chain, and resulting event history. This makes
governance replayable and auditable.

### 3. Identity Is Governed State

Identities are governed entities. They may be created, retired, aliased, merged,
split, reclassified, delegated, or inherited. The system preserves organizational
continuity through lineage rather than immutability.

### 4. Causality Matters More Than Wall-Clock Time

The system models partially ordered transitions rather than assuming globally
synchronized clocks. Causal ordering is the primary architectural primitive for
replay, governance reconstruction, and distributed workflows.

## Platform Foundation

| Component           | Purpose                                       |
| ------------------- | --------------------------------------------- |
| PostgreSQL          | Canonical relational persistence              |
| TimescaleDB         | Temporal/event scaling and hypertables        |
| RuVector            | Vector similarity and embedding search        |
| PostGIS             | Geospatial extension support                  |
| TimescaleDB Toolkit | Time-series analysis helpers                  |
| pgAgent             | PostgreSQL job scheduling                     |
| Oxigraph            | Optional RDF/SPARQL semantic graph projection |
| SEA Forge Bridge    | Optional NATS JetStream event bridge          |

The add-on can also be used as a general PostgreSQL + TimescaleDB server for
Home Assistant recorder data, Grafana dashboards, monitoring, and SQL-based
time-series workloads. The Agent Memory profile adds governed event, memory,
identity, and audit schemas on top of that database foundation.

## Storage Model

When the Agent Memory profile is enabled, the add-on creates an `agent_memory`
database with these schemas:

| Schema       | Purpose                                             |
| ------------ | --------------------------------------------------- |
| `event_log`  | Canonical event history plus inbox/outbox tables    |
| `memory`     | Qualified memory lifecycle                          |
| `embeddings` | RuVector embedding storage                          |
| `governance` | Identity, policy, action, lineage, and replay state |
| `kg`         | Oxigraph projection state tracking                  |
| `audit`      | Optional derived audit projections                  |

## Schema Migration Discipline

The add-on tracks applied schema migrations in
`agent_memory.schema_migrations`. Each numbered SQL file (000 through 013 and
beyond) is a migration with a sha256 checksum.

### How It Works

1. On first startup, all migrations are applied in order and recorded with
   their checksums.
2. On subsequent startups, each migration is checked against the tracking
   table:
   - **Not applied** → apply and record.
   - **Applied, same checksum** → skip silently.
   - **Applied, different checksum** → fail closed.

### Checksum Mismatch

If a historical migration file is edited after it has been applied, the init
script detects the checksum change and refuses to proceed. This prevents silent
schema drift.

Resolution:

- **Do not edit existing migration files.**
- Create a new numbered SQL file (e.g., `014_your_new_feature.sql`).
- If you must reapply during local development, set `developer_mode: true`.
  This logs a loud warning and allows the reapply, but should never be used in
  production.

### Adding New Migrations

1. Create a new file: `agent_memory/014_description.sql`
2. Use `CREATE ... IF NOT EXISTS` and other idempotent patterns.
3. The init script will detect it as a new migration, apply it, and record it.

### Migration Tracking Table

```sql
SELECT version, description, checksum, applied_at
FROM agent_memory.schema_migrations
ORDER BY version;
```

| Column        | Type        | Purpose                              |
| ------------- | ----------- | ------------------------------------ |
| `version`     | TEXT (PK)   | Migration number (e.g., `001`)       |
| `description` | TEXT        | Human-readable name from filename    |
| `checksum`    | TEXT        | sha256 of the SQL file at apply time |
| `applied_at`  | TIMESTAMPTZ | When the migration was applied       |

This table is append-only. Do not DELETE or UPDATE rows.

## Event Model

Events are append-only immutable records.

Examples:

- agent session started
- tool invocation requested
- file write proposed
- file write accepted
- memory candidate created
- memory accepted
- policy override requested
- action rejected
- identity merged
- role assigned

Event guarantees include immutable event IDs, provenance linkage, append-only
semantics, replayability support, policy version traceability, and identity
lineage traceability.

## Memory System

Raw events are observations. Memory is governed promotion.

```text
observed -> candidate -> accepted -> verified -> superseded / rejected / expired
```

The system separates:

```text
what happened
```

from:

```text
what the system chooses to remember
```

RuVector-backed embeddings support semantic recall, memory retrieval, similarity
search, and contextual materialization. Embeddings are linked to qualified memory
objects, not directly to raw events. Embeddings are regenerable; canonical
history is not.

## Identity Governance

Supported identity classes include:

- agent
- human
- service
- tool
- role
- workspace
- resource

Supported identity transitions include:

```text
create_identity
retire_identity
alias_identity
split_identity
merge_identity
reclassify_identity
bind_role
unbind_role
```

Identity transitions are first-class events. They participate in causal ordering
like operational actions.

The system maintains a lineage DAG over identities. This enables organizational
continuity, delegated authority tracing, replayable provenance, auditability
after mergers/splits, and identity inheritance policies. The lineage graph is
enforced as acyclic.

## Governed Agent Action Ledger

The Governed Agent Action Ledger answers:

```text
Did this identity have authority
to perform this transition
under the active governance context?
```

Action flow:

1. The acting identity exists and remains valid.
2. An action request is submitted.
3. The governance layer evaluates identity validity, lineage, role bindings,
   active policy versions, resource constraints, and transition admissibility.
4. A decision is recorded: `accepted`, `rejected`, `requires_review`, or
   `deferred`.
5. Accepted and rejected actions both become canonical history.

The ledger stores infrastructure primitives. It is not a policy engine, planner,
or workflow orchestrator.

## Replayability

The system is designed for governance replayability, not full environmental
determinism.

Replay reconstructs:

- why a decision occurred
- which policy allowed or rejected it
- which identity lineage authorized it
- which role bindings were active
- which causal history preceded it

Available replay helpers include:

| Function or view                                        | Purpose                                             |
| ------------------------------------------------------- | --------------------------------------------------- |
| `governance.identity_status_at(identity_id, timestamp)` | Identity status at a point in time                  |
| `governance.role_bindings_at(identity_id, timestamp)`   | Active role bindings at a point in time             |
| `governance.active_policy_at(policy_name, timestamp)`   | Active policy version at a point in time            |
| `governance.lineage_ancestors(identity_id, max_depth)`  | Identity lineage traversal                          |
| `governance.replay_identity_status`                     | Current identity status with source event reference |

## Inbox / Outbox Infrastructure

Broker-ready tables support RabbitMQ, NATS, event streaming systems, and
distributed ingestion without coupling the database to a specific broker.

Included tables:

- `event_log.inbox_events`
- `event_log.outbox_events`
- `event_log.delivery_attempts`

These tables support replay-safe ingestion, idempotent delivery, retry
semantics, and delivery audit trails.

## Auditability

Audit projections are derived evidence views over canonical history.

Examples:

- action timelines
- policy usage reports
- rejected action analysis
- identity lineage reports
- governance replay traces

Current governance audit views include:

| View                                | Purpose                                                     |
| ----------------------------------- | ----------------------------------------------------------- |
| `governance.audit_action_timeline`  | Action requests with identity, decision, and policy context |
| `governance.audit_identity_lineage` | Human-readable lineage relationships                        |
| `governance.audit_policy_usage`     | Policy version usage statistics                             |
| `governance.audit_rejected_actions` | Rejected actions with governance context                    |
| `governance.replay_identity_status` | Current identity status with last event reference           |

All derived views preserve source-event linkage. Audit artifacts can trace back
to canonical events.

## Installation

### Home Assistant Add-on Store

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FGodSpeedAI%2Fhassos-addon-agent-memory-ledger)

Or add this repository URL manually in the Home Assistant add-on store:

```text
https://github.com/GodSpeedAI/hassos-addon-agent-memory-ledger
```

Select the `Agent Memory Ledger` add-on, install it, start it, and review the
add-on logs.

The add-on currently supports `amd64` and `aarch64`.

### Standalone Container

You can also run the container on a separate Docker host. Docker Hub is not
required; this project publishes add-on images to GitHub Container Registry.

The architecture images must be public in GHCR before Home Assistant can install the add-on.

After the GHCR workflow has published images, pull the image for your
architecture:

```bash
docker pull ghcr.io/godspeedai/agent-memory-ledger/amd64:0.3.2
docker pull ghcr.io/godspeedai/agent-memory-ledger/aarch64:0.3.2
```

For local development, build the image from this repository:

```bash
docker build \
  --build-arg BUILD_FROM=ghcr.io/hassio-addons/base/amd64:20.1.1 \
  --build-arg BUILD_ARCH=amd64 \
  -t agent-memory-ledger:local \
  agent_memory_ledger
```

For `aarch64`, use `ghcr.io/hassio-addons/base/aarch64:20.1.1` and
`BUILD_ARCH=aarch64`.

Run it in the foreground:

```bash
docker run \
  --rm \
  --name agent-memory-ledger \
  -v "${PWD}/agent_memory_ledger_addon_data:/data" \
  -p 5432:5432 \
  ghcr.io/godspeedai/agent-memory-ledger/amd64:0.3.2
```

Run it as a daemon:

```bash
docker run \
  -d \
  --name agent-memory-ledger \
  -v "${PWD}/agent_memory_ledger_addon_data:/data" \
  -p 5432:5432 \
  ghcr.io/godspeedai/agent-memory-ledger/amd64:0.3.2
```

This maps PostgreSQL port `5432` and stores add-on data in
`./agent_memory_ledger_addon_data`.

Use `agent-memory-ledger:local` instead of the GHCR image name when
running a locally built image.

## Enabling Agent Memory Ledger

Add the Agent Memory profile to the add-on configuration:

```yaml
agent_memory:
  enabled: true
  database: agent_memory
  create_default_schema: true
  enable_ruvector: true
  enable_timescaledb: true
  enable_retention_policy: false
  retention_days: 90
  embedding_dimension: 1536
  include_embeddings_in_backup: true
```

Options:

| Option                         | Default        | Purpose                                |
| ------------------------------ | -------------- | -------------------------------------- |
| `enabled`                      | `false`        | Enables the Agent Memory profile       |
| `database`                     | `agent_memory` | Database to create/use                 |
| `create_default_schema`        | `true`         | Applies bundled schema files           |
| `enable_ruvector`              | `true`         | Enables RuVector and vector search     |
| `enable_timescaledb`           | `true`         | Enables TimescaleDB and hypertables    |
| `enable_retention_policy`      | `false`        | Enable TimescaleDB retention on events |
| `retention_days`               | `90`           | Retention period (only when enabled)   |
| `embedding_dimension`          | `1536`         | RuVector dimension, from 1 to 4096     |
| `include_embeddings_in_backup` | `true`         | Includes embeddings in SQL backups     |

**Warning:** `enable_retention_policy` defaults to `false` because TimescaleDB
retention policies delete data from hypertables. Since `event_log.agent_events`
contains canonical event history, enabling retention will permanently destroy
append-only records after the specified period. Only enable this when you have
explicit operational requirements for data expiration and accept the loss of
canonical history for expired events.

When enabled, the add-on applies conservative PostgreSQL defaults suitable for
small Home Assistant systems:

- `shared_buffers = 256MB`
- `effective_cache_size = 768MB`
- `work_mem = 16MB`
- `maintenance_work_mem = 128MB`
- `max_worker_processes = 4`
- `max_parallel_workers_per_gather = 2`
- `jit = off`

Override these with `postgresql_config` when your hardware can support higher
limits.

## PostgreSQL Configuration

Use `postgresql_config` for declarative PostgreSQL settings:

```yaml
postgresql_config:
  log_min_duration_statement: "1000"
  work_mem: "16MB"
  maintenance_work_mem: "256MB"
  effective_cache_size: "4GB"
  random_page_cost: "1.1"
  checkpoint_completion_target: "0.9"
```

Notes:

- Configuration changes require an add-on restart.
- Critical parameters such as `shared_preload_libraries`, `port`, and
  `data_directory` are managed by the add-on.
- Invalid parameters are logged and skipped.
- User settings are applied after TimescaleDB tuning.

Use `pg_hba_config` to append authentication rules:

```yaml
pg_hba_config:
  - type: "host"
    database: "all"
    user: "all"
    address: "192.168.1.0/24"
    method: "scram-sha-256"
  - type: "host"
    database: "all"
    user: "guest"
    address: "0.0.0.0/0"
    method: "reject"
```

Rules are appended to defaults and evaluated in order. Incorrect authentication
rules can lock you out of the database, so keep at least one known-good access
path.

For advanced cases not covered by declarative configuration, `init_commands`
remains available (gated by `developer_mode`).

## Security Model

### Default Credentials

The add-on uses SCRAM-SHA-256 authentication by default.

The default PostgreSQL user is `postgres` with password `homeassistant`. **Change
it immediately after first start:**

```sql
ALTER USER postgres WITH PASSWORD 'strongpassword';
```

### Least-Privilege Database Roles

The `security` configuration block creates least-privilege PostgreSQL roles for
external tools and services:

```yaml
security:
  require_password_change: true
  create_least_privilege_roles: true
  ledger_writer_password: "your-strong-password"
  ledger_reader_password: "your-strong-password"
  projection_worker_password: "your-strong-password"
  bridge_worker_password: "your-strong-password"
```

Options:

| Option                         | Default   | Purpose                                            |
| ------------------------------ | --------- | -------------------------------------------------- |
| `require_password_change`      | `true`    | Warn if the default postgres password is unchanged |
| `create_least_privilege_roles` | `true`    | Create DB roles when passwords are provided        |
| `ledger_writer_password`       | _(empty)_ | Password for the `ledger_writer` DB role           |
| `ledger_reader_password`       | _(empty)_ | Password for the `ledger_reader` DB role           |
| `projection_worker_password`   | _(empty)_ | Password for the `projection_worker` DB role       |
| `bridge_worker_password`       | _(empty)_ | Password for the `bridge_worker` DB role           |

### Role Scopes

| Role                | Capabilities                                                                                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ledger_writer`     | INSERT on canonical event tables (`event_log.agent_events`, `governance.action_requests`, `governance.action_decisions`, `memory.items`, `event_log.inbox_events`) |
| `ledger_reader`     | SELECT on all tables in `event_log`, `governance`, `memory`, and `embeddings` schemas                                                                              |
| `projection_worker` | SELECT on governance, identity, memory, and event tables needed for RDF projection                                                                                 |
| `bridge_worker`     | SELECT/UPDATE on outbox, INSERT/UPDATE on inbox, INSERT on delivery_attempts                                                                                       |

### Connection Strings

External tools connect using standard PostgreSQL connection strings:

```text
# Read-only queries (Grafana, analytics, audit tools)
postgresql://ledger_reader:your-password@homeassistant.local:5432/agent_memory

# Canonical event writes (SEA Forge agents, ZeroClaw)
postgresql://ledger_writer:your-password@homeassistant.local:5432/agent_memory

# Oxigraph projection worker
postgresql://projection_worker:your-password@homeassistant.local:5432/agent_memory

# SEA Forge bridge worker
postgresql://bridge_worker:your-password@homeassistant.local:5432/agent_memory
```

Replace `homeassistant.local` with your Home Assistant hostname or IP address.
The port defaults to `5432` unless changed in the add-on network configuration.

### Security Validation

Run security role validation inside the container:

```bash
/usr/share/agent_memory_ledger/validate_security.sh
```

The validation covers:

- all four roles exist
- no role has superuser, createdb, createrole, replication, or bypassrls
- bridge_worker can INSERT into inbox/outbox but cannot DROP tables
- ledger_reader is read-only (cannot INSERT, UPDATE, DELETE)
- ledger_writer can INSERT but cannot UPDATE or DELETE
- projection_worker can write projection state but not canonical tables
- schema USAGE grants match the expected scope for each role
- functional INSERT/DENY tests confirm privilege enforcement

### Trade-off: Explicit Passwords vs. Generated Files

Passwords are stored in the Home Assistant add-on configuration, which is
visible in the add-on UI. This is the same security posture as the existing
`postgres` user with password `homeassistant` — the add-on is designed for
single-tenant, local-network deployments.

Generated password files would be more secure (not visible in the UI) but add
operational complexity: users cannot copy passwords for external tool
configuration, password rotation requires file deletion and restart, and backup
restore must preserve the password file.

If the add-on is ever exposed to untrusted networks, generated passwords should
replace this approach.

## Developer Mode

The `developer_mode` option controls access to unsafe operations that are useful
for local development but inappropriate for production deployments.

```yaml
developer_mode: false
```

When `developer_mode` is `false` (default):

- `system_packages` is silently ignored — no arbitrary packages are installed
- `init_commands` is silently ignored — no arbitrary commands are executed
- The SEA Forge bridge requires explicit authentication configuration

When `developer_mode` is `true`:

- `system_packages` and `init_commands` are active
- The SEA Forge bridge allows anonymous NATS connections for local development
- A warning is logged at startup

This gate exists because `system_packages` and `init_commands` allow arbitrary
code execution inside the add-on container. Each `init_command` is executed via
`bash -c`, which supports shell expansion, pipes, and redirections. This is
inherently unsafe — that is why it is gated behind `developer_mode`. In
production, all configuration should be handled through the declarative options
provided by the add-on.

## SEA Forge Bridge

The `sea_bridge` configuration block enables a NATS JetStream event bridge for
SEA Forge and ZeroClaw integration. The bridge connects the Agent Memory
Ledger's Postgres-based canonical event store to external agent runtimes.

**Postgres remains the canonical source of truth.** JetStream is transport and
replay surface, not authority.

This feature is intended for SEA Forge / ZeroClaw users who need governed event
bridging between the Agent Memory Ledger and external agent runtimes. Casual
Home Assistant users do not need to configure it.

### Configuration

```yaml
agent_memory:
  enabled: true

sea_bridge:
  enabled: true
  mode: "external_nats"
  nats:
    url: "nats://127.0.0.1:4222"
    name: "agent-memory-ledger"
    jetstream:
      enabled: true
      stream_name: "SEA_LEDGER"
      subjects:
        - "sea.agent.event.>"
        - "sea.governance.request.>"
        - "sea.governance.decision.>"
        - "sea.memory.write.>"
        - "sea.memory.lifecycle.>"
  bridge:
    inbound_enabled: true
    outbound_enabled: true
    fail_closed: true
```

### SEA Bridge Options

| Option    | Default         | Purpose                                              |
| --------- | --------------- | ---------------------------------------------------- |
| `enabled` | `false`         | Master switch for the SEA Forge bridge               |
| `mode`    | `external_nats` | Bridge mode: `external_nats`, `embedded`, `disabled` |

> **Note:** The `embedded` mode is not yet implemented. Setting `mode` to
> `embedded` will log a warning and the bridge will not start. Use
> `external_nats` with a separately deployed NATS server.

### NATS Connection Options

| Option                         | Default                 | Purpose                                    |
| ------------------------------ | ----------------------- | ------------------------------------------ |
| `nats.url`                     | `nats://127.0.0.1:4222` | NATS server URL                            |
| `nats.creds_file`              | _(empty)_               | Path to NATS credentials file              |
| `nats.token`                   | _(empty)_               | NATS authentication token                  |
| `nats.name`                    | `agent-memory-ledger`   | Client connection name                     |
| `nats.connect_timeout_seconds` | `5`                     | Connection timeout (1–300)                 |
| `nats.reconnect_wait_seconds`  | `2`                     | Wait between reconnection attempts (1–300) |
| `nats.max_reconnect_attempts`  | `-1` (unlimited)        | Max reconnection attempts (-1 to 1000)     |

### JetStream Options

| Option                                 | Default                      | Purpose                                      |
| -------------------------------------- | ---------------------------- | -------------------------------------------- |
| `nats.jetstream.enabled`               | `true`                       | Enable JetStream integration                 |
| `nats.jetstream.stream_name`           | `SEA_LEDGER`                 | JetStream stream name                        |
| `nats.jetstream.durable_name`          | `agent_memory_ledger_bridge` | Durable consumer name                        |
| `nats.jetstream.subjects`              | _(see above)_                | Subjects to bind to the stream               |
| `nats.jetstream.outbox_subject_prefix` | `sea.ledger.outbox`          | Prefix for outbox dispatch subjects          |
| `nats.jetstream.ack_wait_seconds`      | `30`                         | ACK timeout for consumed messages (1–600)    |
| `nats.jetstream.max_deliver`           | `10`                         | Max redelivery attempts per message (1–1000) |
| `nats.jetstream.batch_size`            | `100`                        | Messages per pull batch (1–10000)            |
| `nats.jetstream.poll_interval_seconds` | `2`                          | Seconds between outbox polls (1–3600)        |

### Bridge Behavior Options

| Option                       | Default                 | Purpose                                        |
| ---------------------------- | ----------------------- | ---------------------------------------------- |
| `bridge.inbound_enabled`     | `true`                  | Enable NATS → Postgres ingestion               |
| `bridge.outbound_enabled`    | `true`                  | Enable Postgres → NATS publishing              |
| `bridge.dead_letter_enabled` | `true`                  | Enable dead-letter routing for failed messages |
| `bridge.dead_letter_subject` | `sea.ledger.deadletter` | Subject for dead-lettered messages             |
| `bridge.idempotency_header`  | `Nats-Msg-Id`           | Header key for deduplication                   |
| `bridge.source_name`         | `sea-forge`             | Source identifier for bridge-originated events |
| `bridge.fail_closed`         | `true`                  | Reject malformed governance messages           |

### Subject Taxonomy

The bridge uses a single JetStream stream (`SEA_LEDGER` by default) with these
subjects:

| Subject                     | Direction | Description                    |
| --------------------------- | --------- | ------------------------------ |
| `sea.agent.event.>`         | In/Out    | Agent events                   |
| `sea.governance.request.>`  | In/Out    | Governance action requests     |
| `sea.governance.decision.>` | In/Out    | Governance admission decisions |
| `sea.memory.write.>`        | In/Out    | Memory write proposals         |
| `sea.memory.lifecycle.>`    | In/Out    | Memory lifecycle transitions   |
| `sea.ledger.outbox.>`       | Out only  | Outbox dispatch confirmations  |

### Canonical Mapping

Inbound messages are routed to the correct canonical table based on subject:

| Subject Pattern             | Canonical Target                |
| --------------------------- | ------------------------------- |
| `sea.governance.request.*`  | `governance.action_requests`    |
| `sea.governance.decision.*` | `governance.action_decisions`   |
| `sea.memory.write.*`        | `memory.items` (candidate flow) |
| `sea.agent.event.*`         | `event_log.agent_events`        |
| Unknown valid `sea.*`       | `event_log.inbox_events`        |
| Invalid subject             | Dead-letter                     |

### Envelope Validation

Governance requests and decisions require a valid JSON envelope. Messages that
fail validation are not written to canonical tables — they are recorded in
`event_log.inbox_events` with status `failed` and the NATS message is ACKed to
prevent redelivery loops.

Required envelope fields for governance subjects:

```json
{
  "envelope_version": "1.0",
  "message_id": "uuid-v4",
  "occurred_at": "ISO-8601-timestamp",
  "identity_id": "uuid-v4",
  "payload": {}
}
```

Governance subjects fail closed. Agent event subjects fail open (missing
optional fields produce a warning but the message is still processed).

### Event Contract

The bridge validates inbound messages against a formal event contract defined in
JSON Schema files under `rootfs/usr/share/agent_memory_ledger/contracts/`. See
`docs/SEA_EVENT_CONTRACT.md` for the full contract specification and
`docs/TELEMETRY_INTEGRATION.md` for detailed telemetry integration architecture, deduplication logic, and memory lifecycle actuators.

## Health Endpoints

The `health` configuration block controls HTTP health check endpoints for
container orchestration, monitoring, and operational debugging.

```yaml
health:
  enabled: true
  bind: 127.0.0.1
  port: 8099
```

Options:

| Option    | Default     | Purpose                                       |
| --------- | ----------- | --------------------------------------------- |
| `enabled` | `true`      | Enable or disable the health HTTP server      |
| `bind`    | `127.0.0.1` | Network interface (localhost = internal only) |
| `port`    | `8099`      | HTTP health check port                        |

The health server starts before the bridge connects to dependencies, so it is
always available for liveness checks even during startup or connection failures.

### Endpoints

| Endpoint        | Method | Success                  | Failure                          |
| --------------- | ------ | ------------------------ | -------------------------------- |
| `/healthz`      | GET    | `200 {"status":"ok"}`    | `503 {"status":"unhealthy",...}` |
| `/readyz`       | GET    | `200 {"status":"ready"}` | `503 {"status":"not_ready",...}` |
| `/metrics`      | GET    | `200` Prometheus text    | `200` (always 200)               |
| `/metrics-lite` | GET    | `200 {...}`              | `200 {...}` (always 200)         |

### `/healthz` — Liveness

Returns 200 if the bridge process is alive and not deadlocked. Checks:

- Bridge process is running
- Poll loop is not stalled (lag < 3x poll interval)

### `/readyz` — Readiness

Returns 200 only when all dependencies are operational. Checks (in order):

1. **Postgres connection** — `SELECT 1` succeeds
2. **Schema exists** — `agent_memory` schema is present
3. **Migrations current** — `agent_memory.schema_migrations` has records
4. **bridge_worker role** — can query `event_log.inbox_events`,
   `event_log.outbox_events`, `event_log.agent_events`
5. **Oxigraph projection** — `kg.oxigraph_projection_state` shows no errors
   (only when Oxigraph is enabled)
6. **NATS connection** — connected (only when `sea_bridge.enabled=true`)
7. **JetStream stream** — `SEA_LEDGER` stream exists with messages
   (only when `sea_bridge.nats.jetstream.enabled=true`)
8. **Durable consumer** — consumer exists in the stream

Each check appears in the `checks` object with a status string. Any failure
produces a 503 with diagnostic details.

### `/metrics-lite` — Operational Metrics

Returns plain JSON with operational counters. Always returns 200.

```json
{
  "bridge_enabled": true,
  "nats_connected": true,
  "last_message_at": "2026-05-18T12:34:56Z",
  "last_error": null,
  "last_error_at": null,
  "messages_processed": 142,
  "inbox_pending_count": 0,
  "inbox_failed_count": 2,
  "outbox_pending_count": 1,
  "outbox_failed_count": 0,
  "projection_lag_seconds": 12.3
}
```

### `/metrics` — Prometheus Metrics

Returns metrics in Prometheus exposition format for scraping by Prometheus,
Victoria Metrics, or compatible collectors. Always returns 200.

Exposed metrics:

| Metric                                | Type    | Description                              |
| ------------------------------------- | ------- | ---------------------------------------- |
| `sea_bridge_running`                  | gauge   | Whether the bridge process is running    |
| `sea_bridge_nats_connected`           | gauge   | Whether NATS is connected                |
| `sea_bridge_messages_processed_total` | counter | Total messages processed                 |
| `sea_bridge_last_message_timestamp`   | gauge   | Unix timestamp of last processed message |
| `sea_bridge_last_error_timestamp`     | gauge   | Unix timestamp of last error             |
| `sea_bridge_poll_lag_seconds`         | gauge   | Seconds since last poll cycle            |
| `sea_bridge_inbox_events`             | gauge   | Inbox events by status (label: status)   |
| `sea_bridge_outbox_events`            | gauge   | Outbox events by status (label: status)  |
| `sea_bridge_projection_lag_seconds`   | gauge   | Seconds since last Oxigraph projection   |

Example Prometheus scrape config:

```yaml
scrape_configs:
  - job_name: "agent-memory-ledger"
    static_configs:
      - targets: ["host.docker.internal:8099"]
    metrics_path: "/metrics"
    scrape_interval: 15s
```

### Checking Health from Home Assistant

From the Home Assistant terminal (Settings → System → Terminal):

```bash
# Liveness
wget -qO- http://127.0.0.1:8099/healthz

# Readiness (shows all dependency checks)
wget -qO- http://127.0.0.1:8099/readyz

# Operational metrics
wget -qO- http://127.0.0.1:8099/metrics-lite
```

Or from an automation or REST sensor:

```yaml
sensor:
  - platform: rest
    name: Agent Memory Ledger Health
    resource: http://127.0.0.1:8099/readyz
    json_attributes:
      - checks
    value_template: "{{ value_json.status }}"
```

Default bind is `127.0.0.1` (internal only). The health server is not exposed
outside the add-on container by default. To expose, set `bind` to `0.0.0.0`
and map port `8099/tcp` in the add-on configuration.

## Failure Symptoms and Fixes

### NATS Unreachable

**Symptom:** Bridge logs connection errors. `/readyz` shows `nats: disconnected`.

**Cause:** NATS server not running or wrong URL.

**Fix:** Verify `sea_bridge.nats.url`. Ensure the NATS server is running and
reachable from the Home Assistant host. Check firewall rules.

### Duplicate Messages

**Symptom:** Same event appears multiple times in canonical tables.

**Cause:** NATS redelivery due to missing ACK, or duplicate `Nats-Msg-Id`
headers.

**Fix:** The bridge uses inbox idempotency to deduplicate by message ID. Check
`event_log.inbox_events` for duplicate detection. If the producer is sending
duplicates with different message IDs, fix the producer.

### Migration Checksum Mismatch

**Symptom:** Add-on logs `checksum mismatch` and refuses to start.

**Cause:** A SQL migration file was edited after it was applied.

**Fix:** Do not edit applied migrations. Create a new numbered SQL file. In
`developer_mode`, warnings are logged but startup continues.

### Bridge Role Auth Failure

**Symptom:** Bridge logs `authentication failed for user bridge_worker`.

**Cause:** Wrong password or role not created.

**Fix:** Verify `security.bridge_worker_password` matches. Ensure
`013_security_roles.sql` was applied. Run `validate_security.sh` inside the
container.

### Malformed SEA Event

**Symptom:** Events appear in `event_log.inbox_events` with status `failed`.

**Cause:** Inbound message failed contract validation.

**Fix:** Check `event_log.delivery_attempts.error_message` for details. Fix the
message producer to comply with the SEA Event Contract in
`docs/SEA_EVENT_CONTRACT.md`.

### Postgres Not Ready

**Symptom:** `/readyz` shows `postgres: error: ...`.

**Cause:** PostgreSQL still starting or crashed.

**Fix:** Check add-on logs for `postgres` service errors. Verify
`max_connections` and memory limits are appropriate for your hardware.

### Schema Not Found

**Symptom:** `/readyz` shows `schema: agent_memory schema NOT found`.

**Cause:** `agent_memory.enabled=false` or init script failed.

**Fix:** Enable `agent_memory.enabled=true`. Check init-addon logs.

### Comprehensive Failure Reference

| Symptom                     | `/readyz` check                         | Likely Cause                                       | Resolution                                                                                   |
| --------------------------- | --------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Postgres not ready          | `postgres: error: ...`                  | PostgreSQL still starting or crashed               | Check add-on logs for `postgres` service errors. Verify `max_connections` and memory limits. |
| Schema not found            | `schema: agent_memory schema NOT found` | `agent_memory.enabled=false` or init script failed | Enable `agent_memory.enabled=true`. Check init-addon logs.                                   |
| Migrations none             | `migrations: none recorded`             | Fresh install or init script skipped migrations    | Normal on first start. If persistent, check init-addon logs.                                 |
| bridge_worker role error    | `bridge_worker_role: error: ...`        | Role not created or password mismatch              | Set `security.bridge_worker_password`. Run `validate_security.sh`.                           |
| NATS unreachable            | `nats: disconnected`                    | NATS server not running or wrong URL               | Verify `sea_bridge.nats.url`. Ensure NATS server is running and reachable.                   |
| JetStream error             | `jetstream: error: ...`                 | JetStream not enabled on NATS server               | Start NATS with `-js` flag. Check NATS server configuration.                                 |
| Consumer missing            | `consumer: error: ...`                  | Durable consumer not created                       | Bridge creates it on first start. If deleted, restart the add-on.                            |
| Migration checksum mismatch | (in add-on logs)                        | SQL file was modified after migration              | Do not edit applied migrations. Add new numbered SQL files instead.                          |
| Invalid SEA event contract  | (in add-on logs)                        | Inbound message failed contract validation         | Check `event_log.delivery_attempts.error_message` for details. Fix the message producer.     |
| Auth failure                | (in add-on logs)                        | Wrong password for bridge_worker role              | Verify `security.bridge_worker_password` matches. Run `validate_security.sh`.                |

## Backup and Restore

### How Backups Work

Home Assistant backups use SQL dumps rather than raw PostgreSQL data files.

Backup flow:

1. `backup_pre.sh` runs `pg_dumpall` piped through `gzip` and writes
   `/data/backup_db.sql.gz`.
2. Home Assistant backs up the compressed SQL dump and add-on data.
3. `backup_post.sh` removes the temporary compressed dump.

Restore flow:

1. The add-on starts with the restored dump file.
2. If the PostgreSQL data directory is missing or unusable, the add-on
   initializes a fresh database.
3. The restore script detects compressed (`.sql.gz`) or plain (`.sql`) dumps
   and restores automatically.
4. The dump is removed after successful restoration.

This keeps backups portable across systems and PostgreSQL versions, while
excluding the large PostgreSQL data directory from Home Assistant backups.
Compressed backups significantly reduce storage for large event histories.

### What Is Canonical in Backup

The `pg_dumpall` output is the canonical backup. It contains:

- All schema definitions
- All data in `event_log`, `governance`, `memory`, and `embeddings` schemas
- Migration tracking records
- Role definitions and grants

### What Is Derived and Rebuildable

These do not need to be backed up because they can be reconstructed:

- **Oxigraph data** — fully rebuildable from Postgres via
  `oxigraph.rebuild_on_start: true`
- **NATS JetStream stream** — transport/replay surface, not long-term authority
  unless SEA Forge configuration says otherwise
- **Embeddings** — regenerable from qualified memory objects (unless
  `include_embeddings_in_backup: false`)

### Manual Backup

Use `addon_agent_memory_ledger_agent_memory_ledger` for the Home Assistant
add-on container. Use `agent-memory-ledger` for the standalone container.

```bash
docker exec addon_agent_memory_ledger_agent_memory_ledger \
  su - postgres -c "pg_dumpall -U postgres --clean --if-exists -f /data/manual_backup_$(date +%Y%m%d).sql"
```

### Manual Restore

```bash
docker exec addon_agent_memory_ledger_agent_memory_ledger \
  su - postgres -c "psql -U postgres -f /data/manual_backup_YYYYMMDD.sql -d postgres"
```

If `include_embeddings_in_backup` is `false`, the `embeddings` schema is
excluded to reduce backup size. Embeddings can be regenerated from qualified
memory objects.

## Validation

Run validation inside the container:

```bash
/usr/share/agent_memory_ledger/validate_agent_memory.sh
/usr/share/agent_memory_ledger/validate_governance.sh
/usr/share/agent_memory_ledger/validate_security.sh
```

The governance validation covers schema presence, identity lifecycle operations,
lineage cycle rejection, append-only protections, policy replay lookup,
accepted/rejected action requests, and audit projection generation.

The security validation covers role existence, dangerous privilege absence,
schema USAGE grants, table-level privilege enforcement, and functional
INSERT/DENY tests for each role.

## Oxigraph Semantic Graph Projection

### What Oxigraph Is

Oxigraph is a rebuildable semantic graph projection over canonical Postgres
history. It is used for SPARQL queries, identity lineage traversal, governance
provenance, and semantic overlays.

**Oxigraph is not the source of truth.** Postgres remains canonical.

### Architecture

```text
Postgres (canonical) --> Projection Worker --> Oxigraph (derived RDF)
```

The projection is:

- **one-directional**: Postgres to Oxigraph only, never the reverse
- **rebuildable**: Oxigraph data can be destroyed and fully reconstructed from
  Postgres
- **optional**: the add-on works normally when Oxigraph is disabled
- **off the hot path**: projection runs periodically, not on every write
- **configurable**: you choose which categories of data to project

### What Gets Projected

| Category         | Default | Contents                                       |
| ---------------- | ------- | ---------------------------------------------- |
| Identity lineage | on      | identities, lineage edges, role bindings       |
| Governance       | on      | action requests, decisions, policy references  |
| Memory           | on      | memory items, status, embedding existence      |
| Raw events       | off     | event metadata only (never full JSON payloads) |

### Enabling Oxigraph

Oxigraph requires `agent_memory.enabled=true`. Add the Oxigraph configuration
to the add-on options:

```yaml
agent_memory:
  enabled: true

oxigraph:
  enabled: true
  bind: 127.0.0.1
  port: 7878
  expose_port: false
  project_governance: true
  project_identity_lineage: true
  project_memory: true
  project_raw_events: false
  rebuild_on_start: false
  batch_size: 500
  max_projection_interval_seconds: 60
```

Options:

| Option                            | Default          | Purpose                                       |
| --------------------------------- | ---------------- | --------------------------------------------- |
| `enabled`                         | `false`          | Enables the Oxigraph SPARQL service           |
| `data_dir`                        | `/data/oxigraph` | Persistent storage path for Oxigraph/RocksDB  |
| `bind`                            | `127.0.0.1`      | Network interface (localhost = internal only) |
| `port`                            | `7878`           | SPARQL endpoint TCP port                      |
| `expose_port`                     | `false`          | Expose port outside the add-on network        |
| `log_level`                       | `info`           | Oxigraph server log verbosity                 |
| `project_governance`              | `true`           | Project action requests and decisions         |
| `project_identity_lineage`        | `true`           | Project identities, lineage, and roles        |
| `project_memory`                  | `true`           | Project memory items and lifecycle            |
| `project_raw_events`              | `false`          | Project raw event metadata (not payloads)     |
| `rebuild_on_start`                | `false`          | Clear and rebuild Oxigraph on add-on start    |
| `batch_size`                      | `500`            | Records per projection batch                  |
| `max_projection_interval_seconds` | `60`             | Seconds between projection cycles             |

### RDF Vocabulary

The projection uses a small internal vocabulary with stable prefixes:

| Prefix | IRI                                          |
| ------ | -------------------------------------------- |
| `aml:` | `http://agent-memory-ledger.local/ontology#` |
| `id:`  | `http://agent-memory-ledger.local/identity/` |
| `evt:` | `http://agent-memory-ledger.local/event/`    |
| `act:` | `http://agent-memory-ledger.local/action/`   |
| `mem:` | `http://agent-memory-ledger.local/memory/`   |
| `pol:` | `http://agent-memory-ledger.local/policy/`   |

Key predicates:

| Predicate              | Purpose                                                            |
| ---------------------- | ------------------------------------------------------------------ |
| `aml:hasType`          | Resource type (identity, action_request, memory_item, agent_event) |
| `aml:hasStatus`        | Current status                                                     |
| `aml:createdAt`        | Creation timestamp (xsd:dateTime)                                  |
| `aml:retiredAt`        | Retirement timestamp (xsd:dateTime)                                |
| `aml:actedBy`          | Acting identity reference                                          |
| `aml:requestedAction`  | Action type                                                        |
| `aml:targetResource`   | Target resource                                                    |
| `aml:governedByPolicy` | Policy version reference                                           |
| `aml:decision`         | Admission decision                                                 |
| `aml:decisionReason`   | Decision explanation                                               |
| `aml:parentIdentity`   | Lineage parent                                                     |
| `aml:childIdentity`    | Lineage child                                                      |
| `aml:lineageType`      | Lineage relationship type                                          |
| `aml:boundToRole`      | Role binding                                                       |
| `aml:sourceEvent`      | Source event reference                                             |
| `aml:hasMemoryStatus`  | Memory lifecycle status                                            |
| `aml:hasEmbedding`     | Whether embedding exists (true/false)                              |
| `aml:observedAt`       | Observation timestamp                                              |

UUIDs are represented as stable IRIs (not blank nodes). Timestamps use
`xsd:dateTime`.

### Example SPARQL Queries

#### Identity Lineage for an Identity

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX id: <http://agent-memory-ledger.local/identity/>
SELECT ?child ?lineageType WHERE {
    id:<IDENTITY_UUID> aml:parentIdentity ?child .
    ?child aml:lineageType ?lineageType .
}
```

#### All Actions by an Agent

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX id: <http://agent-memory-ledger.local/identity/>
SELECT ?action ?type ?decision ?time WHERE {
    ?action aml:actedBy id:<IDENTITY_UUID> ;
            aml:requestedAction ?type ;
            aml:decision ?decision ;
            aml:observedAt ?time .
}
ORDER BY DESC(?time)
```

#### Rejected Actions and Policy Versions

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
SELECT ?action ?agent ?policy ?reason WHERE {
    ?action aml:decision "rejected" ;
            aml:actedBy ?agent ;
            aml:governedByPolicy ?policy ;
            aml:decisionReason ?reason .
}
```

#### Accepted Memories and Source Events

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
SELECT ?memory ?agent ?event ?time WHERE {
    ?memory aml:hasMemoryStatus "accepted" ;
            aml:hasSourceAgent ?agent ;
            aml:sourceEvent ?event ;
            aml:createdAt ?time .
}
ORDER BY DESC(?time)
```

#### Policy Usage Over Actions

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
SELECT ?policy (COUNT(?action) AS ?actionCount)
       (COUNT(DISTINCT ?agent) AS ?agentCount) WHERE {
    ?action aml:governedByPolicy ?policy ;
            aml:actedBy ?agent .
}
GROUP BY ?policy
ORDER BY DESC(?actionCount)
```

#### Role Bindings

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
SELECT ?identity ?role WHERE {
    ?identity aml:hasActiveRole ?role .
}
```

#### Identities from a Split or Merge

```sparql
PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX id: <http://agent-memory-ledger.local/identity/>
SELECT ?related ?lineageType WHERE {
    {
        id:<IDENTITY_UUID> aml:parentIdentity ?related .
        ?related aml:lineageType ?lineageType .
    } UNION {
        ?related aml:parentIdentity id:<IDENTITY_UUID> .
        ?related aml:lineageType ?lineageType .
    }
}
```

### Rebuilding Oxigraph

Oxigraph data is fully rebuildable from Postgres. To rebuild:

1. Set `oxigraph.rebuild_on_start: true` in add-on configuration.
2. Restart the add-on.
3. The projection worker will clear Oxigraph data and re-project from Postgres.
4. After rebuild completes, set `rebuild_on_start: false` to avoid rebuilding
   on every restart.

**Rebuild does NOT modify Postgres canonical tables.** It only clears the
Oxigraph RocksDB store and re-runs the projection queries.

### Projection State Tracking

The projection worker tracks its progress in the `kg.oxigraph_projection_state`
table. Each projection category (identity_lineage, governance, memory,
raw_events) has a row with:

- `last_event_time`: the timestamp of the last projected record
- `last_event_id`: the UUID of the last projected record
- `status`: idle, running, completed, or error
- `error`: error message if the last projection failed
- `last_projected_at`: when the last successful projection ran

This makes the projection resumable and idempotent.

### Security

Oxigraph defaults to internal access only (`bind: 127.0.0.1`). The SPARQL
endpoint is not exposed outside the add-on container by default.

If you set `expose_port: true`:

- the SPARQL endpoint becomes accessible on the add-on's network port
- SPARQL queries can reveal governance data, identity relationships, and
  action history
- restrict access to trusted networks only
- consider a reverse proxy with authentication for external access

### Resource Considerations

Oxigraph uses RocksDB for storage. On Home Assistant Yellow (Raspberry Pi CM4,
8 GB RAM, NVMe):

- Oxigraph adds approximately 20-30 MB RAM when idle
- Projection batches add temporary CPU and I/O during processing
- RocksDB compaction may cause periodic disk I/O spikes
- Projection data size depends on the number of identities, actions, and
  memories projected
- Raw event projection (disabled by default) significantly increases data volume

The projection worker is designed to be lightweight:

- configurable batch size (default 500 records)
- configurable interval (default 60 seconds)
- no hot-path blocking
- graceful degradation if Oxigraph is unavailable

### Validation

Run Oxigraph validation inside the container:

```bash
/usr/share/agent_memory_ledger/validate_oxigraph.sh
```

The Oxigraph validation covers:

- service running when enabled
- service not running when disabled
- SPARQL endpoint responding
- identity lineage projection
- governance action projection
- memory lifecycle projection
- projection state tracking
- rebuild safety (Postgres tables unchanged)
- raw events not projected unless enabled

## Example Use Cases

### SEA Forge / ZeroClaw Agent Governance

Govern autonomous coding agents, track tool invocations, enforce policy on file
mutations, record governance decisions, and maintain replayable provenance for
every action.

### Local AI Coding Infrastructure

Govern local coding agents, MCP toolchains, and automation runtimes. Track file
mutations, tool usage, command execution, memory writes, policy decisions, and
provenance.

### Home Assistant Autonomous Automations

Govern automations capable of device control, notification dispatch, workflow
execution, and network operations while preserving auditability, replayability,
causal history, and policy traceability.

### Multi-Agent Coordination

Track delegation, authority inheritance, role transitions, policy evolution, and
inter-agent actions with replayable governance state.

### Time-Series Home Assistant Storage

Use PostgreSQL and TimescaleDB for recorder data, sensor history, Grafana
dashboards, and SQL-based analytics. TimescaleDB gives Home Assistant users
time-series scaling while retaining the PostgreSQL ecosystem.

## Non-Goals

This project is not:

- a full agent framework
- a workflow orchestrator
- a policy engine
- a distributed consensus system
- a general-purpose graph database
- a replacement for Home Assistant core

It is infrastructure for governed autonomous state evolution.

## Guiding Formal Principle

```text
Robust systems preserve identity,
causality,
and recoverability
under constrained change.
```

That principle drives the architecture.

## Acknowledgments

We would like to thank [Expaso](https://github.com/expaso/hassos-addon-timescaledb) for the initial PostgreSQL and TimescaleDB add-on foundation, which we have heavily modified and extended for the Agent Memory Ledger.
