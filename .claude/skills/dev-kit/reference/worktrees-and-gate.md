# Worktrees, agent board and the memory gate (dev-kit reference)

Full rules behind the Quick start in `../SKILL.md`. Read when a worktree/link warning, a board warning or a gate wait/kill puzzles you.

## Setup and platforms
You're one of several agents working at the same time, on any stack (Java, Kotlin/Android, React Native,
Angular/React/Node, .NET, Python, Go, ...). Each agent owns one area of the code; stay inside yours.

Your **brief** (from `<workspace>/.claude/skills/orchestrate/templates/` WAVE_BRIEF / BUGFIX_BRIEF / RESUME_BRIEF) gives you: your items, your area,
the repos with their target branches, your branch, your worktree name, your migration range and your tracker task.
Where the brief differs from this file, the brief wins. The repo's own `CLAUDE.md` / README conventions also apply.

All scripts below are PowerShell, in `<workspace>/.claude/skills/dev-kit/scripts` (call it `$K`). Run them from PowerShell:
node, python, glab and gh (plus gws / the tracker CLI when configured) are on the PowerShell PATH, and `python` hangs in git-bash.
Linux/macOS: the same scripts run with `pwsh` (from Bash: `pwsh -NoProfile -Command "& <script>.ps1 ..."`); use `python3`.
Forward-slash paths work everywhere; OS specifics (RAM, processes, links, temp) live in `scripts/sysinfo.ps1`.
`<workspace>` = the folder that holds `.claude` (the scripts work it out themselves). Org settings (git host/group, where repos and
worktrees live, protected branches) come from `kit.local.json` next to this file (copy `kit.example.json`).

## 1. Worktrees and dependencies
- **One worktree per repo**, via `wt.ps1 new`. It branches from `origin/<target>`, records the target, links
  installed `node_modules` / `.venv` from the main checkout as junctions (Windows) or symlinks (Linux/macOS; also added to `.git/info/exclude`) and copies missing `.husky/_`.
- **If it warns that dependencies differ,** the source checkout is on another branch with other versions: pass
  `-LinkFrom <a checkout of the target branch>` (the brief names one if there is a known good source).
- **Never install into a linked folder** (`npm/yarn/pnpm install`, `pip install`): it writes into the source checkout.
  If you really need a new dependency, say so in your final reply instead.
- **Remove** with `wt.ps1 remove -Dir <wt>` (unlinks the junctions/symlinks first, never deletes through them).

## 1b. The agent board (other agents and workflows run at the same time)
- `board.ps1 join` first: keep the SESSION token it prints. It lists the other active agents and their areas, and warns on
  DUPLICATE (your agent id is active in another session → the newer one stops without writing), CLAIM (someone else holds your
  worktree) and AREA (overlapping items). Then `board.ps1 beat -Session <token> -Status "<what you're doing>"` before each build and
  push, `board.ps1 check -Worktree <wt> -Session <token>` before each commit (exit 1 = another writer → stop, tell the coordinator),
  and `board.ps1 leave` at the end. The memory gate gives fair turns per agent: don't hammer it with back-to-back builds you don't need.

## 2. Always work on the latest code
`wt.ps1 sync` at three points: before you start editing, before every push, and right before merging.
Other agents merge all the time; a stale base means avoidable conflicts.

## 3. Builds and tests go through the memory gate
- **Use `check.ps1`** (or `gate.ps1 -Cmd "<cmd>"` for anything it doesn't cover). Never run Maven, Gradle, dotnet/msbuild,
  ng/tsc/jest/vitest, cargo, pytest suites or e2e runners directly: six parallel builds once took the machine to 100% RAM.
- The gate starts a build only when it leaves ≥ 12 GB free after every running build's estimate. Waiting is normal.
  A build that gets killed is not a code failure: run it again.
- **Targeted tests only** (`-Tests`). Full suites, `mvn install`, `-T`, parallel workers are off unless the brief says so.
- **No long-running processes**: no dev servers, no emulators (the QA swarm owns them), at most one headless browser.
  Kill only the processes you started.

## 4. Commits
- Conventional Commits: `feat(scope): …`, `fix(scope): …`, `refactor(scope): …`. End with a blank line and
  `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Hooks must actually run**: commit with `wt.ps1 commit` (it fixes `core.hooksPath` for worktrees). Never `--no-verify`,
  never type a hook's marker (e.g. `✅Pre-Commit`) yourself, never change shared git config.
- **Never `git stash`**: the stash is shared across worktrees. Use a WIP commit.
