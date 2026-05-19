# Agent Operating Contract for Home Assistant Agent Memory Ledger Addon Development

## Project-Specific Authority

When analyzing this project or generating code, agents MUST check for and prioritize `.github/copilot-instructions.md` when that file exists.

That file contains project-level rules, architecture details, and preferred coding standards that supersede general knowledge and this document where they conflict.

## Project Identity

This repository implements **Agent Memory Ledger** — a local-first persistence,
governance, memory, and event-bridge substrate for SEA Forge and ZeroClaw
governed agent runtimes. It runs as a Home Assistant add-on for convenient
installation and local operation.

PostgreSQL is the canonical source of truth. NATS JetStream is transport and
replay surface. Oxigraph is a rebuildable projection. RuVector embeddings are
derived retrieval artifacts.

## Governed Autonomous Infrastructure

This repository implements infrastructure for governed autonomous systems. It is not a generic CRUD application, a traditional AI wrapper, or merely a vector database extension.

The system models:

- governed autonomous actions
- append-only event history
- replayable governance state
- identity lineage
- qualified memory promotion
- causal auditability
- semantic continuity
- temporal reconstruction

Agents working in this repository MUST preserve these architectural invariants.

## Core Philosophy

The system treats autonomous activity as governed state evolution.

The most important architectural principle is:

```text
canonical_history != derived_state
```

Raw events are canonical. Embeddings, summaries, dashboards, audit projections, and other read models are derived.

Agents MUST NEVER collapse canonical history into derived artifacts.

## Architectural Priorities

When making implementation decisions, optimize in this order:

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

Performance optimizations MUST NOT compromise replayability or auditability.

## Repository Purpose

This repository provides:

- PostgreSQL infrastructure
- TimescaleDB temporal scaling
- RuVector semantic retrieval
- governed identity lifecycle management
- governed action admission ledgers
- append-only event persistence
- replayable governance primitives
- inbox/outbox broker interoperability
- qualified memory lifecycle storage
- audit projection infrastructure
- SEA Forge NATS JetStream event bridge
- Oxigraph RDF/SPARQL semantic graph projection

The repository is intended to support:

- SEA Forge and ZeroClaw agent runtimes
- AI coding agents
- MCP ecosystems
- Home Assistant automations
- local-first autonomous systems
- distributed agent workflows
- semantic runtime infrastructure

This repository is not a full orchestration engine, a generalized AI framework, a replacement for Home Assistant, a centralized policy engine, a distributed consensus layer, or a generic graph database. Avoid introducing orchestration complexity unless the requirement explicitly needs it.

## Canonical System Concepts

### Events

Events are immutable canonical facts. Examples include tool invocations, file mutation requests, command executions, memory promotions, policy decisions, identity creations, identity merges, and role bindings.

Events MUST be append-only.

Agents MUST NOT:

- overwrite historical events
- silently mutate event meaning
- repurpose old events
- destroy provenance chains
- delete canonical events

### Governance

Governance means:

```text
A transition is only valid if admitted
under the active governance context.
```

Governance decisions MUST preserve:

- policy version
- acting identity
- lineage context
- timestamps
- provenance
- admission decision
- causal references

Agents MUST NOT create hidden governance state or silent policy overrides.

### Identity

Identity is governed state. Identities may be created, retired, merged, split, aliased, reclassified, or delegated.

Identity continuity is preserved through lineage. Agents MUST preserve lineage integrity and reject lineage cycles.

Invalid lineage example:

```text
A -> B -> C -> A
```

Identity operations MUST preserve provenance, lineage traceability, governance replayability, and causal consistency.

### Replayability

Replayability is a primary invariant.

The system must be able to reconstruct:

- what happened
- who acted
- which policy governed the action
- why the action was accepted or rejected
- what identity lineage existed
- what causal chain preceded the action

Agents MUST prefer replayable explicit state over hidden implicit logic.

## Database Principles

### Append-Only Philosophy

Historical records should be immutable whenever possible.

Preferred patterns:

- append-only event tables
- immutable governance records
- temporal validity ranges
- supersession instead of mutation
- event sourcing patterns
- explicit lifecycle transitions

Avoid:

- destructive updates
- silent deletes
- history rewriting
- implicit state mutation
- mutable audit history

### Raw Events vs Memory

Raw events are observations. Memory is governed promotion.

Memory lifecycle:

```text
observed
-> candidate
-> accepted
-> verified
-> superseded / rejected / expired
```

Agents MUST preserve the separation between:

```text
what happened
```

and:

```text
what the system chooses to remember
```

### Embeddings

Embeddings are derived retrieval artifacts.

Embeddings MUST:

- link to qualified memory objects
- preserve provenance linkage
- remain regenerable
- never replace canonical history

