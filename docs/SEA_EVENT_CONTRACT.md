# SEA Event Contract

## 1. Overview

This document defines the canonical event contract for the SEA (Supervised Event Architecture) event bus. It specifies the envelope structure, subject taxonomy, payload schemas, validation rules, and failure semantics that all producers and consumers must follow.

### Audience

| Consumer                   | Role                                                                          |
| -------------------------- | ----------------------------------------------------------------------------- |
| SEA Forge                  | Produces governance requests and memory writes; consumes governance decisions |
| ZeroClaw                   | Consumes governance requests; produces governance decisions; reads memory     |
| Home Assistant automations | Produces agent events and memory writes via the addon API                     |
| MCP ecosystems             | Produces and consumes events through the MCP bridge adapter                   |

### Core Principle

**Postgres is canonical. NATS is transport.**

NATS carries events between services. PostgreSQL stores the durable, append-only record. If NATS and Postgres disagree, Postgres wins. Every event that enters the system lands in an inbox table before any other processing occurs. Derived state (embeddings, summaries, dashboards) is never treated as canonical.

---

## 2. Common Envelope

All five event types share this envelope structure. Fields are top-level keys in every message published to NATS.

```json
{
  "schema_version": "v1",
  "event_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "idempotency_key": "req-789-abc",
  "source": "zeroclaw",
  "source_agent": "zeroclaw/refactor-agent",
  "occurred_at": "2026-05-18T14:32:00.123456789Z",
  "correlation_id": "corr-abc-123",
  "causation_id": "evt-parent-001",
  "trace_id": "trace-xyz-456",
  "payload": {},
  "provenance": {},
  "metadata": {}
}
```

### Field Reference

| Field             | Type                | Required | Description                                                                                                 |
| ----------------- | ------------------- | -------- | ----------------------------------------------------------------------------------------------------------- |
| `schema_version`  | `string`            | Yes      | Version of the envelope schema. Must be `"v1"`. Gates which validation logic the bridge applies.            |
| `event_id`        | `string (UUID v4)`  | Yes      | Globally unique identifier for this event. Used as the canonical event identifier in all downstream tables. |
| `idempotency_key` | `string`            | No       | Deduplication key. Defaults to `event_id` when absent. See Section 6.                                       |
| `source`          | `string (enum)`     | Yes      | Originating system. One of: `zeroclaw`, `sea-forge`, `home-assistant`, `other`.                             |
| `source_agent`    | `string`            | Yes      | Specific agent or component within the source system. Free-form. Example: `zeroclaw/refactor-agent`.        |
| `occurred_at`     | `string (RFC 3339)` | Yes      | Timestamp when the event occurred in the source system. Nanosecond precision preferred. Must be UTC.        |
| `correlation_id`  | `string`            | No       | Groups related events across different subjects. See Section 7.                                             |
| `causation_id`    | `string`            | No       | Direct parent event ID. Answers "what caused this event to exist." See Section 7.                           |
| `trace_id`        | `string`            | No       | Distributed trace identifier spanning the full causal chain. See Section 7.                                 |
| `payload`         | `object`            | Yes      | Subject-specific event data. Structure depends on the event type. Must not be null.                         |
| `provenance`      | `object`            | No       | Provenance metadata. May include `lineage`, `policy_version`, `identity_ref`, or other traceability data.   |
| `metadata`        | `object`            | No       | Arbitrary metadata for observability, debugging, or operational annotations. Not used for governance logic. |

---

## 3. Subject Taxonomy

| Subject Pattern             | Schema File                       | Canonical Table                     | Fail Behavior |
| --------------------------- | --------------------------------- | ----------------------------------- | ------------- |
| `sea.agent.event.>`         | `sea.agent.event.v1.json`         | `event_log.agent_events`            | fail-open     |
| `sea.governance.request.>`  | `sea.governance.request.v1.json`  | `governance.action_requests`        | fail-closed   |
| `sea.governance.decision.>` | `sea.governance.decision.v1.json` | `governance.action_decisions`       | fail-closed   |
| `sea.memory.write.>`        | `sea.memory.write.v1.json`        | `memory.items` (status=`candidate`) | fail-closed   |
| `sea.memory.lifecycle.>`    | `sea.memory.lifecycle.v1.json`    | `event_log.inbox_events`            | fail-closed   |

