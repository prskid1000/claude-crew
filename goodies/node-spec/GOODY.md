# node-spec
- What: `spec.mjs`, the node spec runner: `crafty.ps1 check -Step test` runs `*.spec.ts` / `*.test.ts` of a web project that has no
  unit-test target (no Karma / Vitest / Jest / `test` script) under plain node, bundled by the project's own esbuild;
  `@angular/core` stubbed unless `-RealAngular` or a spec imports `@angular/forms`; TestBed / fakeAsync specs are NOT RUN.
Needed when: `localEnv.envs.*.services.*.start` ~ `ng serve` | `npm` | `yarn` | `pnpm`, `localEnv.defaults.services.*.start` ~ `ng serve` | `npm` | `yarn` | `pnpm`, `angular.json` in a repo, or listed in kit.local.json `goodies`
- Wiring: `skills/crafty/spec.mjs` (`$KitCmd.spec`); `crafty.ps1 stack` lists it as such a project's test command, `check` prints
  the goody line while it is missing. Tests: `tests.ps1` here.
