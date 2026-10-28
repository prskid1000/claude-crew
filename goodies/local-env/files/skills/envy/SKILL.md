---
name: local-env
description: "Load when: you reproduce, debug or test a change on the local env (dev flow steps 2 and 5), or start, stop, refresh or inspect one (kit.local.json localEnv). Not when: no localEnv -> crafty automated tests only; deployed work on a test env -> pokey; phone lanes -> phoney."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; you reproduce or test a change locally (crafty steps 2,
5), or you are the coordinator running / repairing an env.
**Not when:** no `localEnv` -> `crafty` (automated tests only); a deployed test env -> `pokey`; booting phones ->
`android-swarm`.
**Hands off to:** `crafty` step 6 (MRs + human testing doc) after every goal passed; `pokey` tools (`pokey.ps1 api`,
`browser.mjs`, `pokey.ps1 ui`) for the checks; `android-swarm` for a phone with the local-env APK.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `bossy.ps1 learn -Read -Skill local-env` |
| `envy.ps1` | Steps 1-6; owner verbs: Rules (its header lists every verb) |

## Model
- Env = ONE shared running instance of its services (`localEnv.envs.<env>`: any stack, any shape: a service is a start command
  in a folder; ports unique across envs). Release N = target commit + agent branches merged as **layers** (`localenv/<env>`,
  never pushed).
- **Train**: every deploy queued when it starts = one merge, one gated build, one switch-over; a conflict refuses that branch; a
  failed build bisects to the culprit; merged branches drop out. A layer also leaves when merged, gone from origin, its agent
  finished (`bossy.ps1 release`) or no live holder past the grace (supervise), never a paused or handed-off agent's; an env
  without lease or hold drops at the next lease (`status`: on the next lease, recent; leases.jsonl kind env-layer). A **lease** keeps services up while its holder is live
  (README "Leases") and is used (calls, traffic); unused `leaseIdleMinutes` (default `idle.graceMinutes`) it is released; only
  a person's `-Owner` lease ends at a time. A train waits for leases on what it changes at most `leaseMinutes` (30), then tells
  the holders ("deploy of <svc> starting, pause"; board inbox + `status -Agent` NOTICE), deploys, and tells them "deploy done,
  re-run your checks"; their leases stay. Only leases and holds start (or crash-restart) services, each in a start worker; no
  holder: stop after the idle grace, at once under memory pressure; an out-of-memory line in a running service's log restarts
  it. Starts wait for RAM + CPU: the keep-free floor is learned from 24 h of free-RAM samples (`status` shows it and why;
  `keepFreeGB` fixes it). A start waits for its `dependsOn` to be healthy; one failing on a dependency connection waits
  again and retries once before a train rolls back.
- **DB marks, restore, seed** (`db.engine` mysql / mariadb: goody `db-engine-presets`; nothing is ever dumped whole): a mark = a
  binlog position + the code live then (zero bytes): `mark -Name <n>` by hand, `release-<n>` before each release's code first
  runs, `use-<agent>` at each new lease, `baseline-<date>` after a green `seed`. A release with migrations (layers or the
  target) also keeps **slices**: the CREATE text of each table its migrations touch (`db.migrateSql` = the tool's dry-run SQL;
  unset + goody `liquibase`: `liquibase update-sql`; else the changed migration files' text), the rows its DDL destroys (a
  dropped / retyped column: primary key + column; a dropped table: its rows) and every view / routine / trigger / event
  definition. `restore -Mark <n> | -Release <n> [-DryRun]` (owner / coordinator): holders told to pause, the mark's code built,
  writers stopped, renames undone, each touched table back to its CREATE text (newest slice first), object definitions back,
  the row changes after the mark flashed back newest first (FK orphans / duplicate keys checked per batch), AUTO_INCREMENT reset,
  started, "restore done". A statement group on a table with triggers is undone as inverted binlog row events (no trigger
  fires); the **cascade guard** (`doctor` installs it, again after migrations; `teardown` removes it) journals the child rows
  of CASCADE / SET NULL foreign keys, which come back the same way. A table it cannot bring back exactly (structure changed with
  no slice, a cascade before the guard, a failed batch, FLOAT after DDL) falls back to its `seed` items (`tables`), named in the
  summary; refused only when the binlog lacks the rows (statement-format DML).
  `db.rollback` (a tool's rollback command; `liquibase`: tag `release-<n>` before each release's migrations, rollback to it)
  runs only with `db.restoreVia: tool-then-kit` or `-UseToolRollback`; `restore.after` [ { name, cmd } ] ({mark}) runs after
  it: reindex, cache clears, leftover lists. Marks expire with the binlog (`binlog_expire_logs_seconds`; `marks.keepDays` 30, `marks.max` 60); doctor
  checks binlog ROW / FULL images / FULL metadata / retention. `seed [-Check]`: the env's baseline data (`envs.<env>.seed`, JSON
  `items` [ { name, check: { sql, expect } | { cmd }, create: { cmd }, how, needs, tables } ], default
  `<state>/localenv/<env>.seed.json`): each check gates its create. `db.timeoutSec`: seconds per hook (a number or `{ "<hook>":
  n }`; default 1800, query 120); `tasks` (`task -Task <name>`), `sql -Query` (read-only).
