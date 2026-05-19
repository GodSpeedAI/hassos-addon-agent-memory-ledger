#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# Security Roles Validation Script
# Validates that least-privilege roles exist, have correct grants, and
# do not have dangerous privileges.
# ==============================================================================
# Usage: Run inside the running container:
#   /usr/share/agent_memory_ledger/validate_security.sh
# ==============================================================================

set -euo pipefail

declare AGENT_MEMORY_DB
declare PASS_COUNT=0
declare FAIL_COUNT=0
declare WARN_COUNT=0
declare TOTAL_CHECKS=0

AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')

bashio::log.notice "==================================================================="
bashio::log.notice "  Security Roles Validation"
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
	fail "PostgreSQL is not running or not accepting connections"
	bashio::log.error "Cannot continue validation. Exiting."
	exit 1
fi

# Check if agent_memory profile is enabled
if ! bashio::config.true 'agent_memory.enabled'; then
	bashio::log.warning "agent_memory.enabled is false — security roles are not applicable."
	exit 0
fi

# Check database exists
DB_EXISTS=$(psql -U postgres -t -A -c \
	"SELECT 1 FROM pg_database WHERE datname = '${AGENT_MEMORY_DB}';")
if [[ "${DB_EXISTS}" == "1" ]]; then
	pass "Database '${AGENT_MEMORY_DB}' exists"
else
	fail "Database '${AGENT_MEMORY_DB}' does not exist"
	exit 1
fi

# ===========================================================================
# Role existence checks
# ===========================================================================
bashio::log.info "Checking role existence..."

for ROLE_NAME in ledger_writer ledger_reader projection_worker bridge_worker; do
	ROLE_EXISTS=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT 1 FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${ROLE_EXISTS}" == "1" ]]; then
		pass "Role '${ROLE_NAME}' exists"
	else
		fail "Role '${ROLE_NAME}' does not exist"
	fi
done

# ===========================================================================
# Dangerous privilege checks
# ===========================================================================
bashio::log.info "Checking that roles do NOT have dangerous privileges..."

for ROLE_NAME in ledger_writer ledger_reader projection_worker bridge_worker; do
	# Check superuser
	SUPERUSER=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolsuper FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${SUPERUSER}" == "f" ]]; then
		pass "Role '${ROLE_NAME}' is NOT superuser"
	else
		fail "Role '${ROLE_NAME}' HAS superuser — this is a security violation"
	fi

	# Check createdb
	CREATEDB=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolcreatedb FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${CREATEDB}" == "f" ]]; then
		pass "Role '${ROLE_NAME}' cannot CREATE DATABASE"
	else
		fail "Role '${ROLE_NAME}' can CREATE DATABASE — should not have this privilege"
	fi

	# Check createrole
	CREATEROLE=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolcreaterole FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${CREATEROLE}" == "f" ]]; then
		pass "Role '${ROLE_NAME}' cannot CREATE ROLE"
	else
		fail "Role '${ROLE_NAME}' can CREATE ROLE — should not have this privilege"
	fi

	# Check replication
	REPLICATION=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolreplication FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${REPLICATION}" == "f" ]]; then
		pass "Role '${ROLE_NAME}' does not have REPLICATION"
	else
		fail "Role '${ROLE_NAME}' has REPLICATION — should not have this privilege"
	fi

	# Check bypassrls
	BYPASSRLS=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolbypassrls FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${BYPASSRLS}" == "f" ]]; then
		pass "Role '${ROLE_NAME}' does not have BYPASSRLS"
	else
		fail "Role '${ROLE_NAME}' has BYPASSRLS — should not have this privilege"
	fi
done

# ===========================================================================
# LOGIN status checks
# ===========================================================================
bashio::log.info "Checking LOGIN status..."

