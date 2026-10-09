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


# Quick start (technical audit of one module, any project)

Produce a **rigorous, low-false-positive** list of technical findings (Bug / Performance / Tech Debt) for **one module**, in the exact
23-key schema the findings workbook consumes. Not for testing deployments (that's `qa-kit`).
> **Golden rule:** every finding is backed by evidence you can cite, or explicitly marked as unverified inference. A wrong finding wastes more time than a missing one.

1. **Profile:** read `reference/projects/<project>.md` fully (layout, intended-behaviour sources, known by-design behaviours, review
   lessons); none yet → copy `reference/projects/_template.md` and say so. Stack per layer: `dev-kit/scripts/stack.ps1 -Dir <module folder>`.
2. **Scope:** in scope (`in_scope: "Yes"`) = **Bug** (wrong output for a defined-correct input: logic, required validation, race, leak,
   crash), **Performance** (N+1, leaked listeners, redundant renders, missing batch/index, oversized payloads, blocking I/O, unbounded
   caches), **Tech Debt** (duplication, type gaps, dead code, fragile APIs, schema standardisation, risky patterns, old/vulnerable deps).
   A schema absence (column, FK, timestamp, constraint, index) is never a Bug. Functional Gap / UX / Reporting: record with
   `in_scope: "No"`, `product_decision: "Yes"`, analysis columns blank. Never invent features.
3. **Gather** (state what you used): live/test data (read-only) > code (`file:line`) > DB/API schema > docs/KB > git history.
4. **Map the module** across layers, walk each area (settings, master data, transactions, calculations, sync, reports, jobs, API,
   schema), gather evidence per candidate, write findings, self-review, validate. Large module: one read-only agent per layer, you merge,
   dedupe and assign ids.
5. **False-positive pre-flight, every candidate:** (1) confirmed in code/data? inferred → `current` starts `(unverified)`, severity ≤ Medium;
   (2) described as intended by KB/setting/decision/by-design list? → not a Bug; (3) already fixed on a branch/open MR
   (`git log --all --since=6.months --grep=<topic>`)? (4) is the "missing" field required for this record type? NULL ≠ bug;
   (5) schema absence → Tech Debt at best, Functional Gap by default. Also: grep all layers before "missing"; default-OFF is often
   deliberate (`product_decision: "Yes"`); config state ≠ product bug; don't double-count (cross-reference "Overlaps GAP-00X").
6. **Severity (evidence-gated):** Critical = silent financial/data corruption, security breach, outage (code or live-data evidence only);
   High = wrong results/data loss in normal use (code or schema evidence); Medium = edge case/recoverable/indirect evidence; Low = cosmetic/latent.
7. **Output:** each finding = exactly 23 string keys (`reference/output-schema.md`, example `reference/example-finding.json`):
   `id, module, layer, type, in_scope, subtype, title, area, severity, current, expected, business_impact, root_cause, why_today,
   why_not_prod, customer_impact, db_migration, suggested_fix, code_location, product_decision, effort, existing_notes, source`.
   In-scope findings always fill `why_today` / `why_not_prod` (prefix `(inferred)` unless evidenced) and `db_migration` (Yes/No/Maybe).
8. **Deliver:** `<module>.json` in the profile's findings folder (else `<workspace>/.claude-runtime/audits/<project>/`);
   `python <workspace>/.claude/skills/tech-audit/scripts/validate.py <file>` must print `schema problems: none`; then
   `python .../scripts/summary.py <module>.json --sources "<what you used>"` (→ summary .md + .html; publish the HTML with `devtools.py doc`).
9. **Review loop:** a finding rejected as a false positive → add the lesson to the project profile (by-design / review lessons).

## Reference (read only when you need it)
- `reference/audit-guide.md` — the full guide (scope, inputs table, every false-positive rule, triage columns, workbook + bug-wave hand-off).
- `reference/output-schema.md` — field definitions and allowed values: while writing findings.
