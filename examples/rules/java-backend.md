---
paths:
  - "**/*.java"
  - "**/pom.xml"
---

# Backend (Java / Spring) conventions — EXAMPLE

Example of a path-scoped rule: copy it into `.claude/rules/` and adapt it to your codebase. Claude Code loads it
only when a matching file is opened.

- **Layering:** REST → Service → Repository → Domain. **Never expose JPA entities in REST** — use DTOs + a mapper (e.g. MapStruct).
- API changes are additive: optional DTO fields, new endpoints/params; never break existing clients or tenants.
- Liquibase rules: see `db-migrations.md` (loads when you open a changelog).
