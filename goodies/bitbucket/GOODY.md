# bitbucket
- What: Bitbucket Cloud git host (REST 2.0; merge-when-green emulated by bossy.ps1 track run) and Bitbucket Pipelines CI.
- Config: `gitHostType: "bitbucket"` (or a bitbucket.org origin), `repos[].ci` / `ci.type: "bitbucket"`; env `BITBUCKET_TOKEN` (`user:app-password` = basic).
Needed when: `ci.type` = `bitbucket`, `gitHostType` = `bitbucket`, `repos.*.ci` = `bitbucket`
- Wiring: `skills/crafty/adapters/bitbucket.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
