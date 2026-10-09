# Multi-agent work, builds and QA (all repos in this workspace)

`<workspace>` = the folder that holds this `.claude` folder (the directory Claude Code was started in); kit scripts find it themselves.

- Coordinating several agents, an epic wave or a QA batch → use the `orchestrate` skill, the `/dev-wave` and
  `/test-and-close` workflows, and the subagent types `dev-agent`, `mr-reviewer`, `qa-tester`, `qa-verifier`.
- Builds and tests (Maven, Gradle, dotnet/msbuild, ng/tsc/jest/vitest, pytest, cargo, ...) always go through
  `<workspace>/.claude/skills/dev-kit/scripts/check.ps1` (stack auto-detected, machine-wide memory gate). Targeted tests only.
- Parallel work happens in worktrees from `dev-kit/scripts/wt.ps1`; commit with `wt.ps1 commit` (hooks really run).
  Never `git stash`, never `--no-verify`, never install packages into linked `node_modules`/`.venv`.
- Rebase onto the latest target before editing, before pushing and before merging; merge only on a green pipeline,
  producers (DB/API) before consumers (web/app).
- Testing happens on test environments only (logins in `skills/qa-kit/targets.local.json`), never production.
  Defects are FAIL, never notes. Dev agents never start emulators (the QA swarm owns them).
- Runtime output (tokens, evidence, QA runs, browser profiles) goes to `<workspace>/.claude-runtime/`, not into `.claude\`.

## When you are the coordinator (main session running waves / QA runs)
Two jobs at once: run the agents AND improve the kit (`<workspace>/.claude`). Use the `orchestrate` skill (its Quick start: launching,
one supervise loop, next steps when a workflow finishes). Fix kit friction in the same session (prefer making the script handle it;
retire fixed lessons with `learn.ps1 -Fixed`), keep SKILL.md / playbook / agent docs true, publish kit changes through the kit repo
clone + `sync-kit.ps1`, and automate whatever you did by hand. Full duties: `skills/orchestrate/reference/coordinator-duties.md`.

- The kit learns: read the relevant skill's `LESSONS.md` before starting; record surprises with
  `skills/orchestrate/scripts/learn.ps1`; `/kit-retro` turns signals into lessons and rules. A guard hook blocks
  `git stash`, `--no-verify`, force-pushes to shared branches and ungated heavy builds.
