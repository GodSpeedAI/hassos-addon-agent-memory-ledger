"""DLQ observability (LE-01): rejected messages must be inspectable and
replayable, not just theoretically present.

The NATS dead-letter subject (sea.ledger.deadletter) is not part of any
JetStream stream's subject list, so it is not durably persisted there —
Postgres (event_log.inbox_events / delivery_attempts) is the durable record
of what was rejected and why. fetch_dead_letters() is the minimal inspection
surface: no new NATS consumer needed, no new table, just a query.
"""

import json
import uuid

import pytest

from tests.test_bridge import _make_bridge, _make_nats_msg


class TestDlqPublishCapturesReason:
    """A rejected message reaches sea.ledger.deadletter with reason + payload intact."""

    @pytest.mark.asyncio
    async def test_dlq_publish_preserves_original_payload_and_reason(self, bridge_module):
        bad_envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {},  # missing required "content" for sea.memory.write
        }
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.memory.write.fact",
            json.dumps(bad_envelope).encode(),
            {"Nats-Msg-Id": "dlq-001"},
        )

        await bridge._process_inbound(msg)

        js.publish.assert_awaited()
        dlq_call = js.publish.await_args_list[-1]
        assert dlq_call.kwargs["subject"] == "sea.ledger.deadletter"

        dlq_envelope = json.loads(dlq_call.kwargs["payload"])
        assert dlq_envelope["original_subject"] == "sea.memory.write.fact"
        assert "content" in dlq_envelope["reason"]
        assert json.loads(dlq_envelope["original_payload"]) == bad_envelope

    @pytest.mark.asyncio
    async def test_dlq_reason_is_recorded_in_delivery_attempts(self, bridge_module):
        """The rejection reason is also durable in Postgres, independent of NATS."""
        bad_envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {},
        }
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.memory.write.fact",
            json.dumps(bad_envelope).encode(),
            {"Nats-Msg-Id": "dlq-002"},
        )

        await bridge._process_inbound(msg)

        failed_delivery = [
            c.args
            for c in cur.execute.call_args_list
            if "INSERT INTO event_log.delivery_attempts" in c.args[0] and "'failed'" in c.args[0]
        ]
        assert failed_delivery, "expected a failed delivery_attempts row recording the rejection"
        error_message = failed_delivery[0][1][-1]
        assert "content" in error_message


class TestDlqInspection:
    """fetch_dead_letters() is the replay/inspection surface for operators."""

    @pytest.mark.asyncio
    async def test_dlq_inspection_queries_failed_and_dead_letter_rows(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        inbox_id = uuid.uuid4()
        cur.fetchall = None  # replaced per-call below
        from unittest.mock import AsyncMock

        cur.fetchall = AsyncMock(
            return_value=[
                (
                    inbox_id,
                    "sea.memory.write.fact",
                    "dlq-002",
                    {"payload": {}},
                    "failed",
                    "2025-01-15T10:30:00Z",
                    "Missing required payload fields: ['content']",
                )
            ]
        )

        results = await bridge.fetch_dead_letters(cur, limit=50)

        sql = cur.execute.call_args.args[0]
        assert "event_log.inbox_events" in sql
        assert "'failed', 'dead_letter'" in sql
        assert cur.execute.call_args.args[1] == [50]

        assert len(results) == 1
        assert results[0]["message_id"] == "dlq-002"
        assert results[0]["error_message"] == "Missing required payload fields: ['content']"
        assert results[0]["status"] == "failed"

    @pytest.mark.asyncio
    async def test_dlq_inspection_empty_when_nothing_rejected(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        results = await bridge.fetch_dead_letters(cur)
        assert results == []
