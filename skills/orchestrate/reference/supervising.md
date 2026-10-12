# Supervising in full (orchestrate reference)

Read at orchestrate event E2 (an ACT flag's action is unclear) and E5 (a workflow finished). The heartbeat itself is E1.

## What one heartbeat round does
`& <workspace>/.claude/skills/orchestrate/scripts/supervise.ps1 -Session <this session id> -AutoFix [-Brief]` checks workflows
(agents running / finished / idle), the agent board (duplicates, stale), the gate (queue, longest wait, repeated build failures),
RAM/disk, guard blocks and phone leases, and with `-AutoFix` also runs the tracker (`track.ps1`: task statuses once all MRs merge),
stale board cleanup, due cleanup, idle-emulator shutdown and a LIVE flag once a promoted task's MRs are deployed to a test
environment (`qa-kit/scripts/deployed.ps1`, targets in kit.local.json `repos[].deploys`). `-Brief` prints only flags, or one
`ok: N running, mem X%` line. Keep the heartbeat prompt **generic** (what runs comes from the script): a prompt listing run ids
goes stale within the hour.

## Typical ACT moves (E2)
- A duplicate copy of an agent: TaskStop the resumed task (never SendMessage a workflow agent by id).
- Finished without MRs: resume it with `templates/RESUME_BRIEF.md` (E6).
- A missing decision: append it to `<brief>.contracts.md` (E10).
- The gate queue waits > 30 min: hold new launches.
- Disk or leftovers: run `cleanup.ps1`. A broken shared dependency (e.g. the `-LinkFrom` source): fix it.

## When a workflow finishes (E5)
`& <workspace>/.claude/skills/orchestrate/scripts/wave-report.ps1 -Run <wf id> [-Detail]`: a journal-based summary (agents, MRs,
done/deferred, OPEN review findings, QA verdicts), saved to `<runtime>/work/waves/<run>.json`. The notification text is truncated:
don't parse it. Reconcile (MRs merged? tracker status? lessons recorded?), then take the E5 next step. Stopped a workflow yourself
(TaskStop)? `supervise.ps1 -MarkStopped <run id>` once so its unfinished steps stop showing as running.
