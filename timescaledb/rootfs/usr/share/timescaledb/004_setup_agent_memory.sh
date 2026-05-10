#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: TimescaleDB
# Agent Memory Profile Setup
# Initializes the agent_memory database, extensions, schemas, and hypertables
# when the agent_memory profile is enabled in addon configuration.
# ==============================================================================

declare AGENT_MEMORY_DB
declare EMBEDDING_DIM
declare RETENTION_DAYS
declare ENABLE_RUVECTOR
declare ENABLE_TIMESCALE
declare CREATE_DEFAULT_SCHEMA
declare INCLUDE_EMBEDDINGS_IN_BACKUP

# Check if agent_memory profile is enabled
if ! bashio::config.true 'agent_memory.enabled'; then
	bashio::log.debug "Agent memory profile is not enabled. Skipping setup."
	exit 0
fi

bashio::log.notice "Agent Memory profile is enabled. Setting up..."

# Read configuration with defaults
AGENT_MEMORY_DB=$(bashio::config 'agent_memory.database' 'agent_memory')
CREATE_DEFAULT_SCHEMA=$(bashio::config 'agent_memory.create_default_schema' 'true')
ENABLE_RUVECTOR=$(bashio::config 'agent_memory.enable_ruvector' 'true')
ENABLE_TIMESCALE=$(bashio::config 'agent_memory.enable_timescaledb' 'true')
RETENTION_DAYS=$(bashio::config 'agent_memory.retention_days' '90')
EMBEDDING_DIM=$(bashio::config 'agent_memory.embedding_dimension' '1536')
INCLUDE_EMBEDDINGS_IN_BACKUP=$(bashio::config 'agent_memory.include_embeddings_in_backup' 'true')

