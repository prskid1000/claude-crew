# Self-improvement, scaling and models (orchestrate reference)

Read when you run /kit-retro, turn QA bugs into a wave, add QA workers, or choose models.

## Self-improvement loop (everything learns)
| Signal source | Where it lands | Turned into |
|---|---|---|
| Agents (`learn.ps1 -Skill -Kind -Text`) and each workflow's Learn step | `.claude-runtime/learning/signals.jsonl` | `LESSONS.md` lines (≥ 2 occurrences) |
| Guard hook blocks | `.claude-runtime/guard.log` | lessons / clearer rules where agents keep tripping |
| Memory gate | `<OS temp>/claude-build-gate/history.json` (`%TEMP%` on Windows, `$TMPDIR` or `/tmp` elsewhere) | automatic: next build's memory estimate + "usually ~N min" |
| QA runs (audit reclassifications, verify "not reproduced", NOT_TESTED causes, bad evidence names) | `qa-runs/<run>/` | qa-kit lessons, project gotchas |
| Tech-audit review outcomes | project profile in `tech-audit/reference/projects/` | by-design list, review lessons |

`/kit-retro` (suggested automatically at session start once ≥ 15 new signals pile up) mines all of the above with 4 parallel
analysts, applies lesson changes, promotes lessons seen ≥ 3× into SKILL.md / rules, and lists script or default changes for
approval (`{ applyScripts: true }` to apply them). Every agent reads its skill's `LESSONS.md` before starting.

**New QA bug task → fix wave in one step:** `scripts/bug-brief.ps1 -Task <id> -Agent B-<code> -Repos backend,web [-Hints ...]` writes the brief from the task's failed checks (repos + mandate from `dev-kit/kit.local.json`), starts tracking and prints the /dev-wave args. Add only your judgement as `-Hints`. Started the fix wave from the QA evidence before the bug task existed (skipClose runs)? Link them afterwards: `track.ps1 add -Task <bug> -Wave <wf run id>` holds the task until that wave ends (otherwise an already-merged MR in the list promotes it early, and supervise flags the bug as "not being fixed").

**Scale with memory, pick models by difficulty:** QA concurrency follows free RAM, not a fixed number: every tester takes a memory seat (`qa-kit/scripts/qa-seat.ps1`), and when the supervisor's INFO capacity flag says a run has queued items and room, launch an extra worker (`/test-and-close { runDir, kitDir, instance: 'w2', only: [...] }`) - item claims keep workers apart (never for a run launched before seats existed). Launch `/test-and-close` with the short form `{ runDir, kitDir }` (run.json is read by a tiny agent) to keep launches and notifications small. Models by stage (defaults; table in docs/configuration.md): dev builds and fixes run on sonnet unless the agent is marked complex (`agents[].complex: true` or `args.complex: [ids]`, from the brief's Complex column; `bug-brief.ps1` marks bugs with > 2 checks or any non-cosmetic check) - complex ones get the strongest model; review, QA verify and note audit run on sonnet; mechanical steps (load-run, ci, ship, close, hold, release, learn) on haiku; first-time QA guides keep the strongest model, narrow web/API retests sonnet. Override per agent (`agents[].model`/`effort`, item `model`/`verifyModel`) or per stage (`args.models` / run.json `models`).

**Always pass `mandate`** (the task owner's own words that asked for the work) to /dev-wave and /test-and-close: the harness relays the user's latest chat message into workflow agents as the request that wins, and without the mandate they drop their items for it.
