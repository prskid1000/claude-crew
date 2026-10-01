# Configuration reference

Everything machine- or org-specific lives in git-ignored `*.local.json` files next to their `*.example.json`, or in
environment variables. The kit itself contains no paths, hosts or credentials: scripts find the workspace from their own
location (`<workspace>` = the folder that holds `.claude`).

| File (copy from) | Needed for | Holds secrets? |
|---|---|---|
| `.claude/skills/dev-kit/kit.local.json` (`kit.example.json`) | tracker automation, self-hosted git, worktree cleanup, protected branches, tester-guide publishing | no |
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
| `reposRoot` | `<workspace>` | track.ps1, kitconfig | Folder holding the main checkouts (`<reposRoot>\<repo>`). `track.ps1 -MergeAfter` schedules merges from there |
| `worktreeRoots` | `[$env:CLAUDE_WT_ROOT, "<reposRoot>-wt"]` | cleanup.ps1, status.ps1 | Where `wt.ps1 new` puts worktrees (its default is `<repo's parent>-wt`) |
| `trackerRepos` | `[]` | track.ps1 `-Discover` | Repos searched for MRs whose title/branch contains `CU-<task>` |
| `repoAliases` | `{}` | track.ps1 | Short names agents use in refs, e.g. `{ "api": "backend", "web": "frontend" }` |
| `protectedBranches` | `[]` | guard.ps1, cleanup.ps1 | Shared branches besides `main`, `master`, `develop`, `release/*`: never force-pushed, their worktrees never auto-removed |
| `driveParent` | none | devtools.py `doc` | Google Drive folder (or shared drive) id for tester guides |

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
Placeholders: `{user}`, `{pass}`, `{tenant}`, `{token}`. Tokens are cached in `<runtime>\tokens`, web logins in `<runtime>\sessions`.
Evidence files never contain passwords or auth headers (`[redacted]`).

## `swarm.config.json` (android-swarm)

| Key | Default | Meaning |
|---|---|---|
| `avdDir` | `$env:ANDROID_AVD_HOME`, else `%USERPROFILE%\.android\avd` | Where the lane AVDs live |
| `keepFreeGB` | `12` | A phone boots only if free RAM − 4.5 GB stays above this |
| `headless` | `false` | Boot without windows (also per lane) |
| `lanes[]` | — | `{ name, port, user, notes, headless }`: AVD name, console port (serial `emulator-<port>`), the lane's test login (a user key in targets.local.json), notes printed by `phone.ps1 acquire` |
| `app.kind` | `react-native` | `react-native` or `native` |
| `app.package` | — | Android package id, e.g. `com.example.app` |
| `app.appDir` | — | App checkout (folder with `android\gradlew.bat` or `gradlew.bat`) |
| `app.buildTask` / `app.buildArgs` | `assembleRelease` (RN) / `assembleDebug` (native) | Gradle task + args for `app-build.ps1` |
| `app.apkGlob` | from the variant | APK location under the Android project |
| `app.devClientScheme`, `app.metroPort` | —, `8081` | React Native Metro mode (Expo dev client) |
| `app.permissions` | `[]` | Runtime permissions granted after install |

`avd-template.ini` defines the (identical) lane hardware; `{{NAME}}` and `{{SDK}}` are filled by `swarm-avd.ps1 create`.

## Environment variables

| Variable | Effect |
|---|---|
| `CLAUDE_RUNTIME` | Runtime folder (default `<workspace>\.claude-runtime`) |
| `CLAUDE_WT_ROOT` | Worktree root for `wt.ps1 new` (default `<repo's parent>-wt`) |
| `CLAUDE_AGENT` | Owner name for fair turns in the memory gate (default: worktree prefix) |
| `CLAUDE_GATE_KEEP_FREE_GB` | RAM the gate always keeps free (default 15% of RAM, min 6 GB) |
| `CHROME_PATH` | Chrome/Edge binary for `browser.mjs` (default: standard install paths) |
| `ANDROID_HOME`, `ANDROID_AVD_HOME` | Android SDK and AVD folders |
| `ANDROID_SERIAL` | The phone an app-lane agent drives (set on every command) |
| `GITLAB_HOST` | `glab` host (the scripts set it from `gitHost` when it isn't `gitlab.com`) |

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
{ brief: 'C:\\...\\wave-brief.md', mode: 'feature' | 'bugfix' | 'resume', review: true,
  agents: [ { id: 'X1', items: 'A3, A4', area: 'order form', note: '' } ],
  kitDir: 'C:\\work\\.claude', runtimeDir: 'C:\\work\\.claude-runtime' }   // kitDir/runtimeDir optional, recommended
```

`/test-and-close` (`.claude/workflows/test-and-close.js`): the run's `run.json` plus `runDir` (and optional `kitDir`). Full shape in
the header comment of the workflow file; `finalize.ps1` reads the same `run.json` from the run folder.

`/kit-retro`: `{ applyScripts: false, kitDir, runtimeDir }` — all optional.

Workflow scripts can't read the filesystem, so they don't know where the kit is: without `kitDir` they hand agents paths
relative to the workspace root (`.claude\skills\...`) and tell them so. Passing the absolute `kitDir` is more robust.

## Hooks (`.claude/settings.json`)

| Event | Script | Purpose |
|---|---|---|
| `PreToolUse` (Bash, PowerShell) | `dev-kit/scripts/guard.ps1` | blocks `git stash`, `--no-verify`, force-push to shared branches, ungated heavy builds; logs to `<runtime>\guard.log` |
| `SessionStart` | `orchestrate/scripts/retro-nudge.ps1` | one-line nudge to run `/kit-retro` once ≥ 15 signals piled up |
| `SessionStart` (async) | `orchestrate/scripts/cleanup.ps1 -IfDue -Quiet` | daily self-cleaning |

They run with Windows PowerShell 5.1 (`powershell.exe`, always present on Windows) in exec form, with the path built from
`${CLAUDE_PROJECT_DIR}` — so the kit must sit in the `.claude` folder of the project you open in Claude Code.
