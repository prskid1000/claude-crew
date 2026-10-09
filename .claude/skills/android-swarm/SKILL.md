---
name: android-swarm
description: Run several Android emulators in parallel for app testing (any APK — React Native or native Kotlin/Java) — build the test APK through the memory gate, boot/slim/arrange lanes, install in Release or Metro mode, relaunch per phone, shut down; agents lease phones (phone.ps1); create all lane emulators in one go and reset/restore a corrupted one (swarm-avd.ps1). Use when testing a mobile app on emulators, especially with multiple QA agents at once.
---


# Quick start (app testers and the lead)

Up to N emulators (lanes) run the app under test in parallel, one testing agent per phone. PowerShell only. Everything app-specific
is in `swarm.config.json` (copy `swarm.example.json`): lanes (AVD + console port, login `user` + `notes`) and the app.

**Agents (QA testers on an app lane)**
- Get your phone: `phone.ps1 acquire -Agent <id> -Lane <name>` — returns at once if it is yours, else waits its fair turn, boots it when
  memory allows and installs the current `apk/app.apk` ("installed: updated" = log in again); prints serial, login and notes.
- Hand it back with `phone.ps1 release -Agent <id>` when done or before long non-phone work (API, web UI, code, data prep); acquire again later.
- `$env:ANDROID_SERIAL='<serial>'` at the start of every command; touch only your phone; never `adb kill-server`, never swarm-up/down/app-mode.
- Relaunch / clear the app: `app-launch.ps1 -Serial <s> [-Clear]`. Logs: `ui.ps1 log ReactNativeJS` (RN) or `ui.ps1 log <tag>`;
  in-app camera: tap the app's camera icon, then `ui.ps1 photo [shutterId]`.
- Each lane has its own test login and data prefix; environment-wide setting changes run alone. Passwords live only in `qa-kit/targets.local.json`.

**Lead:** `app-build.ps1` (through the memory gate; fast-forwards a clean checkout to `origin/<branch>`) → `/test-and-close` with
`lanes` (lane + login). Don't boot or shut phones yourself: agents lease them, the workflow releases a lane after its last item,
`supervise.ps1 -AutoFix` releases orphan leases and stops idle unleased phones. Release mode is preferred for testing (Metro = RN dev client).

## Reference (read only when you need it)
- `reference/scripts-and-platforms.md` — every script (app-build variants, swarm-up/avd/slim/arrange/down, app-mode, metro-start),
  modes, memory/ledger, manual leases, Linux/macOS setup: when you build, (re)create or reset emulators, or switch modes.
