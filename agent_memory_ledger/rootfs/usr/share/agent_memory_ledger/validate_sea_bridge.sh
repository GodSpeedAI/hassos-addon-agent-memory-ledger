#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# SEA Forge NATS JetStream Bridge Validation Script
# Validates bridge schema, connectivity, role grants, and health endpoints.
# ==============================================================================
# Usage: Run inside the running container:
#   /usr/share/agent_memory_ledger/validate_sea_bridge.sh
# ==============================================================================

set -euo pipefail

declare AGENT_MEMORY_DB
declare PASS_COUNT=0
declare FAIL_COUNT=0
declare WARN_COUNT=0
declare TOTAL_CHECKS=0

AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')

bashio::log.notice "==================================================================="
bashio::log.notice "  SEA Forge NATS JetStream Bridge Validation"
bashio::log.notice "==================================================================="

# Helper functions
pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.info "  PASS: ${1}"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.error "  FAIL: ${1}"
}

warn() {
	WARN_COUNT=$((WARN_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.warning "  WARN: ${1}"
}

# Check if PostgreSQL is running
bashio::log.info "Checking PostgreSQL connectivity..."
if pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1; then
	pass "PostgreSQL is running and accepting connections"
else
	fail "PostgreSQL is not running — cannot validate bridge schema"
	bashio::log.error "Aborting validation."
	exit 1
fi

# ── Configuration checks ──────────────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking bridge configuration..."

if bashio::config.true 'sea_bridge.enabled'; then
	pass "sea_bridge.enabled is true"
else
	warn "sea_bridge.enabled is false — bridge is disabled"
fi

if bashio::config.true 'agent_memory.enabled'; then
	pass "agent_memory.enabled is true"
else
	fail "agent_memory.enabled is false — bridge requires agent_memory"
fi

# ── Schema checks ─────────────────────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking bridge schema..."

# Check inbox_events table exists
INBOX_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'event_log' AND table_name = 'inbox_events')")
if [[ "${INBOX_EXISTS}" == "t" ]]; then
	pass "event_log.inbox_events table exists"
else
	fail "event_log.inbox_events table does not exist"
fi

# Check outbox_events table exists
OUTBOX_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'event_log' AND table_name = 'outbox_events')")
if [[ "${OUTBOX_EXISTS}" == "t" ]]; then
	pass "event_log.outbox_events table exists"
else
	fail "event_log.outbox_events table does not exist"
fi

# Check delivery_attempts table exists
DELIVERY_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'event_log' AND table_name = 'delivery_attempts')")
if [[ "${DELIVERY_EXISTS}" == "t" ]]; then
	pass "event_log.delivery_attempts table exists"
else
	fail "event_log.delivery_attempts table does not exist"
fi

# Check agent_events table exists
AGENT_EVENTS_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'event_log' AND table_name = 'agent_events')")
if [[ "${AGENT_EVENTS_EXISTS}" == "t" ]]; then
	pass "event_log.agent_events table exists"
else
	fail "event_log.agent_events table does not exist"
fi

# Check governance.action_requests table exists
ACTION_REQUESTS_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'governance' AND table_name = 'action_requests')")
if [[ "${ACTION_REQUESTS_EXISTS}" == "t" ]]; then
	pass "governance.action_requests table exists"
else
	fail "governance.action_requests table does not exist"
fi

# Check governance.action_decisions table exists
ACTION_DECISIONS_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'governance' AND table_name = 'action_decisions')")
if [[ "${ACTION_DECISIONS_EXISTS}" == "t" ]]; then
	pass "governance.action_decisions table exists"
else
	fail "governance.action_decisions table does not exist"
fi

# Check memory.items table exists
MEMORY_ITEMS_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'memory' AND table_name = 'items')")
if [[ "${MEMORY_ITEMS_EXISTS}" == "t" ]]; then
	pass "memory.items table exists"
else
	fail "memory.items table does not exist"
fi

