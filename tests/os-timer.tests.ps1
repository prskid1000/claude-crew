#Requires -Version 7
<#
tests/os-timer.tests.ps1: install / uninstall / status through a fake scheduler adapter, health (off, fresh, stale, gone ->
reinstalled, removed, osTimer false), the tick (supervise as session os-timer; skips while paused), the step-aside windows (K102), the CLI verbs once installed.
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
# 5-min tick, beat 20: a session swept at 0; ticks at 4, 9, 14, 19 min step aside in-process (no child), 24 sweeps
$lkT = Join-Path (Get-KitPath cache -Create) 'supervise.lock'; Write-KitAtomic (Get-KitPath supervise-state -Create) (@{ nextBeat = 20; report = @{ at = (Get-Date).ToString('o') } } | ConvertTo-Json)
$tickRun = foreach ($tickAge in 4, 9, 14, 19, 24) { $script:kx = ''; Write-KitAtomic $lkT (@{ session = 'coord-a'; at = (Get-Date).AddMinutes(-$tickAge).ToString('o') } | ConvertTo-Json); $tr = Invoke-KitOsBeatTick; "$tickAge=$(if ($script:kx) { 'sweep' } elseif ($tr -like 'stepped aside: last sweep*') { 'aside' } else { $tr })" }
"tick5:$(($tickRun -join ' ') -eq '4=aside 9=aside 14=aside 19=aside 24=sweep')"
# its own sweep counts: an OS sweep 5 min ago is never repeated at the next tick
Write-KitAtomic $lkT (@{ session = 'os-timer'; at = (Get-Date).AddMinutes(-5).ToString('o') } | ConvertTo-Json); $script:kx = ''; $null = Invoke-KitOsBeatTick; "tickown:$(-not $script:kx)"
# the header's next sweep: last tick 1 min ago, every 5 min, last sweep 6 min ago -> the tick at +14 min (first one 19.5 min after the sweep)
$nowT = Get-Date; $osB = Read-KitOsBeat; $osB.installed = $true; $osB.minutes = 5; $osB.lastTick = $nowT.AddMinutes(-1).ToString('o'); Write-KitState (Get-KitOsBeatFile) $osB
"nextsweep:$([int]((Get-KitOsBeatNextSweep $nowT.AddMinutes(-6) $nowT) - $nowT).TotalMinutes -eq 14 -and -not (Get-KitOsBeatNextSweep $nowT.AddMinutes(-6) $nowT.AddMinutes(30)))"
# a task installed before the beat gate (fired once a beat) is re-registered at the tick cadence
$osB.Remove('gate'); $osB.minutes = 20; Write-KitState (Get-KitOsBeatFile) $osB; $script:there = $true
"regate:$((Get-KitOsBeatHealth) -match '^OS heartbeat re-registered .*every 5 min' -and (Read-KitOsBeat).gate -eq 'beat' -and (Read-KitOsBeat).minutes -eq 5)"
# a failed re-register says so (no "re-registered" claim); the next health retries
$osB = Read-KitOsBeat; $osB.Remove('gate'); Write-KitState (Get-KitOsBeatFile) $osB; function Set-KitOsBeat([bool]$On, [double]$Minutes) { 'UNKNOWN: windows install failed: denied' }
"regatefail:$((Get-KitOsBeatHealth) -match '^OS heartbeat still fires once a beat \(re-register failed\): UNKNOWN')"
function Get-KitActivePause($Run) { [pscustomobject]@{ reason = 'power off' } }; $script:kx = ''
"paused:$((Invoke-KitOsBeatTick) -eq 'skipped: paused (power off)' -and -not $script:kx)"
$__cfg = [pscustomobject]@{ supervise = [pscustomobject]@{ osTimer = $false } }; Remove-Item (Get-KitOsBeatFile)
"false:$((Get-KitOsBeatAdapter) -eq 'none' -and -not (Get-KitOsBeatHealth))"
'@ @($O)
Expect-Each $ob 'os-timer: # (off: the install line; inst; schema: updated + schemaVersion; fresh: quiet; stale; gone: reinstalled; removed: quiet; tick: supervise as os-timer; tick5: 5-min ticks sweep only a beat after the last; tickown; nextsweep; regate; regatefail; paused: skipped; false: adapter none, quiet)' 'off', 'inst', 'schema', 'fresh', 'stale', 'gone', 'removed', 'tick', 'tick5', 'tickown', 'nextsweep', 'regate', 'regatefail', 'paused', 'false'
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
# beat 10: the OS timer steps aside for any sweep (its own too) under a beat less its 0.5 min start-up, a session for another's under
# half a beat and still stamps coordAt (health OVERDUE); [holder, minutes ago, caller, steps aside]
$lk = Join-Path (TkPath $k cache -Create) 'supervise.lock'; $sf = TkPath $k supervise-state -Create
$asideBad = @(foreach ($ac in @(@('os-timer', 3, 'coord-a', 1), @('os-timer', 6, 'coord-a', 0), @('coord-a', 7, 'os-timer', 1), @('coord-a', 9, 'os-timer', 1), @('os-timer', 4, 'os-timer', 1), @('coord-a', 10, 'os-timer', 0))) {
  & $J @{ nextBeat = 10; report = @{ at = (Get-Date).ToString('o') }; coordAt = (Get-Date).AddHours(-1).ToString('o') } $sf
  & $J @{ session = $ac[0]; at = (Get-Date).AddMinutes(-$ac[1]).ToString('o'); pid = 1 } $lk
  $asideOut = Px $O supervise -Session $ac[2] | Out-String; $stamped = ((Get-Date) - [datetime](Get-Content $sf -Raw | ConvertFrom-Json).coordAt).TotalMinutes -lt 5
  if ([int]($asideOut -match 'steps aside') -ne $ac[3] -or $stamped -ne ($ac[2] -eq 'coord-a')) { "$($ac[2]) vs $($ac[0]) $($ac[1]) min (coordAt fresh: $stamped)" } })
