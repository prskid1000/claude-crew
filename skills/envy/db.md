# Local env DB (envy SKILL.md "Model" detail)
Read by datay, the coordinator (`mark`, `restore`, `seed`, `tenant`, `teardown`, `dbtemp`), kitty wiring `db`, devy with a
migration layer. `db.engine` = an `adapters/db-engines.ps1` adapter (kind db-engine, README
Adapters; a verb an engine lacks refuses, never another engine's client); the cascade
guard and the schema tenant model need mysql / mariadb (`supportsMarks`); never a whole dump. Snapshot marks (sqlserver,
sqlite, oracle, search engines) revert the scopes whole.
- Scopes (`Get-DataScopes`): `db.schemas` + `db.schemasQuery`, else `db.name`; a mark records them, a restore uses the mark's.

## Migration tool (kind migration)
- `db.migrations.tool` (else top-level `migrations.tool`; default none: no tool verbs, touched tables from changed files).
  `liquibase` = `crafty/adapters/liquibase.ps1` (verbs check, discover, pendingSql, tag, rollback, resetEdited,
  missingRoutines, rerunRoutines, historyScopes, unmerged).
- `db.migrations.sets` [ { name, tool, repo, changelog | dir, searchPath, schemas | schemasQuery, registry } ] (paths relative
  to the repo's service folder): one per changelog master. Unset: the tool discovers one; several masters then refuse tag /
  rollback / touched. Tag runs the registry's set and scope first, rollback last.
- `db.migrations.runAt` start (the `tenants.import.restart` services migrate at start) | cmd (`db.migrations.cmd`, {tenant})
  | none: what a tenant import runs after the load.

## DB marks, restore, seed
- Mark = a binlog position (or snapshot) + the code live then: `mark -Name <n>` by hand, `release-<n>` before each release's
  code first runs, `use-<agent>` at each new lease.
- Baseline (`baseline-<nnnn>`, 2 kept): an init's copy, a green `seed`, a DB start with none; then in place when clean after a
  release or lease: no train, layer, lease or hold; seed and the seed file's `clean` [ { name, sql, expect `^0$` } ] green
  (none: never); tool verb `unmerged` empty.
- Slices: a release with migrations (layers or the target) also keeps the CREATE text of each table its migrations touch
  (`db.migrateSql` = the tool's dry-run SQL; unset: each migration set's pendingSql, e.g. `liquibase update-sql`; else the changed migration files'
  text), the rows its DDL destroys (dropped / retyped column: primary key + column; dropped table: its rows) and every view /
  routine / trigger / event definition.
- `restore -Mark <n> | -Release <n> [-DryRun]` (owner / coordinator): holders told to pause, the mark's code built, writers
  stopped, renames undone, each touched table back to its CREATE text (newest slice first), object definitions back, row
  changes after the mark flashed back newest first (FK orphans / duplicate keys checked per batch), AUTO_INCREMENT reset,
  started, "restore done".
- A statement group on a table with triggers is undone as inverted binlog row events (no trigger fires).
- Cascade guard (`db.cascadeGuard` true; default off: `doctor` installs it, again after migrations, a tenant import and
  before a mark that sees a new scope; `teardown` removes it): journals the child rows of CASCADE / SET NULL foreign keys;
  they come back the same way.
- A mark's scope gone since (a dropped tenant) refuses a restore that includes the registry scope; `restore -Schemas` with a
  tenant scope but not the registry's is refused.
- A table it cannot bring back exactly (structure changed with no slice, a cascade before the guard, a failed batch, FLOAT
  after DDL) falls back to its `seed` items (`tables`), named in the summary. Refused only when the binlog lacks the rows
  (statement-format DML).
- A schema dropped / created after the mark (a tenant reset): its tables fall back to seed; its objects stay as they are now
  (never dropped as new).
- `db.rollback` (a rollback command; the tool's name or `tool`: its tag `release-<n>` per set before each release's migrations, rolled back to)
  runs only with `db.restoreVia: tool-then-kit` or `-UseToolRollback`.
- `restore.after` [ { name, cmd } ] ({mark}): runs after it and before a release with migrations switches over
  (`onMigrations: false`: after restores only): marker resets (a "latest changeSet" marker skips a layer's changeSet included
  above the target's newest), reindex, cache clears.
- That release first runs the tool's `resetEdited` verb (liquibase: nulls `MD5SUM` of applied changeSets a rebuilt layer edited and its
  target lacks; the edited DDL is not re-applied), each named in the notes and `<env>-migrations.log`.
- Marks expire with the binlog (`binlog_expire_logs_seconds`; `marks.keepDays` 30, `marks.max` 60); they need ROW
  format, FULL row image and FULL metadata.
- `seed [-Check]`: the env's baseline data (`envs.<env>.seed`, JSON `items` [ { name, check: { sql, expect } | { cmd },
  create: { cmd, upsert }, how, needs, tables } ], default `<state>/localenv/<env>.seed.json`); a create runs on MISSING, on DRIFT only with `create.upsert: true`, then
  the check again; the last line names each item not created and why.
- A tool with `missingRoutines` (liquibase) adds DRIFT `routines:<schema>` = a procedure / function an executed migration created
  that the schema lacks (fix: `rerunRoutines`, reset a migration skip marker, restart).
