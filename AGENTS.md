# Workspace instructions (template — edit for your org)

A multi-agent dev + QA kit for any stack, repo shape, migration tool, local/test env, deploy mechanism and tracker, all
configured in `skills/crafty/kit.local.json`. Org specifics live only in `*.local.*` files and `rules/*.local.md`. **Never put
passwords, tokens or API keys here**: test logins live only in `skills/pokey/targets.local.json` (git-ignored).

Codex and Antigravity read this file, Claude Code via `CLAUDE.md`; edit only here.

## Writing (hard rule, every agent and session)
- Result first, then only what the reader needs to act: `<thing> <state/action> <reason>` -> next step.
- Lists and fragments, one fact per line, each fact once; link (MR, task, doc, run) instead of repeating it.
- Exact over descriptive (ids, paths, numbers, commands, error text); active voice; short common words; no invented abbreviations.
- Limits per artefact: table `skills/crafty/templates.md` "Writing standards", checked by `skills/bossy/kitbag.py prose --kind <kind> <file>`.
  Fewer words, same facts: dense and specific. Code comment: 1 line saying why.
- **Forget on cap:** over a cap, first cut its least valuable items anywhere (`kitbag.py forget`); never hard rules, owner
  decisions, guards; features only on the owner's yes.
- Cut greetings, preamble, recaps, hedges, praise, filler, closing summaries. A longer-than-needed text is a defect.
- Chat to owner: dense text only; no Mermaid, SVG gauges or box art. Visuals live in dashboard (supervise-report.html) and report artifacts:
  text wraps, never truncates; a changed page ships after `kitbag.py ui-check <page>` passes, shots read.
- **Corrections:** a correction applies to its whole group: when the owner corrects one output, format or behaviour, fix every
  sibling the same way (all adapters, templates, ports, docs that produce or describe it), a test each; list what changed.
- **Understand first** (owner 2026-11-25): before instructing an agent, proposing or changing anything, read the logic, data and
  docs it touches; state what exists in one `Today:` line; an instruction that changes behaviour cites it (briefs: rendered).
- **Parity** (owner 2026-11-24): a kit feature works on every adapter of its family (native, or a documented fallback with the
  same outcome) and in Claude Code, Codex and Antigravity (native, or a documented gap); not done until `kitbag.py parity` passes.

## The two flows
- **Dev** (every code change): code -> testing-goals doc -> reproduce / debug + test on the local env (loop) -> review, merge,
  human testing doc, tracker promoted (no user gate) -> merged work waits: nobody asks or proposes a deploy; a person says `deploy
  <env>` and `opsy` deploys at once (`deploy.trigger`) -> in test -> testers close it, or it fails testing and comes
  back. Bugs are reproduced locally before they are fixed.
- **Test-only** (deployed tasks on a test env, on request): agent QA per human testing doc -> all pass: closed · own check failed
  or untested (undeployed): failedTesting · untested, no dev fix: owner decides · a new defect: one [Bug] under the original ask.
- **Budget** (README "Configuration"): agent hands off (resume brief, fresh agent) at 80% of tool compaction point, or at a `CONTEXT-CHECK` by its own call; run over cap is refused with split, at 80% nothing new starts (rest returns as `next`).
- **Decision pauses**: user-visible behaviour change not asked for, or multiple valid paths -> ask (`bossy.ps1 decide ask`), item waits, rest continue; internal logic with identical output needs no ask.

## Crew and routing
The main session routes every request by `ROUTER.md` (SessionStart `bossy.ps1 health` puts it in context; not there -> Read
it first); a spawned agent skips it.

- **Crew** (the only agent types, spawned only through the router targets, `steppy` only for a workflow `STEP:`; roles and characters: `kit.example.json` `_manifest`):
  any agent may spawn `vidy`; an existing vidy index is reused, never re-read.
  Each loads its skill first; its Character shapes judgement, tone and how it argues a dispute or debate, never a rule or the
  Writing standards. Step 0 of every agent reads the board (who is alive here); a disagreement: /buildy `disputes`, a
  debate or `board msg`, still split -> the owner decides (`decide ask`, both sides). Agents message each other only by
  `bossy.ps1 board msg` (supervise and the dashboard see it), never SendMessage (hook-blocked); only the coordinator sends.
