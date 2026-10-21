# board-disputes
What: `orch.ps1 board dispute | disputes`: an agent disagrees with another's result; the other answers once with evidence;
still split after 2 rounds, or silent 2 h, -> a `decide ask` the owner judges (orchestrate E4).
Config: none (runtime path `disputes`). Wiring: `skills/orchestrate/adapters/board_disputes.ps1`, dot-sourced by orch.ps1;
supervise -AutoFix runs its `Get-KitSuperviseFlagsDisputes` (expiry). Test: `pwsh -File extras/board-disputes/test.ps1 <kit>`.
