# Lead steps (pokey; checky lead, a test-only run; bossy T1-T4)
Read by `checky` lead and the coordinator only; testers and verifiers never need it (pokey SKILL.md).

- L0. Machine setup once: `bossy.ps1 setup -WriteLocal` (writes targets.local.json),
  `npm install` in this folder, `swarm.config.json` for app lanes, auth checks (tracker, `gws` when `reports.type` =
  gdocs, git host).
- L1. Run folder `<runtime>/work/qa-runs/<date>-<name>/` + `run.json` (shape: the header of `workflows/testy.js`; one
  item per testing doc: `{code, title, guideFile, lane: a qa.lanes name, target?, services? (local: leased),
  subtasks:[{id,name,mrs}], retest?, only?}`),
  guides exported to text. `lead-notes.md`: MANUAL deploy state; prerequisites per guide: flags, accounts, roles, data (by
  id; local env: `seed -Check`), reindex, server config; what the lead cannot unblock -> `skip` + reason.
  **Selection** (`pokey.ps1 prepare -Job <job JSON>` runs steps 1-5, the workflow's Prepare step; by hand the same):
  1. Folder = `runFolder`, `<testy-id>` -> the run id `testy-<YYYYMMDD>-<nn>`, date placeholders expanded; one with files is refused, an empty one reused.
     Candidates: `crafty.ps1 tracker list <container> <status>` per `lists` (empty: `trackerLists`, else `tracker.list` /
     `tracker.repo`) x `statuses` (logical names via `tracker.statuses`; `in test` = `inTest`; other names pass through);
     `tasks` given: only those + their subtasks in `statuses`; minus `exclude`; `mine` = only the `tracker owner`'s.
  2. Per task: MRs `<repo>!<iid>` (`tracking` `<id>.json` `track.mrs`, else the task's MR links); its "Testing doc
     (human):" link -> `<run>/guides/<code>.md` (its kept copy, else the link).
     None of either -> left out. Tasks sharing a doc = one item.
  3. Target: `target` names a `targets.local.json` entry -> every item; else `kit.local.json` `qa.targets.<target>` = rules
     `[{ lists?, repos?, nameRegex?, pathRegex?, target, localEnv? }]`, first match -> `item.target` (+ `item.localEnv`); none
     -> left out.
  4. Live: test env -> `pokey.ps1 deployed -Mrs <MRs> -Target <t>`, DEPLOYED or N/A (MANUAL resolved): in (NO-TARGET next to a
     live MR: `localParts`, local env); all N/A for the target: left out (other product); `localEnv` -> in after
     `envy.ps1 status -Env <env>`. Else left out with the state.
  5. `run.json` = `{ title, target, kitDir, runDir, mandate, tracker: { list }, items, left: [{ id, name, reason }] }` +
     `runSettings`; then `lead-notes.md`. Return `{ runDir, items, left, summary }`.
- L2. Launch `/testy { runDir, kitDir }`, or let it select: `{ select: { statuses, lists?, tasks?, exclude? }, target,
  kitDir, mandate }` (Prepare = L1 Selection); `launch` record (bossy). Lead notes are the only channel to running testers.
- L3. After the run: items the workflow could not publish -> `pokey.ps1 finalize -RunDir <run> -Code <code>` (results.json);
  a fix went live and needs a retest -> `pokey.ps1 retest -RunDir <run> -Task <id> -Code <code>R -Mrs <refs>`.

## Coordinator (bossy T1-T4)
**Test-only flow** (/testy; steps: `workflows/testy.js`): all pass -> closed; own FAIL or incomplete -> failedTesting (E6); new
defect -> one [Bug] per ask (E6); a local env item still NOT_TESTED -> ENV-FIX (E4), then held, never failedTesting;
unpublished items -> `pokey.ps1 finalize` (`bossy.ps1 recover`).
- T1-T4 (test-only): `/testy { select: { statuses: ['promoted', 'inTest'], lists?, tasks?, exclude? }, target, kitDir,
  mandate }` (its Prepare agent builds the run: pokey L1 Selection; `target` = an env or a `qa.targets` group), or a ready
  `{ runDir, kitDir }` -> `launch` record -> E1. Its log lists the tasks left out (not live, no testing doc, no target).
