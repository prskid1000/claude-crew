# QA runs: setup, run.json, seats, documents (qa-kit reference)

For the lead / whoever sets up a machine or a run. Testers do not need it.

## Setup (once per machine)
1. In this skill's folder: `Copy-Item targets.example.json targets.local.json` and fill in your environments + test logins.
   It's the only place passwords live. Auth styles: login (JSON or form body), static token, basic, none.
2. `cd scripts/web; npm ci` (installs `puppeteer-core`; uses the installed Chrome/Edge).
3. Android: in `..\android-swarm\`, `Copy-Item swarm.example.json swarm.config.json` and set `app`.
4. Check auth: the tracker (`../dev-kit/scripts/tracker.ps1 view <id>`; backend = kit.local.json `tracker.type`), `gws` only when
   `reports.type` is `gdocs`, `glab auth status` / `gh auth status`.

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

## Documents
- Results doc: built by `finalize.ps1` (`scripts/lib/report.ps1`): verdict banner, count chips, at-a-glance summary, facts table,
  colour-coded results table, failure details with screenshots, notes, screenshot gallery, evidence index.
- Tester guides: `templates/tester-guide.html`. Bug tasks raised by finalize use a fixed Markdown layout (steps, saw, re-test, evidence links).
