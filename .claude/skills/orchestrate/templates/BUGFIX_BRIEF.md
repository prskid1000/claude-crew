# Bug-fix brief (e.g. "[Bug] … failed checks" tasks raised by the QA workflow)

Read `<workspace>/.claude/skills/dev-kit/SKILL.md` first.

**Bugs:** <task ids / URLs>   **Repos + targets:** <repo → target branch>   **Environment:** <URLs, account>

1. **Read the bug.** `& <workspace>/.claude/skills/dev-kit/scripts/tracker.ps1 view <id>` and `... tracker.ps1 comments <id>`.
   Check ids (T1, L4, X2 …) refer to the tester guide linked or attached on the original task (a Markdown file, or a Google Doc:
   `gws drive files export --params '{"fileId":"<id>","mimeType":"text/plain"}' -o guide.txt` in the output folder).
   The QA evidence (screenshots, request/response JSON) is linked from the results report (Google Doc, or report.md in the QA run folder).
2. **Classify each check**; change code only for real bugs:
   - **Real bug** → find the root cause, fix it, add a test.
   - **Stale deploy** → the fix exists on the target branch but the environment runs an older build
     (404, 405, "No static resource"). Name the missing commit.
   - **Expected behaviour** → cite the decision.
   - **Config / data** → say what to set where.
3. **Reproduce before fixing** on the environment above (API via `<workspace>/.claude/skills/qa-kit/scripts/api.ps1`, web via the
   browser helper). For app bugs use the tester's evidence plus real API calls; don't start an emulator. Restore any data you change.
4. **Duplicate tasks** (same title): fix once, put the same comments and status on both, mark the second as the duplicate.
5. **Ship**: branch `fix/CU-<id>-<slug>`, one MR per repo, producers (API/DB) first after a green pipeline.
   Tracker: in progress → review → promoted. Never "in test".
6. **Final reply (≤ 200 words):** verdict + root cause per check, MRs, how you verified.
