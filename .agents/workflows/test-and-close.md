# test-and-close (ported procedure, not a native Antigravity workflow)

> Test tracker tasks against tester guides on a test environment (web pool + API pool + Android lanes), audit notes, verify failures independently, publish docs, close tasks, raise bug tasks

**When to run it:** Deployed tasks on a test environment, each with a tester guide or how-to-test comment, are to be tested by agents

Antigravity has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: delegate each phase to the matching subagent in `.agents/agents/*.md` yourself, in the phase order below.

## Phases

1. **Test** -- one agent per guide: web/API pool in parallel, app guides one per phone
2. **Verify** -- note audit + independent re-test of every FAIL
3. **Close** -- report (Google Doc or Markdown, per reports.type) + tracker comment/close + bug task for confirmed failures
4. **Learn** -- signals + LESSONS.md updates (40-line cap) from this run

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/test-and-close.js` (read its header comment and the `orchestrate` skill before running this by hand).
