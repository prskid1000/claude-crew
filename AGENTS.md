# Workspace instructions (template — edit for your org)

A multi-agent dev + QA kit for ANY project type: any stack (JVM, .NET, Node / web frameworks, Python, Go, Rust, mobile, native,
monorepo or many repos), any migration tool, any local env shape, test env, deploy mechanism and tracker, all through config
(`skills/dev-kit/kit.local.json`). Nothing product-shaped (tenants, a web + API + app trio, a database) is assumed; org
specifics live only in `*.local.*` files and `rules/*.local.md`. **Never put passwords, tokens or API keys here**: test logins
live only in `skills/qa-kit/targets.local.json` (git-ignored).

This file is the single source read by Codex and Antigravity directly and by Claude Code through `CLAUDE.md`'s `@AGENTS.md`
import. Edit only here. Claude Code-only mechanics (hooks, the Workflow and Skill tools) are in `CLAUDE.md` below the import.

## Writing (hard rule, every agent and session)
- Result first, then only what the reader needs to act: `<thing> <state/action> <reason>` -> next step.
- Lists and fragments, one fact per line, each fact once; link (MR, task, doc, run) instead of repeating it.
- Exact over descriptive (ids, paths, numbers, commands, error text); active voice; short common words; no invented abbreviations.
- Format and limits per artefact (briefs, docs, MR, commit, tracker texts, reports, owner messages, kit files): the table
  `skills/dev-kit/templates.md` "Writing standards", read when you write one; `kittool.py prose --kind <kind> <file>` measures
  it. Fewer words, same facts: dense and specific, never vaguer. Code comment: 1 line saying why.
- Cut greetings, preamble, recaps, hedges, praise, filler, closing summaries. A longer-than-needed text is a defect.

## The two flows
- **Dev** (every code change): code -> testing-goals doc -> reproduce / debug + test on the local env (loop) -> review, merge,
  human testing doc, tracker promoted (no user gate) -> merged work waits: nobody asks or proposes a deploy; a person says `deploy
  <env>` and the coordinator deploys at once (`deploy.trigger`) -> in test -> testers close it, or it fails testing and comes
  back. Bugs are reproduced locally before they are fixed.
- **Test-only** (deployed tasks on a test env, on request): agent QA per testing doc -> all pass: closed · own check failed or
  incomplete: failedTesting (back to dev) · a new defect: one [Bug] task under the original ask.
- **Budget** (both flows): an agent's budget = its tool's default compaction point; at 80% it hands off (resume brief, fresh
  agent). A run's cap = its planned agents' budgets: over it at launch = refused with the split; at 80% nothing new starts,
  the rest returns as `next` (README "Configuration" `budget`).
- **Decision pauses**: a change to existing behaviour a user sees (output, screens, data, rules applied) that the task did
  not ask for, or several valid paths -> the agent asks; internal logic changes with the same user-visible behaviour need no
  ask. It asks (`orch.ps1 decide ask`), that item waits for the owner's answer, the rest continue.

## Router
Classify every request before acting: the first row whose conditions all hold wins; load the **Load first** skill, then go to
the **Target**. A mixed request is split and each part routed on its own.

