#!/usr/bin/env bash
# smoke_sea_bridge.sh — End-to-end smoke test for the SEA Forge NATS bridge
#
# Publishes messages to NATS, waits for the bridge to ingest them, then
# verifies the data landed in the correct PostgreSQL canonical tables and
# that the health endpoint reports readiness.
#
# Non-destructive: only INSERTs test data. Does not DROP, TRUNCATE, or
# ALTER anything. Test rows are tagged with a smoke_idempotency_key prefix
# so they can be identified and cleaned up manually if desired.
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed (reason printed to stderr)
#
# Environment variables (all required unless noted):
#   NATS_URL        NATS server URL               (e.g. nats://127.0.0.1:4222)
#   PGHOST          PostgreSQL host                (e.g. 127.0.0.1)
#   PGPORT          PostgreSQL port                (e.g. 5432)
#   PGDATABASE      Database name                  (e.g. agent_memory)
#   PGUSER          PostgreSQL user                (e.g. bridge_worker)
#   PGPASSWORD      PostgreSQL password
#   HEALTH_URL      Bridge health base URL         (e.g. http://127.0.0.1:8099)
#
# Optional:
#   SMOKE_WAIT      Seconds to wait for ingestion  (default: 5)
#   PG_SUPERUSER    If set, used for identity setup (default: same as PGUSER)
#   PG_SUPERPASSWORD  Password for PG_SUPERUSER
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

SMOKE_WAIT="${SMOKE_WAIT:-5}"
SMOKE_PREFIX="smoke-$(date +%s)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAILED=0
FAILURES=()

# ── Helpers ────────────────────────────────────────────────────────────────

log() { printf "[INFO]  %s\n" "$*"; }
warn() { printf "[WARN]  %s\n" "$*" >&2; }
fail() {
	FAILURES+=("$*")
	FAILED=1
}

psql_run() {
	PGPASSWORD="${_PGPASS}" psql \
		-h "${PGHOST}" -p "${PGPORT}" -d "${PGDATABASE}" \
		-U "${_PGUSER}" -t -A "$@"
}

# ── Step 1: Validate required tools ───────────────────────────────────────

log "Step 1: Checking required tools"

have_nats=true
if ! command -v nats >/dev/null 2>&1; then
	warn "nats CLI not found — NATS publish steps will be skipped"
	warn "Install: https://github.com/nats-io/natscli"
	have_nats=false
fi

for tool in psql jq curl; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		fail "Required tool not found: ${tool}"
	fi
done

if [ "${FAILED}" -eq 1 ]; then
	echo "FAIL: missing required tools"
	for f in "${FAILURES[@]}"; do printf "  - %s\n" "${f}" >&2; done
	exit 1
fi

log "  psql:  $(psql --version | head -1)"
log "  jq:    $(jq --version)"
log "  curl:  $(curl --version | head -1)"
if [ "${have_nats}" = true ]; then
	log "  nats:  $(nats --version 2>&1 || echo 'available')"
else
	log "  nats:  (not installed — publish steps skipped)"
fi

# ── Step 2: Validate environment variables ─────────────────────────────────

log "Step 2: Checking environment variables"

for var in NATS_URL PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD HEALTH_URL; do
	if [ -z "${!var:-}" ]; then
		fail "Environment variable not set: ${var}"
	fi
done

if [ "${FAILED}" -eq 1 ]; then
	echo "FAIL: missing environment variables"
	for f in "${FAILURES[@]}"; do printf "  - %s\n" "${f}" >&2; done
	exit 1
fi

log "  NATS_URL    = ${NATS_URL}"
log "  PGHOST      = ${PGHOST}"
log "  PGPORT      = ${PGPORT}"
log "  PGDATABASE  = ${PGDATABASE}"
# shellcheck disable=SC2153
log "  PGUSER      = ${PGUSER}"
log "  HEALTH_URL  = ${HEALTH_URL}"
log "  SMOKE_WAIT  = ${SMOKE_WAIT}s"

