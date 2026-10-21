# track-rebuild

`orch.ps1 track -Rebuild [-Force] [-Detail]`: recreates `.state/tracking.json` from MRs tagged with the tracker tag (updated in the last 14 days).
Needed when: the tracking state was lost; uses `trackerRepos`, `tracker.branchTag`, `gitlabGroup`.
Wiring: `skills/orchestrate/adapters/track_rebuild.ps1`, dot-sourced by orch.ps1, runs inside `Invoke-Track` (its helpers: Load, Save, ProjPath, TaskStatus).
