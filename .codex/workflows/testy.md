# testy (ported procedure, not a native Codex workflow)

> Any test run (tracker selection, smoke after a deploy, regression sweep, retest; local or a test env) by checky lead / test / verify: test deployed tasks against their human testing docs (a pool per test lane, device lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)

**When to run it:** Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents

Codex has no workflow engine: you are the coordinator. Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency limit), `wait_agent` for them, then the next phase. Hold every gate below (the .js enforces them in Claude Code and Antigravity). Journal each step (the Runs band, stuck checks and `recover` read it): `python -X utf8 <kit>/skills/bossy/kitbag.py port --journal launched --run <run> --workflow testy` first; per agent `--journal started --run <run> --agent <its id> --label <label> --phase <phase>`, then `--journal result --run <run> --agent <its id>`; the end `--journal done --run <run>` (stopped: `--journal finished --run <run> --error '<why>'`).

## Before any phase (the engine's gates: hold every one)

- **Launch record**: write `args` as ONE JSON line to `<runtime>/work/launches/args-testy-<run>.json` (`<runtime>` = `kitbag.py` kit_path 'runtime'), then `& <kit>/skills/bossy/bossy.ps1 launch -Self -Script testy.js -Run '<run>' -ArgsFile '<that file>' -Fnv <FNV-1a hex of the file> -Plan '<per item: checky/<model>:1,checky/<model>:1,step/<model>:1,item:1>,step/<model>:3,kitty/<model>:1'` (no `-Plan`: no BUDGET line, nothing gated; the record `recover`, resume and the Runs band read).
- Its `BUDGET {cap, estimate, stopAt}` line: estimate > stopAt x cap -> refused: run `floor(items x stopAt x cap / estimate)` items per run (`args.batch`), the rest in the next run; `args.batch` set: only the first N items, the rest -> `next`.
- Unknown args are refused, never dropped (free text for testers: `args.context`).

## Phases

1. **Prepare** -- args.select only: pokey.ps1 prepare (L1 selection) writes run.json + lead-notes.md; tasks not live are left out
   - `args.select` only through `& <kit>/skills/pokey/pokey.ps1 prepare -Job '<job JSON>'` (never a hand-picked list): `select.tasks` = exactly those ids + their subtasks in `statuses` (no list sweep); tasks not live, without a human testing doc, or with every MR N/A for the target (another product) are left out; no items -> stop.
2. **Test** -- one checky (role test) per guide: a pool per qa.lanes lane in parallel, device lanes one guide per device
   - Before each new item: `& <kit>/skills/bossy/bossy.ps1 budget -Run '<run>' -Json`; spent >= stopAt x cap -> no new one starts (running ones finish), the rest -> `next`.
   - One checky (role test) per guide, a pool per `qa.lanes` lane; an unknown lane is refused; device lanes: one guide per device, `args.lanes`.
3. **Verify** -- checky verify: note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL
   - Every FAIL re-tested from scratch by checky verify (unless `verify: false`); NOT_TESTED over 25%: one stronger retry of only those checks; still over 50% on a shared env = a broken run, results held (coordinator decides); local: ENV-FIX.
4. **Close** -- checky lead: report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask
   - Publish per item with `pokey.ps1 finalize -RunDir <run> -Code <code> -ExpectChecks <n>` (EXIT=0 = published); the result rule (closed / failedTesting / one [Bug] per ask) is finalize's, never by hand.
5. **Learn** -- signals from this run, cleanup (/tidy turns them into lessons)

## Owner decisions

- **Blocking** (an item waits): in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` (per question: header, question, options = label + description, recommended first, at most 3: name a 4th in the question; the client adds "Other"); the questions map to the payload's `ids` in order. No tool, or a pending id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/testy.js` (its header comment) and the `bossy` skill.
