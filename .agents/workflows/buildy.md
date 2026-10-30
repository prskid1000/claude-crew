# buildy (ported procedure, not a native Antigravity workflow)

> The dev flow for any multi-item build (any stack): features, fixes, refactors, migrations, bug waves, resume; devy: code, testing goals, local test loop, decision pauses; review, CI, merge (producers first), human testing doc + tracker; merged work waits for a person\'s deploy

**When to run it:** Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)

Antigravity has no workflow engine: you are the coordinator. Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`.

## Phases

1. **Spike** -- args.openQuestions: one rechy answers them in the brief before any devy starts
2. **Build** -- one devy per area: worktree, code, testing goals, local test loop, MRs, testing doc
3. **Decide** -- items paused for an owner decision or a coordinator ENV-FIX wait for the answer, then resume
4. **Review** -- one revy per devy (+ datay on an area with migrations) + CI pipelines
5. **Fix** -- one fix round (local tests again), then merge in order and register the tracker task
6. **Deploy** -- the merged work joins the deploy batch silently (goody deploys); a person says deploy <env> (never asked, never deployed here)
7. **Learn** -- signals from this wave, cleanup (/tidy turns them into lessons)

## Owner decisions

- **Blocking** (an item waits): only when `ask_question` is in your tool list (its schema is not published): one `ask_question` per question of `bossy.ps1 decide list -Ask -Json`, options = the labels, recommended first (it shows its own write-in field); the questions map to the payload's `ids` in order. No tool, or a pending id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/buildy.js` (its header comment) and the `bossy` skill.
