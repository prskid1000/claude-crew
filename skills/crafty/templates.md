# Templates (crafty)

Copy a section, fill the `<...>` parts; which step fills which: the using skill's Files index.

## Writing standards (every artefact the kit reads or writes)
Rules: AGENTS.md "Writing"; every limit is a ceiling. `skills/bossy/kitbag.py prose --kind <kind> <file>` measures a text (exit 1 =
findings); the generators (`devtools.py mr/comment/finish`, `crafty.ps1 wt commit`, `bossy.ps1 bugbrief/decide`,
`pokey.ps1 finalize`) run it, print findings, never truncate; fix by rewriting. Listed `##` sections: always, in
order, never empty or bare "none": `n/a — <why>` (prose; `devtools.py doc` / `finish` refuse a doc without).
Limits: `Nw` words · `Nl` lines · `Nch` line width · `Nsw` words per sentence · `Nb` bullets · `each:` per `##` section ·
`<Section>:` that section (`_` for a space) · `prose:` without table rows (cells: their own kind) and image lines. Required facts: `link` URL / MR / PR ref · `id` task or check id · `path` file or `file:line` ·
`cmd` a command in backticks · `evidence` a screenshot / JSON / log path or link · `expected` an `Expected:` line ·
`options` A/B lines · `recommended` · `verdict` PASS / FAIL / BLOCKED · `conv` subject per `commitStyle` (default Conventional Commits).
Banned everywhere: greetings, thanks · "I hope" · "please note" · "it is worth noting" · "as mentioned" · "in summary" ·
"in conclusion" · "basically" · "simply" · "actually" · "really" · "very" · "successfully" · "feel free" · "let me know" ·
"happy to" · "great job" · "as an AI" · task recap · restating template words.
Markdown: commands, paths, class names, config keys and ids in `backticks` (monospace; nothing else is guessed); labels
`**Label:**`; links `[text](url)`; a blank line between blocks; plain-text trackers: the adapter drops markup.

