---
name: dev-kit
description: Rules and scripts for a dev agent working in parallel with others on any stack (Java/Maven, Gradle, Kotlin/Android, React Native, Angular/React/Node, .NET, Python, Go, Rust) — worktrees with linked deps, stack-detected build/test through a machine-wide memory gate, hook-safe commits, DB migration rules (Liquibase/EF/Flyway/Alembic), MR create + merge-when-green, issue tracker (ClickUp / GitHub / GitLab / Jira / none via tracker.ps1). Use when implementing and shipping code in a worktree, or whenever building/testing a repo in this workspace.
---

# Quick start (every parallel dev agent reads this)

You're one of several agents working at once; each owns one area of the code — stay inside yours. Your **brief**
(orchestrate/templates WAVE_BRIEF / BUGFIX_BRIEF / RESUME_BRIEF) gives your items, area, repos + target branches, branch,
worktree name, migration range and tracker task; it wins over this file. The repo's own `CLAUDE.md` / conventions also apply.
Scripts: `<workspace>/.claude/skills/dev-kit/scripts` (`$K`), PowerShell (Linux/macOS: `pwsh`; `python` hangs in git-bash, use
`python3` off Windows). Org settings come from `kit.local.json` next to this file.

```powershell
$K = '<workspace>/.claude/skills/dev-kit/scripts'; $B = '<workspace>/.claude/skills/orchestrate/scripts/board.ps1'
& $B join -Agent <id> -Run <wave> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md   # 0. board (keep the SESSION token)
& $K/wt.ps1 new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>   # 1. worktree (deps linked)
& $K/wt.ps1 sync -Dir <wt>                                       # 2. rebase onto latest target - before editing
& $K/stack.ps1 -Dir <wt>/<module>                                # 3. this module's build/test commands
& $K/check.ps1 -Dir <wt>/<module>                                # 4. compile + typecheck + lint (gated)
& $K/check.ps1 -Dir <wt>/<module> -Step test -Tests "<names>"    #    targeted tests only
& $K/check.ps1 -Dir <wt>/<module> -Step migrations               #    if you touched DB migrations (must print ISSUES 0)
& $K/wt.ps1 commit -Dir <wt> -Message "feat(scope): ..."         # 5. commit with hooks really running
& $K/wt.ps1 sync -Dir <wt>; & $K/check.ps1 -Dir <wt>/<module>    # 6. rebase + re-check before push
git -C <wt> push -u origin <branch>
python $K/devtools.py mr <wt> "<title>" body.md                  # 7. MR/PR (GitLab or GitHub, from the remote)
python $K/devtools.py merge <wt> <iid>                           # 8. merge-when-green, returns at once (NOT in a reviewed /dev-wave)
& <workspace>/.claude/skills/orchestrate/scripts/track.ps1 add -Task <task id> -Mrs <repo>!<iid>,...   # 8b. coordinator promotes when all merge
& $B leave -Session <token> -Status done                         # 9. leave the board
```

**Rules**
- **Board:** `join` first (DUPLICATE for your id → stop without writing); `beat -Session <t> -Status "<doing>"` before builds and pushes;
  `check -Worktree <wt> -Session <t>` before each commit (another writer → stop, tell the coordinator); `leave` at the end.
- **Worktrees:** one per repo via `wt.ps1 new`; deps-differ warning → `-LinkFrom <checkout of the target branch>`; never install into a
  linked `node_modules`/`.venv` (say what you need instead); remove with `wt.ps1 remove`. `wt.ps1 sync` before editing, before every push, before merging.
- **Gate:** every build/test through `check.ps1` (or `gate.ps1 -Cmd "<cmd>"`), never Maven/Gradle/dotnet/ng/jest/pytest/cargo directly;
  waiting is normal, a killed build is not a code failure (re-run). Targeted tests only. No dev servers, no emulators, ≤ 1 headless browser.
- **Commits:** Conventional Commits ending with a blank line + `Co-Authored-By: Claude <noreply@anthropic.com>`; `wt.ps1 commit` only;
  never `--no-verify`, never type a hook's marker, never change shared git config, never `git stash` (WIP commit instead).
- **Scope:** only your items, no sweeps of similar code, never remove features or inputs; changes are additive (optional fields, new
  endpoints/params, flags); DTOs not entities in APIs; foreign files only as one-line hooks you list in your reply; decisions in the brief are final (new decision needed → defer with a reason).
- **Migrations:** only your assigned range; never edit a merged migration. Per-tool rules (Liquibase/EF/Flyway/Alembic/Django): `reference/migrations.md` — read before touching one.
- **Ship:** re-read `<brief>.contracts.md` before pushing (append-only if you write to it, never overwrite); one MR per repo, title
  `feat: <summary> - <CODE> (<tag><task>) (<Repo>)`, body from `orchestrate/templates/MR_BODY.md`; in a reviewed `/dev-wave` don't
  schedule merges (the workflow does after review); producers (DB/API) merge before consumers; force-push only your own branch (`--force-with-lease`).
- **Tracker:** always `scripts/tracker.ps1` (never a tracker CLI): `inProgress` → `review` once MRs are open and the guide posted → `promoted` when all merged; never `inTest`.
- **Evidence:** UI → screenshots, backend → `qa-kit/scripts/api.ps1 -Save` JSON; never production; a 404/405 on an endpoint that exists on the target branch = stale deploy, not a code bug.

**Final reply (≤ 200 words):** MRs + merge state · done / deferred ids with reasons · settings/data to seed · what needs a live check ·
hooks left in other areas · dependencies you needed but didn't install.

**Learn:** read `LESSONS.md` (next to this file) first. Something cost time, failed or worked unusually well → one line:
`& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill dev-kit -Kind <kind> -Text "<what + fix>"`. The guard hook blocks
`git stash`, `--no-verify`, force-pushes to shared branches and ungated heavy builds — its message names the right command.

## Reference (read only when you need it)
- `reference/worktrees-and-gate.md` — worktree links, board warnings, rebase points, gate behaviour (≥ 12 GB rule), commits in detail: when a warning or gate wait puzzles you.
- `reference/migrations.md` — Liquibase / EF Core / Flyway / Alembic / Django rules: before adding or changing a migration.
- `reference/shipping.md` — scope, evidence, tester guide, MR title/body, contracts, merge order, conflicts, `deploy-merge.ps1`: when you open MRs or write the guide.
- `reference/tracker.md` — tracker statuses and every `tracker.ps1` command (view/comments/status/comment/create/attach): when you touch the task.
