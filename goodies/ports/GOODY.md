# ports

`kitbag.py port [--check]`: Codex / Antigravity ports of the kit (`.codex/`: agents, config.toml hooks, rules/kit.rules, a manual procedure per workflow; `.agents/`: agents, hooks.json, a `run_workflow` script per workflow; GEMINI.md: Antigravity mechanics), deployed to the workspace root with absolute hook paths, `.agents/skills/<name>` links, the org rules (`.agents/rules/`, `AGENTS.override.md`: local only) and the Codex mechanics; also writes each agent's Character block from `_manifest`. `adapters/heartbeat.ps1`: `bossy.ps1 heartbeat`, the Codex E1 timer.
Needed when: `../.codex/config.toml` exists, `../.agents/hooks.json` exists (the workspace uses the ports), or listed in kit.local.json `goodies`.
Wiring: `kitbag.py` loads `skills/bossy/kitbag_ports.py` (command `port`); `bossy.ps1 precommit` regenerates the ports, `health` / `prepush` and `audit scan` (PORT-DRIFT) check them when it is installed; without it they skip.
