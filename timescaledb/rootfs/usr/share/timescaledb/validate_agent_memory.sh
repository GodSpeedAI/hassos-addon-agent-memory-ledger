#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: TimescaleDB
# Agent Memory Profile Validation Script
# Validates that all agent_memory schemas, tables, indexes, and extensions
# are correctly installed and functional.
# ==============================================================================
# Usage: Run inside the running container:
#   /usr/share/timescaledb/validate_agent_memory.sh
# ==============================================================================

set -euo pipefail

declare AGENT_MEMORY_DB
declare PASS_COUNT=0
declare FAIL_COUNT=0
declare WARN_COUNT=0
declare TOTAL_CHECKS=0

AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')

bashio::log.notice "==================================================================="
bashio::log.notice "  Agent Memory Profile Validation"
bashio::log.notice "==================================================================="

# Helper functions
pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.info "  ✅ PASS: ${1}"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.error "  ❌ FAIL: ${1}"
}

warn() {
	WARN_COUNT=$((WARN_COUNT + 1))
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	bashio::log.warning "  ⚠️  WARN: ${1}"
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
bashio::log.info "Checking agent_memory configuration..."
if bashio::config.true 'agent_memory.enabled'; then
	pass "agent_memory.enabled is true"
else
	fail "agent_memory.enabled is false — profile is not active"
	exit 1
fi

# Check database exists
bashio::log.info "Checking database '${AGENT_MEMORY_DB}'..."
DB_EXISTS=$(psql -U postgres -t -A -v AGENT_MEMORY_DB="${AGENT_MEMORY_DB}" -c \
	"SELECT 1 FROM pg_database WHERE datname = :'AGENT_MEMORY_DB';")
if [[ "${DB_EXISTS}" == "1" ]]; then
	pass "Database '${AGENT_MEMORY_DB}' exists"
else
	fail "Database '${AGENT_MEMORY_DB}' does not exist"
fi

# Function to check if a table exists
check_table() {
	local schema="${1}"
	local table="${2}"
	local result
	result=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v schema="${schema}" \
		-v table="${table}" \
		-c "SELECT 1 FROM information_schema.tables WHERE table_schema = :'schema' AND table_name = :'table';")
	if [[ "${result}" == "1" ]]; then
		pass "Table ${schema}.${table} exists"
	else
		fail "Table ${schema}.${table} does not exist"
	fi
}

# Function to check if an index exists
check_index() {
	local schema="${1}"
	local index_name="${2}"
	local result
	result=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v schema="${schema}" \
		-v index_name="${index_name}" \
		-c "SELECT 1 FROM pg_indexes WHERE schemaname = :'schema' AND indexname = :'index_name';")
	if [[ "${result}" == "1" ]]; then
		pass "Index ${index_name} exists in schema ${schema}"
	else
		warn "Index ${index_name} not found in schema ${schema}"
	fi
}

# Function to check if an extension is installed
check_extension() {
	local extname="${1}"
	local result
	result=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v extname="${extname}" \
		-c "SELECT extversion FROM pg_extension WHERE extname = :'extname';")
	if [[ -n "${result}" ]]; then
		pass "Extension ${extname} is installed (version: ${result})"
	else
		warn "Extension ${extname} is not installed in database '${AGENT_MEMORY_DB}'"
	fi
}

# Check schemas
bashio::log.info "Checking schemas..."
for schema in event_log memory embeddings; do
	SCHEMA_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v schema="${schema}" \
		-c "SELECT 1 FROM information_schema.schemata WHERE schema_name = :'schema';")
	if [[ "${SCHEMA_EXISTS}" == "1" ]]; then
		pass "Schema ${schema} exists"
	else
		fail "Schema ${schema} does not exist"
	fi
done

# Check extensions
bashio::log.info "Checking extensions..."
check_extension "timescaledb"
check_extension "ruvector"

# Check event_log tables
bashio::log.info "Checking event_log tables..."
check_table "event_log" "agent_events"
check_table "event_log" "inbox_events"
check_table "event_log" "outbox_events"
check_table "event_log" "delivery_attempts"

# Check event_log indexes
bashio::log.info "Checking event_log indexes..."
check_index "event_log" "idx_agent_events_payload_gin"
check_index "event_log" "idx_agent_events_created_at"
check_index "event_log" "idx_agent_events_source_agent"
check_index "event_log" "idx_agent_events_event_type"
check_index "event_log" "idx_inbox_events_status"
check_index "event_log" "idx_outbox_events_status"

# Check memory tables
bashio::log.info "Checking memory tables..."
check_table "memory" "items"
check_table "memory" "lifecycle_audit"

# Check memory indexes
bashio::log.info "Checking memory indexes..."
check_index "memory" "idx_memory_items_status"
check_index "memory" "idx_memory_items_source_agent"
check_index "memory" "idx_memory_items_created_at"
check_index "memory" "idx_memory_items_confidence"
check_index "memory" "idx_memory_items_metadata_gin"

