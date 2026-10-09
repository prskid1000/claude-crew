# Emulator swarm lessons — active rules (≤ 40 lines)
Newest first, one line each, `(n×)` = times seen. Fixed/old entries live in `HISTORY.md` (never read it for work).

- Release/embedded APKs are far steadier for automated testing than Metro (no dev menu, LogBox toasts or reloads).
- A restored snapshot can leave a lane "offline" in adb → `swarm-up.ps1 -ColdBoot -Lanes <name>` (or `swarm-avd.ps1 reset -Level cold`).
- Start emulators via WMI (swarm-up does) — a tool timeout otherwise kills them with the shell.
- Dev toasts in Metro mode can sit over in-app controls (e.g. a camera flash toggle); dismiss via the LogBox, never the toast's ×.
- Never `adb kill-server` and never touch another lane's serial; set `$env:ANDROID_SERIAL` on every command.
