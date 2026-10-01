# Emulator swarm lessons (self-improving)

Newest first. `(n×)` = times observed.

- (fixed in kit) Agents own phones through leases - `phone.ps1 acquire` (take a free running phone, boot one when memory allows, else wait in a fair queue for a release or memory; installs the current APK) and `release` (close the app, shut down unless someone waits). The coordinator no longer runs swarm-up/down for QA runs; supervise only releases orphan leases and stops unleased idle phones. swarm-down verifies the emulator exited (one ignored `emu kill` and kept running while reported stopped).
- (fixed in kit) A finished app lane's emulator kept running until someone noticed. Phone in use = leased; agents release before long non-phone work (API, web UI in the browser, code, data prep); the supervisor shuts an unleased phone whose app has been closed 10 min; the workflow releases a lane after its last app item.
- (fixed in kit) app-build.ps1 built the main checkout as last pulled, 10 commits behind the branch, so the APK lacked the fixes under test. It now fast-forwards a clean checkout to origin/<branch> first (reinstalls deps if lockfiles changed); `-NoUpdate` opts out.
- (fixed in kit) Headless lanes (-Headless / config), `-Mode Embedded` alias, `metro-start -Port`, variant-safe app-build (+ `-DevClient` builds base.apk), lane logins in config, `ui.ps1 photo` (in-app camera), and `swarm-avd.ps1` (create all lanes from avd-template.ini; reset cold/snapshots/wipe/recreate).
- (2×, fixed in kit) Java 24+ breaks the React Native native (CMake/prefab) step ("restricted method in java.lang.System"). app-build ignores a JAVA_HOME of 24+ and picks a JDK 17/21.
- Release/embedded APKs are far steadier for automated testing than Metro (no dev menu, LogBox toasts or reloads).
- A restored snapshot can leave a lane "offline" in adb → `swarm-up.ps1 -ColdBoot -Lanes <name>` (or `swarm-avd.ps1 reset -Level cold`).
- Start emulators via WMI (swarm-up does) — a tool timeout otherwise kills them with the shell.
- Dev toasts in Metro mode can sit over in-app controls (e.g. a camera flash toggle); dismiss via the LogBox, never the toast's ×.
- Never `adb kill-server` and never touch another lane's serial; set `$env:ANDROID_SERIAL` on every command.
