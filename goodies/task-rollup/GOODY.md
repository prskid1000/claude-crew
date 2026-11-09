# task-rollup
- What: a parent task's delivery status and triage, built by script from kit state (no agent writes them):
  `bossy.ps1 track rollup -Task <parent> [-From <brief dir | item table .md>]`; `track run` refreshes every parent with a
  not-done tracked subtask or a stored triage. Parent description, between `<!-- kit:delivery -->` / `<!-- kit:triage -->`
  markers under the testing-doc links (the owner's text untouched): a summary line (merged, deployed per env, in test, closed,
  next step), one table per repo (per repo and batch when the run had several batches; merge order inside: subtask, status,
  MRs with state and env, testing docs, items done/total, last update); triage counts (severity x fix / defer / duplicate /
  already fixed), each subtask's item ids by severity, the items not in this wave with reason and decision. Each subtask with
  triage items gets an "Items" checklist (`<id> · <severity> · <title>`; ticked when a merged MR names the id or all its MRs
  merged; deferred / duplicate unticked with the reason): tracker verb `checklist`, else an `<!-- kit:items -->` section.
  One parent comment per milestone: all merged, deployed to `<env>`, all closed.
- Sources: task state (`track`, `docs` testing-doc / testing-ai), the git host (`mr.get` / `mr.url`; merged MRs cached), the
  deploy log, the tracker (one parent view per read), the stored triage (`-From`: the first `.md` table with ID and Area
  columns; agents from a `.json` with `agents` [{ id, task or "task <id>" in note, repo or a `repos[]` name in area / note }]
  and `batch` = agents per batch).
- Writes only on a diff (section hashes, checklist signature); no read while local state is unchanged and
  `track.rollupMinutes` (default 30) has not passed.
Needed when: `tracker.type` = `*`
- Wiring: `skills/bossy/adapters/task_rollup.ps1`, dot-sourced by bossy.ps1 (verb `track rollup`; hook
  `Invoke-KitTrackRollupHook` at the end of `track run`). Tests: `tests.ps1` here.
