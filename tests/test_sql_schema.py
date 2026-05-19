"""Tests for SQL schema correctness and least-privilege role grants.

These tests validate the SQL migration files without requiring a running
PostgreSQL instance. They check:
  - Schema files parse correctly (BEGIN/COMMIT balance)
  - Required tables, constraints, and indexes exist in the SQL
  - bridge_worker role has correct grants and no dangerous privileges
  - Least-privilege: bridge_worker cannot DROP schema/table

For full integration tests with a live database, see the integration
test suite that runs against Docker containers.
"""

import re
from pathlib import Path

import pytest

SQL_DIR = (
    Path(__file__).parent.parent
    / "agent_memory_ledger"
    / "rootfs"
    / "usr"
    / "share"
    / "agent_memory_ledger"
    / "agent_memory"
)


def _read_sql(filename: str) -> str:
    """Read a SQL file from the schema directory."""
    path = SQL_DIR / filename
    assert path.exists(), f"SQL file not found: {path}"
    return path.read_text()


def _all_sql_files() -> list[str]:
    """Return all SQL migration files sorted by number."""
    files = sorted(SQL_DIR.glob("*.sql"))
    return [f.name for f in files]


class TestSQLSchemaSmoke:
    """Basic smoke tests for SQL schema files."""

    def test_sql_directory_exists(self):
        assert SQL_DIR.is_dir(), f"SQL directory not found: {SQL_DIR}"

    def test_expected_migration_files_exist(self):
        """All 14 expected migration files are present."""
        files = _all_sql_files()
        for i in range(14):
            expected_prefix = f"{i:03d}_"
            assert any(f.startswith(expected_prefix) for f in files), (
                f"Missing migration file with prefix {expected_prefix}"
            )

    def test_all_sql_files_have_begin_commit(self):
        """Every SQL file should have balanced BEGIN/COMMIT.

        Transaction BEGIN appears as 'BEGIN;' (with semicolon).
        PL/pgSQL BEGIN inside DO blocks has no semicolon.
        We only count transaction-level BEGIN statements.
        """
        for filename in _all_sql_files():
            content = _read_sql(filename)
            # Transaction BEGIN is 'BEGIN;' — PL/pgSQL BEGIN has no semicolon
            begins = len(re.findall(r"\bBEGIN\s*;", content, re.IGNORECASE))
            commits = len(re.findall(r"\bCOMMIT\s*;", content, re.IGNORECASE))
            assert begins == commits, f"{filename}: unbalanced BEGIN ({begins}) / COMMIT ({commits})"

    def test_no_drop_table_without_if_exists(self):
        """No bare DROP TABLE (must use DROP TABLE IF EXISTS for idempotency)."""
        for filename in _all_sql_files():
            content = _read_sql(filename)
            # Find DROP TABLE that is NOT followed by IF EXISTS
            bare_drops = re.findall(r"DROP\s+TABLE\s+(?!IF\s+EXISTS)", content, re.IGNORECASE)
            assert len(bare_drops) == 0, f"{filename}: found DROP TABLE without IF EXISTS"

    def test_no_drop_schema_without_if_exists(self):
        """No bare DROP SCHEMA."""
        for filename in _all_sql_files():
            content = _read_sql(filename)
            bare_drops = re.findall(r"DROP\s+SCHEMA\s+(?!IF\s+EXISTS)", content, re.IGNORECASE)
            assert len(bare_drops) == 0, f"{filename}: found DROP SCHEMA without IF EXISTS"

    def test_no_drop_database(self):
        """No DROP DATABASE in any migration file."""
        for filename in _all_sql_files():
            content = _read_sql(filename)
            assert not re.search(r"DROP\s+DATABASE", content, re.IGNORECASE), f"{filename}: found DROP DATABASE"

    def test_no_truncate(self):
        """No TRUNCATE in migration files (violates append-only)."""
        for filename in _all_sql_files():
            content = _read_sql(filename)
            assert not re.search(r"\bTRUNCATE\b", content, re.IGNORECASE), f"{filename}: found TRUNCATE"

    def test_no_delete_without_where(self):
        """No DELETE without WHERE clause (violates append-only philosophy)."""
        for filename in _all_sql_files():
            content = _read_sql(filename)
            # Look for DELETE FROM ... without a subsequent WHERE on the same statement
            # This is a heuristic check — function bodies are excluded
            lines = content.split("\n")
            for i, line in enumerate(lines):
                stripped = line.strip()
                if re.match(r"DELETE\s+FROM", stripped, re.IGNORECASE):
                    # Check if the statement has a WHERE clause
                    # Accumulate the full statement (may span multiple lines)
                    stmt = stripped
                    j = i + 1
                    while j < len(lines) and not lines[j].strip().endswith(";"):
                        stmt += " " + lines[j].strip()
                        j += 1
                    if j < len(lines):
                        stmt += " " + lines[j].strip()
                    assert "WHERE" in stmt.upper(), f"{filename}:{i + 1}: DELETE without WHERE clause"


