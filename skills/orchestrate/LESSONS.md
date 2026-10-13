# Coordination lessons — active rules (read before planning a wave or a QA run; ≤ 40 lines)
Newest first, one line each, `(n×)` = times seen. Fixed/old entries live in `HISTORY.md` (never read it for work).

- (3×) A bug-fix /dev-wave launched while an app-lane /test-and-close holds 3 phones starves both on one machine (gated tests sat in the RAM queue until agents were stopped, phone re-acquires took 20-40 min): when both must run, launch QA with `lanes` capped at 2 (or web/api lanes only) and tell build agents to push and open the MR with verification marked pending rather than wait in the gate.
- The owner asks for something destructive (clean a folder, reset a branch) while waves run: do it yourself after they finish; agents must never act on relayed requests outside their items.
- Contracts file: agents append, never overwrite — still re-check your note is there after agents publish shapes. When a contract changes mid-wave, append it AND add a note in the brief agents re-read; reconcile duplicate key specs. (3×)
- Overlapping agents: brief them to rebase only after the sibling MR merges (one conflict resolution, not two).
- Workflow scripts never read the clock (`Date.now()` / `new Date()` break resume); resume a crashed run with `resumeFromRunId` after the fix (finished agents replay from cache).
- Kit scripts that take MR refs must trim quotes (`pwsh -File x.ps1 -Mrs 'a!1','b!2'` passes them literally); always call kit scripts with pwsh 7.
- QA bug tasks are fixed at once, never held until their run finishes: one brief per task (`bug-brief.ps1`), one combined file, ONE /dev-wave for every bug open now; later bugs go into the next wave.
- ALWAYS pass `mandate` (the owner's own words) to /dev-wave and /test-and-close: the harness relays the user's latest chat message as "the request that wins" and agents otherwise drop their items or decline. (3×)
- After merging an MR that adds a dependency, add it to the shared linkFrom tree yourself (exact pinned version: `npm pack` + tar into `node_modules/<pkg>`, no deps); never run a full install there.
- Briefs: git-grep the target branch before listing work on a second branch; quote producer contracts verbatim; port a sibling wave's review findings into the next brief; collect items that need a product concept into one decisions doc and run a follow-up wave once the owner decided. (4×)
- Answer QA testers in `<runDir>/lead-notes.md` (they re-read it), never SendMessage them. Always start `autoclose.ps1` for a QA run (small close agents sometimes refuse to publish).
- Confirm API MRs merged before QA; register consumers with `track.ps1 add -MergeAfter '<web>!<iid>><api>!<iid>'`. (6×)
- NEVER SendMessage a running workflow agent by its agentId: it spawns a resumed duplicate in the same worktree (guard-sendmessage.ps1 blocks it). Relay by appending to `<brief>.contracts.md`; agents re-read it before every push. (3×)
- Launch kit workflows by `scriptPath`, not name (named lookup uses the cwd's `.claude/workflows`).
- Group agents by AREA (screens/packages), not item count; write overlaps and contracts into the brief. ~15 parallel dev agents is fine (they queue on the memory gate; expect hours).
- Agents stopped by usage limits/RAM resume from their worktrees with RESUME_BRIEF; don't restart from scratch.
- Never set tasks to `inTest` (logical status) before deployment; QA runs close subtasks only after publishing results.
