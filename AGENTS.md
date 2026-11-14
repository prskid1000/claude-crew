# Workspace instructions (template — edit for your org)

A multi-agent dev + QA kit for any stack, repo shape, migration tool, local/test env, deploy mechanism and tracker, all
configured in `skills/crafty/kit.local.json`. Org specifics live only in `*.local.*` files and `rules/*.local.md`. **Never put
passwords, tokens or API keys here**: test logins live only in `skills/pokey/targets.local.json` (git-ignored).

Codex and Antigravity read this file directly, Claude Code through `CLAUDE.md`; edit only here.

## Writing (hard rule, every agent and session)
- Result first, then only what the reader needs to act: `<thing> <state/action> <reason>` -> next step.
- Lists and fragments, one fact per line, each fact once; link (MR, task, doc, run) instead of repeating it.
- Exact over descriptive (ids, paths, numbers, commands, error text); active voice; short common words; no invented abbreviations.
- Limits per artefact: table `skills/crafty/templates.md` "Writing standards", checked by `kitbag.py prose --kind <kind> <file>`.
  Fewer words, same facts: dense and specific. Code comment: 1 line saying why.
- Cut greetings, preamble, recaps, hedges, praise, filler, closing summaries. A longer-than-needed text is a defect.
- Chat to owner: dense text only (`<thing> <state/action> <reason>` -> next step); no Mermaid, SVG gauges or box art in chat turns. Visuals live in dashboard (supervise-report.html) and report artifacts:
  text wraps, never truncates; a changed page ships after `kitbag.py ui-check <page>` passes, shots read.
- **Corrections:** a correction applies to its whole group: when the owner corrects one output, format or behaviour, fix every
  sibling the same way (all adapters, templates, ports, docs that produce or describe it), a test each; list what changed.

## The two flows
- **Dev** (every code change): code -> testing-goals doc -> reproduce / debug + test on the local env (loop) -> review, merge,
  human testing doc, tracker promoted (no user gate) -> merged work waits: nobody asks or proposes a deploy; a person says `deploy
  <env>` and `opsy` deploys at once (`deploy.trigger`) -> in test -> testers close it, or it fails testing and comes
  back. Bugs are reproduced locally before they are fixed.
- **Test-only** (deployed tasks on a test env, on request): agent QA per human testing doc -> all pass: closed · own check failed
  or untested (undeployed): failedTesting · untested, no dev fix: owner decides · a new defect: one [Bug] under the original ask.
- **Budget** (README "Configuration"): agent hands off at 80% of tool compaction point (resume brief, fresh agent); run over cap is refused with split, at 80% nothing new starts (rest returns as `next`).
- **Decision pauses**: user-visible behaviour change not asked for, or multiple valid paths -> ask (`bossy.ps1 decide ask`), item waits, rest continue; internal logic with identical output needs no ask.

## Router
Classify every request before acting: the first row whose conditions all hold wins; load the **Load first** skill, then go to
the **Target**. A mixed request is split and each part routed on its own.

