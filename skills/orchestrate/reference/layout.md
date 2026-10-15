# Kit layout, quick reference and housekeeping (orchestrate reference)

Read at orchestrate K1 (layout and hard-won rules before changing the kit), E19 (adding a project) and step 4 (dashboard).
The explicit map of every file is each SKILL.md Files index; the router is in `AGENTS.md` (imported by `CLAUDE.md`).

## Background
Nothing project-specific is hard-coded: stacks are detected from marker files, the git host/project from `origin`,
dependencies from the main checkout. Project facts (repos, target branches, environments, accounts, product rules)
go in the wave **brief** / QA **run.json**, in memory, or in the repo's own `CLAUDE.md`.

> Launch the kit workflows by path, not by name: `Workflow({ scriptPath: "<kit>/workflows/dev-wave.js", args })`. Named lookup only searches the *current* working directory's `.claude/workflows`, so after a `cd` into a repo `Workflow({ name: "dev-wave" })` fails with "not found".

## What lives where (standard `.claude/` layout)
`<workspace>/.claude` is a git clone of the kit repo (`git clone https://github.com/prskid1000/claude-crew <workspace>/.claude`),
edited in place and updated with `git pull`. Local files stay out of git (`.gitignore`, and `localOnly` via `.git/info/exclude`).
```
<workspace>/.claude/
├── CLAUDE.md                     the Router + global rules (your org's CLIs, tracker workflow, conventions)
├── README.md, docs/, examples/   the repo's documentation (install, runtime, configuration, example rules)
├── .githooks/pre-push           blocks org terms and force-added local files (on after kit-setup.ps1)
├── settings.json                 permissions + hooks: guard (blocks stash/--no-verify/force-push/ungated builds), retro nudge, cleanup
├── rules\                        multi-agent.md (always) · db-migrations (loads by file path) · your own path-scoped rules
├── skills\
│   ├── orchestrate\              this playbook (Quick start + reference\) + LESSONS.md (active) + HISTORY.md (moved lessons, not read)
│   │                             + templates\ (WAVE/BUGFIX/RESUME briefs, MR_BODY, TASK_SOLUTION)
│   │                             + scripts\ learn.ps1 (signals, lessons cap) · status.ps1 (dashboard) · kit-cost.ps1 (token budget) · retro-nudge.ps1
│   ├── dev-kit\                  dev agent rules (Quick start + reference\) + LESSONS.md + HISTORY.md + scripts\ stack · check · gate · wt · guard · devtools · lbcheck · keepboth · kitconfig
│   │                             + kit.local.json (git host/group, repos root, tracker repos; copy kit.example.json)
│   ├── qa-kit\                   QA rules (Quick start) + LESSONS.md + HISTORY.md + reference/ (evidence-standard, tools-and-rules, runs) + templates/tester-guide.html
│   │                             + scripts\ api · web/browser.mjs · android/ui · finalize (+lib/report.ps1) · autoclose
│   │                             + targets.local.json (environments, logins; copy targets.example.json)
│   ├── android-swarm\            N emulators in parallel for any APK (+ swarm.config.json, LESSONS.md)
│   ├── local-env\                shared local pre-staging envs: scripts\ localenv (CLI) · localenvd (controller) · localenv-lib
│   ├── tech-audit\               static audit of one module → findings JSON + styled summary (+ reference/projects/<project>.md)
│   └── <your own skills>         on-demand references for your org (observability queries, database access, ...)
├── agents\                       dev-agent · mr-reviewer · qa-tester · qa-verifier   (subagent types)
├── workflows\                    /dev-wave · /test-and-close · /kit-retro (each ends with a Learn step)
├── *.local.*                     durable local state, git-ignored: tracking.local.json (tasks -> MRs, merge intents),
│                                 learning.local.jsonl + learning.local.stamp (signals, last retro), tracker-none.local/
└── .claude-runtime\              disposable, git-ignored (or the CLAUDE_RUNTIME env var): work\ (in-flight runs) · cache\ · logs\
```
Every runtime and durable path has a name in `skills/dev-kit/scripts/kitpaths.json` (scripts resolve them with `Get-KitPath`);
what writes each folder and how it is rebuilt: `docs/runtime.md`.
`<workspace>` = the folder that holds `.claude` (where you start Claude Code). Scripts find the kit and workspace from their own location.
Workflows take an optional `kitDir` arg (absolute path of `.claude`); pass it so every agent gets absolute paths.
Run scripts from **PowerShell** (node, python, glab, gh and your tracker/report CLIs are on its PATH; `python` hangs in git-bash).
Linux/macOS: run them with `pwsh` 7 (from Bash: `pwsh -NoProfile -Command "& <script>.ps1 ..."`); everything except
`annotate.ps1` and `swarm-arrange.ps1` works there.
Tracker (any backend: kit.local.json `tracker.type`) = `dev-kit/scripts/tracker.ps1`; QA reports follow `reports.type` (gdocs / markdown).

## Quick reference
```powershell
$K = '<workspace>/.claude/skills/dev-kit/scripts'; $Q = '<workspace>/.claude/skills/qa-kit/scripts'
& $K/stack.ps1 -Dir <module>                                   # detected stack + commands
& $K/wt.ps1 new -Repo <main checkout> -Branch f/<tag>123-x -Target main -Name x1
& $K/check.ps1 -Dir <wt>/<module>                              # compile + typecheck + lint (gated)
& $K/check.ps1 -Dir <wt>/<module> -Step test -Tests "OrderServiceTest"
& $K/check.ps1 -Dir <wt>/<module> -Step migrations
& $K/wt.ps1 commit -Dir <wt> -Message "feat(projects): ..."
python $K/devtools.py mr <wt> "feat: ... (CU-123) (API)" body.md
python $K/devtools.py merge <wt> <iid>
& $Q/api.ps1 -Target <t> -As admin -Path '/api/health' -Save T1_health -OutDir <run>/T1/evidence
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
QA: add the environment to `qa-kit/targets.local.json`; app testing: point `android-swarm/swarm.config.json` at the app.

## Self-cleaning
Every workflow's last step and a daily background SessionStart hook run `scripts/cleanup.ps1`: leftover headless browsers (> 3 h), idle browser
profiles, expired shared logins/tokens, stale evidence/temp, week-old Claude session temp dirs, kit test leftovers in the OS temp folder, finished
worktrees (remote branch merged + deleted, clean, idle > 2 h; the local branch ref is kept; roots from kit.local.json "worktreeRoots") and log rotation. Only kit-created things.
`-DryRun` shows what would go; `<runtime>/logs/cleanup.log` records what was freed.

## Watching a wave
`& <workspace>/.claude/skills/orchestrate/scripts/status.ps1 -Open -Watch` → `<runtime>/cache/dashboard.html`: memory + running builds,
learned build profiles, worktrees (branch, ahead/behind, dirty), latest QA runs, learning signals and guard blocks.

## Document formats
MR description → `templates/MR_BODY.md` (devtools.py mr warns on missing sections, adds the footer) · tracker solution comment →
`templates/TASK_SOLUTION.md` · tester guide → `qa-kit/templates/tester-guide.html` (Google Doc) or `tester-guide.md` (markdown reports) · QA results report (Google Doc or report.md) → generated by finalize.ps1 ·
evidence → `qa-kit/reference/evidence-standard.md` · audit summary → `tech-audit/scripts/summary.py`.
