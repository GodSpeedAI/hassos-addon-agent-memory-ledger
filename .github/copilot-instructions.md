# Copilot Instructions for Agent Memory Ledger

## Read This First

This repository implements **Agent Memory Ledger** — a local-first persistence,
governance, memory, and event-bridge substrate for SEA Forge and ZeroClaw
governed agent runtimes. It runs as a Home Assistant add-on.

Copilot suggestions must preserve the repository's core invariant:

```text
canonical_history != derived_state
```

Raw events are canonical. Embeddings, summaries, projections, dashboards, and
audit views are derived. Do not replace canonical history with derived artifacts.

PostgreSQL is the canonical source of truth. NATS JetStream is transport and
replay surface. Oxigraph is a rebuildable projection. RuVector embeddings are
derived retrieval artifacts.

## Architectural Priorities

When choosing between designs, optimize in this order:

1. correctness
2. replayability
3. provenance
4. append-only integrity
5. governance traceability
6. causal reconstruction
7. auditability
8. semantic consistency
9. operational simplicity
10. performance

Performance improvements must not weaken replayability, provenance, or auditability.

## Repository Map

- `agent_memory_ledger/config.yaml`: Home Assistant addon options, schema, ports, and exposed services.
- `agent_memory_ledger/Dockerfile`: addon image build.
- `agent_memory_ledger/build.yaml`: architecture build configuration.
- `agent_memory_ledger/rootfs/etc/s6-overlay/s6-rc.d/`: s6-overlay service definitions.
- `agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/`: PostgreSQL initialization, tuning, backup, restore, and validation scripts.
- `agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/agent_memory/`: governed memory, governance, inbox/outbox, replay, audit, and identity SQL modules.
- `agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts/`: SEA Event Contract JSON Schema files for envelope validation.
- `agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py`: SEA Forge NATS JetStream bridge worker.
- `tests/`: pytest test suite (168 tests, pure unit tests with mocks).
- `docs/SEA_EVENT_CONTRACT.md`: formal event contract specification.

Follow nearby file patterns before introducing new conventions.

## Governed Memory Rules

Events are immutable canonical facts. Prefer append-only event tables, immutable governance records, temporal validity ranges, supersession, and explicit lifecycle transitions.

Never suggest code that:

- overwrites historical events
- deletes canonical events
- rewrites audit history
- silently mutates event meaning
- stores historical truth only in embeddings
- conflates observations with governed memory
- creates hidden governance state
- bypasses policy versioning or actor identity

Memory is governed promotion, not raw observation. Preserve this lifecycle:

```text
observed -> candidate -> accepted -> verified -> superseded / rejected / expired
```

Embeddings are retrieval artifacts. They must link back to qualified memory objects, preserve provenance, remain regenerable, and never become canonical truth.

## Governance and Identity Rules

Governance decisions must be replayable. Accepted and rejected actions should retain:

- policy version
- request payload
- actor identity
- admission context
- timestamps
- provenance metadata
- causal references

Identity is governed state. Preserve lineage when identities are created, retired, merged, split, aliased, reclassified, or delegated.

Identity lineage must remain acyclic. Reject or prevent cycles such as:

```text
A -> B -> C -> A
```

Prefer explicit, queryable state over implicit behavior hidden in scripts or application logic.

## SEA Forge Bridge Rules

The bridge (`sea_nats_bridge.py`) connects PostgreSQL to NATS JetStream.

Key constraints:

- PostgreSQL is canonical. JetStream is transport, not authority.
- Uses `nats-py` with JetStream (NOT legacy NATS Streaming).
- Inbound messages are validated against JSON Schema contracts in `contracts/`.
- Governance subjects fail closed. Agent event subjects fail open.
- The `bridge_worker` DB role has least-privilege grants.
- Outbound uses `FOR UPDATE SKIP LOCKED` on `event_log.outbox_events`.
- Dead-letter routing goes to `sea.ledger.deadletter` via core NATS.

When modifying the bridge:

1. Update tests in `tests/` (168 tests across 6 modules).
2. Run `ruff check` on the bridge source and tests.
3. Verify the event contract if envelope validation changes.
4. Ensure `bridge_worker` role grants remain least-privilege.

### Key nats-py API Notes

- `add_stream()` / `add_consumer()` — NOT `create_stream()` / `create_consumer()`
- `reconnect_time_wait` — NOT `reconnect_wait`
- Pull consumer: `sub = await js.pull_subscribe()` then `msgs = await sub.fetch()`
- psycopg returns JSONB as `dict` (auto-deserialized), not `str`
- `js.publish()` raises `NoStreamResponseError` when subject not in stream

