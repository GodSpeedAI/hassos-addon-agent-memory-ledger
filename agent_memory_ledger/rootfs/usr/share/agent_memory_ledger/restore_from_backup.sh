#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# Restore script - Restores database from SQL dump (compressed or plain)
# ==============================================================================
declare BACKUP_FILE
declare BACKUP_FILE_GZ
declare POSTGRES_DATA

BACKUP_FILE="/data/backup_db.sql"
BACKUP_FILE_GZ="/data/backup_db.sql.gz"
POSTGRES_DATA="/data/postgres"

# Function to restore from SQL backup
restoreFromBackup() {
	bashio::log.notice "==================================================================="
	bashio::log.notice "  DATABASE RESTORE IN PROGRESS"
	bashio::log.notice "==================================================================="

	# Determine which backup file to use (compressed takes precedence)
	RESTORE_FILE=""
	if [[ -f "${BACKUP_FILE_GZ}" ]]; then
		RESTORE_FILE="${BACKUP_FILE_GZ}"
		bashio::log.notice "Found compressed backup: ${BACKUP_FILE_GZ}"
	elif [[ -f "${BACKUP_FILE}" ]]; then
		RESTORE_FILE="${BACKUP_FILE}"
		bashio::log.notice "Found plain backup: ${BACKUP_FILE}"
	else
		bashio::log.error "No backup file found at ${BACKUP_FILE} or ${BACKUP_FILE_GZ}"
		return 1
	fi

	if [[ ! -r "${RESTORE_FILE}" ]]; then
		bashio::log.error "Backup file is not readable at ${RESTORE_FILE}"
		return 1
	fi

	# Ensure the backup file is accessible by the postgres user
	bashio::log.info "Fixing permissions on backup file..."
	if ! chown postgres:postgres "${RESTORE_FILE}"; then
		bashio::log.error "Could not change owner of backup file to postgres:postgres"
		return 1
	fi
	if ! chmod 640 "${RESTORE_FILE}"; then
		bashio::log.error "Could not change permissions of backup file"
		return 1
	fi

	# Log backup file info
	BACKUP_SIZE=$(du -h "${RESTORE_FILE}" | cut -f1)
	bashio::log.info "Backup file size: ${BACKUP_SIZE}"

	# Start postgres temporarily for restore
	bashio::log.info "Starting PostgreSQL for restore process..."
	su - postgres -c "postgres -D ${POSTGRES_DATA}" &
	POSTGRES_PID=$!

	# Wait for postgres to become available
	bashio::log.info "Waiting for PostgreSQL to be ready..."
	RETRY_COUNT=0
	MAX_RETRIES=30
	while ! psql -U postgres postgres -c "" 2>/dev/null; do
		sleep 1
		RETRY_COUNT=$((RETRY_COUNT + 1))
		if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
			bashio::log.error "PostgreSQL failed to start within ${MAX_RETRIES} seconds"
			kill "${POSTGRES_PID}" 2>/dev/null || true
			return 1
		fi
	done

	bashio::log.info "PostgreSQL is ready. Starting restore..."

	# Ensure the log directory exists (defensive: base image should provide it, but guard anyway)
	mkdir -p /var/log

	# Restore the backup — detect compressed files and decompress on the fly
	if [[ "${RESTORE_FILE}" == *.gz ]]; then
		bashio::log.info "Restoring from compressed backup..."
		su - postgres -c "gunzip -c \"${RESTORE_FILE}\" | psql -X -U postgres -d postgres" 2>&1 | tee /var/log/timescaledb.restore.log
		RESTORE_EXIT=${PIPESTATUS[0]}
	else
		bashio::log.info "Restoring from plain SQL backup..."
		su - postgres -c "psql -X -U postgres -f \"${RESTORE_FILE}\" -d postgres" 2>&1 | tee /var/log/timescaledb.restore.log
		RESTORE_EXIT=${PIPESTATUS[0]}
	fi

	if [[ "${RESTORE_EXIT}" -eq 0 ]]; then
		bashio::log.notice "Database restored successfully from backup!"

		# Stop postgres
		bashio::log.info "Stopping PostgreSQL..."
		kill "${POSTGRES_PID}"
		wait "${POSTGRES_PID}" || true

		# Remove the backup file(s) after successful restore
		bashio::log.info "Removing backup file after successful restore..."
		rm -f "${BACKUP_FILE}" "${BACKUP_FILE_GZ}"

		bashio::log.notice "==================================================================="
		bashio::log.notice "  DATABASE RESTORE COMPLETED SUCCESSFULLY"
		bashio::log.notice "==================================================================="
		return 0
	else
		bashio::log.error "Failed to restore database from backup!"
		bashio::log.error "Check /var/log/timescaledb.restore.log for details"

		# Stop postgres
		kill "${POSTGRES_PID}" 2>/dev/null || true
		wait "${POSTGRES_PID}" 2>/dev/null || true

		bashio::log.notice "==================================================================="
		bashio::log.notice "  DATABASE RESTORE FAILED"
		bashio::log.notice "==================================================================="
		return 1
	fi
}

# Export the function so it can be called from other scripts
export -f restoreFromBackup
