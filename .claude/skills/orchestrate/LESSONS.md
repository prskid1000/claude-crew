# Coordination lessons (self-improving — read before planning a wave or a QA run)

Newest first. `(n×)` = times observed.

- (fixed in kit) After a wave finishes run `cleanup.ps1 -WorktreeIdleHours 0`: merged worktrees (remote branch deleted, clean) go at once; open MRs are protected by their remote branch. Cleanup also stops idle Gradle/Kotlin daemons (GBs each) and test browsers when no QA agent is active.
- NEVER SendMessage a running workflow agent by its agentId: it spawns a resumed DUPLICATE that edits the same worktree
  (two agents collided and both had to be stopped and resumed). Relay contracts by appending to `<brief>.contracts.md`
  — agents re-read it before every push (dev-kit SKILL §8). Agents may still message the coordinator.
- Group agents by AREA (screens/packages), not item count; write overlaps and contracts into the brief.
- ~15 parallel dev agents is fine because they queue on the memory gate — expect hours, not minutes.
- Agents stopped by usage limits/RAM resume cleanly from their worktrees with RESUME_BRIEF — don't restart from scratch.
- Never set tasks to `in test` before deployment; QA runs set `Closed` per subtask only after publishing results.
- Paste the user's request verbatim into the run's `mandate` — testers otherwise decline or return early.
- (fixed in kit) MRs auto-merged before review once shipped a blocking double-billing regression and the tracker would have promoted it: track.ps1 holds while a running wave has a blocking finding on the task's MRs (re-run wave-report.ps1 when the wave ends to release).
- (fixed in kit) /dev-wave with review no longer lets build agents schedule merges; a cheap ship step schedules them after a clean review (consumers via track.ps1 -MergeAfter), and the fix round schedules them itself.
- (fixed in kit) The dev-wave ship step overwrote the build report (done list lost) -> it now merges MR states into it. track.ps1 Save lost an agent's -MergeAfter to a concurrent 'run' -> Save now unions with the file on disk.
- (fixed in kit) dev-wave's fix round also runs for should-fix findings (only nits skip it): a should-fix (a permission check gated off) was otherwise scheduled to merge and the coordinator had to cancel auto-merge.
- (fixed in kit) dev-wave's fix round replaced the build report, so the wave summary listed only the fix-round items. Now merged: MRs, done, live checks and summaries are combined.
- (fixed in kit) An agent registered a short ref (`web!6122`) with track.ps1 that never resolved, which would have blocked the task's promotion forever. track.ps1 normalises refs (kit.local.json `repoAliases`, full MR URLs) on add, save and run.
- (fixed in kit) A user message (about something else) relayed into a running /dev-wave agent was treated as its task and the bug fix was abandoned. The dev-wave build prompt + dev-agent.md now say relayed user messages are for the coordinator (test-and-close already had this).
