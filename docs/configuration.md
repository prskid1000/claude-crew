# Configuration reference

Everything machine- or org-specific lives in git-ignored `*.local.json` files next to their `*.example.json`, or in
environment variables. The kit itself contains no paths, hosts or credentials: scripts find the workspace from their own
location (`<workspace>` = the folder that holds `.claude`).

| File (copy from) | Needed for | Holds secrets? |
|---|---|---|
| `.claude/skills/dev-kit/kit.local.json` (`kit.example.json`) | issue tracker + report output, tracker automation, self-hosted git, worktree cleanup, protected branches | no |
| `.claude/skills/qa-kit/targets.local.json` (`targets.example.json`) | QA: API calls, web login, app lane logins | **yes** — test passwords / API keys, only here |
| `.claude/skills/android-swarm/swarm.config.json` (`swarm.example.json`) | Android emulator lanes + the app under test | no |
| `.claude/settings.local.json` | your personal Claude Code permissions (standard Claude Code file) | maybe |

## `kit.local.json` (dev-kit)

All keys are optional. Read by `dev-kit/scripts/kitconfig.ps1` (PowerShell scripts), `devtools.py` and `guard.ps1`.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `gitHost` | `gitlab.com` | devtools.py, track.ps1, wave-report.ps1 | GitLab host. For self-hosted GitLab the scripts also set `GITLAB_HOST` for `glab` |
| `repos` | - | bug-brief.ps1 | Repos for generated bug-fix briefs: `[{ name, aliases[], checkout, target, linkFrom? }]` |
| `bugfixMandate` | - | bug-brief.ps1 | The task owner's own words asking for QA bugs to be fixed; passed to /dev-wave as `mandate` |
| `githubHost` | `github.com` | devtools.py | GitHub (Enterprise) host |
| `gitlabGroup` | none | track.ps1 | Group (or `group/subgroup`) for short MR refs `<repo>!<iid>`. Without it, refs must be `<group/repo>!<iid>` |
| `reposRoot` | `<workspace>` | track.ps1, kitconfig | Folder holding the main checkouts (`<reposRoot>/<repo>`). `track.ps1 -MergeAfter` schedules merges from there |
| `worktreeRoots` | `[$env:CLAUDE_WT_ROOT, "<reposRoot>-wt"]` | cleanup.ps1, status.ps1 | Where `wt.ps1 new` puts worktrees (its default is `<repo's parent>-wt`) |
| `trackerRepos` | `[]` | track.ps1 `-Discover` | Repos searched for MRs whose title/branch contains `<tracker.branchTag><task>` (e.g. `CU-<task>`) |
| `repoAliases` | `{}` | track.ps1 | Short names agents use in refs, e.g. `{ "api": "backend", "web": "frontend" }` |
| `protectedBranches` | `[]` | guard.ps1, cleanup.ps1 | Shared branches besides `main`, `master`, `develop`, `release/*`: never force-pushed, their worktrees never auto-removed |
| `driveParent` | none | devtools.py `doc`, finalize.ps1 (`gdocs` only) | Google Drive folder (or shared drive) id for tester guides / QA evidence |
| `tracker` | `{ "type": "clickup" }` | tracker.ps1 and everything that talks to the tracker | Issue tracker backend — see [Tracker](#tracker-trackertype) |
| `reports` | `{ "type": "gdocs" }` if `gws` is on PATH, else `{ "type": "markdown" }` | finalize.ps1, devtools.py `doc` | Where QA reports and tester guides go — see [Reports](#reports-reportstype) |
| `cleanup.maxBrowserProfiles` | `4` | cleanup.ps1 | With no QA seat or QA agent active, keep only this many most recently used headless-browser profiles (one in use is never removed) |

### Tracker (`tracker.type`)

Every script and agent talks to the tracker through one adapter, `dev-kit/scripts/tracker.ps1` (PowerShell 7; also
dot-sourceable), never a tracker CLI directly:

```powershell
$TR = '<workspace>/.claude/skills/dev-kit/scripts/tracker.ps1'
& $TR view <id>                    # JSON { id, name, status, url, parent, assignees[], subtasks[], list, description }
& $TR status <id> review           # logical status (or the backend's own name)
& $TR comment <id> <text | file.md>
& $TR comments <id>                # JSON [{ user, date, text }], oldest first
& $TR create -List <list> -Name "<name>" -Description <text | file.md> [-Parent <id>] [-Assignee <user>] [-Priority 1-4]   # JSON { id, url }
& $TR url <id>
& $TR describe <id> <text | file.md>   # replace the description
& $TR attach <id> <file> [-Text "<comment>"]
# any verb: -DryRun (or $env:KIT_TRACKER_DRYRUN=1) prints the CLI/REST call instead; -Type <backend> overrides the config
```
`devtools.py task|subtasks|newtask|status|comment|finish` call the same adapter.

| `tracker.type` | Needs | Model |
|---|---|---|
| `clickup` (default) | `clickup` CLI, logged in | native statuses, subtasks, attachments; `-List` = list id |
| `github` | `gh`, logged in; `tracker.repo` = `owner/name` | issues; status = label `status:<name>`, closed statuses close the issue (reopened when moved back); parent = `Part of #n` in the body plus a `- [ ] #child` line in the parent; reports are posted as comment text |
| `gitlab` | `glab`, logged in (host from `gitHost`); `tracker.repo` = `group/project` | same label/state model through the issues API |
| `jira` | env `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` | REST v3; status = the transition whose name or target status matches; `-List` = project key; `tracker.issueType` (default `Task`) / `tracker.subtaskType` (default `Subtask`); `-Assignee` = account id |
| `none` | nothing | no tracker: every call is logged to `<runtime>/tracker-none/tracker.log` and kept as JSON there (`create` returns `LOCAL-<n>`); nothing fails |

Other `tracker` keys:

| Key | Default | Meaning |
|---|---|---|
| `tracker.repo` | - | `owner/name` (GitHub) or `group/project` (GitLab) holding the issues |
| `tracker.list` | - | Default list / project for `create` (bug tasks when `run.json` has no `tracker.list`) |
| `tracker.branchTag` | `CU-` (clickup), `GH-` (github), `GL-` (gitlab), empty (jira, none) | Put before the task id in branch names and MR titles (`fix/<tag><id>-slug`); `track.ps1 -Discover` searches for it |
| `tracker.statuses` | see below | Map logical statuses to your board's names; a value may be a list (the first is set, all count as a match) |

Logical statuses and their defaults: `open` = `open`/`to do`, `inProgress` = `in progress`, `review` = `for review`/`in review`,
`promoted` = `promoted`, `inTest` = `in test`/`for test`, `closed` = `closed`/`complete`/`done`. Example:
```json
"tracker": { "type": "jira", "list": "PROJ", "statuses": { "review": ["In Review"], "promoted": "Merged", "inTest": "QA", "closed": ["Done"] } }
```

### Reports (`reports.type`)

| `reports.type` | QA report (finalize.ps1) | `devtools.py doc` (tester guides) |
|---|---|---|
| `gdocs` | evidence uploaded to a Drive folder (`driveParent`), a Google Doc report anyone with the link can view; the tracker comment links it. Needs `gws` logged in | HTML uploaded as a Google Doc; prints its URL |
| `markdown` | `<runDir>/<code>/report.md` (+ `report.html`) next to `shots\` and `evidence\`, links relative; the tracker comment carries the report (GitHub/GitLab: its text, ClickUp/Jira: the file attached, `none`: logged) and the bug task gets it too | the file (`.md` or `.html`) is kept under `<runtime>/docs` and its path printed — attach it with `tracker.ps1 attach` |

`finalize.ps1 -Report gdocs|markdown` overrides the setting for one run.

## `targets.local.json` (qa-kit)

```json
{
  "default": "my-staging",
  "targets": {
    "my-staging": {
      "web": "https://staging.example.com",          // browser.mjs base URL
      "api": "https://staging-api.example.com",      // api.ps1 base URL
      "apiPattern": "/api/",                          // which browser calls count as API calls (failure evidence)
      "defaultTenant": "",                            // multi-tenant apps: default {tenant}
      "tenantHeader": "",                             // optional header that carries the tenant on every API call
      "auth": { "type": "login|token|basic|none", "path": "/api/authenticate", "contentType": "json|form",
                "body": { "username": "{user}", "password": "{pass}" }, "tokenField": "id_token",
                "header": "Authorization: Bearer {token}" },
      "webLogin": { "path": "/login", "fields": { "#username": "{user}", "#password": "{pass}" },
                    "rememberMeLabel": "Remember me", "submit": "button[type=submit]", "tokenKeys": ["access_token"] },
      "users": { "admin": ["qa-admin", "<password>"] }   // key -> [login, password]; api.ps1 -As <key>
    }
  }
}
```
Top-level `keepFreeGB` (default `8`): `qa-seat.ps1` lets a new tester/verifier start only while free RAM minus its need
(web ~1.5 GB, API ~0.4 GB) stays at or above it; the supervisor's capacity flag uses the same value.

Placeholders: `{user}`, `{pass}`, `{tenant}`, `{token}`. Tokens are cached in `<runtime>/tokens`, web logins in `<runtime>/sessions`.
Evidence files never contain passwords or auth headers (`[redacted]`).

## `swarm.config.json` (android-swarm)

| Key | Default | Meaning |
|---|---|---|
| `avdDir` | `$env:ANDROID_AVD_HOME`, else `~/.android/avd` (`%USERPROFILE%\.android\avd` on Windows) | Where the lane AVDs live |
| `keepFreeGB` | `12` | A phone boots only if free RAM − 4.5 GB stays above this |
| `headless` | `false` | Boot without windows (also per lane) |
| `lanes[]` | — | `{ name, port, user, notes, headless }`: AVD name, console port (serial `emulator-<port>`), the lane's test login (a user key in targets.local.json), notes printed by `phone.ps1 acquire` |
| `app.kind` | `react-native` | `react-native` or `native` |
| `app.package` | — | Android package id, e.g. `com.example.app` |
| `app.appDir` | — | App checkout (folder with `android/gradlew[.bat]` or `gradlew[.bat]`) |
| `app.buildTask` / `app.buildArgs` | `assembleRelease` (RN) / `assembleDebug` (native) | Gradle task + args for `app-build.ps1` |
| `app.apkGlob` | from the variant | APK location under the Android project |
| `app.devClientScheme`, `app.metroPort` | —, `8081` | React Native Metro mode (Expo dev client) |
| `app.permissions` | `[]` | Runtime permissions granted after install |

`avd-template.ini` defines the (identical) lane hardware; `{{NAME}}` and `{{SDK}}` are filled by `swarm-avd.ps1 create`.

## Environment variables

| Variable | Effect |
|---|---|
| `CLAUDE_RUNTIME` | Runtime folder (default `<workspace>/.claude-runtime`) |
| `CLAUDE_WT_ROOT` | Worktree root for `wt.ps1 new` (default `<repo's parent>-wt`) |
| `CLAUDE_AGENT` | Owner name for fair turns in the memory gate (default: worktree prefix) |
| `CLAUDE_GATE_KEEP_FREE_GB` | RAM the gate always keeps free (default 15% of RAM, min 6 GB) |
| `CHROME_PATH` | Chrome/Edge/Chromium binary for `browser.mjs` (default: the usual install folders per OS, then `google-chrome`, `chromium`, `microsoft-edge` ... on `PATH`) |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | Android SDK (default `%LOCALAPPDATA%\Android\Sdk` on Windows, `~/Android/Sdk` on Linux, `~/Library/Android/sdk` on macOS) |
| `ANDROID_AVD_HOME` | Where the lane AVDs live when `swarm.config.json` has no `avdDir` (default `~/.android/avd`) |
| `ANDROID_HOME`, `ANDROID_AVD_HOME` | Android SDK and AVD folders |
| `ANDROID_SERIAL` | The phone an app-lane agent drives (set on every command) |
| `GITLAB_HOST` | `glab` host (the scripts set it from `gitHost` when it isn't `gitlab.com`) |
| `KIT_TRACKER_TYPE` | Overrides `tracker.type` (e.g. `none` for a dry session) |
| `KIT_TRACKER_DRYRUN` | `1`: tracker.ps1 prints its calls instead of making them |
| `KIT_REPORT_TYPE` | Overrides `reports.type` |
| `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` | Jira tracker backend (`https://<site>.atlassian.net`, account e-mail, API token) |

## Per-repo stack override: `.claude-stack.json`

`stack.ps1` detects Maven, Gradle/Android, .NET (SDK and MSBuild), Angular, Node/React/Next/React Native, Python, Go, Rust,
CMake and Make. If it guesses wrong, drop a `.claude-stack.json` next to the build file:

```json
{ "stack": "custom", "commands": { "compile": "make", "test": "make test T={tests}" }, "deps": ["node_modules"] }
```
Keys you set replace the detected ones. Placeholders: `{tests}`, `{files}`, `{sln}`.

## Workflow arguments

`/dev-wave` (`.claude/workflows/dev-wave.js`):
```js
{ brief: '<abs path>/wave-brief.md', mode: 'feature' | 'bugfix' | 'resume', review: true | false | 'auto', learn: true | false | 'auto',
  agents: [ { id: 'X1', items: 'A3, A4', area: 'project form', note: '', complex: false, model: '', effort: 'medium' } ],   // complex/model/effort optional
  complex: ['X1'], models: { build: 'sonnet', review: 'sonnet' },   // optional (see Models by stage)
  kitDir: '<workspace>/.claude', runtimeDir: '<workspace>/.claude-runtime' }   // kitDir/runtimeDir optional, recommended
```

`/test-and-close` (`.claude/workflows/test-and-close.js`): preferably the short form
`{ runDir, kitDir?, only?: ['F1'], lanes?, instance?: 'w2' }` - a tiny (haiku) agent reads `<runDir>/run.json`, `only` keeps those item
codes, `instance` names an extra worker run (item claims keep runs apart). Or the full `run.json` object plus `runDir` (and optional
`kitDir`). Full shape in the header comment of the workflow file; `finalize.ps1` reads the same `run.json` from the run folder.
Items may carry `model: 'sonnet'|'opus'|'haiku'` and `effort: 'low'|'medium'|'high'` (the test step) and `verifyModel`; without them,
narrow web/API retests use sonnet and first-time guides the default (strongest) model. run.json (or args) `models` overrides a stage.

`/kit-retro`: `{ applyScripts: false, kitDir, runtimeDir, models: { analyse, apply } }` — all optional.

Optional stages:

| Arg | Values (default first) | Effect |
|---|---|---|
| dev-wave `review` | `true` · `false` · `'auto'` | `'auto'` skips the MR review (and so the fix round) for an agent whose MRs change < 40 lines in total and touch no migration / SQL / changelog or security-sensitive path (auth, permission, role, token, secret, session, ...); the build agent reports `changedLines` + `changedFiles`, and a missing report means the review runs. The CI wait and ship steps still run. |
| dev-wave / test-and-close `learn` | `true` · `false` · `'auto'` | `'auto'` runs the learn step only when the run had errors, deferrals, review findings, fix rounds (dev) or FAIL / NOT_TESTED / retries / note-audit or verify changes / a failed close (QA); otherwise (and with `false`) a haiku step just runs `cleanup.ps1`. |
| test-and-close `verify` (args or run.json) | `true` · `false` | `false` skips the independent re-test of FAILs: they are published as FAIL (`re-test: not re-tested (verify: false)`) and get their bug task straight away. The note audit still runs. |

### Models by stage

Defaults (a stage set to `''` gets no model option = the session's model, normally the strongest):

| Workflow | Stage (label) | Default | Override |
|---|---|---|---|
| dev-wave | build, fix | `sonnet`; **strongest** when the agent is marked complex (`agents[].complex: true` or `args.complex: ['X1']`, from the brief's Complex column) | `agents[].model`/`effort`; `models.build` / `models.complex` |
| dev-wave | review | `sonnet` | `models.review` |
| dev-wave | ci (pipeline wait), ship, learn | `haiku` | `models.ci` / `models.ship` / `models.learn` |
| test-and-close | test | strongest; narrow web/API retests `sonnet` | item `model`/`effort` |
| test-and-close | verify, audit | `sonnet` | item `verifyModel`; `models.verify` / `models.audit` |
| test-and-close | load-run, close, hold, release, add-followups, learn | `haiku` (load-run retries on sonnet) | `models.close` / `models.hold` / `models.learn` |
| kit-retro | analyse, apply | session model | `models.analyse` / `models.apply` |

`bug-brief.ps1` marks a bug agent `complex: true` when the task has more than 2 failed checks or any check that isn't cosmetic.
Measure the effect with `kit-cost.ps1 -Steps` (label, agent type, model and prompt size of every step).

Workflow scripts can't read the filesystem, so they don't know where the kit is: without `kitDir` they hand agents paths
relative to the workspace root (`.claude\skills\...`) and tell them so. Passing the absolute `kitDir` is more robust.

## Coordinator script output

Scripts the coordinator runs every round print a compact form by default; add `-Detail` for the long form (`-Json` where offered is unchanged):

| Script | Default | `-Detail` / other |
|---|---|---|
| `orchestrate/scripts/supervise.ps1` | digest + flags | `-Brief`: flags only, one line each (auto-fixed INFO counted), or `ok: N running, mem X%` |
| `orchestrate/scripts/wave-report.ps1 -Run <id>` | totals line + only agents/packages/findings that need the lead | every agent and package, done lists, deferral reasons, live checks, full findings + fixes |
| `orchestrate/scripts/track.ps1 show` / `run` | open tasks / actions only (HOLD lines counted) | finished tasks / every HOLD line (supervise uses `run -Detail`) |
| `qa-kit/scripts/deployed.ps1 -Mrs ...` | one summary line + the MRs that are NOT live | one line per MR per target |
| `orchestrate/scripts/kit-cost.ps1` | token table per agent type | `-Baseline <json>`, `-Steps`, `-Live` |

## Operating systems

The scripts run with PowerShell 7 (`pwsh`) on Windows, Linux and macOS. Everything OS-specific goes through
`skills/dev-kit/scripts/sysinfo.ps1`:

| Need | Windows | Linux | macOS |
|---|---|---|---|
| Total / available RAM (gate, seats, phones, supervisor) | CIM (`Win32_ComputerSystem`, `PerfOS_Memory`) | `/proc/meminfo` (`MemAvailable`) | `sysctl hw.memsize` + `vm_stat` (free + inactive) |
| Processes with command lines (gate trees, cleanup, emulators) | CIM `Win32_Process` | `ps -A -o pid,ppid,rss,etime,args` | same `ps` |
| Linked `node_modules` / `.venv` in worktrees | directory junction (no admin) | symlink (+ `.git/info/exclude`) | symlink (+ `.git/info/exclude`) |
| Build command shell (gate) | `cmd /c` | `/bin/sh -c` | `/bin/sh -c` |
| Repo wrappers | `.\gradlew.bat`, `.\mvnw.cmd` | `./gradlew`, `./mvnw` | `./gradlew`, `./mvnw` |
| Temp folder (gate ledger) | `%TEMP%` | `$TMPDIR` or `/tmp` | `$TMPDIR` |
| Background programs (emulators, Metro) | hidden window | `setsid nohup` | `nohup` |

Windows-only: `annotate.ps1` (System.Drawing; use `browser.mjs` `mark()` elsewhere), `swarm-arrange.ps1` (Win32 window
placement; skips with a note), and the .NET Framework stack (`msbuild` / `vstest.console.exe` for non-SDK projects).
Free RAM for seats and phones (`keepFreeGB`) is Windows "free" memory and the "available" figure on Linux/macOS (their page
cache keeps "free" near zero).

## Hooks (`.claude/settings.json`)

| Event | Script | Purpose |
|---|---|---|
| `PreToolUse` (Bash, PowerShell) | `dev-kit/scripts/guard.ps1` | blocks `git stash`, `--no-verify`, force-push to shared branches, ungated heavy builds; logs to `<runtime>/guard.log` |
| `SessionStart` | `orchestrate/scripts/retro-nudge.ps1` | one-line nudge to run `/kit-retro` once ≥ 15 signals piled up |
| `SessionStart` (async) | `orchestrate/scripts/cleanup.ps1 -IfDue -Quiet` | daily self-cleaning |

They run with PowerShell 7 (`pwsh`, on `PATH` on Windows, Linux and macOS) in exec form, with the path built from
`${CLAUDE_PROJECT_DIR}/.claude/...` (forward slashes work on every OS) — so the kit must sit in the `.claude` folder of
the project you open in Claude Code. The permission allow-list carries both `\` and `/` forms of the kit script paths.
