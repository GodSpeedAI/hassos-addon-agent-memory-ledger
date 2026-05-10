# Agent Memory Ledger

## Governed Autonomous Event Infrastructure for Home Assistant

Agent Memory Ledger is a Home Assistant add-on that provisions PostgreSQL,
TimescaleDB, and RuVector as infrastructure for governed autonomous systems.

It provides:

- append-only agent event history
- governed action admission records
- replayable policy state
- lineage-aware identities
- vector-backed qualified memory
- audit-grade provenance
- broker-ready inbox/outbox tables
- temporal and causal reconstruction primitives
- optional RDF/SPARQL semantic graph projections via Oxigraph

The project is designed for:

- AI coding agents
- MCP tool ecosystems
- Home Assistant automations
- distributed autonomous workflows
- governed multi-agent systems
- local-first cognitive infrastructure
- semantic and event-driven runtime systems

The system treats autonomous activity as governed state evolution, not transient
execution.

## Platform Foundation

This add-on builds on:

| Component | Purpose |
| --- | --- |
| PostgreSQL | Canonical relational persistence |
| TimescaleDB | Temporal/event scaling and hypertables |
| RuVector | Vector similarity and embedding search |
| PostGIS | Geospatial extension support |
| TimescaleDB Toolkit | Time-series analysis helpers |
| pgAgent | PostgreSQL job scheduling |
| Oxigraph | Optional RDF/SPARQL semantic graph projection |

It can still be used as a general PostgreSQL + TimescaleDB add-on for Home
Assistant recorder data, Grafana dashboards, monitoring, and SQL-based
time-series workloads. The Agent Memory profile adds governed event, memory,
identity, and audit schemas on top of that database foundation.

## Core Principles

### 1. Canonical History Is Sacred

Raw events are canonical. Derived artifacts are not.

Derived artifacts include:

- summaries
- embeddings
- dashboards
- audit reports
- reflections
- projections
- analytics

Derived state must remain separable from canonical history:

```text
derived_state != canonical_history
```

Embeddings never replace facts. Summaries never replace memory. Audit views
never replace events.

### 2. Governance Is Transition Admissibility

Every meaningful action is modeled as a transition. A transition is valid only
when admitted under the active governance context.

Examples include:

- tool execution
- file write
- command execution
- memory promotion
- network request
- policy override
- identity mutation

The system records the request, admission decision, policy version, acting
identity, lineage/provenance chain, and resulting event history. This makes
governance replayable and auditable.

### 3. Identity Is Governed State

Identities are governed entities. They may be created, retired, aliased, merged,
split, reclassified, delegated, or inherited.

The system preserves organizational continuity through lineage rather than
immutability:

```text
organizational systems preserve identity by lineage, not immutability
```

### 4. Causality Matters More Than Wall-Clock Time

The system models partially ordered transitions rather than assuming globally
synchronized clocks. Wall-clock timestamps exist, but causal ordering is the
primary architectural primitive for replay, governance reconstruction, and
distributed workflows.

## Architecture Overview

| Component | Purpose |
| --- | --- |
| Event Ledger | Append-only transition history |
| Governance Ledger | Action admission, policies, and auditability |
| Identity Ledger | Governed identity lifecycle and lineage |
| Memory Lifecycle | Promotion from observation to qualified memory |
| Embeddings | RuVector-backed semantic retrieval |
| Replay Layer | Governance reconstruction at a point in time |
| Audit Projections | Derived evidence views linked to source events |
| Inbox/Outbox Layer | Broker interoperability and retry-safe delivery |
| Oxigraph Projection | Optional RDF/SPARQL semantic graph layer |

The system is an append-only temporal graph of governed transitions. Core
entities include agents, humans, services, tools, resources, workspaces,
policies, action requests, governance decisions, memory candidates, and
qualified memories.

Everything evolves through events. Nothing silently mutates.

## Storage Model

When the Agent Memory profile is enabled, the add-on creates an `agent_memory`
database by default.

