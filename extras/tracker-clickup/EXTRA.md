# tracker-clickup
- What: ClickUp as the kit tracker through the `clickup` CLI (view, status, comment, comments, create with assignee lookup,
  describe, rename, attach, list, owner).
- Config: `tracker.type: "clickup"`, `tracker.list` = the list id of new tasks, `tracker.statuses` = the list's status names,
  `tracker.branchTag` (default `CU-`).
Needed when: `tracker.type` = `clickup`
- Wiring: `skills/dev-kit/adapters/tracker_clickup.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved
  (Register-KitAdapter). Tests: `tests.ps1` here.
