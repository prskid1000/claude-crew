# gitea
- What: Gitea / Forgejo git host (REST v1) and Gitea Actions CI (no job log API: the log is the run link).
- Config: `gitHostType: "gitea"` (or a gitea / forgejo / codeberg origin), `gitHostApi.url`; env `GITEA_TOKEN`.
Needed when: `ci.type` = `gitea`, `gitHostType` = `gitea`, `repos.*.ci` = `gitea`
- Wiring: `skills/crafty/adapters/gitea.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
