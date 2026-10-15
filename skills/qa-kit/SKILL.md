---
name: qa-kit
description: "Load when: you test deployed work on a test environment (qa-tester / qa-verifier agent, or one change checked directly: router R10), write a tester guide for a person (R9), or set up a QA run as the lead. Not when: a batch of deployed tasks is to be tested by agents -> /test-and-close via orchestrate; static code audit -> tech-audit; emulator lanes -> android-swarm; coding -> dev-kit."
---

**Load when** (all must hold): the work is testing, or writing testing instructions, for a change deployed (or about to be deployed)
to a **test environment**; you are a `qa-tester` / `qa-verifier`, the main session on R9 / R10, or the lead preparing a run (orchestrate step 7).
**Not when:** several deployed tasks should be tested by agents -> `/test-and-close` (load `orchestrate`); code audit without a
deploy -> `tech-audit`; booting or resetting emulators -> `android-swarm`; fixing what failed -> `dev-kit` / bug wave.
**Hands off to:** `finalize.ps1` (report + tracker close + `[Bug]` tasks, run by /test-and-close), the coordinator (bug tasks →
orchestrate E9), the person who tests by hand (the published guide, G3).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` | step 0 (and G0, L0), before anything else |
| `HISTORY.md` | never read for work (retired lessons) |
| `reference/evidence-standard.md` | step 4 when you save anything other than a screenshot or `api.ps1 -Save` JSON, or a name is unclear |
| `reference/tools-and-rules.md` | step 3 for a tool not shown below; step 4 when marking a FAIL shot; step 5 for a borderline verdict |
| `reference/runs.md` | lead steps L0-L3 (machine setup, run.json, seats, documents) |
| `templates/tester-guide.html` | G1 when `reports.type` is `gdocs` |
| `templates/tester-guide.md` | G1 when `reports.type` is `markdown` |
| `targets.example.json` | L0: copy to `targets.local.json` (environments + test logins; the only place for passwords) |
| `scripts/qa-seat.ps1` | step 1 (`acquire`; the workflow tells you how), `release` at the end |
| `scripts/deployed.ps1` | step 2, before any FAIL; L1, the lead's pre-run deploy check |
| `scripts/api.ps1` | step 3 (API as any user, `-Save` evidence) |
| `scripts/web/browser.mjs` | step 3 (web; read its header first) |
| `scripts/web/package.json`, `scripts/web/package-lock.json` | L0: `npm ci` in `scripts/web` (puppeteer-core) |
| `scripts/android/ui.ps1` | step 3 (app lanes; `$env:ANDROID_SERIAL` on every command) |
| `scripts/annotate.ps1` | step 4, marking a FAIL screenshot (any image) |
| `scripts/finalize.ps1`, `scripts/lib/report.ps1` | step 6 (`finalize.ps1 -Check`, evidence check only); run by /test-and-close's close step; by the lead for `skipClose` items (L3) |
| `scripts/autoclose.ps1` | L2, started in the background with every run |
| `scripts/add-retest.ps1` | L3, when a bug task's fix went live (retest item) |

## Tester / verifier steps (test environment only, never production)
0. Read `LESSONS.md` (general + per-project UI gotchas), then the guide and the run's `context` / `contextFiles`. Check the SQL/MCP tools once (<sql MCP>, <local DB MCP>, <other MCP> drop often) and note their state in the run log: replica SQL then goes through the run's own SQL helper script with the SQL helper's own venv python (its path is in the org rules; system python lacks boto3); on replica lag or timeout fall back to API GETs (`/api/site-visits/{id}`, `/api/runs/{id}/stops`, `/api/mail-audits`) and re-query later; a tool being down alone is never NOT_TESTED.
1. **Seat + board:** `scripts/qa-seat.ps1 acquire` (as the workflow says); `orchestrate/scripts/board.ps1 join -Agent <CODE> -Run <run>
   -Claims <phone serial>,chrome:<port>`; CLAIM/DUPLICATE → stop and report. Phones: `../android-swarm/phone.ps1 acquire|release`. Keep the phone lease
   through any wait under ~30 min (a lead decision, a deploy, a rebuild): release shuts the emulator down and re-acquiring queues
   20-40 min behind the RAM gate. Do not start gated tests while you wait for a phone.
2. **Deployed?** Before any FAIL: `scripts/deployed.ps1 -Mrs <repo>!<iid>,...` for every repo of the task; not deployed → NOT_TESTED "not deployed yet";
   MANUAL (deployed by hand) → the run's lead notes say whether it is live; unresolved there → NOT_TESTED, never FAIL.
3. **Test each check** with the tools: API `scripts/api.ps1 -Target <t> -As <user> [-Tenant <x>] -Method <M> -Path '/...' [-Body '<json>']
   [-Save <name> -OutDir <dir>]`; web `scripts/web/browser.mjs` (`session()` = one logged-in headless Chrome per port; `mark`, `shot`,
   `saveNet`, `hoverSel`; also for the main session's R10 checks and repros; a visible browser only when the owner asks to watch); app `scripts/android/ui.ps1` (dump / tap / tapid / type / swipe / shot / shotmark /
   wait / log). Tracker: `../dev-kit/scripts/tracker.ps1 view|comments <id>`.
4. **Evidence:** folder `<run>/<CODE>/shots` (web JPEG, app PNG) and `/evidence` (API/network/DB/log JSON); your scripts in `/scripts`.
   Name `<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>` (`what` lowercase-kebab ≤ 40 chars), e.g. `F2-T4_01_before-edit.jpeg`.
   PASS (UI) = one shot of the result (state change: before + after); PASS (API) = the request/response JSON; FAIL = failure shot
   **and** the failing call JSON (`saveNet`) or log excerpt + exact steps; verify = your own `_verify` files. Never a blank/loading/login
   page; open each image with Read before listing it; name each file to this standard when you save it and cite in results.json only
   files that exist and are not 0 bytes (`finalize.ps1 -FixNames` is a safety net, not the naming step; it renames files and rewrites results.json on disk). A listed file that is missing: capture it or record the gap in the run log, never drop the entry silently. Mark every FAIL screenshot: app
   `ui.ps1 shotmark <name> "<text>|#<id>" ["label"]`, web `mark(page, selector)` before `shot()`, any image `scripts/annotate.ps1 -In <f> -Rect 'x,y,w,h,label'`
   (`-Copy` keeps the original and writes `<name>-marked.<ext>`). Setup evidence for no one check: `<CODE>-00-<what>` (e.g. the deploy check).
5. **Verdict per check — defects are never notes:**
   - **PASS**: the expected behaviour was seen. **PASS_WITH_NOTE**: ONLY (a) guide text out of date because later, intended work
     changed the flow and the intent holds, (b) a purely cosmetic difference while behaviour is correct, or (c) the guide's expected
     text cannot be met for a reason outside the change (a platform/OS limit, or imprecise guide wording the code and design show was
     never intended) while the behaviour is right: check the code or ask the lead before FAIL and quote both readings. A guide-vs-screen
     disagreement the code does not settle goes to the lead before the run closes, never left as an open FAIL. (d) a check the guide
     itself makes conditional ("if the tenant has X", "conditional step") whose condition is false on the target: write "not applicable:
     <condition> is false here" with the evidence (setting value, schema query, API refusal). It is not NOT_TESTED (it does not keep the
     task open); it is FAIL only when the condition being false is itself the defect.
   - **FAIL**: any defect, in or outside the guide's steps: 5xx or unexpected 4xx, crash, stuck flow, data changed wrongly or not
     saved, wrong records affected, broken navigation, a missing screen the feature needs. Also: a silent 200 with empty data, a 5xx
     "fixed by a restart" (save the request/response and check observability; an unverified 5xx is FAIL), a wrong answer stated as fact
     with HTTP 200 (LLM checks: compare with the DB), a downstream 5xx that surfaces only in a finding, and errors in the first turns
     after a restart. Off-script defects → extra checks `X1`, `X2` ….
   - **Retests of a dev fix** fail on the sibling path: run the full reported flow end to end (create/import, edit round-trip, cancel
     in locked/terminal states, the list GET as well as the item GET, every locale key against the default locale), and every screen
     that reads the same stored record or rule (e.g. home step cards as well as the screen in the bug), and the screen a gate or check
     navigates to, using the same fixture (a gate fix can leave that screen's loader on the old rule, which leaves the flow stuck).
     Date/shift-rule fixes: also cross midnight and run a second shift on the same day through to End of Day.
   - **NOT_TESTED**: only when truly impossible here, with the reason and what you tried; tag each with `cause` in results.json (`no-mail-sandbox` | `phone-only` | `undeployed` | `env-data` | `tool-down`). A check that mails real recipients gets a non-mailing proof (the repo query on the replica with QA data) or is asked of the owner during prep, not left NOT_TESTED. "Not deployed yet" counts; "no time" never does.
     A part of the Expected you did not exercise (a second theme not rendered, a timeout path not triggered, checked via API only because
     the UI path is missing) is its own NOT_TESTED check, never a note; an unreachable screen the feature needs is FAIL.
   - **LLM-driven checks** (an AI assistant or decider) are intermittent: after a redeploy or long idle do a warm-up turn, then run
     each 5+ times in fresh sessions and record every answer with its timestamp; re-run a deviating result once before FAIL and keep
     the first and each deviating run as evidence. Set the check's `attempts` and `window` (conditions + UTC times) in results.json:
     a verifier must recreate them to refute the FAIL (else its verdict is `inconclusive` and the FAIL stays). Count the guide's runs
     only after the warm-up turn; readiness = the health/listener endpoint answering, not the first startup log line; before failing
     a 5xx in a restart window, check the service log for a worker recycle. Count or list questions: before testing compute every
     plausible DB definition of the entity (flags, types, active/deleted); numbers that change between sessions and each match some
     definition are a FAIL (definition drift), not data drift.
   - **PENDING**: tested later in another lane (the workflow adds an app follow-up `<code>A`). **findings**: context only, never defects.
6. **Leave:** write `results.json` and run `scripts/finalize.ps1 -RunDir <run> -Code <CODE> -Check -FixNames` (publishes nothing;
   renames off-standard evidence to `CODE-checkId_NN_slug` per `reference/evidence-standard.md` and rewrites results.json; exit 1 lists
   evidence named but missing, names it could not fix and duplicate check ids: fix and re-run until exit 0); then `board.ps1 leave`, release seat / phone / Chrome ports (`killSession()`),
   return the results the task asks for.

**Shared environment** (others test at the same time): data prefixed `QA-<CODE>` (app lanes `QA-L<n>-<CODE>`), delete only what you
created, an unexpected change may be another agent's (re-check before FAIL); change an environment setting only when a check needs
it, restore it at once, list it in `setup_changes`; per-user preferences on a secondary test user; never deactivate, delete or
re-password test logins; ≤ 2 Chrome ports per web agent; app lanes: only your serial, never `adb kill-server`. Project facts come
from the run's `context` / `contextFiles` and `LESSONS.md`, never from these generic files. An MCP server the run relies on (DB,
messaging) that failed to connect is a connection failure: note it in `lead-notes.md` / the run log and use the API or scripts
instead; it is never a missing capability and never on its own a reason for NOT_TESTED.

## Guide steps (a person tests by hand: router R9; dev agents at dev-kit 7b)
- G0. Read `LESSONS.md`; know the change (MRs, task) and the target environment.
- G1. Fill `templates/tester-guide.html` (`gdocs`) or `templates/tester-guide.md` (`markdown`): check ids, environment, accounts, data to
  prepare, steps and a concrete Expected per check, plus "unchanged" checks for what must not change. Always fill "Before you start /
  Feature switches": every setting or role that switches the feature on, checked ON before testing (a gate the tester cannot switch = NOT_TESTED).
- G2. Publish: `python ../dev-kit/scripts/devtools.py doc "<title>" <guide file>` (a `.md` guide is converted to HTML first, so tables survive).
- G3. Link it on the task (`tracker.ps1 comment` / `attach`) and in the MR; simple change → a how-to-test comment instead.

## Lead steps (setting up a run; orchestrate step 7)
- L0. Machine setup once: `reference/runs.md` "Setup" (targets.local.json, `npm ci` in `scripts/web`, swarm config, auth checks).
- L1. Run folder + `run.json` (shape: `reference/runs.md` and the header of `test-and-close.js`), guides exported to text.
  Pre-run deploy check: `scripts/deployed.ps1 -Mrs <every item's MRs>`; resolve each MANUAL repo (deployed by hand) with the owner or an
  ssh check before launching and write the answer in the run's `lead-notes.md`; NOT-DEPLOYED items wait or are left out.
  Pre-run prerequisites: for every guide, check on the target tenant/role each feature flag or setting (current value, who switches and
  restores it; ask the owner when one was turned off on purpose), the test data and accounts the steps need (a driver with a stocked van,
  franchise data, a soft-delete column, a role with the right authority and the role's screen switches (a screen switched OFF for the
  role makes deep links silently redirect to home), the record/stop/order types the scenario needs such as a
  COLLECT_DROP stop), a search/index rebuild (reindex) on each tenant when the change adds indexed fields (then compare each search
  result with the unsearched list for exact counts), a QA-owned record for any step that saves on shared data (APPLY, allocate,
  resource) so testers never write to someone else's run, the lane driver login's tenant, feature flags (<feature> persona, <feature> mode) and company country/timezone against the guide's tenant (the test tenant may be AE, not UK: +3h), reference data (the CustomerAgingReportGenerate stored procedure in information_schema.routines, feature_PARTIAL_DELIVERY_REASON codes, an employee-linked QA login, an INVOICED invoice; create or toggle through the API, restore at teardown), and server config the feature needs (e.g. an MCP URL); write
  each into `lead-notes.md`. Create up front what the API can create. Mark checks the lead cannot unblock as NOT_TESTED in run.json
  (item `skip` with the reason, the missing thing named) before testers start; an environment-level gate the tester cannot switch is
  NOT_TESTED with the setting named, never FAIL.
- L2. Launch `/test-and-close { runDir, kitDir }` and start `scripts/autoclose.ps1 -Journal <dir> -RunDir <run>` in the background.
- L3. Afterwards: publish `skipClose` items with `finalize.ps1 -RunDir <run> -Code <code>`; a bug fix went live → `add-retest.ps1`.

**Learn:** record surprises: `& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill qa-kit -Kind <kind> -Text "<what + fix>" -Ref <CODE-check>`.
