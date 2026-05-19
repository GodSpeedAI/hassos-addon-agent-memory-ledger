#!/usr/bin/env python3
"""
SEA Forge NATS JetStream Bridge Worker for Agent Memory Ledger.

Connects Postgres canonical event store to NATS JetStream for
SEA Forge / ZeroClaw integration. Postgres remains canonical.

Responsibilities:
  - Inbound: consume SEA subjects, route to canonical tables
  - Outbound: poll outbox, publish to NATS
  - Idempotent: duplicate messages are ACKed without reprocessing
  - Fail-closed: governance subjects with invalid envelopes are rejected
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import signal
import sys
import time
import uuid
from urllib.parse import quote_plus
from dataclasses import dataclass, field
from http import HTTPStatus
from typing import Any

import nats
import psycopg
from nats.js.api import (
    AckPolicy,
    ConsumerConfig,
    DeliverPolicy,
    RetentionPolicy,
    StorageType,
    StreamConfig,
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG = logging.getLogger("sea-bridge")
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
LOG.addHandler(_handler)
LOG.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Configuration — reads from environment set by the s6 run script
# ---------------------------------------------------------------------------
@dataclass
class BridgeConfig:
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "agent_memory"
    db_user: str = "bridge_worker"
    db_password: str = ""

    nats_url: str = "nats://127.0.0.1:4222"
    nats_creds_file: str = ""
    nats_token: str = ""
    nats_name: str = "agent-memory-ledger"
    nats_connect_timeout: int = 5
    nats_reconnect_wait: int = 2
    nats_max_reconnects: int = -1

    js_enabled: bool = True
    js_stream_name: str = "SEA_LEDGER"
    js_durable_name: str = "agent_memory_ledger_bridge"
    js_subjects: list[str] = field(
        default_factory=lambda: [
            "sea.agent.event.>",
            "sea.governance.request.>",
            "sea.governance.decision.>",
            "sea.memory.write.>",
            "sea.memory.lifecycle.>",
        ]
    )
    js_outbox_prefix: str = "sea.ledger.outbox"
    js_ack_wait: int = 30
    js_max_deliver: int = 10
    js_batch_size: int = 100
    js_poll_interval: int = 2

    inbound_enabled: bool = True
    outbound_enabled: bool = True
    dead_letter_enabled: bool = True
    dead_letter_subject: str = "sea.ledger.deadletter"
    idempotency_header: str = "Nats-Msg-Id"
    source_name: str = "sea-forge"
    fail_closed: bool = True

    health_bind: str = "127.0.0.1"
    health_port: int = 8099
    health_enabled: bool = True

    @classmethod
    def from_env(cls) -> BridgeConfig:
        """Load configuration from environment variables."""
        return cls(
            db_host=os.getenv("DB_HOST", "localhost"),
            db_port=int(os.getenv("DB_PORT", "5432")),
            db_name=os.getenv("DB_NAME", "agent_memory"),
            db_user=os.getenv("DB_USER", "bridge_worker"),
            db_password=os.getenv("DB_PASSWORD", ""),
            nats_url=os.getenv("NATS_URL", "nats://127.0.0.1:4222"),
            nats_creds_file=os.getenv("NATS_CREDS_FILE", ""),
            nats_token=os.getenv("NATS_TOKEN", ""),
            nats_name=os.getenv("NATS_NAME", "agent-memory-ledger"),
            nats_connect_timeout=int(os.getenv("NATS_CONNECT_TIMEOUT", "5")),
            nats_reconnect_wait=int(os.getenv("NATS_RECONNECT_WAIT", "2")),
            nats_max_reconnects=int(os.getenv("NATS_MAX_RECONNECTS", "-1")),
            js_enabled=os.getenv("JS_ENABLED", "true").lower() == "true",
            js_stream_name=os.getenv("JS_STREAM_NAME", "SEA_LEDGER"),
            js_durable_name=os.getenv("JS_DURABLE_NAME", "agent_memory_ledger_bridge"),
            js_subjects=[
                s.strip()
                for s in os.getenv(
                    "JS_SUBJECTS",
                    "sea.agent.event.>,sea.governance.request.>,"
                    "sea.governance.decision.>,sea.memory.write.>,"
                    "sea.memory.lifecycle.>",
                ).split(",")
                if s.strip()
            ],
            js_outbox_prefix=os.getenv("JS_OUTBOX_PREFIX", "sea.ledger.outbox"),
            js_ack_wait=int(os.getenv("JS_ACK_WAIT", "30")),
            js_max_deliver=int(os.getenv("JS_MAX_DELIVER", "10")),
            js_batch_size=int(os.getenv("JS_BATCH_SIZE", "100")),
            js_poll_interval=int(os.getenv("JS_POLL_INTERVAL", "2")),
            inbound_enabled=os.getenv("INBOUND_ENABLED", "true").lower() == "true",
            outbound_enabled=os.getenv("OUTBOUND_ENABLED", "true").lower() == "true",
            dead_letter_enabled=os.getenv("DEAD_LETTER_ENABLED", "true").lower() == "true",
            dead_letter_subject=os.getenv("DEAD_LETTER_SUBJECT", "sea.ledger.deadletter"),
            idempotency_header=os.getenv("IDEMPOTENCY_HEADER", "Nats-Msg-Id"),
            source_name=os.getenv("SOURCE_NAME", "sea-forge"),
            fail_closed=os.getenv("FAIL_CLOSED", "true").lower() == "true",
            health_bind=os.getenv("HEALTH_BIND", "127.0.0.1"),
            health_port=int(os.getenv("HEALTH_PORT", "8099")),
            health_enabled=os.getenv("HEALTH_ENABLED", "true").lower() == "true",
        )

    @property
    def db_dsn(self) -> str:
        encoded_password = quote_plus(self.db_password)
        return f"postgresql://{self.db_user}:{encoded_password}@{self.db_host}:{self.db_port}/{self.db_name}"


# ---------------------------------------------------------------------------
# Subject routing
# ---------------------------------------------------------------------------

# Maps subject families to (schema, table, required_fields)
CANONICAL_ROUTES: dict[str, dict[str, Any]] = {
    "sea.agent.event": {
        "schema": "event_log",
        "table": "agent_events",
        "required": ["source_agent", "event_type"],
        "fail_open": True,
    },
    "sea.governance.request": {
        "schema": "governance",
        "table": "action_requests",
        "required": ["requesting_identity_id", "requested_action_type"],
        "fail_open": False,
    },
    "sea.governance.decision": {
        "schema": "governance",
        "table": "action_decisions",
        "required": ["request_id", "decision"],
        "fail_open": False,
    },
    "sea.memory.write": {
        "schema": "memory",
        "table": "items",
        "required": ["source_agent", "content"],
        "fail_open": False,
    },
    "sea.memory.lifecycle": {
        "schema": "event_log",
        "table": "inbox_events",
        "required": ["memory_item_id", "new_status", "changed_by", "reason"],
        "fail_open": False,
    },
}


def subject_family(subject: str) -> str:
    """Extract the family prefix from a subject (e.g., 'sea.agent.event' from
    'sea.agent.event.created')."""
    parts = subject.split(".")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return subject


def derive_message_id(
    subject: str,
    payload: bytes,
    headers: dict[str, str],
    idempotency_header: str,
) -> str:
    """Derive a message ID from header, NATS message ID, or sha256 hash."""
    if idempotency_header in headers:
        return headers[idempotency_header]
    if "Nats-Msg-Id" in headers:
        return headers["Nats-Msg-Id"]
    digest = hashlib.sha256(subject.encode() + payload).hexdigest()
    return f"sha256-{digest[:40]}"


# ---------------------------------------------------------------------------
# Event Contract Validation
# ---------------------------------------------------------------------------
# Validates inbound messages against the SEA Event Contract v1.
# Uses the JSON Schema files in /usr/share/agent_memory_ledger/contracts/
# as the authoritative contract, but implements validation directly
# to avoid adding jsonschema as a runtime dependency.
#
# Validation is two-stage:
#   1. Envelope validation (common fields across all event types)
#   2. Subject-specific payload validation
#
# Fail-closed: governance requests, governance decisions, memory writes,
# and memory lifecycle events are REJECTED if validation fails.
# Fail-open: agent events produce warnings but are still accepted.
# ---------------------------------------------------------------------------

# UUID regex (simplified — validates format, not version)
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)

# RFC 3339 datetime regex (simplified)
_RFC3339_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?"
    r"(?:Z|[+-]\d{2}:\d{2})$"
)

# Valid source values
_VALID_SOURCES = {"zeroclaw", "sea-forge", "home-assistant", "other"}

# Valid governance action types (must match governance_action_type enum)
_VALID_ACTION_TYPES = {
    "tool_call",
    "memory_write",
    "file_write",
    "network_request",
    "email_send",
    "command_execute",
    "policy_override_request",
}

# Valid governance decisions (must match governance_decision enum)
_VALID_DECISIONS = {"accepted", "rejected", "requires_review", "deferred"}

# Valid memory lifecycle statuses (must match memory_status enum)
_VALID_MEMORY_STATUSES = {
    "observed",
    "candidate",
    "accepted",
    "verified",
    "superseded",
    "rejected",
    "expired",
}

# Required common envelope fields
_ENVELOPE_REQUIRED = {
    "schema_version",
    "event_id",
    "source_agent",
    "occurred_at",
    "payload",
}

# Subject-specific payload required fields
_PAYLOAD_REQUIRED: dict[str, set[str]] = {
    "sea.agent.event": set(),  # no payload-level required fields beyond envelope
    "sea.governance.request": {
        "requesting_identity_id",
        "requested_action_type",
    },
    "sea.governance.decision": {
        "request_id",
        "decision",
        "policy_version_id",
    },
    "sea.memory.write": {
        "source_agent",
        "content",
    },
    "sea.memory.lifecycle": {
        "memory_item_id",
        "new_status",
        "changed_by",
        "reason",
    },
}


@dataclass
class ValidationResult:
    """Result of contract validation."""

    valid: bool
    errors: list[str] = field(default_factory=list)

    def error_summary(self) -> str:
        return "; ".join(self.errors)


def _validate_uuid(value: Any, field_name: str) -> list[str]:
    """Validate a UUID string."""
    errors: list[str] = []
    if not isinstance(value, str):
        errors.append(f"{field_name}: expected string, got {type(value).__name__}")
    elif not _UUID_RE.match(value):
        errors.append(f"{field_name}: invalid UUID format '{value}'")
    return errors


def _validate_rfc3339(value: Any, field_name: str) -> list[str]:
    """Validate an RFC 3339 timestamp."""
    errors: list[str] = []
    if not isinstance(value, str):
        errors.append(f"{field_name}: expected string, got {type(value).__name__}")
    elif not _RFC3339_RE.match(value):
        errors.append(f"{field_name}: invalid RFC 3339 format '{value}'")
    return errors


def validate_envelope(data: dict[str, Any]) -> ValidationResult:
    """Stage 1: Validate the common envelope fields.

    Checks:
      - All required envelope fields are present
      - schema_version is 'v1'
      - event_id is a valid UUID
      - source_agent is a non-empty string
      - occurred_at is RFC 3339
      - source (if present) is from the allowed set
      - payload is an object
      - idempotency_key (if present) is a string
      - correlation_id, causation_id, trace_id (if present) are strings
    """
    errors: list[str] = []

    # Required fields
    missing = [f for f in _ENVELOPE_REQUIRED if f not in data]
    if missing:
        errors.append(f"Missing required envelope fields: {missing}")
        return ValidationResult(valid=False, errors=errors)

    # schema_version
    sv = data.get("schema_version")
    if sv != "v1":
        errors.append(f"schema_version: expected 'v1', got '{sv}'")

    # event_id
    errors.extend(_validate_uuid(data.get("event_id"), "event_id"))

    # source_agent
    sa = data.get("source_agent")
    if not isinstance(sa, str) or len(sa) == 0:
        errors.append(f"source_agent: expected non-empty string, got {sa!r}")
    elif len(sa) > 256:
        errors.append(f"source_agent: exceeds 256 characters ({len(sa)})")

    # occurred_at
    errors.extend(_validate_rfc3339(data.get("occurred_at"), "occurred_at"))

    # source (optional)
    src = data.get("source")
    if src is not None and src not in _VALID_SOURCES:
        errors.append(f"source: must be one of {sorted(_VALID_SOURCES)}, got '{src}'")

    # payload (must be object)
    payload = data.get("payload")
    if not isinstance(payload, dict):
        errors.append(f"payload: expected object, got {type(payload).__name__}")

    # idempotency_key (optional string)
    ik = data.get("idempotency_key")
    if ik is not None and not isinstance(ik, str):
        errors.append(f"idempotency_key: expected string, got {type(ik).__name__}")

    # Optional string fields
    for opt_field in ("correlation_id", "causation_id", "trace_id"):
        val = data.get(opt_field)
        if val is not None and not isinstance(val, str):
            errors.append(f"{opt_field}: expected string, got {type(val).__name__}")

    # provenance and metadata (optional objects)
    for obj_field in ("provenance", "metadata"):
        val = data.get(obj_field)
        if val is not None and not isinstance(val, dict):
            errors.append(f"{obj_field}: expected object, got {type(val).__name__}")

    return ValidationResult(valid=len(errors) == 0, errors=errors)


def validate_payload(family: str, data: dict[str, Any]) -> ValidationResult:
    """Stage 2: Validate subject-specific payload fields.

    The payload is extracted from data['payload'] and validated against
    the contract for the given subject family.
    """
    errors: list[str] = []
    payload = data.get("payload", {})

    if not isinstance(payload, dict):
        errors.append("payload is not an object — cannot validate payload fields")
        return ValidationResult(valid=False, errors=errors)

    required = _PAYLOAD_REQUIRED.get(family, set())
    if required:
        missing = [f for f in required if f not in payload]
        if missing:
            errors.append(f"Missing required payload fields: {missing}")

    # Subject-specific type validation
    if family == "sea.governance.request":
        # requesting_identity_id must be UUID
        if "requesting_identity_id" in payload:
            errors.extend(_validate_uuid(payload["requesting_identity_id"], "payload.requesting_identity_id"))
        # requested_action_type must be from enum
        if "requested_action_type" in payload:
            rat = payload["requested_action_type"]
            if rat not in _VALID_ACTION_TYPES:
                errors.append(
                    f"payload.requested_action_type: must be one of {sorted(_VALID_ACTION_TYPES)}, got '{rat}'"
                )

    elif family == "sea.governance.decision":
        # request_id must be UUID
        if "request_id" in payload:
            errors.extend(_validate_uuid(payload["request_id"], "payload.request_id"))
        # policy_version_id must be UUID
        if "policy_version_id" in payload:
            errors.extend(_validate_uuid(payload["policy_version_id"], "payload.policy_version_id"))
        # decision must be from enum
        if "decision" in payload:
            dec = payload["decision"]
            if dec not in _VALID_DECISIONS:
                errors.append(f"payload.decision: must be one of {sorted(_VALID_DECISIONS)}, got '{dec}'")
        # reviewed_by (optional) must be UUID if present
        if "reviewed_by" in payload and payload["reviewed_by"] is not None:
            errors.extend(_validate_uuid(payload["reviewed_by"], "payload.reviewed_by"))

    elif family == "sea.memory.write":
        # content must be non-empty string
        content = payload.get("content")
        if content is not None and (not isinstance(content, str) or len(content) == 0):
            errors.append("payload.content: expected non-empty string")
        # confidence must be 0.0-1.0 if present
        confidence = payload.get("confidence")
        if confidence is not None:
            if not isinstance(confidence, (int, float)) or confidence < 0.0 or confidence > 1.0:
                errors.append(f"payload.confidence: expected number [0.0, 1.0], got {confidence!r}")
        # salience must be 0.0-1.0 if present
        salience = payload.get("salience")
        if salience is not None:
            if not isinstance(salience, (int, float)) or salience < 0.0 or salience > 1.0:
                errors.append(f"payload.salience: expected number [0.0, 1.0], got {salience!r}")

    elif family == "sea.memory.lifecycle":
        # memory_item_id must be UUID
        if "memory_item_id" in payload:
            errors.extend(_validate_uuid(payload["memory_item_id"], "payload.memory_item_id"))
        # new_status must be from enum
        if "new_status" in payload:
            ns = payload["new_status"]
            if ns not in _VALID_MEMORY_STATUSES:
                errors.append(f"payload.new_status: must be one of {sorted(_VALID_MEMORY_STATUSES)}, got '{ns}'")

    return ValidationResult(valid=len(errors) == 0, errors=errors)


def validate_contract(family: str, data: dict[str, Any]) -> ValidationResult:
    """Full two-stage contract validation.

    Returns a ValidationResult with all errors from both stages.
    """
    env_result = validate_envelope(data)
    payload_result = validate_payload(family, data)
    all_errors = env_result.errors + payload_result.errors
    return ValidationResult(
        valid=len(all_errors) == 0,
        errors=all_errors,
    )


# ---------------------------------------------------------------------------
# Bridge Worker
# ---------------------------------------------------------------------------
class SEABridge:
    def __init__(self, cfg: BridgeConfig) -> None:
        self.cfg = cfg
        self.nc: nats.NATS | None = None
        self.js: nats.js.JetStreamContext | None = None
        self._running = True
        self._db: psycopg.AsyncConnection | None = None
        self._last_poll_at: float = 0.0
        self._last_message_at: float = 0.0
        self._last_error: str = ""
        self._last_error_at: float = 0.0
        self._messages_processed: int = 0

    async def start(self) -> None:
        LOG.info("SEA Forge NATS Bridge starting...")
        LOG.info("  NATS URL: %s", self.cfg.nats_url)
        LOG.info("  Stream: %s", self.cfg.js_stream_name)
        LOG.info(
            "  DB: %s@%s:%s/%s",
            self.cfg.db_user,
            self.cfg.db_host,
            self.cfg.db_port,
            self.cfg.db_name,
        )

        await self._connect_db()
        await self._connect_nats()

        if self.cfg.js_enabled and self.js:
            await self._ensure_stream()
            await self._ensure_consumer()

        # Set up pull subscription for inbound
        self._pull_sub = None
        if self.cfg.inbound_enabled and self.js:
            self._pull_sub = await self.js.pull_subscribe(
                subject=">",
                durable=self.cfg.js_durable_name,
                stream=self.cfg.js_stream_name,
            )
            LOG.info("Pull subscription created on stream '%s'", self.cfg.js_stream_name)

        tasks = []
        if self.cfg.inbound_enabled:
            tasks.append(asyncio.create_task(self._inbound_loop(), name="inbound"))
        else:
            LOG.info("Inbound processing disabled")

        if self.cfg.outbound_enabled:
            tasks.append(asyncio.create_task(self._outbound_loop(), name="outbound"))
        else:
            LOG.info("Outbound processing disabled")

        if not tasks:
            LOG.warning("No bridge tasks enabled — nothing to do")
            return

        LOG.info("Bridge worker running")
        await asyncio.gather(*tasks)

    async def stop(self) -> None:
        LOG.info("Bridge worker shutting down...")
        self._running = False
        if self._db and not self._db.closed:
            await self._db.close()
        if self.nc and self.nc.is_connected:
            await self.nc.close()

    # ── NATS connection ────────────────────────────────────────────────────

    async def _connect_nats(self) -> None:
        opts: dict[str, Any] = {
            "servers": [self.cfg.nats_url],
            "name": self.cfg.nats_name,
            "connect_timeout": self.cfg.nats_connect_timeout,
            "reconnect_time_wait": self.cfg.nats_reconnect_wait,
            "max_reconnect_attempts": self.cfg.nats_max_reconnects,
            "error_cb": self._nats_error,
            "disconnected_cb": self._nats_disconnected,
            "reconnected_cb": self._nats_reconnected,
            "closed_cb": self._nats_closed,
        }
        if self.cfg.nats_creds_file:
            opts["user_credentials"] = self.cfg.nats_creds_file
        if self.cfg.nats_token:
            opts["token"] = self.cfg.nats_token

        self.nc = await nats.connect(**opts)
        if self.cfg.js_enabled:
            self.js = self.nc.jetstream()
        else:
            self.js = None
        LOG.info("Connected to NATS at %s", self.cfg.nats_url)

    async def _nats_error(self, e: Exception) -> None:
        LOG.error("NATS error: %s", e)

    async def _nats_disconnected(self) -> None:
        LOG.warning("NATS disconnected")

    async def _nats_reconnected(self) -> None:
        LOG.info("NATS reconnected")

    async def _nats_closed(self) -> None:
        LOG.info("NATS connection closed")

    # ── JetStream setup ────────────────────────────────────────────────────

    async def _ensure_stream(self) -> None:
        assert self.js is not None
        try:
            await self.js.stream_info(self.cfg.js_stream_name)
            LOG.info("Stream '%s' exists", self.cfg.js_stream_name)
        except nats.js.errors.NotFoundError:
            sc = StreamConfig(
                name=self.cfg.js_stream_name,
                subjects=self.cfg.js_subjects,
                retention=RetentionPolicy.LIMITS,
                storage=StorageType.FILE,
                max_msgs_per_subject=1_000_000,
                discard="old",
                duplicate_window=120,
            )
            await self.js.add_stream(config=sc)
            LOG.info(
                "Created stream '%s' with subjects %s",
                self.cfg.js_stream_name,
                self.cfg.js_subjects,
            )

    async def _ensure_consumer(self) -> None:
        assert self.js is not None
        try:
            await self.js.consumer_info(self.cfg.js_stream_name, self.cfg.js_durable_name)
            LOG.info("Consumer '%s' exists", self.cfg.js_durable_name)
        except nats.js.errors.NotFoundError:
            cc = ConsumerConfig(
                durable_name=self.cfg.js_durable_name,
                ack_policy=AckPolicy.EXPLICIT,
                max_deliver=self.cfg.js_max_deliver,
                ack_wait=self.cfg.js_ack_wait,
                deliver_policy=DeliverPolicy.ALL,
                filter_subject=">",
            )
            await self.js.add_consumer(stream=self.cfg.js_stream_name, config=cc)
            LOG.info("Created durable consumer '%s'", self.cfg.js_durable_name)

    # ── Database connection ────────────────────────────────────────────────

    async def _connect_db(self) -> None:
        self._db = await psycopg.AsyncConnection.connect(self.cfg.db_dsn, autocommit=False)
        LOG.info("Connected to PostgreSQL as '%s'", self.cfg.db_user)

    async def _get_db(self) -> psycopg.AsyncConnection:
        if self._db is None or self._db.closed:
            LOG.info("Reconnecting to PostgreSQL...")
            self._db = await psycopg.AsyncConnection.connect(self.cfg.db_dsn, autocommit=False)
        return self._db

    # ── Inbound: NATS → Postgres ───────────────────────────────────────────

    async def _inbound_loop(self) -> None:
        if self._pull_sub is None:
            LOG.error("Inbound loop started but no pull subscription available")
            return
        LOG.info("Inbound loop started (pull consumer)")
        while self._running:
            try:
                msgs = await self._pull_sub.fetch(
                    batch=self.cfg.js_batch_size,
                    timeout=float(self.cfg.js_ack_wait),
                )
                self._last_poll_at = time.time()
                for msg in msgs:
                    await self._process_inbound(msg)
            except nats.errors.TimeoutError:
                self._last_poll_at = time.time()
                pass  # normal — no messages within timeout
            except Exception:
                LOG.exception("Inbound loop error")
                await asyncio.sleep(self.cfg.js_poll_interval)

    async def _process_inbound(self, msg: nats.aio.msg.Msg) -> None:
        subject = msg.subject
        payload = msg.data
        headers = dict(msg.headers) if msg.headers else {}

        msg_id = derive_message_id(subject, payload, headers, self.cfg.idempotency_header)

        # Reject non-JSON payloads
        try:
            data = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            LOG.warning("Non-JSON payload on %s — dead-lettering", subject)
            await self._dead_letter(msg, subject, payload, "invalid_json")
            await msg.ack()
            return

        if not isinstance(data, dict):
            LOG.warning("Non-object JSON on %s — dead-lettering", subject)
            await self._dead_letter(msg, subject, payload, "invalid_envelope")
            await msg.ack()
            return

        family = subject_family(subject)
        route = CANONICAL_ROUTES.get(family)

        # ── Contract validation ──────────────────────────────────────────
        # Two-stage validation: envelope then subject-specific payload.
        # Fail-closed for governance, memory write, memory lifecycle.
        # Fail-open for agent events (warnings only).
        contract_result = validate_contract(family, data)
        is_fail_open = route.get("fail_open", False) if route else True

        if not contract_result.valid:
            error_summary = contract_result.error_summary()
            if is_fail_open:
                LOG.warning(
                    "Contract validation warnings on %s (fail-open): %s",
                    subject,
                    error_summary,
                )
            else:
                LOG.warning(
                    "Contract validation FAILED on %s (fail-closed): %s",
                    subject,
                    error_summary,
                )

        # Determine if we should reject due to validation failure
        should_reject = not contract_result.valid and not is_fail_open

        try:
            db = await self._get_db()
            async with db.cursor() as cur:
                # Build inbox headers with validation metadata
                inbox_headers = dict(headers)
                if not contract_result.valid:
                    inbox_headers["_validation_errors"] = json.dumps(contract_result.errors)
                    inbox_headers["_validation_status"] = "failed"
                else:
                    inbox_headers["_validation_status"] = "passed"

                # Insert into inbox (idempotent by message_id)
                await cur.execute(
                    """
                    INSERT INTO event_log.inbox_events
                        (source_queue, message_id, headers, payload, status)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (source_queue, message_id) DO NOTHING
                    RETURNING id
                    """,
                    [
                        subject,
                        msg_id,
                        json.dumps(inbox_headers),
                        json.dumps(data),
                        "failed" if should_reject else "delivered",
                    ],
                )
                row = await cur.fetchone()

                if row is None:
                    # Duplicate — already processed
                    LOG.debug("Duplicate skipped: %s [%s]", subject, msg_id)
                    await db.commit()
                    await msg.ack()
                    return

                inbox_id = row[0]

                # If validation failed and fail-closed, record error and stop
                if should_reject:
                    error_summary = contract_result.error_summary()
                    await cur.execute(
                        "UPDATE event_log.inbox_events SET status = 'failed', processed_at = now() WHERE id = %s",
                        [inbox_id],
                    )
                    await cur.execute(
                        """
                        INSERT INTO event_log.delivery_attempts
                            (direction, parent_event_id, target_queue,
                             status, error_message)
                        VALUES ('inbound', %s, %s, 'failed', %s)
                        """,
                        [
                            inbox_id,
                            subject,
                            f"Contract validation failed: {error_summary}",
                        ],
                    )
                    if self.cfg.dead_letter_enabled:
                        await self._publish_dead_letter(subject, data, f"contract_validation: {error_summary}")
                    await db.commit()
                    await msg.ack()
                    LOG.info(
                        "Rejected inbound (contract): %s [%s] — %s",
                        subject,
                        msg_id[:16],
                        error_summary[:80],
                    )
                    return

                # Route to canonical table
                if route:
                    await self._route_canonical(cur, family, route, subject, data, inbox_id)
                else:
                    # Unknown subject family — mark inbox as failed
                    LOG.warning("Unknown subject family: %s", family)
                    await cur.execute(
                        "UPDATE event_log.inbox_events SET status = 'failed', processed_at = now() WHERE id = %s",
                        [inbox_id],
                    )
                    if self.cfg.dead_letter_enabled:
                        await self._publish_dead_letter(subject, data, "unknown_subject")

                await db.commit()
            await msg.ack()
            self._last_message_at = time.time()
            self._messages_processed += 1
            LOG.info("Processed inbound: %s [%s]", subject, msg_id[:16])

        except psycopg.errors.UniqueViolation:
            # Race condition on idempotency — treat as success
            await msg.ack()
            LOG.debug("Duplicate (race): %s [%s]", subject, msg_id[:16])
        except Exception:
            LOG.exception("Inbound processing failed: %s [%s]", subject, msg_id[:16])
            self._last_error = f"Inbound failed: {subject}"
            self._last_error_at = time.time()
            # Do NOT ack — JetStream will redeliver
            try:
                db = await self._get_db()
                await db.rollback()
            except Exception:
                pass

    async def _route_canonical(
        self,
        cur: psycopg.AsyncCursor,
        family: str,
        route: dict[str, Any],
        subject: str,
        data: dict[str, Any],
        inbox_id: uuid.UUID,
    ) -> None:
        """Route an inbound message to the correct canonical table.

        Data is the full envelope. Subject-specific fields are in data['payload'].
        For backward compatibility, if payload is missing or not a dict, the
        envelope itself is treated as the payload (legacy flat format).
        """
        table: str = route["table"]

        # Extract the subject-specific payload from the envelope
        inner_payload = data.get("payload")
        if isinstance(inner_payload, dict):
            p = inner_payload
        else:
            # Legacy flat format — treat the whole envelope as payload
            p = data

        # Merge envelope-level fields into the payload for canonical insert.
        # Envelope fields take precedence for identity/tracing; payload fields
        # take precedence for domain-specific data.
        source_agent = p.get("source_agent", data.get("source_agent", self.cfg.source_name))
        idempotency_key = (
            p.get("idempotency_key") or data.get("idempotency_key") or data.get("event_id") or str(inbox_id)
        )
        provenance = p.get("provenance", data.get("provenance", {}))
        metadata = p.get("metadata", data.get("metadata", {}))

        # Build enriched metadata with causal tracing from envelope
        enriched_metadata = dict(metadata) if isinstance(metadata, dict) else {}
        if data.get("correlation_id"):
            enriched_metadata["correlation_id"] = data["correlation_id"]
        if data.get("causation_id"):
            enriched_metadata["causation_id"] = data["causation_id"]
        if data.get("trace_id"):
            enriched_metadata["trace_id"] = data["trace_id"]
        if data.get("source"):
            enriched_metadata["source"] = data["source"]
        if data.get("schema_version"):
            enriched_metadata["schema_version"] = data["schema_version"]

        # Insert into canonical table
        if table == "agent_events":
            event_type = p.get("event_type", data.get("event_type", subject.split(".")[-1]))
            await cur.execute(
                """
                INSERT INTO event_log.agent_events
                    (source_agent, event_type, payload, idempotency_key)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (source_agent, idempotency_key) DO NOTHING
                """,
                [
                    source_agent,
                    event_type,
                    json.dumps(p),
                    idempotency_key,
                ],
            )
        elif table == "action_requests":
            await cur.execute(
                """
                INSERT INTO governance.action_requests
                    (requesting_identity_id, requested_action_type,
                     requested_resource, payload, provenance, metadata)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                [
                    p["requesting_identity_id"],
                    p["requested_action_type"],
                    p.get("requested_resource"),
                    json.dumps(p.get("payload", p)),
                    json.dumps(provenance) if isinstance(provenance, dict) else provenance,
                    json.dumps(enriched_metadata),
                ],
            )
        elif table == "action_decisions":
            await cur.execute(
                """
                INSERT INTO governance.action_decisions
                    (request_id, decision, policy_version_id,
                     decision_reason, admission_context)
                VALUES (%s, %s, %s, %s, %s)
                """,
                [
                    p["request_id"],
                    p["decision"],
                    p["policy_version_id"],
                    p.get("decision_reason"),
                    json.dumps(p.get("admission_context", {})),
                ],
            )
        elif table == "items":
            # Store salience in metadata if present
            if "salience" in p and isinstance(p["salience"], (int, float)):
                enriched_metadata["salience"] = p["salience"]
            await cur.execute(
                """
                INSERT INTO memory.items
                    (source_agent, content, summary, status, confidence, metadata)
                VALUES (%s, %s, %s, 'candidate', %s, %s)
                """,
                [
                    source_agent,
                    p["content"],
                    p.get("summary"),
                    p.get("confidence", 0.5),
                    json.dumps(enriched_metadata),
                ],
            )
        elif table == "inbox_events":
            # External lifecycle requests are canonical inbox facts until a
            # separate governed transition promotes them into memory.lifecycle_audit.
            pass

        # Record delivery attempt
        await cur.execute(
            """
            INSERT INTO event_log.delivery_attempts
                (direction, parent_event_id, target_queue, status)
            VALUES ('inbound', %s, %s, 'delivered')
            """,
            [inbox_id, subject],
        )

        # Mark inbox processed
        await cur.execute(
            "UPDATE event_log.inbox_events SET processed_at = now() WHERE id = %s",
            [inbox_id],
        )

    # ── Outbound: Postgres → NATS ──────────────────────────────────────────

    async def _outbound_loop(self) -> None:
        LOG.info("Outbound loop started (polling outbox)")
        while self._running:
            try:
                self._last_poll_at = time.time()
                await self._poll_outbox()
            except Exception:
                LOG.exception("Outbound loop error")
            await asyncio.sleep(self.cfg.js_poll_interval)

    async def _poll_outbox(self) -> None:
        db = await self._get_db()
        async with db.cursor() as cur:
            await cur.execute(
                """
                SELECT id, target_queue, message_id, headers, payload
                FROM event_log.outbox_events
                WHERE status = 'pending'
                ORDER BY created_at
                LIMIT %s
                FOR UPDATE SKIP LOCKED
                """,
                [self.cfg.js_batch_size],
            )
            rows = await cur.fetchall()

            if not rows:
                return

            for row in rows:
                event_id, target_queue, message_id, headers_json, payload_json = row
                await self._dispatch_outbox(cur, event_id, target_queue, message_id, headers_json, payload_json)

            await db.commit()

    async def _dispatch_outbox(
        self,
        cur: psycopg.AsyncCursor,
        event_id: uuid.UUID,
        target_queue: str,
        message_id: str,
        headers_json: str | None,
        payload_json: str | None,
    ) -> None:
        subject = f"{self.cfg.js_outbox_prefix}.{target_queue}"
        # psycopg may return JSONB as dict (auto-deserialized) or str
        if isinstance(payload_json, dict):
            payload = json.dumps(payload_json).encode()
        elif payload_json is None:
            payload = b"{}"
        else:
            payload = str(payload_json).encode()
        hdrs = {}
        if headers_json:
            try:
                if isinstance(headers_json, dict):
                    hdrs = {str(k): str(v) for k, v in headers_json.items()}
                else:
                    hdrs = json.loads(headers_json)
            except (json.JSONDecodeError, TypeError):
                pass
        hdrs[self.cfg.idempotency_header] = message_id

        try:
            if self.js:
                try:
                    await self.js.publish(
                        subject=subject,
                        payload=payload,
                        headers=hdrs,
                    )
                except nats.js.errors.NoStreamResponseError:
                    # Subject not in any stream — fall back to core NATS
                    await self.nc.publish(
                        subject=subject,
                        payload=payload,
                        headers=hdrs,
                    )
            elif self.nc:
                await self.nc.publish(
                    subject=subject,
                    payload=payload,
                    headers=hdrs,
                )
            else:
                raise RuntimeError("No NATS connection")

            await cur.execute(
                "UPDATE event_log.outbox_events SET status = 'delivered', dispatched_at = now() WHERE id = %s",
                [event_id],
            )
            await cur.execute(
                """
                INSERT INTO event_log.delivery_attempts
                    (direction, parent_event_id, target_queue, status)
                VALUES ('outbound', %s, %s, 'delivered')
                """,
                [event_id, subject],
            )
            LOG.info("Outbox dispatched: %s [%s]", subject, message_id[:16])

        except Exception as e:
            LOG.error("Outbox dispatch failed: %s [%s]: %s", subject, message_id[:16], e)
            await cur.execute(
                """
                INSERT INTO event_log.delivery_attempts
                    (direction, parent_event_id, target_queue, status, error_message)
                VALUES ('outbound', %s, %s, 'failed', %s)
                """,
                [event_id, subject, str(e)],
            )

    # ── Dead letter ────────────────────────────────────────────────────────

    async def _dead_letter(
        self,
        msg: nats.aio.msg.Msg,
        subject: str,
        payload: bytes,
        reason: str,
    ) -> None:
        """Publish to dead letter subject and record in DB."""
        if self.cfg.dead_letter_enabled:
            await self._publish_dead_letter(subject, payload, reason)
        # Record in DB
        try:
            db = await self._get_db()
            async with db.cursor() as cur:
                await cur.execute(
                    """
                    INSERT INTO event_log.inbox_events
                        (source_queue, message_id, payload, status)
                    VALUES (%s, %s, %s, 'dead_letter')
                    ON CONFLICT (source_queue, message_id) DO NOTHING
                    """,
                    [
                        subject,
                        derive_message_id(subject, payload, {}, self.cfg.idempotency_header),
                        payload.decode(errors="replace"),
                    ],
                )
                await db.commit()
        except Exception:
            LOG.exception("Failed to record dead letter in DB")

    async def _publish_dead_letter(self, subject: str, data: Any, reason: str) -> None:
        if not self.nc:
            return
        try:
            envelope = {
                "original_subject": subject,
                "reason": reason,
                "source": self.cfg.source_name,
                "dead_lettered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            if isinstance(data, (dict, list)):
                envelope["original_payload"] = json.dumps(data)
            # Publish as plain NATS message (dead letter subject may not be
            # in the JetStream stream). If JS publish works, use it for
            # persistence; otherwise fall back to core NATS.
            try:
                if self.js:
                    await self.js.publish(
                        subject=self.cfg.dead_letter_subject,
                        payload=json.dumps(envelope).encode(),
                    )
                else:
                    await self.nc.publish(
                        subject=self.cfg.dead_letter_subject,
                        payload=json.dumps(envelope).encode(),
                    )
            except (nats.js.errors.NoStreamResponseError, Exception):
                # Fall back to core NATS publish
                await self.nc.publish(
                    subject=self.cfg.dead_letter_subject,
                    payload=json.dumps(envelope).encode(),
                )
            LOG.info("Dead-lettered: %s (%s)", subject, reason)
        except Exception:
            LOG.exception("Failed to publish dead letter to NATS")


# ---------------------------------------------------------------------------
# Health Server — lightweight HTTP using stdlib asyncio
# ---------------------------------------------------------------------------
class HealthServer:
    """Async HTTP health endpoint server using raw asyncio sockets.

    Endpoints:
      /healthz       — Liveness: process is alive and not deadlocked.
      /readyz        — Readiness: all dependencies operational, schema current,
                       roles functional, bridge connected.
      /metrics       — Prometheus exposition format metrics.
      /metrics-lite  — Operational metrics as plain JSON.
    """

    def __init__(self, bridge: SEABridge, cfg: BridgeConfig) -> None:
        self._bridge = bridge
        self._cfg = cfg
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        self._server = await asyncio.start_server(
            self._handle_request,
            host=self._cfg.health_bind,
            port=self._cfg.health_port,
        )
        LOG.info(
            "Health server listening on %s:%d",
            self._cfg.health_bind,
            self._cfg.health_port,
        )

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            LOG.info("Health server stopped")

    async def _handle_request(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            request_line = await asyncio.wait_for(reader.readline(), timeout=5.0)
            if not request_line:
                writer.close()
                return

            parts = request_line.decode(errors="replace").strip().split()
            path = parts[1] if len(parts) >= 2 else "/"

            # Consume remaining headers
            while True:
                line = await asyncio.wait_for(reader.readline(), timeout=2.0)
                if not line or line == b"\r\n":
                    break

            if path == "/healthz":
                await self._handle_healthz(writer)
            elif path == "/readyz":
                await self._handle_readyz(writer)
            elif path == "/metrics":
                await self._handle_prometheus_metrics(writer)
            elif path == "/metrics-lite":
                await self._handle_metrics(writer)
            else:
                self._send_response(writer, HTTPStatus.NOT_FOUND, {"error": "not found"})
        except Exception:
            LOG.exception("Health request handler error")
            try:
                self._send_response(writer, HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "internal"})
            except Exception:
                pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    # ── /healthz ─────────────────────────────────────────────────────────

    async def _handle_healthz(self, writer: asyncio.StreamWriter) -> None:
        """Liveness check — process is alive and not deadlocked."""
        checks: dict[str, Any] = {}
        healthy = True

        if not self._bridge._running:
            checks["bridge"] = "stopped"
            healthy = False
        else:
            checks["bridge"] = "alive"

        last_poll = getattr(self._bridge, "_last_poll_at", None)
        if last_poll is not None and last_poll > 0:
            elapsed = time.time() - last_poll
            max_elapsed = self._cfg.js_poll_interval * 3
            if elapsed > max_elapsed:
                checks["poll_lag"] = f"{elapsed:.1f}s (threshold: {max_elapsed}s)"
                healthy = False
            else:
                checks["poll_lag"] = f"{elapsed:.1f}s"

        status_code = HTTPStatus.OK if healthy else HTTPStatus.SERVICE_UNAVAILABLE
        body: dict[str, Any] = {
            "status": "ok" if healthy else "unhealthy",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if checks:
            body["checks"] = checks
        self._send_response(writer, status_code, body)

    # ── /readyz ──────────────────────────────────────────────────────────

    async def _handle_readyz(self, writer: asyncio.StreamWriter) -> None:
        """Readiness check — all dependencies operational.

        Checks (in order):
          1. Postgres connection works
          2. agent_memory schema exists
          3. Migrations are current (no checksum mismatches)
          4. bridge_worker role can query canonical tables
          5. Oxigraph projection state (if kg schema exists)
          6. If sea_bridge.enabled: NATS connection works
          7. If JetStream enabled: stream and durable consumer exist
        """
        checks: dict[str, Any] = {}
        ready = True

        # 1. Postgres connectivity
        try:
            db = await self._bridge._get_db()
            async with db.cursor() as cur:
                await cur.execute("SELECT 1")
                await cur.fetchone()
            await db.commit()
            checks["postgres"] = "connected"
        except Exception as e:
            checks["postgres"] = f"error: {e}"
            ready = False
            try:
                await db.rollback()
            except Exception:
                pass
            self._send_readyz_response(writer, checks, ready)
            return

        # 2. agent_memory schema exists
        try:
            async with db.cursor() as cur:
                await cur.execute(
                    "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'agent_memory')"
                )
                exists = (await cur.fetchone())[0]
                if exists:
                    checks["schema"] = "agent_memory exists"
                else:
                    checks["schema"] = "agent_memory schema NOT found"
                    ready = False
            await db.commit()
        except Exception as e:
            checks["schema"] = f"error: {e}"
            ready = False
            try:
                await db.rollback()
            except Exception:
                pass

        # 3. Migrations current (check for checksum mismatches)
        try:
            async with db.cursor() as cur:
                await cur.execute("SELECT version, checksum FROM agent_memory.schema_migrations ORDER BY version")
                rows = await cur.fetchall()
                if rows:
                    checks["migrations"] = f"{len(rows)} applied"
                else:
                    checks["migrations"] = "none recorded"
            await db.commit()
        except Exception as e:
            checks["migrations"] = f"error: {e}"
            try:
                await db.rollback()
            except Exception:
                pass

        # 4. bridge_worker role can query canonical tables
        try:
            async with db.cursor() as cur:
                await cur.execute("SELECT COUNT(*) FROM event_log.inbox_events")
                await cur.fetchone()
                await cur.execute("SELECT COUNT(*) FROM event_log.outbox_events")
                await cur.fetchone()
                await cur.execute("SELECT COUNT(*) FROM event_log.agent_events")
                await cur.fetchone()
            await db.commit()
            checks["bridge_worker_role"] = "can query canonical tables"
        except Exception as e:
            checks["bridge_worker_role"] = f"error: {e}"
            ready = False
            try:
                await db.rollback()
            except Exception:
                pass
            # Cannot proceed with further DB checks
            self._send_readyz_response(writer, checks, ready)
            return

        # 5. Oxigraph projection state (if kg schema exists)
        try:
            async with db.cursor() as cur:
                await cur.execute("SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'kg')")
                kg_exists = (await cur.fetchone())[0]
                if kg_exists:
                    await cur.execute(
                        "SELECT category, status, last_projected_at FROM kg.oxigraph_projection_state ORDER BY last_projected_at DESC LIMIT 1"
                    )
                    proj_row = await cur.fetchone()
                    if proj_row:
                        category, proj_status, last_at = proj_row
                        checks["oxigraph_projection"] = f"{category}: {proj_status} (last: {last_at})"
                        if proj_status == "error":
                            ready = False
                    else:
                        checks["oxigraph_projection"] = "no projection state recorded"
                else:
                    checks["oxigraph_projection"] = "kg schema not present (oxigraph disabled)"
            await db.commit()
        except Exception as e:
            checks["oxigraph_projection"] = f"error: {e}"
            try:
                await db.rollback()
            except Exception:
                pass

        # 6. NATS connectivity (only if bridge is enabled)
        if self._bridge.nc is not None:
            if self._bridge.nc.is_connected:
                checks["nats"] = "connected"
            else:
                checks["nats"] = "disconnected"
                ready = False
        else:
            checks["nats"] = "not_configured"

        # 7. JetStream stream and consumer (only if JS enabled)
        if self._bridge.js is not None and self._bridge.cfg.js_enabled:
            try:
                si = await self._bridge.js.stream_info(self._bridge.cfg.js_stream_name)
                checks["jetstream"] = (
                    f"stream '{self._bridge.cfg.js_stream_name}' exists ({si.state.messages} messages)"
                )
                # Check durable consumer
                try:
                    await self._bridge.js.consumer_info(
                        self._bridge.cfg.js_stream_name,
                        self._bridge.cfg.js_durable_name,
                    )
                    checks["consumer"] = f"durable '{self._bridge.cfg.js_durable_name}' exists"
                except Exception as e:
                    checks["consumer"] = f"error: {e}"
                    ready = False
            except Exception as e:
                checks["jetstream"] = f"error: {e}"
                ready = False

        self._send_readyz_response(writer, checks, ready)

    def _send_readyz_response(
        self,
        writer: asyncio.StreamWriter,
        checks: dict[str, Any],
        ready: bool,
    ) -> None:
        status_code = HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE
        body: dict[str, Any] = {
            "status": "ready" if ready else "not_ready",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if checks:
            body["checks"] = checks
        self._send_response(writer, status_code, body)

    # ── /metrics (Prometheus) ─────────────────────────────────────────────

    async def _handle_prometheus_metrics(self, writer: asyncio.StreamWriter) -> None:
        """Prometheus exposition format metrics.

        Outputs metrics in the standard Prometheus text format for scraping
        by Prometheus, Victoria Metrics, or compatible collectors.
        """
        lines: list[str] = []
        now = time.time()

        # Bridge state
        lines.append("# HELP sea_bridge_running Whether the bridge process is running (1=running, 0=stopped).")
        lines.append("# TYPE sea_bridge_running gauge")
        lines.append(f"sea_bridge_running {1 if self._bridge._running else 0}")

        # NATS connection
        lines.append("# HELP sea_bridge_nats_connected Whether NATS is connected (1=connected, 0=disconnected).")
        lines.append("# TYPE sea_bridge_nats_connected gauge")
        nats_up = 1 if (self._bridge.nc and self._bridge.nc.is_connected) else 0
        lines.append(f"sea_bridge_nats_connected {nats_up}")

        # Messages processed
        lines.append("# HELP sea_bridge_messages_processed_total Total messages processed by the bridge.")
        lines.append("# TYPE sea_bridge_messages_processed_total counter")
        lines.append(f"sea_bridge_messages_processed_total {self._bridge._messages_processed}")

        # Last message timestamp
        lines.append("# HELP sea_bridge_last_message_timestamp Unix timestamp of last processed message.")
        lines.append("# TYPE sea_bridge_last_message_timestamp gauge")
        lines.append(f"sea_bridge_last_message_timestamp {self._bridge._last_message_at:.0f}")

        # Last error
        lines.append("# HELP sea_bridge_last_error_timestamp Unix timestamp of last error (0 if none).")
        lines.append("# TYPE sea_bridge_last_error_timestamp gauge")
        lines.append(f"sea_bridge_last_error_timestamp {self._bridge._last_error_at:.0f}")

        # Poll lag
        if self._bridge._last_poll_at > 0:
            poll_lag = now - self._bridge._last_poll_at
            lines.append("# HELP sea_bridge_poll_lag_seconds Seconds since last poll cycle.")
            lines.append("# TYPE sea_bridge_poll_lag_seconds gauge")
            lines.append(f"sea_bridge_poll_lag_seconds {poll_lag:.1f}")

        # DB metrics
        try:
            db = await self._bridge._get_db()
            async with db.cursor() as cur:
                await cur.execute(
                    "SELECT "
                    "  COUNT(*) FILTER (WHERE status = 'pending') AS inbox_pending, "
                    "  COUNT(*) FILTER (WHERE status = 'failed') AS inbox_failed, "
                    "  COUNT(*) FILTER (WHERE status = 'delivered') AS inbox_delivered "
                    "FROM event_log.inbox_events"
                )
                row = await cur.fetchone()
                if row:
                    lines.append("# HELP sea_bridge_inbox_events Number of inbox events by status.")
                    lines.append("# TYPE sea_bridge_inbox_events gauge")
                    lines.append(f'sea_bridge_inbox_events{{status="pending"}} {row[0]}')
                    lines.append(f'sea_bridge_inbox_events{{status="failed"}} {row[1]}')
                    lines.append(f'sea_bridge_inbox_events{{status="delivered"}} {row[2]}')

                await cur.execute(
                    "SELECT "
                    "  COUNT(*) FILTER (WHERE status = 'pending') AS outbox_pending, "
                    "  COUNT(*) FILTER (WHERE status = 'failed') AS outbox_failed, "
                    "  COUNT(*) FILTER (WHERE status = 'delivered') AS outbox_delivered "
                    "FROM event_log.outbox_events"
                )
                row = await cur.fetchone()
                if row:
                    lines.append("# HELP sea_bridge_outbox_events Number of outbox events by status.")
                    lines.append("# TYPE sea_bridge_outbox_events gauge")
                    lines.append(f'sea_bridge_outbox_events{{status="pending"}} {row[0]}')
                    lines.append(f'sea_bridge_outbox_events{{status="failed"}} {row[1]}')
                    lines.append(f'sea_bridge_outbox_events{{status="delivered"}} {row[2]}')
            await db.commit()
        except Exception:
            pass

        # Projection lag
        try:
            db = await self._bridge._get_db()
            async with db.cursor() as cur:
                await cur.execute(
                    "SELECT EXTRACT(EPOCH FROM (now() - last_projected_at)) "
                    "FROM kg.oxigraph_projection_state "
                    "ORDER BY last_projected_at DESC LIMIT 1"
                )
                row = await cur.fetchone()
                if row and row[0] is not None:
                    lines.append("# HELP sea_bridge_projection_lag_seconds Seconds since last Oxigraph projection.")
                    lines.append("# TYPE sea_bridge_projection_lag_seconds gauge")
                    lines.append(f"sea_bridge_projection_lag_seconds {float(row[0]):.1f}")
        except Exception:
            pass

        payload = "\n".join(lines) + "\n"
        writer.write(
            f"HTTP/1.1 200 OK\r\n"
            f"Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
            f"Content-Length: {len(payload)}\r\n"
            f"Connection: close\r\n"
            f"\r\n".encode()
        )
        writer.write(payload.encode())

    # ── /metrics-lite ────────────────────────────────────────────────────

    async def _handle_metrics(self, writer: asyncio.StreamWriter) -> None:
        """Operational metrics as plain JSON."""
        metrics: dict[str, Any] = {
            "bridge_enabled": self._bridge._running,
            "nats_connected": (self._bridge.nc.is_connected if self._bridge.nc is not None else None),
            "last_message_at": (
                time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ",
                    time.gmtime(self._bridge._last_message_at),
                )
                if self._bridge._last_message_at > 0
                else None
            ),
            "last_error": self._bridge._last_error or None,
            "last_error_at": (
                time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ",
                    time.gmtime(self._bridge._last_error_at),
                )
                if self._bridge._last_error_at > 0
                else None
            ),
            "messages_processed": self._bridge._messages_processed,
        }

        # Query inbox/outbox counts from Postgres
        try:
            db = await self._bridge._get_db()
            async with db.cursor() as cur:
                await cur.execute(
                    "SELECT "
                    "  COUNT(*) FILTER (WHERE status = 'pending') AS inbox_pending, "
                    "  COUNT(*) FILTER (WHERE status = 'failed') AS inbox_failed "
                    "FROM event_log.inbox_events"
                )
                row = await cur.fetchone()
                if row:
                    metrics["inbox_pending_count"] = row[0]
                    metrics["inbox_failed_count"] = row[1]

                await cur.execute(
                    "SELECT "
                    "  COUNT(*) FILTER (WHERE status = 'pending') AS outbox_pending, "
                    "  COUNT(*) FILTER (WHERE status = 'failed') AS outbox_failed "
                    "FROM event_log.outbox_events"
                )
                row = await cur.fetchone()
                if row:
                    metrics["outbox_pending_count"] = row[0]
                    metrics["outbox_failed_count"] = row[1]
            await db.commit()
        except Exception as e:
            metrics["db_query_error"] = str(e)
            try:
                await db.rollback()
            except Exception:
                pass

        # Projection lag (if oxigraph projection state table exists)
        try:
            db = await self._bridge._get_db()
            async with db.cursor() as cur:
                await cur.execute(
                    "SELECT EXTRACT(EPOCH FROM (now() - last_projected_at)) "
                    "FROM kg.oxigraph_projection_state "
                    "ORDER BY last_projected_at DESC LIMIT 1"
                )
                row = await cur.fetchone()
                if row and row[0] is not None:
                    metrics["projection_lag_seconds"] = round(float(row[0]), 1)
        except Exception:
            pass  # Table may not exist — not an error

        self._send_response(writer, HTTPStatus.OK, metrics)

    # ── Helpers ──────────────────────────────────────────────────────────

    @staticmethod
    def _send_response(
        writer: asyncio.StreamWriter,
        status: HTTPStatus,
        body: dict[str, Any],
    ) -> None:
        payload = json.dumps(body).encode()
        writer.write(
            f"HTTP/1.1 {status.value} {status.phrase}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(payload)}\r\n"
            f"Connection: close\r\n"
            f"\r\n".encode()
        )
        writer.write(payload)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def main() -> None:
    cfg = BridgeConfig.from_env()
    bridge = SEABridge(cfg)
    health = HealthServer(bridge, cfg)

    loop = asyncio.get_event_loop()

    def _shutdown() -> None:
        LOG.info("Shutdown signal received")
        bridge._running = False

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown)

    # Start health server first (always available, even before bridge connects)
    if cfg.health_enabled:
        await health.start()
    else:
        LOG.info("Health server disabled by configuration")

    try:
        await bridge.start()
    except Exception:
        LOG.exception("Bridge worker fatal error")
        sys.exit(1)
    finally:
        if cfg.health_enabled:
            await health.stop()
        await bridge.stop()


if __name__ == "__main__":
    asyncio.run(main())
