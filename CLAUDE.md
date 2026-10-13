@AGENTS.md

## Claude Code-only mechanics
Everything above this line is shared with Codex and Antigravity (see `AGENTS.md`'s own final section for what does NOT
port). What's below applies only here:
- **Hooks** (`settings.json`): `PreToolUse` (guard.ps1) and `SessionStart` (retro-nudge.ps1, kit-health.ps1) are ported to
  `.codex/config.toml` and `.agents/hooks.json` by `skills/orchestrate/scripts/port-kit.py` — rerun it after any hooks edit.
  The `SendMessage` guard has no port (see `AGENTS.md`).
- **Agents** (`agents/*.md`) and **workflows** (`workflows/*.js`): the same script ports agent definitions to
  `.codex/agents/*.toml` / `.agents/agents/*.md`, and generates a manual run procedure for each workflow at
  `.codex/workflows/*.md` / `.agents/workflows/*.md` (Codex/Antigravity have no pipeline/phase engine to run the real
  Workflow tool script). `skills/orchestrate/scripts/kit-health.ps1` runs `port-kit.py --check` on every SessionStart and
  nudges if the ports have drifted from source.
- **Skills** (`skills/*/SKILL.md`): loaded by name through the `Skill` tool; no equivalent trigger exists elsewhere.
