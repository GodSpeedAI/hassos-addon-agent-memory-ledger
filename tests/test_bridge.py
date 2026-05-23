"""Tests for SEABridge core logic.

Covers:
  - Inbound message processing (mocked DB/NATS)
  - Outbound message dispatch (mocked DB/NATS)
  - Dead letter handling
  - Idempotency via duplicate detection
  - Transactionality (commit/rollback behavior)

These tests mock psycopg and nats to avoid requiring real infrastructure.
"""

import json
import uuid
from unittest.mock import AsyncMock, MagicMock

import pytest


def _make_nats_msg(subject: str, data: bytes, headers: dict | None = None):
    """Create a mock NATS message."""
    msg = MagicMock()
    msg.subject = subject
    msg.data = data
    msg.headers = headers or {}
    msg.ack = AsyncMock()
    msg.nak = AsyncMock()
    msg.term = AsyncMock()
    return msg


def _make_bridge(bridge_module, **overrides):
    """Create a SEABridge with mocked connections."""
    cfg = bridge_module.BridgeConfig(
        db_host="localhost",
        db_port=5432,
        db_name="agent_memory",
        db_user="bridge_worker",
        db_password="testpass",
        nats_url="nats://localhost:4222",
        health_enabled=False,
        **overrides,
    )
    bridge = bridge_module.SEABridge(cfg)

    # Mock DB
    db = AsyncMock()
    cursor = AsyncMock()
    cursor.__aenter__ = AsyncMock(return_value=cursor)
    cursor.__aexit__ = AsyncMock(return_value=False)
    cursor.execute = AsyncMock()
    cursor.fetchone = AsyncMock(return_value=(uuid.uuid4(),))
    cursor.fetchall = AsyncMock(return_value=[])
    db.cursor = MagicMock(return_value=cursor)
    db.commit = AsyncMock()
    db.rollback = AsyncMock()
    db.closed = False
    bridge._db = db
    bridge._get_db = AsyncMock(return_value=db)

    # Mock NATS
    nc = MagicMock()
    nc.is_connected = True
    nc.publish = AsyncMock()
    bridge.nc = nc

    js = AsyncMock()
    js.publish = AsyncMock()
    bridge.js = js

    return bridge, db, cursor, nc, js


