---
name: pokey
description: "Load when: testing deployed work on a test env (checky test / verify, or one change checked directly), checky lead setting up a test-only run, or a person testing by hand from a human testing doc. Not when: agents test a batch of deployed tasks -> /testy via bossy; before merge -> envy; static audit -> revy agent; phone lanes -> phoney."
---

**Load when:** testing DEPLOYED changes on a test env (never production): `checky` test / verify, the main session checking
one change, `checky` lead preparing a test-only run, or a person testing by hand.
**Not when:** several deployed tasks tested by agents -> `/testy` (load `bossy`); before merge -> `envy`; phones -> `phoney`;
fixing what failed -> `crafty` (bugfix wave).
**Hands off to:** `pokey.ps1 finalize` (report, tracker comment, result rule; run by /testy), the coordinator (failedTesting
tasks and new [Bug] tasks -> bugfix wave), the person testing by hand (H1-H3).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0 (and H0, L0): `bossy.ps1 learn -Read -Skill pokey` |
| `pokey.ps1` | steps 1-4, 6; L1, L3 (verbs: its header) |
| `<kit>/skills/crafty/crafty.ps1` | step 3 (`check -Step e2e`); L1 Selection (`tracker list/view/owner`; a local env: `envy.ps1 status -Env`) |
| `browser.mjs` | step 3 (web: read its header first; one logged-in headless Chrome per port) |
| `adapters/*`, `video.py` | used by the `pokey.ps1` / `browser.mjs` verb that needs them |
| `media.md` | task videos (`pokey.ps1 evidence`) |
| `package.json` | L0: `npm install` in this folder (puppeteer-core) |

## Tester / verifier steps (test environment only, never production)
0. `bossy.ps1 learn -Read -Skill pokey`; [Bug] / task: `crafty.ps1 prior` (FOUND: tracker scope);
   read the guide, the run's `context` / `contextFiles`. Check SQL/MCP tools once; a tool down is never NOT_TESTED (read APIs).
   Only the run's target (run.json `target`, `alsoTargets`; `api` refuses others); no load, stress or request floods on a
   shared env, even when a guide asks.
1. **Seat + board:** `pokey.ps1 seat acquire` (exit 4 = still waiting: run it again);
   `bossy.ps1 board join -Agent <CODE> -Run <run> -Claims <phone serial>`; CLAIM/DUPLICATE -> stop, report.
   Phones: `phoney.ps1 acquire|release` (kept through waits < 30 min). Local env "pause": stop its checks; "deploy done": re-run.
2. **Deployed?** Before any FAIL: `pokey.ps1 deployed -Mrs <repo>!<iid>,...` per repo of the task; not deployed -> NOT_TESTED
   "not deployed yet" (all N/A: another product, not undeployed); MANUAL -> lead notes say if live; unresolved ->
   NOT_TESTED, never FAIL.
3. **Test each check:** API
   `pokey.ps1 api -Target <t> -As <user> -Method <M> -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <abs dir>]` (exit 1
   on HTTP 0 / 4xx / 5xx; status and body still print);
   web `browser.mjs` (`session()`, `mark`, `shot`, `saveNet`, `hoverSel`): UI checks
   at each `qa.matrix` variant (`matrix()`) + `layoutIssues()`; stated qualities measured (`contrast()`, timings);
   app `pokey.ps1 ui dump|tap|tapid|type|swipe|shot|shotmark|wait|log` with `$env:ANDROID_SERIAL` on every command;
   e2e: `check -Step e2e`. A human doc row: from the UI only, as its steps say (`api` for setup data only).
   Check id = guide row id; variants (V1, V2): `case: <row id>`; rows an earlier run covered need no NOT_TESTED filler.
