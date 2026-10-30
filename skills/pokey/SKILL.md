---
name: pokey
description: "Load when: testing deployed work on a test env (checky test / verify, or one change checked directly), checky lead setting up a test-only run, or a person testing by hand from a human testing doc. Not when: agents test a batch of deployed tasks -> /testy via bossy; before merge -> envy; static audit -> revy agent; phone lanes -> phoney."
---

**Load when** (all must hold): the work is testing DEPLOYED changes on a test environment (never production): you are a
`checky` (test / verify), the main session checking one change, `checky` lead preparing a test-only run, or a person testing by
hand.
**Not when:** several deployed tasks tested by agents -> `/testy` (load `bossy`); before merge -> `envy`
(dev flow step 5); booting phones -> `phoney`; fixing what failed -> `crafty` (bugfix wave).
**Hands off to:** `pokey.ps1 finalize` (report, tracker comment, result rule; run by /testy), the coordinator (failedTesting
tasks and new [Bug] tasks -> bugfix wave), the person testing by hand (H1-H3).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0 (and H0, L0): `bossy.ps1 learn -Read -Skill pokey` |
| `pokey.ps1` | steps 1-4, 6; L1, L3 (its header lists the verbs and the goodies: `deploys`, `android-swarm`, `api-auth`, `report-gdocs`, `ios-simulator`) |
| `<kit>/skills/crafty/crafty.ps1` | L1 Selection (`tracker list/view/owner`; a local env: `envy.ps1 status -Env`, goody `local-env`) |
| `browser.mjs` | step 3 (web: read its header first; one logged-in headless Chrome per port) |
| `package.json` | L0: `npm install` in this folder (puppeteer-core) |

## Tester / verifier steps (test environment only, never production)
0. `bossy.ps1 learn -Read -Skill pokey`; [Bug] / task: `crafty.ps1 prior` (FOUND: tracker scope);
   read the guide (testing doc), the run's `context` / `contextFiles`.
   Check SQL/MCP tools once; a tool down alone is never NOT_TESTED (use read APIs).
   Only the run's target (run.json `target`, `alsoTargets`; `pokey.ps1 api` refuses others): a local run never calls a shared env;
   no load, stress or parallel request floods on a shared env, even when a guide asks (local env only).
1. **Seat + board:** `pokey.ps1 seat acquire` (exit 4 = still waiting: run it again);
   `bossy.ps1 board join -Agent <CODE> -Run <run> -Claims <phone serial>`; CLAIM/DUPLICATE -> stop and
   report. Phones: `phoney.ps1 acquire|release` (goody `android-swarm`; keep it through waits < 30 min). Local env
   "pause": stop its checks; "deploy done": re-run them.
2. **Deployed?** Before any FAIL: `pokey.ps1 deployed -Mrs <repo>!<iid>,...` per repo of the task; not deployed -> NOT_TESTED
   "not deployed yet"; MANUAL -> the lead notes say whether it is live; unresolved -> NOT_TESTED, never FAIL.
3. **Test each check:** API
   `pokey.ps1 api -Target <t> -As <user> -Method <M> -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <abs dir>]` (exit 1
   on HTTP 0 / 4xx / 5xx; status and body still print);
   web `browser.mjs` (`session()`, `mark`, `shot`, `saveNet`, `hoverSel`; headless; a visible browser only when the owner asks);
   app `pokey.ps1 ui dump|tap|tapid|type|swipe|shot|shotmark|wait|log` with `$env:ANDROID_SERIAL` on every command.
