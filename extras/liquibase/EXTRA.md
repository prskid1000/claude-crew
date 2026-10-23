# liquibase
- What: `devtools.py lbcheck <master.xml> [since]`, the Liquibase sanity check `dev.ps1 check -Step migrations` runs for a repo
  without its own `repos[].migrations.check`: replays master.xml's includes; flags create / add of an existing table or column
  without `<preConditions>`, schema changeSets without `<rollback>`, "not reversible" ones with an empty rollback.
Needed when: `localEnv.envs.*.db.rollback` ~ `liquibase`, `localEnv.defaults.db.rollback` ~ `liquibase`, `liquibase/**/*.xml` in a repo, or listed in kit.local.json `extras`
- Wiring: `skills/dev-kit/adapters/liquibase.py` (devtools.py plugin verb `lbcheck`) and `liquibase.ps1` (`Invoke-LiquibaseCheck`,
  called by Invoke-Check); without them `check -Step migrations` on Liquibase XML is UNRUN (exit 5) with the extra line.
  Local env (extra `local-env` dot-sources `liquibase.ps1`): `db.migrateSql` unset -> `liquibase update-sql`; `db.rollback`
  `liquibase` -> tag `release-<n>` before a release's migrations and roll back to it (opt-in restore).
  Tests: `tests.ps1` here; the local env part: extra db-engine-presets `tests.ps1`.
