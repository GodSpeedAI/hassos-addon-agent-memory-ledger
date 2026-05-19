"""Tests for event envelope validation.

Covers:
  - valid v1 envelope accepted
  - missing event_id rejected
  - invalid timestamp rejected
  - non-JSON body rejected (at the processing level)
  - schema_version validation
  - source validation
  - payload type validation
  - subject-specific payload validation
"""



class TestEnvelopeValidation:
    """Tests for validate_envelope()."""

    def test_valid_minimal_envelope(self, bridge_module, valid_v1_envelope):
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True
        assert result.errors == []

    def test_missing_event_id(self, bridge_module, valid_v1_envelope):
        del valid_v1_envelope["event_id"]
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("event_id" in e for e in result.errors)

    def test_missing_schema_version(self, bridge_module, valid_v1_envelope):
        del valid_v1_envelope["schema_version"]
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_invalid_schema_version(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["schema_version"] = "v2"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("schema_version" in e for e in result.errors)

    def test_missing_source_agent(self, bridge_module, valid_v1_envelope):
        del valid_v1_envelope["source_agent"]
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_empty_source_agent(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["source_agent"] = ""
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_source_agent_too_long(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["source_agent"] = "x" * 257
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("256" in e for e in result.errors)

    def test_invalid_timestamp_format(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["occurred_at"] = "not-a-timestamp"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("occurred_at" in e for e in result.errors)

    def test_timestamp_with_offset(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["occurred_at"] = "2025-01-15T10:30:00+05:30"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True

    def test_timestamp_with_milliseconds(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["occurred_at"] = "2025-01-15T10:30:00.123Z"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True

    def test_invalid_event_id_format(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["event_id"] = "not-a-uuid"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("event_id" in e for e in result.errors)

    def test_payload_must_be_object(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["payload"] = "not-an-object"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("payload" in e for e in result.errors)

    def test_payload_array_rejected(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["payload"] = [1, 2, 3]
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_payload_null_rejected(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["payload"] = None
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_valid_source_values(self, bridge_module, valid_v1_envelope):
        for source in ["zeroclaw", "sea-forge", "home-assistant", "other"]:
            valid_v1_envelope["source"] = source
            result = bridge_module.validate_envelope(valid_v1_envelope)
            assert result.valid is True, f"source={source} should be valid"

    def test_invalid_source_rejected(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["source"] = "invalid-source"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        assert any("source" in e for e in result.errors)

    def test_optional_idempotency_key_string(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["idempotency_key"] = "key-123"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True

    def test_optional_idempotency_key_non_string_rejected(
        self, bridge_module, valid_v1_envelope
    ):
        valid_v1_envelope["idempotency_key"] = 123
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_optional_correlation_id_string(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["correlation_id"] = "corr-123"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True

    def test_optional_correlation_id_non_string_rejected(
        self, bridge_module, valid_v1_envelope
    ):
        valid_v1_envelope["correlation_id"] = 123
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_optional_provenance_object(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["provenance"] = {"chain": ["a", "b"]}
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is True

    def test_optional_provenance_non_object_rejected(
        self, bridge_module, valid_v1_envelope
    ):
        valid_v1_envelope["provenance"] = "not-an-object"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False

    def test_multiple_missing_fields(self, bridge_module):
        result = bridge_module.validate_envelope({})
        assert result.valid is False
        # Should report missing fields
        assert len(result.errors) >= 1

    def test_error_summary(self, bridge_module, valid_v1_envelope):
        valid_v1_envelope["event_id"] = "bad"
        valid_v1_envelope["occurred_at"] = "bad"
        result = bridge_module.validate_envelope(valid_v1_envelope)
        assert result.valid is False
        summary = result.error_summary()
        assert "event_id" in summary
        assert "occurred_at" in summary


class TestPayloadValidation:
    """Tests for validate_payload()."""

    def test_agent_event_no_required_payload_fields(
        self, bridge_module, valid_agent_event_envelope
    ):
        result = bridge_module.validate_payload(
            "sea.agent.event", valid_agent_event_envelope
        )
        assert result.valid is True

    def test_governance_request_valid(
        self, bridge_module, valid_governance_request_envelope
    ):
        result = bridge_module.validate_payload(
            "sea.governance.request", valid_governance_request_envelope
        )
        assert result.valid is True

    def test_governance_request_missing_identity_id(
        self, bridge_module, valid_governance_request_envelope
    ):
        del valid_governance_request_envelope["payload"]["requesting_identity_id"]
        result = bridge_module.validate_payload(
            "sea.governance.request", valid_governance_request_envelope
        )
        assert result.valid is False
        assert any("requesting_identity_id" in e for e in result.errors)

    def test_governance_request_invalid_identity_id(
        self, bridge_module, valid_governance_request_envelope
    ):
        valid_governance_request_envelope["payload"]["requesting_identity_id"] = (
            "not-a-uuid"
        )
        result = bridge_module.validate_payload(
            "sea.governance.request", valid_governance_request_envelope
        )
        assert result.valid is False

    def test_governance_request_invalid_action_type(
        self, bridge_module, valid_governance_request_envelope
    ):
        valid_governance_request_envelope["payload"]["requested_action_type"] = (
            "invalid_action"
        )
        result = bridge_module.validate_payload(
            "sea.governance.request", valid_governance_request_envelope
        )
        assert result.valid is False
        assert any("requested_action_type" in e for e in result.errors)

    def test_governance_request_valid_action_types(
        self, bridge_module, valid_governance_request_envelope
    ):
        for action_type in [
            "tool_call",
            "memory_write",
            "file_write",
            "network_request",
            "email_send",
            "command_execute",
            "policy_override_request",
        ]:
            valid_governance_request_envelope["payload"]["requested_action_type"] = (
                action_type
            )
            result = bridge_module.validate_payload(
                "sea.governance.request", valid_governance_request_envelope
            )
            assert result.valid is True, f"action_type={action_type} should be valid"

    def test_governance_decision_valid(
        self, bridge_module, valid_governance_decision_envelope
    ):
        result = bridge_module.validate_payload(
            "sea.governance.decision", valid_governance_decision_envelope
        )
        assert result.valid is True

    def test_governance_decision_missing_request_id(
        self, bridge_module, valid_governance_decision_envelope
    ):
        del valid_governance_decision_envelope["payload"]["request_id"]
        result = bridge_module.validate_payload(
            "sea.governance.decision", valid_governance_decision_envelope
        )
        assert result.valid is False

    def test_governance_decision_invalid_decision(
        self, bridge_module, valid_governance_decision_envelope
    ):
        valid_governance_decision_envelope["payload"]["decision"] = "maybe"
        result = bridge_module.validate_payload(
            "sea.governance.decision", valid_governance_decision_envelope
        )
        assert result.valid is False

    def test_governance_decision_valid_decisions(
        self, bridge_module, valid_governance_decision_envelope
    ):
        for decision in ["accepted", "rejected", "requires_review", "deferred"]:
            valid_governance_decision_envelope["payload"]["decision"] = decision
            result = bridge_module.validate_payload(
                "sea.governance.decision", valid_governance_decision_envelope
            )
            assert result.valid is True, f"decision={decision} should be valid"

    def test_governance_decision_invalid_policy_version_id(
        self, bridge_module, valid_governance_decision_envelope
    ):
        valid_governance_decision_envelope["payload"]["policy_version_id"] = (
            "not-a-uuid"
        )
        result = bridge_module.validate_payload(
            "sea.governance.decision", valid_governance_decision_envelope
        )
        assert result.valid is False

    def test_memory_write_valid(self, bridge_module, valid_memory_write_envelope):
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is True

    def test_memory_write_missing_content(
        self, bridge_module, valid_memory_write_envelope
    ):
        del valid_memory_write_envelope["payload"]["content"]
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is False

    def test_memory_write_empty_content(
        self, bridge_module, valid_memory_write_envelope
    ):
        valid_memory_write_envelope["payload"]["content"] = ""
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is False

    def test_memory_write_confidence_valid(
        self, bridge_module, valid_memory_write_envelope
    ):
        valid_memory_write_envelope["payload"]["confidence"] = 0.85
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is True

    def test_memory_write_confidence_out_of_range(
        self, bridge_module, valid_memory_write_envelope
    ):
        valid_memory_write_envelope["payload"]["confidence"] = 1.5
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is False

    def test_memory_write_confidence_negative(
        self, bridge_module, valid_memory_write_envelope
    ):
        valid_memory_write_envelope["payload"]["confidence"] = -0.1
        result = bridge_module.validate_payload(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is False

    def test_memory_lifecycle_valid(self, bridge_module):
        data = {
            "payload": {
                "memory_item_id": "88888888-8888-8888-8888-888888888888",
                "new_status": "accepted",
                "changed_by": "test-agent",
                "reason": "quality check passed",
            }
        }
        result = bridge_module.validate_payload("sea.memory.lifecycle", data)
        assert result.valid is True

    def test_memory_lifecycle_invalid_status(self, bridge_module):
        data = {
            "payload": {
                "memory_item_id": "88888888-8888-8888-8888-888888888888",
                "new_status": "invalid_status",
                "changed_by": "test-agent",
                "reason": "test",
            }
        }
        result = bridge_module.validate_payload("sea.memory.lifecycle", data)
        assert result.valid is False

    def test_memory_lifecycle_invalid_memory_item_id(self, bridge_module):
        data = {
            "payload": {
                "memory_item_id": "not-a-uuid",
                "new_status": "accepted",
                "changed_by": "test-agent",
                "reason": "test",
            }
        }
        result = bridge_module.validate_payload("sea.memory.lifecycle", data)
        assert result.valid is False

    def test_unknown_family_no_required_fields(self, bridge_module, valid_v1_envelope):
        result = bridge_module.validate_payload("sea.unknown.family", valid_v1_envelope)
        assert result.valid is True


class TestContractValidation:
    """Tests for validate_contract() — full two-stage validation."""

    def test_valid_agent_event(self, bridge_module, valid_agent_event_envelope):
        result = bridge_module.validate_contract(
            "sea.agent.event", valid_agent_event_envelope
        )
        assert result.valid is True

    def test_valid_governance_request(
        self, bridge_module, valid_governance_request_envelope
    ):
        result = bridge_module.validate_contract(
            "sea.governance.request", valid_governance_request_envelope
        )
        assert result.valid is True

    def test_valid_governance_decision(
        self, bridge_module, valid_governance_decision_envelope
    ):
        result = bridge_module.validate_contract(
            "sea.governance.decision", valid_governance_decision_envelope
        )
        assert result.valid is True

    def test_valid_memory_write(self, bridge_module, valid_memory_write_envelope):
        result = bridge_module.validate_contract(
            "sea.memory.write", valid_memory_write_envelope
        )
        assert result.valid is True

    def test_invalid_envelope_and_payload(self, bridge_module):
        """Both stages produce errors."""
        data = {
            "schema_version": "v2",
            "event_id": "bad",
            "source_agent": "",
            "occurred_at": "bad",
            "payload": "not-an-object",
        }
        result = bridge_module.validate_contract("sea.governance.request", data)
        assert result.valid is False
        # Should have errors from both envelope and payload stages
        assert len(result.errors) >= 3

    def test_valid_envelope_invalid_payload(self, bridge_module, valid_v1_envelope):
        """Envelope is valid but governance payload is missing required fields."""
        result = bridge_module.validate_contract(
            "sea.governance.request", valid_v1_envelope
        )
        assert result.valid is False
        assert any("requesting_identity_id" in e for e in result.errors)


class TestFailOpenFailClosed:
    """Tests that fail-open/fail-closed semantics are correctly configured."""

    def test_agent_event_is_fail_open(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.agent.event"]
        assert route["fail_open"] is True

    def test_governance_request_is_fail_closed(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.request"]
        assert route["fail_open"] is False

    def test_governance_decision_is_fail_closed(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.governance.decision"]
        assert route["fail_open"] is False

    def test_memory_write_is_fail_closed(self, bridge_module):
        route = bridge_module.CANONICAL_ROUTES["sea.memory.write"]
        assert route["fail_open"] is False
