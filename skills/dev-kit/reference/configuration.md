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
| `repos` | - | bug-brief.ps1, wt.ps1 | Repos: `[{ name, aliases[], checkout, target, linkFrom?, linkFromByTarget?, linkPaths? }]`. `wt.ps1 new` links `node_modules` / `.venv` from `linkFromByTarget[<target>]` (or `linkFrom`, else the checkout) and fails if a configured source is missing; `linkPaths` = git-ignored local files/folders every worktree needs (credentials, `local.properties`, `.env`): folders linked, files copied. Maven (`~/.m2`) and Gradle (`~/.gradle`) caches are per user, so worktrees already share them |
| `repos[].deploys` | - (repo reports NO-TARGET) | qa-kit deployed.ps1, supervise.ps1 | Where a merged MR goes live, one entry per test environment, each `{ target, ... }` plus one of: **CI** `branch` + `job` (live when that job succeeded on a pipeline holding the merge); **`awsStack`** + `region` (stack updated after the merge); **`ssh`** `{ host: "user@host", key: "<key file>", repoDir: "<checkout on the host>", appDir: "<installed app dir>", subdir?: "<part of repoDir that is installed>", exclude?: ["data"], service?: "<systemd unit>" }` (one BatchMode ssh call: live when the merge commit is an ancestor of the host checkout's HEAD AND `sudo -n diff -rq` repoDir/subdir vs appDir shows no differing files, excluding `.git`, `__pycache__`, `*.pyc`, `venv`, `current` and `exclude`; files only in appDir are ignored); **`manual: true`** (deployed by hand, no way to check: MANUAL "confirm with the owner or an ssh check" instead of NOT-DEPLOYED; the qa-kit lead resolves it at L1); **`laneApk: true`** (an app repo tested on the emulator lanes: live when the merge commit is an ancestor of the commit the lane APK was built from, the `app.json` stamp app-build.ps1 writes next to the lane APK; a string instead of `true` = the path of that app.json) |
| `bugfixMandate` | - | bug-brief.ps1 | The task owner's own words asking for QA bugs to be fixed; passed to /dev-wave as `mandate` |
| `githubHost` | `github.com` | devtools.py | GitHub (Enterprise) host |
| `gitlabGroup` | none | track.ps1 | Group (or `group/subgroup`) for short MR refs `<repo>!<iid>`. Without it, refs must be `<group/repo>!<iid>` |
| `reposRoot` | `<workspace>` | track.ps1, kitconfig | Folder holding the main checkouts (`<reposRoot>/<repo>`). `track.ps1 -MergeAfter` schedules merges from there |
| `worktreeRoots` | `[$env:CLAUDE_WT_ROOT, "<reposRoot>-wt"]` | wt.ps1, cleanup.ps1, status.ps1 | Where `wt.ps1 new` puts worktrees (the first entry; without the key: `<repo's parent>-wt`). A root inside a git repo (e.g. `<reposRoot>/.worktrees` in a superproject) is added to that repo's `info/exclude` |
| `trackerRepos` | `[]` | track.ps1 `-Discover` | Repos searched for MRs whose title/branch contains `<tracker.branchTag><task>` (e.g. `CU-<task>`) |
| `repoAliases` | `{}` | track.ps1 | Short names agents use in refs, e.g. `{ "api": "backend", "web": "frontend" }` |
| `protectedBranches` | `[]` | guard.ps1, cleanup.ps1 | Shared branches besides `main`, `master`, `develop`, `release/*`: never force-pushed, their worktrees never auto-removed |
| `localEnv` | - (no local envs) | local-env scripts, guard.ps1 | Local pre-staging envs (local-env skill). Top level: `leaseMinutes` (30), `maxLeaseMinutes` (120), `cpuMaxPct` (90), `roomWaitMinutes` (30), `keepFreeGB` (gate floor), `idle.enabled` (true), `idle.minMinutes` (15), `idle.maxMinutes` (60), `loopExitMinutes` (10), `migrationPattern`, `failPattern`. `envs.<env>`: `description?`, `envFile?` (dotenv, default `<kit>/localenv.local/<env>.env`: secrets only here), `env?` {K: V}, `tasks?` { name: { repo, dir?, cmd, gated?, env? } }, `services[]` in start order: `name`, `repo?` (repos[] name/alias; none = infra), `dir?`, `target?` (repos[].target), `start?` (stack.ps1 `run`), `build?` (gated, per train), `artifact?` (glob under dir: run from a staged copy; `{artifact}` in start), `artifactExclude?`, `port?` (unique across envs), `health?` (URL, status < 500 = up), `dependsOn?` [services], `hot?` (reloads itself: not restarted), `external?` (infra; managed only with `start`), `ramGB?`, `startMinutes?` (10), `failPattern?`, `env?`. Placeholders: `{port}` `{dir}` `{wt}` `{env}` `{kit}` `{workspace}` `{artifact}` `{lanIp}` |
| `driveParent` | none | devtools.py `doc`, finalize.ps1 (`gdocs` only) | Google Drive folder (or shared drive) id for tester guides / QA evidence |
| `tracker` | `{ "type": "clickup" }` | tracker.ps1 and everything that talks to the tracker | Issue tracker backend — see [Tracker](#tracker-trackertype) |
| `reports` | `{ "type": "gdocs" }` if `gws` is on PATH, else `{ "type": "markdown" }` | finalize.ps1, devtools.py `doc` | Where QA reports and tester guides go — see [Reports](#reports-reportstype) |
| `build.mavenOffline` | `true` | stack.ps1 | Maven commands get `-o` (offline: no network round-trips or remote-repo lock contention between parallel builds) when `~/.m2/repository` exists; `false` = always online |
| `gate.keepFreeGB` | 15% of RAM, min 6 | gate.ps1, qa-seat.ps1, phone.ps1 (boots queue in the gate) | RAM every gated build, phone boot and QA seat leaves free: the one memory floor (`-KeepFreeGB` / env `CLAUDE_GATE_KEEP_FREE_GB` win) |
| `gate.startHeapGB` | `{ "gradle": 12, "maven": 8, "node": 4 }` | gate.ps1 | First JVM/Node heap for a project with no build history (afterwards learned from real peaks, never above this) |
| `gate.heapMinGB` | `4` | gate.ps1 | Heap floor when the gate shrinks heaps under memory pressure |
| `supervise.ramActPct` | `90` | supervise.ps1 | RAM use (%) that raises an ACT flag |
| `supervise.minDiskFreeGB` | `30` | supervise.ps1 | Free disk (GB) on the workspace drive below which supervise raises an ACT flag |
| `localOnly` | `[]` | kit-setup.ps1, kit-lint.py, pre-push hook | Kit paths that are local overlay (org-only skills, project profiles, extra rules): `kit-setup.ps1 -Exclude` (run by kit-health at SessionStart) writes them into the clone's `.git/info/exclude` so they never show in `git status`, the pre-push hook blocks them, kit-lint treats them as overlay |
| `orgTerms` | `[]` | kit-lint.py `--org-terms`, pre-push hook | Org words (names, hosts, ids) that must never appear in the published kit; the coordinator scans the kit with them before every push (orchestrate K3) and `.githooks/pre-push` blocks a push that carries one |
| `memory.keepDefault` | `false` | kit-setup.ps1 (and kit-health at session start) | `false`: Claude Code auto memory is kept in `<kit>/memory/` (git-ignored; `autoMemoryDirectory` written into `settings.local.json`). `true`: don't set it per clone, so a user-level `autoMemoryDirectory` (e.g. one structured memory folder in the user's home for every project) or the harness default applies |
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
| `none` | nothing | no tracker: every task is kept as JSON in `<kit>/tracker-none.local/` (durable, git-ignored; `create` returns `LOCAL-<n>`) and every call is logged to `<runtime>/logs/tracker-none.log`; nothing fails |

Other `tracker` keys:

| Key | Default | Meaning |
|---|---|---|
| `tracker.repo` | - | `owner/name` (GitHub) or `group/project` (GitLab) holding the issues |
| `tracker.list` | - | Default list / project for `create` (bug tasks when `run.json` has no `tracker.list`) |
| `tracker.owner` | your OS full name | Optional override. Every task `create` makes (bug tasks, subtasks) without `-Assignee` goes to the person running the kit: this value if set, else the OS user's full name matched to a tracker member (ClickUp/Jira), else the CLI's logged-in user (GitHub/GitLab). `& $TR owner` shows the result; `run.json` `tracker.owner` wins for QA bug tasks; `-Assignee -` = nobody. Tracker user id (ClickUp/Jira) or username (GitHub/GitLab) |
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
| `markdown` | `<runDir>/<code>/report.md` (+ `report.html`) next to `shots\` and `evidence\`, links relative; the tracker comment carries the report (GitHub/GitLab: its text, ClickUp/Jira: the file attached, `none`: logged) and the bug task gets it too | the file (`.md` or `.html`) is kept under `<runtime>/work/docs` and its path printed — attach it with `tracker.ps1 attach` |

`finalize.ps1 -Report gdocs|markdown` overrides the setting for one run.

`reports.guide` (default `complex`): when a change gets a published tester guide (dev-kit step 7b). `complex` = changes over
several screens or flows, repos, migrations or roles get the guide, simple ones a how-to-test comment; `always` = every testable
change gets the guide (steps, concrete Expected, screenshots) and the task comment links it. Agents read it with `devtools.py guide-mode`.

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
`browser` (top level, or per target to override it): `{ "lang": "en-GB", "timezone": "", "width": 1600, "height": 1000 }` (the
defaults) - the headless browser's language (Accept-Language, `navigator.language`: date and number formats), time zone (IANA name,
empty = the machine's) and window/viewport size for `browser.mjs`.

Top-level `keepFreeGB` (default `8`): only the supervisor's capacity flag reads it now. `qa-seat.ps1` uses the memory gate's floor
(`gate.keepFreeGB`, see above): a new tester/verifier starts only while free RAM minus the GB the gate has promised (running and
queued builds / phones) minus its need (web ~1.5 GB, API ~0.4 GB) stays at or above it.

Placeholders: `{user}`, `{pass}`, `{tenant}`, `{token}`. Tokens are cached in `<runtime>/cache/tokens`, web logins in `<runtime>/cache/sessions`.
Evidence files never contain passwords or auth headers (`[redacted]`).

## `swarm.config.json` (android-swarm)

| Key | Default | Meaning |
|---|---|---|
| `avdDir` | `$env:ANDROID_AVD_HOME`, else `~/.android/avd` (`%USERPROFILE%\.android\avd` on Windows) | Where the lane AVDs live |
| `outDir` | `<runtime>/cache/android-swarm` | Runtime output: `apk/` (app.apk, base.apk, per-commit and side builds, `app.json` stamp), `build.log`, `metro.log`, emulator logs, `swarm.json`. An `app.apk` left in the skill's old `apk/` folder is copied here once |
| `keepFreeGB` | `12` | Unused by `phone.ps1` (kept for older configs): a phone boot queues in the memory gate, which keeps `gate.keepFreeGB` free |
| `headless` | `false` | Boot without windows (also per lane) |
| `lanes[]` | — | `{ name, port, user, notes, headless }`: AVD name, console port (serial `emulator-<port>`), the lane's test login (a user key in targets.local.json), notes printed by `phone.ps1 acquire` |
| `app.kind` | `react-native` | `react-native` or `native` |
| `app.package` | — | Android package id, e.g. `com.example.app` |
| `app.appDir` | — | App checkout (folder with `android/gradlew[.bat]` or `gradlew[.bat]`) |
| `app.branch` | - (any branch) | Branch the shared lane APK is tested from: `app-build.ps1` refuses to publish `apk/app.apk` from a checkout that does not contain `origin/<app.branch>` (a worktree cut from it passes), and always from a branch whose remote is gone; `-AnyBranch` overrides |
| `app.buildTask` / `app.buildArgs` | `assembleRelease` (RN) / `assembleDebug` (native) | Gradle task + args for `app-build.ps1` |
| `app.apkGlob` | from the variant | APK location under the Android project; its module folder (the part before `/build/outputs/`) is where `app-build.ps1` looks for the APK it built (an app module not named `app`) |
| `app.devClientScheme`, `app.metroPort` | —, `8081` | React Native Metro mode: with a scheme the Expo dev client is deep-linked to Metro; without one (bare React Native debug build) the app starts normally with the Metro port reversed. `metro-start.ps1` runs `npx expo start` when the app depends on `expo`, else `npx react-native start` |
| `app.javaHome` / `app.javaVersions` | — / `[17, 21]` | `app-build.ps1`: pin a JDK, or the JDK majors the build accepts (found in `JAVA_HOME`, `~/.gradle/jdks`, `~/.jdks`, the usual install folders) |
| `app.permissions` | `[]` | Runtime permissions granted after install |

`avd-template.ini` defines the (identical) lane hardware; `{{NAME}}` and `{{SDK}}` are filled by `swarm-avd.ps1 create`.

## Environment variables

| Variable | Effect |
|---|---|
| `CLAUDE_RUNTIME` | Runtime folder (default `<kit>/.claude-runtime`; layout in `skills/dev-kit/scripts/kitpaths.json`) |
| `CLAUDE_WT_ROOT` | Worktree root for `wt.ps1 new` (default `<repo's parent>-wt`) |
| `CLAUDE_AGENT` | Owner name for fair turns in the memory gate (default: the worktree folder minus its repo suffix, else its first dash part) |
| `CLAUDE_GATE_KEEP_FREE_GB` | RAM the gate always keeps free (default `gate.keepFreeGB`, else 15% of RAM, min 6 GB) |
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
Keys you set replace the detected ones. Placeholders: `{tests}`, `{files}`, `{sln}`. Android: `"androidVariant": "freeDebug"`
picks the variant for compile/test/lint/assemble (default `Debug`, or `<first product flavor>Debug` when the app declares
`productFlavors`).

What detection reads (so most repos need no override):

| Stack | Detected from the project |
|---|---|
| Maven | wrapper (`mvnw`), offline only with a local repo (`build.mavenOffline`) |
| Gradle / Android | wrapper (`gradlew`), `AndroidManifest.xml`, product flavors |
| .NET Framework | `msbuild` / `vstest.console.exe` on `PATH`, else found with `vswhere` (Visual Studio / Build Tools) |
| Angular | `angular.json`: a `test` target and its builder (Karma gets `--browsers=ChromeHeadless`), a `production` build configuration |
| Node | lockfile → `npm` / `yarn` / `pnpm` / `bun` for `test` and `build` scripts; jest / vitest / eslint from dependencies and config files; `tsconfig.app.json` when `tsconfig.json` only holds project references |
| Python | `.venv`; ruff (else flake8) and pytest (else `unittest`) as installed in the project's interpreter, else from their config files |
| Make | `test` step only when the Makefile has a `test:` target |
| Liquibase (`-Step migrations`) | XML master changelogs (`*master.xml`) under a `liquibase/` or `changelog/` folder; changed files are reported whether or not their names start with a timestamp |

## Workflow arguments

`/dev-wave` (`.claude/workflows/dev-wave.js`):
```js
{ brief: '<abs path>/wave-brief.md', mode: 'feature' | 'bugfix' | 'resume', review: true | false | 'auto', learn: true | false | 'auto',
  agents: [ { id: 'X1', items: 'A3, A4', area: 'project form', note: '', complex: false, model: '', effort: 'medium' } ],   // complex/model/effort optional
  complex: ['X1'], models: { build: 'sonnet', review: 'sonnet' },   // optional (see Models by stage)
  kitDir: '<workspace>/.claude' }   // kitDir optional, recommended; runtimeDir optional (default <kitDir>/.claude-runtime)
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
| `PreToolUse` (Bash, PowerShell) | `dev-kit/scripts/guard.ps1` | blocks `git stash`, `--no-verify`, force-push to shared branches, ungated heavy builds, deleting the runtime's `work/` while runs are active; logs to `<runtime>/logs/guard.log` |
| `SessionStart` | `orchestrate/scripts/kit-health.ps1` | one line when the kit clone has uncommitted changes, is behind/ahead of its last-fetched upstream, the pre-push gate is off, an old runtime waits for migration, or kit-lint finds problems; refreshes the `localOnly` excludes |
| `SessionStart` | `orchestrate/scripts/retro-nudge.ps1` | one-line nudge to run `/kit-retro` once ≥ 15 signals piled up |
| `SessionStart` (async) | `orchestrate/scripts/cleanup.ps1 -IfDue -Quiet` | daily self-cleaning |
| `SessionStart` (async) | `orchestrate/scripts/kit-health.ps1 -Flow -Fetch` | regenerates `<runtime>/cache/kit-flow.html` (also done by every kit-lint run) and runs `git fetch` so the next start knows the real behind/ahead count |

They run with PowerShell 7 (`pwsh`, on `PATH` on Windows, Linux and macOS) in exec form, with the path built from
`${CLAUDE_PROJECT_DIR}/.claude/...` (forward slashes work on every OS) — so the kit must sit in the `.claude` folder of
the project you open in Claude Code. The permission allow-list carries both `\` and `/` forms of the kit script paths.
