---
name: orchestrate
description: Coordinator playbook for multi-agent work in any repo/stack in this workspace — plan a wave of parallel dev agents, write the brief, run /dev-wave, relay decisions, then QA the deployed result with /test-and-close and loop bug fixes. Use when the user asks to run many agents in parallel, split an epic/backlog across agents, run a dev wave, resume stopped agents, or test-and-close a batch of tasks.
argument-hint: "[epic / sheet / task list]"
---

# Quick start (you = the coordinator)

Project facts (repos, branches, environments, accounts, product rules) live in the wave **brief** / QA **run.json**, memory or the
repo's `CLAUDE.md`; nothing project-specific is hard-coded. Run kit scripts with **pwsh 7**. `<kit>` = `<workspace>/.claude`.

**Launching:** always by path — `Workflow({ scriptPath: "<kit>/workflows/dev-wave.js", args })` (named lookup breaks after a `cd`).
Always pass `kitDir` (absolute) and `mandate` (the owner's own words that asked for the work: without it agents drop their items for the
latest chat message). /test-and-close takes the short form `{ runDir, kitDir }` (run.json is read from the run folder).
Models: builds run on sonnet unless the brief marks the agent complex (`agents[].complex: true` → strongest); review/verify/audit sonnet;
mechanical steps haiku. Override per agent (`model`) or per stage (`models: {...}`) — docs/configuration.md.
Cheaper runs: dev-wave `review: 'auto'` (small, non-sensitive diffs skip review), `learn: 'auto'` (learn only after trouble);
test-and-close `verify: false` (FAILs go straight to bug tasks, no re-test).

| # | Step | Dev side | QA side |
|---|---|---|---|
| 0 | Scope | Read the epic/sheet; group work **by area, not item count** (disjoint screens/packages per agent) | Note which items need app / web / API testing |
| 1 | Brief | Fill `templates/WAVE_BRIEF.md` in the scratchpad: repos + targets, ownership, migration ranges, contracts | — |
| 2 | Build | `/dev-wave` with args `{ brief, agents:[{id, items, area}], mode, review, kitDir }` — or Agent tool, type `dev-agent`, prompt "Follow the brief <path>. You are X3 …" | — |
| 3 | Relay | Append decisions/contracts to `<brief>.contracts.md` (agents re-read it before every push). **Never SendMessage a `/dev-wave` agent by ID** (the `guard-sendmessage.ps1` PreToolUse hook blocks it) — it spawns a duplicate in the same worktree. SendMessage only for agents you spawned yourself with the Agent tool | — |
| 3b | Merge hold | A repo whose target deploys on merge and the user wants to approve: launch `/dev-wave` with `holdMerge: [<repo>]` (or `true`). Its MRs stay open, reviewed and green; ask the user, then merge. |
| 4 | Ship | Agents merge producers first (DB/API), then clients; tracker → review → promoted | — |
| 5 | Deploy | **A human** deploys to the test environment | `android-swarm/app-build.ps1` from the merged branch (phones: the app agents lease and boot them themselves) |
| 6 | Test | — | Run folder `<workspace>/.claude-runtime/qa-runs/<date>-<name>/` + `run.json`; `/test-and-close` with that object (+ `kitDir`) as args; start `qa-kit/scripts/autoclose.ps1` |
| 7 | Bugs | `[Bug] … failed checks` tasks → `templates/BUGFIX_BRIEF.md` → `/dev-wave` with `mode: 'bugfix'` | Retest: same workflow, `retest: true` on the items |
| 8 | Close | Reconcile backlog vs merged MRs + tracker comments; list only what's open, each with a reason (external / new data model / product decision / no data / cut for size) | `in test` only after deployment, set by a person |

Stopped agents (usage limit, RAM, user): `templates/RESUME_BRIEF.md`, or `/dev-wave` with `mode: 'resume'`; they continue from their worktrees.
~15 parallel dev agents is fine: they queue on the machine-wide memory gate. Expect hours for big waves.

**Supervising:** ONE heartbeat for the whole session, generic prompt (what runs comes from the script, not the prompt):
`/loop 15m` → `& <kit>/skills/orchestrate/scripts/supervise.ps1 -Session <this session id> -AutoFix`. Act on **ACT** flags (each prints
its action), re-check **WATCH** next round, leave healthy agents alone. When a workflow finishes: `wave-report.ps1 -Run <wf id>`
(never parse the truncated notification), reconcile, then the next step: open findings → follow-up wave, deploy → QA, failed checks →
bug-fix wave (`scripts/bug-brief.ps1 -Task <id> -Agent B-<code> -Repos <r>` per bug, ONE wave for all open bugs). Stopped a workflow
yourself? `supervise.ps1 -MarkStopped <run id>`. Stop the loop when nothing runs.

**Relay, never message:** decisions/contracts → append to `<brief>.contracts.md` (agents re-read before every push); never SendMessage a
workflow agent by id (spawns a duplicate; a hook blocks it). Answer QA testers in `<runDir>/lead-notes.md`. Never set `in test` before
deployment; deploys are a person's call (step 5), and repos whose target deploys on merge get `holdMerge`.

**Learn:** read `LESSONS.md` (next to this file) first. Kit friction → fix the script/rule in the same session; `learn.ps1` records
signals; `/kit-retro` turns them into lessons and rules. Token budget per agent type: `scripts/kit-cost.ps1`.

## Reference (read only when you need it)
- `reference/coordinator-duties.md` — supervising like a human lead, fixing the kit, one kit source + sync-kit, being proactive: read when you start coordinating.
- `reference/supervising.md` — every supervise check and the typical ACT moves: when a flag is unclear.
- `reference/self-improvement.md` — signal sources, /kit-retro, bug-brief, memory-based QA scaling, model choice, mandate.
- `reference/layout.md` — what lives where, command quick reference, hard-won rules, adding a project, self-cleaning, dashboard, document formats.
