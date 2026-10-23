# track-rebuild

`bossy.ps1 track -Rebuild [-Force] [-Detail]`: recreates `.state/tracking.json` from MRs tagged with the tracker tag (updated in the last 14 days).
Needed when: the tracking state was lost; uses `trackerRepos`, `tracker.branchTag`, `gitlabGroup`.
Wiring: `skills/bossy/adapters/track_rebuild.ps1`, dot-sourced by bossy.ps1, runs inside `Invoke-Track` (its helpers: Load, Save, ProjPath, TaskStatus).
