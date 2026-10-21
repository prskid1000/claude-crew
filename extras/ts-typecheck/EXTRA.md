# ts-typecheck
- What: `dev.ps1 check -Step typecheck` for tsc: TS5103 (a TypeScript too new for the tsconfig) -> one retry with a temp tsconfig
  (ignoreDeprecations); errors fail only in changed files (and config errors); > 200 errors elsewhere = UNRUN (exit 5: linked
  node_modules that do not match the branch). Without it tsc runs plainly through the gate (every error fails).
Needed when: `tsconfig.json` in a repo
- Wiring: `skills/dev-kit/adapters/ts_typecheck.ps1` defines `Invoke-Typecheck` (lib.ps1 loads adapters/*.ps1); Invoke-Check calls it
  for a tsc typecheck when it is defined. Tests: `tests.ps1` here.
