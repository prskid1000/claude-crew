# Templates (crafty)

Every brief, doc, body and report the flows fill: copy a section into the scratchpad or run folder, fill the `<...>` parts,
drop what does not apply. Which step fills which: the Files index of the skill using it.

## Writing standards (every artefact the kit reads or writes)
Rules: AGENTS.md "Writing"; every limit is a ceiling. `kitbag.py prose --kind <kind> <file>` measures a text (exit 1 =
findings); the generators (`devtools.py mr/comment/finish`, `crafty.ps1 wt commit`, `bossy.ps1 bugbrief/decide`,
`pokey.ps1 finalize`) run it, print findings, never truncate; fix a finding by rewriting.
Limits: `Nw` words · `Nl` lines · `Nch` line width · `Nsw` words per sentence · `Nb` bullets · `each:` per `##` section ·
`<Section>:` that section (`_` for a space) · `prose:` without table rows (cells: their own kind) and image lines. Required facts: `link` URL / MR / PR ref · `id` task or check id · `path` file or `file:line` ·
`cmd` a command in backticks · `evidence` a screenshot / JSON / log path or link · `expected` an `Expected:` line ·
`options` A/B lines · `recommended` · `verdict` PASS / FAIL / BLOCKED · `conv` subject per `commitStyle` (default Conventional Commits).
Banned everywhere: greetings and thanks · "I hope" · "please note" · "it is worth noting" · "as mentioned" · "in summary" ·
"in conclusion" · "basically" · "simply" · "actually" · "really" · "very" · "successfully" · "feel free" · "let me know" ·
"happy to" · "great job" · "as an AI" · task recap · restating the template's own words.
Markdown: commands, paths, class names, config keys and ids in `backticks` (monospace; nothing else is guessed); labels
`**Label:**`; links `[text](url)`; a blank line between blocks; a tracker showing plain text: its adapter drops the markup.

