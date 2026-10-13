# Configuration overview

| What | Where | Notes |
|---|---|---|
| Org settings (issue tracker + status names, report output, git host, GitLab group, repos root, worktree roots, tracker repos, repo aliases, protected branches, Drive folder, browser-profile cap) | `skills/dev-kit/kit.local.json` | all optional, see `kit.example.json` and [../skills/dev-kit/reference/configuration.md](../skills/dev-kit/reference/configuration.md) |
| Test environments, auth styles, test users | `skills/qa-kit/targets.local.json` | **the only file with passwords** |
| Emulator lanes, app under test | `skills/android-swarm/swarm.config.json` | lane hardware in `avd-template.ini`; APKs and logs in `<runtime>/cache/android-swarm` (`outDir`) |
| Per-repo build commands | `.claude-stack.json` next to a build file | overrides stack detection |
| Runtime folder, worktree root, gate headroom, browser path | env vars `CLAUDE_RUNTIME`, `CLAUDE_WT_ROOT`, `CLAUDE_GATE_KEEP_FREE_GB`, `CHROME_PATH` | |
| Workspace rules | `CLAUDE.md`, `rules/*.md` (org rules: `rules/*.local.md`) | examples of path-scoped rules in `examples/rules/` |
| Org-only skills and files kept out of git | `kit.local.json` `localOnly` | written into `.git/info/exclude` by `kit-setup.ps1` |
| Org terms the pre-push hook blocks | `kit.local.json` `orgTerms` | also `kit-lint.py --org-terms` |

Full reference: [../skills/dev-kit/reference/configuration.md](../skills/dev-kit/reference/configuration.md).
