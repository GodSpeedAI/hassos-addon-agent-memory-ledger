"""Tests for subject routing logic.

Covers:
  - sea.agent.event.created -> event_log.agent_events
  - sea.governance.request.tool_call -> governance.action_requests
  - sea.governance.decision.accepted -> governance.action_decisions
  - sea.memory.write.* -> memory.items
  - unknown subject -> no route (dead letter path)
"""


class TestSubjectFamily:
    """Tests for the subject_family() function."""

    def test_agent_event_created(self, bridge_module):
        assert bridge_module.subject_family("sea.agent.event.created") == "sea.agent.event"

    def test_agent_event_updated(self, bridge_module):
        assert bridge_module.subject_family("sea.agent.event.updated") == "sea.agent.event"

    def test_governance_request_tool_call(self, bridge_module):
        assert bridge_module.subject_family("sea.governance.request.tool_call") == "sea.governance.request"

    def test_governance_decision_accepted(self, bridge_module):
        assert bridge_module.subject_family("sea.governance.decision.accepted") == "sea.governance.decision"

    def test_memory_write(self, bridge_module):
        assert bridge_module.subject_family("sea.memory.write.fact") == "sea.memory.write"

    def test_memory_lifecycle(self, bridge_module):
        assert bridge_module.subject_family("sea.memory.lifecycle.accepted") == "sea.memory.lifecycle"

    def test_short_subject(self, bridge_module):
        """Subjects with fewer than 3 parts are returned as-is."""
        assert bridge_module.subject_family("sea.agent") == "sea.agent"

    def test_deeply_nested_subject(self, bridge_module):
        assert bridge_module.subject_family("sea.agent.event.created.sub.event") == "sea.agent.event"


class TestCanonicalRoutes:
    """Tests for the CANONICAL_ROUTES mapping."""

    def test_agent_event_routes_to_event_log(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.agent.event"]
        assert route["schema"] == "event_log"
        assert route["table"] == "agent_events"
        assert route["fail_open"] is True

    def test_governance_request_routes_to_action_requests(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.request"]
        assert route["schema"] == "governance"
        assert route["table"] == "action_requests"
        assert route["fail_open"] is False

    def test_governance_decision_routes_to_action_decisions(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.decision"]
        assert route["schema"] == "governance"
        assert route["table"] == "action_decisions"
        assert route["fail_open"] is False

    def test_memory_write_routes_to_items(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.memory.write"]
        assert route["schema"] == "memory"
        assert route["table"] == "items"
        assert route["fail_open"] is False

    def test_memory_lifecycle_routes_to_inbox_events(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.memory.lifecycle"]
        assert route["schema"] == "event_log"
        assert route["table"] == "inbox_events"
        assert route["fail_open"] is False

    def test_unknown_subject_has_no_route(self, bridge_module):
        family = bridge_module.subject_family("sea.unknown.subject.type")
        route = bridge_module.CANONICAL_ROUTES.get(family)
        assert route is None

    def test_dead_letter_subject_has_no_route(self, bridge_module):
        family = bridge_module.subject_family("sea.ledger.deadletter")
        route = bridge_module.CANONICAL_ROUTES.get(family)
        assert route is None

    def test_outbox_subject_has_no_route(self, bridge_module):
        family = bridge_module.subject_family("sea.ledger.outbox.test")
        route = bridge_module.CANONICAL_ROUTES.get(family)
        assert route is None

    def test_governance_request_required_fields(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.request"]
        assert "requesting_identity_id" in route["required"]
        assert "requested_action_type" in route["required"]

    def test_governance_decision_required_fields(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.decision"]
        assert "request_id" in route["required"]
        assert "decision" in route["required"]

    def test_memory_write_required_fields(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.memory.write"]
        assert "source_agent" in route["required"]
        assert "content" in route["required"]

    def test_memory_lifecycle_required_fields(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.memory.lifecycle"]
        assert "memory_item_id" in route["required"]
        assert "new_status" in route["required"]
        assert "changed_by" in route["required"]
        assert "reason" not in route["required"]


class TestDeriveMessageId:
    """Tests for the derive_message_id() function."""

    def test_uses_idempotency_header(self, bridge_module):
        headers = {"X-Custom-Id": "my-custom-id"}
        result = bridge_module.derive_message_id("sub", b"data", headers, "X-Custom-Id")
        assert result == "my-custom-id"

    def test_uses_nats_msg_id_fallback(self, bridge_module):
        headers = {"Nats-Msg-Id": "nats-id-123"}
        result = bridge_module.derive_message_id("sub", b"data", headers, "X-Custom-Id")
        assert result == "nats-id-123"

    def test_idempotency_header_takes_precedence(self, bridge_module):
        headers = {"X-Id": "primary", "Nats-Msg-Id": "fallback"}
        result = bridge_module.derive_message_id("sub", b"data", headers, "X-Id")
        assert result == "primary"

    def test_sha256_hash_when_no_headers(self, bridge_module):
        result = bridge_module.derive_message_id("sub", b"data", {}, "X-Id")
        assert result.startswith("sha256-")
        assert len(result) == 47  # "sha256-" + 40 hex chars

    def test_deterministic_hash(self, bridge_module):
        r1 = bridge_module.derive_message_id("sub", b"data", {}, "X-Id")
        r2 = bridge_module.derive_message_id("sub", b"data", {}, "X-Id")
        assert r1 == r2

    def test_different_payload_different_hash(self, bridge_module):
        r1 = bridge_module.derive_message_id("sub", b"data1", {}, "X-Id")
        r2 = bridge_module.derive_message_id("sub", b"data2", {}, "X-Id")
        assert r1 != r2

    def test_uses_envelope_event_id_when_no_headers(self, bridge_module):
        """Priority 3: event_id from parsed envelope data."""
        import uuid
        eid = str(uuid.uuid4())
        result = bridge_module.derive_message_id("sub", b"data", {}, "X-Id", data={"event_id": eid})
        assert result == eid

    def test_event_id_lower_priority_than_nats_msg_id(self, bridge_module):
        """Nats-Msg-Id (priority 2) wins over envelope event_id (priority 3)."""
        import uuid
        headers = {"Nats-Msg-Id": "nats-wins"}
        result = bridge_module.derive_message_id(
            "sub", b"data", headers, "X-Id", data={"event_id": str(uuid.uuid4())}
        )
        assert result == "nats-wins"

    def test_empty_event_id_falls_through_to_sha256(self, bridge_module):
        """An empty-string event_id must not be used; fall through to sha256."""
        result = bridge_module.derive_message_id(
            "sub", b"data", {}, "X-Id", data={"event_id": "   "}
        )
        assert result.startswith("sha256-")

    def test_non_string_event_id_falls_through_to_sha256(self, bridge_module):
        """A non-string event_id (e.g. int) must not be used; fall through to sha256."""
        result = bridge_module.derive_message_id(
            "sub", b"data", {}, "X-Id", data={"event_id": 12345}
        )
        assert result.startswith("sha256-")

    def test_data_none_does_not_crash(self, bridge_module):
        """data=None (default) must not raise."""
        result = bridge_module.derive_message_id("sub", b"data", {}, "X-Id", data=None)
        assert result.startswith("sha256-")

    def test_data_not_a_dict_does_not_crash(self, bridge_module):
        """data being a non-dict (e.g. a list) must not raise."""
        result = bridge_module.derive_message_id("sub", b"data", {}, "X-Id", data=["a", "b"])
        assert result.startswith("sha256-")
