# local-env
- What: the `envy` skill: ONE shared local instance per env (`localEnv.envs`) that agents deploy branches to, test and
  debug on (trains, leases, idle stops), DB marks / `restore` / `seed` (goody `db-engine-presets` for mysql / mariadb), env
  `tasks` and `sql`.
Needed when: `localEnv.envs` = `*`
- Wiring: `skills/envy/SKILL.md` + `envy.ps1` (dot-sources `adapters/*.ps1`: goody `db-engine-presets`);
  `skills/bossy/adapters/localenv_supervise.ps1` gives bossy.ps1 supervise its env rows, owner holds and the RESTART LOOP,
  UNKNOWN port and ERROR SPIKE checks (`Get-KitSuperviseFlagsLocalEnv`); `skills/crafty/adapters/guard_localenv.ps1` gives
  crafty.ps1 guard its rules (a localenv/<env> branch is never pushed, dev servers never start by hand). Without it the dev flow's
  step 5 = automated tests only.
