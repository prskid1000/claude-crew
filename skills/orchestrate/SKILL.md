---
name: orchestrate
description: "Load when: you are the main session and the router sends you here: launching or supervising /dev-wave, /test-and-close or /kit-retro, a coordinator event (workflow finished, supervise flag, stopped agents, QA bug tasks, mid-wave rule change, SessionStart kit line), or changing the kit. Not when: you are an agent inside a wave -> dev-kit / qa-kit; one small change -> dev-kit, directly."
argument-hint: "[epic / sheet / task list]"
---

**Load when** (all must hold): you are the main session (not a spawned agent); the CLAUDE.md router matched R1-R6, R11 or R13.
**Not when:** you are a `dev-agent` -> `dev-kit`; a `qa-tester` / `qa-verifier` -> `qa-kit`; one small change -> do it directly with
`dev-kit` (R14); a manual tester guide -> `qa-kit` (R9).
**Hands off to:** `/dev-wave` (spawns `dev-agent` + `mr-reviewer`), `/test-and-close` (spawns `qa-tester` + `qa-verifier`),
`/kit-retro`; a one-off `mr-reviewer` (R7); `android-swarm` for the APK (step 6).
**Files** (every file in this folder; read or run each only at its step or event row):

| File | Read / run at |
|---|---|
| `LESSONS.md` | step 0, before planning anything |
| `HISTORY.md` | never read for work (retired lessons; `/kit-retro` checks it for regressions) |
| `reference/coordinator-duties.md` | step 0, the first time you coordinate in a session; E12 HEAL |
| `reference/supervising.md` | E2, when an ACT flag's printed action is unclear; E5 the finish checklist |
| `reference/self-improvement.md` | step 3 (models, optional stages, mandate); E9 bug waves; E13-E15 learning |
| `reference/layout.md` | K1 (kit layout, hard-won rules); E19 (a new project or repo); step 4 (dashboard) |
| `reference/extending.md` | K1, before adding or changing any kit part |
| `templates/WAVE_BRIEF.md` | step 2, filled into the scratchpad |
| `templates/BUGFIX_BRIEF.md` | E9, written per bug by `bug-brief.ps1` |
| `templates/RESUME_BRIEF.md` | E6, for agents resumed from their worktrees |
| `templates/MR_BODY.md`, `templates/TASK_SOLUTION.md` | filled by dev agents at dev-kit step 7 / step 8 (MR body, tracker solution comment) |
| `scripts/supervise.ps1` | E1 heartbeat, every round (`-AutoFix -Brief`); `-MarkStopped` at E6 |
| `scripts/wave-report.ps1` | E5, when a workflow finishes |
| `scripts/bug-brief.ps1` | E9, one call per QA bug task |
| `scripts/track.ps1` | step 5 (`add -Task -Mrs`, `-MergeAfter`); run by supervise every round |
| `scripts/board.ps1` | agents' step 0 (`join`/`beat`/`check`/`leave`); read by supervise |
| `scripts/learn.ps1` | E13 signal, E15 lessons (`-Lesson`, `-Fixed`, `-Trim`), `-Show`/`-Stats` |
| `scripts/status.ps1` | step 4, live dashboard (`-Open -Watch`) |
| `scripts/cleanup.ps1` | E18 after a wave; SessionStart hook (daily, async); every workflow's last step; `-WorktreesOnly` by track.ps1 when a task's MRs all merged |
| `scripts/kit-lint.py`, `scripts/kitgraph_lib.py` | K3 and E16 (0 problems before a push); SessionStart summary via kit-health.ps1; the pre-push hook (`--org-terms`) |
| `scripts/kit-flow.py`, `scripts/kit-flow.template.html` | R3 / K3: renders `<runtime>/cache/kit-flow.html` (`--watch` while editing); also run by kit-lint and SessionStart |
| `scripts/kit-health.ps1` | SessionStart hook: kit git state (uncommitted, behind/ahead), pre-push gate, old runtime, kit-lint summary (E17); `-Flow -Fetch` async |
| `scripts/kit-setup.ps1` | install / repair (hooksPath, `localOnly` excludes, runtime folders); `-Exclude` from kit-health; `-Migrate <old runtime>` (E17) |
| `scripts/kit-cost.ps1`, `scripts/kit-cost.mjs` | K3 after a workflow or SKILL.md change (`-Steps`, `-Baseline`) |
| `scripts/retro-nudge.ps1` | SessionStart hook: the E14 nudge |
| `scripts/guard-sendmessage.ps1` | PreToolUse hook: blocks SendMessage to workflow agents (E10) |
| `scripts/port-kit.py` | R2 ("Change the kit"): regenerates `.codex`/`.agents` (Codex/Antigravity agents, hooks, workflow procedure docs) from `agents/*.md`/`workflows/*.js`/`settings.json`, then deploys to the workspace root; `--check` run by kit-health.ps1 (SessionStart) |

