# tracker-linear
- What: Linear (GraphQL) as the kit tracker; ids = identifiers (ENG-12), list = team key, status = workflow state name.
- Config: `tracker.type: "linear"`, `tracker.org`, `tracker.list`; env `LINEAR_API_KEY`.
Needed when: `tracker.type` = `linear`
- Wiring: `skills/dev-kit/adapters/tracker_linear.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
