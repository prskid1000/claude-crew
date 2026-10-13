# kit-retro (ported procedure, not a native Antigravity workflow)

> Self-improvement pass for the multi-agent kit: mine learning signals, guard blocks, gate history and recent QA/dev runs; update LESSONS.md, promote stable lessons into rules, propose script/default changes

**When to run it:** A /dev-wave or /test-and-close finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Antigravity has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: delegate each phase to the matching subagent in `.agents/agents/*.md` yourself, in the phase order below.

## Phases

1. **Analyse** -- 4 parallel analysts: dev, QA, speed/infra, docs/evidence
2. **Apply** -- one synthesizer dedupes, applies lesson + rule changes, writes the retro report

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/kit-retro.js` (read its header comment and the `orchestrate` skill before running this by hand).
