---
name: local-env
description: "Load when: you reproduce, debug or test a change on the local env (dev flow steps 2 and 5), or you start, stop, refresh or inspect a local env (kit.local.json localEnv). Not when: no localEnv is configured -> dev-kit automated tests only; testing deployed work on a test env -> qa-kit; phone lanes themselves -> android-swarm."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; you reproduce or test a change locally (dev-kit steps 2, 5),
or you are the coordinator running / repairing an env.
**Not when:** no `localEnv` -> `dev-kit` (automated tests only); a deployed test env -> `qa-kit`; booting phones -> `android-swarm`.
**Hands off to:** `dev-kit` step 6 (MRs + human testing doc) after every goal passed; `qa-kit` tools (`qa.ps1 api`,
`browser.mjs`, `qa.ps1 ui`) for the checks; `android-swarm` for a phone with the local-env APK.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill local-env` |
| `localenv.ps1` | steps 1-6 (`envs`, `status`, `deploy`, `wait`, `use`, `logs`, `events`, `migrations`, `promote`, `release`, `task`); owner: `up`, `down`, `drop`, `refresh`; `_daemon` / `_exec` are internal |
| `migrations.py` | run by `localenv.ps1` to class a deploy's migrations and plan reverts (`localenv.ps1 migrations` shows it); `selftest` after changing it |

## Model
- Env = ONE shared running instance of its services (`localEnv.envs.<env>`: any stack, any shape: a service is a start command
  in a folder; ports unique across envs). Release N = target commit + agent branches merged as **layers** (`localenv/<env>`, never pushed).
- **Train**: every deploy queued when it starts = one merge, one gated build, one switch-over; a conflict refuses that branch; a
  failed build bisects to the culprit; merged branches drop out. A **lease** keeps services up for N min and is never cut by a
  switch-over. Services stop after idle grace, at once under memory pressure; starts wait for RAM + CPU (the gate's floor).
- **Migrations** (`localEnv.migrations` rules): LIGHT (reversible, small) run on the main env and are reverted exactly when the
  layer leaves; HEAVY (drops data, unbounded, no rollback, unauditable) get a sandbox (own build + DB copy, `sb<k>-<svc>`) or a
  DB snapshot first. `deploy` / `status` print the class and why; `migrations -Branch <b>` = dry run with the revert plan.
- Secrets: `<kit>/.state/localenv/<env>.env` (dotenv) only. Dependencies are linked from one install per target, never installed here.

## Steps
```powershell
$L = '<kit>/skills/local-env/localenv.ps1'
& $L envs; & $L status -Env <env>                                       # 1. which env serves your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <worktree>                      # 2. committed work only -> LIVE r<n> | REFUSED | REJECTED | ROLLED BACK
& $L wait -Env <env> -Id <request>                                      #    when it printed "still ..."
& $L use -Env <env> -Agent <id> -Services <svc,..> -Minutes <m> -Session <board token> -Note "<goals>"   # 3. lease, then test
& $L status -Env <env> -Agent <id>                                      # 4. "CHANGED since your lease" -> re-run those goals
& $L logs -Env <env> -Service <svc>; & $L events -Env <env>             #    debug (see "Debug locally")
& $L promote -Env <env> -Agent <id> -Branch <branch> -Note "<goals passed>"   # 5. every goal passed (pre-staging stamp)
& $L release -Env <env> -Agent <id>                                     # 6. always, also on early stop
```
0. `orch.ps1 learn -Read -Skill local-env`.
1-2. REFUSED: `dev.ps1 wt sync`, resolve, deploy again. REJECTED / ROLLED BACK: read the message + `logs`, fix, deploy again.
3. Lease only the services you test, for an honest length; renew with `use` before it ends. Test data: prefix with your agent id.
5. Sandboxed (deploy said SANDBOX): test the `sb<k>-*` instances, then `promote` moves the branch into the main env.

## Local testing (dev flow step 5)
1. The testing-goals doc (`dev-kit/templates.md`) lists every goal with its check, Expected and proof. Deploy your branch (step 2).
2. Data: reuse the env's baseline fixtures (the org's baseline file / seeded test tenant or account named in org rules or the
   brief); verify by id before creating anything; create only what is missing through the env's API (`qa.ps1 api -Target <local
   target>`), never SQL; prefix it with your agent id; note what you created in the goals doc.
3. Run each goal with the tool its proof names: API -> `qa.ps1 api -Target <local target> -Save`; web -> `browser.mjs` (headless);
   app -> a phone with the local-env APK: `swarm.ps1 build -Local [-AppDir <your app worktree>]`, then `swarm.ps1 acquire -Agent
   <id> -Apk local` (installs it, reverses `app.localReverse` ports to this machine; log in against the local server), `qa.ps1 ui ...`,
   `swarm.ps1 release` when done. Save evidence as in qa-kit "Evidence" (the human doc reuses it).
4. A goal fails, a log shows an error, or a request returns 5xx: Debug locally, fix (dev-kit step 3), commit, deploy again,
   re-run ALL goals (a fix can break an earlier one). Max 3 rounds; then report BLOCKED with the failing goals and evidence.
5. Every goal PASS and the logs clean: `promote`, `release`, then dev-kit step 6. Put "Local env <env> r<n>: goals passed" in the
   MR and the report.

## Debug locally (every bug: QA run, [Bug] task, failedTesting task, user report, a failing local check)
1. Reproduce BEFORE fixing: lease the services, load the data the bug needs (baseline fixtures), run the reported steps with
   `qa.ps1 api` / headless browser / a phone lane with the local-env APK.
2. Read the evidence: `localenv.ps1 logs -Env <env> -Service <svc>` (+ `events`), DB state through the org's read-only DB tool's
   local target (org rules), the network calls (`browser.mjs` `s.net.failed`, `saveNet`).
3. Attach a debugger when the service has a `debugPort` (`localenv.ps1 envs` prints it): JVM jdwp, node --inspect, debugpy, ...
4. Record the reproduction (steps, request/response, log lines, screenshots) in the testing-goals doc under "Reproduction".
5. Fix, then re-run the SAME reproduction as the first local check; then all goals.
6. Cannot reproduce locally (data, integration or config only on the test env): say why in the goals doc, then reproduce on the
   test env (qa-kit tools, never production) and continue.

**Rules**
- No dev servers by hand (the guard blocks them while `localEnv` is set); never edit env worktrees, push `localenv/*` or install there.
- A migration layer changes the shared local DB for every layer: say so. Unsure? `migrations -Env <env> -Branch <b>` first.
- Local DB drift (a leftover table, a missing user or grant) breaking a deploy: report it to the coordinator (`refresh` / owner),
  never repair the shared DB by hand.
- `up`, `down`, `drop`, `refresh`: owner / coordinator only. Out of RAM: starts wait, then fail with the biggest users listed;
  report it, never kill other processes.
- Learn: `orch.ps1 learn -Skill local-env -Kind <kind> -Text "<what + fix>"`.
