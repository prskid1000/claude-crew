# Kit lessons
Active rules, one line each `- <when> -> <do> (<why>)`, newest first, `(n×)` = times seen. Read your skill's section: `bossy.ps1 learn -Read -Skill <skill>`
(adds the git-ignored LESSONS.local.md). Retired lines: `bossy.ps1 learn -History` (git + `.state`). Managed by `bossy.ps1 learn` (`-When -Do -Why`).

## bossy
- Two products' web items in one wave -> batch one product's web items, release its web, then launch the other's; testers run API checks first (two local web services, ~8-10 GB each, do not fit beside QA browsers and the keep-free floor). (4×)
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
- A spec-only (test-only) area finds a product bug -> pin today's behaviour in the spec, report BACKEND FIX + `decide ask`, never edit product source (a spec-only area's MR changed 4 service / repository files, passed review and CI, and reached a test env). (1x)
- wt commit refused (prose or lint finding) -> fix it and commit before any wt sync (uncommitted review-fix edits were lost across a sync). (1x)
- A contract claims an old consumer ignores a new param -> test it against the deployed consumer (one call on staging) before merge (kwargs-strict handlers reject unknown params). (2x)
- A long kit verb (bossy deploy request, waits) via Bash -> start it with run_in_background or a timeout over 120 s, then read the output file (a foreground call cut at 120 s loses the plan). (1x)
- After `wt new` -> check the dependency links (node_modules, linkPaths) exist before editing; missing: save the diff, recreate with `wt new` (a worktree without them fails wt remove and can empty the folder). (1×)
- Shipping an MR -> after the local PASS run `devtools.py finish` first, then `mr` with both doc links (take the link finish printed), then merge (merge refuses a body without the Testing doc lines; a gws timeout may move the AI doc). (3×)
- Code reads cloud secrets or creds -> lazy-load them and run unit tests once with creds unset before the MR (import-time reads pass on a laptop and fail on a clean CI container). (1x)
- Wave branches of one task -> pass `--override` with the wave id to devtools finish and mr on each sibling branch (the prior-work gate refuses siblings until it counts the batch as one task). (2x) (2×)
- Writing a shared task doc (one testing-ai key, many wave agents) -> read the current doc first, keep every other area's section and Rounds rows, write patches with the Edit tool or a file (heredoc python collapses backslash-n; areas lost rows). (4x)
- A stacked MR after a fix round on its base -> rebuild it on the new base plus a revert of the moved commit (the stacked diff stays clean). (1x)
- envy deploy REFUSED by a foreign layer not based on the published head -> board msg its holder; holder off the board: raise an ENV-FIX (deploying over it breaks the holder's test). (2x)
- A doc change, final rebase or flaky tracker call -> re-run devtools.py finish and check the tracker status after it (it updates the two docs, the links block and the solution comment in place). (4x)
- Before devtools.py mr -> run `kitbag.py prose --kind mr-body` and fix the body (260 words, How tested bullets, one Not run line) (fixing after mr's warning means a second push). (4x) (2×)
- Writing an MR's state in a report -> re-query the host's mergeState before the summary (earlier output went stale: open vs merged was inferred wrong). (4×)
- Test cleanup deletes several rows -> collect each failure and assert once at the end (one 409 left the rest behind: hard failure). (1x)
- A rule names only items that exist (statuses, keys) -> check every listed name against its source before commit (invented and stale entries shipped). (2x)
- Running a script -> always through its interpreter (`python -X utf8 x.py`, `node x.mjs`, `& x.ps1` / `pwsh -File`) (`& x.py` or `.\x.py` opens the Windows association, an editor on the owner's screen; the guard denies it, doc openers, `--web`, `gh browse` too).
- Before merge -> confirm a pipeline exists for the MR head; none (rules skipped): trigger one or report NOT_MERGED with the reason (agents waited silently on no pipeline). (2x)
- Asking for re-review or merge after review fixes -> push the commit first and check the host's MR head sha equals the local HEAD (reviews ran on the old head). (2x)
- Any claim in the MR body or goals doc (PASS, cleanup added, red before the fix, "no gate exists", "untested methods: none") -> name its proof from the final head (test, grep, request) and update the goals doc before done (a compile error was called a red test). (6×)
- An FK on an old table -> count orphan refs first (local env and a replica), clean them in an earlier changeSet (MySQL rechecks every row on the table copy, 1452; a failed DDL leaves a half-added column). (2×)
- Gating a feature -> gate only what it introduced, on the flag, in the shared method (grep every caller); on/off tests; status gates list every terminal status; shared-aggregate fixes keep existing numbers; flags whose safety lives in another service ship OFF (gates leaked into old paths). (14×)
- Linked shared deps older than the target fail typecheck / build / Jest -> keep the earlier local result, no reinstall, CI decides (a reinstall breaks every linked worktree). (7×)
- Git host 500/502, CI gateway timeout or merge's `INFRA <reason>` -> retry the failed JOB on the same sha (`glab api -X POST projects/<id>/jobs/<job>/retry`), merge only after green, no code change (`glab ci retry` 404s; infra is not a code fault). (6×)
- Resuming an area -> `crafty.ps1 wt status`, `git log origin/<target>..<branch>`, the host's MR state; vanished worktree: `wt new` on the same branch; rebase, re-run targeted tests, keep the goals file; takeovers skip the testing doc (a stopped agent may have merged). (11×)
- An LLM or MCP-path answer changes -> sample 5 fresh chats on an env with the MCP URL before merge, or mark needsLiveCheck with the env (unit tests cannot judge live answers). (3×)
- A task may span repos and target branches -> run `git log --grep <task>` on each target before worktrees; the brief's repo table lists them all (a second branch's work was missed). (4×)
- A precondition fails in an API handler -> use the validation helpers that return 400 and grep every call site (a generic runtime error maps to HTTP 500; the UI shows the server's 400 text). (3×)
- A task or queue payload carries secrets (headers, env, tokens) -> keep them in process memory only, store NULL, chmod db files on open; grep host env var NAMES before removing a fallback (secrets reached a db, WAL, log or temp file). (2×)
- Editing a file with mixed CRLF / LF -> use the Edit tool + `git diff`, or a script with absolute paths (`-Raw .Replace` with `n no-ops, `[IO.File]` relative paths use the process cwd, python without newline='' drops CRLF). (5×)
- A read-only DB tool cannot connect -> use the org's read-only fallback and note it in the MR; migration ids come from the coordinator, applied in id order (ids clashed between agents). (4×)
- Screenshot clones of flex / grid pages -> set flex-grow 0 / flex-basis auto in the clone; the picture starts with the first table row (clones keep the live height). (2×)
- A resumed or split task -> register planned repos (`track add -Task <id> -Discover`) before any sibling merges and read the status before setting one (`track` promotes once every known MR merged). (2×)
- Moving a job off the request path -> grep its other callers, build the new data before deleting the old (swap in one locked step), scope retries; readiness = the health endpoint answering (data went missing between the steps). (4×)
- Mocking a producer -> fixtures from captured payloads, replay write semantics (PATCH deep-merge), dumped SQL read-only on a replica, flag-off golden from origin/<target>, call the real method, dates server-side (mocks hid producer behaviour). (18×)
- Optional context, expiry or revert logic -> never gate the main action on optional context; set the terminal state only when the revert completes; access from structured data, not regex; anchor expiry to the source timestamp; clear a stored reason with its state (each broke a flow once). (5×)
- UI lifecycle changes -> a structural spec over real templates for placement bugs; a destroyed guard after every await, unregister on destroy; list mutations through one resolve-active helper; check new transient states against the template (async callbacks hit destroyed components). (8×)
- A cross-repo contract -> quote producer validation verbatim; the producer accepts both spellings and opens its MR first; never invent limits or endpoints; a producer DTO change ships with its consumer in the same wave (invented limits broke consumers). (19×)
- Tightening validation -> grep every client caller for its real encoding; list each old-accepted input as tested or stated as newly rejected (clients sent encodings the new rule refused). (6×)
- A form rebuilds a payload from visible fields -> prefill from the record; the API never clears absent fields; never bind the raw entity on PUT; keep the stored derived value after a lookup; never overwrite a typed user draft (stored values were wiped). (7×)

## pokey
- Before finalize -> run `finalize -Check -FixNames -ExpectChecks N` (it renames the files and every reference in results.json, lists and text). (2x)
- A PASS_WITH_NOTE whose observed text describes a defect (clipped control, wrong data) -> make it a FAIL; re-read every note before closing (a defect passed as a note once). (1x)
- A node QA script -> wrap it in try/finally s.done(); after a hard kill run `bossy.ps1 release -Agent <id>` (leased tabs, 8 max, made session() hang silently). (2x)
- Before a QA run starts -> check its targets and alsoTargets cover every env each task's checks call (a missing second product's staging left the task untested for env-data). (2×)
- A setting-dependent check -> change the setting, wait for the cache, check, restore and verify the restore by GET; log each step in lead-notes.md (an unrestored setting broke other checks). (1×)
- Writing QA observed and verify text -> sentences of <= 25 words, <= 40 words per observed text, before evidence -Check (so the first -Check passes). (3×) (2×)
- An API check -> replay the body the real client sends (from the web UI network log or the client source), never a hand-built body (a richer hand body passed while the UI request wrote wrong data: defect missed). (1x)
- A PowerShell helper param -> never reuse a script variable name in any case (`$o` is `$O`); use distinct names (the helper ran with the wrong value: hard failure). (1x)
- A NOT_TESTED undeployed check whose MR sits in a running deploy job -> wait on that job (glab api jobs/<id>), then test (failing the task was premature). (1x)
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
- Proving cross-product token refusal -> by unit test or the deployed key, after checking the separate service is deployed (a test env's signing key can differ from repo config).
- Library overlays (dropdowns, date pickers, virtual lists) -> hover dropdowns need `hoverSel`, date pickers a cell click, virtual lists the overlay scrolled; paginate and wait for the first row's id to change (overlays render outside the component). (2×)

## envy
- Local DB drift (leftover table, missing definer or grant, orphan FK refs) fails migrations -> ENV-FIX (kitty NULLs the orphans, drops a half-added column, or `envy.ps1 restore -Mark <mark>` / `seed`), never fix the shared DB by hand (a failed FK changeSet leaves a half-added column). (2×)

## phoney
- The android-build gate (about 11.5 GB + keep-free) -> build before other agents lease phones (with a phone and a local API up it waits up to 20 min or longer). (4×)
- Lanes beside other load -> no heavy web lanes beside 3 emulators; `phoney.ps1 status` before each check, `phoney.ps1 ensure -Agent <id>` at once (lanes drop offline at ~2-14 GB free RAM). (3×)
- A restored snapshot leaves a lane "offline" in adb -> `phoney.ps1 avd reset -Lanes <name> -Level cold` (a warm reset keeps the offline state).

## kitty
- Working after a push in a merged clean worktree -> run every later command with absolute paths into it, never cd then a command that falls back to the live clone (cleanup swept the worktree: hard failure). (1x)
- Reading ISO times with ConvertFrom-Json -> compare as DateTimeOffset or keep them text (-AsHashtable, then ToString('o')) (DateTime interpolation drops fraction and offset: same-second ties broke ordering). (1×)
- A goody test that creates and drops tenants fails once in a parallel kit-tests run -> rerun that area alone before calling it a regression (areas share the machine). (2x)
- A test string holds a regex -> put it in a here-string or a variable (an unbalanced paren in a single-quoted string inside a double-quoted subexpression does not parse). (2x)
- Kit tests clean up -> remove only the fake files they wrote, never a whole folder (Remove-Item adapters -Recurse broke the bossy area for 2 days when a core function moved into adapters/). (1×)
- Scripted replace pairs in PowerShell -> wrap each concatenation in parentheses (the comma binds tighter than +: @('a', 'b' + 'c') has 3 items). (1x)
- Profiling a live supervise -> use a scratch copy; back up supervise-state, lock, report and .runtime/work/deploys/plan-cache.json first, restore after (a live profile overwrote them). (1×)
- Naming a scripted edit helper or a new kit function -> check the name with Get-Command / `git grep 'function <Name>'`, full verb-noun names only (an alias Rd = Remove-Item deleted README.md and lib.ps1; a second Format-KitCell replaced the first). (2x)
- Writing a file that holds regex or Windows paths -> use the Write tool (Bash heredocs in this harness mangle backslashes). (2x)
- Editing a CRLF kit file -> the Edit tool or pwsh ReadAllText / Replace / WriteAllText, never sed -i from Git Bash (it rewrites LF). (1x) (3×)
- Naming a test variable -> never reuse a name of the area file or the harness in any case (q vs Q, $sRc vs $src) (pwsh names are case-insensitive). (3×)
- Adding agents/<x>.md -> update the router row, reach mentions and manifest in the same commit (pre-commit lint ROUTER-UNROUTED, REACH-MENTION, MANIFEST blocks a lone file). (3x)
- Kit token cap work -> measure the whole pass's headroom first (one trim plan), then one file per agent, never trim a file another agent edits, prove each trim by token or AST equality (parallel trims collided). (4×)

## revy
- Reviewing an MR in a main checkout -> read diffs with `git show <sha>:path` or `git diff <base>...<sha>`, never git checkout there (a main checkout may sit on a detached head others use). (2x)

## Decisions
- 2026-11-14 Debate: context Characters unseen, 0 disputes in 448 msgs · decision (owner) Characters, disputes, trigger debates: core, never trimmed for caps; the owner decides splits · consequences buildy.js disputes + debate, rechy / revy kinds debate / dispute, lint MANIFEST, workflow cap 16500.
- 2026-11-14 Kit size: context a whole-kit cap kept parts off main · decision (owner, supersedes 2026-10-21) all on main, vendor adapters run when config selects them; a role starts <= 12k tokens, the rest via SKILL.md pointers; repo total INFO · consequences lint START-BUDGET, ORPHAN-DOC.
- 2026-10-16 Deploys: context agents proposed deploys · decision `deploy.trigger: owner` (owner): nobody asks or proposes; a person says `deploy <env>`, the coordinator deploys at once · consequences supervise has no DEPLOY ASK under owner.
- 2026-10-16 Crew: context many agent types · decision 4 agents devy, revy, checky, kitty (owner) · consequences lint AGENT-TYPE / NON-CREW; old names only in `_manifest.renamed`.
- 2026-10-16 NOT_TESTED: context untested checks closed tasks · decision one stronger retry, then failedTesting on shared envs; local items ENV-FIX, never failedTesting (owner).
- 2026-10-16 Leases: context resources held by fixed hours · decision every resource has a live holder; no holder for idle.graceMinutes -> released; services start only from a lease or a person (owner) · consequences lint LEASE-HOLDER.
- 2026-10-16 Readability: context indentation halving and aliases to save tokens · decision normal indentation and full cmdlet names (owner).
## briefy
- A review sheet of 100+ items -> split verification across read-only agents by surface plus one endpoint-inventory agent, each writing one fixed-shape file, then merge (one agent ran out of context). (1x)
- Launch args mode -> feature, bugfix or resume; map a new-work ask to feature (buildy.js rejects anything else, e.g. build, at once). (1x)
## opsy
## watchy
## rechy
- A Drive .xlsx / .docx -> download once with gws drive files get alt=media --output, dump to one text file, read that file once (re-reading the binary wasted calls). (1x)
- Checking an adapter against a vendor API -> read the vendor reference (an llms.txt index lists .md pages) and diff request and response shapes field by field (adapters drifted from the vendor). (1x)
