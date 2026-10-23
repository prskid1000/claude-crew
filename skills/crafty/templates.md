# Templates (crafty)

Every brief, doc, body and report the flows fill. Copy the section you need into a file in the scratchpad or run folder,
fill the `<...>` parts, delete what does not apply. Which step fills which section: the Files index of the skill that uses it.

## Writing standards (every artefact the kit reads or writes)
The rules: AGENTS.md "Writing". Every limit is a ceiling, not a target. `kitbag.py prose --kind <kind> <file>` measures a text
(exit 1 = findings); the generators (`devtools.py mr/comment/finish`, `crafty.ps1 wt commit`, `bossy.ps1 bugbrief/decide`,
`pokey.ps1 finalize`) run it and print findings, never truncate. A finding is fixed by rewriting.
Limits: `Nw` words · `Nl` lines · `Nch` line width · `Nsw` words per sentence · `Nb` bullets · `each:` per `##` section ·
`<Section>:` that section (`_` for a space). Required facts: `link` URL / MR / PR ref · `id` task or check id · `path` file or `file:line` ·
`cmd` a command in backticks · `evidence` a screenshot / JSON / log path or link · `expected` an `Expected:` line ·
`options` A/B lines · `recommended` · `verdict` PASS / FAIL / BLOCKED · `conv` subject per `commitStyle` (default Conventional Commits).
Banned everywhere: greetings and thanks · "I hope" · "please note" · "it is worth noting" · "as mentioned" · "in summary" ·
"in conclusion" · "basically" · "simply" · "actually" · "really" · "very" · "successfully" · "feel free" · "let me know" ·
"happy to" · "great job" · "as an AI" · task recap · restating the template's own words.

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
| testing-goals | what must be true before merge | ## Goals, ## Test plan (automated), ## Data needed, ## Reproduction (bugs), ## Rounds | 700w Goals:20b each:8b | id expected |
| testing-doc | the human testing doc a tester follows | ## What changed, ## Before you start / Feature switches, ## Checks, ## Out of scope, ## Result (testers) | 1500w What_changed:80w 25sw | expected evidence |
| qa-report | the QA run report | header table, a verdict line per check, defects, not tested | 900w each:15b 25sw | id verdict evidence |
| result-note | a results.json `observed` / `what_was_done` | `<observed> vs <expected>; <evidence>` | 40w 1l | — |
| mr-title | MR / PR title | `<type>(<scope>): <change> (<task id>)` | 1l 90ch | conv |
| mr-body | MR / PR description | ## Summary, ## Changes, ## How tested, ## Risks, ## Links | 260w each:3b Summary:40w | link |
| commit | commit message | subject; blank line; body bullets | first:72ch 12l 100ch | conv |
| merge-commit | a merge commit (deploy merge, target into a branch) | subject naming both branches; blank line; why | 12l 100ch | — |
| task-name | tracker task name | `[Feature/Bug/Chore] <area> — <outcome>` | 1l 100ch | — |
| task-description | tracker task description | Problem, Goal, Acceptance (bullets), Links | 200w each:6b | link |
| comment-solution | solution comment on a task | the "Task solution comment" template | 8l 120w | link |
| comment-status | a status change note | `<status> — <why> · <link>` | 2l 40w | link |
| comment-deploy | a deploy record (+ the batched ask, only under `deploy.trigger` ask) | env, MRs (merge order), who said deploy, result | 8l 120w | link |
| decision-request | a decision the owner makes | the "Decision request" template | 120w 4b | options recommended |
| final-report | an agent's last reply | the "Final reports" shape of its role | 200w 25sw | link |
| owner-message | coordinator -> owner | result first, then the ask / next step | 150w 25sw 8b | — |
## Wave brief
```markdown
# Wave brief: <wave name>, <date>
Read <kit>/skills/crafty/SKILL.md first. This brief wins where they differ.
Items: <tracker epic / sheet>. Decisions: <decisions doc>; final, don't re-ask (a NEW choice -> a decision request, crafty D1).
Local env: <env name in kit.local.json localEnv, or "none: <why>">. Test env after deploy: <name> (never production).

| Repo | Main checkout | Target | Link deps from | Migrations |
|---|---|---|---|---|
| <repo> | `<repos root>/<repo>` | `main` | | <tool / none> |

| Agent | Items | Area (screens / packages / files) | Repos | Migration range | Services (leased, nothing else) | Complex? |
|---|---|---|---|---|---|---|
| X1 | <ids> | <area> | <repos> | <range or —> | <api; api-only items: no web> | <yes: why / no> |

Overlaps: <who touches what in a shared file>. Contracts: <field / endpoint X1 adds, X2 consumes after X1 merges>.
Branch `f/<tag><task>-<slug>`, worktree name = agent id. Tracker task under <epic> in <list>, assigned to <user>.
Rule changes during the wave are appended below and in <brief>.contracts.md: re-read both before every push.

## openQuestions
<question> · blocks <item> · answers: rechy | owner (or "none")
## Findings (rechy)
<the Spike phase appends one block per question>
## Rule changes during the wave (newest last)
```

