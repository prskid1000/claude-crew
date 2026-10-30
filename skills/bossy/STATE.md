# Kit state (`.state/` durable, `.runtime/` disposable)
Read by kitty when a script's state changes, by revy (kind kit), by agents that need a task's links ("Indexes").
Paths: `kit.example.json` `_paths` (`Get-KitPath` / `kit_path`); schemas: the Inventory below (`kitbag.py state lint` parses
it; supervise runs it each beat on recent files: a BAD file = WATCH).

## Rules
- **One file per key** (task, session, decision, run, publish key); a shared map only when one writer owns it.
- **Writes:** `Write-KitState` (lib.ps1) / `state_write` (kitbag.py): temp file + move, `schemaVersion`, `updated`,
  `holder` {agent, session, pid, pidStart, holderPid, holderStart}; read-modify-write inside `Invoke-KitLocked` / `locked()`
  on that file. Log lines only through kitlog (`Write-KitLog`, `kitlog()`).
- **Reads:** `Read-KitState` / `state_read`: `$null` / `None` when missing or broken, never a throw; unknown fields kept.
- **Times:** ISO 8601 with offset (`ToString('o')`, `isoformat()`); readers accept the old offset-less form.
- **Ids:** stable, file-safe: session `<agent>-<8 hex>`, decision `d-<yyyyMMddHHmmss>-<agent>-<4>`, task = tracker id, run =
  workflow run name.
- **Format:** JSON for scripts; markdown only for people (`resume.md`, resume briefs, reports): templates.md kind `kit-report`.
- **Change a schema:** bump `v<n>` in its row and the writer; readers accept `n-1`. A new file: a `_paths` name + a row.
  Deleting state still in use: the owner decides (`bossy.ps1 decide ask`).
- **Lifecycle:** `.runtime` ages out by `_paths.keep` (`bossy.ps1 cleanup`); in `.state` cleanup only trims the logs the Inventory
  says (`Invoke-KitLogTrim`) and deletes `tracking.json.migrated`.

## Indexes (read these, not the tracker's comments)
- `.state/tasks/<id>.json`: `track` (MRs in merge order, mergeAfter, onMerged, done: `bossy.ps1 track`), `docs.<kind>` (url,
  key, type: `devtools.py doc --key <id>:<kind>`), `comments.<kind>` (the comment `tracker comment -Kind` edits), `envRuns[]`
  (env, run, code, pass, fail, notTested, doc: `pokey.ps1 finalize`).
- `<qa run>/index.json`: `items.<code>` -> tasks, doc, pubKey, pass, fail (`pokey.ps1 finalize`); a build run:
  `work/waves/<run>.json` (`bossy.ps1 report`).

## Inventory
Schema: `<form>[=<glob>] v<n>: <required keys>`; form json (one object), dir (one JSON per key, default `*.json`), jsonl (one
object a line; the last is checked), text; v0 = written before this file (no schemaVersion yet).

| Name | Owner | Schema | Lifecycle | Change (2026-10-30) |
|---|---|---|---|---|
| `tasks` | `lib.ps1` `Update-KitTracking` / `Update-KitTaskIndex`, `devtools.py publish`, `pokey.ps1 finalize` | `dir v1: task` | keep | new: replaces `tracking` |
| `tracking` | none (legacy) | `json v0: tasks` | read until the first tracking write moves it into `tasks` and deletes it | cleanup deletes `.migrated` |
| `automerge` | `devtools.py merge`, `bossy.ps1 track run` | `json v1: refs` | an entry until its MR merges | new (was in `tracking`) |
| `mr-ignore` | `bossy.ps1 track ignore` | `json v1: mrs` | keep | new: MRs the untracked-MR watch skips |
| `published` | `devtools.py publish`, `crafty.ps1 tracker create -Key` | `dir v1: key` | keep | schemaVersion |
| `param-state` | `lib.ps1` params | `json v0: byKey` | keep (raw obs 14 d, hourly sketches 90 d) | trigger queue, boot / wake |
| `params-changes` | `kitlog` (`Write-KitParamChange`) | `jsonl v0: at key ctx` | keep (append-only) | new |
| `logs-summary` | `kitlog` (`Invoke-KitLogTrim`) | `jsonl v0: at stream period n` | keep | new: trimmed months |
| `signals` | `bossy.ps1 learn` | `jsonl v0: at skill kind text` | `logs.keepDays`, then `logs-summary` (retired: kept) | cleanup trims |
| `decisions-log` | `kitlog` | `jsonl v0: at` | `logs.keepDays`, then `logs-summary` | cleanup trims |
| `deploy-log` | `kitlog` | `jsonl v0: at` | `logs.keepDays`, then `logs-summary` | cleanup trims |
| `leases` | `kitlog` | `jsonl v0: at event kind` | keep, capped | none |
| `outbox` | tracker writes | `jsonl v0: at` | until replayed | none |
| `audit` | `kitlog` streams | `text v0` | 30 d | none |
| `last-retro` | `bossy.ps1 tidy done` | `text v0` | keep | offset |
| `last-kitty-audit` | `kitbag.py audit stamp` | `text v0` | keep | none |
| `pauses` | `bossy.ps1 pause / resume` | `dir v1: at run state` | keep | schemaVersion |
| `programs` | `bossy.ps1 program` | `dir v1` | keep | schemaVersion (`_updated` gone) |
| `browser-ports` | `browser.mjs` | `json v0` | keep | none |
| `owner-apps` | `bossy.ps1 supervise` | `json v0` | keep | none |
| `runtimes` | goody `runtimes` | `dir v0: leases` | keep | none |
| `board` | `bossy.ps1 board` | `dir v1: agent session run beat status` | 14 d | schemaVersion; file-safe session |
| `launches` | `bossy.ps1 launch`, workflows (`args-*`) | `dir=self-*.json v1: script run args` | 3 d | schemaVersion |
| `agents` | `crafty.ps1 checkpoint` | `dir=*/resume.json v1: agent run steps` | 7 d | schemaVersion, ISO |
| `decisions` | `bossy.ps1 decide` | `dir v2: id status question` | 14 d | `options` {key label description recommended}, `blocking` |
| `qa-runs` | `testy.js`, `pokey.ps1 finalize` | `dir=*/index.json v1: run items` | 14 d | new `index.json` |
| `waves` | `bossy.ps1 report` | `dir v0: run` | 14 d | none |
| `supervise-state` | `bossy.ps1 supervise` | `json v0` | 30 d | ISO |
| `live-steps` | `bossy.ps1 supervise` | `json v0: at` | 30 d | none |
