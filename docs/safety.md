# Safety model

- **Never production.** QA targets are test environments; the rules, agent prompts and evidence standard all say so.
  Testers prefix their data `QA-<CODE>`, restore settings they change, and never touch test logins.
- **Guard hook** (`PreToolUse`): blocks `git stash`, `--no-verify` / hook skipping, force-pushes to shared branches
  (`main`, `master`, `develop`, `release/*` + your `protectedBranches`), and heavy builds that bypass the memory gate.
  Every block is logged.
- **Secrets only in `*.local.json`**, all git-ignored (`.gitignore`); the pre-push hook blocks a force-added local file.
  Evidence files redact `Authorization`, cookies, tokens, keys and passwords. Runtime output (tokens, sessions, evidence)
  lives in the git-ignored `.claude-runtime`.
- **Reviewed merges.** In a reviewed `/dev-wave` agents don't merge their own MRs; merges are scheduled after a clean
  review, only on a green pipeline, producers before consumers. `track.ps1` holds tracker moves while a blocking finding
  is open.
- **Self-cleaning touches only kit-created things** (its own headless browsers, profiles, tokens, temp, merged-and-deleted
  worktrees), and `cleanup.ps1 -DryRun` shows everything first.
