# Templates (crafty)

Copy a section, fill the `<...>` parts, drop what does not apply; which step fills which: the using skill's Files index.

## Writing standards (every artefact the kit reads or writes)
Rules: AGENTS.md "Writing"; every limit is a ceiling. `kitbag.py prose --kind <kind> <file>` measures a text (exit 1 =
findings); the generators (`devtools.py mr/comment/finish`, `crafty.ps1 wt commit`, `bossy.ps1 bugbrief/decide`,
`pokey.ps1 finalize`) run it, print findings, never truncate; fix a finding by rewriting.
Limits: `Nw` words · `Nl` lines · `Nch` line width · `Nsw` words per sentence · `Nb` bullets · `each:` per `##` section ·
`<Section>:` that section (`_` for a space) · `prose:` without table rows (cells: their own kind) and image lines. Required facts: `link` URL / MR / PR ref · `id` task or check id · `path` file or `file:line` ·
`cmd` a command in backticks · `evidence` a screenshot / JSON / log path or link · `expected` an `Expected:` line ·
`options` A/B lines · `recommended` · `verdict` PASS / FAIL / BLOCKED · `conv` subject per `commitStyle` (default Conventional Commits).
Banned everywhere: greetings, thanks · "I hope" · "please note" · "it is worth noting" · "as mentioned" · "in summary" ·
"in conclusion" · "basically" · "simply" · "actually" · "really" · "very" · "successfully" · "feel free" · "let me know" ·
"happy to" · "great job" · "as an AI" · task recap · restating template words.
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
| testing-goals | local goals file, never published (`cases render goals`) | ## Goals, ## Test plan (automated), ## Data needed, ## Reproduction (bugs), ## Rounds | 700w Goals:20b each:8b | id expected |
| testing-doc | the human testing doc (positive cases; env evidence; `cases render human`) | ## What changed, ## Before you start / Feature switches, ## Checks, ## Out of scope, ## Result (testers) | 1500w What_changed:80w 25sw | expected |
| testing-ai | the AI testing doc (the local loop record; `cases render ai`) | setup line, case table, Rounds table | 2500w 25sw | expected |
| qa-report | the QA run report (an "<env> run" section of the human doc) | header table, Tasks table, Results table (Check, Result, Observed, Evidence: images inline), failures in detail | prose:900w each:15b 25sw | id verdict evidence |
| result-note | a results.json `observed` / `what_was_done` | `<observed> vs <expected>; <evidence>` | 40w 1l | — |
| mr-title | MR / PR title ("MR spec") | `mrTitleFormat`, default `<type>(<scope>): <change> (<task id>)` | 1l 90ch | conv |
| mr-body | MR / PR description | ## Summary, ## Changes, ## How tested, ## Risks, ## Links | 260w each:3b Summary:40w | link |
| commit | commit message ("MR spec") | `commitFormat` subject; blank line; body bullets | first:72ch 12l 100ch | conv |
| merge-commit | a merge commit (deploy merge, target into a branch) | subject naming both branches; blank line; why | 12l 100ch | — |
| task-name | tracker task name | `[Feature/Bug/Chore] <area> — <outcome>` | 1l 100ch | — |
| task-description | tracker task text (`tracker create -Spec`) | Problem, Goal, Items, Acceptance, Links | 200w each:6b | link |
| comment-solution | solution comment on a task | "Comment spec" | 8l 120w | — |
| comment-status | a status change note ("Comment spec") | `<status> — <why> · <link>` | 2l 40w | link |
| comment-deploy | a deploy record (+ the batched ask under `deploy.trigger` ask) | env, MRs (merge order), who said deploy, result | 8l 120w | link |
| decisions | a task's Decisions checklist | `decide publish`: `<id> · <question> → <answer> · <by> <MM-dd>`, open unresolved | 80l 600ch | — |
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
`bossy.ps1 bugbrief -Task <id>` writes it (failed checks, evidence, repos), added to the wave brief:
```markdown
1. Read the bug: crafty.ps1 tracker view <id> + comments (the QA comment lists failed and untested checks).
2. Reproduce LOCALLY first (envy SKILL.md "Debug locally"): the checks' steps, logs, DB state, debugger -> goals doc + AI doc
   `repro` row. Not reproducible locally -> say why, reproduce on the test env.
3. Classify each check: real bug (root cause + regression test red before, green after) · stale deploy (name the missing commit)
   · expected (cite the decision) · config/data (what to set where).
4. Fix, then re-run the same reproduction as the first local check; then the full testing goals.
5. Final reply: verdict + root cause per check, MRs, local proof, human testing doc link.
```

## Resume brief
`bossy.ps1 recover` (crash) or a budget handoff writes it. The next agent joins with the same id + `-Resume`
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
`<run>.resume.md`: per area, done (skipped) / missing (run) steps, MRs, tracker, doc.

