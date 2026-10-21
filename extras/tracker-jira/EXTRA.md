# tracker-jira
- What: Jira Cloud (REST v3, ADF texts) and Jira Server / Data Center (REST v2) as the kit tracker.
- Config: `tracker.type: "jira"` or `"jira-server"`, `tracker.list` = project key, `issueType` / `subtaskType`; env `JIRA_BASE_URL` + `JIRA_EMAIL` + `JIRA_API_TOKEN` (server: or `JIRA_TOKEN`).
Needed when: `tracker.type` = `jira` | `jira-server`
- Wiring: `skills/dev-kit/adapters/tracker_jira.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved (Register-KitAdapter). Tests: `tests.ps1` here.