Agents MUST NOT treat embeddings as canonical truth, store raw historical state only in embeddings, or collapse provenance into vector summaries.

### Policy Records

Policy decisions MUST remain replayable.

Every accepted or rejected action should reference:

- policy version
- request payload
- actor identity
- admission context
- timestamps
- provenance metadata

## Inbox and Outbox Principles

The system is broker-compatible but broker-agnostic. Supported targets may include RabbitMQ, NATS, Redis Streams, Kafka, and future event transports.

Agents MUST preserve:

- idempotency
- replay safety
- delivery traceability
- immutable event IDs

Transport implementations MUST NOT redefine event semantics.

## SEA Forge Bridge

The SEA Forge bridge (`sea_nats_bridge.py`) connects the canonical PostgreSQL
ledger to NATS JetStream for SEA Forge and ZeroClaw integration.

Key constraints:

- PostgreSQL is canonical. JetStream is transport, not authority.
- The bridge uses `nats-py` with JetStream (NOT legacy NATS Streaming).
- Inbound messages are validated against the SEA Event Contract (JSON Schema
  files in `rootfs/usr/share/agent_memory_ledger/contracts/`).
- Governance subjects fail closed. Agent event subjects fail open.
- The `bridge_worker` DB role has least-privilege grants.
- Outbound uses `FOR UPDATE SKIP LOCKED` on `event_log.outbox_events`.
- Dead-letter routing goes to `sea.ledger.deadletter` via core NATS.

When modifying the bridge:

1. Update tests in `tests/` (168 tests across 6 modules).
2. Run `ruff check` on the bridge source and tests.
3. Verify the event contract if envelope validation changes.
4. Ensure `bridge_worker` role grants remain least-privilege.

## Schema Evolution Rules

Schema evolution should be additive first, backward compatible where practical, replay-safe, migration-safe, and provenance-preserving.

Preferred strategy:

```text
add new structures
migrate gradually
deprecate later
remove only with explicit migration guarantees
```

Agents SHOULD prefer:

- idempotent migrations
- additive schema evolution
- explicit provenance
- JSONB extensibility
- Timescale hypertables for temporal data
- immutable audit trails
- foreign key integrity
- deterministic replay behavior
- explicit lifecycle state transitions
- schema versioning

Agents MUST avoid:

- `DROP ... CASCADE` without explicit justification
- destructive migrations
- hidden side effects
- orphaned lineage edges
- embedding-only storage
- non-versioned governance logic
- conflating memory with observations
- irreversible transforms without provenance

## PostgreSQL and TimescaleDB Guidance

- Use Timescale hypertables for large temporal streams.
- Use appropriate indexes for temporal, identity, policy, and replay paths.
- Use JSONB GIN indexes where justified.
- Preserve append-only write efficiency.
- Avoid pathological joins on replay paths.
- Document performance tradeoffs when they affect governance, replay, or audit behavior.
- Install extensions in initialization scripts.
- Use `CREATE EXTENSION IF NOT EXISTS` to keep setup idempotent.
- Check compatibility with the PostgreSQL and TimescaleDB versions in the addon.
- Document version-specific requirements.
- Use `timescaledb-tune` for automatic configuration when appropriate.
- Keep memory settings compatible with container limits and Home Assistant resource constraints.

Correctness is more important than premature optimization.

## Home Assistant Addon Standards

This repository is also a Home Assistant addon. Preserve addon conventions while implementing governed infrastructure.

### Key Components

1. `agent_memory_ledger/`
   - `config.yaml`: addon configuration, options, schema, and ports
   - `Dockerfile`: container build instructions
   - `build.yaml`: build configuration for supported architectures

2. `rootfs/`
   - `etc/s6-overlay/s6-rc.d/`: service definitions using s6-overlay
   - `usr/share/agent_memory_ledger/`: initialization scripts
   - `usr/share/agent_memory_ledger/agent_memory/`: SQL schema migrations
   - `usr/share/agent_memory_ledger/contracts/`: SEA Event Contract JSON Schema files
   - `usr/bin/sea_nats_bridge.py`: SEA Forge NATS JetStream bridge worker

3. `docker-dependencies/`
   - pre-built extension binaries

4. `tests/`
   - pytest test suite (168 tests, pure unit tests with mocks)
   - `conftest.py`, `test_subject_routing.py`, `test_envelope_validation.py`,
     `test_bridge.py`, `test_health.py`, `test_sql_schema.py`, `test_config.py`

5. `docs/`
   - `SEA_EVENT_CONTRACT.md`: formal event contract specification

### Shell Script Standards

