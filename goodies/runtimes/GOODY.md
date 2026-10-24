# runtimes
- What: leases on machine runtimes agents start (a container engine, a WSL distro, a VM): `crafty.ps1 runtime use|release|status
  -Name <runtime> [-Agent] [-Session]`; the kit stops a runtime it started once no live lease is left, never one it did not start.
  Before JVM tests that need a container engine (Testcontainers: a `*IT` / `*ContainerTest` name, or `-AllTests` with
  testcontainers in the build file), `crafty.ps1 check -Step test` leases a configured `runtimes.docker` (started when down), else asks
  `docker info` / `podman info`; none answers -> exit 4 with how to start one, instead of minutes of tests failing like a code bug.
Needed when: `runtimes` = `*`, `pom.xml` in a repo, `build.gradle` in a repo, `build.gradle.kts` in a repo
- Config `runtimes.<name>`: `isUp` (running = exit 0 + some output), `up` (optional; unset: the agent's command starts it),
  `down`, `match` (regex, tested at the head of each command segment, never mid-text or in quoted data); lines run in `pwsh -Command`. Example: `{ "docker": { "isUp":
  "docker info", "up": "docker desktop start", "down": "docker desktop stop", "match": "(?:\\S*[\\\\/])?(?:docker(?:-compose)?(?:\\.exe)?\\s+(?!\\s|info|version|desktop)|(?:mvnw?|gradlew?)\\b.*(?:-Dtest=|--tests\\s+)\\S*IT\\b)" } }`.
- Wiring: `skills/crafty/adapters/runtimes.ps1` (lib.ps1 loads it): `Invoke-Runtime` (crafty.ps1 verb), a crafty.ps1 guard rule (a
  matching command without a lease -> an auto lease, a note to release), `Get-KitSuperviseGuardRuntimes` (bossy.ps1 supervise:
  a dead lease -> released after idle.graceMinutes, kit-started + no lease -> down); `container_tests.ps1`
  (`Test-DockerForContainerTests`, called by Invoke-Check for a maven / gradle test step). Tests: `tests.ps1` (runs `tests-*.ps1` too).