# Check embeddings tables
bashio::log.info "Checking embeddings tables..."
check_table "embeddings" "memory_embeddings"

# Check embeddings indexes
bashio::log.info "Checking embeddings indexes..."
check_index "embeddings" "idx_memory_embeddings_created_at"
check_index "embeddings" "idx_memory_embeddings_model"

# Check ruhnsw index (only if ruvector is enabled)
if bashio::config.true 'agent_memory.enable_ruvector'; then
	bashio::log.info "Checking ruhnsw vector index..."
	check_index "embeddings" "idx_memory_embeddings_ruhnsw"
fi

# Check custom types
bashio::log.info "Checking custom types..."
for typename in memory_status delivery_status; do
	TYPE_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v typname="${typename}" \
		-c "SELECT 1 FROM pg_type WHERE typname = :'typname';")
	if [[ "${TYPE_EXISTS}" == "1" ]]; then
		pass "Type ${typename} exists"
	else
		fail "Type ${typename} does not exist"
	fi
done

# Check hypertables (if TimescaleDB is enabled)
if bashio::config.true 'agent_memory.enable_timescaledb'; then
	bashio::log.info "Checking hypertables..."
	for hypertable in "event_log.agent_events" "event_log.inbox_events" "event_log.outbox_events"; do
		HT_EXISTS=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
			-v HTNAME="${hypertable##*.}" \
			-c "SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = :'HTNAME';")
		if [[ "${HT_EXISTS}" == "1" ]]; then
			pass "Hypertable ${hypertable} is configured"
		else
			warn "Hypertable ${hypertable} is not configured (may not be converted yet)"
		fi
	done
fi

# Functional test: insert and query a test event
bashio::log.info "Running functional tests..."
if TEST_EVENT_ID=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c \
	"INSERT INTO event_log.agent_events (source_agent, event_type, payload, idempotency_key) VALUES ('validation_test', 'test_event', '{\"test\": true}', 'validation-test-key') RETURNING id;"); then
	TEST_EVENT_ID=$(echo "${TEST_EVENT_ID}" | tr -d '[:space:]')
else
	fail "Insert into event_log.agent_events failed"
	TEST_EVENT_ID=""
fi

if [[ -n "${TEST_EVENT_ID}" ]]; then
	pass "Insert into event_log.agent_events succeeded (id: ${TEST_EVENT_ID})"

	# Test idempotency constraint
	DUPLICATE_RESULT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c \
		"INSERT INTO event_log.agent_events (source_agent, event_type, payload, idempotency_key) VALUES ('validation_test', 'test_event', '{\"test\": true}', 'validation-test-key') ON CONFLICT (idempotency_key) DO NOTHING RETURNING id;")
	if [[ -z "${DUPLICATE_RESULT}" ]]; then
		pass "Idempotency constraint works (duplicate ignored)"
	else
		warn "Idempotency constraint may not be working"
	fi

	# Test read
	READ_RESULT=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
		-v TEST_EVENT_ID="${TEST_EVENT_ID}" \
		-c "SELECT source_agent FROM event_log.agent_events WHERE id = :'TEST_EVENT_ID';")
	if [[ "${READ_RESULT}" == "validation_test" ]]; then
		pass "Read from event_log.agent_events succeeded"
	else
		fail "Read from event_log.agent_events returned unexpected result"
	fi

	# Cleanup test data
	if psql -U postgres -d "${AGENT_MEMORY_DB}" \
		-v TEST_EVENT_ID="${TEST_EVENT_ID}" \
		-c "DELETE FROM event_log.agent_events WHERE id = :'TEST_EVENT_ID';" >/dev/null; then
		pass "Test data cleaned up"
	else
		rc=$?
		bashio::log.error "Cleanup failed for event ${TEST_EVENT_ID} in ${AGENT_MEMORY_DB}: exit ${rc}"
		fail "Test data cleanup failed"
	fi
fi

# Summary
bashio::log.notice "==================================================================="
bashio::log.notice "  Validation Summary"
bashio::log.notice "==================================================================="
bashio::log.notice "  Total checks: ${TOTAL_CHECKS}"
bashio::log.notice "  Passed:       ${PASS_COUNT}"
bashio::log.notice "  Failed:       ${FAIL_COUNT}"
bashio::log.notice "  Warnings:     ${WARN_COUNT}"
bashio::log.notice "==================================================================="

if [[ ${FAIL_COUNT} -eq 0 ]]; then
	bashio::log.notice "  ✅ ALL CRITICAL CHECKS PASSED"
	exit 0
else
	bashio::log.error "  ❌ ${FAIL_COUNT} CHECK(S) FAILED — review errors above"
	exit 1
fi
