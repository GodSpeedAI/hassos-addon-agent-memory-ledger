"""End-to-end ingest conformance for the v1 event envelope (WP-1).

Covers:
  - A conformant sea.agent.event.v1 instance validates against the actual
    JSON Schema contract file (additionalProperties: false enforced there)
    and round-trips through the bridge to event_log.agent_events with zero
    DLQ activity.
  - A family-A-shaped event (no schema_version, the exact non-conformant
    shape the cross-repo audit found live in production) is rejected and
    dead-lettered on a fail-closed subject family.
"""

import json
import os
import uuid

import jsonschema
import pytest

from tests.test_bridge import _make_bridge, _make_nats_msg

_CONTRACTS_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "agent_memory_ledger",
    "rootfs",
    "usr",
    "share",
    "agent_memory_ledger",
    "contracts",
)


def _load_schema(name: str) -> dict:
    with open(os.path.join(_CONTRACTS_DIR, name)) as f:
        return json.load(f)


@pytest.fixture
def agent_event_schema():
    return _load_schema("sea.agent.event.v1.json")


@pytest.fixture
def conformant_agent_event():
    return {
        "schema_version": "v1",
        "event_id": str(uuid.uuid4()),
        "source_agent": "godspeed_agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "payload": {"event_type": "tool_call.completed", "detail": "ok"},
        "provenance": {"origin": "godspeed_agent", "chain": []},
    }


class TestAgentEventV1SchemaConformance:
    """The contract JSON Schema is the source of truth for wire shape."""

    def test_conformant_fixture_validates(self, agent_event_schema, conformant_agent_event):
        jsonschema.validate(conformant_agent_event, agent_event_schema)

    def test_stray_top_level_key_violates_additional_properties(
        self, agent_event_schema, conformant_agent_event
    ):
        """additionalProperties: false must have teeth at the schema level.

        The bridge's hand-rolled validate_envelope() is fail-open for agent
        events and does not itself check for unknown top-level keys — see
        sea_nats_bridge.py's comment on why jsonschema isn't a runtime dep.
        The JSON Schema file is still the enforced contract; this proves it.
        """
        mutated = dict(conformant_agent_event, unexpected_top_level_field="boom")
        with pytest.raises(jsonschema.ValidationError, match="Additional properties"):
            jsonschema.validate(mutated, agent_event_schema)


class TestAgentEventV1IngestRoundTrip:
    """Bridge-level ingest proof: conformant event -> Postgres, zero DLQ."""

    @pytest.mark.asyncio
    async def test_conformant_event_round_trips_with_zero_dlq(
        self, bridge_module, conformant_agent_event
    ):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.agent.event.tool_call",
            json.dumps(conformant_agent_event).encode(),
            {"Nats-Msg-Id": "conformant-001"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()
        db.rollback.assert_not_awaited()

        executed = [c.args[0] for c in cur.execute.call_args_list]
        assert any("INSERT INTO event_log.agent_events" in sql for sql in executed), (
            "conformant event did not land in the canonical agent_events table"
        )
        assert any("INSERT INTO event_log.inbox_events" in sql for sql in executed)
        delivered = any(
            "INSERT INTO event_log.delivery_attempts" in sql and "'delivered'" in sql
            for sql in executed
        )
        assert delivered, "expected a 'delivered' delivery_attempts row, not a failure"

        # Zero DLQ: no NATS publish of any kind occurs on the happy path.
        js.publish.assert_not_awaited()
        nc.publish.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_mutated_fixture_fails_schema_even_though_bridge_is_fail_open(
        self, agent_event_schema, conformant_agent_event
    ):
        """Guards against the round-trip test degrading into a happy-path stub.

        additionalProperties: false must reject a stray key at the schema
        layer, independent of the bridge's fail-open runtime behavior for
        agent events.
        """
        mutated = dict(conformant_agent_event, extra="not allowed")
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(mutated, agent_event_schema)


class TestFamilyAShapeRejectedAndDeadLettered:
    """Negative companion: the exact non-conformant shape found live in
    production (no schema_version) must be rejected and DLQ'd on a
    fail-closed subject family — proving the gate has teeth."""

    @pytest.mark.asyncio
    async def test_family_a_event_is_dead_lettered(self, bridge_module):
        family_a_event = {
            "event_id": str(uuid.uuid4()),
            "event_type": "governance.request",
            "namespace": "sea-forge",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {
                "requesting_identity_id": str(uuid.uuid4()),
                "requested_action_type": "tool_call",
            },
        }
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.governance.request.tool_call",
            json.dumps(family_a_event).encode(),
            {"Nats-Msg-Id": "family-a-001"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()

        executed = [c.args for c in cur.execute.call_args_list]
        failed_inbox_update = any(
            "status = 'failed'" in args[0] and "event_log.inbox_events" in args[0]
            for args in executed
        )
        assert failed_inbox_update, "rejected family-A event must mark inbox status 'failed'"

        failed_delivery = [
            args
            for args in executed
            if "INSERT INTO event_log.delivery_attempts" in args[0] and "'failed'" in args[0]
        ]
        assert failed_delivery, "expected a 'failed' delivery_attempts row"
        error_message = failed_delivery[0][1][-1]
        assert "schema_version" in error_message, (
            "rejection reason must name the missing field, not just 'invalid'"
        )

        # Dead-lettered to NATS with the original payload intact.
        js.publish.assert_awaited()
        dlq_call = js.publish.await_args_list[-1]
        assert dlq_call.kwargs["subject"] == bridge.cfg.dead_letter_subject
        dlq_envelope = json.loads(dlq_call.kwargs["payload"])
        assert json.loads(dlq_envelope["original_payload"]) == family_a_event

        # Must NOT have landed in the canonical governance table.
        assert not any(
            "INSERT INTO governance.action_requests" in args[0] for args in executed
        )
