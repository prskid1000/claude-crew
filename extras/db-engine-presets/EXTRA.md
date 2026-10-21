# db-engine-presets
- What: `localEnv.envs.<env>.db.engine` presets (postgres, mysql, mariadb, sqlserver, sqlite, oracle, mongodb) that fill the
  unset `db.snapshot|restore|query|exec` and `sandbox.db.clone|drop` hooks.
Needed when: `localEnv.envs.*.db.engine` = `*`
- Wiring: `skills/local-env/adapters/db_presets.ps1`, dot-sourced by `localenv.ps1` (extra `local-env`) after its config.
