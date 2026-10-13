---
name: android-swarm
description: "Load when: you build the test APK, create, boot or reset emulator lanes, lease a phone for app testing (an app-lane qa-tester, or a person by hand), or switch Release/Metro mode. Not when: you drive the app on a phone you already leased -> qa-kit (ui.ps1); a batch of app tests -> /test-and-close via orchestrate; coding -> dev-kit (dev agents never start emulators)."
---

**Load when** (all must hold): Android emulators or the test APK are involved; you are an app-lane `qa-tester`, the lead
(orchestrate step 6, router R12), or a person testing by hand through a manual lease.
**Not when:** driving the app UI -> `qa-kit` (`scripts/android/ui.ps1`); testing a batch -> `/test-and-close`; coding -> `dev-kit`.
**Hands off to:** `qa-kit` step 3 (the leased phone), `/test-and-close` with `lanes` (lane + login).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` | step A0 / L0, before touching a phone |
| `HISTORY.md` | never read for work (retired lessons) |
| `reference/scripts-and-platforms.md` | L1-L4 (build variants, create/reset lanes, modes, memory, manual leases) and on Linux/macOS |
| `swarm.example.json` | L0: copy to `swarm.config.json` (lanes, app, optional `outDir`) |
| `avd-template.ini` | L2: the lane hardware `swarm-avd.ps1 create` copies (x86_64; edit for Apple silicon) |
| `phone.ps1` | A1 (`acquire [-Holder]`), A2b (`ensure`), A4 (`release`), `status` |
| `app-launch.ps1` | A2, relaunch or clear the app |
| `app-build.ps1` | L1, build the test APK through the memory gate |
| `swarm-avd.ps1` | L2, create all lanes; `reset -Level cold|snapshots|wipe|recreate` for a broken one |
| `app-mode.ps1` | L3, switch every phone to Release or Metro (also run by phone.ps1 to install) |
| `metro-start.ps1` | L3, React Native Metro mode only |
| `swarm-up.ps1`, `swarm-down.ps1` | run by phone.ps1 (boot / shut down a lane); by hand only at L4 |
| `swarm-slim.ps1`, `swarm-arrange.ps1` | run by swarm-up (one-time slimming, window layout) |
| `_config.ps1` | library: loads `swarm.config.json` and the output folder; never run by hand |

Runtime output (APKs, `build.log`, `metro.log`, emulator logs, `swarm.json`) goes to `<runtime>/cache/android-swarm/` (`<runtime>` =
`<kit>/.claude-runtime`, disposable; override with `outDir` in `swarm.config.json`). An older APK in this folder's `apk/` is copied there once.

## App-lane tester steps
- A0. Read `LESSONS.md`.
- A1. `phone.ps1 acquire -Agent <id> -Lane <name> [-Holder <board code>]`: returns at once if it is yours, else waits its fair turn,
  boots it when memory allows and installs the current `app.apk` ("installed: updated" = log in again); prints serial, login, notes
  and the APK's branch/commit (a warning when the branch moved on: ask the lead to rebuild). Put the serial in your board entry's
  worktrees (or pass `-Holder`): the supervisor counts the lease as live while that entry is.
- A2. `$env:ANDROID_SERIAL='<serial>'` on every command; touch only your phone; never `adb kill-server`, never swarm-up/down/app-mode.
  Relaunch / clear: `app-launch.ps1 -Serial <s> [-Clear]`. Logs: `ui.ps1 log ReactNativeJS` (RN) or `ui.ps1 log <tag>`; in-app camera:
  tap the app's camera icon, then `ui.ps1 photo [shutterId]`. Each lane has its own login and data prefix; environment-wide setting
  changes run alone; passwords live only in `qa-kit/targets.local.json`.
- A2b. Under RAM pressure lanes can drop offline (`phone.ps1 status` shows "down, leased by <you>"; the lease is kept): before each app
  check confirm `adb devices` lists your serial as `device` and your lease file exists. Serial offline -> `phone.ps1 ensure -Agent <id>`
  (cold-boots your lane through the memory gate); lease file gone -> `phone.ps1 acquire -Agent <id> -Lane <name> -NoInstall`.
  The lead runs at most 2 app lanes while a web pool or a dev wave runs in parallel.
- A3. Hand the phone back with `phone.ps1 release -Agent <id>` before long non-phone work (API, web UI, code, data prep); acquire again later.
- A4. `phone.ps1 release -Agent <id>` when done.

## Lead steps
- L0. Read `LESSONS.md`; copy `swarm.example.json` to `swarm.config.json` once.
- L1. `app-build.ps1` (memory gate; fast-forwards a clean checkout to `origin/<branch>`) → `/test-and-close` with `lanes`.
- L2. `swarm-avd.ps1 create` once per machine; a stuck or corrupt lane → `swarm-avd.ps1 reset -Lanes <name> -Level <level>`.
- L3. Release mode is preferred for testing; Metro (RN dev client) via `app-build.ps1 -DevClient`, `metro-start.ps1`, `app-mode.ps1 -Mode Metro`.
- L4. Don't boot or shut phones yourself: agents lease them, the workflow releases a lane after its last item, `supervise.ps1 -AutoFix`
  releases orphan leases and stops idle unleased phones. A person testing by hand: `phone.ps1 acquire -Agent manual -Lane <name>`.
