#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
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
declare ENABLE_RETENTION_POLICY

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
ENABLE_RETENTION_POLICY=$(bashio::config 'agent_memory.enable_retention_policy' 'false')

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
if ! psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${AGENT_MEMORY_DB}'" | grep -q 1; then
	if ! psql -U postgres -c "CREATE DATABASE \"${AGENT_MEMORY_DB}\""; then
		bashio::log.error "Failed to create agent_memory database '${AGENT_MEMORY_DB}'."
		exit 1
	fi
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

# Step 3: Apply SQL schema files with migration tracking
if bashio::var.true "${CREATE_DEFAULT_SCHEMA}"; then
	SCHEMA_DIR="/usr/share/agent_memory_ledger/agent_memory"

	# ── Step 3a: Apply migration tracking table first ──────────────────────
	# 000_schema_migrations.sql creates agent_memory.schema_migrations.
	# This must exist before we can track any other migrations.
	bashio::log.info "Applying migration tracking table..."
	MIGRATION_SCHEMA="${SCHEMA_DIR}/000_schema_migrations.sql"
	if [[ -f "${MIGRATION_SCHEMA}" ]]; then
		psql -U postgres -d "${AGENT_MEMORY_DB}" -f "${MIGRATION_SCHEMA}" ||
			bashio::log.warning "Migration tracking table had errors (may already exist)."
	else
		bashio::log.error "000_schema_migrations.sql not found. Cannot track migrations."
	fi

	# ── Step 3b: Apply numbered migrations with checksum tracking ──────────
	# For each 001-NNN.sql file:
	#   1. Compute sha256 checksum.
	#   2. Check agent_memory.schema_migrations for this version.
	#   3. If not applied: apply and record.
	#   4. If applied with same checksum: skip (quiet).
	#   5. If applied with different checksum: fail closed unless developer_mode.
	bashio::log.info "Applying tracked schema migrations..."

	declare MIGRATION_FAILED=false
	declare MIGRATION_APPLIED=0
	declare MIGRATION_SKIPPED=0

	for schema_file in "${SCHEMA_DIR}/"[0-9][0-9][0-9]_*.sql; do
		if [[ ! -f "${schema_file}" ]]; then
			continue
		fi

		# Skip 000_schema_migrations.sql — already applied above
		FILENAME=$(basename "${schema_file}")
		if [[ "${FILENAME}" == "000_schema_migrations.sql" ]]; then
			continue
		fi

		# Extract version from filename (e.g., "001" from "001_event_log.sql")
		VERSION="${FILENAME%%_*}"

		# Extract description from filename (e.g., "event_log" from "001_event_log.sql")
		DESCRIPTION="${FILENAME#*_}"
		DESCRIPTION="${DESCRIPTION%.sql}"

		# Compute sha256 checksum
		CHECKSUM=$(sha256sum "${schema_file}" | awk '{print $1}')

		# Check if this version has already been applied
		EXISTING=$(psql -U postgres -d "${AGENT_MEMORY_DB}" -t -A \
			-v VERSION="${VERSION}" \
			-c "SELECT checksum FROM agent_memory.schema_migrations WHERE version = :'VERSION';")

		if [[ -z "${EXISTING}" ]]; then
			# ── New migration: apply and record ────────────────────────────
			bashio::log.info "  [NEW] ${FILENAME} (checksum: ${CHECKSUM:0:12}...)"
			if psql -U postgres -d "${AGENT_MEMORY_DB}" -f "${schema_file}"; then
				psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
					"INSERT INTO agent_memory.schema_migrations (version, description, checksum) VALUES ('${VERSION}', '${DESCRIPTION}', '${CHECKSUM}');" ||
					bashio::log.warning "Failed to record migration ${VERSION} in schema_migrations."
				MIGRATION_APPLIED=$((MIGRATION_APPLIED + 1))
			else
				bashio::log.error "  FAILED to apply migration: ${FILENAME}"
				MIGRATION_FAILED=true
			fi
		elif [[ "${EXISTING}" == "${CHECKSUM}" ]]; then
			# ── Already applied, same checksum: skip silently ──────────────
			MIGRATION_SKIPPED=$((MIGRATION_SKIPPED + 1))
		else
			# ── Checksum mismatch: historical file was edited ──────────────
			bashio::log.error "  [CHANGED] ${FILENAME}"
			bashio::log.error "  Recorded checksum: ${EXISTING:0:12}..."
			bashio::log.error "  Current checksum:  ${CHECKSUM:0:12}..."
			bashio::log.error "  Migration ${VERSION} was already applied with a different checksum."
			bashio::log.error "  Editing historical migrations is not allowed."
			bashio::log.error "  Create a new numbered SQL file instead."

			if bashio::config.true 'developer_mode'; then
				bashio::log.warning "  developer_mode=true: reapplying changed migration."
				bashio::log.warning "  THIS IS UNSAFE. The migration may fail or corrupt state."
				if psql -U postgres -d "${AGENT_MEMORY_DB}" -f "${schema_file}"; then
					psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
						"UPDATE agent_memory.schema_migrations SET checksum = '${CHECKSUM}', applied_at = now() WHERE version = '${VERSION}';" ||
						bashio::log.warning "Failed to update migration ${VERSION} checksum."
					MIGRATION_APPLIED=$((MIGRATION_APPLIED + 1))
				else
					bashio::log.error "  Reapply of ${FILENAME} failed in developer_mode."
					MIGRATION_FAILED=true
				fi
			else
				bashio::log.error "  Set developer_mode=true to override (local development only)."
				MIGRATION_FAILED=true
			fi
		fi
	done

	bashio::log.info "Migration summary: ${MIGRATION_APPLIED} applied, ${MIGRATION_SKIPPED} skipped (unchanged)."

	if bashio::var.true "${MIGRATION_FAILED}"; then
		bashio::log.error "One or more migrations failed. Review errors above."
		bashio::log.error "If a historical migration was edited, revert it and create a new numbered file."
		exit 1
	fi

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

		# Set up retention policy for event_log (opt-in — disabled by default
		# to preserve append-only canonical history)
		if bashio::var.true "${ENABLE_RETENTION_POLICY}"; then
			bashio::log.info "Setting retention policy (${RETENTION_DAYS} days) for event_log.agent_events..."
			psql -U postgres -d "${AGENT_MEMORY_DB}" -c \
				"SELECT add_retention_policy('event_log.agent_events', INTERVAL '${RETENTION_DAYS} days', if_not_exists => TRUE);" ||
				bashio::log.warning "Could not set retention policy for event_log.agent_events."
		else
			bashio::log.info "Retention policy disabled (enable_retention_policy=false). Canonical events are preserved indefinitely."
		fi

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
bashio::log.info "  Retention: ${RETENTION_DAYS} days (enabled: ${ENABLE_RETENTION_POLICY})"
bashio::log.info "  Embeddings in backup: ${INCLUDE_EMBEDDINGS_IN_BACKUP}"

