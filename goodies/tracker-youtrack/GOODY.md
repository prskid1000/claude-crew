# tracker-youtrack
- What: YouTrack (REST /api) as the kit tracker; fields State / Assignee, changes by commands; list = project short name.
- Config: `tracker.type: "youtrack"`; env `YOUTRACK_URL` + `YOUTRACK_TOKEN`.
Needed when: `tracker.type` = `youtrack`
- Wiring: `skills/crafty/adapters/tracker_youtrack.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