# Check schema_migrations table exists
MIGRATIONS_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'agent_memory' AND table_name = 'schema_migrations')")
if [[ "${MIGRATIONS_EXISTS}" == "t" ]]; then
	pass "agent_memory.schema_migrations table exists"
else
	warn "agent_memory.schema_migrations table does not exist (pre-migration tracking)"
fi

# ── Unique constraint checks ──────────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking idempotency constraints..."

# Check inbox_events unique constraint on (source_queue, message_id)
INBOX_UQ=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT COUNT(*) FROM information_schema.table_constraints \
	WHERE table_schema = 'event_log' AND table_name = 'inbox_events' \
	AND constraint_type = 'UNIQUE'")
if [[ "${INBOX_UQ}" -ge 1 ]]; then
	pass "inbox_events has UNIQUE constraint (source_queue, message_id)"
else
	fail "inbox_events missing UNIQUE constraint — idempotency not enforced"
fi

# Check agent_events unique constraint on (source_agent, idempotency_key)
AGENT_UQ=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
	"SELECT COUNT(*) FROM information_schema.table_constraints \
	WHERE table_schema = 'event_log' AND table_name = 'agent_events' \
	AND constraint_type = 'UNIQUE'")
if [[ "${AGENT_UQ}" -ge 1 ]]; then
	pass "agent_events has UNIQUE constraint (source_agent, idempotency_key)"
else
	fail "agent_events missing UNIQUE constraint — idempotency not enforced"
fi

# ── bridge_worker role checks ─────────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking bridge_worker role grants..."

BRIDGE_WORKER_PASSWORD=$(bashio::config 'security.bridge_worker_password' '')
if [[ -n "${BRIDGE_WORKER_PASSWORD}" ]]; then
	# Check role exists
	ROLE_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
		"SELECT COUNT(*) FROM pg_roles WHERE rolname = 'bridge_worker'")
	if [[ "${ROLE_EXISTS}" -eq 1 ]]; then
		pass "bridge_worker role exists"
	else
		fail "bridge_worker role does not exist (password set but role not created)"
	fi

	# Check role is NOINHERIT
	ROLE_NOINHERIT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
		"SELECT rolinherit FROM pg_roles WHERE rolname = 'bridge_worker'")
	if [[ "${ROLE_NOINHERIT}" == "f" ]]; then
		pass "bridge_worker is NOINHERIT"
	else
		fail "bridge_worker should be NOINHERIT"
	fi

	# Check role is NOLOGIN (uses SET ROLE)
	ROLE_LOGIN=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
		"SELECT rolcanlogin FROM pg_roles WHERE rolname = 'bridge_worker'")
	if [[ "${ROLE_LOGIN}" == "f" ]]; then
		pass "bridge_worker is NOLOGIN (uses SET ROLE)"
	else
		warn "bridge_worker is LOGIN (expected NOLOGIN for SET ROLE pattern)"
	fi

	# Check bridge_worker can connect and SELECT from outbox
	if PGPASSWORD="${BRIDGE_WORKER_PASSWORD}" psql -U bridge_worker \
		-d "${AGENT_MEMORY_DB}" -h localhost -tAc \
		"SELECT COUNT(*) FROM event_log.outbox_events LIMIT 1" >/dev/null 2>&1; then
		pass "bridge_worker can SELECT from event_log.outbox_events"
	else
		warn "bridge_worker cannot SELECT from event_log.outbox_events"
	fi

	# Check bridge_worker can INSERT into inbox
	if PGPASSWORD="${BRIDGE_WORKER_PASSWORD}" psql -U bridge_worker \
		-d "${AGENT_MEMORY_DB}" -h localhost -tAc \
		"INSERT INTO event_log.inbox_events (source_queue, message_id, payload, status) \
		VALUES ('validate_test', 'validate_test_id', '{}', 'delivered') \
		ON CONFLICT (source_queue, message_id) DO NOTHING RETURNING id" >/dev/null 2>&1; then
		pass "bridge_worker can INSERT into event_log.inbox_events"
	else
		warn "bridge_worker cannot INSERT into event_log.inbox_events"
	fi

	# Clean up test data
	psql -U postgres -d "${AGENT_MEMORY_DB}" -tAc \
		"DELETE FROM event_log.inbox_events WHERE source_queue = 'validate_test'" >/dev/null 2>&1 || true

	# Check bridge_worker CANNOT DROP tables
	if PGPASSWORD="${BRIDGE_WORKER_PASSWORD}" psql -U bridge_worker \
		-d "${AGENT_MEMORY_DB}" -h localhost -tAc \
		"DROP TABLE event_log.inbox_events" >/dev/null 2>&1; then
		fail "bridge_worker CAN DROP tables — least privilege violated"
	else
		pass "bridge_worker cannot DROP tables (least privilege enforced)"
	fi

	# Check bridge_worker CANNOT INSERT into governance.identities
	if PGPASSWORD="${BRIDGE_WORKER_PASSWORD}" psql -U bridge_worker \
		-d "${AGENT_MEMORY_DB}" -h localhost -tAc \
		"INSERT INTO governance.identities (identity_id, name, identity_type) \
		VALUES ('00000000-0000-0000-0000-000000000000', 'test', 'agent')" >/dev/null 2>&1; then
		fail "bridge_worker CAN INSERT into governance.identities — least privilege violated"
	else
		pass "bridge_worker cannot INSERT into governance.identities (least privilege enforced)"
	fi
