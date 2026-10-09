# Wave brief: <wave name>, <date>

Read `<workspace>/.claude/skills/dev-kit/SKILL.md` first. This brief adds wave-specific rules and wins where the two differ.

**Item source:** <spreadsheet path + sheet, or tracker epic URL>. Each item has an ID, a work package, a severity and why it's open.
**Decisions:** <memory file / decisions doc>. They are final; don't re-ask.
**Environment for testing:** <web URL / API URL / tenant or account>. Never production.

## Repos
| Repo | Main checkout | Target branch | Link deps from (if not the main checkout) | Notes |
|---|---|---|---|---|
| <api> | `<repos root>/<repo>` | `main` | | migrations: Liquibase / EF / Flyway / Alembic / none |
| <web> | `<repos root>/<repo>` | `<branch>` | `<repos root>/<checkout on target>` | |
| <app> | `<repos root>/<repo>` | `<branch>` | | |

## Ownership (stay in your area; add only one-line hooks elsewhere and say so)
| Agent | Items | Area (screens / packages / files) | Repos | Migration range | Complex? (strongest model) |
|---|---|---|---|---|---|
| X1 | … | … | api, web | 2026MMDD100000–2026MMDD105959 | yes: new data flow |
| X2 | … | … | app | — | no (sonnet) |

- **Migration ranges**: non-overlapping per agent, never reused from an earlier wave.
- **Known overlaps**: <"X1 and X2 both touch screen S: X1 = tab A, X2 = export option">.
- **Contracts between agents**: <"X1 adds DTO field f (optional); X2 consumes it after X1's API MR merges">.

**Branch / worktree:** `f/CU-<task>-<slug>`, worktree name = your agent id (e.g. `x1`).
**Tracker:** create your task under epic <id> in list <id>, assigned to <user id>, named `[Feature] <product> — <code> <title> (<repos>)`.

**Items that turn out to need a product decision or a behaviour change for existing users:** defer with a one-line reason. Don't guess.