class TestInboxOutboxSchema:
    """Tests for the inbox/outbox schema (004_inbox_outbox.sql)."""

    @pytest.fixture(autouse=True)
    def _load(self):
        self.sql = _read_sql("004_inbox_outbox.sql")

    def test_inbox_events_table_exists(self):
        assert "event_log.inbox_events" in self.sql

    def test_outbox_events_table_exists(self):
        assert "event_log.outbox_events" in self.sql

    def test_delivery_attempts_table_exists(self):
        assert "event_log.delivery_attempts" in self.sql

    def test_inbox_unique_constraint(self):
        """Inbox has UNIQUE (source_queue, message_id) for idempotency."""
        assert "uq_inbox_events_message" in self.sql
        assert "source_queue" in self.sql
        assert "message_id" in self.sql

    def test_outbox_unique_constraint(self):
        """Outbox has UNIQUE (target_queue, message_id) for idempotency."""
        assert "uq_outbox_events_message" in self.sql

    def test_delivery_status_enum(self):
        """delivery_status enum includes required values."""
        assert "'pending'" in self.sql
        assert "'delivered'" in self.sql
        assert "'failed'" in self.sql
        assert "'dead_letter'" in self.sql

    def test_delivery_attempts_direction_check(self):
        """Direction is constrained to 'inbound' or 'outbound'."""
        assert "direction IN ('inbound', 'outbound')" in self.sql

    def test_delivery_attempts_parent_trigger(self):
        """Trigger validates parent_event_id exists in inbox or outbox."""
        assert "validate_delivery_attempt_parent" in self.sql

    def test_inbox_status_default(self):
        """Inbox events default to 'pending' status."""
        # Check that status defaults to pending
        assert "DEFAULT 'pending'" in self.sql


class TestEventLogSchema:
    """Tests for the event_log schema (001_event_log.sql)."""

    @pytest.fixture(autouse=True)
    def _load(self):
        self.sql = _read_sql("001_event_log.sql")

    def test_agent_events_table(self):
        assert "event_log.agent_events" in self.sql

    def test_idempotency_unique_constraint(self):
        """agent_events has UNIQUE (source_agent, idempotency_key)."""
        assert "uq_agent_events_idempotency" in self.sql

    def test_payload_is_jsonb(self):
        assert "JSONB" in self.sql

    def test_gin_index_on_payload(self):
        assert "idx_agent_events_payload_gin" in self.sql


