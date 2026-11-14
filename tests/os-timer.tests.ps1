#Requires -Version 7
<#
tests/os-timer.tests.ps1: install / uninstall / status through a fake scheduler adapter, health (off, fresh, stale, gone ->
reinstalled, removed, osTimer false), the tick (supervise as session os-timer; skips while paused), the CLI verbs once installed.
Usage: pwsh -NoProfile -File tests/os-timer.tests.ps1 (copies adapters/os_timer.ps1 into its test kit).
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
# cron + launchd: the exact command lines (Invoke-KitSchedCmd replaced: nothing is scheduled on this machine)
$cl = Invoke-PsTest os-beat-cron @'
. $args[0]; $script:tab = "MAILTO=x`n5 * * * * other # keep"; $script:calls = @()
function Invoke-KitSchedCmd([string]$Exe, [string[]]$ArgList = @(), [string]$Stdin = $null) { $script:calls += "$Exe $($ArgList -join ' ')"
  if ($Exe -eq 'crontab' -and $ArgList[0] -eq '-l') { return @{ code = $(if ($script:tab) { 0 } else { 1 }); out = $script:tab } }
  if ($Exe -eq 'crontab' -and $ArgList[0] -eq '-') { $script:tab = $Stdin.TrimEnd("`n"); return @{ code = 0; out = '' } }
  if ($Exe -eq 'launchctl' -and $ArgList[0] -eq 'list') { return @{ code = $(if ($script:loaded) { 0 } else { 113 }); out = '' } }
  if ($Exe -eq 'launchctl') { $script:loaded = $ArgList[0] -eq 'load'; return @{ code = 0; out = '' } } }
$a = Get-KitOsBeatArgs 15
Invoke-KitAdapter 'scheduler' 'cron' 'install' $a; Invoke-KitAdapter 'scheduler' 'cron' 'install' $a   # twice: one line
$mine = @($script:tab -split "`n" | Where-Object { $_ -match "# $($a.name)$" })
"cronline:$($mine.Count -eq 1 -and $mine[0] -like "*/15 * * * * $($a.command) >/dev/null 2>&1 # $($a.name)" -and $script:tab -match '(?m)^5 \* \* \* \* other # keep$' -and $script:tab -match '(?m)^MAILTO=x$')"
$s = Invoke-KitAdapter 'scheduler' 'cron' 'status' $a; "cronstatus:$($s.installed -and $s.every -eq 15)"
"cronhour:$((Get-KitCronSpec 120) -eq '0 */2 * * *')"
Invoke-KitAdapter 'scheduler' 'cron' 'uninstall' $a; $s = Invoke-KitAdapter 'scheduler' 'cron' 'status' $a
"cronoff:$(-not $s.installed -and $script:tab -notmatch [regex]::Escape($a.name) -and $script:tab -match 'other # keep')"
$script:tab = ''; Invoke-KitAdapter 'scheduler' 'cron' 'install' $a; "cronempty:$(@($script:tab -split "`n").Count -eq 1)"   # no table yet: crontab -l exit 1
$la = Join-Path ([IO.Path]::GetTempPath()) "la-$PID"; function Get-KitLaunchAgentDir { $la }; $script:calls = @()
Invoke-KitAdapter 'scheduler' 'launchd' 'install' $a; $p = Join-Path $la "$($a.name).plist"; $x = [xml](Get-Content -LiteralPath $p -Raw)
$argv = @($x.plist.dict.array.string)
"plist:$($x.plist.dict.string -eq $a.name -and $x.plist.dict.integer -eq '900' -and $argv[0] -eq $a.pwsh -and $argv[-1] -eq 'tick' -and $argv[-2] -eq 'heartbeat' -and $script:calls -contains "launchctl load -w $p")"
$s = Invoke-KitAdapter 'scheduler' 'launchd' 'status' $a; "lstatus:$($s.installed -and $s.every -eq 15)"
Invoke-KitAdapter 'scheduler' 'launchd' 'install' $a; "lreinstall:$($script:calls -contains "launchctl unload $p")"
Invoke-KitAdapter 'scheduler' 'launchd' 'uninstall' $a; $s = Invoke-KitAdapter 'scheduler' 'launchd' 'status' $a
"loff:$(-not (Test-Path -LiteralPath $p) -and -not $s.installed -and $script:calls -contains "launchctl unload -w $p")"
Remove-Item -Recurse -Force $la -ErrorAction SilentlyContinue
'@ @($O)
Expect-Each $cl 'os-timer: cron + launchd # (cronline: one tagged line, other lines kept; cronstatus; cronhour; cronoff; cronempty; plist: label, interval, argv; lstatus; lreinstall: unload first; loff)' 'cronline', 'cronstatus', 'cronhour', 'cronoff', 'cronempty', 'plist', 'lstatus', 'lreinstall', 'loff'
# the CLI verbs reach os_timer.ps1; a paused kit's tick never starts supervise; status of a never-installed timer exits 1
$pd = TkPath $k pauses -Create; & $J @{ at = (Get-Date).ToString('o'); reason = 'owner pause'; run = '*'; state = 'paused' } (Join-Path $pd 'pause-t.json')
$tk = Invoke-TestScript $O heartbeat tick; $st = Invoke-TestScript $O heartbeat status
Expect "os-timer: heartbeat tick while paused = skipped; heartbeat status of a never-installed timer exits 1 ($($tk.code) $($st.code))" ($tk.out -match 'skipped: paused \(owner pause\)' -and $tk.code -eq 0 -and $st.code -eq 1 -and $st.out -match '^heartbeat: (not installed|UNKNOWN)')
Remove-TestKit $k
Complete-Tests
