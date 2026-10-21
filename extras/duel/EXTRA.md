# duel

`workflows/buildy-duel.js`: /buildy (as of 2026-10-21) with `mode: 'duel'`: two devy POCs of one question, revy compares, a debate (max 3 rounds), the owner judges (`decide ask`), the winner ships through the dev flow.
Needed when: the owner wants two approaches built and compared before one ships.
Wiring: a standalone workflow, `Workflow({ scriptPath: "<kit>/workflows/buildy-duel.js", args })`: /buildy args plus `mode: 'duel'`, `duel: { question, approaches?, rounds }`, exactly 2 agents; the debate record goes to `<runtime>/work/duels/<run>.md`.
