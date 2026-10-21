# deploy-merge
What: `orch.ps1 deploy merge -Repo <checkout> -To <target|branch> [-From] [-Check <dir>] [-Push]`: merges the main line into a
deploy branch in a worktree (known add/add conflicts resolved to the main line), or tags it when `deploys[].tag` is set.
Config: `repos[].deploys[]` (`target`, `branch`, `tag`). Wiring: `skills/orchestrate/adapters/deploy_merge.ps1`, dot-sourced
by orch.ps1. Test: `pwsh -File extras/deploy-merge/test.ps1 <kit>`.
