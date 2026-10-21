# local-env
- What: the `local-env` skill: ONE shared local instance per env (`localEnv.envs`) that agents deploy branches to, test and
  debug on (trains, leases, idle stops), with migration sandboxes, exact LIGHT reverts (`db.rollback`), env `tasks` and `sql`.
Needed when: `localEnv.envs` = `*`
- Wiring: `skills/local-env/SKILL.md` + `localenv.ps1` (dot-sources `adapters/*.ps1`: extra `db-engine-presets`); LIGHT/HEAVY
  classes also need the extra `migration-classify` (devtools.py). Without it the dev flow's step 5 = automated tests only.
