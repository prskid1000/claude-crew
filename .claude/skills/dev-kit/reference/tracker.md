# Tracker (dev-kit reference)

Read when you change a task status, comment, create a subtask or attach a file.

## 9. Tracker
The backend (ClickUp, GitHub issues, GitLab issues, Jira or none) is set once in kit.local.json `tracker.type`; you always use
**`scripts/tracker.ps1`** (or the `devtools.py` task commands, which call it) — never a tracker CLI directly.
- `inProgress` at start → `review` once the MRs are open and the guide is posted (`devtools.py finish`) →
  `promoted` once **all** your MRs are merged. **Never set `inTest`**: that happens after deployment.
  Use these logical names; `tracker.statuses` maps them to the board's own names.
- Don't change other people's tasks, or tasks already in a testing status.
- New tasks go under the epic named in the brief, assigned to the requester.
- **Commands** (`$TR = '<workspace>/.claude/skills/dev-kit/scripts/tracker.ps1'`):
  - read: `& $TR view <id>` (JSON incl. subtasks, description) · `& $TR comments <id>`
  - status: `& $TR status <id> review` — the coordinator's track.ps1 only promotes a task that is already in review, so set it.
  - comment: `& $TR comment <id> <file.md>` (a file for long or multi-line text; plain text works for one line).
  - subtask: `& $TR create -List <list> -Parent <id> -Name "<name>" -Description <file.md>` (prints `{ id, url }`).
  - file (guide, report): `& $TR attach <id> <file> -Text "<comment>"`. Add `-DryRun` to see the call without making it.
- **Claude Code's built-in "Remove-Item on system path … is blocked"** sometimes fires on PowerShell commands that contain
  escaped quotes such as `"\"X\""`, even with no delete. Put that text in a file (or a `.ps1` script) and pass it from there.
