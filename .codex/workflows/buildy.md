# buildy (ported procedure, not a native Codex workflow)

> The dev flow for any multi-item build (any stack): devy code, goals, local loop, decisions; review, CI, merge (producers first), testing docs + tracker; deploys on a person\'s word

**When to run it:** Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)

Codex has no workflow engine: you are the coordinator. Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency limit), `wait_agent` for them, then the next phase. Hold every gate below (the .js enforces them in Claude Code and Antigravity). Journal each step (the Runs band, stuck checks and `recover` read it): `python -X utf8 <kit>/skills/bossy/kitbag.py port --journal launched --run <run> --workflow buildy` first; per agent `--journal started --run <run> --agent <its id> --label <label> --phase <phase>`, then `--journal result --run <run> --agent <its id>`; the end `--journal done --run <run>` (stopped: `--journal finished --run <run> --error '<why>'`).

## Before any phase (the engine's gates: hold every one)

- **Launch record**: write `args` as ONE JSON line to `<runtime>/work/launches/args-buildy-<run>.json` (`<runtime>` = `kitbag.py` kit_path 'runtime'), then `& <kit>/skills/bossy/bossy.ps1 launch -Self -Script buildy.js -Run '<run>' -ArgsFile '<that file>' -Fnv <FNV-1a hex of the file> -Plan '<per area: devy/<model>:1,revy/<model>:1,[datay/<model>:1,]step/<model>:3,item:<n items>>,[rechy/<model>:1 (spike),]step/<model>:2,kitty/<model>:1'` (no `-Plan`: no BUDGET line, nothing gated; the record `recover`, resume and the Runs band read). A `TASKS REFUSED` line: stop, fix the task gaps.
- Its `BUDGET {cap, estimate, stopAt}` line: estimate > stopAt x cap -> refused: run `floor(areas x stopAt x cap / estimate)` areas per run (`args.batch`), the rest in the next run; `args.batch` set: only the first N areas, the rest -> `next`. One area over: split the brief or `decide ask`.
- Unknown args are refused, never dropped (free text: `agents[].note` or the brief).

## Phases

1. **Spike** -- one rechy answers args.openQuestions in the brief before any devy
   - A question still open after rechy: no devy starts.
2. **Build** -- a devy per area: worktree, code, testing goals, local loop, MRs, testing docs
   - An area with `dependsOn` starts only once its producers' MRs are merged.
   - Before each new devy round (build, fix, decide resume): `& <kit>/skills/bossy/bossy.ps1 budget -Run '<run>' -Json`; spent >= stopAt x cap -> no new one starts (running ones finish), the rest -> `next`.
   - A devy returning `handoff`: a fresh devy continues from that resume brief (at most 3 times).
3. **Decide** -- items paused for an owner decision or ENV-FIX resume after the answer
4. **Review** -- a revy per devy (+ datay on migrations) while the CI pipelines run
   - Not reviewed, not merged (the coordinator decides) when the local test is BLOCKED, FAIL beyond env gaps, or NONE in a code area (kind not doc / spike / repro) without an owner word.
   - NONE needs `localTest.decisionId` = `dec-<words>` (older: `dec-<n>`, `dec-<nnnn>`, `d-<14 digits>-<suffix>`) and `& <kit>/skills/bossy/bossy.ps1 decide check -Id <id> -Gate 'merge,scope,other' -Item '<area>,<task>,<branch>,<items>,<repo>!<iid>' -MaxHours 720` printing `WORD ` (any other output: held).
   - One revy per area, plus datay on an area with `migrations`; an empty review blocks the merge.
5. **Fix** -- fix round + local tests; re-review holds on blocking (a round, then a decide ask; rest -> Follow-ups); merge in order, tracker
   - Blocking findings or a failed pipeline -> one fix round (local loop again), re-review; still blocking after round 2 -> `decide ask` (A merge + Follow-ups / B hold), not merged; non-blocking re-review findings -> MR Follow-ups (`devtools.py followups`).
   - `holdMerge` repos (`true` = all): reviewed + green, never merged.
   - Merge per MR, producers first, consumers last: `crafty.ps1 wt lease`, then `python -X utf8 <kit>/skills/crafty/devtools.py merge <wt> <iid> --scope '<area paths>'`; kind `foundation` adds `--no-docs 'foundation <area>'`; a WAIT "waiting for producer" is never merged another way.
   - Register the tasks: `bossy.ps1 track add -Discover -Mrs '<url>,<url>'` (one add per task named in the MR titles; `-HoldPromotion '<why>'` when blocked, budget-stopped or items deferred).
6. **Deploy** -- merged work joins the deploy batch (bossy.ps1 deploy); a person says deploy <env>, never asked
   - Merged MRs: `bossy.ps1 deploy request -Mrs <urls> -Run <run>`, then `deploy plan -Json`; nobody deploys or asks (a `trigger: ask` env: one ask per env).
7. **Learn** -- signals from this wave, cleanup (/tidy makes lessons)

## Owner decisions

- **Blocking** (an item waits): in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` (per question: header, question, options = label + description, recommended first, at most 3: name a 4th in the question; the client adds "Other"); the questions map to the payload's `ids` in order. No tool, or a pending id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.
- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's "1 A, 2 B" back with `decide answer -Id <id>` per number.

Arguments and step details: `.claude/workflows/buildy.js` (its header comment) and the `bossy` skill.
