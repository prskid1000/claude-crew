# module-audit
- What: revy's static module audit (router R14, `agents/revy.md` kind module): the steps in `skills/crafty/module-audit.md` and
  `devtools.py findings schema | validate <module>.json | summary <module>.json [--sources ".."] [--out <dir>]` (23-key finding
  schema, validation, a summary for `devtools.py doc`).
- Config: optional `findings.required` = the in-scope finding fields (default root_cause, why_today, why_not_prod, db_migration,
  code_location).
Needed when: listed in kit.local.json goodies (goody add does it)
- Wiring: `skills/crafty/adapters/module_audit.py` (devtools.py plugin verb `findings`); revy returns the goody line
  while it is missing. Tests: `tests.ps1` here.
