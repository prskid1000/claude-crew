---
name: kit-audit
description: "Load when: you are the kit-auditor agent: the weekly kit audit is due (SessionStart nudge), or the owner asks to audit, review, recover or repair the whole kit, set it up or fix missing config. Not when: one kit script or rule failed -> orchestrate (Change the kit, HEAL); a retrospective of learning signals -> /kit-retro; auditing product code -> tech-audit."
argument-hint: "[focus: setup | config | recover | audit | all]"
---

**Load when** (all must hold): you are the `kit-auditor` agent (orchestrate E13); the task is the whole kit, not one script.
**Not when:** one failing script, hook or rule -> `orchestrate` K1-K5; signals -> `/kit-retro`; a product module ->
`tech-audit`.
**Hands off to:** the lead (merges your pushed `kit/audit-<date>` branch, answers the ASK list, approves proposals).
**Files** (this skill has only this file; the tool and the report template live elsewhere):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill kit-audit` |
| `<kit>/skills/orchestrate/kittool.py` | steps 1-3 (`audit setup|config|recover` on the live clone), 4 and 8 (`audit scan`, `lint`), 9 (`audit stamp`); `audit due` any time |
| `<kit>/skills/dev-kit/templates.md` | step 6: "Writing standards" (the limits `kittool.py prose` checks); step 9: "Audit report", filled into `<runtime>/logs/kit-audits/audit-<date>.md` |

## Steps
`<kit>` = the live clone (never edit its files: runs execute them); `<wt>` = your audit worktree; `$A = 'python -X utf8
<wt>/skills/orchestrate/kittool.py audit'`; `$O = '<kit>/skills/orchestrate/orch.ps1'`.
0. **Start:** `& $O learn -Read -Skill kit-audit`; `& $O board join -Agent kit-auditor -Run kit-audit -Area kit` (DUPLICATE ->
   stop).
   `git -C <kit> fetch`;
   `& <kit>/skills/dev-kit/dev.ps1 wt new -Repo <kit> -Branch kit/audit-<yyyy-MM-dd> -Target main -Name kit-audit`.
   Busy check: `& $O launch -List -Brief` + `& $O board show`: anything running -> no `--fix` on worktrees, board or cleanup.
1. **Setup:** `$A setup` (clone, git hooks, `localOnly` excludes, runtime + state folders, hooks clean and fast, ports, CLIs and
   auth: check only, never log in). `$A setup --fix` runs `kit.ps1 setup` (idempotent).
2. **Missing config:** `$A config` (local files vs `kit.example.json`, the README "Configuration" table and the keys scripts
   read).
   `--fill` writes only documented defaults (backup next to the file). Org values (hosts, ids, credentials, `orgTerms`) = ASK
   lines `<file> <key>: why`; never guess them, never print or copy a value from a `*.local.*` file.
3. **Recover:** `$A recover` (uncommitted changes, behind/ahead, kit worktrees, merged kit branches, tracked local files, launch
   records of dead runs, stale board entries, orphan worktrees, cleanup dry run, runtime size). `--fix` only when step 0 found
   nothing running; unmerged work is listed with its exact command, never deleted.
4. **Deep audit:** read EVERY tracked file (`git -C <wt> ls-files`; <= 50 by rule); trace each flow end to end (below);
   `$A scan`
   and `python -X utf8 <wt>/skills/orchestrate/kittool.py lint --warn` add candidates. Keep only proven findings (`file:line`,
   the input that breaks it, the effect). Large: up to 6 read-only Explore agents, one per area; verify each yourself.
5. **Generic and project-agnostic:** `kittool.py lint --org-terms <kit>/skills/dev-kit/kit.local.json` = 0 ORG-TERM; no
   hard-coded
   product, tenant, status name, list id, host, person, absolute path, stack, migration tool, app trio or DB; each such value ->
   a config key with today's default, the org's value in the report's "kit.local.json additions". Any stack, migration tool,
   local
   env shape, deploy mechanism and tracker must work through config.
