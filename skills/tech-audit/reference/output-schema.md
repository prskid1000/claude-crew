# Finding output schema (machine contract)

Each finding is a JSON object with **exactly these 23 string keys** (use `""` when unknown). Findings workbooks depend on this exact set — do not add or rename keys.

| Key | Meaning | Allowed values / format |
|-----|---------|--------------------------|
| `id` | Unique finding id | `<MODULE-ABBR>-<BUG\|PERF\|REF\|GAP\|UX\|RPT>-NNN` e.g. `UOM-BUG-001`, `AM-PERF-03` |
| `module` | Human module name | e.g. `Notifications`, `Search`, `CSV Export` |
| `layer` | Where it lives | `Web UI` \| `Java API` \| `.NET API` \| `Python` \| `Node API` \| `Mobile` \| `Desktop` \| `DB` \| `Jobs` \| `Integration` \| `Cross-cutting` (add the project's own layer names if it has others) |
| `type` | Finding type | `Bug` \| `Performance` \| `Tech Debt` \| `Functional Gap` \| `UX` \| `Reporting` |
| `in_scope` | In this exercise? | `Yes` for Bug/Performance/Tech Debt; `No` otherwise |
| `subtype` | Short category | e.g. `Data Integrity`, `Validation`, `Calculation`, `Concurrency`, `Memory leak`, `Schema/Migration`, `Dead code`, `API contract`, `RxJS`, `Render perf` |
| `title` | Concise finding title | one line |
| `area` | Screen / component / table | e.g. `Settings / Profile`, `user-list.component.ts` |
| `severity` | Impact level | `Critical` \| `High` \| `Medium` \| `Low` (map gap/UX priority: Must-Have→High, Nice-to-Have→Low) |
| `current` | Current behaviour / the problem | 1–2 sentences. Prefix `(unverified)` if not confirmed in code/data |
| `expected` | Correct behaviour | 1–2 sentences |
| `business_impact` | Why it matters to the business | 1 sentence |
| `root_cause` | Technical root cause | 1 sentence (in-scope only; `""` for out-of-scope) |
| `why_today` | Why the code is like this | Prefix `(inferred)` unless evidenced. In-scope only |
| `why_not_prod` | Why it isn't visibly breaking prod / how teams live with it | Prefix `(inferred)`. In-scope only. Be concrete |
| `customer_impact` | Effect on existing customers if unfixed | short phrase, or `Minimal`. In-scope only |
| `db_migration` | Needs a schema change? | `Yes` \| `No` \| `Maybe` |
| `suggested_fix` | Recommended fix | 1–2 sentences |
| `code_location` | Where to fix | `file:line`, table, or endpoint. Always try for in-scope |
| `product_decision` | Needs a business/product call first? | `Yes` \| `No` |
| `effort` | Rough effort | `Low` \| `Medium` \| `High` \| `""` |
| `existing_notes` | Prior reviewer comments, ticket links, cross-refs | `""` if none |
| `source` | Where this finding came from | e.g. `Catch Weight doc`, `2026-05 audit run` |

## Validation

```powershell
python <workspace>/.claude/skills/tech-audit/scripts/validate.py <module>.json
```
Checks the exact key set, string values, allowed vocab, unique ids, triage columns on in-scope findings, empty analysis on
out-of-scope ones, and the severity cap on `(unverified)` findings. Must print `schema problems: none`.
