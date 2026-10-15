# Kit audit lessons — active rules (read at step 0; ≤ 40 lines)
Newest first, one line each, `(n×)` = times seen. Fixed/old entries live in `HISTORY.md` (never read it for work).

- Run file edits with absolute paths: `[IO.File]::ReadAllText('skills/x')` resolves against the PROCESS directory (often the live clone), not the pwsh location, so a "worktree" edit lands in the live kit. Check `git -C <live kit> status` after any scripted edit.
- Never edit the live clone (`<workspace>/.claude`): QA runs and agents execute its scripts mid-run. Work in your audit worktree; only `kit-audit.py --fix/--fill` touches the live clone (runtime, git metadata, kit.local.json with a backup).
- Another kit branch may be open (`git -C <kit> worktree list`): diff its changed files before fixing the same file; overlap -> propose, don't fix.
- `kit-audit.py scan` lines are candidates: open the code and prove each one (caller, input, effect) before it becomes a finding.