- **DB temp** (mysql): once a minute the controller kills the connection with the most temp on disk (session temp tablespaces +
  TempTable mmap files) above `db.tempMaxGB` (5); `dbtemp [-Kill <id>]` lists / kills them with the env file's credential: set
  `storage.db.use` = `pwsh -NoProfile -File <kit>/skills/envy/envy.ps1 dbtemp -Env <env>`, `storage.db.kill` = the same
  `-Kill {id}`. Doctor WARNs: ibtmp1 without a max, temp caps above `db.tempMaxGB`, `max_execution_time` 0, slow log off, the
  datadir outside `storage.watch`.
- **DB buffer pool** (mysql, `db.bufferPool` set, e.g. `{}`): while a lease or train is live on any env of that db server, the
  controller grows `innodb_buffer_pool_size` online to `busyMB` (2048), and once none was for `idle.graceMinutes` (or the loop
  exits) shrinks it to `idleMB` (256): chunk-aligned, one resize at a time, never during a switch-over, one log line each; `db.expect`
  then skips the pool. Doctor: the pool and the server's RAM. Windows can keep the freed memory in mysqld's working set until a
  restart; the resize is `SET GLOBAL` only: keep the server's configured size (my.cnf / `SET PERSIST`) the idle one.
- Config: envs inherit `localEnv.defaults`, then `envs.<env>.extends` (another env); objects merge, named lists (`services`,
  `smoke`) merge by `name`. `envy.ps1 doctor` checks hook scripts, env file, ports, JAVA_HOME, builds, health and `db.expect` ({ server
  variable: value }); `deploy` stops on its FAIL lines. Service logs move to `.prev` past `logMaxMB` (100; per service too).
- **Speed and disk** (per service): `static` = the folder its `build` writes: the train builds once per release, the kit's
  static server serves a staged copy (unknown routes -> index.html; no dev server). `prepare` = a command after each sync whose
  edits are committed locally on `localenv/<env>` (a build cache at `{cache}`, outside the repo). `unpack` = a command that
  unpacks `{artifact}` into `{out}`: each library under `unpackLib` (lib) kept once by content hash, hard-linked into each
  release (it fails: the plain artifact is staged, event `unpack-fallback`, doctor warns); `keepReleases` (2) staged per service + the ones running. `aotTrain` ({aotFile}): one gated background run per
  artifact after it is up; `{aot}` in `start` = `aotUse` (`-XX:AOTCache="{aotFile}"`) once it exists. `{reactor}` in `build` =
  `-f <aggregator> -pl <module> -am` over `reactor` (module folder globs; only modules whose parent is in the module's parent
  chain, the rest come from the local repository: doctor lists them). An edited kit.local.json restarts the loop between trains. `readyPattern`: a ready log line checks health at
  once (else every 5 s; fail lines every 1 s). `mvnd` on PATH replaces mvn / mvnw in every gated build. Events: `build`,
  `stage`, `up`, `aot-train` with seconds. Idle services all stop in one tick, also while a train waits for leases.
- **Owner upkeep:** `tenant list | drop -Name <t,..> [-DryRun]` (`tenants`: { schema, table, key, name, tables, idColumns,
  nameColumns, users { table, key, tenantTable, tenantKey }, keep, keepFrom, verify }; mysql / mariadb): kept = `keep` or a
  name in `keepFrom` (default kit.local.json, targets.local.json, the seed file; { file, keys }); refused while a lease, hold or
  train is on; per tenant one transaction (the registry row, its FK children, `tables` rows by id / name column, users no
  staying tenant has), then the schema; 0 references left checked, smoke + `verify` ({tenant}) per kept tenant. `cleanup
  [-Quick] [-DryRun]`: env worktrees (uncommitted ones kept), logs, run files and `cleanup.dataRoots` children no env uses;
  `-Quick` adds old releases and `cleanup.quick` [ { name, paths, olderThanDays, cmd } ] (never what runs).
