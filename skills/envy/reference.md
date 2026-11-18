# Local env reference (envy SKILL.md "Model" detail)
Read by kitty / the coordinator editing `localEnv` or running owner verbs; by any agent puzzled by a NOTICE, a wait or a lane.

## Train and leases
- Train = every deploy queued when it starts: one merge, one gated build, one switch-over; a conflict refuses that branch; a
  failed build bisects to the culprit; merged branches drop out.
- A layer also leaves when merged, gone from origin, its agent finished (`bossy.ps1 release`) or no live holder past the
  grace (supervise); never a paused or handed-off agent's. An env without lease or hold drops at the next lease (`status`:
  on the next lease, recent; leases.jsonl kind env-layer).
- A lease keeps services up while its holder is live (README "Leases") and uses them (calls, traffic); unused
  `leaseIdleMinutes` (default `idle.graceMinutes`): released. Only a person's `-Owner` lease ends at a time.
- A train waits for leases on what it changes at most `leaseMinutes` (30), then tells the holders ("deploy of <svc> starting,
  pause"; board inbox + `status -Agent` NOTICE), deploys, tells them "deploy done, re-run your checks"; their leases stay.
- A train whose worker is gone (pid + start time: a reused pid is not it) or whose phase and log stay quiet
  `trainStallMinutes` (45): killed, its requests requeue (supervise ACT TRAIN STALLED).
- Only leases and holds start (or crash-restart) services, each in a start worker. No holder: stop after the idle grace; at
  once under memory pressure (a start waiting for RAM; a CPU wait is none).
- A dependency of a waiting, starting or train-switched service is never idle. An out-of-memory line in a running service's
  log restarts it. Idle services all stop in one tick, also while a train waits for leases.
- Starts wait for RAM + CPU: the keep-free floor is learned from 24 h of free-RAM samples (`status` shows it and why;
  `keepFreeGB` fixes it).
- A start starts a down `dependsOn` nobody starts, then waits for it to be healthy (one whose start waits for room: up to
  `roomWaitMinutes` more; `status`: waiting (CPU)); one failing on a dependency connection waits again and retries once.
- A dependency still down: the train keeps its release, no rollback (the service starts once it is up).
- Restarts count only real starts (backoff 3 / 30 min).

## Lanes
- `envs.<env>.lanes` { max, portStep 100 }: copies of an env side by side, each its own state, controller, train, worktrees,
  logs and release dirs.
- Lane 1 = `<env>`, lane k = `<env><k>`, all derived alike: ports of services the env runs + (k-1) x portStep; in every string
  `{lane}` ('' / k), `{port:<svc>}` and `:<old port>` follow.
- `envs.<env><k>` keys override that lane (e.g. its own DB service; `db.port` follows its port); env file `<env>.env`, then
  `<env><k>.env`.
- `-Env <env>` (deploy, use, task) = the lane the agent already uses, else the least busy warm lane (services up or a train;
  shared when busy); a cold lane opens only when the warm lanes' queue wait reaches `localEnv.lanes.openAfterMinutes` (learned
  from queue waits) and free RAM minus the keep-free floor holds all its services; `-Env <env><k>` / `-Lane <k>` opens or pins
  one; owner verbs act on the named lane. An extra lane's services stop after `idle.graceMinutes` unheld (at least 3 start times). `status`: `lanes open
  N of M (why)`.
- API calls: `pokey.ps1 api -Target <target><k>`. Seed: the env's seed file; `{lane}` in it (e.g. `-Target local-shop{lane}`).
- `services[].init` { cmd, creates, timeoutSec }: runs before a start while `creates` is missing (a lane's own data copy).
- A lane's own DB service (port = `db.port`) down: marks wait for its start (an init's fresh copy marks `baseline-<date>`; no
  baseline yet: a green SQL-only seed check at its start marks one); db checks, pool, mark expiry and the temp watchdog rest.
  A train starts it for its DB steps and keeps it up.
- A new release staged for a service in start backoff resets it, like `restart`.
- `services[].shareBuild` true (a build that reads no per-lane value): a lane stages another lane's recorded copy of the same
  code and build config, no build.
- `services[].shareCheckBuild` (unset: on for a Maven `package` build without `prepare` or build `env`; true / false): a
  `crafty.ps1 check -Step build` of a clean tree with the same code, service folder and -P / -D flags is staged (its jar
  copied, unchanged since), no build.

## Lane service standard
Every local-env service (mysql, search, api, web, any new one) follows it; `doctor` checks it (`adapters/lane_standard.ps1`, rows WARN;
`localEnv.laneStandard: "FAIL"` makes `deploy` stop on a breach):
- One per lane and per product: no service shared across lanes or products; data folder, log folder and port carry `{lane}` and the env.
- Started by envy (`start`, with `init` when it has data to copy) at a lease, stopped when idle (`idle.graceMinutes`); never `external` (always on) and never an OS service.
- Data and logs on D: under the kit (`.state/localenv/lanes/<service>-<env>{lane}`), never C:; low-write settings (a MySQL lane ini: doublewrite off, `sync_binlog=0`, logs off).
- Names: `localEnv.laneIds: "bird"` makes the lane id `<product>-<bird>` (rm-falcon, rm-kestrel; shown `rm·Kestrel`): `-Env`, state, logs, run dirs, cmd files, leases, `{bird}` in lane paths (`mysql-rm-{bird}`, `search-rm-{bird}`). Old ids (`rm`, `rm2`) are accepted aliases with a warning; old `<product><k>` config keys still read; `doctor` flags them.
- Move an existing one: `skills/envy/mysql-base-move.ps1` (mysql: clone per product + the `-Config` edit, also moves search data off C:).

## Config
- Envs inherit `localEnv.defaults`, then `envs.<env>.extends` (another env); objects merge, named lists (`services`, `smoke`)
  merge by `name`.
- `services[].target`: a branch other than the repo's `target`; a second target of one repo in an env (an old UI next to the
  new one) gets its own lane worktree and branch `lane/<product>-<bird>-<target>`, keyed `<repo>@<target>`.
- `envy.ps1 doctor` checks hook scripts, env file, ports, JAVA_HOME, builds, health, `db.expect` ({ server variable: value })
  and `services[].requiredEnv` (variable names each lane must set, e.g. an integration key); `deploy` stops on its FAIL lines.
- Service logs move to `.prev` past `logMaxMB` (100; per service too).
- Example (`kit.local.json`):
```json
{ "localEnv": {
  "_readme": "Local envs (local-env skill): the dev flow tests every change here before merge. Secrets: <kit>/.state/localenv/<env>.env",
  "maxLeaseMinutes": 120,
  "idle": { "minMinutes": 15, "maxMinutes": 60 },
  "envs": { "shop": {
   "description": "API + web of the shop",
   "services": [
    { "name": "db", "external": true, "port": 5432 },
    { "name": "api", "repo": "backend", "dir": "api", "port": 8080, "health": "http://127.0.0.1:{port}/health",
     "dependsOn": ["db"], "build": "mvn -q package -DskipTests", "artifact": "target/api-*.jar", "debugPort": 5005,
     "start": "java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address={debugPort} -jar \"{artifact}\" --server.port={port}" },
    { "name": "web", "repo": "frontend", "port": 4200, "dependsOn": ["api"], "build": "npx ng build", "static": "dist/app",
     "prepare": "npx ng config cli.cache.enabled true && npx ng config cli.cache.path \"{cache}\"" }
   ],
   "smoke": [ { "name": "api health", "service": "api", "url": "http://127.0.0.1:8080/health" } ],
   "db": { "engine": "mysql", "user": "root", "schemas": ["shop"], "schemasQuery": "<SELECT listing more env schemas>",
    "migrateSql": "<the migration tool's dry-run SQL command, run in the service folder>" },
   "seed": "<kit>/.state/localenv/shop.seed.json"
  } } } }