| Schema | Purpose |
| --- | --- |
| `event_log` | Canonical event history plus inbox/outbox tables |
| `memory` | Qualified memory lifecycle |
| `embeddings` | RuVector embedding storage |
| `governance` | Identity, policy, action, lineage, and replay state |
| `kg` | Oxigraph projection state tracking |
| `audit` | Optional derived audit projections |

The currently provisioned schema files focus on `event_log`, `memory`,
`embeddings`, and `governance`.

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

| Function or view | Purpose |
| --- | --- |
| `governance.identity_status_at(identity_id, timestamp)` | Identity status at a point in time |
| `governance.role_bindings_at(identity_id, timestamp)` | Active role bindings at a point in time |
| `governance.active_policy_at(policy_name, timestamp)` | Active policy version at a point in time |
| `governance.lineage_ancestors(identity_id, max_depth)` | Identity lineage traversal |
| `governance.replay_identity_status` | Current identity status with source event reference |

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

| View | Purpose |
| --- | --- |
| `governance.audit_action_timeline` | Action requests with identity, decision, and policy context |
| `governance.audit_identity_lineage` | Human-readable lineage relationships |
| `governance.audit_policy_usage` | Policy version usage statistics |
| `governance.audit_rejected_actions` | Rejected actions with governance context |
| `governance.replay_identity_status` | Current identity status with last event reference |

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

The architecture images must be public in GHCR before Home Assistant can install the add-on.
Supervisor pulls:

```text
ghcr.io/godspeedai/agent-memory-ledger/amd64:<version>
ghcr.io/godspeedai/agent-memory-ledger/aarch64:<version>
```

If installation fails with `error from registry: denied`, the image tag is
missing or the GHCR package is private. Publish the release images with the
Deploy workflow, then make the `agent-memory-ledger/amd64` and
`agent-memory-ledger/aarch64` packages public in the GodSpeedAI organization
package settings. GHCR public container images can be pulled anonymously, which
is required because Home Assistant Supervisor does not authenticate to this
project's private package registry during add-on installation.

### Standalone Container

You can also run the container on a separate Docker host. Docker Hub is not
required; this project publishes add-on images to GitHub Container Registry.

After the GHCR workflow has published images, pull the image for your
architecture:

```bash
docker pull ghcr.io/godspeedai/agent-memory-ledger/amd64:0.1.0
docker pull ghcr.io/godspeedai/agent-memory-ledger/aarch64:0.1.0
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
  ghcr.io/godspeedai/agent-memory-ledger/amd64:0.1.0
```

Run it as a daemon:

```bash
docker run \
  -d \
  --name agent-memory-ledger \
  -v "${PWD}/agent_memory_ledger_addon_data:/data" \
  -p 5432:5432 \
  ghcr.io/godspeedai/agent-memory-ledger/amd64:0.1.0
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
  retention_days: 90
  embedding_dimension: 1536
  include_embeddings_in_backup: true
```

Options:

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `false` | Enables the Agent Memory profile |
| `database` | `agent_memory` | Database to create/use |
| `create_default_schema` | `true` | Applies bundled schema files |
| `enable_ruvector` | `true` | Enables RuVector and vector search |
| `enable_timescaledb` | `true` | Enables TimescaleDB and hypertables |
| `retention_days` | `90` | Retention period for event hypertables |
| `embedding_dimension` | `1536` | RuVector dimension, from 1 to 4096 |
| `include_embeddings_in_backup` | `true` | Includes embeddings in SQL backups |

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
remains available.

## Security Model

The add-on uses SCRAM-SHA-256 authentication by default.

The default PostgreSQL user is `postgres` with password `homeassistant`. Change
it immediately after first start:

```sql
ALTER USER postgres WITH PASSWORD 'strongpassword';
```

The platform is designed for governance-grade observability through append-only
event philosophy, immutable governance history, policy-version traceability, and
provenance preservation.

## Backup and Restore

Home Assistant backups use SQL dumps rather than raw PostgreSQL data files.

Backup flow:

