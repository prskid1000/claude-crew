# supervise-resources
- What: the machine's shared resources in `orch.ps1`: supervise checks the build gate (no live holder, queue waits, 3 failed builds,
  `gate.cacheFlush`), phone leases, QA seats and orphan browsers, and lists their RAM; `board show` / `recover` list seats and leases;
  `cleanup` stops idle test browsers and Gradle / Kotlin daemons and removes idle browser profiles (`cleanup.maxBrowserProfiles`).
Needed when: `skills/dev-kit/kit.local.json` exists, `gate` = `*`, `localEnv.envs` = `*`, `devices` = `*`, or `skills/qa-kit/node_modules/puppeteer-core` exists
- Wiring: `skills/orchestrate/adapters/supervise_resources.ps1`, dot-sourced by orch.ps1: `Get-KitSuperviseGuardResources`,
  `Get-KitBoardLinesResources`, `Get-KitRecoverLinesResources`, `Invoke-KitCleanupResources`; without it supervise keeps RAM %, disk, guard.
