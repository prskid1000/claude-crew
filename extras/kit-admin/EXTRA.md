# kit-admin

`kittool.py audit setup [--fix] | config [--fill] | recover [--fix]`: install, config and recovery checks (agents/kitty.md steps 1-3).
Needed when: a kitty setup / recover run, or an audit wants the mechanical half of steps 1-3 (`orch.ps1 setup` / `health` / `cleanup` cover the basics).
Wiring: `kittool.py` loads `skills/orchestrate/kittool_admin.py` (audit verbs setup, config, recover).
