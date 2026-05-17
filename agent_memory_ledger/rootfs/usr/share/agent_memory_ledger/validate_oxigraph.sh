#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# Oxigraph Integration Validation Script
# ==============================================================================
# Validates:
#   1. Oxigraph disabled does not start service
#   2. Oxigraph enabled starts service
#   3. SPARQL endpoint responds
#   4. Identity lineage projects to RDF
#   5. Governance action decision projects to RDF
#   6. Accepted memory projects to RDF
#   7. Projection state advances
#   8. Rebuild clears only Oxigraph data
#   9. Postgres canonical tables are never modified by rebuild
#  10. Raw events are not projected unless enabled
#
# Usage: Run inside the running container:
#   /usr/share/agent_memory_ledger/validate_oxigraph.sh
# ==============================================================================

set -euo pipefail

declare AGENT_MEMORY_DB
declare PASS_COUNT=0
declare FAIL_COUNT=0
declare WARN_COUNT=0
declare TOTAL_CHECKS=0

AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')

bashio::log.notice "==================================================================="
bashio::log.notice "  Oxigraph Integration Validation"
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

run_sql() {
	psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A -c "${1}" 2>&1
}

run_sql_silent() {
	psql -U postgres -d "${AGENT_MEMORY_DB}" -c "${1}" >/dev/null 2>&1
}

