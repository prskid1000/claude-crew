# ci-jenkins
- What: Jenkins as the CI of a repo (multibranch job; run id = <branch>#<build>).
- Config: `repos[].ci` / `ci.type: "jenkins"`, `ci.url`, `ci.job` (default `job/{repo}`), `ci.tokenEnv` (default `JENKINS_TOKEN`, "user:api-token").
Needed when: `ci.type` = `jenkins`, `repos.*.ci` = `jenkins`
- Wiring: `skills/crafty/adapters/ci_jenkins.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
