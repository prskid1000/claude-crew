# Local env reference (envy SKILL.md "Model" detail)
For kitty / the coordinator (`localEnv`, owner verbs); any agent puzzled by a NOTICE, wait or lane.

## Train and leases
- Train = every deploy queued when it starts: one merge, one gated build, one switch-over; a conflict refuses that branch; a
  failed build bisects to the culprit; merged branches drop out.
- A layer also leaves when merged, gone from origin, its agent finished (`bossy.ps1 release`) or no live holder past the
  grace (supervise); never a paused or handed-off agent's. An env without lease or hold drops at the next lease (`status`,
  leases.jsonl kind env-layer).
- A lease keeps services up while its holder is live (README "Leases") and uses them (its gated check or browser.mjs session
  counts); unused `leaseIdleMinutes`: released. Only an `-Owner` lease ends at a time.
- A train waits for leases on its changes `leaseMinutes` (30; a check runs: `maxLeaseMinutes` 120), tells holders
  ("deploy of <svc> starting, pause"; inbox, `status -Agent` NOTICE), deploys, then "deploy done, re-run your checks"; leases stay.
- A train whose worker is gone (pid + start time) or quiet (phase, logs) `trainStallMinutes` (45): killed,
  its requests requeue (supervise ACT TRAIN STALLED).
- Only leases and holds start (or crash-restart) services, each in a start worker. No holder: stop after the idle grace; at
  once under memory pressure (a start waiting for RAM; a CPU wait is none).
- A dependency of a waiting, starting or train-switched service is never idle. An out-of-memory log line restarts a
  service. Idle services stop in one tick, also while a train waits.
- Starts wait for RAM (`roomWaitMinutes` 30: fails; keep-free floor learned or `keepFreeGB`) and CPU over `cpuMaxPct` 90
  (`cpuWaitMinutes` 2: starts; `status` waiting CPU until HH:mm): up to `cpuSmallStartSec` 30 none, bigger ones in one
  machine-wide queue, shortest first with aging.
- A start starts a down `dependsOn` nobody starts, waits for it to be healthy; one failing on a dependency connection
  waits again and retries once.
- A dependency still down: the release stays (it starts once that is up).
- Restarts count only real starts (backoff 3/30 min).

## Lanes
- `envs.<env>.lanes` { max, portStep 100 }: env copies side by side, each its own state, controller, train, dirs.
- Lane 1 = `<env>`, lane k = `<env><k>` (laneIds: "Names"), all derived alike: ports of services the env runs + (k-1) x portStep; in every string
  `{lane}` ('' / k), `{port:<svc>}` and `:<old port>` follow.
- `envs.<lane id>` (or an older id) keys override that lane (e.g. its own DB service; `db.port` follows its port); env file `<env>.env`, then
  `<env><k>.env`.
