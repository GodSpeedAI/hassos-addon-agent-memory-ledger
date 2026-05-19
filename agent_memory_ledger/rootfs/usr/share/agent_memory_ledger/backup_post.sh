#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: Agent Memory Ledger
# Post-backup script - Cleans up compressed SQL dump after Home Assistant backup
# ==============================================================================
declare BACKUP_FILE

BACKUP_FILE="/data/backup_db.sql.gz"

bashio::log.info "Starting post-backup cleanup..."

# Remove the backup file if it exists
if [[ -f "${BACKUP_FILE}" ]]; then
	if rm -f "${BACKUP_FILE}"; then
		bashio::log.info "Backup file removed successfully."
	else
		bashio::log.error "Failed to remove backup file at ${BACKUP_FILE}"
		exit 1
	fi
else
	bashio::log.debug "No backup file to clean up."
fi

bashio::log.info "Post-backup cleanup completed."
