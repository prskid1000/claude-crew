# Extending the kit (orchestrate reference)

Read at orchestrate K1, before adding or changing any kit part. Every part must be reachable on an explicit path:
**CLAUDE.md Router row → skill (its numbered steps) → the Files-index row that binds a reference / template / script to a step →
workflow → agent type.** `kit-lint.py` enforces what it can (codes in brackets); run it until it prints 0 problems (orchestrate K3).
The kit is the workspace's `.claude` folder, a git clone of the kit repo: edit it in place, keep everything generic (org specifics go
in the local overlay, §8), commit and push (orchestrate K3-K4).

## 1. A script, reference doc or template inside a skill
- Put it in the skill folder (`scripts/`, `reference/`, `templates/`), never loose at the kit root.
- Add a row to that skill's **Files** table: the file in backticks and *the step or event row that reads, fills or runs it*
  ("step 4c, before adding a migration"), never "read when you need it" [FILES-UNLISTED, FILES-UNBOUND, SKILL-FUZZY].
- Make the step itself name it, so the agent meets it on its way through the steps.
- A reference doc opens with one line saying which step(s) read it. A library dot-sourced by other scripts is listed as such.
- Scripts: derive paths from their own location (`kitconfig.ps1`). Runtime output and durable local state are named in
  `skills/dev-kit/scripts/kitpaths.json` and resolved only through its helpers: `Get-KitPath <name>` (PowerShell), `kit_path()`
  (Python), `kitPath()` (Node), `rp()` with a `const KP` copy of the names in workflows [RUNTIME-RAW, RUNTIME-MAP, JUNK]. A new
  path is a new name in `kitpaths.json`: `work/` (in-flight runs), `cache/` (rebuilt on demand) or `logs/` under the disposable
  runtime, or `durable` (a git-ignored `*.local.*` file at the kit root) when losing it would lose knowledge or task state;
  then add a row to `docs/runtime.md` and, if it grows, a prune rule to `cleanup.ps1`. Scripts run with pwsh 7 on
  Windows/Linux/macOS, trim quotes from MR refs (`'a!1','b!2'` arrive literally), and are parse-checked.

## 2. A new skill
- `skills/<name>/SKILL.md` with frontmatter `description: "Load when: <concrete conditions>. Not when: <condition> -> <sibling>. ..."`
  (under ~400 chars; conditions an agent can check, not topics) [SKILL-DESC].
- The body opens with four blocks [SKILL-BLOCK]: **Load when** (all must hold) · **Not when** (-> which sibling) · **Hands off to**
  (the workflow, agent or skill that comes next) · **Files** (every file in the folder with its step; `LESSONS.md` at step 0,
  `HISTORY.md` "never read for work").
- Then numbered steps. Add `LESSONS.md` (≤ 40 lines, `learn.ps1` manages it) if agents will learn from it.
- Add a **Router** row in `CLAUDE.md` (or an org router row for a local skill, §8) placed where its conditions are more specific
  than the rows below it [ROUTER-UNROUTED, ROUTER-TARGET].

## 3. An agent type (`agents/<name>.md`)
- `description` (quoted YAML) says: what it does, **"Spawned by** <workflow / coordinator> <when, how many>", its **Precondition**,
  the skill it loads, and **"Not for:** <cases> (-> which other agent or skill)" [AGENT-SPAWN].
- The body's first instruction is **Load first:** `<workspace>/.claude/skills/<skill>/SKILL.md` [AGENT-SKILL], then its task.
- Name it in the Router (the agent-types line or a row) and in the workflow that spawns it.

## 4. A workflow (`workflows/<name>.js`)
- `meta.whenToUse` is word for word the **Conditions** cell of its Router row [WF-WHEN]; the row targets `/<name>`.
- Document every argument in the header comment (type, default, effect), plus the optional ones every workflow takes
  (`kitDir`, `runtimeDir`, `models`). New args default to today's behaviour.
- Never read the clock (`Date.now()` / `new Date()` break resume) [WF-CLOCK]; LF line endings [WF-CRLF]; end with a Learn step and
  `cleanup.ps1`. Check: wrap and `node --check` (CONTRIBUTING), `kit-cost.ps1 -Steps`.

## 5. A rule (`rules/<name>.md`)
- **Always-loaded** (no frontmatter): only short hard rules every session needs, whatever the route (e.g. never production, the
  memory gate). Anything that depends on the task belongs in a skill step instead.
- **Path-scoped** (`paths:` globs in frontmatter): conventions for one kind of file (migrations, a framework's code), loaded when
  such a file is opened. Point to the skill reference that holds the long form.
- Never repeat the Router; point to it.

## 6. A config key
- Optional, with today's behaviour as the default (a missing key changes nothing).
- Document it in `skills/dev-kit/reference/configuration.md` (key, default, used by, meaning) and add it to the right
  `*.example.json` [CONFIG-UNDOC]; read it through `kitconfig.ps1` (`Get-KitSetting 'a.b' <default>`).

## 7. A hook (`settings.json`)
- Use `pwsh` in exec form with `${CLAUDE_PROJECT_DIR}/.claude/...`; synchronous hooks stay well under their timeout (SessionStart
  < 2 s), slow work goes in an `"async": true` entry. List the script in its skill's Files index ("SessionStart hook: ...").

## 8. The local overlay (per workspace, never committed or published)
- `*.local.*`: `kit.local.json` (org settings, `localOnly`, `orgTerms`), `targets.local.json` (the only place for passwords),
  `settings.local.json`, `rules/*.local.md` (org rules); plus `swarm.config.json` and every path in `kit.local.json` `localOnly`
  (`kit-setup.ps1 -Exclude`, run by kit-health at SessionStart, keeps them in `.git/info/exclude`: never in `git status`).
- `rules/org.local.md` (always loaded) holds a `## Org router rows` table with the Router's columns (`# | Conditions | Target |
  Load first`), rows `O1`, `O2`, ... for org-only skills and needs; the Router's R0 sends matching requests there [OVERLAY-ROUTER].
  Keep each row narrow (it is checked before R1).
- A local skill (`skills/<org-skill>/`, listed in `localOnly`) follows §2 exactly and is routed by an org row.
- A project profile for tech-audit (`skills/tech-audit/reference/projects/<project>.md`) is covered by that skill's Files index.
- Path-scoped org rules (`rules/<stack>.md` in `localOnly`) follow §5.
- Before pushing kit changes, scan with the overlay's terms: `kit-lint.py --org-terms <kit>/skills/dev-kit/kit.local.json` [ORG-TERM];
  the pre-push hook (`.githooks/pre-push`, on after `kit-setup.ps1`) runs the same scan and blocks force-added local files.
