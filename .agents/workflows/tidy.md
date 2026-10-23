# tidy (ported procedure, not a native Antigravity workflow)

> Kit upkeep by kitty (kind retro) in 2-5 min: one script step (bossy.ps1 tidy prep: digest of signals, guard blocks, script errors, builds, runs, lint, goodies, params + the upkeep: goodies sync / prune, param learn, cleanup, worktree prune, signal counting), then one kitty judges the digest: lessons, rule edits, script proposals

**When to run it:** A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Antigravity has no workflow engine: you are the coordinator. Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`.

## Phases

1. **Prep** -- one STEP: launch record + bossy.ps1 tidy prep (no LLM work)
2. **Judge** -- one kitty: lesson wording, rule edits, script proposals, retro report, tidy done

Arguments and step details: `.claude/workflows/tidy.js` (its header comment) and the `bossy` skill.
