#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# Oxigraph RDF Projection Worker
# ==============================================================================
# Projects selected canonical records from Postgres into RDF triples
# and loads them into the Oxigraph SPARQL endpoint.
#
# IMPORTANT: Postgres is canonical. Oxigraph is a rebuildable projection.
# This script NEVER modifies Postgres canonical tables.
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
declare AGENT_MEMORY_DB
declare OXIGRAPH_BIND
declare OXIGRAPH_PORT
declare OXIGRAPH_URL
declare OXIGRAPH_DATA
declare BATCH_SIZE
declare MAX_INTERVAL
declare PROJECT_GOVERNANCE
declare PROJECT_IDENTITY_LINEAGE
declare PROJECT_MEMORY
declare PROJECT_RAW_EVENTS
declare REBUILD_ON_START

AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')
OXIGRAPH_BIND=$(bashio::config 'oxigraph.bind' '127.0.0.1')
OXIGRAPH_PORT=$(bashio::config 'oxigraph.port' '7878')
OXIGRAPH_URL="http://${OXIGRAPH_BIND}:${OXIGRAPH_PORT}"
OXIGRAPH_DATA=$(bashio::config 'oxigraph.data_dir' '/data/oxigraph')
BATCH_SIZE=$(bashio::config 'oxigraph.batch_size' '500')
MAX_INTERVAL=$(bashio::config 'oxigraph.max_projection_interval_seconds' '60')
PROJECT_GOVERNANCE=$(bashio::config 'oxigraph.project_governance' 'true')
PROJECT_IDENTITY_LINEAGE=$(bashio::config 'oxigraph.project_identity_lineage' 'true')
PROJECT_MEMORY=$(bashio::config 'oxigraph.project_memory' 'true')
PROJECT_RAW_EVENTS=$(bashio::config 'oxigraph.project_raw_events' 'false')
REBUILD_ON_START=$(bashio::config 'oxigraph.rebuild_on_start' 'false')

bashio::log.info "Oxigraph Projection: Using endpoint ${OXIGRAPH_URL} with data directory ${OXIGRAPH_DATA}"

# ---------------------------------------------------------------------------
# RDF Namespace Prefixes
# ---------------------------------------------------------------------------
readonly PREFIXES='@prefix aml: <http://agent-memory-ledger.local/ontology#> .
@prefix id: <http://agent-memory-ledger.local/identity/> .
@prefix evt: <http://agent-memory-ledger.local/event/> .
@prefix act: <http://agent-memory-ledger.local/action/> .
@prefix mem: <http://agent-memory-ledger.local/memory/> .
@prefix pol: <http://agent-memory-ledger.local/policy/> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
'

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

log_info() { bashio::log.info "Oxigraph Projection: ${1}"; }
log_warn() { bashio::log.warning "Oxigraph Projection: ${1}"; }
log_error() { bashio::log.error "Oxigraph Projection: ${1}"; }
log_notice() { bashio::log.notice "Oxigraph Projection: ${1}"; }

