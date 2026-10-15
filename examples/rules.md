# Example path-scoped rules

Copy a block into `rules/<name>.md` (or `rules/<name>.local.md` for org-only conventions, listed in `kit.local.json`
`localOnly`), keep the `paths:` front matter, adapt it to your repo. A path-scoped rule loads only when a matching file is opened.
Org-specific test conventions (frameworks, base classes, fixture helpers, naming) belong in your `rules/*.local.md`.

## Database migrations (any tool)
```markdown
---
paths: ["**/liquibase/**", "**/db/migration/**", "**/Migrations/**", "**/migrations/**", "**/alembic/versions/**", "**/prisma/migrations/**"]
---
# Database migrations
- Only the id/timestamp range your brief assigns; never edit a merged migration; a rollback / down for every change the tool supports.
- Liquibase: the repo's file naming and include layout; append-only master conflicts: `python <kit>/skills/dev-kit/devtools.py keepboth <file>`;
  `dev.ps1 check -Step migrations` = ISSUES 0 before every push.
- Flyway `V<range>__desc.sql` · Alembic: re-point `down_revision` after a rebase (one head) · EF Core / Prisma / Django: regenerate
  on top of the latest after a rebase, never a merge migration.
```

## Tests (any stack)
```markdown
---
paths: ["**/src/test/**", "**/*.spec.*", "**/*.test.*", "**/tests/**", "**/test_*.py", "**/*Tests.cs"]
---
# Tests
- One behaviour per test, arrange / act / assert, names `should_<behaviour>_when_<condition>` (or the repo's style).
- Fixed clocks, no sleeps, no shared mutable state, deterministic builders / fixtures, mocks only at boundaries, no network
  unless the test is tagged integration.
- A fixed bug gets a regression test that fails before the fix. Run: `dev.ps1 check -Step test -Tests <names> -Touched`.
```

## A JVM backend
```markdown
---
paths: ["**/src/main/java/**", "**/src/main/kotlin/**"]
---
# Backend
- DTOs in APIs, never entities; additive changes (optional fields, new endpoints); validation at the boundary.
- Unit tests next to the package (`src/test/...`), integration tests tagged; `dev.ps1 check -Dir <module> -Step test -Touched`.
```

## A web frontend
```markdown
---
paths: ["**/src/app/**/*.ts", "**/src/**/*.tsx", "**/src/**/*.vue"]
---
# Frontend
- Fix a variant in the component's own style, never a global override; shared formatters keyed by field.
- A logic change ships a spec (`*.spec.ts`); a template-only change attaches a 1366x768 screenshot.
```