# Use superuser credentials if provided (for identity setup), otherwise
# fall back to the regular user. The script never requires superuser for
# queries — only for INSERT into governance.identities if the regular user
# lacks access.
_PGUSER="${PG_SUPERUSER:-${PGUSER}}"
_PGPASS="${PG_SUPERPASSWORD:-${PGPASSWORD}}"

# ── Step 3: Set up test identity ──────────────────────────────────────────

# governance.action_requests has a FK to governance.identities.
# Create a smoke-test identity so the governance request can succeed.
# This is a non-destructive INSERT — it does not affect existing data.

log "Step 3: Ensuring smoke-test identity exists"

TEST_IDENTITY_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
TEST_IDENTITY_ID="$(echo "${TEST_IDENTITY_ID}" | tr '[:upper:]' '[:lower:]')"

# Try to insert the identity. If it already exists or the user lacks
# permission, that is fine — we will detect the problem at query time.
psql_run -c "
    INSERT INTO governance.identities (identity_id, identity_type, display_name, status, metadata)
    VALUES ('${TEST_IDENTITY_ID}', 'agent', 'smoke-test-agent', 'active',
            '{\"source\": \"smoke_sea_bridge.sh\", \"prefix\": \"${SMOKE_PREFIX}\"}')
    ON CONFLICT (identity_id) DO NOTHING
" 2>/dev/null || warn "Could not insert test identity (may need PG_SUPERUSER)"

# ── Step 4: Publish sea.agent.event.test ───────────────────────────────────

AGENT_EVENT_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
AGENT_EVENT_ID="$(echo "${AGENT_EVENT_ID}" | tr '[:upper:]' '[:lower:]')"

AGENT_PAYLOAD="$(jq -n \
	--arg id "${AGENT_EVENT_ID}" \
	--arg ts "${TIMESTAMP}" \
	--arg prefix "${SMOKE_PREFIX}" \
	'{
        schema_version: "v1",
        event_id: $id,
        source: "sea-forge",
        source_agent: ($prefix + "-agent"),
        event_type: "smoke_test",
        occurred_at: $ts,
        payload: {
            test: true,
            smoke_prefix: $prefix,
            description: "smoke_sea_bridge.sh agent event"
        }
    }')"

if [ "${have_nats}" = true ]; then
	log "Step 4: Publishing sea.agent.event.smoke.test"
	if nats pub "sea.agent.event.smoke.test" "${AGENT_PAYLOAD}" \
		--server="${NATS_URL}" \
		--header="Nats-Msg-Id:${SMOKE_PREFIX}-agent" \
		2>/dev/null; then
		log "  published (event_id=${AGENT_EVENT_ID})"
	else
		warn "  nats publish failed — is the server reachable?"
	fi
else
	log "Step 4: SKIPPED (nats CLI not available)"
fi

# ── Step 5: Publish sea.governance.request.tool_call ───────────────────────

GOV_EVENT_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
GOV_EVENT_ID="$(echo "${GOV_EVENT_ID}" | tr '[:upper:]' '[:lower:]')"

GOV_PAYLOAD="$(jq -n \
	--arg id "${GOV_EVENT_ID}" \
	--arg ts "${TIMESTAMP}" \
	--arg prefix "${SMOKE_PREFIX}" \
	--arg identity "${TEST_IDENTITY_ID}" \
	'{
        schema_version: "v1",
        event_id: $id,
        source: "sea-forge",
        source_agent: ($prefix + "-gov"),
        occurred_at: $ts,
        payload: {
            requesting_identity_id: $identity,
            requested_action_type: "tool_call",
            requested_resource: "smoke-test://verify-bridge",
            payload: {
                test: true,
                smoke_prefix: $prefix,
                description: "smoke_sea_bridge.sh governance request"
            }
        }
    }')"

