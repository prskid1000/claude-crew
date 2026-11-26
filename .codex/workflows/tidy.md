# tidy (ported procedure, not a native Codex workflow)

> Kit upkeep by kitty (kind retro) in 2-5 min: one script step (bossy.ps1 tidy prep: digest of signals, task outcomes, guard blocks, script errors, builds, runs, lint, params + the upkeep, standing-rule asks: param learn, cleanup, worktree prune, signal counting), then one kitty judges the digest: lessons, rule edits, script proposals

**When to run it:** A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective

Codex has no workflow engine: you are the coordinator. Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency limit), `wait_agent` for them, then the next phase. Hold every gate below (the .js enforces them in Claude Code and Antigravity). Journal each step (the Runs band, stuck checks and `recover` read it): `python -X utf8 <kit>/skills/bossy/kitbag.py port --journal launched --run <run> --workflow tidy` first; per agent `--journal started --run <run> --agent <its id> --label <label> --phase <phase>`, then `--journal result --run <run> --agent <its id>`; the end `--journal done --run <run>` (stopped: `--journal finished --run <run> --error '<why>'`).

## Phases

1. **Prep** -- one STEP: launch record + bossy.ps1 tidy prep (no LLM work)
   - **Launch record**: write `args` as ONE JSON line to `<runtime>/work/launches/args-tidy-<run>.json` (`<runtime>` = `kitbag.py` kit_path 'runtime'), then `& <kit>/skills/bossy/bossy.ps1 launch -Self -Script tidy.js -Run '<run>' -ArgsFile '<that file>' -Fnv <FNV-1a hex of the file> -Plan 'step/fable:1,kitty/:1'` (no `-Plan`: no BUDGET line, nothing gated; the record `recover`, resume and the Runs band read); then `bossy.ps1 tidy prep -Json` (no work: stop).
2. **Judge** -- one kitty: lesson wording, rule edits, script proposals, retro report, tidy done
   - One kitty (kind retro) judges the digest; the run ends with `bossy.ps1 tidy done -At '<prep at>'`.

## Owner decisions

- **Blocking** (an item waits): in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` (per question: header, question, options = label + description, recommended first, at most 3: name a 4th in the question; the client adds "Other"); the questions map to the payload's `ids` in order. No tool, or a pending id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/tidy.js` (its header comment) and the `bossy` skill.
