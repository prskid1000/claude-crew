#Requires -Version 7
<#
tests.ps1 (goody os-timer): install / uninstall / status through a fake scheduler adapter, health (off, fresh, stale, gone ->
reinstalled, removed, osTimer false), the tick (supervise as session os-timer; skips while paused), the CLI verbs once installed.
Usage: kitbag.py goody test os-timer (next to the kit's tests/harness.ps1; New-TestKit gets this goody's files).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit ostimer; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $ad = Join-Path $k 'skills/bossy/adapters/os_timer.ps1'
if (-not (Test-Path $ad)) { New-Item -ItemType Directory -Force (Split-Path $ad) | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters/os_timer.ps1') $ad }
# owner 2026-11-14: the sweep stopped with every session; the OS task keeps the page, auto-fixes and flags going
$ob = Invoke-PsTest os-beat @'
. $args[0]; $script:there = $false
Register-KitAdapter 'scheduler' 'fake' @{ 'install' = { param($a) $script:there = $true }; 'uninstall' = { param($a) $script:there = $false }; 'status' = { param($a) @{ installed = $script:there; state = 'Ready'; every = 15 } } }
"off:$((Get-KitOsBeatHealth) -match '^OS heartbeat off: .* heartbeat install$')"
$__cfg = [pscustomobject]@{ supervise = [pscustomobject]@{ osTimer = 'fake' } }; $i = Set-KitOsBeat $true 15; $s = Read-KitOsBeat; "inst:$($i -match '^installed: fake task claude-crew-heartbeat-[0-9a-f]{8}, every 15 min' -and $s.installed -and $script:there)"
"schema:$(($w = Get-Content -LiteralPath (Get-KitOsBeatFile) -Raw | ConvertFrom-Json).updated -and $w.schemaVersion -eq 1)"   # STATE.md programs: dir v1, updated required (L21)
"fresh:$(-not (Get-KitOsBeatHealth))"
$s.at = (Get-Date).AddHours(-2).ToString('o'); Write-KitAtomic (Get-KitOsBeatFile) ($s | ConvertTo-Json)
"stale:$((Get-KitOsBeatHealth) -match '^OS heartbeat stale: last tick never \(installed \d\d-\d\d \d\d:\d\d\), task Ready')"
$script:there = $false; "gone:$((Get-KitOsBeatHealth) -match '^OS heartbeat was missing: installed:' -and $script:there)"
$null = Set-KitOsBeat $false 0; "removed:$(-not (Get-KitOsBeatHealth) -and -not $script:there)"
function Invoke-KitExe($Exe, $A, $T) { $script:kx = "$A"; [pscustomobject]@{ code = 0; out = "page`n2 ACT · 1 WATCH"; err = ''; timedOut = $false } }
function Get-KitActivePause($Run) { }
"tick:$((Invoke-KitOsBeatTick) -eq 'ok: 2 ACT · 1 WATCH' -and $script:kx -match 'supervise -Session os-timer -AutoFix -Brief$' -and (Read-KitOsBeat).lastTick)"
function Get-KitActivePause($Run) { [pscustomobject]@{ reason = 'power off' } }; $script:kx = ''
"paused:$((Invoke-KitOsBeatTick) -eq 'skipped: paused (power off)' -and -not $script:kx)"
$__cfg = [pscustomobject]@{ supervise = [pscustomobject]@{ osTimer = $false } }; Remove-Item (Get-KitOsBeatFile)
"false:$((Get-KitOsBeatAdapter) -eq 'none' -and -not (Get-KitOsBeatHealth))"
'@ @($O)
Expect-Each $ob 'os-timer: # (off: the install line; inst; schema: updated + schemaVersion; fresh: quiet; stale; gone: reinstalled; removed: quiet; tick: supervise as os-timer; paused: skipped; false: adapter none, quiet)' 'off', 'inst', 'schema', 'fresh', 'stale', 'gone', 'removed', 'tick', 'paused', 'false'
# the CLI verbs reach the goody; a paused kit's tick never starts supervise; status of a never-installed timer exits 1
$pd = TkPath $k pauses -Create; & $J @{ at = (Get-Date).ToString('o'); reason = 'owner pause'; run = '*'; state = 'paused' } (Join-Path $pd 'pause-t.json')
$tk = Invoke-TestScript $O heartbeat tick; $st = Invoke-TestScript $O heartbeat status
Expect "os-timer: heartbeat tick while paused = skipped; heartbeat status of a never-installed timer exits 1 ($($tk.code) $($st.code))" ($tk.out -match 'skipped: paused \(owner pause\)' -and $tk.code -eq 0 -and $st.code -eq 1 -and $st.out -match '^heartbeat: (not installed|UNKNOWN)')
Remove-TestKit $k
Complete-Tests
