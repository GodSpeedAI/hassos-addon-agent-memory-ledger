#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: TimescaleDb
# Pre-backup script - Creates a SQL dump before Home Assistant backup runs
# ==============================================================================
declare BACKUP_FILE

BACKUP_FILE="/data/backup_db.sql"

bashio::log.info "Starting pre-backup process..."

# Check if postgres is running by trying to connect
if pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1; then
	bashio::log.info "PostgreSQL is running, creating database dump..."

	# Remove old backup file if it exists
	if [[ -f "${BACKUP_FILE}" ]]; then
		bashio::log.debug "Removing old backup file..."
		rm -f "${BACKUP_FILE}"
	fi

	# Create an empty file with proper ownership first
	touch "${BACKUP_FILE}"
	chown postgres:postgres "${BACKUP_FILE}"
	chmod 600 "${BACKUP_FILE}"

	# Create the SQL dump.
	BACKUP_OPTS="-U postgres --clean --if-exists"
	EXCLUDE_EMBEDDINGS=false

	if bashio::config.true 'agent_memory.enabled'; then
		if ! bashio::config.true 'agent_memory.include_embeddings_in_backup'; then
			bashio::log.info "Excluding embeddings schema from backup (agent_memory.include_embeddings_in_backup=false)"
			EXCLUDE_EMBEDDINGS=true
		fi
	fi

	if bashio::var.true "${EXCLUDE_EMBEDDINGS}"; then
		if su - postgres -c "pg_dumpall ${BACKUP_OPTS} --globals-only -f ${BACKUP_FILE}"; then
			DATABASES=$(su - postgres -c "psql -U postgres -t -A -c \"SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;\"")
			while IFS= read -r database; do
				[[ -z "${database}" ]] && continue
				bashio::log.debug "Dumping database '${database}' without embeddings schema..."
				if ! su - postgres -c "pg_dump ${BACKUP_OPTS} --exclude-schema=embeddings -d \"${database}\" >> ${BACKUP_FILE}"; then
					bashio::log.error "Failed to dump database '${database}'!"
					exit 1
				fi
			done <<<"${DATABASES}"
			DUMP_CREATED=true
		else
			DUMP_CREATED=false
		fi
	elif su - postgres -c "pg_dumpall ${BACKUP_OPTS} -f ${BACKUP_FILE}"; then
		DUMP_CREATED=true
	else
		DUMP_CREATED=false
	fi

	if bashio::var.true "${DUMP_CREATED}"; then
		bashio::log.info "Database dump created successfully at ${BACKUP_FILE}"

		# Set proper permissions
		chmod 600 "${BACKUP_FILE}"
		chown postgres:postgres "${BACKUP_FILE}"

		# Log file size for verification
		BACKUP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
		bashio::log.info "Backup file size: ${BACKUP_SIZE}"
	else
		bashio::log.error "Failed to create database dump!"
		exit 1
	fi
else
	bashio::log.warning "PostgreSQL is not running. Skipping database dump."
	bashio::log.warning "Note: Only file-level backup will be performed."
fi

bashio::log.info "Pre-backup process completed."