Expect "os-timer: the timer steps aside for any sweep under a beat, a session under half a beat and stamps coordAt ($asideBad)" (-not $asideBad.Count)
# K102 regression: no supervise.lock yet (fresh install) sweeps, never "Cannot convert null to type System.DateTime"
Remove-Item -LiteralPath $lk -Force; $noLock = Px $O supervise -Session coord-a | Out-String
Expect "supervise: a first sweep without supervise.lock runs and writes the lock ($($noLock -match 'FAILED' -as [bool]))" ($noLock -notmatch 'Supervise FAILED' -and (Test-Path -LiteralPath $lk))
# the CLI verbs reach os_timer.ps1; a paused kit's tick never starts supervise; status of a never-installed timer exits 1
$pd = TkPath $k pauses -Create; & $J @{ at = (Get-Date).ToString('o'); reason = 'owner pause'; run = '*'; state = 'paused' } (Join-Path $pd 'pause-t.json')
$tk = Invoke-TestScript $O heartbeat tick; $st = Invoke-TestScript $O heartbeat status
Expect "os-timer: heartbeat tick while paused = skipped; heartbeat status of a never-installed timer exits 1 ($($tk.code) $($st.code))" ($tk.out -match 'skipped: paused \(owner pause\)' -and $tk.code -eq 0 -and $st.code -eq 1 -and $st.out -match '^heartbeat: (not installed|UNKNOWN)')
# header next: the OS timer's next sweep when it ticks (a busy session's NEXT went past: "next 19:01 (overdue)"), else the session's NEXT
$nxh = & { . $O; $n = [datetime]'2026-01-02T18:49:00'; $hs = @(foreach ($on in @($n.AddMinutes(24).ToString('o'), $null)) { Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); next = '12 min'; osNext = $on }) })
  @($hs | ForEach-Object { if ($_ -match "data-next='(\d+)'.*id=nx [^>]*data-due='([^']+)' data-dn='([^']+)'[^>]*data-tail='([^']*)'") { "$($Matches[1]) $($Matches[2]) $($Matches[3])$($Matches[4])" } }) -join '|' }
Expect "supervise page: next = the OS timer's sweep, else the session NEXT; staleness stays on NEXT ($nxh)" ($nxh -eq '12 19:13 24 &#183; OS timer|12 19:01 12')
Remove-TestKit $k
Complete-Tests
