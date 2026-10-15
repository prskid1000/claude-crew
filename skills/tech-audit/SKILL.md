---
name: tech-audit
description: "Load when: asked to audit, review or health-check one module's code for bugs, performance or tech debt, or to generate findings, without changing code or a deploy to test. Not when: reviewing an agent's open MRs -> mr-reviewer agent; testing deployed changes -> qa-kit; fixing the findings -> dev-kit or /dev-wave via orchestrate."
argument-hint: "<module> [project]"
---

**Load when** (all must hold): the target is one module (a folder, feature or service) of any codebase; the output is findings,
not
code changes.
**Not when:** an agent's open MRs -> `mr-reviewer`; a deployed change -> `qa-kit`; fixing the findings -> `dev-kit` /
`/dev-wave`.
**Hands off to:** the person reviewing the findings; accepted ones become a wave brief (`orchestrate` step 2) or bug tasks;
rejected false positives go back into the project profile (step 9).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill tech-audit` |
| `reference/projects/<project>.md` | step 1, read fully (local overlay: one profile per project, `localOnly`; shape: "Project profile" below) |
| `tech-audit.py` | step 8: `validate <file>` (must print `schema problems: none`), `summary <file> --sources "..."` (.md + .html) |

> **Golden rule:** every finding is backed by evidence you can cite, or explicitly marked as unverified inference. A wrong
finding
> wastes more time than a missing one.

## Steps
0. `orch.ps1 learn -Read -Skill tech-audit`.
1. **Profile:** read `reference/projects/<project>.md`; none yet -> write one from "Project profile" below and say so. Stack per
   layer: `dev.ps1 stack -Dir <module folder>`.
2. **Scope:** in scope (`in_scope: "Yes"`) = **Bug** (wrong output for a defined-correct input: logic, required validation,
   race,
   leak, crash), **Performance** (N+1, leaked listeners, redundant renders, missing batch/index, oversized payloads, blocking
   I/O,
   unbounded caches), **Tech Debt** (duplication, type gaps, dead code, fragile APIs, schema standardisation, risky patterns,
   old or
   vulnerable deps). A schema absence (column, FK, timestamp, constraint, index) is never a Bug. Functional Gap / UX /
   Reporting:
   `in_scope: "No"`, `product_decision: "Yes"`, analysis columns blank. Never invent features.
3. **Gather** (state what you used), strongest first: live/test data (read-only) > code (`file:line`) > DB/API schema > docs >
   git history.
4. **Map the module** across layers, walk each area (settings, master data, transactions, calculations, sync, reports, jobs,
   API,
   schema), gather evidence per candidate, write findings, self-review, validate. Large module: one read-only agent per layer,
   you
   merge, dedupe and assign ids.
5. **False-positive pre-flight, every candidate:** (1) confirmed in code/data? inferred -> `current` starts `(unverified)`,
   severity <= Medium; (2) described as intended by docs / a setting / a decision / the by-design list? -> not a Bug; (3)
   already
   fixed on a branch or open MR (`git log --all --since=6.months --grep=<topic>`)? (4) is the "missing" field required for this
   record type (NULL != bug)? (5) schema absence -> Tech Debt at best. Also: grep all layers before "missing"; default-OFF is
   often
   deliberate (`product_decision: "Yes"`); config state != product bug; don't double-count ("Overlaps GAP-00X").
6. **Severity (evidence-gated):** Critical = silent financial/data corruption, security breach, outage (code or live-data
   evidence
   only); High = wrong results / data loss in normal use (code or schema evidence); Medium = edge case, recoverable, indirect
   evidence; Low = cosmetic / latent.
7. **Output:** one JSON array; each finding exactly these 23 string keys (`""` when unknown):

| Key | Format |
|---|---|
| `id` | `<MODULE>-<BUG\|PERF\|REF\|GAP\|UX\|RPT>-NNN` |
| `module`, `area`, `title`, `subtype`, `source` | short text (`subtype` e.g. Data Integrity, Validation, Concurrency, Memory leak, Schema/Migration) |
| `layer` | `Web UI` \| `Java API` \| `.NET API` \| `Python` \| `Node API` \| `Mobile` \| `Desktop` \| `DB` \| `Jobs` \| `Integration` \| `Cross-cutting` (or the profile's own) |
| `type` | `Bug` \| `Performance` \| `Tech Debt` \| `Functional Gap` \| `UX` \| `Reporting` |
| `in_scope` | `Yes` (Bug / Performance / Tech Debt) \| `No` |
| `severity` | `Critical` \| `High` \| `Medium` \| `Low` |
| `current`, `expected`, `suggested_fix` | 1-2 sentences (`current` prefixed `(unverified)` when inferred) |
| `business_impact`, `root_cause`, `customer_impact` | 1 sentence (in scope only) |
| `why_today`, `why_not_prod` | in scope only, prefixed `(inferred)` unless evidenced; concrete |
| `db_migration` | `Yes` \| `No` \| `Maybe` |
| `code_location` | `file:line`, table or endpoint |
| `product_decision` | `Yes` \| `No` |
| `effort` | `Low` \| `Medium` \| `High` \| `""` |
| `existing_notes` | prior comments, links, cross-refs, the evidence tier |

8. **Deliver:** `<module>.json` in the profile's findings folder (else `<runtime>/work/audits/<project>/`); `python -X utf8
   tech-audit.py validate <file>` = `schema problems: none`; `python -X utf8 tech-audit.py summary <file> --sources "<what you
   used>"`; publish the HTML with `devtools.py doc` when it goes to reviewers.
9. **Review loop:** a finding rejected as a false positive -> one line in the profile ("Known by-design" / "Review lessons");
   a lesson for any codebase -> `orch.ps1 learn -Skill tech-audit -Lesson "..."`.

## Project profile (`reference/projects/<project>.md`, local)
```markdown
# Project profile: <name>
## Repo layout
| Layer | Repo / folder | Stack (dev.ps1 stack) | Notes (migration tool, single- or multi-tenant, ...) |
## Intended-behaviour sources
- docs / knowledge base / MCP tools / decision records
## Live / test data (read-only)
- how to query a test environment; never production writes
## Findings output
- folder, id prefix, workbook generator (if any)
## Known by-design behaviours (not bugs)
## Review lessons
```

Example finding: `{"id": "NOTIF-BUG-002", "module": "Notifications", "layer": "Node API", "type": "Bug", "in_scope": "Yes",
"subtype": "Data Integrity", "title": "Digest emails ignore the user's unsubscribe flag", "area": "Settings / Email
preferences",
"severity": "High", "current": "Opted-out users still receive the weekly digest.", "expected": "Opted-out users never receive
it.",
"business_impact": "Unwanted email to users who opted out.", "root_cause": "The digest job never reads the per-user flag.",
"why_today": "(inferred) The flag was added after the job.", "why_not_prod": "(inferred) Few users opted out so far.",
"customer_impact": "Opted-out users keep getting the digest.", "db_migration": "No", "suggested_fix": "Filter on the opt-out
flag; add a test.",
"code_location": "DigestJob.buildRecipients()", "product_decision": "No", "effort": "Low", "existing_notes": "Evidence: 3 of 3
opted-out test users got it.", "source": "module review"}`
