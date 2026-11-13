# task-rollup
- What: a parent task's delivery status and triage, built by script from kit state (no agent writes them):
  `bossy.ps1 track rollup -Task <parent> [-From <brief dir | item table .md>]`; `track run` refreshes every parent with a
  not-done tracked subtask or a stored triage. Parent description, between `<!-- kit:delivery -->` / `<!-- kit:triage -->`
  markers under the testing-doc links (the owner's text untouched): a summary line (merged, deployed per env, in test, closed,
  next step), one table per repo headed `<shortest alias> (<repo>)` (merge order inside: subtask, status, MRs with state and
  env, items done/total, severity `11C/1H` of its fix items, item ids); triage counts (severity x fix / defer / duplicate /
  already fixed), a "Not in this wave" table (id, severity, verdict, reason). Trackers storing rich text get real tables
  (lib.ps1 `ConvertFrom-KitMarkdown`: Jira ADF / wiki, Azure HTML). Each subtask with
  triage items gets an "Items" checklist (`<id> · <severity> · <title> · <MR URLs>`; ticked when a merged MR names the id or all
  its MRs merged; deferred / duplicate unticked with the reason): tracker verb `checklist`, else an `<!-- kit:items -->` section.
  Its own Items ids (areas) join that checklist as `<id> · <plain description> · <MR URLs>` (the description: the Items words,
  triage ids in them as their titles), ticked once every MR naming the id merged. The id leads: a new text renames in place.
  One parent comment per milestone: all merged, deployed to `<env>`, all closed.
- Parent close (owner, 2026-11-11): every subtask in the tracker's closed status -> ONE decision (`decide ask -Gate close`, task =
  the parent; A close / B keep open + why), shown in the delivery line; the parent closes only on the answer `A` (`decide answer`).
  A reopened subtask spends an answered ask; all closed again asks once more. A task without subtasks keeps its flow (QA closes it).
- Items of every built task: `launch -Self` / `launch -Check` write the task's description Items list (`**Items (ids):** a, b`
  or bullets under it) as its "Items" checklist (`<id> · <words after the id> · <URLs of the MRs naming it>`); `track run` ticks
  an id a merged MR names, all once its MRs are all merged. No Items list: one item `MRs · <task name> · <MR URLs>` (`track add`
  writes it; the task's MR links live here, there is no MRs comment).
- Sources: task state (`track`), the git host (`mr.get` / `mr.url`; merged MRs cached), the
  deploy log, the tracker (one parent view per read), the stored triage (`-From`: the first `.md` table with ID and Area
  columns; agents from a `.json` with `agents` [{ id, task or "task <id>" in note, repo or a `repos[]` name in area / note }]).
- Writes only on a diff (section hashes, checklist signature); no read while local state is unchanged and
  `track.rollupMinutes` (default 30) has not passed.
Needed when: `tracker.type` = `*`
- Wiring: `skills/bossy/adapters/task_rollup.ps1`, dot-sourced by bossy.ps1 (verb `track rollup`; hook
  `Invoke-KitTrackRollupHook` at the end of `track run`). Tests: `tests.ps1` here.
