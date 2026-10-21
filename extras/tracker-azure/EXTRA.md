# tracker-azure
- What: Azure Boards work items (REST 7.1) as the kit tracker; list = area path; HTML texts.
- Config: `tracker.type: "azure"`, `tracker.org`, `tracker.project`, `issueType`; env `AZURE_DEVOPS_EXT_PAT`.
Needed when: `tracker.type` = `azure`
- Wiring: `skills/dev-kit/adapters/tracker_azure.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
