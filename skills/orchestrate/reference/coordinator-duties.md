# Coordinator duties in full (orchestrate reference)

Read at orchestrate step 0 (the first time you coordinate in a session) and at event E12 (HEAL). The Events table in `../SKILL.md`
says what to run for each event; this file says how to behave between events.

You do two jobs at once: run the agents AND continuously improve the kit (`<workspace>/.claude`) and its flows.
- **Supervise like a human lead (E1-E5):** one heartbeat, act on ACT, re-check WATCH, take the next step when a workflow finishes.
  Leave healthy agents alone; the details of each flag are in `supervising.md`.
- **Fix the kit, not just the symptom (E12):** whenever an agent, script or flow causes friction (a workaround, a repeated lesson, a
  false flag, a crash, a slow step), fix the script/rule/template in the kit in the same session, re-test it, and retire its
  lesson (`learn.ps1 -Skill <s> -Fixed "<words>"` moves it to HISTORY.md). Prefer making the tool handle it over telling agents to.
- **Keep the docs true:** when a script's behaviour changes, update its SKILL.md (steps + Files index), the router row, the agent
  definitions and `dev-kit/reference/configuration.md` together; `kit-lint.py` catches what it can (`extending.md`).
- **One kit, edited in place (E16-E17):** `<workspace>/.claude` is a git clone of the kit repo, so there is no second copy and
  nothing to sync. Keep every change generic (no org/tenant/product names, hosts, ids or local paths; config through
  `*.local.json`), write lessons generically (no dates or task ids), lint and parse-check, commit and push (the versioned
  pre-push hook blocks org terms and ignored/local files). The local overlay stays out of git: `*.local.*` (configs,
  `rules/*.local.md`, the durable `tracking.local.json` / `learning.local.*`), `swarm.config.json` (all in `.gitignore`) and the
  `localOnly` paths in `kit.local.json` (org-only skills, project profiles; `kit-setup.ps1` writes them into `.git/info/exclude`).
  The SessionStart line says when the clone has uncommitted changes or is behind/ahead of its upstream.
- **Be proactive, the owner should never have to point it out.** Each round also ask: what did I do by hand, what is idle or
  wasted, what friction did agents report? Automate it (supervisor `-AutoFix`, a workflow stage, `cleanup.ps1`, a script, a
  kit-lint check) in the same round. A flag that needs a human is a last resort; safe actions must run themselves.
- **Relay, never message:** SendMessage only agents you spawned yourself with the Agent tool; workflow agents get decisions
  through `<brief>.contracts.md` (E10).
