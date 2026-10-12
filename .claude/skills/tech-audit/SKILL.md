---
name: tech-audit
description: "Load when: asked to audit, review or health-check one module's code for bugs, performance or tech debt, or to generate findings, without changing code or a deploy to test. Not when: reviewing an agent's open MRs -> mr-reviewer agent; testing deployed changes -> qa-kit; fixing the findings -> dev-kit or /dev-wave via orchestrate."
argument-hint: "<module> [project]"
---

**Load when** (all must hold): the target is one module (a folder, feature or service) of a codebase; the output is findings, not
code changes; router row R8.
**Not when:** an agent's open MRs -> `mr-reviewer` agent (R7); a deployed change on a test environment -> `qa-kit`; fixing the
findings -> `dev-kit` (one) or `/dev-wave` (many, via `orchestrate`).
**Hands off to:** the person reviewing the findings workbook; accepted findings become a wave brief (`orchestrate` step 2) or
bug tasks; rejected false positives go back into the project profile (step 9).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `reference/projects/<project>.md` | step 1, read fully (local overlay: each project's profile) |
| `reference/projects/_template.md` | step 1, copied when the project has no profile yet |
| `reference/audit-guide.md` | step 5 for any candidate whose pre-flight answer is unsure, and before the self-review of a module with > 10 findings |
| `reference/output-schema.md` | step 7, before writing the first finding |
| `reference/example-finding.json` | step 7, the shape of one finding |
| `scripts/validate.py` | step 8, must print `schema problems: none` |
| `scripts/summary.py` | step 8, summary .md + .html |

# Steps (technical audit of one module, any project)

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
   `python .../scripts/summary.py <module>.json --sources "<what you used>"` (→ summary .md + .html; publish the HTML with `python <workspace>/.claude/skills/dev-kit/scripts/devtools.py doc "<title>" <file.html>`).
9. **Review loop:** a finding rejected as a false positive → add the lesson to the project profile (by-design / review lessons).