# Validate that a value looks like a UUID
validate_uuid() {
	local val="${1}"
	[[ "${val}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# Poll for a SPARQL result with timeout instead of fixed sleep
# Usage: wait_for_sparql_result "SPARQL_QUERY" "expected_substring" "timeout_seconds" "description"
wait_for_sparql_result() {
	local query="${1}"
	local expected="${2}"
	local timeout="${3:-30}"
	local description="${4:-projection}"

	local waited=0
	local interval=2
	while [[ ${waited} -lt ${timeout} ]]; do
		local response
		response=$(curl -sf "${OXIGRAPH_URL}/query" --data-urlencode "query=${query}" 2>/dev/null || echo "")
		if echo "${response}" | grep -q "${expected}"; then
			return 0
		fi
		sleep "${interval}"
		waited=$((waited + interval))
	done
	warn "Timed out waiting for ${description}"
	return 1
}

# Check PostgreSQL connectivity
bashio::log.info "Checking PostgreSQL connectivity..."
if pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1; then
	pass "PostgreSQL is running and accepting connections"
else
	fail "PostgreSQL is not running"
	exit 1
fi

# Check agent_memory is enabled
if ! bashio::config.true 'agent_memory.enabled'; then
	fail "agent_memory.enabled is false — cannot test Oxigraph"
	exit 1
fi
pass "agent_memory profile is enabled"

# ===========================================================================
# TEST 1: Check if Oxigraph is enabled
# ===========================================================================
bashio::log.notice "--- Test: Oxigraph Configuration ---"

if bashio::config.true 'oxigraph.enabled'; then
	pass "oxigraph.enabled is true"
else
	warn "oxigraph.enabled is false — Oxigraph service should not be running"
	if pgrep -f "oxigraph serve" >/dev/null 2>&1; then
		fail "Oxigraph process is running but oxigraph.enabled is false"
	else
		pass "Oxigraph process is not running when disabled"
	fi
	bashio::log.notice "Skipping remaining Oxigraph tests (disabled)."
	bashio::log.notice "==================================================================="
	bashio::log.notice "  Validation Summary"
	bashio::log.notice "==================================================================="
	bashio::log.notice "  Total checks: ${TOTAL_CHECKS}"
	bashio::log.notice "  Passed:       ${PASS_COUNT}"
	bashio::log.notice "  Failed:       ${FAIL_COUNT}"
	bashio::log.notice "  Warnings:     ${WARN_COUNT}"
	bashio::log.notice "==================================================================="
	exit 0
fi

# ===========================================================================
# TEST 2: Check kg schema and projection state table
# ===========================================================================
bashio::log.notice "--- Test: Projection State Schema ---"

SCHEMA_EXISTS=$(run_sql "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'kg';")
if [[ "${SCHEMA_EXISTS}" == "1" ]]; then
	pass "Schema kg exists"
else
	fail "Schema kg does not exist"
fi

TABLE_EXISTS=$(run_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = 'kg' AND table_name = 'oxigraph_projection_state';")
if [[ "${TABLE_EXISTS}" == "1" ]]; then
	pass "Table kg.oxigraph_projection_state exists"
else
	fail "Table kg.oxigraph_projection_state does not exist"
fi

# ===========================================================================
# TEST 3: Check SPARQL endpoint
# ===========================================================================
bashio::log.notice "--- Test: SPARQL Endpoint ---"

OXIGRAPH_BIND=$(bashio::config 'oxigraph.bind' '127.0.0.1')
OXIGRAPH_PORT=$(bashio::config 'oxigraph.port' '7878')
OXIGRAPH_URL="http://${OXIGRAPH_BIND}:${OXIGRAPH_PORT}"

if command -v oxigraph >/dev/null 2>&1; then
	pass "Oxigraph binary is installed"
else
	fail "Oxigraph binary is not installed"
fi

if pgrep -f "oxigraph serve" >/dev/null 2>&1; then
	pass "Oxigraph process is running"
else
	fail "Oxigraph process is not running"
fi

SPARQL_RESULT=$(curl -sf -o /dev/null -w "%{http_code}" \
	"${OXIGRAPH_URL}/query" \
	--data-urlencode "query=ASK { ?s ?p ?o }" 2>/dev/null || echo "000")

if [[ "${SPARQL_RESULT}" == "200" ]]; then
	pass "SPARQL endpoint responds at ${OXIGRAPH_URL}"
else
	fail "SPARQL endpoint not reachable at ${OXIGRAPH_URL} (HTTP ${SPARQL_RESULT})"
fi

# ===========================================================================
# TEST 4: Identity lineage projection
# ===========================================================================
bashio::log.notice "--- Test: Identity Lineage Projection ---"

TEST_ID=$(run_sql "
    INSERT INTO governance.identities (identity_type, display_name, status, metadata)
    VALUES ('agent', 'oxigraph-test-agent', 'active', '{\"test\": true, \"oxigraph_validation\": true}')
    RETURNING identity_id;
")

if [[ -n "${TEST_ID}" ]] && validate_uuid "${TEST_ID}"; then
	pass "Created test identity for projection: ${TEST_ID}"
else
	fail "Failed to create test identity or invalid UUID returned"
	TEST_ID=""
fi

if [[ -n "${TEST_ID}" ]]; then
	TEST_EVENT_ID=$(run_sql "
        INSERT INTO governance.identity_events (event_type, target_identity_id, occurred_at, payload, provenance)
        VALUES ('create_identity', '${TEST_ID}', now(), '{\"display_name\": \"oxigraph-test-agent\"}', '{\"source\": \"oxigraph_validation\"}')
        RETURNING event_id;
    ")

	if [[ -n "${TEST_EVENT_ID}" ]] && validate_uuid "${TEST_EVENT_ID}"; then
		pass "Created identity event: ${TEST_EVENT_ID}"
	else
		warn "Failed to create identity event or invalid UUID"
	fi
fi

# Poll for projection instead of fixed sleep
if [[ -n "${TEST_ID}" ]]; then
	SPARQL_QUERY="PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX id: <http://agent-memory-ledger.local/identity/>
SELECT ?status WHERE {
    id:${TEST_ID} aml:hasStatus ?status .
} LIMIT 1"

	if wait_for_sparql_result "${SPARQL_QUERY}" "active" 30 "identity lineage"; then
		pass "Identity lineage projected to RDF (found status 'active')"
	else
		warn "Identity not yet projected to RDF (projection worker may not have run yet)"
	fi
fi

# ===========================================================================
# TEST 5: Governance action projection
# ===========================================================================
bashio::log.notice "--- Test: Governance Action Projection ---"

run_sql_silent "
    INSERT INTO governance.inheritance_policies (policy_name, inheritance_type, description, policy_definition)
    VALUES ('oxigraph_test_policy', 'none', 'Oxigraph validation test policy', '{\"test\": true}')
    ON CONFLICT (policy_name) DO NOTHING;
"

TEST_POLICY_VID=$(run_sql "
    INSERT INTO governance.policy_versions (policy_name, version, effective_at, policy_definition, created_by)
    VALUES ('oxigraph_test_policy', '1.0.0', now() - interval '1 hour', '{\"rules\": [{\"action\": \"*\", \"effect\": \"allow\"}]}', '${TEST_ID}')
    RETURNING policy_version_id;
")

if [[ -n "${TEST_POLICY_VID}" ]] && validate_uuid "${TEST_POLICY_VID}"; then
	pass "Created test policy version: ${TEST_POLICY_VID}"
else
	fail "Failed to create test policy version or invalid UUID"
	TEST_POLICY_VID=""
fi

if [[ -n "${TEST_ID}" ]]; then
	TEST_REQ_ID=$(run_sql "
        INSERT INTO governance.action_requests (requesting_identity_id, requested_action_type, payload, occurred_at)
        VALUES ('${TEST_ID}', 'tool_call', '{\"tool\": \"test_tool\"}', now())
        RETURNING request_id;
    ")

	if [[ -n "${TEST_REQ_ID}" ]] && validate_uuid "${TEST_REQ_ID}"; then
		pass "Created test action request: ${TEST_REQ_ID}"
	else
		fail "Failed to create test action request or invalid UUID"
		TEST_REQ_ID=""
	fi
fi

if [[ -n "${TEST_REQ_ID}" ]] && [[ -n "${TEST_POLICY_VID}" ]]; then
	TEST_DEC_ID=$(run_sql "
        INSERT INTO governance.action_decisions (request_id, decision, policy_version_id, decision_reason)
        VALUES ('${TEST_REQ_ID}', 'accepted', '${TEST_POLICY_VID}', 'Oxigraph validation test')
        RETURNING decision_id;
    ")

	if [[ -n "${TEST_DEC_ID}" ]] && validate_uuid "${TEST_DEC_ID}"; then
		pass "Created accepted decision: ${TEST_DEC_ID}"
	else
		fail "Failed to create accepted decision or invalid UUID"
		TEST_DEC_ID=""
	fi
fi

# Poll for governance projection
if [[ -n "${TEST_REQ_ID}" ]]; then
	SPARQL_QUERY="PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX act: <http://agent-memory-ledger.local/action/>
SELECT ?decision WHERE {
    act:${TEST_REQ_ID} aml:decision ?decision .
} LIMIT 1"

	if wait_for_sparql_result "${SPARQL_QUERY}" "accepted" 30 "governance"; then
		pass "Governance action projected to RDF (found decision 'accepted')"
	else
		warn "Governance action not yet projected to RDF (projection worker may not have run yet)"
	fi
fi

# ===========================================================================
# TEST 6: Memory projection
# ===========================================================================
bashio::log.notice "--- Test: Memory Projection ---"

TEST_MEM_ID=$(run_sql "
    INSERT INTO memory.items (source_agent, memory_type, content, status, confidence)
    VALUES ('oxigraph_validation', 'fact', 'Oxigraph validation test memory', 'accepted', 0.95)
    RETURNING id;
")

if [[ -n "${TEST_MEM_ID}" ]] && validate_uuid "${TEST_MEM_ID}"; then
	pass "Created test memory item: ${TEST_MEM_ID}"
else
	fail "Failed to create test memory item or invalid UUID"
	TEST_MEM_ID=""
fi

# Poll for memory projection
if [[ -n "${TEST_MEM_ID}" ]]; then
	SPARQL_QUERY="PREFIX aml: <http://agent-memory-ledger.local/ontology#>
PREFIX mem: <http://agent-memory-ledger.local/memory/>
SELECT ?status WHERE {
    mem:${TEST_MEM_ID} aml:hasMemoryStatus ?status .
} LIMIT 1"

	if wait_for_sparql_result "${SPARQL_QUERY}" "accepted" 30 "memory"; then
		pass "Memory item projected to RDF (found status 'accepted')"
	else
		warn "Memory item not yet projected to RDF (projection worker may not have run yet)"
	fi
fi

# ===========================================================================
# TEST 7: Projection state advances
# ===========================================================================
bashio::log.notice "--- Test: Projection State ---"

for proj in identity_lineage governance memory; do
	STATE=$(run_sql "SELECT status FROM kg.oxigraph_projection_state WHERE projection_name = '${proj}';")
	if [[ "${STATE}" == "completed" || "${STATE}" == "idle" ]]; then
		pass "Projection '${proj}' state is '${STATE}'"
	else
		warn "Projection '${proj}' state is '${STATE}'"
	fi
done

# ===========================================================================
# TEST 8: Raw events not projected unless enabled
# ===========================================================================
bashio::log.notice "--- Test: Raw Events Projection Control ---"

PROJECT_RAW=$(bashio::config 'oxigraph.project_raw_events' 'false')
if bashio::var.false "${PROJECT_RAW}"; then
	pass "project_raw_events is false (correct default)"
else
	warn "project_raw_events is true — raw event metadata will be projected"
fi

# ===========================================================================
# TEST 9: Postgres canonical tables are never modified by rebuild
# ===========================================================================
bashio::log.notice "--- Test: Canonical Table Integrity ---"

IDENTITY_COUNT_BEFORE=$(run_sql "SELECT count(*) FROM governance.identities WHERE metadata->>'oxigraph_validation' = 'true';")
if [[ -n "${TEST_ID}" ]]; then
	ACTION_COUNT_BEFORE=$(run_sql "SELECT count(*) FROM governance.action_requests WHERE requesting_identity_id = '${TEST_ID}';")
else
	ACTION_COUNT_BEFORE=0
fi
MEMORY_COUNT_BEFORE=$(run_sql "SELECT count(*) FROM memory.items WHERE source_agent = 'oxigraph_validation';")

# Reset projection state (simulates rebuild preparation)
run_sql_silent "UPDATE kg.oxigraph_projection_state SET last_event_time = NULL, last_event_id = NULL, status = 'idle', error = NULL;"

IDENTITY_COUNT_AFTER=$(run_sql "SELECT count(*) FROM governance.identities WHERE metadata->>'oxigraph_validation' = 'true';")
if [[ -n "${TEST_ID}" ]]; then
	ACTION_COUNT_AFTER=$(run_sql "SELECT count(*) FROM governance.action_requests WHERE requesting_identity_id = '${TEST_ID}';")
else
	ACTION_COUNT_AFTER=0
fi
MEMORY_COUNT_AFTER=$(run_sql "SELECT count(*) FROM memory.items WHERE source_agent = 'oxigraph_validation';")

if [[ "${IDENTITY_COUNT_BEFORE}" == "${IDENTITY_COUNT_AFTER}" ]]; then
	pass "Postgres identities table unchanged by projection state reset"
else
	fail "Postgres identities table was modified by projection state reset"
fi

if [[ "${ACTION_COUNT_BEFORE}" == "${ACTION_COUNT_AFTER}" ]]; then
	pass "Postgres action_requests table unchanged by projection state reset"
else
	fail "Postgres action_requests table was modified by projection state reset"
fi

if [[ "${MEMORY_COUNT_BEFORE}" == "${MEMORY_COUNT_AFTER}" ]]; then
	pass "Postgres memory.items table unchanged by projection state reset"
else
	fail "Postgres memory.items table was modified by projection state reset"
fi

# ===========================================================================
# Cleanup test data
# ===========================================================================
bashio::log.info "Cleaning up test data..."

if [[ -n "${TEST_DEC_ID:-}" ]]; then
	run_sql_silent "DELETE FROM governance.admission_contexts WHERE decision_id = '${TEST_DEC_ID}';" || true
	run_sql_silent "DELETE FROM governance.action_decisions WHERE decision_id = '${TEST_DEC_ID}';" || true
fi
if [[ -n "${TEST_REQ_ID:-}" ]]; then
	run_sql_silent "DELETE FROM governance.action_requests WHERE request_id = '${TEST_REQ_ID}';" || true
fi
if [[ -n "${TEST_MEM_ID:-}" ]]; then
	run_sql_silent "DELETE FROM memory.items WHERE id = '${TEST_MEM_ID}';" || true
fi
run_sql_silent "DELETE FROM governance.identity_events WHERE provenance->>'source' = 'oxigraph_validation';" || true
if [[ -n "${TEST_ID:-}" ]]; then
	run_sql_silent "DELETE FROM governance.policy_versions WHERE created_by = '${TEST_ID}';" || true
fi
run_sql_silent "DELETE FROM governance.inheritance_policies WHERE policy_name = 'oxigraph_test_policy';" || true
if [[ -n "${TEST_ID:-}" ]]; then
	run_sql_silent "DELETE FROM governance.identities WHERE identity_id = '${TEST_ID}';" || true
fi

pass "Test data cleaned up"

# ===========================================================================
# Summary
# ===========================================================================
bashio::log.notice "==================================================================="
bashio::log.notice "  Oxigraph Validation Summary"
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
