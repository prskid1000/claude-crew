# migration-classify
- What: `devtools.py migrations classify|plan|rules|detect|selftest`: LIGHT / HEAVY classes per changeSet (Liquibase, Flyway, Prisma,
  Alembic, Django, EF Core, Rails, Knex, goose, sqitch, plain SQL) and exact revert plans for the local env.
Needed when: you want exact LIGHT / HEAVY reverts of migration layers on the local env instead of a snapshot restore.
- Config: kit.local.json `localEnv.migrations` (`rules`, `extraRules`, `dialect`, `parsers`); without the extra the local env snapshots before migrations and restores on rollback.
- Wiring: `skills/dev-kit/adapters/migrations.py`, registered as the devtools.py verb `migrations`. Test: `devtools.py migrations selftest`.
