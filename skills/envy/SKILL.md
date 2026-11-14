---
name: local-env
description: "Load when: you reproduce, debug or test a change on the local env (dev flow steps 2 and 5), or start, stop, refresh or inspect one (kit.local.json localEnv). Not when: no localEnv -> crafty automated tests only; deployed work on a test env -> pokey; phone lanes -> phoney."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; you reproduce or test a change locally (crafty steps 2,
5), or you are the coordinator running / repairing an env.
**Not when:** no `localEnv` -> `crafty` (automated tests only); a deployed test env -> `pokey`; booting phones -> `phoney`.
**Hands off to:** `crafty` step 6 (MRs + human testing doc) after every goal passed; `pokey` tools (`pokey.ps1 api`,
`browser.mjs`, `pokey.ps1 ui`) for the checks; `phoney` for a phone with the local-env APK; `datay` for DB marks, restores, seed.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `bossy.ps1 learn -Read -Skill local-env` |
| `envy.ps1` | Steps 1-6; owner verbs: Rules |
| `reference.md` | "Train and leases", "Lanes", "Config" (shape + example), "Speed and disk", "Cleanup": kitty / coordinator editing `localEnv` or running owner verbs; a NOTICE, wait or lane you do not follow |
| `db.md` | "DB marks, restore, seed", "DB temp", "DB buffer pool", "Tenants": datay, coordinator `mark` / `restore` / `seed` / `tenant` / `dbtemp`, a migration layer, DB drift |
| `adapters/db_presets.ps1` | dot-sourced by `envy.ps1` when `db.engine` is set: db hooks, marks, restore, dbtemp, pool, tenant (db.md) |
| `adapters/db_flashback.py` | run by `envy.ps1` `restore`, release slices, the cascade guard (`doctor`), `tenant import` masking (db.md) |

## Model
- Env = ONE shared running instance of its services (`localEnv.envs.<env>`: any stack; a service = a start command in a folder;
  ports unique across envs). Release N = target commit + agent branches merged as **layers** (`localenv/<env>`, never pushed).
- **Train**: every deploy queued when it starts = one merge, one gated build, one switch-over; a conflict refuses that branch;
  a failed build bisects to the culprit (reference.md "Train and leases").
- **Lease** (`use`): keeps the services you test up while you use them (README "Leases"); unused past `leaseIdleMinutes`:
  released. A train changing a leased service tells you "deploy of <svc> starting, pause", then "deploy done, re-run your checks".
- Starts wait for RAM + CPU; idle services stop after the grace. **Lanes**: side-by-side copies `<env><k>` (API target
  `<target><k>`); `deploy` / `use` pick yours (reference.md "Lanes").
- **DB** (`db.engine` mysql / mariadb): marks, restore, seed baseline; nothing is ever dumped whole (db.md).
- Secrets: `<kit>/.state/localenv/<env>.env` (dotenv) only. Dependencies are linked from one install per target, never
  installed here.

## Steps
```powershell
$L = '<kit>/skills/envy/envy.ps1'
& $L envs; & $L status -Env <env>                                       # 1. which env serves your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <worktree>                      # 2. committed work only -> LIVE r<n> | REFUSED | ...
& $L wait -Env <env> -Id <request>                                      #    when it printed "still ..."
& $L use -Env <env> -Agent <id> -Services <svc,..> -Session <board token> -Note "<goals>"   # 3. lease, then test
& $L status -Env <env> -Agent <id>                                      # 4. "CHANGED since your lease" -> re-run those goals
& $L logs -Env <env> -Service <svc> [-Grep <re>] [-Since <min>]; & $L events -Env <env>   #    debug ("Debug locally")
& $L promote -Env <env> -Agent <id> -Branch <branch> -Note "<goals passed>"   # 5. every goal passed (pre-staging stamp)
& $L release -Env <env> -Agent <id>                                     # 6. always, also on early stop
```
0. `bossy.ps1 learn -Read -Skill local-env`.
1-2. `deploy` prints LIVE r<n> | REFUSED | REJECTED | ROLLED BACK; "[<env><k>] lane k": test there (target `<target><k>`).
   REFUSED: `crafty.ps1 wt sync`, resolve, deploy again. REJECTED / ROLLED BACK: read the message + `logs`, fix, deploy again.
3. Lease only the services you test, right before the checks; it lives while you use it (README "Leases"); exit 3 = no lease
   yet, call again. A NOTICE "deploy of <svc> starting, pause" (board inbox or `status -Agent`): stop checks there until
   "deploy done", then re-run the checks of that service. Release right after your last check.
   Test data: prefix with your agent id.

