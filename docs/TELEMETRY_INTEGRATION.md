# NATS Telemetry Integration & Lifecycle Actuator

This document describes how the Home Assistant Agent Memory Ledger Addon integrates with NATS JetStream as a telemetry event substrate, specifically covering message ingestion and governed memory lifecycle transitions.

## Ingestion Bridge (`sea_nats_bridge.py`)

The bridge worker connects directly to the local NATS server (specified via the `nats_url` option in `config.yaml`) and subscribes to the `SEA_LEDGER` stream (subject wildcard `sea.agent.event.>`).

### Message ID Resolution & Deduplication
To preserve replay safety and strict idempotency, every message is assigned a unique message ID to prevent duplicate writes:
1. **X-Idempotency-Key Header**: Custom HTTP-style header (priority 1).
2. **Nats-Msg-Id Header**: Native NATS JetStream message ID (priority 2).
3. **Envelope Event ID**: The UUID found inside the standard v1 JSON telemetry envelope (`event_id` field) (priority 3).
4. **SHA-256 Digest fallback**: Derived from the exact bytes of the subject + payload (priority 4).

## Memory Lifecycle Actuator

Memory objects are stored under the PostgreSQL schema `memory.items`. In addition to raw observation ingestion, the bridge listens for explicit memory lifecycle transition events published on the subject wildcard `sea.memory.lifecycle.*`.

### Transition Event Format (v1 Envelope)
Transition requests map to the following JSON structure:

```json
{
  "schema_version": "v1",
  "event_id": "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
  "source": "zeroclaw",
  "source_agent": "zeroclaw/agent@v0.7",
  "occurred_at": "2026-05-21T21:30:00.000Z",
  "payload": {
    "memory_item_id": "a1b2c3d4-e5f6-7a8b-9c0d-e1f2a3b4c5d6",
    "new_status": "accepted",
    "changed_by": "zeroclaw/agent@v0.7",
    "reason": "Successfully verified memory coherence against policy"
  }
}
```

> [!NOTE]
> The `event_type` in general telemetry envelopes is used for human-readable logging and routing; for memory lifecycle transitions, the routing is determined by the NATS subject prefix `sea.memory.lifecycle.*`, and the transition payload contains the domain fields (`memory_item_id`, `new_status`, `changed_by`, and optionally `reason`) directly within the `payload` block.

### Database Operations
When a transition request is received, the bridge executes a single transactional state update:
1. **Locks the Row**: Acquires a `FOR UPDATE` lock on `memory.items` for `memory_item_id`.
2. **Captures Current State**: Extracts the `old_status` of the memory item.
3. **Validates FSM State Transition**: Assures that the transition from `old_status` to `new_status` is allowed according to the lifecycle finite state machine (e.g. `observed` -> `candidate` -> `accepted` / `rejected` -> `verified` / `expired` -> `superseded`). If the transition is illegal, it rejects the message to the dead-letter queue.
4. **Performs State Update**: Updates the status in `memory.items` to the requested `new_status` (`memory_status` enum).
5. **Appends to Audit Trail**: Inserts a new record into `memory.lifecycle_audit` containing the full context (`memory_item_id`, `old_status`, `new_status`, `changed_by`, `reason`, `created_at`), preserving append-only historical provenance.

## Security & Identity Trust

The `changed_by` field in lifecycle transition requests records the **claimed** identity of the system or actor triggering the change. When `changed_by` is absent from the payload, it defaults to the envelope's `source_agent` value.

Full identity authentication requires NATS Access Control List (ACL) configuration at the NATS server level to ensure only authorized agents can publish messages to `sea.memory.lifecycle.*` subjects. Without NATS ACLs, any NATS publisher can set arbitrary `source_agent` or `changed_by` values.

Operators MUST configure secure NATS accounts and subject-level write permissions in production environments. Refer to the [NATS Authorization documentation](https://docs.nats.io/nats-concepts/security/authorization) for details.

## Addon Configuration

Enable the database schema and bridge service inside your `config.yaml` options:

```yaml
options:
  agent_memory: true
  sea_bridge: true
  nats_url: "nats://127.0.0.1:4222"
```
