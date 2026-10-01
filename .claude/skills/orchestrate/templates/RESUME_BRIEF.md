# Resume brief: you're continuing a stopped agent's work

A previous agent on this work was stopped (memory, a usage limit, or the user). Its work is in the worktrees named
`<Root>\<prefix>-*` (default root: `<repo's parent>-wt`, or `$env:CLAUDE_WT_ROOT`). It may be uncommitted,
committed only locally, or partly merged.

1. **Rules.** Read `<workspace>\.claude\skills\dev-kit\SKILL.md` and the original brief: <path>.
2. **Work out what's done before you edit anything.**
   - Each worktree: `& <workspace>\.claude\skills\dev-kit\scripts\wt.ps1 status -Dir <wt>` (branch, target, ahead/behind, dirty files).
   - The tracker task description and comments.
   - Open/merged MRs on the branch: `glab mr list --source-branch <b>` / `gh pr list --head <b>`.
   - Continue where it stopped; don't redo finished work.
3. **Another agent may still be in the same worktree.** If files keep changing between two `git status` runs, stop and
   report it (the stopped agent may have children still running).
4. **Then ship** as in the dev-kit SKILL.md §8–§9.
