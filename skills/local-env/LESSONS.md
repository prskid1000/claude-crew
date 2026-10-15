# Local env lessons — active rules (read at step 0; ≤ 40 lines)
Newest first, one line each, `(n×)` = times seen. Managed by `orchestrate/scripts/learn.ps1 -Skill local-env`.
- Migration snapshots per deploy cost minutes and GBs: reversible (LIGHT) changeSets are reverted exactly instead (Liquibase `rollbackCount` on a changelog cut down to the leaving changeSets touches nothing else, verified 4.33); only HEAVY ones get a sandbox or snapshot.
- Sandbox DB isolation: never by renamed schema copies (apps hardcode admin/tenant schema names and migrate the real ones); use a separate DB server per sandbox with real names, and verify the main DB is untouched (data AND migration markers) after the first sandbox run.
