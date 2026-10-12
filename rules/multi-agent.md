# Multi-agent work, builds and QA (all repos in this workspace)

`<workspace>` = the folder that holds this `.claude` folder (the directory Claude Code was started in); kit scripts find it themselves.
**What to load or launch for a request:** the Router in `.claude/CLAUDE.md` (first matching row wins; workflows launch autonomously,
deploys need a person's yes). The rules below hold whatever the route.

- Builds and tests (Maven, Gradle, dotnet/msbuild, ng/tsc/jest/vitest, pytest, cargo, ...) always go through
  `<workspace>/.claude/skills/dev-kit/scripts/check.ps1` (stack auto-detected, machine-wide memory gate: builds queue when RAM is
  short, and the guard hook blocks ungated builds). Targeted tests only.
- Parallel work happens in worktrees from `dev-kit/scripts/wt.ps1`; commit with `wt.ps1 commit` (hooks really run).
  Never `git stash`, never `--no-verify`, never install packages into linked `node_modules`/`.venv`.
- Rebase onto the latest target before editing, before pushing and before merging; merge only on a green pipeline,
  producers (DB/API) before consumers (web/app).
- Testing happens on test environments only (logins in `skills/qa-kit/targets.local.json`), never production.
  Defects are FAIL, never notes. Dev agents never start emulators (the QA swarm owns them).
- Runtime output (tokens, evidence, QA runs, APKs, logs, browser profiles) goes to `<workspace>/.claude-runtime/`, not into `.claude/`.
- The kit learns: every agent reads its skill's `LESSONS.md` at step 0 and records surprises with
  `skills/orchestrate/scripts/learn.ps1`. A guard hook blocks `git stash`, `--no-verify`, force-pushes to shared branches,
  `adb kill-server` and ungated heavy builds; its message names the right command.
- **The main session coordinating agents** (router rows R1-R6, R11, R13) runs the agents AND improves the kit: it loads the
  `orchestrate` skill and follows its **Events** table (supervise heartbeat, HEAL, LEARN, retro, sync).
