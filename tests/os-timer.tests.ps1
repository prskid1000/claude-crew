#Requires -Version 7
<#
tests/os-timer.tests.ps1: install / uninstall / status through a fake scheduler adapter, health (off, fresh, stale, gone ->
reinstalled, removed, osTimer false), the tick (supervise as session os-timer; skips while paused), the step-aside windows (K102), the CLI verbs once installed; storage (verdicts, folder drill-down, db watchdog, rescue hold).
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
$tickRun = foreach ($tickAge in 4, 9, 14, 19, 24) { $script:kx = ''; Write-KitAtomic $lkT (@{ session = 'coord-a'; at = (Get-Date).AddMinutes(-$tickAge).ToString('o') } | ConvertTo-Json); Write-KitAtomic (Get-KitPath supervise-state) (@{ nextBeat = 20; report = @{ at = (Get-Date).AddMinutes(-$tickAge).ToString('o') } } | ConvertTo-Json); $tr = Invoke-KitOsBeatTick; "$tickAge=$(if ($script:kx) { 'sweep' } elseif ($tr -like 'stepped aside: last sweep*') { 'aside' } else { $tr })" }
"tick5:$(($tickRun -join ' ') -eq '4=aside 9=aside 14=aside 19=aside 24=sweep')"
# its own sweep counts: an OS sweep 5 min ago is never repeated at the next tick
Write-KitAtomic $lkT (@{ session = 'os-timer'; at = (Get-Date).AddMinutes(-5).ToString('o') } | ConvertTo-Json); Write-KitAtomic (Get-KitPath supervise-state) (@{ nextBeat = 20; report = @{ at = (Get-Date).AddMinutes(-5).ToString('o') } } | ConvertTo-Json); $script:kx = ''; $null = Invoke-KitOsBeatTick; "tickown:$(-not $script:kx)"
# a sweep that died after stamping the lock (its pid gone, no newer report): never counts, the tick sweeps
Write-KitAtomic $lkT (@{ session = 'coord-a'; at = (Get-Date).ToString('o'); pid = 999999 } | ConvertTo-Json); Write-KitAtomic (Get-KitPath supervise-state) (@{ nextBeat = 20; report = @{ at = (Get-Date).AddMinutes(-25).ToString('o') } } | ConvertTo-Json); $script:kx = ''; $null = Invoke-KitOsBeatTick; "tickdead:$([bool]$script:kx)"
# a sweep still running (its pid alive, started before the lock): counts
Write-KitAtomic $lkT (@{ session = 'coord-a'; at = (Get-Date).ToString('o'); pid = $PID } | ConvertTo-Json); $script:kx = ''; $null = Invoke-KitOsBeatTick; "ticklive:$(-not $script:kx)"
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
Expect-Each $ob 'os-timer: # (off: the install line; inst; schema: updated + schemaVersion; fresh: quiet; stale; gone: reinstalled; removed: quiet; tick: supervise as os-timer; tick5: 5-min ticks sweep only a beat after the last; tickown; tickdead: a dead sweep''s lock never counts; ticklive: a running sweep counts; nextsweep; regate; regatefail; paused: skipped; false: adapter none, quiet)' 'off', 'inst', 'schema', 'fresh', 'stale', 'gone', 'removed', 'tick', 'tick5', 'tickown', 'tickdead', 'ticklive', 'nextsweep', 'regate', 'regatefail', 'paused', 'false'
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
  & $J @{ nextBeat = 10; report = @{ at = (Get-Date).AddMinutes(-$ac[1]).ToString('o') }; coordAt = (Get-Date).AddHours(-1).ToString('o') } $sf
  & $J @{ session = $ac[0]; at = (Get-Date).AddMinutes(-$ac[1]).ToString('o'); pid = 1 } $lk
  $asideOut = Px $O supervise -Session $ac[2] | Out-String; $stamped = ((Get-Date) - [datetime](Get-Content $sf -Raw | ConvertFrom-Json).coordAt).TotalMinutes -lt 5
  if ([int]($asideOut -match 'steps aside') -ne $ac[3] -or $stamped -ne ($ac[2] -eq 'coord-a')) { "$($ac[2]) vs $($ac[0]) $($ac[1]) min (coordAt fresh: $stamped)" } })