| # | Conditions (all must hold) | Target | Load first |
|---|---|---|---|
| R0 | The request matches a row of "Org router rows" in `rules/*.local.md` (org-only skills and needs) | that org row's target | — |
| R1 | A coordinator event: a workflow notification, a supervise flag, stopped or restarted agents or workflows, a decision request, a person's `deploy <env>` or a finished deploy, QA results (failedTesting or new [Bug] tasks), the owner changing a rule mid-run, a SessionStart kit line | `bossy` → its Events table | — |
| R2 | Kit friction or a kit change: a kit script, hook, rule or workflow failed, blocked wrongly or needed a workaround, or a kit part or config key is added or changed | `kitty` agent (kind fix / build / docs) | — (the agent holds its steps) |
| R3 | The owner asks to audit, review, recover or repair the whole kit, set it up or fix missing config, or the local env or the phone lanes need admin (start, stop, refresh, wiring, create or reset lanes) or an ENV-FIX | `kitty` agent (one at a time; kind audit / recover / setup / env) | — (the agent holds its steps) |
| R4 | A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective | `/tidy` | `bossy` |
| R5 | Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens) | `/buildy` | `bossy` |
| R6 | Coding: one small change in one repo (one screen, file or endpoint, a quick fix, a config edit) | direct, crafty steps (a task, `track add` before merge) | `crafty` |
| R7 | A person says `deploy <env>` (or approves an ask under `deploy.trigger: ask`), deployed tasks are to move to in test, a deploy is to be rolled back, or a deploy secret is to be moved or rotated | `opsy` agent (kind deploy / rollback / status / secret; bossy E5) | — (the agent loads `bossy`) |
| R8 | Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents | `/testy` | `bossy` |
| R9 | A person tests by hand from a human testing doc | `pokey` → H steps | — |
| R10 | Test, check or verify one thing outside a running workflow: a deployed change, one screen or endpoint, a smoke after a deploy, a regression sweep, a user-report reproduction, perf on the local env, an "is X live / true?" claim | `checky` agent (role test; kind task / smoke / regression / repro / perf / claim) | — (the agent loads `pokey`) |
| R11 | The local env outside a running flow: inspect, reproduce or debug on it | `envy` skill | — |
| R12 | Phones or APKs outside a running flow: build the lane or local-env APK, a manual lease | `phoney` skill | — |
| R13 | Review something already written, outside a running workflow: open merge/pull requests, a kit commit, a brief, a testing or QA doc, a plan, a config, tracker texts | `revy` agent (kind mr / kit / doc / qa / plan / config) | — (the agent loads `crafty` Rules) |
| R14 | Static audit of one module's code for bugs, performance or tech debt, without changing code | `revy` agent (kind module) | — |
| R15 | Data work: a run's test data to clean up, a build or test failing on setup data, a migration's data review, local DB marks / restores / seed, a backfill, a data check | `datay` agent (kind cleanup / fixture / migration / localdb / backfill / check) | — (the agent holds its steps) |
| R16 | Watch a deployed env: errors, logs or monitoring after a deploy, a nightly error sweep, an owner's error screenshot or report | `watchy` agent (kind window / sweep / triage) | — (the agent loads `pokey`) |
| R17 | Research before building or deciding: compare options, pick a library, is X free / licensed / supported, how Y works; no code change | `rechy` agent (kind question / compare / library / licence / spike) | — (the agent holds its steps) |
| R19 | Understand a video, screen recording or screenshot (a tester's or user's link or file): what it shows, what was done, where it failed | `vidy` agent (kind question / index) | — (the agent loads `pokey`) |
| R18 | A question, an explanation, an analysis, a plan, or how the kit fits together (README graph sections); no code change | direct | — |

- **Crew** (the only agent types, spawned only through these targets; names, roles and characters: `kit.example.json`
  `_manifest`): `devy` builds (by /buildy, one per brief area), `revy` reviews (by /buildy, R13, R14),
  `checky` tests (by /testy as lead / test / verify, R10), `kitty` keeps the kit and the machine (R2, R3, /tidy), `briefy` writes briefs and contracts (R5, E8), `rechy` researches (R17,
  /buildy Spike), `opsy` deploys on a person's word (R7, E5), `watchy` watches deployed envs (R16, E15), `datay` guards test and
  local data (R15, /buildy migrations, E2, E7), `vidy` reads videos and screenshots for any agent (R19; an existing vidy index is
  reused, never re-read).
  Each loads its skill first; its Character shapes judgement, tone and how it argues a dispute or debate, never a rule or the
  Writing standards. Step 0 of every agent reads the board (who is alive here); a disagreement: /buildy `disputes`, a
  debate or `board msg`, still split -> the owner decides (`decide ask`, both sides). Codex / Antigravity: the ported agents,
  workflows and mechanics are in AGENTS.override.md / GEMINI.md (`kitbag.py port`).
