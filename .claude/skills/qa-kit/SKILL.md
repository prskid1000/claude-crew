---
name: qa-kit
description: QA rules and tools for testing deployed work on a test environment (never production) — API calls as any configured user with saved request/response evidence, headless logged-in browser for any web app, Android UI driving, honest verdicts (defects are never notes), publishing results (Google Doc or Markdown report) to the issue tracker (ClickUp / GitHub / GitLab / Jira / none) with bug tasks. Use when testing tasks/guides on staging, verifying fixes, collecting evidence, or running /test-and-close.
---

# QA rules (every tester, verifier and auditor agent)

Test deployed work on a **test environment** (never production), record honest verdicts with evidence, publish
results to the tracker, and raise bug tasks for confirmed failures. Works for web apps, APIs/services and Android apps.

## Setup (once per machine)
1. In this skill's folder: `Copy-Item targets.example.json targets.local.json` and fill in your environments + test logins.
   It's the only place passwords live. Auth styles: login (JSON or form body), static token, basic, none.
2. `cd scripts/web; npm ci` (installs `puppeteer-core`; uses the installed Chrome/Edge).
3. Android: in `..\android-swarm\`, `Copy-Item swarm.example.json swarm.config.json` and set `app`.
4. Check auth: the tracker (`../dev-kit/scripts/tracker.ps1 view <id>`; backend = kit.local.json `tracker.type`), `gws` only when
   `reports.type` is `gdocs`, `glab auth status` / `gh auth status`.

## Tools
| Need | Tool |
|---|---|
| Call an API as any user, save evidence | `scripts/api.ps1 -Target <t> -As <user> [-Tenant <x>] -Method -Path [-Body] [-Save <name> -OutDir <dir>]` |
| Drive a web UI | `scripts/web/browser.mjs` — `session()` keeps one logged-in headless Chrome per port (logins shared across ports); `mark()` highlights, `shot()` checks names, `saveNet()` saves failed calls |
| Drive an Android app | `scripts/android/ui.ps1` (dump / tap / tapid / type / swipe / shot / wait / log), with `$env:ANDROID_SERIAL` set |
| Several phones in parallel | `..\android-swarm\` (its SKILL.md) |
| Publish one package | `scripts/finalize.ps1 -RunDir <run> -Code <code> [-Report gdocs\|markdown]` — `gdocs`: Drive evidence + Google Doc; `markdown`: `<code>/report.md` beside the evidence, carried by the tracker comment (kit.local.json `reports.type`) |
| Read / update a task | `../dev-kit/scripts/tracker.ps1 view / comments / comment / status / create / attach` (never a tracker CLI directly) |
| Is a fix live on the test env? | `scripts/deployed.ps1 -Mrs <repo>!<iid>,... [-Target <env>]` (CI deploy job + branch ancestry or same file content; never hold an item as "not deployed" without it) |
| Retest a bug task whose fix went live | `scripts/add-retest.ps1 -RunDir <run> -Task <bug> -Code <code>R -Mrs <repo>!<iid>` (guide = the bug task; checks from its name), then `/test-and-close { runDir, only: [<code>R], instance: w<next> }` |
| Run a whole batch | `/test-and-close` (`.claude/workflows/test-and-close.js`) + `scripts/autoclose.ps1` safety net |
| Memory seat + item claim | `scripts/qa-seat.ps1 acquire / release / status` (every tester/verifier runs it first; see below) |

## Marking evidence (show the reviewer where to look)
- **App:** `ui.ps1 shotmark <name> "<text>|#<id>" ["label"]` takes the screenshot and boxes the element(s) in one go.
- **Web:** `mark(page, selector)` before the screenshot (`unmark` after), or annotate afterwards.
- **Any image:** `scripts/annotate.ps1 -In <file> -Rect 'x,y,w,h,label' -Arrow 'x1,y1,x2,y2,label' -Text 'x,y,text'` (overwrites in place, keeps the evidence name).
Mark every FAIL screenshot (red box on the wrong value / missing element); PASS shots only when the point isn't obvious.

## Memory seats and extra workers
Every tester/verifier first runs `scripts/qa-seat.ps1 acquire` (the workflow tells it how): it waits its fair turn while free RAM would drop under `keepFreeGB` (targets.local.json, default 8) and claims its item. So a run's `webParallel` is only a cap - real concurrency follows memory, and an extra worker run (`/test-and-close { runDir, kitDir, instance: 'w2', only: [...] }`, suggested by the supervisor's capacity flag) never tests an item another worker owns. Items can carry `model`/`effort`; narrow web/API retests default to sonnet.

## A run, end to end
1. **Run folder**: `<workspace>/.claude-runtime/qa-runs/<date>-<name>/` with `run.json` (shape: header of `test-and-close.js`).
   One item per tester guide: `{code, title, guideFile, lane: web|api|app, subtasks:[{id,name,mrs}], retest?, only?, dups?}`.
   Several items may share one task (e.g. a guide split by `only` into web + app parts): finalize keeps the task open until every
   item on it is published, so no `skipClose` is needed for that. `skipClose: true` = test + verify only; the verdicts are saved to
   `<code>/results.json` + `held.json` and the lead publishes later with `finalize.ps1 -RunDir <run> -Code <code>`. `skipClose` works per item or for the whole run (`args.skipClose` / run.json). Finalize never closes a task that has NOT_TESTED checks (it comments "not closed" instead) unless run.json `tracker.closeWithNotTested` is true.
   Guides can be Markdown/text files (`guideFile`) or, with `gdocs`, Google Docs exported to text:
   `cd <run>; gws drive files export --params '{"fileId":"<id>","mimeType":"text/plain"}' -o <code>.txt` (`gws -o` only writes inside the current directory).
2. **Workflow**: `/test-and-close` (or the Workflow tool with `scriptPath = <workspace>/.claude/workflows/test-and-close.js`), `args` = `{ runDir, kitDir }` (short form: a tiny agent reads `<runDir>/run.json`; add `only: [codes]` to run a subset) or the full run.json object + `runDir`.
   Per item: test → retest if > 25% NOT_TESTED → note audit → independent verify of every FAIL → close (finalize).
   Results with > 50% NOT_TESTED are never published.
3. **Safety net** (background): `autoclose.ps1 -Journal <workflow transcript dir> -RunDir <run>`. It publishes only packages whose
   close step returned `ok=false`, so nothing is published twice.
4. **Evidence**: `<run>\<code>\{shots,evidence,scripts}`, named and formatted per **`reference/evidence-standard.md`**
   (`<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>`, request/response envelope, redaction). finalize warns about non-standard names.

## Verdicts: defects are never notes
- **PASS**: the expected behaviour was seen.
- **PASS_WITH_NOTE**: ONLY when (a) the guide text is out of date because later, intended work changed the flow and the intent
  still holds, or (b) a purely cosmetic difference while the behaviour is correct.
- **FAIL**: any defect, inside or outside the guide's steps: 5xx or unexpected 4xx, crash, stuck/blocked flow, data changed wrongly
  or not saved, wrong records affected, broken navigation, a missing screen the feature needs. Off-script defects → extra checks `X1`, `X2` ….
- **NOT_TESTED**: only when truly impossible here, with the reason and what you tried. "Not deployed yet" counts; "no time" doesn't.
- **PENDING**: tested later in another lane (e.g. the app part of a web package). Its task stays open. When the run has phone lanes,
  the workflow adds an app follow-up item `<code>A` for exactly the PENDING checks and runs it on the phones in the same run.
- **findings**: context only (test-data notes, guide drift). Never defects.
- Before calling a FAIL, confirm the change is deployed (stale builds are common on test environments).
- The workflow's **note audit** re-reads every PASS_WITH_NOTE and finding; real defects become FAIL and get verified and a bug task.

## Agent board
Join before testing and claim what must be exclusive: `orchestrate/scripts/board.ps1 join -Agent <CODE> -Run <run> -Claims emulator-5556,chrome:9601`.
It flags another agent on the same phone/port (CLAIM) or a duplicate of you (DUPLICATE). `leave` when done.

## Shared-environment etiquette (other agents test on the same environment at the same time)
- **Data**: prefix everything you create `QA-<CODE>` (app lanes: `QA-L<n>-<CODE>`); delete only what you created.
  If something changed unexpectedly, another agent may have done it: re-check before calling it a failure.
- **Settings**: change an environment/company setting only when a check needs it, restore it straight away, list it in
  `setup_changes`. Per-user preferences: use a secondary test user. Run checks that change environment-wide settings alone.
- **Accounts**: never deactivate, delete or re-password the test logins.
- **Memory**: ≤ 2 Chrome ports per web agent, `killSession()` when done; don't kill processes you didn't start.
- **App lanes**: each lane owns one serial and one login; set `$env:ANDROID_SERIAL` on every command; never touch another
  lane's phone, never `adb kill-server`; test the APK built from the branch under test.
- **Workflow scripts** must have LF line endings.
- Project-specific facts (tenants, accounts, test data, known quirks) go in the run's `context` / `contextFiles` or in memory,
  never into these generic files.

## Documents
- Results doc: built by `finalize.ps1` (`scripts/lib/report.ps1`): verdict banner, count chips, at-a-glance summary, facts table,
  colour-coded results table, failure details with screenshots, notes, screenshot gallery, evidence index.
- Tester guides: `templates/tester-guide.html`. Bug tasks raised by finalize use a fixed Markdown layout (steps, saw, re-test, evidence links).

## Learn
Read `LESSONS.md` before testing (general + per-project UI gotchas). Record surprises with
`& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill qa-kit -Kind <kind> -Text "<what + fix>" -Ref <CODE-check>`.