# Validate that a value looks like a safe identifier (letters, digits, underscore, hyphen)
validate_identifier() {
	local val="${1}"
	[[ "${val}" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Run SQL against the agent_memory database using psql -v for safe parameter binding
run_sql() {
	local query="${1}"
	shift
	psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A "$@" -c "${query}" 2>&1
}

run_sql_silent() {
	local query="${1}"
	shift
	psql -U postgres -d "${AGENT_MEMORY_DB}" "$@" -c "${query}" >/dev/null 2>&1
}

# Check if Oxigraph SPARQL endpoint is reachable
check_oxigraph_health() {
	curl -sf -o /dev/null "${OXIGRAPH_URL}/query" --data-urlencode "query=ASK { ?s ?p ?o }" 2>/dev/null
}

# Load Turtle RDF data into Oxigraph via the store API
# Uses --data-binary to POST the file contents directly, avoiding file:// URLs.
load_rdf_to_oxigraph() {
	local rdf_data="${1}"
	local graph="${2:-}"

	if [[ -z "${rdf_data}" ]]; then
		return 0
	fi

	# Write RDF to a temp file to avoid shell escaping issues
	local tmp_file
	tmp_file=$(mktemp /tmp/oxigraph_projection_XXXXXX.ttl)

	# Write prefixes + data
	echo "${PREFIXES}" >"${tmp_file}"
	echo "${rdf_data}" >>"${tmp_file}"

	local result
	if [[ -n "${graph}" ]]; then
		# POST to the named graph via the Oxigraph store API with graph parameter
		result=$(curl -sf -o /dev/null -w "%{http_code}" \
			-X POST \
			-H "Content-Type: application/turtle" \
			"${OXIGRAPH_URL}/store?graph=${graph}" \
			--data-binary @"${tmp_file}" 2>/dev/null || echo "000")
	else
		# POST to the default graph
		result=$(curl -sf -o /dev/null -w "%{http_code}" \
			-X POST \
			-H "Content-Type: application/turtle" \
			"${OXIGRAPH_URL}/store" \
			--data-binary @"${tmp_file}" 2>/dev/null || echo "000")
	fi

	rm -f "${tmp_file}"

	if [[ "${result}" == "200" || "${result}" == "201" || "${result}" == "204" ]]; then
		return 0
	else
		log_error "Failed to load RDF data. HTTP status: ${result}"
		return 1
	fi
}

# Update projection state in Postgres using psql -v for safe parameter binding
update_projection_state() {
	local projection_name="${1}"
	local status="${2}"
	local last_event_time="${3:-}"
	local last_event_id="${4:-}"
	local error_msg="${5:-}"

	# Validate projection_name to prevent injection
	if ! validate_identifier "${projection_name}"; then
		log_error "Invalid projection_name: ${projection_name}"
		return 1
	fi

	# Validate status to prevent injection
	if ! validate_identifier "${status}"; then
		log_error "Invalid projection status: ${status}"
		return 1
	fi

	# Build the SQL with psql variable bindings for safe interpolation
	local extra_args=()
	extra_args+=(-v projection_name="${projection_name}")
	extra_args+=(-v status="${status}")

	if [[ -n "${last_event_time}" ]]; then
		extra_args+=(-v last_event_time="${last_event_time}")
	else
		extra_args+=(-v last_event_time="NULL")
	fi

	if [[ -n "${last_event_id}" ]]; then
		extra_args+=(-v last_event_id="${last_event_id}")
	else
		extra_args+=(-v last_event_id="NULL")
	fi

	if [[ -n "${error_msg}" ]]; then
		extra_args+=(-v error_msg="${error_msg}")
	else
		extra_args+=(-v error_msg="NULL")
	fi

	run_sql_silent "
        INSERT INTO kg.oxigraph_projection_state (projection_name, last_event_time, last_event_id, status, error, last_projected_at)
        VALUES (:'projection_name',
                CASE WHEN :'last_event_time' = 'NULL' THEN NULL ELSE :'last_event_time'::timestamptz END,
                CASE WHEN :'last_event_id' = 'NULL' THEN NULL ELSE :'last_event_id'::uuid END,
                :'status',
                CASE WHEN :'error_msg' = 'NULL' THEN NULL ELSE :'error_msg' END,
                now())
        ON CONFLICT (projection_name) DO UPDATE SET
            last_event_time = EXCLUDED.last_event_time,
            last_event_id = EXCLUDED.last_event_id,
            status = EXCLUDED.status,
            error = EXCLUDED.error,
            last_projected_at = now();
    " "${extra_args[@]}"
}

# ---------------------------------------------------------------------------
# Projection: Identity Lineage
# ---------------------------------------------------------------------------
project_identity_lineage() {
	log_info "Projecting identity lineage..."

	local last_time
	last_time=$(run_sql "SELECT COALESCE(to_char(last_event_time, 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '1970-01-01T00:00:00Z') FROM kg.oxigraph_projection_state WHERE projection_name = 'identity_lineage';")

	update_projection_state "identity_lineage" "running" "" "" ""

	# Fetch identities created or changed since last projection
	# Uses psql -v for safe parameter binding of last_time
	local rdf_data
	rdf_data=$(run_sql "
        SELECT
            'id:' || identity_id || ' aml:hasType \"identity\" ;' || E'\n' ||
            '    aml:hasStatus \"' || status || '\" ;' || E'\n' ||
            '    aml:hasIdentityClass \"' || identity_type || '\" ;' || E'\n' ||
            CASE WHEN display_name IS NOT NULL
                THEN '    aml:displayName \"' || REPLACE(display_name, '\"', '\\\"') || '\" ;' || E'\n'
                ELSE '' END ||
            '    aml:createdAt \"' || to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime ;' || E'\n' ||
            CASE WHEN retired_at IS NOT NULL
                THEN '    aml:retiredAt \"' || to_char(retired_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime ;' || E'\n'
                ELSE '' END ||
            '    a aml:Identity .' || E'\n'
        FROM governance.identities
        WHERE created_at > :'last_time'::timestamptz
        ORDER BY created_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${rdf_data}" ]]; then
		if load_rdf_to_oxigraph "${rdf_data}" "http://agent-memory-ledger.local/graph/identities"; then
			local max_time
			max_time=$(run_sql "
                SELECT to_char(MAX(created_at), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
                FROM governance.identities
                WHERE created_at > :'last_time'::timestamptz;
            " -v last_time="${last_time}")
			local max_id
			max_id=$(run_sql "
                SELECT identity_id FROM governance.identities
                WHERE created_at = :'max_time'::timestamptz
                ORDER BY identity_id DESC LIMIT 1;
            " -v max_time="${max_time}")
			update_projection_state "identity_lineage" "completed" "${max_time}" "${max_id}" ""
			log_info "Identity lineage projection batch completed (up to ${max_time})"
		else
			update_projection_state "identity_lineage" "error" "" "" "Failed to load RDF to Oxigraph"
			log_error "Failed to load identity lineage RDF data"
			return 1
		fi
	else
		update_projection_state "identity_lineage" "completed" "" "" ""
		log_info "No new identity data to project"
	fi

	# Project lineage edges
	local lineage_data
	lineage_data=$(run_sql "
        SELECT
            'id:' || parent_identity_id || ' aml:parentIdentity id:' || child_identity_id || ' .' || E'\n' ||
            'id:' || child_identity_id || ' aml:childIdentity id:' || parent_identity_id || ' .' || E'\n' ||
            'id:' || child_identity_id || ' aml:lineageType \"' || relationship_type || '\" .' || E'\n'
        FROM governance.identity_lineage
        WHERE created_at > :'last_time'::timestamptz
        ORDER BY created_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${lineage_data}" ]]; then
		if load_rdf_to_oxigraph "${lineage_data}" "http://agent-memory-ledger.local/graph/lineage"; then
			log_info "Identity lineage edges projected"
		else
			log_warn "Failed to load lineage edge RDF data"
		fi
	fi

	# Project role bindings
	local role_data
	role_data=$(run_sql "
        SELECT
            'id:' || irb.identity_id || ' aml:boundToRole id:' || irb.role_id || ' .' || E'\n' ||
            CASE WHEN irb.unbound_at IS NULL
                THEN 'id:' || irb.identity_id || ' aml:hasActiveRole id:' || irb.role_id || ' .' || E'\n'
                ELSE '' END
        FROM governance.identity_role_bindings irb
        WHERE irb.bound_at > :'last_time'::timestamptz
        ORDER BY irb.bound_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${role_data}" ]]; then
		if load_rdf_to_oxigraph "${role_data}" "http://agent-memory-ledger.local/graph/roles"; then
			log_info "Role bindings projected"
		else
			log_warn "Failed to load role binding RDF data"
		fi
	fi
}

# ---------------------------------------------------------------------------
# Projection: Governance Actions
# ---------------------------------------------------------------------------
project_governance() {
	log_info "Projecting governance actions..."

	local last_time
	last_time=$(run_sql "SELECT COALESCE(to_char(last_event_time, 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '1970-01-01T00:00:00Z') FROM kg.oxigraph_projection_state WHERE projection_name = 'governance';")

	update_projection_state "governance" "running" "" "" ""

	# Project action requests with decisions
	local rdf_data
	rdf_data=$(run_sql "
        SELECT
            'act:' || ar.request_id || ' aml:hasType \"action_request\" ;' || E'\n' ||
            '    aml:actedBy id:' || ar.requesting_identity_id || ' ;' || E'\n' ||
            '    aml:requestedAction \"' || ar.requested_action_type || '\" ;' || E'\n' ||
            CASE WHEN ar.requested_resource IS NOT NULL
                THEN '    aml:targetResource \"' || REPLACE(ar.requested_resource, '\"', '\\\"') || '\" ;' || E'\n'
                ELSE '' END ||
            '    aml:observedAt \"' || to_char(ar.occurred_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime ;' || E'\n' ||
            CASE WHEN ad.decision_id IS NOT NULL
                THEN '    aml:decision \"' || ad.decision || '\" ;' || E'\n' ||
                     '    aml:governedByPolicy pol:' || ad.policy_version_id || ' ;' || E'\n' ||
                     CASE WHEN ad.decision_reason IS NOT NULL
                         THEN '    aml:decisionReason \"' || REPLACE(ad.decision_reason, '\"', '\\\"') || '\" ;' || E'\n'
                         ELSE '' END ||
                     '    aml:decidedAt \"' || to_char(ad.decided_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime ;' || E'\n'
                ELSE '' END ||
            '    a aml:ActionRequest .' || E'\n'
        FROM governance.action_requests ar
        LEFT JOIN governance.action_decisions ad ON ad.request_id = ar.request_id
        WHERE ar.occurred_at > :'last_time'::timestamptz
        ORDER BY ar.occurred_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${rdf_data}" ]]; then
		if load_rdf_to_oxigraph "${rdf_data}" "http://agent-memory-ledger.local/graph/governance"; then
			local max_time
			max_time=$(run_sql "
                SELECT to_char(MAX(occurred_at), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
                FROM governance.action_requests
                WHERE occurred_at > :'last_time'::timestamptz;
            " -v last_time="${last_time}")
			local max_id
			max_id=$(run_sql "
                SELECT request_id FROM governance.action_requests
                WHERE occurred_at = :'max_time'::timestamptz
                ORDER BY request_id DESC LIMIT 1;
            " -v max_time="${max_time}")
			update_projection_state "governance" "completed" "${max_time}" "${max_id}" ""
			log_info "Governance projection batch completed (up to ${max_time})"
		else
			update_projection_state "governance" "error" "" "" "Failed to load RDF to Oxigraph"
			log_error "Failed to load governance RDF data"
			return 1
		fi
	else
		update_projection_state "governance" "completed" "" "" ""
		log_info "No new governance data to project"
	fi
}

# ---------------------------------------------------------------------------
# Projection: Memory Lifecycle
# ---------------------------------------------------------------------------
project_memory() {
	log_info "Projecting memory lifecycle..."

	local last_time
	last_time=$(run_sql "SELECT COALESCE(to_char(last_event_time, 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '1970-01-01T00:00:00Z') FROM kg.oxigraph_projection_state WHERE projection_name = 'memory';")

	update_projection_state "memory" "running" "" "" ""

	local rdf_data
	rdf_data=$(run_sql "
        SELECT
            'mem:' || mi.id || ' aml:hasType \"memory_item\" ;' || E'\n' ||
            '    aml:hasMemoryStatus \"' || mi.status || '\" ;' || E'\n' ||
            '    aml:hasSourceAgent \"' || REPLACE(mi.source_agent, '\"', '\\\"') || '\" ;' || E'\n' ||
            '    aml:hasMemoryType \"' || REPLACE(mi.memory_type, '\"', '\\\"') || '\" ;' || E'\n' ||
            CASE WHEN mi.source_event_id IS NOT NULL
                THEN '    aml:sourceEvent evt:' || mi.source_event_id || ' ;' || E'\n'
                ELSE '' END ||
            '    aml:createdAt \"' || to_char(mi.created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime ;' || E'\n' ||
            CASE WHEN mi.confidence > 0
                THEN '    aml:hasConfidence \"' || mi.confidence || '\"^^xsd:float ;' || E'\n'
                ELSE '' END ||
            CASE WHEN me.id IS NOT NULL
                THEN '    aml:hasEmbedding true .' || E'\n'
                ELSE '    aml:hasEmbedding false .' || E'\n' END
        FROM memory.items mi
        LEFT JOIN embeddings.memory_embeddings me ON me.memory_item_id = mi.id
        WHERE mi.created_at > :'last_time'::timestamptz
        ORDER BY mi.created_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${rdf_data}" ]]; then
		if load_rdf_to_oxigraph "${rdf_data}" "http://agent-memory-ledger.local/graph/memory"; then
			local max_time
			max_time=$(run_sql "
                SELECT to_char(MAX(created_at), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
                FROM memory.items
                WHERE created_at > :'last_time'::timestamptz;
            " -v last_time="${last_time}")
			local max_id
			max_id=$(run_sql "
                SELECT id FROM memory.items
                WHERE created_at = :'max_time'::timestamptz
                ORDER BY id DESC LIMIT 1;
            " -v max_time="${max_time}")
			update_projection_state "memory" "completed" "${max_time}" "${max_id}" ""
			log_info "Memory projection batch completed (up to ${max_time})"
		else
			update_projection_state "memory" "error" "" "" "Failed to load RDF to Oxigraph"
			log_error "Failed to load memory RDF data"
			return 1
		fi
	else
		update_projection_state "memory" "completed" "" "" ""
		log_info "No new memory data to project"
	fi
}

# ---------------------------------------------------------------------------
# Projection: Raw Events (optional, default off)
# ---------------------------------------------------------------------------
project_raw_events() {
	log_info "Projecting raw event metadata..."

	local last_time
	last_time=$(run_sql "SELECT COALESCE(to_char(last_event_time, 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '1970-01-01T00:00:00Z') FROM kg.oxigraph_projection_state WHERE projection_name = 'raw_events';")

	update_projection_state "raw_events" "running" "" "" ""

	# Only project event METADATA, never full JSON payloads
	local rdf_data
	rdf_data=$(run_sql "
        SELECT
            'evt:' || ae.id || ' aml:hasType \"agent_event\" ;' || E'\n' ||
            '    aml:hasSourceAgent \"' || REPLACE(ae.source_agent, '\"', '\\\"') || '\" ;' || E'\n' ||
            '    aml:hasEventType \"' || REPLACE(ae.event_type, '\"', '\\\"') || '\" ;' || E'\n' ||
            '    aml:observedAt \"' || to_char(ae.created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '\"^^xsd:dateTime .' || E'\n'
        FROM event_log.agent_events ae
        WHERE ae.created_at > :'last_time'::timestamptz
        ORDER BY ae.created_at ASC
        LIMIT ${BATCH_SIZE};
    " -v last_time="${last_time}" 2>/dev/null || echo "")

	if [[ -n "${rdf_data}" ]]; then
		if load_rdf_to_oxigraph "${rdf_data}" "http://agent-memory-ledger.local/graph/events"; then
			local max_time
			max_time=$(run_sql "
                SELECT to_char(MAX(created_at), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
                FROM event_log.agent_events
                WHERE created_at > :'last_time'::timestamptz;
            " -v last_time="${last_time}")
			local max_id
			max_id=$(run_sql "
                SELECT id FROM event_log.agent_events
                WHERE created_at = :'max_time'::timestamptz
                ORDER BY id DESC LIMIT 1;
            " -v max_time="${max_time}")
			update_projection_state "raw_events" "completed" "${max_time}" "${max_id}" ""
			log_info "Raw events projection batch completed (up to ${max_time})"
		else
			update_projection_state "raw_events" "error" "" "" "Failed to load RDF to Oxigraph"
			log_error "Failed to load raw events RDF data"
			return 1
		fi
	else
		update_projection_state "raw_events" "completed" "" "" ""
		log_info "No new raw event data to project"
	fi
}

# ---------------------------------------------------------------------------
# Full Rebuild
# ---------------------------------------------------------------------------
rebuild_all() {
	log_notice "Starting full Oxigraph projection rebuild..."
	log_notice "This will clear Oxigraph data and re-project from Postgres."
	log_notice "Postgres canonical tables are NOT modified."

	# Clear projection state to force full re-projection
	run_sql_silent "UPDATE kg.oxigraph_projection_state SET last_event_time = NULL, last_event_id = NULL, status = 'idle', error = NULL;"

	# Clear Oxigraph data via SPARQL UPDATE
	curl -sf -o /dev/null "${OXIGRAPH_URL}/update" \
		--data-urlencode "update=CLEAR ALL" 2>/dev/null || log_warn "Could not clear Oxigraph store (may be empty)"

	log_info "Projection state reset. Starting full projection..."

	# Run all enabled projections
	if bashio::var.true "${PROJECT_IDENTITY_LINEAGE}"; then
		project_identity_lineage || log_error "Identity lineage projection failed during rebuild"
	fi

	if bashio::var.true "${PROJECT_GOVERNANCE}"; then
		project_governance || log_error "Governance projection failed during rebuild"
	fi

	if bashio::var.true "${PROJECT_MEMORY}"; then
		project_memory || log_error "Memory projection failed during rebuild"
	fi

	if bashio::var.true "${PROJECT_RAW_EVENTS}"; then
		project_raw_events || log_error "Raw events projection failed during rebuild"
	fi

	log_notice "Full rebuild completed."
}

# ---------------------------------------------------------------------------
# Health Check
# ---------------------------------------------------------------------------
log_health() {
	if check_oxigraph_health; then
		log_info "SPARQL endpoint is healthy at ${OXIGRAPH_URL}"

		# Report projection state
		local states
		states=$(run_sql "
            SELECT projection_name || ': ' || status ||
                   CASE WHEN last_projected_at IS NOT NULL
                       THEN ' (last: ' || to_char(last_projected_at, 'YYYY-MM-DD HH24:MI:SS') || ')'
                       ELSE '' END
            FROM kg.oxigraph_projection_state
            ORDER BY projection_name;
        " 2>/dev/null || echo "No projection state found")

		if [[ -n "${states}" ]]; then
			while IFS= read -r line; do
				[[ -n "${line}" ]] && log_info "  ${line}"
			done <<<"${states}"
		fi
	else
		log_warn "SPARQL endpoint is NOT reachable at ${OXIGRAPH_URL}"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	log_notice "Oxigraph Projection Worker starting..."

	# Verify prerequisites
	if ! bashio::config.true 'oxigraph.enabled'; then
		log_info "Oxigraph is disabled. Exiting."
		exit 0
	fi

	if ! bashio::config.true 'agent_memory.enabled'; then
		log_error "agent_memory must be enabled for Oxigraph projection."
		exit 1
	fi

	# Wait for PostgreSQL
	log_info "Waiting for PostgreSQL..."
	local retries=0
	while ! pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1; do
		retries=$((retries + 1))
		if [[ ${retries} -ge 60 ]]; then
			log_error "PostgreSQL not available after 60 seconds. Exiting."
			exit 1
		fi
		sleep 1
	done
	log_info "PostgreSQL is ready."

	# Ensure projection state table exists
	run_sql_silent "
        CREATE TABLE IF NOT EXISTS kg.oxigraph_projection_state (
            projection_name   TEXT PRIMARY KEY,
            last_event_time   TIMESTAMPTZ,
            last_event_id     UUID,
            last_projected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            status            TEXT NOT NULL DEFAULT 'idle',
            error             TEXT,
            metadata          JSONB NOT NULL DEFAULT '{}'
        );
    " || log_warn "Could not verify kg.oxigraph_projection_state table"

	# Initialize projection state rows if they don't exist
	for proj in identity_lineage governance memory raw_events; do
		run_sql_silent "
            INSERT INTO kg.oxigraph_projection_state (projection_name, status)
            VALUES (:'proj', 'idle')
            ON CONFLICT (projection_name) DO NOTHING;
        " -v proj="${proj}"
	done

	# Wait for Oxigraph to become available
	log_info "Waiting for Oxigraph SPARQL endpoint..."
	retries=0
	while ! check_oxigraph_health; do
		retries=$((retries + 1))
		if [[ ${retries} -ge 60 ]]; then
			log_error "Oxigraph endpoint not available after 60 seconds. Exiting."
			exit 1
		fi
		sleep 1
	done
	log_info "Oxigraph SPARQL endpoint is ready."

	# Handle rebuild
	if bashio::var.true "${REBUILD_ON_START}"; then
		rebuild_all
	fi

	# Main projection loop with consecutive error tracking and backoff
	log_notice "Starting periodic projection (interval: ${MAX_INTERVAL}s, batch: ${BATCH_SIZE})"

	local consecutive_errors=0
	local current_interval="${MAX_INTERVAL}"

	while true; do
		local batch_had_error=0

		if bashio::var.true "${PROJECT_IDENTITY_LINEAGE}"; then
			project_identity_lineage || batch_had_error=1
		fi

		if bashio::var.true "${PROJECT_GOVERNANCE}"; then
			project_governance || batch_had_error=1
		fi

		if bashio::var.true "${PROJECT_MEMORY}"; then
			project_memory || batch_had_error=1
		fi

		if bashio::var.true "${PROJECT_RAW_EVENTS}"; then
			project_raw_events || batch_had_error=1
		fi

		if [[ ${batch_had_error} -eq 0 ]]; then
			consecutive_errors=0
			current_interval="${MAX_INTERVAL}"
		else
			consecutive_errors=$((consecutive_errors + 1))
			# Exponential backoff: double interval up to 5x MAX_INTERVAL
			current_interval=$((MAX_INTERVAL * consecutive_errors))
			if [[ ${current_interval} -gt $((MAX_INTERVAL * 5)) ]]; then
				current_interval=$((MAX_INTERVAL * 5))
			fi
			log_warn "Consecutive projection errors: ${consecutive_errors}. Backing off to ${current_interval}s."
		fi

		# Log health periodically
		log_health

		sleep "${current_interval}"
	done
}

main "$@"
