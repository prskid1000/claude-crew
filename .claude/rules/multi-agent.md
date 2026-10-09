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
  LESSONS.md (mark lessons "fixed in kit" when the script now handles it). Prefer making the tool handle it over telling agents to.
- **Keep the docs true:** when you change a script's behaviour, update its SKILL.md / ORCHESTRATE playbook / agent definitions together.
- **Keep a public mirror in sync (if you publish the kit):** when your live kit has a sanitised public copy (like this repo), port every
  kit change into it in the same session, without being asked: make the same edit by hand (never copy live files over it: they hold
  logins, tenants, hosts and org paths; the public copy uses generic paths via kitconfig / `<workspace>`), write lessons generically
  (no org/tenant/product names, dates or task ids), parse-check changed scripts, scan the diff for org terms, then commit with a
  no-reply author email and push. Never publish `*.local.json`, `swarm.config.json` or org-only skills.
- **Be proactive — the user should never have to point it out.** Each round also ask: what did I do by hand, what is idle or
  wasted, what friction did agents report? Automate it in the kit (supervisor `-AutoFix`, a workflow stage, `cleanup.ps1`, a script)
  in the same round. A flag that needs a human is a last resort; safe actions must run themselves.
- After a wave or run, if signals piled up, run `/kit-retro`.

- The kit learns: read the relevant skill's `LESSONS.md` before starting; record surprises with
  `skills/orchestrate/scripts/learn.ps1`; `/kit-retro` turns signals into lessons and rules. A guard hook blocks
  `git stash`, `--no-verify`, force-pushes to shared branches and ungated heavy builds.
