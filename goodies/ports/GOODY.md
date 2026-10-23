# ports

`kitbag.py port [--check]`: Codex / Antigravity ports of the kit (`.codex/`, `.agents/`, GEMINI.md: agents, hook wiring, a manual procedure per workflow), copied to the workspace root; also writes each agent's Character block from `_manifest`.
Needed when: `../.codex/config.toml` exists, `../.agents/hooks.json` exists (the workspace uses the ports), or listed in kit.local.json `goodies`.
Wiring: `kitbag.py` loads `skills/bossy/kitbag_ports.py` (command `port`); `bossy.ps1 precommit` regenerates the ports, `health` / `prepush` and `audit scan` (PORT-DRIFT) check them when it is installed; without it they skip.
