# Kit extras

Optional kit parts kept off `main` so the core stays small. They install at runtime, when a config or a task needs them.

- Layout: `extras/<name>/EXTRA.md` (3-6 lines: what it is, `Needed when:`, how it is wired) and `extras/<name>/files/<kit path>`
  (the files, at the path they install to). The extra's own tests live in its folder (`extras/<name>/tests.ps1`).
- `Needed when:` with a config condition, e.g. ``Needed when: `tracker.type` = `jira` ``: `kittool.py extra check` (run by
  `orch.ps1 health` / `setup`) prints the missing-extra line when kit.local.json asks for it; `*` walks every key or list
  item (`repos.*.migrations.tool`); `a` | `b` = either value, `~` = contains, `,` = any of the conditions; `Needed when (<file>.json, ...):`
  reads that file instead of kit.local.json; `<path>` exists = that kit path is there; `<glob>` in a repo = a
  kit.local.json `repos[].checkout` tracks such a file (`tsconfig.json` in a repo); `<os>` OS = this machine's OS (`windows`,
  `linux`, `macos`). `extra sync` installs every match and updates installed extras the branch changed (only while the kit is not behind origin/main); `extra test` runs installed extras' tests.
- `python -X utf8 skills/orchestrate/kittool.py extra list`: the extras on `origin/extras`, `*` = installed.
- `extra add <name>`: writes its files into the kit and lists them in `.git/info/exclude` (local-only: never pushed, not in
  the budget). `extra remove <name>` deletes them.
- A script that needs a missing extra stops with one line: `<feature> is an extra: run kittool.py extra add <name>`.
- Add or change an extra: `git worktree add <dir> origin/extras`, commit `extras/<name>/`, `git push origin HEAD:extras`
  (fetch + rebase on conflict, never force).
