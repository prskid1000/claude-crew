# tidy (ported procedure, not a native Antigravity workflow)

> Kit upkeep by kitty (kind retro): learning signals -> lessons + rule updates, cleanup, the weekly audit kick-off; self-improvement pass for the multi-agent kit: mine learning signals, guard blocks, gate history and recent QA/dev runs; update LESSONS.md, promote stable lessons into rules, propose script/default changes

**When to run it:** A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Antigravity has no workflow engine: you are the coordinator. Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`.

## Phases

1. **Analyse** -- 4 parallel kitty analysts: dev, QA, speed/infra, docs/evidence
2. **Apply** -- one kitty dedupes, applies lesson + rule changes, writes the retro report, says when the audit is due

Arguments and step details: `.claude/workflows/tidy.js` (its header comment) and the `orchestrate` skill.
