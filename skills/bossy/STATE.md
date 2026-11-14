# Kit state (`.state/` durable, `.runtime/` disposable)
Read by kitty on a state change, revy (kind kit), agents needing a task's links ("Indexes").
Paths: `kit.example.json` `_paths` (`Get-KitPath` / `kit_path`); schemas: the Inventory below (`kitbag.py state lint` parses
it; supervise lints recent files each beat: BAD = WATCH).

## Rules
- **One file per key** (task, session, decision, run, publish key); a shared map only with one owning writer.
- **Writes:** `Write-KitState` (lib.ps1) / `state_write` (kitbag.py): temp file + move, `schemaVersion`, `updated`,
  `holder` {agent, session, pid, pidStart, holderPid, holderStart}; read-modify-write inside `Invoke-KitLocked` / `locked()`
  on that file. Log lines: kitlog only (`Write-KitLog`, `kitlog()`).
- **Reads:** `Read-KitState` / `state_read`: `$null` / `None` when missing or broken, never throws; unknown fields kept.
- **Times:** ISO 8601 with offset (`ToString('o')`, `isoformat()`); readers accept offset-less ones.
- **Ids:** stable, file-safe: session `<agent>-<8 hex>`, decision `d-<yyyyMMddHHmmss>-<agent>-<4>`, task = tracker id, run =
  workflow run name.
- **Format:** JSON for scripts; markdown only for people (`resume-<run>.md`, resume briefs, reports: templates.md `kit-report`).
- **Change a schema:** bump `v<n>` in its row and the writer; readers accept `n-1`. A new file: a `_paths` name + a row.
  Deleting state in use: the owner decides.
- **Lifecycle:** `.runtime` ages out by `_paths.keep` (`bossy.ps1 cleanup`); in `.state` it only trims the Inventory's logs
  (`Invoke-KitLogTrim`), deletes `tracking.json.migrated`.

## Indexes (not the tracker's comments)
- `.state/tasks/<id>.json`: `track` (MRs in merge order, mergeAfter, onMerged, done: `bossy.ps1 track`), `docs.<kind>` (url,
  key, type: `devtools.py doc --key <id>:<kind>`), `comments.<kind>` (the comment `tracker comment -Kind` edits), `envRuns[]`
  (env, run, code, pass, fail, notTested, doc: `pokey.ps1 finalize`), `cases` (`devtools.py cases`); `rollup` (`task_rollup.ps1`; a parent: sections, milestones,
  `closeAsk` = its one close-parent decision, `parentClosed`), `itemIds` / `itemsFrom` / `itemsSig` / `itemsFinal` (the Items checklist).
- `<qa run>/index.json`: `items.<code>` -> tasks, doc, pubKey, pass, fail (`pokey.ps1 finalize`); a build run:
  `work/waves/<run>.json` (`bossy.ps1 report`).

## Inventory
Schema: `<form>[=<glob>] v<n>: <required keys> [+ <allowed keys>]` (a list: another key = drift, BAD); a `<name>:<part>` row = another file kind in that folder; form json (one object), dir (one JSON per key, default `*.json`), jsonl (one
object a line; the last is checked), text; v0 = no schemaVersion yet.

