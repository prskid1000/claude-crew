# Skills

- **dev-kit** — rules for parallel dev agents plus tools:
  `stack.ps1` (detects Maven, Gradle/Android, .NET SDK/MSBuild, Angular, Node/React/Next/React Native, Python, Go, Rust,
  CMake, Make), `check.ps1` (compile + typecheck + lint / targeted tests / Liquibase checks, incremental `tsc`, through the
  gate), `gate.ps1` (memory gate: fair queue per owner, learned per-project peaks, dynamic heap caps, backfilling),
  `wt.ps1` (worktrees with linked `node_modules`/`.venv` (junctions on Windows, symlinks elsewhere), rebase, hook-safe
  commits, safe removal), `guard.ps1` (PreToolUse guard), `tracker.ps1` (one issue-tracker adapter: ClickUp, GitHub issues,
  GitLab issues, Jira or none; `-DryRun`), `devtools.py` (MR/PR create, merge-when-green on GitLab/GitHub, tracker
  comments/statuses, tester-guide publishing as a Google Doc or file), `pipe-wait.ps1` (waits for MR pipelines; JSON with
  the failed job and error tail), `lbcheck.py` (Liquibase replay: duplicate columns/tables, missing rollbacks, empty
  rollbacks on changeSets marked irreversible), `keepboth.py` (append-only conflict resolver), `kitconfig.ps1`,
  `kitpaths.*` (the one map of runtime and local-state paths).
- **orchestrate** — the coordinator playbook and templates (wave / bug-fix / resume briefs, MR body, task solution), plus
  `supervise.ps1` (heartbeat with ACT/WATCH flags and `-AutoFix`), `board.ps1` (agent board), `track.ps1` (moves tracker
  tasks when all MRs merge; ordered merges), `bug-brief.ps1` (QA bug task → bug-fix brief + tracking + ready /dev-wave args,
  with a model suggestion), `wave-report.ps1` (journal-based wave summary), `status.ps1` (HTML dashboard),
  `cleanup.ps1` (self-cleaning), `learn.ps1` and `retro-nudge.ps1` (self-improvement), `kit-lint.py` (the kit's structure
  check) and `kit-flow.py` (the trigger-flow page; both use `kitgraph_lib.py`), `kit-health.ps1` (SessionStart line: kit git
  state + lint), `kit-setup.ps1` (install: pre-push gate, local-only excludes, migration).
- **qa-kit** — QA rules (verdicts, shared-environment etiquette), the evidence standard, a tester-guide template, and
  tools: `api.ps1` (any API as any configured user; evidence envelopes with secrets redacted), `web/browser.mjs`
  (long-lived logged-in headless Chrome sessions via puppeteer-core, shared logins, failure capture, element highlighting),
  `android/ui.ps1` (uiautomator-based tap/type/dump/shot/shotmark/wait/log/photo), `annotate.ps1` (box / arrow / label on
  any screenshot), `finalize.ps1` + `lib/report.ps1` (styled results report → Google Doc or Markdown, tracker comments, bug
  tasks), `autoclose.ps1` (safety net), `qa-seat.ps1` (memory seats + item claims: QA concurrency follows free RAM, extra
  worker runs never test the same item).
- **android-swarm** — parallel emulators for any APK (React Native or native): `phone.ps1` leases, `app-build.ps1`
  (through the gate, from the latest merged branch), `swarm-up/-down/-slim/-arrange`, `app-mode`/`app-launch` (Release or
  Metro), `swarm-avd.ps1` (create all lanes from one template; reset cold/snapshots/wipe/recreate).
- **tech-audit** — static audit of one module for bugs, performance and tech debt with strict false-positive discipline;
  fixed 23-key findings schema, validator and styled summary.
