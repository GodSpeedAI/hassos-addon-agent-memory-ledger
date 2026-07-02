"""Shared test fixtures and configuration."""

import importlib.util
import os
import sys

import pytest

# ---------------------------------------------------------------------------
# Import the bridge module without installing it.
# The source is at agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py
# ---------------------------------------------------------------------------
_BRIDGE_PATH = os.path.join(
    os.path.dirname(__file__),
    "..",
    "agent_memory_ledger",
    "rootfs",
    "usr",
    "bin",
    "sea_nats_bridge.py",
)


@pytest.fixture(autouse=True)
def _import_bridge():
    """Make sea_nats_bridge module available as 'sea_nats_bridge'."""
    if "sea_nats_bridge" not in sys.modules:
        spec = importlib.util.spec_from_file_location("sea_nats_bridge", _BRIDGE_PATH)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["sea_nats_bridge"] = mod
        spec.loader.exec_module(mod)


@pytest.fixture
def bridge_module():
    """Return the imported sea_nats_bridge module."""
    return sys.modules["sea_nats_bridge"]


@pytest.fixture
def valid_v1_envelope():
    """Return a minimal valid v1 event envelope."""
    return {
        "schema_version": "v1",
        "event_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        "source_agent": "test-agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "provenance": {"origin": "test-agent", "chain": []},
        "payload": {},
    }


@pytest.fixture
def valid_agent_event_envelope():
    """Valid envelope for sea.agent.event.* subjects."""
    return {
        "schema_version": "v1",
        "event_id": "11111111-1111-1111-1111-111111111111",
        "source_agent": "test-agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "provenance": {"origin": "test-agent", "chain": []},
        "payload": {
            "event_type": "created",
        },
    }


@pytest.fixture
def valid_governance_request_envelope():
    """Valid envelope for sea.governance.request.* subjects."""
    return {
        "schema_version": "v1",
        "event_id": "22222222-2222-2222-2222-222222222222",
        "source_agent": "test-agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "provenance": {"origin": "test-agent", "chain": []},
        "payload": {
            "requesting_identity_id": "33333333-3333-3333-3333-333333333333",
            "requested_action_type": "tool_call",
        },
    }


@pytest.fixture
def valid_governance_decision_envelope():
    """Valid envelope for sea.governance.decision.* subjects."""
    return {
        "schema_version": "v1",
        "event_id": "44444444-4444-4444-4444-444444444444",
        "source_agent": "test-agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "provenance": {"origin": "test-agent", "chain": []},
        "payload": {
            "request_id": "55555555-5555-5555-5555-555555555555",
            "decision": "accepted",
            "policy_version_id": "66666666-6666-6666-6666-666666666666",
        },
    }


@pytest.fixture
def valid_memory_write_envelope():
    """Valid envelope for sea.memory.write.* subjects."""
    return {
        "schema_version": "v1",
        "event_id": "77777777-7777-7777-7777-777777777777",
        "source_agent": "test-agent",
        "occurred_at": "2025-01-15T10:30:00Z",
        "provenance": {"origin": "test-agent", "chain": []},
        "payload": {
            "source_agent": "test-agent",
            "content": "This is a test memory content",
        },
    }
