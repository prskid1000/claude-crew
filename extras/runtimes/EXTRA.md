# runtimes
- What: leases on machine runtimes agents start (a container engine, a WSL distro, a VM): `dev.ps1 runtime use|release|status
  -Name <runtime> [-Agent] [-Session]`; the kit stops a runtime it started once no live lease is left, never one it did not start.
Needed when: `runtimes` = `*`
- Config `runtimes.<name>`: `isUp` (running = exit 0 + some output), `up` (optional; unset: the agent's command starts it),
  `down`, `match` (regex, tested on each command segment); lines run in `pwsh -Command`. Example: `{ "docker": { "isUp":
  "docker info", "up": "docker desktop start", "down": "docker desktop stop", "match": "^docker\\s+(?!info|version|desktop)" } }`.
- Wiring: `skills/dev-kit/adapters/runtimes.ps1` (lib.ps1 loads it): `Invoke-Runtime` (dev.ps1 verb), a dev.ps1 guard rule (a
  matching command without a lease -> an auto lease, a note to release), `Get-KitSuperviseGuardRuntimes` (orch.ps1 supervise:
  a dead lease -> released after idle.graceMinutes, kit-started + no lease -> down). Tests: `tests.ps1` here.
