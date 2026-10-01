---
name: orchestrate
description: Coordinator playbook for multi-agent work in any repo/stack in this workspace — plan a wave of parallel dev agents, write the brief, run /dev-wave, relay decisions, then QA the deployed result with /test-and-close and loop bug fixes. Use when the user asks to run many agents in parallel, split an epic/backlog across agents, run a dev wave, resume stopped agents, or test-and-close a batch of tasks.
argument-hint: "[epic / sheet / task list]"
---

# Multi-agent dev + QA (any repo, any stack)

Nothing project-specific is hard-coded: stacks are detected from marker files, the git host/project from `origin`,
dependencies from the main checkout. Project facts (repos, target branches, environments, accounts, product rules)
go in the wave **brief** / QA **run.json**, in memory, or in the repo's own `CLAUDE.md`.

## What lives where (standard `.claude/` layout)
```
<workspace>\.claude\
├── CLAUDE.md                     global rules (your org's CLIs, tracker workflow, conventions)
├── settings.json                 permissions + hooks: guard (blocks stash/--no-verify/force-push/ungated builds), retro nudge, cleanup
├── rules\                        multi-agent.md (always) · db-migrations (loads by file path) · your own path-scoped rules
├── skills\
│   ├── orchestrate\              this playbook + LESSONS.md + templates\ (WAVE/BUGFIX/RESUME briefs, MR_BODY, TASK_SOLUTION)
│   │                             + scripts\ learn.ps1 (signals) · status.ps1 (dashboard) · retro-nudge.ps1
│   ├── dev-kit\                  dev agent rules + LESSONS.md + scripts\ stack · check · gate · wt · guard · devtools · lbcheck · keepboth · kitconfig
│   │                             + kit.local.json (git host/group, repos root, tracker repos; copy kit.example.json)
│   ├── qa-kit\                   QA rules + LESSONS.md + reference\evidence-standard.md + templates\tester-guide.html
│   │                             + scripts\ api · web\browser.mjs · android\ui · finalize (+lib\report.ps1) · autoclose
│   │                             + targets.local.json (environments, logins; copy targets.example.json)
│   ├── android-swarm\            N emulators in parallel for any APK (+ swarm.config.json, LESSONS.md)
│   ├── tech-audit\               static audit of one module → findings JSON + styled summary (+ reference\projects\<project>.md)
│   └── <your own skills>         on-demand references for your org (observability queries, database access, ...)
├── agents\                       dev-agent · mr-reviewer · qa-tester · qa-verifier   (subagent types)
└── workflows\                    /dev-wave · /test-and-close · /kit-retro (each ends with a Learn step)
<workspace>\.claude-runtime\      tokens, evidence, qa-runs, browser profiles, logs (outside .claude; or $env:CLAUDE_RUNTIME)
```
`<workspace>` = the folder that holds `.claude` (where you start Claude Code). Scripts find it from their own location.
Workflows take an optional `kitDir` arg (absolute path of `.claude`); pass it so every agent gets absolute paths.
Run scripts from **PowerShell** (node, python, gws, clickup, glab, gh are on its PATH; `python` hangs in git-bash).

## The lifecycle (you = the coordinator)