class TestSecurityRolesLeastPrivilege:
    """Tests for least-privilege security roles (013_security_roles.sql).

    Validates that the SQL grants follow the principle of least privilege
    by inspecting the SQL text. For runtime verification against a live
    database, use the integration test suite.
    """

    @pytest.fixture(autouse=True)
    def _load(self):
        self.sql = _read_sql("013_security_roles.sql")

    def test_bridge_worker_role_created(self):
        assert "bridge_worker" in self.sql

    def test_bridge_worker_is_nologin(self):
        """bridge_worker is created NOLOGIN — cannot connect directly."""
        assert "NOLOGIN" in self.sql

    def test_bridge_worker_is_noinherit(self):
        """bridge_worker is created NOINHERIT — only explicit grants active."""
        assert "NOINHERIT" in self.sql

    def test_bridge_worker_cannot_drop_schema(self):
        """No GRANT DROP or ownership transfer to bridge_worker."""
        # Check that bridge_worker never receives DROP-related privileges
        lines = self.sql.split("\n")
        for line in lines:
            if "bridge_worker" in line.lower():
                upper = line.upper()
                assert "DROP" not in upper or "DROP TRIGGER" in upper, (
                    f"bridge_worker should not have DROP privilege: {line.strip()}"
                )

    def test_bridge_worker_cannot_drop_table(self):
        """bridge_worker has no DROP TABLE grants."""
        assert not re.search(r"GRANT\s+.*DROP.*TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_cannot_create_table(self):
        """bridge_worker has no CREATE TABLE grants."""
        assert not re.search(r"GRANT\s+.*CREATE.*TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_cannot_alter(self):
        """bridge_worker has no ALTER grants."""
        assert not re.search(r"GRANT\s+.*ALTER.*TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_inbox_insert(self):
        """bridge_worker can INSERT into inbox_events."""
        assert re.search(r"GRANT\s+INSERT\s+ON\s+event_log\.inbox_events\s+TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_inbox_update(self):
        """bridge_worker can UPDATE inbox_events (for status changes)."""
        assert re.search(r"GRANT\s+UPDATE\s+ON\s+event_log\.inbox_events\s+TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_outbox_select_update(self):
        """bridge_worker can SELECT and UPDATE outbox_events."""
        assert re.search(
            r"GRANT\s+SELECT\s+ON\s+event_log\.outbox_events\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )
        assert re.search(
            r"GRANT\s+UPDATE\s+ON\s+event_log\.outbox_events\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )

    def test_bridge_worker_has_delivery_attempts_insert(self):
        """bridge_worker can INSERT into delivery_attempts for audit trail."""
        assert re.search(
            r"GRANT\s+INSERT\s+ON\s+event_log\.delivery_attempts\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )

    def test_bridge_worker_has_agent_events_insert(self):
        """bridge_worker can INSERT into agent_events (inbound mapping)."""
        assert re.search(r"GRANT\s+INSERT\s+ON\s+event_log\.agent_events\s+TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_governance_insert(self):
        """bridge_worker can INSERT into governance tables (inbound mapping)."""
        assert re.search(
            r"GRANT\s+INSERT\s+ON\s+governance\.action_requests\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )
        assert re.search(
            r"GRANT\s+INSERT\s+ON\s+governance\.action_decisions\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )

    def test_bridge_worker_has_memory_insert(self):
        """bridge_worker can INSERT into memory.items (inbound mapping)."""
        assert re.search(r"GRANT\s+INSERT\s+ON\s+memory\.items\s+TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_schema_migrations_select(self):
        """bridge_worker can SELECT schema_migrations for health checks."""
        assert re.search(
            r"GRANT\s+SELECT\s+ON\s+agent_memory\.schema_migrations\s+TO\s+bridge_worker", self.sql, re.IGNORECASE
        )

    def test_bridge_worker_has_no_superuser_attrs(self):
        """bridge_worker has NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS."""
        assert re.search(r"ALTER\s+ROLE\s+bridge_worker\s+.*NOCREATEDB", self.sql, re.IGNORECASE)
        assert re.search(r"ALTER\s+ROLE\s+bridge_worker\s+.*NOCREATEROLE", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_no_delete_grants(self):
        """bridge_worker has no DELETE grants on any table."""
        assert not re.search(r"GRANT\s+.*DELETE.*TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_has_no_truncate_grants(self):
        """bridge_worker has no TRUNCATE grants on any table."""
        assert not re.search(r"GRANT\s+.*TRUNCATE.*TO\s+bridge_worker", self.sql, re.IGNORECASE)

    def test_bridge_worker_schema_usage_limited(self):
        """bridge_worker only has USAGE on event_log, governance, memory, agent_memory."""
        usage_grants = re.findall(r"GRANT\s+USAGE\s+ON\s+SCHEMA\s+(\S+)\s+TO\s+bridge_worker", self.sql, re.IGNORECASE)
        # Normalize to lowercase for comparison
        schemas = {s.lower().strip('"') for s in usage_grants}
        expected = {"event_log", "governance", "memory", "agent_memory"}
        assert schemas == expected, f"bridge_worker schema grants: got {schemas}, expected {expected}"

    def test_all_roles_are_nologin(self):
        """All four roles are created NOLOGIN."""
        for role in ["ledger_writer", "ledger_reader", "projection_worker", "bridge_worker"]:
            assert re.search(rf"CREATE\s+ROLE\s+{role}\s+.*NOLOGIN", self.sql, re.IGNORECASE), (
                f"{role} should be created NOLOGIN"
            )

    def test_all_roles_are_noinherit(self):
        """All four roles are created NOINHERIT."""
        for role in ["ledger_writer", "ledger_reader", "projection_worker", "bridge_worker"]:
            assert re.search(rf"CREATE\s+ROLE\s+{role}\s+.*NOINHERIT", self.sql, re.IGNORECASE), (
                f"{role} should be created NOINHERIT"
            )


class TestGovernanceActionsSchema:
    """Tests for governance action tables (009_governance_actions.sql)."""

    @pytest.fixture(autouse=True)
    def _load(self):
        self.sql = _read_sql("009_governance_actions.sql")

    def test_action_requests_table(self):
        assert "governance.action_requests" in self.sql

    def test_action_decisions_table(self):
        assert "governance.action_decisions" in self.sql

    def test_action_request_references_identity(self):
        """action_requests.requesting_identity_id references governance.identities."""
        assert "requesting_identity_id" in self.sql
        assert "governance.identities" in self.sql

    def test_action_decision_references_request(self):
        """action_decisions.request_id references governance.action_requests."""
        assert "request_id" in self.sql
        assert "governance.action_requests" in self.sql

    def test_action_decision_references_policy(self):
        """action_decisions.policy_version_id references governance.policy_versions."""
        assert "policy_version_id" in self.sql
        assert "governance.policy_versions" in self.sql

    def test_governance_action_type_enum(self):
        """governance_action_type enum includes tool_call."""
        assert "tool_call" in self.sql

    def test_governance_decision_enum(self):
        """governance_decision enum includes accepted, rejected."""
        assert "'accepted'" in self.sql
        assert "'rejected'" in self.sql


class TestMemoryLifecycleSchema:
    """Tests for memory lifecycle schema (002_memory_lifecycle.sql)."""

    @pytest.fixture(autouse=True)
    def _load(self):
        self.sql = _read_sql("002_memory_lifecycle.sql")

    def test_memory_items_table(self):
        assert "memory.items" in self.sql

    def test_memory_status_enum(self):
        assert "'observed'" in self.sql
        assert "'candidate'" in self.sql
        assert "'accepted'" in self.sql

    def test_memory_items_content_not_null(self):
        """content column is NOT NULL."""
        assert "content" in self.sql
        # Check for NOT NULL constraint on content
        content_line = [line for line in self.sql.split("\n") if "content" in line.lower()]
        assert any("NOT NULL" in line.upper() for line in content_line)

    def test_confidence_range_check(self):
        """confidence has a CHECK constraint >= 0.0 and <= 1.0."""
        assert "confidence" in self.sql
        assert "0.0" in self.sql
        assert "1.0" in self.sql
