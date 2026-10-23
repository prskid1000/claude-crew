---
name: android-swarm
description: "Load when: an Android phone lane is needed: devy's local test with the local-env APK, checky on an app lane, checky lead building a run's lane APK, kitty creating / resetting lanes, a person leasing a phone. Not when: driving the app on a leased phone -> pokey (pokey.ps1 ui); a batch of app tests -> /testy via bossy."
---

**Load when** (all must hold): Android emulators or an APK are involved; you are `devy` (local test loop), an app-lane
`checky` (lead: the lane APK), `kitty` (lanes), or a person testing by hand.
**Not when:** driving the app UI -> `pokey` (`pokey.ps1 ui`); testing a batch -> `/testy`; coding -> `crafty`.
**Hands off to:** `pokey` step 3 / `local-env` "Local testing" (the leased phone), `/testy` with `lanes`.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step A0 / L0: `bossy.ps1 learn -Read -Skill android-swarm` |
| `phoney.ps1` | A1-A4 (`acquire`, `ensure`, `launch`, `release`, `status`), L1-L4 (`build`, `avd`, `install`, `up`, `down`); `slim` runs from `up` |
| `<kit>/skills/pokey/adapters/ui_android.ps1` | never read: `pokey.ps1 ui` and the `deploys[]` `laneApk` check of `pokey.ps1 deployed` (this goody) |

Lanes and the app: `swarm.config.json` (git-ignored; an example: "Config" below; keys and defaults: `Get-SwarmConfig`
in `phoney.ps1`). `kit.local.json` `devices.type`: android (default) · none (verbs refuse; app checks NOT_TESTED). Also here:
`app.kind` presets (flutter, maui, capacitor, Expo), `phoney.ps1 arrange` (visible windows in a row); goody `ios-simulator`. Output (APKs, logs, `swarm.json`): `<runtime>/cache/android-swarm/` (`outDir` overrides). Two APKs:
- **lane APK** `apk/app.apk` (+ `app.json` stamp): the merged branch, installed on every lane at acquire (test-only runs).
- **local-env APK** `apk/app-local.apk` (+ `app-local.json`): `phoney.ps1 build -Local [-AppDir <worktree>]` = a JS-bundled
  release build with the app's cleartext manifest overlay (`app.localManifests`, first that exists) for the local env's http
  API; `acquire -Apk local` installs it and reverses `app.localReverse`. Not debug variants: they need Metro / a dev launcher.
  Only a clean origin/<app.branch> HEAD or `localenv/*` replaces it; any other build is a side APK (`acquire -Apk <its path>`).

## App-lane steps (devy and checky)
- A0. `bossy.ps1 learn -Read -Skill android-swarm`.
- A1. `phoney.ps1 acquire -Agent <id> -Lane <name> [-Holder <board code>] [-Apk local]`: returns at once if it is yours, else
  waits its fair turn, boots it through the memory gate, installs the app ("installed: updated" / a side APK = log in again;
  the local APK: pick the app's local-server setting at login, per org lessons). Prints serial, login, notes, app commit.
  Put the serial in your board entry's claims (or pass `-Holder`).
- A2. `$env:ANDROID_SERIAL='<serial>'` on every command; touch only your phone; never `adb kill-server`, never
  `up`/`down`/`install` for others. Relaunch / clear: `phoney.ps1 launch -Serial <s> [-Clear]`. Logs: `pokey.ps1 ui log <tag>`.
  Camera: the app's camera icon, then `pokey.ps1 ui photo [shutterId]`.
- A2b. Offline lane (`phoney.ps1 status` shows "down, leased by <you>"): `phoney.ps1 ensure -Agent <id>` (cold boot, lease and
  reverses kept). Lease file gone: `acquire -Agent <id> -Lane <name> -NoInstall`.
- A3. Release before long non-phone work: `phoney.ps1 release -Agent <id>` (removes reverses); acquire again later.
- A4. `phoney.ps1 release -Agent <id>` when done. The next acquire without `-Apk` puts the lane APK back.

## Lead steps
- L0. `bossy.ps1 learn -Read -Skill android-swarm`; `swarm.config.json` once.
- L1. Lane APK: `phoney.ps1 build` (memory gate; fast-forwards a clean checkout to `origin/<branch>`; refuses a branch without
  `app.branch`); a side checkout writes `app-<branch>-<commit>.apk` unless `-Shared`.
- L2. `phoney.ps1 avd create` once per machine; a stuck or corrupt lane: `avd reset -Lanes <name> -Level
  cold|snapshots|wipe|recreate` (image: `swarm.config.json` `avd`; default `abi` = the host's: `arm64-v8a` or `x86_64`).
- L3. Never boot or shut phones yourself: agents lease them, the workflow releases a lane after its last item, `acquire` and
  `supervise -AutoFix` reclaim leases with no live holder (README "Leases"), supervise stops idle phones. At most 2 app lanes
  while a web pool or a dev wave runs.
- L4. A person testing by hand: `phoney.ps1 acquire -Agent manual -Lane <name>` ... `release -Agent manual` (owner hold, 240 min).
- Linux/macOS: SDK from `$ANDROID_HOME` / `$ANDROID_SDK_ROOT`.

**Learn:** `bossy.ps1 learn -Skill android-swarm -Kind <kind> -Text "<what + fix>"`.

## Config (an example `skills/phoney/swarm.config.json`)
```json
{
 "swarm.config.json": {
   "_readme": "Lanes = AVD names (phoney.ps1 avd create; iOS: a udid), each with its test login (user: targets.local.json) and notes. avd {abi, api, device, tag}. app.kind: react-native | native | kmp; flutter, maui, capacitor (adapters/app_kinds.ps1). localManifests: cleartext manifests build -Local merges; localReverse: ports acquire -Apk local reverses (local API).",
   "avdDir": "",
   "outDir": "",
   "headless": false,
   "lanes": [
    { "name": "Falcon", "port": 5556, "user": "qa-user-1", "notes": "data prefix QA-L1-" },
    { "name": "Kestrel", "port": 5558, "user": "qa-user-2", "notes": "data prefix QA-L2-" }
   ],
   "app": {
    "kind": "react-native", "package": "com.example.app", "appDir": "/path/to/example-app/app", "branch": "main",
    "buildTask": "assembleRelease", "buildArgs": "-PreactNativeArchitectures=x86_64 -Dorg.gradle.workers.max=4",
    "apkGlob": "app/build/outputs/apk/release/*.apk", "permissions": ["CAMERA", "ACCESS_FINE_LOCATION"],
    "localManifests": ["src/debugOptimized/AndroidManifest.xml", "src/debug/AndroidManifest.xml"], "localReverse": [8080],
    "javaHome": "", "javaVersions": [17, 21]
   }
  }
}
```