6. **Consistency:** Files indexes vs disk; README "Configuration" vs the keys scripts read (both ways); Router vs skills, agents
   and workflows; agent tools vs what their skill runs; ports in the kit and the workspace copies (`kittool.py port --check`;
   the pre-commit hook regenerates them, pre-push blocks stale ones); the README graph current; no script opens the desktop
   without `--open` (DESKTOP-OPEN); every file reached from the root with a reason on each edge; budgets and the 50-file cap;
   script headers (usage, exit codes, shared params). Writing: lint PROSE for kit files; `kittool.py prose --kind <kind> <file>`
   on a sample of produced artefacts (latest MR bodies, tracker comments, briefs and testing docs under `<runtime>/work`, QA
   reports, results.json notes): each finding = kind, file, limit broken (templates.md "Writing standards").
7. **Improve:** `& $O learn -Stats`, `-Show -Last 300`, the newest `<runtime>/logs/retros/*.md`, `<runtime>/logs/guard.log`; a
   `## History` "(fixed in kit)" problem seen again = a regression finding. Each pattern -> the smallest durable change.
8. **Fix in `<wt>`:** blocking and should-fix findings with a small, safe fix; bigger ones (or ones an open kit branch also
   changes: diff it first) -> proposed with the exact edit. Then in `<wt>`: lint 0, `port` + `port --check`, parse touched
   .ps1, `py_compile` .py, `node --check` .mjs / wrapped workflows, `tests/kit-tests.ps1`, `cost --steps` after a workflow
   change.
9. **Ship:** `dev.ps1 wt commit` (Conventional Commits, the org's author rules), `git -C <wt> push -u origin kit/audit-<date>`;
   never push `main`, never merge. Report (templates.md "Audit report"). `$A stamp`; `board leave`.

| Flow | Hops to trace |
|---|---|
| dev | router -> orchestrate -> `dev-wave.js` (build + local loop, decisions, review, fix, ci, ship, track, deploy ask, learn) -> `dev-agent` -> dev-kit (`dev.ps1 wt/check/gate/stack`, `devtools.py mr/doc/merge`) -> local-env (`localenv.ps1`, `migrations.py`) -> `orch.ps1 track/deploy` |
| test-only | router -> `test-and-close.js` (load-run, test, audit, verify, close) -> `qa-tester` / `qa-verifier` -> `qa.ps1 seat/deployed/api/ui/annotate/finalize` -> result rule -> `orch.ps1 supervise` (failedTesting, [Bug]) -> bugfix wave |
| coordinator | `orch.ps1 supervise -AutoFix -Brief` -> board, track, deployed, deploy plan, decide, launch, report, cleanup; `swarm.ps1` leases |
| kit | `settings.json` hooks (`dev.ps1 guard`, `kit.ps1 health/guard-sendmessage`, `orch.ps1 cleanup -IfDue`), `.githooks`, `kittool.py lint/flow/port/cost`, `kit.ps1 setup -Migrate` |
Script pitfalls to check (pwsh 7): case-insensitive variables (`$L` = `$l`); `-File x.ps1 -List a,b` passes one string
(`Split-KitList`); short helper names that are aliases (`r`, `rd`, `h`, `del`, `diff`: an alias beats a function and can delete
files); `[IO.File]` resolves against the process directory; `exit` in a dot-sourced file ends the caller; `SilentlyContinue`
hides throws; native commands never throw (`$LASTEXITCODE`). Python: `encoding='utf-8'`, `shutil.which` for shims, timeouts.
JS workflows: no `Date.now()` / `new Date()`, LF only, every `agentType` exists.

**Rules**
- The live clone is read-only for you except `kittool.py audit --fix / --fill`; every tracked change goes through `<wt>` and a
  push.
- Evidence or it is not a finding; unproven -> "candidate". Final reply <= 200 words (templates.md "Final reports").
- Learn: `& $O learn -Skill kit-audit -Kind <kind> -Text "<what + fix>"`.
