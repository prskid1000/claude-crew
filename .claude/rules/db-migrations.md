---
paths:
  - "**/liquibase/**"
  - "**/db/migration/**"
  - "**/Migrations/**"
  - "**/migrations/**"
  - "**/alembic/versions/**"
---

# Database migrations (any tool)

- Use only the id/timestamp range your brief assigns, so parallel agents never collide. Never edit a migration that has merged.
- **Liquibase**: file `YYYYMMDDHHMMSS_description.xml`, appended to `master.xml`; first changeSet `tagDatabase`; a `<rollback>`
  on every schema/data changeSet; FK names `fk_<table>_<column>` (follow the repo's own naming if it has one).
  `master.xml` rebase conflicts: `python <workspace>/.claude/skills/dev-kit/scripts/keepboth.py <file>`.
  Before every push: `check.ps1 -Dir <module> -Step migrations` must print `ISSUES 0`.
  Replacing an existing empty table: drop it behind `preConditions onFail=MARK_RAN` with a rollback that recreates it.
- **EF Core**: one migration per agent named with your range prefix; regenerate on top after a rebase if the snapshot conflicts.
- **Flyway**: `V<range>__desc.sql`. **Alembic**: re-point `down_revision` to the new head after a rebase (one head only).
  **Django**: re-number on top of the latest; no `--merge` migrations.
- Unsure what's deployed? Check the environment's DB read-only (e.g. a read-only database MCP server or SQL client) before adding a column.
