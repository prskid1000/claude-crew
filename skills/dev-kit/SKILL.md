---
name: dev-kit
description: "Load when: you write, fix, test or ship code in a repo of this workspace: as a dev-agent from a brief, or directly for one small change. Not when: you coordinate several agents -> orchestrate; you test deployed work on a test env -> qa-kit; you audit code without changing it -> tech-audit; you review someone's MRs -> mr-reviewer agent."
---

**Load when** (all must hold): you change code in a repo of this workspace; you are a `dev-agent` from a brief, or the main
session on a one-small-change router row.
**Not when:** coordinating agents -> `orchestrate`; testing deployed work -> `qa-kit`; static audit -> `tech-audit`; reviewing
MRs -> `mr-reviewer`; running the shared local env itself -> `local-env` (you use it at step 5).
**Hands off to:** `local-env` (steps 2 and 5: reproduce, test), the coordinator (your final report; the workflow merges after
review; a person's `deploy <env>` starts the deploy), testers through the human testing doc (step 6).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill dev-kit` prints this skill's section (+ the local one) |
| `templates.md` | "Writing standards" at every step that writes text; step 4 (Testing goals), step 6 (MR body, Human testing doc, Task solution), D1 (Decision request), briefs (orchestrate step 2) |
| `dev.ps1` | steps 1-5 (`wt`, `stack`, `check`, `gate`, `tracker`), CI wait (`pipes`), PreToolUse hook (`guard`) |
| `lib.ps1` | library dot-sourced by every kit script (config, paths, OS, tracker and git-host adapters); never run by hand |
| `devtools.py` | step 6 (`mr`, `doc`, `finish`), step 7 (`merge`), rebase conflicts (`keepboth`), check migrations (`lbcheck`, run by `check`) |
| `spec.mjs` | step 4: the test runner `check -Step test` uses for a web project without a unit-test target (never by hand) |
| `paths.json` | the one map of runtime (`.runtime/`) and durable (`.state/`) paths, read by lib.ps1 / devtools / spec / browser |
| `kit.example.json` | setup: `kit.ps1 setup -WriteLocal` writes `kit.local.json` and the other local files from it (keys: README "Configuration") |

## Steps (every dev agent; your brief wins where it differs)
```powershell
$D = '<kit>/skills/dev-kit/dev.ps1'; $O = '<kit>/skills/orchestrate/orch.ps1'; $L = '<kit>/skills/local-env/localenv.ps1'
& $O learn -Read -Skill dev-kit                                                # 0. lessons
& $O board join -Agent <id> -Run <run> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md
& $D tracker status <task> inProgress
& $D wt new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>; & $D wt sync -Dir <wt>   # 1. worktree, latest target
#   2. bugs: REPRODUCE on the local env first (local-env SKILL.md "Debug locally"); record it in the testing-goals doc
#   3. code (Rules > Scope; a choice the task did not make -> D1 decision request)
#   4. testing goals doc (templates.md "Testing goals") + the automated tests (Rules > Tests)
& $D check -Dir <wt>/<module>                                                  #    compile + typecheck + lint (gated)
& $D check -Dir <wt>/<module> -Step test -Tests "<names>" -Touched             #    targeted + every test of the touched files
& $D check -Dir <wt>/<module> -Step migrations                                 #    if you touched migrations: ISSUES 0
& $D wt commit -Dir <wt> -Message "feat(scope): ..."                           #    hooks run
#   5. LOCAL TEST LOOP (local-env SKILL.md "Local testing"): deploy, lease, run every goal; failed -> back to 3 (max 3 rounds,
#      then report BLOCKED with the failing goals); 0 errors + every goal reached -> 6
& $D wt sync -Dir <wt>; & $D check -Dir <wt>/<module>; git -C <wt> push -u origin <branch>
python <kit>/skills/dev-kit/devtools.py mr <wt> "<title>" body.md              # 6. MR (templates.md "MR body")
python <kit>/skills/dev-kit/devtools.py doc "<title>" testing.md               #    human testing doc -> link it on the task and in the MR
python <kit>/skills/dev-kit/devtools.py finish <task> <doc url> solution.md review   # guide link + solution comment + status review
#   7. merge: inside /dev-wave the workflow merges after review (never you). One small change by yourself:
python <kit>/skills/dev-kit/devtools.py merge <wt> <iid>                       #    producers first; last line MERGED|SCHEDULED|WAIT|...
& $O track add -Task <task> -Mrs <repo>!<iid>,...                              #    promoted once all merge (automatic)
& $O deploy request -Mrs <repo>!<iid>,... -Run <run>                           # 8. joins the deploy batch silently (never deploy, never ask)
& $O board leave -Session <token> -Status done                                 # 9. final report (templates.md "Final reports")
```
- D1. **Decision pause**: about to change business logic / existing behaviour the task did not ask for, or several valid paths
  (design, data handling, migration strategy, UX)? `& $O decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options
  "A: ..","B: .." -Recommend <A|B> -Contracts <brief>.contracts.md`, stop THAT item (report it as `needsDecision`), continue the
  others. The answer comes back in the contracts file (`decide wait -Id <id>`); then finish the item from it.
- No `localEnv` configured for your repo: step 5 = the automated tests only; say "local env: none" in the MR and the report.

**Rules**
- **Board:** `join` first (DUPLICATE for your id -> stop without writing); `beat -Session <t> -Status "<doing>"` before builds
  and
  pushes; `check -Worktree <wt> -Session <t>` before each commit (another writer -> stop, tell the coordinator); `leave` at the
  end.
- **Worktrees:** one per repo (`wt new`); deps-differ warning -> `-LinkFrom <checkout of the target branch>`; never install into
  a
  linked `node_modules`/`.venv`; `wt sync` before editing, before every push, before merging; `wt remove` when done.
- **Gate:** every build/test through `dev.ps1 check` (or `gate -Cmd "<cmd>"`), never Maven/Gradle/dotnet/ng/jest/pytest/cargo
  directly; waiting is normal, a killed build is not a code failure. Tool timeout 600000 ms (or `run_in_background`). A gate
  still queued when you must stop: push, open the MR as Draft with `Not run: <gate>`, report NOT_MERGED. No dev servers by hand
  (the local env runs them), at most one headless browser; phones only through `swarm.ps1 acquire` (never `up`/`down`).
- **Tests** (stack-agnostic; reviewers check them, the dev loop is the guard because CI may skip tests):
  - Ship: unit tests for new/changed logic; a regression test per fixed bug (red before, green after); integration/API tests
    for endpoints touched; UI/component tests for screens touched where the stack supports it.
  - Shape: arrange / act / assert; one behaviour per test; names `should_<behaviour>_when_<condition>` (or the repo's style);
    no sleeps or real clocks (fixed clock); no shared mutable state; deterministic builders / fixtures; mocks only at
    boundaries; no network unless tagged integration.
  - Place: next to the repo's existing tests (its convention wins; `dev.ps1 stack` shows the runner; `kit.local.json`
    `tests.<stack>.testFor` maps a source name to its test names for `-Touched`).
  - Run: `check -Step test -Tests <new tests> -Touched` before every push; the coordinator schedules a full suite
    (`check -Step test -AllTests`) per repo on its own cadence. Each testing goal names its test or its local manual check.
- **Commits:** Conventional Commits + the attribution trailer your harness or org asks for; `wt commit` only; never
  `--no-verify`, never type a hook's marker, never change shared git config, never `git stash`.
  Checkpoint: a WIP commit (`chore(wip): <step>`) after each step 1-5, so a crash or restart loses no edits.
- **Scope:** only your items; additive changes (optional fields, new endpoints/params, flags); never remove features or inputs;
  DTOs not entities in APIs; foreign files only as one-line hooks you list; decisions in the brief are final, a NEW one -> D1.
- **Shared code:** before changing a shared helper, hook, service, formatter, validator, default or global style, grep every
  caller; overrides opt-in; key shared formatters by field; a round-trip test; list the callers in the MR and the testing goals.
- **Text files:** write with the Write tool, change with Edit, pass file paths (`devtools.py doc <file>`, MR body from a file);
  never heredocs / sed / string-replace for text with backslashes, quotes or CRLF.
- **Migrations** (any tool: Liquibase, Flyway, Alembic, EF, Prisma, Django, none): only your assigned range; never edit a merged
  migration; a rollback for every schema/data change where the tool has one; append-only changelog conflicts:
  `python devtools.py keepboth <file>`; before every push `check -Step migrations` = ISSUES 0 (Liquibase; other tools: the
  repo's own check). Local env DB drift (a leftover table, a missing user): report it, never "fix" the shared DB by hand.
- **Ship:** re-read `<brief>.contracts.md` and the brief's bottom before pushing (append-only if you write to it); one MR per
  repo,
  title with `<tag><task>` (`tracker.branchTag`); producers (DB/API/library) merge before consumers; force-push only your own
  branch.
- **Tracker:** always `dev.ps1 tracker` (any backend; logical statuses `inProgress` -> `review` once the MR, the testing doc and
  the solution comment are posted -> `promoted` by `track` when all merge -> `inTest` after the deploy (coordinator)). Never set
  `inTest` or `closed` yourself.
- **Evidence:** UI -> screenshots, backend -> `qa.ps1 api -Save` JSON (names: qa-kit SKILL.md "Evidence"); never production;
  a 404/405 on an endpoint that exists on the target branch = stale deploy, not a code bug.

**Learn:** something cost time, failed or worked unusually well ->
`& $O learn -Skill dev-kit -Kind <kind> -Text "<what + fix>"`.
The guard hook's message names the right command when it blocks something.