| # | Step | Dev side | QA side |
|---|---|---|---|
| 0 | Scope | Read the epic/sheet; group work **by area, not item count** (disjoint screens/packages per agent) | Note which items need app / web / API testing |
| 1 | Brief | Fill `templates\WAVE_BRIEF.md` in the scratchpad: repos + targets, ownership, migration ranges, contracts | — |
| 2 | Build | `/dev-wave` with args `{ brief, agents:[{id, items, area}], mode, review, kitDir }` — or Agent tool, type `dev-agent`, prompt "Follow the brief <path>. You are X3 …" | — |
| 3 | Relay | Append decisions/contracts to `<brief>.contracts.md` (agents re-read it before every push). **Never SendMessage a `/dev-wave` agent by ID** — it spawns a duplicate in the same worktree. SendMessage only for agents you spawned yourself with the Agent tool | — |
| 4 | Ship | Agents merge producers first (DB/API), then clients; tracker → review → promoted | — |
| 5 | Deploy | **A human** deploys to the test environment | `android-swarm\app-build.ps1` from the merged branch (phones: the app agents lease and boot them themselves) |
| 6 | Test | — | Run folder `<workspace>\.claude-runtime\qa-runs\<date>-<name>\` + `run.json`; `/test-and-close` with that object (+ `kitDir`) as args; start `qa-kit\scripts\autoclose.ps1` |
| 7 | Bugs | `[Bug] … failed checks` tasks → `templates\BUGFIX_BRIEF.md` → `/dev-wave` with `mode: 'bugfix'` | Retest: same workflow, `retest: true` on the items |
| 8 | Close | Reconcile backlog vs merged MRs + tracker comments; list only what's open, each with a reason (external / new data model / product decision / no data / cut for size) | `in test` only after deployment, set by a person |

Stopped agents (usage limit, RAM, user): `templates\RESUME_BRIEF.md`, or `/dev-wave` with `mode: 'resume'`; they continue from their worktrees.
~15 parallel dev agents is fine: they queue on the machine-wide memory gate. Expect hours for big waves.

## Quick reference
```powershell
$K = '<workspace>\.claude\skills\dev-kit\scripts'; $Q = '<workspace>\.claude\skills\qa-kit\scripts'
& $K\stack.ps1 -Dir <module>                                   # detected stack + commands
& $K\wt.ps1 new -Repo <main checkout> -Branch f/CU-123-x -Target main -Name x1
& $K\check.ps1 -Dir <wt>\<module>                              # compile + typecheck + lint (gated)
& $K\check.ps1 -Dir <wt>\<module> -Step test -Tests "OrderServiceTest"
& $K\check.ps1 -Dir <wt>\<module> -Step migrations
& $K\wt.ps1 commit -Dir <wt> -Message "feat(orders): ..."
python $K\devtools.py mr <wt> "feat: ... (CU-123) (API)" body.md
python $K\devtools.py merge <wt> <iid>
& $Q\api.ps1 -Target <t> -As admin -Path '/api/health' -Save T1_health -OutDir <run>\T1\evidence
```

## Hard-won rules (why the kit looks like this)
- **Memory gate**: six parallel Maven JVMs once hit 100% RAM. Every heavy build/test goes through `gate.ps1` (via `check.ps1`);
  a fixed one-at-a-time lock was safe but made builds wait ~1 h, so the gate is memory-aware.
- **Worktree hooks** were silently skipped (`core.hooksPath` missing in worktrees): `wt.ps1 commit` fixes it.
- **Wrong dependency versions** in a main checkout on another branch broke `tsc`/builds: `wt.ps1 new` warns; use `-LinkFrom`.
- **No `git stash`**: shared across worktrees; one agent popped another's stash.
- **Rebase often**; merge only on a green pipeline. **Stale test environments** are common: check before "fixing".
- **Under-reported defects**: 25 real defects once sat in tester notes → strict verdicts + note audit.
- **Never production.** Dev agents never start emulators (the QA swarm owns them).

## Adding a new project
Nothing to register. If `stack.ps1 -Dir <module>` prints the right commands, it works. Otherwise drop a `.claude-stack.json`
next to the build file: `{ "stack": "custom", "commands": { "compile": "make", "test": "make test T={tests}" } }`.
QA: add the environment to `qa-kit\targets.local.json`; app testing: point `android-swarm\swarm.config.json` at the app.

## Self-improvement loop (everything learns)
| Signal source | Where it lands | Turned into |
|---|---|---|
| Agents (`learn.ps1 -Skill -Kind -Text`) and each workflow's Learn step | `.claude-runtime\learning\signals.jsonl` | `LESSONS.md` lines (≥ 2 occurrences) |
| Guard hook blocks | `.claude-runtime\guard.log` | lessons / clearer rules where agents keep tripping |
| Memory gate | `%TEMP%\claude-build-gate\history.json` | automatic: next build's memory estimate + "usually ~N min" |
| QA runs (audit reclassifications, verify "not reproduced", NOT_TESTED causes, bad evidence names) | `qa-runs\<run>\` | qa-kit lessons, project gotchas |
| Tech-audit review outcomes | project profile in `tech-audit\reference\projects\` | by-design list, review lessons |

`/kit-retro` (suggested automatically at session start once ≥ 15 new signals pile up) mines all of the above with 4 parallel
analysts, applies lesson changes, promotes lessons seen ≥ 3× into SKILL.md / rules, and lists script or default changes for
approval (`{ applyScripts: true }` to apply them). Every agent reads its skill's `LESSONS.md` before starting.

**New QA bug task → fix wave in one step:** `scripts\bug-brief.ps1 -Task <id> -Agent B-<code> -Repos backend,web [-Hints ...]` writes the brief from the task's failed checks (repos + mandate from `dev-kit\kit.local.json`), starts tracking and prints the /dev-wave args. Add only your judgement as `-Hints`.

**Scale with memory, pick models by difficulty:** QA concurrency follows free RAM, not a fixed number: every tester takes a memory seat (`qa-kit\scripts\qa-seat.ps1`), and when the supervisor's INFO capacity flag says a run has queued items and room, launch an extra worker (`/test-and-close { runDir, kitDir, instance: 'w2', only: [...] }`) - item claims keep workers apart. Launch `/test-and-close` with the short form `{ runDir, kitDir }` (run.json is read by a tiny agent) to keep launches and notifications small. Models: mechanical steps (load-run, close, ship, release) run on haiku; narrow web/API retests default to sonnet; set `agents[].model` (dev-wave) or item `model`/`effort` (run.json) where a task is clearly small - `bug-brief.ps1` suggests sonnet for one or two cosmetic checks. Real code changes and first-time guides keep the strongest model.

**Always pass `mandate`** (the task owner's own words that asked for the work) to /dev-wave and /test-and-close: workflow agents otherwise drop their items for a later, unrelated chat message.

## Supervising (the coordinator works like a human lead)
After launching workflows, keep ONE heartbeat running in the coordinator session (never several crons; one `/loop` or one cron job) — `/loop 15m supervise the running waves` — and each round. Keep the heartbeat prompt **generic** (what is running comes from
`supervise.ps1`, not from the prompt): a prompt that lists run ids goes stale within the hour as waves finish and new ones start.
Each round:
1. `& <workspace>\.claude\skills\orchestrate\scripts\supervise.ps1 -Session <this session id> -AutoFix` (also runs the tracker - `track.ps1`, task statuses when all MRs merge -, stale board cleanup, due cleanup and idle-emulator shutdown): workflows (agents running/finished/idle),
   agent board (duplicates, stale), gate (queue, longest wait, repeated build failures), RAM/disk, guard blocks — with ACT/WATCH flags.
2. Act on **ACT** flags (each prints its action). Typical moves: stop a duplicate copy (TaskStop the resumed task — never SendMessage a
   workflow agent by id), resume a finished-without-MRs agent with `RESUME_BRIEF`, append a decision to `<brief>.contracts.md`, hold
   new launches while the gate queue waits > 30 min, run `cleanup.ps1`, fix a broken shared dependency (e.g. the `-LinkFrom` source).
3. Re-check **WATCH** flags next round. Don't micromanage healthy agents.
4. When a workflow finishes: `& <workspace>\.claude\skills\orchestrate\scripts\wave-report.ps1 -Run <wf id>` (journal-based summary:
   agents, MRs, done/deferred, OPEN review findings, QA verdicts; saved to `.claude-runtime\waves\<run>.json` — the notification text is
   truncated, don't parse it). Reconcile (MRs merged? tracker status? lessons recorded?), turn open should-fix findings into a follow-up
   wave (one group per file owner), then start the next step
   (QA after deploy, bug-fix wave from failed checks, app lane when the APK is built).
5. Stop the loop when nothing is running.

## Self-cleaning
Every workflow's last step and a daily background SessionStart hook run `scripts\cleanup.ps1`: leftover headless browsers (> 3 h), idle browser
profiles, expired shared logins/tokens, stale evidence/temp, week-old Claude session temp dirs, kit test leftovers in %TEMP%, finished
worktrees (remote branch merged + deleted, clean, idle > 2 h; the local branch ref is kept; roots from kit.local.json "worktreeRoots") and log rotation. Only kit-created things.
`-DryRun` shows what would go; `cleanup.log` in `.claude-runtime` records what was freed.

## Watching a wave
`& <workspace>\.claude\skills\orchestrate\scripts\status.ps1 -Open -Watch` → `.claude-runtime\dashboard.html`: memory + running builds,
learned build profiles, worktrees (branch, ahead/behind, dirty), latest QA runs, learning signals and guard blocks.

## Document formats
MR description → `templates\MR_BODY.md` (devtools.py mr warns on missing sections, adds the footer) · ClickUp solution comment →
`templates\TASK_SOLUTION.md` · tester guide → `qa-kit\templates\tester-guide.html` · QA results doc → generated by finalize.ps1 ·
evidence → `qa-kit\reference\evidence-standard.md` · audit summary → `tech-audit\scripts\summary.py`.