4. **Evidence** (below): name each file when you save it; mark every FAIL screenshot (`ui shotmark`, `mark()`,
   `pokey.ps1 annotate`: goody `android-swarm`). Each verdict: `crafty.ps1 checkpoint -Agent <CODE> -Run <run> -Step <check id>
   -Next <next check id> -Evidence "<verdict> <file>"` (a restart starts at that check; a beat's PAUSE line says what to do).
5. **Verdict per check — defects are never notes:**
   - **PASS**: expected behaviour seen. **PASS_WITH_NOTE** only for: (a) guide text stale from later intended work, intent holds,
     (b) cosmetic difference, (c) Expected blocked by platform limit or imprecise wording (check code/lead, quote both),
     (d) false conditional ("not applicable: <condition>", with evidence); `observed` starts with the class: `(b) <why>`.
   - **FAIL**: any defect: 5xx, unexpected 4xx, crash, stuck flow, unsaved data, broken navigation, missing screen,
     silent 200 with empty data, wrong answer stated as fact, restart errors. Set **`defect`**: `own` = task expected
     behaviour failed (failedTesting -> back to dev);
     `new` = regression outside change (goody checks `X1`, `X2`... -> [Bug] task).
   - **Upstream 5xx** (502/503/504 or a killed long turn from a service the change does not touch): check that service's
     health and restart times first (service log, a control call). An outage -> NOT_TESTED `tool-down`, re-run after recovery;
     a real defect there -> `defect: new` under that service's owner, one bug per shared cause.
   - **Retests of a fix** fail on the sibling path: run the whole flow end to end and every screen reading
     same record/rule; date/shift fixes also cross midnight.
   - **NOT_TESTED**: only when truly impossible here, with the reason, what you tried and `cause` (`no-mail-sandbox` |
     `phone-only` | `undeployed` | `env-data` | `tool-down`). An unexercised part of an Expected is its own NOT_TESTED check.
     NOT_TESTED gets ONE stronger retry (`models.retest`, told your blocker); still
     NOT_TESTED -> the task goes to failedTesting: never for "no time" (shared test envs).
   - **Local env item** (`localEnv`): no cause is final (envy "Unblock yourself"); a coordinator-only fix -> NOT_TESTED
     with `env_fix`: the workflow raises ENV-FIX, retests (`envFixCycles` 2), then holds it, never failedTesting.
   - **LLM-driven checks** are intermittent: warm-up turn, 5+ runs in fresh sessions, every answer with its UTC time; set
     `attempts` and `window`; a verifier must recreate them to refute.
   - **Flaky**: a FAIL with saved evidence that a re-test does not reproduce stays FAIL, `flaky: true` (own ->
     failedTesting, new -> [Bug] tagged flaky); never PASS_WITH_NOTE.
   - **OUT_OF_SCOPE**: the step only exercises a channel agent QA never tests (`qa.outOfScope`, run.json `outOfScope` wins):
     never tested, never counted; the in-app part of the same check is still tested.
   - **PENDING**: tested later in another lane (the workflow adds `<code>A`). **findings**: context only.
6. **Leave:** write `results.json` (each `observed`: `<observed> vs <expected>; <evidence>`; retest/audit text: `verify`;
   limits: 40 words per observed or finding, 25 per sentence, 900 per report: `kitbag.py prose` first), run `pokey.ps1
   finalize -RunDir <run> -Code <CODE> -Check -FixNames` (scoped retry: `-Results results-retry.json`) until exit 0;
   kill your background shells, `board leave`, release seat / phone, close your tab (`s.done()`, never `killSession` or log
   out); return the results.

**Result rule** (finalize applies it per task; the same for agents and people):
all checks pass -> **closed** · an own check FAILED or checks not tested completely (shared test env) -> **failedTesting**
(logical status; fallback `inProgress` + comment),
the one QA comment (no doc link) lists failed / untested checks and why, NO new task · a new / unexpected
defect -> ONE `[Bug] <ask> — new defects (n)` task under the task's original ask (appended to an open one) · PENDING -> open.

**Shared environment:** data prefixed `QA-<CODE>` (app lanes `QA-L<n>-<CODE>`), delete only what you created, an unexpected
change may be another agent's; change a setting only when a check needs it, restore it at once, list it in `setup_changes`;
never deactivate, delete or re-password test logins; one shared Chrome per target + tenant + user (`session()`: own tab,
`relogin(s)` on a 401, never log out), <= 2 tabs per agent; app lanes: only your serial, never `adb kill-server`.

## Evidence
- Where: `<run>/<CODE>/shots` (web `.jpeg`, app `.png`, `.mp4` <= 30 s), `/evidence` (`.json` request/response, `.jsonl`, `.log`
  +-20 lines, DB `{meta, query, rows}` <= 50 rows), `/scripts` (yours, never published).
- Name: `<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>` (`what` lowercase-kebab <= 40 chars; marked copy `-marked`; setup evidence
  `<CODE>-<nn>-<what>`, 00 = before the checks, 90+ = cleanup), e.g. `F2-T4_01_before-edit.jpeg`. List only files that exist
  and are not 0 bytes; open each image with Read first; `finalize -FixNames` is a safety net, not the naming step.
- Minimum: PASS (UI) = a shot of the result (state change: before + after); PASS (API) = the request/response JSON; FAIL = the
  failure shot AND the failing call JSON (`saveNet`) or log excerpt + exact steps; verify = your own `_verify` files.
- Redaction: helpers write `[redacted]` for auth headers, cookies, tokens, passwords, secrets, keys; prefer QA-created records,
  mask real customer data.

## Human testing doc (a person tests by hand)
- H0. `bossy.ps1 learn -Read -Skill pokey`; the doc is the task's testing doc (written by its developer at crafty step 6:
  `crafty/templates.md` "Human testing doc"). Missing or incomplete for this change: write it from that template first.
