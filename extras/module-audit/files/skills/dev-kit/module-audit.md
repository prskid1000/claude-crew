# Module audit (revy kind module; extra module-audit)

One folder, feature or service; findings only, no code changes. `<kit>` = the workspace's `.claude` folder.

0. `python -X utf8 <kit>/skills/dev-kit/devtools.py findings schema` (each key's format, an example, the profile shape); read the
   profile `<kit>/skills/dev-kit/projects/<project>.local.md` (none -> return a draft in that shape for the caller to save).
   Golden rule: every finding cites evidence, or is marked unverified; a wrong finding costs more than a missing one.
1. Scope: **Bug** (wrong output for a defined-correct input: logic, validation, race, leak, crash), **Performance** (N+1, leaked
   listeners, redundant renders, missing batch/index, oversized payloads, blocking I/O, unbounded caches), **Tech Debt**
   (duplication, type gaps, dead code, fragile APIs, schema standardisation, risky patterns, old/vulnerable deps). A schema
   absence is never a Bug. Functional Gap / UX / Reporting: `in_scope: "No"`, `product_decision: "Yes"`. Never invent features.
2. Evidence, strongest first: live/test data > code (`file:line`) > DB/API schema > docs > git history. Map the module across
   layers, walk each area (settings, master data, transactions, calculations, sync, reports, jobs, API, schema); a large module:
   the caller runs one revy (kind module) per layer, then one more merges, dedupes and assigns ids.
3. False-positive pre-flight per candidate: confirmed in code/data (else `current` starts `(unverified)`, severity <= Medium)?
   intended by docs / a setting / a decision / the by-design list? already fixed on a branch or open MR (`git log --all
   --since=6.months --grep=<topic>`)? the "missing" field required for this record type? grep all layers before "missing";
   default-OFF is often deliberate; config state != product bug; no double counting ("Overlaps GAP-00X").
4. Severity: Critical = silent financial/data corruption, security breach, outage (code or live-data evidence only); High =
   wrong results / data loss in normal use; Medium = edge case, recoverable, indirect evidence; Low = cosmetic / latent.
5. Return the findings (you write no file; the caller saves `<module>.json` in the profile folder, else
   `<runtime>/work/audits/<project>/`): one array, each finding exactly the 23 string
   keys `id` (`<MODULE>-<BUG|PERF|REF|GAP|UX|RPT>-NNN`), `module`, `area`, `title`, `subtype`, `source`, `layer`, `type`,
   `in_scope`, `severity`, `current`, `expected`, `suggested_fix` (1-2 sentences), `business_impact`, `root_cause`,
   `customer_impact` (in scope), `why_today`, `why_not_prod` (`(inferred)` unless evidenced), `db_migration`, `code_location`,
   `product_decision`, `effort`, `existing_notes` (formats: `findings schema`). The caller then runs `devtools.py findings
   validate <file>` (= `schema problems: none`), `findings summary <file> --sources "<used>"` and `devtools.py doc` (HTML).
6. Hand off to the person reviewing the findings: accepted ones become a /buildy brief (orchestrate step 2) or bug tasks; one
   rejected as a false positive -> a line in the profile ("Known by-design" / "Review lessons"); a lesson for any codebase ->
   `orch.ps1 learn -Skill revy -Lesson "..."`.
