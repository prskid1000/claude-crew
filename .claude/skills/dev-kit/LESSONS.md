# Dev lessons (self-improving — read before starting)

Maintained by each `/dev-wave` learn step and `/kit-retro`. Newest first. `(n×)` = times observed.
Project-specific lessons go under a `## Project: <name>` heading below the general ones.

## General
- (fixed in kit) A repo with no MR CI (deploy-only pipelines) never gets an MR pipeline, so `devtools.py merge` set merge-when-pipeline-succeeds and the MR waited forever. merge/merge_when_green now merge directly when the MR has no pipeline and its head commit is > 5 min old (younger: returns WAIT, run again).
- (fixed in kit) guard.ps1 blocked a read-only `Get-Process java,node,msbuild` as an ungated heavy build: `msbuild\b` matched the word anywhere. msbuild now counts only when it is run as a command (start of a segment, after & ; | ( or a quote).
- (fixed in kit) .NET checks never ran through check.ps1: stack.ps1's dotnet commands use a `{sln}` placeholder that check.ps1 never filled ("MSB1009: Project file does not exist. Switch: {sln}"). check.ps1 now fills it with the .sln in the stack dir, else its single project file.
- A squash merge makes an agent's own commits look "not in main" (`merge-base --is-ancestor` is false) even when their content is. Compare trees (`git diff <branch> origin/main -- <path>`), not commit ancestry, before assuming a fix round didn't land.
- (fixed in kit) A Liquibase changeSet commented 'not reversible' with an EMPTY `<rollback/>` failed the CI changelog check: lbcheck.py now flags missing or empty rollbacks on changeSets marked irreversible. Agents stopped at 'MR opened' and nobody saw failed pipelines: dev-wave now waits for MR pipelines (pipe-wait.ps1, cheap 'ci' step) and sends failures to the fix round.
- A new helper/member inserted between an existing Javadoc/JSDoc and its method steals the doc comment (review nits in Java and TS): add new members above the doc block or below the method. (2×)
- `track.ps1 add -Discover` can find no MRs right after `devtools.py mr` (search lag): pass `-Mrs <repo>!<iid>` explicitly as well. (4×)
- A client flag like "already on server" must not trust the 200 of a queueing endpoint (it only stores the request for later processing): fix it server side (fall back to the latest earlier request for the same id) and test the failed-then-resubmitted case. (2×)
- A local-DB schema bump or a new sync-derived field in a mobile app needs a forced full sync on upgrade (migration + wipe fallback reset the sync cursor), else the delta sync never backfills records already on the phone; verify by upgrading in place over an old APK. (2×)
- Feature/isolation gates (hide new behaviour where it is off): gate only what the new feature introduced (not older security checks), grep every consumer of a gated API or seeded row (a role hidden in one list but not in other filters), give each gate on and off tests, and set remembered flags on every known session, not only a fresh sign-in. (4× review findings)
- A global style rule with `!important` can beat a component library's variant (e.g. danger buttons): fix a feature's dialogs in the component's own, more specific style. A crash seen on one screen can come from a shared component: trace the stack first.
- Swapping a shared helper into a module can change behaviour the brief says to keep: diff outputs for edge cases (zero sizes, special units) or get a product decision.
- The guard can false-positive on PowerShell commands whose text holds slash paths or arrows; put such text in a script file via the Write tool and run that. Use the Edit tool, not sed/python/heredoc, for CRLF files and anything with backslashes.
- A web app with no unit-test target makes the `check.ps1` test step fail: keep logic in exported pure functions; specs are type-checked, or bundled with esbuild (through gate.ps1) and run under node with a tiny shim. (5×)
- `board.ps1 check` prints ok but can leave `$LASTEXITCODE` null/stale, so `-ne 0` guards falsely stop: test its output text or `-gt 0`. (4×)
- Git Bash `python`/`py` can be a broken pyenv .bat shim (`python -c` multi-line fails; emoji hit cp1252): write a .py file in the scratchpad, run it from PowerShell with PYTHONIOENCODING=utf-8, or use `node -e`. (14×)
- (fixed in kit) `wt.ps1 commit` stages everything (`git add -A`) unless `-NoStage`. (3×)
- `devtools.py merge-wait` needs a background timeout of 3600000 and a log file (10 min kills it mid-pipeline); prefer `devtools.py merge` (schedules and returns). `devtools.py doc` handles absolute paths itself (fixed in kit). (2× each)
- Duplicate dev agents (SendMessage to a workflow agent's ID spawns a copy) share one worktree and interleave edits; relay via contracts.md. Husky v8 `core.hooksPath=.husky/_` skips hooks (wt.ps1 falls back to .husky). (3×; commits made with skipped hooks can fail CI init: recommit)
- Heap caps are dynamic and learned PER PROJECT (main repo + subproject folder, e.g. `backend/services/api`; worktrees share their main repo's profile): a new project starts at Gradle 12 / Maven 8 / Node 4 GB, then learned peak × 1.25 (never below 4 GB, never above the start), shrunk toward 4 GB when memory is tight. JVMs run G1 with tight free-ratios so the learned peak can fall. Inherited -Xmx (e.g. a user `MAVEN_OPTS=-Xmx16g`, which once made one `mvn test` take 6 GB) is always overridden.
- Claude Code sets `NoDefaultCurrentDirectoryInExePath=1`: bare `gradlew.bat` / `mvnw.cmd` aren't found in the current dir. Use `.\gradlew.bat` (the gate and stack.ps1 add `.\` automatically).
- `check.ps1` typecheck is incremental (cache in `.claude-runtime\tsbuild`): 16 s → 6 s on a large Angular app. Don't pass your own `--incremental`.
- The memory gate learns real peaks per build kind (`%TEMP%\claude-build-gate\history.json`); long waits print the biggest memory users — if an IDE or another session hogs RAM, say so instead of retrying.
- Six parallel Maven JVMs hit 100% RAM; every build goes through the gate (the guard hook blocks ungated builds).
- Worktree hooks were silently skipped (`core.hooksPath` missing in worktrees) → always `wt.ps1 commit`.
- One agent popped another's `git stash` → stash is blocked by the guard; use WIP commits.
- A hook/side effect added after a service call must check the call really took effect (a cancel method that silently returns for an already-paid record once caused double billing): reload state, test the status, add a test for the no-op branch.
- Agents can report before the API pipeline finishes; web MRs must merge after their API MR: the coordinator confirms the merge before QA, and consumers are registered with `track.ps1 add -MergeAfter '<web>!<iid>><api>!<iid>'`. (6×)
- Forms that rebuild a payload from visible fields wipe stored values on update: prefill from the existing record and send unchanged values back; the API must not clear fields that are absent. Skip idempotent syncs when the request equals stored values. (3×)
- When widening a status filter or adding report columns, keep old exclusions and update every report definition sharing the summary. (2×)
- Signed numeric inputs need a signed keyboard on React Native (`decimal-pad` has no minus key); test typed input, not just a set value.
- A main checkout on another branch links the wrong `node_modules` versions into a worktree: `wt.ps1 new ... -LinkFrom <a checkout of the target branch>`.
- Merge API MRs first, then web/app; test-environment deploys lag — call stale deploys out instead of "fixing" them.
