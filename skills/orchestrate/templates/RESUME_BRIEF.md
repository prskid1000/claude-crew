# Resume brief: you're continuing a stopped agent's work

A previous agent on this work was stopped (memory, a usage limit, or the user). Its work is in the worktrees named
`<Root>/<prefix>-*` (default root: `<repo's parent>-wt`, or `$env:CLAUDE_WT_ROOT`). It may be uncommitted,
committed only locally, or partly merged.

1. **Rules.** Read `<workspace>/.claude/skills/dev-kit/SKILL.md` and the original brief: <path>.
   **Board:** join with the stopped agent's id and run, its worktrees as claims, and `-Resume`:
   `& <workspace>/.claude/skills/orchestrate/scripts/board.ps1 join -Agent <id> -Run <wave> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md -Resume`.
   It takes over the stopped agent's board entry (TAKEOVER) instead of reporting DUPLICATE; keep the SESSION token on its last line.
   DUPLICATE or CLAIM even with `-Resume` = another live writer: stop and report it.
2. **Work out what's done before you edit anything.**
   - Each worktree: `& <workspace>/.claude/skills/dev-kit/scripts/wt.ps1 status -Dir <wt>` (branch, target, ahead/behind, dirty files).
   - The tracker task description and comments.
   - Open/merged MRs on the branch: `glab mr list --source-branch <b>` / `gh pr list --head <b>`.
   - Continue where it stopped; don't redo finished work.
3. **Another agent may still be in the same worktree.** If files keep changing between two `git status` runs, stop and
   report it (the stopped agent may have children still running).
4. **Then ship** as in the dev-kit SKILL.md steps 6-9 (details in `dev-kit/reference/shipping.md` and `tracker.md`).
5. **Testing instructions (mandatory):** if the stopped agent did not post them, do it (dev-kit step 7b) before the task moves to `review`.

**Rule changes mid-wave** are appended at the bottom of the original brief and of this one (and in `<brief>.contracts.md`):
re-read them before every push.

## Rule changes during the wave (appended by the coordinator; newest last)

