---
name: bossy
description: "Load when: you are the main session routed here: launching or supervising /buildy, /testy or /tidy, a coordinator event (workflow finished, supervise flag, stopped agents, decision, a person's deploy <env>, QA results, SessionStart kit line, a restart), or a kit change. Not when: you are a crew agent (devy -> crafty, checky -> pokey); one small change -> crafty, directly."
---

**Load when** (all must hold): you are the main session; the router matched a coordinator, dev-flow, test-only, deploy or kit
row.
**Not when:** you are `devy` -> `crafty`; `checky` -> `pokey`; `revy` / `kitty` -> their agent steps; one small change ->
`crafty`.
**Hands off to:** `/buildy` (spawns `devy` + `revy`), `/testy` (spawns `checky` lead / test / verify), `/tidy`
(`kitty`), one `kitty` (kit changes, audits, ENV-FIX), the owner (decisions, duel verdicts).
**Files** (read or run each only at its step or event row):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `bossy.ps1 learn -Read -Skill bossy` |
| `bossy.ps1` | every event row (verbs: its header); hooks: SessionStart `health`, SendMessage `guard-sendmessage`, git `prepush` / `precommit` (goody `kit-admin`; `.githooks` install it) |
| `adapters/supervise_resources.ps1` | E1 heartbeat (`supervise`), `board show`, `recover`, `cleanup`: dot-sourced by bossy.ps1 (build gate, phones, QA seats, browsers) |
| `<kit>/.githooks/pre-commit`, `<kit>/.githooks/pre-push`, `<kit>/.githooks/post-merge` | K3: run by git (`bossy.ps1 setup` sets core.hooksPath) |
| `kitbag.py`, `<kit>/README.md`, `<kit>/tests/kit-tests.ps1` | K1-K3 (the `kitty` agent runs them); E14: README "Rule examples" |

