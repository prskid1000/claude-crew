# Kit extras

Optional kit parts kept off `main` so the core stays small. They install at runtime, when a config or a task needs them.

- Layout: `extras/<name>/EXTRA.md` (3-6 lines: what it is, the config key that needs it, how it is wired) and
  `extras/<name>/files/<kit path>` (the files, at the path they install to). The extra's own tests live in its folder.
- `python -X utf8 skills/orchestrate/kittool.py extra list`: the extras on `origin/extras`, `*` = installed.
- `extra add <name>`: writes its files into the kit and lists them in `.git/info/exclude` (local-only: never pushed, not in
  the budget). `extra remove <name>` deletes them.
- A script that needs a missing extra stops with one line: `<feature> is an extra: run kittool.py extra add <name>`.
- Add or change an extra: `git worktree add <dir> extras`, commit `extras/<name>/`, `git push origin HEAD:extras` (rebase on
  conflict, never force).