1. `backup_pre.sh` runs `pg_dumpall` and writes `/data/backup_db.sql`.
2. Home Assistant backs up the SQL dump and add-on data.
3. `backup_post.sh` removes the temporary SQL dump.

Restore flow:

1. The add-on starts with the restored SQL dump.
2. If the PostgreSQL data directory is missing or unusable, the add-on
   initializes a fresh database.
3. The SQL dump is restored automatically.
4. The dump is removed after successful restoration.

This keeps backups portable across systems and PostgreSQL versions, while
excluding the large PostgreSQL data directory from Home Assistant backups.

Manual backup:

Use `addon_agent_memory_ledger_agent_memory_ledger` for the Home Assistant add-on container.
Use `agent-memory-ledger` for the standalone container examples above.

```bash
docker exec addon_agent_memory_ledger_agent_memory_ledger \
  su - postgres -c "pg_dumpall -U postgres --clean --if-exists -f /data/manual_backup_$(date +%Y%m%d).sql"
```

Manual restore:

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
```

The governance validation covers schema presence, identity lifecycle operations,
lineage cycle rejection, append-only protections, policy replay lookup,
accepted/rejected action requests, and audit projection generation.

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

| Category | Default | Contents |
| --- | --- | --- |
| Identity lineage | on | identities, lineage edges, role bindings |
| Governance | on | action requests, decisions, policy references |
| Memory | on | memory items, status, embedding existence |
| Raw events | off | event metadata only (never full JSON payloads) |

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

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `false` | Enables the Oxigraph SPARQL service |
| `data_dir` | `/data/oxigraph` | Persistent storage path for Oxigraph/RocksDB |
| `bind` | `127.0.0.1` | Network interface (localhost = internal only) |
| `port` | `7878` | SPARQL endpoint TCP port |
| `expose_port` | `false` | Expose port outside the add-on network |
| `log_level` | `info` | Oxigraph server log verbosity |
| `project_governance` | `true` | Project action requests and decisions |
| `project_identity_lineage` | `true` | Project identities, lineage, and roles |
| `project_memory` | `true` | Project memory items and lifecycle |
| `project_raw_events` | `false` | Project raw event metadata (not payloads) |
| `rebuild_on_start` | `false` | Clear and rebuild Oxigraph on add-on start |
| `batch_size` | `500` | Records per projection batch |
| `max_projection_interval_seconds` | `60` | Seconds between projection cycles |

### RDF Vocabulary

The projection uses a small internal vocabulary with stable prefixes:

| Prefix | IRI |
| --- | --- |
| `aml:` | `http://agent-memory-ledger.local/ontology#` |
| `id:` | `http://agent-memory-ledger.local/identity/` |
| `evt:` | `http://agent-memory-ledger.local/event/` |
| `act:` | `http://agent-memory-ledger.local/action/` |
| `mem:` | `http://agent-memory-ledger.local/memory/` |
| `pol:` | `http://agent-memory-ledger.local/policy/` |

Key predicates:

| Predicate | Purpose |
| --- | --- |
| `aml:hasType` | Resource type (identity, action_request, memory_item, agent_event) |
| `aml:hasStatus` | Current status |
| `aml:createdAt` | Creation timestamp (xsd:dateTime) |
| `aml:retiredAt` | Retirement timestamp (xsd:dateTime) |
| `aml:actedBy` | Acting identity reference |
| `aml:requestedAction` | Action type |
| `aml:targetResource` | Target resource |
| `aml:governedByPolicy` | Policy version reference |
| `aml:decision` | Admission decision |
| `aml:decisionReason` | Decision explanation |
| `aml:parentIdentity` | Lineage parent |
| `aml:childIdentity` | Lineage child |
| `aml:lineageType` | Lineage relationship type |
| `aml:boundToRole` | Role binding |
| `aml:sourceEvent` | Source event reference |
| `aml:hasMemoryStatus` | Memory lifecycle status |
| `aml:hasEmbedding` | Whether embedding exists (true/false) |
| `aml:observedAt` | Observation timestamp |

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