Expect "os-timer: the timer steps aside for any sweep under a beat, a session under half a beat and stamps coordAt ($asideBad)" (-not $asideBad.Count)
# a dead sweep (fresh lock, its pid gone, the last report 2 beats old): a session sweeps, no coordAt stamp hides OVERDUE
& $J @{ nextBeat = 10; report = @{ at = (Get-Date).AddMinutes(-20).ToString('o') }; coordAt = (Get-Date).AddHours(-1).ToString('o') } $sf; & $J @{ session = 'os-timer'; at = (Get-Date).ToString('o'); pid = 999999 } $lk
$deadOut = Px $O supervise -Session coord-a | Out-String
Expect "supervise: a dead sweep's fresh lock never makes a session step aside" ($deadOut -notmatch 'steps aside' -and (Get-Content $lk -Raw) -match 'coord-a')
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
# (moved from bossy.tests.ps1: its cap)
$lkf = Join-Path (TkPath $k cache -Create) 'supervise.lock'
Set-JsonFile $lkf @{ session = 'other'; at = (Get-Date).ToString('s'); pid = 1 }; Set-JsonFile (TkPath $k supervise-state -Create) @{ report = @{ at = (Get-Date).ToString('o') } }   # its sweep ended just now
$sv = pwsh @np $O supervise -Brief -Session me | Out-String
Expect 'supervise: another session''s fresh lock -> steps aside, lock file kept, its .lock not held' ($sv -match 'steps aside' -and (Get-Content $lkf -Raw) -match 'other' -and -not (Test-FileLockHeld $lkf))
# storage: verdicts, learned normal, folder sizes, drill-down, db watchdog, rescue hold
$sd = Join-Path (Kd) 'stree'; foreach ($f in 'a/x/1.bin', 'a/y/2.bin', 'b/3.bin') { New-Item -ItemType Directory -Force (Split-Path "$sd/$f") | Out-Null; [IO.File]::WriteAllBytes("$sd/$f", [byte[]]::new(1MB)) }
'if ($env:USE10) { 1..10 | ForEach-Object { "$_ 0.6 10 q$_" } } else { "42 0.5 900 SELECT 1"; "43 7 30 SELECT big" }' | Set-Content "$sd/use.ps1"; 'param($i) Add-Content (Join-Path $PSScriptRoot killed.txt) $i' | Set-Content "$sd/kill.ps1"
$sto = Invoke-PsTest storage @'
$null = . $args[0] 6>$null; $sd = $args[1]
$c = [pscustomobject]@{ watchFreeGB = 50; actHours = 1; factor = 10; minRateGBh = 5; scanDropGB = 1; actFreeGB = 30; drillGB = 1; flatDays = 7; holdMinutes = 60; sampleSeconds = 60; watch = @()
  db = @{ use = "pwsh -NoProfile -File `"$sd/use.ps1`""; kill = "pwsh -NoProfile -File `"$sd/kill.ps1`" {id}"; maxGB = 5 } }
function Get-KitStorageConf { $c }
$xs = { param($f, $pm) @(0..20 | ForEach-Object { [pscustomobject]@{ t = 1e6 + 60 * $_; free = $f + $pm * (20 - $_) } }) }
foreach ($x in @(40, 0.12, 0.2), @(600, 0.12, 0.2), @(3, 0.12, 0.2), @(600, 0.12, 2), @(600, 0, 0.2), @(20, 0, 0.2, 0)) { $v = Get-KitDiskVerdict (& $xs $x[0] $x[1]) $c $x[2] ($x.Count -lt 4); "v:$($v.level),$($v.rescue),$($v.scan)" }
$b = @(0..20 | ForEach-Object { [pscustomobject]@{ t = 1e6 + 60 * $_; free = 8 + [math]::Max(0, 2 - 0.7 * $_) } }); $v = Get-KitDiskVerdict $b $c; "burst:$($v.level),$($v.rescue)"
"normal:$(Get-KitDiskNormal @(0..10 | ForEach-Object { [pscustomobject]@{ t = 3600 * $_; free = 100 - 0.5 * $_ } }))"
$m = Measure-KitFolders $sd @("$sd/a".Replace('/', [IO.Path]::DirectorySeparatorChar)); $ak = "$sd/a".Replace('/', [IO.Path]::DirectorySeparatorChar).ToLower()
"folders:$($m.sizes[$ak] / 1MB):$((@($m.kids[$ak].Values) | Sort-Object) -join ',')"
$fo = @{ tracked = @{ R = @{ src = 'default' }; L = @{ src = 'learned'; flat = (Get-Date).AddDays(-8).ToString('s') } } }
$g = Update-KitTracked $fo @{ sizes = @{ R = 13; L = 2 }; kids = @{ R = @{ 'R/a' = 1.2; 'R/b' = 7.8 } } } @{ sizes = @{ R = 10; L = 2 }; kids = @{ R = @{ 'R/a' = 1; 'R/b' = 5 } } } $c
"drill:$($g[0].path)+$($g[0].gb):$(@($fo.tracked.Keys | Sort-Object) -join ',')"
$q = @(Get-KitDbQueries $c); $null = Invoke-KitStorageTick -Force; $env:USE10 = '1'; $null = Invoke-KitStorageTick -Force; $z = [pscustomobject]@{ drive = 'Z'; kit = $true; free = 3; rate = 9; ttf = 0.3 }
Invoke-KitDiskRescue $c $z @($q | Where-Object id -ne 43); Invoke-KitDiskRescue $c $z $q; $h1 = (Get-KitDiskHold).drive
Set-KitStorageState { param($s) $s.rescues.Z.at = (Get-Date).AddHours(-2).ToString('o') }
"db:$($q.Count):$((Get-Content "$sd/killed.txt") -join ','):hold $h1/$([bool](Get-KitDiskHold))"
[IO.File]::WriteAllText((Get-KitStorageFile Q), (@(0..2 | ForEach-Object { '{"t":' + ([DateTimeOffset]::Now.ToUnixTimeSeconds() - 60 * $_) + ',"free":' + (50 + $_) + ',"size":100}' }) -join "`n") + "`n")
Invoke-Storage -Drive Q -Since 1h
'@ @($O, $sd)
Expect 'storage verdicts: odd fill ACT + rescue, far WATCH, full in 1 h rescue, normal OK, 1 GB/beat scan, kit drives only, burst no rescue' ((($sto | Where-Object { $_ -like 'v:*' -or $_ -like 'burst:*' }) -join ' ') -eq 'v:ACT,True,True v:WATCH,False,True v:ACT,True,True v:OK,False,True v:OK,False,False v:OK,False,False burst:ACT,False')
Expect 'storage: the learned normal = the median hourly fill rate' ($sto -contains 'normal:0.5')
Expect 'storage: one enumeration gives a folder''s size and each child''s' ($sto -contains 'folders:2:1048576,1048576')
Expect 'storage: the grown folder''s grown child becomes tracked; a learned folder flat 7 days drops out' ($sto -contains 'drill:R+3:R,R/b')
Expect 'storage: over maxGB killed (43), small not; rescue kills the temp holder (42) once per 10 min, holds builds' ($sto -contains 'db:2:43,42:hold Z/False')
Expect 'bossy.ps1 storage: the timeline of a drive with its db kills' ((($sto -join "`n") -match '(?m)^== Q: 3 sample') -and ($sto -join "`n") -match 'db-kill: SELECT big')
Remove-TestKit $k
Complete-Tests
