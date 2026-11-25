# Tests (crafty Rules > Tests)
Read by devy at steps 2 and 4-5 and revy (kinds mr, kit, config). Any stack; reviewers check them; CI may skip tests, the dev loop guards.

- **Ship:** unit tests for new/changed logic; a regression test per fixed bug (red before, green after); integration/API tests
  for endpoints touched; UI/component tests for screens touched where the stack supports it.
- **Shape:** arrange / act / assert; one behaviour per test; names `should_<behaviour>_when_<condition>` (or the repo's style);
  no sleeps or real clocks (fixed clock); no shared mutable state; deterministic builders / fixtures; mocks only at
  boundaries; no network unless tagged integration. Every assertion runs: a list is asserted non-empty before a loop over
  it; a success test calls the endpoint and never branches on an error status; a placeholder is a listed coverage gap,
  never counted. Shared env or tenant: unique ids from one helper (no random, no real clock); assert only records the
  test made; settings and cleanup in before/after hooks registered before the mutation; cleanup accepts 2xx/404 only,
  the MR lists leftovers.
- **Place:** next to the repo's existing tests (its convention wins; `crafty.ps1 stack` shows the runner; a web project without a
  unit-test target: `skills/crafty/spec.mjs` when `tests.fallbackRunner` is `spec`; `kit.local.json` `tests.<stack>.testFor` maps a source name to its test names for
  `-Touched`). node-spec cannot bundle code needing framework DI or a linker (forms, router, store, injectable services):
  move the logic into a pure helper the component calls, spec that helper (never a local copy), list the wiring as a live check.
- **Run:** `check -Step test -Tests <new tests> -Touched` before every push (full suites, `-AllTests`: the coordinator's
  cadence). Each testing goal names its test or manual check. E2E: only `check -Step e2e` (the diff's
  specs, each with its reason, for the goals doc; none = e2e NOT_TESTED; `-AllTests` only on the owner's word).

## Impact map (crafty step 2, BEFORE any edit; `wt commit` refuses a task branch's code commit without it)
`impact` in the cases spec (templates.md "Test cases"; a one-line fix: a short map); revy checks the diff touches or excludes each item:
- `logic`: the existing logic you change and why it is so: `git log -L` / blame of the touched lines, the tests that state it
  (disabled ones too: a disabled test that expects the behaviour is the spec).
- `callers`: callers and consumers of each changed function, endpoint, DTO field and column (grep / LSP in every repo: web, app,
  services, AI tools).
- `renders`: `[{item, result}]`: every screen, record type and state that renders or uses it (sibling screens, other record
  types, empty / deleted / flagged states); `result` = case id + PASS, or `excluded: <why>` (finish refuses an open one).
- `path`: the tester's end-to-end path (UI -> API -> DB / AI -> UI), cross-repo, run end to end once.
- Seed shaped like staging: read-only staging queries (counts, nulls, flags, deleted rows, volume; never rows copied out) set
  `data`; never assume a flag or field value.

## Proof (`devtools.py proof <task>`; finish and a non-Draft `mr` refuse a gap)
Each check carries `channel`: `ui` (a person sees it on a screen) · `api` · `job` (no UI trigger) · `ai` (model output).
- **ui:** a PASS case with a screenshot, video or trace of the human doc's exact steps at the testers' screen (`browser.mjs
  testerScreen()`, `qa.testerViewport`; `mobile: true`: the mobile one, a phone lane `viewport=device:<lane>`), the app's global
  widgets on (chat, banners, help) and `hitTest()` on each control touched: `cases result <task> <id> PASS <shot>=<link>
  viewport=1366x768 hit=PASS`. API JSON, a stub or NOT_TESTED_LOCAL proves no ui goal; not runnable locally: `preverify` = the
  staging run's evidence link, or `waiver` = the owner's decision id.
- **ai:** a deterministic guard in code (validates the output or plan: create-only plans, a cancel needs a reason, ids owned),
  its unit test in `guard`, plus ONE local run PASS; never rerun a model N times to judge it. `qa.aiWaiver` (the owner's
  decision id) waives that run while the doc's `env` runs no `services[].aiStack` service; once it does, the run is due.
- **Failure paths:** at least one negative or edge case (what a tester tries: invalid input, a denial, empty data).

## Test cases (the gates judge the rendered text)
- `checks` = the human doc (`| # | UI steps | Expected on screen | Screenshot | Extra evidence | Result |`), POSITIVE only, from
  the request (task, acceptance, stated qualities), never the code; driven from the UI (owner 2026-11-20): what a person clicks
  or types and sees, a backend change through the UI action that triggers it, no endpoints, payloads or code names (refused); a
  screenshot per check, request / response JSON only from that action (network or app log) as extra; Screenshot / Extra
  evidence / Result empty (an env run fills them: pokey finalize or a person, a dated "<env> run" section).
- `cases` = every positive, negative, edge and regression case (invalid input, role denials, boundaries, empty data,
  concurrency, nearby features, impact edges), each human check run by a case naming it (`check`); a bug fix: a `repro` case
  (`process.gates.bugFix` `builtin:reproRow`: merge refuses without); UI cases at the variants the diff needs (`devtools.py
  matrix-scope <task> --dir <wt>`: layout / style / a new screen = all of `qa.matrix`, else `qa.matrixRun.reduced`: tester web
  + mobile + one locale), run at once (pokey `matrix.mjs`), its line in `matrix`; a
  failing case is FAIL, never "pre-existing"; a `qa.notLocal` stub path NOT_TESTED_LOCAL, never PASS; a result needs an
  evidence link (screenshot, request / response JSON, run output: `devtools.py evidence`).
