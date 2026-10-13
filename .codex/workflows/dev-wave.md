# dev-wave (ported procedure, not a native Codex workflow)

> Run a wave of parallel dev agents (any stack) from a brief: implement + ship each area, independent MR review, one fix round, reconcile

**When to run it:** Coding with more than 2 work items or tasks, one item spanning 2+ repos, or one large item (new feature or epic, migrations, many screens)

Codex has no pipeline/phase scripting engine equivalent to Claude Code's Workflow tool, so this is a manual run procedure, not an automated script. Drive it yourself as the coordinator: spawn each phase's agents from `.codex/agents/*.toml` yourself with `spawn_agent` (one call per agent in that phase, up to the session's concurrency limit), `wait_agent` for them to finish, then move to the next phase, in the order below. Verified against the installed CLI (`codex features list`: hooks/multi_agent stable) on 2026-10-13 -- `spawn_agents_on_csv` does not exist; don't use it.

## Phases

1. **Build** -- one agent per area: worktree, code, gated checks, MRs, merge when green
2. **Review** -- independent reviewer per agent reads its MR diffs
3. **Fix** -- one follow-up round for blocking review findings
4. **Learn** -- signals + LESSONS.md updates (40-line cap) from this wave

Full argument shape and step-by-step mechanics: the canonical source is `.claude/workflows/dev-wave.js` (read its header comment and the `orchestrate` skill before running this by hand).
