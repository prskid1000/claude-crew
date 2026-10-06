---
name: android-swarm
description: Run several Android emulators in parallel for app testing (any APK — React Native or native Kotlin/Java) — build the test APK through the memory gate, boot/slim/arrange lanes, install in Release or Metro mode, relaunch per phone, shut down; agents lease phones (phone.ps1); create all lane emulators in one go and reset/restore a corrupted one (swarm-avd.ps1). Use when testing a mobile app on emulators, especially with multiple QA agents at once.
---

# Android emulator swarm — parallel app testing (any Android app)

Up to N emulators (lanes) run the app under test in parallel, one testing agent per phone. PowerShell only.
Everything app-specific is in `swarm.config.json` (copy `swarm.example.json`): lanes (AVD name + console port), and the
app (`kind` react-native | native, package, appDir, build task/args, APK glob, permissions, Metro port/dev-client scheme).

| Script | Purpose |
|---|---|
| `app-build.ps1` | build the test APK through the memory gate (`..\dev-kit\scripts\gate.ps1`) → `apk\app.apk` (+ `app-<commit>.apk`). Fast-forwards a clean checkout to `origin/<branch>` first (`-NoUpdate` to skip). Rebuild after app changes. Only the configured checkout publishes `apk\app.apk` (installed on every lane); `-AppDir <other worktree>` writes `apk\app-<branch>-<commit>.apk` for your own leased phone (`-Shared` to publish) |
| `phone.ps1 acquire\|release\|status -Agent <id> [-Lane <name>]` | **how agents get phones.** acquire: take a free running phone, else boot one if memory allows (free RAM − 4.5 GB ≥ `keepFreeGB`), else wait in a fair queue for a release or memory; installs the current `apk\app.apk` if the phone has an older one. release: close the app, free the lease, shut the phone down unless another agent waits |
| `swarm-up.ps1 [-Count n] [-Mode Release\|Metro\|None] [-Headless] [-ColdBoot]` | (manual / used by phone.ps1) boot lanes, wait, slim once, install the app, write `swarm.json`. `-Headless` (or `"headless": true` in the config, per lane or top level) = no windows; `-Mode Embedded` = Release (old name) |
| `swarm-avd.ps1 list\|create\|reset` | **create** every missing lane emulator in one go from `avd-template.ini` (identical phones; no Android command-line tools needed). **reset -Lanes X -Level** `cold` (stuck/offline boot) → `snapshots` (corrupt quick-boot snapshot) → `wipe` (factory reset) → `recreate` (AVD files broken). A lane leased by an agent is refused unless `-Force`; after wipe/recreate the next acquire re-slims and reinstalls the app |
| `app-build.ps1 -DevClient` | react-native: build the Expo dev client (debug variant) → `apk\base.apk` for Metro mode. Any other `-Task` copies the APK that run built to `apk\app-<variant>.apk` |
| `app-mode.ps1 -Mode Release\|Metro` | install that mode's APK on all phones (Metro = React Native dev client `apk\base.apk` + adb reverse) |
| `app-launch.ps1 -Serial <s> [-Clear]` | (re)start the app the right way for the phone's mode; `-Clear` wipes app data and re-grants permissions |
| `metro-start.ps1` | React Native only: one shared Metro (no watching, capped workers), bundle pre-warmed |
| `swarm-arrange.ps1` | windows side by side, centred on the main monitor (DPI-aware) |
| `swarm-slim.ps1 -Serial <s>` | one-time: disable heavy Google extras, no animations, screen on, no lock (undo: `adb shell pm enable <pkg>`) |
| `swarm-down.ps1` | stop the emulators (snapshot saved) and leftover headless test browsers |

Typical run: `app-build.ps1` → run the agents (`/test-and-close` with `lanes` = lane + its login). The coordinator does NOT boot or shut
phones: each app agent acquires its lane's phone and the workflow releases it after the lane's last item.

Modes: **Release** (preferred for testing: the APK as built, no dev tooling) and **Metro** (React Native while code still changes).
Native Kotlin/Java apps use Release only (`buildTask` e.g. `assembleDebug`, `apkGlob` e.g. `app\build\outputs\apk\debug\*.apk`).

Memory + coordination: each emulator boot takes a fair turn in the machine-wide gate (same queue as builds) and stays registered in its
ledger while running, so builds account for it. QA agents claim their phone on the agent board (`-Claims emulator-55xx`).
Manual use (a person testing by hand): `phone.ps1 acquire -Agent manual -Lane <name>` … `phone.ps1 release -Agent manual`; a manual lease is never reclaimed by the supervisor. AVD images live in `avdDir` (default `$env:ANDROID_AVD_HOME`, else `%USERPROFILE%\.android\avd`).

Phone in use = it is leased (`<runtime>\phones\<lane>.json`). Agents release before long non-phone work (API, web UI, code, data prep)
and acquire again later. `supervise.ps1 -AutoFix` is only the safety net: it releases a lease whose holder is gone (crashed) and shuts an
unleased phone (booted by hand) whose app has been closed for 10 min. `swarm-down` verifies the emulator exited (force-kills after 90 s).

Rules for agents: set `$env:ANDROID_SERIAL='<serial>'` at the start of every command; only touch your own phone; each lane
uses its own test login and data prefix; environment-wide setting changes run alone. `swarm-up` won't boot a lane with
less than `keepFreeGB` free RAM. Keep the AVD resolution fixed across lanes so coordinates in notes stay valid.
App logs: `ui.ps1 log ReactNativeJS` (RN) or `ui.ps1 log <your tag>` / `ui.ps1 log` (errors).
In-app camera (POD, inspections): tap the app's camera icon, then `ui.ps1 photo [shutterId]` (the back camera is a virtual scene).
Lane logins: each lane in `swarm.config.json` has `user` + `notes` (employee, vehicle, data prefix); `phone.ps1 acquire` prints them.
Passwords live only in `qa-kit\targets.local.json`.