if [[ ! "${AGENT_MEMORY_DB}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
	bashio::log.error "Invalid agent_memory.database: ${AGENT_MEMORY_DB}. Must be a PostgreSQL identifier."
	exit 1
fi

# Validate embedding dimension
if [[ "${EMBEDDING_DIM}" -lt 1 ]] || [[ "${EMBEDDING_DIM}" -gt 4096 ]]; then
	bashio::log.error "Invalid embedding_dimension: ${EMBEDDING_DIM}. Must be between 1 and 4096."
	exit 1
fi

# Validate retention days
if [[ "${RETENTION_DAYS}" -lt 1 ]]; then
	bashio::log.error "Invalid retention_days: ${RETENTION_DAYS}. Must be at least 1."
	exit 1
fi

# Step 1: Create the database if it doesn't exist
bashio::log.info "Ensuring agent_memory database '${AGENT_MEMORY_DB}' exists..."
psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${AGENT_MEMORY_DB}'" | grep -q 1 ||
	psql -U postgres -c "CREATE DATABASE \"${AGENT_MEMORY_DB}\""

if [[ $? -ne 0 ]]; then
	bashio::log.error "Failed to create agent_memory database '${AGENT_MEMORY_DB}'."
	exit 1
fi

bashio::log.info "Database '${AGENT_MEMORY_DB}' is ready."

# Step 2: Enable extensions
bashio::log.info "Enabling extensions for agent_memory database..."

# Enable TimescaleDB if requested
if bashio::var.true "${ENABLE_TIMESCALE}"; then
	bashio::log.info "Enabling TimescaleDB extension..."
	psql -U postgres -d "${AGENT_MEMORY_DB}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;" ||
		bashio::log.warning "Failed to enable TimescaleDB extension."
fi

# Enable RuVector if requested
if bashio::var.true "${ENABLE_RUVECTOR}"; then
	bashio::log.info "Enabling RuVector extension..."
	psql -U postgres -d "${AGENT_MEMORY_DB}" -c "CREATE EXTENSION IF NOT EXISTS ruvector;" ||
		bashio::log.warning "Failed to enable RuVector extension. Embedding features will be unavailable."
fi

# Step 3: Apply SQL schema files
if bashio::var.true "${CREATE_DEFAULT_SCHEMA}"; then
	bashio::log.info "Applying agent_memory schema files..."

	SCHEMA_DIR="/usr/share/timescaledb/agent_memory"

	for schema_file in "${SCHEMA_DIR}"/*.sql; do
		if [[ -f "${schema_file}" ]]; then
			bashio::log.info "Applying schema: $(basename "${schema_file}")"
			psql -U postgres -d "${AGENT_MEMORY_DB}" -f "${schema_file}" ||
				bashio::log.warning "Schema file $(basename "${schema_file}") had errors (may be expected if objects exist)."
		fi
		done

		# Create embedding storage with the configured ruvector dimension.
		if bashio::var.true "${ENABLE_RUVECTOR}"; then
			bashio::log.info "Ensuring embeddings.memory_embeddings uses dimension ${EMBEDDING_DIM}..."
			psql -U postgres -d "${AGENT_MEMORY_DB}" -v EMBEDDING_DIM="${EMBEDDING_DIM}" -c '
				CREATE TABLE IF NOT EXISTS embeddings.memory_embeddings (
				    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
				    memory_item_id  UUID NOT NULL REFERENCES memory.items(id) ON DELETE CASCADE,
				    embedding       ruvector(:EMBEDDING_DIM) NOT NULL,
				    embedding_model TEXT,
				    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
				    CONSTRAINT uq_memory_embeddings_memory_item UNIQUE (memory_item_id)
				);
				CREATE INDEX IF NOT EXISTS idx_memory_embeddings_created_at
				    ON embeddings.memory_embeddings (created_at DESC);
				CREATE INDEX IF NOT EXISTS idx_memory_embeddings_model
				    ON embeddings.memory_embeddings (embedding_model);
			' || bashio::log.warning "Could not create embeddings.memory_embeddings."
		fi

		# Step 4: Convert event_log.agent_events to hypertable if TimescaleDB is enabled
	if bashio::var.true "${ENABLE_TIMESCALE}"; then
		bashio::log.info "Converting event_log.agent_events to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('event_log.agent_events', 'created_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert event_log.agent_events to hypertable."

		# Set up retention policy for event_log
		bashio::log.info "Setting retention policy (${RETENTION_DAYS} days) for event_log.agent_events..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT add_retention_policy('event_log.agent_events', INTERVAL '${RETENTION_DAYS} days', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not set retention policy for event_log.agent_events."

		# Convert inbox/outbox to hypertables
		bashio::log.info "Converting event_log.inbox_events to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('event_log.inbox_events', 'received_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert event_log.inbox_events to hypertable."

		bashio::log.info "Converting event_log.outbox_events to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('event_log.outbox_events', 'created_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert event_log.outbox_events to hypertable."
	fi

	# Step 5: Create ruhnsw index for embeddings if RuVector is enabled
	if bashio::var.true "${ENABLE_RUVECTOR}"; then
		bashio::log.info "Creating ruhnsw index for embedding similarity search..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"CREATE INDEX IF NOT EXISTS idx_memory_embeddings_ruhnsw ON embeddings.memory_embeddings USING ruhnsw (embedding ruvector_cosine_ops);" ||
			bashio::log.warning "Could not create ruhnsw index. Vector similarity search may be slow."
	fi

	# Step 6: Convert governance tables to hypertables if TimescaleDB is enabled
	if bashio::var.true "${ENABLE_TIMESCALE}"; then
		bashio::log.info "Converting governance.identity_events to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('governance.identity_events', 'occurred_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert governance.identity_events to hypertable."

		bashio::log.info "Converting governance.action_requests to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('governance.action_requests', 'occurred_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert governance.action_requests to hypertable."

		bashio::log.info "Converting governance.action_decisions to hypertable..."
		psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
			"SELECT create_hypertable('governance.action_decisions', 'decided_at', if_not_exists => TRUE);" ||
			bashio::log.warning "Could not convert governance.action_decisions to hypertable."
	fi
fi

bashio::log.notice "Agent Memory profile setup completed successfully."
bashio::log.info "  Database: ${AGENT_MEMORY_DB}"
bashio::log.info "  TimescaleDB: ${ENABLE_TIMESCALE}"
bashio::log.info "  RuVector: ${ENABLE_RUVECTOR}"
bashio::log.info "  Embedding dimension: ${EMBEDDING_DIM}"
bashio::log.info "  Retention: ${RETENTION_DAYS} days"
bashio::log.info "  Embeddings in backup: ${INCLUDE_EMBEDDINGS_IN_BACKUP}"
