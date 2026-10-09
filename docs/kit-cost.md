# Kit token budget

Approximate tokens (UTF-8 bytes / 4) each agent reads when it starts, measured by
`.claude/skills/orchestrate/scripts/kit-cost.ps1`:

- **always-loaded**: `CLAUDE.md` + `rules/multi-agent.md` + the skill index (one description per skill) - every session.
- **start files**: the agent definition (`agents/<type>.md`) and the files it is told to read first (SKILL.md, LESSONS.md, ...).
- **prompt**: the prompt the workflow builds for that step, rendered by `kit-cost.mjs` (each workflow runs with mock agents and sample args).
- **run: ...** rows add up every step of one sample run (2 dev agents with review/CI/ship/fix + learn; 1 web + 1 app QA item with
  audit/verify/close/release + learn; a kit-retro with 4 analysts + apply).

Not counted: Claude Code's own system prompt, the brief / tester guide / code the agent reads for its actual work.

## BEFORE

| Agent / run | always-loaded | start files | prompt | BEFORE total |
|---|---:|---:|---:|---:|
| dev-agent (build) | 2748 | 9380 | 621 | 12749 |
| dev-agent (fix) | 2748 | 9380 | 435 | 12563 |
| mr-reviewer | 2748 | 9226 | 262 | 12236 |
| qa-tester (web) | 2748 | 7199 | 1417 | 11364 |
| qa-tester (app) | 2748 | 7199 | 1704 | 11651 |
| qa-verifier | 2748 | 6865 | 1406 | 11019 |
| coordinator | 2748 | 7323 | 0 | 10071 |
| run: dev-wave (8 steps) | 21984 | 46592 | 3215 | 71791 |
| run: test-and-close (10 steps) | 27480 | 41858 | 8187 | 77525 |
| run: kit-retro (5 steps) | 13740 | 0 | 3187 | 16927 |

Baseline data: `docs/kit-cost.before.json` (compare with `kit-cost.ps1 -Baseline docs/kit-cost.before.json`).
