# app-kinds
- What: `swarm.ps1 build` presets for `app.kind` flutter, maui (`app.tfm`), capacitor, and the Expo prebuild (android/ generated).
Needed when (swarm.config.json, checked by swarm.ps1): `app.kind` = `flutter` | `maui` | `capacitor`
- Wiring: `skills/android-swarm/adapters/app_kinds.ps1` (`Set-AppKindPreset`, `Invoke-AppPrebuild`), dot-sourced by swarm.ps1.
