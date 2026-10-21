# annotate
- What: `qa.ps1 annotate -In <image> -Rect 'x,y,w,h[,label]' [-Out <file> | -Copy]`: red boxes (and labels) on a PNG / JPEG
  screenshot (Windows, System.Drawing); the android-swarm `qa.ps1 ui shotmark` uses it. Elsewhere: browser.mjs `mark()` before `shot()`.
Needed when: `skills/android-swarm/swarm.ps1` exists, `devices.type` = `android`, `repos.*.deploys.*.laneApk` = `*`, or listed in kit.local.json `extras`
- Wiring: `skills/qa-kit/adapters/annotate.ps1` defines `Invoke-Annotate` (qa.ps1 loads adapters/). Tests: `tests.ps1` here.

