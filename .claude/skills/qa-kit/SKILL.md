---
name: qa-kit
description: QA rules and tools for testing deployed work on a test environment (never production) — API calls as any configured user with saved request/response evidence, headless logged-in browser for any web app, Android UI driving, honest verdicts (defects are never notes), publishing results (Google Doc or Markdown report) to the issue tracker (ClickUp / GitHub / GitLab / Jira / none) with bug tasks. Use when testing tasks/guides on staging, verifying fixes, collecting evidence, or running /test-and-close.
---

# Quick start (every tester, verifier and auditor reads this)

Test deployed work on a **test environment** (never production), record honest verdicts with evidence. Web apps, APIs, Android apps.
Scripts: `<workspace>/.claude/skills/qa-kit/scripts` (PowerShell). Environments + logins: `targets.local.json` (passwords only there).

**Verdicts — defects are never notes**
- **PASS**: the expected behaviour was seen.
- **PASS_WITH_NOTE**: ONLY (a) guide text out of date because later, intended work changed the flow and the intent holds, or (b) a purely cosmetic difference while behaviour is correct.
- **FAIL**: any defect, in or outside the guide's steps: 5xx or unexpected 4xx, crash, stuck flow, data changed wrongly or not saved,
  wrong records affected, broken navigation, a missing screen the feature needs. Off-script defects → extra checks `X1`, `X2` ….
- **NOT_TESTED**: only when truly impossible here, with the reason and what you tried. "Not deployed yet" counts; "no time" never does.
- **PENDING**: tested later in another lane (the workflow adds an app follow-up `<code>A` for those checks when the run has phones).
- **findings**: context only (test-data notes, guide drift), never defects. The note audit re-reads every note and finding anyway.
- Before a FAIL confirm the change is deployed: `scripts/deployed.ps1 -Mrs <repo>!<iid>,...` (else NOT_TESTED "not deployed yet").

**Evidence** (full standard: `reference/evidence-standard.md`)
- Folder `<run>/<CODE>/shots` (screenshots: web JPEG, app PNG) and `/evidence` (API/network/DB/log JSON); your scripts in `/scripts`.
- Name `<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>` (`what` lowercase-kebab ≤ 40 chars), e.g. `F2-T4_01_before-edit.jpeg`, `F2-X1_01_500-on-cancel.json`.
- PASS (UI) = one shot of the result (state change: before + after); PASS (API) = the request/response JSON; FAIL = failure shot **and**
  the failing call JSON (`saveNet`) or log excerpt + exact steps; verify = your own `_verify` files. Never a blank/loading/login page;
  open each image with Read before listing it. List only file names that exist (no paths, folders or scripts). Secrets are redacted by the helpers.
- Mark every FAIL screenshot: app `ui.ps1 shotmark <name> "<text>|#<id>" ["label"]`, web `mark(page, selector)` before `shot()`, any image `scripts/annotate.ps1 -In <f> -Rect 'x,y,w,h,label'`.

**Tools**
- API as any user: `scripts/api.ps1 -Target <t> -As <user> [-Tenant <x>] -Method <M> -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <dir>]`.
- Web: `scripts/web/browser.mjs` (read its header) — `session()` = one logged-in headless Chrome per port; `mark`, `shot`, `saveNet`, `hoverSel`. Not the chrome-devtools MCP.
- Android: `scripts/android/ui.ps1` (dump / tap / tapid / type / swipe / shot / shotmark / wait / log) with `$env:ANDROID_SERIAL` set; phones via `../android-swarm/phone.ps1 acquire|release`.
- Tracker: `../dev-kit/scripts/tracker.ps1 view|comments <id>` (never a tracker CLI directly). Memory seat: `scripts/qa-seat.ps1` (the workflow tells you how).

**Shared environment** (others test at the same time)
- Board: `orchestrate/scripts/board.ps1 join -Agent <CODE> -Run <run> -Claims <phone serial>,chrome:<port>`; CLAIM/DUPLICATE → stop and report; `leave` when done.
- Data prefixed `QA-<CODE>` (app lanes `QA-L<n>-<CODE>`); delete only what you created; an unexpected change may be another agent's — re-check before FAIL.
- Change an environment setting only when a check needs it, restore it at once, list it in `setup_changes`; per-user preferences on a
  secondary test user; never deactivate, delete or re-password test logins.
- ≤ 2 Chrome ports per web agent, `killSession()` when done; kill only processes you started. App lanes: only your serial, never `adb kill-server`.
- Project facts (tenants, accounts, quirks) come from the run's `context` / `contextFiles` and `LESSONS.md`, never from these generic files.

**Learn:** read `LESSONS.md` first (general + per-project UI gotchas). Record surprises:
`& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill qa-kit -Kind <kind> -Text "<what + fix>" -Ref <CODE-check>`.

## Reference (read only when you need it)
- `reference/evidence-standard.md` — evidence formats (JSON envelope, logs, DB rows, recordings, redaction): when you save anything beyond screenshots and `api.ps1 -Save` JSON, or a name is unclear.
- `reference/tools-and-rules.md` — full tool table (finalize, deployed, add-retest, autoclose, qa-seat), marking evidence, verdicts, board and etiquette in full.
- `reference/runs.md` — machine setup, run folder + `run.json`, skipClose, memory seats + extra workers, documents: for the lead setting up or publishing a run.
