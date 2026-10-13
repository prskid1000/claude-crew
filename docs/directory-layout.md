# Directory layout

```
claude-crew/  =  <workspace>/.claude/   (git clone; edit in place)
├── CLAUDE.md                     the Router + template: CLIs, tracker workflow, org specifics
├── settings.json                 hooks (guard, kit health, retro nudge, cleanup, kit-flow page, git fetch) + permissions
├── agents/                       dev-agent · mr-reviewer · qa-tester · qa-verifier
├── rules/                        multi-agent.md (always) · db-migrations.md (by path) · your *.local.md org rules
├── workflows/                    dev-wave.js · test-and-close.js · kit-retro.js
├── skills/                       each SKILL.md = Load when / Not when / Hands off to + a Files index (file -> step) + steps;
│   │                             LESSONS.md = active rules (≤ 40 lines), HISTORY.md = retired lessons (agents never read it)
│   ├── dev-kit/                  SKILL.md, LESSONS.md, HISTORY.md, reference/, kit.example.json, scripts/ (incl. kitpaths.*)
│   ├── orchestrate/              SKILL.md, LESSONS.md, HISTORY.md, reference/, templates/, scripts/
│   ├── qa-kit/                   SKILL.md, LESSONS.md, HISTORY.md, targets.example.json, reference/, templates/, scripts/{web,android,lib}
│   ├── android-swarm/            SKILL.md, LESSONS.md, HISTORY.md, reference/, swarm.example.json, avd-template.ini, *.ps1
│   └── tech-audit/                SKILL.md, reference/ (full guide, schema, example, project template), scripts/
├── .githooks/pre-push            org-term + local-file gate (git config core.hooksPath .githooks)
├── docs/                         install.md · runtime.md (what is regenerable) · kit-cost.md (token budget) · configuration.md
├── examples/rules/                path-scoped rule examples (Java backend, Angular frontend)
├── README.md · CONTRIBUTING.md · LICENSE
├── *.local.* (git-ignored)       your configs and durable local state: tracking.local.json, learning.local.jsonl, ...
└── .claude-runtime/ (ignored)    disposable: work/ (in-flight runs) · cache/ · logs/
```
