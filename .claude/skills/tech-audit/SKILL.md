---
name: tech-audit
description: >-
  Static technical audit of one module in any codebase/stack (web, API, mobile, desktop, Python, .NET, ...) for
  Bugs, Performance issues and Tech Debt, with strict false-positive discipline. Functional gaps / UX / reporting are
  captured but flagged out-of-scope. Produces findings in a fixed 23-key JSON schema plus a Markdown summary, ready for
  a findings workbook. Use when asked to "audit / review <module> for bugs / perf / tech debt", "find bugs in <module>",
  "health-check this module" or "generate findings". Not for testing deployed changes (that's qa-kit).
argument-hint: "<module> [project]"
---

# Technical audit (any project)

Produce a **rigorous, low-false-positive** list of technical improvement findings for **one module**, in the exact
schema the findings workbook consumes. The process is generic; project knowledge (repo layout, knowledge-base tools,
known by-design behaviours, past review lessons) lives in `reference/projects/<project>.md`.

> **Golden rule:** every finding is either (a) backed by evidence you can cite, or (b) explicitly marked as unverified
> inference. Never present a guess as a fact. A wrong finding wastes more time than a missing one.

**Audit vs QA:** this skill *reads* code, schema and data to find what's wrong in a module. To check that a deployed
change works on a test environment, use the `qa-kit` skill / `/test-and-close` instead.

---

## 0. Load the project profile

1. Find `reference/projects/<project>.md` for the codebase you're auditing (e.g. `my-product.md`).
   Read it fully: repo layout, intended-behaviour sources, **known by-design behaviours**, and **past review lessons**.
2. No profile yet? Copy `reference/projects/_template.md`, fill what you can from the repo's `CLAUDE.md`/README, and say so in the summary.
3. Identify each layer's stack: `& <workspace>/.claude/skills/dev-kit/scripts/stack.ps1 -Dir <module folder>`.

---

## 1. When to use / not use

**Use it when** the request is "audit / review / find bugs / find perf issues / find tech debt in `<module>`", or "generate findings".
**Do not use it for** building features, writing functional specs, product/UX design, or testing a deployment.
If you notice gaps/UX/reporting ideas, record them (§2) but do not analyse or champion them.

---

## 2. Scope — what counts as a finding

**In-scope (the focus) → `in_scope: "Yes"`.**
- **Bug** — **produces wrong output for a defined-correct input**: incorrect behaviour, broken validation the spec actually
  requires, concurrency/race, memory leak, crash, dead or wrong logic. **A schema absence is not a bug** — a missing column,
  FK, timestamp, type discriminator, unique constraint, or a nullable field used as designed is **Tech Debt** (if it
  demonstrably causes wrong results today) or **Functional Gap** (otherwise).
- **Performance** — N+1 / O(N) request patterns, leaked subscriptions/listeners, redundant renders / change detection,
  missing batch endpoints, missing indexes, oversized payloads, blocking I/O on hot paths, unbounded caches.
- **Tech Debt** — duplication, missing abstraction, type-safety gaps, dead code, inconsistent or fragile APIs, schema
  standardisation, risky patterns, outdated/vulnerable dependencies.

**Out-of-scope but captured → `in_scope: "No"`, `product_decision: "Yes"`**, analytical columns (`root_cause`, `why_today`,
`why_not_prod`, `customer_impact`) left blank: **Functional Gap**, **UX**, **Reporting**. Record so nothing is lost; no analysis.

Never invent net-new features. Technical improvement only.

---

## 3. Inputs — gather before writing findings

Use as many as available and **state which you used** in the summary. Strongest evidence first:

| Source | How (generic) | Gives you |
|---|---|---|
| **Live / test data** | Read-only queries against a test environment (DB MCP, `qa-kit/scripts/api.ps1` GETs, product MCP tools named in the profile) | Real data-quality issues (NULLs, orphans, misaligned values). Strongest evidence. Never production writes. |
| **Code** | Read real files in every layer of the module; cite `file:line` | The truth for bugs / perf / tech debt |
| **DB schema** | Migrations (Liquibase, EF Core, Flyway, Alembic, Django, raw SQL) + ORM entities | Missing constraints, columns, indexes, nullable fields |
| **API schema** | Controllers / routes / OpenAPI / GraphQL schema / DTOs | Contracts, missing batch ops, validation |
| **Intended behaviour** | Knowledge base / docs / settings named in the project profile, tracker decisions, memory | Whether something is a bug or by design |
| **History** | `git log --all --since=6.months --grep=<topic>`, `git branch -r --contains <commit>`, open MRs | Already fixed / in flight? Why is it like this? |

---

## 4. Process

1. **Map the module.** Where it lives across layers (UI / API / mobile / DB / jobs), its tables, endpoints, settings, key workflows. This is your coverage checklist.
2. **Walk each area** (settings, master data, each transaction stage, calculations, offline sync, reports, background jobs, API, schema). Ask: correct? performant? clean?
3. **Gather evidence** per candidate (code citation, schema fact, or a data query result). If you cannot verify, you may still record it — marked unverified (§5), lower severity.
4. **Write findings** in the schema (§6). One object per finding, unique id.
5. **Self-review against §5** and the project profile's by-design list and lessons. Drop or downgrade anything that fails.
6. **Validate and emit** (§7).

For a large module, split it by layer and run parallel read-only agents (one per layer), then merge and dedupe yourself
before the §5 self-review — never let parallel agents write ids.

---

## 5. False-positive discipline (the most important section)

**Pre-flight — run on every candidate before drafting it:**
1. Is the behaviour confirmed in code/data, or only inferred (screenshot, naming, a sample)? If inferred, prefix `current` with `(unverified)` and **cap severity at Medium**.
2. Does the knowledge base, a setting, a decision record or the profile's by-design list describe it as intended? If yes, it is not a Bug — move it to Tech Debt / Gap, or drop it.
3. Is it already addressed on an active branch or open MR? Check `git log --all --since=6.months --grep=<topic>` and `git branch -r --contains` on the module's files.
4. Is the field you call "missing" actually required by the spec for this record type? If the spec allows NULL, a NULL is not a bug.
5. Is it a schema absence (column / FK / timestamp / constraint / index)? Then Tech Debt at best, Functional Gap by default — **never a Bug** unless you can show wrong results today.

**Rules:**
- **Verify, don't assume.** Before claiming "X is missing/broken", grep for X across all layers and generated code.
- **Mark unverified inference.** `(unverified)` prefix, severity ≤ Medium; an entirely inferred root cause is never Critical.
- **By design ≠ bug.** Check intended-behaviour sources first; quote the rule you rely on in `existing_notes`.
- **Default-OFF is often deliberate.** Opt-in defaults for existing customers/tenants are product decisions: `product_decision: "Yes"` at most.
- **Config ≠ product bug.** A feature switched off or unconfigured in one environment/tenant is a config state; say so in `why_not_prod`.
- **NULL ≠ bug.** Confirm the field is required for this record type before flagging.
- **Don't double-count.** If a Bug and a Tech-Debt/Gap describe the same fix, keep the in-scope one and cross-reference the other in `existing_notes` ("Overlaps GAP-00X"). Never reuse an id.
- **Highly configurable modules need extra intended-behaviour checks** — consult the docs/KB *per finding* before drafting.

**Evidence tiers (highest first):** live data > code citation > schema/API > docs/KB inference. Note the tier per finding.

**Severity rubric (evidence-gated):**
- **Critical** — silent financial/data corruption, security breach, or outage. Requires code or live-data evidence; never on an inferred root cause.
- **High** — wrong results or data loss under normal use. Requires at least code or schema evidence.
- **Medium** — edge case, recoverable, or needs unusual input. Default when evidence is indirect.
- **Low** — cosmetic, latent, or on an unused path.

---

## 6. Output schema

Each finding is a JSON object with **exactly 23 keys**, all string values (`""` if unknown). Field definitions and allowed
values: **`reference/output-schema.md`**; an example: **`reference/example-finding.json`**.

```
id, module, layer, type, in_scope, subtype, title, area, severity,
current, expected, business_impact, root_cause, why_today, why_not_prod,
customer_impact, db_migration, suggested_fix, code_location,
product_decision, effort, existing_notes, source
```

Always fill the triage columns for in-scope findings:
- `why_today` — why the code is like this. Prefix `(inferred)` unless evidenced.
- `why_not_prod` — why it isn't visibly breaking production / how teams live with it. Prefix `(inferred)`. Be concrete.
- `db_migration` — `Yes` (schema change) / `No` (code only) / `Maybe`.

`product_decision: "Yes"` whenever a business call is needed first (a default, a business rule, anything customer-visible).

---

## 7. Deliverables

1. **`<output dir>/<module>.json`** — one JSON array of findings (output dir: the project profile's findings folder, else
   `<workspace>/.claude-runtime/audits/<project>/`). Validate:
   `python <workspace>/.claude/skills/tech-audit/scripts/validate.py <file>` → must print `schema problems: none`.
2. **Summary** — `python <workspace>/.claude/skills/tech-audit/scripts/summary.py <module>.json --sources "<what you used>"` writes
   `<module>-summary.md` (chat/MR) and a styled `<module>-summary.html` (severity chips, Critical/High, "Needs a product decision",
   all findings, out-of-scope) — publish the HTML with `dev-kit/scripts/devtools.py doc` when it goes to reviewers.
3. If the profile names a workbook generator, re-run it.
4. Optional hand-off: accepted in-scope Bugs can become tracker tasks and a bug-fix wave
   (`orchestrate` skill → `templates/BUGFIX_BRIEF.md`).

---

## 8. Review loop — how this skill improves

Reviewers mark each finding Accepted / Rejected / Needs Discussion / Duplicate. **When a finding is rejected as a false
positive, add the lesson to the project's profile** (`reference/projects/<project>.md` → "Known by-design behaviours" or
"Review lessons"). If the lesson applies to any codebase, add it to §5 here instead. Over time the profiles become each
team's memory of what *isn't* a real finding.