# ===========================================================================
# Step 7: Least-privilege security roles
# ===========================================================================
# Apply 013_security_roles.sql (creates NOLOGIN roles with grants).
# Then, if security.create_least_privilege_roles is true, set passwords
# and enable LOGIN for each role whose password is non-empty.
#
# Passwords come from add-on config, never from SQL files.
# If require_password_change is true and a password is empty, the role
# is not created with LOGIN — the operator must provide a password.
# ===========================================================================

bashio::log.info "Setting up least-privilege security roles..."

# 013_security_roles.sql is already applied by the migration loop above.
# This section only handles password configuration for the roles.

# Check if role management is enabled
if bashio::config.true 'security.create_least_privilege_roles'; then
	bashio::log.info "Creating least-privilege roles with passwords..."

	declare REQUIRE_PW_CHANGE
	REQUIRE_PW_CHANGE=$(bashio::config 'security.require_password_change' 'true')

	# Helper: configure a role with password and LOGIN
	# Args: $1=role_name, $2=password_value
	configure_role() {
		local ROLE_NAME="${1}"
		local ROLE_PASSWORD="${2}"

		if [[ -z "${ROLE_PASSWORD}" ]]; then
			if bashio::var.true "${REQUIRE_PW_CHANGE}"; then
				bashio::log.warning "Role '${ROLE_NAME}' has no password configured."
				bashio::log.warning "Set security.${ROLE_NAME}_password to enable this role."
				bashio::log.warning "Role '${ROLE_NAME}' exists but cannot log in (no password)."
			else
				bashio::log.warning "Role '${ROLE_NAME}' has no password (require_password_change=false)."
				bashio::log.warning "This is acceptable for local development only."
			fi
			return 0
		fi

		# Validate password is not the default placeholder
		if [[ "${ROLE_PASSWORD}" == "changeme" ]] || [[ "${ROLE_PASSWORD}" == "password" ]]; then
			if bashio::var.true "${REQUIRE_PW_CHANGE}"; then
				bashio::log.error "Role '${ROLE_NAME}' uses an insecure default password."
				bashio::log.error "Refusing to enable LOGIN with an insecure password."
				bashio::log.error "Set a strong password for security.${ROLE_NAME}_password."
				return 1
			else
				bashio::log.warning "Role '${ROLE_NAME}' uses an insecure default password."
				bashio::log.warning "This is only acceptable because require_password_change=false."
			fi
		fi

		# Grant LOGIN and set password using a temp SQL file to avoid
		# leaking the password in process arguments (visible via ps).
		bashio::log.info "Configuring role '${ROLE_NAME}' with LOGIN..."
		_PW_FILE=$(mktemp /tmp/aml_role_pw.XXXXXX.sql)
		chmod 600 "${_PW_FILE}"
		echo "ALTER ROLE \"${ROLE_NAME}\" WITH LOGIN PASSWORD '${ROLE_PASSWORD}';" >"${_PW_FILE}"
		if psql -U postgres -d "${AGENT_MEMORY_DB}" -f "${_PW_FILE}" 2>/dev/null; then
			rm -f "${_PW_FILE}"
			bashio::log.info "Role '${ROLE_NAME}' is now active with LOGIN."
			return 0
		else
			rm -f "${_PW_FILE}"
			bashio::log.error "Failed to set password for role '${ROLE_NAME}'."
			return 1
		fi
	}

	# Configure each role
	declare ROLE_FAILED=false

	PW=$(bashio::config 'security.ledger_writer_password' '')
	configure_role "ledger_writer" "${PW}" || ROLE_FAILED=true

	PW=$(bashio::config 'security.ledger_reader_password' '')
	configure_role "ledger_reader" "${PW}" || ROLE_FAILED=true

	PW=$(bashio::config 'security.projection_worker_password' '')
	configure_role "projection_worker" "${PW}" || ROLE_FAILED=true

	PW=$(bashio::config 'security.bridge_worker_password' '')
	configure_role "bridge_worker" "${PW}" || ROLE_FAILED=true

	if bashio::var.true "${ROLE_FAILED}"; then
		bashio::log.error "One or more security roles could not be configured."
		bashio::log.error "Review the errors above and update security configuration."
		# Do not exit — the add-on can still function with the postgres superuser.
		# The roles simply won't have LOGIN enabled.
	fi

	bashio::log.info "Security role configuration completed."
else
	bashio::log.info "security.create_least_privilege_roles is false — skipping role activation."
	bashio::log.info "Roles exist (NOLOGIN) but cannot be used until passwords are set."
fi
