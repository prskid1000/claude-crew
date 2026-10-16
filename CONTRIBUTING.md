# Contributing to the kit

The kit is the workspace's `.claude` folder, a git clone of this repo. Change it in a kit worktree while runs execute the live
clone (`dev.ps1 wt new -Repo <kit> -Branch kit/<topic> -Target main -Name kit`), keep it generic and project-agnostic, and run
the checks below before every push. `kittool.py lint` enforces what it can; its codes are in brackets.

## Hard rules
- **At most 50 tracked files** [FILE-CAP]. Counted: every `git ls-files` path except the generated ports (`.codex/`, `.agents/`,
  `GEMINI.md`). Git-ignored local files (`*.local.*`, `swarm.config.json`, `.runtime/`, `.state/`) never count. One script per
  concern area; references and templates fold into the SKILL.md or `dev-kit/templates.md`; tests in `tests/kit-tests.ps1`.
- **Token budgets** [BUDGET] (tokens = UTF-8 bytes / 4): always-loaded (`CLAUDE.md` + `AGENTS.md` + always-on rules) 3500 ·
  SKILL.md 3200 · agent 900 · rule 900 · template / example 2600 · `dev-kit/templates.md` 4000 · README / CONTRIBUTING 7000 · LESSONS.md 30000 (40 lines per
  skill section) · workflow 14000 · .ps1 48000 · .py 44000 · .mjs 8000 · json 3000 · tests 16000 · total 360000. `kittool.py
  lint` prints the top consumers when one is over.
- **Every file reached from the root** [REACH-NONE, REACH-MENTION]: CLAUDE.md -> AGENTS.md (Router) -> skill / workflow / agent
  -> the Files-index row that names the file and the step that reads or runs it. Mentions do not count. Every edge carries its
  reason (the router row, the index step, the hook event, the spawning workflow, the calling verb).
- **Generic and project-agnostic** [ORG-TERM]: no org, product, tenant, host, id, person or local path; no assumed stack,
  migration tool, app trio or database. Org values -> `kit.local.json` keys with today's behaviour as the default; org rules ->
  `rules/*.local.md`; org lessons -> `LESSONS.local.md` (`orch.ps1 learn` routes a line with an `orgTerms` word there itself).

## Shapes
- **Script** [SCRIPT-HEADER]: one entry file per area with verbs; a header block with purpose, usage, verbs, inputs, outputs and
  `Exit codes:` (0 ok · 1 problem found · 2 usage error); shared parameter names `-Env -Run -Task -Repo -Dir -Agent -Mrs -DryRun
  -Json -Quiet`; JSON output for machines; no silent failures (a failed call is UNKNOWN, never a state); idempotent where possible;
  every path through `Get-KitPath` / `kit_path` / `kitPath` / `rp()` [RUNTIME-RAW, RUNTIME-MAP]; network calls bounded (lib.ps1
  sets git timeouts; `Invoke-GitFetch`, memoised host / tracker reads); never opens a file, browser or app on the desktop unless an
  explicit `--open` / `-Open` flag asks [DESKTOP-OPEN] (hooks, lint and generators stay silent; the guard blocks agents' opens too).
  Template: `dev-kit/templates.md` "Script header".
- **Skill** [SKILL-DESC, SKILL-BLOCK, FILES-*]: front matter `description: "Load when: ... Not when: ... -> <sibling>."`; then
  **Load when**, **Not when**, **Hands off to**, **Files** (every file in the folder, plus `<kit>/...` files it binds, each with
  its step), numbered steps, **Rules**, **Learn**. Lessons: the skill's `## <skill>` section of `LESSONS.md` (`learn -Read`).
- **Agent** [AGENT-SPAWN, AGENT-SKILL]: front matter `name`, `description` ("Spawned by ...", "Precondition", "Not for: ..."),
  `tools` only when the agent needs no MCP servers (dev and QA agents keep all tools: the local env's DB tool is an MCP server),
  `model`; body: **Load first** `<kit>/skills/<skill>/SKILL.md`, non-negotiables, the report shape, self-improvement.
- **Workflow** [WF-WHEN, WF-CLOCK, WF-CRLF]: `meta.whenToUse` = its router row's conditions word for word; every arg in the
  header comment with its default; no `Date.now()` / `new Date()`; LF only; ends with a Learn step and cleanup. Both flows return
  the same report shape (`agents|results`, `deployBatch`, `decisions`, `retroDue`). Check: wrap and `node --check`, `kittool.py cost --steps`.
- **Rule**: always-loaded only for short hard rules every session needs; path-scoped (`paths:` front matter) for one kind of file
  (examples: `examples/rules.md`).
- **Text** [PROSE]: every artefact type has a row in `dev-kit/templates.md` "Writing standards" (purpose, sections, limits,
  required facts); a new artefact type adds a row; generators call `kittool.py prose` and print findings, never truncate.
- **Config key**: optional, today's behaviour as the default, a row in README "Configuration", a sample in `kit.example.json` [CONFIG-UNDOC].
- **Hook**: `pwsh` exec form with `${CLAUDE_PROJECT_DIR}/.claude/...`; SessionStart work < 2 s, slow work `"async": true`.

## Before every push
```powershell
python -X utf8 skills/orchestrate/kittool.py lint                 # 0 problems (strict); also regenerates the flow page
python -X utf8 skills/orchestrate/kittool.py port; python -X utf8 skills/orchestrate/kittool.py port --check
pwsh -NoProfile -File tests/kit-tests.ps1                         # all areas (or -Area dev|qa|orch|local)
python -X utf8 skills/orchestrate/kittool.py lint --org-terms skills/dev-kit/kit.local.json
python -X utf8 skills/orchestrate/kittool.py cost --steps         # after a workflow change
```
The pre-commit hook regenerates the README graph sections and the ports (`kittool.py port`: `.codex/`, `.agents/`, `GEMINI.md`,
plus the workspace copies when the kit is an installed `<workspace>/.claude`), stages them, and blocks while `port --check`
still differs or lint finds problems; the pre-push hook re-runs `port --check` and blocks stale ports, org terms and ignored /
local files. SessionStart (`kit.ps1 health`) only reports. Generated ports never count toward the file cap. Commit with `dev.ps1 wt commit` (Conventional Commits).
