# Kit token budget

Approximate tokens (UTF-8 bytes / 4) each agent reads when it starts, measured by
`.claude/skills/orchestrate/scripts/kit-cost.ps1`:

- **always-loaded**: `CLAUDE.md` + `rules/multi-agent.md` + the skill index (one description per skill) - every session.
- **start files**: the agent definition (`agents/<type>.md`) and the files it is told to read first (SKILL.md Quick start, LESSONS.md, ...).
- **prompt**: the prompt the workflow builds for that step, rendered by `kit-cost.mjs` (each workflow runs with mock agents and sample args).
- **run: ...** rows add up every step of one sample run (2 dev agents with review/CI/ship/fix + learn; 1 web + 1 app QA item with
  audit/verify/close/release + learn; a kit-retro with 4 analysts + apply).

Not counted: Claude Code's own system prompt, the brief / tester guide / code the agent reads for its actual work, and the
`reference/*.md` files agents open only at the step that names them (the SKILL.md Files index).

## BEFORE vs AFTER

| Agent / run | BEFORE | AFTER | change | AFTER: always-loaded + start files + prompt |
|---|---:|---:|---:|---|
| dev-agent (build) | 12749 | 7988 | -37% | 2499 + 4922 + 567 |
| dev-agent (fix) | 12563 | 7890 | -37% | 2499 + 4922 + 469 |
| mr-reviewer | 12236 | 7440 | -39% | 2499 + 4800 + 141 |
| qa-tester (web) | 11364 | 7337 | -35% | 2499 + 3763 + 1075 |
| qa-tester (app) | 11651 | 7483 | -36% | 2499 + 3763 + 1221 |
| qa-verifier | 11019 | 6919 | -37% | 2499 + 3413 + 1007 |
| coordinator | 10071 | 6623 | -34% | 2499 + 4124 + 0 |
| run: dev-wave (8 steps) | 71791 | 47260 | -34% | 19992 + 24366 + 2902 |
| run: test-and-close (10 steps) | 77525 | 52520 | -32% | 24990 + 21178 + 6352 |
| run: kit-retro (5 steps) | 16927 | 16020 | -5% | 12495 + 0 + 3525 |

The explicit-routing restructure (Router in CLAUDE.md, a Files index binding every file to a step in each SKILL.md) costs about
1k tokens per agent at start compared with the previous Quick-start layout, in exchange for deterministic routing: agents no
longer skip step-bound references (the tester-guide step was once lost that way).

The coordinator row now includes `orchestrate/reference/coordinator-duties.md` (moved out of the always-loaded rule).

Coordinator output per round (measured on a sample workspace with two finished workflows): `supervise.ps1` digest ~99 tokens vs
`-Brief` ~6 (`ok: 1 running, mem 48%`); `wave-report.ps1` for a 3-agent wave ~68 tokens compact vs ~410 with `-Detail`.
Real sessions with many workflows, board entries and flags save proportionally more.

## What changed

1. **Lessons split:** each `LESSONS.md` holds only active rules (≤ 40 lines, newest first, one line each); fixed-in-kit, historical and
   coordinator-only lessons moved verbatim to `HISTORY.md` (never read by agents). `learn.ps1 -Lesson / -Fixed / -Trim` keep the cap.
2. **Quick start SKILL.md:** every skill starts with a ≤ 60-line Quick start; the full sections moved verbatim to `reference/*.md`,
   linked with "read when ...". Testers no longer load the evidence standard up front. The coordinator-only block of
   `rules/multi-agent.md` (loaded by every agent) moved to `orchestrate/reference/coordinator-duties.md`.
3. **Shorter workflow prompts:** text repeating the skills/agent definitions points at the Quick start; WHY/mandate, contracts,
   safety rules and output schemas are unchanged (`kit-cost.ps1 -Steps` shows identical step labels, agent types and models).
4. **Model by stage:** builds on sonnet unless marked complex; review/verify/audit sonnet; ci/ship/close/hold/learn haiku
   (table in `.claude/skills/dev-kit/reference/configuration.md`). Token counts above don't include this saving.
5. **Optional stages:** dev-wave `review: 'auto'`, `learn: 'auto'`; test-and-close `verify: false`, `learn: 'auto'`.
6. **Cheaper supervising:** `supervise.ps1 -Brief` on a 30-minute loop; compact default output for wave-report, track, deployed.

Re-measure: `pwsh -File .claude/skills/orchestrate/scripts/kit-cost.ps1 -Baseline docs/kit-cost.before.json [-Live]`.
Baseline data: `docs/kit-cost.before.json`.
