# Cross-CLI support (Codex, Antigravity)

The *instructions* (Router, CLIs, org specifics) and the five agent roles are also usable from **OpenAI's Codex CLI** and
**Google's Antigravity/`agy` CLI**, generated from the same Claude Code source by one script, so there is one place to edit:

```powershell
python <workspace>/.claude/skills/orchestrate/scripts/port-kit.py   # after editing agents/*.md, settings.json hooks or workflows/*.js
```

| What | Claude Code source | Codex | Antigravity |
|---|---|---|---|
| Instructions | `CLAUDE.md` (`@AGENTS.md` import) | `AGENTS.md` (native) | `GEMINI.md` (`@AGENTS.md` import) |
| Agents | `agents/*.md` | `.codex/agents/*.toml` | `.agents/agents/*.md` |
| Guard + SessionStart hooks | `settings.json` | `.codex/config.toml` | `.agents/hooks.json` |
| Workflows (`/dev-wave`, ...) | `workflows/*.js` (runs) | `.codex/workflows/*.md` (manual procedure doc) | `.agents/workflows/*.md` (manual procedure doc) |

`port-kit.py` writes the canonical copy into this repo (tracked, pushed) and deploys a mirror to the workspace root, since
Codex and Antigravity resolve `AGENTS.md`/`GEMINI.md`/`.codex`/`.agents` from the session's working directory upward, not
from inside `.claude`. `kit-health.ps1` runs `port-kit.py --check` on every SessionStart and nudges if the ports drift from
source.

**Not portable, and not simulated:** the Workflow tool's pipeline/phase engine (Codex/Antigravity get a run procedure, not an
automated script), the agent board's duplicate-session detection, the `SendMessage` guard hook (neither CLI has a tool by
that name), the `Skill` tool's name-triggered invocation, and `kit-lint.py`'s own graph validation. These stay Claude
Code-only; `AGENTS.md`'s own final section documents each one and why.

## Rules and hooks

- `rules/multi-agent.md` (always loaded) and `rules/db-migrations.md` (loads when a migration file is opened).
- `settings.json`: PreToolUse guard, SessionStart kit health (git state + kit-lint), retro nudge, daily cleanup, the kit-flow
  page and an async `git fetch`, a conservative permission allowlist, `git stash` denied.
- `.githooks/pre-push` (on after `kit-setup.ps1`): blocks a push that carries an org term or a git-ignored / local-only file.
