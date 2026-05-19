# Backup and Restore Implementation Summary

## Overview

This document describes the backup and restore mechanism for the Agent Memory
Ledger — a local-first governance substrate for SEA Forge and ZeroClaw that
runs as a Home Assistant add-on.

The backup system uses SQL dumps rather than raw PostgreSQL data files. This
preserves the canonical event ledger, governance records, identity lineage,
memory lifecycle, and all schema migrations in a portable, version-agnostic
format.

## Canonical vs. Derived in Backup

The `pg_dumpall` output is the canonical backup. It contains:

- All schema definitions (`event_log`, `governance`, `memory`, `embeddings`,
  `kg`, `audit`)
- All canonical data (events, governance decisions, identity lineage, memory
  items)
- Migration tracking records (`agent_memory.schema_migrations`)
- Role definitions and grants

These are derived and rebuildable — they do not require backup:

- **Oxigraph data** — fully rebuildable from Postgres via
  `oxigraph.rebuild_on_start: true`
- **NATS JetStream stream** — transport/replay surface, not long-term authority
- **Embeddings** — regenerable from qualified memory objects (unless
  `include_embeddings_in_backup: true`)

## Changes Made

### 1. Configuration (`agent_memory_ledger/config.yaml`)

Added Home Assistant backup lifecycle hooks:

```yaml
backup_pre: /usr/share/agent_memory_ledger/backup_pre.sh
backup_post: /usr/share/agent_memory_ledger/backup_post.sh
backup_exclude:
  - /data/postgres/*
```

These hooks ensure that:

- Before backup: A SQL dump is created
- After backup: The SQL dump is cleaned up
- During backup: The PostgreSQL data directory is excluded (only the SQL dump
  is backed up)

### 2. Pre-Backup Script (`backup_pre.sh`)

**Location:** `/usr/share/agent_memory_ledger/backup_pre.sh`

**Functionality:**

- Checks if PostgreSQL is running
- Executes `pg_dumpall` to create a complete SQL dump
- Creates the file `/data/backup_db.sql`
- Sets proper permissions
- Logs the backup size for verification
- Gracefully handles cases where PostgreSQL isn't running

**Key Features:**

- Uses `pg_isready` to check PostgreSQL status
- Runs as the postgres user
- Includes `--clean --if-exists` flags for safe restore
- Won't fail the backup if database isn't running

### 3. Post-Backup Script (`backup_post.sh`)

**Location:** `/usr/share/agent_memory_ledger/backup_post.sh`

**Functionality:**

- Removes the temporary SQL dump file after backup completes
- Saves disk space
- Logs cleanup status

### 4. Restore Script (`restore_from_backup.sh`)

**Location:** `/usr/share/agent_memory_ledger/restore_from_backup.sh`

**Functionality:**

- Provides `restoreFromBackup()` function
- Starts PostgreSQL temporarily
- Waits for PostgreSQL to be ready (with timeout)
- Restores database from SQL dump using `psql`
- Logs detailed progress and any errors
- Cleans up the backup file after successful restore
- Stops PostgreSQL cleanly after restore

**Key Features:**

- Comprehensive error handling
- Progress logging for user visibility
- Retry logic with timeout for PostgreSQL startup
- Preserves backup file if restore fails (for manual recovery)
- Creates detailed restore log at `/var/log/timescaledb.restore.log`

### 5. Initialization Script Updates (`init-addon/run`)

**Enhanced Logic:**

1. **Fresh Installation with Backup:**
   - Detects if `backup_db.sql` exists on new install
   - Enables restore mode
   - Initializes fresh database
   - Automatically restores from SQL dump

2. **Corrupted Database Detection:**
   - Checks if PostgreSQL data directory is corrupted
   - Detects missing `PG_VERSION` file
   - If backup exists, moves corrupted data aside
   - Initializes fresh database and restores

3. **Automatic Recovery:**
   - Restores silently without user intervention
   - Skips firstrun setup after successful restore
   - Preserves backup file if restore fails

**New Variables:**

- `BACKUP_FILE`: Path to SQL dump file
- `RESTORE_MODE`: Flag indicating restore should occur

### 6. Dockerfile Updates

Added execution permissions for the new scripts:

```dockerfile
RUN chmod +x /usr/share/agent_memory_ledger/backup_pre.sh \
    && chmod +x /usr/share/agent_memory_ledger/backup_post.sh \
    && chmod +x /usr/share/agent_memory_ledger/restore_from_backup.sh
```

## How It Works

### Backup Flow

```text
User triggers HA backup
    |
    v
backup_pre.sh runs
    |
    v
pg_dumpall creates /data/backup_db.sql
    |
    v
HA backs up /data/* (excluding /data/postgres/*)
    |
    v
backup_post.sh runs
    |
    v
backup_db.sql is removed
    |
    v
Backup complete
```

### Restore Flow

```text
User restores HA backup
    |
    v
Addon starts with backup_db.sql
    |
    v
init-addon/run detects restore scenario
    |
    v
Initializes fresh PostgreSQL database
    |
    v
restore_from_backup.sh runs
    |
    v
Starts PostgreSQL temporarily
    |
    v
Restores from SQL dump
    |
    v
Stops PostgreSQL
    |
    v
Removes backup_db.sql
    |
    v
Normal startup continues
```

## Benefits

1. **Consistency:** SQL dumps are transaction-consistent snapshots
2. **Safety:** No risk of backing up corrupted files
3. **Portability:** Can restore across PostgreSQL versions
4. **Size:** Excludes large data directory, only backs up SQL
5. **Automatic:** No user intervention required
6. **Resilient:** Handles corrupted databases automatically
7. **Recoverable:** Preserves backup file if restore fails
8. **Governance-safe:** Canonical event history, governance decisions, identity
   lineage, and migration records are all preserved in the dump

## Testing Recommendations

1. **Test normal backup/restore:**
   - Create some test data (events, governance decisions, identities)
   - Trigger Home Assistant backup
   - Delete database or corrupt it
   - Restore from backup
   - Verify all canonical data is restored
   - Verify migration tracking is intact

2. **Test with PostgreSQL not running:**
   - Stop PostgreSQL
   - Trigger backup
   - Verify graceful handling

3. **Test corrupted database recovery:**
   - Corrupt `PG_VERSION` file
   - Place a valid `backup_db.sql` in /data/
   - Restart addon
   - Verify automatic recovery

4. **Test fresh install with backup:**
   - Delete PostgreSQL data directory
   - Place a valid `backup_db.sql` in /data/
   - Start addon
   - Verify restoration occurs

5. **Test with SEA Forge bridge enabled:**
   - Enable `sea_bridge` and produce some events
   - Trigger backup
   - Restore on fresh install
   - Verify canonical tables contain the bridged events
   - Verify `bridge_worker` role is recreated

## Future Enhancements

Possible improvements:

- Add configuration option for backup retention
- Support for compressed SQL dumps
- Incremental backup support
- Backup verification/testing
- Email notifications on backup/restore events

## Compliance with Agent Guidelines

This implementation follows the AGENTS.md guidelines:

- Uses `bashio::log.*` for all logging
- Quotes all variables properly
- Includes comprehensive error handling
- Documents non-obvious logic
- Uses meaningful variable names
- Follows existing project patterns
- Maintains backward compatibility
- Adds user-facing documentation
- Uses `#!/command/with-contenv bashio` shebang
- Handles edge cases gracefully
- Preserves canonical history as the backup authority
- Does not conflate derived state (Oxigraph, embeddings) with canonical backup
