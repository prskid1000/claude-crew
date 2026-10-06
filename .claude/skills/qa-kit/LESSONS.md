# QA lessons (self-improving — read before testing)

Maintained by each `/test-and-close` learn step and `/kit-retro`. Newest first inside each section. Keep each line
actionable; `(n×)` = times observed. Lessons that stay true for a while get promoted into SKILL.md by `/kit-retro`.
UI gotchas for one product go under a `## Project: <name> (target <target>)` heading (selectors, test accounts to use or never touch,
app login steps) — never passwords; those live only in `targets.local.json`.

## General
- (fixed in kit) Two test-and-close workers mapped their first app item to lane 1 and leased it under the same id, so both "owned" the phone (the board CLAIM caught it). Phone leases are now per worker (`qa-<instance>-<lane>`), so the second waits in the fair queue, and extra workers start on lane (instance-1).
- (fixed in kit) A web item finished with device checks PENDING and the run ended with them untested until the lead added an app item by hand. The workflow now appends an app follow-up `<code>A` (only = the PENDING checks) to run.json and runs it on the phones in the same run.
- (fixed in kit) `skipClose` items saved nothing to disk (verdicts only in the workflow's return value) and never got a finalize.json, so the supervisor kept their run "unfinished" and held its bug batch. They now write `<code>\results.json` + `held.json`, which supervise and qa-seat treat as finished. Items that share one task don't need skipClose: finalize already keeps the task open until all of them are published.
- (fixed in kit) Short-form `/test-and-close { runDir }`: the small load-run agent sometimes returned run.json without `items[]`, so workers died at start. The loader now validates items[] and retries once on a stronger model; if it still fails, pass the full run.json object as args.
- (fixed in kit) Reviewers could not tell what a FAIL screenshot was about: `annotate.ps1` (box / arrow / label on any screenshot, one call) and `ui.ps1 shotmark` (screenshot + box on elements by text / #id) now exist. Mark every FAIL screenshot.
- (fixed in kit) finalize warned on valid files (pdf/csv exports, `_verify_` without nn) and skipped evidence saved outside shots\/evidence\ or given as absolute paths: finalize now collects listed evidence from anywhere under the run dir and drops helper scripts.
- (7×) Evidence hygiene: finalize warns on off-standard names (CODE-ID_NN_slug) and on files listed in results.json but missing (helper .mjs scripts, absolute paths). Save evidence into the item folder with the standard name, list only files that exist, relative names.
- (2×) The test web app can be redeployed mid-run: re-check the bundle version/timestamp before finalising FAILs and re-run them on the new build.
- (25×) Testers hid real defects in PASS_WITH_NOTE / findings. Any 5xx, stuck flow or unsaved data is FAIL — the note audit will reclassify it anyway, so report it right the first time.
- Test environments often run an older build than the target branch. Before a FAIL, check the change is deployed (endpoint exists, web bundle contains the change); otherwise NOT_TESTED "not deployed yet".
- Small/cheap close agents sometimes refuse to publish; that's why `autoclose.ps1` exists — always start it for a run.
- Guides go stale when later packages change screens; test the same intent on the current screen and say so (PASS_WITH_NOTE), not FAIL.
- Keep web agents to ≤ 2 Chrome ports; killSession() when done — other sessions run Maven/Angular builds.
- Component-library dropdown menus that open on HOVER (e.g. ng-zorro `nz-dropdown`) need `hoverSel(page, selector)`; menu items render in an overlay container (`.cdk-overlay-container`), not under the trigger.
- A "Enable notifications" toast can cover the header's right side; browser.mjs grants the permission so it doesn't appear.
- Use a secondary test user for per-user preference checks, and keep one tenant/account with the feature OFF for "nothing else changed" (R) checks; never change its settings.
- (fixed in kit) api.ps1 crashed on a binary response (image/file download) and, called from Git Bash, a /api/... path arrived as C:/Program Files/Git/api/... (MSYS path conversion). Binary bodies are saved next to the evidence as <Save>.body.<ext> with a text stub in the JSON; MSYS-mangled paths are restored.
- (fixed in kit) A run launched with args.skipClose still closed its task (skipClose was read per item only), and finalize closed a task that had NOT_TESTED checks (a dependency was not deployed). Run-level skipClose now applies to every item; finalize keeps a task with NOT_TESTED checks open and comments why (run.json tracker.closeWithNotTested overrides).
