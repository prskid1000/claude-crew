# container-tests
- What: before JVM tests that need a container engine (Testcontainers: a `*IT` / `*ContainerTest` name, or `-AllTests` with
  testcontainers in the build file), `dev.ps1 check -Step test` asks `docker info` / `podman info`; none answers -> exit 4 with how
  to start one, instead of minutes of tests failing like a code bug.
Needed when: `pom.xml` in a repo, `build.gradle` in a repo, `build.gradle.kts` in a repo
- Wiring: `skills/dev-kit/adapters/container_tests.ps1` defines `Test-DockerForContainerTests` (lib.ps1 loads adapters/*.ps1);
  Invoke-Check calls it for a maven / gradle test step when it is defined. Tests: `tests.ps1` here.