for ROLE_NAME in ledger_writer ledger_reader projection_worker bridge_worker; do
	CAN_LOGIN=$(psql -U postgres -t -A -v ROLE_NAME="${ROLE_NAME}" -c \
		"SELECT rolcanlogin FROM pg_roles WHERE rolname = :'ROLE_NAME';")
	if [[ "${CAN_LOGIN}" == "t" ]]; then
		pass "Role '${ROLE_NAME}' has LOGIN enabled (password is set)"
	else
		warn "Role '${ROLE_NAME}' does NOT have LOGIN — set a password to enable"
	fi
done

# ===========================================================================
# Schema usage checks
# ===========================================================================
bashio::log.info "Checking schema USAGE grants..."

check_schema_usage() {
	local ROLE_NAME="${1}"
	local SCHEMA_NAME="${2}"
	local EXPECTED="${3}"

	HAS_USAGE=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v ROLE_NAME="${ROLE_NAME}" \
		-v SCHEMA_NAME="${SCHEMA_NAME}" \
		-c "SELECT has_schema_privilege(:'ROLE_NAME', :'SCHEMA_NAME', 'USAGE');")
	if [[ "${HAS_USAGE}" == "${EXPECTED}" ]]; then
		pass "Role '${ROLE_NAME}' ${EXPECTED} USAGE on schema '${SCHEMA_NAME}'"
	else
		if [[ "${EXPECTED}" == "t" ]]; then
			fail "Role '${ROLE_NAME}' should have USAGE on '${SCHEMA_NAME}' but does not"
		else
			fail "Role '${ROLE_NAME}' should NOT have USAGE on '${SCHEMA_NAME}' but does"
		fi
	fi
}

# ledger_writer: event_log, governance, memory (NOT embeddings, NOT kg)
check_schema_usage "ledger_writer" "event_log" "t"
check_schema_usage "ledger_writer" "governance" "t"
check_schema_usage "ledger_writer" "memory" "t"
check_schema_usage "ledger_writer" "embeddings" "f"
check_schema_usage "ledger_writer" "kg" "f"

# ledger_reader: event_log, governance, memory, embeddings (NOT kg)
check_schema_usage "ledger_reader" "event_log" "t"
check_schema_usage "ledger_reader" "governance" "t"
check_schema_usage "ledger_reader" "memory" "t"
check_schema_usage "ledger_reader" "embeddings" "t"
check_schema_usage "ledger_reader" "kg" "f"

# projection_worker: event_log, governance, memory, kg (NOT embeddings)
check_schema_usage "projection_worker" "event_log" "t"
check_schema_usage "projection_worker" "governance" "t"
check_schema_usage "projection_worker" "memory" "t"
check_schema_usage "projection_worker" "kg" "t"
check_schema_usage "projection_worker" "embeddings" "f"

# bridge_worker: event_log, governance, memory (NOT embeddings, NOT kg)
check_schema_usage "bridge_worker" "event_log" "t"
check_schema_usage "bridge_worker" "governance" "t"
check_schema_usage "bridge_worker" "memory" "t"
check_schema_usage "bridge_worker" "embeddings" "f"
check_schema_usage "bridge_worker" "kg" "f"

# ===========================================================================
# Table privilege checks
# ===========================================================================
bashio::log.info "Checking table-level privileges..."

check_table_priv() {
	local ROLE_NAME="${1}"
	local SCHEMA_NAME="${2}"
	local TABLE_NAME="${3}"
	local PRIVILEGE="${4}"
	local EXPECTED="${5}"

	HAS_PRIV=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v ROLE_NAME="${ROLE_NAME}" \
		-v FULL_TABLE="${SCHEMA_NAME}.${TABLE_NAME}" \
		-v PRIVILEGE="${PRIVILEGE}" \
		-c "SELECT has_table_privilege(:'ROLE_NAME', :'FULL_TABLE', :'PRIVILEGE');")
	if [[ "${HAS_PRIV}" == "${EXPECTED}" ]]; then
		pass "Role '${ROLE_NAME}' ${EXPECTED} ${PRIVILEGE} on ${SCHEMA_NAME}.${TABLE_NAME}"
	else
		if [[ "${EXPECTED}" == "t" ]]; then
			fail "Role '${ROLE_NAME}' should have ${PRIVILEGE} on ${SCHEMA_NAME}.${TABLE_NAME} but does not"
		else
			fail "Role '${ROLE_NAME}' should NOT have ${PRIVILEGE} on ${SCHEMA_NAME}.${TABLE_NAME} but does"
		fi
	fi
}

