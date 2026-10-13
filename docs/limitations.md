# Limitations

- **A few Windows-only extras.** Everything runs on Windows, Linux and macOS with PowerShell 7, except: `annotate.ps1`
  (System.Drawing is Windows-only in .NET; mark elements with `browser.mjs` `mark()` instead), `swarm-arrange.ps1`
  (Win32 window placement; it skips with a note), and the .NET Framework stack (`msbuild`/`vstest.console.exe` for
  non-SDK projects). Linux and macOS were tested less than Windows.
- **GitLab-first tracker automation.** MR creation, auto-merge, the CI wait (`pipe-wait.ps1`) and `wave-report.ps1` merge
  checks work on GitLab and GitHub, but `track.ps1` (ordered merges, tracker moves), `deployed.ps1` and the supervisor's
  MR-owner lookup speak GitLab (`glab`). Issue trackers are pluggable (ClickUp, GitHub, GitLab, Jira, none); Jira support
  targets Jira Cloud REST v3 with plain-text descriptions, and GitHub/GitLab have no task attachments (reports are posted
  as comment text).
- **Workflow scripts can't read the filesystem**, so pass `kitDir` (absolute) to workflows; without it, agents get
  workspace-relative paths.
- Supervision reads Claude Code's local session journals (`~/.claude/projects/<workspace slug>/.../workflows`); if that
  layout changes, `supervise.ps1` and `wave-report.ps1` need updating.
- The memory gate coordinates only the processes started through it (plus the emulators); other heavy apps are just
  "less available RAM".
