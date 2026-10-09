# Supervising in full (orchestrate reference)

Read when a supervise flag or its action is unclear.

## Supervising (the coordinator works like a human lead)
After launching workflows, keep ONE heartbeat running in the coordinator session (never several crons; one `/loop` or one cron job) — `/loop 30m supervise the running waves` with `supervise.ps1 ... -AutoFix -Brief` (flags only, or one `ok: N running, mem X%` line) and rely on the workflow completion notifications for finished runs — and each round. Keep the heartbeat prompt **generic** (what is running comes from
`supervise.ps1`, not from the prompt): a prompt that lists run ids goes stale within the hour as waves finish and new ones start.
Each round:
1. `& <workspace>/.claude/skills/orchestrate/scripts/supervise.ps1 -Session <this session id> -AutoFix [-Brief]` (also runs the tracker - `track.ps1`, task statuses when all MRs merge -, stale board cleanup, a LIVE flag once a promoted task's MRs are deployed to a test env (`qa-kit/scripts/deployed.ps1`, targets in kit.local.json `repos[].deploys`), due cleanup and idle-emulator shutdown): workflows (agents running/finished/idle),
   agent board (duplicates, stale), gate (queue, longest wait, repeated build failures), RAM/disk, guard blocks — with ACT/WATCH flags.
2. Act on **ACT** flags (each prints its action). Typical moves: stop a duplicate copy (TaskStop the resumed task — never SendMessage a
   workflow agent by id), resume a finished-without-MRs agent with `RESUME_BRIEF`, append a decision to `<brief>.contracts.md`, hold
   new launches while the gate queue waits > 30 min, run `cleanup.ps1`, fix a broken shared dependency (e.g. the `-LinkFrom` source).
3. Re-check **WATCH** flags next round. Don't micromanage healthy agents.
4. When a workflow finishes: `& <workspace>/.claude/skills/orchestrate/scripts/wave-report.ps1 -Run <wf id> [-Detail]` (journal-based summary, compact by default:
   agents, MRs, done/deferred, OPEN review findings, QA verdicts; saved to `.claude-runtime/waves/<run>.json` — the notification text is
   truncated, don't parse it). Reconcile (MRs merged? tracker status? lessons recorded?), turn open should-fix findings into a follow-up
   wave (one group per file owner), then start the next step
   (QA after deploy, bug-fix wave from failed checks, app lane when the APK is built).
Stopped a workflow yourself (TaskStop)? Run `supervise.ps1 -MarkStopped <run id>` once so its unfinished steps stop showing as running.
5. Stop the loop when nothing is running.
