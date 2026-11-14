#Requires -Version 7
<#
supervise-generic.tests.ps1: supervise resources on neutral and custom config: cleanup.idleDaemons, storage.toolCaches, gate.labels.
Usage: pwsh -NoProfile -File <kit>/tests/supervise-generic.tests.ps1 (or tests/kit-tests.ps1 -Area supervise-generic).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit supgen; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# storage.db.maxGB unset: no temp cap, a 7 GB query is not killed; 5 = killed (LEGACY value)
$sd = Join-Path (Kd) 'sdb'; New-Item -ItemType Directory -Force $sd | Out-Null
'"43 7 30 SELECT big"' | Set-Content "$sd/use.ps1"; 'param($i) Add-Content (Join-Path $PSScriptRoot killed.txt) $i' | Set-Content "$sd/kill.ps1"
$cap = Invoke-PsTest storage-cap @'
$null = . $args[0] 6>$null; $sd = $args[1]; $db = @{ use = "pwsh -NoProfile -File `"$sd/use.ps1`""; kill = "pwsh -NoProfile -File `"$sd/kill.ps1`" {id}" }
$__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ db = [pscustomobject]$db } }; $null = Invoke-KitStorageTick -Force; "nocap:$(-not (Test-Path "$sd/killed.txt"))"
$db.maxGB = 5; $__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ db = [pscustomobject]$db } }; $null = Invoke-KitStorageTick -Force; "cap:$((Get-Content "$sd/killed.txt") -eq '43')"
'@ @($O, $sd)
Expect-Each $cap 'storage db cap: #' 'nocap', 'cap' -Show 4
# generic: idle daemons only from cleanup.idleDaemons (busyKinds hold them), tool caches from storage.toolCaches, gate.labels before built-in kinds
$gen = Invoke-PsTest res-generic @'
$null = . $args[0] 6>$null; Remove-Item Env:KIT_KEEP_DAEMONS -ErrorAction SilentlyContinue
$now = Get-Date; $actions = [Collections.ArrayList]::new(); $DryRun = $true; $tmp = Join-Path $args[1] 'gt'; New-Item -ItemType Directory -Force (Join-Path $tmp 'claude-build-gate') | Out-Null
function Get-SysProcs([string]$Name) { @([pscustomobject]@{ Id = 7; Name = 'java'; CommandLine = 'java GradleDaemon'; Created = $now.AddHours(-1); WorkingSet = 1GB }, [pscustomobject]@{ Id = 8; Name = 'node'; CommandLine = 'node tsserver'; Created = $now.AddHours(-1); WorkingSet = 1GB }) | Where-Object Name -match $Name }
Invoke-KitCleanupResources; "none:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ cleanup = [pscustomobject]@{ idleDaemons = @([pscustomobject]@{ process = '^node$'; match = 'tsserver'; label = 'TS server' }) } }
Invoke-KitCleanupResources; "own:$($actions.Count -eq 1 -and $actions[0] -match '^stopped idle TS server pid 8 ')"
$actions.Clear(); $__cfg.cleanup.idleDaemons[0] | Add-Member busyKinds '^tsc' ; Set-Content (Join-Path $tmp "claude-build-gate/b.json") (@{ kind = 'tsc-lint'; pid = $PID; start = (Get-Process -Id $PID).StartTime.ToString('o') } | ConvertTo-Json)
function Test-KitPid { $true }; Invoke-KitCleanupResources; "busy:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ toolCaches = @('~/.mine', '{localAppData}/x') } }
"caches:$((@(Get-KitToolCaches 'H' 'L') -join ',') -eq 'H/.mine,L/x' -and (@(Get-KitToolCaches 'H' '') -join ',') -eq 'H/.mine')"
$__cfg = $null; "cachedef:$(@(Get-KitToolCaches 'H' 'L') -contains 'H/.gradle')"
"labels-def:$((Get-KitGateGroup 'maven-test' 'x') -eq 'maven test' -and (Get-KitGateGroup 'zig' 'x') -eq 'other')"
$script:KitGateLabels = $null; $__cfg = [pscustomobject]@{ gate = [pscustomobject]@{ labels = [pscustomobject]@{ _readme = 'x'; 'zig build' = '^zig'; 'all maven' = '^maven' } } }
"labels:$((Get-KitGateGroup 'zig' 'x') -eq 'zig build' -and (Get-KitGateGroup 'maven-test' 'x') -eq 'all maven' -and (Get-KitGateGroup 'ng-test' 'x') -eq 'js tests')"
'@ @($O, (Kd))
Expect-Each $gen 'resources generic: #' 'none', 'own', 'busy', 'caches', 'cachedef', 'labels-def', 'labels' -Show 6
Remove-TestKit $k
Complete-Tests