4. **Evidence** (below): name each file when you save it; mark every FAIL screenshot (`ui shotmark`, `mark()`,
   `pokey.ps1 annotate`). Each verdict: `crafty.ps1 checkpoint -Agent <CODE> -Run <run> -Step <check id>
   -Next <next check id> -Evidence "<verdict> <file>"` (a restart resumes there; obey a beat's PAUSE line).
5. **Verdict per check — defects are never notes:**
   - **PASS**: expected behaviour seen. **PASS_WITH_NOTE** only for: (a) guide text stale from later intended work, intent holds,
     (b) cosmetic difference, (c) Expected blocked by platform limit or imprecise wording (check code/lead, quote both),
     (d) false conditional ("not applicable: <condition>", with evidence); `observed` starts with the class: `(b) <why>`.
   - **FAIL**: any defect: 5xx, unexpected 4xx, crash, stuck flow, unsaved data, broken navigation, missing screen,
     silent 200 with empty data, wrong answer stated as fact, restart errors. Set **`defect`**: `own` = task expected
     behaviour failed, never "pre-existing" (failedTesting -> back to dev); `new` = regression outside change
     (`X1`, `X2`... -> [Bug] task); **`knownBug: <task id>`**: an open, untested task already tracks it.
   - **Upstream 5xx** (502/503/504 or a killed long turn from a service the change does not touch): check its health and
     restart times (log, a control call). An outage -> NOT_TESTED `tool-down`, re-run after recovery;
     a real defect there -> `defect: new` under that service's owner, one bug per shared cause.
   - **Retests of a fix** fail on the sibling path: run the whole flow end to end and every screen reading
     same record/rule; date/shift fixes also cross midnight.
   - **NOT_TESTED**: only when truly impossible: the reason, what you tried, `cause` (`no-mail-sandbox` |
     `phone-only` | `undeployed` | `env-data` | `tool-down`). An unexercised part of an Expected is its own NOT_TESTED check.
     An env switch off on the target: `tool-down` + `decide ask`, never toggled (guard denies it).
     ONE stronger retry (`models.retest`, told your blocker); still NOT_TESTED -> failedTesting; never for "no time".
   - **Local env item** (`localEnv`): no cause is final (envy "Unblock yourself"); a coordinator-only fix -> NOT_TESTED
     with `env_fix`: the workflow raises ENV-FIX, retests (`envFixCycles` 2), then holds it, never failedTesting.
   - **LLM-driven checks** are intermittent: warm-up turn, 5+ runs in fresh sessions, each answer's UTC time; set
     `attempts`, `window`; a verifier recreates them to refute.
   - **Flaky**: a FAIL no re-test reproduces stays FAIL, `flaky: true` (own -> failedTesting, new -> [Bug] tagged
     flaky); no PASS_WITH_NOTE.
   - **OUT_OF_SCOPE**: only a `qa.outOfScope` channel (run.json `outOfScope` wins), its in-app part tested. A part with no
     build on the target (NO-TARGET): the local env (`phoney.ps1 build -Local` + a lane), a "local run"; no lane: NOT_TESTED.
   - **PENDING**: tested later in another lane (the workflow adds `<code>A`). **findings**: context only.
6. **Leave:** write `results.json` (each `observed`: `<observed> vs <expected>; <evidence>`; retest/audit text: `verify`;
   limits: 40 words per observed or finding, 25 per sentence, 900 per report; same for run.json `envLines`), run `pokey.ps1
   finalize -RunDir <run> -Code <CODE> -Check -FixNames` (scoped retry: `-Results results-retry.json`) until exit 0;
   kill your background shells, `board leave`, release seat / phone, close your tab (`s.done()`, never `killSession`);
   return the results.

**Result rule** (finalize applies it per task; the same for agents and people):
all pass -> **closed** · an own check FAILED or not all tested -> **failedTesting** (fallback `inProgress` + comment),
one QA comment (no doc link) names failed / untested checks, why; NO new task · a new defect -> ONE `[Bug] <product> —
<first defect> (+n)` under the ask (one open collector; known `signature`: duplicate line); verify `inconclusive` + no
request named: WATCH, no [Bug] · `knownBug` FAIL: not own, no task, "Seen again" line · PENDING: open.

**Shared environment:** data prefixed `QA-<CODE>` (app lanes `QA-L<n>-<CODE>`), delete only what you created, an unexpected
change may be another agent's; an app setting (never env config) only when a check needs it, restored at once, in
`setup_changes`; test logins: `api -As` / `session()` only, never read (`targets.local.json`), deactivated,
deleted or re-passworded; one shared Chrome per target + tenant + user (`session()`: own tab, `relogin(s)` on a 401,
never log out), <= 2 tabs an agent; app lanes: your serial, no `adb kill-server`.

## Evidence
- Where: `<run>/<CODE>/shots` (web `.jpeg`, app `.png`, `.mp4` <= 30 s), `/evidence` (`.json` request/response, `.jsonl`, `.log`
  +-20 lines, DB `{meta, query, rows}` <= 50 rows), `/scripts` (yours, never published).
- Name: `<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>` (`what` lowercase-kebab <= 40 chars; marked copy `-marked`; setup evidence
  `<CODE>-<nn>-<what>`, 00 = before the checks, 90+ = cleanup), e.g. `F2-T4_01_before-edit.jpeg`. List only files that exist
  and are not 0 bytes; open each image with Read first.
- Minimum: a result shot (state change: before + after) per human doc check (`finalize -Check`; "No UI trigger": or a
  `.log`); JSON only from the UI action (`saveNet`, app log); FAIL: + the failing call JSON or log; verify: own `_verify` files.
- Redaction: helpers write `[redacted]` for auth headers, cookies, tokens, passwords, secrets, keys; prefer QA-created records,
  mask real customer data.

## Human testing doc (a person tests by hand)
- H0. `bossy.ps1 learn -Read -Skill pokey`; the doc: the task's testing doc (`crafty/templates.md` "Test cases");
  missing or incomplete for this change: write it from that template first.
- H1. First: every in-app switch ON (the doc's table; an env switch off: ask the owner), the logins and data it names.
- H2. Each check: do the steps in the app, compare with Expected on screen, a screenshot always; its network / log JSON: extra.
- H3. Result rule (above), each with a comment (check ids, saw, evidence) `crafty.ps1 tracker status <task> closed|failedTesting`;
  a new defect: `crafty.ps1 tracker create -Parent <ask> -Key qa-<ask>-<defect> -Name "<product> — <defect>"` (kit adds [Bug]).

## Lead steps (a test-only run; bossy T1-T4)
- L0. Machine setup once: `bossy.ps1 setup -WriteLocal` (writes targets.local.json),
  `npm install` in this folder, `swarm.config.json` for app lanes, auth checks (tracker, `gws` when `reports.type` =
  gdocs, git host).
- L1. Run folder `<runtime>/work/qa-runs/<date>-<name>/` + `run.json` (shape: the header of `workflows/testy.js`; one
  item per testing doc: `{code, title, guideFile, lane: a qa.lanes name, target?, services? (local: leased),
  subtasks:[{id,name,mrs}], retest?, only?}`),
  guides exported to text. `lead-notes.md`: MANUAL deploy state; prerequisites per guide: flags, accounts, roles, data (by
  id; local env: `seed -Check`), reindex, server config; what the lead cannot unblock -> `skip` + reason.
  **Selection** (`pokey.ps1 prepare -Job <job JSON>` runs steps 1-5, the workflow's Prepare step; by hand the same):
  1. Folder = `runFolder`, date placeholders (`<yyyy-MM-dd-HHmmss>`) expanded; one with files is refused, an empty one reused.
     Candidates: `crafty.ps1 tracker list <container> <status>` per `lists` (empty: `trackerLists`, else `tracker.list` /
     `tracker.repo`) x `statuses` (logical names via `tracker.statuses`; `in test` = `inTest`; other names pass through);
     `tasks` given: only those + their subtasks in `statuses`; minus `exclude`; `mine` = only the `tracker owner`'s.
  2. Per task: MRs `<repo>!<iid>` (`tracking` `<id>.json` `track.mrs`, else the task's MR links); its "Testing doc
     (human):" link -> `<run>/guides/<code>.md` (its kept copy, else the link).
     None of either -> left out. Tasks sharing a doc = one item.
  3. Target: `target` names a `targets.local.json` entry -> every item; else `kit.local.json` `qa.targets.<target>` = rules
     `[{ lists?, repos?, nameRegex?, pathRegex?, target, localEnv? }]`, first match -> `item.target` (+ `item.localEnv`); none
     -> left out.
  4. Live: test env -> `pokey.ps1 deployed -Mrs <MRs> -Target <t>`, DEPLOYED or N/A (MANUAL resolved): in (NO-TARGET next to a
     live MR: `localParts`, local env); all N/A for the target: left out (other product); `localEnv` -> in after
     `envy.ps1 status -Env <env>`. Else left out with the state.
  5. `run.json` = `{ title, target, kitDir, runDir, mandate, tracker: { list }, items, left: [{ id, name, reason }] }` +
     `runSettings`; then `lead-notes.md`. Return `{ runDir, items, left, summary }`.
- L2. Launch `/testy { runDir, kitDir }`, or let it select: `{ select: { statuses, lists?, tasks?, exclude? }, target,
  kitDir, mandate }` (Prepare = L1 Selection); `launch` record (bossy). Lead notes are the only channel to running testers.
- L3. After the run: items the workflow could not publish -> `pokey.ps1 finalize -RunDir <run> -Code <code>` (results.json);
  a fix went live and needs a retest -> `pokey.ps1 retest -RunDir <run> -Task <id> -Code <code>R -Mrs <refs>`.

**Learn:** `bossy.ps1 learn -Skill pokey -Kind <kind> -Text "<what + fix>" -Ref <CODE-check>`.
