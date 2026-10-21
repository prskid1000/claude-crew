# localenv-sandbox
- What: the full local-env script with migration sandboxes (own worktree, build, DB copy, port offset, `sb<k>-<svc>`), exact
  LIGHT reverts (`db.rollback`, `db.applied`, `db.tag`), env `tasks` (`localenv.ps1 task`), `sql -Query` and `migrations`.
Needed when: `localEnv.envs.*.sandbox` = `*`, `localEnv.envs.*.tasks` = `*`, `localEnv.envs.*.db.rollback` = `*`
- Wiring: core `localenv.ps1` forwards every call to `skills/local-env/localenv-sandbox.ps1` when it exists; LIGHT/HEAVY
  classes also need the extra `migration-classify` (devtools.py). Code as of core commit 1fda997.
