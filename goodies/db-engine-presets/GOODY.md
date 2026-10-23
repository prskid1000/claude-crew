# db-engine-presets
- What: `localEnv.envs.<env>.db.engine` presets (postgres, mysql, mariadb, sqlserver, sqlite, oracle, mongodb) that fill the
  unset `db.query|exec` hooks; for mysql / mariadb the layered DB of the local env: marks (binlog positions), slices before a
  migration release (CREATE text, the rows its DDL destroys, view / routine / trigger / event definitions), `restore` (structure
  and objects back, row flashback with FK / unique checks; trigger tables as inverted row events; a table it cannot restore
  exactly falls back to seed), the cascade guard (journal triggers on CASCADE / SET NULL parents) and the touched-tables parser
  (`db.migrateSql` output or migration files); mysql: the temp watchdog (`db.tempMaxGB`), `dbtemp`, temp-cap doctor rows;
  `db.expect` doctor rows; `tenant list | drop` (`tenants`: local tenants dropped with their admin rows, users and schema).
  Other engines: marks unsupported.
Needed when: `localEnv.envs.*.db` = `*`, `localEnv.defaults.db` = `*`
- Wiring: `skills/envy/adapters/db_presets.ps1` (dot-sourced by `envy.ps1`, goody `local-env`) + `db_flashback.py`
  (`plan|apply|slice|structure|objects|guard|touched`). Tests: `tests.ps1` (a scratch mysqld of its own when `mysqld` is on PATH).