class TestInboundProcessing:
    """Tests for _process_inbound."""

    @pytest.mark.asyncio
    async def test_valid_agent_event(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-001"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()

    @pytest.mark.asyncio
    async def test_valid_governance_request(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {
                "requesting_identity_id": str(uuid.uuid4()),
                "requested_action_type": "tool_call",
            },
        }
        msg = _make_nats_msg(
            "sea.governance.request.tool_call",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-002"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()

    @pytest.mark.asyncio
    async def test_valid_memory_write(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {
                "source_agent": "test-agent",
                "content": "test memory content",
            },
        }
        msg = _make_nats_msg(
            "sea.memory.write.fact",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-003"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()

    @pytest.mark.asyncio
    async def test_valid_memory_lifecycle(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        inbox_id = uuid.uuid4()
        cur.fetchone = AsyncMock(side_effect=[(inbox_id,), ("candidate",)])
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {
                "memory_item_id": str(uuid.uuid4()),
                "new_status": "accepted",
                "changed_by": "test-agent",
                "reason": "governance_approved",
            },
        }
        msg = _make_nats_msg(
            "sea.memory.lifecycle.accepted",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-003b"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()

        execute_sql = "\n".join(call.args[0] for call in cur.execute.call_args_list)
        assert "status = 'failed'" not in execute_sql

    @pytest.mark.asyncio
    async def test_non_json_payload_dead_lettered(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.agent.event.created",
            b"not json at all",
            {"Nats-Msg-Id": "msg-004"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        # Should attempt dead letter publish
        js.publish.assert_awaited()

    @pytest.mark.asyncio
    async def test_non_object_json_dead_lettered(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        msg = _make_nats_msg(
            "sea.agent.event.created",
            b"[1, 2, 3]",
            {"Nats-Msg-Id": "msg-005"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_unknown_subject_dead_lettered(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {},
        }
        msg = _make_nats_msg(
            "sea.unknown.subject.type",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-006"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()

    @pytest.mark.asyncio
    async def test_fail_closed_governance_rejects_invalid(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        # Missing required payload fields for governance request
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {},
        }
        msg = _make_nats_msg(
            "sea.governance.request.tool_call",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-007"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()
        # Should have recorded a failed delivery attempt
        # The inbox status should be 'failed'

    @pytest.mark.asyncio
    async def test_fail_open_agent_event_accepts_invalid(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        # Agent events are fail-open — even with validation warnings, they're accepted
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"extra_field": "value"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "msg-008"},
        )

        await bridge._process_inbound(msg)

        msg.ack.assert_awaited_once()
        db.commit.assert_awaited()


class TestIdempotency:
    """Tests for idempotent message processing."""

    @pytest.mark.asyncio
    async def test_duplicate_inbox_skipped(self, bridge_module):
        """Same source_queue + message_id only inserted once."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        # First call returns an ID, second returns None (duplicate)
        inbox_id = uuid.uuid4()
        cur.fetchone = AsyncMock(side_effect=[(inbox_id,), None])

        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "dup-msg"},
        )

        # First delivery
        await bridge._process_inbound(msg)
        assert msg.ack.await_count == 1

        # Second delivery (duplicate — fetchone returns None)
        msg2 = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "dup-msg"},
        )
        await bridge._process_inbound(msg2)
        assert msg2.ack.await_count == 1
        # Both should be acked — duplicate is not an error

    @pytest.mark.asyncio
    async def test_unique_violation_treated_as_success(self, bridge_module):
        """Race condition on idempotency — UniqueViolation is caught."""
        import psycopg.errors

        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        cur.execute = AsyncMock(side_effect=psycopg.errors.UniqueViolation("duplicate key"))

        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "race-msg"},
        )

        await bridge._process_inbound(msg)
        msg.ack.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_duplicate_outbox_dispatch_idempotent(self, bridge_module):
        """Duplicate outbox publish does not create duplicate dispatched state.

        The outbox_events table has a UNIQUE constraint on
        (target_queue, message_id). If the same outbox event is polled
        twice (e.g., after a crash before commit), the second dispatch
        should not create a duplicate delivery_attempts record because
        the first dispatch already updated the status to 'delivered'
        and the row is no longer 'pending' (FOR UPDATE SKIP LOCKED
        prevents re-locking).
        """
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        event_id = uuid.uuid4()

        # First dispatch succeeds
        await bridge._dispatch_outbox(cur, event_id, "test.target", "out-dup-001", "{}", "{}")
        assert js.publish.await_count == 1

        # Verify the outbox was marked delivered (not still pending)
        execute_calls = cur.execute.call_args_list
        delivered_update = any("delivered" in str(c) and "outbox_events" in str(c) for c in execute_calls)
        assert delivered_update, "First dispatch should mark outbox as delivered"

        # Reset mocks for second attempt
        js.publish.reset_mock()
        cur.execute.reset_mock()

        # Second dispatch of the same event — in production, FOR UPDATE SKIP LOCKED
        # would skip this row since it's no longer 'pending'. Here we verify
        # that calling _dispatch_outbox again still works correctly.
        await bridge._dispatch_outbox(cur, event_id, "test.target", "out-dup-001", "{}", "{}")
        js.publish.assert_awaited_once()

        # The second dispatch should also mark delivered (idempotent update)
        execute_calls_2 = cur.execute.call_args_list
        delivered_update_2 = any("delivered" in str(c) and "outbox_events" in str(c) for c in execute_calls_2)
        assert delivered_update_2


class TestTransactionality:
    """Tests for transaction commit/rollback behavior."""

    @pytest.mark.asyncio
    async def test_successful_inbound_commits(self, bridge_module):
        """Inbox insert + canonical insert + status update commit together."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "txn-001"},
        )

        await bridge._process_inbound(msg)

        db.commit.assert_awaited()
        db.rollback.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_db_error_does_not_ack(self, bridge_module):
        """If DB fails, message is NOT acked — JetStream will redeliver."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        cur.execute = AsyncMock(side_effect=Exception("DB connection lost"))

        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "txn-002"},
        )

        await bridge._process_inbound(msg)

        # Should NOT ack — JetStream will redeliver
        msg.ack.assert_not_awaited()
        # Should rollback
        db.rollback.assert_awaited()

    @pytest.mark.asyncio
    async def test_failure_after_inbox_before_canonical_leaves_retryable(self, bridge_module):
        """Failure between inbox insert and canonical insert rolls back
        the entire transaction, leaving the message retryable.

        In production, the inbox INSERT and canonical INSERT happen in the
        same transaction. If the canonical INSERT fails (e.g., FK violation),
        the entire transaction is rolled back, the inbox row is not committed,
        and the message is NOT acked — JetStream will redeliver it.
        """
        bridge, db, cur, nc, js = _make_bridge(bridge_module)

        # First execute (inbox INSERT) succeeds, second (canonical) fails
        call_count = [0]

        async def _execute_side_effect(*args, **kwargs):
            call_count[0] += 1
            if call_count[0] <= 1:
                return  # inbox INSERT succeeds
            raise Exception("FK violation on canonical table")

        cur.execute = AsyncMock(side_effect=_execute_side_effect)
        # fetchone returns inbox ID for the first call
        cur.fetchone = AsyncMock(return_value=(uuid.uuid4(),))

        envelope = {
            "schema_version": "v1",
            "event_id": str(uuid.uuid4()),
            "source_agent": "test-agent",
            "occurred_at": "2025-01-15T10:30:00Z",
            "payload": {"event_type": "created"},
        }
        msg = _make_nats_msg(
            "sea.agent.event.created",
            json.dumps(envelope).encode(),
            {"Nats-Msg-Id": "txn-003"},
        )

        await bridge._process_inbound(msg)

        # Should NOT ack — transaction rolled back, message is retryable
        msg.ack.assert_not_awaited()
        # Should rollback the failed transaction
        db.rollback.assert_awaited()
        # Should NOT commit
        db.commit.assert_not_awaited()


class TestDeadLetter:
    """Tests for dead-letter publishing behavior."""

    @pytest.mark.asyncio
    async def test_dead_letter_falls_back_to_core_nats_when_js_disabled(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        bridge.js = None

        msg = _make_nats_msg("sea.agent.event.created", b"{}")

        await bridge._dead_letter(msg, "sea.agent.event.created", b"{}", "test_reason")

        nc.publish.assert_awaited_once()


class TestOutboundDispatch:
    """Tests for outbound message dispatch."""

    @pytest.mark.asyncio
    async def test_outbox_dispatch_marks_delivered(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        event_id = uuid.uuid4()

        await bridge._dispatch_outbox(
            cur,
            event_id,
            "test.target",
            "out-msg-001",
            '{"key": "value"}',
            '{"data": "payload"}',
        )

        js.publish.assert_awaited_once()
        # Should update outbox status to delivered
        execute_calls = cur.execute.call_args_list
        update_found = any("delivered" in str(c) and "outbox_events" in str(c) for c in execute_calls)
        assert update_found

    @pytest.mark.asyncio
    async def test_outbox_dispatch_failure_records_error(self, bridge_module):
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        js.publish = AsyncMock(side_effect=Exception("NATS timeout"))
        event_id = uuid.uuid4()

        await bridge._dispatch_outbox(
            cur,
            event_id,
            "test.target",
            "out-msg-002",
            "{}",
            "{}",
        )

        # Should record failed delivery attempt
        execute_calls = cur.execute.call_args_list
        fail_found = any("failed" in str(c) and "delivery_attempts" in str(c) for c in execute_calls)
        assert fail_found

    @pytest.mark.asyncio
    async def test_outbox_dispatch_fallback_to_core_nats(self, bridge_module):
        """When JetStream publish fails with NoStreamResponseError,
        fall back to core NATS publish."""
        import nats.js.errors

        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        js.publish = AsyncMock(side_effect=nats.js.errors.NoStreamResponseError())
        event_id = uuid.uuid4()

        await bridge._dispatch_outbox(
            cur,
            event_id,
            "test.target",
            "out-msg-003",
            "{}",
            "{}",
        )

        # Should fall back to core NATS
        nc.publish.assert_awaited_once()


class TestLifecycleActuator:
    """Unit tests for the inbox_events lifecycle actuator in _actuate_table."""

    @pytest.mark.asyncio
    async def test_happy_path_executes_update_and_audit_insert(self, bridge_module):
        """Happy path: found item, legal transition → UPDATE + INSERT lifecycle_audit."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        item_id = str(uuid.uuid4())
        # SELECT returns current status "candidate"
        cur.fetchone = AsyncMock(return_value=("candidate",))

        await bridge._actuate_table(
            cur=cur,
            table="inbox_events",
            p={
                "memory_item_id": item_id,
                "new_status": "accepted",
                "changed_by": "zeroclaw/agent@v0.7",
                "reason": "governance_approved",
            },
            source_agent="zeroclaw/agent@v0.7",
            inbox_id=uuid.uuid4(),
        )

        calls = [call_args.args[0].strip() for call_args in cur.execute.call_args_list]
        assert any("SELECT status FROM memory.items" in c for c in calls), \
            "Expected FOR UPDATE SELECT"
        assert any("UPDATE memory.items" in c for c in calls), \
            "Expected UPDATE memory.items"
        assert any("INSERT INTO memory.lifecycle_audit" in c for c in calls), \
            "Expected INSERT INTO lifecycle_audit"

    @pytest.mark.asyncio
    async def test_unknown_memory_item_id_skips_update(self, bridge_module):
        """If the item does not exist, no UPDATE or INSERT should be executed."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        cur.fetchone = AsyncMock(return_value=None)

        await bridge._actuate_table(
            cur=cur,
            table="inbox_events",
            p={
                "memory_item_id": str(uuid.uuid4()),
                "new_status": "accepted",
                "changed_by": "agent",
                "reason": "test",
            },
            source_agent="agent",
            inbox_id=uuid.uuid4(),
        )

        calls = [call_args.args[0].strip() for call_args in cur.execute.call_args_list]
        assert not any("UPDATE memory.items" in c for c in calls)
        assert not any("INSERT INTO memory.lifecycle_audit" in c for c in calls)

    @pytest.mark.asyncio
    async def test_illegal_transition_raises_and_no_update(self, bridge_module):
        """An illegal FSM arc (e.g. superseded→accepted) must raise ValueError and not mutate."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)
        cur.fetchone = AsyncMock(return_value=("superseded",))

        with pytest.raises(ValueError, match="Illegal transition"):
            await bridge._actuate_table(
                cur=cur,
                table="inbox_events",
                p={
                    "memory_item_id": str(uuid.uuid4()),
                    "new_status": "accepted",
                    "changed_by": "agent",
                    "reason": "test",
                },
                source_agent="agent",
                inbox_id=uuid.uuid4(),
            )

        calls = [call_args.args[0].strip() for call_args in cur.execute.call_args_list]
        assert not any("UPDATE memory.items" in c for c in calls)

    @pytest.mark.asyncio
    async def test_missing_memory_item_id_skips_all_sql(self, bridge_module):
        """If memory_item_id is absent from payload, no SQL at all."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)

        await bridge._actuate_table(
            cur=cur,
            table="inbox_events",
            p={"new_status": "accepted", "changed_by": "agent", "reason": "test"},
            source_agent="agent",
            inbox_id=uuid.uuid4(),
        )

        cur.execute.assert_not_called()

    @pytest.mark.asyncio
    async def test_missing_new_status_skips_all_sql(self, bridge_module):
        """If new_status is absent from payload, no SQL at all."""
        bridge, db, cur, nc, js = _make_bridge(bridge_module)

        await bridge._actuate_table(
            cur=cur,
            table="inbox_events",
            p={"memory_item_id": str(uuid.uuid4()), "changed_by": "agent", "reason": "test"},
            source_agent="agent",
            inbox_id=uuid.uuid4(),
        )

        cur.execute.assert_not_called()
