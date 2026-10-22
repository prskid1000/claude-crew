---
name: local-env
description: "Load when: you reproduce, debug or test a change on the local env (dev flow steps 2 and 5), or start, stop, refresh or inspect one (kit.local.json localEnv). Not when: no localEnv -> dev-kit automated tests only; deployed work on a test env -> qa-kit; phone lanes -> android-swarm."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; you reproduce or test a change locally (dev-kit steps 2,
5), or you are the coordinator running / repairing an env.
**Not when:** no `localEnv` -> `dev-kit` (automated tests only); a deployed test env -> `qa-kit`; booting phones ->
`android-swarm`.
**Hands off to:** `dev-kit` step 6 (MRs + human testing doc) after every goal passed; `qa-kit` tools (`qa.ps1 api`,
`browser.mjs`, `qa.ps1 ui`) for the checks; `android-swarm` for a phone with the local-env APK.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill local-env` |
| `localenv.ps1` | Steps 1-6; owner verbs: Rules (its header lists every verb) |

## Model
- Env = ONE shared running instance of its services (`localEnv.envs.<env>`: any stack, any shape: a service is a start command
  in a folder; ports unique across envs). Release N = target commit + agent branches merged as **layers** (`localenv/<env>`,
  never pushed).
- **Train**: every deploy queued when it starts = one merge, one gated build, one switch-over; a conflict refuses that branch; a
  failed build bisects to the culprit; merged branches drop out. A **lease** keeps services up while its holder is live
  (README "Leases"), never cut by a switch-over; only a person's `-Owner` lease ends at a time. Only leases and holds start
  (or crash-restart) services; no holder: stop after `idle.graceMinutes` + idle grace (normal idle), at once under memory
  pressure; starts wait for RAM + CPU (the gate's floor).
- **Migrations**: a layer with migrations changes the shared DB: `db.snapshot` runs before the switch-over, `db.restore` on
  rollback; a layer that leaves keeps its DB changes. `sandbox`: a migrating branch gets its own build + DB copy (`sb<k>-<svc>`);
  `db.rollback`: LIGHT layers revert exactly on leave (`migrations -Env <env> [-Branch]` shows the plan; classes need the extra
  `migration-classify`); `tasks` (`task -Task <name>`), `sql -Query` (read-only). `db.engine` presets: extra `db-engine-presets`
  (`localenv.ps1` names the extra when the config needs one).
- Secrets: `<kit>/.state/localenv/<env>.env` (dotenv) only. Dependencies are linked from one install per target, never installed
  here.

## Steps
```powershell
$L = '<kit>/skills/local-env/localenv.ps1'
& $L envs; & $L status -Env <env>                                       # 1. which env serves your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <worktree>                      # 2. committed work only -> LIVE r<n> | REFUSED | REJECTED | ROLLED BACK
& $L wait -Env <env> -Id <request>                                      #    when it printed "still ..."
& $L use -Env <env> -Agent <id> -Services <svc,..> -Session <board token> -Note "<goals>"   # 3. lease, then test
& $L status -Env <env> -Agent <id>                                      # 4. "CHANGED since your lease" -> re-run those goals
& $L logs -Env <env> -Service <svc>; & $L events -Env <env>             #    debug (see "Debug locally")
& $L promote -Env <env> -Agent <id> -Branch <branch> -Note "<goals passed>"   # 5. every goal passed (pre-staging stamp)
& $L release -Env <env> -Agent <id>                                     # 6. always, also on early stop
```
0. `orch.ps1 learn -Read -Skill local-env`.
1-2. REFUSED: `dev.ps1 wt sync`, resolve, deploy again. REJECTED / ROLLED BACK: read the message + `logs`, fix, deploy again.
3. Lease only the services you test; it lives while you do (README "Leases"); exit 3 = no lease yet, call again.
   Test data: prefix with your agent id.

## Local testing (dev flow step 5)
1. The testing-goals doc (`skills/dev-kit/templates.md`) lists every goal with its check, Expected and proof.
   Deploy your branch (step 2).
2. Data: reuse the env's baseline fixtures (the org's baseline file / seeded test tenant or account named in org rules or the
   brief); verify by id before creating anything; create only what is missing through the env's API (`qa.ps1 api -Target <local
   target>`), never SQL; prefix it with your agent id; note what you created in the goals doc.
3. Run each goal with the tool its proof names: API -> `qa.ps1 api -Target <local target> -Save`; web -> `browser.mjs`
   (headless); app -> a phone with the local-env APK: `swarm.ps1 build -Local [-AppDir <your app worktree>]`,
   then `swarm.ps1 acquire -Agent <id> -Apk local` (installs it, reverses `app.localReverse` ports to this machine; log in
   against the local server), `qa.ps1 ui ...`,
   `swarm.ps1 release` when done. Save evidence as in qa-kit "Evidence" (the human doc reuses it).
4. A goal fails, a log shows an error, or a request returns 5xx: Debug locally, fix (dev-kit step 3), commit, deploy again,
   re-run ALL goals (a fix can break an earlier one). Max 3 rounds; then report FAIL with the failing goals and evidence (a
   stronger round follows, then the coordinator). Never BLOCKED for an env reason: "Unblock yourself".
5. Every goal PASS and the logs clean: `promote`, `release`, then dev-kit step 6. Put "Local env <env> r<n>: goals passed" in
   the MR and the report.

## Debug locally (every bug: QA run, [Bug] task, failedTesting task, user report, a failing local check)
1. Reproduce BEFORE fixing: lease the services, load the data the bug needs (baseline fixtures), run the reported steps with
   `qa.ps1 api` / headless browser / a phone lane with the local-env APK.
2. Read the evidence: `localenv.ps1 logs -Env <env> -Service <svc>` (+ `events`), DB state through the org's read-only DB tool's
   local target (org rules), the network calls (`browser.mjs` `s.net.failed`, `saveNet`).
3. Attach a debugger when the service has a `debugPort` (`localenv.ps1 envs` prints it): JVM jdwp, node --inspect, debugpy, ...
4. Record the reproduction (steps, request/response, log lines, screenshots) in the testing-goals doc under "Reproduction".
5. Fix, then re-run the SAME reproduction as the first local check; then all goals.
6. Cannot reproduce locally (data, integration or config only on the test env): first make it local ("Unblock yourself"); a
   remote-only dependency: say why in the goals doc, then reproduce on the test env (qa-kit tools, never production) and continue.

## Unblock yourself (we own the local env: a local check never ends NOT_TESTED, a local loop never BLOCKED for an env reason)
- Data: the env API (baseline first, verify by id); config / flags / env vars: `<kit>/.state/localenv/<env>.env` or the app's
  settings API; services: `deploy`, `use`, `logs`, `events`; not deployed: `deploy` the branch; phone-only: a lane with the
  local-env APK; a missing integration: wire it locally or point it at a stub or the test env's service; env-file lines and stubs
  you add go in the lease note and are removed before you release.
- Coordinator-only (`up`, `restart`, `down`, `refresh`, `drop`, shared DB repair): ENV-FIX `orch.ps1 decide ask -Kind envfix
  -Run <run> -Agent <id> -Item <item> -Question "<the fix>"`, then WAIT (`decide wait -Id <id>`) and continue: an env fix request, not a
  verdict. Only org-rule out-of-scope channels stay OUT_OF_SCOPE.

**Rules**
- No dev servers by hand (the guard blocks them while `localEnv` is set); never edit env worktrees, push `localenv/*` or install
  there.
- A migration layer changes the shared local DB for every layer: say so.
- Local DB drift (a leftover table, a missing user or grant) breaking a deploy: ENV-FIX to the coordinator ("Unblock
  yourself"), never repair the shared DB by hand.
- `up` (only named services), `unhold`, `restart -Services` (keeps leases; `down` ends them), `down`, `drop`, `refresh`: owner /
  coordinator only. Out of RAM: starts wait, then fail with the biggest users listed; report it, never kill other processes.
- Learn: `orch.ps1 learn -Skill local-env -Kind <kind> -Text "<what + fix>"`.

## Config (`kit.local.json` `localEnv`; an example)
```json
{
 "localEnv": {
  "_readme": "Local envs (local-env skill): the dev flow tests every change here before merge. Any shape: a service is a start command in a folder; envs.<env>.db.snapshot / restore: commands ({snapshot} = the name) run around migration layers. Secrets: <kit>/.state/localenv/<env>.env (dotenv), never here.",
  "maxLeaseMinutes": 120,
  "idle": { "minMinutes": 15, "maxMinutes": 60 },
  "envs": {
   "shop": {
    "description": "API + web of the shop",
    "services": [
     { "name": "db", "external": true, "port": 5432 },
     { "name": "api", "repo": "backend", "dir": "api", "port": 8080, "health": "http://localhost:8080/health", "dependsOn": ["db"],
      "build": "mvn -q package -DskipTests", "artifact": "target/api-*.jar",
      "start": "java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address={debugPort} -jar \"{artifact}\" --server.port={port}", "debugPort": 5005 },
     { "name": "web", "repo": "frontend", "port": 4200, "hot": true, "dependsOn": ["api"], "start": "npx ng serve --port {port}" }
    ],
    "smoke": [ { "name": "api health", "service": "api", "url": "http://localhost:8080/health" } ],
    "db": { "snapshot": "<command that saves the shop DB as {snapshot}>", "restore": "<command that loads snapshot {snapshot}>" }
   }
  }
 }
}
```
