# Kit lessons
Active rules, one line each `- <when> -> <do> (<why>)`, newest first, `(n×)` = times seen, `- [local|ship]` = those phases only (`-Phase`; local also reads code). Read your skill's section: `bossy.ps1 learn -Read -Skill <skill>`
(adds the git-ignored LESSONS.local.md). Retired lines: `bossy.ps1 learn -History` (git + `.state`). Managed by `bossy.ps1 learn` (`-When -Do -Why`).

## bossy
- a deploy plan or script whose final JSON you need -> run it in the foreground with a timeout, not as a background task (background run lost the JSON 3x; monitor waited on unsettled output, ENOENT on the task file)
- supervise flags a SHELL ORPHAN whose owner agent still shows on the board -> check the board row and its last beat before taskkill /T; kill only when the agent is gone (taskkill /T on checky-R2 pid 32160 cut a live agent)
- A consumer MR waits on producer MRs -> register EVERY producer with `bossy.ps1 track add -MergeAfter '<web>!<iid>><api>!<iid>'` before any merge, read the printed list back, confirm API MRs merged before QA, never merge a consumer by hand (a consumer merged first broke QA). (9×)
- The owner asks to explain or plan -> answer or plan, never launch a wave (a 9-agent wave once built nothing). (4×)
- Reporting or acting on an MR's state -> take it from devtools.py merge output or the host, reconcile before consumer merges or promotes (an agent's prose said merged while it was only scheduled for green). (8×)
- A destructive owner ask (clean a folder, reset a branch) while runs go on -> do it yourself after the runs end; agents never act on relayed asks outside their items (a live run's files would go).
- A contract changes mid-wave -> agents append to the contracts file, never overwrite; put the change in the contracts file AND the brief's bottom; re-check your note after agents publish (overwrites lost notes). (3×)
- Two agents overlap on files -> the second rebases only after the sibling MR merges (one conflict resolution, not two).
- QA results arrive (failedTesting or [Bug]) -> one bugbrief per task, ONE /buildy for all open now; give `bugbrief` repo@branch when a repo ships two products from different branches (fixes otherwise land on the wrong branch).
- Launching /buildy or /testy -> always pass `mandate` (the owner's words) (the harness relays the latest chat message as "the request that wins"). (3×)
- A merged MR adds a dependency -> add it to the shared linkFrom tree yourself (the exact version, unpacked in place), never a full install there (a full install breaks every linked worktree).
- Writing a brief -> git-grep the target branch before listing work on a second branch; quote producer contracts verbatim; port sibling review findings; task text and brief agree on each area; concept items -> one decisions doc; meetings: ASK lines (briefs drifted from code and tasks). (6×)
- A QA tester asks a question -> answer in `<runDir>/lead-notes.md` (`pokey.ps1 lead-notes add`), never SendMessage; items a run could not publish: `pokey.ps1 finalize` from the on-disk results.json (testers cannot be messaged; they re-read the notes).
- Splitting work into agents -> group by AREA (screens / packages), not item count; overlaps and contracts in the brief; ~15 parallel devy; each area its own file prefix and number range; overlap checks list every path any commit touched (net diffs hid overlaps; the memory gate fits ~15). (2×)

## crafty
- [ship] writing the MR body How tested -> count PASS rows from the diff; say UI change when the diff touches a UI file (MR body marked not a UI change while the AI panel changed (6791)
- one-off python from Git Bash -> write a scratch .py and run it with pwsh python -X utf8, not python -c (python shim echoes goto :error)
- a kit worktree push is refused as protected branch -> use git -C <wt> push origin HEAD:main, not from the worktree cwd (guard refuses cwd form)
- [ship] Review returns blocking findings and the MR head has not moved -> fix and push a commit, then re-request review; do not repeat the round unchanged (2 blocking findings stayed unresolved after round 1)
- [local|ship] A spec is edited (e.g. a revert) after the last green local pass -> re-run that spec before finish (role-gating revert left 6 tests never re-run)
- [ship] deploy plan shows a MERGED MR as NOT-DEPLOYED, or mr.get prints null -> Re-query MR state with the host verb before reporting; run deploy plan with a long timeout (Wrong not-merged summary and skipped MR body, docs and tracker updates)
- a scratch file (probe, diff, config copy) -> only under crafty.ps1 dir -Agent <id> (a stray in <runtime>/work cannot be removed later: the guard blocks deletes there, 7x on 2026-11-19)
- [code] a change touches files outside the area paths of the brief -> raise the scope decide ask at plan time, not at wt commit (wt commit refused files and the agent waited with no answer) (2×)
- editing regex text or writing mr/spec text -> use the Edit tool, not heredoc python; run kitbag.py prose on the text first (heredoc corrupted files; 46 prose refusals in one window)
- [local|ship] A testing-doc row is NOT_TESTED_LOCAL -> Add its human check (or needsLiveCheck) at write time, before devtools.py finish (finish refused 3x, blocking sibling items' publish)
- Agent reports code plus unit tests pass but local-env loop and testing docs not done -> Treat as not finished: run the local loop and docs before returning, or hand off with the open steps (Cause seen 5x in 30 days; items came back for rework)
- [ship] devtools.py finish runs on a task created without a spec (no Problem, Goal, Items, Acceptance, Links) -> write the tracker spec sections before finish, or create tasks through tracker create with a spec (tracker describe refused finish 3 times, task stuck before promoted)
- [code] A spec-only (test-only) area finds a product bug -> pin today's behaviour in the spec, report BACKEND FIX + `decide ask`, never edit product source (a spec-only area's MR changed 4 service / repository files, passed review and CI, and reached a test env). (1x)
- [ship] devtools.py finish on a parent task whose description is rendered from a spec -> update the description with crafty.ps1 tracker update -Spec before finish; finish must skip describe on spec-rendered tasks (finish failed 3x at tracker describe after docs and MRs were already posted)
- looking for a skill, script or file -> Glob / Grep the kit, ~/.claude or the repo; never a whole-drive find (an orphaned whole-drive find held the shell and disk)
- After `wt lease` / `wt new` -> check the dependency links (node_modules, linkPaths) exist before editing; missing: save the diff, lease again (a worktree without them fails wt remove and can empty the folder). (1×)
- [ship] Wave branches of one task -> pass `--override` with the wave id to devtools finish and mr on each sibling branch (the prior-work gate refuses siblings until it counts the batch as one task). (3×) (2×)
- [ship] Writing a shared task doc (one testing-ai key, many wave agents) -> read the current doc first, keep every other area's section and Rounds rows, write patches with the Edit tool or a file (heredoc python collapses backslash-n; areas lost rows). (4x)
- [local] envy deploy REFUSED by a foreign layer not based on the published head -> board msg its holder; holder off the board: raise an ENV-FIX (deploying over it breaks the holder's test). (2x)
- [ship] A doc change, final rebase or flaky tracker call -> re-run devtools.py finish and check the tracker status after it (it updates the two docs, the links block and the solution comment in place). (4x)
- [ship] Before the push -> `devtools.py mr <wt> --spec mr.json --check` and fix the body (260 words, How tested bullets, one Not run line) (fixed in kit: crafty step 6 runs it; fixing after mr's refusal meant a second push; seen again = regression). (4x) (2×)
- [ship] Writing an MR's state in a report -> re-query the host's mergeState before the summary (earlier output went stale: open vs merged was inferred wrong). (4×)
- [code] A rule names only items that exist (statuses, keys) -> check every listed name against its source before commit (invented and stale entries shipped). (2x)
- [ship] Before merge -> confirm a pipeline exists for the MR head; none (rules skipped): trigger one or report NOT_MERGED with the reason (agents waited silently on no pipeline). (2x)
- [ship] Asking for re-review or merge after review fixes -> push the commit first and check the host's MR head sha equals the local HEAD (reviews ran on the old head). (2x)
- Any claim in the MR body or goals doc (PASS, cleanup added, red before the fix, "no gate exists", "untested methods: none") -> name its proof from the final head (test, grep, request) and update the goals doc before done (a compile error was called a red test). (6×)
- Gating a feature -> gate only what it introduced, on the flag, in the shared method (grep every caller); on/off tests; status gates list every terminal status; shared-aggregate fixes keep existing numbers; flags whose safety lives in another service ship OFF (gates leaked into old paths). (14├ù)
- Resuming an area -> `crafty.ps1 wt status`, `git log origin/<target>..<branch>`, the host's MR state; released or vanished slot: `wt lease` the same branch; rebase, re-run targeted tests, keep the goals file; takeovers skip the testing doc (a stopped agent may have merged). (11×)
- [code] A task may span repos and target branches -> run `git log --grep <task>` on each target before worktrees; the brief's repo table lists them all (a second branch's work was missed). (4×)
- [code] A precondition fails in an API handler -> use the validation helpers that return 400 and grep every call site (a generic runtime error maps to HTTP 500; the UI shows the server's 400 text). (3×)
- [code] A task or queue payload carries secrets (headers, env, tokens) -> keep them in process memory only, store NULL, chmod db files on open; grep host env var NAMES before removing a fallback (secrets reached a db, WAL, log or temp file). (2×)
- Editing a file with mixed CRLF / LF -> use the Edit tool + `git diff`, or a script with absolute paths (`-Raw .Replace` with `n no-ops, `[IO.File]` relative paths use the process cwd, python without newline='' drops CRLF). (5×)
- A read-only DB tool cannot connect -> use the org's read-only fallback and note it in the MR; migration ids come from the coordinator, applied in id order (ids clashed between agents). (4×)
- Screenshot clones of flex / grid pages -> set flex-grow 0 / flex-basis auto in the clone; the picture starts with the first table row (clones keep the live height). (2×)
- [ship] A resumed or split task -> register planned repos (`track add -Task <id> -Discover`) before any sibling merges and read the status before setting one (`track` promotes once every known MR merged). (2×)
- [code] Moving a job off the request path -> grep its other callers, build the new data before deleting the old (swap in one locked step), scope retries; readiness = the health endpoint answering (data went missing between the steps). (4×)
- [code] Mocking a producer -> fixtures from captured payloads, replay write semantics (PATCH deep-merge), dumped SQL read-only on a replica, flag-off golden from origin/<target>, call the real method, dates server-side (mocks hid producer behaviour). (18×)
- Optional context, expiry or revert logic -> never gate the main action on optional context; set the terminal state only when the revert completes; access from structured data, not regex; anchor expiry to the source timestamp; clear a stored reason with its state (each broke a flow once). (5├ù)

## pokey
- run dir is under <kit>/.claude/.runtime and browser.mjs shot()/saveNet refuse it -> set CLAUDE_RUNTIME to that dir before running browser.mjs; use crafty.ps1 dir for run files (seen 3x: shot refused, Write guard-denied)
- finalize -Check fails a prose limit (observed text over 40 words) -> count words in each observed text before finalize; keep <= 40 (seen 2x: found only at check, needed a results patch)
- before publishing results -> run finalize -Check -FixNames first; evidence entries must be files, prose fields within word caps (it caught evidence renames and prose overruns on 3 tests before publish; a T2 stop after Check left the run unpublished, so always send publish right after)
- a run starts and chrome-devtools MCP may be down (CONNECT_TIMEOUT seen in 5 tests) -> health check the MCP once at run start; use skills/pokey/browser.mjs when it is down (repeated connect failures in T1-T10 though no step needed it)
- calling pokey.ps1 in command position (pwsh -Command, stdin heredoc) -> always run pwsh -NoProfile -File <kit>/skills/pokey/pokey.ps1 <verb>  (guard blocked it in 4 tests and each retry cost a round)
- pokey.ps1 prepare writes run.json title -> keep the title one short sentence (<=20 words) before finalize -Check; prose gate reads it, a tester cannot fix it (finalize -Check failed prose for every item in 5 signals)
- calling kit scripts from pwsh in a tester run -> use pwsh -NoProfile -File <script> <args>, never -Command, stdin or a bare & script.ps1 (guard blocked -Command and stdin forms and flagged & script.ps1 as a desktop launch (2x)
- a testy run ends via launch -Done -> finish the Learn phase (record signals) before launch -Done (run stopped before Learn 3x: steps and results lost)
- calling a kit script (pokey.ps1 prepare, results patch) from Bash -> pwsh -NoProfile -File <script> <verb> with the JSON in single quotes, or a .ps1 in the run dir that calls it (the guard denies a script in command position, -Command or a heredoc: 13x on 2026-11-19) (3×)
- results patch carries a row key firstAttempt -> use only keys in testy.js CHECKS_SCHEMA; fold the content into observed (9 refusals and re-runs of patch in one day)
- finalize -Check -Results results-retry.json on a scoped retry -> check only rows in the retry file; expect docgaps to flag rows it does not cover and publish with the item results.json check instead (3 signals: false doc-check failures on unpublished rows)
- writing testing-doc or check texts with prose limits -> write to the word limit first and keep the key request (e.g. server-log check) when cutting (prose check failed twice; shortening dropped the server-log request)
- a test run lasts longer than a few minutes (a full e2e suite) -> start it detached with Start-Process and a log file, never as a Bash run_in_background child (a 3.5 h e2e run died at 42 min with the shell, no exit line)
- publishing QA evidence -> run finalize -Check, then publish -FixNames so evidence names are standard on the first try (T3 and T4 closed clean first try; T1 and T2 needed renames) (3×)
- Before finalize -> run `finalize -Check -FixNames -ExpectChecks N` (it renames the files and every reference in results.json, lists and text). (2x)
- A node QA script -> wrap it in try/finally s.done(); after a hard kill run `bossy.ps1 release -Agent <id>` (leased tabs, 8 max, made session() hang silently). (2x)
- A setting-dependent check -> change the setting, wait for the cache, check, restore and verify the restore by GET; log each step in lead-notes.md (an unrestored setting broke other checks). (1×)
- Writing QA observed and verify text -> sentences of <= 25 words, <= 40 words per observed text, before evidence -Check (so the first -Check passes). (3×) (2×)
- An API check -> replay the body the real client sends (from the web UI network log or the client source), never a hand-built body (a richer hand body passed while the UI request wrote wrong data: defect missed). (1x)
- A PowerShell helper param -> never reuse a script variable name in any case (`$o` is `$O`); use distinct names (the helper ran with the wrong value: hard failure). (1x)
- Passing `pokey.ps1 api -OutDir` -> take it from `crafty.ps1 dir` in a distinctly named variable (a reused case-insensitive name, $o is $O, sent a number: refused 9x). (9x)
- Report -Check fails on prose limits -> shorten the observed wording only, keep every evidence name and file reference (renamed references broke the report). (2x) (3×)
- Before every publish -> run `pokey.ps1 finalize -Check` (it catches missing or renamed evidence references: no broken report goes out). (1x)
- A publish run exits 0 -> check the publish output and the tracker, not the exit code (fixed in kit 1fda997 + 711fa46: a finalize crash exits 1; seen again = regression). (5×)
- A local env start -> check free RAM for the gate (its need + gate.keepFreeGB) first, or run the API checks first (the start waited on the memory gate). (3×)
- Before a run -> check the MCP servers it uses (record in lead-notes.md); checks needing a down server use the API or scripts (a down server left checks untested). (2×)
- Calling `pokey.ps1 api` in PowerShell -> never pipe a -Save call into Select-Object -First N, never Out-String long JSON, read .response.body from the -Save file; no passwords in results or reports (output was cut and names collided case-insensitively). (5×)
- A FAIL found in a retest -> check the build from before the MR (old build or git blame); not caused by the MR: `defect: new` with that evidence (old defects were blamed on the MR). (2×)
- Retesting a fix in shared code -> cover every caller and screen on the same code path or record (one screen passed while another broke). (3×)
- Lanes share one user -> one session key per lane, delete only your own data (they share its per-user server state). (3×)
- Lead notes widen scope -> re-read lead-notes.md before each check; a required check goes into the run item (`pokey.ps1 retest -Only <ids>` + the guide) (checks the lead added were missed). (4×)
- Before any FAIL -> run `pokey.ps1 deployed` for EVERY repo of the task; an owner-confirmed manual deploy counts after an API marker check; re-check the test app's version before finalising FAILs (undeployed fixes were failed). (8×)
- A layout fix -> test the smallest and largest viewports with real wheel scrolling (scrollIntoView hides overflow:hidden clipping). (3×)
- Guide data drifted on a shared env -> create your own data via the API; a later screen change: test the same intent (PASS_WITH_NOTE (a)); guide vs screen: read the code, quote both, ask the lead (shared data changes under testers). (6×)
- Parallel items toggle a shared env setting -> serialise them; keep one feature-OFF account, made before the run (toggles caused 403s elsewhere). (3×)
- Capture (timing) checks -> time per screen and page type, wait for pageSize rows before timing, re-run once at low load before FAIL; a capture blocking past its cap is FAIL with the profile saved (load spikes gave false FAILs). (9×)
- An item is skipped -> write its reason into run.json (skips without a reason were lost). (2×)
- A server-side config check (model, temperature, fallback) from the API lane -> verify the deployed code and its unit tests, name unseen env overrides; unprovable: NOT_TESTED with cause (the API cannot show config).
- Library overlays (dropdowns, date pickers, virtual lists) -> hover dropdowns need `hoverSel`, date pickers a cell click, virtual lists the overlay scrolled; paginate and wait for the first row's id to change (overlays render outside the component). (2×)

## envy
- a helper pipes crafty wt new output to Write-Host -> check the exit code or output of wt new and fail loudly (a refused wt new (missing dep source) went unnoticed)
- Local DB drift (leftover table, missing definer or grant, orphan FK refs) fails migrations -> ENV-FIX (kitty NULLs the orphans, drops a half-added column, or `envy.ps1 restore -Mark <mark>` / `seed`), never fix the shared DB by hand (a failed FK changeSet leaves a half-added column). (2×)

## phoney
- The android-build gate (about 11.5 GB + keep-free) -> build before other agents lease phones (with a phone and a local API up it waits up to 20 min or longer). (4×)
- Lanes beside other load -> no heavy web lanes beside 3 emulators; `phoney.ps1 status` before each check, `phoney.ps1 ensure -Agent <id>` at once (lanes drop offline at ~2-14 GB free RAM). (3×)
- A restored snapshot leaves a lane "offline" in adb -> `phoney.ps1 avd reset -Lanes <name> -Level cold` (a warm reset keeps the offline state).

## kitty
- a command prints a long result (audit, lint, scan, ls-files) -> filter or range it (--warn | head, grep, -First) before it enters context (kitty bigresult: 28 runs, 327k tokens)
- a kit file is needed again in the same run -> note its facts once; later Read only an offset/limit range or grep the line (kitty reread: 101 runs, 843k tokens in one retro window)
- writing kit edit scripts -> create each edit .py with the Write tool, not a Bash heredoc (heredoc lost backslashes and missed CRLF anchors (3 failures)
- editing with a scripted replace -> write the script with the Write tool; no pwsh -Command from Git Bash, no heredoc python with backslash-n (dropped apostrophes, 5 MISSed replaces)
- Splitting a SKILL.md or moving a block between files -> run kitbag.py lint before wt commit (FILE-CAP and READ-BUDGET surfaced only at pre-commit)
- Running board beat or checkpoint -> call the live clone bossy.ps1 / crafty.ps1, never the worktree copy (the worktree board does not know your session)
- A kit test needs a port or matches a CLI flag -> use a free port from TcpListener 0 and -cmatch (fixed port 3307 and case-insensitive match broke the test)
- a small fix touches files near their token cap (buildy.js, crafty SKILL.md, a test file) -> measure headroom per file first (kitbag.py budget), then forget or move a block before editing (measuring after the edit cost most of a small fix, twice)
- A test fixture is made with tracker create -Key -> Use a non-keyed create or expect the [Bug] prefix and no Items check (Keyed creates became a [Bug] and silently skipped the Items check)
- Edit removes a block spanning line ends in a CRLF file -> Include the whole lines with their CRLF in old_string, then check the file parses (A newline-only old_string joined two lines and caused a parse error) (3×)
- ui-check --click uses a child selector (a>b) from Git Bash -> quote the selector, run from the PowerShell tool, do not pipe stdout (unquoted > redirected stdout, left a stray file named summary, later calls refused (3x)
- writing test data or fixtures -> use invented paths and ids, never copy a real repo path or cloud resource id from live state (pre-push ORG-TERM block)
- a scripted replace has ONE pair -> write @(,@(a,b)) so PowerShell keeps the pair nested (single pair flattened, every 5 in a file was replaced)
- changing a status-guard or transition table -> run every -Area that starts tasks open (pokey, qa-config), not only the touched one (QA fixtures broke after a transition-table change)
- a shell command reads stdin (heredoc ending in cat > /dev/null) -> never run a stdin-reading command; use a timeout or bounded input (blocked 64 min, SHELL STALLED)
- a full kit suite or pre-push -Full runs while other kittys run suites -> run tests/kit-tests.ps1 -Full yourself first, with a long timeout; never kill a shell by pid (subagents share one claude pid) (pre-push hit the 30 min cap, flaked under load, and one kitty killed another's push shell)
- kit push runs the full pre-push suite -> use a timeout over 20 min or run it in background; rerun a flaky area (guard-warm, wt-pool) alone before judging (a 590 s timeout killed pre-push (exit 143) and left orphan tests; 3 load-only flakes)
- Adding a trailing # comment with Edit to a PowerShell one-liner (hash literal, foreach body) -> Put the comment on its own line above the statement (The # swallowed the rest of the line, 4x broken scripts)
- a kit test reads durable state (.state leases, acks, status cache) or a block moves into a new adapters/*.ps1 -> redirect .state in the harness, clear acks / caches it reads, add new files to harness New-TestKit and each area's list (torn leases, missing files failed tests) (2×)
- a multi-line program or a > or // argument to python from Git Bash (pyenv shim, MSYS conversion) -> write a .py into crafty.ps1 dir, run it and pass selectors from pwsh (cut programs, stray files, 4 flaky FAILs, a dropped slash) (3×)
- counting a property that may be null in PowerShell -> use @($x.prop | Where-Object { $_ }).Count or test $null first; @($null).Count is 1 (deploy plan printed OUT-OF-AREA for every MR, supervise info on an empty cache, a route hold skipped) (3×)
- Working after a push in a merged clean worktree -> run every later command with absolute paths into it, never cd then a command that falls back to the live clone (cleanup swept the worktree: hard failure). (2×)
- Reading ISO times with ConvertFrom-Json -> compare as DateTimeOffset or keep them text (-AsHashtable, then ToString('o')) (DateTime interpolation drops fraction and offset: same-second ties broke ordering). (1×)
- A test string holds a regex -> put it in a here-string or a variable (an unbalanced paren in a single-quoted string inside a double-quoted subexpression does not parse). (2x)
- Kit tests clean up -> remove only the fake files they wrote, never a whole folder (Remove-Item adapters -Recurse broke the bossy area for 2 days when a core function moved into adapters/). (1×)
- Scripted replace pairs in PowerShell -> wrap each concatenation in parentheses (the comma binds tighter than +: @('a', 'b' + 'c') has 3 items). (2×)
- Profiling a live supervise -> use a scratch copy; back up supervise-state, lock, report and .runtime/work/deploys/plan-cache.json first, restore after (a live profile overwrote them). (1×)
- Naming a scripted edit helper or a new kit function -> check the name with Get-Command / `git grep 'function <Name>'`, full verb-noun names only (an alias Rd = Remove-Item deleted README.md and lib.ps1; a second Format-KitCell replaced the first). (2x)
- Writing a file that holds regex or Windows paths -> use the Write tool (Bash heredocs in this harness mangle backslashes). (2x)
- Editing a CRLF kit file -> the Edit tool or pwsh ReadAllText / Replace / WriteAllText, never sed -i from Git Bash (it rewrites LF). (11×)
- Naming a test variable -> never reuse a name of the area file or the harness in any case (q vs Q, $sRc vs $src) (pwsh names are case-insensitive). (3×)
- Adding agents/<x>.md -> update the router row, reach mentions and manifest in the same commit (pre-commit lint ROUTER-UNROUTED, REACH-MENTION, MANIFEST blocks a lone file). (3x)
- Kit token cap work -> measure the whole pass's headroom first (one trim plan), then one file per agent, never trim a file another agent edits, prove each trim by token or AST equality (parallel trims collided). (4×)

## revy
- reviewing a diff or the same files twice -> read each file once, note facts, then only ranges; build output as failure lines only (revy reread 23 runs 336k tokens, buildlog 15 runs 81k)
- Reviewing an MR in a main checkout -> read diffs with `git show <sha>:path` or `git diff <base>...<sha>`, never git checkout there (a main checkout may sit on a detached head others use). (2x)

## Decisions
- 2026-11-19 shareCheckBuild: context never hit here (the check build skips the step that makes a runnable artifact: nothing to stage) · decision (owner) keep it as is · consequences envy reference.md `shareCheckBuild`; other stacks' check builds still stage.
- 2026-11-14 Debate: context Characters unseen, 0 disputes in 448 msgs · decision (owner) Characters, disputes, trigger debates: core, never trimmed for caps; the owner decides splits · consequences buildy.js disputes + debate, rechy / revy kinds debate / dispute, lint MANIFEST, workflow cap 16500.
- 2026-11-14 Kit size: context a whole-kit cap kept parts off main · decision (owner, supersedes 2026-10-21) all on main, vendor adapters run when config selects them; a role starts <= 12k tokens, the rest via SKILL.md pointers; repo total INFO · consequences lint START-BUDGET, ORPHAN-DOC.
- 2026-10-16 Deploys: context agents proposed deploys · decision `deploy.trigger: owner` (owner): nobody asks or proposes; a person says `deploy <env>`, the coordinator deploys at once · consequences supervise has no DEPLOY ASK under owner.
- 2026-10-16 Crew: context many agent types · decision 4 agents devy, revy, checky, kitty (owner) · consequences lint AGENT-TYPE / NON-CREW; old names only in `_manifest.renamed`.
- 2026-10-16 NOT_TESTED: context untested checks closed tasks · decision one stronger retry, then failedTesting on shared envs; local items ENV-FIX, never failedTesting (owner).
- 2026-10-16 Leases: context resources held by fixed hours · decision every resource has a live holder; no holder for idle.graceMinutes -> released; services start only from a lease or a person (owner) · consequences lint LEASE-HOLDER.
- 2026-10-16 Readability: context indentation halving and aliases to save tokens · decision normal indentation and full cmdlet names (owner).
## briefy
- render wave-brief fails prose check on the renderer MR limits line (339 chars vs 130) -> shorten the limits line in the renderer template to <=130 chars (wave-brief render refused twice)
- render wave-brief output feeds buildy -> check args.json for agents[].kind, run name and spec openQuestions before launch; patch if missing (render drops them, hand patch after each render, revy caught empty openQuestions)
- A review sheet of 100+ items -> split verification across read-only agents by surface plus one endpoint-inventory agent, each writing one fixed-shape file, then merge (one agent ran out of context). (1x)
- Launch args mode -> feature, bugfix or resume; map a new-work ask to feature (buildy.js rejects anything else, e.g. build, at once). (1x)
## opsy
## watchy
## rechy
- a search or fetch returns a large page or list -> narrow it (filter, range, one section) and note the facts once (rechy bigresult 118k + reread 111k tokens in 5 runs)
- Checking an adapter against a vendor API -> read the vendor reference (an llms.txt index lists .md pages) and diff request and response shapes field by field (adapters drifted from the vendor). (1x)