The `>` wildcard in subject patterns indicates that one or more trailing tokens are permitted. Producers typically append an agent identifier or request identifier. Example: `sea.agent.event.zeroclaw.refactor-agent`.

---

## 4. Event Type Details

### 4.1 Agent Event

| Property        | Value                    |
| --------------- | ------------------------ |
| Subject pattern | `sea.agent.event.>`      |
| Fail behavior   | fail-open                |
| Canonical table | `event_log.agent_events` |

**Required envelope fields:** All common envelope fields.

**Required payload fields:**

| Field            | Type     | Description                                                                                   |
| ---------------- | -------- | --------------------------------------------------------------------------------------------- |
| `event_type`     | `string` | Category of agent activity. Example: `tool_invocation`, `file_mutation`, `command_execution`. |
| `description`    | `string` | Human-readable summary of what occurred.                                                      |
| `agent_identity` | `string` | Identity reference for the agent that performed the action.                                   |

**Optional payload fields:**

| Field            | Type            | Description                                     |
| ---------------- | --------------- | ----------------------------------------------- |
| `tool_name`      | `string`        | Name of the tool invoked, if applicable.        |
| `parameters`     | `object`        | Input parameters to the tool or action.         |
| `result_summary` | `string`        | Brief description of the outcome.               |
| `file_paths`     | `array[string]` | Files affected by the action.                   |
| `exit_code`      | `integer`       | Exit or return code if the action produced one. |
| `duration_ms`    | `integer`       | Duration of the action in milliseconds.         |
| `tags`           | `array[string]` | Free-form tags for categorization.              |

**Example:**

```json
{
  "schema_version": "v1",
  "event_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "idempotency_key": "tool-invoke-001",
  "source": "zeroclaw",
  "source_agent": "zeroclaw/refactor-agent",
  "occurred_at": "2026-05-18T14:32:00.123456789Z",
  "correlation_id": "session-abc-123",
  "causation_id": null,
  "trace_id": "trace-xyz-456",
  "payload": {
    "event_type": "tool_invocation",
    "description": "Invoked file_write tool to update configuration module",
    "agent_identity": "zeroclaw/refactor-agent@v2.1",
    "tool_name": "file_write",
    "parameters": {
      "path": "/etc/agent/config.yaml",
      "content_sha256": "e3b0c44298fc1c149afbf4c8996fb924"
    },
    "result_summary": "Configuration updated successfully",
    "file_paths": ["/etc/agent/config.yaml"],
    "duration_ms": 142,
    "tags": ["config", "mutation"]
  },
  "provenance": {
    "lineage": ["session-abc-123"],
    "policy_version": "v1"
  },
  "metadata": {
    "environment": "production",
    "hostname": "ha-addon-01"
  }
}
```

---

### 4.2 Governance Request

| Property        | Value                        |
| --------------- | ---------------------------- |
| Subject pattern | `sea.governance.request.>`   |
| Fail behavior   | fail-closed                  |
| Canonical table | `governance.action_requests` |

**Required envelope fields:** All common envelope fields.

**Required payload fields:**

- `requesting_identity_id` (`string`): UUID of the identity requesting the action. Must reference an existing governance identity.
- `requested_action_type` (`string`, enum): Type of governed action being requested. One of: `tool_call`, `memory_write`, `file_write`, `network_request`, `email_send`, `command_execute`, `policy_override_request`.

**Optional payload fields:**

- `requested_resource` (`string`): Resource identifier the action targets. A file path, URL, tool name, or similar.
- `payload` (`object`): Action-specific parameters for the requested action.
- `provenance` (`object`): Request-level provenance metadata such as origin and causal chain.
- `metadata` (`object`): Additional request metadata.

**Example:**

