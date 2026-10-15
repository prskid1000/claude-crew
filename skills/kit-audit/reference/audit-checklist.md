# Kit audit checklist (kit-audit reference)

Read at kit-audit step 4 (deep audit), before reading the first area; steps 5-6 use §3-§4. Every item is a question to answer
with evidence (`file:line`, a command and its output), never a guess. `kit-audit.py scan` lists candidates for §2-§4; you judge
each one by reading the code.

## 1. Flows to trace end to end
For each flow: start at its Router row, follow the skill steps, every script it runs and every file it writes or reads, to the
last step. At each hop ask: does the caller pass what the callee expects (names, types, list form, exit code)? Does the doc say
what the code does? What happens on failure, on an empty input, on a second run, on Linux/macOS?

| Flow | Entry | Hops to follow |
|---|---|---|
| dev-wave | Router R13 -> `orchestrate` steps 2-5 | `workflows/dev-wave.js` (build, review, fix, ci, ship, learn) -> `agents/dev-agent.md` -> `dev-kit` steps (`wt.ps1`, `check.ps1` -> `gate.ps1` -> `stack.ps1`, `lbcheck.py`, `devtools.py mr/merge`, `tracker.ps1`) -> `agents/mr-reviewer.md` -> `track.ps1` -> `cleanup.ps1` |
| bugfix / resume | R5, R6 -> E6, E9 | `bug-brief.ps1` (tracker task -> brief), `templates/RESUME_BRIEF.md`, `launch-record.ps1`, dev-wave `mode` |
| test-and-close | R11 -> `orchestrate` step 7 | `workflows/test-and-close.js` (load-run, test, audit, verify, close) -> `qa-tester` / `qa-verifier` -> `qa-kit` (`qa-seat.ps1`, `browser.mjs`, `api.ps1`, `qa-kit/scripts/android/ui.ps1`, `annotate.ps1`) -> `finalize.ps1` (+ `qa-kit/scripts/lib/report.ps1`) -> `add-retest.ps1`, `autoclose.ps1` |
| kit-retro | R4 / E14 | `retro-nudge.ps1` -> `workflows/kit-retro.js` -> `learn.ps1 -Lesson/-Fixed/-Trim` -> `last-retro` stamp |
| supervise / track / autoclose | E1-E5 | `supervise.ps1 -AutoFix -Brief` -> `board.ps1`, `track.ps1 run`, `deployed.ps1`, `wave-report.ps1`, `phone.ps1`, `cleanup.ps1`; `mark-in-test.ps1`; `autoclose.ps1` -> `finalize.ps1` |
| local-env | R12b | `localenv.ps1` -> `localenvd.ps1` (train, switch-over, leases) -> `localenv-lib.ps1` -> `migrations.py`; tests in `local-env/tests/` |
| android-swarm | R12 | `app-build.ps1`, `swarm-avd.ps1`, `swarm-up.ps1`/`swarm-down.ps1`, `phone.ps1 acquire/release` (gate), `metro-start.ps1`, `app-mode.ps1`, `_config.ps1` |
| qa-kit finalize | qa-kit lead steps | `run.json` -> `finalize.ps1 -Report gdocs/markdown` -> tracker comment + bug tasks -> `autoclose.ps1` |
| dev-kit ship / merge / deploy | dev-kit steps 7-8 | `devtools.py mr`, `merge` (automerge intents in `tracking.local.json`), `deploy-merge.ps1`, `pipe-wait.ps1`, `deployed.ps1` (CI job / awsStack / ssh / manual / laneApk) |
| install / hooks | `docs/install.md` | `kit-setup.ps1`, `settings.json` hooks (`guard.ps1`, `guard-sendmessage.ps1`, `kit-health.ps1`, `retro-nudge.ps1`, `cleanup.ps1 -IfDue`), `.githooks/pre-push.ps1`, `port-kit.py` |
| kit tooling | R2, R3 | `kit-lint.py` + `kitgraph_lib.py` + `kit-flow.py`, `kit-cost.ps1`/`.mjs`, `kitpaths.*` (one map, four readers), `kitconfig.ps1` |

## 2. Script pitfalls (each one has bitten this kit or kits like it)
PowerShell (pwsh 7):
- Variable names are case-insensitive: `$L` (a list) and `$l` (a loop var) are ONE variable; a loop var that matches a param or an
  earlier value (`$P` JSON, `foreach ($p ...)`) silently replaces it for every later line.
- `pwsh -File x.ps1 -List a,b` passes ONE string `"a,b"` (and `'a','b'` arrives with the quotes): `[string[]]` params need
  `Split-KitList`; refs need `.Trim('''"')`.
