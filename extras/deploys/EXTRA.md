# deploys

`orch.ps1 deploy plan | request | record | intest`: the deploy batch (orchestrate E5: a person says `deploy <env>`; merged-not-deployed MRs per test env, `deploy.trigger` owner / ask, `deploy.minIntervalHours`), recorded deploys, promoted tasks -> inTest once live; supervise -AutoFix moves live tasks to inTest and caches the plan (DEPLOY ASK).
Needed when: `repos.*.deploys` = `*` (a repo deploys to a test env), or listed in kit.local.json `extras`.
Wiring: `skills/orchestrate/adapters/deploys.ps1`, dot-sourced by orch.ps1 (verb `deploy`; `Get-KitSuperviseFlagsDeploys`); `deploy merge` is the extra deploy-merge; uses `qa.ps1 deployed` and `kit.local.json` `repos[].deploys`, `productTargets`, `trackerLists`.
