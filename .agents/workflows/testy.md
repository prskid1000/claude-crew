# testy (ported procedure, not a native Antigravity workflow)

> Any test run (tracker selection, smoke after a deploy, regression sweep, retest; local or a test env) by checky lead / test / verify: test deployed tasks against their human testing docs (web + API pools, device lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)

**When to run it:** Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents

Antigravity has no workflow engine: you are the coordinator. Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`.

## Phases

1. **Prepare** -- args.select only: checky lead (pokey L1) writes run.json + lead-notes.md; tasks not live are left out
2. **Test** -- one checky (role test) per guide: web/API pool in parallel, app guides one per phone
3. **Verify** -- checky verify: note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL
4. **Close** -- checky lead: report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask
5. **Learn** -- signals from this run, cleanup (/tidy turns them into lessons)

## Owner decisions

- **Blocking** (an item waits): only when `ask_question` is in your tool list (its schema is not published): one `ask_question` per question of `bossy.ps1 decide list -Ask -Json`, options = the labels, recommended first (it shows its own write-in field); otherwise the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/testy.js` (its header comment) and the `bossy` skill.