| # | Conditions (all must hold) | Target | Load first |
|---|---|---|---|
| R0 | The request matches a row of "Org router rows" in `rules/*.local.md` (org-only skills and needs) | that org row's target | — |
| R1 | A coordinator event: a workflow notification, a supervise flag, stopped or restarted agents or workflows, a decision request, a person's `deploy <env>` or a finished deploy, QA results (failedTesting or new [Bug] tasks), the owner changing a rule mid-run, a SessionStart kit line | `orchestrate` → its Events table | — |
| R2 | Kit friction or a kit change: a kit script, hook, rule or workflow failed, blocked wrongly or needed a workaround, or a kit part or config key is added or changed | `kitty` agent (kind fix / build / docs) | — (the agent holds its steps) |
| R3 | The owner asks to audit, review, recover or repair the whole kit, set it up or fix missing config, or the local env or the phone lanes need admin (start, stop, refresh, wiring, baseline data, snapshots, create or reset lanes) or an ENV-FIX | `kitty` agent (one at a time; kind audit / recover / setup / env) | — (the agent holds its steps) |
| R4 | A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective | `/tidy` | `orchestrate` |
| R5 | Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens) | `/buildy` | `orchestrate` |
| R6 | Coding: one small change in one repo (one screen, file or endpoint, a quick fix, a config edit) | direct, dev-kit steps | `dev-kit` |
| R7 | A person says `deploy <env>` (or approves an ask under `deploy.trigger: ask`), or deployed tasks are to move to in test | direct: orchestrate E5 (`orch.ps1 deploy`) | `orchestrate` |
| R8 | Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents | `/testy` | `orchestrate` |
| R9 | A person tests by hand from a human testing doc | `qa-kit` → H steps | — |
| R10 | Test, check or verify one thing outside a running workflow: a deployed change, one screen or endpoint, a smoke after a deploy, a regression sweep, a user-report reproduction, a data or migration check, perf on the local env, an "is X live / true?" claim | `checky` agent (role test; kind task / smoke / regression / repro / data / perf / claim) | — (the agent loads `qa-kit`) |
| R11 | The local env outside a running flow: inspect, reproduce or debug on it | `local-env` | — |
| R12 | Phones or APKs outside a running flow: build the lane or local-env APK, a manual lease | `android-swarm` | — |
| R13 | Review something already written, outside a running workflow: open merge/pull requests, a kit commit, a brief, a testing or QA doc, a plan, a config, tracker texts | `revy` agent (kind mr / kit / doc / qa / plan / config) | — (the agent loads `dev-kit` Rules) |
| R14 | Static audit of one module's code for bugs, performance or tech debt, without changing code | `revy` agent (kind module) | — |
| R15 | A question, an explanation, an analysis, a plan, or how the kit fits together (README graph sections); no code change | direct | — |

- **Crew** (the only agent types, spawned only through these targets; names, roles and characters: `kit.example.json`
  `_manifest`): `devy` builds (by /buildy, one per brief area, two in a duel), `revy` reviews (by /buildy, R13, R14),
  `checky` tests (by /testy as lead / test / verify, R10), `kitty` keeps the kit and the machine (R2, R3, /tidy).
  Each loads its skill first; its Character shapes judgement and tone, never a rule or the Writing standards. Step 0 of every
  agent reads the board (who is alive on this machine); a disagreement goes to `orch.ps1 board dispute` (two rounds, then the
  owner judges through `decide ask`). Codex / Antigravity: the same agents are ported to `.codex/agents/*.toml` /
  `.agents/agents/*.md`; no workflow engine there: follow `.codex/workflows/*.md` / `.agents/workflows/*.md` by hand.
- **Autonomous:** installing this kit is the standing opt-in for its workflows: launch the routed workflow yourself, then say in
  one line what started and why. An org that wants to be asked first says so in its org rules. A request already running in a
  workflow is never launched twice: add to it through the contracts file.
- **Deploys start only from a person's word**, never from an agent: with `deploy.trigger: owner` (default) nobody asks or proposes;
  the person says `deploy <env>`, then it runs end to end. Merges into branches that deploy (`holdMerge`) need a yes too; merges
  into the main line after review, CI and the local test loop need none.

## Multi-agent work, builds and testing (every repo of the workspace)
`<kit>` = the `.claude` folder of the workspace (the directory Claude Code was started in); kit scripts find it themselves.
**What to load or launch:** the Router above (first matching row wins; workflows launch autonomously; a deploy
starts only when a person says `deploy <env>`: nobody asks or proposes one). These rules hold whatever the route:

- Builds and tests go through `<kit>/skills/dev-kit/dev.ps1 check` (stack auto-detected; the machine-wide memory gate queues
  them; the guard hook blocks ungated builds). Targeted tests plus the tests of touched files (`-Touched`).