```json
{
  "schema_version": "v1",
  "event_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "idempotency_key": "gov-req-20260518-001",
  "source": "sea-forge",
  "source_agent": "sea-forge/planner",
  "occurred_at": "2026-05-18T14:35:00.000000000Z",
  "correlation_id": "session-abc-123",
  "causation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "trace_id": "trace-xyz-456",
  "payload": {
    "requesting_identity_id": "33333333-3333-3333-3333-333333333333",
    "requested_action_type": "file_write",
    "requested_resource": "/etc/agent/config.yaml",
    "payload": {
      "path": "/etc/agent/config.yaml",
      "content_sha256": "e3b0c44298fc1c149afbf4c8996fb924",
      "size_bytes": 2048
    },
    "provenance": {
      "origin": "session-abc-123",
      "chain": ["session-abc-123", "plan-0042"]
    },
    "metadata": {
      "risk_level": "medium",
      "justification": "Approved configuration change from session-abc-123 planning phase",
      "dry_run": false
    }
  },
  "provenance": {
    "lineage": ["session-abc-123"],
    "policy_version": "v1"
  },
  "metadata": {}
}
```

---

### 4.3 Governance Decision

| Property        | Value                         |
| --------------- | ----------------------------- |
| Subject pattern | `sea.governance.decision.>`   |
| Fail behavior   | fail-closed                   |
| Canonical table | `governance.action_decisions` |

**Required envelope fields:** All common envelope fields.

**Required payload fields:**

| Field              | Type            | Description                                                                                           |
| ------------------ | --------------- | ----------------------------------------------------------------------------------------------------- |
| `request_event_id` | `string`        | The `event_id` of the governance request this decision resolves.                                      |
| `decision`         | `string (enum)` | Admission decision. One of: `accepted`, `rejected`, `deferred`.                                       |
| `decider_identity` | `string`        | Identity reference of the governance component that made the decision.                                |
| `reason`           | `string`        | Machine-readable reason code. Example: `policy_match`, `policy_violation`, `risk_threshold_exceeded`. |
| `policy_version`   | `string`        | Version of the policy that governed this decision.                                                    |

**Optional payload fields:**

| Field                   | Type                | Description                                                                             |
| ----------------------- | ------------------- | --------------------------------------------------------------------------------------- |
| `human_readable_reason` | `string`            | Human-facing explanation of the decision.                                               |
| `conditions`            | `array[object]`     | Conditions attached to an `accepted` decision. Each object has `type` and `value` keys. |
| `expires_at`            | `string (RFC 3339)` | When this decision expires. Null means no expiration.                                   |
| `related_decisions`     | `array[string]`     | Event IDs of related prior decisions that influenced this one.                          |

**Example:**

```json
{
  "schema_version": "v1",
  "event_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  "idempotency_key": "gov-dec-20260518-001",
  "source": "zeroclaw",
  "source_agent": "zeroclaw/governance-engine",
  "occurred_at": "2026-05-18T14:35:01.500000000Z",
  "correlation_id": "session-abc-123",
  "causation_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "trace_id": "trace-xyz-456",
  "payload": {
    "request_event_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "decision": "accepted",
    "decider_identity": "zeroclaw/governance-engine@v1.0",
    "reason": "policy_match",
    "policy_version": "v1",
    "human_readable_reason": "Action matches allowed file_mutation policy for requester identity under current governance context",
    "conditions": [
      {
        "type": "max_file_size",
        "value": "4096"
      }
    ],
    "expires_at": null,
    "related_decisions": []
  },
  "provenance": {
    "policy_version": "v1"
  },
  "metadata": {}
}
```

---

### 4.4 Memory Write

| Property        | Value                               |
| --------------- | ----------------------------------- |
| Subject pattern | `sea.memory.write.>`                |
| Fail behavior   | fail-closed                         |
| Canonical table | `memory.items` (status=`candidate`) |

**Required envelope fields:** All common envelope fields.

**Required payload fields:**

| Field             | Type     | Description                                                                               |
| ----------------- | -------- | ----------------------------------------------------------------------------------------- |
| `memory_type`     | `string` | Category of memory. Example: `observation`, `fact`, `procedure`, `preference`, `context`. |
| `content`         | `string` | The memory content. Text, structured text, or a JSON-serializable string.                 |
| `source_identity` | `string` | Identity reference of the agent or system that produced this memory.                      |
| `scope`           | `string` | Visibility scope. One of: `private`, `shared`, `global`.                                  |

**Optional payload fields:**

