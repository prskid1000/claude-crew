# migration-classify
- What: `devtools.py migrations classify|plan|rules|detect|selftest`: LIGHT / HEAVY classes per changeSet (Liquibase, Flyway, Prisma,
  Alembic, Django, EF Core, Rails, Knex, goose, sqitch, plain SQL) and exact revert plans for the local env.
Needed when: `localEnv.envs.*.db.rollback` = `*` (exact LIGHT reverts of migration layers; without it every layer is HEAVY: sandbox or snapshot).
- Config: kit.local.json `localEnv.migrations` (`rules`, `extraRules`, `dialect`, `parsers`); without the extra the local env snapshots before migrations and restores on rollback.
- Wiring: `skills/dev-kit/adapters/migrations.py`, registered as the devtools.py verb `migrations`. Test: `devtools.py migrations selftest`.