- Secrets: `<kit>/.state/localenv/<env>.env` (dotenv) only. Dependencies are linked from one install per target, never installed
  here.

## Steps
```powershell
$L = '<kit>/skills/envy/envy.ps1'
& $L envs; & $L status -Env <env>                                       # 1. which env serves your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <worktree>                      # 2. committed work only -> LIVE r<n> | REFUSED | REJECTED | ROLLED BACK
& $L wait -Env <env> -Id <request>                                      #    when it printed "still ..."
& $L use -Env <env> -Agent <id> -Services <svc,..> -Session <board token> -Note "<goals>"   # 3. lease, then test
& $L status -Env <env> -Agent <id>                                      # 4. "CHANGED since your lease" -> re-run those goals
& $L logs -Env <env> -Service <svc> [-Grep <re>] [-Since <min>]; & $L events -Env <env>   #    debug ("Debug locally")
& $L promote -Env <env> -Agent <id> -Branch <branch> -Note "<goals passed>"   # 5. every goal passed (pre-staging stamp)
& $L release -Env <env> -Agent <id>                                     # 6. always, also on early stop
```
0. `bossy.ps1 learn -Read -Skill local-env`.
1-2. REFUSED: `crafty.ps1 wt sync`, resolve, deploy again. REJECTED / ROLLED BACK: read the message + `logs`, fix, deploy again.
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
   (headless); app -> a phone with the local-env APK: `phoney.ps1 build -Local [-AppDir <your app worktree>]`,
   then `phoney.ps1 acquire -Agent <id> -Apk local` (installs it, reverses `app.localReverse` ports to this machine; log in
   against the local server), `pokey.ps1 ui ...`,
   `phoney.ps1 release` when done. Save evidence as in pokey "Evidence" (the human doc reuses it).
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
  -Run <run> -Agent <id> -Item <item> -Question "<the fix>"`, then WAIT (`decide wait -Id <id>`) and continue: an env fix request, not a
  verdict. Only org-rule out-of-scope channels stay OUT_OF_SCOPE.

**Rules**
- No dev servers by hand (the guard blocks them while `localEnv` is set); never edit env worktrees, push `localenv/*` or install
  there.
- A migration layer changes the shared local DB for every layer: say so.
- Local DB drift (a leftover table, a missing user or grant) breaking a deploy: ENV-FIX to the coordinator ("Unblock
  yourself"; it runs `seed` or `restore -Mark <n>`), never repair the shared DB by hand.
- `up` (only named services), `unhold`, `restart -Services` (keeps leases; `down` ends them), `down`, `drop`, `refresh`,
  `restore`, `teardown`, `tenant`, `cleanup`: owner / coordinator only. Out of RAM: starts wait, then fail with the biggest users listed; report it,
  never kill other processes.
- Learn: `bossy.ps1 learn -Skill local-env -Kind <kind> -Text "<what + fix>"`.

## Config (`kit.local.json` `localEnv`; an example)
```json
{
 "localEnv": {
  "_readme": "Local envs (local-env skill): the dev flow tests every change here before merge. Any shape: a service is a start command in a folder; envs.<env>.db: engine (marks + restore), schemas, seed. Secrets: <kit>/.state/localenv/<env>.env (dotenv), never here.",
  "maxLeaseMinutes": 120,
  "idle": { "minMinutes": 15, "maxMinutes": 60 },
  "envs": {
   "shop": {
    "description": "API + web of the shop",
    "services": [
     { "name": "db", "external": true, "port": 5432 },
     { "name": "api", "repo": "backend", "dir": "api", "port": 8080, "health": "http://127.0.0.1:{port}/health", "dependsOn": ["db"],
      "build": "mvn -q package -DskipTests", "artifact": "target/api-*.jar",
      "start": "java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address={debugPort} -jar \"{artifact}\" --server.port={port}", "debugPort": 5005 },
     { "name": "web", "repo": "frontend", "port": 4200, "dependsOn": ["api"], "build": "npx ng build", "static": "dist/app",
      "prepare": "npx ng config cli.cache.enabled true && npx ng config cli.cache.path \"{cache}\"" }
    ],
    "smoke": [ { "name": "api health", "service": "api", "url": "http://127.0.0.1:8080/health" } ],
    "db": { "engine": "mysql", "user": "root", "schemas": ["shop"], "schemasQuery": "<SELECT that lists more env schemas, one per row>",
     "migrateSql": "<the migration tool's dry-run SQL command, run in the service folder>" },
    "seed": "<kit>/.state/localenv/shop.seed.json"
   }
  }
 }
}
```