| Kind | Purpose | Format (sections in order) | Limits | Required facts |
|---|---|---|---|---|
| skill | how an agent does one job | front matter, Load when, Not when, Hands off to, Files, numbered steps, Rules, Learn | 3000t 130ch | path |
| skill-step | one numbered step | `N. **Name:** action -> result` + commands | 90w 30sw | cmd |
| agent | an agent's contract (a crew member holds its own steps) | front matter, Character, Kind, Load first, non-negotiables, report shape, self-improvement | 2400t 130ch | path |
| rule | a hard rule for one file kind | `paths:` front matter (path-scoped), bullets | 900t 12b 130ch | — |
| reference | a guide inside a SKILL.md / README | `##` per topic, bullets, tables | each:250w 130ch | path |
| lesson | one LESSONS.md line | `- <when> -> <do this> (<why>)` | 1l 50w 300ch | — |
| history | one retired lesson (`learn -History`; an older LESSONS.local.md `## History`) | `- <date> <what was retired / merged> -> <where it lives now>` | 1l 50w 300ch | — |
| wave-brief | what a wave builds, by whom | ## Repos, ## Agents, ## openQuestions, ## Findings (rechy), ## Rule changes during the wave (newest last) | 600w each:12b 130ch | id path |
| spec | a task's or subject's spec ("Spec") | every section always: answered, `n/a — <why>` or its open question; S-id rules + acceptance; change log | 2500w 130ch | id |
| bug-brief | one bug to fix | the "Bug-fix brief" template + failed checks + evidence | 350w 130ch | id evidence |
| testing-goals | local goals file, never published (`cases render goals`) | ## Goals, ## Test plan (automated), ## Data needed, ## Reproduction (bugs), ## Rounds | 700w Goals:20b each:8b | id expected |
| testing-doc | the human testing doc (positive UI cases; a screenshot each; `cases render human`) | ## What changed, ## Before you start / Feature switches, ## Checks, ## Out of scope, ## Result (testers) | 1500w What_changed:80w 25sw | expected |
| testing-ai | the AI testing doc (the local loop record; `cases render ai`) | setup line, case table, Rounds table | 2500w 25sw | expected |
| qa-report | the QA run report (an "<env> run" section of the human doc) | header table, ## Tasks, ## Results, ## Failures in detail, ## Notes, ## Setup changes and test data, ## Evidence index | prose:900w each:15b 25sw | id verdict evidence |
| result-note | a results.json `observed` / `what_was_done` | `<observed> vs <expected>; <evidence>` | 40w 1l | — |
| mr-title | MR / PR title ("MR spec") | keyed task: `<type>(<scope>): <change> [<KEY>]`; else `mrTitleFormat`, default `<type>(<scope>): <change> (<task id>)` | 1l 90ch | conv |
| mr-body | MR / PR description | ## Summary, ## Changes, ## How tested, ## Risks, ## Links | 260w each:3b Links:9b Summary:40w | link |
| commit | commit message ("MR spec") | `commitFormat` subject; blank line; body bullets | first:72ch 12l 100ch | conv |
| merge-commit | a merge commit (deploy merge, target into a branch) | subject naming both branches; blank line; why | 12l 100ch | — |
| task-name | tracker task name (`tracker create`: `naming make title`) | `<KEY> <outcome>`; kind, product, area, wave: tags (`naming tags`); DUP-WORDS | 1l 100ch | — |
| task-description | tracker task text (`tracker create -Spec`; <= 170w: `finish` adds links) | Problem, Goal, Items, Acceptance, Links | 200w each:6b | link |
| comment-solution | solution comment on a task | "Comment spec" | 8l 120w | — |
| comment-status | a status change note ("Comment spec") | `<status> — <why> · <link>` | 2l 40w | link |
| comment-deploy | a deploy record (+ the batched ask under `deploy.trigger` ask) | env, MRs (merge order), who said deploy, result | 8l 120w | link |
| decisions | a task's Decisions checklist | `decide publish`: `<id> · <question> → <answer> · <by> <MM-dd>`, open unresolved | 80l 600ch | — |
| decision-request | a decision the owner makes | the "Decision request" template | 120w 4b | options recommended |
| kit-report | supervise report, retro, lead notes, resume brief | `# <title>`, a `**Result:**` line, `##` sections, tables for like items | prose:400w 130ch | — |
| retro | the /tidy retro (`render retro`) | ## Changed, ## Awaiting approval, ## Rejected | prose:400w 130ch | — |
| runbook | an ops procedure (deploy, restore, rollback) | ## Purpose, ## Preconditions, ## Steps, ## Verify, ## Rollback | 800w 130ch | cmd |
| final-report | an agent's last reply | the "Final reports" JSON of its role (`render final-report`) | 200w 25sw | link |
| owner-message | coordinator -> owner | result first, then the ask / next step | 150w 25sw 8b | — |
## Wave brief
Rendered (`devtools.py render wave-brief <spec.json> <brief.md>` + `.contracts.md` `.args.json` `.order.json`). Spec: `{ name, date?,
items, decisions, localEnv, testEnv, kitDir, repos: [{ repo, checkout, target, linkFrom, migrations }], agents: [{ id (ask-prompts), items, area, paths (globs),
repos, migrationRange, services, complex, note?, dependsOn?, migrations?, model?, effort?, debate?, task? }], task?, overlaps, branch, tracker,
contracts: [{ name, type, producer, consumers, order, compatible }], openQuestions: [{ question, blocks, answers }], mandate, mode,
holdMerge?, wave? }`.
Layout: the renderer (`**Specs:**` links each task's spec); `name` titles it, `run` the /buildy run.

## Spec
Rendered, never hand-written: `devtools.py spec write <task|subject> <spec.json>` (`spec --help`; sections per kind:
`spec template <kind>`); one per task (its Spec line) or a subject spec tasks link (`spec link`). S-ids (`S<n>`, never
reused): cases cite them, MR / commit specs list `specIds`; finish refuses an uncited one (`spec trace`) and a feature /
subject with no diagram (or `n/a — <why>`). A `change` line -> v<n+1>, a change-log row (S-ids touched), `RETEST` on their
tasks; a draft spec refuses the wave brief.

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
Rendered, never hand-written: `bossy.ps1 recover` (crash) or, at a budget HANDOFF, `crafty.ps1 checkpoint -Agent <id> -Run <run>
-Step <last done> -Next <step> -Notes '<one line>' -Brief <the path HANDOFF names>` (Done table with evidence and worktree @ head,
Open: worktrees, leases, pending decisions, Notes). The next agent joins with the same id + `-Resume` (TAKEOVER), leases
each branch again (`crafty.ps1 wt lease -Branch <b>`: the slot that has it) + `wt status`, reads the task and its MRs;
files changing under it: stop, report.
`<run>.resume.md`: per area, done (skip) / missing (run) steps, MRs, tracker, doc.

## Test cases (goals file, AI doc, human doc)
devy writes ONE spec per task (crafty step 4), never the three docs: `devtools.py cases add <task> <spec.json>` (merged by id),
each loop round `cases result <task> <id> PASS|FAIL|NOT_TESTED_LOCAL <file>=<evidence link> ...` (the link reads as its type: json, screenshot, log) + `cases round <task> --fix <sha>
--bugs "<what>"`; `cases render <task> goals|ai|human` prints the file (goals: local, never published). Publish: `devtools.py doc
"<title>" cases --key <task>:testing-ai --label "round <n>"` each round; after the loop PASS `devtools.py finish <task> cases
solution.md review --ai cases`.
```json
{ "title": "", "change": "<one line, user terms>", "repos": ["<refs>"], "env": "<env> r<n>", "services": "<leased>", "setup": "<data via the API, prefixed; cleanup>",
  "data": "", "repro": "<bugs: steps, logs, DB state>", "plan": { "unit": "", "regression": "", "api": "", "ui": "", "run": "" }, "matrix": "<qa.matrix line>",
  "checks": [{ "id": "T1", "area": "<screen>", "steps": "1. <click / type> 2. ...", "expected": "<exact text on screen>", "noUi": "<only: no UI trigger (job, inbound feed); steps = where its effect shows>" }],
  "qualities": [{ "id": "Q1", "goal": "<'prominent', '< 10 s'>", "how": "<contrast(), 5 timings>", "rule": "<p95 <= 10 s>" }], "unchanged": [{ "id": "U1", "goal": "" }],
  "cases": [{ "id": "A1", "type": "positive|negative|edge|regression|repro", "check": "T1", "steps": "<API call + payload / screen, selector>", "expected": "", "result": "", "evidence": ["<link>"] }],
  "switches": [{ "setting": "", "where": "", "value": "" }], "outOfScope": [{ "item": "", "why": "" }], "tasks": "", "environment": "", "logins": "<keys>", "testData": "", "whatChanged": "" }
```
The gates judge the rendered text: `checks` = the human doc (`| # | UI steps | Expected on screen | Screenshot | Extra evidence |
Result |`), POSITIVE only, from the request (task, acceptance, stated qualities), never the code; driven from the UI (owner
2026-11-20): what a person clicks or types and sees, a backend change through the UI action that triggers it, no endpoints, payloads
or code names (refused); a screenshot per check, request / response JSON only from that action (network or app log) as extra;
Screenshot / Extra evidence / Result empty (an env run fills them: pokey finalize or a person, a dated "<env> run" section); `cases` = every
positive, negative, edge and regression case (invalid input, role denials, boundaries, empty data, concurrency, nearby features,
impact edges), each human check run by a case naming it (`check`); a bug fix: a `repro` case (`process.gates.bugFix` `builtin:reproRow`: merge refuses without); UI cases at
every `qa.matrix` variant (`matrix`); a failing case is FAIL, never "pre-existing"; a `qa.notLocal` stub path NOT_TESTED_LOCAL,
never PASS; a result needs an evidence link (screenshot, request / response JSON, run output: `devtools.py evidence`).

## MR spec (title, body, commit)
One spec renders the MR title (`mrTitleFormat`), body (Summary, Changes, How tested table, Risks, Links) and the commit
(`commitFormat` subject + change bullets + trailers): `devtools.py mr <wt> --spec mr.json`, `crafty.ps1 wt commit -Dir <wt>
-Spec mr.json`; `devtools.py render mr-title|mr-body|commit mr.json` reads it first. Local env row: the loop checkpoint
(`checkpoint -Step loop -Evidence`) unless `localEnv`; testing doc lines: `devtools.py finish` (`builtin:testingDocs`: merge refuses without).
Limits (`devtools.py mr` refuses more): body 260 words, **max 3 bullets per section** (`changes` 3; `risks` 1, +
`limits` + `afterDeploy`; Links 9), Summary 40 words; title 90 chars; commit subject 72 chars, lines 100 chars.
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
renders `<status> — <why> · <link>`. MR and task refs in a comment or MR body: full URLs (MR: `[repo!n](<url>)`, host `mr.url`). Kit comments, one per kind, edited: solution, QA result (MR URLs: Items); doc links: crafty "Tracker".

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

## Final reports (one JSON shape per crew member, <= 200 words)
The last reply is at most 10 lines, then one fenced `json` block, `role` first; the coordinator reads it with `devtools.py render final-report <file>`.
Before it: stop every Monitor and background shell you started (by its id; supervise flags leftovers).
- **devy**: `{ "role": "devy", "agent", "mrs": [{ "url", "state" }], "localTest": { "status", "rounds", "envFix": [], "blocked" },
  "doc": "<testing doc link>", "done": [], "deferred": [], "needsDecision": [], "seed": "<settings / data>", "hooks": [], "disputes": [] }`
- **revy**: `{ "role": "revy", "findings": [{ "where": "<file:line | section>", "severity", "change": "<patch hunk | rewritten text>" }] }`
- **checky**: `{ "role": "checky", "summary": ["<a line per package>"], "report": "<lead: run report link>", "rule": "<result rule applied>",
  "results": "<results.json path>" }`
- **kitty**: `{ "role": "kitty", "branch", "commits": [], "fixed": 0, "proposed": 0, "ask": 0, "report": "<path>", "next": [] }`
- any other: `{ "role", "agent", "result": "<one line>", "links": [], "next": [] }`
