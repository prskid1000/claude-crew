# dev-wave (ported procedure, not a native Antigravity workflow)

> The dev flow for a wave of parallel dev agents (any stack): code, testing-goals doc, reproduce + test on the local env (loop), decision pauses, independent review, CI, merge (producers first), human testing doc + tracker, merged work joins the deploy batch (a person says deploy)

**When to run it:** Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)

Antigravity has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: delegate each phase to the matching subagent in `.agents/agents/*.md` yourself, in the phase order below.

## Phases

1. **Build** -- one agent per area: worktree, code, testing goals, local test loop, MRs, testing doc
2. **Decide** -- items paused for an owner decision or a coordinator ENV-FIX wait for the answer, then resume
3. **Review** -- independent reviewer per agent + CI pipelines
4. **Fix** -- one fix round (local tests again), then merge in order and register the tracker task
5. **Deploy** -- the merged work joins the deploy batch silently; a person says deploy <env> (never asked, never deployed here)
6. **Learn** -- signals + lessons from this wave, cleanup

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/dev-wave.js` (read its header comment and the `orchestrate` skill before running this by hand).
