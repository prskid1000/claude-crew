# os-timer
- What: the OS heartbeat (owner, 2026-11-14: the sweep stopped with every session restart, pause or missed re-arm). One OS task
  per kit folder runs `bossy.ps1 heartbeat tick` every `supervise.heartbeatMinutes`: `supervise -AutoFix -Brief` as session
  `os-timer` in a child pwsh, so the page, auto-fixes and flags stay fresh with no session open. Never a model call; a kit
  paused with `pause -All` skips (result `skipped: paused (<reason>)`). A coordinator session never steps aside for it; it
  steps aside while a session supervises; its sweeps do not count as the coordinator's beat (health OVERDUE) and leave SETTINGS
  lines for the coordinator.
- Verbs: `bossy.ps1 heartbeat install [-Minutes <n>] | uninstall | status | tick`; `status` exits 1 when missing or stale (no
  tick for 2 intervals). State: `<state>/programs/os-timer.json` (installed adapter name minutes at lastTick result).
- Health (SessionStart, hook `Get-KitOsBeatHealth`): never installed -> the install line; ticked within 2 intervals -> quiet;
  task gone -> reinstalled; stale -> one line with the last tick and `heartbeat status`; uninstalled or `osTimer` false -> quiet.
- Adapter `scheduler` (verbs install uninstall status, `adapter:scheduler/<name>` blocks): `windows` (Task Scheduler, this
  user while logged on; `conhost --headless`: no console flash; runs on battery, catches up after sleep, 10 min limit, one
  instance), `cron` and `launchd` (not built yet: install throws the exact crontab line / LaunchAgent to add by hand), `none`.
Needed when: `supervise.osTimer` = `*`, `windows` OS, or listed in kit.local.json `goodies`.
## Config (kit.local.json `supervise.osTimer`)
- unset: health offers the install line · `true`: health keeps it installed · `false`: off (adapter `none`) · a scheduler
  name: that adapter.
- Wiring: `skills/bossy/adapters/os_timer.ps1`, dot-sourced by bossy.ps1 (verb `heartbeat install|uninstall|status|tick`
  through `Assert-KitExtra`; health hook `Get-KitOsBeatHealth`). Tests: `tests.ps1` here.
