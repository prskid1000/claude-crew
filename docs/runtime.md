# Runtime and local state

The kit keeps two kinds of local state, both git-ignored:

- **Runtime** (`<kit>/.claude-runtime/`, or the folder in the `CLAUDE_RUNTIME` env var): **disposable**. Three folders, by
  lifetime: `work/` (runs in flight), `cache/` (rebuilt on demand), `logs/` (append-only). Deleting the whole folder loses
  nothing durable; the scripts recreate what they need. Only deleting `work/` while runs are active hurts (it holds live QA runs,
  the agent board and phone leases), so the guard hook blocks that; `cache/` and `logs/` may be cleared any time.
- **Durable** (`*.local.*` files at the kit root): knowledge and task state that must survive a runtime wipe.

Every path has a name in [`skills/dev-kit/scripts/kitpaths.json`](../skills/dev-kit/scripts/kitpaths.json). Scripts never build
these paths by hand: PowerShell uses `Get-KitPath <name>` (`kitpaths.ps1`, loaded by `kitconfig.ps1`), Python `kit_path(name)`
(`kitpaths.py`), Node `kitPath(name)` (`kitpaths.mjs`), and each workflow an `rp(name)` helper over a `const KP` copy of the names.
`kit-lint.py` fails on a hand-built path (`RUNTIME-RAW`), on a workflow map that drifts from `kitpaths.json` (`RUNTIME-MAP`) and on
durable state left inside the runtime (`RUNTIME-DURABLE`).

## What is regenerable

