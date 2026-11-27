<p align="center"><img src="assets/claude-crew.svg" alt="claude-crew" width="330"></p>
<p align="center"><b>A crew of AI agents that builds, tests, ships and watches your code, with one coordinator in charge.</b></p>
<p align="center"><img src="assets/badges.svg" alt="license MIT · agents: Claude Code, Codex, Antigravity · scripts: PowerShell 7, Python 3 · telemetry: none"></p>

# claude-crew

**[Interactive kit map ->](https://prskid1000.github.io/claude-crew/)** (every command, step, decision and loop; built on each push from `kitbag_flow.py`)

A multi-agent dev + QA kit for Claude Code (ports for Codex and Antigravity) for **any project type**: any stack, migration tool,
local env shape, test env, deploy mechanism and tracker. Org specifics live only in git-ignored config
(`skills/crafty/kit.local.json`, `rules/*.local.md`). Core defaults assume no tenants, no web + API + app trio, no database
engine, migration tool, testing docs or deploy mechanism: each is a built-in or adapter that runs only when config selects it.
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
| `devy` | builder: makes or changes anything in product repos through the dev flow | feature · fix · refactor · migration · config · doc · tests · foundation · spike · repro | /buildy, R5, R6 | deploy, merge into deploy branches, edit the kit | pragmatic builder: "Small, tested, shipped." |
| `revy` | reviewer: reviews anything and suggests concrete changes | mr · kit · doc · qa · plan · module · config · dispute | /buildy, R13, R14 | edit anything (suggests only) | sceptical, blunt: "Show me the test." |
| `checky` | tester: tests or verifies anything, always with evidence | task · smoke · regression · repro · data · perf · claim (roles: lead / test / verify) | /testy, R10 | edit code, leave its target, load shared envs | paranoid, evidence-obsessed: "Screenshot or it didn't happen." |
| `kitty` | kit caretaker: the kit and the machine setup | build · fix · audit · retro · setup · env · recover · docs | /tidy, R2, R3 | touch product repos | tidy and frugal: "Measure before and after." |
| `briefy` | spec + brief writer: specs, /buildy brief, contracts, rule changes | spec · brief · bugfix · rule-change | R5, E8 | write code, launch runs | system architect: "Who owns this field?" |
| `rechy` | researcher: cited answers before building or deciding | question · compare · library · licence · spike · debate | /buildy, R17 | edit anything but its findings | skeptical librarian: "Cite it or drop it." |
| `datay` | data guardian: test data, local DB, migration data, backfills | cleanup · fixture · migration · localdb · backfill · check | /buildy, R15, E2, E7 | write production, edit code or the kit | meticulous archivist: "Mark it, count it, then touch it." |
| `opsy` | deploy pilot: deploys on a person's word, verifies, rolls back | deploy · rollback · status · secret | R7, E5 | deploy without a person's word, edit code | cautious pilot: "Checklist first." |
| `watchy` | on-call watcher: errors of deployed envs, one [Bug] per issue | window · sweep · triage | R16, E15 | change systems, deploy, move tasks | calm on-call engineer: "What changed, and since when?" |
| `vidy` | video reader: exact screen text, timed answers | question · index · segment | R19 | edit code, tracker, kit | frame-by-frame witness: "Which frame shows it?" |
| `steppy` | one workflow STEP, verbatim |  | /buildy, /testy, /tidy | judge, edit, spawn | literal clerk: "Exactly as written." |
<!-- kit-graph:end -->
Board and disagreements: AGENTS.md "Crew".

## Flows
- `/buildy`: devy codes and tests on the local env in a loop, revy reviews, the workflow merges; only a person's `deploy <env>`
  ships it (`deploy.trigger`).
- `/testy`: checky lead / test / verify per testing doc; the result rule closes the task, fails it back to dev or files one [Bug].
- Every task the kit builds: rendered from a spec (`skills/crafty/crafty.ps1` "task spec": description, Items and Decisions checklists, its
  line on the parent's Items; `tracker create` refuses free text but a QA / watch defect keyed `qa-` / `watch-`, `tracker describe` one that drops a section), the process.docs links before promoted; the rollup closes a parent once every subtask is
  closed (one comment).
- **Status roles**: tasks move through fixed roles, never board names: open -> inProgress -> review -> promoted (all MRs merged)
  -> inTest (deployed) -> closed; review -> failedReview (a person or revy rejects) or inProgress (review changes); failedReview,
  failedTesting -> inProgress; inTest (or promoted: undeployed) -> failedTesting; any role -> inProgress on a new code round
  (`tracker status -Back '<why>'`). Forward skips pass; other moves, a sibling agent's write while the task's round owner is live,
  repeats and stale QA results (MRs merged after the run started) are refused; a parent = its least complete open child. Per scope
  (ClickUp list, Jira project, Linear team, repo) the adapter verb `statuses` reads the live names (cached a day, again on an
  unknown name) and maps them to roles by name and type; `tracker.statusMap.<scope>.<role>` overrides, `tracker.statuses` holds the
  default names. A role the scope lacks: that step is skipped; a live name of no role: supervise WATCH. Check: `crafty.ps1 tracker
  roles <scope>`. The local env: one shared
  instance per env, branches as layers. WIP commits after every dev-flow step: a fresh agent loses nothing after a crash. The kit
  learns from every run (`/tidy`) and fixes itself in a kit worktree.
<!-- kit-graph:start table-workflows -->
| Workflow | Covers | Crew | Router row |
|---|---|---|---|
| `/buildy` | any multi-item build: features, fixes, refactors, migrations, bug waves, resume, disputes, debates | `rechy`, `devy`, `revy`, `datay`, `kitty` | R5 |
| `/testy` | any test run: tracker selection, smoke after a deploy, regression sweep, retest, on local or a test env | `checky`, `kitty` | R8 |
| `/tidy` | kit upkeep in 2-5 min: `bossy.ps1 tidy prep` (digest of signals and task outcomes, standing-rule asks from repeated owner answers, upkeep; no LLM), then one kitty: lessons + rule updates | `kitty` | R4 |
<!-- kit-graph:end -->

## Budget and handoff
The rule: "Configuration" `budget`; per-tool defaults in the table. Models (`MODELS` in each workflow; `agents[].model` / `items[].model`
win; owner 2026-11-26): build, fix, docs, test, debate, `complex` = sonnet; review, verify, audit, spike, one stronger
retry = opus; steps (ci, ship, track, close, learn) = haiku. Agents spawned by hand: their agent file's `model`.
<!-- kit-graph:start table-budget -->
| Tool / window | Budget | Source |
|---|---|---|
| claude-1m | 967000 | Claude Code docs: 1M models compact at ~967k |
| claude-200k | 167000 | conservative 83.5% of 200k (docs: at the limit) |
| codex | 0.9 x window | 0.9 x the models_cache.json window; auto_compact_token_limit wins |
| antigravity | 800000 | unverified: 0.8 x the model window (no window: 0.8 x a 1M Gemini window) |
| local | 32000 | a locally served model (llama.cpp -c, Ollama num_ctx): set tokens to its context; KIT_TOOL=local or a model id under local/ |
| unknown | 160000 | 0.8 x 200k |
<!-- kit-graph:end -->

Handoff: the first of 80% x the tool's cap and `budget.agentCap.<role>`; kit sized to
min(`budget.window`, the cap) (past: WATCH; self-check: C1).<!-- kit-graph:start flow-context -->
```mermaid
flowchart LR
  F_transcripts["transcripts"] -->|"usage pass"| F_usage_ps1["usage.ps1"]
  F_usage_ps1["usage.ps1"] -->|"live agent"| F_WATCH["WATCH"]
  F_usage_ps1["usage.ps1"] -->|"2+ agents"| F_ACT["ACT"]
  F_usage_ps1["usage.ps1"] -->|"ended starts"| F_startNorm["startNorm"]
  F_WATCH["WATCH"] -->|"past peakWatch"| F_handoff_at_80_["handoff at 80%"]
  F_ACT["ACT"] -->|"coordinator"| F_kitty_fix_at_the_source["kitty fix at the source"]
```
<!-- kit-graph:end -->

### Context plan
Per session (`bossy.ps1 usage -Context`): kit instructions target 30k, max 50k (`budget.instructions`); the
others: the role's p90 (`usage.context.slice.<key>`); over: WATCH with its rule, then ACT. Rules: LESSONS.md
"Decisions".

## Leases
One rule (`lib.ps1` `Update-KitLease`, lint LEASE-HOLDER) for env services, browser tabs, phones, builds, runtimes, worktree slots;
only owner holds (`envy.ps1 up -Owner`, phone `manual`) keep minutes, with a reminder.
Worktree slots (`crafty.ps1 wt lease / release / pool`): a fixed pool per repo (`pool.size`), created lazily, never deleted; a
released slot keeps its build caches and goes detached, a fair queue when all are leased. Names: "Worktrees and lanes".
Local AI, held by a process: `local-stt` (`skills/pokey/media.md`) one job, RAM via the memory gate; `local-model`
(`crafty.ps1 local`) `models.local.maxConcurrent` seats.
GPU (`gpu.exclusive.<kind>`, `lib.ps1` `Use-KitGpu`): one kind at a time (e.g. lane emulators), others wait (`waiting for GPU:
held by <holder>`); `processes` (regex) hold it; `idleExcept` (the kind's own backend): also waits on any other nvidia-smi process,
or over `idleMaxMB` (512) with its backend down; `minFreeMB` (caller's, lanes 2048; 0 off): waits while `memory.free` is lower,
then refuses naming the processes; no nvidia-smi: one warning.
Test locks (`repos[].exclusiveTests` `[{dir, match, lock}]`, `lib.ps1` `Use-KitLock`): a `check -Step test` under `dir` whose test
names or sources match `match` (no names: all) holds `lock`; others queue up to the learned `gate.waitMinutes` (context
`lock:<name>`), then exit 3; an ended holder is dropped; supervise RAM rows show `lock <name>`.
- **End:** an agent ends with `bossy.ps1 release -Agent <id>` (every lease of that id: lane + its emulator, env and its layers, GPU, build, tabs);
  `board leave` and /buildy, /testy after each agent stage repeat it. A holder on the board with no live entry is dead (its holder
  pid is the shared session process); `supervise -AutoFix` reclaims every kind after the grace (lanes stop with `emu kill`).
- **Activity** (`lib.ps1` `Get-KitLastActivity`, for leases, STUCK and stale board rows, shell owners): the newest board beat or
  transcript write (+ task outputs it names); a workflow step counts under any run name it joined with.
- **Log:** `.state/leases.jsonl` (`lib.ps1` `Write-KitLeaseLog`): a line per acquire / release / reclaim / down (kind, name, agent,
  session, run, since, reason); past 1 MB the newest half kept. Last used: `bossy.ps1 status`, lane and env status.

## Worktrees and lanes
- **Pool slots** (`crafty.ps1 wt lease`): per repo, folder `<bird>-<repo>`, shown `<repo>·<Bird>`
  (`nn`: `slot-<nn>-<repo>`); agents lease one per branch and release it; a free slot sits detached at `origin/<target>`, never on a
  stale branch; warm free slots: 7-day p90 + 1 (`pool.warm` first).
- **Lanes** (envy; ids `localEnv.laneIds`: `skills/envy/reference.md` "Names"): `nn` lane `lane-<nn>`, worktrees
  `lane-<nn>-<repo>` on local branch `lane/<nn>`; `bird` `<product>-<bird>`, `lane-<product>-<bird>-<repo>`, `lane/<product>-<bird>`;
  never pushed: the target + task branches merged as layers. Older names (`localenv-<env>-<repo>`, `localenv/<env>`; nn: the
  bird ones) move when the lane is idle (`envy.ps1 lanes -Migrate [-DryRun]`; supervise each sweep, `-LanesOnly`), which
  also removes clean worktrees of `localenv/*` branches no lane owns, deletes `[gone]` branches merged into the target and
  backups fully on origin, and lists the rest.
- **One lane name:** output shows `<product>·<Bird>`; state and logs keep the id (older ids group as today's); `-Env` takes either (ui-check: LANE-ID).
- **Lanes in sync** (`wt pool -Sync` -> `envy.ps1 lanes -Sync`): an idle lane is rebuilt as a build would (`origin/<target>` +
  open layers + prepare; merged layers dropped; a conflict: left as it was, listed); `lane/*` track no upstream; Branches tile:
  `base @ <sha> · behind N · test merges N`.
- **Many to many:** any task branch builds into any lane (merged onto its target); the slot keeps the task's own code. A lane
  branch no worktree holds is pruned (commits on no remote kept first as tag `backup/<branch>-<sha>`).
- **Repo sync** (`wt pool -Sync`, plain `wt pool` previews it; supervise every `sync.everyMinutes`): one fetch per repo, every local branch strictly behind its
  upstream fast-forwarded (checked out: only when clean), merged branches whose upstream is gone deleted; diverged or dirty ones
  are listed (dashboard Branches tile), never touched.

## Pause and resume
- **Checkpoints** (both paths): each agent runs `crafty.ps1 checkpoint` at every step boundary (worktree, commit, testing goals,
  loop round, MR, review, CI, testing doc, tracker, merge; QA: each check): `work/agents/<id>/resume-<run>.json` + `.md` (per run: same-named agents never overwrite; an old `resume.json` is still read). Kit
  state is written atomically (temp + rename) or appended; leases, gate slots and board entries keep their process id with its
  start time (a pid reused after a cold boot holds nothing); a lock whose holder died is taken at once (Windows).
- **Pause** (power off, a day offline): `bossy.ps1 pause -All | -Run <run> [-Reason]` returns in seconds; `pause -Status`
  says "safe to power off" (exit 1 until then; `-Wait <min>` blocks): every agent left, or at a checkpoint with a clean
  worktree and no build. The paused agents' gated builds stop at once (queued ones never start: `redo`); agents read PAUSE on
  their next `board beat` (and inbox), let a git or MR call finish, checkpoint `-Next 'redo: <step>'`, commit WIP locally,
  release leases, leave the board `paused`; a background finisher stops env services no live holder needs;
  `.state/pauses/` records runs, launch records, agents, checkpoints and worktree heads. Nothing after it needs the network.
- **Crash** (power loss, kill): SessionStart `health` marks dead board entries and launch records crashed: `paused/crashed runs: N -> bossy.ps1 resume`.
- **Resume**: `bossy.ps1 resume -All | -Run <run> [-Wait <min>] [-Hours 24] [-MaxSeconds 150]`: paused runs and runs crashed
  in `-Hours` (a journal ended at its last phase: closed, not listed; also `health`, `pause`); lines stream; past `-MaxSeconds`
  a `partial:` line names the rest; offline: says so, stops. Per agent a brief (`work/agents/<id>/resume-<run>-brief.md`) AT
  its next step: done steps verified (commit, MR state), never redone; the interrupted step's diff and journal results
  (`resumeFromRunId`) kept; a run with all MRs merged skipped; then the exact Workflow call; `board join` shows the CHECKPOINT.
  `launch -RunId` re-binds the self record to the new session; a run is live while a record's holder lives or its folder was
  written within `supervise.stuckMinutes` (then STUCK; STOPPED when every holder is gone).
- Kept: commits, diffs, MRs, tracker, decisions, checkpoints, launch records, program state (`bossy.ps1 program set|get`).
  Lost: agent conversations (fresh agent from its brief), running builds (rerun), env processes (next lease), browser logins.

## Install
```powershell
git clone https://github.com/prskid1000/claude-crew <workspace>/.claude
pwsh -File <workspace>/.claude/skills/bossy/bossy.ps1 setup -WriteLocal   # git hooks, excludes, .runtime/.state, local config stubs
```
Needs pwsh 7, Python 3.8+, git, Node 18+, `glab` or `gh`; optional: the tracker CLI, `gws`, the Android SDK. Fill
`skills/crafty/kit.local.json`, `skills/pokey/targets.local.json` (the only place for passwords), phones: `swarm.config.json`;
`npm install` in `skills/pokey`. Update: `git pull` once nothing runs.
Org specifics: settings in `kit.local.json` (keys: "Configuration"); org rules, house style, extra CLIs, **Org router rows**,
products, repos, test envs (names only), deploy rules and tracker statuses in `rules/*.local.md`; org-only skills in `localOnly`; per-role ones: `ROLES.local.md` (learn -Read).
Codex / Antigravity (`kitbag.py port`): off by default; `kit.local.json` `ports.targets: codex | antigravity | both` deploys
them (`none` removes the kit-written copies; unset keeps an earlier deploy). Start them in the workspace root (Codex: hooks approved once with `/hooks`); the port writes absolute hook paths, `.agents/skills/<name>` links, the org rules (`.agents/rules/` always-on,
`AGENTS.override.md`; local only) and each CLI's mechanics (GEMINI.md, AGENTS.override.md). Antigravity runs the workflows
(`run_workflow` on `.agents/kit-workflows/<name>.py`, journal in `<runtime>/work/port-runs/`); Codex follows
`.codex/workflows/*.md` by hand (each phase with the engine's gates). Codex config: `approval_policy = "never"`, workspace-write
with network (trusted project; Windows: `~/.codex/config.toml` `[windows] sandbox`). Not ported natively (gaps and
fallbacks: `skills/crafty/parity.json` `harness`; `kitbag.py parity`, lint PARITY):
<!-- kit-graph:start table-ports -->
| Feature | Codex | Antigravity |
|---|---|---|
| hook PreToolUse bossy.ps1 guard-sendmessage | fallback: no SendMessage hook; AGENTS.md Crew rule: crew messages only through bossy.ps1 board msg | fallback: no SendMessage hook; AGENTS.md Crew rule: crew messages only through bossy.ps1 board msg |
| hook PostToolUse ctx_hook.mjs | fallback: board beat prints the CONTEXT-CHECK line; board msgs: the per-command inbox print (board beat, crafty.ps1 wt / check / checkpoint, the gate). PostToolUse additionalContext exists (https://learn.chatgpt.com/docs/hooks) but its input names no agent: a sub-agent's hook would drain its parent's inbox | fallback: board beat prints the CONTEXT-CHECK line; board msgs: the per-command inbox print. PostToolUse returns {} only (https://antigravity.google/docs/hooks/); PostInvocation injectSteps is not wired: sub-agent firing unverified |
| workflow buildy | fallback: by-hand procedure, gates in the doc | port: .agents/kit-workflows/buildy.py |
| workflow testy | fallback: by-hand procedure, gates in the doc | port: .agents/kit-workflows/testy.py |
| workflow tidy | fallback: by-hand procedure, gates in the doc | port: .agents/kit-workflows/tidy.py |
| idle-wait guard (Monitor timeout_ms, foreground sleep over guard.warmSeconds; subagents only) | fallback: kit waits return within guard.warmSeconds (decide wait 4 min, envy wait 4.5 min / 270 s); AGENTS.md Waits | fallback: kit waits return within guard.warmSeconds; AGENTS.md Waits |
| screenshot view copy and re-read deny | gap: Codex reads images outside the hooks; the view copy is written, AGENTS.md points to it | port: guard_client.mjs redirects view_file of a shot to its view copy; re-read deny gap (no session id in the hook input) |
| test-login read deny | fallback: kit.rules exec policy + the shell guard (best-effort) | port: guard_client.mjs denies view_file of the logins file, an always-on rule, the shell guard |
| dated model override (kit.local.json models.override {model, until: ISO time}: every claude tier and models.<phase> id until then; brief agents[].model / items[].model, debateModels and inherit keep theirs) | fallback: Claude tiers only (usage.ps1 Get-KitModelOverride); a Codex session sets models.tiers.codex by hand and removes it after | fallback: Claude tiers only; an Antigravity session sets models.tiers.antigravity / ports.models by hand and removes it after |
| per-role prompt cache TTL (agent front matter experimental.cacheTtl: devy 1h; settings subagentPromptCacheTtl / env CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL override it) | gap: no config.toml key or custom-agent field sets a cache TTL (codex.exe 2026-11-27: prompt_cache_key / options are set by Codex itself); caching stays automatic | gap: no per-agent cache TTL setting; Gemini caching stays implicit |
| per-agent tool and MCP lists | gap: no such feature: https://learn.chatgpt.com/docs/agent-configuration/subagents a custom agent has no tools allow-list and its mcp_servers / sandbox_mode do not override the parent: the ported note names the allowlist, the guard covers both | port: tools: [<agy names>] in .agents/agents/*.md (https://antigravity.google/docs/subagents/; kitbag_ports.py GRAVITY_TOOL_MAP + call_mcp_tool); an agent with a tool agy cannot name (WebFetch, WebSearch) keeps all tools |
| Artifacts | fallback: the HTML file itself (supervise-report.html, a report artifact under <runtime>), opened in a browser; the Codex CLI has no viewer (https://learn.chatgpt.com/docs/artifacts-viewer) | fallback: the HTML file itself (supervise-report.html, a report artifact under <runtime>), opened in a browser; agy Artifacts are its own plans and walkthroughs (https://antigravity.google/docs/artifacts/) |
| heartbeat cron (CronList) | fallback: bossy.ps1 heartbeat (OS timer) | fallback: schedule |
| blocking owner questions | fallback: request_user_input in Plan mode, else bossy.ps1 decide ask (blocking) | fallback: ask_question when listed, else bossy.ps1 decide ask |
| run journals (Runs band, stuck checks, recover) | fallback: the .codex/workflows procedure journals each step (kitbag.py port --journal) into <runtime>/work/port-runs/codex/ | port: run_workflow journal in <runtime>/work/port-runs/ |
| local model launcher (crafty.ps1 local: a client on a local server, its env from models.local, seats, RAM and forbidden-model checks) | port: crafty.ps1 local codex starts Codex on the server (-c model_providers.local.{base_url, wire_api, env_key, stream_idle_timeout_ms}, model_provider=local; headless: codex exec --output-schema); the same verb runs from a Codex shell | gap: no such feature: https://antigravity.google/docs/settings/ (read 2026-11-27) the app, CLI and IDE add custom models only over the Gemini API (customModelsConfig, modelName gemini-api://<base_url>/models/<model>, modelProvider gemini + GEMINI_API_KEY), not an OpenAI or Anthropic endpoint; only the Python SDK has LocalOpenAIAgentConfig(base_url) (https://antigravity.google/docs/sdk/local-models/), which the kit's agy port does not run. Closes when the local server answers the Gemini API (then local antigravity writes customModelsConfig) or the port runs on the SDK |
<!-- kit-graph:end -->

## Using it
- Ask the main session; the Router launches the rest. The heartbeat (`bossy.ps1 supervise -AutoFix -Brief`: a recurring durable
  session cron, plus the opt-in OS timer `bossy.ps1 heartbeat install|uninstall|status` that ticks every `supervise.osTimerTickMinutes` (5) and runs it once the last sweep is a beat old (a session skips one under half a beat),
  `adapters/os-timer.ps1`) writes the dashboard ("Live supervisor dashboard" below; alone: `bossy.ps1 status
  [-Watch]`). Its stdout (`supervise.output`): `html` (default) = the page link, one line per ACT /
  WATCH and auto-fix, a count line; `chat` = the tables; `both`. `supervise.publish` (unset = off): a pwsh command run detached
  after each write, `$env:KIT_SUPERVISE_HTML` = the page, `$env:KIT_SUPERVISE_RUNS` = its run pages folder (linked as
  `supervise-runs/`: upload both; the bytes never pass through the model). After a restart: `bossy.ps1 resume -All`.
  Every script prints its usage without arguments.

## Live supervisor dashboard
<p align="center"><img src="assets/dashboard-dark.png" alt="supervisor dashboard, dark theme, sample data" width="900"></p>

Each sweep, the script (no model tokens) rewrites `<runtime>/logs/supervise-report.html` and its `.json` (compact data):
- header, one row from 1100 px: staleness (amber past 2x NEXT, red past 4x), next sweep, jump links, ACT / WATCH counts, filter
  (`/`), auto-refresh 60 s and light / dark icon buttons;
Each number appears once, in the order the owner acts on (owner 2026-11-13). Every section and sub-section is a `<details>` whose
summary reads `<title> (<count>)` (count 0: the summary line only); open by default flags, runs, machine and resources,
trends; shells with none and kit internals folded; the page keeps each one the owner toggles (localStorage `kc-open`). Tables show 10
rows, then "Show all (N)" (kept); the filter (`/`) searches every section, opens the matches, says "No match"; times read `HH:mm · <age>` in local time (zone in the footer); on a phone a row is a card
of two fields a line, low-value columns hidden; tone-coloured text is mixed toward the foreground (WCAG AA in both themes):
- every heatmap: one renderer, a number in each cell, now / today outlined; hours (24 clock hours) or days (`Format-KitDayHeat`:
  rows = series, columns = days, a total); rows from config + data only; rows with no data in the window fold ("N idle rows");
  each widget names its metric (`data-mk`, once per page); kit pages open in an in-page drawer, web links in a new tab;
- flags (owner 2026-11-19): one table, ACT first (level, kind, who, problem, next step, age), a repeat one row with its count,
  auto-fixes and notes one folded row, the 24 h flags heatmap behind a header toggle; promotion holds folded under it;
- task clock (Delivery rows): agent-live min vs `budget.taskMinutes`, phase;
- split cells (owner 2026-11-20): every token count and $ is a row of small muted tiles, one per type (output, fresh in, cache
  write, cache read; a $ each at the model's per-type price) + the total, every duration model / tools / waiting + elapsed
  (transcript gaps; a tool's kind from its command; the gate's printed queue time = waiting); the cell's width picks the form
  (container query): wide all tiles, medium work / cache + total, narrow the total over a 4-part bar; the tooltip holds every
  value; a heatmap's split column names its tiles in the column head; a transcript first read before the split: "split not
  recorded", a duration "wall clock" (a run: "split: N of M steps"); time counts inside the 7-day window only;
- palette: muted sage / slate / stone / clay tokens, each fill capped (`--kcap`) so text keeps 4.5:1 in both themes; every
  legend one short line of swatches and 1-2 word keys, the explanation in an (i) tooltip;
- runs: one runs x hour heatmap (a cell = minutes active under that hour's output tokens), live runs on top over the last 24 h,
  ended ones by day (today open on the same 24 h axis, older days folded), in each day a fold per kind (build, test, kit, deploy,
  agents: its sums; the newest open); a run row: short title (run name + task codes; the mandate in its tooltip), kind, its steps page, tokens · cost, time (agent minutes
  added up; elapsed = to its last step's write in the tooltip); agents (steps by agent code, live board rows with
  state and age) under it on a tap; board agents outside a workflow run grouped by their run (in one only by proof: its run name or transcript folder), with no run a row each (agents kind);
- machine and resources: tiles in one row (RAM used, builds running / queued / today, longest gate wait, QA seats, phone lanes, agents
  live, lane services up, CPU, disk written today,
  emulators, test browsers) and one RAM bar (used / promised to builds / free above the floor / floor); Resources · 24 h: one
  heatmap, metric switch CPU · RAM | Writes GB | Waits min | Builds min, rows in folding groups (count + the worst state): the
  machine (whole machine, a row per internal drive with free GB, % used, fill rate and full-in under 72 h, kit-owned, other
  processes), env services, builds, worktree slots, phones, browser tabs, shells, shared; a row: holder + branch / task; the
  builds group: a row per gate kind, its owners today as chips, today / build-min / failed (red chip) / wait avg / peak; then
  the top other processes (10%+) folded; shells: their own section;
- trends (7 calendar days ending today; usage: `bossy.ps1 budget -Usage` reads the transcripts incrementally, `_paths`
  `usage-cache` + `.cold.json`; `budget.prices` per model; delivery: `.state/outcomes.jsonl`): one tile strip (QA first pass %,
  came back %, median fix rounds, p50 hours to promoted (from agent start, first MR; 1 vs 2+ MRs), output tokens per merged MR, review + fix share, a tile per step outcome: a tap
  shows the runs with it); ONE day heatmap, folding row groups: Delivery (MRs per repo, tasks closed, came back, runs
  started: a cell filters the tasks or runs), Work in flight (today), Outcomes and test checks, Usage, Kit health, Disk,
  Repos
  (a row per repo: branches / worktrees, kept, dirty amber, diverged red); ONE "Per role" heatmap, column groups: Spend (steps,
  tokens · est. cost, share, avg / p90 active time), Model mix, Context, Waste (fixable / open / fixed);
- context: a run row's peak cell (bar by source, waste in the tooltip); Trends "Context mix", "Peak context"; Per role
  Context; flags: "Context plan";
- kit internals (folded): Tuning: Settings = a tile map of key groups (width = keys, sage = changed this week, a source strip; a
  tap opens the group as a full row: a tile per key, colour = learned / shadow / local / default, the value inside, changed in 7
  days outlined), keys changed in 7 days as a key + scope x day heatmap (latest change first; a cell = old→new, up slate,
  down plum, →default = a reset; the value now on the right; full key and reason in the tooltip), the rows as TSV on a tap.
  No parity panel (owner 2026-11-24): parity stays internal (`kitbag.py parity`).

One self-contained file: inline CSS, JS and SVG, no request leaves it; every data value is HTML-escaped. Layout rule: every list of
short items (tiles, cards, bars, key-value pairs) goes through one grid helper (`$grid`, CSS `.cg`: a wrapping row, a min width per item,
optional max across, top-aligned, the last row's items grow; card grids pack as masonry: each card in page order into the
shortest column; a tile grid (`data-fill`) takes the column count, of up to 3, with the least empty area, and each column's
last tile stretches to the tallest, its last graph growing (capped at 170 px; under 2 points: "no trend yet")), never one full-width row per item; repeated words (running, queued, today, wait, RAM) are one icon set
(`Format-KitIcon`, a title and aria-label each); a flag text over 25 words shows a one-line summary that opens to the full text;
tables only for many-column rows; 8-12 px gaps, every card
as tall as its content. Content never truncates; it wraps (every kit page: `kitbag.py ui-check <page>` fails on clipped text at
1920, 1366, 900 and 390 px (390: touch emulation, taps), on a `data-fit` card with 24+ px blank below its content, on a card row
24+ px short of its box at 1280+ px (an empty column), on a canvas page's
`window.uiBoxes()` node or label off-screen or overlapping, and on each issue a page's own `window.uiChecks()` returns: the
dashboard checks a one-row header at desktop width, a text label on every bar and sparkline, and no card under a column with
48+ px free above it). It checks a page at rest, never after a fixed sleep: fonts loaded, finite animations done, each toggle event
run and the page's own `window.uiBusy()` false (the kit map: a pending resize).

## Configuration
`skills/crafty/kit.local.json`, every key optional; the table is generated from `kit.example.json` (`_readme` / `_doc`).
<!-- kit-graph:start table-config -->
| Key | Example / default | Meaning |
|---|---|---|
| `gitHost`, `gitHostType`, `githubHost`, `gitHostGroup` | gitlab.com | git host (no default), owner in &lt;repo&gt;!&lt;n&gt; (was `gitlabGroup`, still read) |
| `reposRoot`, `worktreeRoots`, `repoAliases`, `protectedBranches` | /path/to/src | checkouts (default the workspace), worktrees (&lt;repos&gt;-wt); short repo names; branches never force-pushed; `protectedBranchesMode` extend (replace: without main/master/develop) |
| `commitStyle`, `mrTitleFormat`, `commitFormat`, `commit.ignore`, `locale.testCommentPattern`, `locale.proseTerms` |  | subject rule conventional (free / a regex); formats: devtools.py render; globs wt commit never stages; English defaults: testing comment, prose required words ({expected: regex, ...}) |
| `devices` | {"type": "none"} | type: none (default: verbs refuse, app checks NOT_TESTED) / android / ios (swarm-ios.ps1); avd {api, device, tag, extra: {config.ini key: value}}; phoneGB (4.5: memory gate need per phone); snapshotSave (false: no multi-GB snapshot save on each close) |
| `trackerRepos`, `trackerLists`, `productTargets` | ["backend", "frontend", "mobile-app"] | repos searched for a task's MRs; containers for deploy intest and tracker list without -List / tracker.list; env per path |
| `holdMerge` | [] | repos (or true = all) whose MRs a person merges (their target deploys): merge prints NOT_MERGED, held |
| `repos` | [{"name": "backend", "aliases": ["api"], "checkout":… | poolSize: worktree slots (pool.size; 0 = none); role producer / consumer; migrations.check, else migrations.tool (envy db.md); exclusiveTests: README Leases; regenerate: wt sync conflicts -&gt; target's copy, run ({mr} {target}), amend, push; ci.mrPipelines false = CI on deploy branches only: pipes no-ci, merge on review + local checks; deploys[] per env (production: untested): CI branch + job (= target: trunk), laneApk; ssh, awsStack, probe, tag, manual, from, paths, serves, after [repos], lock (one deploy per name); kind: bossy deploys.md; localTest required (default) / optional / none -&gt; localFallback ci (default) / unit; commitStyle: subject regex: wt commit refuses a miss, -ProseOk too; commitMarker: text the commit hook adds; a head without it: wt commit / precheck error; hooksPath: hook folder (default .husky; its _ copied into new worktrees); appendOnly: globs a lane train merges keeping both sides |
| `driveParent` | &lt;Drive folder or shared-drive id (gdocs)&gt; | Drive folder or shared drive for testing docs, reports (gdocs) |
| `supervise` | {"ramActPct": 90, "minDiskFreeGB": 30, "briefSeconds": 40,… | heartbeat: ramActPct, ramCleanupPct (85: RAM % to clean), minDiskFreeGB, ramNames (_manifest.ram), briefSeconds; heartbeatMinutes (15): NEXT=&lt;n&gt; (5-30; manyAgents 8); stuckMinutes (20) / shellStuckMinutes (30, learned): an idle agent = STUCK / a shell with no CPU, IO, output = STALLED; finishedMinutes (30): -Brief drops older FINISHED; output, historySweeps, publish: README Using it; sectionMinutes: section cadence |
| `idle` | {"graceMinutes": 10} | README Leases: no live holder for graceMinutes -&gt; released; a board beat counts for beatMinutes |
| `cleanup` | {"maxBrowserProfiles": 4} | maxBrowserProfiles: profiles kept; worktreeDays (7): idle days before a clean worktree with a gone upstream goes; idleDaemons: idle build daemons to stop [{process, match, label, busyKinds}] |
| `kitBranch`, `models` |  | kit branch (origin/HEAD); &lt;phase&gt;: tier fast / balanced / strong / inherit, or a model id; tiers.&lt;tool&gt;: tier -&gt; model (unset: next stronger); mode cloud / local / mixed; local: crafty.ps1 local (token env:&lt;VAR&gt; / secret:&lt;name&gt;; wireApi, commands, env) |
| `localOnly`, `orgTerms` | ["skills/&lt;org-only-skill&gt;", "&lt;another org-only path&gt;"] | org-only kit paths kept out of git; words pre-push blocks |
| `localFiles` | {"skills/pokey/targets.local.json": {"_readme": "One entry per TEST… | example only (setup -WriteLocal) |
| `localEnv` |  | local envs the dev flow tests on; `defaults` / `envs.&lt;env&gt;.extends` share one shape (envy reference.md); baseMove {targets, donorPort, verifyPort, bin, service, adminSchema, registryTable, poolTable}: mysql-base-move.ps1 |
| `runtimes` |  | runtimes agents lease (container engine, WSL distro, VM): &lt;name&gt;: isUp, up, down, match, needsOwnerClick (true or the step's text: the start waits on a person, e.g. a UAC prompt, runtimeProbe.ownerWaitMinutes; the coordinator gets a hold msg) |
| `media` |  | evidence videos -&gt; text index (pokey media.md); stt {baseUrl, model, maxConcurrent (1), ramGB (2)}: local speech-to-text |
| `writes` |  | tracer {csv, time, kind, process, folder, mb, disk}: a disk-write tracer CSV and its column names (tracerCsv: older csv key); softGBPerHour, hardGBPerHour: params pins |
| `findings` |  | required: fields every module-audit finding fills (default root_cause, why_today, why_not_prod, db_migration, code_location) |
| `gpu` |  | exclusive.&lt;kind&gt;.processes (regex): one kind on the GPU at a time; unset: no limit |
| `process` |  | gates.&lt;promote/merge/finish/bugFix/mrBody&gt;: unset = pass, builtin:testingDocs / builtin:reproRow, or a hook (payload JSON on stdin, exit 0 = pass); docs[] {key, label, linkRx, headerRx, required, columns} (unset: vocab.json pair, [] = none); humanDocUiOnly (default true); bugFixRx; qaResult {fail: role (default) / reopen / none, newDefect: collector (default) / per-defect / none} |
| `mr` |  | footer: last line of every MR body ("" = none); sections, uiFilesRx: devtools.py render |
| `protectedBranchesBase`, `linkDefaults`, `stack.presets` |  | protected branches (main/master/develop/release/*): never swept, force-pushed or pushed to (MR only), a deploy-MR source; dep folders wt lease / new link; false = no built-in stack presets |
| `api`, `auth` |  | api.defaultUser (unset: a target's only user), api.tokenFields (login answer token fields, [] = none); targets: auth.tokenField / auth.preset oauth2 / oidc; userAuth.&lt;user&gt; = that login's auth fields (path, body, tokenField, ...) over auth + its tenant; profiles.&lt;name&gt; {login, secret, auth, fields (tenant, {placeholders})} |
| `secrets` |  | store: file (default: targets.local.json) / env (KIT_SECRET_&lt;NAME&gt;) / keychain / command (secrets.command.&lt;verb&gt;); &lt;store&gt;.paths: guard-denied; secret:&lt;name&gt; values resolve through it |
| `masking`, `migrations` |  | masking.rules {table.column glob: kind}, logins, names {first, last, streets}; migrations.tool (none), lbcheck.*, historyTables (envy db.md) |
| `configVersion` | 4 | below 4: migrate adds old defaults |
| `gitHostApi` | {"commands": {}} | commands: host verb -&gt; command; hostCli: more MR CLIs [{exe, noun, type, allow (setup -Allow entries), source, target, title, valued}] |
| `ci` | {"type": "host"} |  |
| `naming` | {"products": {}} | products / areas {CODE: name}, digits (3): &lt;PRODUCT&gt;-&lt;AREA&gt;-&lt;nnn&gt; keys in the description's kit table, plain titles (dec-60); tags.&lt;group&gt;: [values] / false (kitbag.py naming tags); tags.areaMap: {AREA code: broad tag} (wide modules, default the area name); titleStrip: [regex] old codes tracker retag cuts (old title kept in the description) |
| `tracker` | {"type": "none", "repo": "&lt;owner/name, for github issues&gt;", "list":… | type: none (default) / command / a vendor adapter. Status roles (fixed, transitions README "Flows": open inProgress review failedReview promoted inTest failedTesting closed): statuses = default names per role (first set, all match; null skips the step); caps.&lt;cap&gt; false = off (checklist, commentEdit, commentDelete, statuses, move, attach; README Adapters); statusMap.&lt;scope&gt;.&lt;role&gt; = one scope's names (a list id, Jira project, Linear team, repo; .other = names that are no role) over its live names (crafty.ps1 tracker roles &lt;scope&gt;); statusLabelPrefix: github status labels (status:); priorities: names of 1-4; branchTag: branch / MR task tag; bugPrefix: defect names; bugBranchPrefix: bug-fix brief branches (fix/); ciTaskPattern: CI-raised test task names, closed when their job passes (unset: off). branchRx, bugBranchRx, kindPrefixes, nameFormat, taskTemplate, commentTemplates, urlFragment, bugCollectorTitle: vocabulary (default: vocab.json). blockLinkType: Jira link type of waits on… |
| `reports` | {"type": "markdown"} | type: markdown, html (a kept file) / command ('&lt;cli&gt; {title} {path} {parent} {url} {tags}' prints the URL); gdocs (Google Doc + Drive evidence via gws), pdf, confluence, notion: adapters. share (gdocs): anyone (default) / domain:&lt;domain&gt; / none. parent (notion): a page or a database (rows; tags = its Tags multi-select). evidence: report (default: the type's host; kept docs: &lt;docs&gt;/&lt;name&gt;/) / local / command (evidenceCommand {name} {parent} {files} prints '&lt;file&gt; &lt;URL&gt;' lines) |
| `qa` | {"seatGB": {"web": 1.5, "api": 0.4, "app": 0.4}, "matrix":… | lanes {&lt;lane&gt;: {kind, parallel (unset: free RAM sets it), followUp, devices}} (unset: one web lane); newDefectIdRx, holdCauses (none), guideDoc (first process doc). shutterText / confirmText: camera label regexes. outOfScope: channels QA never tests (OUT_OF_SCOPE). targets: /testy env rules (target: '&lt;group&gt;'; first match of lists / repos / nameRegex / pathRegex; localEnv: live = in its running release). seatGB: RAM per seat. testerViewport {web, mobile}: the testers' screen per ui goal (testing.md "Proof"). aiWaiver: owner decision id waiving an ai goal's local run while its env runs no services[].aiStack. preflight {env, tool, tenantSql, roles, maxScanRows}: testing.md "Preflight" (unset: off). matrix: UI cases at viewports (WxH) x fontScales x themes x locales. matrixRun {parallel (4), variantSec (300: then FAIL), full / newScreen: path regexes a diff needs every variant for, reduced {viewports, locales} else; tests: paths never counted (specs, cypress, test_*)}: devtools.py… |
| `deploy` | {"trigger": "owner", "minIntervalHours": {"default": 4, "&lt;target&gt;":… | trigger: owner (default: a person says deploy &lt;env&gt;) / ask (one batched ask per env, at most one per minIntervalHours: a number or per target + default); minIntervalScope: repo (default: a repo's own last deploy to the env starts its window) / env; planTimeoutSec bounds supervise's plan per env (late = UNKNOWN); hold: [&lt;env&gt;] never asked; triggers {&lt;env / repo&gt;: auto}: standing word; answerWords {yes, no, noAll, wait}: more answer words; productionPattern, branchPrefix, mergeMethod, commitTemplate, ssh: bossy deploys.md. deploy run -To &lt;env&gt;: each row's kind deploy verb. schedule {mode auto / parallel / serial, maxParallel (0 = none), marginMinutes 2, historyRuns 10, historyDays 60, deployJobRx, migrationPathRx, breakingMigrationRx (a match in a producer's added migration lines, or a migration file in code, = strict edge)}: deploy schedule / watch (bossy deploys.md) |
| `net` | {"timeoutSec": 60} | timeoutSec per git-host / tracker CLI call; transient errors retry; lost tracker writes wait in .state/outbox.jsonl (supervise replays) |
| `tests` | {"maven": {"testFor": ["{name}Test", "{name}IT"]}} | Per stack: testFor = test names -Touched derives from a changed file's name ({name}). e2e (check -Step e2e): specs (default *.cy.*, e2e/*.spec, *.e2e.*), map[] {dir?, paths, specs}, else folder, name, import, route; run[] {dir, cmd?, env?, split?: folder, portFiles?: lane ports swapped in}. ciRuns: ["&lt;repo&gt;/&lt;module&gt;" globs] whose MR pipeline runs build + suite: check -Step build / test -AllTests skip there (-Force runs). containerWhen: {"&lt;repo&gt;/&lt;module&gt;" glob: [path globs]}: container / IT tests named alone run locally only when the diff touches one, else CI. |
| `browsers` | {"chromePolicies": {}} | chromePolicies: {&lt;key under Software/Policies, e.g. Google/Chrome&gt;: {&lt;policy&gt;: &lt;number or text&gt;}}: bossy.ps1 setup writes them per user (HKCU; an admin-only key: prints the elevated command); setup -BrowserPolicy -Undo removes them, -Clean deletes model folders in kit and Cypress profiles. |
| `decide` | {"neverAuto": []} | neverAuto: regex words a question never gets a standing rule for, added to the built-in deploy / prod / data / customer list (bossy outcomes.ps1) |
| `guard` | {"layout": "warn", "writeRoots": []} | heavyPatterns / e2ePatterns: commands that need the gate. layout: warn (default) / block: an agent's own write into .runtime / .state outside the _paths names (crafty.ps1 dir; kit scripts exempt). writeRoots: more folders agents may create files in; envChangeCommands: more deployed-env change commands to deny (regexes; built-in: vocab.json); a new file at a drive root or outside the workspace, kit, repos, worktree roots, temp, ~/.claude, ~/Downloads is denied. |
| `ports` | {"targets": "none", "models": {"haiku": "flash"}} | kitbag.py port workspace copies: none (default) / codex / antigravity / both. models: {&lt;Claude model&gt;: &lt;agy model&gt;} for the runner (default haiku -&gt; flash) |
| `memory` | {"keepDefault": false} | false = auto memory off (settings.json); true = on (settings.local.json). |
| `kitAudit` | {"everyDays": 7} | everyDays: SessionStart nudges a kitty audit past it (default 7; 0 = off). |
| `build` | {"mavenOffline": false} | mavenOffline: Maven -o when ~/.m2/repository exists (default false). |
| `reverse` | {"toolsDir": ""} | toolsDir: the reversy engines (Ghidra, JADX, apktool, ilspycmd, WABT, frida, ...); default &lt;runtime&gt;/tools, never pruned by cleanup; relative = from the kit. pins: &lt;tool&gt; {version, asset, sha256} overrides one entry of skills/reversy/pins.json (no pin = no download). |
| `gate` | {} | keepFreeGB (default 15% of RAM, min 6): RAM builds leave free; startHeapGB, heapMinGB: adapters/build-heap.ps1; GB defaults (heaps, params gate.kindGB.&lt;kind&gt;) fit 64 GB RAM and scale down with it (a quarter at 16 GB); cacheFlush (unset) = a command supervise -AutoFix runs when a gate head waited 10+ min and the file cache is 25%+ of RAM (at most every 30 min). labels {row: kindRx}. |
| `storage` | {"watch": [], "sampleSeconds": 60, "keepDays": 30, "watchFreeGB": 50,… | free GB/drive per sampleSeconds (keepDays). ACT+rescue: 10 min fill, full in actHours or factor x normal (&gt;= minRateGBh) below watchFreeGB; kit-drive floors. Rescue: kill db temp holder, hold builds holdMinutes. Scans: drop &gt;= scanDropGB (scanCooldownMin), scanHours; toolCaches (~, {localAppData}), watch[], learned (drillGB, flatDays). db.use: &lt;id&gt; &lt;GB&gt; &lt;s&gt; &lt;query&gt;; db.kill {id}; db.maxGB. TODO-PARAM. |
| `watch` | {"windows": ["15m", "2h", "24h"], "rising": {"factor": 3, "hits": 10}} | watchy after a deploy: windows = one-shot timers (default 15m, 2h, 24h; bossy E15); rising = a signature at factor x its baseline and at least hits (default 3, 10) |
| `pool` | {"size": 10} | size = worktree slots per repo (default 10; repos[].poolSize, 0 = no pool: wt new), created on lease, never deleted; warm = free slots kept made (default 2; repos[].poolWarm); sync.everyMinutes (60): supervise runs wt pool -Sync (fetch, fast-forward, prune, idle slots at origin/&lt;target&gt;); names: the n-th member of every pool (slot, env lane, phone lane); wipRestore: [globs] tracked files a test run rewrites, restored on release (no WIP commit) |
| `params` | {"learning": "on", "shadowDays": 14} | Tunables (param show; keys: params.registry.json) learn both ways per machine (.state/params.json) within default/4..x4: a failure (timeout, OOM, short: holder back past grace, handoff, 2+ new ACTs a sweep) steps safe next use (x1.5 or the need); risky steps &lt;= 10%/day after 5 new samples, none 7 d after a failure; shadowDays: shown, then used; past 2x default: param approve (owner). kit.local.json value = pin; learning on / shadow / off. |
| `budget` | {"window": 200000, "agentCap": {"_readme": "kit handoff budget per… | Budget = an agent tool's compaction point: handoff at handoffAt x it or a step &gt; stepHours (0: off); run cap = planned budgets: estimate &gt; runStopAt x cap refused (split), at it no new item; runMinutes: a testy run's wall-clock cap (args.maxMinutes wins; 0: none); defaults.&lt;tool&gt;: its compaction point; models: claude id -&gt; row; estimate per agent, item |
| `tools` | {"roles": {}, "mainOnly": []} | coordinator: every tool; crew: _manifest.agents.&lt;role&gt;.tools + roles.&lt;role&gt; grants (["mcp__&lt;server&gt;"], port renders them); a server no role grants: health line (mainOnly: quiet). A disabled server for one task: the owner enables it (/mcp), grants a role, then reverts both |
<!-- kit-graph:end -->
Env vars: `CLAUDE_RUNTIME`, `CLAUDE_WT_ROOT`, `CLAUDE_AGENT`, `CLAUDE_GATE_KEEP_FREE_GB`, `KIT_TRACKER_TYPE`, `KIT_TRACKER_DRYRUN`,
`KIT_REPORT_TYPE`, `KIT_NET_TIMEOUT_SEC` / `KIT_NET_TRIES` / `KIT_NO_OUTBOX`, `CHROME_PATH`; adapters name theirs (file header).
A repo whose stack is detected wrongly: `.claude-stack.json` next to its build file (`{ "commands": { "test": "make test T={tests}" } }`).

## Adapters
One interface per kind, chosen by config; `command` = your CLI per verb (`{placeholders}` in, JSON out); `kitbag.py new adapter <kind> <name>` scaffolds one.
Vendor adapters sit in `skills/crafty/adapters/` and load only when config selects them (env vars / keys: each file's header).
Registry: `skills/crafty/parity.json` (per family: verbs, caps, fallbacks, declared gaps); `kitbag.py parity [--json]` prints
adapter x verb (native, config, fallback, gap) and harness x feature; lint PARITY fails a verb or feature with neither.
`kitbag.py parity next [--n 3]`: the cells to close next (kit-admin.md "Parity"); supervise ACT `PARITY next batch` starts each batch.
`kitbag.py faults [next]`: agents' failed commands -> recurring script-fault items (ACT `SCRIPT-FAULTS`; guard: `adapters/guard-scripts.ps1`).
<!-- kit-graph:start table-adapters -->
| Kind | Selected by | Interface (verbs; caps: Test-KitCap) | Built in | Vendor (config-selected) | Not native (adapters) | Code |
|---|---|---|---|---|---|---|
| tracker | `tracker.type` | view url status comment comments create describe rename list owner; caps: checklist commentEdit commentDelete statuses move attach dependencies labels tagPrune | command, none | clickup, github, gitlab, jira, jira-server, linear, youtrack, azure | fallback: checklist (1), dependencies (1), tagPrune (1) · gap: checklist (4), tagPrune (2) | `skills/crafty/adapters/tracker-local.ps1` |
| git-host | `gitHostType` | mr.get mr.list mr.changes mr.create mr.update mr.merge mr.unauto mr.url mr.parseRef whoami repo.base repo.commit repo.compare branch.protect; caps: mr.labels | command | github, gitlab, bitbucket, azure, gitea | gap: mr.labels (1) | `skills/crafty/lib.ps1` |
| report | `reports.type` | publish selftest; caps: evidence tags | markdown, html, command | gdocs, pdf, confluence, notion |  | `skills/crafty/devtools.py` |
| ci | `ci.type` | runs jobs log status config failure parseUrl | command, none | github, gitlab, bitbucket, azure, gitea, jenkins |  | `skills/crafty/lib.ps1` |
| transcript | `board tool` | root last; caps: agentMeta | claude, codex, antigravity, none |  | gap: agentMeta (1) | `skills/crafty/lib.ps1` |
| deploy-kind | `repos[].deploys[] (kind)` | isDeployed plan; caps: deploy | command, ci-job, branch-mr, ssh, tag, probe, manual, awsStack, laneApk |  | fallback: deploy (1), isRunning (3), lastDeploy (2), restart (5) | `skills/pokey/adapters/deployed-checks.ps1` |
| secret-store | `secrets.store` | get; caps: write list rotate | file, env, keychain, command |  | gap: delete (1), rotate (1), set (1), write (1) | `skills/crafty/adapters/secret-store.ps1` |
| process-gate | `process.gates.<gate>` | promote merge finish bugFix mrBody |  | testingDocs, reproRow | not walked: a built-in is one rule for its own gates (testingDocs: promote here, finish / merge / mrBody in devtools.py; reproRow: bugFix in devtools.py); an unset gate passes | `skills/crafty/adapters/process-gates.ps1` |
| db-engine | `localEnv db.engine` | query exec jdbc sql; caps: marks temp sizes kill snap revert unsnap |  | mysql, mariadb, postgres, sqlserver, sqlite, oracle, mongodb, redis, elasticsearch, opensearch | gap: binlogs (4), jdbc (1), kill (5), marks (3), pos (3), query (1), revert (3), snap (6), sql (1), temp (5), unsnap (6) | `skills/envy/adapters/db-engines.ps1` |
| tenant-model | `localEnv tenants.model` | list drop import footprint scopes |  | none, schema, database, column, instance | fallback: drop (1), footprint (1), import (2) · gap: drop (1), footprint (1), import (1), list (1) | `skills/envy/adapters/tenant-models.ps1` |
| migration | `migrations.tool` | check discover pendingSql tag rollback resetEdited missingRoutines rerunRoutines historyScopes appendOnly unmerged |  | liquibase |  | `skills/crafty/adapters/liquibase.ps1` |
| envy-verb | `adapters/*.local.ps1` | ops run |  | tenant, priority |  | `skills/envy/adapters/tenant-models.ps1` |
| api-auth | `targets auth.type` | invoke |  |  |  | `skills/pokey/pokey.ps1` |
| login | `targets.<t>.users / profiles (targets.local.json)` | users secretRefs profiles | api, app, web |  |  | `skills/pokey/pokey.ps1` |
| device | `devices.type` | dump tap tapid tapxy type clear key swipe openurl shot shotmark wait photo log mic | android, ios, none |  | gap: clear (1), dump (1), key (1), log (1), mic (2), openurl (1), photo (2), shot (1), shotmark (1), swipe (1), tap (1), tapid (1), tapxy (1), type (1), wait (1) | `skills/pokey/adapters/ui-android.ps1` |
| browser-engine | `browser.engine` | session context; caps: reuse | chrome, chromium, firefox, webkit |  |  | `skills/pokey/adapters/engine-playwright.mjs` |
| scheduler | `supervise.osTimer` | install uninstall status | windows, cron, launchd, none |  |  | `skills/bossy/adapters/os-timer.ps1` |
| guard | `built-in guard rules` | check | local-env, deployed-env, large-writes, secrets, runtimes, script-faults, file-dumps |  |  | `skills/crafty/adapters/guard-localenv.ps1` |
| stack | `repos[] stack detection` | detect | core, presets |  |  | `skills/crafty/adapters/stack-presets.ps1` |
<!-- kit-graph:end -->

## Layout, state and safety
- `<kit>/.runtime/` disposable (`work/` runs, `cache/` rebuildable, `logs/` service logs), `<kit>/.state/` durable; both
  git-ignored. `kit.example.json` `_paths` is the one map: scripts resolve names (`Get-KitPath`, `kit_path`, `kitPath`, `rp()`;
  lint RUNTIME-RAW), `_paths.keep` the retention per name, `_paths.schema` the schema per name (`skills/bossy/STATE.md`, `kitbag.py state lint`). Agents write only under `crafty.ps1 dir`: `work/agents/<agent>/[<item>/]`
  (scratch) and `work/evidence/<item>/` (`<agent>-<what>.<ext>`); names lowercase-kebab, dates ISO. The guard notes any other
  write into either root (`guard.layout: block` denies it).
- Logs: every line through kitlog (`Write-KitLog`, `kitlog()`; lint LOG-DIRECT), masked, with time, run, agent, task, script,
  verb: streams `calls` (each verb's start / end, rc, ms), `builds` (gate wait, peak, code), `env`, `guard` in
  `.state/audit/<date>/<stream>.jsonl` (30 d); `signals`, `decisions-log`, `deploy-log`, `scope-log` in their `.state` files (raw for the learned
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
  servers, `adb kill-server`, whole-drive searches (`find /`, `grep -r C:/`: scope them), a file or folder path as the command or opened by `start` / `ii` / `code` (the Read tool instead), Git Bash `/d/...` paths and `/x` args handed to Windows programs, script faults (rule `script-faults`), new files at a drive root or outside the workspace, kit, repo, worktree, temp, `~/.claude`, `~/Downloads` and `guard.writeRoots` roots (any write, the Write tool too: `crafty.ps1 dir` instead) and edits
  to the live kit clone's tracked or new files (edit a kit worktree; a deliberate live edit: `KIT_LIVE_EDIT=1`),
  a raw `glab mr create` / `gh pr create` without `<tag><id>` in title or branch and a raw `glab mr merge` / `gh pr merge` of an MR no
  task tracks (no task: `KIT_NO_TASK=<reason>`, logged). Deploys start only from a person's word. Never production. One
  machine (a local memory gate); Codex runs no workflows (ported procedures, "Install").
## Extending (change the kit)
The kit is the workspace's `.claude` folder, a git clone of this repo; `kitty` changes it in a kit worktree while runs execute the
live clone, keeps it generic, gets a `revy` review and pushes main (`main` is protected:
fast-forward pushes only, never force or delete; the guard denies force, delete and move from the kit clone and its worktrees;
`bossy.ps1 setup` sets it on the origin (host verb `branch.protect`; else the by-hand line), `health` reports it missing).
The rules, part shapes, lint codes and pre-push checks: `skills/bossy/kit-admin.md`. A script over
~2,000 tokens opens each part with a `# ---- <name>: <what>` line (`// ----` in JS) and maps them in a `Sections:` header line
(`kitbag.py sections --fix`; lint SECTION-MAP, SECTION-UNMAPPED; a section over 600 lines: audit WARN SECTION-BIG). Token budgets
(UTF-8 bytes / 4, README graph sections excluded): what a role loads at start (always-loaded files + its agent file, skill and
lessons; lint START-BUDGET), per file (lint BUDGET), docs reached only through a SKILL.md pointer (lint ORPHAN-DOC); scripts are
run, never named as files to read. `kitbag.py budget` prints each role's start and the repo / tests totals (INFO, no cap):
<!-- kit-graph:start table-caps -->
always 3500 · skill 3000 · agent 2400 · rule 900 · template 2600 · templates 4000 · doc 7000 · lessons 30000 · workflow 16500 · ps1 58000 · py 77000 · mjs 8000 · json 7000 · config 10075 · tests 9000 · start per role 12000 · files:33 content + 9 plumbing
<!-- kit-graph:end -->

One behaviour, one test case: in `tests/`, shared setup in `tests/harness.ps1`; a case name
(its PASS / FAIL line) seen twice fails `tests/kit-tests.ps1` (TEST-DUP).

## Rule examples
Path-scoped rule templates to copy into `rules/` (database migrations, any tool):
`skills/bossy/kit-admin.md` "Rule examples".

## How the kit fits together
Generated by `kitbag.py flow --readme` (pre-commit); interactive: `kitbag_flow.py` (public: the kit map above).
<!-- kit-graph:start map -->
```mermaid
flowchart LR
  CLAUDE_md["CLAUDE.md"] -->|"main session"| ROUTER_md["ROUTER.md"]
  agents_briefy_md("briefy")
  agents_checky_md("checky")
  agents_datay_md("datay")
  agents_devy_md("devy")
  agents_kitty_md("kitty")
  agents_opsy_md("opsy")
  agents_rechy_md("rechy")
  agents_revy_md("revy")
  agents_steppy_md("steppy")
  agents_vidy_md("vidy")
  agents_watchy_md("watchy")
  skills_bossy_SKILL_md["bossy"]
  skills_crafty_SKILL_md["crafty"]
  skills_envy_SKILL_md["envy"]
  skills_phoney_SKILL_md["phoney"]
  skills_pokey_SKILL_md["pokey"]
  skills_reversy_SKILL_md["reversy"]
  workflows_buildy_js[/"buildy"/]
  workflows_testy_js[/"testy"/]
  workflows_tidy_js[/"tidy"/]
  ROUTER_md --> agents_checky_md
  ROUTER_md --> agents_datay_md
  ROUTER_md --> agents_kitty_md
  ROUTER_md --> agents_opsy_md
  ROUTER_md --> agents_rechy_md
  ROUTER_md --> agents_revy_md
  ROUTER_md --> agents_vidy_md
  ROUTER_md --> agents_watchy_md
  ROUTER_md --> skills_bossy_SKILL_md
  ROUTER_md --> skills_envy_SKILL_md
  ROUTER_md --> skills_phoney_SKILL_md
  ROUTER_md --> skills_pokey_SKILL_md
  ROUTER_md --> skills_reversy_SKILL_md
  ROUTER_md --> workflows_buildy_js
  ROUTER_md --> workflows_testy_js
  ROUTER_md --> workflows_tidy_js
  workflows_buildy_js -->|"spawns"| agents_datay_md
  workflows_buildy_js -->|"spawns"| agents_devy_md
  workflows_buildy_js -->|"spawns"| agents_kitty_md
  workflows_buildy_js -->|"spawns"| agents_rechy_md
  workflows_buildy_js -->|"spawns"| agents_revy_md
  workflows_buildy_js -->|"spawns"| agents_steppy_md
  workflows_testy_js -->|"spawns"| agents_checky_md
  workflows_testy_js -->|"spawns"| agents_kitty_md
  workflows_testy_js -->|"spawns"| agents_steppy_md
  workflows_testy_js -->|"spawns"| agents_vidy_md
  workflows_tidy_js -->|"spawns"| agents_kitty_md
  workflows_tidy_js -->|"spawns"| agents_steppy_md
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
  skills_bossy_SKILL_md -->|"every event row (verbs: its header); hooks:…"| skills_bossy_ctx_hook_mjs["ctx_hook.mjs"]
  skills_bossy_SKILL_md -->|"a script's state file changes; an agent needs a…"| skills_bossy_STATE_md["STATE.md"]
  skills_bossy_SKILL_md -->|"a timeout, wait or limit is added or changed…"| skills_bossy_params_registry_json["params.registry.json"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_bugbrief_ps1["bugbrief.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_deploy_merge_ps1["deploy-merge.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_deploys_ps1["deploys.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_guard_sendmessage_ps1["guard-sendmessage.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_heartbeat_ps1["heartbeat.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_kit_admin_ps1["kit-admin.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_localenv_supervise_ps1["localenv-supervise.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_os_timer_ps1["os-timer.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_outcomes_ps1["outcomes.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_storage_ps1["storage.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_supervise_resources_ps1["supervise-resources.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_supervise_stats_ps1["supervise-stats.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_task_clock_ps1["task-clock.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_task_rollup_ps1["task-rollup.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_track_rebuild_ps1["track-rebuild.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_usage_ps1["usage.ps1"]
  skills_bossy_SKILL_md -->|"dot-sourced by bossy.ps1"| skills_bossy_adapters_waits_ps1["waits.ps1"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_pre_commit["pre-commit"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_pre_push["pre-push"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_post_merge["post-merge"]
  skills_bossy_SKILL_md -->|"K3: run by git (bossy.ps1 setup sets…"| _githooks_post_rewrite["post-rewrite"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_py["kitbag.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_admin_py["kitbag_admin.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_flow_py["kitbag_flow.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_forget_py["kitbag_forget.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_naming_py["kitbag_naming.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_ports_py["kitbag_ports.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_kitbag_scaffold_py["kitbag_scaffold.py"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| skills_bossy_lint_vocab_json["lint-vocab.json"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| README_md["README.md"]
  skills_bossy_SKILL_md -->|"K1-K3 (the kitty agent runs them); E14: README…"| tests_kit_tests_ps1["kit-tests.ps1"]
  skills_bossy_SKILL_md -->|"K1-K3: kitty step 0, revy kind kit"| skills_bossy_kit_admin_md["kit-admin.md"]
  skills_bossy_SKILL_md -->|"E5: opsy deploy steps"| skills_bossy_deploys_md["deploys.md"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-crafty -->
```mermaid
flowchart LR
  skills_crafty_SKILL_md["crafty"]
  skills_crafty_SKILL_md -->|"step 0 (bossy.ps1 learn -Read -Skill crafty)"| LESSONS_md["LESSONS.md"]
  skills_crafty_SKILL_md -->|"#quot;Writing standards#quot; whenever you write; steps 4…"| skills_crafty_templates_md["templates.md"]
  skills_crafty_SKILL_md -->|"steps 2, 4-5 (impact map, proof per channel,…"| skills_crafty_testing_md["testing.md"]
  skills_crafty_SKILL_md -->|"steps 6-9 (MR, docs, tracker, merge, deploy…"| skills_crafty_ship_md["ship.md"]
  skills_crafty_SKILL_md -->|"steps 1-5, CI wait (pipes), the PreToolUse hook…"| skills_crafty_crafty_ps1["crafty.ps1"]
  skills_crafty_SKILL_md -->|"the PreToolUse hook: a warm guard (~0.1 s a…"| skills_crafty_guard_client_mjs["guard_client.mjs"]
  skills_crafty_SKILL_md -->|"the PreToolUse hook: a warm guard (~0.1 s a…"| skills_crafty_guard_server_ps1["guard_server.ps1"]
  skills_crafty_SKILL_md -->|"dot-sourced by every kit script; never run by…"| skills_crafty_lib_ps1["lib.ps1"]
  skills_crafty_SKILL_md -->|"run by lib.ps1 / envy.ps1 for the calls pwsh…"| skills_crafty_flagged_ps1["flagged.ps1"]
  skills_crafty_SKILL_md -->|"steps 6-7, rebase conflicts (keepboth)"| skills_crafty_devtools_py["devtools.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_android_sdk_ps1["android-sdk.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_azure_devops_ps1["azure-devops.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_bitbucket_ps1["bitbucket.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_build_heap_ps1["build-heap.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_check_stamps_ps1["check-stamps.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_ci_jenkins_ps1["ci-jenkins.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_container_tests_ps1["container-tests.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_gitea_ps1["gitea.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_github_ps1["github.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_gitlab_ps1["gitlab.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_guard_localenv_ps1["guard-localenv.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_guard_scripts_ps1["guard-scripts.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_liquibase_ps1["liquibase.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_liquibase_py["liquibase.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_local_model_ps1["local-model.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_module_audit_py["module_audit.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_precheck_py["precheck.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_process_gates_ps1["process-gates.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_proof_py["proof.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_report_confluence_py["report_confluence.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_report_gdocs_py["report_gdocs.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_report_notion_py["report_notion.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_report_pdf_py["report_pdf.py"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_runtimes_ps1["runtimes.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_secret_store_ps1["secret-store.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_stack_presets_ps1["stack-presets.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_supervise_report_ps1["supervise-report.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_task_items_ps1["task-items.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_azure_ps1["tracker-azure.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_clickup_ps1["tracker-clickup.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_jira_ps1["tracker-jira.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_linear_ps1["tracker-linear.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_local_ps1["tracker-local.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_tracker_youtrack_ps1["tracker-youtrack.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_ts_typecheck_ps1["ts-typecheck.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_video_ps1["video.ps1"]
  skills_crafty_SKILL_md -->|"loaded by lib.ps1 / devtools.py; a vendor one…"| skills_crafty_adapters_wt_pool_ps1["wt-pool.ps1"]
  skills_crafty_SKILL_md -->|"step 4: check -Step test runs it for a web…"| skills_crafty_spec_mjs["spec.mjs"]
  skills_crafty_SKILL_md -->|"revy kind module (devtools.py findings)"| skills_crafty_module_audit_md["module-audit.md"]
  skills_crafty_SKILL_md -->|"setup (bossy.ps1 setup -WriteLocal; keys:…"| skills_crafty_kit_example_json["kit.example.json"]
  skills_crafty_SKILL_md -->|"a new adapter verb or kit feature (AGENTS.md…"| skills_crafty_parity_json["parity.json"]
  skills_crafty_SKILL_md -->|"built-in defaults (statuses, tracker vendor ids…"| skills_crafty_vocab_json["vocab.json"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-pokey -->
```mermaid
flowchart LR
  skills_pokey_SKILL_md["pokey"]
  skills_pokey_SKILL_md -->|"step 0 (and H0, L0): bossy.ps1 learn -Read…"| LESSONS_md["LESSONS.md"]
  skills_pokey_SKILL_md -->|"steps 1-4, 6; L1, L3 (verbs: its header)"| skills_pokey_pokey_ps1["pokey.ps1"]
  skills_pokey_SKILL_md -->|"step 3 (check -Step e2e); L1 Selection (tracker…"| skills_crafty_crafty_ps1["crafty.ps1"]
  skills_pokey_SKILL_md -->|"step 3 (web: read its header first; one…"| skills_pokey_browser_mjs["browser.mjs"]
  skills_pokey_SKILL_md -->|"step 3 (a UI case at every variant at once; run…"| skills_pokey_matrix_mjs["matrix.mjs"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_annotate_ps1["annotate.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_api_auth_ps1["api-auth.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_deployed_checks_ps1["deployed-checks.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_engine_playwright_mjs["engine-playwright.mjs"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_media_grab_mjs["media-grab.mjs"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_report_html_ps1["report-html.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_ui_android_ps1["ui-android.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_ui_checks_mjs["ui-checks.mjs"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_ui_ios_ps1["ui-ios.ps1"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_adapters_web_login_mjs["web-login.mjs"]
  skills_pokey_SKILL_md -->|"used by the pokey.ps1 / browser.mjs verb that…"| skills_pokey_video_py["video.py"]
  skills_pokey_SKILL_md -->|"task videos (pokey.ps1 evidence)"| skills_pokey_media_md["media.md"]
  skills_pokey_SKILL_md -->|"L0-L3: checky lead, the coordinator (a…"| skills_pokey_lead_md["lead.md"]
  skills_pokey_SKILL_md -->|"L0: npm install in this folder (puppeteer-core)"| skills_pokey_package_json["package.json"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-envy -->
```mermaid
flowchart LR
  skills_envy_SKILL_md["envy"]
  skills_envy_SKILL_md -->|"step 0: bossy.ps1 learn -Read -Skill local-env"| LESSONS_md["LESSONS.md"]
  skills_envy_SKILL_md -->|"Steps 1-6; owner verbs: Rules"| skills_envy_envy_ps1["envy.ps1"]
  skills_envy_SKILL_md -->|"#quot;Train and leases#quot;, #quot;Lanes#quot;, #quot;Config#quot; (shape +…"| skills_envy_reference_md["reference.md"]
  skills_envy_SKILL_md -->|"#quot;DB marks, restore, seed#quot;, #quot;DB temp#quot;, #quot;DB…"| skills_envy_db_md["db.md"]
  skills_envy_SKILL_md -->|"kind db-engine: each engine's presets and verbs…"| skills_envy_adapters_db_engines_ps1["db-engines.ps1"]
  skills_envy_SKILL_md -->|"dot-sourced by envy.ps1: db hooks from the…"| skills_envy_adapters_db_presets_ps1["db-presets.ps1"]
  skills_envy_SKILL_md -->|"kind tenant-model (tenants.model, default none)…"| skills_envy_adapters_tenant_models_ps1["tenant-models.ps1"]
  skills_envy_SKILL_md -->|"the schema tenant model: list, drop, import…"| skills_envy_adapters_tenant_schema_ps1["tenant-schema.ps1"]
  skills_envy_SKILL_md -->|"deploy step 2: a lane's or a check's build of…"| skills_envy_adapters_shared_builds_ps1["shared-builds.ps1"]
  skills_envy_SKILL_md -->|"doctor rows for the lane service standard:…"| skills_envy_adapters_lane_standard_ps1["lane-standard.ps1"]
  skills_envy_SKILL_md -->|"owner / coordinator: moves a base env's MySQL…"| skills_envy_mysql_base_move_ps1["mysql-base-move.ps1"]
  skills_envy_SKILL_md -->|"run by envy.ps1 restore, release slices, the…"| skills_envy_adapters_db_flashback_py["db_flashback.py"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-phoney -->
```mermaid
flowchart LR
  skills_phoney_SKILL_md["phoney"]
  skills_phoney_SKILL_md -->|"step A0 / L0: bossy.ps1 learn -Read -Skill…"| LESSONS_md["LESSONS.md"]
  skills_phoney_SKILL_md -->|"A1-A5 (acquire, ensure, launch, release,…"| skills_phoney_phoney_ps1["phoney.ps1"]
  skills_phoney_SKILL_md -->|"never read: pokey.ps1 ui and the deploys[]…"| skills_pokey_adapters_ui_android_ps1["ui-android.ps1"]
  skills_phoney_SKILL_md -->|"dot-sourced by phoney.ps1: app.kind presets,…"| skills_phoney_adapters_app_kinds_ps1["app-kinds.ps1"]
  skills_phoney_SKILL_md -->|"dot-sourced by phoney.ps1: app.kind presets,…"| skills_phoney_adapters_arrange_ps1["arrange.ps1"]
  skills_phoney_SKILL_md -->|"devices.type: ios: phoney.ps1 forwards its…"| skills_phoney_swarm_ios_ps1["swarm-ios.ps1"]
```
<!-- kit-graph:end -->

<!-- kit-graph:start skill-reversy -->
```mermaid
flowchart LR
  skills_reversy_SKILL_md["reversy"]
  skills_reversy_SKILL_md -->|"step 0: bossy.ps1 learn -Read -Skill reversy"| LESSONS_md["LESSONS.md"]
  skills_reversy_SKILL_md -->|"steps 1-3: the entry (--help per verb)"| skills_reversy_reversy_py["reversy.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_lib_py["lib.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_binary_py["binary.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_managed_py["managed.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_android_py["android.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_web_py["web.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_firmware_py["firmware.py"]
  skills_reversy_SKILL_md -->|"imported by reversy.py (nothing to study)"| skills_reversy_runtime_py["runtime.py"]
  skills_reversy_SKILL_md -->|"the only tool downloads allowed (tag, asset,…"| skills_reversy_pins_json["pins.json"]
```
<!-- kit-graph:end -->
