#Requires -Version 7
<#
guard-warm.tests.ps1: the warm PreToolUse guard (guard_client.mjs + guard_server.ps1, K48): the same answers as crafty.ps1 guard,
a fast call once the server runs, a caller's env per call, a kit file change ends the server (the next call is plain again).
Usage: pwsh -NoProfile -File <kit>/tests/guard-warm.tests.ps1 (or tests/kit-tests.ps1 -Area guard-warm). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$TestKitFiles = @('skills/crafty/guard_client.mjs', 'skills/crafty/guard_server.ps1')
$k = New-TestKit gwarm; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $gc = Join-Path $k 'skills/crafty/guard_client.mjs'
$mine = { @(Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -like "*guard_server*" -and "$($_.CommandLine)" -like "*$(Split-Path $k -Leaf)*" }) }
$ins = @('git stash', 'git status --short', 'echo hi') | ForEach-Object { @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $_ } } | ConvertTo-Json -Compress -Depth 4 }
# the decision and its reason (key order differs per process)
$nz = { param($s) if ("$s".Trim()) { $h = ("$s" | ConvertFrom-Json).hookSpecificOutput; "$($h.permissionDecision)|$($h.permissionDecisionReason)" } else { '' } }
$viaPlain = { param($j) & $nz (($j | pwsh @np $D guard) -join '') }
$viaClient = { param($j) & $nz (($j | node $gc) -join '') }
$plain = @($ins | ForEach-Object { & $viaPlain $_ })
$first = @($ins | ForEach-Object { & $viaClient $_ })   # no server yet: the plain path, and a server starts
for ($i = 0; $i -lt 40 -and -not (& $mine).Count; $i++) { Start-Sleep -Milliseconds 250 }; Start-Sleep -Seconds 2   # it loads the kit
$ms = @(); $warm = @($ins | ForEach-Object { $sw = [Diagnostics.Stopwatch]::StartNew(); & $viaClient $_; $ms += [int]$sw.Elapsed.TotalMilliseconds })
Expect "warm guard: the same answers as crafty.ps1 guard (cold and warm), a server runs, warm calls fast ($($ms -join ' ') ms)" (($first -join '~') -eq ($plain -join '~') -and ($warm -join '~') -eq ($plain -join '~') -and $plain[0] -match 'git stash is shared' -and (& $mine).Count -eq 1 -and @($ms | Where-Object { $_ -gt 900 }).Count -le 1)
$env:KIT_LIVE_EDIT = '1'; $null = & $viaClient $ins[0]; Remove-Item Env:KIT_LIVE_EDIT; $le2 = & $viaClient $ins[0]
Expect 'warm guard: the caller''s KIT_* env counts for its call only' ($le2 -eq $plain[0])
$old = @((& $mine).Id); Set-Content (Join-Path $k 'skills/crafty/kit.local.json') '{}'; $after = & $viaClient $ins[0]
for ($i = 0; $i -lt 20 -and @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Milliseconds 250 }
Expect "warm guard: a kit file change ends the server ($($old -join ',')); that call gets the plain answer" ($old.Count -eq 1 -and $after -eq $plain[0] -and -not @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count)
$env:KIT_GUARD_WARM = '0'; $off = & $viaClient $ins[0]; Remove-Item Env:KIT_GUARD_WARM
Expect 'warm guard: KIT_GUARD_WARM=0 = the plain path' ($off -eq $plain[0])
& $mine | Stop-Process -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