- `.Substring(i, n)` throws when the string is shorter; use `[math]::Min` or `-replace`/regex.
- `$null.Prop` is `$null` (no error), but `$null.Method()` throws; `@($x).Count` vs `$x.Count` on a single object or `$null`.
- `$ErrorActionPreference = 'SilentlyContinue'` hides failures: a `throw` inside a function does not stop the script; check `$?`
  and `$LASTEXITCODE` after native commands (`git`, `glab`, `gh`), which never throw.
- `exit` in a dot-sourced library ends the caller; `return` at script level in a dot-sourced file returns from the caller's scope.
- `[IO.File]::*` and .NET APIs resolve relative paths against the PROCESS directory, not `Get-Location`: always pass absolute paths.
- `ConvertFrom-Json` turns one-element arrays into scalars and dates into `[datetime]`; `-AsHashtable` keys are case-insensitive.
- `Join-Path a b c` needs pwsh 7; `"$dir\file"` breaks off Windows; `& "$K\x.ps1"` parses as module\command.
- `Get-Content -Raw` on an empty file is `$null`; `Set-Content` adds a BOM in Windows PowerShell 5.1 (the kit needs pwsh 7).
- Automatic variables (`$input`, `$args`, `$matches`, `$host`, `$error`, `$pid`, `$home`) as param or variable names.
- Hooks: a SessionStart hook prints one JSON line or nothing, exits 0, stays < 2 s; anything slow goes in an `async` hook.
Python:
- `open()` without `encoding='utf-8'` reads cp1252 on Windows; `print` of non-ASCII needs `-X utf8`.
- `subprocess` on Windows: `.cmd` shims need `shutil.which()`; no `shell=True` with user text; set `timeout=`.
- Bare `except:` / `except Exception: pass` hiding the real error; `sys.exit()` inside library code.
- Paths from `__file__` with a fixed `parents[n]`: count the levels, and check it still works from a worktree or a second clone.
JS (workflows):
- No `Date.now()` / `new Date()` (resume breaks); LF only; every `agentType` exists in `agents/`; prompts name absolute kit
  paths only when `kitDir` was passed; a returned schema field the coordinator reads exists in the schema.
Everywhere:
- Races: two agents writing one file (use `Invoke-KitLocked` / `locked()`), read-modify-write of JSON state, a lock never released.
- Exit codes: a script that fails but exits 0 (callers think it worked) or exits 1 on a warning (hooks, `--check` modes).
- Regex gaps: unanchored matches, case, `\` vs `/`, ids that prefix other ids (`F1` vs `F10`), CRLF line ends.
- One-machine assumptions: drive letters, `D:`-style paths, a user name, `python` vs `python3`, `%TEMP%`, Windows-only APIs
  without a guard (`sysinfo.ps1` is the place for OS differences).
- Dead code: functions or params nothing calls; config keys nothing reads; files nothing reaches (kit-lint REACH-*).

## 3. Generic check (step 5)
- `kit-lint.py --org-terms <live kit>/skills/dev-kit/kit.local.json`: 0 ORG-TERM. Also read for business logic that names a
  product, tenant, status name, list id, host or person without a config key (a default that only fits one org).
- Absolute paths (`C:\...`, `/home/<user>`), hosts, tracker ids, branch names other than `main`/`master`/`develop`/`release/*`.
- Every such value -> a key in `kit.example.json` + `configuration.md` with today's behaviour as the default (extending.md §6);
  the org's value goes in the report's "kit.local.json additions" list for the lead.

## 4. Consistency (step 6)
- Files index of every skill vs the files on disk (kit-lint FILES-*); each Files row's step exists in that skill's steps.
- `configuration.md` vs the keys scripts read, both ways (`kit-audit.py scan` CONFIG-UNDOC / CONFIG-UNUSED), and vs
  `kit.example.json` (CONFIG-EXAMPLE); defaults in the doc equal the defaults in the code.
- Router rows vs skills, agents and workflows that exist; each workflow's `whenToUse` equals its row (kit-lint); the agent-types
  line names every `agents/*.md`; every Events row's script exists and takes the flags it shows (DOC-FLAG).
- Agent `tools` vs what its skill runs (AGENT-TOOLS); workflows' `agentType`s vs `agents/` (WF-AGENT).
- Ports: `port-kit.py --check` (content, not just presence); `<workspace>/AGENTS.md` equals the kit copy.
- kit-flow graph: no unreached or mention-only files (kit-lint REACH-*); `docs/runtime.md` lists every `kitpaths.json` name.
- `LESSONS.md` <= 40 lines, one line each, `(n×)` counts; a lesson the kit now enforces -> `learn.ps1 -Fixed` (lands in
  `HISTORY.md`); a `HISTORY.md` "(fixed in kit)" problem seen again in signals = a regression finding.
