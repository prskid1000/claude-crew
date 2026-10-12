# Install, update, contribute

The repo root **is** a workspace's `.claude` folder. There is one copy of the kit per workspace, a git clone, edited in place:
no second source of truth and nothing to sync.

## Install

```powershell
git clone https://github.com/prskid1000/claude-crew <workspace>/.claude
pwsh -File <workspace>/.claude/skills/orchestrate/scripts/kit-setup.ps1
```

`kit-setup.ps1` (idempotent; run it again any time):
- turns on the versioned pre-push gate: `git config core.hooksPath .githooks`;
- writes the `localOnly` paths of `skills/dev-kit/kit.local.json` into `.git/info/exclude` (kit-health refreshes this at every
  session start);
- creates the runtime (`.claude-runtime/work`, `cache`, `logs`) and lists the local config files still to copy:
  `skills/dev-kit/kit.local.json`, `skills/qa-kit/targets.local.json`, `skills/android-swarm/swarm.config.json` (from their
  `*.example.json`).

Then follow the README "Setup" steps (CLAUDE.md, tracker, web QA helper, Android swarm). Start Claude Code in `<workspace>`.

## Update

```powershell
git -C <workspace>/.claude pull --rebase
```

Do it when no agents run (running agents keep the files they already read). The SessionStart kit line says when the clone is
behind or ahead of its upstream; an async SessionStart hook runs `git fetch`, so the count is current at the next start.

## Contribute (change the kit)

Edit the files in `<workspace>/.claude` directly, then:

```powershell
python <workspace>/.claude/skills/orchestrate/scripts/kit-lint.py          # 0 problems (CONTRIBUTING.md has the other checks)
git -C <workspace>/.claude add -A; git -C <workspace>/.claude commit -m "fix(dev-kit): ..."
git -C <workspace>/.claude pull --rebase; git -C <workspace>/.claude push
```

The pre-push hook blocks the push when a pushed commit carries a git-ignored or local-only file, or when an org term from
`kit.local.json` `orgTerms` appears in a published file or an added line. A fork works the same way: clone your fork, add this
repo as `upstream`, and `git pull upstream main` to take updates.

## What stays local

| What | How it stays out of git |
|---|---|
| `*.local.*`: `kit.local.json`, `targets.local.json`, `settings.local.json`, `rules/*.local.md`, `tracking.local.json`, `learning.local.*`, `tracker-none.local/` | `.gitignore` |
| `skills/android-swarm/swarm.config.json`, `swarm.json`, `apk/`, `*.apk`, `*.log`, `node_modules/`, `__pycache__/` | `.gitignore` |
| `.claude-runtime/` (disposable runtime) and the harness's `worktrees/`, `agent-memory-local/`, `scheduled_tasks.lock` | `.gitignore` |
| org-only skills, project profiles, extra rules (e.g. `skills/<org-skill>`, `rules/<stack>.md`) | list them in `kit.local.json` `localOnly`: `.git/info/exclude` |

Runtime layout and what is regenerable: [runtime.md](runtime.md).

## Migrate a workspace that has a synced copy

Older installs copied the kit into `<workspace>/.claude` and kept the runtime next to it. With no agents running:

1. Move the old folder aside (never delete it before the end): `Rename-Item <workspace>/.claude .claude.old` and stop any
   `/loop` heartbeat.
2. `git clone https://github.com/prskid1000/claude-crew <workspace>/.claude`
3. Copy the local files back from `.claude.old`, keeping their paths: every `*.local.*` file, `settings.local.json`,
   `skills/android-swarm/swarm.config.json` (and `swarm.json`), every `localOnly` path, plus any other file you added
   (compare: `git -C <workspace>/.claude status --ignored` after copying).
4. Add every org-only path that is not `*.local.*` to `kit.local.json` `localOnly`, then run
   `pwsh -File <workspace>/.claude/skills/orchestrate/scripts/kit-setup.ps1`. `git -C <workspace>/.claude status` must be clean.
5. Carry the durable state over: `pwsh -File <workspace>/.claude/skills/orchestrate/scripts/kit-setup.ps1 -Migrate <workspace>/.claude-runtime [-Work] [-Apk]`.
6. Start a session: the kit line should only mention the old runtime; delete `<workspace>/.claude-runtime` and `.claude.old` once
   you have checked the result.
