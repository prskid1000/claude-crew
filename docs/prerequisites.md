# Prerequisites

Required:
- **Windows 10/11, Linux or macOS.** OS specifics (RAM, processes, directory links, temp folder, SDK paths) live in one
  helper, `skills/dev-kit/scripts/sysinfo.ps1`: CIM and junctions on Windows, `/proc/meminfo`, `ps` and symlinks on Linux,
  `sysctl`/`vm_stat`, `ps` and symlinks on macOS.
- **PowerShell 7+** (`pwsh` on `PATH`) for the scripts and the hooks, on every OS.
- **Claude Code** with subagents and workflows (the Workflow tool / workflow slash commands).
- **git**, **Node.js 18+**, **Python 3.10+** on the `PATH` (`python` on Windows, `python3` on Linux/macOS).
- The build tools of your stacks (JDK + Maven/Gradle, .NET SDK, Node package manager, Python venvs, Go, Rust, ...).

Optional, per feature:

| Feature | Needs |
|---|---|
| MRs / PRs, merge-when-green, tracker automation | `glab` (GitLab, incl. self-hosted) or `gh` (GitHub), logged in |
| Tracker statuses, comments, bug tasks | one of, set by `tracker.type` in `kit.local.json`: **`clickup`** (default; `clickup` CLI), **`github`** (`gh`, issues with `status:` labels), **`gitlab`** (`glab`, issues), **`jira`** (Cloud REST: `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) or **`none`** (no tracker; calls are logged locally). Status names map through `tracker.statuses` |
| Publishing tester guides and QA reports | `reports.type`: **`gdocs`** (Google Workspace CLI `gws`, logged in: Drive evidence + Google Doc) or **`markdown`** (no extra tool: `report.md` in the QA run folder, posted/attached on the task). Default: `gdocs` when `gws` is on PATH, else `markdown` |
| Web QA | Chrome, Edge or Chromium in its usual install folder or on `PATH` (or set `CHROME_PATH`), `npm install` in `skills/qa-kit/scripts/web` |
| Android QA | Android SDK (platform-tools, emulator, an x86_64 system image; arm64 on Apple silicon), hardware acceleration (KVM on Linux), **JDK 17 or 21** for app builds |
| Plenty of RAM | the gate makes any size work, but more RAM = more agents and phones at once (each emulator ~4.5 GB) |