| Field                | Type                | Description                                                       |
| -------------------- | ------------------- | ----------------------------------------------------------------- |
| `summary`            | `string`            | Short summary of the content for quick retrieval.                 |
| `tags`               | `array[string]`     | Free-form tags for categorization and filtering.                  |
| `confidence`         | `number (0.0–1.0)`  | Confidence score for the memory's accuracy or relevance.          |
| `valid_from`         | `string (RFC 3339)` | When this memory becomes valid. Defaults to `occurred_at`.        |
| `valid_until`        | `string (RFC 3339)` | When this memory expires. Null means no expiration.               |
| `related_memory_ids` | `array[string]`     | IDs of related memories already in the system.                    |
| `embedding_hint`     | `string`            | Hint text for embedding generation. If absent, `content` is used. |

**Example:**

```json
{
  "schema_version": "v1",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "idempotency_key": "mem-write-20260518-001",
  "source": "sea-forge",
  "source_agent": "sea-forge/session-summarizer",
  "occurred_at": "2026-05-18T15:00:00.000000000Z",
  "correlation_id": "session-abc-123",
  "causation_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  "trace_id": "trace-xyz-456",
  "payload": {
    "memory_type": "observation",
    "content": "During session-abc-123, the refactor agent successfully updated /etc/agent/config.yaml with new timeout settings. Governance admitted the change under policy v1 with a max file size condition of 4096 bytes.",
    "source_identity": "sea-forge/session-summarizer@v1.0",
    "scope": "shared",
    "summary": "Config file updated with new timeout settings in session-abc-123",
    "tags": ["config", "mutation", "session-abc-123"],
    "confidence": 0.92,
    "valid_from": "2026-05-18T15:00:00.000000000Z",
    "valid_until": null,
    "related_memory_ids": [],
    "embedding_hint": "configuration update timeout settings agent refactor session"
  },
  "provenance": {
    "lineage": ["session-abc-123"],
    "policy_version": "v1"
  },
  "metadata": {
    "session_id": "session-abc-123"
  }
}
```

Memory writes always enter the system with status `candidate`. Promotion to `accepted`, `verified`, or higher statuses occurs through the memory lifecycle, not through the write event itself.

---

### 4.5 Memory Lifecycle

| Property        | Value                    |
| --------------- | ------------------------ |
| Subject pattern | `sea.memory.lifecycle.>` |
| Fail behavior   | fail-closed              |
| Canonical table | `event_log.inbox_events` |

**Required envelope fields:** All common envelope fields.

**Required payload fields:**

| Field              | Type            | Description                                                                                                                                   |
| ------------------ | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `memory_item_id`   | `string`        | The ID of the memory item this lifecycle event applies to. Must reference an existing memory item.                                            |
| `new_status`       | `string (enum)` | Target lifecycle status. One of: `observed`, `candidate`, `accepted`, `verified`, `superseded`, `rejected`, `expired`.                        |
| `changed_by`       | `string`        | Identity reference of the agent or system performing the transition.                                                                          |
| `reason`           | `string`        | Machine-readable reason code for the transition. Example: `governance_approved`, `verification_passed`, `superseded_by_newer`, `ttl_expired`. |

**Optional payload fields:**

| Field                   | Type            | Description                                                                                                                |
| ----------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `human_readable_reason` | `string`        | Human-facing explanation of the transition.                                                                                |
| `superseding_memory_id` | `string`        | For `superseded` transitions, the ID of the memory that replaces this one.                                                 |
| `verification_method`   | `string`        | For `verified` transitions, how verification was performed. Example: `cross_reference`, `human_review`, `automated_check`. |
| `policy_version`        | `string`        | Policy version governing this transition.                                                                                  |
| `evidence`              | `array[object]` | Supporting evidence for the transition. Each object has `type`, `source`, and `value` keys.                                |

**Example:**

```json
{
  "schema_version": "v1",
  "event_id": "9c858901-8a57-4791-8144-56c7890d1234",
  "idempotency_key": "mem-lifecycle-20260518-001",
  "source": "zeroclaw",
  "source_agent": "zeroclaw/memory-governor",
  "occurred_at": "2026-05-18T15:05:00.000000000Z",
  "correlation_id": "session-abc-123",
  "causation_id": "550e8400-e29b-41d4-a716-446655440000",
  "trace_id": "trace-xyz-456",
  "payload": {
    "memory_item_id": "550e8400-e29b-41d4-a716-446655440000",
    "new_status": "accepted",
    "changed_by": "zeroclaw/memory-governor@v1.0",
    "reason": "governance_approved",
    "human_readable_reason": "Memory passed governance review: content is consistent with observed events and policy v1",
    "policy_version": "v1",
    "evidence": [
      {
        "type": "governance_decision",
        "source": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
        "value": "accepted"
      }
    ]
  },
  "provenance": {
    "policy_version": "v1"
  },
  "metadata": {}
}
```

