# Coordinator duties in full (orchestrate reference)

The full text behind the short "When you are the coordinator" block in `rules/multi-agent.md` (moved here so dev/QA agents
don't load it every session). Read it when you start coordinating, and before publishing a kit change.

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
