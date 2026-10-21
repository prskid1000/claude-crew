# liquibase
- What: `devtools.py lbcheck <master.xml> [since]`, the Liquibase sanity check `dev.ps1 check -Step migrations` runs for a repo
  without its own `repos[].migrations.check`: replays master.xml's includes; flags create / add of an existing table or column
  without `<preConditions>`, schema changeSets without `<rollback>`, "not reversible" ones with an empty rollback.
Needed when: `localEnv.envs.*.db.applied` ~ `liquibase`, `localEnv.envs.*.db.rollback` ~ `liquibase`, or listed in kit.local.json `extras`
- Wiring: `skills/dev-kit/adapters/liquibase.py` (devtools.py plugin verb `lbcheck`); without it `check -Step migrations` on
  Liquibase XML is UNRUN (exit 5) with the extra line. Tests: `tests.ps1` here.
