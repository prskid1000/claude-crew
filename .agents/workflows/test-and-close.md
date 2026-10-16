# test-and-close (ported procedure, not a native Antigravity workflow)

> Test-only flow: test deployed tasks against their human testing docs on a test environment (web pool + API pool + Android lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)

**When to run it:** Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents

Antigravity has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: delegate each phase to the matching subagent in `.agents/agents/*.md` yourself, in the phase order below.

## Phases

1. **Prepare** -- args.select only: a lead agent (qa-kit L1) writes run.json + lead-notes.md; tasks not live are left out
2. **Test** -- one agent per guide: web/API pool in parallel, app guides one per phone
3. **Verify** -- note audit + independent re-test of every FAIL
4. **Close** -- report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask
5. **Learn** -- signals + LESSONS.md updates (40-line cap) from this run

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/test-and-close.js` (read its header comment and the `orchestrate` skill before running this by hand).
