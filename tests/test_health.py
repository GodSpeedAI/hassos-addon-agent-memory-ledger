"""Tests for health endpoints.

Covers:
  - /healthz works (liveness)
  - /readyz fails when DB unavailable
  - /readyz fails when NATS unavailable and bridge enabled
  - /readyz passes when dependencies are healthy
  - /metrics-lite returns operational metrics
  - Unknown paths return 404

These tests use mock objects for DB and NATS to avoid requiring real
infrastructure. They test the HealthServer HTTP handling directly by
calling the handler methods.
"""

import io
import json
import time
from unittest.mock import AsyncMock, MagicMock

import pytest


class MockStreamWriter:
    """Mock asyncio.StreamWriter that captures written data."""

    def __init__(self):
        self._buffer = io.BytesIO()
        self.closed = False

    def write(self, data: bytes):
        self._buffer.write(data)

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass

    def get_output(self) -> str:
        return self._buffer.getvalue().decode()


class MockStreamReader:
    """Mock asyncio.StreamReader that provides request lines."""

    def __init__(self, request_line: str):
        self._lines = [
            f"{request_line}\r\n".encode(),
            b"\r\n",
        ]
        self._idx = 0

    async def readline(self):
        if self._idx < len(self._lines):
            line = self._lines[self._idx]
            self._idx += 1
            return line
        return b""


def _make_bridge_mock(connected=True, js_enabled=True):
    """Create a mock SEABridge with sensible defaults."""
    bridge = MagicMock()
    bridge._running = True
    bridge._last_poll_at = time.time()
    bridge._last_message_at = time.time()
    bridge._last_error = ""
    bridge._last_error_at = 0.0
    bridge._messages_processed = 42

    # NATS mock
    nc = MagicMock()
    nc.is_connected = connected
    bridge.nc = nc

    # JetStream mock
    if js_enabled and connected:
        js = AsyncMock()
        si = MagicMock()
        si.state.messages = 100
        js.stream_info = AsyncMock(return_value=si)
        js.consumer_info = AsyncMock(return_value=MagicMock())
        bridge.js = js
    else:
        bridge.js = None

    # Config mock
    bridge.cfg = MagicMock()
    bridge.cfg.js_poll_interval = 2
    bridge.cfg.js_stream_name = "SEA_LEDGER"
    bridge.cfg.js_durable_name = "test_bridge"
    bridge.cfg.js_enabled = js_enabled

    # DB mock
    db = AsyncMock()
    cursor = AsyncMock()
    cursor.__aenter__ = AsyncMock(return_value=cursor)
    cursor.__aexit__ = AsyncMock(return_value=False)
    cursor.execute = AsyncMock()
    cursor.fetchone = AsyncMock(return_value=(1,))
    cursor.fetchall = AsyncMock(return_value=[])
    db.cursor = MagicMock(return_value=cursor)
    db.commit = AsyncMock()
    db.rollback = AsyncMock()
    db.closed = False
    bridge._get_db = AsyncMock(return_value=db)
    bridge._db = db

    return bridge


@pytest.fixture
def bridge_mock():
    return _make_bridge_mock()


@pytest.fixture
def health_server(bridge_module, bridge_mock):
    cfg = bridge_module.BridgeConfig(health_bind="127.0.0.1", health_port=0)
    return bridge_module.HealthServer(bridge_mock, cfg)


class TestHealthz:
    """Tests for /healthz endpoint."""

    @pytest.mark.asyncio
    async def test_healthz_alive(self, health_server):
        writer = MockStreamWriter()
        await health_server._handle_healthz(writer)
        output = writer.get_output()
        assert "200" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["status"] == "ok"
        assert body["checks"]["bridge"] == "alive"

    @pytest.mark.asyncio
    async def test_healthz_stopped(self, health_server, bridge_mock):
        bridge_mock._running = False
        writer = MockStreamWriter()
        await health_server._handle_healthz(writer)
        output = writer.get_output()
        assert "503" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["status"] == "unhealthy"
        assert body["checks"]["bridge"] == "stopped"


class TestReadyz:
    """Tests for /readyz endpoint."""

    @pytest.mark.asyncio
    async def test_readyz_all_healthy(self, health_server):
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        assert "200" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["status"] == "ready"
        assert body["checks"]["postgres"] == "connected"

    @pytest.mark.asyncio
    async def test_readyz_db_unavailable(self, health_server, bridge_mock):
        bridge_mock._get_db = AsyncMock(side_effect=Exception("Connection refused"))
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        assert "503" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["status"] == "not_ready"
        assert "Connection refused" in body["checks"]["postgres"]

    @pytest.mark.asyncio
    async def test_readyz_nats_disconnected(self, health_server, bridge_mock):
        bridge_mock.nc.is_connected = False
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        assert "503" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["checks"]["nats"] == "disconnected"

    @pytest.mark.asyncio
    async def test_readyz_nats_not_configured(self, health_server, bridge_mock):
        bridge_mock.nc = None
        bridge_mock.js = None
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["checks"]["nats"] == "not_configured"
        # not_configured is not an error — should still be ready
        assert body["status"] == "ready"

    @pytest.mark.asyncio
    async def test_readyz_schema_check(self, health_server, bridge_mock):
        """Verify schema check is included in readiness."""
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert "schema" in body["checks"]

    @pytest.mark.asyncio
    async def test_readyz_bridge_worker_role_check(self, health_server, bridge_mock):
        """Verify bridge_worker role check is included."""
        writer = MockStreamWriter()
        await health_server._handle_readyz(writer)
        output = writer.get_output()
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert "bridge_worker_role" in body["checks"]


class TestMetrics:
    """Tests for /metrics-lite endpoint."""

    @pytest.mark.asyncio
    async def test_metrics_returns_json(self, health_server):
        writer = MockStreamWriter()
        await health_server._handle_metrics(writer)
        output = writer.get_output()
        assert "200" in output
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert "messages_processed" in body
        assert body["messages_processed"] == 42
        assert "bridge_enabled" in body

    @pytest.mark.asyncio
    async def test_metrics_nats_connected(self, health_server, bridge_mock):
        writer = MockStreamWriter()
        await health_server._handle_metrics(writer)
        output = writer.get_output()
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["nats_connected"] is True

    @pytest.mark.asyncio
    async def test_metrics_nats_none(self, health_server, bridge_mock):
        bridge_mock.nc = None
        writer = MockStreamWriter()
        await health_server._handle_metrics(writer)
        output = writer.get_output()
        body = json.loads(output.split("\r\n\r\n", 1)[1])
        assert body["nats_connected"] is None


class TestHttpRouting:
    """Tests for HTTP request routing."""

    @pytest.mark.asyncio
    async def test_unknown_path_returns_404(self, health_server):
        reader = MockStreamReader("GET /unknown HTTP/1.1")
        writer = MockStreamWriter()
        await health_server._handle_request(reader, writer)
        output = writer.get_output()
        assert "404" in output

    @pytest.mark.asyncio
    async def test_healthz_route(self, health_server):
        reader = MockStreamReader("GET /healthz HTTP/1.1")
        writer = MockStreamWriter()
        await health_server._handle_request(reader, writer)
        output = writer.get_output()
        assert "200" in output

    @pytest.mark.asyncio
    async def test_readyz_route(self, health_server):
        reader = MockStreamReader("GET /readyz HTTP/1.1")
        writer = MockStreamWriter()
        await health_server._handle_request(reader, writer)
        output = writer.get_output()
        # May be 200 or 503 depending on mock state
        assert "200" in output or "503" in output
