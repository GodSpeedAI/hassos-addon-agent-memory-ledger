#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: TimescaleDb
# Post-backup script - Cleans up SQL dump after Home Assistant backup completes
# ==============================================================================
declare BACKUP_FILE

BACKUP_FILE="/data/backup_db.sql"

bashio::log.info "Starting post-backup cleanup..."

# Remove the backup file if it exists
if [[ -f "${BACKUP_FILE}" ]]; then
    if rm -f "${BACKUP_FILE}"; then
        bashio::log.info "Backup SQL file removed successfully."
    else
        bashio::log.error "Failed to remove backup SQL file at ${BACKUP_FILE}"
        exit 1
    fi
else
    bashio::log.debug "No backup SQL file to clean up."
fi

bashio::log.info "Post-backup cleanup completed."
