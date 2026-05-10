#!/bin/bash

if [ -z "${POSTGRESQL_CONF_DIR:-}" ]; then
	if [ -z "${PGDATA:-}" ]; then
		echo "PGDATA is not set; cannot determine POSTGRESQL_CONF_DIR for pg_hba.conf" >&2
		exit 1
	fi
	POSTGRESQL_CONF_DIR=${PGDATA}
fi

PG_HBA_CONF="${POSTGRESQL_CONF_DIR}/pg_hba.conf"

if [ ! -f "${PG_HBA_CONF}" ]; then
	echo "pg_hba.conf not found at ${PG_HBA_CONF} (POSTGRESQL_CONF_DIR=${POSTGRESQL_CONF_DIR})" >&2
	exit 1
fi

if [ ! -w "${PG_HBA_CONF}" ]; then
	echo "pg_hba.conf is not writable at ${PG_HBA_CONF} (POSTGRESQL_CONF_DIR=${POSTGRESQL_CONF_DIR})" >&2
	exit 1
fi

# reenable password authentication (scram-sha-256 is preferred over md5)
if ! sed -i "s/host all all all trust/host all all all scram-sha-256/" "${PG_HBA_CONF}"; then
	echo "sed replacement failed for ${PG_HBA_CONF} (POSTGRESQL_CONF_DIR=${POSTGRESQL_CONF_DIR})" >&2
	exit 1
fi