---

## 5. Fail-Closed Semantics

### Fail-Closed Event Types

Governance requests, governance decisions, memory writes, and memory lifecycle events are fail-closed. If any required field is missing, malformed, or fails validation, the event is rejected. The bridge does not coerce, default, or silently repair malformed data.

### Fail-Open Event Types

Agent events are fail-open. Missing optional fields produce validation warnings but do not prevent ingestion. Required fields on agent events are still enforced. The distinction is deliberate: agent events are observational telemetry where best-effort capture is preferable to data loss. Governance and memory events are state-mutating actions where incorrect data is worse than missing data.

### Rejection Flow

When an event fails validation:

1. The inbox record status is set to `failed`.
2. The `delivery_attempts` row records `error_message` with the validation failure details.
3. The event is moved to the dead letter storage.
4. The bridge sends a NATS ACK to the broker. The message is not redelivered.

This prevents redelivery loops. A rejected event is definitively rejected. Producers must correct and republish with a new `event_id`.

### No Silent Coercion

The bridge must never:

- Default missing required fields to empty values.
- Coerce types (e.g., convert `"123"` to `123`).
- Strip unknown fields to force conformance.
- Modify event content to pass validation.

If the event does not match the schema exactly as published, it is rejected.

---

## 6. Idempotency

### Deduplication Key Resolution

The bridge resolves the deduplication key (used as `message_id` in the inbox) in the following priority order:

| Priority | Source                          | Description                               |
| -------- | ------------------------------- | ----------------------------------------- |
| 1        | `idempotency_key` from envelope | Explicit producer-supplied key.           |
| 2        | `event_id` from envelope        | Falls back to the event UUID.             |
| 3        | `Nats-Msg-Id` NATS header       | Falls back to the NATS message ID header. |
| 4        | SHA-256 hash of message body    | Last resort deterministic hash.           |

### Deduplication Mechanism

The inbox table enforces a unique constraint on `(source_queue, message_id)`. The insert uses `ON CONFLICT DO NOTHING`:

```sql
INSERT INTO event_log.inbox_events (source_queue, message_id, ...)
VALUES ($1, $2, ...)
ON CONFLICT (source_queue, message_id) DO NOTHING
```

When a duplicate is detected:

- The insert is silently skipped.
- The bridge ACKs the message to NATS.
- No reprocessing occurs.
- No error is recorded.

Producers that need to retry a failed submission must use a new `event_id` and, optionally, a new `idempotency_key`. Reusing the same key after a failure will cause the retry to be silently deduplicated.

---

## 7. Causal Tracing

Three fields in the envelope provide causal tracing across events, subjects, and distributed systems.

### correlation_id

Groups all events that belong to the same logical operation or session, regardless of which subject they are published to. A single user request may produce a governance request, a governance decision, a memory write, and a memory lifecycle event. All four share the same `correlation_id`.

Example: A planning session with ID `session-abc-123` produces events across four subjects. All carry `"correlation_id": "session-abc-123"`.

### causation_id

Identifies the direct parent event — the specific event that caused this event to exist. This forms a directed acyclic graph of causality.

Example: A governance decision carries `"causation_id": "<request-event-id>"`, pointing to the governance request it resolves.

### trace_id

A distributed tracing identifier that propagates through the full chain of events, including across service boundaries. This is compatible with OpenTelemetry and W3C Trace Context propagation.

Example: A trace that starts in Home Assistant, flows through ZeroClaw governance, and ends in memory promotion carries the same `trace_id` across all events.

### Relationship Summary

