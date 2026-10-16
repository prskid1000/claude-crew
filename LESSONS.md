# Kit lessons
Active rules, one line each, newest first, `(n×)` = times seen. Read only your skill's section: `orch.ps1 learn -Read -Skill <skill>`
(it adds LESSONS.local.md, the org's git-ignored lessons). Retired lines leave the file: `orch.ps1 learn -History` lists them (git +
`.state`). Managed by `orch.ps1 learn`.

## orchestrate
- Never launch a wave for an explain-or-plan request; check the request kind first (a 9-agent wave once built nothing). (4×)
- (6×) MR state comes from devtools.py merge output or the host, never from an agent's prose; scheduled (waiting for green) and merged are two states; reconcile before consumer merges or promotes.
- The owner asks for something destructive (clean a folder, reset a branch) while runs go on: do it yourself after they finish; agents never act on relayed requests outside their items.
- Contracts file: agents append, never overwrite — re-check your note is still there after agents publish shapes; a contract change mid-wave goes into the contracts file AND the brief's bottom. (3×)
- Overlapping agents: brief them to rebase only after the sibling MR merges (one conflict resolution, not two).
- QA results are fixed at once, never held until their run finishes: one bugbrief per failedTesting or [Bug] task, ONE /buildy for all open now; later ones go into the next wave. Give `bugbrief` repo@branch when a repo ships two products from different branches.
- ALWAYS pass `mandate` (the owner's own words) to /buildy and /testy: the harness relays the latest chat message as "the request that wins". (3×)
- After merging an MR that adds a dependency, add it to the shared linkFrom tree yourself (exact pinned version: `npm pack` + tar into `node_modules/<pkg>`); never a full install there.
- Briefs: git-grep the target branch before listing work on a second branch; quote producer contracts verbatim; port a sibling wave's review findings into the next brief; items that need a product concept -> one decisions doc, a follow-up wave once decided. (4×)
- Answer QA testers in `<runDir>/lead-notes.md` (they re-read it), never SendMessage them. Items a run could not publish: `qa.ps1 finalize` from the on-disk results.json.
- Confirm API MRs merged before QA; register consumers with `orch.ps1 track add -MergeAfter '<web>!<iid>><api>!<iid>'`. (6×)
- NEVER SendMessage a running workflow agent by its agentId: it resumes a duplicate in the same worktree (the hook blocks it); relay through `<brief>.contracts.md`. (3×)
- Group agents by AREA (screens/packages), not item count; write overlaps and contracts into the brief; ~15 parallel devy queue fine on the memory gate.
- Never set tasks to `inTest` before the deploy; `orch.ps1 deploy intest` sets it from the CI / host state.

## dev-kit
- (2×) An LLM or MCP-path answer needs live sampling (5 fresh chats) on an env that has the MCP URL; the local env may lack it. Sample on a free env before merge, or mark needsLiveCheck on the tester guide with the env requirement.
- (4×) A task can span repos and target branches (one product's half on another branch): before creating worktrees run `git log --grep <task>` on each target and check the brief's repo table lists them all.
- (3×) Precondition helpers that throw a generic runtime error map to HTTP 500: use the codebase's validation helpers that return 400, and grep every call site in the same change.
- (2×) Changing an API status code or stale fix notes: grep the API test specs for the endpoint path and delete the old known-bug blocks in the same MR; a 500->400 change breaks pinned specs.
- (2×) Never persist secrets from a task or queue payload (headers, env, bearer tokens, credential fallbacks) to a db, WAL, log or temp file: keep them in process memory, store NULL, chmod any db file on every open, grep the host env var NAMES before removing a fallback.
- (3×) Edits on mixed CRLF/LF files: Get-Content -Raw .Replace with `n no-ops silently, [IO.File] relative paths resolve against the process cwd, python without newline='' drops CRLF, quoted Bash heredocs break. Use Edit with exact strings + `git diff`, or a script with absolute paths.
- (5×) Web local checks: linked node_modules can be older than the target (another branch's checkout): typecheck/builds may fail, tsc skips templates, spec.mjs can't bundle framework-DI specs. Spec pure framework-free helpers; templates: local env or "template unverified, left to CI". No reinstall.
- (2×) A guard fix for one app goes to its sibling copy in the same wave (the same screen or endpoint in a sibling product): a fix that clears or matches state must match method and path, not just any success.
- (4×) A git host 500/502 outage or a CI gateway timeout fails a job while the code is fine: check the job log, retry the job on the same sha, merge only after a green run; never change code for it.
- (4×) The read-only SQL MCP server often fails to connect: use the org's fallback (org rules), read-only, and note it in the MR; ask the coordinator for migration timestamps instead of picking one; insert changelog includes in timestamp order.
- (3×) Testing docs: write each Expected from the code you shipped (layout, which rows appear, button placement), not from the brief or the bug text; re-read the final diff before publishing. A timing Expected comes from a measurement, not the goal.
- (2×) Screenshot capture clones of a flex/grid page keep the live height, so flex-grow children push later content off the capture: set flex-grow 0 / flex-basis auto in the clone and check the picture starts with the first table row.
- (2×) Tracker status on a resumed or split task: `track` promotes a task once every MR it knows has merged, so a late MR leaves it promoted early. Register the planned repos (`track add -Task <id> -Discover`) before any sibling merges; read the current status before setting one.
- (4×) Moving a job off the request path (background thread, async index, retry wrapper): grep its other callers; never delete old data before the new is built (swap in one locked step); scope retries to callers needing them; readiness = listener/health endpoint answering, not first startup log.
- (8×) Resuming an area: `dev.ps1 wt status` and `git log origin/<target>..<branch>` first; vanished worktree: `wt new` on the same branch; stalled WIP: compile, targeted tests, review the diff; commit WIP at each green step; takeovers often skip the testing doc: check MR body and tracker comments.
- (18×) Mocks hide producer behaviour: fixtures from captured payloads; replay write semantics (deep-merge PATCH keeps absent keys); run dumped SQL read-only on a replica; flag-off: golden from origin/<target>, JSON compare; call the real method; test guards via the real tool; dates server-side.
- Optional context (date format, locale hint) never gates the main action; undo/revert/expiry: set the terminal state only when the revert completes; decide access from structured data, not regex; anchor expiry to the source record's timestamp; a stored reason/flag clears when its state ends. (5×)
- UI lifecycle: placement bugs need a committed structural spec over real templates; async init: destroyed guard after every await, unregister on destroy; route list mutations through one pure resolve-active helper; check new transient UI states against the template branch rendering them. (8×)
- Re-read `<brief>.contracts.md` AND the brief's bottom before every commit and push (scope changes mid-wave) and reconcile your diff; never overwrite a typed user draft; show the server's 400 text. (5×)
- Cross-repo contracts: quote producer validation verbatim; the producer accepts both spellings while clients vary and opens its MR first; never invent limits or guess endpoints; check merge order from the producer's merge state; a producer DTO change needs its consumer in the same wave. (18×)
- One-path fixes keep coming back: test sibling endpoints, every error branch, the round-trip; a new branch in a shared method: grep every caller/sender (proxies, portals, other products), list each in the MR; a business rule goes in every writing path, as the data services define it. (21×)
- Before tightening validation (allow-lists, size/char caps, formats) grep every client caller for its real encoding; list each old-accepted input and test it or state it as newly rejected. (6×)
- Forms that rebuild a payload from visible fields wipe stored values: prefill from the record and send unchanged values; the API never clears absent fields; a PUT binding the raw entity resets fields the form never sends; a lookup after load must not overwrite the stored derived value. (7×)
- Side effects after a service call: reload and check it took effect; grep the flow for an existing call before adding one; test the no-op branch; a queueing endpoint's 200 is not "already on server". (3×)
- Mappers that build an entity in steps: a flag read from a party early misses parties resolved later; grep every later setter, add a post-pass and a final-entity test. (3×)
- Feature/isolation gates: gate only what the feature introduced, on the flag, not request content; on/off tests; status-set gates list every terminal status; shared-aggregate fixes keep existing numbers (feature-OFF test); flags whose safety lives in a separately deployed service ship OFF. (13×)
- Shared multi-environment services: environment is part of tenant identity (DB name, cache key); external calls after commit on a bounded executor; read-only views get a wall-clock bound; secret temp files in a 0700 folder swept by age; noise classifiers match client aborts only at top level. (2×)
- Data-fix migrations: backup table with a restoring rollback; non-transactional DDL in separate changeSets (backup, then delete), DROP IF EXISTS first; a retried changeSet inserting bookkeeping rows needs a NOT EXISTS guard; derived totals recompute the original, test parts sum to the whole. (4×)

## qa-kit
- (2×) Local web start needs free RAM for the gate (12.4 GB + keep 10 GB): check RAM before launching web items, or testers run API checks first.
- (2×) Report stays at or under 900 words and each sentence under 25 words: write the fact list, link the evidence, and check prose before publish.
- (4×) An upstream AI service's 5xx (e.g. 504s while its workers recycle) fails assistant checks on the web side: check that service's health before FAIL and file the failure under its owner.
- (5×) Every NOT_TESTED check states its cause in results.json and the outcome line; a bare count hides why (and NOT_TESTED sends the task back to its developer).
- (2×) Check the health of the MCP servers the run uses before it starts and record it in lead-notes.md; checks needing a down server use the API or scripts instead.
- (4×) `finalize -Check -FixNames` fixes names only: before publish confirm each listed file exists with a supported type (re-save .bin as .json or .txt) and compare results.json with the uploaded list (a warning alone hid a gap).
- (5×) qa.ps1 api in PowerShell: never pipe a -Save call into Select-Object -First N (stops before writing evidence); never Out-String long JSON (wraps, corrupts keys): read .response.body from the -Save file; variables are case-insensitive ($o overwrites $O); no passwords in results.json/reports.
- (2×) A FAIL found during a retest: check the build from before the MR under test (old build, or git blame on the failing line); not caused by the MR -> `defect: new` (it becomes the ask's [Bug] task), with that evidence.
- (3×) A retest of a fix in shared code exercises every caller and every screen that reads the same code path or stored record, not only the reported screen.
- (3×) Flags switched on for a retest are restored at teardown and noted in lead-notes.md; the next run starts from the documented state.
- (3×) Lanes that share one admin user share the assistant chat list: give each lane its own session key and delete only your own files.
- (4×) Lead notes can widen scope mid-run: re-read lead-notes.md before each check; a check the lead requires goes into the run item (`qa.ps1 retest -Only <ids>` plus the check in the guide), never only into lead-notes.md.
- Deployed? Before any FAIL run `qa.ps1 deployed` for EVERY repo of the task (a consumer can be live while its producer is not); a manual deploy the owner confirms counts as live after an API marker check; the test app can be redeployed mid-run: re-check its version before finalising FAILs. (8×)
- (3×) Layout fixes (scroll, max-height, drag bounds): test the smallest and largest supported viewports with real wheel scrolling (scrollIntoView hides overflow:hidden clipping).
- (6×) Guide data drifts on shared environments: create your own data through the API and record it; a later change to a screen: test the same intent (PASS_WITH_NOTE (a)); a guide vs screen disagreement: read the code, quote both readings, ask the lead before the run closes.
- (3×) Parallel items toggling a shared environment setting cause transient 403s elsewhere: serialise those checks; keep one account with the feature OFF for "nothing else changed" checks, created before the run (missing: 3 NOT_TESTED in one day).
- (8×) Screenshot/canvas-capture checks: time per screen and page type, wait for pageSize table rows before timing, re-run once at low load before FAIL; a capture blocking the page past its cap is FAIL with the profile saved; compare each capture with a live page shot.
- (2×) Skipping an item: write the skip reason into run.json.
- A server-side config check (model, temperature, fallback) from the API lane: verify it in the deployed code plus its unit tests and name the env overrides you could not see; still unprovable -> NOT_TESTED with cause.
- A test environment's signing key can differ from the repo config (re-signed tokens get 401): prove cross-product token refusal by unit test or with the deployed key; a separately deployed service may be undeployed: check first.
- Component-library overlays render outside the component (e.g. `.cdk-overlay-container`): hover-open dropdowns need `hoverSel`; date pickers ignore typed text (click the cell); virtual-scrolled options need the overlay list scrolled; paginate and wait for the first row's id to change. (2×)

## local-env
- Migration snapshots per deploy cost minutes and GBs: reversible (LIGHT) changeSets are reverted exactly instead (a rollbackCount on a changelog cut down to the leaving changeSets touches nothing else); only HEAVY ones get a sandbox or snapshot.
- Sandbox DB isolation: never renamed schema copies (apps hardcode schema names and migrate the real ones); a separate DB server per sandbox with real names, and verify the main DB is untouched (data AND migration markers) after the first sandbox run.
- Local DB drift (a leftover table from a dropped layer, a missing definer user or grant) fails a deploy's migrations: report it for `refresh` / the owner; never repair the shared DB by hand.

## android-swarm
- (3×) Lanes drop offline or fail to boot at ~2-14 GB free RAM (a web lane's headless browser plus qemu): no heavy web lanes beside 3 emulators; check `swarm.ps1 status` before each check and `swarm.ps1 ensure -Agent <id>` at once.
- A release APK cannot reach a local http API: use the local-env APK (`swarm.ps1 build -Local`, `acquire -Apk local` reverses the API ports); debug builds need Metro / a dev launcher.
- A restored snapshot can leave a lane "offline" in adb -> `swarm.ps1 avd reset -Lanes <name> -Level cold`.
- Never `adb kill-server` and never touch another lane's serial; set `$env:ANDROID_SERIAL` on every command.

## kitty
- Never use short helper names in builder or edit scripts: `r`, `rd`, `h`, `del`, `diff` are aliases that beat functions (`rd` = Remove-Item deleted live files once); Set-Location to the worktree first; Get-Command a name before defining it.
- Run file edits with absolute paths: `[IO.File]` resolves against the PROCESS directory (often the live clone); check `git -C <live kit> status` after any scripted edit.
- Never edit the live clone: runs execute its scripts mid-run; only `kittool.py audit --fix/--fill` touches it.
- Another kit branch may be open (`git -C <kit> worktree list`): diff its changed files before fixing the same file; overlap -> propose.
- `kittool.py audit scan` lines are candidates: prove each one (caller, input, effect) before it becomes a finding.

## revy
