# Router (main session only)
The main session classifies every request here. SessionStart `bossy.ps1 health` puts this file in its context; not
in context -> Read it before acting. Spawned agents skip it: their prompt names the job.

## Router
Classify every request before acting: the first row whose conditions all hold wins; load the **Load first** skill, then go to
the **Target**. A mixed request is split and each part routed on its own.

| # | Conditions (all must hold) | Target | Load first |
|---|---|---|---|
| R0 | The request matches a row of "Org router rows" in `rules/*.local.md` (org-only skills and needs) | that org row's target | — |
| R1 | A coordinator event: a workflow notification, a supervise flag, stopped or restarted agents or workflows, a decision request, a person's `deploy <env>` or a finished deploy, QA results (failedTesting or new [Bug] tasks), the owner changing a rule mid-run, a SessionStart kit line | `bossy` → its Events table | — |
| R2 | Kit friction or a kit change: a kit script, hook, rule or workflow failed, blocked wrongly or needed a workaround, or a kit part or config key is added or changed | `kitty` agent (kind fix / build / docs) | — |
| R3 | The owner asks to audit, review, recover or repair the whole kit, set it up or fix missing config, or the local env or the phone lanes need admin (start, stop, refresh, wiring, create or reset lanes) or an ENV-FIX | `kitty` agent (one at a time; kind audit / recover / setup / env) | — |
| R4 | A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective | `/tidy` | `bossy` |
| R5 | Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens) | `/buildy` | `bossy` |
| R6 | Coding: one small change in one repo (one screen, file or endpoint, a quick fix, a config edit) | direct, crafty steps (a task, `track add` before merge) | `crafty` |
| R7 | A person says `deploy <env>` (or approves an ask under `deploy.trigger: ask`), deployed tasks are to move to in test, a deploy is to be rolled back, or a deploy secret is to be moved or rotated | `opsy` agent (kind deploy / rollback / status / secret; bossy E5) | — |
| R8 | Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents | `/testy` | `bossy` |
| R9 | A person tests by hand from a human testing doc | `pokey` → H steps | — |
| R10 | Test, check or verify one thing outside a running workflow: a deployed change, one screen or endpoint, a smoke after a deploy, a regression sweep, a user-report reproduction, perf on the local env, an "is X live / true?" claim | `checky` agent (role test; kind task / smoke / regression / repro / perf / claim) | — |
| R11 | The local env outside a running flow: inspect, reproduce or debug on it | `envy` skill | — |
| R12 | Phones or APKs outside a running flow: build the lane or local-env APK, a manual lease | `phoney` skill | — |
| R13 | Review something already written, outside a running workflow: open merge/pull requests, a kit commit, a brief, a testing or QA doc, a plan, a config, tracker texts | `revy` agent (kind mr / kit / doc / qa / plan / config) | — |
| R14 | Static audit of one module's code for bugs, performance or tech debt, without changing code | `revy` agent (kind module) | — |
| R15 | Data work: a run's test data to clean up, a build or test failing on setup data, a migration's data review, local DB marks / restores / seed, a backfill, a data check | `datay` agent (kind cleanup / fixture / migration / localdb / backfill / check) | — |
| R16 | Watch a deployed env: errors, logs or monitoring after a deploy, a nightly error sweep, an owner's error screenshot or report | `watchy` agent (kind window / sweep / triage) | — |
| R17 | Research before building or deciding: compare options, pick a library, is X free / licensed / supported, how Y works; no code change | `rechy` agent (kind question / compare / library / licence / spike) | — |
| R19 | Understand a video, screen recording or screenshot (a tester's or user's link or file): what it shows, what was done, where it failed | `vidy` agent (kind question / index) | — |
| R20 | Reverse-engineer a shipped app or binary without its source (native exe / dll, .NET, APK, JS bundle / Electron / wasm, firmware, a capture or a live process) | `reversy` skill | — |
| R18 | A question, an explanation, an analysis, a plan, or how the kit fits together (README graph sections); no code change | direct | — |

- One `devy` per brief area; `briefy` writes specs, briefs and contracts.
- `steppy`: spawned only by /buildy, /testy and /tidy for one `STEP:` prompt (a kit command, a launch record); never routed.
