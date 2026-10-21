# buildy (ported procedure, not a native Antigravity workflow)

> The dev flow for any multi-item build (any stack): features, fixes, refactors, migrations, bug waves, resume, duels; devy: code, testing goals, local test loop, decision pauses; review, CI, merge (producers first), human testing doc + tracker; merged work waits for a person\'s deploy

**When to run it:** Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)

Antigravity has no workflow engine: you are the coordinator. Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`.

## Phases

1. **Build** -- one devy per area: worktree, code, testing goals, local test loop, MRs, testing doc
2. **Decide** -- items paused for an owner decision or a coordinator ENV-FIX wait for the answer, then resume
3. **Review** -- one revy per devy + CI pipelines
4. **Fix** -- one fix round (local tests again), then merge in order and register the tracker task
5. **Deploy** -- the merged work joins the deploy batch silently; a person says deploy <env> (never asked, never deployed here)
6. **Learn** -- signals + lessons from this wave, cleanup

Arguments and step details: `.claude/workflows/buildy.js` (its header comment) and the `orchestrate` skill.
