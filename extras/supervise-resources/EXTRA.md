# supervise-resources
- What: the machine's shared resources in `orch.ps1`: supervise checks the build gate (holders with no live holder, queue waits,
  3 failed builds in a row, `gate.cacheFlush`), phone leases, QA seats and claims of gone sessions, orphan test browsers, and
  lists browsers, phones and builds with their RAM in the round report; `board show` lists QA seats and env leases, `recover`
  env and phone leases with no live holder; `cleanup` stops test browsers with no tab holder, idle Gradle / Kotlin daemons,
  and removes idle or surplus browser profiles (`cleanup.maxBrowserProfiles`).
Needed when: `gate` = `*`, `localEnv.envs` = `*`, `devices` = `*`, or `skills/qa-kit/node_modules/puppeteer-core` exists
- Wiring: `skills/orchestrate/adapters/supervise_resources.ps1`, dot-sourced by orch.ps1: `Get-KitSuperviseFlagsResources`,
  `Get-KitBoardLinesResources`, `Get-KitRecoverLinesResources`, `Invoke-KitCleanupResources`. Without it supervise keeps RAM %,
  disk and guard checks; the gate itself (`dev.ps1 check`) is core.
