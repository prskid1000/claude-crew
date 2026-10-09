# Project profile: <name>

Copy to `<project>.md`. Keep it factual and short; it's read at the start of every audit of this project.

## Repo layout
| Layer | Repo / folder | Stack (from `stack.ps1`) | Notes |
|---|---|---|---|
| UI | | | |
| API | | | |
| DB schema | | migrations tool: | single- or multi-tenant? |

## Intended-behaviour sources
- Docs / knowledge base / MCP tools / decision records that say what's *meant* to happen.

## Live / test data (read-only)
- How to query a test environment (DB MCP, API target in `qa-kit/targets.local.json`, ...). Never production writes.

## Findings output
- Output folder, id prefix convention, workbook generator (if any).

## Known by-design behaviours (not bugs)
- Add one line per rejected false positive that was "intended".

## Review lessons
- Per review round: acceptance rate, rejected patterns (with the §5 rule that catches each), landed patterns.
