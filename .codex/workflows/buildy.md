# buildy (ported procedure, not a native Codex workflow)

> The dev flow for any multi-item build (any stack): features, fixes, refactors, migrations, bug waves, resume; devy: code, testing goals, local test loop, decision pauses; review, CI, merge (producers first), human testing doc + tracker; merged work waits for a person\'s deploy

**When to run it:** Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)

Codex has no workflow engine: you are the coordinator. Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency limit), `wait_agent` for them, then the next phase.

## Phases

1. **Spike** -- args.openQuestions: one rechy answers them in the brief before any devy starts
2. **Build** -- one devy per area: worktree, code, testing goals, local test loop, MRs, testing doc
3. **Decide** -- items paused for an owner decision or a coordinator ENV-FIX wait for the answer, then resume
4. **Review** -- one revy per devy (+ datay on an area with migrations) + CI pipelines
5. **Fix** -- one fix round (local tests again), then merge in order and register the tracker task
6. **Deploy** -- the merged work joins the deploy batch silently (goody deploys); a person says deploy <env> (never asked, never deployed here)
7. **Learn** -- signals from this wave, cleanup (/tidy turns them into lessons)

## Owner decisions

- **Blocking** (an item waits): in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` (per question: header, question, options = label + description, recommended first, at most 3: name a 4th in the question; the client adds "Other"); the questions map to the payload's `ids` in order. No tool, or a pending id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/buildy.js` (its header comment) and the `bossy` skill.
