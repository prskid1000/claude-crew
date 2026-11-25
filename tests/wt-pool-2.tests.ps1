#Requires -Version 7
<#
wt-pool-2.tests.ps1: wt lease waits after board leave / handoff (wt-pool.tests.ps1 is at its cap): Remove-KitPoolWaits,
Test-KitPoolWaiterGone, the wait loop exits.
Usage: pwsh -NoProfile -File <kit>/tests/wt-pool-2.tests.ps1 (or tests/kit-tests.ps1 -Area wt-pool-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit pool2
# coordinator 2026-11-25: a handed-off agent's wt lease kept waiting (an orphan pwsh refreshed wait/<agent>-<repo>.json); its successor queued behind it
$owTest = Invoke-PsTest pool-orphan-wait @"
. '$k/skills/crafty/lib.ps1'; `$wd = Join-Path (Get-KitPath wt-slots -Create) 'wait'; New-Item -ItemType Directory -Force `$wd | Out-Null; `$bd = Get-KitPath board -Create
`$t0 = (Get-Date).AddMinutes(-5).ToString('o'); `$t1 = (Get-Date).ToString('o')
@{ agent = 'devQ'; repo = 'app'; since = `$t0; token = 'x' } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devQ-app.json'); @{ agent = 'devR'; repo = 'app'; since = `$t0 } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devR-app.json')
"removed:`$((Remove-KitPoolWaits devQ) -join ',') kept:`$(Test-Path (Join-Path `$wd 'devR-app.json'))"
"never-joined:`$(Test-KitPoolWaiterGone devZ `$t0)"
@{ agent = 'devQ'; status = 'left'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-1.json'); "left-after:`$(Test-KitPoolWaiterGone devQ `$t0)"
"left-before:`$(Test-KitPoolWaiterGone devQ (Get-Date).AddMinutes(1).ToString('o'))"
@{ agent = 'devQ'; status = 'active'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-2.json'); "successor-live:`$(Test-KitPoolWaiterGone devQ `$t0)"
"@
$owOut = $owTest -join ' '
Expect "pool: board leave removes only the leaving agent's queued waits; a waiter stops once its agent left after the wait began, never for one that never joined, left before it, or has a live successor row ($owOut)" ($owOut -match 'removed:devQ-app kept:True' -and $owOut -match 'never-joined:False' -and $owOut -match 'left-after:True' -and $owOut -match 'left-before:False' -and $owOut -match 'successor-live:False')
$lsrc = Get-Content (Join-Path $k 'skills/crafty/adapters/wt-pool.ps1') -Raw; $bsrc = Get-Content (Join-Path $k 'skills/bossy/bossy.ps1') -Raw
Expect "pool: the lease wait loop exits on a removed / replaced wait file or a gone agent, and its finally keeps a newer waiter's file; board leave calls Remove-KitPoolWaits" ($lsrc -match 'if \(-not \(& \$ownWait\)\) \{ throw' -and $lsrc -match 'Test-KitPoolWaiterGone \$Agent \$since' -and $lsrc -match 'finally \{ if \(& \$ownWait\)' -and $bsrc -match 'Remove-KitPoolWaits \$script:leftEntry\.agent')
Remove-TestKit $k
Complete-Tests
