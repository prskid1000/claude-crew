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
  MR state in any report or text: only from the host at write time (`crafty.ps1 host mr.get`, merge's last line), never the
  brief or memory. Over its prose limit, `wt commit`, `tracker comment -Kind <comment-*>`, `devtools.py comment|finish|mr`
  refuse: rewrite (`-ProseOk` / `--prose-ok "<why>"` only for a format the brief fixes).
- **Tracker:** always `crafty.ps1 tracker` (any backend; `inProgress` -> `review` once MR, both docs and
  solution comment posted -> `promoted` by `track` when all merge -> `inTest` after deploy (coordinator)). Never set
  `inTest`, `closed`, a parent's (= least open child), a step back (new code round: `-Back`); `promoted` passes
  `process.gates.promote` (`builtin:testingDocs`: doc links atop the description).
- **Publish once per key:** docs and evidence via `devtools.py doc|evidence --key <task|run>:<kind>` (same link, a dated
  section per round); comments via `tracker comment -Kind <kind>` (edits the last kit one; decisions: `bossy.ps1 decide` only);
  `devtools.py mr` edits the open MR.
- **Evidence:** UI -> screenshots, backend -> `pokey.ps1 api -Save` JSON (names: pokey SKILL.md "Evidence"); never production;
  a 404/405 on an endpoint that exists on the target branch = stale deploy, not a code bug.
