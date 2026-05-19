# Schema Migration Rollback Procedure

## When Rollback Is Needed

Schema migration rollback is an emergency recovery operation. It should only be
performed when a migration has caused a critical failure and the add-on cannot
operate normally.

Common scenarios:

- A new migration introduced a breaking schema change that is incompatible with
  the current application logic.
- A migration failed partway through, leaving the database in an inconsistent
  state.
- A migration was applied to the wrong database or environment.

## Before You Begin

**Rollback is destructive.** It modifies `agent_memory.schema_migrations` and
potentially drops or alters database objects. Always:

1. Take a fresh backup before proceeding.
2. Test the rollback on a non-production system first.
3. Document exactly which migration(s) need to be rolled back.

## Rollback Strategies

### Strategy 1: Restore from Backup (Recommended)

The safest rollback is to restore the database from a backup taken before the
problematic migration was applied.

1. Stop the add-on.
2. Restore from the most recent backup that predates the migration:

   ```bash
   # Inside the container
   su - postgres -c "gunzip -c /data/backup_db.sql.gz | psql -U postgres -d postgres"
   ```

3. Start the add-on. The init script will detect the migration state from the
   restored backup and skip already-applied migrations.

**Advantages:** Clean, complete, no risk of partial state.
**Disadvantages:** Loses all data written after the backup was taken.

### Strategy 2: Manual Migration Reversal (Advanced)

When backup restore is not feasible (too much data would be lost), you can
manually reverse the effects of a specific migration.

1. Stop the add-on.
2. Connect to PostgreSQL:

   ```bash
   psql -U postgres -d agent_memory
   ```

3. Inspect the current migration state:

   ```sql
   SELECT version, description, checksum, applied_at
   FROM agent_memory.schema_migrations
   ORDER BY version;
   ```

4. Write a reversal SQL script that undoes the changes made by the migration.
   For example, if migration `014` added a table:

   ```sql
   -- Reverse 014_add_audit_summary.sql
   DROP TABLE IF EXISTS audit.audit_summary;
   ```

5. Execute the reversal script.
6. Update the migration tracking table to remove the rolled-back migration:

   ```sql
   DELETE FROM agent_memory.schema_migrations
   WHERE version = '014';
   ```

   **Warning:** This is the only acceptable DELETE on `schema_migrations`. The
   table is append-only by convention; this operation breaks that convention
   and must be documented.

7. Start the add-on. The init script will detect the migration as "not applied"
   and attempt to re-apply it. If you want to skip it permanently, you must
   also remove or rename the migration file.

### Strategy 3: Developer Mode Re-Apply (Development Only)

If the migration was applied with a different checksum (e.g., you edited the
file during development), you can use `developer_mode` to force re-application.

1. Enable `developer_mode: true` in add-on configuration.
2. Restart the add-on.
3. The init script will log a warning and re-apply the changed migration.
4. Disable `developer_mode` after the migration is corrected.

**This is not a rollback.** It re-applies the current file content. Only use
this in development environments.

## Emergency: Reset Migration Tracking

If the migration tracking table itself is corrupted:

```sql
-- WARNING: This resets ALL migration tracking.
-- The init script will attempt to re-apply ALL migrations.
-- Use CREATE IF NOT EXISTS / IF NOT EXISTS patterns to ensure idempotency.
TRUNCATE agent_memory.schema_migrations;
```

After truncating, restart the add-on. The init script will re-apply all
migrations. Because migrations use `CREATE ... IF NOT EXISTS` patterns, this
is generally safe but may produce warnings for already-existing objects.

## Rollback Checklist

- [ ] Fresh backup taken
- [ ] Rollback strategy selected and tested on non-production system
- [ ] Add-on stopped
- [ ] Rollback executed
- [ ] Migration tracking table updated (if using Strategy 2)
- [ ] Add-on started and verified
- [ ] `/readyz` endpoint returns 200
- [ ] Application functionality verified
- [ ] Rollback documented in incident log

## Prevention

To minimize the need for rollback:

- Always test new migrations in `developer_mode` on a development system first.
- Use additive migrations (add new tables/columns, don't modify existing ones).
- Use `CREATE ... IF NOT EXISTS` and `ALTER ... IF NOT EXISTS` patterns.
- Never edit applied migration files — create new numbered files instead.
- Keep backups frequent enough that backup restore is a viable rollback option.
