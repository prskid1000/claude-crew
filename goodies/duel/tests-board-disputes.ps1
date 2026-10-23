#Requires -Version 7
<#
tests-board-disputes.ps1 (goody duel, board disputes): offline, on a throw-away test kit with this goody's files.
Usage: kitbag.py goody test duel (its tests.ps1 runs this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kitbag.py goody test: the kit's harness; New-TestKit adds this goody's files
$k = New-TestKit board-disputes; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$dp = pwsh @np $O board dispute -Agent X7 -With R7 -Item A1 -Claim 'no null check needed' -Evidence 'a.ts:3' -Propose 'drop it' | Out-String
$did = if ($dp -match 'DISPUTE (p-\S+) open') { $Matches[1] }
$null = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'b.ts:9'
$null = pwsh @np $O board dispute -Id $did -Agent X7 -Claim 'b.ts is dead' -Evidence 'git grep: no caller'
$esc = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'router.ts:12' | Out-String
$ib = pwsh @np $O board inbox -Agent R7 | Out-String
Expect 'dispute: board msg to the other agent; split after 2 rounds -> decision' ($did -and $ib -match "DISPUTE $did" -and $esc -match 'escalated: DECISION d-' -and (pwsh @np $O decide list -Pending | Out-String) -match "Dispute $did")
$dp2 = pwsh @np $O board dispute -Agent X7 -With R7 -Item A2 -Claim 'cache is safe' -Evidence 'c.ts:4' -Propose 'keep' | Out-String
$did2 = if ($dp2 -match 'DISPUTE (p-\S+) open') { $Matches[1] }
$df2 = & { . (Join-Path $k 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath disputes) "$did2.json" }
(Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex = & { . $O; Get-KitSuperviseFlagsDisputes -AutoFix } | Out-String
(Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex2 = & { . $O; Invoke-DisputeExpiry } | Out-String
Expect 'dispute: silent 2 h escalates once through the supervise hook' (-not $ex2.Trim() -and $ex -match "dispute $did2 .*escalated, DECISION d-" -and (Get-Content $df2 -Raw | ConvertFrom-Json).status -eq 'escalated')
Expect 'disputes: lists both' (@((pwsh @np $O board disputes) | Where-Object { $_ -match '^ESCALATED' }).Count -eq 2)
Remove-TestKit $k
Complete-Tests
