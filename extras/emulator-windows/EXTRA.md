# emulator-windows
- What: `swarm.ps1 arrange`: visible emulator windows placed in a row on the main monitor (Windows, Win32 API).
Needed when: never by config (owner watches phones: `up -ShowAll` or a lane with `headless: false`)
- Wiring: `skills/android-swarm/adapters/arrange.ps1` (`Invoke-Arrange`); `up` calls it once after a visible boot.
