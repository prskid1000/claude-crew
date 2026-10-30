---
name: crafty
description: "Load when: you write, fix, test or ship code in a repo of this workspace: as devy from a brief, or directly for one small change. Not when: you coordinate several agents -> bossy; you test deployed work on a test env -> pokey; you audit code without changing it or review someone's MRs -> revy agent."
---

**Load when** (all must hold): you change code in a repo of this workspace; you are `devy` from a brief, or the main
session on a one-small-change router row.
**Not when:** coordinating agents -> `bossy`; testing deployed work -> `pokey`; static audit or reviewing
MRs -> `revy`; running the shared local env itself -> `envy` (you use it at step 5).
**Hands off to:** `envy` (steps 2 and 5: reproduce, test), the coordinator (your final report; the workflow merges after
review; a person's `deploy <env>` starts the deploy), testers through the human testing doc (step 6).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0 (`bossy.ps1 learn -Read -Skill crafty`) |
| `templates.md` | "Writing standards" whenever you write; steps 4 and 6, D1 |
| `crafty.ps1` | steps 1-5, CI wait (`pipes`), the PreToolUse hook (`guard`) |
| `lib.ps1` | dot-sourced by every kit script; never run by hand |
| `devtools.py` | steps 6-7, rebase conflicts (`keepboth`) |
| `kit.example.json` | setup (`bossy.ps1 setup -WriteLocal`; keys: README "Configuration"); `_paths`: every state path |

## Steps (every devy; your brief wins where it differs)
```powershell
$D = '<kit>/skills/crafty/crafty.ps1'; $O = '<kit>/skills/bossy/bossy.ps1'; $L = '<kit>/skills/envy/envy.ps1'
& $O learn -Read -Skill crafty   # 0. lessons
& $D prior -Task <id> -Repo <repo>   # 0. FOUND: stop, tell the coordinator
& $O board join -Agent <id> -Run <run> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md
& $D tracker status <task> inProgress
& $D wt new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>; & $D wt sync -Dir <wt>   # 1. worktree, latest target
#   2. bugs: REPRODUCE on the local env first (envy SKILL.md "Debug locally"); record it in the testing-goals doc
#   3. code (Rules > Scope; a choice the task did not make -> D1 decision request)
#   4. goals.md (local) + AI testing doc FIRST (templates.md) + automated tests (Rules > Tests); each loop round:
#      devtools.py doc "<title>" ai.md --key <task>:testing-ai --label "round <n>"
& $D check -Dir <wt>/<module>   #    compile + typecheck + lint (gated)
& $D check -Dir <wt>/<module> -Step test -Tests "<names>" -Touched   #    targeted + every test of the touched files
& $D check -Dir <wt>/<module> -Step migrations   #    if you touched migrations: ISSUES 0
& $D wt commit -Dir <wt> -Message "feat(scope): ..."   #    hooks run
#   5. LOCAL TEST LOOP (envy SKILL.md "Local testing"): deploy, lease, run every goal; a failed goal or bug (yours, checky's)
#      -> back to 3 until 0 open bugs (max 3 rounds; then FAIL + failing goals: a stronger round, then the
#      coordinator); never BLOCKED for an env reason (envy "Unblock yourself", D2); NOTICE "deploy of <svc> starting,
#      pause" -> stop checks there until "deploy done", then re-run; 0 bugs, every goal met -> release -> 6
& $D checkpoint -Agent <id> -Run <run> -Step loop -Item <task> -Evidence "round <n> PASS"
& $D wt sync -Dir <wt>; & $D check -Dir <wt>/<module>; git -C <wt> push -u origin <branch>
python <kit>/skills/crafty/devtools.py mr <wt> "<title>" body.md              # 6. MR ("MR body"); after finish: again, both links
python <kit>/skills/crafty/devtools.py finish <task> testing.md solution.md review --ai ai.md   # human doc, links block, comment, status
#   7. merge: inside /buildy the workflow merges after review (never you). One small change by yourself:
python <kit>/skills/crafty/devtools.py merge <wt> <iid>                       #    producers first; last line MERGED|SCHEDULED|WAIT|...
& $O track add -Task <task> -Mrs <repo>!<iid>,...   #    promoted once all merge (automatic)
& $O deploy request -Mrs <repo>!<iid>,... -Run <run>   # 8. deploy batch, silently (goody deploys; never deploy, never ask)
& $O board leave -Session <token> -Status done   # 9. final report (templates.md "Final reports")
```
- D1. **Decision pause**: about to change existing user-visible behaviour the task did not ask for (internal logic with the
  same behaviour: no pause), or several valid paths
  (design, data handling, migration strategy, UX)? `& $O decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options
  "A: <label> — <why>","B: .." -Recommend <A|B> -Contracts <brief>.contracts.md` (`-Fyi`: nothing waits), stop THAT item
  (`needsDecision`), continue the others. The answer: contracts file (`decide wait -Id <id>`); finish the item from it.
- D2. **ENV-FIX**: a local-env fix only the coordinator may do (`up`/`down`/`refresh`/`drop`, shared DB repair): `& $O decide ask
  -Kind envfix -Run <run> -Agent <id> -Item <item> -Question "<the fix>"`, stop THAT item (`needsEnvFix`), continue the others.
  `localTest` BLOCKED only for an owner decision or a remote-only dependency (`blockedKind`, `blockedReason`).
- No `localEnv` configured for your repo: step 5 = the automated tests only; say "local env: none" in the MR and the report.
  `envy` (steps 2, 5, `$L`) is the goody `local-env`: `localEnv` set but `skills/envy/` missing ->
  `kitbag.py goody sync` once, else the same as no `localEnv`.

**Rules**
- **Board:** `join` first (DUPLICATE for your id -> stop without writing); `beat -Session <t> -Status "<doing>"` before builds
  and pushes; `check -Worktree <wt> -Session <t>` before each commit (another writer -> stop, tell the coordinator); `leave` at
  the end.
- **Worktrees:** one per repo (`wt new`); deps-differ warning -> `-LinkFrom <checkout of the target branch>`; never install into
  a linked `node_modules`/`.venv`; `wt sync` before editing, before every push, before merging; `wt remove` when done.
- **Gate:** every build/test through `crafty.ps1 check` (or `gate -Cmd "<cmd>"`), never Maven/Gradle/dotnet/ng/jest/pytest/cargo
  directly; waiting is normal; a killed build is no bug. Tool timeout 600000 ms, or `run_in_background` bounded
  (timeout or loop cap, no stdin read; killed before `leave`). A gate still queued when you must stop: push, Draft MR with
  `Not run: <gate>`, report NOT_MERGED. No dev servers by hand (the local env runs them), at most one headless browser; phones
  only through `phoney.ps1 acquire` (never `up`/`down`; goody `android-swarm`); Docker / WSL / VMs: `crafty.ps1 runtime use
  -Name <r>` first, `release` when done (goody `runtimes`; the guard leases if you forget).
- **Tests** (any stack; reviewers check them; CI may skip tests, the dev loop guards):
  - Ship: unit tests for new/changed logic; a regression test per fixed bug (red before, green after); integration/API tests
    for endpoints touched; UI/component tests for screens touched where the stack supports it.
  - Shape: arrange / act / assert; one behaviour per test; names `should_<behaviour>_when_<condition>` (or the repo's style);
    no sleeps or real clocks (fixed clock); no shared mutable state; deterministic builders / fixtures; mocks only at
    boundaries; no network unless tagged integration. Every assertion runs: a list is asserted non-empty before a loop over
    it; a success test calls the endpoint and never branches on an error status; a placeholder is a listed coverage gap,
    never counted. Shared env or tenant: unique ids from one helper (no random, no real clock); assert only records the
    test made; settings and cleanup in before/after hooks registered before the mutation; cleanup accepts 2xx/404 only,
    the MR lists leftovers.
  - Place: next to the repo's existing tests (its convention wins; `crafty.ps1 stack` shows the runner; a web project without a
    unit-test target: goody `node-spec`; `kit.local.json` `tests.<stack>.testFor` maps a source name to its test names for
    `-Touched`). node-spec cannot bundle code needing framework DI or a linker (forms, router, store, injectable services):
    move the logic into a pure helper the component calls, spec that helper (never a local copy), list the wiring as a live check.
  - Run: `check -Step test -Tests <new tests> -Touched` before every push; the coordinator schedules a full suite
    (`check -Step test -AllTests`) per repo on its own cadence. Each testing goal names its test or local manual check.
- **Commits:** subject per `commitStyle` (default Conventional Commits) + any attribution trailer your harness or org
  asks for; `wt commit` only; never `--no-verify`, never type a hook's marker, never change shared git config or `git stash`.
- **Checkpoint** (crash, pause): at each step boundary (worktree, commit sha, testing goals, loop round N + result, MR url,
  review round, CI result, testing doc url, tracker, merge) `& $D checkpoint -Agent <id> -Run <run> -Step <worktree|commit|goals|
  loop|mr|review|ci|doc|tracker|merge> -Evidence "<sha|url|result>" -Dir <wt>`, and a WIP commit (`chore(wip): <step>`) after
  steps 1-5. `board join` prints CHECKPOINT: start at that step; verify the done ones, never redo them; keep an uncommitted
  diff. `board beat` prints PAUSE: checkpoint, WIP commit (no push), release your leases, `board leave -Session <t> -Status
  paused` (again while it prints PAUSED); return no result.
- **Scope:** only your items; additive changes (optional fields, new endpoints/params, flags); never remove features or inputs;
  DTOs not entities in APIs; foreign files only as one-line hooks you list; decisions in the brief are final, a NEW one -> D1.
- **Shared code:** before changing a shared helper, hook, service, formatter, validator, default or global style, grep every
  caller; overrides opt-in; key shared formatters by field; a round-trip test; list callers in the MR and the testing goals.
  A fix on one path: grep every other path that writes, serves or proxies the same data (sibling services, other products,
  every render path) and fix them in the same MR. An API status-code change: grep the API / e2e specs for the
  endpoint and delete stale known-bug blocks in the same MR.
- **Text files:** write with the Write tool, change with Edit, pass file paths (`devtools.py doc <file>`, MR body from a file);
  never heredocs / sed / string-replace for text with backslashes, quotes or CRLF.
- **Migrations** (any tool): only your assigned range; never edit a merged migration; a down / rollback for every change;
  append-only changelog conflicts: `python devtools.py keepboth <file>`; before every push `check -Step migrations` = exit 0
  (`repos[].migrations.check`, else Liquibase: goody `liquibase`; exit 5 = UNRUN: say so in the MR). Local env DB drift (a
  leftover table, a missing user): report it, never "fix" the shared DB by hand.
- **Ship:** re-read `<brief>.contracts.md` and the brief's bottom before the local test loop and before every push (a scope
  change stamped after your head commit is still yours; append-only if you write to it); one MR per repo, title with
  `<tag><task>` (`tracker.branchTag`); producers (DB/API/library) merge before consumers; force-push only your own branch.
  MR state in any report or text: only from the host at write time (`crafty.ps1 host mr.get`, merge's last line), never the
  brief or memory. Over its prose limit, `wt commit`, `tracker comment -Kind <comment-*>`, `devtools.py comment|finish|mr`
  refuse: rewrite (`-ProseOk` / `--prose-ok "<why>"` only for a format the brief fixes).
- **Tracker:** always `crafty.ps1 tracker` (any backend; `inProgress` -> `review` once the MR, both docs and
  the solution comment are posted -> `promoted` by `track` when all merge -> `inTest` after the deploy (coordinator)). Never set
  `inTest` or `closed` yourself; `promoted` needs both doc links, only atop the description, never in a comment.
- **Publish once per key:** docs and evidence via `devtools.py doc|evidence --key <task|run>:<kind>` (same link, a dated
  section per round); comments via `tracker comment -Kind <kind>` (edits the last kit one); `devtools.py mr` edits the open MR.
- **Evidence:** UI -> screenshots, backend -> `pokey.ps1 api -Save` JSON (names: pokey SKILL.md "Evidence"); never production;
  a 404/405 on an endpoint that exists on the target branch = stale deploy, not a code bug.

**Learn:** something cost time, failed or worked unusually well ->
`& $O learn -Skill crafty -Kind <kind> -Text "<what + fix>"`.
A guard hook block names the right command.