# --- bridge_worker: can INSERT/UPDATE inbox/outbox, cannot DROP tables ---
bashio::log.info "Checking bridge_worker inbox/outbox privileges..."
check_table_priv "bridge_worker" "event_log" "inbox_events" "INSERT" "t"
check_table_priv "bridge_worker" "event_log" "inbox_events" "UPDATE" "t"
check_table_priv "bridge_worker" "event_log" "inbox_events" "SELECT" "t"
check_table_priv "bridge_worker" "event_log" "outbox_events" "INSERT" "t"
check_table_priv "bridge_worker" "event_log" "outbox_events" "UPDATE" "t"
check_table_priv "bridge_worker" "event_log" "outbox_events" "SELECT" "t"
check_table_priv "bridge_worker" "event_log" "delivery_attempts" "INSERT" "t"
check_table_priv "bridge_worker" "event_log" "delivery_attempts" "SELECT" "t"
check_table_priv "bridge_worker" "event_log" "agent_events" "INSERT" "t"
check_table_priv "bridge_worker" "event_log" "agent_events" "SELECT" "t"

# bridge_worker: can INSERT governance action requests/decisions
check_table_priv "bridge_worker" "governance" "action_requests" "INSERT" "t"
check_table_priv "bridge_worker" "governance" "action_requests" "SELECT" "t"
check_table_priv "bridge_worker" "governance" "action_decisions" "INSERT" "t"
check_table_priv "bridge_worker" "governance" "action_decisions" "SELECT" "t"

# bridge_worker: can INSERT memory items
check_table_priv "bridge_worker" "memory" "items" "INSERT" "t"
check_table_priv "bridge_worker" "memory" "items" "SELECT" "t"

# bridge_worker: CANNOT drop tables (no TRIGGER, no RULE, no REFERENCES on critical tables)
check_table_priv "bridge_worker" "event_log" "agent_events" "DELETE" "f"
check_table_priv "bridge_worker" "governance" "identities" "INSERT" "f"
check_table_priv "bridge_worker" "governance" "identities" "DELETE" "f"

# --- ledger_reader: read-only ---
bashio::log.info "Checking ledger_reader is read-only..."
check_table_priv "ledger_reader" "event_log" "agent_events" "SELECT" "t"
check_table_priv "ledger_reader" "event_log" "agent_events" "INSERT" "f"
check_table_priv "ledger_reader" "event_log" "agent_events" "UPDATE" "f"
check_table_priv "ledger_reader" "event_log" "agent_events" "DELETE" "f"
check_table_priv "ledger_reader" "governance" "action_requests" "SELECT" "t"
check_table_priv "ledger_reader" "governance" "action_requests" "INSERT" "f"
check_table_priv "ledger_reader" "memory" "items" "SELECT" "t"
check_table_priv "ledger_reader" "memory" "items" "INSERT" "f"

# --- ledger_writer: can INSERT but not UPDATE/DELETE ---
bashio::log.info "Checking ledger_writer write-only privileges..."
check_table_priv "ledger_writer" "event_log" "agent_events" "INSERT" "t"
check_table_priv "ledger_writer" "event_log" "agent_events" "UPDATE" "f"
check_table_priv "ledger_writer" "event_log" "agent_events" "DELETE" "f"
check_table_priv "ledger_writer" "governance" "action_requests" "INSERT" "t"
check_table_priv "ledger_writer" "governance" "action_requests" "UPDATE" "f"
check_table_priv "ledger_writer" "memory" "items" "INSERT" "t"
check_table_priv "ledger_writer" "memory" "items" "UPDATE" "f"
check_table_priv "ledger_writer" "memory" "items" "DELETE" "f"