## Local testing (dev flow step 5)
1. The testing-goals doc (`skills/crafty/templates.md`) lists every goal with its check, Expected and proof.
   Deploy your branch (step 2).
2. Data: `seed -Check -Env <env>` (the baseline fixtures; drift -> ENV-FIX: the coordinator runs `seed`); verify by id before
   creating anything; create only what is missing through the env's API (`pokey.ps1 api -Target <local
   target>`), never SQL; prefix it with your agent id; note what you created in the goals doc.
3. Run each goal with the tool its proof names: API -> `pokey.ps1 api -Target <local target> -Save`; web -> `browser.mjs`
   (headless); app -> a phone with the local-env APK through the `phoney` skill: `build -Local [-AppDir <your app worktree>]`,
   then `acquire -Agent <id> -Apk local` (installs it, reverses `app.localReverse` ports to this machine; log in against the
   local server), `pokey.ps1 ui ...`, `release` when done. Save evidence as in pokey "Evidence" (the human doc reuses it).
4. A goal fails, a log shows an error, or a request returns 5xx: Debug locally, fix (crafty step 3), commit, deploy again,
   re-run ALL goals (a fix can break an earlier one). Max 3 rounds; then report FAIL with the failing goals and evidence (a
   stronger round follows, then the coordinator). Never BLOCKED for an env reason: "Unblock yourself".
5. Every goal PASS and the logs clean: `promote`, `release`, then crafty step 6. Put "Local env <env> r<n>: goals passed" in
   the MR and the report.

## Debug locally (every bug: QA run, [Bug] task, failedTesting task, user report, a failing local check)
1. Reproduce BEFORE fixing: lease the services, load the data the bug needs (baseline fixtures), run the reported steps with
   `pokey.ps1 api` / headless browser / a phone lane with the local-env APK.
2. Read the evidence: `envy.ps1 logs -Env <env> -Service <svc>` (+ `events`), DB state through the org's read-only DB tool's
   local target (org rules), the network calls (`browser.mjs` `s.net.failed`, `saveNet`).
3. Attach a debugger when the service has a `debugPort` (`envy.ps1 envs` prints it): JVM jdwp, node --inspect, debugpy, ...
4. Record the reproduction (steps, request/response, log lines, screenshots) in the testing-goals doc under "Reproduction".
5. Fix, then re-run the SAME reproduction as the first local check; then all goals.
6. Cannot reproduce locally (data, integration or config only on the test env): first make it local ("Unblock yourself"); a
   remote-only dependency: say why in the goals doc, then reproduce on the test env (pokey tools, never production) and continue.

## Unblock yourself (we own the local env: a local check never ends NOT_TESTED, a local loop never BLOCKED for an env reason)
- Data: the env API (baseline first, verify by id); config / flags / env vars: `<kit>/.state/localenv/<env>.env` or the app's
  settings API; services: `deploy`, `use`, `logs`, `events`; not deployed: `deploy` the branch; phone-only: a lane with the
  local-env APK; a missing integration: wire it locally or point it at a stub or the test env's service; env-file lines and stubs
  you add go in the lease note and are removed before you release.
- Coordinator-only (`up`, `restart`, `down`, `refresh`, `drop`, shared DB repair): ENV-FIX `bossy.ps1 decide ask -Kind envfix
  -Run <run> -Agent <id> -Item <item> -Question "<the fix>"`, then WAIT (`decide wait -Id <id>`) and continue: an env fix
  request, not a verdict. Only org-rule out-of-scope channels stay OUT_OF_SCOPE.
- An ENV-FIX that edits `<env>.env` takes effect only after a restart: once the holder releases, the fixer runs `envy restart
  -Services <svc>` (the services reading that line), then rechecks the failing step before `decide answer`.

**Rules**
- No dev servers by hand (the guard blocks them while `localEnv` is set); never edit env worktrees, push `localenv/*` or install
  there.
- A migration layer changes the shared local DB for every layer: say so.
- Local DB drift (a leftover table, a missing user or grant) breaking a deploy: ENV-FIX to the coordinator ("Unblock
  yourself"; it runs `seed` or `restore -Mark <n>`), never repair the shared DB by hand.
- `up` (only named services), `unhold`, `restart -Services` (keeps leases; `down` ends them), `down`, `drop`, `refresh`,
  `restore`, `teardown`, `tenant`, `cleanup`: owner / coordinator only.
- Out of RAM: starts wait, then fail with the biggest users listed; report it, never kill other processes.
- Learn: `bossy.ps1 learn -Skill local-env -Kind <kind> -Text "<what + fix>"`.
