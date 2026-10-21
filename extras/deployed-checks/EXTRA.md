# deployed-checks
- What: `qa.ps1 deployed` kinds `ssh` (host checkout + installed files compared), `awsStack`, `probe` (URL / command +
  `probeField` / `probeRegex`), `tag`, `manual`.
Needed when: `repos.*.deploys.*.ssh` = `*`, `repos.*.deploys.*.awsStack` = `*`, `repos.*.deploys.*.probe` = `*`, `repos.*.deploys.*.tag` = `*`, `repos.*.deploys.*.manual` = `true`
- Wiring: `skills/qa-kit/adapters/deployed_checks.ps1` defines `Test-DeployedExtra`, called inside `Invoke-Deployed`.
