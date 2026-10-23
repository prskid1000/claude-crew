# Changing the kit (extra kit-admin)
Read by `kitty` at step 0 and by `revy` (kind kit). README "Extending" points here; `[CODE]` = the lint code that enforces a rule.

## Parts
Parts are added, renamed or removed with the `scaffold` extra (`kittool.py new | rename | remove <kind> <name>`, `new adr <title>`:
template, manifest, Router / Events rows, test stub; lint TODO-STUB refuses unfilled ones); then `port`, lint 0, tests. An optional
feature goes to the `extras` branch, not the core.
- **Registry** [MANIFEST, OLD-NAME]: `_manifest` holds every agent, skill, workflow, Router / Events row and cap; README tables,
  Character blocks and ports are generated from it; `renamed` lists old names (no aliases).
- **Formats** [SCHEMA, AGENT-TYPE]: SKILL.md and subagent front matter + the Character shape, JSON-Schema checked; every workflow
  `agent()` names a crew agentType. **Versions**: SemVer tags from Conventional Commits (`kittool.py release`; no CHANGELOG).
  **Decisions**: ADR lines in LESSONS.md "Decisions". Every addition: front matter, manifest entry, reachability edge, test, flow
  node, README row, ports; lint refuses a half-added part.

## Hard rules
- **30 content + 8 plumbing files** [FILE-CAP, PLUMBING-CAP] (`git ls-files` minus the ports and `tests/`; plumbing = LICENSE,
  .gitignore, .gitattributes, .githooks/*, .github/*, settings.json; git-ignored local files never count). One script per area;
  templates fold into a SKILL.md, an agent or `skills/dev-kit/templates.md`; tests in `tests/<area>.tests.ps1` (shared helpers:
  `tests/harness.ps1`).
- **Token budgets** [BUDGET] (UTF-8 bytes / 4; README graph sections excluded; LESSONS.md: 40 lines per skill), from kittool
  `BUDGETS` and `_manifest.caps` (the README "Extending" table). Over a budget: trim first (dense prose, dedupe, never golf that
  hurts reading); only when trimming cannot make room, `kittool.py budget raise -Reason "<why>"` (x1.1, rounded to 1k; the reason
  goes in the commit message) [BUDGET-CAP refuses any other change of the total]. The total counts what agents load; `tests/`
  has its own cap `_manifest.caps.testTokens` [BUDGET-TESTS].
- **Reached from the root** [REACH-NONE, REACH-MENTION]: CLAUDE.md -> AGENTS.md Router -> skill / workflow / agent -> its Files
  row; mentions do not count; every edge has its reason.
- **Generic** [ORG-TERM]: no org, product, tenant, host, id, person, local path or assumed stack; org values -> `kit.local.json`
  (today's behaviour as default), org rules -> `rules/*.local.md`, org lessons -> `LESSONS.local.md`.

## Shapes
- **Script** [SCRIPT-HEADER, PS-VERSION, RUNTIME-RAW, RUNTIME-MAP, DESKTOP-OPEN, SECTION-MAP, SECTION-UNMAPPED]: one entry file per area with
  verbs, each function in a `---- <name>:` section (README "Extending"); header with usage, `Sections:` and `Exit codes:` (0 ok · 1 problem · 2 usage); shared params `-Env -Run -Task -Repo -Dir -Agent -Mrs -DryRun -Json -Quiet`; a
  failed call is UNKNOWN, never a state; paths via `Get-KitPath` / `kit_path` / `kitPath` / `rp()`; bounded network calls; no
  desktop opens without `--open` / `-Open` ("Script header" below).
- **Skill** [SKILL-DESC, SKILL-BLOCK, FILES-*]: `description: "Load when: ... Not when: ... -> <sibling>."`; blocks Load when,
  Not when, Hands off to, Files (each file with its step), steps, Rules, Learn.
- **Agent** [AGENT-SPAWN, AGENT-SKILL]: description with "Spawned by", "Precondition", "Not for"; `tools` only without MCP needs;
  body: Character, Kind, Load first, non-negotiables (incl. Budget), the `STEP:` rule, report shape, self-improvement.
- **Workflow** [WF-WHEN, WF-CLOCK, WF-CRLF]: `whenToUse` = its router row; every arg in the header; no clock calls; LF; plan +
  budget gate (README "Configuration" `budget`); ends with Learn + cleanup; check with `node --check` and `cost --steps`.
- **Rule**: always-loaded only for short hard rules; else `paths:` front matter (README "Rule examples"). **Text** [PROSE]: a row
  in templates.md "Writing standards" per artefact type. **Config key** [CONFIG-UNDOC]: optional, a README "Configuration" row, a
  `kit.example.json` sample. **Hook**: `pwsh` exec form, SessionStart < 2 s, slow work async.

## Before every push
`agents/kitty.md` step 8: `kittool.py lint` (0 problems, 0 counted flow issues), `port` + `port --check` (extra ports),
`tests/kit-tests.ps1 [-Area <area>]` (areas in parallel), `lint --org-terms <kit.local.json>`, `cost --steps` after a workflow
change. pre-commit regenerates README graph sections, staged scripts' `Sections:` maps and ports and blocks on lint (a flow issue with a `flow: <reason>` marker is
deliberate); pre-push blocks stale ports, org terms and local files; commit with `dev.ps1 wt commit`.

## kitty steps 1-3 (`$A` = `python -X utf8 <wt>/skills/orchestrate/kittool.py audit`)
1. **Setup:** `$A setup` (clone, git hooks, `localOnly` excludes, runtime + state folders, hooks clean and fast, ports, CLIs and
   auth: check only, never log in). `$A setup --fix` runs `orch.ps1 setup` (idempotent).
2. **Missing config:** `$A config` (local files vs `kit.example.json`, the README "Configuration" table and the keys scripts
   read). `--fill` writes only documented defaults (backup next to the file). Org values (hosts, ids, credentials, `orgTerms`)
   = ASK lines `<file> <key>: why`; never guess them, never print or copy a value from a `*.local.*` file.
3. **Recover:** `$A recover` (uncommitted changes, behind/ahead, kit worktrees, merged kit branches, tracked local files, launch
   records of dead runs, stale board entries, orphan worktrees, cleanup dry run, runtime size). `--fix` only when step 0 found
   nothing running; unmerged work is listed with its exact command, never deleted.

## kitty steps 5-6 (audit; build / fix / docs: on what you change)
5. **Generic & agnostic:** `kittool.py lint --org-terms <kit>/skills/dev-kit/kit.local.json` = 0 ORG-TERM; no hard-coded
   product, tenant, status, list id, host, path, stack, DB; each such value -> config key with default, org value in report
   additions. Any stack, local env shape, deploy mechanism and tracker must work through config.
6. **Consistency:** Files indexes vs disk; README "Configuration" vs script keys; manifest vs agents, skills, workflows,
   Router and Events; ports in sync (`kittool.py port --check`); README graph current;
   no desktop open without `--open` (DESKTOP-OPEN); every file reached from root; budgets and file caps (over: trim first;
   `kittool.py budget raise -Reason` only when trimming cannot make room); script headers (usage, exit codes).
   Writing: lint PROSE for kit files; `kittool.py prose --kind <kind> <file>` on sample artefacts (latest MR bodies,
   tracker comments, briefs, testing docs, QA reports).

## Flows to trace (kitty step 4)
| Flow | Hops |
|---|---|
| dev | Router -> orchestrate -> `buildy.js` (build + local loop, decisions, review, fix, ci, ship, track, deploy batch, learn) -> `devy` -> `revy` -> dev-kit (`dev.ps1 wt/check/gate/stack`, `devtools.py mr/doc/merge`) -> local env (extra `local-env`) -> `orch.ps1 track`, `deploy` (extra `deploys`) |
| test-only | Router -> `testy.js` (prepare, load-run, test, audit, verify, close) -> `checky` lead / test / verify -> `qa.ps1 seat/deployed/api/finalize` -> result rule -> `orch.ps1 supervise` (failedTesting, [Bug]) -> bugfix /buildy |
| coordinator | `orch.ps1 supervise -AutoFix -Brief` -> board, track, decide, launch, recover, outbox, report, cleanup; extras' supervise parts |
| kit | `settings.json` hooks (`dev.ps1 guard`, `orch.ps1 health/guard-sendmessage`, `orch.ps1 cleanup -IfDue`), `.githooks`, `kittool.py lint/flow/extra`, `kitty` -> `revy` -> push main |

## Script pitfalls
pwsh 7: case-insensitive variables (`$L` = `$l`); `-File x.ps1 -List a,b` passes one string (`Split-KitList`); short helper names
that are aliases (`r`, `rd`, `h`, `del`, `diff`: an alias beats a function and can delete files); `[IO.File]` resolves against the
process directory; `exit` in a dot-sourced file ends the caller; `SilentlyContinue` hides throws; native commands never throw
(`$LASTEXITCODE`). Python: `encoding='utf-8'`, `shutil.which` for shims, timeouts. JS workflows: no `Date.now()` / `new Date()`,
LF only, every `agentType` a crew literal in the `agent()` call (lint AGENT-TYPE).

## Rule examples
Copy the block into `rules/<name>.md` (org-only: `rules/<name>.local.md`, in `localOnly`) and adapt it; a `paths:` rule loads only
when a matching file is opened.

### Database migrations (any tool)
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

## Script header (every kit script; kit-lint SCRIPT-HEADER)
```powershell
<#
<file>: <purpose, one line>. Run from pwsh 7:
  & <kit>/skills/<skill>/<file> <verb> [args]
Verbs: <verb> <params> — <what>
Inputs: <config keys, files, env>. Outputs: <text / JSON with -Json / files>.
Exit codes: 0 ok · 1 problem found · 2 usage error.
Sections: L<n> <name> · ... (kittool.py sections --fix writes it)
#>
#Requires -Version 7
```
Extras' scripts too: lint checks installed ones, `kittool.py extra test` the branch's (fix maps on the extras branch).
Shared parameter names: `-Env -Run -Task -Repo -Dir -Agent -Mrs -DryRun -Json -Quiet`. No silent failures: a failed call is
UNKNOWN, never a state. Idempotent where possible. `learn` signals for surprises.

## Audit report
Saved to `<runtime>/logs/kitty-audits/audit-<date>.md` (kitty step 9).
```markdown
# Kit audit <date> (<commit>, branch kit/audit-<date>)
## Result
- <N> fixed (<commits>), <N> proposed, <N> ASK, <N> rejected · lint 0 · ports ok · tests ok · org terms 0 · content <n>/<cap> · plumbing <n>/<cap> · tokens <n>
## ASK
- `<file> <key>`: <why> (never values)
## Findings
| # | Severity | Where | Problem (evidence) | Status |
|---|---|---|---|---|
## Improvements · kit.local.json additions · Next audit
```