## SQL and Migration Guidance

Use additive, replay-safe schema evolution. Prefer:

- idempotent SQL scripts
- `CREATE ... IF NOT EXISTS` where PostgreSQL supports it
- explicit constraints and foreign keys
- immutable or append-only audit tables
- temporal validity columns for state transitions
- JSONB for extensible metadata with clear provenance
- Timescale hypertables for large temporal streams
- indexes on replay, identity, policy, timestamp, and event lookup paths

Avoid:

- `DROP ... CASCADE` unless explicitly justified
- destructive migrations
- orphaned lineage edges
- irreversible transforms without provenance
- non-versioned governance logic
- mutable audit projections presented as canonical state

If a change affects `agent_memory/*.sql`, include validation for replayability, append-only behavior, lineage integrity, policy linkage, provenance preservation, idempotency, duplicate rejection, and migration safety.

## Shell Script Guidance

For addon scripts that need Home Assistant integration, use:

```bash
#!/usr/bin/with-contenv bashio
```

Shell scripts must:

- quote variables, for example `"${VALUE}"`
- use `bashio::log.info`, `bashio::log.warning`, `bashio::log.error`, or `bashio::log.debug`
- validate configuration values read from `bashio::config`
- handle missing files, permissions, and command failures
- use clear exit codes
- avoid `echo` for operator-facing logs

Keep initialization scripts idempotent. They must handle fresh installs and upgrades.

## Home Assistant Addon Guidance

Configuration changes must update both `options` and `schema` in `agent_memory_ledger/config.yaml`.

Services under `s6-rc.d/` must have deliberate dependencies and predictable startup behavior. Long-running daemons should use `type` set to `longrun`; one-time initialization should use the existing local pattern.

Do not hardcode values that belong in addon configuration. Preserve backward compatibility unless a migration and documentation explain the breaking change.

## PostgreSQL, TimescaleDB, and Extensions

Use `CREATE EXTENSION IF NOT EXISTS` for extension setup. Check version compatibility before changing PostgreSQL, TimescaleDB, RuVector, or extension behavior.

Use `timescaledb-tune` only where it respects container limits and Home Assistant resource constraints. Document any manual tuning that changes replay or write-path behavior.

## Testing Expectations

The test suite contains 168 pure unit tests across 6 modules:

| Module | Tests | Coverage area |
|---|---|---|
| `test_subject_routing.py` | 21 | Subject family extraction, canonical route mapping, message ID derivation |
| `test_envelope_validation.py` | 47 | Envelope validation, payload validation, contract validation, fail-open/fail-closed |
| `test_bridge.py` | 17 | Inbound processing, idempotency, transactionality, outbound dispatch |
| `test_health.py` | 15 | `/healthz`, `/readyz`, `/metrics-lite`, HTTP routing |
| `test_sql_schema.py` | 55 | SQL schema smoke tests, least-privilege role grants, constraint validation |
| `test_config.py` | 5 | BridgeConfig defaults, env loading, DSN construction |

Run with:

```bash
python -m pytest tests/ -v
```

Lint with:

```bash
ruff check agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py tests/
```

For SQL or governance changes, prefer tests or validation scripts that prove:

- identity can be reconstructed at time T
- active policy can be reconstructed at time T
- action admission decisions can be replayed
- identity lineage remains acyclic
- duplicate events are rejected or handled idempotically
- migrations can run more than once safely

For addon behavior, verify initialization, service startup and shutdown, configuration validation, extension loading, backup, and restore paths where affected.

## Documentation Expectations

Update `README.md`, `README-DEV.md`, or focused design docs when a user-facing option, operational flow, schema contract, or governance invariant changes.

Documentation should explain:

- what invariant exists
- why it exists
- what breaks if it is violated
- how replayability and provenance are preserved
- operational tradeoffs

Use direct technical language. Avoid marketing phrasing. This is complex by design
because SEA Forge is complex. Be honest about complexity.

## Completion Checklist

Before suggesting a completed change, confirm:

- canonical history remains separate from derived state
- governance decisions remain replayable
- provenance links are preserved
- identity lineage remains acyclic
- migrations are additive or explicitly justified
- addon configuration and documentation match behavior
- shell scripts use bashio conventions
- affected validation scripts or tests are updated
- bridge changes include corresponding test updates
- event contract changes are reflected in JSON Schema files
- `bridge_worker` role grants remain least-privilege
