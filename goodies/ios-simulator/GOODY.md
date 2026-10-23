# ios-simulator
- What: `devices.type ios`: iOS Simulator lanes (`xcrun simctl`, macOS) in phoney.ps1 and `pokey.ps1 ui shot|openurl|log`.
Needed when: `devices.type` = `ios`
- Wiring: `skills/phoney/swarm-ios.ps1` (full variant; phoney.ps1 of the goody `android-swarm` forwards to it) and
  `skills/pokey/adapters/ui_ios.ps1` (`Invoke-UiIos`). Code as of core commit 1fda997.
