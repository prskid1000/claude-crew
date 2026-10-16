# Multi-agent work, builds and testing (all repos in this workspace)

`<kit>` = the `.claude` folder of the workspace (the directory Claude Code was started in); kit scripts find it themselves.
**What to load or launch:** the Router in `AGENTS.md` (first matching row wins; workflows launch autonomously; a deploy
starts only when a person says `deploy <env>`: nobody asks or proposes one). These rules hold whatever the route:

- Builds and tests go through `<kit>/skills/dev-kit/dev.ps1 check` (stack auto-detected; the machine-wide memory gate queues
  them; the guard hook blocks ungated builds). Targeted tests plus the tests of touched files (`-Touched`).
- Parallel work happens in worktrees (`dev.ps1 wt`); commit with `dev.ps1 wt commit` (hooks run). Never `git stash`, never
  `--no-verify`, never install packages into linked `node_modules` / `.venv`.
- Rebase onto the latest target before editing, before pushing and before merging; merge only on a green pipeline, producers
  (DB / API / library) before consumers (web / app / clients).
- Commit WIP on your branch after each dev-flow step (`dev.ps1 wt commit -Message "chore(wip): <step>"`): a crash or restart
  loses no edits.
- Every change is tested on the LOCAL env before merge (reproduce bugs there first); deployed changes are tested on test
  environments only (logins in `skills/qa-kit/targets.local.json`), never production. Defects are FAIL, never notes.
- Phones only through `android-swarm/swarm.ps1 acquire` (never boot or kill emulators by hand, never `adb kill-server`).
- Browsers are headless by default (`qa-kit/browser.mjs`); a visible browser only when the owner asks to watch.
- Run python and node from the PowerShell tool (pwsh 7), not Git Bash; Python with `-X utf8`.
- Runtime output goes to `<kit>/.runtime/` (disposable) and durable state to `<kit>/.state/`, both git-ignored and resolved by
  name (`Get-KitPath`); never elsewhere in the kit.
- The kit learns: every agent reads its lessons at step 0 (`orch.ps1 learn -Read -Skill <skill>`) and records surprises with
  `orch.ps1 learn`. A business-logic change the task did not ask for, or several valid paths -> `orch.ps1 decide ask`.
- **The main session coordinating agents** loads `orchestrate` and follows its Events table (heartbeat, decisions, `deploy <env>`,
  recovery after a restart, HEAL, LEARN, retro, kit commits).
