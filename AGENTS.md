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
| R2 | Kit friction or a kit change: a kit script, hook, rule or workflow failed, blocked wrongly or needed a workaround, or a kit part or config key is added or changed | `orchestrate` → "Change the kit" | — |
| R3 | The owner asks to audit, review, recover or repair the whole kit, or to set it up or fix missing config | `kit-auditor` agent (one at a time) | — (the agent loads `kit-audit`) |
| R4 | A /dev-wave or /test-and-close finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective | `/kit-retro` | `orchestrate` |
| R5 | Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens) | `/dev-wave` | `orchestrate` |
| R6 | Coding: one small change in one repo (one screen, file or endpoint, a quick fix, a config edit) | direct, dev-kit steps | `dev-kit` |
| R7 | A person says `deploy <env>` (or approves an ask under `deploy.trigger: ask`), or deployed tasks are to move to in test | direct: orchestrate E5 (`orch.ps1 deploy`) | `orchestrate` |
| R8 | Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents | `/test-and-close` | `orchestrate` |
| R9 | A person tests by hand, or you check one deployed change yourself (one screen or endpoint) | `qa-kit` → H steps / tester steps | — |
| R10 | The local env outside a running flow: start, stop, refresh, inspect, reproduce or debug on it | `local-env` | — |
| R11 | Phones or APKs outside a running flow: build the lane or local-env APK, create or reset lanes, a manual lease | `android-swarm` | — |
| R12 | Review merge/pull requests that are already open (not the review inside a running /dev-wave) | `mr-reviewer` agent | — |
| R13 | Static audit of one module's code for bugs, performance or tech debt, without changing code | `tech-audit` | — |
| R14 | A question, an explanation, an analysis, a plan, or how the kit fits together (README graph sections); no code change | direct | — |

- **Agent types** (spawned only through these targets): `dev-agent` by /dev-wave (one per brief area; owns code, testing goals,
  the local test loop and its MRs), `mr-reviewer` by /dev-wave (one per build agent) and R12, `qa-tester` and `qa-verifier` by
  /test-and-close, `kit-auditor` by the coordinator (R3, or weekly). Each loads its skill first. Codex / Antigravity: the same
  agents are ported to `.codex/agents/*.toml` / `.agents/agents/*.md`; no workflow engine there: follow `.codex/workflows/*.md`
  / `.agents/workflows/*.md` by hand.
- **Autonomous:** installing this kit is the standing opt-in for its workflows: launch the routed workflow yourself, then say in
  one line what started and why. An org that wants to be asked first says so in its org rules. A request already running in a
  workflow is never launched twice: add to it through the contracts file.
- **Deploys start only from a person's word**, never from an agent: with `deploy.trigger: owner` (default) nobody asks or proposes;
  the person says `deploy <env>`, then it runs end to end. Merges into branches that deploy (`holdMerge`) need a yes too; merges
  into the main line after review, CI and the local test loop need none.

## CLIs
Check auth before using a CLI (never log in headlessly). Windows: resolve shims (`gws`, `gh`, `npx`, ...) with `shutil.which()`.

| CLI | Purpose | Auth check |
|-----|---------|------------|
| `glab` / `gh` | git host: MRs/PRs, pipelines (kit scripts go through `dev-kit/lib.ps1` Invoke-HostApi and `devtools.py`) | `glab auth status` / `gh auth status` |
| tracker | tasks, comments, statuses: only through `skills/dev-kit/dev.ps1 tracker` (`tracker.type`: clickup / github / gitlab / jira / none) | `dev.ps1 tracker view <id>` |
| `gws` (optional) | Google Docs reports and testing docs, only when `reports.type` is `gdocs` | resolve with `shutil.which()` |
| `<your-cli>` | <purpose, e.g. logs / observability> | `<auth check>` |

## Org specifics (fill in)
- Org settings the scripts read: `skills/dev-kit/kit.local.json` (`kit.ps1 setup -WriteLocal` writes it from
  `kit.example.json`; keys: README "Configuration").
- Org rules, house style and **Org router rows** (same columns as the Router): `rules/*.local.md` (git-ignored).
- Products / repos, test environments (names only; URLs and logins in `targets.local.json`), deploy rules, tracker statuses.
- Code and test conventions: path-scoped rules in `rules/` (examples: `examples/rules.md`); org-only skills under `skills/<name>/`
  listed in `kit.local.json` `localOnly`. How to add any part: `CONTRIBUTING.md`.

## Not portable to Codex/Antigravity (stays Claude Code-only)
- The SendMessage guard hook (`kit.ps1 guard-sendmessage`): neither tool has a SendMessage tool to match.
- The agent board, `orch.ps1 learn` signals and decision pauses are not wired into Codex `spawn_agent` / Antigravity
  `invoke_subagent`; the ported procedure docs tell a human coordinator to use them.
- The Skill tool's name-triggered loading and `kittool.py lint`'s router/graph checks run only against this kit's own files.
- Antigravity's `tools:` allow-list stays unset: its tool names do not map 1:1 from Claude's.