else
	warn "bridge_worker_password not set — skipping role validation"
fi

# ── Health endpoint checks ────────────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking health endpoints..."

HEALTH_BIND=$(bashio::config 'health.bind' '127.0.0.1')
HEALTH_PORT=$(bashio::config 'health.port' '8099')

# Check /healthz
if HEALTHZ_RESPONSE=$(wget -qO- --timeout=5 \
	"http://${HEALTH_BIND}:${HEALTH_PORT}/healthz" 2>&1); then
	pass "/healthz endpoint responded: ${HEALTHZ_RESPONSE}"
else
	warn "/healthz endpoint not responding (bridge may not be running): ${HEALTHZ_RESPONSE}"
fi

# Check /readyz
if READYZ_RESPONSE=$(wget -qO- --timeout=5 \
	"http://${HEALTH_BIND}:${HEALTH_PORT}/readyz" 2>&1); then
	pass "/readyz endpoint responded: ${READYZ_RESPONSE}"
else
	warn "/readyz endpoint not responding (bridge may not be running): ${READYZ_RESPONSE}"
fi

# ── Python bridge worker checks ───────────────────────────────────────────
bashio::log.info ""
bashio::log.info "Checking bridge worker installation..."

if command -v python3 >/dev/null 2>&1; then
	pass "python3 is installed"
else
	fail "python3 is not installed — bridge worker cannot run"
fi

if python3 -c "import nats" 2>/dev/null; then
	pass "nats-py is installed"
else
	fail "nats-py is not installed — bridge worker cannot connect to NATS"
fi

if python3 -c "import psycopg" 2>/dev/null; then
	pass "psycopg is installed"
else
	fail "psycopg is not installed — bridge worker cannot connect to PostgreSQL"
fi

if [[ -x /usr/bin/sea_nats_bridge.py ]]; then
	pass "sea_nats_bridge.py is executable"
else
	fail "sea_nats_bridge.py is not executable"
fi

# ── Summary ───────────────────────────────────────────────────────────────
bashio::log.info ""
bashio::log.notice "==================================================================="
bashio::log.notice "  Validation Summary"
bashio::log.notice "==================================================================="
bashio::log.notice "  Total checks: ${TOTAL_CHECKS}"
bashio::log.info "  Passed: ${PASS_COUNT}"
bashio::log.warning "  Warnings: ${WARN_COUNT}"
bashio::log.error "  Failed: ${FAIL_COUNT}"
bashio::log.notice "==================================================================="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
	bashio::log.error "Validation FAILED — ${FAIL_COUNT} check(s) did not pass"
	exit 1
fi

bashio::log.notice "Validation PASSED — all checks successful"
exit 0
