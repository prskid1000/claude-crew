# deploy-merge

`orch.ps1 deploy merge -Repo <checkout> -To <target|branch> [-From] [-Check <dir>] [-Push]`: merges the main line into a deploy branch in a worktree (add/add conflicts with older main-line versions resolved to the main line), or tags it when `deploys[].tag` is set.
Needed when: a test env deploys from its own branch (`repos[].deploys[].branch`) or a tag (`repos[].deploys[].tag`) and the kit should merge or tag it (not an MR to that branch).
Wiring: `skills/orchestrate/adapters/deploy_merge.ps1`, dot-sourced by orch.ps1 (`deploy merge` stops with the extra line without it).
