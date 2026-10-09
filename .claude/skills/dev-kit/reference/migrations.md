# Database migrations (dev-kit reference)

Read before you add or change a DB migration (any tool).

## 6. Database migrations (whatever the tool)
- **Use only your assigned range** for ids/timestamps, so parallel agents never collide.
- **Never edit a migration that has already merged**; add a new one.
- **Liquibase**: file `YYYYMMDDHHMMSS_desc.xml` inside your range, first changeSet `tagDatabase`, a `<rollback>` on every
  schema/data changeSet, append the include to `master.xml`. On rebase conflicts in `master.xml`: `python $K/keepboth.py <file>`.
  Before every push: `check.ps1 -Step migrations` must print `ISSUES 0` (no duplicate addColumn/createTable). To replace an
  existing empty table, drop it behind a `preConditions onFail=MARK_RAN` guard with a rollback that recreates it.
- **EF Core**: one migration per agent, named with your range prefix; after a rebase, if the model snapshot conflicts, regenerate your migration on top.
- **Flyway**: `V<your range>__desc.sql`. **Alembic**: after a rebase, re-point your `down_revision` to the new head (one head only).
  **Django**: `makemigrations --merge` is not allowed; re-number on top of the latest.
- Unsure what's deployed? Check the environment's DB read-only (e.g. a read-only database MCP server or SQL client) before adding a column.