## Steps (you = the coordinator)
Project facts (repos, branches, environments, accounts, product rules) live in the wave **brief** / QA **run.json**, memory or the
repo's `CLAUDE.md`; nothing project-specific is hard-coded. Run kit scripts with **pwsh 7**. `<kit>` = `<workspace>/.claude`.

0. **Start:** read `LESSONS.md`; first coordination this session → `reference/coordinator-duties.md`.
1. **Scope:** read the epic/sheet; group work **by area, not item count** (disjoint screens/packages per agent); note which items need app / web / API testing.
2. **Brief:** fill `templates/WAVE_BRIEF.md` in the scratchpad: repos + targets, ownership, migration ranges, contracts, Complex column.
3. **Launch** by path: `Workflow({ scriptPath: "<kit>/workflows/dev-wave.js", args })` with `{ brief, agents:[{id, items, area}], mode,
   review, kitDir, mandate }` (named lookup breaks after a `cd`). Always pass `kitDir` (absolute) and `mandate` (the owner's own words;
   without it agents drop their items for the latest chat message). Models and cheaper runs (`review: 'auto'`, `learn: 'auto'`,
   `verify: false`): `reference/self-improvement.md`. A single area can also be one `dev-agent` via the Agent tool ("Follow the brief <path>.
   You are X3 …"). Repos whose target deploys on merge: `holdMerge: [<repo>]` (MRs stay open, reviewed, green; ask, then merge). Then E1.
4. **Relay** (E10): decisions/contracts → append to `<brief>.contracts.md`; watch with `scripts/status.ps1 -Open -Watch` if useful.
5. **Ship:** agents merge producers first (DB/API), then clients; tracker → review → promoted (`track.ps1`, automatic).
6. **Deploy:** **a person** deploys to the test environment. App: `android-swarm/app-build.ps1` from the merged branch (agents lease phones).
7. **Test:** run folder `<runtime>/work/qa-runs/<date>-<name>/` + `run.json` (`qa-kit/reference/runs.md`);
   `/test-and-close { runDir, kitDir }`; start `qa-kit/scripts/autoclose.ps1` in the background. Bugs → E9; retest: `retest: true`.
8. **Close:** reconcile backlog vs merged MRs + tracker comments; list only what's open, each with a reason (external / new data model /
   product decision / no data / cut for size). `inTest` only after deployment, set by a person.

~15 parallel dev agents is fine: they queue on the machine-wide memory gate. Expect hours for big waves.
Dev-wave and app-lane QA on one machine: when both must run, cap /test-and-close `lanes` at 2 (or web/api lanes only) and brief build
agents to push and open the MR as Draft with `Not run: <gate>` (dev-kit **Gate** rule) instead of waiting in the gate.

