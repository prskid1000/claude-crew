@AGENTS.md

## Claude Code-only mechanics
Everything above this line is shared with Codex and Antigravity (README "Install" lists what does not port).
- **Hooks** (`settings.json`): PreToolUse `dev.ps1 guard` (Bash, PowerShell, file edits) and `orch.ps1 guard-sendmessage` (SendMessage);
  SessionStart `orch.ps1 health` (git state, gates, stopped runs, lint, ports, retro / audit nudges) and `orch.ps1 cleanup -IfDue
  -Quiet` (async). Agents, workflows and hooks are ported to Codex / Antigravity by the `ports` extra (`kittool.py port`).
- **Skills** (`skills/*/SKILL.md`): loaded by name through the Skill tool. Launch workflows by path:
  `Workflow({ scriptPath: "<kit>/workflows/<name>.js", args })` (named lookup fails after a `cd`).
