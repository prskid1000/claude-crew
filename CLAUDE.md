@AGENTS.md

## Claude Code-only mechanics
Everything above this line is shared with Codex and Antigravity (README "Install" lists what does not port).
- **Hooks** (`settings.json`): PreToolUse `dev.ps1 guard` (Bash, PowerShell) and `orch.ps1 guard-sendmessage` (SendMessage);
  SessionStart `orch.ps1 health` (git state, gates, stopped runs, lint, ports, retro / audit nudges) and `orch.ps1 cleanup -IfDue
  -Quiet` (async). `kittool.py port` ports them to `.codex/config.toml` / `.agents/hooks.json` (no SendMessage port).
- **Agents** (`agents/*.md`) and **workflows** (`workflows/*.js`): `kittool.py port` writes `.codex/agents/*.toml`,
  `.agents/agents/*.md` and a manual procedure per workflow (`.codex/workflows/*.md`, `.agents/workflows/*.md`); `orch.ps1
  health` runs `port --check` at every SessionStart.
- **Skills** (`skills/*/SKILL.md`): loaded by name through the Skill tool. Launch workflows by path:
  `Workflow({ scriptPath: "<kit>/workflows/<name>.js", args })` (named lookup fails after a `cd`).