- H1. Before you start: every feature switch ON (the doc's table), the logins and data it names; restore what you change.
- H2. Each check: do the steps, compare with Expected exactly, save a screenshot (UI) or the request/response (API) per check.
- H3. Result rule (above): all pass -> close the task (`crafty.ps1 tracker status <task> closed` + a comment with the evidence);
  own check failed or not testable -> `failedTesting` + a comment with the check ids, what you saw and the evidence; a new defect
  -> `crafty.ps1 tracker create -Parent <ask> -Key <ask>-<defect> -Name "[Bug] <ask> — <defect>"`: steps, saw, expected, evidence.

## Lead steps (a test-only run; bossy T1-T4)
- L0. Machine setup once: `bossy.ps1 setup -WriteLocal` (targets.local.json = environments + test logins, the only place for
  passwords), `npm install` in this folder, `swarm.config.json` for app lanes, auth checks (tracker, `gws` when `reports.type` =
  gdocs, git host).
- L1. Run folder `<runtime>/work/qa-runs/<date>-<name>/` + `run.json` (shape: the header of `workflows/testy.js`; one
  item per testing doc: `{code, title, guideFile, lane: web|api|app, target?, services? (local: leased),
  subtasks:[{id,name,mrs}], retest?, only?}`),
  guides exported to text. Deploy check: `pokey.ps1 deployed -Mrs <every item's MRs>`; MANUAL repos: `lead-notes.md`; not
  deployed -> left out. Prerequisites per guide in `lead-notes.md`: feature flags, accounts and roles, baseline data (by id;
  local env: `seed -Check`, goody `local-env`), reindex, server config; what the lead cannot unblock -> `skip` + reason.
  **Selection** (the workflow's Prepare agent, from its job JSON; the same by hand):
  1. Folder = `runFolder` with today's date (taken -> `-2`, `-3`). Candidates: `crafty.ps1 tracker list <container> <status>` per
     `lists` (empty: `trackerLists`, else `tracker.list` / `tracker.repo`) x `statuses` (logical names via `tracker.statuses`;
     `in test` = `inTest`; other names pass through); plus `tasks` (`tracker view`), minus `exclude`; `mine` = only the
     `tracker owner`'s.
  2. Per task: MRs `<repo>!<iid>` (`tracking` `<id>.json` `track.mrs`, else the task's MR links, else merged MRs with the
     tracker tag + id in `trackerRepos`); its "Testing doc (human):" link -> `<run>/guides/<code>.md` (finalize fills it).
     None of either -> left out. Tasks sharing a doc = one item.
  3. Target: `target` names a `targets.local.json` entry -> every item; else `kit.local.json` `qa.targets.<target>` = rules
     `[{ lists?, repos?, nameRegex?, pathRegex?, target, localEnv? }]`, first match -> `item.target` (+ `item.localEnv`); none
     -> left out.
  4. Live: test env -> `pokey.ps1 deployed -Mrs <its MRs> -Target <t>`, all DEPLOYED (MANUAL resolved): in; local env (`localEnv`)
     -> `envy.ps1 status -Env <env>` (goody `local-env`), every MR commit in the running release -> in. Else left out
     with the state.
  5. `run.json` = `{ title, target, kitDir, runDir, mandate, tracker: { list }, items, left: [{ id, name, reason }] }` +
     `runSettings`; then `lead-notes.md`. Return `{ runDir, items, left, summary }`.
- L2. Launch `/testy { runDir, kitDir }`, or let it select: `{ select: { statuses, lists?, tasks?, exclude? }, target,
  kitDir, mandate }` (Prepare = L1 Selection); `launch` record (bossy). Lead notes are the only channel to running testers.
- L3. After the run: items the workflow could not publish -> `pokey.ps1 finalize -RunDir <run> -Code <code>` (results.json);
  a fix went live and needs a retest -> `pokey.ps1 retest -RunDir <run> -Task <id> -Code <code>R -Mrs <refs>`.

**Learn:** `bossy.ps1 learn -Skill pokey -Kind <kind> -Text "<what + fix>" -Ref <CODE-check>`.
