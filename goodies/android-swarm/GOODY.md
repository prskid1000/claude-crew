# android-swarm
- What: the `phoney` skill: Android emulator lanes (acquire / release leases, AVDs, the lane and local-env APKs) and
  `pokey.ps1 ui` (drive the app on a leased phone; `ui mic` feeds the virtual mic over the emulator's gRPC) + the `deploys[]` `laneApk` check of `pokey.ps1 deployed`; `pokey.ps1 annotate -In
  <image> -Rect 'x,y,w,h[,label]' [-Out <file> | -Copy]` (red boxes on a screenshot, Windows; elsewhere browser.mjs `mark()`);
  `phoney.ps1 arrange` (visible emulator windows in a row, Windows); `phoney.ps1 build` presets for `app.kind` flutter, maui
  (`app.tfm`), capacitor and the Expo prebuild.
Needed when: `devices.type` = `android`, `devices.type` = `ios`, `repos.*.deploys.*.laneApk` = `*`, `skills/phoney/phoney.ps1` exists, or listed in kit.local.json `goodies`
Needed when (swarm.config.json, checked by phoney.ps1): `app.kind` = `flutter` | `maui` | `capacitor`
- Wiring: `skills/phoney/SKILL.md` + `phoney.ps1` (lanes: git-ignored `swarm.config.json`; env `ANDROID_HOME`,
  `ANDROID_SERIAL`); `skills/phoney/adapters/arrange.ps1` (`Invoke-Arrange`, called once after a visible boot) and
  `app_kinds.ps1` (`Set-AppKindPreset`, `Invoke-AppPrebuild`); `skills/pokey/adapters/ui_android.ps1` (`Invoke-Ui`,
  `Test-LaneApkDeployed`) and `annotate.ps1` (`Invoke-Annotate`), dot-sourced by pokey.ps1; `skills/crafty/adapters/android_sdk.ps1`
  (`Get-AndroidSdk`). Builds on it: `ios-simulator`. Without it app checks are NOT_TESTED (`phone-only`).
- Tests: `tests.ps1` (runs `tests-*.ps1` too).
- GPU: with `gpu.exclusive.emulator` set (README "Leases"), `up` boots no emulator while another GPU kind holds the
  GPU (`<lane> not started: no memory turn (waiting for GPU)`: acquire's queue retries); a running emulator holds it until it exits.
  Each boot also waits for `gpu.exclusive.emulator.minFreeMB` (2048) free GPU memory (`lane <lane>: needs <n> MB free GPU memory, <m>
  MB free (held by <processes>)`); no nvidia-smi: one warning, no check. Needs the core `Use-KitGpu -MinFreeMB`.
