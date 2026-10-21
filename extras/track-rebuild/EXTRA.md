# track-rebuild
What: `orch.ps1 track -Rebuild [-Force] [-Detail]`: recreates `.state/tracking.json` from MRs tagged with the tracker tag
(updated in the last 14 days) after the state was lost.
Config: `trackerRepos`, `tracker.branchTag`, `gitlabGroup`. Wiring: `skills/orchestrate/adapters/track_rebuild.ps1`,
dot-sourced by orch.ps1, run inside `Invoke-Track` (its helpers). Test: `pwsh -File extras/track-rebuild/test.ps1 <kit>`.