if [ "${have_nats}" = true ]; then
	log "Step 5: Publishing sea.governance.request.tool_call"
	if nats pub "sea.governance.request.tool_call" "${GOV_PAYLOAD}" \
		--server="${NATS_URL}" \
		--header="Nats-Msg-Id:${SMOKE_PREFIX}-gov" \
		2>/dev/null; then
		log "  published (event_id=${GOV_EVENT_ID})"
	else
		warn "  nats publish failed — is the server reachable?"
	fi
else
	log "Step 5: SKIPPED (nats CLI not available)"
fi

# ── Step 6: Wait for ingestion ────────────────────────────────────────────

log "Step 6: Waiting ${SMOKE_WAIT}s for bridge ingestion"
sleep "${SMOKE_WAIT}"

# ── Step 7: Query canonical tables ────────────────────────────────────────

# Switch to regular user for queries (matches bridge_worker scope)
_PGPASS="${PGPASSWORD}"
_PGUSER="${PGUSER}"

log "Step 7: Querying canonical tables"

# 7a. event_log.inbox_events
log "  7a. event_log.inbox_events"
INBOX_COUNT="$(psql_run -c "
    SELECT COUNT(*)
    FROM event_log.inbox_events
    WHERE message_id LIKE '${SMOKE_PREFIX}%'
" 2>/dev/null || echo "0")"

if [ "${INBOX_COUNT}" -ge 1 ] 2>/dev/null; then
	log "    PASS: ${INBOX_COUNT} inbox row(s) found"
else
	# If nats was not available, this is expected
	if [ "${have_nats}" = true ]; then
		fail "inbox_events: expected >= 1 row with prefix ${SMOKE_PREFIX}, got ${INBOX_COUNT:-0}"
		log "    FAIL: no inbox rows found"
	else
		log "    SKIP: nats CLI not available — inbox check skipped"
	fi
fi

# 7b. event_log.agent_events
log "  7b. event_log.agent_events"
AGENT_COUNT="$(psql_run -c "
    SELECT COUNT(*)
    FROM event_log.agent_events
    WHERE source_agent = '${SMOKE_PREFIX}-agent'
" 2>/dev/null || echo "0")"

if [ "${AGENT_COUNT}" -ge 1 ] 2>/dev/null; then
	log "    PASS: ${AGENT_COUNT} agent_event row(s) found"

	# Show the row for debugging
	psql_run -c "
        SELECT id, source_agent, event_type, payload
        FROM event_log.agent_events
        WHERE source_agent = '${SMOKE_PREFIX}-agent'
        ORDER BY created_at DESC LIMIT 1
    " 2>/dev/null | while IFS= read -r line; do
		[ -n "${line}" ] && log "    row: ${line}"
	done
else
	if [ "${have_nats}" = true ]; then
		fail "agent_events: expected >= 1 row with source_agent=${SMOKE_PREFIX}-agent, got ${AGENT_COUNT:-0}"
		log "    FAIL: no agent_event rows found"
	else
		log "    SKIP: nats CLI not available — agent_events check skipped"
	fi
fi

# 7c. governance.action_requests
log "  7c. governance.action_requests"
GOV_COUNT="$(psql_run -c "
    SELECT COUNT(*)
    FROM governance.action_requests
    WHERE requesting_identity_id = '${TEST_IDENTITY_ID}'
      AND requested_action_type = 'tool_call'
      AND metadata::text LIKE '%${SMOKE_PREFIX}%'
" 2>/dev/null || echo "0")"

if [ "${GOV_COUNT}" -ge 1 ] 2>/dev/null; then
	log "    PASS: ${GOV_COUNT} action_request row(s) found"

	psql_run -c "
        SELECT request_id, requesting_identity_id, requested_action_type, requested_resource
        FROM governance.action_requests
        WHERE requesting_identity_id = '${TEST_IDENTITY_ID}'
          AND requested_action_type = 'tool_call'
        ORDER BY occurred_at DESC LIMIT 1
    " 2>/dev/null | while IFS= read -r line; do
		[ -n "${line}" ] && log "    row: ${line}"
	done
