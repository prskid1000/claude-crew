# Scope, evidence and shipping (dev-kit reference)

Read when you open MRs, write the tester guide or hit a merge conflict.

## 5. Scope
- Fix only what your items ask; no sweeps of similar code. Don't remove existing features or inputs.
- Stay in your area. If you must touch someone else's file, keep it to a one-line hook and list it in your final reply.
- Changes are **additive**: optional fields, new endpoints/params, feature flags. Don't change behaviour other
  products/tenants rely on. Don't expose persistence entities in APIs (use DTOs).
- Product decisions in the brief or in memory are final; don't re-ask. If an item needs a new decision, defer it with a reason.
- Follow the repo's own conventions (its `CLAUDE.md`, base classes, lint rules, naming).

## 7. Evidence and environments
- UI change → screenshots. Backend change → request/response JSON (`<workspace>/.claude/skills/qa-kit/scripts/api.ps1 -Save`).
- Test against the environment named in the brief. **Never touch production.**
- **Stale deploy**: if a check fails only because the environment runs an older build (404 / 405 / "No static resource" on
  an endpoint that exists on the target branch), call it a stale deploy and don't change code.
- Tester guide: fill `<workspace>/.claude/skills/qa-kit/templates/tester-guide.html` (check ids T/L/R, concrete Expected) and publish it
  with `devtools.py doc` (anyone with the link can view). Say what still needs a live check.
- Evidence names and formats: `qa-kit/reference/evidence-standard.md`.

## 8. Ship it yourself
1. Re-read `<brief>.contracts.md` next to your brief (if it exists): the coordinator appends cross-agent contracts there during
   the wave — field names, ownership, merge order. Follow them. Then `wt.ps1 sync`, then re-run `check.ps1` (and `-Step migrations`).
   If another writer appears in your worktree (changes you didn't make), stop writing and tell the coordinator.
   Writing to the contracts file yourself (shapes for a sibling agent): **append only** (Edit at the end, or `Add-Content`), never
   Write/overwrite the whole file: the coordinator and other agents keep notes there and an overwrite silently deletes them.
2. Push and open one MR/PR per repo: `devtools.py mr`. Title `feat: <summary> - <CODE> (<tag><task>) (<Repo>)` (`<tag>` = kit.local.json
   `tracker.branchTag`, e.g. `CU-`; the coordinator's track.ps1 finds your MRs by it).
   Body: fill `<workspace>/.claude/skills/orchestrate/templates/MR_BODY.md` (devtools warns on missing sections and adds the footer).
   Tracker solution comment: `templates/TASK_SOLUTION.md`.
3. **In a reviewed `/dev-wave`, don't schedule merges yourself**: open the MRs and stop; the workflow schedules them after a clean review
   (or you do it at the end of your fix round). Merging before review shipped a double-billing bug once.
   **Merge producers before consumers**: DB/API/library first, then web/app/clients. `devtools.py merge <wt> <iid>` asks GitLab/GitHub
   to squash-merge as soon as the pipeline is green and returns at once (no waiting; `merge-wait` is the old blocking mode). Post your
   tracker comment right after scheduling; the coordinator verifies the merge. On conflict: `wt.ps1 sync`, resolve, re-check, `push --force-with-lease` to
   **your** branch. Never force-push a target branch.
4. Several MRs are fine for a big stream; merge each before starting the next.

## The full loop (incl. coordinator steps)

```powershell
$K = '<workspace>/.claude/skills/dev-kit/scripts'; $B = '<workspace>/.claude/skills/orchestrate/scripts/board.ps1'
& $B join -Agent <id> -Run <wave> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md   # 0. board: SESSION token + who else is active
& $K/wt.ps1 new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>   # 1. worktree (deps linked)
& $K/wt.ps1 sync -Dir <wt>                                       # 2. rebase onto latest target - before editing
& $K/stack.ps1 -Dir <wt>/<module>                                # 3. see what build/test commands this module uses
#    ... edit ...
& $K/check.ps1 -Dir <wt>/<module>                                # 4. compile + typecheck + lint (gated)
& $K/check.ps1 -Dir <wt>/<module> -Step test -Tests "<names>"    #    targeted tests only
& $K/check.ps1 -Dir <wt>/<module> -Step migrations               #    if you touched DB migrations
& $K/wt.ps1 commit -Dir <wt> -Message "feat(scope): ..."         # 5. commit with hooks really running
& $K/wt.ps1 sync -Dir <wt>; & $K/check.ps1 -Dir <wt>/<module>    # 6. rebase + re-check before push
git -C <wt> push -u origin <branch>
python $K/devtools.py mr <wt> "<title>" body.md                  # 7. MR/PR (GitLab or GitHub, from the remote)
python $K/devtools.py merge <wt> <iid>                           # 8. schedules "merge when pipeline succeeds" and returns at once (the supervisor re-arms it if a later push drops it)
& $K/deploy-merge.ps1 -Repo <checkout> -To staging/<product> -Check <module> [-Push]   # coordinator: merge main into a deploy branch; auto-resolves add/add conflicts left by an earlier squashed merge
& <workspace>/.claude/skills/orchestrate/scripts/track.ps1 add -Task <task id> -Mrs <repo>!<iid>,...   # 8b. the coordinator's heartbeat promotes the task when all merge
& $B leave -Session <token> -Status done                         # 9. leave the board
```
