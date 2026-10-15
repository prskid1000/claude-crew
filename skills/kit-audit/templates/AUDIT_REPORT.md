# Kit audit <yyyy-MM-dd> (<kit commit audited>, branch <kit/audit-yyyy-MM-dd>)

Filled at kit-audit step 9; saved to `<runtime>/logs/kit-audits/audit-<yyyy-MM-dd>.md`. One line per finding, newest evidence
only; link instead of repeating. Severity: blocking (breaks a flow, loses data, leaks org data or secrets) / should-fix / nit.

## Result
- <N> fixed on the branch (<commits>), <N> proposed, <N> need the lead (ASK), <N> rejected candidates.
- Checks: kit-lint <0 problems>, port-kit --check <ok>, parse <ok>, org terms <0>, kit-cost -Steps <ok / not needed>.

## Setup and missing config (steps 1-2)
- FIX <what was repaired> | ACT <what is left and the command> 
- ASK `<file> <key path>`: <why it is needed, what feature stops without it> (values never written here)

## Recovery (step 3)
- FIX <worktree / branch / board entry / cleanup> | left for the lead: <item> -> <exact command>

## Findings (steps 4-6)
| # | Severity | Where (`file:line`) | Problem (evidence) | Status (fixed in <commit> / proposed: <exact change>) |
|---|---|---|---|---|

## Improvements (step 7)
- <signal / lesson pattern (n×)> -> <kit change applied or proposed>

## kit.local.json additions for the org (never published)
- `<key>`: <what the lead should set and why> (default in the kit: <value>)

## Next audit
- Watch: <regressions or half-done items to re-check next week>
