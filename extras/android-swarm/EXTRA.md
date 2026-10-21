# android-swarm
- What: the `android-swarm` skill: Android emulator lanes (acquire / release leases, AVDs, the lane and local-env APKs) and
  `qa.ps1 ui` (drive the app on a leased phone) + the `deploys[]` `laneApk` check of `qa.ps1 deployed`.
Needed when: `devices.type` = `android`, `devices.type` = `ios`, `repos.*.deploys.*.laneApk` = `*`
- Wiring: `skills/android-swarm/SKILL.md` + `swarm.ps1` (lanes: git-ignored `swarm.config.json`; env `ANDROID_HOME`, `ANDROID_SERIAL`); `skills/qa-kit/adapters/
  ui_android.ps1` (`Invoke-Ui`, `Test-LaneApkDeployed`, dot-sourced by qa.ps1); `skills/dev-kit/adapters/android_sdk.ps1` (`Get-AndroidSdk`). Builds on it: `ios-simulator`, `app-kinds`,
  `emulator-windows`. Without it app checks are NOT_TESTED (`phone-only`).