| Name | Path | Written by | Read by | If it is deleted |
|---|---|---|---|---|
| `waves` | `work/waves/<run>.json` | `wave-report.ps1` (also called by `supervise.ps1`, `track.ps1`) | `track.ps1` (merge/promote holds), `supervise.ps1` | `wave-report.ps1 -Run <id>` rebuilds it from the session journal; supervise does so every round for running waves |
| `qa-runs` | `work/qa-runs/<date>-<name>/` | the lead (`run.json`, guides), `/test-and-close` agents (results, evidence), `finalize.ps1`, `autoclose.ps1`, `add-retest.ps1` | `supervise.ps1` (capacity, bug parents, QA coverage), `bug-brief.ps1`, `status.ps1`, `cleanup.ps1`, `/kit-retro` | in flight: the run is lost (guard blocks this while active); finished: reports and bug tasks are already published on the tracker / Drive |
| `board` | `work/board/<session>.json` | `board.ps1` (every agent: join, beat, leave) | `supervise.ps1` (also reclaims leases of agents that left), `cleanup.ps1`, guard | agents re-join on their next `beat` |
| `briefs` | `work/briefs/<task>.md` | `bug-brief.ps1` | `/dev-wave` (its `brief` arg) | run `bug-brief.ps1` again |
| `phones` | `work/phones/<lane>.json` | `phone.ps1` (leases), `swarm-avd.ps1` (voids a lease on reset) | `supervise.ps1`, `swarm-avd.ps1` | phones count as free; agents acquire again |
| `qa-seats` | `work/qa-seats/` | `qa-seat.ps1` (memory seats, item claims) | `supervise.ps1`, `cleanup.ps1` | testers take seats again |
| `launches` | `work/launches/<runId>.json` | `launch-record.ps1` (the coordinator, after each workflow launch; `-Done` at E5) | `kit-health.ps1` (SessionStart: stopped runs to resume), `cleanup.ps1` (> 3 days) | the coordinator rebuilds the launch by hand (script, args, run folder) |
| `localenv` | `work/localenv/<env>.json`, `run/<env>/<svc>/<release-train>/` (staged artifacts), `run/*.cmd` (launchers), `.no-hooks` | `localenv.ps1`, `localenvd.ps1` (loop, train worker; state: release, services, leases, holds, requests, train, sandboxes, snapshots) | `localenv.ps1`, `localenvd.ps1` | the env forgets layers, leases and sandboxes; running services show "up (adopted)" and are rebuilt into copies by the next train; agents deploy again |
| `audits` | `work/audits/<project>/` | tech-audit agents (when the profile names no findings folder) | the lead, `/kit-retro` | re-run the audit (keep findings you need in the project's own folder) |
| `docs` | `work/docs/` | `devtools.py doc` (markdown reports) | people (the file is attached to the task) | publish again |
| `evidence` | `work/evidence/` | `api.ps1 -Save` without `-OutDir` | testers | re-run the call (run evidence lives in the run folder) |
| `shots` | `work/shots/<serial>/` | `android/ui.ps1 shot` without a folder | testers | take the screenshot again |
| `chrome-profiles` | `cache/chrome-profiles/` | `web/browser.mjs` | `cleanup.ps1`, `swarm-down.ps1` | the next `session()` creates a profile and logs in |
| `sessions` | `cache/sessions/` | `web/browser.mjs` (shared logins) | `web/browser.mjs` | logs in again |
| `tokens` | `cache/tokens/` | `api.ps1` | `api.ps1` | logs in again |
| `tsbuild` | `cache/tsbuild/` | `check.ps1` (incremental `tsc`, `ts5103.<hash>.flag` markers) | `check.ps1` | the next type-check is a full one (and re-learns TS5103) |
| `android-swarm` | `cache/android-swarm/` (or `swarm.config.json` `outDir`) | `app-build.ps1`, `swarm-up.ps1`, `metro-start.ps1`, `phone.ps1` (`_config.ps1`) | android-swarm scripts | `app-build.ps1` (slow: keep it, or migrate it with `kit-setup.ps1 -Migrate <old> -Apk`) |
| `android-tmp` | `cache/android-tmp/` | `android/ui.ps1` (UI dumps) | `android/ui.ps1` | recreated on the next dump |
| `stopped` | `cache/stopped/<run>` | `supervise.ps1 -MarkStopped` | `supervise.ps1`, `wave-report.ps1` | a stopped run is flagged as idle again: mark it again |
| `kit-flow` | `cache/kit-flow.html` | `kit-flow.py` (kit-lint, SessionStart `kit-health.ps1 -Flow`) | people (router R3) | regenerated by the next lint or session |
| `dashboard` | `cache/dashboard.html` | `status.ps1` | people | `status.ps1` |
| `supervise-state` | `cache/supervise-state.json` | `supervise.ps1` (idle-since times) | `supervise.ps1` | idle timers restart |
| `last-cleanup` | `cache/last-cleanup.txt` | `cleanup.ps1` | `cleanup.ps1 -IfDue` | cleanup runs at the next session start |
| `guard-log` | `logs/guard.log` | `guard.ps1` | `supervise.ps1` (WATCH), `retro-nudge.ps1`, `status.ps1`, `/kit-retro` | the next retro sees fewer guard blocks |
| `cleanup-log` | `logs/cleanup.log` | `cleanup.ps1` | `status.ps1`, the workflows' last step | history only |
| `tracker-log` | `logs/tracker-none.log` | `tracker.ps1` (`tracker.type` none) | people | history only |
| `localenv-logs` | `logs/localenv/<env>-<svc>.log` (+ `.prev`), `<env>-<svc>-build.log`, `<env>-loop.log`, `<env>-train.log`, `<env>-db.log`, `<env>-smoke.log`, `<env>-events.jsonl` | `localenv.ps1`, `localenvd.ps1` | `localenv.ps1 logs` / `events`, people, `/kit-retro` | history only |
| `localenv-history` | `cache/localenv-history.json` | `localenv.ps1` (RAM footprint per env/service) | `localenv.ps1` (start admission) | per-stack defaults until services start again |
| `retros` | `logs/retros/retro-<time>.md` | `/kit-retro` | people | history only (the changes are in the kit's git history) |
| `kit-audits` | `logs/kit-audits/audit-<date>.md` (+ `cache/kit-audit-lint.json`) | `kit-auditor` (kit-audit step 9; `kit-audit.py scan`) | the lead, the next audit | history only (fixes are on the audit branches) |

`cleanup.ps1` prunes old entries (sessions > 8 h, tokens > 3 d, stop markers > 7 d, loose evidence > 14 d, wave reports > 14 d,
briefs and docs > 30 d, QA run bulk > 30 d, retro reports > 90 d, idle browser profiles) and rotates `logs/*.log`.
Outside the runtime, on purpose: the memory gate's ledger (`<OS temp>/claude-build-gate/`, shared by every workspace on the machine).

## Durable local state (kit root, git-ignored)

| Name | Path | Written by | Read by | Recovery |
|---|---|---|---|---|
| `signals` | `learning.local.jsonl` | `learn.ps1` (agents, every workflow's Learn step) | `retro-nudge.ps1`, `status.ps1`, `learn.ps1 -Show/-Stats`, `/kit-retro` | none needed: never inside the runtime (`cleanup.ps1` keeps the newest 5000 lines) |
| `last-retro` | `learning.local.stamp` | `/kit-retro` (last step) | `retro-nudge.ps1`, `status.ps1`, `learn.ps1 -Stats` | without it every signal counts as new |
| `last-kit-audit` | `kit-audit.local.stamp` | `kit-audit.py stamp` (kit-auditor, last step) | `retro-nudge.ps1` (weekly nudge), `kit-audit.py due` | the next session says "kit audit due" |
| `tracking` | `tracking.local.json`: `tasks` (task -> MRs, `onMerged`, `done`, QA/live fields) and `automerge` (merge-when-green intents) | `track.ps1` (`add`, `run`, `-Rebuild`), `devtools.py merge` (`automerge`), `supervise.ps1` (live / QA-covered fields) | `track.ps1`, `supervise.ps1`, `bug-brief.ps1` | `track.ps1 -Rebuild`: every open (or recently merged) MR in `trackerRepos` with `<tracker tag><id>` in its branch or title becomes a `-Discover` task again |
| `tracker-none` | `tracker-none.local/` | `tracker.ps1` with `tracker.type` none | `tracker.ps1` | it is the local tracker itself: back it up if you rely on it |
| `localenv-env` | `localenv.local/<env>.env` | people (dotenv: DB passwords, cloud keys of a local env) | `localenv.ps1` (service, build and task environment) | re-enter the values: they are secrets kept nowhere else |

Writes to `tracking.local.json` take a `<file>.lock` (`Invoke-KitLocked` / `locked()`) and replace the file atomically. A PowerShell
writer that cannot get the lock in ~130 s, or finds the file is not valid JSON, writes nothing (the bad file is copied to
`tracking.local.json.bad-<time>`; fix it, or remove it and run `track.ps1 -Rebuild`).

## Moving from the old layout

Before the repo root became the kit, the runtime lived next to `.claude` (`<workspace>/.claude-runtime`) and held the learning
signals, tracking and `automerge.json`. Carry them over once, with no agents running:

```powershell
pwsh -File <workspace>/.claude/skills/orchestrate/scripts/kit-setup.ps1 -Migrate <workspace>/.claude-runtime [-Work] [-Apk]
```

It merges the signals and the last-retro time, folds every `tracking/<task>.json` and `automerge.json` into `tracking.local.json`
(tasks already there win), copies `tracker-none/`, and with `-Work` / `-Apk` also copies in-flight runs and the APK build output.
It never deletes the old folder: check the result, then delete it yourself. Until then the SessionStart kit line reminds you.