- Parallel work happens in worktrees (`dev.ps1 wt`); commit with `dev.ps1 wt commit` (hooks run). Never `git stash`, never
  `--no-verify`, never install packages into linked `node_modules` / `.venv`.
- Rebase onto the latest target before editing, before pushing and before merging; merge only on a green pipeline, producers
  (DB / API / library) before consumers (web / app / clients).
- Commit WIP on your branch after each dev-flow step (`dev.ps1 wt commit -Message "chore(wip): <step>"`): a crash or restart
  loses no edits.
- Every change is tested on the LOCAL env before merge (reproduce bugs there first); deployed changes are tested on test
  environments only (logins in `skills/qa-kit/targets.local.json`), never production. Defects are FAIL, never notes.
- Phones only through `android-swarm/swarm.ps1 acquire` (never boot or kill emulators by hand, never `adb kill-server`).
- Browsers are headless by default (`qa-kit/browser.mjs`); a visible browser only when the owner asks to watch.
- Run python and node from the PowerShell tool (pwsh 7), not Git Bash; Python with `-X utf8`.
- Runtime output goes to `<kit>/.runtime/` (disposable) and durable state to `<kit>/.state/`, both git-ignored and resolved by
  name (`Get-KitPath`); never elsewhere in the kit.
- The kit learns: every agent reads its lessons at step 0 (`orch.ps1 learn -Read -Skill <skill>`) and records surprises with
  `orch.ps1 learn`. A user-visible behaviour change the task did not ask for, or several valid paths -> `orch.ps1 decide
  ask` ("Decision pauses").
- **The main session coordinating agents** loads `orchestrate` and follows its Events table (heartbeat, decisions, `deploy <env>`,
  recovery after a restart, HEAL, LEARN, retro, kit commits).

## CLIs
Check auth before using a CLI (never log in headlessly). Windows: resolve shims (`gws`, `gh`, `npx`, ...) with `shutil.which()`.

| CLI | Purpose | Auth check |
|-----|---------|------------|
| `glab` / `gh` | git host: MRs/PRs, pipelines (kit scripts go through `dev-kit/lib.ps1` Invoke-HostApi and `devtools.py`) | `glab auth status` / `gh auth status` |
| tracker | tasks, comments, statuses: only through `skills/dev-kit/dev.ps1 tracker` (`tracker.type`: clickup / github / gitlab / jira / none) | `dev.ps1 tracker view <id>` |
| `gws` (optional) | Google Docs reports and testing docs, only when `reports.type` is `gdocs` | resolve with `shutil.which()` |
| `<your-cli>` | <purpose, e.g. logs / observability> | `<auth check>` |

## Org specifics (fill in)
- Org settings the scripts read: `skills/dev-kit/kit.local.json` (`orch.ps1 setup -WriteLocal` writes it from
  `kit.example.json`; keys: README "Configuration").
- Org rules, house style and **Org router rows** (same columns as the Router): `rules/*.local.md` (git-ignored).
- Products / repos, test environments (names only; URLs and logins in `targets.local.json`), deploy rules, tracker statuses.
- Code and test conventions: path-scoped rules in `rules/` (examples: README "Rule examples"); org-only skills under
  `skills/<name>/` listed in `kit.local.json` `localOnly`. How to add any part: README "Extending".

## Not portable to Codex/Antigravity (stays Claude Code-only)
- The SendMessage guard hook (`orch.ps1 guard-sendmessage`): neither tool has a SendMessage tool to match.
- The agent board, `orch.ps1 learn` signals and decision pauses are not wired into Codex `spawn_agent` / Antigravity
  `invoke_subagent`; the ported procedure docs tell a human coordinator to use them.
- The Skill tool's name-triggered loading and `kittool.py lint`'s router/graph checks run only against this kit's own files.
- Antigravity's `tools:` allow-list stays unset: its tool names do not map 1:1 from Claude's.
