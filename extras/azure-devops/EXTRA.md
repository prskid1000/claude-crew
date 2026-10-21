# azure-devops
- What: Azure DevOps Repos git host (REST 7.1, auto-complete = merge-when-green; repo = org/project/repo) and Azure Pipelines CI.
- Config: `gitHostType: "azure"` (or a dev.azure.com origin), `ci.type: "azure"`; env `AZURE_DEVOPS_EXT_PAT`.
Needed when: `ci.type` = `azure`, `gitHostType` = `azure`, `repos.*.ci` = `azure`
- Wiring: `skills/dev-kit/adapters/azure_devops.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
