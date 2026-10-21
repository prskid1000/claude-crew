# local-env
- What: the `local-env` skill: ONE shared local instance per env (`localEnv.envs`) that agents deploy branches to, test and
  debug on (trains, leases, idle stops), with migration sandboxes, exact LIGHT reverts (`db.rollback`), env `tasks` and `sql`.
Needed when: `localEnv.envs` = `*`
- Wiring: `skills/local-env/SKILL.md` + `localenv.ps1` (dot-sources `adapters/*.ps1`: extra `db-engine-presets`); LIGHT/HEAVY
  classes also need the extra `migration-classify` (devtools.py); `skills/orchestrate/adapters/localenv_supervise.ps1` gives orch.ps1
  supervise its env rows, owner holds and the RESTART LOOP, UNKNOWN port and ERROR SPIKE checks (`Get-KitSuperviseFlagsLocalEnv`);
  `skills/dev-kit/adapters/guard_localenv.ps1` gives dev.ps1 guard its rules (a localenv/<env> branch is never pushed, dev servers
  never start by hand). Without it the dev flow's step 5 = automated tests only.
