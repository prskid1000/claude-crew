# testy (ported procedure, not a native Antigravity workflow)

> Any test run (tracker selection, smoke after a deploy, regression sweep, retest; local or a test env) by checky lead / test / verify: test deployed tasks against their human testing docs on a test environment (web pool + API pool + Android lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)

**When to run it:** Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents

Antigravity has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: delegate each phase to the matching subagent in `.agents/agents/*.md` yourself, in the phase order below.

## Phases

1. **Prepare** -- args.select only: checky lead (qa-kit L1) writes run.json + lead-notes.md; tasks not live are left out
2. **Test** -- one checky (role test) per guide: web/API pool in parallel, app guides one per phone
3. **Verify** -- checky verify: note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL
4. **Close** -- checky lead: report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask
5. **Learn** -- signals + LESSONS.md updates (40-line cap) from this run

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/testy.js` (read its header comment and the `orchestrate` skill before running this by hand).
