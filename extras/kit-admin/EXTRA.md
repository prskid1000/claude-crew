# kit-admin

kitty's tools: `kittool.py audit setup [--fix] | config [--fill] | recover [--fix]` (agents/kitty.md steps 1-3), `cost [--steps]` (start tokens per agent, workflow prompts), `release [--tag] [--publish]` (SemVer + notes), `budget raise -Reason` (the token cap x1.1).
Needed when: `skills/dev-kit/kit.local.json` exists (a configured install: the weekly audit nudge spawns kitty), or listed in kit.local.json `extras`.
Wiring: `kittool.py` loads `skills/orchestrate/kittool_admin.py` (audit verbs setup, config, recover; commands cost, release; `budget raise` through `kittool.py budget`).