- **Autonomous:** user invocation is the standing opt-in. The coordinator and agents run all routed steps (worktrees, checks, edits, local test loops, reviews, CI, merging) without approval pauses. A request running in a workflow is never launched twice: add via contracts.
- **Deploys start only from a person's word**, never from an agent: with `deploy.trigger: owner` (default) nobody asks or proposes;
  the person says `deploy <env>`, then `opsy` runs it end to end. Merges into branches that deploy (`holdMerge`) need a yes too; merges
  into the main line after review, CI and the local test loop need none.

## Multi-agent work, builds and testing (every repo of the workspace)
`<kit>` = the `.claude` folder of the workspace (the directory Claude Code was started in); kit scripts find it themselves.
These rules hold whatever the route:

- File inspection: the Read tool (`offset` / `limit`), never a bare file path as a command (it opens a desktop app; the guard denies it); the top 40
  lines (the section line map), then only the line range you need, never a whole large file.
- Builds and tests go through `<kit>/skills/crafty/crafty.ps1 check` (stack auto-detected; the machine-wide memory gate queues
  them); parallel work in worktrees (`crafty.ps1 wt`), commits with `crafty.ps1 wt commit`; never install packages into linked
  `node_modules` / `.venv`. The guard hook blocks `git stash`, `--no-verify` and ungated builds. Rebase (`wt sync`) before
  editing, pushing and merging; merge only on a green pipeline, producers before consumers.
- Phones only through `skills/phoney/phoney.ps1 acquire`. Every kit resource (env service,
  browser tab, phone, build) has a holder: lease only what your item declares, release when done; no live holder for
  `idle.graceMinutes` -> released (README "Leases").
- Browsers are headless by default (`skills/pokey/browser.mjs`); a visible browser only when the owner asks to watch.
- Run python and node from the PowerShell tool (pwsh 7), not Git Bash; Python with `-X utf8`.
- Anything handed to node, python, java or another Windows program (arguments, JSON, env vars, file contents) uses Windows
  paths (`D:/...`, `D:\...` or the `crafty.ps1 dir` output), never Git Bash `/d/...` or `/c/...` (read as `\d\...` on the
  current drive; the guard denies it).
- Runtime output goes to `<kit>/.runtime/` (disposable) and durable state to `<kit>/.state/`, both git-ignored and resolved by
  name (`Get-KitPath`); never elsewhere in the kit. Your own files (notes, bodies, diffs, logs, evidence outside a QA run) go
  only where `crafty.ps1 dir -Agent <id> [-Item <task>] [-Name <file>]` (or `-Kind evidence -Item <task>`) says, never in `/tmp`,
  `%TEMP%` itself or a main checkout (shared: the guard denies body / desc files there).
- The kit learns: every agent reads its lessons at step 0 (`bossy.ps1 learn -Read -Skill <skill>`) and records surprises with
  `bossy.ps1 learn`.
- **The main session coordinating agents** loads `bossy` and follows its Events table (heartbeat, decisions, `deploy <env>`,
  recovery after a restart, HEAL, LEARN, retro, kit commits).

## CLIs
Check auth before using a CLI (never log in headlessly). Windows: resolve shims (`gws`, `gh`, `npx`, ...) with `shutil.which()`.

| CLI | Purpose | Auth check |
|-----|---------|------------|
| `glab` / `gh` | git host: MRs/PRs, pipelines (kit scripts: `lib.ps1` Invoke-HostVerb, README "Adapters") | `glab auth status` / `gh auth status` |
| tracker | tasks, comments, statuses: only through `skills/crafty/crafty.ps1 tracker` (`tracker.type`: README "Adapters") | `crafty.ps1 tracker view <id>` |

Org specifics (settings, rules, Org router rows, more CLIs) and what does not port to Codex / Antigravity: README "Install".
