# deployed-checks
- What: `qa.ps1 deployed -Mrs <repo>!<iid>,... [-Target] [-Detail] [-Json]`: is a merged MR live on a test env (`repos[].deploys`):
  the CI deploy job on its branch, a squash-merged deploy MR or the same content; kinds `ssh` (host checkout + installed files
  compared), `awsStack`, `probe` (URL / command + `probeField` / `probeRegex`), `tag`, `manual`; `laneApk`: extra android-swarm.
Needed when: `repos.*.deploys` = `*`
- Wiring: `skills/qa-kit/adapters/deployed_checks.ps1` defines `Invoke-Deployed` and `Test-DeployedExtra` (qa.ps1 loads adapters/);
  the extra deploys (orch.ps1 deploy) calls `qa.ps1 deployed`. Tests: `tests.ps1` here.