- Use `#!/usr/bin/with-contenv bashio` for addon scripts that need Home Assistant integration.
- Always quote variables: `"${variable}"` instead of `$variable`.
- Use `bashio::log.*` functions for logging.
- Check return codes and handle errors gracefully.
- Use meaningful `ALL_CAPS` names for constants.
- Add comments only for non-obvious logic.

### Docker Standards

- Minimize unnecessary layers.
- Clean package manager caches after installation.
- Use version pins where stability is critical.
- Document why specific versions are chosen.
- Follow multi-stage build patterns when applicable.
- All Docker image tags must be pinned (enforced by CI).
- Exceptions must be documented in `scripts/check-dockerfile-deps.sh`.

### Service Management

- Each service has its own directory under `s6-rc.d/`.
- Required service files are `type` and `run`; `finish` is optional.
- Use `dependencies.d/` to control service startup order.
- Services should handle failure and restart behavior deliberately.

Services include: `postgres`, `pgagent`, `oxigraph`, `oxigraph-projector`,
`init-addon`, `init-user`, `user` (bundle), `sea-nats-bridge`.

### Addon Configuration

Configuration belongs in `config.yaml`:

```yaml
options:
  key: value
schema:
  key: type
```

Read configuration with bashio:

```bash
#!/usr/bin/with-contenv bashio

VALUE=$(bashio::config 'option_name')

if bashio::config.exists 'option_name'; then
    bashio::log.info "Option is set"
fi

VALUE=$(bashio::config 'option_name' 'default_value')
```

Use bashio logging:

```bash
bashio::log.info "Informational message"
bashio::log.warning "Warning message"
bashio::log.error "Error message"
bashio::log.debug "Debug message"
```

## Development Workflow

### Planning

1. Read the requirement carefully.
2. Check `.github/copilot-instructions.md` if it exists.
3. Review existing code for similar patterns.
4. Identify replayability, provenance, lineage, policy, and audit implications.
5. Plan focused changes and avoid unrelated edits.

### Implementation

1. Make one coherent feature or fix per change set.
2. Preserve working addon behavior.
3. Follow existing architecture and service patterns.
4. Prefer additive, replay-safe changes.
5. Add logging that helps operators debug without leaking secrets.
6. Update user-facing documentation when behavior or configuration changes.

### Testing

Test initialization scripts for fresh installs and upgrades. Verify configuration options, service startup and shutdown, PostgreSQL extension loading, and supported architectures where practical.

The bridge test suite (`tests/`) contains 168 pure unit tests using mocks. Run with:

```bash
python -m pytest tests/ -v
```

Lint with:

```bash
ruff check agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py tests/
```

Changes affecting governance or canonical history MUST include validation for:

- replayability
- append-only guarantees
- lineage integrity
- identity validity
- policy linkage
- provenance preservation
- idempotency
- duplicate rejection
- migration safety

Important replay tests include:

- reconstruct identity at time T
- reconstruct active policy at time T
- replay action admission decisions
- verify the lineage graph remains acyclic

## Documentation Standards

Documentation should explain:

- what invariant exists
- why it exists
- what breaks if it is violated
- replay implications
- governance implications
- provenance guarantees
- tradeoffs
- operational constraints

Avoid shallow marketing language. This is complex by design because SEA Forge is
complex. Be honest about complexity.

## Code Review Checklist

Before completing work, verify:

- [ ] `.github/copilot-instructions.md` was checked if present
- [ ] code follows existing style and patterns
- [ ] shell scripts have proper shebangs
- [ ] variables are properly quoted
- [ ] error handling is in place
- [ ] logging uses bashio functions
- [ ] configuration changes are reflected in `config.yaml` schema
- [ ] services have proper dependencies defined
- [ ] documentation is updated if needed
- [ ] no hardcoded values should be configurable
- [ ] changes are tested or testable
- [ ] canonical history remains separate from derived state
- [ ] governance decisions remain replayable
- [ ] provenance links are preserved
- [ ] identity lineage remains acyclic
- [ ] migrations are additive or explicitly justified
- [ ] canonical events are not deleted or rewritten
- [ ] bridge changes include corresponding test updates
- [ ] event contract changes are reflected in JSON Schema files

## Getting Help

When stuck:

1. Review existing code for similar patterns.
2. Check Home Assistant addon documentation.
3. Examine bashio library capabilities.
4. Check PostgreSQL, TimescaleDB, and RuVector documentation.
5. Check nats-py documentation for NATS JetStream API.
6. Trace the governance, identity, replay, and provenance invariants affected by the change.
7. Ask specific questions about the architecture or requirement.

## Guiding Principle

```text
Robust autonomous systems preserve:
identity,
causality,
replayability,
and provenance
under constrained change.
```

All implementation decisions should be evaluated against that principle while preserving Home Assistant addon reliability and conventions.