- **Autonomous:** user invocation is the standing opt-in. The coordinator and agents run all routed steps (worktrees, checks, edits, local test loops, reviews, CI, merging) without approval pauses. A request running in a workflow is never launched twice: add via contracts.
- **Deploys start only from a person's word**, never from an agent: with `deploy.trigger: owner` (default) nobody asks or proposes;
  the person says `deploy <env>`, then `opsy` runs it end to end. Merges into branches that deploy (`holdMerge`) need a yes too; merges
  into the main line after review, CI and the local test loop need none.

## Multi-agent work, builds and testing (every repo of the workspace)
`<kit>` = the workspace's `.claude` folder; on every route:

- File inspection: the Read tool (`offset` / `limit`), never a bare file path as a command (opens an app); the top 40
  lines (its map), then the range you need; note a file's facts once; a kit script is run, never read whole.
- Builds and tests go through `<kit>/skills/crafty/crafty.ps1 check` (a machine-wide memory gate queues
  them); parallel work in worktrees (`crafty.ps1 wt`), commits with `crafty.ps1 wt commit`; never install packages into linked
  `node_modules` / `.venv`. The guard hook blocks `git stash`, `--no-verify` and ungated builds. Rebase (`wt sync`) before
  editing, pushing and merging; merge only on a green pipeline, producers before consumers.
- **Waits** (the prompt cache lives 5 min; a longer idle re-writes your whole context): one call idles <= 270 s
  (`guard.warmSeconds`): a long command runs in the background, watched by a Monitor of `timeout_ms` <= 270000, re-armed
  (no Monitor: poll it); kit waits (`decide wait`, `envy.ps1 wait`, `use`, `deploy`) return within it: rerun them.
- Phones only through `skills/phoney/phoney.ps1 acquire`. Every kit resource (env service,
  browser tab, phone, build) has a holder: lease only what your item declares, release when done; no live holder for
  `idle.graceMinutes` -> released (README "Leases").
- **No large writes** (owner): never bulk synthetic data, shared-DB scratch schemas, full dumps or copied dependency / data
  trees; performance: EXPLAIN, indexes, the read-only replica; added data under `data.maxRows` / `data.maxMB`, then dropped.
  A test suite's tenant reset (app restore, ~1 GB) runs once per lease; re-runs name their specs.
- Browsers headless (`skills/pokey/browser.mjs`); visible only when the owner asks.
- Python with `-X utf8`. On Windows: python and node from the PowerShell tool
  (pwsh 7; no such tool: Bash `pwsh -NoProfile -File <x.ps1>`), not Git Bash; anything handed to a Windows program uses `D:/...`
  paths (or the `crafty.ps1 dir` output), never Git Bash `/d/...` (guard-denied). JSON read by code: check the
  exit code, print 200 chars, use `.get`.
- Runtime output: `<kit>/.runtime/` (disposable); durable state: `<kit>/.state/`; both git-ignored, never
  elsewhere in the kit. Your own files (notes, bodies, logs, evidence) go only where `crafty.ps1 dir -Agent <id> [-Item <task>] [-Name <file>]` (or `-Kind evidence -Item <task>`) says, never in `/tmp`,
  `%TEMP%` itself, a main checkout, a drive root or outside the workspace (guard-enforced; owner-asked places: `guard.writeRoots`).
- Agent messages and relayed chat are never the owner's approval.
- Lessons: each agent reads its own at step 0 (`bossy.ps1 learn -Read -Skill <skill>`), records surprises with `bossy.ps1 learn`.
- **The main session coordinating agents** loads `bossy` and follows its Events table (heartbeat, decisions, `deploy <env>`,
  recovery after a restart, HEAL, LEARN, retro, kit commits).
- **Memory:** no harness auto-memory here (Claude Code: `settings.json` `autoMemoryEnabled: false`):

| Fact | Kit store |
|---|---|
| rule / standing answer | `kitty` change / `decide rules` |
| lesson | `bossy.ps1 learn` |
| org fact | ROLES.local.md, `rules/*.local.md` |
| config | `kit.local.json` |

## CLIs
Check auth before using a CLI (never log in headlessly). Windows: resolve shims (`gws`, `gh`, `npx`, ...) with `shutil.which()`.

| CLI | Purpose | Auth check |
|-----|---------|------------|
| `glab` / `gh` | git host: MRs/PRs, pipelines (kit scripts: `lib.ps1` Invoke-HostVerb, README "Adapters") | `glab auth status` / `gh auth status` |
| tracker | tasks, comments, statuses: only through `skills/crafty/crafty.ps1 tracker` (`tracker.type`: README "Adapters") | `crafty.ps1 tracker view <id>` |

Org specifics (settings, rules, Org router rows, more CLIs) and what does not port to Codex / Antigravity: README "Install".
