---
name: local-env
description: "Load when: the owner or a brief asks for a local check, or you start, stop, deploy to, test or debug on a local env (kit.local.json localEnv), or build an APK or run a task from one. Optional: never a default step. Not when: no localEnv configured -> dev-kit; deployed test env -> qa-kit; emulator lanes -> android-swarm."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; the owner or your brief asked for a local check, or you are
the main session / coordinator running, stopping or debugging an env.
**Not when:** no `localEnv` -> `dev-kit`; deployed test env -> `qa-kit`; phone lanes -> `android-swarm`; coordinating -> `orchestrate`.
**Hands off to:** `dev-kit` step 7 (MRs) after `promote`; `qa-kit` tools (`browser.mjs`, `api.ps1`) for checks; `android-swarm` for APKs.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` (+ LESSONS.local.md next to it: org/project lessons, git-ignored, when present) | step 0 |
| `scripts/localenv.ps1` | steps 1-6 (`envs`, `status`, `deploy`, `wait`, `use`, `logs`, `events`, `migrations`, `promote`, `release`, `task`); owner: `up`, `down`, `drop`, `refresh`; `_exec` internal |
| `scripts/localenvd.ps1` | never by hand: the controller `localenv.ps1` starts (env loop, train workers) |
| `scripts/localenv-lib.ps1` | library dot-sourced by both scripts; never run by hand |
| `scripts/migrations.py` | never by hand: the scripts run it to classify a deploy's migrations and plan reverts (`localenv.ps1 migrations` shows it) |
| `tests/test_migrations.py`, `tests/test-revert.ps1` | after changing migration classes or reverts: `python -X utf8 tests/test_migrations.py`; `pwsh -File tests/test-revert.ps1` |

## Model
- Flow: agent branch -> **local env** (pre-staging) -> test env -> production.
- Env = one running instance of its services (`localEnv.envs.<env>`; envs independent, ports unique across envs).
- **Release N** = target commit + agent branches merged as **layers** (worktrees `localenv-<env>-<repo>`, branch `localenv/<env>`, never pushed).
- **Controller** (one per env, auto-start, exits idle) does all work; CLI calls return within `-Wait` (8 min).
- **Train** = every request queued when it starts: one merge, one gated build, one switch-over. Conflict -> that branch refused.
  Build fails -> binary search finds the culprit, rejects it, the rest go live. Merged branches drop out.
- **Artifact services** run from a staged copy: build while serving, rollback = restart previous copy.
- **Lease** = services (+ dependencies) for N min (cap `maxLeaseMinutes`); ends early when your board session dies. A switch-over
  waits for leases on the services it restarts, never cuts them, blocks new ones meanwhile.
- **Lifecycle**: a service runs while needed (lease, `up`, browser traffic, dependents); stops after idle grace (~3x start time,
  15-60 min), at once under memory pressure. Crash -> restart, 3 tries / 30 min. Starts wait for RAM + CPU (gate's floor).
- Dependencies: linked from one install per target (`wt.ps1`; workspace packages point into the worktree). Never installed here.
- **Migrations** are audited per changeSet at deploy (`migrations.py`, rules in `localEnv.migrations`):
  - **LIGHT** (reversible DDL, small or WHERE-limited data changes with a rollback): main env, no snapshot, no sandbox. When the
    layer leaves (drop, replace, conflict, rollback) the changeSets the new release lacks are reverted newest first (`db.rollback`),
    then checked gone (`db.applied`). A staying layer that uses what they created -> snapshot restore, else the DB keeps them (said).
  - **HEAVY** (drops existing data, unbounded or bulk data, no/empty rollback, runAlways/runOnChange, unauditable SQL): own
    sandbox when configured (own build + DB copy, `sb<k>-<svc>`; `promote` moves it to the main env, snapshot first), else the
    main env with a `db.snapshot` first. No `db.rollback` hook: every migration is HEAVY.
  - `deploy` and `status` print the class and why; `migrations` the changeSets and the revert command (dry run).
- Secrets: dotenv `<kit>/localenv.local/<env>.env` only.

## Steps
```powershell
$L = '<workspace>/.claude/skills/local-env/scripts/localenv.ps1'
& $L envs; & $L status -Env <env>                                   # 1. env for your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <worktree>                  # 2. committed work only; -> LIVE r<n> | REFUSED | REJECTED | ROLLED BACK
& $L wait -Env <env> -Id <request>                                  #    if it printed "still ..."
& $L migrations -Env <env> -Branch <b>                              #    migrations: LIGHT/HEAVY per changeSet + revert plan (dry run)
& $L use -Env <env> -Agent <id> -Services <svc,..> -Minutes <m> -Session <board token> -Note "<checks>"   # 3. lease, then test
& $L status -Env <env> -Agent <id>                                  # 4. "CHANGED since your lease" -> re-run those checks
& $L logs -Env <env> -Service <svc>                                 #    debug: fix, commit, deploy again
& $L promote -Env <env> -Agent <id> -Branch <branch> -Note "<passed>"   # 5. checks passed (pre-staging stamp)
& $L release -Env <env> -Agent <id>                                 # 6. always, also on early stop
& $L task -Env <env> -Task <name> -Agent <id>                       # one-shot task on env code (APK, ...)
```
0. Read `LESSONS.md`.
1-2. Refused: `wt.ps1 sync`, resolve, deploy again. Rejected / rolled back: read the message + `logs`, fix, deploy again.
3. Declare only the services you test and an honest length; renew with `use` before it ends. Test data: prefix with your agent id.
5. Sandboxed (deploy said SANDBOX): test the `sb<k>-*` instances (lease them), then `promote` = deploy into the main env.
   Put "Locally promoted on <env> r<n>" in your final reply and MR body.

**Rules**
- No dev servers by hand (guard blocks them with `localEnv` set); never edit env worktrees, push `localenv/*`, or install there.
- A `MIGRATIONS` layer changes the shared local DB for every layer: say so. LIGHT is undone exactly when it leaves; HEAVY only by
  restoring the snapshot taken before it. Unsure? `migrations -Env <env> -Branch <b>` first: each HEAVY line names changeSet + rule.
- `up`, `down`, `drop`, `refresh`: owner / coordinator only.
- Env database: read it with the org's read-only DB tool when it has a target for the local DB (org rules / the org's database
  skill), never a DB client by hand; create test data through the env's API (`qa-kit/scripts/api.ps1 -Target <local target>`), not SQL.
- Out of RAM: starts wait, then fail with the biggest users listed; report it, never kill other processes.
- Learn: `& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill local-env -Kind <kind> -Text "<what + fix>"`.