```

## Speed and disk
- Per service: `static` = the folder its `build` writes: the train builds once per release, the kit's static server serves a
  staged copy (unknown routes -> index.html; no dev server).
- `prepare` = a command after each sync whose edits are committed locally on the lane branch `lane/<product>-<bird>` (a build cache at `{cache}`,
  outside the repo).
- `unpack` = a command that unpacks `{artifact}` into `{out}` (it fails: the plain artifact is staged, event `unpack-fallback`,
  doctor warns).
- `keepReleases` (2) staged per service + the ones running.
- `stageLinks` (true): a release copies nothing: the artifact is moved out of the build (copied when another service
  stages the same one); unpacked and static files are kept once per content hash in `_lib` and hard-linked (a served file
  is never written in place); another release's files hard-linked. `unpackLib` is gone: every unpacked file is stored.
- `reuseBuilds` (false): a lane re-stages its own copy of the same tree + config instead of building; only for builds that
  read nothing outside the worktree (a SNAPSHOT dependency from the local repository would go stale).
- `aotTrain` ({aotFile}): one gated background run per artifact after it is up; `{aot}` in `start` = `aotUse`
  (`-XX:AOTCache="{aotFile}"`) once it exists.
- `{reactor}` in `build` = `-f <aggregator> -pl <module> -am` over `reactor` (module folder globs; only modules whose parent is
  in the module's parent chain, the rest come from the local repository: doctor lists them).
- An edited kit.local.json, envy.ps1, lib.ps1 or `adapters/` file restarts the loop between trains.
- `readyPattern`: a ready log line checks health at once (else every 5 s; fail lines every 1 s).
- `logClasses` { expected, startup, connection, 5xx, dependency }: regexes replacing the generic log classes (supervise's
  ERROR SPIKE classes; `dependency` = a start failed on a dependency that was down: wait, retry once). `expectedErrors`
  (`localEnv.` or `envs.<env>.`; a lane uses its env's): regexes of lines that never flag (a job calling an outside system the
  machine cannot reach). `defaultService`:
  the service `logs` shows without `-Service` (else the env's only one).
- `mvnd` on PATH replaces mvn / mvnw in every gated build. Events: `build`, `stage`, `up`, `aot-train` with seconds.

## Cleanup
- `cleanup [-Quick] [-DryRun]` (owner / coordinator): env worktrees (uncommitted ones kept), logs, run files and
  `cleanup.dataRoots` children no env uses; `-Quick` adds old releases and `cleanup.quick` [ { name, paths, olderThanDays,
  cmd } ] (never what runs).
