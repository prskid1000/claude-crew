# Tests (crafty Rules > Tests)
Read by devy at steps 4-5 and revy (kinds mr, kit, config). Any stack; reviewers check them; CI may skip tests, the dev loop guards.

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
  unit-test target: `skills/crafty/spec.mjs`; `kit.local.json` `tests.<stack>.testFor` maps a source name to its test names for
  `-Touched`). node-spec cannot bundle code needing framework DI or a linker (forms, router, store, injectable services):
  move the logic into a pure helper the component calls, spec that helper (never a local copy), list the wiring as a live check.
- **Run:** `check -Step test -Tests <new tests> -Touched` before every push (full suites, `-AllTests`: the coordinator's
  cadence). Each testing goal names its test or manual check. E2E: only `check -Step e2e` (the diff's
  specs, each with its reason, for the goals doc; none = e2e NOT_TESTED; `-AllTests` only on the owner's word).
