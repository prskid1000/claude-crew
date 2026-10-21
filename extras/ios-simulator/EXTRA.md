# ios-simulator
- What: `devices.type ios`: iOS Simulator lanes (`xcrun simctl`, macOS) in swarm.ps1 and `qa.ps1 ui shot|openurl|log`.
Needed when: `devices.type` = `ios`
- Wiring: `skills/android-swarm/swarm-ios.ps1` (full variant; core swarm.ps1 forwards to it) and
  `skills/qa-kit/adapters/ui_ios.ps1` (`Invoke-UiIos`). Code as of core commit 1fda997.
