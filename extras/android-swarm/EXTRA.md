# android-swarm
- What: the `android-swarm` skill: Android emulator lanes (acquire / release leases, AVDs, the lane and local-env APKs) and
  `qa.ps1 ui` (drive the app on a leased phone) + the `deploys[]` `laneApk` check of `qa.ps1 deployed`; `qa.ps1 annotate -In
  <image> -Rect 'x,y,w,h[,label]' [-Out <file> | -Copy]` (red boxes on a screenshot, Windows; elsewhere browser.mjs `mark()`);
  `swarm.ps1 arrange` (visible emulator windows in a row, Windows); `swarm.ps1 build` presets for `app.kind` flutter, maui
  (`app.tfm`), capacitor and the Expo prebuild.
Needed when: `devices.type` = `android`, `devices.type` = `ios`, `repos.*.deploys.*.laneApk` = `*`, `skills/android-swarm/swarm.ps1` exists, or listed in kit.local.json `extras`
Needed when (swarm.config.json, checked by swarm.ps1): `app.kind` = `flutter` | `maui` | `capacitor`
- Wiring: `skills/android-swarm/SKILL.md` + `swarm.ps1` (lanes: git-ignored `swarm.config.json`; env `ANDROID_HOME`,
  `ANDROID_SERIAL`); `skills/android-swarm/adapters/arrange.ps1` (`Invoke-Arrange`, called once after a visible boot) and
  `app_kinds.ps1` (`Set-AppKindPreset`, `Invoke-AppPrebuild`); `skills/qa-kit/adapters/ui_android.ps1` (`Invoke-Ui`,
  `Test-LaneApkDeployed`) and `annotate.ps1` (`Invoke-Annotate`), dot-sourced by qa.ps1; `skills/dev-kit/adapters/android_sdk.ps1`
  (`Get-AndroidSdk`). Builds on it: `ios-simulator`. Without it app checks are NOT_TESTED (`phone-only`).
- Tests: `tests.ps1` (runs `tests-*.ps1` too).