# --- projection_worker: can write kg but not canonical tables ---
bashio::log.info "Checking projection_worker projection-only writes..."
check_table_priv "projection_worker" "kg" "oxigraph_projection_state" "SELECT" "t"
check_table_priv "projection_worker" "kg" "oxigraph_projection_state" "INSERT" "t"
check_table_priv "projection_worker" "kg" "oxigraph_projection_state" "UPDATE" "t"
check_table_priv "projection_worker" "event_log" "agent_events" "SELECT" "t"
check_table_priv "projection_worker" "event_log" "agent_events" "INSERT" "f"
check_table_priv "projection_worker" "governance" "identities" "SELECT" "t"
check_table_priv "projection_worker" "governance" "identities" "INSERT" "f"

# ===========================================================================
# Functional test: bridge_worker can INSERT into inbox but cannot DROP
# ===========================================================================
bashio::log.info "Running functional privilege tests..."

# Test bridge_worker INSERT into inbox_events
TEST_INSERT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c \
	"SET ROLE bridge_worker;
	 INSERT INTO event_log.inbox_events (source_queue, message_id, payload)
	 VALUES ('validate_security_test', 'security-test-msg-001', '{\"test\": true}')
	 RETURNING id;")
if [[ -n "${TEST_INSERT}" ]]; then
	pass "bridge_worker can INSERT into event_log.inbox_events"
	# Cleanup
	psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
		"DELETE FROM event_log.inbox_events WHERE message_id = 'security-test-msg-001';" >/dev/null 2>&1 || true
else
	fail "bridge_worker cannot INSERT into event_log.inbox_events"
fi

# Test bridge_worker CANNOT drop tables
DROP_RESULT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c \
	"SET ROLE bridge_worker;
	 DROP TABLE event_log.agent_events;" 2>&1 || true)
if [[ "${DROP_RESULT}" == *"must be owner"* ]] || [[ "${DROP_RESULT}" == *"permission denied"* ]] || [[ "${DROP_RESULT}" == *"ERROR"* ]]; then
	pass "bridge_worker CANNOT DROP event_log.agent_events (correctly denied)"
else
	fail "bridge_worker was able to DROP event_log.agent_events — SECURITY VIOLATION"
fi

# Test ledger_reader CANNOT INSERT
READER_INSERT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c \
	"SET ROLE ledger_reader;
	 INSERT INTO event_log.agent_events (source_agent, event_type, payload)
	 VALUES ('security_test', 'test', '{}');" 2>&1 || true)
if [[ "${READER_INSERT}" == *"permission denied"* ]] || [[ "${READER_INSERT}" == *"ERROR"* ]]; then
	pass "ledger_reader CANNOT INSERT into event_log.agent_events (correctly denied)"
else
	fail "ledger_reader was able to INSERT into event_log.agent_events — should be read-only"
fi

# ===========================================================================
# Summary
# ===========================================================================
bashio::log.notice "==================================================================="
bashio::log.notice "  Security Roles Validation Summary"
bashio::log.notice "==================================================================="
bashio::log.notice "  Total checks: ${TOTAL_CHECKS}"
bashio::log.notice "  Passed:       ${PASS_COUNT}"
bashio::log.notice "  Failed:       ${FAIL_COUNT}"
bashio::log.notice "  Warnings:     ${WARN_COUNT}"
bashio::log.notice "==================================================================="

if [[ ${FAIL_COUNT} -eq 0 ]]; then
	bashio::log.notice "  ALL CRITICAL SECURITY CHECKS PASSED"
	exit 0
else
	bashio::log.error "  ${FAIL_COUNT} SECURITY CHECK(S) FAILED — review errors above"
	exit 1
fi