## One orchestration model (both flows)
State every run shares: launch record (`bossy.ps1 launch`), agent board (`board`), tracking (`.state/tracking.json`, `track`),
decisions (`decide`), contracts (`<brief>.contracts.md` or `<runDir>/lead-notes.md`), the run report (`report -Run <id>`), agent
checkpoints (`crafty.ps1 checkpoint`), your own program state (`bossy.ps1 program set|get -Program <name>`: phases -> runs, MRs,
synced; never only in the session: a heartbeat after a restart reads it). Both
workflows return `{ agents|results, deployBatch?, decisions?, retroDue }`; they differ only in their steps.
What happened when, who called what: `bossy.ps1 audit -Run <run|wf id> | -Agent <id> | -Task <id> [-Since 2h]` (one
line per step, kit call, build, guard block, signal, decision, deploy; supervise and retros read it, never journals or log
files). Tunables (lease grace, timeouts, gate memory, heartbeat base, budget estimates) learn from live data:
`bossy.ps1 param show` (value, default, last change, next risky step; supervise -AutoFix learns: INFO per change). Launch by path:
`Workflow({ scriptPath: "<kit>/workflows/<wf>.js", args })`, always with `kitDir` (absolute) and `mandate` (the owner's words).
Invoking the coordinator is the only action needed: all steps run autonomously to completion without asking confirmation.

**Dev flow** (/buildy = `devy` -> `revy` -> CI -> merge -> `devy` (doc, tracker), or one `devy`, or you on a small change;
steps: AGENTS.md "The two flows"): merged work waits silently (`deploy request`) until a person says `deploy <env>` -> E5.

Only these dev paths need you (the workflow handles the rest: `workflows/buildy.js`):

| Dev path | You do |
|---|---|
| still FAIL after the stronger local round (MRs open, item held) | a follow-up wave, or ask the owner |
| ENV-FIX or needs decision (that item stops, the others continue) | E4 |
| held repo (`holdMerge`): MR reviewed, green | the owner's yes, then `devtools.py merge` |
| duel (goody `duel`): two `devy`, `revy` compares, they debate | E4: the owner judges from the debate record |
| stopped / restarted (launch record without completion) | E3 |

**Test-only flow** (/testy; steps: `workflows/testy.js`): all pass -> closed; own FAIL or incomplete -> failedTesting (E6); new
defect -> one [Bug] per ask (E6); a local env item still NOT_TESTED -> ENV-FIX (E4), then held, never failedTesting;
unpublished items -> `pokey.ps1 finalize` (`bossy.ps1 recover`).

## Steps (you = the coordinator)
0. `bossy.ps1 learn -Read -Skill bossy`. Project facts: the brief, run.json, memory, the repo's CLAUDE.md.
1. **Scope:** group work by area (disjoint screens / packages per agent), not item count; the local env each repo uses.
2. **Brief:** `crafty/templates.md` "Wave brief" in the scratchpad (limits: "Writing standards", kinds `wave-brief`,
   `owner-message`) (bugs: `bossy.ps1 bugbrief -Task <id> -Mandate '<the owner's words>' [-Complex]` per task).
3. **Status:** before the first agent of ANY task (spikes, analysis, docs too): `crafty.ps1 tracker status <task> inProgress`.
   **Launch** `/buildy` with `{ brief, agents:[{id, items, area, dependsOn?}], mode, kitDir, mandate, holdMerge? }`; then
   `bossy.ps1 launch -RunId <id> -Script <path> -ArgsJson '<args>'` (the workflow records its exact args itself); then E1.
4. **Relay** (E8): decisions and contracts -> append to `<brief>.contracts.md`; never SendMessage a workflow agent (a hook
   blocks it).
5. **Close** (deploys only on a person's word, E5): reconcile backlog vs merged MRs; list only what is open, each with a reason.
- T1-T4 (test-only): `/testy { select: { statuses: ['promoted', 'inTest'], lists?, tasks?, exclude? }, target, kitDir,
  mandate }` (its Prepare agent builds the run: pokey L1 Selection; `target` = an env or a `qa.targets` group), or a ready
  `{ runDir, kitDir }` -> `launch` record -> E1. Its log lists the tasks left out (not live, no testing doc, no target).
~15 devy queue fine on the gate; beside app-lane QA cap `lanes` at 2.

## Events (check this table whenever something happens)
| # | Event | Action |
|---|---|---|
| E1 | Workflow/agent launched or active runs found, and no heartbeat runs | ONE heartbeat, one-shot: a timer in `supervise.heartbeatMinutes` (15, learned) min, prompt: run `bossy.ps1 supervise -AutoFix -Brief`, paste output verbatim (own line only when ACT needs action), act on flags, then re-arm the timer to its last line `NEXT <n> min` (one-shot schedule or cron update: 5 on an ACT / ENV-FIX, 30 when nothing runs); 2nd session supervisor steps aside. Stop when nothing runs |
| E2 | supervise prints ACT / WATCH | do the printed action; leave healthy agents alone; answered or false: `supervise -Ack '<flag start>' -Reason '<why>'` (hidden 24 h) |
| E3 | Agents/workflow stopped (crash, limits, restart, power loss), budget handoff, or the owner pauses (power off, offline) | pause: `bossy.ps1 pause -All` (or `-Run <run>`, `-Reason`) until "safe to power off"; the machine stays on: stop the workflow runs and the heartbeat. Back or after a crash: `bossy.ps1 resume -All` (network first; a brief per agent from its checkpoint; then `recover`'s exact `Workflow({ scriptPath, resumeFromRunId, args })`, refused -> its RELAUNCH line (`mode: 'resume'`, per-area `resume` skip list from host + tracker: done steps skipped, all done = no agent); unpublished QA -> `pokey.ps1 finalize` lines); then E1. You stopped it: `launch -Done -RunId <id>` |
| E4 | DECISION <id> (supervise, decisions, duel debate) · ENV-FIX <id> (local-env fix for kitty/coordinator; `envFixes`) | DECISION: ask owner with options + recommendation (owner judges a duel); `bossy.ps1 decide answer -Id <id> -Answer '<words>'`; evidence settles -> a duel (goody `duel`). ENV-FIX: you or `kitty` (kind env) fix (config, paths, hung train, shared DB: `envy.ps1 seed` / `restore -Mark`; service starts only from live lease); fixer answers `decide answer -Id <id> -By kitty -Answer 'done: <what>'`; never ask owner. Item resumes; held after cycles: fix + `pokey.ps1 retest` |
| E5 | A person says `deploy <env>`, or supervise DEPLOY ASK | at once, end to end, no question back: the steps in `<kit>/skills/bossy/deploys.md` (goody `deploys`); then in test: testers, or /testy on request |
| E6 | QA results: failedTesting tasks or new [Bug] tasks (supervise) | `bossy.ps1 bugbrief -Task <id> -Agent B-<code> -Repos <r>` per task, then ONE /buildy `mode: 'bugfix'` for all (reproduce locally first) |
| E7 | A workflow finished (notification) | `launch -Done -RunId <id>`; `report -Run <id>` (timeline: `audit -Run <id>`); `next` (budget stop, batch, refusal) -> launch it; MR states from report; open findings -> follow-up wave; `deployBatch` waits for person's word (E5); then E10 |
| E8 | The owner changes a rule or scope mid-run | append to brief AND contracts file (QA: `lead-notes.md`); agents re-read before every push / check |
| E9 | The owner asks for something destructive while runs go on | do it yourself after they finish |
| E10 | A run finished or stopped (pause, `launch -Done`: their signals are recorded then), supervise says "retro due", or signals piled up | launch /tidy yourself, no owner ask, once no other workflow of this session runs (one retro covers several runs) |
| E11 | HEAL: guard block wrong, script crash, workaround, kit friction; a line `<feature> is a goody: run kitbag.py goody add <name>` | the goody line: `kitbag.py goody sync` (between runs) or the line's `goody add`, retry. Else spawn `kitty` (kind fix; K1-K3); re-tests, gets `revy` review, pushes and retires lesson (`learn -Fixed`) |
| E12 | LEARN: something cost time, failed or surprised you | `bossy.ps1 learn -Skill <s> -Kind <kind> -Text "<what + fix>"`; 2x -> lesson (`-Lesson "... (n×)"`, goody `kit-admin`); 3x -> script check / default |
| E13 | SessionStart kit line (git state, gates, lint, ports, stopped runs, retro/audit due) | stopped runs -> E3 + E1; uncommitted -> commit + push; behind -> `git pull --rebase` when idle; audit due -> spawn ONE `kitty` (kind audit); pulls live clone when idle, relays ASK list |
| E14 | A new repo or stack joins | `crafty.ps1 stack -Dir <module>`; wrong commands -> `.claude-stack.json`; conventions -> `rules/*.local.md` (README "Rule examples") |

## Change the kit (HEAL and extending)
- K1. Spawn ONE `kitty` (`subagent_type: 'kitty'`, kind build / fix / docs / audit / setup / env / recover) with the change or the
  friction in the owner's words. It works in its own kit worktree (never the live clone: runs execute it), keeps the kit generic
  (no org, product, tenant, host, id or local path; config through `kit.local.json`; org-only parts in the local overlay), adds
  parts with `kitbag.py new` (README "Extending"), prefers a script check over a rule, and has `revy` (kind kit) review the diff.
- K2. Its checks (kitty step 8): `kitbag.py lint` = 0 problems and 0 counted flow issues, `port` + `port --check`, parsed .ps1,
  `py_compile`, `node --check`, `tests/kit-tests.ps1`, `cost --steps` after a workflow change, `lint --org-terms`.
  Over the kit cap: trim, else `kitbag.py budget raise`.
- K3. It commits (the pre-commit hook regenerates the README graph and the ports, and blocks on lint), rebases, pushes main
  fast-forward (pre-push blocks org terms and local files) and retires the lesson the change fixes (`learn -Fixed`). You pull the
  live clone once no run uses it and relay its ASK lines.

**Learn:** `bossy.ps1 learn -Skill bossy -Kind <kind> -Text "<what + fix>"`.