| Field            | Cardinality | Scope             | Answers                                     |
| ---------------- | ----------- | ----------------- | ------------------------------------------- |
| `correlation_id` | One-to-many | Logical operation | "What group does this belong to?"           |
| `causation_id`   | One-to-one  | Direct parent     | "What caused this specific event?"          |
| `trace_id`       | One-to-many | Distributed trace | "What end-to-end flow does this belong to?" |

---

## 8. Schema Evolution

### Version Gating

The `schema_version` field in the envelope determines which validation logic the bridge applies. When the bridge encounters `"schema_version": "v1"`, it loads the `v1` JSON Schema definitions for the given subject.

### Evolution Rules

| Rule                                      | Rationale                                                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| New schema versions are additive          | `v2` must accept all valid `v1` payloads. New fields are optional.                                                       |
| Unknown versions are rejected             | If the bridge does not recognize the `schema_version`, the event is rejected (fail-closed for all types).                |
| Existing fields must not change meaning   | A field documented as `string` in `v1` cannot become `integer` in `v2`. Rename or add new fields instead.                |
| `additionalProperties: false` on envelope | Unknown top-level envelope fields cause rejection. This prevents producers from silently extending the envelope.         |
| `additionalProperties: true` on payload   | Payload objects tolerate additional fields. This allows producers to attach domain-specific data without schema changes. |

### Adding a New Version

To introduce `v2`:

1. Create new schema files: `sea.*.v2.json`.
2. Register the new version in the bridge's version registry.
3. Ensure all `v1` valid payloads remain valid under `v2`.
4. Document new fields and their defaults.
5. Update this contract document with `v2` details.

---

## 9. Machine-Readable Schemas

JSON Schema files are located at:

```
agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts/
```

| File                              | `$id` URI                                                   | Event Type          |
| --------------------------------- | ----------------------------------------------------------- | ------------------- |
| `sea.agent.event.v1.json`         | `https://sea.local/schemas/sea.agent.event.v1.json`         | Agent Event         |
| `sea.governance.request.v1.json`  | `https://sea.local/schemas/sea.governance.request.v1.json`  | Governance Request  |
| `sea.governance.decision.v1.json` | `https://sea.local/schemas/sea.governance.decision.v1.json` | Governance Decision |
| `sea.memory.write.v1.json`        | `https://sea.local/schemas/sea.memory.write.v1.json`        | Memory Write        |
| `sea.memory.lifecycle.v1.json`    | `https://sea.local/schemas/sea.memory.lifecycle.v1.json`    | Memory Lifecycle    |

Each schema file defines both the envelope constraints and the subject-specific payload constraints. The `$schema` field in each file points to JSON Schema Draft 2020-12.

---

## 10. Validation in the Bridge

The bridge worker validates every inbound message in two stages.

### Stage 1: Envelope Validation

The bridge validates the common envelope fields against the shared envelope schema. This checks:

- `schema_version` is present and recognized.
- `event_id` is present and is a valid UUID v4.
- `source` is present and is one of the allowed enum values.
- `source_agent` is present and is a non-empty string.
- `occurred_at` is present and is a valid RFC 3339 timestamp.
- `payload` is present and is an object.
- No unknown top-level fields exist (`additionalProperties: false`).

### Stage 2: Subject-Specific Payload Validation

If envelope validation passes, the bridge loads the schema corresponding to the subject and `schema_version`, then validates `payload` against it. This checks:

- All required payload fields are present.
- Field types match the schema.
- Enum values are within the allowed set.
- Numeric ranges are respected.

### Error Storage

When validation fails:

- The error message is recorded in `event_log.delivery_attempts.error_message` as a structured string containing the validation stage and the specific JSON Schema validation errors.
- The error is also recorded in `event_log.inbox_events.headers` under the key `_validation_errors` as a JSON array of error objects.
- The inbox record status is set to `failed`.

### ACK Behavior

Invalid events are ACKed (not NACKed) to NATS. This is intentional. NACKing would cause the broker to redeliver the same invalid message indefinitely, creating a redelivery loop. ACKing acknowledges receipt while recording the failure in the durable inbox. Producers are responsible for monitoring dead letter records and correcting their output.

---

## 11. Version History

| Version | Date       | Description                                                                                                                           |
| ------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| v1      | 2026-05-18 | Initial contract. Defines envelope, five event types, fail-closed semantics, idempotency, causal tracing, and schema evolution rules. |
