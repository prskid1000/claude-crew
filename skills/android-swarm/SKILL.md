---
name: android-swarm
description: "Load when: an Android phone lane is needed: devy's local test with the local-env APK, checky on an app lane, checky lead building a run's lane APK, kitty creating / resetting lanes, a person leasing a phone. Not when: driving the app on a leased phone -> qa-kit (qa.ps1 ui); a batch of app tests -> /testy via orchestrate."
---

**Load when** (all must hold): Android emulators or an APK are involved; you are `devy` (local test loop), an app-lane
`checky` (lead: the lane APK), `kitty` (lanes), or a person testing by hand.
**Not when:** driving the app UI -> `qa-kit` (`qa.ps1 ui`); testing a batch -> `/testy`; coding -> `dev-kit`.
**Hands off to:** `qa-kit` step 3 / `local-env` "Local testing" (the leased phone), `/testy` with `lanes`.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step A0 / L0: `orch.ps1 learn -Read -Skill android-swarm` |
| `swarm.ps1` | A1-A4 (`acquire`, `ensure`, `launch`, `release`, `status`), L1-L4 (`build`, `avd`, `install`, `up`, `down`); `slim`, `arrange` run by `up` |

Lanes and the app: `swarm.config.json` (git-ignored; `orch.ps1 setup -WriteLocal` writes it):
`lanes[] {name, port | udid, user, notes, headless}`, `avd {abi, api, device, tag}`, `app {kind, package, appDir, buildTask,
buildArgs, apkGlob | buildCmd + artifact, permissions, localManifests, localReverse, branch, javaHome, javaVersions}`.
Device kinds (`kit.local.json` `devices.type`): android (default) · ios (Simulators, macOS; `qa.ps1 ui`
shot / openurl / log, `$env:KIT_DEVICE=<udid>`) · none (verbs refuse; app checks NOT_TESTED). Output (APKs, logs, `swarm.json`):
`<runtime>/cache/android-swarm/` (`outDir` overrides). Two APKs:
- **lane APK** `apk/app.apk` (+ `app.json` stamp): the merged branch, installed on every lane at acquire (test-only runs).
- **local-env APK** `apk/app-local.apk` (+ `app-local.json`): `swarm.ps1 build -Local [-AppDir <worktree>]` = a JS-bundled
  release build with the app's cleartext manifest overlay (`app.localManifests`, first that exists) for the local env's http
  API; `acquire -Apk local` installs it and reverses `app.localReverse`. Not debug variants: they need Metro / a dev launcher.

## App-lane steps (devy and checky)
- A0. `orch.ps1 learn -Read -Skill android-swarm`.
- A1. `swarm.ps1 acquire -Agent <id> -Lane <name> [-Holder <board code>] [-Apk local]`: returns at once if it is yours, else
  waits its fair turn, boots it through the memory gate, installs the app ("installed: updated" / a side APK = log in again;
  the local APK: pick the app's local-server setting at login, per org lessons). Prints serial, login, notes, app commit.
  Put the serial in your board entry's claims (or pass `-Holder`).
- A2. `$env:ANDROID_SERIAL='<serial>'` on every command; touch only your phone; never `adb kill-server`, never
  `up`/`down`/`install` for others. Relaunch / clear: `swarm.ps1 launch -Serial <s> [-Clear]`. Logs: `qa.ps1 ui log <tag>`.
  Camera: the app's camera icon, then `qa.ps1 ui photo [shutterId]`.
- A2b. Offline lane (`swarm.ps1 status` shows "down, leased by <you>"): `swarm.ps1 ensure -Agent <id>` (cold boot, lease and
  reverses kept). Lease file gone: `acquire -Agent <id> -Lane <name> -NoInstall`.
- A3. Release before long non-phone work: `swarm.ps1 release -Agent <id>` (removes reverses); acquire again later.
- A4. `swarm.ps1 release -Agent <id>` when done. The next acquire without `-Apk` puts the lane APK back.

## Lead steps
- L0. `orch.ps1 learn -Read -Skill android-swarm`; `swarm.config.json` once.
- L1. Lane APK: `swarm.ps1 build` (memory gate; fast-forwards a clean checkout to `origin/<branch>`; refuses a branch without
  `app.branch`); a side checkout writes `app-<branch>-<commit>.apk` unless `-Shared`.
- L2. `swarm.ps1 avd create` once per machine; a stuck or corrupt lane: `avd reset -Lanes <name> -Level
  cold|snapshots|wipe|recreate` (image: `swarm.config.json` `avd`; Apple silicon: `abi` `arm64-v8a`).
- L3. Never boot or shut phones yourself: agents lease them, the workflow releases a lane after its last item, `supervise
  -AutoFix` frees orphan leases and stops idle phones. At most 2 app lanes while a web pool or a dev wave runs.
- L4. A person testing by hand: `swarm.ps1 acquire -Agent manual -Lane <name>` ... `release -Agent manual` (never reclaimed).
- Linux/macOS: SDK from `$ANDROID_HOME` / `$ANDROID_SDK_ROOT`; `arrange` is Windows-only.

**Learn:** `orch.ps1 learn -Skill android-swarm -Kind <kind> -Text "<what + fix>"`.
