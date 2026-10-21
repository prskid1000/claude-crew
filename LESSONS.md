# Kit lessons
Active rules, one line each, newest first, `(n×)` = times seen. Read your skill's section: `orch.ps1 learn -Read -Skill <skill>`
(adds the git-ignored LESSONS.local.md). Retired lines: `orch.ps1 learn -History` (git + `.state`). Managed by `orch.ps1 learn`.

## orchestrate
- Explain-or-plan request: never launch a wave (a 9-agent wave once built nothing). (4×)
- MR state comes from devtools.py merge output or the host, never an agent's prose; scheduled (waiting for green) != merged; reconcile before consumer merges or promotes. (6×)
- Destructive owner asks (clean a folder, reset a branch) while runs go on: do them yourself after the runs end; agents never act on relayed asks outside their items.
- Contracts file: agents append, never overwrite; re-check your note after agents publish; a mid-wave contract change goes into the contracts file AND the brief's bottom. (3×)
- Overlapping agents rebase only after the sibling MR merges (one conflict resolution, not two).
- QA results are fixed at once: one bugbrief per failedTesting or [Bug] task, ONE /buildy for all open now; give `bugbrief` repo@branch when a repo ships two products from different branches.
- Always pass `mandate` (the owner's words) to /buildy and /testy: the harness relays the latest chat message as "the request that wins". (3×)
- A merged MR that adds a dependency: add it to the shared linkFrom tree yourself (the exact version, unpacked in place); never a full install there.
- Briefs: git-grep the target branch before listing work on a second branch; quote producer contracts verbatim; port a sibling wave's review findings; items needing a product concept -> one decisions doc, a follow-up wave. (4×)
- Answer QA testers in `<runDir>/lead-notes.md` (they re-read it), never SendMessage; items a run could not publish: `qa.ps1 finalize` from the on-disk results.json.
- Confirm API MRs merged before QA; register consumers with `orch.ps1 track add -MergeAfter '<web>!<iid>><api>!<iid>'`. (6×)
- Group agents by AREA (screens/packages), not item count; overlaps and contracts go into the brief; ~15 parallel devy queue fine on the memory gate.

## dev-kit
- LLM or MCP-path answers need live sampling (5 fresh chats) on an env with the MCP URL: sample on a free env before merge, or mark needsLiveCheck with the env. (3×)
- A task can span repos and target branches: before worktrees run `git log --grep <task>` on each target; the brief's repo table lists them all. (4×)
- Precondition helpers throwing a generic runtime error map to HTTP 500: use the validation helpers that return 400; grep every call site. (3×)
- An API status-code change: grep the API specs for the endpoint and delete old known-bug blocks in the same MR (500->400 breaks pinned specs). (2×)
- Never persist secrets from a task or queue payload (headers, env, tokens) to a db, WAL, log or temp file: process memory only, store NULL, chmod db files on open; grep host env var NAMES before removing a fallback. (2×)
- Mixed CRLF/LF edits: `-Raw .Replace` with `n no-ops, `[IO.File]` relative paths resolve against the process cwd, python without newline='' drops CRLF: use Edit + `git diff`, or a script with absolute paths. (3×)
- Linked shared dependencies can be older than the target: typechecks / builds may fail, spec.mjs can't bundle framework-DI specs. Spec framework-free helpers; the rest: local env or "left to CI". No reinstall. (6×)
- A guard fix for one app goes to its sibling copy in the same wave; a fix that clears or matches state matches method and path, not any success. (2×)
- Git host 500/502 or CI gateway timeout: check the job log, retry on the same sha, merge only after green; never change code for it. (4×)
- A read-only DB tool can fail to connect: the org's read-only fallback, noted in the MR; migration ids come from the coordinator, applied in id order. (4×)
- Testing docs: each Expected from the shipped code, not the brief or the bug text; re-read the final diff; a timing Expected comes from a measurement. (3×)
- Screenshot clones of flex/grid pages keep the live height: set flex-grow 0 / flex-basis auto in the clone; the picture starts with the first table row. (2×)
- Resumed or split task: `track` promotes once every known MR merged; register planned repos (`track add -Task <id> -Discover`) before any sibling merges; read the status before setting one. (2×)
- A job moved off the request path: grep its other callers; never delete old data before the new is built (swap in one locked step); scope retries; readiness = health endpoint answering. (4×)
- Resuming an area: `dev.ps1 wt status`, `git log origin/<target>..<branch>`; vanished worktree: `wt new` on the same branch; stalled WIP: compile, targeted tests, review the diff; takeovers often skip the testing doc. (8×)
- Mocks hide producer behaviour: fixtures from captured payloads; replay write semantics (PATCH deep-merge); dumped SQL read-only on a replica; flag-off golden from origin/<target>; call the real method; dates server-side. (18×)
- Optional context never gates the main action; revert/expiry sets the terminal state only when it completes; access from structured data, not regex; expiry anchored to the source timestamp; a stored reason clears with its state. (5×)
- UI lifecycle: placement bugs need a structural spec over real templates; destroyed guard after every await, unregister on destroy; list mutations through one resolve-active helper; new transient states checked against the template. (8×)
- Re-read `<brief>.contracts.md` AND the brief's bottom before every commit and push; never overwrite a typed user draft; show the server's 400 text. (5×)
- Cross-repo contracts: quote producer validation verbatim; the producer accepts both spellings and opens its MR first; never invent limits or endpoints; a producer DTO change ships with its consumer in the same wave. (18×)
- One-path fixes come back: test sibling endpoints, every error branch, the round-trip; a new branch in a shared method: grep every caller (proxies, portals, other products), list each in the MR; a business rule goes in every writing path. (22×)
- Before tightening validation grep every client caller for its real encoding; list each old-accepted input: tested or stated as newly rejected. (6×)
- Forms rebuilding a payload from visible fields wipe stored values: prefill from the record; the API never clears absent fields; a PUT binding the raw entity resets unsent fields; a lookup after load keeps the stored derived value. (7×)
- Side effects after a service call: reload and check; grep for an existing call before adding one; test the no-op branch; a queueing endpoint's 200 is not "on server". (3×)
- Mappers building an entity in steps: a flag read early misses parties resolved later; grep later setters, add a post-pass and a final-entity test. (3×)
- Feature gates: gate only what the feature introduced, on the flag; on/off tests; status-set gates list every terminal status; shared-aggregate fixes keep existing numbers; flags whose safety lives in a separately deployed service ship OFF. (13×)
- Shared multi-env services: the env is part of every key (DB name, cache key); external calls after commit on a bounded executor; read-only views get a wall-clock bound; secret temp files in a 0700 folder swept by age. (2×)
- Data-fix migrations: backup table with a restoring rollback; non-transactional DDL in separate steps, DROP IF EXISTS first; retried bookkeeping inserts need NOT EXISTS; derived totals recompute the original, parts sum to the whole. (4×)

## qa-kit
- (2×) A publish run that exits 0 without a published report or tracker comment is a failure: check the publish output and the tracker, not the exit code.
- A local env start needs free RAM for the gate (its need + gate.keepFreeGB): check RAM first, or run the API checks first. (3×)
- An upstream service's 5xx fails the checks that use it: check that service's health before FAIL; file it under its owner. (4×)
- Every NOT_TESTED check states its cause in results.json and the outcome line. (5×)
- Check the MCP servers the run uses before it starts (record in lead-notes.md); checks needing a down server use the API or scripts. (2×)
- `finalize -Check -FixNames` fixes names only: confirm each listed file exists with a supported type and compare results.json with the uploaded list. (4×)
- `qa.ps1 api` in PowerShell: never pipe a -Save call into Select-Object -First N; never Out-String long JSON: read .response.body from the -Save file; variables are case-insensitive; no passwords in results or reports. (5×)
- A FAIL found in a retest: check the build from before the MR (old build or git blame); not caused by the MR -> `defect: new` with that evidence. (2×)
- A retest of a fix in shared code covers every caller and screen on the same code path or record. (3×)
- Flags switched on for a retest are restored at teardown and noted in lead-notes.md. (3×)
- Lanes sharing one user share its per-user server state: one session key per lane; delete only your own data. (3×)
- Lead notes can widen scope: re-read lead-notes.md before each check; a required check goes into the run item (`qa.ps1 retest -Only <ids>` + the guide). (4×)
- Before any FAIL run `qa.ps1 deployed` for EVERY repo of the task; an owner-confirmed manual deploy counts after an API marker check; re-check the test app's version before finalising FAILs. (8×)
- Layout fixes: test the smallest and largest viewports with real wheel scrolling (scrollIntoView hides overflow:hidden clipping). (3×)
- Guide data drifts on shared envs: create your own data via the API; a later screen change: test the same intent (PASS_WITH_NOTE (a)); guide vs screen: read the code, quote both, ask the lead. (6×)
- Parallel items toggling a shared env setting cause 403s elsewhere: serialise them; keep one feature-OFF account, made before the run. (3×)
- Capture checks: time per screen and page type, wait for pageSize rows before timing, re-run once at low load before FAIL; a capture blocking past its cap is FAIL with the profile saved. (9×)
- A skipped item: its reason goes into run.json. (2×)
- A server-side config check (model, temperature, fallback) from the API lane: verify the deployed code and its unit tests, name unseen env overrides; unprovable -> NOT_TESTED with cause.
- A test env's signing key can differ from repo config: prove cross-product token refusal by unit test or the deployed key; check a separate service is deployed first.
- Library overlays render outside the component (an overlay container): hover dropdowns need `hoverSel`; date pickers need a cell click; virtual lists need the overlay scrolled; paginate and wait for the first row's id to change. (2×)

## local-env
- Local DB drift (leftover table, missing definer or grant) fails migrations: report it for `refresh` / the owner; never repair the shared DB by hand.

## android-swarm
- (2×) The android-build gate needs about 11.5 GB + 10 GB free: with a phone and the rm api up it queues 80-90 min. Request an envfix or build before other agents lease phones.
- Lanes drop offline at ~2-14 GB free RAM: no heavy web lanes beside 3 emulators; `swarm.ps1 status` before each check, `swarm.ps1 ensure -Agent <id>` at once. (3×)
- A restored snapshot can leave a lane "offline" in adb -> `swarm.ps1 avd reset -Lanes <name> -Level cold`.

## kitty

## revy

## Decisions
- 2026-10-21 Kit size cap: context 400k tokens · decision (owner, replaces "no function removed") total <= 200k: drop dead code, duplication, features; optional parts on the `extras` branch (`kittool.py extra add <name>`); never minified · consequences cap 200000, lint BUDGET / BUDGET-CAP.
- 2026-10-16 Deploys: context agents proposed deploys · decision `deploy.trigger: owner` (owner): nobody asks or proposes; a person says `deploy <env>`, the coordinator deploys at once · consequences supervise has no DEPLOY ASK under owner.
- 2026-10-16 Crew: context many agent types · decision 4 agents devy, revy, checky, kitty (owner) · consequences lint AGENT-TYPE / NON-CREW; old names only in `_manifest.renamed`.
- 2026-10-16 NOT_TESTED: context untested checks closed tasks · decision one stronger retry, then failedTesting on shared envs; local items ENV-FIX, never failedTesting (owner).
- 2026-10-16 Leases: context resources held by fixed hours · decision every resource has a live holder; no holder for idle.graceMinutes -> released; services start only from a lease or a person (owner) · consequences lint LEASE-HOLDER.
- 2026-10-16 Readability: context indentation halving and aliases to save tokens · decision normal indentation and full cmdlet names (owner).
