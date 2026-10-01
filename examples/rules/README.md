# Example rules

Path-scoped rules (`.claude/rules/*.md` with a `paths:` front-matter list) load only when Claude opens a matching file.
The kit ships one generic rule set (`.claude/rules/multi-agent.md`, always loaded, and `db-migrations.md`).
The files here are examples of codebase-specific conventions; copy what fits into `.claude/rules/` and edit it.
