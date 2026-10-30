@AGENTS.md

## Claude Code-only mechanics
Everything above this line is shared with Codex and Antigravity (README "Install" lists what does not port).
- **Hooks** (`settings.json`): PreToolUse `crafty.ps1 guard` (Bash, PowerShell, file edits) and `bossy.ps1 guard-sendmessage` (SendMessage);
  SessionStart `bossy.ps1 health` (git state, gates, stopped runs, lint, ports, retro / audit nudges) and `bossy.ps1 cleanup -IfDue
  -Quiet` (async). Codex / Antigravity ports: goody `ports` (`kitbag.py port`).
- **Skills** (`skills/*/SKILL.md`): loaded by name through the Skill tool. Launch workflows by path:
  `Workflow({ scriptPath: "<kit>/workflows/<name>.js", args })` (named lookup fails after a `cd`).
- **Heartbeat** (bossy E1): while a run or agent is live, every coordinator turn ends with one heartbeat one-shot armed (CronList);
  none -> arm it to the last stderr `NEXT=<n>` (none seen: `supervise.heartbeatMinutes`). After a compaction or restart, check first.
  Paste the ENTIRE supervise output verbatim and unfenced, never filtered or cut (no grep / tail / head): a table without its
  header row renders as cards. Resolve WATCH lines like ACT ones, without asking: cross-check stale board rows, explain error
  spikes (QA 4xx: ignore; 5xx, startup or connection failures: act), close finished runs, finish merge-wait and tracker steps;
  ask the owner only for a real decision (`AskUserQuestion`, main session only: bossy E4).
