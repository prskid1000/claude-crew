# kit-retro (ported procedure, not a native Codex workflow)

> Self-improvement pass for the multi-agent kit: mine learning signals, guard blocks, gate history and recent QA/dev runs; update LESSONS.md, promote stable lessons into rules, propose script/default changes

**When to run it:** A /dev-wave or /test-and-close finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Codex has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: spawn each phase's agents from `.codex/agents/*.toml` yourself with `spawn_agent` (one call per agent in that phase, up to the session's concurrency limit), `wait_agent` for them to finish, then move to the next phase, in the order below. Verified against the installed CLI (`codex features list`: hooks/multi_agent stable) on 2026-10-13 -- `spawn_agents_on_csv` does not exist; don't use it.

## Phases

1. **Analyse** -- 4 parallel analysts: dev, QA, speed/infra, docs/evidence
2. **Apply** -- one synthesizer dedupes, applies lesson + rule changes, writes the retro report

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/kit-retro.js` (read its header comment and the `orchestrate` skill before running this by hand).