| Kind | Purpose | Format (sections in order) | Limits | Required facts |
|---|---|---|---|---|
| skill | how an agent does one job | front matter, Load when, Not when, Hands off to, Files, numbered steps, Rules, Learn | 3200t 130ch | path |
| skill-step | one numbered step | `N. **Name:** action -> result` + commands | 90w 30sw | cmd |
| agent | an agent's contract (a crew member holds its own steps) | front matter, Character, Kind, Load first, non-negotiables, report shape, self-improvement | 2400t 130ch | path |
| rule | a hard rule for one file kind | `paths:` front matter (path-scoped), bullets | 900t 12b 130ch | — |
| reference | a guide inside a SKILL.md / README | `##` per topic, bullets, tables | each:250w 130ch | path |
| lesson | one LESSONS.md line | `- <when> -> <do this> (<why>)` | 1l 50w 300ch | — |
| history | one retired lesson (`learn -History`; an older LESSONS.local.md `## History`) | `- <date> <what was retired / merged> -> <where it lives now>` | 1l 50w 300ch | — |
| wave-brief | what a wave builds, by whom | the "Wave brief" template | 600w each:12b 130ch | id path |
| bug-brief | one bug to fix | the "Bug-fix brief" template + failed checks + evidence | 350w 130ch | id evidence |
| testing-goals | local goals file (`goals.md`), never published | ## Goals, ## Test plan (automated), ## Data needed, ## Reproduction (bugs), ## Rounds | 700w Goals:20b each:8b | id expected |
| testing-doc | the human testing doc (positive cases; env evidence) | ## What changed, ## Before you start / Feature switches, ## Checks, ## Out of scope, ## Result (testers) | 1500w What_changed:80w 25sw | expected |
| testing-ai | the AI testing doc (the local loop record) | the "Testing doc (AI)" template: setup line, case table | 2500w 25sw | expected |
| qa-report | the QA run report (an "<env> run" section of the human doc) | header table, Tasks table, Results table (Check, Result, Observed, Evidence: images inline), failures in detail | prose:900w each:15b 25sw | id verdict evidence |
| result-note | a results.json `observed` / `what_was_done` | `<observed> vs <expected>; <evidence>` | 40w 1l | — |
| mr-title | MR / PR title | `<type>(<scope>): <change> (<task id>)` | 1l 90ch | conv |
| mr-body | MR / PR description | ## Summary, ## Changes, ## How tested, ## Risks, ## Links | 260w each:3b Summary:40w | link |
| commit | commit message | subject; blank line; body bullets | first:72ch 12l 100ch | conv |
| merge-commit | a merge commit (deploy merge, target into a branch) | subject naming both branches; blank line; why | 12l 100ch | — |
| task-name | tracker task name | `[Feature/Bug/Chore] <area> — <outcome>` | 1l 100ch | — |
| task-description | tracker task description | Problem, Goal, Acceptance (bullets), Links | 200w each:6b | link |
| comment-solution | solution comment on a task | the "Task solution comment" template | 8l 120w | — |
| comment-status | a status change note | `<status> — <why> · <link>` | 2l 40w | link |
| comment-deploy | a deploy record (+ the batched ask, only under `deploy.trigger` ask) | env, MRs (merge order), who said deploy, result | 8l 120w | link |
| decision-request | a decision the owner makes | the "Decision request" template | 120w 4b | options recommended |
| kit-report | supervise report, retro, lead notes, resume brief | `# <title>`, a `**Result:**` line, `##` sections, tables for like items | prose:400w 130ch | — |
| final-report | an agent's last reply | the "Final reports" shape of its role | 200w 25sw | link |
| owner-message | coordinator -> owner | result first, then the ask / next step | 150w 25sw 8b | — |
## Wave brief
```markdown
# Wave brief: <wave name>, <date>
**Read first:** `<kit>/skills/crafty/SKILL.md`; this brief wins where they differ.
**Items:** <tracker epic / sheet> · **Decisions:** <doc>; final, don't re-ask (a NEW choice -> crafty D1).
**Local env:** <kit.local.json localEnv name, or "none: <why>"> · **Test env after deploy:** <name> (never production).
## Repos
| Repo | Main checkout | Target | Link deps from | Migrations |
|---|---|---|---|---|
| <repo> | `<repos root>/<repo>` | `main` | | <tool / none> |
## Agents
| Agent | Items | Area (screens / packages / files) | Repos | Migration range | Services (leased, nothing else) | Complex? |
|---|---|---|---|---|---|---|
| X1 | <ids> | <area> | <repos> | <range or —> | <api; api-only items: no web> | <yes: why / no> |

**Overlaps:** <who touches what in a shared file> · **Contracts:** <field / endpoint X1 adds, X2 consumes after X1 merges>
**Branch:** `f/<tag><task>-<slug>`, worktree name = agent id · **Tracker:** task under <epic> in <list>, assigned to <user>.
Rule changes during the wave are appended below and to the contracts file: re-read both before every push.

## openQuestions
<question> · blocks <item> · answers: rechy | owner (or "none")
## Findings (rechy)
<the Spike phase appends one block per question>
## Rule changes during the wave (newest last)
```

## Bug-fix brief
`bossy.ps1 bugbrief -Task <id>` writes it (failed checks, evidence, repos). A bug brief adds to the wave brief:
```markdown
1. Read the bug: crafty.ps1 tracker view <id> + comments (a failedTesting task's QA comment lists its failed and untested checks).
2. Reproduce LOCALLY first (envy SKILL.md "Debug locally"): the checks' steps on the local env, logs, DB state, debugger.
   Steps + evidence -> the testing-goals doc. Not reproducible locally -> say why, reproduce on the test env.
3. Classify each check: real bug (root cause + regression test red before, green after) · stale deploy (name the missing commit)
   · expected (cite the decision) · config/data (what to set where).
4. Fix, then re-run the same reproduction as the first local check; then the full testing goals.
5. Final reply: verdict + root cause per check, MRs, local proof, human testing doc link.
```

