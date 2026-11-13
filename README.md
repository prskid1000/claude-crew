<p align="center"><img src="assets/claude-crew.svg" alt="claude-crew" width="330"></p>
<p align="center"><b>A crew of AI agents that builds, tests, ships and watches your code, with one coordinator in charge.</b></p>
<p align="center"><img src="assets/badges.svg" alt="license MIT · agents: Claude Code, Codex, Antigravity · scripts: PowerShell 7, Python 3 · telemetry: none"></p>

# claude-crew

**[Interactive kit map ->](https://prskid1000.github.io/claude-crew/)** (every command, step, decision and loop; built on each push with the `flow-map` goody)

A multi-agent dev + QA kit for Claude Code (ports for Codex and Antigravity) for **any project type**: any stack, migration tool,
local env shape, test env, deploy mechanism and tracker. Org specifics live only in git-ignored config
(`skills/crafty/kit.local.json`, `rules/*.local.md`); the kit assumes no tenants, no web + API + app trio, no database.
Every diagram is generated at pre-commit (`kitbag.py flow --readme`) from the manifest, Router and flow model.

## The crew
The owner talks to the coordinator; it routes each request to a workflow or one crew member (`kit.example.json` `_manifest`).
<!-- kit-graph:start crew -->
```mermaid
flowchart LR
  OW(["owner"]) -->|"asks, says deploy env"| CO["coordinator: Router + Events"]
  CO -->|"R5"| W_buildy[/"buildy"/]
  W_buildy -->|"spawns"| A_rechy("rechy")
  W_buildy -->|"spawns"| A_devy("devy")
  W_buildy -->|"spawns"| A_revy("revy")
  W_buildy -->|"spawns"| A_datay("datay")
  W_buildy -->|"spawns"| A_kitty("kitty")
  CO -->|"R8"| W_testy[/"testy"/]
  W_testy -->|"spawns"| A_checky("checky")
  W_testy -->|"spawns"| A_kitty("kitty")
  CO -->|"R4"| W_tidy[/"tidy"/]
  W_tidy -->|"spawns"| A_kitty("kitty")
  CO -->|"R5, R6"| A_devy("devy")
  CO -->|"R13, R14"| A_revy("revy")
  CO -->|"R10"| A_checky("checky")
  CO -->|"R2, R3"| A_kitty("kitty")
  CO -->|"R5"| A_briefy("briefy")
  CO -->|"R17"| A_rechy("rechy")
  CO -->|"R15"| A_datay("datay")
  CO -->|"R7"| A_opsy("opsy")
  CO -->|"R16"| A_watchy("watchy")
  CO -->|"R19"| A_vidy("vidy")
```
<!-- kit-graph:end -->
<!-- kit-graph:start table-crew -->
| Agent | Job | Kinds / roles | Used in | Can't | Character |
|---|---|---|---|---|---|
| `devy` | builder: makes or changes anything in product repos through the dev flow | feature · fix · refactor · migration · config · doc · tests · spike · repro | /buildy, R5, R6 | deploy, merge into deploy branches, edit the kit | pragmatic builder: "Small, tested, shipped." |
| `revy` | reviewer: reviews anything and suggests concrete changes | mr · kit · doc · qa · plan · module · config | /buildy, R13, R14 | edit anything (suggests only) | sceptical, blunt: "Show me the test." |
| `checky` | tester: tests or verifies anything, always with evidence | task · smoke · regression · repro · data · perf · claim (roles: lead / test / verify) | /testy, R10 | edit code, leave its target, load shared envs | paranoid, evidence-obsessed: "Screenshot or it didn't happen." |
| `kitty` | kit caretaker: the kit and the machine setup | build · fix · audit · retro · setup · env · recover · docs | /tidy, R2, R3 | touch product repos | tidy and frugal: "Measure before and after." |
| `briefy` | brief writer: /buildy brief, contracts, impact check, rule changes | brief · bugfix · rule-change | R5, E8 | write code, launch runs | exacting planner: "Who owns this field?" |
| `rechy` | researcher: cited answers before building or deciding | question · compare · library · licence · spike | /buildy, R17 | edit anything but its findings | skeptical librarian: "Cite it or drop it." |
| `datay` | data guardian: test data, local DB, migration data, backfills | cleanup · fixture · migration · localdb · backfill · check | /buildy, R15, E2, E7 | write production, edit code or the kit | meticulous archivist: "Mark it, count it, then touch it." |
| `opsy` | deploy pilot: deploys on a person's word, verifies, rolls back | deploy · rollback · status · secret | R7, E5 | deploy without a person's word, edit code | cautious pilot: "Checklist first." |
| `watchy` | on-call watcher: errors of deployed envs, one [Bug] per issue | window · sweep · triage | R16, E15 | change systems, deploy, move tasks | calm on-call engineer: "What changed, and since when?" |
| `vidy` | video reader: exact screen text, timed answers | question · index · segment | R19 | edit code, tracker, kit | frame-by-frame witness: "Which frame shows it?" |
<!-- kit-graph:end -->
Board and disagreements: AGENTS.md "Crew".

## Flows
- `/buildy`: devy codes and tests on the local env in a loop, revy reviews, the workflow merges; only a person's `deploy <env>`
  ships it (`deploy.trigger`).
- `/testy`: checky lead / test / verify per testing doc; the result rule closes the task, fails it back to dev or files one [Bug].
- Every task the kit builds: an Items list (subtasks: the whole templates.md task-description; `tracker create -Parent` and the
  launch refuse less), both testing-doc links before promoted; a parent with every subtask closed closes only on the owner's
  answer to its one close ask (goody task-rollup).
- Tasks move through logical tracker statuses (`tracker.statuses` maps them to your board's names). The local env: one shared
  instance per env, branches as layers. WIP commits after every dev-flow step: a fresh agent loses nothing after a crash. The kit
  learns from every run (`/tidy`) and fixes itself in a kit worktree.
<!-- kit-graph:start table-workflows -->
| Workflow | Covers | Crew | Router row |
|---|---|---|---|
| `/buildy` | any multi-item build: features, fixes, refactors, migrations, bug waves, resume, duels | `rechy`, `devy`, `revy`, `datay`, `kitty` | R5 |
| `/testy` | any test run: tracker selection, smoke after a deploy, regression sweep, retest, on local or a test env | `checky`, `kitty` | R8 |
| `/tidy` | kit upkeep in 2-5 min: `bossy.ps1 tidy prep` (digest + upkeep, no LLM), then one kitty: lessons + rule updates | `kitty` | R4 |
<!-- kit-graph:end -->

## Budget and handoff
The rule: "Configuration" `budget`; per-tool defaults in the table. Models (`MODELS` in each workflow; `agents[].model` / `items[].model`
win): devy, revy, checky test / verify / prepare = sonnet; close, ci, ship, learn = haiku; one stronger retry = opus; `complex` (buildy,
`bugbrief -Complex`) = the session model. Agents spawned by hand: their agent file's `model`.
<!-- kit-graph:start table-budget -->
| Tool / window | Budget | Source |
|---|---|---|
| claude-1m | 967000 | Claude Code docs: 1M models compact at ~967k |
| claude-200k | 167000 | conservative 83.5% of 200k (docs: at the limit) |
| codex | 0.9 x window | 0.9 x the models_cache.json window; auto_compact_token_limit wins |
| antigravity | 0.8 x window | unverified: 0.8 x the model window |
| unknown | 160000 | 0.8 x 200k |
<!-- kit-graph:end -->

## Leases
One rule (`lib.ps1` `Update-KitLease`, lint LEASE-HOLDER) for env services, browser tabs, phones, builds, runtimes (goody `runtimes`);
only owner holds (`envy.ps1 up -Owner`, phone `manual`; goody `local-env`, goody `android-swarm`) keep minutes, with a reminder.
The local STT server (`local-stt`; goody `media-evidence`): one job at a time, bound to the job's process, its RAM through the memory gate.
The GPU (`gpu.exclusive.<kind>`, `lib.ps1` `Use-KitGpu`): one kind at a time (e.g. lane emulators); another kind waits, supervise
shows `waiting for GPU: held by <holder>`. `processes` (regex): running processes that hold it; `idleExcept` (regex of the kind's own backend):
it also waits while nvidia-smi shows any other GPU process, or `idleMaxMB` (512) used with its backend down; `minFreeMB` (default: the
caller's, lanes 2048; 0 off): waits while nvidia-smi `memory.free` is lower, then refuses naming the GPU processes; no nvidia-smi: one warning, no check.
Test locks (`repos[].exclusiveTests` `[{dir, match, lock}]`, `lib.ps1` `Use-KitLock`): `check -Step test` under `dir` whose test names or
sources match the regex `match` (no names: all) holds lock `lock`;
others queue (`waiting for lock <name> held by <holder> since <t>`), cap = learned `gate.waitMinutes` (context `lock:<name>`), then exit 3; an ended holder is dropped; supervise RAM rows show `lock <name>`.
- **End:** an agent ends with `bossy.ps1 release -Agent <id>` (every lease of that id: lane + its emulator, env and its layers, GPU, build, tabs);
  `board leave` and /buildy, /testy after each agent stage repeat it. A holder on the board with no live entry is dead (its holder
  pid is the shared session process); `supervise -AutoFix` reclaims every kind after the grace (lanes stop with `emu kill`).
- **Activity:** one source (`lib.ps1` `Get-KitLastActivity`) for leases, STUCK rows, stale board rows and shell owners: the newest of
  the board beat and the agent's transcript write (+ task outputs it names); a workflow step counts under any run name it joined with.
- **Log:** `.state/leases.jsonl` (`lib.ps1` `Write-KitLeaseLog`): one line per acquire / release / reclaim / down (kind, name, agent,
  session, run, since, reason); the newest half kept past 1 MB. Last used: `bossy.ps1 status`, the lane and env status (goody `android-swarm`, goody `local-env`).

## Pause and resume
- **Checkpoints** (both paths): each agent runs `crafty.ps1 checkpoint` at every step boundary (worktree, commit, testing goals,
  loop round, MR, review, CI, testing doc, tracker, merge; QA: each check): `work/agents/<id>/resume-<run>.json` + `.md` (per run: same-named agents never overwrite; an old `resume.json` is still read). Kit
  state is written atomically (temp + rename) or appended; leases, gate slots and board entries keep their process id with its
  start time (a pid reused after a cold boot holds nothing); a lock whose holder died is taken at once (Windows).
- **Pause** (power off, a day offline): `bossy.ps1 pause -All | -Run <run> [-Reason]` returns in seconds; `pause -Status`
  says when it is "safe to power off" (exit 1 until then; `-Wait <min>` blocks as before): every agent left, or not yet left
  but at a checkpoint with a clean worktree and no build. Gated builds and tests of the paused agents stop at once (queued
  ones never start; the gate says `redo`); agents read PAUSE on their next `board beat` (and inbox), let a git or MR call
  finish, checkpoint `-Next 'redo: <step>'`, commit WIP locally, release leases and leave the board `paused`; a background
  finisher then stops env services no live holder needs (goody `local-env`);
  `.state/pauses/` records runs, launch records, agents, checkpoints and worktree heads. Nothing after it needs the network.
- **Crash** (power loss, kill): SessionStart `health` marks dead board entries and launch records crashed and prints
  `paused/crashed runs: N -> bossy.ps1 resume`.
- **Resume**: `bossy.ps1 resume -All | -Run <run> [-Wait <min>] [-Hours 24] [-MaxSeconds 150]`: paused runs and runs
  crashed in `-Hours`; a run whose journal ended at its last phase is closed, not listed (also `health`, `pause`); lines
  stream as found; past `-MaxSeconds` a `partial:` line names the runs left. Offline -> says so, stops. Per agent a brief
  (`work/agents/<id>/resume-<run>-brief.md`) starting AT its next step: done steps verified (commit present, MR state), never
  redone; the uncommitted diff kept for the interrupted step; journal results kept (`resumeFromRunId`); a run whose MRs all
  merged skipped; then the exact Workflow call. `board join` shows each relaunched agent its CHECKPOINT. Recording the
  resumed run (`launch -RunId`) re-binds its self record to the new session; a run is live while any record's holder lives or
  its folder was written within `supervise.stuckMinutes` (quiet past that: STUCK; STOPPED only when every holder is gone).
- Kept: commits, diffs, MRs, tracker state, decisions, checkpoints, launch records, coordinator program state (`bossy.ps1
  program set|get`). Lost: agent conversations (a fresh agent from its brief), running builds and tests (rerun), env service
  processes (started on the next lease), browser logins.

## Install
```powershell
git clone https://github.com/prskid1000/claude-crew <workspace>/.claude
pwsh -File <workspace>/.claude/skills/bossy/bossy.ps1 setup -WriteLocal   # git hooks, excludes, .runtime/.state, local config stubs
```
Needs pwsh 7, Python 3.8+, git, Node 18+, `glab` or `gh`; optional: the tracker CLI, `gws`, the Android SDK. Fill
`skills/crafty/kit.local.json`, `skills/pokey/targets.local.json` (the only place for passwords), phones: `swarm.config.json` (goody `android-swarm`);
`npm install` in `skills/pokey`. Update: `git pull` once nothing runs.
Org specifics: settings in `kit.local.json` (keys: "Configuration"); org rules, house style, extra CLIs and **Org router rows** (the
Router's columns) in `rules/*.local.md`; products, repos, test envs (names only), deploy rules and tracker statuses there too; org-only
skills listed in `localOnly`.
Codex / Antigravity (goody `ports`, `kitbag.py port`): start them in the workspace root (Codex: a trusted project in
`~/.codex/config.toml`, kit hooks approved once with `/hooks`); the port writes absolute hook paths, `.agents/skills/<name>`
links, the org rules (`.agents/rules/` always-on, `AGENTS.override.md` for Codex; local only) and each CLI's mechanics
(GEMINI.md, AGENTS.override.md). Antigravity runs the workflows (`run_workflow` on `.agents/kit-workflows/<name>.py`); Codex
follows `.codex/workflows/*.md` by hand. Not ported: the SendMessage guard, the guard on file edits outside shell commands,
Claude's per-agent tool lists (all tools load; the guard covers both), Artifacts, the CronList check (the heartbeat:
Antigravity `schedule`, Codex `bossy.ps1 heartbeat`), blocking questions in Codex outside Plan mode.

## Using it
- Ask the main session; the Router launches the rest. The heartbeat (`bossy.ps1 supervise -AutoFix -Brief`; its stderr `NEXT=<n>`
  sets the next one, 5-30 min by state) writes the dashboard ("Live supervisor dashboard" below; alone: `bossy.ps1 status
  [-Watch]`). Its stdout (`supervise.output`): `html` (default) = the page link, one line per ACT /
  WATCH and auto-fix, a count line; `chat` = the tables; `both`. `supervise.publish` (unset = off): a pwsh command run detached
  after each write, `$env:KIT_SUPERVISE_HTML` = the page (e.g. upload it as a private page; its bytes never pass through the
  model). After a restart: `bossy.ps1 resume -All`.
  Every script prints its usage without arguments.

## Live supervisor dashboard
<p align="center"><img src="assets/dashboard-dark.png" alt="supervisor dashboard, dark theme, sample data" width="900"></p>

Each sweep, the script (no model tokens) rewrites `<runtime>/logs/supervise-report.html` and its `.json` (the full data):
- header: last sweep, staleness (amber past 2x NEXT, red past 4x), auto-refresh 60 s, filter (`/`), light / dark toggle;
Each number appears once, in the order the owner acts on (owner 2026-11-13):
- flags as cards with the next step (ACT first), INFO below;
- live agents grouped by run: state chip, task, since, last progress, doing / next; finished ones folded;
- runs, 7 days, one line each (steps done as a bar, tokens, est. cost, merged MRs, elapsed, context budget bar), each with
  its steps (role, model, in / out / cache, elapsed, tool calls, result, round, retry);
- machine: memory (with sparkline), every watched disk in one tile (free GB, fill rate, "full in" under 72 h; a flagged drive
  coloured and first), build gate + QA seats in one tile; each vs the previous sample and over 7 days;
- usage (the 7 calendar days ending today, cut by the day tokens were spent; `bossy.ps1 budget -Usage` in the background each
  sweep reads the transcripts' usage fields incrementally, cached by `_paths` `usage-cache`): tokens and est. cost today vs
  the 7-day average (`budget.prices`: USD per M tokens [in, out, cache read, cache write 5 min, 1 h] per model id or alias;
  unknown models listed as not priced), tokens per merged MR (the git host's merged MRs of this login, cached 2 beats; no
  login: MRs reported by workflows), review + fix share; tokens and cost per day (the 7-day totals in its title); workflow
  steps by outcome as one stacked bar; a role table (coordinator and agents outside workflows included: steps, tokens, share
  bar, est. cost, avg / p90 time) and a model table (steps, tokens, est. cost, cost share bar, avg time);
- top 5 steps, 7 days (today's marked);
- kit internals, folded: flags per sweep (last `supervise.historySweeps`), kit activity tiles (workflow steps now, branches,
  sweep time, runs, agents spawned / finished / failed, average duration, deploys, decisions, lessons, auto-fixed %: today
  vs yesterday, 7 days vs the 7 before; `—` = no source), per step type (avg / p50 / p90), sessions when 2+, resources and
  leases, shells, `supervise` settings and learned changes.

One self-contained file: inline CSS, JS and SVG, no request leaves it; every data value is HTML-escaped. Layout rule: every list of
short items (tiles, cards, bars, key-value pairs) goes through one grid helper (`$grid`, CSS `.cg`: auto-fill, a min width per item,
optional max across, top-aligned), never one full-width row per item; tables only for many-column rows; 8-12 px gaps, every card
as tall as its content. Content never truncates; it wraps (every kit page: `kitbag.py ui-check <page>` fails on clipped text at
1366, 900 and 390 px, on a `data-fit` card with 24+ px blank below its content, and on a canvas page's `window.uiBoxes()` node or
label off-screen or overlapping).

## Goodies
Optional parts (more trackers, git hosts, CI and report types, stack presets, the local env, phone lanes, deploys, kit admin and
scaffolding, the duel mode, evidence videos to a text index) live on the origin's `goodies` branch, one folder each; the core stays small.

**Use** (`python -X utf8 skills/bossy/kitbag.py goody <verb>`):
- `list`: the goodies on `origin/goodies` (`*` = installed) · `check`: config that needs a missing goody · `add <name>` /
  `remove <name>`: install / delete its files and list / unlist it in kit.local.json `goodies` (always installed) · `sync`:
  installs every goody whose "Needed when" matches, updates changed ones only while the kit is not behind origin/main (then a
  goody merged into another or into the core, kitbag `MERGED_EXTRAS`, is swapped: old files out, a listed old name relisted) ·
  `test [<name>]`: installed goodies' tests · `prune [--days N] [--dry-run]`: drops goodies unused > N days (default 30;
  /tidy prep passes the learned value) that no "Needed when" asks for and `goodies` does not list.
- Files install at their kit path, local-only (`.git/info/exclude`: never pushed, outside the budget). `sync` runs in
  SessionStart `health`, `setup` and the post-merge hook (a pull is followed by a sync: an old goody may need the new core).
- On demand: a config-named adapter (tracker, git host, ci) missing at lib.ps1 load, or a verb that needs a missing goody, runs
  `goody add <name> --auto` (unlisted) and runs the verb again once; a failed try waits 1 h; `KIT_EXTRA_AUTO=0` turns it off
  (tests). Offline or refused: the stop line `<feature> is a goody: run kitbag.py goody add <name>`.
- Use: the code that runs a goody's adapter, verb, hook or command touches `<state>/extras-used/<file>` once a day.

**Write one** (`kitty`):
- Shape: `goodies/<name>/files/<kit path>` (each file where it installs), `goodies/<name>/GOODY.md` (What; `Needed when:`;
  Wiring), `goodies/<name>/tests.ps1` (`tests/harness.ps1` helpers; runs the `tests-*.ps1` of goodies merged into it).
- `Needed when:` forms, `,` = any: `` `key` = `v` | `w` `` (`` = `*` ``: set; `*` in a key walks keys and list items:
  `repos.*.ci`), `` `key` ~ `v` `` (contains), `` `<path>` exists ``, `` `<glob>` in a repo `` (a `repos[].checkout` tracks one),
  `` `<os>` OS `` (windows, linux, macos), `` origin ~ `v` `` (the kit's or a repo's origin URL); `Needed when (<file>.json):` reads that
  file. Listed in `goodies`: always installed.
- Seam: core calls the goody when it is loaded, else prints the stop line; never a broken reference (lint and tests pass without
  it).
- Move a core part out: `git grep` its callers, a seam at each, its files + tests to `goodies/<name>/`, README / Files rows /
  manifest updated; lint + tests on main, `goody test <name>` with it.
- Publish: `git -C <kit> worktree add -b kit/goodies-<date> <dir> origin/goodies`, commit, `git push origin HEAD:goodies` (its `.githooks/pre-push` runs the kit's pre-push gate).
- `main` and `goodies` are protected: fast-forward pushes only (on a reject: fetch, rebase), never force or delete. The guard
  denies force, delete and move from the kit clone and its worktrees; `bossy.ps1 setup` sets it on the kit origin (host verb `branch.protect`;
  hosts without it: the by-hand line), `health` reports it missing.

## Configuration
`skills/crafty/kit.local.json`, every key optional; the table is generated from `kit.example.json` (`_readme` / `_doc`).
<!-- kit-graph:start table-config -->
| Key | Example / default | Meaning |
|---|---|---|
| `gitHost`, `gitHostType`, `githubHost`, `gitlabGroup` | gitlab.com | the git host (type from the host) and the group / owner for short refs &lt;repo&gt;!&lt;iid&gt; |
| `reposRoot`, `worktreeRoots`, `repoAliases`, `protectedBranches` | /path/to/src | checkouts (default the workspace), worktrees (&lt;repos&gt;-wt); short repo names; branches never force-pushed; `protectedBranchesMode` extend (replace: without main/master/develop) |
| `commitStyle`, `locale.testCommentPattern`, `locale.proseTerms` |  | subject rule conventional (free / a regex); English defaults: testing comment, prose required words ({expected: regex, ...}) |
| `devices` | {"type": "android"} | type: android (default) / none (verbs refuse, app checks NOT_TESTED); ios: goody ios-simulator |
| `trackerRepos`, `trackerLists`, `productTargets` | ["backend", "frontend", "mobile-app"] | repos searched for a task's MRs; tracker containers for deploy intest; which env a path needs |
| `holdMerge` | [] | repos (or true = all) whose MRs a person merges (their target deploys): devtools.py merge: NOT_MERGED held for approval |
| `repos` | [{"name": "backend", "aliases": ["api"], "checkout":… | role producer / consumer; migrations.check = its own check (else Liquibase: goody liquibase; another tool: UNRUN); exclusiveTests: README Leases; regenerate: wt sync conflicts -&gt; target's copy, run ({mr} {target}), amend, push; ci.mrPipelines false = no MR pipelines (CI on deploy branches): pipes no-ci, devtools.py merge on review + local checks; deploys[] per env (production: true = never tested): CI branch + job (= target: trunk), laneApk; ssh, awsStack, probe, tag, manual, from, paths, serves: goody deploys |
| `driveParent` | &lt;Drive folder or shared-drive id (gdocs)&gt; | Drive folder or shared drive for testing docs and reports (reports.type gdocs) |
| `supervise` | {"ramActPct": 90, "minDiskFreeGB": 30, "askOwnerGB": 2,… | heartbeat: ramActPct, minDiskFreeGB, askOwnerGB (big, idle or growing app: one ASK), ramNames (_manifest.ram), briefSeconds; heartbeatMinutes (15): base of NEXT=&lt;n&gt; (5-30; manyAgents 8); stuckMinutes (20) / shellStuckMinutes (30, learned): an idle agent (no named wait) / flat-CPU shell = STUCK; finishedMinutes (30): -Brief drops older FINISHED; output, historySweeps, publish: README Using it; sectionMinutes: each section's cadence |
| `idle` | {"graceMinutes": 10} | README Leases: no live holder for graceMinutes -&gt; released; a board beat counts for beatMinutes |
| `cleanup` | {"maxBrowserProfiles": 4} | maxBrowserProfiles: profiles kept; worktreeDays (7): idle days before a clean worktree with a gone upstream goes |
| `localOnly`, `orgTerms`, `goodies` | ["skills/&lt;org-only-skill&gt;", "&lt;another org-only path&gt;"] | org-only kit paths kept out of git; words the pre-push gate blocks; goodies: goody sync always installs them (add lists, remove unlists) |
| `localFiles` | {"skills/pokey/targets.local.json": {"_readme": "One entry per TEST… | example only (setup -WriteLocal) |
| `localEnv` |  | local envs the dev flow tests on before merge; `defaults` / `envs.&lt;env&gt;.extends` share one shape (shape + example: goody local-env SKILL.md) |
| `runtimes` |  | machine runtimes agents lease (container engine, WSL distro, VM): &lt;name&gt;: isUp, up, down, match (shape: goody runtimes GOODY.md) |
| `media` |  | evidence videos -&gt; text index (goody media-evidence GOODY.md) |
| `gpu` |  | exclusive.&lt;kind&gt;.processes (regex): one kind on the GPU at a time; unset: no limit |
| `gitHostApi` | {"commands": {}} |  |
| `ci` | {"type": "host"} |  |
| `tracker` | {"type": "none", "repo": "&lt;owner/name, for github issues&gt;", "list":… | type: none (default) / command; others: goodies (goody list). statuses maps logical statuses to your board's names (a list = the first is set, all match); statusLabelPrefix: github status labels (status:); priorities: names of 1-4, space separated; branchTag: branch / MR task tag; bugPrefix: defect names. Examples: _examples, goody GOODY.md. |
| `reports` | {"type": "markdown"} | type: markdown, html (a kept file) / command ('&lt;cli&gt; {title} {path} {parent}' prints the URL); gdocs (Google Doc + Drive evidence via gws; default with gws), pdf, confluence, notion: goodies. share (gdocs): anyone (default) / domain:&lt;domain&gt; / none |
| `qa` | {"seatGB": {"web": 1.5, "api": 0.4, "app": 0.4}, "outOfScope": ["&lt;a… | shutterText / confirmText: camera label regexes. outOfScope: channels QA never tests (OUT_OF_SCOPE, not counted). targets: /testy select groups (target: '&lt;group&gt;'): a task's env: the first rule matching lists / repos / nameRegex / pathRegex (localEnv: live = in its running release). seatGB: RAM per QA seat. matrix: UI cases run at viewports (WxH) x fontScales x themes (app-set). notLocal: [{ name, match: row regex }] deps no local env runs (PASS -&gt; NOT_TESTED_LOCAL). qualityWords: stated-quality regex ('' = off). |
| `deploy` | {"trigger": "owner", "minIntervalHours": {"default": 4, "&lt;target&gt;":… | trigger: owner (default: a person says deploy &lt;env&gt;) or ask (one batched ask per env, at most one per minIntervalHours: a number, or per target + default); planTimeoutSec bounds supervise's deploy plan per test env (late = UNKNOWN); productionPattern ((?i)prod/critical): production by name when production is unset. |
| `net` | {"timeoutSec": 60} | timeoutSec per git-host / tracker CLI call; transient errors retry; lost tracker writes wait in .state/outbox.jsonl (supervise replays) |
| `tests` | {"maven": {"testFor": ["{name}Test", "{name}IT"]}} | Per stack (crafty.ps1 stack names): testFor = test names -Touched derives from a changed file's base name ({name}; defaults: check). e2e (check -Step e2e; module globs): specs (default *.cy.*, e2e/*.spec, *.e2e.*), map[] {dir?, paths, specs}; else by folder, name, import, route. |
| `guard` | {"layout": "warn"} | layout: warn (default) / block: an agent's own write into .runtime / .state outside the _paths names (crafty.ps1 dir gives its place; kit scripts are exempt). |
| `ports` | {"targets": "both"} | goody ports |
| `memory` | {"keepDefault": false} | keepDefault: false = Claude Code auto memory lives in &lt;kit&gt;/memory/ (git-ignored); true = the user's own setting. |
| `kitAudit` | {"everyDays": 7} | everyDays: SessionStart nudges a kitty audit when the last is older (default 7; 0 = off). |
| `build` | {"mavenOffline": true} | mavenOffline: Maven runs with -o when ~/.m2/repository exists (default true). |
| `gate` | {} | Memory gate. keepFreeGB (default 15% of RAM, min 6) = RAM every build leaves free; startHeapGB, heapMinGB: goody build-heap; cacheFlush (unset) = a command supervise -AutoFix runs when a gate head waited 10+ min and the file cache is 25%+ of RAM (at most every 30 min). |
| `storage` | {"watch": [], "sampleSeconds": 60, "keepDays": 30, "watchFreeGB": 50,… | bossy.ps1 storage: free space per fixed drive every sampleSeconds, .state/storage (keepDays). ACT + rescue: a 10 min fill, full within actHours or factor x the learned normal (&gt;= minRateGBh) below watchFreeGB; floors (watchFreeGB, supervise.minDiskFreeGB) on kit drives only. Rescue: kill the db query holding temp, hold builds holdMinutes. Scans (background): a drop &gt;= scanDropGB (scanCooldownMin), scanHours, ACT; defaults + watch[] + learned children (drillGB, flatDays). db.use: &lt;id&gt; &lt;temp GB&gt; &lt;seconds&gt; &lt;query&gt; each; db.kill: {id}; past db.maxGB (5): killed. TODO-PARAM. |
| `params` | {"learning": "on", "shadowDays": 14} | Tunables (param show; keys: params.registry.json) learn both ways per machine (.state/params.json) from the default within default/4..x4: a failure (timeout, OOM, short: holder back past grace, handoff, 2+ new ACTs a sweep) steps safe next use (x1.5 or the need); risky steps &lt;= 10%/day after 5 new samples, none 7 d after a failure; shadowDays: shown, then used; past 2x default: param approve (owner). kit.local.json value = pin; learning on / shadow / off. |
| `budget` | {"handoffAt": 0.8, "runStopAt": 0.8, "stepHours": 2, "prices":… | Budget = an agent tool's compaction point: handoff at handoffAt x it or a step &gt; stepHours (0: off); run cap = planned budgets: estimate &gt; runStopAt x cap refused (split), at it no new item; estimate per agent, item |
<!-- kit-graph:end -->
Env vars: `CLAUDE_RUNTIME`, `CLAUDE_WT_ROOT`, `CLAUDE_AGENT`, `CLAUDE_GATE_KEEP_FREE_GB`, `KIT_TRACKER_TYPE`, `KIT_TRACKER_DRYRUN`,
`KIT_REPORT_TYPE`, `KIT_NET_TIMEOUT_SEC` / `KIT_NET_TRIES` / `KIT_NO_OUTBOX`, `CHROME_PATH`; goodies name their own (GOODY.md).
A repo whose stack is detected wrongly: `.claude-stack.json` next to its build file (`{ "commands": { "test": "make test T={tests}" } }`).

## Adapters
One interface per kind, chosen by config; `command` = your CLI per verb (`{placeholders}` in, JSON out); `kitbag.py new adapter <kind> <name>` scaffolds one.
<!-- kit-graph:start table-adapters -->
| Kind | Selected by | Interface (verbs) | Built in | Code |
|---|---|---|---|---|
| tracker | `tracker.type` | view url status comment comments create describe rename attach list owner | command, none | `skills/crafty/lib.ps1` |
| git-host | `gitHostType` | mr.get mr.list mr.changes mr.create mr.merge mr.unauto mr.url repo.base repo.commit repo.compare branch.protect | command | `skills/crafty/lib.ps1` |
| report | `reports.type` | publish | markdown, html, command | `skills/crafty/devtools.py` |
| ci | `ci.type` | runs jobs log status config | command, none | `skills/crafty/lib.ps1` |
| transcript | `board tool` | root last | claude, codex, antigravity, none | `skills/crafty/lib.ps1` |
<!-- kit-graph:end -->

## Layout, state and safety
- `<kit>/.runtime/` disposable (`work/` runs, `cache/` rebuildable, `logs/` service logs), `<kit>/.state/` durable; both
  git-ignored. `kit.example.json` `_paths` is the one map: scripts resolve names (`Get-KitPath`, `kit_path`, `kitPath`, `rp()`;
  lint RUNTIME-RAW), `_paths.keep` the retention per name, `_paths.schema` the schema per name (`skills/bossy/STATE.md`, `kitbag.py state lint`). Agents write only under `crafty.ps1 dir`: `work/agents/<agent>/[<item>/]`
  (scratch) and `work/evidence/<item>/` (`<agent>-<what>.<ext>`); names lowercase-kebab, dates ISO. The guard notes any other
  write into either root (`guard.layout: block` denies it).
- Logs: every line through kitlog (`Write-KitLog`, `kitlog()`; lint LOG-DIRECT), masked, with time, run, agent, task, script,
  verb: streams `calls` (each verb's start / end, rc, ms), `builds` (gate wait, peak, code), `env`, `guard` in
  `.state/audit/<date>/<stream>.jsonl` (30 d); `signals`, `decisions-log`, `deploy-log` in their `.state` files (raw for the learned
  `logs.keepDays`, then one line per month in `logs-summary.jsonl`: cleanup); `params-changes` (append-only).
  `bossy.ps1 audit -Run | -Agent | -Task [-Since]` merges them with the workflow journal and the board into one timeline.
- `bossy.ps1 cleanup [-DryRun]` removes only kit-created leftovers: `_paths.keep` ages, entries off the layout (runtime root
  after 3 d, `work/` 14 d, `cache/`, `logs/` 30 d; durable ones listed only), and, in every repo (`repos[].checkout`, git
  checkouts under `reposRoot`, the kit), local branches (merged, MR merged at the tip, upstream gone or a local copy, its tip on the host;
  never protected, checked out or unpushed), clean idle worktrees no board agent or process holds, records of missing folders
  and worktree-root folders no repo lists (links unlinked, never followed; files only when all are in git) (`-WorktreesOnly`;
  `-Detail`: each item and what stays, why; counts per repo: health line, dashboard); Claude session temp: reported only.
  `crafty.ps1 wt remove` prunes and deletes its branch by the same rule.
- The PreToolUse guard blocks `git stash`, `--no-verify`, force-pushes to shared branches, pushes to a deploy branch (`repos[].deploys[].branch`: a deploy MR only, `bossy.ps1 deploy merge -Mr`), ungated builds, hand-started dev
  servers, `adb kill-server`, a file or folder path as the command or opened by `start` / `ii` / `code` (a desktop app: use the Read tool), Git Bash `/d/...` paths handed to Windows programs (node, python, java, curl, ...) and edits
  to the live kit clone's tracked or new files (edit a kit worktree; a deliberate live edit: `KIT_LIVE_EDIT=1` in the session env or the command),
  a raw `glab mr create` / `gh pr create` without `<tag><id>` in title or branch and a raw `glab mr merge` / `gh pr merge` of an MR no
  task tracks (an MR with no task: `KIT_NO_TASK=<reason>`, logged). Deploys start only from a person's word. Never production. One
  machine (the memory gate is local); Codex runs no workflows (ported procedures, "Install").
## Extending (change the kit)
The kit is the workspace's `.claude` folder, a git clone of this repo; `kitty` changes it in a kit worktree while runs execute the
live clone, keeps it generic, gets a `revy` review and pushes main; an optional feature goes to the `goodies` branch, not the core.
The rules, part shapes, lint codes and pre-push checks: `skills/bossy/kit-admin.md` (goody `kit-admin`). A script over
~2,000 tokens opens each part with a `# ---- <name>: <what>` line (`// ----` in JS) and maps them in a `Sections:` header line
(`kitbag.py sections --fix`; lint SECTION-MAP, SECTION-UNMAPPED; a section over 600 lines: audit WARN SECTION-BIG). Token budgets
(lint BUDGET; UTF-8 bytes / 4, README graph sections excluded; `kitbag.py budget` prints both totals). The kit total measures
what agents load; `tests/` has its own cap (all tests, lint BUDGET-TESTS) because agents never load it:
<!-- kit-graph:start table-caps -->
always 3500 · skill 3200 · agent 2400 · rule 900 · template 2600 · templates 4000 · doc 7000 · lessons 30000 · workflow 15000 · ps1 58000 · py 77000 · mjs 8000 · json 7000 · tests 9000 · total 428000 · all tests 101000 · files: 33 content + 9 plumbing
<!-- kit-graph:end -->

One behaviour, one test case: core in `tests/`, a goody's in `goodies/<name>/tests.ps1`, shared setup in `tests/harness.ps1`; a case name
(its PASS / FAIL line) seen twice fails `tests/kit-tests.ps1` (TEST-DUP).

## Rule examples
Path-scoped rule templates to copy into `rules/` (database migrations, any tool):
`skills/bossy/kit-admin.md` "Rule examples" (goody `kit-admin`).

## How the kit fits together
Generated by `kitbag.py flow --readme` (pre-commit); interactive: the `flow-map` goody (public: the kit map above).
<!-- kit-graph:start map -->
```mermaid
flowchart LR
  CLAUDE_md["CLAUDE.md"] -->|"import"| AGENTS_md["AGENTS.md Router"]
  agents_briefy_md("briefy")
  agents_checky_md("checky")
  agents_datay_md("datay")
  agents_devy_md("devy")
  agents_kitty_md("kitty")
  agents_opsy_md("opsy")
  agents_rechy_md("rechy")
  agents_revy_md("revy")
  agents_vidy_md("vidy")
  agents_watchy_md("watchy")
  skills_bossy_SKILL_md["bossy"]
  skills_crafty_SKILL_md["crafty"]
  skills_pokey_SKILL_md["pokey"]
  workflows_buildy_js[/"buildy"/]
  workflows_testy_js[/"testy"/]
  workflows_tidy_js[/"tidy"/]
  AGENTS_md --> agents_briefy_md
  AGENTS_md --> agents_checky_md
  AGENTS_md --> agents_datay_md
  AGENTS_md --> agents_devy_md
  AGENTS_md --> agents_kitty_md
  AGENTS_md --> agents_opsy_md
  AGENTS_md --> agents_rechy_md
  AGENTS_md --> agents_revy_md
  AGENTS_md --> agents_vidy_md
  AGENTS_md --> agents_watchy_md
  AGENTS_md --> skills_bossy_SKILL_md
  AGENTS_md --> skills_crafty_SKILL_md
  AGENTS_md --> skills_pokey_SKILL_md
  AGENTS_md --> workflows_buildy_js
  AGENTS_md --> workflows_testy_js
  AGENTS_md --> workflows_tidy_js
  workflows_buildy_js -->|"spawns"| agents_checky_md
  workflows_buildy_js -->|"spawns"| agents_datay_md
  workflows_buildy_js -->|"spawns"| agents_devy_md
  workflows_buildy_js -->|"spawns"| agents_kitty_md
  workflows_buildy_js -->|"spawns"| agents_rechy_md
  workflows_buildy_js -->|"spawns"| agents_revy_md
  workflows_buildy_js -->|"spawns"| agents_vidy_md
  workflows_testy_js -->|"spawns"| agents_checky_md
  workflows_testy_js -->|"spawns"| agents_kitty_md
  workflows_testy_js -->|"spawns"| agents_vidy_md
  workflows_tidy_js -->|"spawns"| agents_kitty_md
  agents_checky_md -->|"loads"| skills_pokey_SKILL_md
  agents_devy_md -->|"loads"| skills_crafty_SKILL_md
  agents_opsy_md -->|"loads"| skills_bossy_SKILL_md
  agents_watchy_md -->|"loads"| skills_pokey_SKILL_md
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-bossy -->
```mermaid
flowchart LR
  skills_bossy_SKILL_md["bossy"]
  skills_bossy_SKILL_md -->|"step 0: bossy.ps1 learn -Read -Skill bossy"| LESSONS_md["LESSONS.md"]
  skills_bossy_SKILL_md -->|"every event row (verbs: its header); hooks:…"| skills_bossy_bossy_ps1["bossy.ps1"]
  skills_bossy_SKILL_md -->|"a script's state file changes; an agent needs a…"| skills_bossy_STATE_md["STATE.md"]
  skills_bossy_SKILL_md -->|"a timeout, wait or limit is added or changed…"| skills_bossy_params_registry_json["params.registry.json"]
  skills_bossy_SKILL_md -->|"E1 heartbeat (supervise), board show, recover,…"| skills_bossy_adapters_supervise_resources_ps1["supervise_resources.ps1"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_pre_commit["pre-commit"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_pre_push["pre-push"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_post_merge["post-merge"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_post_rewrite["post-rewrite"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_py["kitbag.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| README_md["README.md"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| tests_kit_tests_ps1["kit-tests.ps1"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-crafty -->
```mermaid
flowchart LR
  skills_crafty_SKILL_md["crafty"]
  skills_crafty_SKILL_md -->|"step 0 (bossy.ps1 learn -Read -Skill crafty)"| LESSONS_md["LESSONS.md"]
  skills_crafty_SKILL_md -->|"#quot;Writing standards#quot; whenever you write; steps 4…"| skills_crafty_templates_md["templates.md"]
  skills_crafty_SKILL_md -->|"steps 1-5, CI wait (pipes), the PreToolUse hook…"| skills_crafty_crafty_ps1["crafty.ps1"]
  skills_crafty_SKILL_md -->|"dot-sourced by every kit script; never run by…"| skills_crafty_lib_ps1["lib.ps1"]
  skills_crafty_SKILL_md -->|"steps 6-7, rebase conflicts (keepboth)"| skills_crafty_devtools_py["devtools.py"]
  skills_crafty_SKILL_md -->|"setup (bossy.ps1 setup -WriteLocal; keys:…"| skills_crafty_kit_example_json["kit.example.json"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-pokey -->
```mermaid
flowchart LR
  skills_pokey_SKILL_md["pokey"]
  skills_pokey_SKILL_md -->|"step 0 (and H0, L0): bossy.ps1 learn -Read…"| LESSONS_md["LESSONS.md"]
  skills_pokey_SKILL_md -->|"steps 1-4, 6; L1, L3 (its header lists the…"| skills_pokey_pokey_ps1["pokey.ps1"]
  skills_pokey_SKILL_md -->|"step 3 (check -Step e2e); L1 Selection (tracker…"| skills_crafty_crafty_ps1["crafty.ps1"]
  skills_pokey_SKILL_md -->|"step 3 (web: read its header first; one…"| skills_pokey_browser_mjs["browser.mjs"]
  skills_pokey_SKILL_md -->|"L0: npm install in this folder (puppeteer-core)"| skills_pokey_package_json["package.json"]
```
<!-- kit-graph:end -->
