---
name: dev-kit
description: Rules and scripts for a dev agent working in parallel with others on any stack (Java/Maven, Gradle, Kotlin/Android, React Native, Angular/React/Node, .NET, Python, Go, Rust) — worktrees with linked deps, stack-detected build/test through a machine-wide memory gate, hook-safe commits, DB migration rules (Liquibase/EF/Flyway/Alembic), MR create + merge-when-green, ClickUp. Use when implementing and shipping code in a worktree, or whenever building/testing a repo in this workspace.
---

# Rules for every parallel dev agent (read fully before starting)

You're one of several agents working at the same time, on any stack (Java, Kotlin/Android, React Native,
Angular/React/Node, .NET, Python, Go, ...). Each agent owns one area of the code; stay inside yours.

Your **brief** (from `<workspace>\.claude\skills\orchestrate\templates\` WAVE_BRIEF / BUGFIX_BRIEF / RESUME_BRIEF) gives you: your items, your area,
the repos with their target branches, your branch, your worktree name, your migration range and your tracker task.
Where the brief differs from this file, the brief wins. The repo's own `CLAUDE.md` / README conventions also apply.

All scripts below are PowerShell, in `<workspace>\.claude\skills\dev-kit\scripts` (call it `$K`). Run them from PowerShell:
node, python, gws, clickup, glab and gh are on the PowerShell PATH, and `python` hangs in git-bash.
`<workspace>` = the folder that holds `.claude` (the scripts work it out themselves). Org settings (git host/group, where repos and
worktrees live, protected branches) come from `kit.local.json` next to this file (copy `kit.example.json`).

## The loop, in one screen

```powershell
$K = '<workspace>\.claude\skills\dev-kit\scripts'; $B = '<workspace>\.claude\skills\orchestrate\scripts\board.ps1'
& $B join -Agent <id> -Run <wave> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md   # 0. board: SESSION token + who else is active
& $K\wt.ps1 new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>   # 1. worktree (deps linked)
& $K\wt.ps1 sync -Dir <wt>                                       # 2. rebase onto latest target - before editing
& $K\stack.ps1 -Dir <wt>\<module>                                # 3. see what build/test commands this module uses
#    ... edit ...
& $K\check.ps1 -Dir <wt>\<module>                                # 4. compile + typecheck + lint (gated)
& $K\check.ps1 -Dir <wt>\<module> -Step test -Tests "<names>"    #    targeted tests only
& $K\check.ps1 -Dir <wt>\<module> -Step migrations               #    if you touched DB migrations
& $K\wt.ps1 commit -Dir <wt> -Message "feat(scope): ..."         # 5. commit with hooks really running
& $K\wt.ps1 sync -Dir <wt>; & $K\check.ps1 -Dir <wt>\<module>    # 6. rebase + re-check before push
git -C <wt> push -u origin <branch>
python $K\devtools.py mr <wt> "<title>" body.md                  # 7. MR/PR (GitLab or GitHub, from the remote)
python $K\devtools.py merge <wt> <iid>                           # 8. schedules "merge when pipeline succeeds" and returns at once
& <workspace>\.claude\skills\orchestrate\scripts\track.ps1 add -Task <task id> -Mrs <repo>!<iid>,...   # 8b. the coordinator's heartbeat promotes the task when all merge
& $B leave -Session <token> -Status done                         # 9. leave the board
```

## 1. Worktrees and dependencies
- **One worktree per repo**, via `wt.ps1 new`. It branches from `origin/<target>`, records the target, links
  installed `node_modules` / `.venv` from the main checkout as junctions and copies missing `.husky/_`.
- **If it warns that dependencies differ,** the source checkout is on another branch with other versions: pass
  `-LinkFrom <a checkout of the target branch>` (the brief names one if there is a known good source).
- **Never install into a linked folder** (`npm/yarn/pnpm install`, `pip install`): it writes into the source checkout.
  If you really need a new dependency, say so in your final reply instead.
- **Remove** with `wt.ps1 remove -Dir <wt>` (unlinks the junctions first, never deletes through them).

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

## 5. Scope
- Fix only what your items ask; no sweeps of similar code. Don't remove existing features or inputs.
- Stay in your area. If you must touch someone else's file, keep it to a one-line hook and list it in your final reply.
- Changes are **additive**: optional fields, new endpoints/params, feature flags. Don't change behaviour other
  products/tenants rely on. Don't expose persistence entities in APIs (use DTOs).
- Product decisions in the brief or in memory are final; don't re-ask. If an item needs a new decision, defer it with a reason.
- Follow the repo's own conventions (its `CLAUDE.md`, base classes, lint rules, naming).

## 6. Database migrations (whatever the tool)
- **Use only your assigned range** for ids/timestamps, so parallel agents never collide.
- **Never edit a migration that has already merged**; add a new one.
- **Liquibase**: file `YYYYMMDDHHMMSS_desc.xml` inside your range, first changeSet `tagDatabase`, a `<rollback>` on every
  schema/data changeSet, append the include to `master.xml`. On rebase conflicts in `master.xml`: `python $K\keepboth.py <file>`.
  Before every push: `check.ps1 -Step migrations` must print `ISSUES 0` (no duplicate addColumn/createTable). To replace an
  existing empty table, drop it behind a `preConditions onFail=MARK_RAN` guard with a rollback that recreates it.
- **EF Core**: one migration per agent, named with your range prefix; after a rebase, if the model snapshot conflicts, regenerate your migration on top.
- **Flyway**: `V<your range>__desc.sql`. **Alembic**: after a rebase, re-point your `down_revision` to the new head (one head only).
  **Django**: `makemigrations --merge` is not allowed; re-number on top of the latest.
- Unsure what's deployed? Check the environment's DB read-only (e.g. a read-only database MCP server or SQL client) before adding a column.

## 7. Evidence and environments
- UI change → screenshots. Backend change → request/response JSON (`<workspace>\.claude\skills\qa-kit\scripts\api.ps1 -Save`).
- Test against the environment named in the brief. **Never touch production.**
- **Stale deploy**: if a check fails only because the environment runs an older build (404 / 405 / "No static resource" on
  an endpoint that exists on the target branch), call it a stale deploy and don't change code.
- Tester guide: fill `<workspace>\.claude\skills\qa-kit\templates\tester-guide.html` (check ids T/L/R, concrete Expected) and publish it
  with `devtools.py doc` (anyone with the link can view). Say what still needs a live check.
- Evidence names and formats: `qa-kit\reference\evidence-standard.md`.

## 8. Ship it yourself
1. Re-read `<brief>.contracts.md` next to your brief (if it exists): the coordinator appends cross-agent contracts there during
   the wave — field names, ownership, merge order. Follow them. Then `wt.ps1 sync`, then re-run `check.ps1` (and `-Step migrations`).
   If another writer appears in your worktree (changes you didn't make), stop writing and tell the coordinator.
2. Push and open one MR/PR per repo: `devtools.py mr`. Title `feat: <summary> - <CODE> (CU-<task>) (<Repo>)`.
   Body: fill `<workspace>\.claude\skills\orchestrate\templates\MR_BODY.md` (devtools warns on missing sections and adds the footer).
   Tracker solution comment: `templates\TASK_SOLUTION.md`.
3. **In a reviewed `/dev-wave`, don't schedule merges yourself**: open the MRs and stop; the workflow schedules them after a clean review
   (or you do it at the end of your fix round). Merging before review shipped a double-billing bug once.
   **Merge producers before consumers**: DB/API/library first, then web/app/clients. `devtools.py merge <wt> <iid>` asks GitLab/GitHub
   to squash-merge as soon as the pipeline is green and returns at once (no waiting; `merge-wait` is the old blocking mode). Post your
   ClickUp comment right after scheduling; the coordinator verifies the merge. On conflict: `wt.ps1 sync`, resolve, re-check, `push --force-with-lease` to
   **your** branch. Never force-push a target branch.
4. Several MRs are fine for a big stream; merge each before starting the next.

## 9. Tracker (ClickUp)
- `in progress` at start → review status once the MRs are open and the guide is posted (`devtools.py finish`) →
  `promoted` once **all** your MRs are merged. **Never set `in test`**: that happens after deployment.
- Don't change other people's tasks, or tasks already in a testing status.
- New tasks go under the epic named in the brief, assigned to the requester.

## 10. Final reply to the coordinator (≤ 200 words)
MRs merged · done / deferred item ids with reasons · settings or data to seed · what still needs a live check ·
hooks you left in another agent's area · dependencies you needed but didn't install.

## 11. Learn
Read `LESSONS.md` (next to this file) before you start. When something costs you time, fails, or works unusually well, record
one line: `& <workspace>\.claude\skills\orchestrate\scripts\learn.ps1 -Skill dev-kit -Kind <kind> -Text "<what + fix>"`.
The guard hook blocks `git stash`, `--no-verify`, force-pushes to shared branches and ungated heavy builds — its message tells you the right command.
