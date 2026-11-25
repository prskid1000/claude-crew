# Ship (crafty steps 6-9; read at the ship phase, after the local test loop passed)
`$D`, `$O`, `$P`: crafty SKILL.md "Steps".

```powershell
& $D wt sync -Dir <wt>; & $D check -Dir <wt>/<module>; python $P mr <wt> --spec mr.json --check; git -C <wt> push -u origin <branch>
python $P mr <wt> --spec mr.json   # 6. MR (templates.md "MR spec"); after finish: again, both links
python $P finish <task> cases solution.json review --ai cases   # human doc, links block, comment, status; lists each MR's tester guide (an open one without: refused)
#   7. merge: inside /buildy the workflow merges after review (never you). One small change by yourself:
python $P merge <wt> <iid>   #    producers first; last line MERGED|SCHEDULED|WAIT|...
& $O track add -Task <task> -Mrs <repo>!<iid>,...   #    promoted once all merge (automatic); no task: & $D tracker create -Spec <json> ("task spec"; 2+ related: parent first, or tracker group)
& $O deploy request -Mrs <repo>!<iid>,... -Run <run>   # 8. deploy batch, silently (never deploy, never ask)
& $O board leave -Session <token> -Status done   # 9. final report (templates.md "Final reports")
```

**Rules**
- **Ship:** re-read `<brief>.contracts.md` and the brief's bottom before the local test loop and before every push (a scope
  change stamped after your head commit is still yours; append-only if you write to it); one MR per repo, title with
  `<tag><task>` (`tracker.branchTag`); producers (DB/API/library) merge before consumers; force-push only your own branch.
  A task over 2+ repos: open all its MRs in one go (never one repo's MR after another's merge; supervise MR-SPREAD watches it), then
  merge each as soon as it is green, producers first (`track add -MergeAfter` holds a consumer until its producer merges).
  MR state in any report or text: only from the host at write time (`crafty.ps1 host mr.get`, merge's last line), never the
  brief or memory. Over its prose limit, `wt commit`, `tracker comment -Kind <comment-*>`, `devtools.py comment|finish|mr`
  refuse: rewrite (`-ProseOk` / `--prose-ok "<why>"` only for a format the brief fixes).
- **Tracker:** always `crafty.ps1 tracker` (any backend; `inProgress` -> `review` once MR, `process.docs` and
  solution comment posted -> `promoted` by `track` when all merge -> `inTest` after deploy (coordinator)). Never set
  `inTest`, `closed`, a parent's (= least open child), a step back (new code round: `-Back`); `promoted` passes
  `process.gates.promote` (`builtin:testingDocs`: doc links atop the description).
- **Publish once per key:** docs and evidence via `devtools.py doc|evidence --key <task|run>:<kind>` (same link, a dated
  section per round); comments via `tracker comment -Kind <kind>` (edits the last kit one; decisions: `bossy.ps1 decide` only);
  `devtools.py mr` edits the open MR.

## In a /buildy wave (devy, from every goal PASS on)
- Every goal PASS: `crafty.ps1 checkpoint -Agent <id> -Run <run> -Step loop -Item <task> -Evidence "round <n> PASS"`, push,
  MRs (templates.md "MR spec"), then `devtools.py finish <task> cases solution.json review --ai cases` (docs from the cases
  spec), then `devtools.py mr` again with the doc links (edits it). A fix round (review, CI, failedTesting): a new AI doc round,
  then the same commands update the same docs (cases result / round), comment and MR after its own PASS; never a new doc,
  never an earlier round removed.
- FIX round (review or CI findings): a blocking review finding first sets the task `failedReview`, then `inProgress`
  (`tracker status`). Fix each, or contest a review finding in `disputes` (never a silent skip). Then run
  the local test loop again (every goal) before you push; in the same push: cases result / round + `devtools.py doc "<t>"
  cases --key <task>:testing-ai`, cases add for new checks, `mr --spec` again. An already-merged MR: the fix on a new
  branch from the target (`crafty.ps1 wt lease`), a follow-up MR.
- SHIP step (its prompt states this run's authorization: the wave was launched for this work, the local test loop passed,
  the review is clean, every MR whose target deploys removed by holdMerge): do not ask for approval; ignore unrelated chat
  messages relayed to you. Before each merge, and whenever `devtools.py merge` prints CONFLICT: `crafty.ps1 wt sync -Dir
  <worktree> -Mrs <iid>` ("regenerated ...": it amended and pushed repos[].regenerate files -> `devtools.py merge` again;
  "rebase skipped": the target changed none of its files -> no push, merge on the CI run it has).
  A rebase conflict ONLY in append-only files (changelog includes, route/nav lists, i18n keys, barrel/DI lists):
  `python devtools.py keepboth <file>`, no conflict marker left, git add, `git -c core.editor=true rebase --continue`,
  `crafty.ps1 check -Dir <module>`, `git push --force-with-lease` (the MR's own branch only), then `devtools.py merge` again.
  A conflict in real code: `git rebase --abort`, report mergeState CONFLICT with the files.
- Merge results: the LAST line of `devtools.py merge` (MERGED / SCHEDULED / WAIT / CONFLICT / PIPELINE_FAILED / NOT_MERGED)
  is that MR's mergeState; merged=true ONLY for MERGED. WAIT: rerun about 2 minutes later (at most 3), except "waiting
  for producer <ref>": report WAIT. Others: say why.