| Name | Owner | Schema | Lifecycle |
|---|---|---|---|
| `tasks` | `lib.ps1` `Update-KitTracking` / `Update-KitTaskIndex`, `devtools.py publish`, `pokey.ps1 finalize` | `dir v1: task` | keep |
| `tracking` | none (legacy) | `json v0: tasks` | read until the first tracking write moves it into `tasks` and deletes it |
| `automerge` | `devtools.py merge`, `bossy.ps1 track run` | `json v1: refs` | an entry until its MR merges |
| `mr-ignore` | `bossy.ps1 track ignore` | `json v1: mrs` | keep |
| `published` | `devtools.py publish`, `crafty.ps1 tracker create -Key` | `dir v1: key` | keep |
| `param-state` | `lib.ps1` params | `json v0: byKey` | keep (raw obs 14 d, hourly sketches 90 d) |
| `params-changes` | `kitlog` (`Write-KitParamChange`) | `jsonl v0: at key ctx` | keep (append-only) |
| `logs-summary` | `kitlog` (`Invoke-KitLogTrim`) | `jsonl v0: at stream period n` | keep |
| `signals` | `bossy.ps1 learn` | `jsonl v0: at skill kind text + run script verb ref source` | `logs.keepDays`, then `logs-summary` (retired: kept) |
| `decisions-log` | `kitlog` | `jsonl v0: at` | `logs.keepDays`, then `logs-summary` |
| `deploy-log` | `kitlog` | `jsonl v0: at` | `logs.keepDays`, then `logs-summary` |
| `scope-log` | `kitlog` | `jsonl v0: at` | `logs.keepDays`, then `logs-summary` |
| `leases` | `kitlog` | `jsonl v0: at event kind` | keep, capped |
| `outbox` | tracker writes | `jsonl v0: at` | until replayed |
| `audit` | `kitlog` streams | `text v0` | 30 d |
| `last-retro` | `bossy.ps1 tidy done` | `text v0` | keep |
| `last-kitty-audit` | `kitbag.py audit stamp` | `text v0` | keep |
| `pauses` | `bossy.ps1 pause / resume` | `dir v1: at run state` | keep |
| `programs` | `bossy.ps1 program` | `dir v1: updated` | keep |
| `browser-ports` | `browser.mjs` | `json v0` | keep |
| `ports-deployed` | `kitbag.py port` | `json v1: files` | rewritten each deploy |
| `owner-apps` | `bossy.ps1 supervise` | `json v0` | keep |
| `runtimes` | `crafty.ps1 runtime` | `dir v0: leases` | keep |
| `locks` | `lib.ps1` (`repos[].exclusiveTests`) | `json v0: held waiting` | keep |
| `board` | `bossy.ps1 board` | `dir v1: agent session run beat status` | 14 d |
| `launches` | `bossy.ps1 launch`, workflows (`args-*`) | `dir=self-*.json v1: script run args` | 3 d |
| `agents` | `crafty.ps1 checkpoint` | `dir=*/resume*.json v1: agent run steps` | 7 d |
| `decisions` | `bossy.ps1 decide` | `dir v2: id status question + kind run agent item options blocking contracts at task mrs answer by answeredAt recommend commit parentId gate source usedAt usedBy supersedes` | 14 d |
| `qa-runs` | `testy.js`, `pokey.ps1 finalize` | `dir=*/index.json v1: run items` | 14 d |
| `qa-runs:run` | `pokey.ps1 prepare`, `retest` | `dir=*/run.json v0: title runDir items + kitDir tracker target mandate left lanes tester envLines localEnv envFixCycles webParallel apiParallel verify learn context contextFiles alsoTargets outOfScope runSettings devices skipClose driveParent` | 14 d |
| `qa-runs:results` | the tester (testy.js CHECKS_SCHEMA), `pokey.ps1 results patch` | `dir=*/*/results.json v0: code checks + findings setup_changes data_created skipped handoff` | 14 d |
| `qa-runs:held` | `pokey.ps1 results hold` | `dir=*/*/held.json v0: code held at + envFix summary` | 14 d |
| `qa-runs:bugs` | `pokey.ps1 finalize` | `dir=*/bugs.json v0: groups + groups` | 14 d |
| `qa-runs:cells` | `pokey.ps1 finalize` | `dir=*/*/cells.json v0` | 14 d |
| `waves` | `bossy.ps1 report` | `dir v0: run` | 14 d |
| `supervise-state` | `bossy.ps1 supervise` | `json v0` | 30 d |
| `live-steps` | `bossy.ps1 supervise` | `json v0: at` | 30 d |

