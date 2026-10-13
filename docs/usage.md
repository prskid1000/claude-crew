# Usage

## A dev wave

1. Ask the coordinator (your main session) to plan: *"Split these 8 tickets into a dev wave, grouped by area."* It fills
   `skills/orchestrate/templates/WAVE_BRIEF.md` (repos + target branches, ownership, migration ranges, contracts).
2. Run it:
   ```
   /dev-wave
   args: { brief: '<workspace>/briefs/wave-projects.md', kitDir: '<workspace>/.claude',
           agents: [ { id: 'X1', items: 'PRJ-12, PRJ-13', area: 'project form + API' },
                     { id: 'X2', items: 'PRJ-20', area: 'report export' } ] }
   ```
3. Keep one heartbeat on: `/loop 10m supervise the running waves` (`supervise.ps1 -AutoFix -Brief`). Each round runs
   `& <workspace>/.claude/skills/orchestrate/scripts/supervise.ps1 -AutoFix` and acts on ACT flags.
4. When it finishes: `& <workspace>/.claude/skills/orchestrate/scripts/wave-report.ps1 -Run <workflow id>` (MRs,
   done/deferred, open review findings) and follow up (fix wave, deploy, QA).

Bug-fix waves use `mode: 'bugfix'` with `BUGFIX_BRIEF.md`; stopped agents continue with `mode: 'resume'`. For a
`[Bug] … failed checks` task from QA, one command writes the brief, starts tracking and prints the /dev-wave args
(including `mandate` and `complex: true` unless the bug is one or two cosmetic checks):
`& <workspace>/.claude/skills/orchestrate/scripts/bug-brief.ps1 -Task <task id> -Agent B-ORD -Repos api,web`.
Agents build on sonnet by default; mark hard ones `complex: true` (strongest model) or set `model` / `effort`
(e.g. `{ id: 'X3', items: 'ORD-31', area: 'pricing engine', complex: true }`).

## Test and close a deployed batch

1. Create a run folder `<runtime>/work/qa-runs/2026-10-01-projects/` (`<runtime>` = `<workspace>/.claude/.claude-runtime`)
   with the tester guides (exported to text) and `run.json`:
   ```json
   { "title": "Projects epic", "target": "my-staging", "tester": "QA team",
     "mandate": ["Test the projects epic on staging and close what passes"],
     "tracker": { "list": "<list id>", "parent": "<epic id>", "owner": "<user id>", "closeStatus": "closed" },
     "lanes": [ { "n": 1, "name": "Falcon", "serial": "emulator-5556", "user": "qa-user-1" } ],
     "items": [ { "code": "F1", "title": "Project form", "guideFile": "<runtime>/work/qa-runs/2026-10-01-projects/F1.txt",
                  "lane": "web", "subtasks": [ { "id": "<task id>", "name": "Project form", "mrs": "!101" } ] } ] }
   ```
2. Run `/test-and-close` with the short form `{ runDir: '<run dir>', kitDir: '<workspace>/.claude' }` (a tiny agent reads
   `run.json`; `only: ['F1']` runs a subset) or with the whole object plus `"runDir"` and `"kitDir"`, and start the safety
   net in the background: `& <workspace>/.claude/skills/qa-kit/scripts/autoclose.ps1 -Journal <workflow transcript dir> -RunDir <run dir>`.
3. Each package ends with a report (verdict, results table, failures with screenshots, evidence index) as a Google Doc or
   `report.md` (`reports.type`), a comment on every task, closed tasks, and a `[Bug] … failed checks` task for confirmed
   failures, which feeds the next bug-fix wave.
4. Testers wait for a memory seat, so parallelism follows free RAM. When the supervisor flags spare capacity, add a worker:
   `/test-and-close { runDir, kitDir, instance: 'w2', only: ['F4','F5'] }` — item claims stop two runs testing the same
   item.

## Phones

```powershell
$P = '<workspace>/.claude/skills/android-swarm/phone.ps1'
& $P acquire -Agent manual -Lane Falcon     # by hand: boots when memory allows, installs the current APK
& $P status
& $P release -Agent manual                  # closes the app, shuts the phone down unless someone is waiting
```
QA agents do the same with their own id; the supervisor releases leases whose holder crashed.

## Housekeeping and learning

```powershell
& <workspace>/.claude/skills/orchestrate/scripts/status.ps1 -Open -Watch     # live HTML dashboard
& <workspace>/.claude/skills/orchestrate/scripts/cleanup.ps1 -DryRun         # what self-cleaning would remove
& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Stats            # signals since the last retro
& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill dev-kit -Fixed "<words>"   # the kit handles it now: lesson -> HISTORY.md
```
Run `/kit-retro` after a wave or when the session-start nudge says signals piled up (`{ applyScripts: true }` also applies
script changes).
