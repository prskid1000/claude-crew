# board-disputes

`orch.ps1 board dispute | disputes`: an agent disagrees with another's result; the other answers once with evidence; still split after 2 rounds, or silent 2 h, -> a `decide ask` the owner judges (orchestrate E4, DECISION).
Needed when: agents should settle a disagreement in a two-round dispute before the owner judges (without it: `board msg`, then `decide ask`).
Wiring: `skills/orchestrate/adapters/board_disputes.ps1`, dot-sourced by orch.ps1; supervise -AutoFix calls its `Get-KitSuperviseFlagsDisputes` (2 h expiry); runtime path `disputes`; the dispute text: `skills/dev-kit/templates-dispute.md`.