else
	if [ "${have_nats}" = true ]; then
		fail "action_requests: expected >= 1 row for identity ${TEST_IDENTITY_ID}, got ${GOV_COUNT:-0}"
		log "    FAIL: no action_request rows found"
	else
		log "    SKIP: nats CLI not available — action_requests check skipped"
	fi
fi

# ── Step 8: Health check ──────────────────────────────────────────────────

log "Step 8: Calling /readyz"

READYZ_HTTP="$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}/readyz" 2>/dev/null || echo "000")"
READYZ_BODY="$(curl -s "${HEALTH_URL}/readyz" 2>/dev/null || echo '{"error":"curl failed"}')"

if [ "${READYZ_HTTP}" = "200" ]; then
	BRIDGE_STATUS="$(echo "${READYZ_BODY}" | jq -r '.status // "unknown"' 2>/dev/null || echo "parse-error")"
	log "    PASS: /readyz returned HTTP ${READYZ_HTTP} status=${BRIDGE_STATUS}"
elif [ "${READYZ_HTTP}" = "503" ]; then
	NOT_READY_CHECKS="$(echo "${READYZ_BODY}" | jq -r '.checks | to_entries[] | select(.value != "ok") | "\(.key): \(.value)"' 2>/dev/null || echo "could not parse checks")"
	fail "/readyz returned HTTP 503 (not ready)"
	log "    FAIL: /readyz returned 503"
	log "    failing checks:"
	echo "${NOT_READY_CHECKS}" | while IFS= read -r line; do
		[ -n "${line}" ] && log "      ${line}"
	done
else
	fail "/readyz returned HTTP ${READYZ_HTTP} (expected 200 or 503)"
	log "    FAIL: /readyz returned HTTP ${READYZ_HTTP}"
fi

# Also check /healthz for completeness
HEALTHZ_HTTP="$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}/healthz" 2>/dev/null || echo "000")"
if [ "${HEALTHZ_HTTP}" = "200" ]; then
	log "    /healthz: HTTP ${HEALTHZ_HTTP} (liveness OK)"
else
	warn "    /healthz: HTTP ${HEALTHZ_HTTP} (liveness check failed)"
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "${FAILED}" -eq 0 ]; then
	echo "PASS: all smoke tests passed"
	echo "  smoke_prefix:       ${SMOKE_PREFIX}"
	echo "  test_identity_id:   ${TEST_IDENTITY_ID}"
	echo "  agent_event_id:     ${AGENT_EVENT_ID}"
	echo "  gov_event_id:       ${GOV_EVENT_ID}"
else
	echo "FAIL: ${#FAILURES[@]} check(s) failed"
	for f in "${FAILURES[@]}"; do printf "  - %s\n" "${f}" >&2; done
	echo "  smoke_prefix:       ${SMOKE_PREFIX}"
	echo "  test_identity_id:   ${TEST_IDENTITY_ID}"
fi
echo "═══════════════════════════════════════════════════════════════"

# ── Cleanup hint ──────────────────────────────────────────────────────────

cat <<CLEANUP

To clean up smoke-test data:

    -- Remove test identity and dependent rows
    DELETE FROM governance.action_requests
      WHERE requesting_identity_id = '${TEST_IDENTITY_ID}';
    DELETE FROM governance.identities
      WHERE identity_id = '${TEST_IDENTITY_ID}';

    -- Remove test agent events
    DELETE FROM event_log.agent_events
      WHERE source_agent LIKE '${SMOKE_PREFIX}%';

    -- Remove test inbox rows
    DELETE FROM event_log.inbox_events
      WHERE message_id LIKE '${SMOKE_PREFIX}%';

CLEANUP

exit "${FAILED}"