- `-Env <env>` (deploy, use, task) = the agent's lane, else the least busy warm lane (services up or a train; shared when
  busy; a deploy skips one others lease for a free one with room); a cold one opens when warm queue wait reaches
  `localEnv.lanes.openAfterMinutes` (learned) and free RAM minus the keep-free floor holds its services; `-Env <lane id>` /
  `-Lane <k>` opens or pins one; owner verbs: the named lane. An extra lane's services stop after `idle.graceMinutes` unheld (at least 3 start times). `status`: `lanes open
  N of M (why)`. Same layers: no target move (`refresh`).
- API calls: `pokey.ps1 api -Target <target>-<bird>` (`-falcon` = lane 1). Seed: the env's seed file; `{bird}` in it (e.g. `-Target local-shop-{bird}`).
- `envy.ps1 sql`: `SHOW COLUMNS FROM <table>` first (`Unknown column` = a guessed name).
- `services[].init` { cmd, creates, timeoutSec, donor }: runs before a start while `creates` is missing (a lane's own data
  copy); `donor` (a lane id): refused unless that lane's DB is a clean baseline (db.md).
- A lane's own DB service (port = `db.port`) down: marks wait for its start; db checks, pool, mark expiry and the temp watchdog rest.
  A train starts it for its DB steps and keeps it up.
- A new release staged for a service in start backoff resets it, like `restart`.
- `services[].shareBuild` true (a build reading no per-lane value): another lane's copy of the same inputs + config, no build.
- `services[].shareCheckBuild` (unset: on for a Maven `package` build without `prepare` or build `env`; true / false): a
  `crafty.ps1 check -Step build` jar of the same clean tree, service folder and -P / -D flags is staged, no build (a
  Spring Boot check skips the repackage: never).

## Lane service standard
Every local-env service follows it; `doctor` checks (`adapters/lane-standard.ps1`, rows WARN;
`localEnv.laneStandard: "FAIL"` makes `deploy` stop on a breach):
- One per lane and per product: no service shared across lanes or products; data folder, log folder and port carry the lane id (`{bird}` in a template).
- Started by envy (`start`, with `init` when it has data to copy) at a lease, stopped when idle (`idle.graceMinutes`); never `external` (always on) and never an OS service.
- Data and logs under the kit (`.state/localenv/lanes/<service>-<product>-<bird>`), never the system drive; low-write settings (MySQL lane ini: doublewrite off, `sync_binlog=0`).
- Names (`localEnv.laneIds`; default `bird`) `nn` lane `lane-<10 x env index + k>`, `bird` `<product>-<bird>`; shown `shop·Kestrel`; the id in `-Env`, state, logs; `{bird}` in lane paths. Older ids (`shop2`, `shop-kestrel`, pokey `local-shop2`) warn; `doctor` flags old config keys.
- Move a base env: `skills/envy/mysql-base-move.ps1` (`-Apply` copies product schemas only, `-Rename [-Ids nn]` lane names, `-Config`; config `localEnv.baseMove`).

## Config
- Envs inherit `localEnv.defaults`, then `envs.<env>.extends` (another env); objects merge, named lists (`services`, `smoke`)
  merge by `name`.
- `services[].target`: a branch other than the repo's `target`; a second target of one repo in an env gets its own lane worktree and branch `lane/<product>-<bird>-<target>`, keyed `<repo>@<target>`.
- `envy.ps1 doctor` checks hook scripts, env file, ports, JAVA_HOME, builds, health, `db.expect`, `services[].requiredEnv`
  (set per lane; `NAME=value` pins it), dependency sources, lane worktrees (`-Fix` remakes one); `deploy` stops on its FAIL lines.
- Logs move to `.prev` past `logMaxMB` (100; per service too).
- Companion services (model runner, MCP server): one each, `{port:<svc>}` in `env`, `dependsOn` top-down (`use -Services
  <top>` brings the chain); jobs reaching shared systems off (`:9`); no session-opening `health`. `aiStack`: AI path (testing.md "Proof").
- Example (`kit.local.json`):
```json
{ "localEnv": {
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
- `unpack` = a command unpacking `{artifact}` into `{out}` (failed: plain artifact staged, event `unpack-fallback`).
- `keepReleases` (2) per service + running ones.
- `stageLinks` (true): the artifact moves out of the build (copied when another service stages it); unpacked / static
  files: one per content hash in `_lib`, hard-linked (never written in place).
- `reuseBuilds` (false): its own copy of the same inputs + config re-staged, no build (unchanged: no restart);
  only for builds reading nothing outside the worktree (a local SNAPSHOT goes stale).
- `services[].inputs`: repo paths keying the build; unset: Maven: `dir`'s top folder + in-repo deps + root files, else all.
- `aotTrain` ({aotFile}): one gated background run per artifact after it is up; `{aot}` in `start` = `aotUse`
  (`-XX:AOTCache="{aotFile}"`) once it exists.
- `classpathFile` (off): thin jar + this classpath: per-release argfile; `start`: `@"{javaArgs}" <main>`.
- `{reactor}` in `build` = `-f <aggregator> -pl <module> -am` over `reactor` (module folder globs; only modules whose parent is
  in the module's parent chain, the rest from the local repository: doctor lists them). Without it (or `-pl`):
  needed modules a layer changes or a stale jar holds join its reactor (Gradle `--include-build`); never installed.
- An edited kit.local.json, envy.ps1, lib.ps1 or `adapters/` file restarts the loop between trains.
- `readyPattern`: a ready log line checks health at once (else every 5 s; fail lines every 1 s).
- `logClasses` { expected, startup, connection, 5xx, dependency }: regexes replacing the generic log classes (supervise's
  ERROR SPIKE classes; `dependency` = a start failed on a dependency that was down: wait, retry once). `expectedErrors`
  (`localEnv.` or `envs.<env>.`; a lane uses its env's): regexes of lines that never flag (a job calling an unreachable
  system). `defaultService`: what `logs` shows without `-Service` (else the only one).
- `mvnd` on PATH replaces mvn / mvnw in gated builds. Events `build`, `stage`, `up`, `aot-train` carry seconds.

## Cleanup
- `cleanup [-Quick] [-DryRun]` (owner / coordinator): env worktrees (uncommitted ones kept), logs, run files and
  `cleanup.dataRoots` children no env uses; `-Quick` adds old releases and `cleanup.quick` [ { name, paths, olderThanDays,
  cmd } ] (never what runs).