## Artefacts (drift guard)
Every agent-written kind (templates.md "Writing standards" + run files), its writer (a renderer, or `free: <who> (<plan>)`), place
and shape (`md <first-line regex>`, `todo <regex>` + `- [ ] <code> · <desc> · <ref>` items, `json <keys>`, `any`; the longest
matching place decides). `kitbag.py lint` [ARTEFACT]: a kind without a row fails. `state lint`: an unlisted `.md` / `.json` in
`work/briefs|waves` or a QA run's folder = BAD; in `work/docs`, agent scratch (`work/agents/<id>/`) or loose in `work/` = WARN.

| Kind | Writer | Where (runtime) | Shape |
|---|---|---|---|
| `skill` | free: kitty (kit source) | — | — |
| `skill-step` | free: kitty (kit source) | — | — |
| `agent` | free: kitty (kit source) | — | — |
| `rule` | free: kitty (kit source) | — | — |
| `reference` | free: kitty (kit source) | — | — |
| `lesson` | `bossy.ps1 learn` | — | — |
| `history` | `bossy.ps1 learn -History` | — | — |
| `wave-brief` | `devtools.py render wave-brief` | `work/briefs/*.md` | `md ^# (Wave brief\|Bugfix wave\|Contracts)` |
| `bug-brief` | `bossy.ps1 bugbrief` | `work/briefs/*.md` | `md ^# Bug-fix brief:` |
| `resume-brief` | `crafty.ps1 checkpoint`, `bossy.ps1 recover` | `work/briefs/*.md` | `md ^# Resume brief:` |
| `handoff` | `crafty.ps1 checkpoint -Brief` | `work/briefs/handoff-*.md` | `md ^# Resume brief:` |
| `testing-goals` | `devtools.py cases render` | `work/docs/*-goals.md` | `md ^# Testing goals:` |
| `testing-doc` | `devtools.py cases render` | `work/docs/*-human.md` | `md ^# Testing:` |
| `published` | `devtools.py doc` (kept copies) | `work/docs/*` | `any` |
| `testing-ai` | `devtools.py cases render` | `work/docs/*-ai.md` | `md ^# Testing doc \(AI\):` |
| `qa-report` | `pokey.ps1 finalize` | `work/qa-runs/*/report.md` | `any` |
| `qa-run` | `testy.js`, `pokey.ps1 results` (written once, deltas by id) | `work/qa-runs/*/*.json` | `any` |
| `lead-notes` | `pokey.ps1 prepare`, `lead-notes add` | `work/qa-runs/*/lead-notes.md` | `md ^# Lead notes:` |
| `result-note` | `pokey.ps1 finalize` (results.json cells) | — | — |
| `mr-title` | `devtools.py render` | — | — |
| `mr-body` | `devtools.py render` | `work/agents/*/*.md` | `md ^## Summary` |
| `commit` | `crafty.ps1 wt commit` | — | — |
| `merge-commit` | `crafty.ps1 wt commit` | — | — |
| `task-name` | `crafty.ps1 tracker` | — | — |
| `task-description` | `crafty.ps1 tracker` | — | — |
| `comment-solution` | `devtools.py comment --spec`, `devtools.py finish` | `work/agents/*/*.md` | `md ^\*\*Solution:\*\*` |
| `comment-status` | `devtools.py comment --spec` | — | — |
| `comment-deploy` | `bossy.ps1 deploy` | — | — |
| `decisions` | `bossy.ps1 decide` | — | — |
| `decision-request` | `bossy.ps1 decide` | — | — |
| `kit-report` | `bossy.ps1 supervise`, `devtools.py render retro`; free: kit audit | — | — |
| `final-report` | `devtools.py render final-report` (role JSON) | — | — |
| `owner-message` | free: the coordinator (chat, never a file) | — | — |
| `spec` | free: the agent (renderer input: task, cases, MR spec) | `work/agents/*/*.json` | `any` |
| `resume` | `crafty.ps1 checkpoint` | `work/agents/*/resume*.md` | `any` |
| `kitty-todo` | `kitbag.py state todo` | `work/agents/kitty/*.md` | `todo ^# ` |