- `db.timeoutSec`: seconds per hook (a number or `{ "<hook>": n }`; default 1800, query 120). `tasks` (`task -Task <name>`),
  `sql -Query` (read-only).

## DB temp
- mysql: once a minute the controller kills the connection with the most temp on disk (session temp tablespaces + TempTable
  mmap files) above `db.tempMaxGB` (5).
- `dbtemp [-Kill <id>]` lists / kills them with the env file's credential: set `storage.db.use` =
  `pwsh -NoProfile -File <kit>/skills/envy/envy.ps1 dbtemp -Env <env>`, `storage.db.kill` = the same `-Kill {id}`.

## DB buffer pool
- mysql, `db.bufferPool` set (e.g. `{}`): while a lease or train is live on any env of that db server, the controller grows
  `innodb_buffer_pool_size` online to `busyMB` (2048); once none was for `idle.graceMinutes` (or the loop exits) it shrinks
  it to `idleMB` (256).
- Chunk-aligned, one resize at a time, never mid switch-over, one log line each; `db.expect` skips the pool.
- `SET GLOBAL` only: keep the configured size (my.cnf / `SET PERSIST`) the idle one.

## Tenants (owner upkeep)
- `tenants.model` (kind tenant-model, `adapters/tenant-models.ps1`): none (default: tenant verbs refuse) | schema (a
  schema per tenant + a registry, `adapters/tenant-schema.ps1`) | database (same, databases as schemas) | column (one
  scope; `tenants.column` { table, column }) | instance (`tenants.instances` [{ name, db }]): list only. Non-SQL engines (redis,
  search): `sizes` only.
- `tenant list | drop -Name <t,..> [-DryRun]` (schema model: `tenants.registry` or flat `tenants` { schema, table, key, name
  (required, no defaults), tables, idColumns, nameColumns, users { table, key, tenantTable, tenantKey }, keep, keepFrom, verify }).
- Kept = `keep` or a name in `keepFrom` (default none; files, { file, keys }, `builtin:kit-config` / `builtin:targets` /
  `builtin:seed`); no keep source refuses. Drop takes a mark first.
- Drop: refused while a lease, hold or train is on; per tenant one transaction (the registry row, its FK children, `tables`
  rows by id / name column (an id column with an FK to another table: only through that FK), users no staying tenant has),
  then the schema; 0 references left checked, smoke + `verify` ({tenant}) per kept tenant. A planned row pointing at a row
  that stays: `BLOCKED` in the dry run, the whole drop refused.
- `tenant import -From <source> -Tenant <schema> [-As <name>] -Mask <profile> [-DryRun] [-Refresh]`. Config `tenants.import`:
  - `sources` { <name>: { creds (a command printing JSON host, port, user, password) | host, port, user, passwordEnv; prod;
    requireReadOnly (true); adminSchema; maxMB (500) } }, `template`, `skipTables`,
    `set` { "<table>.<column>": "<value | {tenant} | {source:<table>.<column>}>" }, `restart`, `prodPattern`, `cacheHours` (unset: never expires).
  - `profiles` { <name>: { extends ('personal', built in: names, emails, phones, addresses, logins, secrets by column name;
    '' = none), rules { "<table>.<column> glob": kind | { kind, value } } (keep, null, fixed, password, hash, email, login,
    shape, first, last, name, address, text), skipData, passwordHash, salt, keepValues, keepDomains, scanEmails (true) } }.
  - Top-level `masking` { rules (an app's own columns, after the profile's, before the built-in), logins (kept as-is),
    names { first, last, streets } }: the org's masking for every 'personal' profile.
- Import refused: a source marked prod or matching `prodPattern`, a writable one (`@@read_only` 0), a schema over `maxMB`, a
  taken name, or while a lease, hold or train is on.
- The schema is streamed through the mask (never stored unmasked; per value deterministic: the same email, login or name
  masks alike in every table), loaded as `<name>`, registered by cloning the `template` tenant's registry rows (new ids;
  name columns and text values equal to the template's name = `<name>`; `set` on top) in one transaction (a failure drops
  the new schema and its registry rows); routines, triggers and events come with it (DEFINER dropped); a routine the source
  lacks while its history says it ran is made pending (tool verb `rerunRoutines`); a mark before the load, `restore.after` hooks (marker resets), the cascade guard;
  then `db.migrations.runAt`, `verify`, `seed -Check`. `tenants.import.register`: builtin:clone (default) or a command
  ({tenant} {template} {source}).
- Saved copy: one masked dump per source + tenant + profile config (`profiles.<p>` + `masking`; a kit or masker update keeps it:
  the migrations bring its schema up to date), reused until `-Refresh` or `cacheHours`; the source is read only with no usable
  copy (on reuse only its metadata: read-only, size, charset, `set` values). Profile changed: the old copy is reused, warned (no unmasked copy to re-mask); `-Refresh`
  masks a new one. Lanes (own DB copies): import on each lane (`-Env <env><k>`), one source read.
- A failed load or registration deletes only the registry rows it inserted (auto-increment id above the max before it; a
  plan row pointing at a staying tenant's row: left, named); a template plan reaching other tenants' rows is refused.