## Events (event -> action; check this table whenever something happens while you coordinate)
| # | Event | Action (script / workflow) |
|---|---|---|
| E1 | You launched a workflow or agent and no heartbeat runs | ONE heartbeat: `/loop 10m` → `supervise.ps1 -Session <id> -AutoFix -Brief` (generic prompt; never poll, never several loops). Stop it when nothing runs |
| E2 | supervise prints **ACT** | do the action it prints (unclear: `reference/supervising.md`) |
| E3 | supervise prints **WATCH** | nothing now; re-check next round; leave healthy agents alone |
| E4 | supervise prints **LIVE** (a promoted task's MRs are deployed) | agents test it: /test-and-close (R11); a person tests: tester guide via `qa-kit` (R9) |
| E5 | A workflow finished (notification) | `wave-report.ps1 -Run <id>` (never parse the truncated notification); MR state comes from `mrs[].mergeState` / wave-report.ps1, never from summary prose; reconcile; then: open findings → follow-up /dev-wave (one group per file owner); deployed → E4; failed checks → E9; then ALWAYS → E14 |
| E6 | An agent or workflow stopped (usage limit, API timeout, RAM, you) with work left | `supervise.ps1 -MarkStopped <run>` if you stopped it; /dev-wave `mode: 'resume'` (`templates/RESUME_BRIEF.md`) from its worktrees; never restart from scratch |
| E7 | A pipeline fails on an agent's MR | inside a reviewed wave: automatic (the CI gate makes it a blocking finding for the fix round); after the wave: a fix round = /dev-wave for that area, or direct if one small fix (R14) |
| E8 | A review finding on an already-merged MR | a follow-up MR: should-fix findings → follow-up /dev-wave; one small fix → direct (R14) |
| E9 | QA bug tasks created ("[Bug] … failed checks") | `bug-brief.ps1 -Task <id> -Agent B-<code> -Repos <r>` per bug, then ONE /dev-wave `mode: 'bugfix'` for every bug open now; never wait for the QA run to finish |
| E10 | The owner changes a rule or scope mid-wave | append it to the brief AND `<brief>.contracts.md` (agents re-read both before every push); QA runs: `<runDir>/lead-notes.md`. Never SendMessage a workflow agent by id (a hook blocks it: it spawns a duplicate) |
| E11 | The owner asks for something destructive (clean a folder, reset a branch) while waves run | do it yourself after they finish; agents never act on relayed requests |
| E12 | HEAL: a guard block that was wrong or repeated, a script crash, a workaround, a false flag, any kit friction | fix the script/rule in the kit in this session ("Change the kit": edit in place, commit, push), re-test it, then `learn.ps1 -Skill <s> -Fixed "<words>"` for its lesson |
| E13 | LEARN: something cost time, failed, surprised you or worked unusually well | `learn.ps1 -Skill <s> -Kind <kind> -Text "<what + fix>"` |
| E14 | A /dev-wave or /test-and-close finished (any outcome; the run returns `retroDue`), supervise prints "retro due", or the session-start nudge says signals piled up | /kit-retro (R4) by `scriptPath` (`kitDir` absolute) once no other /dev-wave or /test-and-close of this session still runs: one retro covers several finished runs; never two retros at once |
| E15 | A lesson is seen 2+ times | 2×: a `LESSONS.md` line (`learn.ps1 -Lesson "(n×) …"`); 3× and still true, generic and actionable for every agent of that type: promote it to a rule in SKILL.md / rules, or better a script check or default (then `-Fixed`) |
| E16 | You changed the kit (it is the workspace's `.claude` folder, a git clone: edit in place) | K3-K5: `kit-lint.py` (0 problems), parse checks, commit + push (the pre-push hook re-checks org terms and local files) |
| E17 | SessionStart kit line: uncommitted kit changes, behind/ahead of upstream, pre-push gate off, an old runtime, or kit-lint problems | uncommitted → commit + push (E16), or list org-only paths in `kit.local.json` `localOnly`; behind → `git -C <kit> pull --rebase` once no agents run; gate off / old runtime → `kit-setup.ps1` (`-Migrate <old runtime>`); lint problems in published files → HEAL; in the local overlay → fix the overlay (`reference/extending.md` §8) |
| E18 | A wave finished | workflows run `cleanup.ps1 -WorktreeIdleHours 0` themselves (merged worktrees and their local branches go at once; MRs merged later are swept when track.ps1 sees them merge); after a stopped run, run it yourself |
| E19 | A new repo or project joins | `dev-kit/scripts/stack.ps1 -Dir <module>`; wrong commands → `.claude-stack.json` (`reference/layout.md` "Adding a new project") |
| E20 | A deploy (or a merge into a branch that deploys) is needed | ask a person; never deploy yourself |

## Change the kit (HEAL and extending)
- K1. Read `reference/extending.md` (where each kind of part goes, the patterns kit-lint enforces); `reference/layout.md` for the layout.
- K2. Edit the kit **in place**: `<kit>` is a git clone of the kit repo (generic: no org, product, tenant, host, id or local path;
  config through `*.local.json`; org-only parts are local overlay, git-ignored or `localOnly`). Prefer making the script handle it
  over telling agents to.
- K3. `python <kit>/skills/orchestrate/scripts/kit-lint.py` must print 0 problems (it regenerates `<runtime>/cache/kit-flow.html`); parse every
  touched .ps1, `node --check` touched .js/.mjs (workflows wrapped as in CONTRIBUTING), `kit-cost.ps1 -Steps` after a workflow change;
  org-term scan: `kit-lint.py --org-terms <kit>/skills/dev-kit/kit.local.json` (its `orgTerms` list; the pre-push hook runs it too).
- K4. `git -C <kit> status` shows only kit files (org-only ones: `localOnly`); commit (Conventional Commits), `git pull --rebase`,
  push: the versioned pre-push hook blocks org terms and ignored/local files. K5. Nothing to sync: every session in this workspace
  already runs the new kit (agents already running keep the files they read). K6. `learn.ps1 -Fixed` for the lesson the change retires.