## Resume brief
`bossy.ps1 recover` writes it (crash), an agent at a budget handoff. The next agent joins with the same id + `-Resume`
(TAKEOVER), runs `crafty.ps1 wt status -Dir <wt>` per worktree, reads the task and its MRs; files changing under it: stop, report.
```markdown
# Resume brief: <agent> (run `<run>`)
**Result:** Start AT step: <next>. The steps below are done and verified: never redo them.
## Done (verified)
| Step | Item | Evidence | Check |
|---|---|---|---|
## Interrupted step `<next>`
| Worktree | Branch @ head | Uncommitted (kept) |
|---|---|---|
## Open
**Leases to take again:** <ids> · **Decisions:** <ids>
```
`<run>.resume.md`: a table per area: done (skipped) and missing (run) steps, MRs, tracker, doc.

## Testing goals
devy writes it FIRST, before the local loop (crafty step 4): a local `goals.md`, never published; the AI doc grows from it.
Docs list checks and facts as tables, an intro line above each; cells keep the prose limits.
```markdown
# Testing goals: <task id> <title>
Change: <one line, user terms>. Repos/MRs: <refs>. Local env: <env> r<n> (envy.ps1 status), services <the leased ones>.
## Goals (what must be true)
What must hold before merge:
| # | Goal | How checked | Pass rule | Result |
|---|---|---|---|---|
| G1 | <behaviour> | <steps; `<TestClass#method>` / api.ps1 / browser / phone> | <exact values, messages, status codes> | |
| U1 | <unchanged behaviour that must stay> | | | |
## Test plan (automated)
- Unit: <new/changed logic -> test names> · Regression: <each fixed bug -> test, red before / green after>
- Integration/API: <endpoints touched -> tests> · UI/component: <screens touched -> specs, where the stack supports it>
- Run: crafty.ps1 check -Step test -Tests <names> -Touched   (targeted + every test of the touched classes/modules)
## Data needed
<fixtures / seed records / settings / roles / feature switches ON; created through the API, prefixed with your agent id>
## Reproduction (bugs)
<steps, logs, DB state, evidence files; the first local check re-runs it after the fix>
## Rounds
| Round | What failed | Fix |
|---|---|---|
```

## Testing doc (AI)
The dev flow's local test record, by devy from `goals.md` when the loop starts: one row per positive, negative, edge and
regression case (invalid input, role denials, boundaries, empty data, concurrency where relevant, nearby features,
impact-check edges). Each round (fix rounds too) fills Result and Evidence (images inline, request / response excerpt +
link), appends its Rounds row, republishes: `devtools.py doc --key <task>:testing-ai --label "loop round <n>"` (same link,
earlier rounds kept; refused without a negative row or the Rounds table, or with a row dropped). It shows the local PASS.
```markdown
# Testing doc (AI): <task id> <title>
Setup and cleanup: <data created via the API (prefixed), feature switches, logins by key; what is deleted after>.
Cases:
| # | Type | Steps / API call + payload | Expected | Result | Evidence |
|---|---|---|---|---|---|
| A1 | positive | `POST /x {"a": 1}` as <role>; screen <name>, selector `<css>` | 201, body.a = 1; row shown | PASS | ![A1: row shown](<shot>) |
| A2 | negative | same as <role without the right> | 403 `<message>` | PASS | `403 {"error": ...}` [json](<link>) |
| A3 | edge | <empty / boundary / concurrent> | <exact> | | |
| A4 | regression | <nearby feature> | unchanged: <exact> | | |
Rounds (one row per round, appended; bugs found by you or checky go back to the code until 0 are open):
| Round | Date | Cases run | Result | Bugs found | Fix commit | Retest |
|---|---|---|---|---|---|---|
| 1 | <yyyy-MM-dd> | A1-A4 | 3 PASS, 1 FAIL | A3: <what broke> | <sha> | A3 PASS in round 2 |
```

## Human testing doc
A person's steps: POSITIVE cases only, no negative rows. Written after the local PASS with Result and Evidence EMPTY:
evidence comes only from a deployed env (local evidence: the AI doc). `devtools.py finish` publishes it as
`<task>:testing-doc` (refused before a loop PASS checkpoint, without the case table, with a negative row, an image or a
filled Result / Evidence); a fix round updates it after its own PASS. Testers and /testy follow it (pokey H1-H3, L1); each
deployed-env run (`pokey.ps1 finalize` or a person) fills Result / Evidence in place (images inline) and adds a dated
"<env> run <date>" section with its report; each retest adds one, earlier runs stay.
```markdown
# Testing: <feature / change>
| | |
|---|---|
| Tasks | <task links> |
| Environment | <test env name, build / MRs deployed> |
| Logins | <user keys from targets.local.json; never passwords> |
| Test data | <records to use, or how to create them> |
## What changed
<one paragraph in user terms; what must not change>
## Before you start / Feature switches
Set these first, restore them after:
| Setting | Where | Value |
|---|---|---|
## Checks
<screen / area>:
| # | Steps | Expected | Result | Evidence |
|---|---|---|---|---|
| T1 | 1. <step> 2. Run `<command>` / open `<path>` | <exact result from the shipped code (final diff), never the brief> | | |
## Out of scope
Not tested, and why (a qa.outOfScope channel: "out of scope for agent QA: <channel>"):
| Item | Why |
|---|---|
## Result (testers)
All checks pass -> close the task. A check of this change fails or could not be tested -> failedTesting with the check ids
and why. A defect outside this change -> one [Bug] task under the original ask.
```

## MR body
`devtools.py mr` checks it (kind `mr-body`): sections in this order, limits from "Writing standards".
```markdown
## Summary
[<task id>](<task URL>) — <one-line goal and outcome>
## Changes
- <behaviour change, user terms> · **Technical:** `<files / endpoints / migrations>`
## How tested
| Check | Result |
|---|---|
| Checks | check quick ✅ · tests `<names>` ✅ · touched-class tests ✅ · migrations ISSUES 0 ✅ |
| Local env | <env> r<n>: goals G1-Gn PASS (testing-goals doc) |
| Not run | <what, why> (or "nothing") |
| UI | <committed spec or screenshot link> (or "not a UI change") |
| Pure logic | <spec file> (or "none") |
| Regression | `<test>` red before the fix, green after (or "not a fix"); changed methods without a test: <names> (or "none") |
## Risks
- <deferred item — reason>
- **Behaviour limits:** <not handled>
- **Needs after deploy:** <settings / data> (or "none")
## Links
- **Testing doc:** [open](<url>)
- **Sibling MRs:** <refs> (merge order: producers first)
```
The MR opens with `Testing doc: pending`; after the loop PASS, `devtools.py mr` with the link edits the same body. Merge refuses an MR with a task link and no `Testing doc: <url>` line.

## Task solution comment
```markdown
**Solution:** <what was wrong / built, and the fix>
**MRs:** <ref (MERGED|SCHEDULED|OPEN)> · **Local proof:** <env r<n>, goals passed>
**After deploy:** <settings/data to seed, or "nothing"> · **Deferred:** <item — reason, or "none">
```
A task has three kit comments, each edited in place: MRs (merge order; a status line once all merged), solution, QA result.
The testing doc links (human + AI) live only on top of the task description (`devtools.py finish`), never in a comment.

## Decision request
`bossy.ps1 decide ask` writes it to the contracts file; structured options feed the question tools (bossy E4).
```markdown
## DECISION NEEDED <id> (<agent>, item <item>)
**Question:** <which behaviour / design / data handling / migration strategy / UX>
**Blocking:** yes: item <item> waits (`-Fyi`: no)
| Option | Choice | Trade-off |
|---|---|---|
| A (recommended) | <label> | <trade-off> |
**Recommended:** <A, one line why>
**Answer:** pending
```

## Final reports (one shape per crew member, <= 200 words)
- **devy**: MRs + merge state · local test result (goals passed / rounds / ENV-FIX ids / blocked: decision or remote, why) · testing
  doc link · done / deferred / needs-decision ids · settings/data to seed · hooks left in other areas · disputes opened.
- **revy**: findings only (file/line or section, severity, the suggested change: patch hunk or rewritten text).
- **checky**: results.json (the workflow's schema); summary line per package; lead: the run report link and the result rule applied.
- **kitty**: branch + commits · fixed / proposed / ASK counts · report path · the lead's next steps.
