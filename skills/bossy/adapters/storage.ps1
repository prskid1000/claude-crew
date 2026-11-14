<#
storage.ps1 (core): bossy.ps1 storage (free space per drive, folder scans, disk rescue; kit.example.json storage), dot-sourced by
bossy.ps1 (skills/bossy/adapters/); its tick runs inside board beat and supervise.
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L9 storage
#>
#Requires -Version 7
# ---- storage: free space trend, folder scans, rescue (kit.example.json storage; TODO-PARAM)
function Get-KitStorageConf {
  $d = [ordered]@{ watch = @(); sampleSeconds = 60; keepDays = 30; watchFreeGB = 50; actHours = 1; factor = 10; minRateGBh = 5; scanDropGB = 1; scanCooldownMin = 30; scanHours = 24; drillGB = 1; flatDays = 7; holdMinutes = 60 }
  foreach ($k in @($d.Keys)) { $d[$k] = Get-KitSetting "storage.$k" $d[$k] }
  $d.actFreeGB = [double](Get-KitSetting 'supervise.minDiskFreeGB' 30); $d.db = Get-KitSetting 'storage.db' $null; [pscustomobject]$d
}
# fixed drives; kit = holds workspace, .runtime, temp, profile, worktree root or watch[]
function Get-KitDrives {
  $ds = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.TotalSize -gt 1GB -and "$($_.DriveFormat)" -notmatch '^(squashfs|tmpfs|overlay|iso9660|udf|devtmpfs|ramfs)$' })
  $kp = @(@($KitConf.Workspace, (Get-KitRuntime), [IO.Path]::GetTempPath(), [Environment]::GetFolderPath('UserProfile')) + @($KitConf.WorktreeRoots) + @(Get-KitSetting 'storage.watch' @()) | Where-Object { $_ } | ForEach-Object { try { [IO.Path]::GetFullPath("$_") } catch {} })
  $roots = @($ds | ForEach-Object { $_.RootDirectory.FullName } | Sort-Object Length -Descending)
  $kr = @($kp | ForEach-Object { $p = $_; @($roots | Where-Object { $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })[0] })
  @($ds | ForEach-Object { [pscustomobject]@{ name = $(if ($KitIsWindows) { $_.Name.Substring(0, 1) } else { $_.Name }); root = $_.RootDirectory.FullName; free = [math]::Round($_.AvailableFreeSpace / 1GB, 2); size = [math]::Round($_.TotalSize / 1GB, 2); kit = $_.RootDirectory.FullName -in $kr } })
}
function Get-KitStorageFile([string]$Drive, [string]$Kind = 'jsonl') { $s = ConvertTo-KitSlug $Drive; Join-Path (Get-KitPath storage -Create) "$(if ($s) { $s } else { 'root' }).$Kind" }
function Get-KitStorageState { $f = Join-Path (Get-KitPath storage -Create) 'state.json'; $s = if (Test-Path -LiteralPath $f) { try { Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null } }; if ($s) { $s } else { @{} } }
function Set-KitStorageState([scriptblock]$Change) { $f = Join-Path (Get-KitPath storage -Create) 'state.json'; Invoke-KitLocked $f { $s = Get-KitStorageState; & $Change $s; Write-KitAtomic $f ($s | ConvertTo-Json -Depth 8) } }
function Get-KitStorageSamples([string]$Drive, [int]$Tail = 0) {   # regex: 40k lines a drive
  $f = Get-KitStorageFile $Drive; if (-not (Test-Path -LiteralPath $f)) { return @() }
  @($(if ($Tail) { Get-Content -LiteralPath $f -Tail $Tail } else { Get-Content -LiteralPath $f }) | ForEach-Object { if ($_ -match '"t":(\d+)' -and ($t = [long]$Matches[1]) -and $_ -match '"free":([\d.]+)') { [pscustomobject]@{ t = $t; free = [double]$Matches[1] } } })
}
# median of filling hours (GB/h, min 0.1)
function Get-KitDiskNormal($Xs) {
  $h = [ordered]@{}; foreach ($x in @($Xs | Sort-Object t)) { $b = "h$([math]::Floor($x.t / 3600))"; if (-not $h.Contains($b)) { $h[$b] = $x } }
  $v = @($h.Values); $r = @(for ($i = 1; $i -lt $v.Count - 1; $i++) { ($v[$i - 1].free - $v[$i].free) / [math]::Max(1.0, ($v[$i].t - $v[$i - 1].t) / 3600) }) | Where-Object { $_ -gt 0.01 } | Sort-Object
  if ($r.Count) { [math]::Max(0.1, [math]::Round($r[[int][math]::Floor($r.Count / 2)], 2)) } else { 0.1 }
}
# fill rate over 10 min (both halves), hours to full, level
function Get-KitDiskVerdict($Xs, $C, [double]$Normal = 0.1, [bool]$Kit = $true, [double]$BeatSec = 840) {
  $xs = @($Xs | Sort-Object t); if (-not $xs.Count) { return $null }; $cur = $xs[-1]
  $rt = { param($s) $w = @($xs | Where-Object { $_.t -ge $cur.t - $s })[0]; $hrs = ($cur.t - $w.t) / 3600; if ($hrs -ge $s / 3600 * 0.5) { ($w.free - $cur.free) / $hrs } else { 0.0 } }
  $rate = [math]::Round((& $rt 660), 2); $late = & $rt 330
  $prev = @($xs | Where-Object { $_.t -le $cur.t - $BeatSec })[-1]; $drop = if ($prev) { [math]::Round($prev.free - $cur.free, 2) } else { 0 }
  $ttf = if ($rate -gt 0) { [math]::Round($cur.free / $rate, 1) } else { [double]::PositiveInfinity }
  $sust = $rate -ge $C.minRateGBh -and $late -ge $C.minRateGBh / 2   # a 2 GB burst early in the window is no fill
  $anom = $sust -and $rate -ge $C.factor * [math]::Max(0.1, $Normal)
  $rescue = $sust -and ($ttf -lt $C.actHours -or ($anom -and $cur.free -lt $C.watchFreeGB))
  $lvl = if ($rescue -or ($Kit -and $cur.free -lt $C.actFreeGB)) { 'ACT' } elseif ($anom -or ($Kit -and $cur.free -lt $C.watchFreeGB)) { 'WATCH' } else { 'OK' }
  [pscustomobject]@{ free = $cur.free; rate = $rate; drop = $drop; ttf = $ttf; normal = $Normal; anomaly = $anom; rescue = $rescue; level = $lvl; scan = $drop -ge $C.scanDropGB }
}
# snapshots 2 s apart: a rate, not lifetime totals
function Get-KitTopWriters([int]$N = 3) {
  $snap = { $h = @{}
    if ($KitIsWindows) { foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, Name, WriteTransferCount -ErrorAction SilentlyContinue) { $h[[int]$p.ProcessId] = @($p.Name, [double]$p.WriteTransferCount) } }
    else { foreach ($d in Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d+$') { try { $wb = (Get-Content "$($d.FullName)/io" -ErrorAction Stop | Where-Object { $_ -like 'write_bytes:*' }) -replace '\D', ''; $h[[int]$d.Name] = @((Get-Content "$($d.FullName)/comm" -Raw).Trim(), [double]$wb) } catch {} } }
    $h }
  $a = & $snap; Start-Sleep -Seconds 2; $b = & $snap
  @($b.Keys | Where-Object { $a[$_] } | ForEach-Object { [pscustomobject]@{ pid = $_; name = $b[$_][0]; mbs = [math]::Round(($b[$_][1] - $a[$_][1]) / 2MB, 2) } } | Where-Object mbs -gt 0 | Sort-Object mbs -Descending | Select-Object -First $N)
}
# deleted-but-open space: <root>\$Extend\$Deleted, rarely readable
function Get-KitHeldDeletedGB([string]$Root) { if (-not $KitIsWindows) { return $null }; try { [math]::Round((Get-ChildItem -LiteralPath (Join-Path $Root '$Extend\$Deleted') -Force -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum).Sum / 1GB, 2) } catch { $null } }
function Invoke-KitShellLine([string]$Cmd, [int]$Sec = 5) { if ($KitIsWindows) { Invoke-KitExe 'cmd.exe' @() $Sec "/d /s /c `"$Cmd`"" } else { Invoke-KitExe '/bin/sh' @('-c', $Cmd) $Sec } }
# storage.db.use / kill; 5 s max (full-disk db hangs), timeout skips 5 min
function Get-KitDbQueries($C) {
  if (-not $C.db.use) { return @() }; $st = Get-KitStorageState; if ($st.dbDownAt -and ((Get-Date) - [datetime]$st.dbDownAt).TotalMinutes -lt 5) { return @() }
  $r = Invoke-KitShellLine $C.db.use; if ($r.timedOut) { Set-KitStorageState { param($s) $s.dbDownAt = (Get-Date).ToString('o') }; return @() }
  @("$($r.out)" -split "`r?`n" | ForEach-Object { if ($_ -match '^\s*(?<id>\d+)\s+(?<gb>\d+(\.\d+)?)\s+(?<s>\d+)\s*(?<q>.*)$') { [pscustomobject]@{ id = $Matches.id; gb = [double]$Matches.gb; secs = [int]$Matches.s; query = (Protect-KitText $Matches.q) } } })
}
function Stop-KitDbQuery($C, $Q, [string]$Why) {
  if (-not $C.db.kill -or -not $Q) { return $null }
  $r = Invoke-KitShellLine $C.db.kill.Replace('{id}', $Q.id)
  Write-KitLog disk db-kill ([ordered]@{ id = $Q.id; gb = $Q.gb; secs = $Q.secs; query = $Q.query; why = $Why; code = $r.code })
  "killed db query $($Q.id) ($($Q.gb) GB temp, $($Q.secs) s, $Why): $($Q.query)"
}
# one sample a drive per sampleSeconds machine-wide; db temp watchdog
function Invoke-KitStorageTick([switch]$Force) {
  $c = Get-KitStorageConf; $now = [DateTimeOffset]::Now.ToUnixTimeSeconds(); $stamp = Join-Path (Get-KitPath storage -Create) 'last-sample.txt'
  $go = Invoke-KitLocked $stamp { $l = if (Test-Path -LiteralPath $stamp) { "$(Get-Content -LiteralPath $stamp -Raw)".Trim() }; if (-not $Force -and $l -match '^\d+$' -and $now - [long]$l -lt $c.sampleSeconds) { $false } else { [IO.File]::WriteAllText($stamp, "$now"); $true } }
  if (-not $go) { return @() }
  $out = @(); $st = Get-KitStorageState
  foreach ($d in Get-KitDrives) {
    $f = Get-KitStorageFile $d.name; Invoke-KitLocked $f { [IO.File]::AppendAllText($f, (@{ t = $now; free = $d.free; size = $d.size } | ConvertTo-Json -Compress) + "`n") }
    $v = Get-KitDiskVerdict (Get-KitStorageSamples $d.name 40) $c ([double]$(if ($st.normal -and $st.normal[$d.name]) { $st.normal[$d.name] } else { 0.1 })) $d.kit ((Get-KitBeatMinutes) * 60 - 60)
    $out += $v | Add-Member -PassThru NoteProperty drive $d.name | Add-Member -PassThru NoteProperty root $d.root | Add-Member -PassThru NoteProperty kit $d.kit
  }
  $q = @(Get-KitDbQueries $c); $max = [double]$(if ($c.db.maxGB) { $c.db.maxGB } else { 5 })   # owner: no query above 5 GB of temp
  $top = @($q | Sort-Object gb -Descending)[0]; if ($top -and $top.gb -gt $max) { $null = Stop-KitDbQuery $c $top "temp above $max GB"; $q = @($q | Where-Object id -ne $top.id) }
  foreach ($v in $out | Where-Object rescue) { Invoke-KitDiskRescue $c $v $q }
  $out
}
# sustained fill (10 min a drive): kill temp db query, hold builds, Stop-KitDiskWriter* hooks
function Invoke-KitDiskRescue($C, $V, $Q) {
  $why = "disk $($V.drive): $($V.free) GB free, filling $($V.rate) GB/h, full in $($V.ttf) h"
  $go = Set-KitStorageState { param($s) if (-not $s.rescues) { $s.rescues = @{} }; $h = $s.rescues[$V.drive]
    if ($h -and ((Get-Date) - [datetime]$h.at).TotalMinutes -lt 10) { $false } else { $s.rescues[$V.drive] = @{ drive = $V.drive; kit = [bool]$V.kit; at = (Get-Date).ToString('o'); reason = $why; lines = @() }; $true } }
  if (-not $go) { return }
  $dq = @(@($Q) | Where-Object { $_.gb -ge 0.1 } | Sort-Object gb, secs -Descending)[0]   # db is a cause only while a query holds temp
  $lines = @(@(Stop-KitDbQuery $C $dq 'disk rescue') + @(Invoke-KitHooks Stop-KitDiskWriter @{ Verdict = $V }) | Where-Object { $_ })
  Set-KitStorageState { param($s) $s.rescues[$V.drive].lines = $lines }
  Write-KitLog disk rescue ([ordered]@{ drive = $V.drive; free = $V.free; rate = $V.rate; ttf = "$($V.ttf)"; lines = $lines })
  Start-KitStorageScan $V.drive
}
function Get-KitStorageDefaults([string]$Root) {
  $h = [Environment]::GetFolderPath('UserProfile'); $la = [Environment]::GetFolderPath('LocalApplicationData'); $ra = [Environment]::GetFolderPath('ApplicationData')
  $c = @($h, $la, $ra, [IO.Path]::GetTempPath(), [Environment]::GetFolderPath('CommonApplicationData'), (Get-KitRuntime)) + @($KitConf.WorktreeRoots) +
    @('.gradle', '.m2', '.cache', '.nuget', '.npm', '.cargo', '.docker' | ForEach-Object { Join-Path $h $_ }) + @('Yarn', 'npm-cache', 'pip', 'Docker', 'Temp' | ForEach-Object { Join-Path $la $_ }) +
    @(if ($KitIsWindows -and $env:windir) { Get-ChildItem (Join-Path $env:windir 'ServiceProfiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } })   # service temp dirs (db tmpdir; admin only)
  @(@($c) + @((Get-KitStorageConf).watch) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue) } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/') } | Where-Object { $_.StartsWith($Root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) } | Sort-Object -Unique)
}
function Start-KitStorageScan([string]$Drive) {
  if ($env:KIT_STORAGE_SCAN -eq '0') { return }   # tests: no real drive scans
  $lk = Get-KitStorageFile $Drive 'scan.lock'; $o = try { Get-Content -LiteralPath $lk -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  if ($o -and ($(if ($o.pid) { Test-KitPid $o.pid $o.start } else { ((Get-Date) - (Get-Item -LiteralPath $lk).LastWriteTime).TotalMinutes -lt 1 }))) { return }
  if ($o) { Remove-Item -LiteralPath $lk -ErrorAction SilentlyContinue }   # stale: its scan is gone
  try { [IO.File]::Open($lk, 'CreateNew', 'Write', 'None').Dispose() } catch { return }   # another caller starts it
  Set-KitStorageState { param($s) if (-not $s.scanAt) { $s.scanAt = @{} }; $s.scanAt[$Drive] = (Get-Date).ToString('o') }   # a failing scan waits the cooldown
  $a = @('-NoProfile', '-NonInteractive', '-File', "`"$($KitCmd.orch)`"", 'storage', '-Scan', '-Drive', $Drive)
  $p = if ($KitIsWindows) { Start-Process pwsh -ArgumentList $a -WindowStyle Hidden -PassThru } else { Start-Process pwsh -ArgumentList $a -PassThru }
  try { $p.PriorityClass = 'Idle' } catch {}; Write-KitAtomic $lk (@{ pid = $p.Id; start = (Get-KitPidStart $p.Id) } | ConvertTo-Json)
}
# one pass, rolled up to tracked folders and their children
function Measure-KitFolders([string]$Root, [string[]]$Tracked) {
  $opt = [IO.EnumerationOptions]@{ RecurseSubdirectories = $true; IgnoreInaccessible = $true; AttributesToSkip = [IO.FileAttributes]::ReparsePoint }
  $dir = @{}; foreach ($f in [IO.DirectoryInfo]::new($Root).EnumerateFiles('*', $opt)) { $dir[$f.DirectoryName] = [double]$dir[$f.DirectoryName] + $f.Length }
  $want = @{}; foreach ($t in $Tracked) { $want[$t.ToLower()] = $t }; $tot = @{}; $kids = @{}; $rk = $Root.TrimEnd('\', '/').ToLower()
  foreach ($k in $dir.Keys) {
    $p = $k.TrimEnd('\', '/'); $child = $null   # flow: parent walk to the root, bounded by path depth
    while ($p) { $pl = $p.ToLower(); if ($want.ContainsKey($pl)) { $tot[$pl] = [double]$tot[$pl] + $dir[$k]; if ($child) { if (-not $kids[$pl]) { $kids[$pl] = @{} }; $kids[$pl][$child] = [double]$kids[$pl][$child] + $dir[$k] } }
      if ($pl -eq $rk) { break }; $child = $p; $p = [IO.Path]::GetDirectoryName($p) }
  }
  [pscustomobject]@{ sizes = $tot; kids = $kids; rootFiles = [double]$dir[$Root] + [double]$dir[$Root.TrimEnd('\', '/')] }
}
# grown child of a grown folder is tracked; flat for flatDays drops out
function Update-KitTracked($Fo, $Scan, $Prev, $C, [datetime]$Now = (Get-Date)) {
  if (-not $Prev) { return @() }; $sz = $Scan.sizes
  $grew = @($sz.Keys | Where-Object { $Prev.sizes.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ path = $_; gb = [math]::Round($sz[$_] - [double]$Prev.sizes[$_], 2) } } | Where-Object gb -ge $C.drillGB | Sort-Object gb -Descending)   # new folders have no growth yet
  foreach ($g in $grew | Select-Object -First 3) { $nk = $Scan.kids[$g.path]; $pk = $Prev.kids[$g.path]; if (-not $nk) { continue }
    $best = @($nk.Keys | ForEach-Object { [pscustomobject]@{ p = $_; gb = $nk[$_] - [double]$(if ($pk) { $pk[$_] }) } } | Where-Object gb -ge $C.drillGB | Sort-Object gb -Descending)[0]
    if ($best -and -not $Fo.tracked[$best.p]) { $Fo.tracked[$best.p] = @{ src = 'learned'; at = $Now.ToString('o') } } }
  foreach ($k in @($Fo.tracked.Keys | Where-Object { $Fo.tracked[$_].src -eq 'learned' -and $sz.ContainsKey($_) })) {
    if ([math]::Abs($sz[$k] - [double]$Prev.sizes[$k]) -ge 0.05) { $Fo.tracked[$k].flat = $null } elseif (-not $Fo.tracked[$k].flat) { $Fo.tracked[$k].flat = $Now.ToString('o') }
    elseif (($Now - [datetime]$Fo.tracked[$k].flat).TotalDays -ge $C.flatDays) { $Fo.tracked.Remove($k) } }
  $grew
}
function Invoke-KitStorageScan([string]$Drive) {
  try {
    $c = Get-KitStorageConf; $d = @(Get-KitDrives | Where-Object name -eq $Drive)[0]; if (-not $d) { return "no fixed drive $Drive" }
    $ff = Get-KitStorageFile $Drive 'folders.json'; $fo = try { Get-Content -LiteralPath $ff -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $fo) { $fo = @{ tracked = @{}; scans = @() } }
    $top = @(Get-ChildItem -LiteralPath $d.root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object FullName)
    foreach ($t in @($top) + @(Get-KitStorageDefaults $d.root)) { if (-not $fo.tracked[$t]) { $fo.tracked[$t] = @{ src = 'default'; at = (Get-Date).ToString('o') } } }
    $m = Measure-KitFolders $d.root @($fo.tracked.Keys); $gb = { param($b) [math]::Round($b / 1GB, 2) }
    $used = [math]::Round($d.size - $d.free, 2); $sz = @{}; foreach ($k in @($fo.tracked.Keys)) { $sz[$k] = & $gb $m.sizes[$k.ToLower()] }
    $known = (@($top | ForEach-Object { $sz[$_] }) | Measure-Object -Sum).Sum + (& $gb $m.rootFiles)
    $scan = @{ t = [DateTimeOffset]::Now.ToUnixTimeSeconds(); used = $used; sizes = $sz; unexplained = [math]::Round($used - $known, 2); deleted = (Get-KitHeldDeletedGB $d.root); kids = @{} }
    foreach ($k in @($fo.tracked.Keys)) { $kk = $m.kids[$k.ToLower()]; if ($kk) { $scan.kids[$k] = @{}; foreach ($x in $kk.Keys) { if ($kk[$x] -ge 50MB) { $scan.kids[$k][$x] = & $gb $kk[$x] } } } }
    $grew = @(Update-KitTracked $fo $scan @($fo.scans)[-1] $c)
    # daily scans after a day, keepDays total
    $old = @($fo.scans | Where-Object { $_.t -ge $scan.t - $c.keepDays * 86400 }); foreach ($o in $old) { $o.Remove('kids') }
    $day = @{}; $old = @($old | Where-Object { $k1 = "d$([math]::Floor($_.t / 86400))"; if ($_.t -ge $scan.t - 86400) { $true } elseif ($day.ContainsKey($k1)) { $false } else { $day[$k1] = 1; $true } })
    $fo.scans = @($old) + $scan; Write-KitAtomic $ff ($fo | ConvertTo-Json -Depth 8)
    "scan ${Drive}: used $used GB, unexplained $($scan.unexplained) GB$(if ($null -ne $scan.deleted) { ", deleted-but-open $($scan.deleted) GB" }); grew: $(if ($grew.Count) { @($grew | Select-Object -First 5 | ForEach-Object { "$($_.path) +$($_.gb) GB" }) -join '; ' } else { 'nothing above ' + $c.drillGB + ' GB' })"
  } finally { Remove-Item -LiteralPath (Get-KitStorageFile $Drive 'scan.lock') -ErrorAction SilentlyContinue }
}
# growth over the last two scans vs normal (GB/day)
function Get-KitFolderGrowth([string]$Drive, [int]$Top = 3) {
  $fo = try { Get-Content -LiteralPath (Get-KitStorageFile $Drive 'folders.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; $s = @($fo.scans); if ($s.Count -lt 2) { return @() }
  $a = $s[-2]; $b = $s[-1]; $days = [math]::Max(0.01, ($b.t - $a.t) / 86400); $span = [math]::Max(0.01, ($b.t - $s[0].t) / 86400)
  @(@($b.sizes.Keys) + '<unexplained>' | ForEach-Object { $now = if ($_ -eq '<unexplained>') { $b.unexplained } else { $b.sizes[$_] }; $was = if ($_ -eq '<unexplained>') { $a.unexplained } else { $a.sizes[$_] }; $first = if ($_ -eq '<unexplained>') { $s[0].unexplained } else { $s[0].sizes[$_] }
      [pscustomobject]@{ path = $_; gb = [double]$now; grew = [math]::Round([double]$now - [double]$was, 2); perDay = [math]::Round(([double]$now - [double]$was) / $days, 2); normal = [math]::Round([math]::Abs([double]$now - [double]$first) / $span, 2) } } |
    Where-Object { $_.grew -gt 0 } | Sort-Object grew -Descending | Select-Object -First $Top)
}
# ACT names writers, db temp, grown folders
function Get-KitStorageRound {
  $c = Get-KitStorageConf; $vs = @(Invoke-KitStorageTick -Force); $st = Get-KitStorageState
  if (-not $st.normalAt -or ((Get-Date) - [datetime]$st.normalAt).TotalHours -ge 1) {   # hourly: learned normal (14 days), retention
    $nm = @{}; $cut = [DateTimeOffset]::Now.ToUnixTimeSeconds() - $c.keepDays * 86400
    foreach ($v in $vs) { $f = Get-KitStorageFile $v.drive; $nm[$v.drive] = Get-KitDiskNormal (Get-KitStorageSamples $v.drive 20160)
      Invoke-KitLocked $f { $ls = @(Get-Content -LiteralPath $f); $keep = @($ls | Where-Object { $_ -match '"t":(\d+)' -and [long]$Matches[1] -ge $cut }); if ($keep.Count -lt $ls.Count) { Write-KitAtomic $f (($keep -join "`n") + "`n") } } }
    Set-KitStorageState { param($s) $s.normal = $nm; $s.normalAt = (Get-Date).ToString('o') }
  }
  $hm = [double]$c.holdMinutes
  foreach ($v in $vs) {
    "disk $($v.drive): $($v.free) GB free, $(if ($v.rate -ge 0) { '+' })$($v.rate) GB/h (normal $($v.normal)), $(if ([double]::IsInfinity($v.ttf)) { 'not filling' } else { "full in $($v.ttf) h" })"
    $last = if ($st.scanAt) { $st.scanAt[$v.drive] }; $since = if ($last) { ((Get-Date) - [datetime]$last).TotalMinutes } else { 1e9 }
    $rising = $st.trigger -and $st.trigger[$v.drive] -and $v.rate -gt 1.5 * [double]$st.trigger[$v.drive]
    if (($v.scan -and ($since -ge $c.scanCooldownMin -or $rising)) -or $since -ge $c.scanHours * 60 -or (($v.rescue -or $v.anomaly) -and $since -ge 10)) {
      Start-KitStorageScan $v.drive; Set-KitStorageState { param($s) if (-not $s.trigger) { $s.trigger = @{} }; $s.trigger[$v.drive] = $v.rate }
    }
    $h = if ($st.rescues) { $st.rescues[$v.drive] }; $held = $h -and ((Get-Date) - [datetime]$h.at).TotalMinutes -lt $hm
    if ($v.level -eq 'OK') { if ($h) { Set-KitStorageState { param($s) $s.rescues.Remove($v.drive) }; if ($held) { [pscustomobject]@{ level = 'INFO'; what = "disk $($v.drive) back to normal: build hold lifted"; action = 'Nothing to do.' } } }; continue }
    $why = @(); if ($v.anomaly -or $v.rescue) { $tw = @(Get-KitTopWriters); if ($tw.Count) { $why += "top writers: $(@($tw | ForEach-Object { "$($_.name) ($($_.pid)) $($_.mbs) MB/s" }) -join ', ')" }
      $q = @(Get-KitDbQueries $c | Sort-Object gb -Descending)[0]; if ($q -and $q.gb -gt 0) { $why += "db query $($q.id): $($q.gb) GB temp, $($q.secs) s" } }
    $del = Get-KitHeldDeletedGB $v.root; if ($null -ne $del) { $why += "deleted-but-open $del GB" }
    $g = @(Get-KitFolderGrowth $v.drive); if ($g.Count) { $why += "grew since the last scan: $(@($g | ForEach-Object { "$($_.path) +$($_.grew) GB ($($_.perDay) GB/day, normal $($_.normal))" }) -join '; ') (<unexplained> = deleted-but-open or no access)" }
    $what = "disk $($v.drive): $($v.free) GB free, filling $($v.rate) GB/h$(if (-not [double]::IsInfinity($v.ttf)) { ", full in $($v.ttf) h" })$(if ($v.anomaly) { " ($([math]::Round($v.rate / [math]::Max(0.1, $v.normal))) x normal)" })$(if ($why.Count) { '; ' + ($why -join '; ') })"
    $act = if ($held) { "Rescue ran $(([datetime]$h.at).ToString('HH:mm')), new builds held until $(([datetime]$h.at).AddMinutes($hm).ToString('HH:mm'))$(if (@($h.lines).Count) { ": $(@($h.lines) -join '; ')" }); stop the writer named, then bossy.ps1 storage -Drive $($v.drive) -Since 2h" } else { "Find the writer (bossy.ps1 storage -Drive $($v.drive) -Folders); run bossy.ps1 cleanup" }
    [pscustomobject]@{ level = $v.level; what = $what; action = $act }
  }
}
function Show-KitStorage {
param([string]$Drive, [string]$Since = '24h', [switch]$Folders, [switch]$Scan)
if ($Scan) { foreach ($d in @(if ($Drive) { $Drive } else { Get-KitDrives | ForEach-Object name })) { Invoke-KitStorageScan $d }; return }
$from = if ($Since -match '^(\d+)([mhd]?)$') { (Get-Date).AddMinutes(-[int]$Matches[1] * (@{ m = 1; h = 60 }[$Matches[2]] ?? 1440)) } else { [datetime]$Since }; $t0 = [DateTimeOffset]::new($from).ToUnixTimeSeconds()
foreach ($d in @(if ($Drive) { $Drive } else { Get-KitDrives | ForEach-Object name })) {
  if ($Folders) {
    $fo = try { Get-Content -LiteralPath (Get-KitStorageFile $d 'folders.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; $sc = @($fo.scans | Where-Object { $_.t -ge $t0 })
    "== $d folders: $($sc.Count) scan(s) since $($from.ToString('yyyy-MM-dd HH:mm'))$(if (-not $sc.Count) { ' (bossy.ps1 storage -Scan -Drive ' + $d + ')' })"
    if (-not $sc.Count) { continue }; $a = $sc[0]; $b = $sc[-1]; $days = [math]::Max(0.01, ($b.t - $a.t) / 86400)
    foreach ($k in @($b.sizes.Keys | Sort-Object { - [double]$b.sizes[$_] } | Select-Object -First 25)) { '{0,9:N2} GB {1,8:+0.00;-0.00} ({2,7:N2}/day)  {3}{4}' -f $b.sizes[$k], ($b.sizes[$k] - [double]$a.sizes[$k]), (($b.sizes[$k] - [double]$a.sizes[$k]) / $days), $k, $(if ($fo.tracked[$k].src -eq 'learned') { ' (learned)' }) }
    '{0,9:N2} GB {1,8:+0.00;-0.00}  <unexplained: used minus the folders: deleted-but-open, no access; hardlinks count twice: watch its change>{2}' -f $b.unexplained, ($b.unexplained - [double]$a.unexplained), $(if ($null -ne $b.deleted) { "; `$Deleted $($b.deleted) GB" })
    continue
  }
  $xs = @(Get-KitStorageSamples $d | Where-Object { $_.t -ge $t0 }); "== ${d}: $($xs.Count) sample(s) since $($from.ToString('yyyy-MM-dd HH:mm'))"
  if (-not $xs.Count) { continue }; $step = [math]::Max(1, [math]::Ceiling($xs.Count / 40)); $pv = $null
  for ($i = 0; $i -lt $xs.Count; $i += $step) { $x = $xs[$i]; $tm = [DateTimeOffset]::FromUnixTimeSeconds($x.t).LocalDateTime
    '{0}  {1,8:N1} GB free{2}' -f $tm.ToString('MM-dd HH:mm'), $x.free, $(if ($pv) { ' {0,8:+0.0;-0.0} GB' -f ($x.free - $pv.free) }); $pv = $x }
  foreach ($e in @(Read-KitLog disk $from | Where-Object { $_.drive -eq $d -or $_.event -eq 'db-kill' })) { "  $(([datetime]$e.at).ToString('MM-dd HH:mm')) $($e.event): $(if ($e.lines) { @($e.lines) -join '; ' } else { $e.query })" }
}
}
