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
You do two jobs at once: run the agents AND continuously improve the kit (`<workspace>/.claude`) and its flows.
- **Supervise like a human lead:** after launching anything, keep `/loop 15m` supervision on (`orchestrate/scripts/supervise.ps1`), act on
  ACT flags, re-check WATCH flags, take the next step when a workflow finishes (`wave-report.ps1 -Run <id>` for the result, then
  follow-ups: open review findings → follow-up wave; deploy → QA; failed checks → bug-fix wave; all merged → tracker status).
- **Fix the kit, not just the symptom:** whenever an agent, script or flow causes friction (a workaround, a repeated lesson, a false flag,
  a crash, a slow step), fix the script/rule/template in `.claude` in the same session, re-test it, and record it in the skill's
  LESSONS.md (once the script handles it, retire the lesson: `learn.ps1 -Skill <s> -Fixed "<words>"` moves it to HISTORY.md). Prefer making the tool handle it over telling agents to.
- **Keep the docs true:** when you change a script's behaviour, update its SKILL.md / ORCHESTRATE playbook / agent definitions together.
- **One kit source, synced (if you keep the kit in its own repo, like this one):** make every kit change in the repo clone (generic:
  no org/tenant/product names, hosts, ids or local paths; config through `*.local.json`), write lessons generically (no dates or task
  ids), parse-check changed scripts, scan the diff for org terms, commit and push, then update the workspace with
  `pwsh -File <clone>/.claude/skills/dev-kit/scripts/sync-kit.ps1 -To <workspace>/.claude -Clean`. Never edit the workspace copy
  directly except its local overlay: `*.local.*` (configs, `rules/*.local.md` for org rules), `swarm.config.json` and the
  `localOnly` paths in `kit.local.json` (org-only skills, project profiles) — sync-kit never touches those and they are never published.
- **Be proactive — the user should never have to point it out.** Each round also ask: what did I do by hand, what is idle or
  wasted, what friction did agents report? Automate it in the kit (supervisor `-AutoFix`, a workflow stage, `cleanup.ps1`, a script)
  in the same round. A flag that needs a human is a last resort; safe actions must run themselves.
- After a wave or run, if signals piled up, run `/kit-retro`.

- The kit learns: read the relevant skill's `LESSONS.md` before starting; record surprises with
  `skills/orchestrate/scripts/learn.ps1`; `/kit-retro` turns signals into lessons and rules. A guard hook blocks
  `git stash`, `--no-verify`, force-pushes to shared branches and ungated heavy builds.
