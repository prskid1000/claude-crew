# Local env DB (envy SKILL.md "Model" detail)
Read by datay, the coordinator (`mark`, `restore`, `seed`, `tenant`, `teardown`, `dbtemp`), kitty wiring `db`, devy with a
migration layer. `db.engine` mysql / mariadb (`adapters/db_presets.ps1`); nothing is ever dumped whole.

## DB marks, restore, seed
- Mark = a binlog position + the code live then (zero bytes): `mark -Name <n>` by hand, `release-<n>` before each release's
  code first runs, `use-<agent>` at each new lease, `baseline-<date>` after a green `seed`.
- Slices: a release with migrations (layers or the target) also keeps the CREATE text of each table its migrations touch
  (`db.migrateSql` = the tool's dry-run SQL; unset + Liquibase: `liquibase update-sql`; else the changed migration files'
  text), the rows its DDL destroys (dropped / retyped column: primary key + column; dropped table: its rows) and every view /
  routine / trigger / event definition.
- `restore -Mark <n> | -Release <n> [-DryRun]` (owner / coordinator): holders told to pause, the mark's code built, writers
  stopped, renames undone, each touched table back to its CREATE text (newest slice first), object definitions back, row
  changes after the mark flashed back newest first (FK orphans / duplicate keys checked per batch), AUTO_INCREMENT reset,
  started, "restore done".
- A statement group on a table with triggers is undone as inverted binlog row events (no trigger fires).
- Cascade guard (`doctor` installs it, again after migrations; `teardown` removes it): journals the child rows of CASCADE /
  SET NULL foreign keys; they come back the same way.
- A table it cannot bring back exactly (structure changed with no slice, a cascade before the guard, a failed batch, FLOAT
  after DDL) falls back to its `seed` items (`tables`), named in the summary. Refused only when the binlog lacks the rows
  (statement-format DML).
- A schema dropped / created after the mark (a tenant reset): its tables fall back to seed; its objects stay as they are now
  (never dropped as new).
- `db.rollback` (a tool's rollback command; `liquibase`: tag `release-<n>` before each release's migrations, roll back to it)
  runs only with `db.restoreVia: tool-then-kit` or `-UseToolRollback`.
- `restore.after` [ { name, cmd } ] ({mark}): runs after it and before a release with migrations switches over
  (`onMigrations: false`: after restores only): marker resets (a "latest changeSet" marker skips a layer's changeSet included
  above the target's newest), reindex, cache clears.
- That release first nulls `MD5SUM` of applied Liquibase changeSets a rebuilt layer edited and its target lacks (unmerged;
  the edited DDL is not re-applied), each named in the notes and `<env>-migrations.log`.
- Marks expire with the binlog (`binlog_expire_logs_seconds`; `marks.keepDays` 30, `marks.max` 60). Doctor checks binlog
  ROW / FULL images / FULL metadata / retention.
- `seed [-Check]`: the env's baseline data (`envs.<env>.seed`, JSON `items` [ { name, check: { sql, expect } | { cmd },
  create: { cmd }, how, needs, tables } ], default `<state>/localenv/<env>.seed.json`); each check gates its create.
- With Liquibase also DRIFT `routines:<schema>` = a procedure / function an executed changeSet file created that the schema
  lacks (fix: delete those rows, reset a migration skip marker, restart).
- `db.timeoutSec`: seconds per hook (a number or `{ "<hook>": n }`; default 1800, query 120). `tasks` (`task -Task <name>`),
  `sql -Query` (read-only).

## DB temp
- mysql: once a minute the controller kills the connection with the most temp on disk (session temp tablespaces + TempTable
  mmap files) above `db.tempMaxGB` (5).
- `dbtemp [-Kill <id>]` lists / kills them with the env file's credential: set `storage.db.use` =
  `pwsh -NoProfile -File <kit>/skills/envy/envy.ps1 dbtemp -Env <env>`, `storage.db.kill` = the same `-Kill {id}`.
- Doctor WARNs: ibtmp1 without a max, temp caps above `db.tempMaxGB`, `max_execution_time` 0, slow log off, the datadir
  outside `storage.watch`.

## DB buffer pool
- mysql, `db.bufferPool` set (e.g. `{}`): while a lease or train is live on any env of that db server, the controller grows
  `innodb_buffer_pool_size` online to `busyMB` (2048); once none was for `idle.graceMinutes` (or the loop exits) it shrinks
  it to `idleMB` (256).
- Chunk-aligned, one resize at a time, never during a switch-over, one log line each; `db.expect` then skips the pool.
- Doctor: the pool and the server's RAM. Windows can keep the freed memory in mysqld's working set until a restart.
- The resize is `SET GLOBAL` only: keep the server's configured size (my.cnf / `SET PERSIST`) the idle one.

## Tenants (owner upkeep)
- `tenant list | drop -Name <t,..> [-DryRun]` (`tenants`: { schema, table, key, name, tables, idColumns, nameColumns,
  users { table, key, tenantTable, tenantKey }, keep, keepFrom, verify }).
- Kept = `keep` or a name in `keepFrom` (default kit.local.json, targets.local.json, the seed file; { file, keys }).
- Drop: refused while a lease, hold or train is on; per tenant one transaction (the registry row, its FK children, `tables`
  rows by id / name column, users no staying tenant has), then the schema; 0 references left checked, smoke + `verify`
  ({tenant}) per kept tenant.
- `tenant import -From <source> -Tenant <schema> [-As <name>] -Mask <profile> [-DryRun]`. Config `tenants.import`:
  - `sources` { <name>: { creds (a command printing JSON host, port, user, password) | host, port, user, passwordEnv; prod;
    requireReadOnly (true); adminSchema; maxMB (500) } }, `template`, `skipTables`,
    `set` { "<table>.<column>": "<value | {tenant} | {source:<table>.<column>}>" }, `restart`, `prodPattern`, `cacheHours` (24).
  - `profiles` { <name>: { extends ('personal', built in: names, emails, phones, addresses, logins, secrets by column name;
    '' = none), rules { "<table>.<column> glob": kind | { kind, value } } (keep, null, fixed, password, hash, email, login,
    shape, first, last, name, address, text), skipData, passwordHash, salt, keepValues, keepDomains, scanEmails (true) } }.
- Import refused: a source marked prod or matching `prodPattern`, a writable one (`@@read_only` 0), a schema over `maxMB`, a
  taken name, or while a lease, hold or train is on.
- The schema is streamed through the mask (never stored unmasked; per value deterministic: the same email, login or name
  masks alike in every table), loaded as `<name>`, registered by cloning the `template` tenant's registry rows (new ids;
  name columns and text values equal to the template's name = `<name>`; `set` on top) in one transaction (a failure drops
  the new schema and its registry rows); then `restart` services start under a hold (migrations), `verify`, `seed -Check`.
- Lanes (own DB copies): import on each lane (`-Env <env><k>`); the masked dump is cached `cacheHours`, the source is read once.