## Test cases (goals file, AI doc, human doc)
devy writes ONE spec per task (crafty step 4), never the three docs: `devtools.py cases add <task> <spec.json>` (merged by id),
each loop round `cases result <task> <id> PASS|FAIL|NOT_TESTED_LOCAL <evidence link> ...` + `cases round <task> --fix <sha>
--bugs "<what>"`; `cases render <task> goals|ai|human` prints the file (goals: local, never published). Publish: `devtools.py doc
"<title>" cases --key <task>:testing-ai --label "round <n>"` each round; after the loop PASS `devtools.py finish <task> cases
solution.md review --ai cases`.
```json
{ "title": "", "change": "<one line, user terms>", "repos": ["<refs>"], "env": "<env> r<n>", "services": "<leased>", "setup": "<data via the API, prefixed; cleanup>",
  "data": "", "repro": "<bugs: steps, logs, DB state>", "plan": { "unit": "", "regression": "", "api": "", "ui": "", "run": "" }, "matrix": "<qa.matrix line>",
  "checks": [{ "id": "T1", "area": "<screen>", "steps": "1. <step> 2. <step>", "expected": "<exact, from the shipped code>" }],
  "qualities": [{ "id": "Q1", "goal": "<'prominent', '< 10 s'>", "how": "<contrast(), 5 timings>", "rule": "<p95 <= 10 s>" }], "unchanged": [{ "id": "U1", "goal": "" }],
  "cases": [{ "id": "A1", "type": "positive|negative|edge|regression|repro", "check": "T1", "steps": "<API call + payload / screen, selector>", "expected": "", "result": "", "evidence": ["<link>"] }],
  "switches": [{ "setting": "", "where": "", "value": "" }], "outOfScope": [{ "item": "", "why": "" }], "tasks": "", "environment": "", "logins": "<keys>", "testData": "", "whatChanged": "" }
```
The gates judge the rendered text: `checks` = the human doc, POSITIVE only, from the request (task, acceptance, stated qualities), never the
code, Result / Evidence empty (an env run fills them: pokey finalize or a person, a dated "<env> run" section); `cases` = every
positive, negative, edge and regression case (invalid input, role denials, boundaries, empty data, concurrency, nearby features,
impact edges), each human check run by a case naming it (`check`); a bug fix: a `repro` case (merge refuses without); UI cases at
every `qa.matrix` variant (`matrix`); a failing case is FAIL, never "pre-existing"; a `qa.notLocal` stub path NOT_TESTED_LOCAL,
never PASS; a result needs an evidence link (screenshot, request / response JSON, run output: `devtools.py evidence`).

## MR spec (title, body, commit)
One spec renders the MR title (`mrTitleFormat`), body (## Summary, ## Changes, ## How tested table, ## Risks, ## Links) and the
commit (`commitFormat` subject + change bullets + trailers): `devtools.py mr <wt> --spec mr.json`, `crafty.ps1 wt commit -Dir <wt>
-Spec mr.json`, `devtools.py render mr-title|mr-body|commit mr.json` to read it first. Local env row: the loop checkpoint
(`checkpoint -Step loop -Evidence`) unless `localEnv`; the testing doc lines: `devtools.py finish` (merge refuses without).
```json
{ "task": "<id>", "type": "feat|fix|refactor", "scope": "", "change": "<subject>", "code": "<item code>", "repo": "", "summary": "<one-line goal and outcome>",
  "changes": [{ "text": "<behaviour change, user terms>", "technical": "<files / endpoints / migrations>" }],
  "checksRun": [{ "name": "check quick | tests <names> | migrations", "result": "PASS" }], "notRun": "<what, why>", "ui": "<spec or screenshot link>",
  "pureLogic": "<spec file>", "regression": "<test> red before, green after; untested changed methods", "risks": [{ "text": "<deferred item — reason>" }],
  "limits": "", "afterDeploy": "<settings / data>", "siblings": ["<refs, producers first>"], "trailers": ["<org / harness trailer lines>"] }
```

## Comment spec
`devtools.py comment <task> --spec c.json [comment-solution|comment-status]`; `finish <task> ... c.json` (a .json = this spec).
comment-solution `{ "solution": "<what was wrong / built, and the fix>", "mrs": ["<ref (MERGED|OPEN)>"], "localProof": "", "afterDeploy":
"", "deferred": "<item — reason>" }` (mrs: the task's tracking, localProof: the loop checkpoint when left out) renders `**Solution:**
...` / `**MRs:** ... · **Local proof:** ...` / `**After deploy:** ... · **Deferred:** ...`; comment-status `{ "status", "why", "link" }`
renders `<status> — <why> · <link>`. Kit comments, one per kind, edited: solution, QA result (MR URLs: Items); doc links: crafty "Tracker".

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