## Bug-fix brief
`bossy.ps1 bugbrief -Task <id>` writes it (failed checks, evidence, repos). A bug brief adds to the wave brief:
```markdown
1. Read the bug: crafty.ps1 tracker view <id> + comments (the QA comment of a failedTesting task carries the failed and untested checks).
2. Reproduce LOCALLY first (envy SKILL.md "Debug locally"): the checks' steps on the local env, logs, DB state, debugger.
   Record steps + evidence in the testing-goals doc. Cannot reproduce locally -> say why, then reproduce on the test env.
3. Classify each check: real bug (root cause + regression test red before, green after) · stale deploy (name the missing commit)
   · expected (cite the decision) · config/data (what to set where).
4. Fix, then re-run the same reproduction as the first local check; then the full testing goals.
5. Final reply: verdict + root cause per check, MRs, local proof, human testing doc link.
```

## Resume brief
```markdown
A stopped agent's work is in worktrees <root>/<prefix>-*. Join the board with its id + -Resume (TAKEOVER, not DUPLICATE).
Before editing: crafty.ps1 wt status -Dir <wt> per worktree, the task + comments, open/merged MRs of the branch. Continue where it
stopped (testing goals, local test loop, MRs); never redo finished work. Files changing under you = another writer: stop, report.
```
`bossy.ps1 recover` adds one table per area: each item's done steps (skipped) and missing steps (run), MRs, tracker, testing doc.

## Testing goals
Written by devy BEFORE testing (crafty step 4); the local test loop runs it; the human testing doc grows out of it.
```markdown
# Testing goals: <task id> <title>
Change: <one line, user terms>. Repos/MRs: <refs>. Local env: <env> r<n> (envy.ps1 status), services <the leased ones>.
## Goals (what must be true)
| # | Goal | Check (steps) | Expected | Proof: automated test / local manual check | Result |
|---|---|---|---|---|---|
| G1 | <behaviour> | <steps> | <exact values, messages, status codes> | `<TestClass#method>` / api.ps1 / browser / phone | |
| U1 | <unchanged behaviour that must stay> | | | | |
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

## Human testing doc
Published at crafty step 6 (`devtools.py doc`), linked on the task and in the MR; testers follow it (pokey H1-H3).
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
| Setting or role | Where | Must be | How to switch | Restore after |
|---|---|---|---|---|
## Checks
### T1 — <screen / area>
**Steps:** 1. <step> 2. <step>
**Expected:** <exact result, read from the shipped code (final diff), never the brief or bug text; a timing from a measurement>
**Proven locally:** <screenshot / JSON from the local loop, or "not provable locally: <why>" (needsLiveCheck); never claim a pass>
### R1 — <unchanged behaviour> (regression)
## Out of scope
- <not to test, why> · a step that only exercises a channel in qa.outOfScope: "(out of scope for agent QA: <channel>)"
## Result (testers)
All checks pass -> close the task. A check of this change fails or could not be tested -> failedTesting with the check ids
and why. A defect outside this change -> one [Bug] task under the original ask.
```

## MR body
`devtools.py mr` checks it (kind `mr-body`): sections in this order, limits from "Writing standards".
```markdown
## Summary
<task URL> — <one-line goal and outcome>
## Changes
- <behaviour change, user terms> · Technical: <files / endpoints / migrations>
## How tested
- Checks: check quick ✅ · tests `<names>` ✅ · touched-class tests ✅ · migrations ISSUES 0 ✅
- Local env: <env> r<n>: goals G1-Gn PASS (testing-goals doc) · Not run: <what, why> (or "nothing")
- UI: <committed spec or screenshot link> (or "not a UI change") · Pure logic: <spec file> (or "none")
- Regression: `<test>` red before the fix, green after (or "not a fix") · Changed methods without a test: <names> (or "none")
## Risks
- <deferred item — reason> · Behaviour limits: <not handled> · Needs after deploy: <settings / data> (or "none")
## Links
- Testing doc: <link> · Sibling MRs: <refs> (merge order: producers first)
```

## Task solution comment
```markdown
**Solution** — <what was wrong / built, and the fix>
**MRs**: <ref (MERGED|SCHEDULED|OPEN)> · **Local proof**: <env r<n>, goals passed> · **Testing doc**: <link>
**After deploy**: <settings/data to seed, or "nothing"> · **Deferred**: <item — reason, or "none">
```

## Decision request
Written by `bossy.ps1 decide ask` into the contracts file; the coordinator relays it, the owner answers.
```markdown
## DECISION NEEDED <id> (<agent>, item <item>)
<the question: which behaviour / design / data handling / migration strategy / UX>
Options:
- A: <option> — <trade-off>
- B: <option> — <trade-off>
Recommended: <A/B, one line why>
Answer: pending
```

## Final reports (one shape per crew member, <= 200 words)
- **devy**: MRs + merge state · local test result (goals passed / rounds / ENV-FIX ids / blocked: decision or remote, why) · testing
  doc link · done / deferred / needs-decision ids · settings/data to seed · hooks left in other areas · disputes opened.
- **revy**: findings only (file/line or section, severity, the suggested change: patch hunk or rewritten text).
- **checky**: results.json (the workflow's schema); summary line per package; lead: the run report link and the result rule applied.
- **kitty**: branch + commits · fixed / proposed / ASK counts · report path · the lead's next steps.
