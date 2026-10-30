# tidy (ported procedure, not a native Codex workflow)

> Kit upkeep by kitty (kind retro) in 2-5 min: one script step (bossy.ps1 tidy prep: digest of signals, guard blocks, script errors, builds, runs, lint, goodies, params + the upkeep: goodies sync / prune, param learn, cleanup, worktree prune, signal counting), then one kitty judges the digest: lessons, rule edits, script proposals

**When to run it:** A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Codex has no workflow engine: you are the coordinator. Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency limit), `wait_agent` for them, then the next phase.

## Phases

1. **Prep** -- one STEP: launch record + bossy.ps1 tidy prep (no LLM work)
2. **Judge** -- one kitty: lesson wording, rule edits, script proposals, retro report, tidy done

## Owner decisions

- **Blocking** (an item waits): in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` (per question: header, question, options = label + description, recommended first; the client adds "Other"); otherwise the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/tidy.js` (its header comment) and the `bossy` skill.
