<#
Kit library (config, paths, OS, tracker + git-host adapters). Usage (pwsh 7): dot-source: . (Join-Path <kit> 'skills/crafty/lib.ps1')
Functions only, silent. Exit codes: none. Out: $KitConf, $KitCmd, Get-KitPath, Get-KitSetting, tracker, Invoke-HostVerb.
Sections: L10 paths · L68 state · L137 config · L217 OS · L414 leases · L855 status · L1099 supervise sweep ·
  L1170 supervise report · L1266 tracker · L1589 prior · L1605 ask bugs · L1810 git-host · L1970 kitlog · L2090 params ·
  L2395 entry-scripts
#>
#Requires -Version 7
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }   # every kit script: piped stdout and child output are UTF-8 (· → £ é), never the console code page
# ---- paths: kit.example.json _paths
$script:KitRoot = Split-Path (Split-Path $PSScriptRoot)
$script:KitEntry = $MyInvocation.PSCommandPath   # the script that dot-sourced this file (Resolve-KitExtra runs it again)
$script:KitExample = Get-Content (Join-Path $PSScriptRoot 'kit.example.json') -Raw | ConvertFrom-Json; $script:KitPathMap = $script:KitExample._paths
function Get-KitRuntime { $rt = if ($env:CLAUDE_RUNTIME) { if ([IO.Path]::IsPathRooted($env:CLAUDE_RUNTIME) -or -not $script:KitRoot) { $env:CLAUDE_RUNTIME } else { Join-Path $script:KitRoot $env:CLAUDE_RUNTIME } } elseif ($script:KitRoot -and $script:KitRoot -notin '/', '\') { Join-Path $script:KitRoot $script:KitPathMap.runtimeDir }; if (-not $rt -or $rt -in '/', '\') { throw "Get-KitRuntime: bad runtime '$rt'" }; $rt }
function Get-KitPath([Parameter(Mandatory)][string]$Name, [switch]$Create) {
  $m = $script:KitPathMap
  if ($Name -eq 'runtime') { $p = Get-KitRuntime; $dir = $true }
  elseif ($m.runtime.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.runtime.$Name; $p = Join-Path (Get-KitRuntime) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  elseif ($m.durable.PSObject.Properties.Name -contains $Name) { if (-not $script:KitRoot -or $script:KitRoot -in '/', '\') { throw 'Get-KitPath: bad KitRoot' }; $rel = [string]$m.durable.$Name; $p = Join-Path (Join-Path $script:KitRoot $m.stateDir) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  else { throw "Get-KitPath: unknown name '$Name' (see skills/crafty/kit.example.json _paths)" }
  if (-not $p -or $p -in '/', '\' -or $p -match '^[A-Za-z]:[\\/]?$') { throw "Get-KitPath: root '$p'" }
  if ($Create) { New-Item -ItemType Directory -Force $(if ($dir) { $p } else { Split-Path $p }) | Out-Null }
  $p
}
# cross-process <file>.lock: stale after 2 min (Windows: holder gone); throws after 130 s, never runs unlocked
function Invoke-KitLocked([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body) {
  $lock = "$File.lock"; $fs = $null
  for ($i = 0; $i -lt 1300 -and -not $fs; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch {
      try { if ([IO.File]::Exists($lock) -and ($KitIsWindows -or ((Get-Date) - [IO.File]::GetLastWriteTime($lock)).TotalMinutes -gt 2)) { [IO.File]::Delete($lock) } } catch {}
      Start-Sleep -Milliseconds 100
    }
  }
  if (-not $fs) { $m = "Invoke-KitLocked: $lock held after 130 s"; Write-Warning $m; throw $m; return }
  try { & $Body } finally { $fs.Dispose(); try { [IO.File]::Delete($lock) } catch {} }
}
# temp + rename in one folder: a crash never leaves half a file
function Write-KitAtomic([Parameter(Mandatory)][string]$Path, [string]$Text) {
  $p = [IO.Path]::GetFullPath($Path, (Get-Location -PSProvider FileSystem).ProviderPath); $t = "$p.$PID.tmp"
  [IO.File]::WriteAllText($t, $Text, [Text.UTF8Encoding]::new($false))
  for ($i = 0; ; $i++) {
    try { [IO.File]::Move($t, $p, $true); return }
    catch {
      # Win32 87 never clears on a retry (board join failed twice): copy over, not atomic
      if (Test-KitMoveUnsupported $_.Exception) { try { [IO.File]::Copy($t, $p, $true) } finally { [IO.File]::Delete($t) }; return }
      if ($i -ge 40) { [IO.File]::Delete($t); throw }; Start-Sleep -Milliseconds 50
    }
  }
}
# rename refused by the file system, unlike a reader holding the file (retried)
function Test-KitMoveUnsupported([Exception]$Err) {
  for ($e = $Err; $e; $e = $e.InnerException) {
    if ($e -is [ArgumentException] -or ($e.HResult -band 0xFFFF) -eq 87) { return $true }
    if ($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) { return $false }
  }
  $false
}
# kit-made names (crafty.ps1 dir, briefs, checkpoints, snapshots)
function ConvertTo-KitSlug([string]$Text) { ("$Text".ToLower() -replace '[^a-z0-9.]+', '-').Trim('-.') }
# agents/<agent>/resume-<run>.json (same-named agents never overwrite); an old resume.json is still read
function Get-KitCheckpointFile([string]$Agent, [string]$Run = '', [switch]$Write) {
  $ckDir = Join-Path (Get-KitPath agents) (ConvertTo-KitSlug $Agent); $runFile = if ($Run) { Join-Path $ckDir "resume-$(ConvertTo-KitSlug $Run).json" }
  if ($runFile -and ((Test-Path -LiteralPath $runFile) -or ($Write -and "$((Read-KitState (Join-Path $ckDir 'resume.json')).run)" -ne $Run))) { return $runFile }
  if ($Run -or $Write) { return Join-Path $ckDir 'resume.json' }   # old file (same run in flight: keeps its steps); readers compare its .run
  @(@(Get-ChildItem -LiteralPath $ckDir -Filter 'resume*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object FullName) + (Join-Path $ckDir 'resume.json'))[0]
}
# ---- state: skills/bossy/STATE.md (tolerant reads, atomic writes, one file per key)
function Read-KitState([string]$Path) {   # never throws (state-lint flags the bad file)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try { $o = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($o -is [Collections.IDictionary]) { $o } } catch { Write-KitLog calls state-bad @{ file = $Path; error = "$_" } }
}
function Write-KitState([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data, [int]$Version = 1) {   # a hashtable or a JSON object
  $w = if ($script:KitWho) { $script:KitWho } else { @{} }
  $h = [ordered]@{ agent = "$($w.agent)"; session = "$env:KIT_SESSION"; pid = $PID; pidStart = (Get-KitPidStart $PID) } + (Get-KitHolder)
  foreach ($p in ([ordered]@{ schemaVersion = $Version; updated = (Get-Date).ToString('o'); holder = $h }).GetEnumerator()) {
    if ($Data -is [Collections.IDictionary]) { $Data[$p.Key] = $p.Value } else { $Data | Add-Member -Force NoteProperty $p.Key $p.Value } }
  New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null; Write-KitAtomic $Path ($Data | ConvertTo-Json -Depth 32)
}
# .state/tasks/<id>.json (track, docs, comments, envRuns): agents read it, not tracker comments
function Get-KitTaskFile([string]$Task) { Join-Path (Get-KitPath tasks) "$($Task -replace '[^\w.-]', '_').json" }
function Update-KitTaskIndex([Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][scriptblock]$Change) {
  $f = Get-KitTaskFile $Task; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  Invoke-KitLocked $f { $x = Read-KitState $f; if (-not $x) { $x = [ordered]@{ task = $Task } }; foreach ($k in 'docs', 'comments') { if ($x[$k] -isnot [Collections.IDictionary]) { $x[$k] = @{} } }; $x.envRuns = @($x.envRuns | Where-Object { $_ }); & $Change $x; Write-KitState $f $x }
}
# a legacy tracking.json is read until the first write migrates and deletes it
function Read-KitTracking([switch]$Strict) {
  $t = @{ tasks = @{}; automerge = @{} }; $f = Get-KitPath tracking
  if (Test-Path -LiteralPath $f) {
    try { $old = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable; foreach ($s in 'tasks', 'automerge') { if ($old.$s -is [Collections.IDictionary]) { foreach ($k in @($old.$s.Keys)) { $t.$s[$k] = $old.$s[$k] } } } }
    catch { $m = "tracking: $f is not valid JSON ($_)"; if ($Strict) { Copy-Item $f "$f.bad-$(Get-Date -Format yyyyMMddHHmmss)" -Force; throw "$m - fix or remove it; not writing" }; Write-Warning $m }
  }
  foreach ($g in @(Get-ChildItem -LiteralPath (Get-KitPath tasks) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $x = Read-KitState $g.FullName
    if ($x.track -is [Collections.IDictionary] -and $x.task) { $t.tasks[$x.task] = $x.track } elseif (-not $x -and $Strict -and -not (Test-Path "$($g.FullName).bad-*")) { Copy-Item $g.FullName "$($g.FullName).bad-$(Get-Date -Format yyyyMMddHHmmss)" -Force; Write-Warning "tracking: $($g.FullName) unreadable (copy kept)" }
  }
  $am = (Read-KitState (Get-KitPath automerge)).refs; if ($am -is [Collections.IDictionary]) { foreach ($k in @($am.Keys)) { $t.automerge[$k] = $am[$k] } }
  $t
}
function Update-KitTracking([Parameter(Mandatory)][scriptblock]$Change) {
  $lk = Join-Path (Get-KitPath tasks -Create) '_tracking'; $f = Get-KitPath tracking
  Invoke-KitLocked $lk {
    $t = Read-KitTracking -Strict; $was = @{}; foreach ($k in @($t.tasks.Keys)) { $was[$k] = $t.tasks[$k] | ConvertTo-Json -Depth 8 -Compress }
    $am0 = $t.automerge | ConvertTo-Json -Compress; $move = Test-Path -LiteralPath $f
    & $Change $t
    foreach ($k in @($t.tasks.Keys)) { if ($move -or $was[$k] -cne ($t.tasks[$k] | ConvertTo-Json -Depth 8 -Compress)) { $tr = $t.tasks[$k]; Update-KitTaskIndex $k { param($x) $x.track = $tr } } }
    foreach ($k in @($was.Keys | Where-Object { -not $t.tasks.ContainsKey($_) })) { Update-KitTaskIndex $k { param($x) $x.Remove('track') } }   # its docs and comments stay
    if ($move -or $am0 -cne ($t.automerge | ConvertTo-Json -Compress)) { Write-KitState (Get-KitPath automerge) ([ordered]@{ refs = $t.automerge }) }
    if ($move) { Remove-Item -LiteralPath $f -Force }
  }
}
# a task deleted in the tracker (404 + "not found", never an outage or missing CLI): dropped from tracking
function Remove-KitGoneTask([string]$Id, $Err) {
  if ("$Err" -notmatch '(?is)(?=.*\b404\b)(?=.*\b(task|issue|item|ticket)\b[^.]{0,30}\b(not found|does not exist|deleted)\b)|could not resolve to an? issue') { return $false }
  Update-KitTracking { param($t) Write-KitLog calls task-gone @{ task = $Id; error = "$Err"; entry = $t.tasks[$Id] }; $t.tasks.Remove($Id) }; $true
}
function Set-KitTaskFields([Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][hashtable]$Fields) {
  Update-KitTracking { param($t) if ($t.tasks[$Task]) { foreach ($k in $Fields.Keys) { $t.tasks[$Task][$k] = $Fields[$k] } } }
}
# a task's tracker id in a branch or MR title (tracker.branchTag)
function Get-KitTaskTagRx { if ($KitConf.TrackerTag) { "(?i)$([regex]::Escape($KitConf.TrackerTag))(?<id>[A-Za-z0-9]+)" } else { '' } }
# repo!iid in some task's track: repos match on last path segment, via repoAliases
function Test-KitMrTracked([string]$Repo, [string]$Iid, $Tracking) {
  if (-not $Tracking) { $Tracking = Read-KitTracking }
  $al = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $al[$p.Name.ToLower()] = [string]$p.Value } }
  $names = { param($r) $l = ("$r".TrimEnd('/') -split '/')[-1].ToLower(); @($l) + @(if ($al[$l]) { ($al[$l] -split '/')[-1].ToLower() }) }
  $want = @(& $names $Repo)
  foreach ($x in @($Tracking.tasks.Values)) {
    foreach ($r in @($x.mrs)) {
      $r = "$r".Trim(); if (($u = ConvertFrom-MrUrl $r)) { $r = "$($u.repo)!$($u.n)" }
      if ($r -match '^(?<r>[\w./-]+)!(?<i>\d+)$' -and $Matches.i -eq $Iid -and (-not $Repo -or @(& $names $Matches.r | Where-Object { $_ -in $want }).Count)) { return $true }
    }
  }
  $false
}

# ---- config: kit.local.json
$__devkit = $PSScriptRoot
$__kit = Split-Path (Split-Path $__devkit)
$__ws = Split-Path $__kit
$__cfg = $null
$__cfgFile = Join-Path $__devkit 'kit.local.json'
if (-not (Test-Path $__cfgFile)) {
  $__cd = "$(git -C $__devkit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($__cd) { $__alt = Join-Path (Split-Path $__cd) 'skills/crafty/kit.local.json'; if (Test-Path $__alt) { $__cfgFile = $__alt } }
}
if (Test-Path $__cfgFile) { try { $__cfg = Get-Content $__cfgFile -Raw | ConvertFrom-Json } catch { Write-Warning "ignoring $__cfgFile (invalid JSON): $_" } }
function Get-KitValue([string]$Name, $Default) { if ($__cfg -and $null -ne $__cfg.$Name -and "$($__cfg.$Name)" -ne '') { return $__cfg.$Name }; $Default }   # arrays stay whole
function Get-KitSetting([string]$Path, $Default) {
  $cur = $__cfg
  foreach ($part in $Path -split '\.') {
    if ($null -eq $cur -or -not ($cur.PSObject.Properties.Name -contains $part)) { return $Default }
    $cur = $cur.$part
  }
  if ($cur -is [array]) { if (-not $cur.Count) { return $Default } } elseif ($null -eq $cur -or "$cur" -eq '') { return $Default }   # a list of objects stringifies to ''
  $cur
}
$__reportType = [string]$(if ($env:KIT_REPORT_TYPE) { $env:KIT_REPORT_TYPE } else { Get-KitSetting 'reports.type' $(if (Get-Command gws -ErrorAction SilentlyContinue) { 'gdocs' } else { 'markdown' }) })
$__trLp = [string](Get-KitSetting 'tracker.statusLabelPrefix' 'status:')   # github / gitlab status labels
$__trType = ([string]$(if ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { Get-KitSetting 'tracker.type' 'none' })).ToLower()
$__trTag = [string](Get-KitSetting 'tracker.branchTag' $(switch ($__trType) { 'clickup' { 'CU-' } 'github' { 'GH-' } 'gitlab' { 'GL-' } default { '' } }))
$__repos = Get-KitValue 'reposRoot' $__ws
$__wtRoots = @(@($env:CLAUDE_WT_ROOT) + @(Get-KitValue 'worktreeRoots' @("$__repos-wt")) | Where-Object { $_ } | Select-Object -Unique)
$KitConf = [pscustomobject]@{
  Kit = $__kit
  Workspace = $__ws
  Runtime = (Get-KitRuntime)
  ConfigFile = $__cfgFile
  ReposRoot = $__repos
  WorktreeRoots = $__wtRoots
  GitHost = [string](Get-KitValue 'gitHost' 'gitlab.com')
  GitlabGroup = [string](Get-KitValue 'gitlabGroup' '')
  TrackerRepos = @(Get-KitValue 'trackerRepos' @())
  RepoAliases = (Get-KitValue 'repoAliases' $null)
  ProtectedBranches = @(Get-KitValue 'protectedBranches' @())     # besides main/master/develop/release/*
  TrackerType = $__trType
  TrackerTag = $__trTag
  ReportType = $__reportType.ToLower()
  MaxBrowserProfiles = [int](Get-KitSetting 'cleanup.maxBrowserProfiles' 4)
  ClaudeProjectDir = (Join-Path (Join-Path $HOME '.claude/projects') ($__ws -replace '[^A-Za-z0-9]', '-'))
}

function Split-KitList([object[]]$Values, [string]$Sep = '[\s,]+') {
  @(foreach ($v in @($Values)) {
      $v = "$v"
      $q = [regex]::Matches($v, '''([^'']*)''|"([^"]*)"')
      if ($q.Count -and [regex]::Replace($v, '''[^'']*''|"[^"]*"', '') -match '^[\s,;]*$') { foreach ($m in $q) { $m.Groups[1].Value + $m.Groups[2].Value } }
      else { $v -split $Sep | ForEach-Object { $_.Trim().Trim("'", '"').Trim() } }
    }) | Where-Object { $_ }
}

# ----- git: no prompts, no hangs (< 1 KB/s for 30 s = abort)
if (-not $env:GIT_TERMINAL_PROMPT) { $env:GIT_TERMINAL_PROMPT = '0' }
if (-not $env:GIT_HTTP_LOW_SPEED_LIMIT) { $env:GIT_HTTP_LOW_SPEED_LIMIT = '1000'; $env:GIT_HTTP_LOW_SPEED_TIME = '30' }
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=15' }
function Get-KitMemo([hashtable]$Cache, [string]$Key, [int]$TtlSec, [scriptblock]$Getter) {
  if ($Cache.ContainsKey($Key) -and ((Get-Date) - $Cache[$Key].at).TotalSeconds -lt $TtlSec) {
    if ($null -ne $Cache[$Key].v) { return $Cache[$Key].v }
    return $Cache[$Key].ok
  }
  $res = & $Getter
  if ($null -ne $res) { $Cache[$Key] = @{ at = Get-Date; v = $res; ok = $res } }
  $res
}
if (-not $global:KitFetched) { $global:KitFetched = @{} }
function Invoke-GitFetch([string]$Dir, [int]$TimeoutSec = 60, [string[]]$Refs = @()) {
  $common = "$(git -C $Dir rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim(); if (-not $common) { return $false }
  $key = "$common|$($Refs -join ',')"
  [bool](Get-KitMemo $global:KitFetched $key 600 {
    $a = @('-C', $Dir, 'fetch', '-q', '--prune', 'origin') + @($Refs | Where-Object { $_ })
    $r = Invoke-KitExe git $a $TimeoutSec
    if ($r.timedOut) { Write-Warning "git fetch in $Dir timed out after $TimeoutSec s (skipped)" }
    elseif ($r.code) { Write-Warning "git fetch in $Dir failed (exit $($r.code)): $("$($r.err)".Trim() -split "`n" | Select-Object -Last 1)" }
    if (-not $r.timedOut -and $r.code -eq 0) { $true }   # a failure is not memoized: the next caller fetches again
  })
}
# ---- OS: helpers (Windows, Linux, macOS)
$KitIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$KitIsMac = (-not $KitIsWindows) -and ($PSVersionTable.OS -match 'Darwin' -or ((Test-Path variable:IsMacOS) -and $IsMacOS))

function Get-KitTemp { [IO.Path]::GetTempPath().TrimEnd([char]'\', [char]'/') }

function Get-ExeName([string]$Name) { if ($KitIsWindows) { "$Name.exe" } else { $Name } }

function Get-SysMem {
  $kv = { param($lines, $re) $h = @{}; foreach ($l in $lines) { if ($l -match $re) { $h[$Matches[1]] = [double]$Matches[2] } }; $h }
  if ($KitIsWindows) {
    $total = (Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes, CacheBytes
    $cache = $pm.CacheBytes / 1GB   # system file cache: resident, trimmed only under pressure
    $avail = $pm.AvailableMBytes / 1KB   # Available = free + standby (the cache is not "used")
    $free = (Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1MB
  }
  elseif ($KitIsMac) {
    $total = [double](sysctl -n hw.memsize) / 1GB
    $vm = vm_stat
    $page = if (($vm | Select-Object -First 1) -match 'page size of (\d+)') { [double]$Matches[1] } else { 4096 }
    $n = & $kv $vm '^(Pages [^:]+):\s+(\d+)'
    $free = ($n['Pages free'] + $n['Pages speculative']) * $page / 1GB
    $avail = $free + ($n['Pages inactive'] + $n['Pages purgeable']) * $page / 1GB
  }
  else {
    $m = & $kv (Get-Content /proc/meminfo) '^(\w+):\s+(\d+)'
    $total = $m['MemTotal'] / 1MB
    $free = $m['MemFree'] / 1MB
    $avail = $(if ($m.ContainsKey('MemAvailable')) { $m['MemAvailable'] } else { $m['MemFree'] + $m['Cached'] + $m['Buffers'] }) / 1MB
  }
  [pscustomobject]@{ TotalGB = [math]::Round($total, 1); AvailGB = [math]::Round($avail, 1); FreeGB = [math]::Round($free, 1); CacheGB = [math]::Round([double]$cache, 1) }
}

function Get-FreeGB { $m = Get-SysMem; if ($KitIsWindows) { $m.FreeGB } else { $m.AvailGB } }
# CPU busy % (non-Windows: 1-min load average per core)
function Get-SysCpu {
  try { if ($KitIsWindows) { [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -Property PercentProcessorTime -ErrorAction Stop).PercentProcessorTime }
    else { $la = if ($KitIsMac) { [double]((sysctl -n vm.loadavg) -replace '[{}]' -split '\s+' | Where-Object { $_ })[0] } else { [double]((Get-Content /proc/loadavg) -split ' ')[0] }; [int][math]::Min(100, 100 * $la / [Environment]::ProcessorCount) } } catch { $null }
}
# RAM every build, phone and QA seat leaves free
# the file cache is freed only under RAM pressure, which a gate never allows: half of it counts as available
function Get-GateAvailGB($Mem) { [math]::Round([double]$Mem.AvailGB + 0.5 * [double]$Mem.CacheGB, 1) }
# bossy.ps1 storage disk-rescue hold on a kit drive: crafty.ps1 gate holds new builds
function Get-KitDiskHold { $hs = try { (Get-Content -LiteralPath (Join-Path (Get-KitPath storage) 'state.json') -Raw -ErrorAction Stop | ConvertFrom-Json).rescues } catch { $null }; @($hs.PSObject.Properties.Value | Where-Object { $_.kit -and ((Get-Date) - [datetime]$_.at).TotalMinutes -lt [double](Get-KitSetting 'storage.holdMinutes' 60) })[0] }
# after 20 min waiting, a start needs only a hard floor
function Test-GateStart([double]$Left, [double]$KeepFree, [double]$WaitedMin, [double]$TotalGB) {
  $Left -ge $KeepFree -or ($WaitedMin -ge 20 -and $Left -ge [math]::Max(3, $TotalGB * 0.05))
}
# one process snapshot shared by many Get-KitTreeGB calls
function Get-KitProcSnap {
  $snap = @{ procs = @{}; kids = @{}; names = @{} }
  foreach ($p in Get-SysProcs -NoCommandLine) {
    $snap.procs[$p.Id] = $p.WorkingSet; $snap.names[$p.Id] = $p.Name
    if (-not $snap.kids.ContainsKey($p.ParentId)) { $snap.kids[$p.ParentId] = [Collections.ArrayList]::new() }
    [void]$snap.kids[$p.ParentId].Add($p.Id)
  }
  $snap
}
function Get-KitTreeGB([int]$Root, $Snap = $(Get-KitProcSnap)) {
  $sum = 0; $stack = [Collections.Stack]::new(); $stack.Push($Root)
  while ($stack.Count) {
    $node = $stack.Pop()
    if ($Snap.procs.ContainsKey($node)) { $sum += $Snap.procs[$node] }
    if ($Snap.kids.ContainsKey($node)) { foreach ($k in $Snap.kids[$node]) { $stack.Push($k) } }
  }
  $sum / 1GB
}
function ConvertFrom-PsElapsed([string]$e) {
  if ($e -notmatch '^(\d+-)?(\d+:){1,2}\d+$') { return $null }
  $d = 0; if ($e -match '^(\d+)-(.*)$') { $d = [int]$Matches[1]; $e = $Matches[2] }
  $s = 0; foreach ($x in $e -split ':') { $s = $s * 60 + [int]$x }
  (Get-Date).AddSeconds(-($s + 86400 * $d))
}
function Get-SysProcs([string]$Name, [switch]$NoCommandLine) {   # -NoCommandLine: faster on Windows, no CommandLine/Created
  $all = if ($KitIsWindows) {
    $props = if ($NoCommandLine) { 'ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize' } else { 'ProcessId', 'ParentProcessId', 'Name', 'CommandLine', 'ExecutablePath', 'WorkingSetSize', 'CreationDate', 'PrivatePageCount', 'KernelModeTime', 'UserModeTime' }
    foreach ($p in Get-CimInstance Win32_Process -Property $props -ErrorAction SilentlyContinue) {   # Private: bytes; Cpu: seconds used
      [pscustomobject]@{ Id = [int]$p.ProcessId; ParentId = [int]$p.ParentProcessId; Name = $p.Name; CommandLine = $p.CommandLine; Path = $p.ExecutablePath; WorkingSet = [double]$p.WorkingSetSize; Created = $p.CreationDate; Private = [double]$p.PrivatePageCount; Cpu = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7 }
    }
  }
  else {
    $names = @{}
    foreach ($l in (ps -A -o pid= -o comm= 2>$null)) { if ($l -match '^\s*(\d+)\s+(.*)$') { $names[[int]$Matches[1]] = Split-Path $Matches[2].Trim() -Leaf } }
    foreach ($l in (ps -A -o pid= -o ppid= -o rss= -o etime= -o args= 2>$null)) {
      if ($l -notmatch '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s?(.*)$') { continue }
      $id = [int]$Matches[1]; $cl = $Matches[5]; $n = [string]$names[$id]
      $exe = Split-Path (($cl -split '\s+')[0]) -Leaf
      if ($n.Length -ge 15 -and $exe.StartsWith($n)) { $n = $exe }
      [pscustomobject]@{ Id = $id; ParentId = [int]$Matches[2]; Name = $n; CommandLine = $cl; Path = ($cl -split '\s+')[0]; WorkingSet = [double]$Matches[3] * 1KB; Created = (ConvertFrom-PsElapsed $Matches[4]); Private = [double]$Matches[3] * 1KB; Cpu = $null }
    }
  }
  if ($Name) { @($all | Where-Object { $_.Name -match $Name }) } else { @($all) }
}

function Stop-SysProcess([int]$Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
function Get-KitBudget([string]$Tool = '', [string]$Model = '', [int]$Window = 0) {
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget
  $row = { param($n) $o = Get-KitSetting "budget.defaults.$n" $null; if ($o) { $o } else { $ex.defaults.$n } }
  $envs = @(Get-ChildItem env: | ForEach-Object Name)
  if (-not $Tool) {
    $Tool = if ($Model -match '^(claude|opus|sonnet|haiku)') { 'claude' }
    elseif ($Model -match '^gpt') { 'codex' }
    elseif ($Model -match '^gemini') { 'antigravity' }
    elseif ($v = $env:KIT_TOOL) { $v }
    elseif ($env:CLAUDECODE) { 'claude' }
    elseif ($envs -like 'CODEX_*') { 'codex' }
    elseif ($envs -match 'ANTIGRAVITY') { 'antigravity' }
    else { 'unknown' }
  }
  $n = 'unknown'; $tok = 0; $src = ''
  if ($Tool -eq 'claude') {
    if (-not $Model) { $Model = "$env:ANTHROPIC_MODEL" }
    $m = $Model.ToLower(); $big = $m -match '\[1m\]|fable|^(opus|sonnet|haiku|inherit|default)?$'
    if ($m -match '(opus|sonnet|haiku)-(\d+)(?:-(\d)(?!\d))?') { $big = $big -or ([double]$Matches[2] + [double]"0$($Matches[3])" / 10) -ge @{ opus = 4.7; sonnet = 5; haiku = 5.5 }[$Matches[1]] }
    if ($big -or $m -match 'claude|opus|sonnet|haiku') {
      if ($env:CLAUDE_CODE_DISABLE_1M_CONTEXT -eq '1') { $big = $false }
      $n = if ($big) { 'claude-1m' } else { 'claude-200k' }; $tok = [int](& $row $n).tokens
      if ($v = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $tok = [int]$v; $src = 'env CLAUDE_CODE_AUTO_COMPACT_WINDOW' }
      if ($v = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE) { $tok = [math]::Min($tok, [int]($(if ($big) { 1e6 } else { 2e5 }) * [double]$v / 100)); $src = 'env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' }
    }
  } elseif ($Tool -eq 'codex') {
    $ch = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $tt = "$(Get-Content (Join-Path $ch 'config.toml') -Raw -ErrorAction SilentlyContinue)"
    if (-not $Model -and $tt -match '(?m)^\s*model\s*=\s*"([^"]+)"') { $Model = $Matches[1] }
    $mc = try { @((Get-Content (Join-Path $ch 'models_cache.json') -Raw | ConvertFrom-Json).models | Where-Object slug -eq $Model)[0] } catch { $null }
    $n = 'codex'
    if ($tt -match '(?m)^\s*model_auto_compact_token_limit\s*=\s*(\d+)') { $tok = [int]$Matches[1]; $src = 'config.toml model_auto_compact_token_limit' }
    elseif ($v = $mc.auto_compact_token_limit) { $tok = [int]$v; $src = 'models_cache.json auto_compact_token_limit' }
    else {
      $w = if ($v = $mc.context_window) { [double]$v * $(if ($q = $mc.effective_context_window_percent) { [double]$q } else { 100 }) / 100 } else { $Window }
      $tok = [int]($w * [double](& $row $n).fraction)
    }
  } elseif ($Tool -eq 'antigravity' -and $Window) { $n = 'antigravity'; $tok = [int]($Window * [double](& $row $n).fraction) }
  if (-not $tok) { $n = 'unknown'; $tok = [int](& $row $n).tokens }
  $h = [double](Get-KitSetting 'budget.handoffAt' $ex.handoffAt)
  [pscustomobject]@{ tool = $Tool; model = $Model; row = $n; budget = $tok; handoff = [int]($tok * $h); handoffAt = $h; runStopAt = [double](Get-KitSetting 'budget.runStopAt' $ex.runStopAt); source = $(if ($src) { $src } else { (& $row $n).source }) }
}
# reads only the last 512 KB (then 8 MB): Get-Content -Tail took 1.3 s per MB-sized transcript
function Get-KitSpend([string]$File) {
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $null }
  foreach ($cap in 512KB, 8MB) {
    $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite, Delete')
    try { $n = [int][math]::Min($fs.Length, $cap); $null = $fs.Seek(-$n, 'End'); $b = [byte[]]::new($n); $null = $fs.Read($b, 0, $n); $whole = $n -ge $fs.Length } finally { $fs.Dispose() }
    $t = @([Text.Encoding]::UTF8.GetString($b) -split "`r?`n" | Select-Object -Skip $(if ($whole) { 0 } else { 1 }))   # a cut tail's first line is partial
    $r = Read-KitSpendLines $t; if ($r -or $whole) { return $r }
  }
}
function Read-KitSpendLines([string[]]$t) {
  for ($i = $t.Count - 1; $i -ge 0; $i--) {
    if ($t[$i] -match '"token_count"') {   # Codex rollout: the last request's context = its compaction measure
      $o = try { $t[$i] | ConvertFrom-Json -Depth 40 } catch { continue }; $u = $o.payload.info.last_token_usage; if ($u) { return [pscustomobject]@{ spend = [int]$u.total_tokens; model = '' } }
    }
    if ($t[$i] -notmatch '"usage"') { continue }
    $o = try { $t[$i] | ConvertFrom-Json -Depth 40 } catch { continue }; $u = $o.message.usage; if (-not $u) { continue }
    return [pscustomobject]@{ spend = [int]($u.input_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens + $u.output_tokens); model = "$($o.message.model)" }
  }
}
function Find-KitTranscript([string]$Marker, [string]$Filter = '*.jsonl', [string]$Root) {
  $root = if ($Root) { $Root } elseif ($v = $env:KIT_TRANSCRIPTS) { $v } else { $KitConf.ClaudeProjectDir }; $sid = "$env:CLAUDE_CODE_SESSION_ID"
  foreach ($f in @(Get-ChildItem $root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } | Sort-Object { -not $sid -or $_.FullName -notmatch [regex]::Escape($sid) }, { -$_.LastWriteTime.Ticks })) {
    if (Select-String -LiteralPath $f.FullName -SimpleMatch $Marker -Quiet) { return $f.FullName }
  }
}

$script:KitShells = '^(pwsh|powershell|bash|sh|zsh|dash|fish|cmd|conhost|env|timeout|sudo|python\d*(\.\d+)?|py)$'
function Get-KitHolder {
  $p = Get-Process -Id $PID -ErrorAction SilentlyContinue
  for ($i = 0; $p -and $i -lt 12; $i++) {
    $q = $p.Parent; if (-not $q) { break }
    if ($q.ProcessName -notmatch $script:KitShells) { return [ordered]@{ holderPid = $q.Id; holderStart = $(try { $q.StartTime.ToUniversalTime().ToString('o') } catch { '' }) } }
    $p = $q
  }
  [ordered]@{ holderPid = $null; holderStart = '' }
}
# supervise lock owner = the heartbeat's session, not this pwsh (a new pid each round would step aside from itself)
function Get-SuperviseOwner([string]$Session) {
  if ($Session) { return $Session }
  if ($env:CLAUDE_CODE_SESSION_ID) { return $env:CLAUDE_CODE_SESSION_ID }
  $h = Get-KitHolder; if ($h.holderPid) { return "holder$($h.holderPid)" }
  # only shells above (detached background shell): the topmost one is stable across rounds
  $top = $PID; $p = Get-Process -Id $PID -ErrorAction SilentlyContinue
  for ($i = 0; $p -and $i -lt 12; $i++) { $p = $p.Parent; if ($p) { $top = $p.Id } }
  if ($top -ne $PID) { "shell$top" } else { "pid$PID" }
}
# Linux / macOS monotonic clocks stop in suspend; Windows TickCount64 does not
function Get-KitBootTime { try { if ($KitIsWindows) { (Get-Date).AddMilliseconds(-[Environment]::TickCount64) } elseif ($KitIsMac) { [DateTimeOffset]::FromUnixTimeSeconds([long]([regex]::Match((sysctl -n kern.boottime), 'sec = (\d+)').Groups[1].Value)).LocalDateTime }
    else { [DateTimeOffset]::FromUnixTimeSeconds([long](((Get-Content /proc/stat) -match '^btime ' -split ' ')[1])).LocalDateTime } } catch { (Get-Date).AddMilliseconds(-[Environment]::TickCount64) } }
function Get-KitPidStart([int]$Id) { try { (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { '' } }
# same pid + start time: a cold boot reuses pids. $Start untyped: JSON gives a DateTime
function Test-KitPid($Id, $Start) {
  $p = if ($Id) { Get-Process -Id ([int]$Id) -ErrorAction SilentlyContinue }; if (-not $p) { return $false }
  if ($Start) { $s0 = try { [datetimeoffset]$Start } catch { return $false }   # a malformed start: not provably the same process
    try { return [math]::Abs(([datetimeoffset]$p.StartTime - $s0).TotalSeconds) -lt 2 } catch {} }
  $true
}
function Test-KitHolder($o) { if (-not $o -or -not $o.holderPid) { return $null }; Test-KitPid $o.holderPid $o.holderStart }
# ---- leases: README "Leases"; one rule for env services, browsers, phones, builds
function Set-KitProp($o, [string]$k, $v) { if ($o -is [Collections.IDictionary]) { $o[$k] = $v } else { $o | Add-Member -Force NoteProperty $k $v } }
function New-KitLease([string]$Agent, [string]$Session = '', [int]$OwnerMinutes = 0, [int]$ProcessId = 0) {
  $l = [ordered]@{ agent = $Agent; session = $Session; at = (Get-Date).ToString('o') } + (Get-KitHolder); Test-KitLeaseBack $Agent
  $rn = if ($script:KitWho.run) { $script:KitWho.run } else { "$env:KIT_RUN" }; if ($rn) { $l.run = $rn }
  if ($OwnerMinutes) { $l.owner = $true; $l.until = (Get-Date).AddMinutes($OwnerMinutes).ToString('o') }   # only owner holds keep minutes
  if ($ProcessId) { $l.pid = $ProcessId; $l.pidStart = Get-KitPidStart $ProcessId }; $l
}
$script:KitLiveCache = @{}
function Get-KitLiveCached([string]$k, [scriptblock]$b) { $c = $script:KitLiveCache[$k]; if (-not $c -or ((Get-Date) - $c.at).TotalSeconds -gt 15) { $c = @{ at = Get-Date; v = (& $b) }; $script:KitLiveCache[$k] = $c }; $c.v }
function Test-KitLive($l) {
  $now = Get-Date; $bm = [double](Get-KitParam 'idle.beatMinutes'); $a = "$($l.agent)"
  if ($l.owner -or ($l.until -and -not $a -and -not $l.holderPid)) { return [datetime]$l.until -gt $now }   # a pre-lease hold keeps its minutes
  if ($l.pid -and (Test-KitPid $l.pid $l.pidStart)) { return $true }
  $ls = Get-KitLiveCached steps { try { $s = Get-Content (Get-KitPath live-steps) -Raw | ConvertFrom-Json; if (((Get-Date) - [datetime]$s.at).TotalMinutes -lt $bm) { $s } } catch {} }
  $mine = @($ls.labels | Where-Object { ($a -and (($_ -split ':', 2)[-1] -split '@')[0] -eq $a) -or ($l.lane -and $_ -match "@$([regex]::Escape($l.lane))$") })
  if (@($mine | Where-Object { $_ -in @($ls.running) }).Count) { return $true }
  $all = @(Get-KitLiveCached board { @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} }) } |
    Where-Object { if ($l.session) { $_.session -eq $l.session } else { ($_.agent -and $_.agent -in @($a, $l.holder)) -or ($l.holder -and $_.session -eq $l.holder) } })
  $fresh = { param($e, $m) $x = Get-KitLiveCached "act:$($e.session)/$($e.agent)/$($e.run)" { Get-KitLastActivity "$($e.transcript)" $e "$($e.tool)" }; $x -and ($now - $x).TotalMinutes -lt $m }   # a silent agent writing its transcript is live
  if (@($all | Where-Object { $_.status -ne 'left' -and ((& $fresh $_ $bm) -or ($_.pid -and (Test-KitPid $_.pid $_.pidStart))) }).Count) { return $true }
  if ($mine.Count -or $l.session) { return $false }   # its step finished / its board entry left or went quiet
  if ($a -match '^(main|coordinator)$') { $f = Get-Item (Get-KitPath supervise-state) -ErrorAction SilentlyContinue; if ($f -and ($now - $f.LastWriteTime).TotalMinutes -lt [math]::Max($bm, (Get-KitBeatMinutes) + 5)) { return $true } }   # its heartbeat writes it
  if ($all.Count -and -not @($all | Where-Object { $_.status -ne 'left' -and (& $fresh $_ (3 * $bm)) }).Count) { return $false }   # left / long quiet: its holder pid is the shared session process (a subagent)
  (Test-KitHolder $l) -eq $true
}
# last supervise NEXT; one older than 2 beats = coordinator stopped
function Get-KitBeatMinutes {
  $s = try { Get-Content (Get-KitPath supervise-state) -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  if ($s.nextBeat -and $s.report.at -and ((Get-Date) - [datetime]$s.report.at).TotalMinutes -lt 2 * [double]$s.nextBeat) { [double]$s.nextBeat } else { [double](Get-KitParam 'supervise.heartbeatMinutes') }
}
# health: the beat supervise asked for passed while agents live (a one-shot dies with a restart or a busy session)
function Get-KitBeatOverdue([datetime]$Now = (Get-Date)) {
  $s = try { Get-Content (Get-KitPath supervise-state) -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  if (-not $s.report.at -or -not $s.nextBeat) { return }
  $last = [datetime]$s.report.at; $due = $last.AddMinutes([double]$s.nextBeat); $late = [int]($Now - $due).TotalMinutes
  $bm = [double](Get-KitParam 'idle.beatMinutes')
  $live = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -notin 'left', 'crashed' -and $_.beat -and ($Now - [datetime]$_.beat).TotalHours -lt [double](Get-KitParam 'board.rowHours') -and ($a = Get-KitLastActivity "$($_.transcript)" $_ "$($_.tool)") -and ($Now - $a).TotalMinutes -lt $bm })   # board Active or writing its transcript
  if ($late -gt 0 -and $live.Count) { "heartbeat OVERDUE $late min: last beat $($last.ToString('HH:mm')), next was due $($due.ToString('HH:mm')), $($live.Count) agent(s) live: run supervise now, then arm one one-shot (bossy E1)" }
}
# heartbeat prompt (bossy E1)
function Get-KitBeatPrompt { "Run & '$($KitCmd.orch -replace '\\', '/')' supervise -AutoFix -Brief. Act on every ACT and WATCH line; re-arm this one-shot with this same prompt (stderr HEARTBEAT_PROMPT) to stderr NEXT=<n> min. Reply = 1-4 lines of the actions taken this beat, plus one line only when an ACT needs the owner; never paste the stdout (detail: supervise-report.html) (bossy E1)." }
# base = learned heartbeatMinutes (15: how often new ACTs appear); drifts back halfway per beat
# Act / EnvFix = NEW since the last sweep: an ACT left open (owner's call, being fixed) keeps the normal pace
function Get-KitNextBeat([double]$Prev, [double]$Base, [int]$Act, [int]$EnvFix, [bool]$Storage, [int]$BuildFails, [int]$Agents, [int]$Live, [int]$Running) {
  $many = [int](Get-KitParam 'supervise.manyAgents')
  $r = if ($Act -or $EnvFix) { @(5, $(if ($EnvFix) { "fast pace: $EnvFix new ENV-FIX" } else { "fast pace: $Act new ACT" })) }
    elseif ($Storage -or $BuildFails -ge 3 -or $Agents -ge $many) { @([math]::Round($Base / 2), "quick pace: $(if ($Storage) { 'storage anomaly' } elseif ($BuildFails -ge 3) { "$BuildFails failed builds in a row" } else { "$Agents live agents" })") }
    elseif (-not $Running -and -not $Agents) { @(30, 'slow pace: nothing runs') }
    elseif (-not $Live) { @([math]::Round(($Base + 30) / 2), 'slow pace: every agent idle') }
    elseif ([math]::Abs($Prev - $Base) -le 2) { @($Base, 'normal pace') }
    else { @([math]::Round(($Prev + $Base) / 2), "easing back to $Base min") }
  [pscustomobject]@{ min = [int][math]::Min(30, [math]::Max(5, $r[0])); why = $r[1] }
}
# track's LAG / missing-doc ATTENTION of a task held on purpose: dropped (the background run may predate the hold)
function Test-KitHeldLine([string]$Line, [string[]]$Held) { $Line -match '^(LAG|ATTENTION) (?<tid>[^\s:]+):' -and $Matches.tid -in $Held -and ($Line -match '^LAG' -or $Line -match 'no (solution/testing comment|testing-doc link)') }
function Update-KitLease($l) {
  $now = Get-Date
  if (Test-KitLive $l) {   # seen at most once a minute: re-confirming a live holder writes nothing
    if ($null -ne $l.graceLeft -and $l.seen) { Add-KitParamObs 'idle.graceMinutes' ($now - [datetime]$l.seen).TotalMinutes -Default 10 }   # how long a live holder went silent
    if (-not $l.seen -or ($now - [datetime]$l.seen).TotalSeconds -ge 60) { Set-KitProp $l seen $now.ToString('o') }
    if ($null -ne $l.graceLeft) { Set-KitProp $l graceLeft $null; Set-KitProp $l graceMin $null; Set-KitProp $l released $null }; return $true
  }
  if ($l.owner -or ($l.until -and -not $l.agent -and -not $l.holderPid)) { return $false }
  if (-not $l.seen) { Set-KitProp $l seen $now.ToString('o') }   # first seen dead: the grace starts now
  if ($null -eq $l.graceMin) { Set-KitProp $l graceMin ([double](Get-KitParam 'idle.graceMinutes')) }   # read once: a running grace keeps its value
  $left = [double]$l.graceMin - ($now - [datetime]$l.seen).TotalMinutes
  Set-KitProp $l graceLeft ([math]::Max(0, [math]::Ceiling($left)))
  if ($left -le 0 -and "$($l.agent)" -and -not $l.released) { Set-KitProp $l released $true; Set-KitLeaseReleased "$($l.agent)" @{ at = (Get-KitNow).ToString('o'); quiet = [math]::Round(($now - [datetime]$l.seen).TotalMinutes, 1); grace = $l.graceMin } }
  $left -gt 0
}
# releases by grace (params.json released.<agent>); never fails a lease
function Set-KitLeaseReleased([string]$Agent, $R) {
  if ("$(Get-KitSetting 'params.learning' 'on')" -eq 'off') { return }
  try { $f = Get-KitPath param-state -Create; Invoke-KitLocked $f { $s = Read-KitParams -Strict; if (-not $s.released) { $s.released = @{} }; if ($R) { $s.released[$Agent] = $R } else { $s.released.Remove($Agent) }; Write-KitAtomic $f ($s | ConvertTo-Json -Depth 8 -Compress) } } catch {}
}
# leasing again within 3 graces of a grace release: it was alive, grace too short
function Test-KitLeaseBack([string]$Agent) {
  $r = if ($Agent) { (Read-KitParams).released.$Agent }; if (-not $r) { return }; $now = Get-KitNow; $gap = ($now - [datetime]$r.at).TotalMinutes
  if ($gap -le 3 * [double]$r.grace) { Add-KitParamObs 'idle.graceMinutes' ([double]$r.quiet + $gap) '' 'short' 10 }
  Set-KitLeaseReleased $Agent $null
}
# leases.jsonl: newest half kept past the max
$script:KitLeaseLogMax = 1MB
function Write-KitLeaseLog([string]$Event, [string]$Kind, [string]$Name, $Lease = @{}, [string]$Reason) {
  if (-not $Reason) { $Reason = "$env:KIT_LEASE_REASON" }; if ($Event -eq 'release' -and $Reason -like 'reclaim*') { $Event = 'reclaim' }
  $iso = { param($v) if ($v -is [datetime]) { $v.ToString('o') } else { "$v" } }
  $f = [ordered]@{ kind = $Kind; name = $Name; agent = "$($Lease.agent)"; session = "$($Lease.session)"; holder = "$($Lease.holder)"; run = "$($Lease.run)"
    since = & $iso $(if ($Lease.at) { $Lease.at } else { $Lease.since }); seen = & $iso $Lease.seen; reason = $Reason; by = "$(if ($script:KitWho.agent) { $script:KitWho.agent } else { $env:KIT_AGENT })" }
  foreach ($k in @($f.Keys)) { if (-not $f[$k]) { $f.Remove($k) } }
  Write-KitLog leases $Event $f
  try { $lf = Get-KitLogFile leases; if ((Get-Item -LiteralPath $lf).Length -gt $script:KitLeaseLogMax) { Invoke-KitLocked $lf { $ls = [IO.File]::ReadAllLines($lf); Write-KitAtomic $lf ((@($ls | Select-Object -Last ([int]($ls.Count / 2))) -join "`n") + "`n") } } } catch {}
}
function Invoke-KitLeaseReason([string]$Reason, [scriptblock]$Body) { $o = $env:KIT_LEASE_REASON; $env:KIT_LEASE_REASON = $Reason; try { & $Body } finally { $env:KIT_LEASE_REASON = $o } }
# "<kind>|<name>" -> its newest release / reclaim line (status "last used")
function Get-KitLeaseLast {
  $m = @{}; $lf = Get-KitLogFile leases
  if (Test-Path -LiteralPath $lf) { foreach ($x in Get-Content -LiteralPath $lf) { $o = try { $x | ConvertFrom-Json } catch { $null }; if ($o.event -in 'release', 'reclaim') { $m["$($o.kind)|$($o.name)"] = $o } } }
  $m
}
function Format-KitLeaseLast($o) { if ($o) { "$(([datetime]$o.at).ToString('MM-dd HH:mm')) by $(if ($o.agent) { $o.agent } else { '?' }) ($(if ("$($o.reason)" -like "$($o.event)*") { $o.reason } else { "$($o.event)$(if ($o.reason) { ": $($o.reason)" })" }))" } else { 'never' } }
# GPU: exclusive per kind in gpu.exclusive (e.g. emulator lanes)
function Get-KitGpuFile { Join-Path (Get-KitPath runtimes -Create) 'gpu.json' }
function Get-KitGpuState {
  $s = try { Get-Content (Get-KitGpuFile) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if ($s -isnot [hashtable]) { $s = @{} }
  $script:KitGpuDropped = @($s.leases | Where-Object { $_ -and -not (Test-KitPid $_.pid $_.pidStart) })   # Save-KitGpuState logs them
  $s.leases = @($s.leases | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) }); $s.waiting = @($s.waiting | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) }); $s
}
function Save-KitGpuState([string]$File, $St) {
  Write-KitAtomic $File ($St | ConvertTo-Json -Depth 5)
  foreach ($d in @($script:KitGpuDropped)) { Write-KitLeaseLog release gpu $d.kind @{ agent = $d.holder; at = $d.at } 'holder process ended' }; $script:KitGpuDropped = @()
}
function Get-KitGpuHolders($St = (Get-KitGpuState)) {
  $ex = Get-KitSetting 'gpu.exclusive' $null; if (-not $ex) { return @() }
  @($St.leases) + @(foreach ($k in @($ex.PSObject.Properties.Name)) { $rx = "$($ex.$k.processes)"; if ($rx) { Get-SysProcs -Name $rx -NoCommandLine | ForEach-Object { @{ kind = $k; holder = "$($_.Name) pid $($_.Id)"; pid = $_.Id } } } })
}
# procs parsed from the table: --query-compute-apps omits graphics (G) users such as emulators
function Get-KitGpuProbe {
  if ($env:KIT_GPU_PROBE) { return (Get-Content $env:KIT_GPU_PROBE -Raw | ConvertFrom-Json -AsHashtable) }
  $r = Invoke-KitExe 'nvidia-smi' @() 20; if ($r.code) { return $null }
  $used = if ("$($r.out)" -match '(\d+)MiB\s*/\s*\d+MiB') { [int]$Matches[1] } else { 0 }
  $q = Invoke-KitExe 'nvidia-smi' @('--query-gpu=memory.free', '--format=csv,noheader,nounits') 20
  $free = if (-not $q.code -and "$($q.out)" -match '(\d+)') { [int]$Matches[1] } else { $null }
  @{ usedMB = $used; freeMB = $free; procs = @(foreach ($m in [regex]::Matches("$($r.out)", '(?m)^\|\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(?:C|G|C\+G)\s+(\S+)\s+(\d+MiB|N/A)')) {
        $id = [int]$m.Groups[1].Value; $n = (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName
        @{ pid = $id; name = $(if ($n) { $n } else { $m.Groups[2].Value }); mb = $(if ($m.Groups[3].Value -match '\d+') { [int]$Matches[0] } else { $null }) } }) }
}
# idleExcept = its backend's process regex; another GPU process, or idleMaxMB used with it down, blocks
function Get-KitGpuBusy([string]$Kind, [int]$MinFreeMB = 0) {
  $rx = "$(Get-KitSetting "gpu.exclusive.$Kind.idleExcept" '')"; if (-not $rx -and $MinFreeMB -le 0) { return $null }
  $p = Get-KitGpuProbe
  if (-not $p) {
    if ($rx) { return @{ kind = 'gpu'; holder = 'state unknown (nvidia-smi does not answer)' } }
    if (-not $script:KitGpuNoSmiSaid) { Write-Warning "GPU free-memory check skipped: nvidia-smi does not answer (no NVIDIA GPU?)"; $script:KitGpuNoSmiSaid = $true }; return $null
  }
  $mb = { param($x) "$($x.name) pid $($x.pid) $(if ($null -ne $x.mb) { "$($x.mb) MB" } else { 'using the GPU' })" }
  if ($MinFreeMB -gt 0 -and $null -ne $p.freeMB -and [int]$p.freeMB -lt $MinFreeMB) {
    return @{ kind = 'gpu'; vram = $true; holder = "needs $MinFreeMB MB free GPU memory, $($p.freeMB) MB free (held by $(if (@($p.procs).Count) { @($p.procs | ForEach-Object { & $mb $_ }) -join ', ' } else { 'no listed process' }))" }
  }
  if (-not $rx) { return $null }
  $f = @($p.procs | Where-Object { "$($_.name)" -notmatch $rx }) | Select-Object -First 1
  if ($f) { return @{ kind = 'gpu'; holder = "$($f.name) pid $($f.pid) using $(if ($null -ne $f.mb) { "$($f.mb) MB" } else { 'the GPU' })" } }
  $max = [int](Get-KitSetting "gpu.exclusive.$Kind.idleMaxMB" 512)
  if (-not @($p.procs | Where-Object { "$($_.name)" -match $rx }).Count -and [int]$p.usedMB -gt $max) { return @{ kind = 'gpu'; holder = "$($p.usedMB) MB used (> idleMaxMB $max)" } }
}
# -MinFreeMB: default for gpu.exclusive.<kind>.minFreeMB, waited on even for unlisted kinds
function Use-KitGpu([string]$Kind, [string]$Holder, [int]$ProcessId = $PID, [double]$WaitMinutes = 30, [int]$MinFreeMB = 0) {
  $ex = Get-KitSetting 'gpu.exclusive' $null; $listed = $ex -and $Kind -in @($ex.PSObject.Properties.Name)
  $min = if ($MinFreeMB -gt 0) { [int](Get-KitSetting "gpu.exclusive.$Kind.minFreeMB" $MinFreeMB) } else { 0 }
  if (-not $listed -and $min -le 0) { return $true }
  $me = @{ kind = $Kind; holder = $Holder; pid = $ProcessId; pidStart = (Get-KitPidStart $ProcessId); at = (Get-Date).ToString('o') }
  $end = (Get-Date).AddMinutes($WaitMinutes); $said = $false; $f = Get-KitGpuFile; $script:KitGpuRefused = $null
  while ($true) {
    $busy = Get-KitGpuBusy $Kind $min
    $other = Invoke-KitLocked $f {
      $st = Get-KitGpuState; $o = @(@(if ($listed) { Get-KitGpuHolders $st | Where-Object { $_.kind -ne $Kind } }) + @($busy | Where-Object { $_ })) | Select-Object -First 1
      $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $ProcessId }); $script:KitGpuNew = $false
      if ($o) { $st.waiting += $me + @{ heldBy = "$($o.kind) $($o.holder)" } } elseif ($listed) { $old = @($st.leases | Where-Object { $_.kind -ne $Kind -or ($_.pid -ne $ProcessId -and $_.holder -ne $Holder) }); $script:KitGpuNew = $old.Count -eq @($st.leases).Count; $st.leases = $old + $me }   # one per kind + holder (a lane: its boot, then its emulator)
      Save-KitGpuState $f $st; $o
    }
    if (-not $other) { if ($script:KitGpuNew) { Write-KitLeaseLog acquire gpu $Kind @{ agent = $Holder; at = $me.at } }; return $true }
    if (-not $said) { Write-Host "waiting for GPU: held by $($other.kind) $($other.holder)"; $said = $true }
    if ((Get-Date) -ge $end) { Remove-KitGpu -ProcessId $ProcessId; $script:KitGpuRefused = $other; return $false }
    Wait-KitPoll 30
  }
}
# -Holder: for bossy.ps1 release
function Remove-KitGpu([int]$ProcessId = $PID, [string]$Holder) {
  $f = Get-KitGpuFile; if (-not (Test-Path $f)) { return }
  $mine = { param($x) if ($Holder) { $x.holder -eq $Holder } else { $x.pid -eq $ProcessId } }
  $gone = Invoke-KitLocked $f { $st = Get-KitGpuState; $g = @($st.leases | Where-Object { & $mine $_ }); $st.leases = @($st.leases | Where-Object { -not (& $mine $_) }); $st.waiting = @($st.waiting | Where-Object { -not (& $mine $_) }); Save-KitGpuState $f $st; $g }
  foreach ($g in @($gone)) { Write-KitLeaseLog release gpu $g.kind @{ agent = $g.holder; at = $g.at } }
}
# machine-wide named locks (repos[].exclusiveTests): FIFO waiters, dead holders dropped
function Get-KitLockFile { Get-KitPath locks -Create }
# alive: its process, or a build its gate started (a killed check leaves its test process running)
function Test-KitLockHolder($H) {
  if (Test-KitPid $H.pid $H.pidStart) { return $true }
  @(Get-ChildItem (Join-Path (Get-KitTemp) 'claude-build-gate') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { "$($_.gate)" -eq "$($H.pid)" -and (Test-KitPid $_.pid $_.start) }).Count -gt 0
}
function Get-KitLockState {
  $s = try { Get-Content (Get-KitLockFile) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if ($s -isnot [hashtable]) { $s = @{} }
  $h = if ($s.held -is [hashtable]) { $s.held } else { @{} }
  $script:KitLockDropped = @(foreach ($k in @($h.Keys)) { if (-not (Test-KitLockHolder $h[$k])) { $h[$k]; $h.Remove($k) } })
  @{ held = $h; waiting = @($s.waiting | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) }) }
}
function Save-KitLockState($St) {
  Write-KitAtomic (Get-KitLockFile) ($St | ConvertTo-Json -Depth 5)
  foreach ($d in @($script:KitLockDropped)) { Write-KitLeaseLog release lock $d.lock @{ agent = $d.holder; at = $d.at } 'holder process ended' }; $script:KitLockDropped = @()
}
function Remove-KitLock([string]$Name, [int]$ProcessId = $PID) {
  $f = Get-KitLockFile; if (-not (Test-Path $f)) { return }
  $h = Invoke-KitLocked $f { $st = Get-KitLockState; $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $ProcessId }); $x = $st.held[$Name]; if ($x -and $x.pid -eq $ProcessId) { $st.held.Remove($Name) } else { $x = $null }; Save-KitLockState $st; $x }
  if ($h) { Write-KitLeaseLog release lock $Name @{ agent = $h.holder; at = $h.at }; Add-KitParamObs 'gate.waitMinutes' ((Get-Date) - [datetime]$h.at).TotalMinutes "lock:$Name" -Default 90 }
}
# bossy.ps1 supervise GPU line; -AutoFix drops (and logs) leases of ended processes
function Get-KitSuperviseGuardGpu([switch]$AutoFix) {
  $st = Get-KitGpuState; $h = @(Get-KitGpuHolders $st)
  if ($AutoFix -and @($script:KitGpuDropped).Count) { $f = Get-KitGpuFile; Invoke-KitLocked $f { Save-KitGpuState $f (Get-KitGpuState) } }
  if ($h.Count -or $st.waiting.Count) { "gpu: $(if ($h.Count) { "held by $(@($h | ForEach-Object { "$($_.kind) $($_.holder)" }) -join ', ')" } else { 'free' })$(@($st.waiting | ForEach-Object { "; waiting for GPU: $($_.kind) $($_.holder) (held by $($_.heldBy))" }) -join '')" }
}

function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60, [string]$Raw, [string]$Cwd) {   # -Raw: the argument string as is (cmd.exe /s /c "<command>")
  $res = { param($c, $o, $e, $t = $false) [pscustomobject]@{ code = $c; out = $o; err = $e; timedOut = $t } }
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd.CommandType -eq 'ExternalScript') { $app = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($app) { $cmd = $app } }   # an npm .ps1 shim: its .cmd keeps the timeout
  if (-not $cmd) { return & $res 127 '' "$Exe is not on PATH" }
  if ($cmd.CommandType -ne 'Application') {
    if ($Cwd) { Push-Location -LiteralPath $Cwd }
    try { $o = @(& $Exe @A 2>&1); $c = [int]$LASTEXITCODE } finally { if ($Cwd) { Pop-Location } }
    $so = @(); $se = @()
    foreach ($x in $o) { if ($x -is [Management.Automation.ErrorRecord]) { $se += "$x" } else { $so += "$x" } }
    return & $res $c ($so -join "`n") ($se -join "`n")
  }
  $si = [Diagnostics.ProcessStartInfo]::new($cmd.Source)
  if ($Raw) { $si.Arguments = $Raw } else { foreach ($x in @($A)) { $si.ArgumentList.Add([string]$x) } }
  if ($Cwd) { $si.WorkingDirectory = $Cwd }
  $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($si)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; return & $res -1 '' "$Exe timed out after $TimeoutSec s" $true }
  $p.WaitForExit()
  & $res $p.ExitCode $so.Result.TrimEnd() $se.Result.TrimEnd()
}
$script:KitNoConnect = '(?i)could not resolve|no such host|connection refused|unreachable|dial tcp'
$script:KitTransient = $script:KitNoConnect + '|timed? ?out|connection (reset|closed|aborted)|\bEOF\b|TLS handshake|temporar|\b(429|50[0234])\b|bad gateway|service unavailable|too many requests'
function Test-KitTransient($Text, [switch]$Connect) {
  for ($x = $Text.Exception; $x; $x = $x.InnerException) {
    $c = "$($x.SocketErrorCode)$($x.HttpRequestError)"
    if ($c -match '^(HostNotFound|ConnectionRefused|\w+Unreachable|TryAgain|NameResolutionError|ConnectionError)$' -or (-not $Connect -and ($c -match '^(ConnectionReset|ConnectionAborted|TimedOut)$' -or
        $x -is [TimeoutException] -or $x -is [Threading.Tasks.TaskCanceledException] -or [int]$(if ($x.StatusCode) { $x.StatusCode } else { $x.Response.StatusCode }) -in 429, 500, 502, 503, 504))) { return $true }
  }
  "$(if ($Text.Exception) { $Text.Exception.Message } else { $Text })" -match $(if ($Connect) { $script:KitNoConnect } else { $script:KitTransient })
}
function Get-KitNetTimeout([string]$Cli = '') { if ($env:KIT_NET_TIMEOUT_SEC) { [int]$env:KIT_NET_TIMEOUT_SEC } else { [int](Get-KitParam 'net.timeoutSec' $null $Cli) } }
# net.timeoutSec learned per CLI (under the learned value, not a caller cap); after a timeout the next call waits x1.5 (RFC 6298)
function Invoke-KitNetExe([string]$Exe, [string[]]$A) {
  $cli = [IO.Path]::GetFileNameWithoutExtension($Exe).ToLower(); $t0 = Get-KitNetTimeout $cli; $t = [int]($t0 * $(if ($script:KitNetBackoff) { 1.5 } else { 1 })); $script:KitNetBackoff = $false
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-KitExe $Exe $A $t; $null = Add-KitNetCount
  if (-not $r.timedOut -and $r.code -ne 127) { Add-KitParamObs 'net.timeoutSec' $sw.Elapsed.TotalSeconds $cli -Default 60 } elseif ($r.timedOut) { $script:KitNetBackoff = $true; if (-not $env:KIT_NET_TIMEOUT_SEC) { Add-KitParamObs 'net.timeoutSec' $t0 $cli 'timeout' 60 } }
  $r
}
# hang retries capped at 10% of network calls (10 min window, at least 1/min): no retry storm on a dead host
function Add-KitNetCount([switch]$Retry, [switch]$Check) {
  $f = Get-KitPath net-budget -Create; $m = (Get-Date).ToString('yyyyMMddHHmm'); $ok = $true; $lk = $null
  for ($i = 0; $i -lt 20 -and -not $lk; $i++) {   # a lock whose writer pid is gone is stale
    try { $lk = [IO.File]::Open("$f.lock", 'CreateNew', 'Write', 'Read'); $pb = [Text.Encoding]::ASCII.GetBytes("$PID"); $lk.Write($pb, 0, $pb.Length); $lk.Flush() }
    catch { try { $hp = ([IO.File]::ReadAllText("$f.lock")).Trim(); if ($hp -and -not (Test-KitPid ([int]$hp) $null)) { [IO.File]::Delete("$f.lock") } } catch {}; [void][Threading.Thread]::Yield() } }
  if (-not $lk) { return $true }   # busy: best effort (20 tries, no sleep), never a wait on a network call
  try { $s = try { Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $s) { $s = @{} }
    foreach ($k in @($s.Keys)) { if ([long]$k -lt [long](Get-Date).AddMinutes(-10).ToString('yyyyMMddHHmm')) { $s.Remove($k) } }
    if ($Check) { $c = ($s.Values | ForEach-Object { [int]$_.c } | Measure-Object -Sum).Sum; $rt = ($s.Values | ForEach-Object { [int]$_.r } | Measure-Object -Sum).Sum; $ok = [int]$s[$m].r -lt 1 -or $rt -lt 0.1 * $c }
    if ($ok) { if (-not $s[$m]) { $s[$m] = @{ c = 0; r = 0 } }; if ($Retry) { $s[$m].r = [int]$s[$m].r + 1 } else { $s[$m].c = [int]$s[$m].c + 1 }; Write-KitAtomic $f ($s | ConvertTo-Json -Compress) }
  } catch {} finally { $lk.Dispose(); try { [IO.File]::Delete("$f.lock") } catch {} }
  $ok
}
function Wait-KitPoll([int]$Seconds) { Start-Sleep -Milliseconds $(if ($env:KIT_POLL_MS) { [int]$env:KIT_POLL_MS } else { 1000 * $Seconds }) }   # KIT_POLL_MS: the tests' fake clock
function Invoke-KitRetry([scriptblock]$Call, [int]$Tries = $(if ($env:KIT_NET_TRIES) { [int]$env:KIT_NET_TRIES } else { 3 }), [switch]$Connect) {
  $delay = 2
  for ($i = 1; ; $i++) {
    $r = & $Call
    if ($r.code -eq 0 -or $i -ge $Tries -or -not (($r.timedOut -and -not $Connect) -or (Test-KitTransient "$($r.err) $($r.out)" -Connect:$Connect))) { return $r }
    if ($r.timedOut -and -not (Add-KitNetCount -Retry -Check)) { $r.err = "$($r.err) (hang retry budget spent: 10% of the calls of the last 10 min)".Trim(); return $r }
    Start-Sleep -Seconds $delay; $delay *= 3
  }
}

function New-DirLink([string]$Path, [string]$Target) {
  if ($KitIsWindows) { cmd /c mklink /J "$Path" "$Target" | Out-Null; if ($LASTEXITCODE) { throw "New-DirLink: mklink /J $Path -> $Target failed ($LASTEXITCODE)" } }
  else { New-Item -ItemType SymbolicLink -Path $Path -Value $Target | Out-Null }
}

function Remove-DirLink([string]$Path) {
  if ($KitIsWindows) { cmd /c rmdir "$Path" | Out-Null }
  else { & /bin/rm -f -- "$($Path.TrimEnd('/'))" }
}

function Set-NodeModules([string]$To, [string]$From, [string]$SrcRoot, [string]$WtRoot) {
  $norm = { param($x) [IO.Path]::GetFullPath($x).TrimEnd('\', '/') }   # a\.\x == a\x
  $To = & $norm $To; $From = & $norm $From; $SrcRoot = & $norm $SrcRoot; $WtRoot = & $norm $WtRoot
  $tgtOf = { param($i) $x = "$(@($i.Target)[0])"; if (-not [IO.Path]::IsPathRooted($x)) { $x = [IO.Path]::GetFullPath((Join-Path (Split-Path $i.FullName) $x)) }; $x.TrimEnd('\', '/') }
  $inSrc = { param($x) $x.StartsWith($SrcRoot + [IO.Path]::DirectorySeparatorChar, 'OrdinalIgnoreCase') -or $x.StartsWith($SrcRoot + '/', 'OrdinalIgnoreCase') }
  $ls = { param($d) Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue }
  $entries = @(& $ls $From)
  $ws = @(foreach ($e in $entries) {
      if ($e.LinkType -and (& $inSrc (& $tgtOf $e))) { $e }
      elseif ($e.Name.StartsWith('@') -and -not $e.LinkType -and $e.PSIsContainer) { & $ls $e.FullName | Where-Object { $_.LinkType -and (& $inSrc (& $tgtOf $_)) } }
    })
  $mk = { param($path, $target) $null = New-Item -ItemType $(if ($KitIsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $path -Value $target }
  $item = Get-Item -LiteralPath $To -Force -ErrorAction SilentlyContinue
  if (-not $ws.Count) {
    if ($item -and $item.LinkType -and (& $tgtOf $item) -eq $From) { return $false }
    if ($item) { Remove-NodeModules $To }
    New-DirLink $To $From; return $true
  }
  $marker = Join-Path $To '.kit-farm.json'; $want = "$From|$WtRoot"
  if ($item -and -not $item.LinkType -and (Test-Path $marker) -and (Get-Content $marker -Raw).Trim() -eq $want) { return $false }
  if ($item) { Remove-NodeModules $To }
  New-Item -ItemType Directory -Force $To | Out-Null
  $add = { param($e, $dest)
    if ($e.LinkType) { $x = & $tgtOf $e; if (& $inSrc $x) { $m = $WtRoot + $x.Substring($SrcRoot.Length); if (Test-Path $m) { $x = $m } }; & $mk $dest $x }
    elseif ($e.PSIsContainer) { & $mk $dest $e.FullName }
    else { Copy-Item -LiteralPath $e.FullName $dest }
  }
  foreach ($e in $entries) {
    $dest = Join-Path $To $e.Name
    if ($e.Name.StartsWith('@') -and -not $e.LinkType -and $e.PSIsContainer) {
      New-Item -ItemType Directory -Force $dest | Out-Null
      foreach ($c in (& $ls $e.FullName)) { & $add $c (Join-Path $dest $c.Name) }
    } else { & $add $e $dest }
  }
  Set-Content -LiteralPath $marker $want
  $true
}
function Remove-NodeModules([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  if ($item.LinkType) { Remove-DirLink $Path; return }
  $unlink = { param($x) if ($KitIsWindows) { [IO.Directory]::Delete($x) } else { Remove-DirLink $x } }
  $kids = @(Get-ChildItem -LiteralPath $Path -Force)
  $no = { param($x, $why) throw "Remove-NodeModules: $x $why - $Path is not a link farm, nothing deleted" }
  foreach ($c in $kids) {
    if ($c.PSIsContainer -and -not $c.LinkType) {
      if (-not $c.Name.StartsWith('@')) { & $no $c.FullName 'is a real folder' }
      $real = @(Get-ChildItem -LiteralPath $c.FullName -Force | Where-Object { -not $_.LinkType }) | Select-Object -First 1
      if ($real) { & $no $real.FullName 'is not a link' }
    }
  }
  foreach ($c in $kids) {
    if ($c.LinkType) { & $unlink $c.FullName }
    elseif ($c.PSIsContainer) { foreach ($g in Get-ChildItem -LiteralPath $c.FullName -Force) { if ($g.LinkType) { & $unlink $g.FullName } else { throw "Remove-NodeModules: $($g.FullName) is not a link, not deleted" } }; Remove-Item -LiteralPath $c.FullName -Force }
    else { Remove-Item -LiteralPath $c.FullName -Force }
  }
  Remove-Item -LiteralPath $Path -Force
}
function Get-DirLinks([string]$Dir, [int]$Depth = 4) {
  if ($KitIsWindows) { Get-ChildItem $Dir -Recurse -Depth $Depth -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue }
  else { Get-ChildItem $Dir -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -eq 'SymbolicLink' -and (Test-Path -PathType Container $_.FullName) } }
}

function Resolve-Tool {
  foreach ($n in $args) { $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.Source } }
  $null
}

function Get-Python { if ($KitIsWindows) { 'python' } else { $p = Resolve-Tool python3 python; if ($p) { $p } else { 'python3' } } }

function Test-KitProse([string]$Kind, [string]$Text, [string]$Path) {
  $kt = $KitCmd.kitbag; if (-not $kt -or -not (Test-Path $kt)) { return @() }
  $tmp = $null
  if (-not $Path) { $tmp = Join-Path (Get-KitTemp) "kit-prose-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 6)).md"; [IO.File]::WriteAllText($tmp, $Text); $Path = $tmp }
  $lec = $global:LASTEXITCODE   # kitbag's exit 1 on findings is no exit code of the caller
  try { $r = & (Get-Python) -X utf8 $kt prose --kind $Kind $Path --json 2>$null | ConvertFrom-Json } catch { $r = $null } finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }; $global:LASTEXITCODE = $lec }
  $found = @(if ($r) { $r.findings })
  foreach ($f in $found) { Write-Warning "[prose] $Kind`: $f (templates.md ""Writing standards"": rewrite, nothing was cut)" }
  $found
}
function Start-Detached([string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path, [string]$Log) {
  if ($KitIsWindows) { $null = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden; return }
  if (-not $Log) { $Log = Join-Path (Get-KitTemp) "kit-bg-$([IO.Path]::GetFileNameWithoutExtension($FilePath))-$PID.log" }
  $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.UseShellExecute = $false
  $script = 'cd "$1" || exit 1; log=$2; shift 2; s=; command -v setsid >/dev/null 2>&1 && s=setsid; $s nohup "$@" >"$log" 2>&1 </dev/null &'
  foreach ($a in @('-c', $script, 'sh', $WorkingDirectory, $Log, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$a) }
  ([Diagnostics.Process]::Start($psi)).WaitForExit()
}

# ----- adapters (README "Adapters"): kind -> name -> verb -> { param($a, $verb) }; '*' = any verb
if (-not $global:KitAdapters) { $global:KitAdapters = @{} }
function Register-KitAdapter([string]$Kind, [string]$Name, [hashtable]$Verbs) { if (-not $KitAdapters[$Kind]) { $KitAdapters[$Kind] = @{} }; $KitAdapters[$Kind][$Name] = $Verbs }
function Invoke-KitAdapter([string]$Kind, [string]$Name, [string]$Verb, [hashtable]$a = @{}) {
  $ad = $KitAdapters[$Kind][$Name]; $f = if (-not $ad) { $null } elseif ($ad.ContainsKey($Verb)) { $ad[$Verb] } else { $ad['*'] }
  if (-not $ad -and $Name) { throw (Get-KitExtraLine $Kind $Name) }
  if (-not $f) { Write-Warning "$Kind ($Name): no adapter or verb $Verb (README ""Adapters"")"; return $null }
  if ($f.File) { Add-KitExtraUse $f.File }   # a goody's adapter in use
  & $f $a $Verb
}
# a config command line -> argv: quotes group, {name} = $a.name
function Split-KitCommand([string]$Line, [hashtable]$a) { @([regex]::Matches($Line, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object { [regex]::Replace($_.Groups[1].Value + $_.Groups[2].Value + $_.Groups[3].Value, '\{(\w+)\}', { param($m) [string]$a[$m.Groups[1].Value] }) }) }
function Invoke-KitCommand([string]$Kind, $Commands, [string]$Verb, [hashtable]$a) {
  $line = [string]$(if ($Commands) { $Commands.$Verb }); if (-not $line) { Write-Warning "$Kind (command): no commands.$Verb in kit.local.json"; return $null }
  $t = Split-KitCommand $line $a
  $r = Invoke-KitRetry { Invoke-KitNetExe $t[0] @($t | Select-Object -Skip 1) } -Connect:($Verb -match 'create|merge|comment|attach|publish')
  if ($r.code) { $global:KitHostFailed = $true; Write-Warning "$Kind (command) $Verb failed (exit $($r.code)): $($r.err)"; return $null }
  $o = "$($r.out)".Trim(); if ($o -match '^[\[{]') { try { return ($o | ConvertFrom-Json) } catch {} }; $o
}
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
  $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = (Get-KitNetTimeout) }
  if ($Method -eq 'GET') { $p.MaximumRetryCount = 2; $p.RetryIntervalSec = 3 }
  if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress)); $p.ContentType = 'application/json' }
  try { Invoke-RestMethod @p } catch { $global:KitHostFailed = $true; Write-Warning "http $Method $($Uri -replace '\?.*') failed: $($_.Exception.Message)"; $null }
}
function Get-KitAuth([string]$Env, [string]$Kind = 'bearer') {
  $t = [Environment]::GetEnvironmentVariable($Env); if (-not $t) { return @{} }
  @{ Authorization = switch ($Kind) { 'basic' { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($(if ($t -match ':') { $t } else { ":$t" }))) } 'token' { "token $t" } default { "Bearer $t" } } }
}
# ----- goodies (kitbag.py goody add <name>): adapters a config names but the kit does not ship; files land in skills/crafty/adapters/
$script:KitExtraOf = @{ 'tracker/jira-server' = 'tracker-jira'; 'git-host/bitbucket' = 'bitbucket'; 'ci/bitbucket' = 'bitbucket'
  'tracker/gitlab' = 'gitlab'; 'git-host/gitlab' = 'gitlab'; 'ci/gitlab' = 'gitlab'
  'tracker/github' = 'github'; 'git-host/github' = 'github'; 'ci/github' = 'github'
  'git-host/azure' = 'azure-devops'; 'ci/azure' = 'azure-devops'; 'git-host/gitea' = 'gitea'; 'ci/gitea' = 'gitea' }
function Get-KitExtraName([string]$Kind, [string]$Name) { if ($script:KitExtraOf["$Kind/$Name"]) { $script:KitExtraOf["$Kind/$Name"] } else { "$Kind-$Name" } }
function Get-KitExtraLine([string]$Kind, [string]$Name) { "$Kind $Name is a goody: run kitbag.py goody add $(Get-KitExtraName $Kind $Name)" }
# `kitbag.py goody add <name> --auto` (prune drops it once unused); KIT_EXTRA_AUTO=0 off; a failed try waits 1 h
function Install-KitExtra([string]$Name) {
  if (-not $Name -or $env:KIT_EXTRA_AUTO -eq '0' -or -not (Test-Path -LiteralPath $KitCmd.kitbag)) { return $false }
  $try = Join-Path (Get-KitPath extras-used -Create) "_try-$Name"
  if ((Test-Path -LiteralPath $try) -and ((Get-Date) - [IO.File]::GetLastWriteTime($try)).TotalMinutes -lt 60) { return $false }   # TODO-PARAM (fixed default)
  $r = Invoke-KitExe (Get-Python) @('-X', 'utf8', $KitCmd.kitbag, 'goody', 'add', $Name, '--auto') 180   # kitbag's lock serializes two installers
  Write-KitLog calls extra-auto @{ extra = $Name; code = $r.code }
  if ($r.code) { [IO.File]::WriteAllText($try, ''); Write-Warning "goody ${Name}: install on demand failed ($(@("$($r.err)$($r.out)" -split "`n" | Where-Object { $_.Trim() })[0]))"; return $false }
  [Console]::Error.WriteLine("goody ${Name}: installed on demand"); $true
}
# installs the goody and reruns the verb once; returns only when it could not
function Resolve-KitExtra([string]$Name) {
  if (-not $script:KitEntry -or $env:KIT_EXTRA_RETRY -eq $Name -or -not (Install-KitExtra $Name)) { return }
  $env:KIT_EXTRA_RETRY = $Name
  $again = @(@($script:__verb | Where-Object { $_ }) + @($script:__rest))   # a variable: @(...) inline would pass one array
  # to the host: callers capture this function's output ($null = Assert-KitExtra ...)
  try { & $script:KitEntry @again | ForEach-Object { Write-Host $(if ($_ -is [string]) { $_ } else { ($_ | Out-String).TrimEnd() }) }; $code = $LASTEXITCODE } finally { $env:KIT_EXTRA_RETRY = $null }
  exit $code
}
# daily usage stamp per loaded goody file, for kitbag.py goody prune
function Add-KitExtraUse([string[]]$Files) {
  try {
    $d = Get-KitPath extras-used; if (-not [IO.Directory]::Exists($d)) { $null = [IO.Directory]::CreateDirectory($d) }; $today = [datetime]::Today
    foreach ($f in $Files) {
      if (-not $f -or -not $f.StartsWith($script:KitRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
      $s = Join-Path $d ($f.Substring($script:KitRoot.Length).TrimStart('\', '/') -replace '[\\/]', '__')
      if (-not [IO.File]::Exists($s) -or [IO.File]::GetLastWriteTime($s) -lt $today) { [IO.File]::WriteAllText($s, '') }
    }
  } catch {}   # a stamp never fails a verb
}
# /tidy prep: kitbag.py goody prune; -Days default: learned goodies.pruneDays
function Invoke-ExtrasPrune([double]$Days = 0, [switch]$DryRun) {
  $gp = Get-Command Get-KitParam -ErrorAction SilentlyContinue   # the learned-parameter framework, when installed
  if (-not $Days) { $Days = if ($gp) { try { [double](& $gp 'goodies.pruneDays' 30) } catch { 30 } } else { 30 } }   # TODO-PARAM (fixed default)
  $pa = @('-X', 'utf8', $KitCmd.kitbag, 'goody', 'prune', '--days', "$Days") + @(if ($DryRun) { '--dry-run' })
  & (Get-Python) @pa
}

# ---- status: one row per agent and workflow run, from files only; no LLM, no network
# <Claude project dir>/<session>/subagents/workflows/<run>
function Get-KitWorkflowDirs([string]$Session) {
  Get-ChildItem $(if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }) -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents/workflows') -Directory -ErrorAction SilentlyContinue }
}
# launch records by run id or wfDir, plus the record-args step's "RECORDED <leaf> <run> (fnv <h>)" within 30 min
function Get-KitWorkflowRecords($Dir, $Events, $Launches) {
  @($Launches | Where-Object { $_.runId -eq $Dir.Name -or ($_.wfDir -and (Split-Path "$($_.wfDir)" -Leaf) -eq $Dir.Name) })
  $m = @($Events | Where-Object type -eq 'result' | ForEach-Object { [regex]::Match("$($_.result.output)", 'RECORDED (\S+) (\S+) \(fnv (\w+)\)') } | Where-Object Success)[0]
  if ($m) { $Launches | Where-Object { "$($_.fnv)" -eq $m.Groups[3].Value -and $_.run -eq $m.Groups[2].Value -and (Split-Path "$($_.script)" -Leaf) -eq $m.Groups[1].Value -and [math]::Abs(([datetime]$_.at - $Dir.CreationTime).TotalMinutes) -le 30 } | Select-Object -First 1 }
}
# no end marker (TaskStop, restart): completed, or quiet and every holder gone (none: every Claude process younger)
function Get-KitWorkflowStop($Dir, $Records) {
  if (@($Records | Where-Object completed).Count) { return 'completed' }
  if (Test-KitRunLive $Dir $Records) { return }   # bossy adapters/supervise_resources.ps1
  $h = @($Records | Where-Object holderPid); if ($h.Count) { if (-not @($h | Where-Object { (Test-KitHolder $_) -ne $false }).Count) { 'session gone' }; return }
  if (-not @($Records).Count -and ($cs = @(Get-KitClaudeStarts)).Count -and -not @($cs | Where-Object { $_ -le $Dir.CreationTime }).Count) { 'session gone' }   # no Claude process found: unknown
}
function Get-KitClaudeStarts { @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -match '^claude' | ForEach-Object { try { $_.StartTime } catch {} }) }
# a broken file is skipped
function Read-KitJsonFiles([string]$Dir, [string]$Filter = '*.json') {
  if (-not $Dir) { return }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue)) {
    $o = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }
    if ($o) { $o | Add-Member -Force NoteProperty file $f.FullName; $o }
  }
}
# running = no result and no later start of the same item or label (a 529-dead agent writes no result)
function Get-JournalRunning($Started, $DoneIds) {
  $itemOf = { param($label) (([string]$label -split ':', 2)[-1] -split '@')[0] }
  $lastDone = @{}; $lastStart = @{}
  for ($i = 0; $i -lt $Started.Count; $i++) {
    if ($Started[$i].agentId -in $DoneIds) { $lastDone[(& $itemOf $Started[$i].label)] = $i }
    $lastStart[[string]$Started[$i].label] = $i
  }
  @(for ($i = 0; $i -lt $Started.Count; $i++) { $s = $Started[$i]; if ($s.agentId -notin $DoneIds -and -not ($lastDone[(& $itemOf $s.label)] -gt $i) -and $lastStart[[string]$s.label] -eq $i) { $s } })
}
# a workflow label -> the board names its agent may use (X1, X1-review, review-X1)
function LabelNames($l) { $p = $l -split ':'; $n = ($p[-1] -split '@')[0]; @($n) + $(if ($p.Count -gt 1) { "$n-$($p[0])"; "$($p[0])-$n" }) }
# last 512 KB only (transcripts reach MBs), newest line first; $Each returns $true when done
function Read-KitTranscriptTail([string]$File, [string]$Want, [scriptblock]$Each) {
  $fi = if ($File) { Get-Item -LiteralPath $File -ErrorAction SilentlyContinue }; if (-not $fi) { return $null }
  $fs = [IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite')
  try { $n = [int][math]::Min($fs.Length, 512KB); $null = $fs.Seek(-$n, 'End'); $b = [byte[]]::new($n); $null = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  $s = [pscustomobject]@{ file = $fi.FullName; at = $fi.LastWriteTime; tool = ''; what = ''; ended = $null; killed = $false; version = ''; raw = [Text.Encoding]::UTF8.GetString($b) }
  $lines = @($s.raw -split "`r?`n" | Select-Object -Skip $(if ($n -lt $fi.Length) { 1 } else { 0 }))   # the first line of a cut tail is partial
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -notmatch $Want) { continue }
    $o = try { $lines[$i] | ConvertFrom-Json -Depth 80 } catch { $null }; if ($o -and (& $Each $o $s)) { break }
  }
  $s
}
# adapter:transcript/claude: <project dir>/<session>/subagents/**/agent-*.jsonl; its named task *.output files = progress
Register-KitAdapter 'transcript' 'claude' @{
  'root' = { @{ dir = $(if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }); filter = '*.jsonl' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file '"tool_use"' { param($o, $s) $u = @($o.message.content | Where-Object { $_.type -eq 'tool_use' })[-1]
      if ($u) { $s.tool = "$($u.name)"; $s.what = "$($u.input.description)" }; [bool]$u }
    if (-not $s) { return }; if ($s.raw -match '"version":"([^"]+)"') { $s.version = "claude $($Matches[1])" }
    $end = "$(@($s.raw -split "`r?`n" | Where-Object { $_.Trim() })[-1])"; $s.ended = $end -match '"role":"assistant"' -and $end -match '"stop_reason":"end_turn"'   # last record = final answer
    $outs = foreach ($m in [regex]::Matches($s.raw, 'tasks(?:\\\\|/)\w+\.output')) { $i = $s.raw.LastIndexOfAny([char[]]'"<> ', $m.Index) + 1; $s.raw.Substring($i, $m.Index + $m.Length - $i) -replace '\\\\', '\' }   # scan back: a forward regex backtracks for seconds
    foreach ($o in @($outs | Select-Object -Unique)) { $f = Get-Item -LiteralPath $o -ErrorAction SilentlyContinue; if ($f -and $f.LastWriteTime -gt $s.at) { $s.at = $f.LastWriteTime } }
    $s }
}
# adapter:transcript/codex: $CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl; line 1 session_meta; newest task_complete = turn ended
Register-KitAdapter 'transcript' 'codex' @{
  'root' = { @{ dir = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }) 'sessions'; filter = 'rollout-*.jsonl'; sub = '*/*/*' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file 'function_call"|task_started|task_complete' { param($o, $s) $p = $o.payload
      if (-not $s.tool -and $o.type -eq 'response_item' -and $p.type -eq 'function_call') { $s.tool = "$($p.name)"; $g = try { "$($p.arguments)" | ConvertFrom-Json } catch { $null }; $s.what = "$(if ($g.cmd) { $g.cmd } else { $g.command })" }
      elseif ($null -eq $s.ended -and $o.type -eq 'event_msg' -and $p.type -in 'task_started', 'task_complete') { $s.ended = $p.type -eq 'task_complete' }
      $s.tool -and $null -ne $s.ended }
    if ($s) { $m = try { Get-Content -LiteralPath $s.file -TotalCount 1 | ConvertFrom-Json } catch { $null }; if ($m.payload.cli_version) { $s.version = "codex $($m.payload.cli_version)" } }; $s }
}
# adapter:transcript/antigravity: brain/<id>/.system_generated/logs/transcript.jsonl; killed per the parent's subagents/<id>.json state
Register-KitAdapter 'transcript' 'antigravity' @{
  'root' = { @{ dir = Join-Path $HOME '.gemini/antigravity-cli/brain'; filter = 'transcript.jsonl'; sub = '*/.system_generated/logs' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file '"tool_calls"' { param($o, $s) $c = @($o.tool_calls)[-1]; if ($c.name) { $s.tool = "$($c.name)"; $s.what = "$($c.args.toolSummary)" }; [bool]$c.name }
    if ($s) { $id = Split-Path (Split-Path (Split-Path (Split-Path $s.file))) -Leaf; $brain = Split-Path (Split-Path (Split-Path (Split-Path $s.file)))
      $k = @(Get-Item -Force -Path (Join-Path $brain "*/.system_generated/subagents/$id.json") -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} })[0]
      $s.killed = "$($k.state)" -eq 'SUBAGENT_STATE_KILLED' }; $s }
}
# adapter:transcript/none: no transcript (another tool): board and journal only
Register-KitAdapter 'transcript' 'none' @{ 'root' = { $null }; 'last' = { $null } }
# adapter-end:transcript
# SessionStart output: Antigravity (input has conversationId) takes injectSteps, others a systemMessage
function Format-KitSessionStart([string]$Text, $Hook) {
  if ($Hook.conversationId) { @{ injectSteps = @($(if ($Text) { @{ systemMessage = @{ systemMessage = $Text } } })) } | ConvertTo-Json -Compress -Depth 5 }
  elseif ($Text) { @{ systemMessage = $Text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $Text } } | ConvertTo-Json -Compress -Depth 4 }
}
function Get-KitTranscriptKind([string]$Tool) { if (-not $Tool) { 'claude' } elseif ($KitAdapters.transcript[$Tool]) { $Tool } else { 'none' } }
# liveness (STUCK rows, stale board rows, lease grace, shell owners): newest board beat or transcript (+ task output) write
function Get-KitLastActivity([string]$Tx, $Entry, [string]$Tool) {
  $fi = if ($Tx) { Get-Item -LiteralPath $Tx -ErrorAction SilentlyContinue }   # one tail read per transcript write (sweeps ask per step, shell, lease)
  $t = if ($fi) { Get-KitLiveCached "tx:$($fi.FullName)" { Invoke-KitAdapter transcript (Get-KitTranscriptKind $Tool) last @{ file = $Tx } } }
  @(@($t.at) + @($(if ($Entry.beat) { try { [datetime]$Entry.beat } catch {} })) | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
}
# first that holds: STOPPED · FINISHED · WAITING · ACTIVE (progress within $StuckMin) · STUCK
function Set-KitStatusState($R, [datetime]$Now, [double]$StuckMin) {
  $s = if ($R.stopped) { 'STOPPED' } elseif ($R.done) { 'FINISHED' } elseif ($R.wait) { 'WAITING' } elseif ($R.last -and ($Now - [datetime]$R.last).TotalMinutes -lt $StuckMin) { 'ACTIVE' } else { 'STUCK' }
  $rc = "bossy.ps1 recover$(if ($R.run) { " -Run $($R.run)" })"
  $R | Add-Member -Force NoteProperty state $s
  $R | Add-Member -Force NoteProperty since $(switch ($s) { 'ACTIVE' { $R.started } 'WAITING' { $R.waitAt } 'STUCK' { $R.last } default { $R.ended } })
  $R | Add-Member -Force NoteProperty next $(switch ($s) { 'WAITING' { $R.waitNext } 'STUCK' { "read its transcript tail; resume it or $rc" } 'STOPPED' { $rc } default { $R.next } }); $R
}
# agent transcripts (not workflow steps), board row or not; the session-folder walk is cached 60 s
function Get-KitLiveTranscripts([datetime]$Now, [double]$Minutes, [string]$Kind = 'claude') {
  if ($Kind -eq '*') { foreach ($k in 'claude', 'codex', 'antigravity') { Get-KitLiveTranscripts $Now $Minutes $k }; return }
  $r = Invoke-KitAdapter transcript $Kind root; if (-not $r.dir -or -not (Test-Path -LiteralPath $r.dir)) { return }
  $cf = Get-KitPath transcript-dirs -Create; $c = try { Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $c) { $c = @{} }
  $hit = $c[$r.dir]; $dirs = if ($hit -and ((Get-Date) - [datetime]$hit.at).TotalSeconds -lt 60) { @($hit.dirs) } else {
    $w = @(Get-Item -Force -Path (Join-Path ([WildcardPattern]::Escape($r.dir)) $(if ($r.sub) { $r.sub } else { '*/subagents' })) -ErrorAction SilentlyContinue | Where-Object PSIsContainer | ForEach-Object FullName)
    $c[$r.dir] = @{ at = (Get-Date).ToString('o'); dirs = $w }; try { Write-KitAtomic $cf ($c | ConvertTo-Json -Depth 4 -Compress) } catch {}; $w }
  foreach ($sd in $dirs) { Get-ChildItem -LiteralPath $sd -Filter $r.filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Now.AddMinutes(-$Minutes) } }
}
# rows: board entries, workflow runs (2 h after last write, 48 h unfinished), running steps no entry covers (windows inline)
function Get-KitStatusRows([datetime]$Now = (Get-Date), [string]$Session) {
  $stuck = [double](Get-KitParam 'supervise.stuckMinutes'); $rows = [Collections.Generic.List[object]]::new(); $script:KitTxVersions = @{}
  $last = { param($tool, $file) $t = if ($file) { Invoke-KitAdapter transcript (Get-KitTranscriptKind $tool) last @{ file = $file } }; if ($t.version) { $script:KitTxVersions[($t.version -split ' ')[0]] = $t.version }; $t }
  $max = { param([object[]]$T) @($T | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1] }
  $doing = { param($t) if ($t.tool) { "$($t.tool)$(if ($t.what) { ": $($t.what)" })" } }
  $outcome = { param($st) if ("$($st.result.summary)") { "$($st.result.summary)" } else { 'done' } }
  $tok = { param($n) if ($n -ge 1e6) { '{0:0.#}M' -f ($n / 1e6) } else { '{0:0}k' -f ($n / 1e3) } }
  # waits: "<run>/<agent>" or "/<agent>" -> why, since, next
  $waits = @{}; $put = { param($k, $why, $at, $nx) if (-not $waits[$k]) { $waits[$k] = [pscustomobject]@{ why = $why; at = $at; next = $nx } } }
  foreach ($d in @(Read-KitJsonFiles (Get-KitPath decisions) | Where-Object status -eq 'pending')) {
    $e = $d.kind -eq 'envfix'; & $put "$($d.run)/$($d.agent)" "$(if ($e) { 'env fix' } else { 'decision' }) $($d.id)" $d.at "$(if ($e) { 'coordinator fixes the env' } else { 'owner answers' }), then decide answer -Id $($d.id)"
  }
  foreach ($g in @((Get-KitGpuState).waiting)) { & $put "/$($g.holder)" "GPU, held by $($g.heldBy)" $g.at 'the GPU frees' }
  foreach ($h in @(Get-Command 'Get-KitStatusWait*' -CommandType Function -ErrorAction SilentlyContinue)) { foreach ($w in @(& $h)) { & $put "/$($w.agent)" $w.why $w.at $w.next } }   # adapters: build gate, phone lanes
  $pauses = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object state -eq 'paused')
  $waitOf = { param([string]$Run, [string[]]$Names)
    foreach ($n in $Names) { foreach ($k in "$Run/$n", "/$n") { if ($waits[$k]) { return $waits[$k] } } }
    $p = @($pauses | Where-Object { $Run -and ($_.run -eq $Run -or ($_.run -eq '*' -and $Run -notin @($_.released))) })[0]
    if ($p) { [pscustomobject]@{ why = "owner pause: $($p.reason)"; at = $p.at; next = "bossy.ps1 resume -Run $Run" } } }
  # a board transcript inside a workflow folder maps the engine's folder id to the run's name
  $recent = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { -not $_.takenOverBy -and ($Now - [datetime]$_.beat).TotalHours -lt $(if ($_.status -eq 'left') { 2 } else { 6 }) })   # supervise's window
  $runOf = @{}; foreach ($e in $recent) { if ("$($e.transcript)" -match '[\\/]workflows[\\/]([^\\/]+)[\\/]agent-' -and $e.run) { $runOf[$Matches[1]] = $e.run } }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $steps = @{}; $anyRun = @{}; $runSteps = [Collections.Generic.List[object]]::new()
  foreach ($w in @(Get-KitWorkflowDirs $Session | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | Sort-Object LastWriteTime)) {   # oldest first: a relaunch's steps win
    $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
    $ev = @(Get-Content $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $jt = (Get-Item $j).LastWriteTime
    $rec = @(Get-KitWorkflowRecords $w $ev $launch); $lr = @($rec | Where-Object { $_.runId -or $_.wfDir })
    $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x }
    $running = @(Get-JournalRunning $started @($res.Keys)); $seen = [Collections.Generic.List[object]]::new(); $seen.Add($jt)
    # no end marker: no running step for 2+ min = ended (unless paused)
    $paused = [bool]@($rec | Where-Object { $_.paused -and -not $_.completed }).Count
    $fin = -not $paused -and ([bool]@($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count -or [bool]@($rec | Where-Object completed).Count -or ($started.Count -and -not $running.Count -and ($Now - $jt).TotalMinutes -ge 2))
    $gone = if (-not $fin) { Get-KitWorkflowStop $w $rec }; $live = -not $fin -and -not $gone   # ended runs have no running steps
    if (($Now - $jt).TotalHours -ge $(if ($live) { 48 } else { 2 })) { continue }
    $run = @(@($lr | ForEach-Object run) + $runOf[$w.Name] + $w.Name | Where-Object { $_ })[0]
    if (-not @($lr).Count) { $lr = @(@($rec) + @($launch | Where-Object { $_.run -eq $run -and $_.cap }) | Where-Object { $_ }) }   # its self record: script, tokens spent, cap
    foreach ($s in $started) {
      $st = [pscustomobject]@{ label = [string]$s.label; run = $run; result = $res[$s.agentId].result; tf = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; tx = $null; covered = $false; jt = $jt }
      if ($live -and $s -in $running) { $st.tx = & $last 'claude' $st.tf; $seen.Add($st.tx.at); $runSteps.Add($st)
        $st | Add-Member -Force NoteProperty created (Get-Item -LiteralPath $st.tf -ErrorAction SilentlyContinue).CreationTime
        $st | Add-Member -Force NoteProperty type $(try { (Get-Content ($st.tf -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json).agentType } catch { '' })
        foreach ($n in @(LabelNames $st.label)) { $anyRun[$n] = if ($anyRun.ContainsKey($n) -and $anyRun[$n] -ne $st) { $false } else { $st } } }   # one running step of a name: its agent, whatever run it joined the board under
      foreach ($k in @(LabelNames $st.label | ForEach-Object { "$run/$_"; if ($run -like 'wf_*') { "?/$_" } })) { if (-not ($steps[$k].tx -and -not $st.tx)) { $steps[$k] = $st } }   # latest step wins, running first; ?/ = run name unknown
    }
    $errs = @($res.Values | Where-Object { $_.result.error }).Count; $spent = @($lr.spent | Where-Object { $_ })[0]; $cap = @($lr.cap | Where-Object { $_ })[0]
    $cw = @(foreach ($x in @($runSteps | Where-Object { $_.tf.StartsWith($w.FullName) })) { & $waitOf $run @(LabelNames $x.label) })   # every running step waits = the run waits
    $wp = if ($paused) { [pscustomobject]@{ why = 'owner pause'; at = @($lr.paused)[0]; next = "bossy.ps1 resume -Run $run" } } elseif (-not $running.Count) { & $waitOf $run @() } elseif ($cw.Count -eq $running.Count) { [pscustomobject]@{ why = "$($cw[0].why)$(if ($cw.Count -gt 1) { ", $($cw.Count) steps" })"; at = @($cw.at | Sort-Object)[0]; next = $cw[0].next } }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$run (workflow)"; run = $run; left = $(if ($live) { $running.Count } else { 0 })
          task = "$(@($lr.script | Where-Object { $_ } | ForEach-Object { Split-Path "$_" -Leaf })[0]) $($w.Name) · steps $($res.Count)/$($started.Count)$(if ($spent) { " · $(& $tok $spent) tokens$(if ($cap) { " of $(& $tok $cap)" })" })"
          stopped = $gone; done = $(if ($fin) { "$($res.Count)/$($started.Count) steps$(if ($errs) { ", $errs error(s)" })" })
          wait = $wp.why; waitAt = $wp.at; waitNext = $wp.next; last = & $max $seen; started = $w.CreationTime; ended = $jt; next = '' }) $Now $stuck))
  }
  # a running step of the same name is that agent now (resume or env-fix after its entry left)
  $trk = (Read-KitTracking).tasks; $txCache = @{}; $byTx = @{}
  # Agent-tool subagent: transcript found by its SESSION line, saved in the entry
  $txOf = { param($e) if ($e.transcript -or $e.status -eq 'left' -or -not $e.session -or ($e.txTry -and ($Now - [datetime]$e.txTry).TotalMinutes -lt 10)) { return "$($e.transcript)" }
    $k = Get-KitTranscriptKind $e.tool; if (-not $txCache.ContainsKey($k)) { $txCache[$k] = @(Get-KitLiveTranscripts $Now 360 $k) }
    $hit = @($txCache[$k] | Where-Object { $_.LastWriteTime -ge [datetime]$e.joined -and (Select-String -LiteralPath $_.FullName -SimpleMatch "SESSION $($e.session)" -Quiet) })[0]
    try { Invoke-KitLocked $e.file { $x = Read-KitState $e.file; if ($x) { if ($hit) { $x.transcript = $hit.FullName } else { $x.txTry = $Now.ToString('o') }; Write-KitState $e.file $x } } } catch { }   # a miss: 10 min until the next scan
    if ($hit) { $hit.FullName } }
  foreach ($e in @($recent | Group-Object { "$($_.run)/$($_.agent)" } | ForEach-Object { $_.Group | Sort-Object { [datetime]$_.joined } | Select-Object -Last 1 } | Sort-Object -Stable { -not $_.type })) {   # a re-join replaces its older entry; typed first
    $sq = $steps["?/$($e.agent)"]; $st = @($steps["$($e.run)/$($e.agent)"], $(if ($sq.tx -or $sq.jt -ge [datetime]$e.joined) { $sq }) | Where-Object { $_ })[0]   # an unnamed run's ended step never matches a newer entry
    $sa = $anyRun["$($e.agent)"]; if (-not $st -and $sa -and $e.status -ne 'left' -and -not $e.crashed -and $sa.type -and $sa.type -eq $e.type -and $sa.created -and [datetime]$e.joined -ge $sa.created.AddMinutes(-1)) { $st = $sa   # testy testers join under the run folder, the launch is select-<target>
      if (-not $e.transcript -and $e.file) { try { Invoke-KitLocked $e.file { $x = Read-KitState $e.file; if ($x) { $x.transcript = $sa.tf; Write-KitState $e.file $x } } } catch { } } }   # lease grace and shell owners read it too
    if ($st) { $st.covered = $true }; $on = [bool]$st.tx
    $t = if ($on) { $st.tx } else { $tx = & $txOf $e; & $last $e.tool $(if ($tx) { $tx } elseif ($st) { $st.tf }) }
    $w = if ($e.paused -and -not $on) { [pscustomobject]@{ why = 'owner pause'; at = $e.paused; next = "bossy.ps1 resume -Run $($e.run)" } } else { & $waitOf $e.run @($e.agent) }
    if (-not $w -and "$($e.status)" -match '^(?i)wait' -and ($Now - [datetime]$e.beat).TotalMinutes -lt $stuck) { $w = [pscustomobject]@{ why = "$($e.status)"; at = $e.beat; next = '' } }   # its own words (e.g. waiting for area X1) while it beats
    $tn = foreach ($i in "$($e.items)" -split '[,\s]+') { $o = if ($i -and $trk) { $trk[$i] }; if ($o -and -not $o.done) { "track $i`: $(@($o.mrs).Count) MR(s) until promoted$(if ($o.holdPromotion) { " (held: $($o.holdPromotion))" })"; break } }
    $dupKey = "$($e.agent)|$($t.file)"; $twin = if ($t.file) { $byTx[$dupKey] }
    if ($twin) { if ($twin.state -notmatch '^(FIN|STOP)' -or $e.status -eq 'left') { continue }; [void]$rows.Remove($twin) }   # joined twice: one row, live wins
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$($e.agent) ($($e.type))"; run = $e.run; session = $e.session; tx = $t.file; task = (@($(if ($on) { $st.label }), $e.items, $e.run) | Where-Object { $_ }) -join ' · '
          stopped = $(if ($e.crashed -and -not $on) { 'crashed' } elseif ($e.status -ne 'left' -and (Test-KitHolder $e) -eq $false) { 'session gone' } elseif ($st.result.error) { "error: $($st.result.error)" } elseif ($t.killed) { 'killed' })
          done = $(if ($on) { '' } elseif ($e.handoffBrief) { 'handoff' } elseif (($e.status -eq 'left' -and -not $e.paused) -or ($st.result -and [datetime]$e.joined -le $st.jt)) { & $outcome $st } elseif ($t.ended) { 'turn complete' })
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = & $max @($e.beat, $t.at); doing = & $doing $t; started = $e.joined; ended = $(if ($e.crashed) { $e.crashed } else { $e.beat })
          next = $(if ($e.handoffBrief) { "a fresh $($e.type) from $(Split-Path "$($e.handoffBrief)" -Leaf)" } elseif ($tn) { $tn } elseif ("$($e.status)" -notin 'working', 'left') { "$($e.status)" }) }) $Now $stuck))
    $byTx[$dupKey] = $rows[$rows.Count - 1]
  }
  foreach ($st in @($runSteps | Where-Object { -not $_.covered })) {
    $w = & $waitOf $st.run @(LabelNames $st.label); $ty = try { (Get-Content ($st.tf -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json).agentType } catch { '' }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$((($st.label -split ':', 2)[-1] -split '@')[0]) ($(if ($ty) { $ty } else { 'step' }))"; run = $st.run; task = "$($st.label) · $($st.run)"
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = $(if ($st.tx) { $st.tx.at } else { $st.jt }); doing = & $doing $st.tx; started = (Get-Item -LiteralPath $st.tf -ErrorAction SilentlyContinue).CreationTime; next = '' }) $Now $stuck))
  }
  @($rows)
}
# Claude Code wraps cells only at spaces and draws cards when a word does not fit
function Format-KitCell($Text, [int]$Max = 12, [switch]$Exact) {
  $t = "$Text" -replace '[\r\n]+', ' '
  if (-not $Exact) { $t = $t -replace '\bwf_([0-9a-f]{8})[0-9a-f-]*', '$1' -replace '\b20\d\d-\d\d-\d\d-(?=\S)', '' }
  $t = $t -replace '(\\*)\|', '$1$1\|'   # escaped before the split (backslashes doubled: \\| ends the cell); never split inside \|
  $out = [Collections.Generic.List[string]]::new()
  foreach ($w in @($t -split '\s+' | Where-Object { $_ })) {
    if ($w.Length -le $Max -or $w -match '^-[A-Za-z]+$') { $out.Add($w); continue }   # a split -Parameter is a broken command (-Hold Promotion)
    $cur = ''
    foreach ($p in [regex]::Split($w, '(?<=[-_.:,;/\\=])(?!\\*\|)(?=.)|(?<=[a-z])(?=[A-Z])')) {
      if ($cur -and ($cur + $p).Length -gt $Max) { $out.Add($cur); $cur = '' }
      $cur += $p
      while ($cur.Length -gt $Max) {
        $c = $Max; while ($c -gt 1 -and $cur[$c - 1] -eq '\' -and $cur.Substring($c) -match '^\\*\|') { $c-- }
        if ($c -gt 1 -and [char]::IsHighSurrogate($cur[$c - 1])) { $c-- }   # never half an emoji
        $out.Add($cur.Substring(0, $c)); $cur = $cur.Substring($c)
      }
    }
    if ($cur) { $out.Add($cur) }
  }
  $out -join ' '
}
# a cell over $Max chars turns the table into cards; full text in supervise-report.md
function Limit-KitCell($Text, [int]$Max = 80) {
  $t = ("$Text" -replace '\s+', ' ' -replace '&\s*\S*[\\/](\w+\.ps1)\b', '$1').Trim()   # a kit script by its name
  if ($Max -le 0 -or $t.Length -le $Max) { return $t }
  $c = $t.Substring(0, $Max); $cl = @([regex]::Matches($c, '[;:.](?=\s)|\s\(') | Where-Object Index -ge 12)[-1]
  if ($cl) { return $t.Substring(0, $cl.Index).TrimEnd() }
  $c = $t.Substring(0, $Max - 2); if ([char]::IsHighSurrogate($c[-1])) { $c = $c.Substring(0, $c.Length - 1) }; $sp = $c.LastIndexOf(' '); "$($c.Substring(0, $(if ($sp -gt 0) { $sp } else { $c.Length })).TrimEnd(' ', ',', ';', ':', '-')) …"
}
# worst states first
function Format-KitStatusTable($Rows, $Now, $Versions, [int]$Cap = 0) {
  $Now = if ($Now) { [datetime]$Now } else { Get-Date }
  $cut = { param($t) Format-KitCell (Limit-KitCell $t $Cap) }
  $hm = { param($t) if ($t) { ([datetime]$t).ToString('HH:mm') } else { '—' } }
  '| Agent | Task / run | State | Since | Last progress | Next |'; '|---|---|---|---|---|---|'
  foreach ($r in @($Rows | Sort-Object { @{ STUCK = 0; STOPPED = 1; WAITING = 2; ACTIVE = 3; FINISHED = 4 }[$_.state] }, name)) {
    $sc = switch ($r.state) { 'ACTIVE' { "ACTIVE$(if ($r.left) { " ($($r.left) step$(if ($r.left -ne 1) { 's' }) left)" })" } 'WAITING' { "WAITING: $($r.wait)" } 'FINISHED' { "FINISHED: $($r.done)" }
      'STUCK' { "STUCK ($(if ($r.last) { "$([int]($Now - [datetime]$r.last).TotalMinutes) min" } else { 'no progress seen' }))" } default { "STOPPED ($($r.stopped))" } }
    "| $(& $cut $r.name) | $(& $cut $r.task) | $(& $cut $sc) | $(& $hm $r.since) | $(& $hm $r.last)$(if ($r.doing) { ' ' + (Limit-KitCell (Format-KitCell $r.doing) $(if ($Cap) { $Cap - 6 } else { 0 })) }) | $(if ($r.next) { & $cut $r.next } else { '—' }) |"
  }
  if (-not @($Rows).Count) { '| — | nothing running | — | — | — | — |' }
  if ($Versions -and $Versions.Count) { "transcripts read: $(@($Versions.Values | Sort-Object) -join ', ')" }
}

# ---- supervise sweep: sections by learned cost, starved first, promotion always; slow calls in the background
# runs when its cost fits the time left after starved sections; supervise.sectionMinutes caps its cadence
function New-KitSweep([datetime]$Deadline, $State) {
  $sw = if ($State.sweep -is [Collections.IDictionary]) { $State.sweep } else { @{} }; if ($sw.cost -isnot [Collections.IDictionary] -or $sw.v -ne 2) { $sw.cost = @{} }   # v2: costs exclude ungated work
  $every = @{ 'cleanup' = 30; 'deploy checks' = 10; 'stale layers' = 15 }   # only one-shot sections: standing flags would vanish off-round
  $cf = Get-KitSetting 'supervise.sectionMinutes' $null; if ($cf) { foreach ($p in @($cf.PSObject.Properties | Where-Object MemberType -eq NoteProperty)) { $v = 0.0; if ([double]::TryParse("$($p.Value)", [ref]$v)) { $every[$p.Name] = $v } } }
  [pscustomobject]@{ deadline = $Deadline; cost = $sw.cost; starved = @($sw.starved | Where-Object { $_ }); last = $(if ($sw.last -is [Collections.IDictionary]) { $sw.last } else { @{} }); every = $every; always = @('tracker checks'); ran = @{}; cur = $null; t = $null; skipped = [Collections.Generic.List[string]]::new(); timedOut = [Collections.Generic.List[string]]::new() }
}
# an ungated phase (~<name>): reported, never charged to the prior section
function Start-KitSweepPhase($Sw, [string]$Name, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds }
  $Sw.cur = "~$Name"; $Sw.t = $Now
}
function Test-KitSweep($Sw, [string]$Name, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds; $Sw.cur = $null }
  if (-not $Sw.ran.ContainsKey($Name) -and $Sw.last[$Name] -and ($Now - [datetime]$Sw.last[$Name]).TotalMinutes -lt [double]$Sw.every[$Name]) { return $false }
  $left = ($Sw.deadline - $Now).TotalSeconds
  $hold = [math]::Min(0.5 * $left, [double](@($Sw.starved | Where-Object { $_ -ne $Name -and -not $Sw.ran.ContainsKey($_) } | ForEach-Object { [double]$Sw.cost[$_] }) | Measure-Object -Sum).Sum)   # starved reserve at most half: none starves the rest
  # starved: up to 10 s past the deadline
  $go = if ($Name -in $Sw.always) { $true } elseif ($Name -in $Sw.starved) { $left + 10 -ge [math]::Min([double]$Sw.cost[$Name], 5) } else { $left -gt 0 -and $left -ge [double]$Sw.cost[$Name] + $hold }
  if ($go) { $Sw.cur = $Name; $Sw.t = $Now } elseif ($Name -notin $Sw.skipped) { $Sw.skipped.Add($Name) }
  $go
}
# sweep end: stores costs (EWMA 0.3) and the starved list
function Complete-KitSweep($Sw, $State, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds; $Sw.cur = $null }
  foreach ($n in @($Sw.ran.Keys | Where-Object { -not "$_".StartsWith('~') })) { $c = $Sw.cost[$n]; $Sw.cost[$n] = [math]::Round($(if ($null -ne $c) { 0.7 * [double]$c + 0.3 * $Sw.ran[$n] } else { $Sw.ran[$n] }), 2); if ($Sw.every[$n]) { $Sw.last[$n] = $Now.ToString('o') } }
  $State.sweep = @{ v = 2; cost = $Sw.cost; last = $Sw.last; starved = @($Sw.skipped | Where-Object { -not $Sw.ran.ContainsKey($_) }) }
  "slowest: $(@($Sw.ran.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 5 | ForEach-Object { '{0} {1:0.0} s' -f $_.Key, $_.Value }) -join ', ')"   # ~ = ungated phase
}
# inline within the time left; -Background over half of it, or -Detached: background, last finished result now
function Invoke-KitSweepCall($Sw, [string]$Name, [string]$Script, [string[]]$A, [switch]$Background, [string]$Job, [switch]$Detached) {
  $left = [math]::Max(5, [int]($Sw.deadline - (Get-Date)).TotalSeconds); $c = $Sw.cost[$Name]
  if (-not $Detached -and (-not $Background -or $null -eq $c -or [double]$c -le $left / 2)) {
    $t0 = Get-Date; $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $Script) + $A) $left; $s = ((Get-Date) - $t0).TotalSeconds
    $Sw.cost[$Name] = [math]::Round($(if ($r.timedOut) { [math]::Max(2 * $s, [double]$c) } elseif ($null -ne $c) { 0.7 * [double]$c + 0.3 * $s } else { $s }), 2); if ($r.timedOut) { $Sw.timedOut.Add($Name) }   # cut short: at least 2x what it got
    return @($r.out -split "`r?`n" | Where-Object { $_ })
  }
  @(Invoke-KitBackground $(if ($Job) { $Job } else { $Name }) $Script $A { param($s) $Sw.cost[$Name] = [math]::Round(0.7 * [double]$Sw.cost[$Name] + 0.3 * $s, 2) } ([double]$c))
}
# past max(10 x cost, 30 min) = hung, stopped; empty result with errors = WATCH
function Invoke-KitBackground([string]$Name, [string]$Script, [string[]]$A, [scriptblock]$OnSeconds, [double]$Cost = 0) {
  $d = Get-KitPath background -Create; $sl = ConvertTo-KitSlug $Name
  if ($sl.Length -gt 100) { $sl = $sl.Substring(0, 80) + '-' + [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($sl))).Substring(0, 12) }   # stay within MAX_PATH
  $base = Join-Path $d $sl; $res = @{ out = @() }
  Invoke-KitLocked "$base.json" {
    $run = try { Get-Content -LiteralPath "$base.json" -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    $busy = $run -and (Test-KitPid $run.pid $run.start)
    if ($busy -and ((Get-Date) - [datetime]$run.at).TotalMinutes -gt [math]::Max(30, 10 * $Cost / 60)) {
      if ($KitIsWindows) { $null = & taskkill /PID ([int]$run.pid) /T /F 2>$null } else { Stop-Process -Id $run.pid -Force -ErrorAction SilentlyContinue }   # the launcher, its job and the job's children
      $busy = $false; $res.out = @("WATCH background $Name hung $([int]((Get-Date) - [datetime]$run.at).TotalMinutes) min: stopped, started again")
    }
    elseif ($run -and -not $busy -and -not (Test-Path -LiteralPath "$base.out")) { $res.out = @("WATCH background $Name ended without output (launch failed): started again") }
    elseif ($run -and -not $busy) {
      $res.out = @(Get-Content -LiteralPath "$base.out" | Where-Object { $_ }); $er = @(Get-Content -LiteralPath "$base.err" -ErrorAction SilentlyContinue | Where-Object { $_ })
      if (-not $res.out.Count -and $er.Count) { $res.out = @("WATCH background $Name failed: $($er[0])") }
      if (-not $run.read -and $OnSeconds) { & $OnSeconds ((Get-Item -LiteralPath "$base.out").LastWriteTime - [datetime]$run.at).TotalSeconds }
      $run | Add-Member -Force NoteProperty read $true; Write-KitAtomic "$base.json" ($run | ConvertTo-Json -Compress)
    }
    if (-not $busy) {
      Remove-Item -LiteralPath "$base.out", "$base.err" -Force -ErrorAction SilentlyContinue
      $fileArgs = @('-NoProfile', '-NonInteractive', '-File', "`"$Script`"") + @($A | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } })
      # Windows: -Redirect* inherits the caller's stdout (a -Brief call hung 120+ s): a hidden pwsh runs the job
      $sq = { param($s) "'$("$s" -replace '([\u2018-\u201B''])', '$1$1')'" }   # PowerShell reads the smart quotes as ' too
      $bc = "(Start-Process pwsh -ArgumentList $(@($fileArgs | ForEach-Object { & $sq $_ }) -join ',') -NoNewWindow -PassThru -RedirectStandardOutput $(& $sq "$base.out") -RedirectStandardError $(& $sq "$base.err")).WaitForExit()"
      $p = if ($KitIsWindows) { Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bc))) -WindowStyle Hidden -PassThru } else { Start-Process pwsh -ArgumentList $fileArgs -PassThru -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err" }
      Write-KitAtomic "$base.json" (@{ pid = $p.Id; start = (Get-KitPidStart $p.Id); at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
    }
  }
  $res.out
}
# ---- supervise report: -Brief, no LLM step; pure on $d, so fixtures test it
# a FINISHED row shows for supervise.finishedMinutes after it ended
function Select-KitBriefRows($Rows, [datetime]$Now) {
  $fm = [double](Get-KitSetting 'supervise.finishedMinutes' 30)
  @($Rows | Where-Object { $_.state -ne 'FINISHED' -or -not $_.ended -or ($Now - [datetime]$_.ended).TotalMinutes -le $fm })
}
function Format-KitReport($d) {
  $g1 = { param($x) [math]::Round([double]$x, 1) }
  $reportLines = [Collections.Generic.List[string]]::new()
  foreach ($l in @(Format-KitStatusTable $d.rows $d.at $null -Cap 80) + '') { $reportLines.Add($l) }
  # flags: ACT, WATCH, then INFO (deploy-ready envs)
  $fl = @(@($d.flags | Where-Object { $_.level -ne 'INFO' } | Sort-Object { @{ ACT = 0; WATCH = 1 }[$_.level] }) + @($d.info | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }))
  if ($fl.Count) { $reportLines.Add('| Level | Flag | Who / item | Age | Problem | Next step |'); $reportLines.Add('|---|---|---|---|---|---|') }
  foreach ($f in $fl) {
    $c = Get-KitFlagCells $f
    $reportLines.Add("| $($f.level) | $(@($c.kind, $c.who, $c.age, $c.problem, $c.action | ForEach-Object { if ("$_".Trim()) { Format-KitCell (Limit-KitCell $_ 80) -Exact } else { '—' } }) -join ' | ') |")
  }
  if ($fl.Count) { $reportLines.Add('') }   # GFM: a plain line right after a table becomes a row
  # RAM below the flags: the owner reads flags first
  $m = $d.mem
  $reportLines.Add("**RAM** $(& $g1 ($m.TotalGB - $m.AvailGB)) / $(& $g1 $m.TotalGB) GB used, $(& $g1 $m.AvailGB) GB free$(if ($m.AvailGB -lt $d.keepFree) { " (below the floor $($d.keepFree) GB)" })")
  $rs = @($d.resources | Sort-Object { -[double]$_.gb })
  if ($rs.Count) {
    # up to 3 column groups side by side: 9 columns fit only short cells (words at 9, cells at 24)
    $gs = if ($rs.Count -le 4) { 1 } elseif ($rs.Count -le 8) { 2 } else { 3 }
    $reportLines.Add(''); $reportLines.Add('|' + ' Resource | Used by | RAM |' * $gs); $reportLines.Add('|' + '---|' * (3 * $gs))
    $rc = @(foreach ($r in $rs) { "$(Limit-KitCell (Format-KitCell $r.name 9) 24) | $(if ($r.by) { Limit-KitCell (Format-KitCell $r.by 9) 24 }) | $(if ($r.gb) { & $g1 $r.gb })" })
    for ($i = 0; $i -lt $rc.Count; $i += $gs) { $row = @($rc[$i..([math]::Min($i + $gs, $rc.Count) - 1)]); while ($row.Count -lt $gs) { $row += ' |  | ' }; $reportLines.Add('| ' + ($row -join ' | ') + ' |') }
  }
  $reportLines.Add('')
  foreach ($l in @(Format-KitShellTable $d.shells)) { $reportLines.Add($l) }
  @($reportLines)
}
# Get-KitShellSweep rows: problems first, then oldest
function Format-KitShellTable($Shells) {
  if (-not @($Shells | Where-Object { $_ }).Count) { return }
  $cut = { param($t, [int]$m) if ("$t".Trim()) { Limit-KitCell (Format-KitCell $t -Exact) $m } else { '—' } }
  '| Shell | Owner | Age | State | Next |'; '|---|---|---|---|---|'
  foreach ($s in @($Shells | Sort-Object { $_.state -eq 'running' }, { -$_.age })) {
    "| $(& $cut $s.short 60) | $(& $cut $s.owner 40) | $(if ($s.age -ge 120) { '{0:0.#} h' -f ($s.age / 60) } else { "$($s.age) min" }) | $($s.state) | $(& $cut $s.next 80) |"
  }
  ''
}
# no producer kind: an upper-case lead ("RESTART LOOP: ...") is the kind
function Get-KitFlagCells($f) {
  $kind = $f.kind; $problem = $f.problem
  if (-not $kind -and "$($f.what)" -cmatch '^([A-Z]{3,}(?:[ -][A-Z]{3,})*):?\s+(.+)$') { $kind = $Matches[1]; if (-not $problem) { $problem = $Matches[2] } }
  [pscustomobject]@{ kind = $kind; who = $f.who; age = $f.age; problem = $(if ($problem) { $problem } else { $f.what }); action = $(if ($f.next) { $f.next } else { $f.action }) }
}
# a flag's identity across rounds: counts, times and sizes vary
function Get-KitFlagKey([string]$What) { $k = (($What.ToLower() -replace '\b\d+\b', '#') -replace '\s+', ' ').Trim(); $k.Substring(0, [math]::Min(160, $k.Length)) }
# -Ack text pasted from the -Brief table: cells add spaces after - / (word wrap), escape |, end in …, join with ·; counts vary
function ConvertTo-KitAckText([string]$Text) { ($Text.ToLower() -replace '\b\d+\b', '#') -replace '[\s\\|…·''"`]', '' }
# an ack matches the flag's whole line or any one cell
function Test-KitAcked($Flag, [string[]]$Keys) {
  $c = Get-KitFlagCells $Flag; $w = ConvertTo-KitAckText "$($Flag.what)"; $cells = ConvertTo-KitAckText "$($c.kind) $($c.who) $($c.problem)"
  [bool]@($Keys | ForEach-Object { ConvertTo-KitAckText $_ } | Where-Object { $_.Length -ge 12 -and ($w.Contains($_) -or $cells.Contains($_)) }).Count
}
# an acknowledged one (answered / proven false) hides 24 h
function Select-KitFlags($Flags, $Acks, [datetime]$Now) {
  $seen = @{}; $hid = 0; $live = @($Acks.Keys | Where-Object { ($Now - [datetime]$Acks[$_].at).TotalHours -lt 24 })
  $keep = @(foreach ($f in @($Flags)) { $k = Get-KitFlagKey $f.what; if ($seen[$k]) { continue }; $seen[$k] = 1
      if ($f.level -ne 'INFO' -and $live.Count -and (Test-KitAcked $f $live)) { $hid++; continue }; $f })
  if ($hid) { $keep += [pscustomobject]@{ level = 'INFO'; what = "$hid acknowledged flag(s) hidden (supervise -Ack, 24 h)"; action = 'Nothing to do.' } }
  $keep
}
# flags with refs (UNTRACKED MR, ERROR SPIKE) store the refs, so a new ref flags again
function Add-KitFlagAck([string]$Ack, [string]$Reason) {
  $sf0 = Get-KitPath supervise-state -Create; $k0 = Get-KitFlagKey $Ack; $script:ackOut = ''
  Invoke-KitLocked $sf0 { $s0 = try { Get-Content $sf0 -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $s0) { $s0 = @{} }; if (-not $s0.acks) { $s0.acks = @{} }
    $hit = @($s0.lastFlags | Where-Object { $_ -and (Test-KitAcked ([pscustomobject]$_) @($k0)) }); $refs = @($hit | ForEach-Object { @($_.refs) } | Where-Object { $_ })
    if ($refs.Count) { if (-not $s0.known) { $s0.known = @{} }; foreach ($r in $refs) { $s0.known[$r] = (Get-Date).ToString('o') } }
    if (-not $hit.Count -or @($hit | Where-Object { -not @(@($_.refs) | Where-Object { $_ }).Count }).Count) { $s0.acks[$k0] = @{ at = (Get-Date).ToString('o'); reason = $Reason } }
    Write-KitAtomic $sf0 ($s0 | ConvertTo-Json -Depth 5)
    $script:ackOut = "$(if ($refs.Count) { "known from now on (they no longer flag; a new one does): $(@($refs | Select-Object -First 5) -join ' · ')$(if ($refs.Count -gt 5) { " +$($refs.Count - 5)" })" } else { "acknowledged for 24 h: $k0" })$(if ($Reason) { " ($Reason)" })`n$(if ($hit.Count) { "hides $($hit.Count) flag(s) of the last round: $(@($hit | ForEach-Object { "$($_.what)".Substring(0, [math]::Min(90, "$($_.what)".Length)) }) -join ' · ')" } else { 'matches no flag of the last round: check the text (any later flag containing it hides)' })" }
  $script:ackOut
}
# supervise anomalies: pure -> WATCH flags + next state
function Get-KitAnomalies($c, $p) {
  $f = [Collections.Generic.List[object]]::new(); $AddF = { param($w, $a) $f.Add([pscustomobject]@{ level = 'WATCH'; what = $w; action = $a }) }; if (-not $p) { $p = @{} }
  if ($null -ne $p.outbox -and $c.outbox -gt [int]$p.outbox) { & $AddF "SILENT FAILURE: tracker outbox grew to $($c.outbox) write(s)" 'evidence .state/outbox.jsonl: tracker auth / network' }
  if ($null -ne $p.toolErrors -and $c.toolErrors -gt [int]$p.toolErrors) { & $AddF "SILENT FAILURE: $($c.toolErrors - [int]$p.toolErrors) new agent result error(s)" "evidence $($c.errorRun) journal" }
  [pscustomobject]@{ flags = @($f); state = @{ outbox = $c.outbox; toolErrors = $c.toolErrors } }
}
# supervise -Brief's report file: whole cells, one table per section
function Write-KitSuperviseReport($d, [string[]]$Md, [string[]]$Sweep, [string]$Next) {
  $ag = { param($st) Format-KitMdTable 'Agent', 'Task', 'State', 'Doing', 'Next' @($d.rows | Where-Object { ($_.state -eq 'FINISHED') -eq $st } | ForEach-Object { , @($_.name, $_.task, "$($_.state) $($_.wait)$($_.done)$($_.stopped)", $_.doing, $_.next) }) }
  $n = { param($l) @($d.flags | Where-Object level -eq $l).Count }
  @("# Supervise report $($d.at.ToString('yyyy-MM-dd HH:mm'))", "**Result:** $(& $n ACT) ACT · $(& $n WATCH) WATCH · $(@($d.rows | Where-Object state -ne 'FINISHED').Count) live · $Next$(if ($d.versions.Count) { " · transcripts: $(@($d.versions.Values | Sort-Object) -join ', ')" })", '') + $Md +
    @('', '## Agents (whole cells)', '') + @(& $ag $false) + @('', '## Finished today', '') + @(& $ag $true) + @('', '## All flags', '') +
    @(Format-KitMdTable 'Level', 'Flag', 'Action' @(@($d.flags | ForEach-Object { , @($_.level, $_.what, $_.action) }) + @($d.info | Where-Object { $_ } | ForEach-Object { , @('INFO', $_, '') }))) +
    @('', '## Resources', '') + @(Format-KitMdTable 'Resource', 'Holder', 'GB' @($d.resources | ForEach-Object { , @($_.name, $_.by, $_.gb) })) +
    @('', '## Shells (whole commands)', '') + @(Format-KitMdTable 'PID', 'Owner', 'Age min', 'State', 'Dir', 'Command', 'Next' @($d.shells | ForEach-Object { , @($_.pid, $_.owner, $_.age, $_.state, $_.dir, ($_.cmd -replace '\r?\n', ' \n '), $_.next) })) +
    @('', '## Sweep', '', '```text') + $Sweep + '```' |
    Set-Content (Get-KitPath supervise-report -Create) -Encoding utf8
}
# ---- tracker: adapter (a Register-KitAdapter block per tracker.type)

function Initialize-KitTracker([string]$Type, [switch]$DryRun) {
  $script:__trType = ([string]$(if ($Type) { $Type } elseif ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { $KitConf.TrackerType })).ToLower()
  $script:__trDry = [bool]($DryRun -or $env:KIT_TRACKER_DRYRUN -eq '1')

}
$__trRepo = [string](Get-KitSetting 'tracker.repo' '')
$__trNoneDir = Get-KitPath tracker-none

$__trStatus = [ordered]@{
  open = @('open', 'to do'); inProgress = @('in progress'); review = @('for review', 'in review'); promoted = @('promoted')
  inTest = @('in test', 'for test'); failedTesting = @('failed testing', 'test failed'); closed = @('closed', 'complete', 'done')
}
$__trCfgSt = Get-KitSetting 'tracker.statuses' $null
if ($__trCfgSt) { foreach ($__p in $__trCfgSt.PSObject.Properties) { $__trStatus[$__p.Name] = @($__p.Value | ForEach-Object { [string]$_ }) } }

function Resolve-TrackerStatus([string]$Status) {
  foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $Status) { return @($__trStatus[$k])[0] } }
  $Status
}
function Test-TrackerStatus([string]$Status, [string[]]$Logical) {
  foreach ($l in $Logical) { foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $l -and (@($__trStatus[$k]) | Where-Object { $_ -ieq "$Status".Trim() })) { return $true } } }
  $false
}
function __TrText([string]$s) {
  $isFile = $false; if ($s -and $s.Length -lt 260 -and $s -notmatch '[\r\n<>|"*?]') { try { $isFile = Test-Path -LiteralPath $s -PathType Leaf } catch {} }
  if ($isFile) { Get-Content -LiteralPath $s -Raw -Encoding utf8 } else { $s }
}
function __TrQuote([string[]]$a) { ($a | ForEach-Object { if ("$_" -match '[\s"]' -or "$_" -eq '') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' ' }
function __TrShort([string]$s) { $s = $s -replace "`r?`n", '\n'; if ($s.Length -gt 160) { $s.Substring(0, 157) + '...' } else { $s } }
function __TrCli([string]$Exe, [string[]]$A) {
  if ($__trDry) { Write-Host "DRYRUN: $Exe $(__TrShort (__TrQuote $A))"; return $null }
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { throw "tracker ($__trType): the '$Exe' CLI is not on PATH" }
  $h2 = "$($A[0..1] -join ' ')"; $all = "$($A -join ' ')"
  $write = ($h2 -match '(?i)\b(comment|create|add|edit|attach|upload|new)\b' -and $h2 -notmatch '(?i)status') -or ($all -match '(?i)(^|\s)(-X|--method)\s+(POST|PUT|PATCH|DELETE)\b' -and $all -notmatch '(?i)status')
  $r = Invoke-KitRetry { Invoke-KitNetExe $Exe $A } -Connect:$write
  $out = (@($r.out, $r.err) | Where-Object { $_ }) -join "`n"
  if ($r.code -and $out -notmatch 'no matching status') { throw "tracker ($__trType): $Exe $h2 failed (exit $($r.code)): $(__TrShort $out)" }
  $out
}
function __TrJson([string]$Out) {
  if (-not $Out) { return $null }
  $i = @($Out.IndexOf('{'), $Out.IndexOf('[')) | Where-Object { $_ -ge 0 } | Sort-Object | Select-Object -First 1
  if ($null -eq $i) { return $null }
  try { $Out.Substring($i) | ConvertFrom-Json } catch { $null }
}
function __TrTemp([string]$Text) { $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, $Text, (New-Object Text.UTF8Encoding $false)); $f }
function __TrStub([string]$Id) { [pscustomobject]@{ id = $Id; name = ''; status = ''; url = (Get-TrackerUrl $Id); parent = $null; assignees = @(); subtasks = @(); list = ''; description = '' } }
function __TrDate($d) { if ($d -match '^\d{10,}$') { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d).UtcDateTime.ToString('s') } elseif ($d) { ([datetime]$d).ToUniversalTime().ToString('s') } else { '' } }
function __TrPrio([string]$p) { switch ($p) { '1' { 'urgent' } '2' { 'high' } '3' { 'normal' } '4' { 'low' } default { $p } } }
function __TrWho($id, $u) { [pscustomobject]@{ id = "$id"; username = "$u" } }
function __TrSub($i, $n, $s, $u) { [pscustomobject]@{ id = $i; name = $n; status = $s; url = $u } }
function __TrRow($i, $n, $s, $who) { [pscustomobject]@{ id = $i; name = $n; status = $s; assignees = $who } }
function __TrComment($u, $d, $t, $i) { [pscustomobject]@{ user = [string]$u; date = (__TrDate $d); text = [string]$t; id = [string]$i } }
function __TrTask($i, $n, $s, $u, $p, $who, $l, $subs, $d) { [pscustomobject]@{ id = $i; name = $n; status = $s; url = $u; parent = $p; assignees = $who; list = $l; subtasks = $subs; description = $d } }
function __TrPartOf($a) { if ($a.parent) { "Part of #$($a.parent -replace '^.*#', '')`n`n" } }
function __TrNote($a) { if ($a.text) { Add-TrackerComment $a.id "$($a.text) (attached: $($a.leaf))" } }
function __TrAttachText($a) {
  $b = Get-Content -LiteralPath $a.file -Raw -Encoding utf8
  if ($b.Length -gt 60000) { $b = $b.Substring(0, 60000) + "`n`n_(truncated: the full $($a.leaf) is in the QA run folder)_" }
  Add-TrackerComment $a.id ($(if ($a.text) { "$($a.text)`n`n" }) + $b)
}

function __TrRef([string]$Id) {
  if ($Id -match '^(?<r>[^#\s]+)#(?<n>\S+)$') { return @($Matches.r, $Matches.n) }
  if (-not $__trRepo -and -not $__trDry) { throw "tracker ($__trType): set ""tracker"": { ""repo"": ""owner/name"" } in kit.local.json" }
  @($(if ($__trRepo) { $__trRepo } else { '<tracker.repo>' }), ($Id -replace '^#', ''))
}
function __TrRepoOf([string]$List) { if ($List -match '/') { $List } else { (__TrRef '0')[0] } }
function __TrLabelStatus($labels, [bool]$closed) {
  if ($closed) { return @($__trStatus.closed)[0] }
  $l = @($labels | Where-Object { $_ -like "$__trLp*" } | Select-Object -First 1)
  if ($l) { return ([string]$l[0]).Substring($__trLp.Length) }
  @($__trStatus.open)[0]
}
function __TrIsClosed([string]$name) { Test-TrackerStatus $name 'closed' }
function __TrIssue($Num, $Name, $St, $Url, $Who, $Repo, [string]$Body, [scriptblock]$Sub) {
  __TrTask "$Num" $Name $St $Url $(if ($Body -match '(?m)^Part of #(\d+)') { $Matches[1] }) $Who $Repo @([regex]::Matches($Body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object $Sub) $Body
}

function __TrNone([string]$Id, [string]$What, [scriptblock]$Change) {
  $d = Get-KitPath tracker-none -Create
  Write-KitLog calls tracker-none @{ id = $Id; what = (__TrShort $What) }
  if (-not $Id) { return $null }
  $f = Join-Path $d "$($Id -replace '[^\w.-]', '_').json"
  $o = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
  if ($Change) { if (-not $o) { $o = [pscustomobject]@{ id = $Id; name = ''; status = ''; parent = $null; list = ''; assignees = @(); description = ''; comments = @() } }; & $Change $o; $o | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8 }
  $o
}
function __TrNoneAll { Get-ChildItem $__trNoneDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } }
function __TrNoneNote($o, [string]$t) { $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('o'); text = $t; id = "c$(@($o.comments).Count + 1)$([guid]::NewGuid().ToString('n').Substring(0, 6))" }) }

function __TrOsFullName {
  $n = ''
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    try { $n = (Get-LocalUser $env:USERNAME -ErrorAction Stop).FullName } catch {}
    if (-not $n) { try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement; $n = [System.DirectoryServices.AccountManagement.UserPrincipal]::Current.DisplayName } catch {} }
  } else { try { $n = ((getent passwd $env:USER) -split ':')[4] -split ',' | Select-Object -First 1 } catch {} }
  if (-not $n) { try { $n = git config --global user.name } catch {} }
  ([string]$n).Trim()
}
# ----- backends: $a = id, text, status (tracker name), logical, name, list, parent, assignee, priority, file, leaf
# tracker clickup, github: goodies tracker-clickup, github
# adapter:tracker/command: tracker.commands.<verb> = a CLI line, {placeholders} = $a keys; prints the kit's JSON
Register-KitAdapter 'tracker' 'command' @{ '*' = { param($a, $v)
    $c = Get-KitSetting 'tracker.commands' $null; if ($v -in 'url', 'owner' -and -not $c.$v) { return $(if ($v -eq 'url') { $a.id } else { $a.name }) }
    if ($__trDry) { Write-Host "DRYRUN: tracker command $v $(__TrShort ($a | ConvertTo-Json -Compress))"; return }
    Invoke-KitCommand 'tracker' $c $v $a } }
# adapter:tracker/none: local store (.state/tracker-none) + log
Register-KitAdapter 'tracker' 'none' @{
  'url' = { param($a) Join-Path $__trNoneDir "$($a.id -replace '[^\w.-]', '_').json" }
  'view' = { param($a)
    $o = __TrNone $a.id 'view' $null; if (-not $o) { return }
    __TrTask $o.id $o.name $o.status (Get-TrackerUrl $o.id) $o.parent @($o.assignees) $o.list @(__TrNoneAll | Where-Object { $_.parent -eq $a.id } | ForEach-Object { __TrSub $_.id $_.name $_.status (Get-TrackerUrl $_.id) }) $o.description
  }
  'status' = { param($a) $null = __TrNone $a.id "status $($a.status)" { param($o) $o.status = $a.status }; "status of $($a.id): $($a.status) (tracker none)" }
  'comment' = { param($a) $null = __TrNone $a.id "comment $($a.text)" { param($o) __TrNoneNote $o $a.text }; "commented on $($a.id) (tracker none)" }
  'comments' = { param($a) @((__TrNone $a.id 'comments' $null).comments) }
  'comment-edit' = { param($a) $null = __TrNone $a.id "comment-edit $($a.comment)" { param($o) foreach ($c in @($o.comments)) { if ($c.id -eq $a.comment) { $c.text = $a.text } } }; "edited comment $($a.comment) on $($a.id) (tracker none)" }
  'comment-delete' = { param($a) $null = __TrNone $a.id "comment-delete $($a.comment)" { param($o) $o.comments = @($o.comments | Where-Object { $_.id -ne $a.comment }) }; "deleted comment $($a.comment) on $($a.id) (tracker none)" }
  'create' = { param($a)
    $d = Get-KitPath tracker-none -Create; $n = 1 + @(Get-ChildItem $d -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count
    while (Test-Path (Join-Path $d "LOCAL-$n.json")) { $n++ }
    $null = __TrNone "LOCAL-$n" "create $($a.name)" { param($o) $o.name = $a.name; $o.status = @($__trStatus.open)[0]; $o.parent = $a.parent; $o.list = $a.list; $o.assignees = @($a.assignee | Where-Object { $_ }); $o.description = $a.description }
    [pscustomobject]@{ id = "LOCAL-$n"; url = Get-TrackerUrl "LOCAL-$n" }
  }
  'describe' = { param($a) $null = __TrNone $a.id 'describe' { param($o) $o.description = $a.text }; "described $($a.id) (tracker none)" }
  'rename' = { param($a) $null = __TrNone $a.id "rename $($a.name)" { param($o) $o.name = $a.name }; "renamed $($a.id) (tracker none)" }
  'attach' = { param($a) $null = __TrNone $a.id "attach $($a.file)" { param($o) __TrNoneNote $o "$($a.text) [attachment: $($a.file)]" }; "attached $($a.leaf) to $($a.id) (tracker none)" }
  'list' = { param($a) @(__TrNoneAll | Where-Object { (-not $a.list -or "$($_.list)" -eq $a.list) -and ((Test-TrackerStatus "$($_.status)" $a.logical) -or "$($_.status)" -ieq $a.status) } | ForEach-Object { __TrRow $_.id $_.name $_.status @($_.assignees | ForEach-Object { __TrWho $_ $_ }) }) }
  'owner' = { param($a) $a.name }
}
# adapter-end:tracker
# goodies register their adapters before the tracker type is resolved
$script:KitAdapterFiles = @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName)
foreach ($__plugin in $script:KitAdapterFiles) { . $__plugin }
Initialize-KitTracker

# ----- verbs: dispatch to the tracker.type backend
function __TrA([string]$Verb, [hashtable]$A) { Invoke-KitAdapter 'tracker' $__trType $Verb $A }
function Get-TrackerUrl([string]$Id) { __TrA 'url' @{ id = $Id } }

if (-not $global:KitTrackerMemo) { $global:KitTrackerMemo = @{} }
function Get-TrackerTask([string]$Id) {
  $res = Get-KitMemo $global:KitTrackerMemo "$($__trType)|$Id" 90 {
    $v = __Get-TrackerTask $Id
    if ($v -and $v.name) { $v } else { $null }
  }
  if ($null -ne $res) { $res } else { __Get-TrackerTask $Id }
}
function Clear-TrackerMemo([string]$Id) { $global:KitTrackerMemo.Remove("$($__trType)|$Id") }
function __Get-TrackerTask([string]$Id) { $v = __TrA 'view' @{ id = $Id }; if ($v.id) { $v } else { __TrStub $Id } }

function Add-KitOutbox([string]$Op, [string]$Id, [string]$Arg, [string]$Why) {
  $f = Get-KitPath outbox -Create
  $line = [ordered]@{ at = (Get-Date).ToString('o'); op = $Op; id = $Id; arg = $Arg; tracker = $__trType; tries = 0; why = $Why } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
  Write-Warning "tracker ($__trType): $Op $Id failed on the network ($Why): queued; bossy.ps1 supervise replays it"
  "QUEUED $Op $Id (network; outbox replays it)"
}
function Invoke-TrackerWrite([string]$Op, [string]$Id, [string]$Arg, [scriptblock]$Call) {
  try { & $Call }
  catch {
    $m = "$($_.Exception.Message)"
    if ($__trDry -or $env:KIT_NO_OUTBOX -eq '1' -or -not (Test-KitTransient $_)) { throw }
    Add-KitOutbox $Op $Id $Arg (__TrShort $m)
  }
}
function Invoke-KitOutbox([switch]$DryRun) {
  $f = Get-KitPath outbox; if (-not (Test-Path $f)) { return }
  Invoke-KitLocked $f {
    $keep = [Collections.Generic.List[string]]::new()
    foreach ($l in @(Get-Content -LiteralPath $f | Where-Object { $_.Trim() })) {
      $e = try { $l | ConvertFrom-Json } catch { $null }; if (-not $e) { continue }
      if ($DryRun) { "QUEUED $($e.op) $($e.id) since $($e.at) (tries $($e.tries)): $($e.why)"; $keep.Add($l); continue }
      if ($e.op -eq 'status' -and ((Get-Date) - [datetime]$e.at).TotalHours -gt 24) { "GAVE UP $($e.op) $($e.id) -> $($e.arg): queued > 24 h ago (a person may have moved it)"; continue }
      try {
        $out = if ($e.op -eq 'status') { __Set-TrackerStatus $e.id $e.arg } else { __Add-TrackerComment $e.id $e.arg }
        "SENT $($e.op) $($e.id) (queued $($e.at)): $(__TrShort "$out")"
      } catch {
        $m = "$($_.Exception.Message)"; $e.tries = [int]$e.tries + 1; $e.why = __TrShort $m
        if ((Test-KitTransient $_) -and $e.tries -lt 20) { $keep.Add(($e | ConvertTo-Json -Compress)) }
        else { "GAVE UP $($e.op) $($e.id) after $($e.tries) tries: $($e.why)" }
      }
    }
    if ($keep.Count) { [IO.File]::WriteAllLines($f, $keep) } else { Remove-Item -LiteralPath $f -Force }
  }
}
function Set-TrackerStatus([string]$Id, [string]$Status) {
  # promoted needs both doc links; an unread task fails closed (KIT_DOC_GATE=1: also tracker none)
  if (($Status -eq 'promoted' -or (Test-TrackerStatus $Status 'promoted')) -and ($__trType -ne 'none' -or $env:KIT_DOC_GATE -eq '1') -and (Test-KitTaskDocLink $Id) -ne $true) {
    throw "tracker: $Id not set to $Status`: its description lacks 'Testing doc (human):' and 'Testing doc (AI):' links (devtools.py finish writes them) or the task could not be read"
  }
  Invoke-TrackerWrite 'status' $Id $Status { __Set-TrackerStatus $Id $Status }
}
function Add-TrackerComment([string]$Id, [string]$Text) { if (-not "$Id".Trim()) { throw 'tracker comment: no task id (a tracker CLI would guess it from the branch name)' }; $t = __TrText $Text; Invoke-TrackerWrite 'comment' $Id $t { __Add-TrackerComment $Id $t } }
function __Set-TrackerStatus([string]$Id, [string]$Status) { Clear-TrackerMemo $Id; __TrA 'status' @{ id = $Id; status = (Resolve-TrackerStatus $Status); logical = $Status } }
function __Add-TrackerComment([string]$Id, [string]$Text) { Clear-TrackerMemo $Id; __TrA 'comment' @{ id = $Id; text = (__TrText $Text) } }
function Get-TrackerComments([string]$Id) { @(__TrA 'comments' @{ id = $Id } | Where-Object { $_ } | Sort-Object date) }
# ONE kit comment per kind: edit, else post + delete old, else post; found by id, last text or legacy '[kit:<kind>]'
# marker. People's comments are never touched
function Get-KitCommentSig([string]$Text) { $n = ConvertTo-KitLetters ("$Text" -replace '\\?\[kit:[^\]\\]*\\?\]', ''); $n.Substring(0, [math]::Min(60, $n.Length)) }   # trackers re-render markdown: letters and digits only
$script:KitMrsHeading = 'MRs (merge order)'   # the retired MRs comment: never written (MR links: the Items checklist)
function ConvertTo-KitLetters([string]$Text) { ("$Text" -replace '[^\p{L}\p{N}]', '').ToLower() }
function Test-KitHeadText([string]$Text, [string]$Heading) { (ConvertTo-KitLetters (("$Text".Trim() -split "`r?`n")[0])) -eq (ConvertTo-KitLetters $Heading) }
function Get-TrackerHeadComments([string]$Id, [string]$Heading, [scriptblock]$Match) { @(Get-TrackerComments $Id | Where-Object { $_.id -and (Test-KitHeadText $_.text $Heading) -and (-not $Match -or (& $Match $_)) }) }
# -Heading: found by heading, not this kit copy's index (agents run from several copies), under a machine-wide lock
function Set-TrackerKitComment([string]$Id, [string]$Kind, $Text, [string]$Heading, [scriptblock]$Match) {
  if ($Heading) { return Invoke-KitLocked (Join-Path (Get-KitTemp) "claude-kit-comment-$("$Id-$Kind" -replace '[^\w.-]', '_')") { Set-TrackerHeadComment $Id $Kind $Text $Heading $Match } }
  $body = (__TrText "$Text").TrimEnd(); $ad = $KitAdapters['tracker'][$__trType]; $edit = $ad -and $ad.ContainsKey('comment-edit'); $sig = Get-KitCommentSig $body
  $keep = { param($cid) try { Update-KitTaskIndex $Id { param($x) if ($cid) { $x.comments[$Kind] = "$cid"; $x.comments.Remove("$Kind#text") } else { $x.comments["$Kind#text"] = $sig } } } catch { } }
  $ix = (Read-KitState (Get-KitTaskFile $Id)).comments; if ($ix -isnot [Collections.IDictionary]) { $ix = @{} }; $known = "$($ix.$Kind)"; $last = "$($ix["$Kind#text"])"
  if ($known -and $edit) { try { Clear-TrackerMemo $Id; return __TrA 'comment-edit' @{ id = $Id; comment = $known; text = $body } } catch { Write-KitLog calls comment-index-stale @{ task = $Id; kind = $Kind; error = "$_" } } }
  $old = @(try { Get-TrackerComments $Id } catch { @() }) | Where-Object { $_.id -and ("$($_.text)" -match ('\\?\[kit:' + [regex]::Escape($Kind) + '\\?\]\s*$') -or ($last -and (Get-KitCommentSig $_.text) -eq $last)) } | Select-Object -Last 1
  if ($old -and $edit) { Clear-TrackerMemo $Id; $r = __TrA 'comment-edit' @{ id = $Id; comment = $old.id; text = $body }; & $keep $old.id; return $r }
  $r = Add-TrackerComment $Id $body; $cid = $r.id
  if (-not $cid -and "$r" -notmatch '^QUEUED') { $cid = (@(try { Get-TrackerComments $Id } catch { @() }) | Where-Object { $_.id -and (Get-KitCommentSig $_.text) -eq $sig } | Select-Object -Last 1).id }   # adapters that print no id
  & $keep $cid
  if ($old -and $ad -and $ad.ContainsKey('comment-delete') -and "$r" -notmatch '^QUEUED') { try { $null = __TrA 'comment-delete' @{ id = $Id; comment = $old.id } } catch { Write-Warning "tracker ($__trType): superseded comment $($old.id) not deleted: $_" } }
  $r
}
# $Text may be a scriptblock run under the lock, so a writer never drops another's MRs
function Set-TrackerHeadComment([string]$Id, [string]$Kind, $Text, [string]$Heading, [scriptblock]$Match) {
  if ($Text -is [scriptblock]) { $Text = & $Text }; if (-not "$Text".Trim()) { return }
  $body = (__TrText "$Text").TrimEnd(); $ad = $KitAdapters['tracker'][$__trType]; if (-not $ad) { throw "tracker: no adapter for type '$__trType'" }
  $all = @(Get-TrackerHeadComments $Id $Heading $Match)   # a failed read throws: a duplicate is worse than a late one
  $first = $all | Select-Object -First 1; $extra = @($all | Select-Object -Skip 1)
  if ($first -and $ad.ContainsKey('comment-edit')) { Clear-TrackerMemo $Id; $r = __TrA 'comment-edit' @{ id = $Id; comment = $first.id; text = $body }; $cid = $first.id }
  elseif ($all.Count -and -not $ad.ContainsKey('comment-delete') -and (ConvertTo-KitLetters $all[-1].text) -eq (ConvertTo-KitLetters (ConvertTo-KitPlainText $body))) { return }   # no edit, no delete: post only on a change
  else {
    $r = Add-TrackerComment $Id $body; if ("$r" -match '^QUEUED') { return $r }
    $cid = (@(Get-TrackerHeadComments $Id $Heading $Match) | Where-Object { @($all.id) -notcontains $_.id } | Select-Object -Last 1).id; $extra = $all
  }
  if ($extra.Count -and -not $ad.ContainsKey('comment-delete')) { Write-Warning "tracker ($__trType): earlier '$Heading' comment(s) $($extra.id -join ', ') on $Id (the adapter cannot delete): remove by hand" }
  elseif ($extra.Count) { foreach ($x in $extra) { try { $null = __TrA 'comment-delete' @{ id = $Id; comment = $x.id } } catch { Write-Warning "tracker ($__trType): duplicate '$Heading' comment $($x.id) on $Id not deleted: $_" } } }
  try { Update-KitTaskIndex $Id { param($ix) if ($cid) { $ix.comments[$Kind] = "$cid" } } } catch { }
  $r
}

$script:__trOwner = $null
function Get-TrackerOwner {
  if ($null -ne $script:__trOwner) { return $script:__trOwner }
  $o = [string](Get-KitSetting 'tracker.owner' '')
  if (-not $o -and -not $__trDry) {
    $name = __TrOsFullName
    try { $o = __TrA 'owner' @{ name = $name } } catch { Write-Warning "tracker: could not resolve the task owner '$name' ($($_.Exception.Message)); new tasks stay unassigned" }
  }
  $script:__trOwner = ([string]$o).Trim(); $script:__trOwner
}
# missing labels of a task text (templates.md task-description; -Subtask: Items too); a [Bug] keeps its own shape
function Get-KitTaskTextGaps([string]$Name, [string]$Text, [switch]$Subtask) {
  if (-not "$Text".Trim()) { return @('a description') }; if ($Name -match '^\W*Bug\]' -or "$Name".TrimStart().StartsWith([string](Get-KitSetting 'tracker.bugPrefix' '[Bug]'), 'OrdinalIgnoreCase')) { return @() }
  @(foreach ($lb in @('Problem', 'Goal') + @(if ($Subtask) { 'Items|Bugs' }) + @('Acceptance', 'Links')) { if ($Text -notmatch "(?im)^(?:\s*\d+[.)])?\W{0,6}(?:$lb)\b(?:\s+\w+){0,2}(?:\s*\([^)\r\n]*\))?\W{0,3}(?::|\s+[-–—]|\s*$)") { ($lb -split '\|')[0] } })
}
# -NewTask '<why>' skips the duplicate check (logged); -Related: tasks the owner named this session
function New-TrackerTask([string]$List, [string]$Name, [string]$Description, [string]$Parent, [string]$Assignee, [string]$Priority, [string]$NewTask, [string[]]$Related) {
  $sub = $Parent -and $Parent -ne '-'; $gap = @(if ($sub) { Get-KitTaskTextGaps $Name $Description -Subtask })   # no bare subtasks (owner, 2026-11-11)
  if ($gap.Count) { throw "tracker create refused: subtask '$Name' of $Parent lacks $($gap -join ', ') (templates.md task-description): crafty.ps1 tracker create -Spec <json> (crafty.ps1 ""task spec"")" }
  if (-not $List) { $List = [string](Get-KitSetting 'tracker.list' '') }
  # under -Parent the check sees only siblings: the reason acks them (matched [] = no supervise WATCH)
  if ($NewTask) { Write-KitLog calls prior-override (@{ what = "task $Name"; reason = $NewTask } + $(if ($sub) { @{ matched = @(); parent = $Parent } } else { @{} })) }
  else {
    $dup = try { @(Find-KitSimilarTasks $Name $List $Parent $Related) } catch { throw "tracker create: UNKNOWN: the duplicate check failed ($_): retry, or -NewTask '<why it differs>'" }
    if ($dup.Count) { Write-KitLog calls prior-refused @{ what = "task $Name"; found = $dup[0].id }
      throw "tracker create refused: possible duplicate of $($dup[0].id) $($dup[0].name) (score $($dup[0].score)): extend it (crafty.ps1 tracker scope -Task $($dup[0].id) -Add '<item>'), or -NewTask '<why it cannot be folded in>'" }
  }
  if (-not $Assignee) { $Assignee = Get-TrackerOwner }   # assignee: the kit runner unless '-' (nobody)
  __TrA 'create' @{ list = $List; name = $Name; description = (__TrText $Description); parent = $(if ($Parent -and $Parent -ne '-') { $Parent }); assignee = $(if ($Assignee -and $Assignee -ne '-') { $Assignee }); priority = $Priority }
}
function Set-TrackerDescription([string]$Id, [string]$Text) { Clear-TrackerMemo $Id; __TrA 'describe' @{ id = $Id; text = (__TrText $Text) } }
# the owner's text stays: only <!-- kit:<name> --> ... <!-- /kit:<name> --> is replaced; new: after section $After, else under the testing-doc links
function Set-KitDescSection([string]$Desc, [string]$Name, [string]$Body, [string]$After) {
  $s = "<!-- kit:$Name -->"; $e = "<!-- /kit:$Name -->"; $block = "$s`n$Body`n$e"; $d = "$Desc" -replace "`r`n", "`n"
  $i = $d.IndexOf($s); $j = if ($i -ge 0) { $d.IndexOf($e, $i) } else { -1 }
  if ($i -ge 0 -and $j -gt $i) { return $d.Substring(0, $i) + $block + $d.Substring($j + $e.Length) }
  $ae = "<!-- /kit:$After -->"; $k = if ($After) { $d.IndexOf($ae) } else { -1 }
  if ($k -ge 0) { $p = $k + $ae.Length; return $d.Substring(0, $p) + "`n`n$block" + $d.Substring($p) }
  $lines = @($d -split "`n"); $last = 0
  for ($x = 0; $x -lt $lines.Count; $x++) { if ($lines[$x] -match '(?i)^\W{0,3}Testing doc \(') { $last = $x + 1 } elseif ($lines[$x].Trim()) { break } }
  (@((@($lines | Select-Object -First $last) -join "`n").Trim(), $block, (@($lines | Select-Object -Skip $last) -join "`n").Trim()) | Where-Object { $_ }) -join "`n`n"
}
# a named checklist on a task ({ text; done }; items keyed by the text before the first ' · '): adapter verb checklist, else a <!-- kit:<name> --> description section
function Set-KitTaskChecklist([string]$Task, [string]$Name, $Items) {
  $ad = $KitAdapters['tracker'][$__trType]
  if ($ad -and $ad.ContainsKey('checklist')) { return __TrA 'checklist' @{ id = $Task; name = $Name; items = @($Items | ForEach-Object { @{ text = $_.text; done = [bool]$_.done } }) } }
  Clear-TrackerMemo $Task; $tk = Get-TrackerTask $Task; if (-not $tk.name) { throw "tracker read of $Task failed" }
  $nd = Set-KitDescSection $tk.description $Name.ToLower() ((@("**$Name**") + @($Items | ForEach-Object { "- [$(if ($_.done) { 'x' } else { ' ' })] $($_.text)" })) -join "`n") ''
  if ($nd -ne ("$($tk.description)" -replace "`r`n", "`n")) { Set-TrackerDescription $Task $nd }
}
# checklist item "<id> · <plain words> · <URLs>" (links and a status suffix out of the words); task specs: crafty.ps1 "task spec"
function Format-KitCell([string]$Text) { ("$Text" -replace '\s+', ' ' -replace '\|', '/').Trim() }   # one line, never cut (Writing standards: text wraps, never truncates)
function Format-KitItemText([string]$Id, [string]$Desc, $Urls) {
  $Desc = $Desc -replace '`' -replace '\[([^\]]*)\]\([^)]*\)', '$1' -replace 'https?://\S+' -replace '(?<![\w-])[\w./-]+!\d+' -replace '(?i)(?:\s+[–—-]\s*|\s*\()(?:merged|done|deployed|closed)\)?\s*$' -replace '[\s·,;:–—-]+$'
  (@($Id, (Format-KitCell $Desc), (@($Urls | Where-Object { $_ } | Select-Object -Unique) -join ' ')) | Where-Object { $_ }) -join ' · ' }
function ConvertTo-KitSpecItems($Spec) { @($Spec.items | Where-Object { $_.code } | ForEach-Object { [pscustomobject]@{ text = (Format-KitItemText "$($_.code)" "$($_.desc)" @($_.mrs)); done = [bool]$_.done } }) }
# a parent's Items: its spec items + one per subtask "<code> · <name without [Kind]> · <URL>", ticked once closed; code: the
# subtask's spec, the parent spec's subtasks[{ id, code }], $CodeOf (rollup areas), else its id
function Update-KitParentItems([string]$Parent, $Pt, [hashtable]$CodeOf = @{}) {
  if (-not $Pt) { Clear-TrackerMemo $Parent; $Pt = Get-TrackerTask $Parent }; $subs = @($Pt.subtasks | Where-Object { $_.id }); if (-not $subs.Count) { return }
  $px = Read-KitState (Get-KitTaskFile $Parent); $items = @(ConvertTo-KitSpecItems $px.spec) + @(foreach ($s in $subs) { $sc = (Read-KitState (Get-KitTaskFile $s.id)).spec.code
      if (-not $sc) { $sc = @($px.spec.subtasks | Where-Object { "$($_.id)" -eq "$($s.id)" } | ForEach-Object code)[0] }
      [pscustomobject]@{ text = (Format-KitItemText $(if ($sc) { "$sc" } elseif ($CodeOf[$s.id]) { "$($CodeOf[$s.id])" } else { "$($s.id)" }) ("$($s.name)" -replace '^\s*\[[^\]]*\]\s*') @($s.url)); done = [bool](Test-TrackerStatus "$($s.status)" 'closed') } })
  $sig = ConvertTo-KitLetters (@($items | ForEach-Object { "$($_.text)|$($_.done)" }) -join ';'); if ($sig -eq "$($px.parentItemsSig)") { return }
  $null = Set-KitTaskChecklist $Parent 'Items' $items; Update-KitTaskIndex $Parent { param($x) $x.parentItemsSig = $sig; $x.itemsFrom = 'subtasks' }
  "parent items ${Parent}: $(@($items | Where-Object done).Count)/$($items.Count) done"
}
function Set-TrackerName([string]$Id, [string]$Name) { Clear-TrackerMemo $Id; __TrA 'rename' @{ id = $Id; name = $Name } }
function Add-TrackerAttachment([string]$Id, [string]$File, [string]$Text) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "tracker: no such file $File" }
  __TrA 'attach' @{ id = $Id; file = $File; text = $Text; leaf = (Split-Path $File -Leaf) }
}
function Get-TrackerTasks([string]$List, [string]$Status) {
  if (-not $List) { $List = [string]$(if ($__trType -in 'github', 'gitlab') { $__trRepo } else { Get-KitSetting 'tracker.list' '' }) }
  # every tracker.statuses name of the logical status (lists differ: "in test" / "for test")
  $names = @(foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $Status) { @($__trStatus[$k]) } }); if (-not $names.Count) { $names = @($Status) }
  $seen = @{}; $err = $null; $ok = 0
  foreach ($n in $names) {
    try { foreach ($t in @(__TrA 'list' @{ list = $List; status = $n; logical = $Status })) { $tk = if ($t.id) { [string]$t.id } else { [guid]::NewGuid() }; if ($t -and -not $seen[$tk]) { $seen[$tk] = 1; $t } }; $ok++ }
    catch { if (-not $err) { $err = $_ }; Write-Warning "tracker list $List '$n' failed: $_" }   # a name the list lacks may throw
  }
  if (-not $ok -and $err) { throw $err }
}
# ---- prior: check before creating (owner rule: reuse an existing task, branch, MR or doc, or extend its scope)
# a title's key words (tags, ids, filler dropped)
function Get-KitTitleWords([string]$Text) {
  $stop = 'the', 'and', 'for', 'with', 'from', 'into', 'when', 'that', 'this', 'not', 'are', 'was', 'has', 'have', 'its', 'all', 'can', 'via', 'per', 'but', 'more'
  @(([regex]::Replace("$Text".ToLower(), '\[[^\]]*\]|\S*\d\S*', ' ') -split '[^a-z]+') | Where-Object { $_.Length -ge 3 -and $_ -notin $stop } | Select-Object -Unique)
}
# score = shared key words (2+) / the shorter title's, over tracker.duplicateScore
function Find-KitSimilarTasks([string]$Name, [string]$List, [string]$Parent, [string[]]$Related, [string[]]$Skip = @()) {
  $mine = @(Get-KitTitleWords $Name); if (-not $mine.Count) { return }
  $c = @{}; if (-not $Parent -or $Parent -eq '-') { foreach ($st in @($__trStatus.Keys | Where-Object { $_ -ne 'closed' })) { foreach ($x in @(Get-TrackerTasks $List $st)) { $c["$($x.id)"] = $x } } }
  foreach ($id in @(@($Parent) + @($Related) | Where-Object { $_ -and $_ -ne '-' })) { $v = Get-TrackerTask $id; if ($id -ne $Parent -and $v.name) { $c[$id] = $v }; foreach ($s in @($v.subtasks)) { if (-not (Test-TrackerStatus "$($s.status)" 'closed')) { $c["$($s.id)"] = $s } } }
  $min = [double](Get-KitParam 'tracker.duplicateScore')
  @(foreach ($x in $c.Values) { if ("$($x.id)" -in $Skip -or "$($x.id)" -eq $Parent) { continue }
      $w = @(Get-KitTitleWords $x.name); $n = @($w | Where-Object { $_ -in $mine }).Count; $lo = [math]::Max(2, [math]::Min($w.Count, $mine.Count))
      if ($n -ge 2 -and $n / $lo -ge $min) { [pscustomobject]@{ id = "$($x.id)"; name = $x.name; score = [math]::Round($n / $lo, 2) } } }) | Sort-Object score -Descending
}
# ---- ask bugs: ONE open QA collector [Bug] per ask across agents; each source owns a "[kit:bug:<key>]" section; known signatures = duplicates
function ConvertTo-KitBugNorm([string]$Text) { ((("$Text" -replace '\\(.)', '$1') -replace '/\d+(?=/|\b)', '/{id}') -replace '\s+', ' ').ToLower().Trim() }
# a whole signature in a text (vector.py:120 is not in vector.py:1205)
function Test-KitBugSig([string]$Hay, [string]$Sig) { $q = ConvertTo-KitBugNorm $Sig; $q.Length -ge 6 -and $Hay -match "(?<![\w.:-])$([regex]::Escape($q))(?![\w/:-])" }
# .signature, else file:line (not host:port) and URLs with a path (hash routes kept) in observed / cause
function Get-KitDefectSigs($Check) {
  if ($Check.signature) { return @(@($Check.signature) | ForEach-Object { "$_".Trim() } | Where-Object { $_.Length -ge 6 }) }
  $t = "$($Check.observed) $($Check.cause)"
  $fl = [regex]::Matches($t, '(?<![\w./\\:-])[\w./\\-]+\.(?<x>[A-Za-z]\w{0,4}):\d+(?![\w/])') | Where-Object { $_.Groups['x'].Value -notmatch '^(com|org|net|io|dev|app|co|uk|eu|local|internal|cloud|ai)$' }
  $url = [regex]::Matches($t, 'https?://[^/\s]+/[^\s)\]>"''`]+') | ForEach-Object { $_.Value -replace '\?[^#]*' -replace '#(?!/).*$' -replace '[.,;:]+$' } | Where-Object { $_ -notmatch '^https?://[^/]+/?$' }
  @(@(@($fl | ForEach-Object Value) + @($url)) | Select-Object -Unique)
}
# a QA collector [Bug]: text opens with a kit:bug marker or title says "— new defects (n)"; a hand-made [Bug] takes no sections
function Test-KitBugCollector($Task) { "$($Task.name)" -match '[—-]\s*new defects(\s*\(\d+\))?(:|\s*$)' -or "$($Task.description)".TrimStart() -match '^[^\r\n]*\\?\[kit:bug:[^\]\r\n]+?\\?\][ \t]*(\r?\n|$)' }
# $Defects: [{ label; sig = @(); md; group }]; -Id: the [Bug] this source wrote before; -Mine: its whole unmarked text is this source's
function Add-KitAskBug([string]$Ask, [string]$Key, [string]$Name, [string]$Head, [object[]]$Defects, [string]$List, [string]$Assignee, [string]$Priority = '2', [string]$Id, [switch]$Mine) {
  $Key = ("$Key" -replace '[^\w.-]+', '_').Trim('_'); if (-not $Key) { throw 'Add-KitAskBug: -Key (the section key) is required' }
  if ($Key.Length -gt 80) { $Key = $Key.Substring(0, 70) + '-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Key))).Substring(0, 8) }
  Invoke-KitLocked (Join-Path (Get-KitTemp) "claude-kit-bug-$("$(if ($Ask) { $Ask } else { $Key })" -replace '[^\w.-]', '_')") {
    $open = { param($i) if (-not $i) { return }; Clear-TrackerMemo $i; $v = Get-TrackerTask $i; if ($v.name -and -not (Test-TrackerStatus "$($v.status)" 'closed')) { $v } }
    $pre = [string](Get-KitSetting 'tracker.bugPrefix' '[Bug]')
    $put = { param($bug)
      $text = "$($bug.description)".TrimEnd()   # markers read back markdown-escaped too ("\[kit:bug:a\_b\]")
      $ms = @([regex]::Matches($text, '(?m)^[^\r\n]*\\?\[kit:bug:(?<k>[^\]\r\n]+?)\\?\][ \t]*\r?$'))
      $lead = if ($ms.Count) { $text.Substring(0, $ms[0].Index).TrimEnd() } elseif ($Mine -and $bug.id -eq $Id) { '' } else { $text }
      $secs = [ordered]@{}; for ($j = 0; $j -lt $ms.Count; $j++) { $end = if ($j + 1 -lt $ms.Count) { $ms[$j + 1].Index } else { $text.Length }; $secs[($ms[$j].Groups['k'].Value -replace '\\')] = $text.Substring($ms[$j].Index, $end - $ms[$j].Index).TrimEnd() }
      $hay = ConvertTo-KitBugNorm ((@($lead) + @($secs.Keys | Where-Object { $_ -ne $Key } | ForEach-Object { $secs[$_] })) -join "`n")
      $new = @(); $dup = @()
      foreach ($d in @($Defects | Where-Object { $_ })) {
        $hit = @($d.sig | Where-Object { Test-KitBugSig $hay $_ }) | Select-Object -First 1
        if ($hit) { $dup += "$($d.label) (``$hit``)" } else { $new += $d } }
      $lines = @("Source: $Key [kit:bug:$Key]") + @($Head | Where-Object { $_ } | ForEach-Object { $_.TrimEnd() })
      foreach ($g in @($new | ForEach-Object { "$($_.group)" } | Select-Object -Unique)) { if ($g) { $lines += "## $g" }; $lines += @($new | Where-Object { "$($_.group)" -eq $g } | ForEach-Object { "$($_.md)".TrimEnd() }) }
      if ($dup.Count) { $lines += "**Duplicates** (already in this task, not added again): $($dup -join '; ')" }
      $sec = $lines -join "`n`n"
      if (-not $bug.id) { return [pscustomobject]@{ section = $sec; duplicates = $dup } }
      $secs[$Key] = $sec; $null = Set-TrackerDescription $bug.id ((@($lead | Where-Object { $_ }) + @($secs.Values)) -join "`n`n")
      [pscustomobject]@{ id = $bug.id; url = (Get-TrackerUrl $bug.id); action = $(if ($Id -and $bug.id -eq $Id) { 'updated' } else { 'appended' }); duplicates = $dup }
    }
    $bug = & $open $Id; if ($bug -and -not ($Mine -or (Test-KitBugCollector $bug))) { $bug = $null }   # a hand-made [Bug] adopted before
    if (-not $bug -and $Ask -and $Ask -ne '-') { Clear-TrackerMemo $Ask
      $bug = @(foreach ($sb in @((Get-TrackerTask $Ask).subtasks | Where-Object { "$($_.name)".StartsWith($pre) -and -not (Test-TrackerStatus "$($_.status)" 'closed') })) { if (($v = & $open $sb.id) -and (Test-KitBugCollector $v)) { $v; break } }) | Select-Object -First 1 }
    if ($bug) { return & $put $bug }
    $s0 = & $put ([pscustomobject]@{ id = $null; description = '' })
    $t = try { New-TrackerTask -List $List -Name $Name -Description $s0.section -Parent $Ask -Assignee $Assignee -Priority $Priority } catch {   # owner rule: grow a related open task
      if ("$_" -match 'UNKNOWN: the duplicate check failed') { New-TrackerTask -List $List -Name $Name -Description $s0.section -Parent $Ask -Assignee $Assignee -Priority $Priority -NewTask 'ask bug: duplicate check unavailable' }
      elseif ("$_" -match 'possible duplicate of (\S+)') { $rid = $Matches[1]; if (($b2 = & $open $rid) -and (Test-KitBugCollector $b2)) { return & $put $b2 }
        New-TrackerTask -List $List -Name $Name -Description $s0.section -Parent $Ask -Assignee $Assignee -Priority $Priority -NewTask "ask bug: the related task $rid is closed or not a QA collector" } else { throw } }
    if ($t.id) { [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }); action = 'created'; duplicates = @() } }
  }
}
# gate before work (wt new, devtools.py mr / finish / doc): -Override is logged
function Assert-KitPrior([string]$Task, [string]$Repo, [string]$What, [string]$Override, [string]$Reuse) {
  if (-not $Task) { return }
  $p = (Read-KitState (Get-KitTaskFile $Task)).prior
  $fresh = $p.at -and ((Get-Date) - [datetime]$p.at).TotalHours -lt [double](Get-KitParam 'prior.validHours')
  if (-not $fresh -and -not $Override) { throw "$What refused: run crafty.ps1 prior -Task $Task first (check before create)" }
  $found = @($p.found | Where-Object { $_ -and $_.kind -notin '', 'doc', 'qa' -and -not ($Reuse -and (($_.kind -eq 'branch' -and ("$($_.ref)" -replace '^origin/') -eq $Reuse) -or @($_.branches) -contains $Reuse)) })   # -Reuse: that branch is this work
  $hit = @($found | Where-Object { $_.kind -eq 'task' -or -not $_.repo -or -not $Repo -or ($_.repo -split '[\\/]')[-1] -eq ($Repo -split '[\\/]')[-1] })   # no -Repo (guard, repo unknown): every hit stops
  if ($Override) { $lf = @{ task = $Task; what = $What; reason = $Override }; if ($fresh) { $lf.matched = @($hit | ForEach-Object { [ordered]@{ kind = $_.kind; ref = $_.ref; tagged = [bool]$_.tagged } }) }; Write-KitLog calls prior-override $lf; return }   # supervise flags only other tasks' matches
  foreach ($pf in @($found | Where-Object { $_.tagged -and $_ -notin $hit })) { [Console]::Error.WriteLine("INFO ${What}: paired $($pf.kind) $($pf.ref) (task $Task, another repo)") }   # same task, another repo: never a stop
  if ($hit.Count) { Write-KitLog calls prior-refused @{ task = $Task; what = $What; found = "$($hit[0].kind) $($hit[0].ref)" }
    throw "$What refused: already exists: $(@($hit | ForEach-Object { "$($_.kind) $($_.ref) $($_.title)" }) -join '; '): reuse it (a task: extend it with crafty.ps1 tracker scope -Task <id> -Add '<item>'), or -Override '<reason>'" }
}

# failed checks in pokey.ps1 Format-Checks texts; env-data untested checks (not a code bug) skipped
function Get-KitFailedChecks([string[]]$Texts) {
  $seen = @{}
  foreach ($tx in $Texts) {
    $cur = $null; $sect = ''
    foreach ($line in @("$tx" -split '\r?\n') + '## end') {
      if ($line -match '^##\s+[^#]|^###\s+\S+\s+[—-]\s+') {
        if ($cur -and -not $seen[$cur.id] -and -not ($sect -match '^##\s+Untested' -and $cur.nt) -and $cur.screen -notmatch '\((PASS|NOT TESTED|PENDING|OUT OF SCOPE)\b.*\)$') { $seen[$cur.id] = 1; $cur.Remove('nt'); $cur }
        $cur = $null; if ($line -match '^###\s+(?<id>\S+)\s+[—-]\s+(?<screen>.+)$') { $cur = [ordered]@{ id = $Matches.id; screen = $Matches.screen.Trim(); saw = '' } } else { $sect = $line }
      } elseif ($cur -and $line -match '^\*\*Saw:\*\*\s*(?<s>.+)$') { $s = ($Matches.s -split '\| Independent re-test')[0].Trim(); $cur.nt = $s -match '\(cause: env-data\)'; $cur.saw = if ($s.Length -gt 500) { $s.Substring(0, 497) + '...' } else { $s } }
    }
  }
}
# a web link as [text](url)
function Format-KitMdLink([string]$Url, [string]$Text = 'open') { if ($Url -match '^https?://\S+$') { "[$Text]($Url)" } else { $Url } }
# for tracker fields that show text as typed
function ConvertTo-KitPlainText([string]$Text) {
  $t = [regex]::Replace($Text, '\[([^\]\n]+)\]\((https?://[^)\s]+)\)', { if ($args[0].Groups[1].Value -eq $args[0].Groups[2].Value) { $args[0].Groups[2].Value } else { "$($args[0].Groups[1].Value) ($($args[0].Groups[2].Value))" } })
  [regex]::Replace(($t -replace '\*\*([^*\n]+)\*\*', '$1'), '`([^`\n]+)`', '$1')
}
# Markdown -> blocks for trackers storing rich text (ADF, wiki, HTML): table (only with a |---| rule), item, para
function ConvertFrom-KitMarkdown([string]$Text) {
  $mdLines = @(("$Text" -replace "`r", '') -split "`n")
  for ($i = 0; $i -lt $mdLines.Count; $i++) {
    $t = $mdLines[$i].Trim(); if (-not $t) { continue }
    if ($t -match '^\|.*\|$' -and $i + 1 -lt $mdLines.Count -and $mdLines[$i + 1].Trim() -match '^\|(\s*:?-+:?\s*\|)+$') {
      $tblRows = [Collections.Generic.List[object]]::new()
      for ($j = $i; $j -lt $mdLines.Count -and $mdLines[$j].Trim() -match '^\|.*\|$'; $j++) {
        if ($j -eq $i + 1) { continue }; $r = $mdLines[$j].Trim()
        $tblRows.Add(@($r.Substring(1, $r.Length - 2) -split '(?<!\\)\|' | ForEach-Object { ($_ -replace '\\\|', '|').Trim() }))
      }
      [pscustomobject]@{ type = 'table'; rows = $tblRows.ToArray() }; $i = $j - 1; continue
    }
    if ($t -match '^[-*+]\s+(?<s>.*)$') { [pscustomobject]@{ type = 'item'; text = $Matches.s }; continue }
    [pscustomobject]@{ type = 'para'; text = $t }
  }
}
# inline Markdown -> runs (mark: '' / bold / code / link with url / br), adjacent plain text joined
function ConvertFrom-KitMdInline([string]$Text) {
  $runs = [Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches("$Text", '\*\*(?<b>[^*\n]+)\*\*|`(?<c>[^`\n]+)`|\[(?<lt>[^\]\n]+)\]\((?<lu>https?://[^)\s]+)\)|(?<br><br\s*/?>)|(?<t>[^*`\[<]+|.)')) {
    $g = $m.Groups
    $run = if ($g['b'].Success) { @{ text = $g['b'].Value; mark = 'bold' } } elseif ($g['c'].Success) { @{ text = $g['c'].Value; mark = 'code' } }
    elseif ($g['lt'].Success) { @{ text = $g['lt'].Value; mark = 'link'; url = $g['lu'].Value } } elseif ($g['br'].Success) { @{ text = ''; mark = 'br' } } else { @{ text = $m.Value; mark = '' } }
    if (-not $run.mark -and $runs.Count -and -not $runs[-1].mark) { $runs[-1].text += $run.text } else { $runs.Add($run) }
  }
  $runs.ToArray()
}
# rows: , @(cells)
function Format-KitMdTable([string[]]$Head, $Rows) {
  "| $($Head -join ' | ') |"; "|$('---|' * $Head.Count)"
  foreach ($r in @($Rows)) { "| $(@($r | ForEach-Object { $s = ("$_" -replace '[\r\n]+', ' ' -replace '\|', '\|').Trim(); if ($s) { $s } else { '—' } }) -join ' | ') |" }
}
# "A: <label> — <trade-off>" -> the native question tools' shape
function Get-KitDecisionChoices([string[]]$Options, [string]$Recommend) {
  foreach ($o in $Options) {
    $k, $t = if ($o -match '^\s*(\w+)\s*[:)]\s*(.*)$') { $Matches[1], $Matches[2] } else { '', $o }
    $l, $d = "$t" -split '\s+[—–]\s+', 2
    [pscustomobject]@{ key = $k; label = "$l".Trim(); description = "$d".Trim(); recommended = [bool]($k -and $Recommend -match "^\s*$k\b") }
  }
}
# a decision's choices, recommended first (a v1 record holds "A: ..." strings)
function Get-KitDecisionOrder($d) {
  $ch = @(foreach ($o in @($d.options)) { if ($o -is [string]) { Get-KitDecisionChoices $o $d.recommend } else { $o } })
  @($ch | Where-Object recommended) + @($ch | Where-Object { -not $_.recommended })
}
# contracts note, and the fallback for a CLI with no question tool
function Format-KitDecision($d) {
  $mr = @($d.mrs | Where-Object { $_ })
  "## DECISION NEEDED $($d.id) ($($d.agent), item $($d.item))$(if ($d.task) { " [Task: $($d.task)]" })$(if ($mr.Count) { " [MRs: $($mr -join ', ')]" })"
  "**Question:** $($d.question)"; "**Blocking:** $(if ($d.blocking -eq $false) { 'no (FYI): the item goes on' } else { "yes: item $($d.item) waits" })"; ''
  Format-KitMdTable 'Option', 'Choice', 'Trade-off' @(foreach ($c in Get-KitDecisionOrder $d) { , @("$($c.key)$(if ($c.recommended) { ' (recommended)' })", $c.label, $c.description) })
  ''; "**Recommended:** $(if ($d.recommend) { $d.recommend } else { 'none' })"; '**Answer:** pending (the coordinator appends it below)'
}
# numbered so the owner answers "1 A, 2 B"
function Format-KitFyiList($Decisions) {
  $n = 0; foreach ($d in @($Decisions)) { $n++; "$n. $($d.question) (``$($d.id)``): $(@(Get-KitDecisionOrder $d | ForEach-Object { "$($_.key) $($_.label)$(if ($_.recommended) { ' (recommended)' })" }) -join ' · ')" }
}
# one task's decisions: the last publish (kept after the log trim), the log, live records (newest state wins)
function Get-KitTaskDecisionRows([string]$Task) {
  $rows = [ordered]@{}; $files = @(Read-KitJsonFiles (Get-KitPath decisions))
  foreach ($r in @((Read-KitState (Get-KitTaskFile $Task)).decisions.rows)) { if ($r.id) { $rows["$($r.id)"] = $r } }
  foreach ($d in @(Read-KitLog decisions-log ([datetime]'2000-01-01')) + $files) {
    if (-not ($d.id -and $d.question) -or $d.kind -eq 'envfix' -or ("$($d.task)" -ne $Task -and "$($d.item)" -ne $Task)) { continue }
    $at = if ($d.answeredAt) { $d.answeredAt } else { $d.at }; if ($at -is [datetime]) { $at = $at.ToString('o') }   # JSON gives a DateTime: "$x" drops the fraction and offset
    $rows["$($d.id)"] = [ordered]@{ id = "$($d.id)"; at = "$at"; question = "$($d.question)"; answer = "$($d.answer)"
      by = "$($d.by)"; status = "$($d.status)"; supersedes = @($d.supersedes | Where-Object { $_ }) }
  }
  $live = @($files.id)   # a pending row whose record expired unanswered is no open question
  @($rows.Values | Where-Object { $_.status -ne 'pending' -or "$($_.id)" -in $live } | Sort-Object { Get-KitUtcTicks $_.at })
}
function Get-KitUtcTicks($At) { try { ([datetimeoffset]"$At").UtcTicks } catch { 0 } }
# templates.md decisions: the task's Decisions checklist, one item per decision "<short id> · <question> → <answer> · <by> <MM-dd>" (resolved),
# a pending ask unresolved, an OLDER answer the same question, -Supersedes or "supersedes d-<id>" replaced -> "superseded by <id>"
function Format-KitDecisionItems($Rows, [string]$Link, [string]$Task) {
  $ans = @($Rows | Where-Object { $_.status -eq 'answered' -and $_.answer }); $sup = @{}; $tk = @{}; foreach ($r in $ans) { $tk["$($r.id)"] = Get-KitUtcTicks $r.at }
  foreach ($r in $ans) {
    $ids = @($r.supersedes) + @([regex]::Matches("$($r.answer)", '(?i)\bsupersedes\s+(d-\d{14}-[\w-]+)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($o in $ans) { if ($tk["$($o.id)"] -lt $tk["$($r.id)"] -and ("$($o.id)" -in $ids -or (ConvertTo-KitLetters $o.question) -eq (ConvertTo-KitLetters $r.question))) { $sup["$($o.id)"] = $r.id } }
  }
  $dup = @($Rows | Group-Object { ("$($_.id)" -split '-')[-1] } | Where-Object Count -gt 1 | ForEach-Object Name)
  $sid = { param($i) $p = "$i" -split '-'; if ($p[-1] -in $dup) { $p[-2..-1] -join '-' } else { $p[-1] } }   # the checklist keys items by it: a clash takes the agent part too
  $day = { param($r) try { ([datetimeoffset]"$($r.at)").ToString('MM-dd') } catch { '' } }
  $q = { param($r) $t = ("$($r.question)" -replace "\s*\($([regex]::Escape($Task))\)", '').Trim(); if ($t -match '^(.{4,}?\?)(\s|$)') { $t = $Matches[1] }; if ($t.Length -gt 80) { $t = ($t.Substring(0, 79) -replace '\s+\S*$', '') + '…' }; $t }
  $a = { param($r) ("$($r.answer)" -replace '\s*\([\w ]+,? \d{4}-\d\d-\d\d(?: \d\d:\d\d)?\)', '' -replace '\([\w ]+,? \d{4}-\d\d-\d\d(?: \d\d:\d\d)?;\s*', '(').Trim() }   # "(owner, <date>)": the item says both
  foreach ($r in @($Rows | Where-Object { $_.status -eq 'pending' -or ($_.status -eq 'answered' -and $_.answer) })) {
    $f = $sup["$($r.id)"]; $hop = 0; while ($sup.ContainsKey("$f") -and $hop++ -lt 20) { $f = $sup["$f"] }
    $tail = if ($r.status -eq 'pending') { "open · asked $(& $day $r)" } elseif ($f) { "superseded by $(& $sid $f)" } else { "$(& $a $r) · $(if ($r.by) { $r.by } else { 'owner' }) $(& $day $r)" }
    [pscustomobject]@{ text = "$(& $sid $r.id) · $(& $q $r) → $tail"; done = $r.status -ne 'pending' }
  }
  if ($Link) { [pscustomobject]@{ text = "plan · $Link"; done = $true } }
}
# blocking decisions as ONE native question call (AskUserQuestion: 4 questions, 4 options, header <= 12 chars; Codex: 3)
function ConvertTo-KitAskPayload($Decisions, [int]$Max = 4) {
  $ds = @($Decisions | Where-Object { @(Get-KitDecisionOrder $_).Count -ge 2 } | Select-Object -First $Max)   # the tools need 2-4 options
  [pscustomobject]@{ ids = @($ds | ForEach-Object id); questions = @(foreach ($d in $ds) {
    $h = if ("$($d.item)") { "$($d.item)" } else { 'Decision' }
    [pscustomobject]@{ question = $d.question; header = $h.Substring(0, [math]::Min(12, $h.Length)); multiSelect = $false
      options = @(Get-KitDecisionOrder $d | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ label = "$($_.key): $($_.label)$(if ($_.recommended) { ' (Recommended)' })" -replace '^: ', ''; description = $_.description } }) } }) }
}
function Test-KitTaskDocLink([string]$Task) {
  try { $tt = Get-TrackerTask $Task } catch { return $null }   # unread = unknown, never "no doc"
  if (-not $tt -or -not $tt.name) { return $null }
  $d = [string]$tt.description
  ($d -match '(?im)^\W{0,3}Testing doc \(human\)\W{0,3}:[ \t*_]*[^\s*_]') -and ($d -match '(?im)^\W{0,3}Testing doc \(AI\)\W{0,3}:[ \t*_]*[^\s*_]')   # an empty bold label is no link
}
# this request's mandate only (a stored one is older words); sonnet unless -Complex
function Get-BugWfArgs($Brief, $RunName, $Agent, $Items, $Area, [string[]]$Mandate, [bool]$Complex, $KitDir) {
  if (-not $Mandate) { Write-Warning "no -Mandate: replace the placeholder with the owner's words of this request (agents drop items for later chat messages without them)" }
  $a = [ordered]@{ id = $Agent; items = $Items; area = $Area.Substring(0, [math]::Min(160, $Area.Length)) }; if ($Complex) { $a.complex = $true }
  [ordered]@{ brief = $Brief; run = $RunName; mode = 'bugfix'; kitDir = ($KitDir -replace '\\', '/'); mandate = @(if ($Mandate) { $Mandate } else { "<the owner's words of this request, verbatim>" }); agents = @($a) }
}
# finalize writes <run>/<item>/report.md per tested item (none at the run root)
function Get-KitQaRunGap([string]$RunDir) {
  $items = @(Get-ChildItem -LiteralPath $RunDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'results.json') })
  if (-not $items.Count) { return ', no item tested' }
  $miss = @($items | Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName 'report.md')) } | ForEach-Object Name)
  if ($miss.Count) { ", no report: $($miss -join ', ')" } else { '' }
}

# ---- git-host: git-host + ci adapters (README "Adapters"); Invoke-HostVerb <verb> @{ repo = '<group/name>'; n; ... }
function Get-HostKind([string]$HostName) { switch -Regex ($HostName) { 'github' { 'github' } 'bitbucket' { 'bitbucket' } 'dev\.azure\.com|visualstudio\.com' { 'azure' } 'gitea|forgejo|codeberg' { 'gitea' } default { 'gitlab' } } }
if (-not (Get-KitValue 'gitHost' '') -and ($__o = @(@(Get-KitValue 'repos' @()).checkout | Where-Object { $_ -and (Test-Path $_) })[0]) -and "$(git -C $__o remote get-url origin 2>$null)" -match '^(?:\w+://)?(?:[^@/]+@)?(?:ssh\.)?([^/:]+)') { $KitConf.GitHost = $Matches[1] }
$script:HostType = ([string](Get-KitValue 'gitHostType' (Get-HostKind $KitConf.GitHost))).ToLower()
$script:MrSegRx = '(?:-/merge_requests|pulls?|pull-requests|pullrequest)'
function ConvertFrom-MrUrl([string]$Url) {
  if ($Url -notmatch '^https?://(?<h>[^/\s]+)/(?<p>[^\s?#]+?)/(?<s>-/merge_requests|pulls?|pull-requests|pullrequest)/(?<n>\d+)') { return $null }
  $t = @{ '-/merge_requests' = 'gitlab'; pull = 'github'; pulls = 'gitea'; 'pull-requests' = 'bitbucket'; pullrequest = 'azure' }[$Matches.s]
  @{ repo = $Matches.p -replace '/_git/', '/'; n = $Matches.n; type = $(if ($t -eq 'github' -and (Get-HostKind $Matches.h) -eq 'gitea') { 'gitea' } else { $t }) }
}
function Get-HostProject([string]$Repo, [switch]$Raw) {
  $p = if ($Repo -match '/') { $Repo } elseif ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$Repo" } else { $Repo }
  if ($Raw) { $p } else { [uri]::EscapeDataString($p) }
}
function Get-RepoConf([string]$Repo, [string]$Key, $Default) {
  $n = ("$Repo" -split '/')[-1]
  foreach ($r in @(Get-KitValue 'repos' @())) { if (($r.name -in $n, $Repo -or @($r.aliases) -contains $n) -and "$($r.$Key)" -ne '') { return $r.$Key } }
  $Default
}
# repos[].ci: a CI type string or an object ({ type, mrPipelines }); only the type names the adapter
function Get-KitCiType([string]$Repo, [string]$HostT = $script:HostType) { $rc = Get-RepoConf $Repo 'ci' 'host'; $c = ([string]$(if ($rc -is [string]) { $rc } elseif ($rc.type) { $rc.type } else { 'host' })).ToLower(); if ($c -eq 'external') { $c = ([string](Get-KitSetting 'ci.type' 'host')).ToLower() }; if ($c -eq 'host') { $HostT } else { $c } }
function __HostJson($out) { $t = (@($out) | ForEach-Object { "$_" }) -join "`n"; if (-not $t.Trim()) { return $null }; try { $t | ConvertFrom-Json } catch { $null } }
function __Enc([string]$s) { [uri]::EscapeDataString($s) }
function __Del($a) { [bool](Get-RepoConf $a.repo 'deleteBranch' $true) }
function __Query([string]$q) { $h = @{}; foreach ($kv in ($q -split '&' | Where-Object { $_ })) { $k, $v = $kv -split '=', 2; $h[[uri]::UnescapeDataString($k)] = [uri]::UnescapeDataString("$v") }; $h }
function __HostSet([string]$Key, $Default) { Get-KitSetting "gitHostApi.$Key" $Default }
function __Cli([string]$Exe, [string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) {
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }
  $a = @('api'); if ($Method -ne 'GET') { $a += @('-X', $Method) }; $a += $Path; $f = $null
  if ($Json) { $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, ($Fields | ConvertTo-Json -Compress -Depth 10)); $a += @('-H', 'Content-Type: application/json', '--input', $f) }
  else { foreach ($k in $Fields.Keys) { $a += @('-f', "$k=$($Fields[$k])") } }
  try { $r = Invoke-KitRetry { Invoke-KitNetExe $Exe $a } -Connect:($Method -ne 'GET') } finally { if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
  if ($Res) { return $r }
  if ($r.code) { $global:KitHostFailed = $true; if ($r.timedOut -or (Test-KitTransient $r.err)) { Write-Warning "githost: $Exe api $Path failed on the network: $($r.err)" }; return $null }
  if ($Path -match '/(trace|logs)$') { return $r.out }
  __HostJson $r.out
}
function __Files($files) { @($files | ForEach-Object { [pscustomobject]@{ new_path = $_.filename; old_path = $(if ($_.previous_filename) { $_.previous_filename } else { $_.filename }) } }) }
function __CiWord([string]$w) {
  switch -Regex ($w) { '^(success|successful|succeeded|neutral|passed)$' { 'success' } '^(skipped|not_built|not_executed)$' { 'skipped' } '^(cancel+ed|aborted|stopped)$' { 'canceled' }
    '^(fail|failure|failed|error|errored|broken|infrastructure_fail|timed_out|action_required|startup_failure|unstable|partiallysucceeded)$' { 'failed' } '^(manual|paused|blocked|waiting)$' { 'manual' } '^scheduled$' { 'scheduled' } '^(pending|queued|created|notstarted|postponed)$' { 'pending' } default { 'running' } }
}
function __CiRoll([string[]]$s) { $s = @($s | Where-Object { $_ }); if (-not $s.Count) { return $null }; foreach ($w in 'failed', 'canceled', 'running', 'pending', 'manual', 'scheduled') { if ($s -contains $w) { return $w } }; if ($s -contains 'success') { 'success' } else { 'skipped' } }
function __CiRun($Id, $Sha, $Status, $CreatedAt = $null, $UpdatedAt = $null, $Url = $null) { $o = [ordered]@{ id = $Id; sha = $Sha; created_at = $CreatedAt; updated_at = $(if ($UpdatedAt) { $UpdatedAt } else { $CreatedAt }); status = $Status }; if ($Url) { $o.url = $Url }; [pscustomobject]$o }
function __CiJob($Id, $Name, $Status, $FinishedAt = $null) { $o = [ordered]@{ id = $Id; name = $Name; status = $Status }; if ($FinishedAt) { $o.finished_at = $FinishedAt }; [pscustomobject]$o }
function __CiStat($Id, $Status) { if ($Status) { [pscustomobject]@{ id = $Id; status = $Status } } }
function __CommitObj($Sha, $Date = $null) { if ($Sha) { $o = [ordered]@{ id = $Sha }; if ($Date) { $o.committed_date = $Date }; [pscustomobject]$o } }

# git hosts: goodies gitlab, github, bitbucket, azure-devops, gitea
# MR objects: __Mr fills the kit's shape; __GhMr maps a GitHub-shaped PR (goodies github, gitea)
function __Mr([hashtable]$H) {
  $o = [ordered]@{ iid = $null; title = ''; state = ''; source_branch = ''; target_branch = ''; sha = ''; merge_commit_sha = $null; squash_commit_sha = $null; merged_at = $null; created_at = $null
    updated_at = $null; draft = $false; has_conflicts = $false; detailed_merge_status = ''; merge_when_pipeline_succeeds = $false; web_url = ''; head_pipeline = $null }
  foreach ($k in $H.Keys) { $o[$k] = $H[$k] }; [pscustomobject]$o
}
function __GhMr($p) {
  if (-not $p -or -not $p.number) { return $null }
  __Mr @{ iid = $p.number; title = $p.title; state = $(if ($p.merged_at -or $p.merged) { 'merged' } elseif ($p.state -eq 'open') { 'opened' } else { 'closed' }); source_branch = $p.head.ref; target_branch = $p.base.ref
    sha = $p.head.sha; merge_commit_sha = $p.merge_commit_sha; merged_at = $p.merged_at; created_at = $p.created_at; updated_at = $p.updated_at; draft = [bool]$p.draft; has_conflicts = ($p.mergeable -eq $false)
    detailed_merge_status = $(if ($p.mergeable_state -eq 'dirty' -or $p.mergeable -eq $false) { 'conflict' } else { [string]$p.mergeable_state }); merge_when_pipeline_succeeds = [bool]$p.auto_merge; web_url = $p.html_url; author = $p.user.login }
}
# adapter:git-host/command: gitHostApi.commands.<verb>
Register-KitAdapter 'git-host' 'command' @{ '*' = { param($a, $v) Invoke-KitCommand 'git-host' (__HostSet 'commands' $null) $v $a } }
# adapter-end:git-host

# adapter:ci/command: ci.commands.<verb>
Register-KitAdapter 'ci' 'command' @{ '*' = { param($a, $v) Invoke-KitCommand 'ci' (Get-KitSetting 'ci.commands' $null) $v $a } }
# adapter:ci/none
Register-KitAdapter 'ci' 'none' @{ 'runs' = { @() }; 'jobs' = { @() }; 'log' = { '' }; 'status' = { $null }; 'config' = { $false } }
# adapter-end:ci

$global:KitHostMemo = if ($global:KitHostMemo) { $global:KitHostMemo } else { @{} }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  $t = ([string]$(if ($A.type) { $A.type } else { $script:HostType })).ToLower()
  if ($Verb -in 'mr.merge', 'mr.create' -and -not $A.method) { $A.method = [string](Get-RepoConf $A.repo 'mergeMethod' 'squash') }
  $ci = Get-KitCiType $A.repo $t
  $kind, $name, $v2 = if ($Verb -like 'ci.*') { 'ci', $ci, $Verb.Substring(3) } else { 'git-host', $t, $Verb }
  $mk = "$name|$Verb|$(($A.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&')"
  if ($Verb -in 'mr.create', 'mr.update', 'mr.merge', 'mr.unauto') { $global:KitHostMemo.Clear() }
  elseif (-not $NoMemo) {
    $cached = Get-KitMemo $global:KitHostMemo $mk 90 { $null }
    if ($null -ne $cached) { return $cached }
  }
  $v = Invoke-KitAdapter $kind $name $v2 $A
  if ($Verb -eq 'mr.get' -and $v.state -eq 'opened' -and ($t -ne 'gitlab' -or $ci -ne 'gitlab')) { $v | Add-Member -Force head_pipeline (Invoke-HostVerb 'ci.status' @{ type = $t; repo = $A.repo; sha = $v.sha; ref = $v.source_branch; n = $A.n } -NoMemo:$NoMemo) }
  if ($Verb -notin 'mr.create', 'mr.update', 'mr.merge', 'mr.unauto' -and $null -ne $v) { $global:KitHostMemo[$mk] = @{ at = Get-Date; v = $v; ok = $v } }
  $v
}
function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) {
  if ($Path -notmatch '^projects/(?<p>[^/?]+)/?(?<rest>[^?]*)\??(?<q>.*)$') { Write-Warning "githost: no verb for $Path"; return $null }
  $a = __Query $Matches.q; $a.repo = [uri]::UnescapeDataString($Matches.p); $v = $null
  switch -Regex ($Matches.rest) {
    '^merge_requests/(\d+)/?(\w*)$' { $a.n = $Matches[1]; $v = @{ '' = 'mr.get'; changes = 'mr.changes'; merge = 'mr.merge'; cancel_merge_when_pipeline_succeeds = 'mr.unauto' }[$Matches[2]] }
    '^merge_requests$' { $v = 'mr.list' }
    '^repository/merge_base$' { $r = @([regex]::Matches($Path, 'refs\[\]=([^&]+)') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) }); if ($r.Count -ge 2) { $a.a, $a.b = $r[0], $r[1]; $v = 'repo.base' } }
    '^repository/commits/(.+)$' { $a.ref = [uri]::UnescapeDataString($Matches[1]); $v = 'repo.commit' }
    '^repository/compare$' { $v = 'repo.compare' }
    '^pipelines$' { $v = 'ci.runs' }
    '^pipelines/(\d+)/jobs$' { $a.id = $Matches[1]; $v = 'ci.jobs' }
    '^jobs/(\d+)/trace$' { $a.id = $Matches[1]; $v = 'ci.log' }
  }
  if ($v -eq 'mr.merge') { if ($Fields.squash) { $a.method = if ($Fields.squash -eq 'true') { 'squash' } else { 'merge' } }; $a.sha = $Fields.sha; $a.auto = "$($Fields.merge_when_pipeline_succeeds)" -eq 'true' }
  if (-not $v) { Write-Warning "githost: no verb for $Path"; return $null }
  Invoke-HostVerb $v $a -NoMemo:$NoMemo
}
# from the host, not git: a squash merge's tip is never in the target
function Get-MergedMrs([string]$Dir, [string]$Branch, [string]$Target, [string]$State = 'merged', [string]$Iid) {   # -Iid: that MR, in that state
  $url = "$(git -C $Dir remote get-url origin 2>$null)".Trim()
  if ($url -notmatch '^(?:https?://(?:[^@/]+@)?(?<host>[^/]+)/|[^@]+@(?<host>[^:]+):)(?<path>.+?)(?:\.git)?/?$') { return @() }
  $hostName = $Matches.host; $path = $Matches.path -replace '/_git/', '/' -replace '^v3/', ''
  $type = if ($hostName -eq $KitConf.GitHost) { $script:HostType } else { Get-HostKind $hostName }
  if ($type -eq 'gitlab') { $env:GITLAB_HOST = $hostName }
  if ($Iid) { return @(Invoke-HostVerb 'mr.get' @{ repo = $path; type = $type; n = $Iid } | Where-Object { $_ -and $_.state -eq $State }) }
  $q = @{ repo = $path; type = $type; source_branch = $Branch; state = $State; per_page = 20 }; if ($Target) { $q.target_branch = $Target }
  @(Invoke-HostVerb 'mr.list' $q | Where-Object { $_ -and (-not $Target -or $_.target_branch -eq $Target) })
}
# track ignore: MRs the untracked-MR watch skips
function Add-KitMrIgnore([string[]]$Mrs, [string]$Reason) {
  if (-not ($Mrs.Count -and $Reason)) { Stop-KitVerb "usage: bossy.ps1 track ignore -Mrs '<repo>!<iid>' -Reason '<why>'" }
  $f = Get-KitPath mr-ignore -Create
  Invoke-KitLocked $f { $m = [ordered]@{}; $o = Read-KitState $f; if ($o.mrs) { foreach ($n in $o.mrs.Keys) { $m[$n] = $o.mrs[$n] } }
    foreach ($r in $Mrs) { $m[$r] = [ordered]@{ reason = $Reason; at = (Get-Date).ToString('o') } }; Write-KitState $f ([ordered]@{ mrs = $m }) }
  $Mrs | ForEach-Object { "ignored $_ ($Reason): the untracked-MR watch skips it" }
}
# this machine's git-host CLI login; '' = unknown
function Get-KitHostUser {
  switch ($script:HostType) { 'gitlab' { if (Get-Command __GlEnv -ErrorAction SilentlyContinue) { __GlEnv }; [string](__Cli glab 'user').username } 'github' { [string](__Cli gh 'user').login } default { '' } }
}
# deploy MR (no task): a protected or deploy/* source, or a repos[].deploys[].branch target other than the task target
function Test-KitDeployMr([string]$Repo, [string]$Source, [string]$Target) {
  if ($Source -match ('^(?:main|master|develop|release/.+|deploy/.+' + (@($KitConf.ProtectedBranches | Where-Object { $_ } | ForEach-Object { '|' + ([regex]::Escape($_) -replace '\\\*', '.+') }) -join '') + ')$')) { return $true }
  $r = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq ($Repo -split '/')[-1] } | Select-Object -First 1
  [bool]($Target -and $r -and $Target -in @(@($r.deploys).branch | Where-Object { $_ -and $_ -ne $r.target }))
}
# ONE WATCH for the owner's MRs merged in 24 h that no task tracks; host lists cached 2 beats, the login a day
function Get-KitUntrackedMrFlag($State, [datetime]$Now, [scriptblock]$Within = { $true }) {
  $um = $State.untrackedMrs
  if (-not $um -or ($Now - [datetime]$um.at).TotalMinutes -ge [math]::Max(30, 2 * (Get-KitBeatMinutes))) {   # per-round lists took 4.5-6 s; a 5 min pace refreshed every other sweep
    $hu = if ($State.hostUser.v -and ($Now - [datetime]$State.hostUser.at).TotalHours -lt 24) { $State.hostUser.v } else { $x = try { Get-KitHostUser } catch { '' }; if ($x) { $State.hostUser = @{ at = $Now.ToString('o'); v = $x } }; $x }
    $since = $Now.ToUniversalTime().AddHours(-24).ToString('o')
    $um = @{ at = $Now.ToString('o'); user = $hu; mrs = @(if ($hu) { foreach ($rp in @(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ }) {
            if (-not (& $Within)) { break }
            foreach ($m in @(try { Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = $since; per_page = 50 } } catch { }) | Where-Object { $_.iid }) {
              @{ repo = $rp; iid = "$($m.iid)"; title = "$($m.title)"; branch = "$($m.source_branch)"; target = "$($m.target_branch)"; author = $(if ($m.author.username) { $m.author.username } else { "$($m.author)" }); merged_at = "$($m.merged_at)" } } } }) }
    $State.untrackedMrs = $um
  }
  $tr = Read-KitTracking; $cut = $Now.ToUniversalTime().AddHours(-24)
  $ig =@{ tasks = @{ ignored = @{ mrs = @((Read-KitState (Get-KitPath mr-ignore)).mrs.Keys) } } }   # track ignore: not the owner's work
  $known = if ($State.known) { @($State.known.Keys) } else { @() }   # supervise -Ack on this flag: one decision per MR
  $un = @($um.mrs | Where-Object { $_ -and $um.user -and $_.author -eq $um.user -and -not (Test-KitDeployMr $_.repo $_.branch $_.target) -and $_.merged_at -and ([datetimeoffset]$_.merged_at).UtcDateTime -ge $cut -and "$($_.repo)!$($_.iid)" -notin $known -and -not (Test-KitMrTracked $_.repo $_.iid $tr) -and -not (Test-KitMrTracked $_.repo $_.iid $ig) })
  if (-not $un.Count) { return }
  $tg = Get-KitTaskTagRx; $refs = @($un | ForEach-Object { "$($_.repo)!$($_.iid)" })
  $adds = @($un | ForEach-Object { $tid = if ($tg -and "$($_.branch) $($_.title)" -match $tg) { $Matches.id } else { '<task>' }; "& $($KitCmd.orch) track add -Task $tid -Mrs '$($_.repo)!$($_.iid)'" })
  # cells are cut at 90 chars: full commands in the report's "All flags"
  [pscustomobject]@{ level = 'WATCH'; what = "$($un.Count) MR(s) of $($um.user) merged in 24 h tracked by no task: $(@($un | ForEach-Object { "$($_.repo)!$($_.iid) ($("$($_.title)".Substring(0, [math]::Min(50, "$($_.title)".Length))))" }) -join '; ')"
    action = "Link each to its task: $($adds -join '; '); then track run (no task: supervise -Ack; not the owner's: track ignore -Mrs <MR> -Reason '<why>')."; kind = 'UNTRACKED MR'; who = $um.user; problem = "$(@($refs | Select-Object -First 5) -join ', ')$(if ($refs.Count -gt 5) { " +$($refs.Count - 5)" }) merged, no task"; next = 'track add -Task <id> -Mrs <MR> each (full: report)'; refs = $refs }
}

function Get-KitRepoSweep { try { Get-Content -LiteralPath (Get-KitPath repo-sweep) -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }   # the last cleanup's counts per repo

# ---- kitlog: every log line (kit.example.json _paths.log)
$script:KitLogMap = $script:KitPathMap.log
function Protect-KitText([string]$s) { if ($s) { foreach ($m in $script:KitLogMap.mask) { $s = $s -replace $m[0], $m[1] } }; $s }
function Protect-KitValue($v, [int]$d = 0) {
  if ($null -eq $v -or $v -is [ValueType]) { return $v }
  if ($v -is [string]) { return Protect-KitText $v }
  $isD = $v -is [Collections.IDictionary]
  if (($isD -or $v -is [Management.Automation.PSCustomObject]) -and $d -lt 5) {
    $o = [ordered]@{}; foreach ($k in @(if ($isD) { $v.Keys } else { $v.PSObject.Properties.Name })) { $x = $null; if ($isD) { $x = $v[$k] } else { $x = $v.$k }   # not $(...): it unrolls a one-item list
      $o["$k"] = if ("$k" -match $script:KitLogMap.secretKey) { '[redacted]' } else { Protect-KitValue $x ($d + 1) } }; return $o }
  if ($v -is [Collections.IEnumerable] -and $d -lt 5) { return , @($v | ForEach-Object { Protect-KitValue $_ ($d + 1) }) }
  Protect-KitText "$v"
}
function Get-KitLogFile([string]$Stream, [datetime]$Day = (Get-Date), [switch]$Create) {
  if ($Stream -notin $script:KitLogMap.streams) { throw "kitlog: unknown stream '$Stream' (kit.example.json _paths.log.streams)" }
  if ($script:KitPathMap.durable.PSObject.Properties.Name -contains $Stream) { return Get-KitPath $Stream -Create:$Create }
  $p = Join-Path (Get-KitPath audit) "$($Day.ToString('yyyy-MM-dd'))/$Stream.jsonl"; if ($Create) { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null }; $p
}
# params, else the board entry (-Session, -Dir, -Worktree), else KIT_AGENT / KIT_RUN
function Get-KitWho([Collections.IDictionary]$Named = @{}) {
  $w = [ordered]@{ run = "$($Named.Run)"; agent = "$($Named.Agent)"; task = "$($Named.Task)" }
  $b = if ($Named.Session) { try { Get-Content (Join-Path (Get-KitPath board) "$($Named.Session).json") -Raw -ErrorAction Stop | ConvertFrom-Json } catch {} }
  $dir = "$(@($Named.Dir, $Named.Worktree) | Where-Object { $_ } | Select-Object -First 1)"
  if (-not $b -and -not $w.agent -and $dir) { $d = try { [IO.Path]::GetFullPath($dir).TrimEnd('\', '/').ToLower() } catch { '' }
    $b = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt (Get-Date).AddDays(-1) | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
      Where-Object { $_.status -ne 'left' -and @($_.worktrees | Where-Object { $_ -and $d.StartsWith(([IO.Path]::GetFullPath("$_").TrimEnd('\', '/').ToLower())) }).Count })[0] }
  if ($b) { if (-not $w.agent) { $w.agent = "$($b.agent)" }; if (-not $w.run) { $w.run = "$($b.run)" } }
  if (-not $w.agent) { $w.agent = "$env:KIT_AGENT" }; if (-not $w.run) { $w.run = "$env:KIT_RUN" }
  $w
}
# one whole JSON line, shared append, retried; logging never breaks a verb
function Write-KitLog([Parameter(Mandatory)][string]$Stream, [string]$Event = '', $Fields = @{}, [Collections.IDictionary]$Who) {
  try {
    if (-not $Who) { $Who = if ($script:KitWho) { $script:KitWho } else { Get-KitWho } }
    $f = Protect-KitValue $Fields; $o = [ordered]@{ at = $(if ($f.at) { $f.at } else { (Get-Date).ToString('o') }) }
    foreach ($k in 'run', 'agent', 'task') { if ($Who[$k]) { $o[$k] = $Who[$k] } }
    $o.script = "$script:KitScript"; $o.verb = "$script:KitVerb"; if ($Event) { $o.event = $Event }
    foreach ($k in $f.Keys) { $o[$k] = $f[$k] }
    $b = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress -Depth 8) + "`n"); $file = Get-KitLogFile $Stream -Create
    for ($i = 0; $i -lt 40; $i++) { try { $fs = [IO.FileStream]::new($file, 'Append', 'Write', 'ReadWrite, Delete'); try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; break } catch [IO.IOException] { Start-Sleep -Milliseconds 25 } }
  } catch {}
}
# a bad line is skipped
function Read-KitLog([string[]]$Stream = $script:KitLogMap.streams, [datetime]$Since = (Get-Date).AddDays(-1)) {
  foreach ($s in $Stream) {
    $files = if ($script:KitPathMap.durable.PSObject.Properties.Name -contains $s) { Get-KitPath $s } else { Get-ChildItem (Get-KitPath audit) -Directory -ErrorAction SilentlyContinue | Where-Object Name -ge $Since.ToString('yyyy-MM-dd') | Sort-Object Name | ForEach-Object { Join-Path $_.FullName "$s.jsonl" } }
    foreach ($f in @($files | Where-Object { Test-Path -LiteralPath $_ })) {
      foreach ($l in Get-Content -LiteralPath $f) { $o = try { $l | ConvertFrom-Json } catch { $null }; if ($o.at -and [datetime]$o.at -ge $Since) { $o | Add-Member -Force NoteProperty stream $s; $o } }
    }
  }
}
# word sets and their overlap (Jaccard)
$script:KitTidyCommon = 'that this with from then when what they have were been into only also than after which there does fixed'.Split(' ')
function Get-KitWordSet([string]$Text) { $h = [Collections.Generic.HashSet[string]]::new(); foreach ($m in [regex]::Matches("$Text".ToLower(), '[a-z][a-z0-9_-]{3,}')) { if ($m.Value -notin $script:KitTidyCommon) { [void]$h.Add($m.Value) } }; , $h }
function Get-KitOverlap($A, $B) { if (-not $A.Count -or -not $B.Count) { return 0 }; $i = 0; foreach ($w in $A) { if ($B.Contains($w)) { $i++ } }; $i / ($A.Count + $B.Count - $i) }
# signals of one skill joined when any two overlap >= $Min; each group with its closest lesson (bump candidate)
function Get-KitSignalGroups($Signals, $Lessons, [double]$Min = 0.3) {   # TODO-PARAM (fixed default)
  $groups = [Collections.Generic.List[object]]::new()
  foreach ($s in $Signals) {
    $w = Get-KitWordSet $s.text; $hit = $null
    foreach ($g in $groups) { if ($g.skill -eq $s.skill -and @($g.words | Where-Object { (Get-KitOverlap $_ $w) -ge $Min }).Count) { $hit = $g; break } }
    if ($hit) { $hit.items.Add($s); $hit.words.Add($w) } else { $groups.Add([pscustomobject]@{ skill = $s.skill; items = [Collections.Generic.List[object]]@($s); words = [Collections.Generic.List[object]]@(, $w) }) }
  }
  foreach ($g in $groups) {
    $best = $null; $bs = 0
    foreach ($l in @($Lessons | Where-Object skill -eq $g.skill)) { $lw = Get-KitWordSet $l.text; $sc = @($g.words | ForEach-Object { Get-KitOverlap $_ $lw } | Measure-Object -Maximum).Maximum; if ($sc -gt $bs) { $bs = $sc; $best = $l } }
    [pscustomobject]@{ skill = $g.skill; n = $g.items.Count; kinds = @($g.items.kind | Select-Object -Unique) -join ','; text = $g.items[0].text; refs = @($g.items.ref | Where-Object { $_ } | Select-Object -Unique); lesson = $(if ($bs -ge $Min) { $best.text }); score = [math]::Round($bs, 2) }
  }
}
function ConvertTo-KitArgs([object[]]$Tokens) {
  $hide = $false; $a = foreach ($t in $Tokens) { $s = Protect-KitText ("$t" -replace '\s+', ' '); $out = if ($hide) { '[redacted]' } elseif ($s.Length -gt 120) { $s.Substring(0, 117) + '...' } else { $s }; $hide = $s -match '^-' -and $s -match $script:KitLogMap.secretKey; $out }
  $j = Protect-KitText (@($a) -join ' '); if ($j.Length -gt 500) { $j.Substring(0, 497) + '...' } else { $j }
}

function Invoke-KitVerb([string]$Fn, [object[]]$Tokens) {
  $Tokens = @($Tokens)
  $src = $MyInvocation.PSCommandPath
  $help = { if ($src -and (Test-Path $src)) { (Get-Content $src -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1' | Write-Output }; exit 0 }
  $fnc = Get-Command $Fn; if ($fnc.ScriptBlock.File) { Add-KitExtraUse $fnc.ScriptBlock.File }   # a verb a goody brings
  $meta = $fnc.Parameters
  $own = @($meta.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
  $script:KitScript = if ($src) { Split-Path $src -Leaf } else { '' }; $sub = "$($Tokens[0])" -match '^[a-z][\w-]*$'; $script:KitVerb = (($Fn -replace '^Invoke-', '') + $(if ($sub) { " $($Tokens[0])" })).ToLower()
  # calls stream: start, then end with rc (0, 1 crash, 2 bad parameters, 'exit' = the verb's own exit) and ms
  $script:KitLogOn = $Fn -notmatch '^Invoke-Guard'; $sw = [Diagnostics.Stopwatch]::StartNew(); $script:KitRc = 'exit'   # guards run on every tool call: they log only denials
  $end = { param([string]$EndWhy) if (-not $EndWhy) { $EndWhy = $script:KitWhy }; if ($script:KitLogOn) { $script:KitLogOn = $false; Write-KitLog calls end (@{ pid = $PID; rc = $script:KitRc; ms = $sw.ElapsedMilliseconds } + $(if ($EndWhy) { @{ error = $EndWhy } } else { @{} })) } }   # rc 2 feeds tidy digest "Script errors"
  # bad parameters: exit 2 with the usage line, never the host's prompt for a mandatory one
  $usage = { param([string]$why, [bool]$missing)
    $vs = @($meta.Values | Where-Object { $_.Attributes.Where({ $_ -is [Parameter] -and $_.Position -eq 0 }) } | ForEach-Object { $_.Attributes.Where({ $_ -is [ValidateSet] }).ValidValues } | Where-Object { $_ }); if ($vs.Count -and $missing) { $why += " Verbs: $($vs -join ', ')." }    $use = if ($src -and (Test-Path $src)) { [regex]::Match((Get-Content $src -Raw), "(?m)^\s+$([regex]::Escape(($Fn -replace '^Invoke-', '').ToLower()))\b[^\r\n]*").Value.Trim() }; if ($use) { $why += " Usage: $use" }
    $script:KitRc = 2; & $end $why; [Console]::Error.WriteLine($why); exit 2 }
  # a crash exits 1, never 0: a statement error alone lets `pwsh -File` exit 0
  $run = { param([object[]]$pa, [hashtable]$nm)
    $script:KitWho = Get-KitWho $nm; if ($script:KitLogOn) { Write-KitLog calls start @{ pid = $PID; args = (ConvertTo-KitArgs @($Tokens | Select-Object -Skip ([int]$sub))) } }
    try { try { & $Fn @pa @nm; $script:KitRc = 0 } catch {
    if ($_.Exception -is [Management.Automation.ParameterBindingException] -and $_.InvocationInfo.MyCommand.Name -eq $Fn) { & $usage "$($Fn -replace '^Invoke-', ''): $($_.Exception.Message)" ($_.Exception.ErrorId -eq 'MissingMandatoryParameter') }
    $script:KitRc = 1; Write-KitLog calls error @{ error = "$_ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" }; & $end
    if ($KitVerbOnError) { & $KitVerbOnError $_ }; [Console]::Error.WriteLine("$($Fn -replace '^Invoke-', '') FAILED: $_$(if ($_.FullyQualifiedErrorId -ne "$($_.Exception.Message)") { ' ' + ($_.InvocationInfo.PositionMessage -replace '\s+', ' ') })"); exit 1 } } finally { & $end } }   # a thrown message alone: no code position
  if (-not $own.Count) { if ($Tokens.Count -and "$($Tokens[0])" -in '--help', '-h', '-?', '-help') { & $help }; & $run $Tokens @{}; return }
  $named = @{}; $pos = [Collections.Generic.List[object]]::new(); $i = 0
  while ($i -lt $Tokens.Count) {
    $t = "$($Tokens[$i])"
    if ($t -in '--help', '-?' -or ($t -in '-h', '-help' -and -not @($own | Where-Object { $_ -ieq $t.TrimStart('-') }).Count)) { & $help }
    if ($t -match '^--\w') { [Console]::Error.WriteLine("$($Fn -replace '^Invoke-', ''): unknown option $t (parameters take one dash; --help prints the usage)"); exit 2 }
    if ($t -match '^-([A-Za-z][\w-]*)(?::(.*))?$') {
      $n = $Matches[1]; $inline = $Matches[2]
      $p = @($own | Where-Object { $_ -ieq $n }); if (-not $p.Count) { $p = @($own | Where-Object { @($meta[$_].Aliases) -contains $n }) }; if (-not $p.Count) { $p = @($own | Where-Object { $_ -like "$n*" }) }
      if ($p.Count -ne 1) { [Console]::Error.WriteLine("$($Fn -replace '^Invoke-', ''): unknown or ambiguous parameter -$n"); exit 2 }
      $pm = $meta[$p[0]]; $i++
      if ($inline -eq '') { $inline = $null; if ($pm.SwitchParameter -and $i -lt $Tokens.Count -and ($Tokens[$i] -is [bool] -or "$($Tokens[$i])" -match '^(true|false)$')) { $inline = "$($Tokens[$i])"; $i++ } }
      if ($pm.SwitchParameter) { $named[$p[0]] = if ($null -ne $inline) { $inline -notmatch '^(\$?false|0)$' } else { $true }; continue }
      $vals = [Collections.Generic.List[object]]::new(); if ($null -ne $inline) { $vals.Add($inline) }
      while ($i -lt $Tokens.Count -and "$($Tokens[$i])" -notmatch '^-[A-Za-z][\w-]*(:.*)?$') { $vals.Add($Tokens[$i]); $i++ }
      $named[$p[0]] = if ($pm.ParameterType.IsArray) { @($vals) } elseif ($vals.Count -gt 1) { @($vals) -join ' ' } elseif ($vals.Count) { $vals[0] } else { '' }
    } else { $pos.Add($Tokens[$i]); $i++ }
  }
  $miss = @($own | Where-Object { $pa = @($meta[$_].Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory -and $_.ParameterSetName -eq '__AllParameterSets' -and -not $_.ValueFromPipeline -and -not $_.ValueFromRemainingArguments }); $pa.Count -and -not $named.ContainsKey($_) -and -not ($pa[0].Position -ge 0 -and $pa[0].Position -lt $pos.Count) })
  if ($miss.Count) { & $usage "$($Fn -replace '^Invoke-', ''): missing -$($miss -join ', -')." $true }   # a host prompt would hang the tool call
  & $run $pos.ToArray() $named
}
# a verb's own refusal: the message to stderr and the calls log (tidy digest "Script errors"), then exit
function Stop-KitVerb([string]$Msg, [int]$Code = 2) { $script:KitRc = $Code; $script:KitWhy = $Msg; [Console]::Error.WriteLine($Msg); exit $Code }
# ---- params: tunable parameters (skills/bossy/params.registry.json; README "Configuration")
$script:KitParamReg = try { (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'bossy/params.registry.json') -Raw -ErrorAction Stop | ConvertFrom-Json).params } catch { $null }
function Get-KitNow { if ($env:KIT_NOW) { [datetime]$env:KIT_NOW } else { Get-Date } }   # KIT_NOW: the tests' fake clock
# entry: '<how> q=.95 k=1.5 up=.25 down=.1 min=5 safe=up gate=accuracy class=timeout sample=10 default=60 unit=s floor=1 ceil=9' or
# an object; how config = fixed default, never learned
function Get-KitParamSpec([string]$Key) {
  $r = if ($script:KitParamReg) { $script:KitParamReg.$Key }; if (-not $r) { return $null }
  $o = @{ how = 'quantile'; q = 0.95; k = 1.5; up = 0.25; down = 0.1; min = 5; safe = 'up'; gate = ''; class = ''; sample = 1; spec = "$r" }
  if ($r -is [string]) { $w = @($r -split '\s+'); $o.how = $w[0]; foreach ($x in $w | Select-Object -Skip 1) { $kv = $x -split '=', 2; $o[$kv[0]] = if ($kv[1] -match '^[\d.]+$') { [double]$kv[1] } else { $kv[1] } } }
  else { foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }; if ($r.kind -and $r.kind -ne 'learn') { $o.how = 'config' }; $o.spec = $r | ConvertTo-Json -Compress }
  $o.down = [math]::Min(0.1, $o.down); $o   # a risky step (toward failures): at most 10%
}
function Get-KitParamKeys([switch]$Learned) { @(if ($script:KitParamReg) { $script:KitParamReg.PSObject.Properties.Name | Where-Object { -not $Learned -or (Get-KitParamSpec $_).how -ne 'config' } }) }
function Read-KitParams([switch]$Strict) {   # -Strict (writers): a broken file throws, never overwritten
  $f = Get-KitPath param-state; if ($Strict -and -not (Test-Path -LiteralPath $f)) { return @{} }
  try { $s = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($s) { $s } else { @{} } } catch { if ($Strict) { throw "param state $f unreadable: $_" }; @{} }
}
# KIT_PARAM_<KEY> > kit.local.json <key>[.<context>] > param pin > learned (params.learning on) > default
function Resolve-KitParam([string]$Key, $Default, [string]$Context, $St) {
  $ev = [Environment]::GetEnvironmentVariable('KIT_PARAM_' + ($Key -replace '\W', '_').ToUpper()); if ($ev) { return @([double]$ev, 'env') }
  foreach ($p in @($Key) + @(if ($Context) { "$Key.$Context" })) { $c = Get-KitSetting $p $null; if ($null -ne $c -and ($c -is [ValueType] -or $c -is [string])) { return @($c, 'pin (kit.local.json)') } }
  $pn = $St.pins."$Key|$Context"; if ($null -eq $pn) { $pn = $St.pins."$Key|" }; if ($null -ne $pn) { return @($pn.value, 'pin') }   # a pin without context: every context
  $e = $St.byKey.$Key.$(if ($Context) { $Context } else { '_' })
  if ($null -ne $e.value -and "$(Get-KitSetting 'params.learning' 'on')" -eq 'on') { return @([double]$e.value, 'learned') }
  @($Default, $(if ($null -ne $e.rec) { 'default (learned in shadow)' } else { 'default' }))
}
$script:KitParamMemo = @{}
function Get-KitParamState { Get-KitMemo $script:KitParamMemo state 60 { Read-KitParams } }
# never throws: the default on any error; state cached 60 s
function Get-KitParam([Parameter(Mandatory)][string]$Key, $Default, [string]$Context = '') {
  if ($null -eq $Default) { $Default = (Get-KitParamSpec $Key).default }
  try { (Resolve-KitParam $Key $Default $Context (Get-KitParamState))[0] } catch { $Default }
}
# last sweep's load (under 1 h old); lb busy (cpu 80%+ or manyAgents) | calm
function Get-KitLoadTags { Get-KitMemo $script:KitParamMemo load 60 { $l = try { (Get-Content (Get-KitPath supervise-state) -Raw -ErrorAction Stop | ConvertFrom-Json).load } catch { $null }
    if (-not $l.at -or ((Get-Date) - [datetime]$l.at).TotalHours -ge 1) { return @{ lb = '' } }
    @{ availGB = $l.availGB; cpu = $l.cpu; agents = $l.agents; lb = $(if ([double]$l.cpu -ge 80 -or [double]$l.agents -ge [double](Get-KitParam 'supervise.manyAgents')) { 'busy' } else { 'calm' }) } } }
# $Default = the call site's fixed default (clamps); Result ok | fail | timeout (censored) | oom | short
function Add-KitParamObs([string]$Key, [double]$Value, [string]$Context = '', [string]$Result = 'ok', [double]$Default = 0) {
  $sp = Get-KitParamSpec $Key; if (-not $sp -or $sp.how -eq 'config' -or "$(Get-KitSetting 'params.learning' 'on')" -eq 'off') { return }
  $w = if ($Result -eq 'ok' -and $sp.sample -gt 1) { if ([long]((Get-KitNow).Ticks / 10000) % [int]$sp.sample) { return }; [int]$sp.sample } else { 1 }   # 1 in N ok lines, weight N; failures always
  if (-not $script:KitBoot) { $script:KitBoot = (Get-KitBootTime).ToString('yyyy-MM-ddTHH:mmzzz') }   # a reboot changes it
  $now = Get-KitNow; $ld = Get-KitLoadTags; $o = [ordered]@{ at = $now.ToString('o'); key = $Key; ctx = $Context; v = [math]::Round($Value, 3); r = $Result; d = $Default; w = $w; boot = $script:KitBoot; host = [Environment]::MachineName; lb = $ld.lb }
  if ($null -ne $ld.availGB) { $o.load = [ordered]@{ availGB = $ld.availGB; cpu = $ld.cpu; agents = $ld.agents } }
  $wk = (Get-KitParamState).wakeAt; if ($wk -and ($now - [datetime]$wk).TotalMinutes -lt 60) { $o.wake = [int]($now - [datetime]$wk).TotalMinutes }
  Write-KitLog params obs $o
}
# an outside trigger for the next learn pass: wake, reboot, deploy (key * = every key)
function Add-KitParamTrigger([string]$Why, [string]$Key = '*', [string]$Context = '') { Write-KitLog params trig ([ordered]@{ at = (Get-KitNow).ToString('o'); key = $Key; ctx = $Context; why = $Why }) }
# SessionStart: a reboot (boot time moved) or a wake (Windows power event) since the last look
function Test-KitWake {
  $boot = Get-KitBootTime
  $wake = if ($KitIsWindows) { try { (Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1 -ErrorAction Stop).TimeCreated } catch { $null } }
  $f = Get-KitPath param-state -Create; $res = @{}   # the locked body runs in a child scope
  Invoke-KitLocked $f { $s = Read-KitParams -Strict
    $res.why = if ($s.boot -and [math]::Abs(($boot - [datetime]$s.boot).TotalMinutes) -gt 2) { 'reboot' } elseif ($wake -and $s.wake -and $wake -gt [datetime]$s.wake) { 'wake' }
    if ($res.why) { $s.wakeAt = $(if ($res.why -eq 'wake') { $wake } else { $boot }).ToString('o') }
    $s.boot = $boot.ToString('o'); if ($wake) { $s.wake = $wake.ToString('o') }; Write-KitAtomic $f ($s | ConvertTo-Json -Depth 8 -Compress) }
  if ($res.why) { Add-KitParamTrigger $res.why }; $res.why
}
function Get-KitQuantile([double[]]$V, [double]$Q, [double[]]$W) {
  if (-not $V.Count) { return $null }; if (-not $W) { $W = @(foreach ($x in $V) { 1.0 }) }
  $ix = @(0..($V.Count - 1) | Sort-Object { $V[$_] }); $tot = ($W | Measure-Object -Sum).Sum; $acc = 0.0
  foreach ($i in $ix) { $acc += $W[$i]; if ($acc -ge $Q * $tot - 1e-9) { return $V[$i] } }; $V[$ix[-1]]
}
# DDSketch (2% relative accuracy) of an hour's ok observations; raw kept 14 d, hourly buckets 90 d
$script:KitSketchG = 1.02 / 0.98
function Add-KitSketch($H, [double]$V, [double]$W = 1) { $i = if ($V -gt 0) { [string][int][math]::Ceiling([math]::Log($V) / [math]::Log($script:KitSketchG)) } else { 'z' }; $H[$i] = [double]$H[$i] + $W }
function Get-KitSketchValue([string]$I) { if ($I -eq 'z') { 0.0 } else { 2 * [math]::Pow($script:KitSketchG, [int]$I) / ($script:KitSketchG + 1) } }
function Update-KitParamWindow($E, [datetime]$Now, $New) {   # $New: an observation to add; raw past 14 d or past 50 -> its hour's sketch
  if ($E.hr -isnot [Collections.IDictionary]) { $E.hr = @{} }
  $roll = { param($x) if ($x[2] -eq 'ok') { $hk = ([datetime]$x[0]).ToString('yyyy-MM-ddTHH:00'); if ($E.hr[$hk] -isnot [Collections.IDictionary]) { $E.hr[$hk] = @{} }; Add-KitSketch $E.hr[$hk] ([double]$x[1]) $(if ($x.Count -gt 3 -and [double]$x[3] -gt 0) { [double]$x[3] } else { 1 }) } }
  $all = [Collections.Generic.List[object]]::new(); foreach ($x in @($E.obs)) { $all.Add($x) }; if ($New) { $all.Add($New) }   # a List: @() would flatten a lone [at, v, r, w]
  $wl = [Collections.Generic.List[object]]::new(); foreach ($x in $all) { if (($Now - [datetime]$x[0]).TotalDays -le 14) { $wl.Add($x) } else { & $roll $x } }
  while ($wl.Count -gt 50) { & $roll $wl[0]; $wl.RemoveAt(0) }; $E.obs = $wl.ToArray()
  foreach ($hk in @($E.hr.Keys)) { if (($Now - [datetime]$hk).TotalDays -gt 90) { $E.hr.Remove($hk) } }
}
function Get-KitParamHistory($E) { @(foreach ($hk in @($E.hr.Keys | Sort-Object)) { foreach ($i in @($E.hr[$hk].Keys)) { , @($hk, (Get-KitSketchValue $i), 'ok', [double]$E.hr[$hk][$i]) } }) }   # sketch buckets as weighted observations
# quantile (under 5/(1-q) samples p90 x 2k; > 10% timeouts step up unless hangs) | peak (half-life 7 d) | ewma | aimd;
# spikes > median + 5 MAD dropped; two-sided CUSUM on logs (k 0.5, h 4.5 sigma) restarts the window on drift
function Get-KitParamRec($Spec, [object[]]$Obs, [double]$Cur, [datetime]$Now, $Since) {   # Since: last change (its timeouts already stepped)
  if ($Spec.how -eq 'config') { return $null }
  $all = @($Obs); $ok = @($all | Where-Object { $_[2] -in 'ok', 'short' }); $new = @($all | Where-Object { -not $Since -or [datetime]$_[0] -gt [datetime]$Since })
  if ($Spec.how -eq 'aimd') {
    if ($new.Count -lt $Spec.min -or @($new | Where-Object { $_[2] -ne 'ok' }).Count) { return $null }
    return @{ v = $Cur * 1.1; n = $all.Count; conf = 1; why = 'quiet: +10% (AIMD)' }
  }
  $okv = [double[]]@($ok | Where-Object { $_[2] -eq 'ok' } | ForEach-Object { [double]$_[1] }); $hang = $okv.Count -ge 5 -and (Get-KitQuantile $okv 0.99) -lt 0.1 * $Cur
  if ($Spec.how -eq 'quantile' -and $new.Count -ge $Spec.min -and @($new | Where-Object { $_[2] -eq 'timeout' }).Count -gt 0.1 * $new.Count) {
    if ($hang) { return @{ v = $Cur; n = $all.Count; conf = 1; why = 'timeouts are hangs (ok p99 < 0.1 x the value): retry, never raise' } }
    return @{ v = $Cur * (1 + $Spec.up); n = $all.Count; conf = 1; why = 'over 10% timed out: step up' }
  }
  $v = [double[]]@($ok | ForEach-Object { [double]$_[1] }); $wt = [double[]]@($ok | ForEach-Object { if ($_.Count -gt 3 -and [double]$_[3] -gt 0) { [double]$_[3] } else { 1.0 } })
  if ($v.Count -lt $Spec.min) { return $null }
  $med = Get-KitQuantile $v 0.5; $mad = Get-KitQuantile ([double[]]@($v | ForEach-Object { [math]::Abs($_ - $med) })) 0.5; $why = ''; $drift = $false
  if ($mad -gt 0) {
    $keep = @(0..($v.Count - 1) | Where-Object { $v[$_] -le $med + 5 * $mad }); if ($keep.Count -lt $v.Count) { $why = "$($v.Count - $keep.Count) spike(s) dropped; " }
    $ok = @($keep | ForEach-Object { , $ok[$_] }); $wt = [double[]]@($keep | ForEach-Object { $wt[$_] }); $v = [double[]]@($keep | ForEach-Object { $v[$_] })
  }
  $lg = [double[]]@($v | ForEach-Object { [math]::Log([math]::Max(1e-6, $_)) }); $lm = Get-KitQuantile $lg 0.5; $ls = 1.4826 * (Get-KitQuantile ([double[]]@($lg | ForEach-Object { [math]::Abs($_ - $lm) })) 0.5)
  if ($ls -gt 0 -and $v.Count -ge 10) {
    $hi = 0.0; $lo = 0.0; $cut = -1
    for ($i = 0; $i -lt $lg.Count; $i++) { $z = ($lg[$i] - $lm) / $ls; $hi = [math]::Max(0, $hi + $z - 0.5); $lo = [math]::Max(0, $lo - $z - 0.5); if ($hi -gt 4.5 -or $lo -gt 4.5) { $cut = $i; $hi = 0.0; $lo = 0.0 } }
    if ($cut -ge 0) { $from = [math]::Min($cut, $v.Count - $Spec.min); $ok = @($ok | Select-Object -Skip $from); $wt = [double[]]@($wt | Select-Object -Skip $from); $v = [double[]]@($v | Select-Object -Skip $from); $why += 'drift (CUSUM): window restarted; '; $drift = $true }
  }
  $x = switch ($Spec.how) {
    'peak' {
      $w = [double[]]@(for ($i = 0; $i -lt $ok.Count; $i++) { $wt[$i] * [math]::Pow(0.5, [math]::Max(0, ($Now - [datetime]$ok[$i][0]).TotalDays) / 7) })
      $p = (Get-KitQuantile $v 0.95 $w) * $Spec.k; $oom = @($all | Where-Object { $_[2] -eq 'oom' } | ForEach-Object { [double]$_[1] })
      if ($oom.Count) { $p = [math]::Max($p, 1.2 * ($oom | Measure-Object -Maximum).Maximum); $why += 'OOM bump; ' }; $p; $why += "peak q95 x$($Spec.k)" }
    'ewma' { $m = $v[0]; $var = 0.0; foreach ($y in $v) { $dl = $y - $m; $m += 0.3 * $dl; $var = 0.7 * ($var + 0.3 * $dl * $dl) }; $m + $Spec.k * [math]::Sqrt($var); $why += "ewma + $($Spec.k) sigma" }
    default {
      $nw = ($wt | Measure-Object -Sum).Sum
      if ($Spec.q -gt 0.9 -and $nw -lt 5 / (1 - $Spec.q)) { (Get-KitQuantile $v 0.9 $wt) * 2 * $Spec.k; $why += "p90 x$(2 * $Spec.k) (n $nw < $([int](5 / (1 - $Spec.q))) for p$([int](100 * $Spec.q)))" }
      else { (Get-KitQuantile $v $Spec.q $wt) * $Spec.k; $why += "p$([int](100 * $Spec.q)) x$($Spec.k)" } }
  }
  $mean = ($v | Measure-Object -Average).Average; $sd = [math]::Sqrt((($v | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / $v.Count)
  $conf = $v.Count / ($v.Count + 5) * $(if ($Spec.how -eq 'quantile' -or -not $mean) { 1 } else { 1 - [math]::Min(1, $sd / $mean) })
  @{ v = $x; n = $v.Count; conf = [math]::Round($conf, 2); p50 = $med; p90 = (Get-KitQuantile $v 0.9); max = ($v | Measure-Object -Maximum).Maximum; why = $why; drift = $drift; hang = $hang }
}
# append-only params-changes.jsonl: learned, pinned, approved, reset; host + load bucket
function Write-KitParamChange([string]$Key, [string]$Ctx, $From, $To, [string]$Why) { Write-KitLog params-changes change ([ordered]@{ at = (Get-KitNow).ToString('o'); key = $Key; ctx = $Ctx; from = $From; to = $To; why = $Why; host = [Environment]::MachineName; lb = (Get-KitLoadTags).lb }) }
# heartbeat "Settings": changes since a time
function Get-KitParamChanges([datetime]$Since) { @(Read-KitLog params-changes $Since | ForEach-Object { "SETTINGS: $($_.key) [$($_.ctx)] $(if ($null -ne $_.from) { $_.from } else { 'default' }) -> $(if ($null -ne $_.to) { $_.to } else { 'default' }) ($($_.why))" }) }
# the one writer (supervise -AutoFix, tidy prep): one change a day per key; steps, range, shadow, approve: kit.example.json params._readme
$script:KitUrgent = 'fail', 'newCtx', 'newRule', 'load', 'wake', 'reboot', 'deploy'
function Invoke-ParamLearn([switch]$Due, [datetime]$Deadline = [datetime]::MaxValue) {
  $mode = "$(Get-KitSetting 'params.learning' 'on')"; if ($mode -eq 'off') { return }
  $now = Get-KitNow; $file = Get-KitPath param-state -Create; $flags = [Collections.Generic.List[object]]::new()
  $shadow = [double](Get-KitSetting 'params.shadowDays' 14)
  $flag = { param($l, $w, $a) $flags.Add([pscustomobject]@{ level = $l; what = $w; action = $a }) }
  $enq = { param($k, $c, $why) $qk = "$k|$c"; if ($st.queue[$qk] -isnot [Collections.IDictionary]) { $st.queue[$qk] = @{ at = $now.ToString('o'); why = @() } }; if ($why -notin @($st.queue[$qk].why)) { $st.queue[$qk].why = @(@($st.queue[$qk].why) + $why) } }
  # registry entry changed: relearn from the default
  $respec = { param($e, $sp, $key, $ctx) if ("$($e.spec)" -ne $sp.spec) { if ($e.spec) { foreach ($n in 'rec', 'value', 'hold', 'changed', 'clamp', 'dir', 'why', 'ask') { $e.Remove($n) }; $e.obs = @(); $e.hr = @{}; $e.fresh = 0; & $enq $key $ctx 'newRule'
        $st.history = @(@($st.history | Where-Object { $_ }) + @{ at = $now.ToString('o'); key = $key; ctx = $ctx; from = $null; to = $null; why = 'rule changed: relearn from the default' } | Select-Object -Last 200) }; $e.spec = $sp.spec } }
  Invoke-KitLocked $file {
    $st = Read-KitParams -Strict; foreach ($n in 'byKey', 'pins', 'approved', 'queue') { if ($st[$n] -isnot [Collections.IDictionary]) { $st[$n] = @{} } }
    if ($Due -and $st.lastPass -and ($now - [datetime]$st.lastPass).TotalMinutes -lt 15) { return }
    $since = if ($st.cursor) { [datetime]$st.cursor } else { $now.AddDays(-30) }
    foreach ($o in @(Read-KitLog params $since.AddDays(-1) | Where-Object { $_.event -in 'obs', 'trig' -and [datetime]$_.at -gt $since } | Sort-Object { [datetime]$_.at })) {
      if ((Get-Date) -gt $Deadline) { break }
      $st.cursor = ([datetime]$o.at).ToString('o')
      if ($o.event -eq 'trig') { foreach ($k in @($st.byKey.Keys | Where-Object { $o.key -in '*', $_ })) { foreach ($c in @($st.byKey[$k].Keys | Where-Object { -not $o.ctx -or $_ -eq $o.ctx })) { & $enq $k $c "$($o.why)" } }; continue }
      $sp = Get-KitParamSpec $o.key; if (-not $sp -or $sp.how -eq 'config') { continue }
      $ctx = if ($o.ctx) { "$($o.ctx)" } else { '_' }; if (-not $st.byKey[$o.key]) { $st.byKey[$o.key] = @{} }
      $e = $st.byKey[$o.key][$ctx]; if (-not $e) { $e = $st.byKey[$o.key][$ctx] = @{ since = $st.cursor; obs = @() }; & $enq $o.key $ctx 'newCtx' }
      & $respec $e $sp $o.key $ctx
      if ([double]$o.d) { $e.d = [double]$o.d }
      if ($sp.gate -eq 'accuracy' -and $o.r -eq 'ok' -and [double]$o.v) { $est = if ($null -ne $e.rec) { [double]$e.rec } else { [double]$e.d }; $e.errs = @(@($e.errs) + [math]::Round([math]::Abs($est - [double]$o.v) / [double]$o.v, 3) | Where-Object { $null -ne $_ } | Select-Object -Last 10) }
      Update-KitParamWindow $e $now @($st.cursor, [double]$o.v, "$($o.r)", [double]$(if ($o.w) { $o.w } else { 1 }), "$($o.lb)")
      $e.fresh = [int]$e.fresh + 1; if (-not ($e.fresh % 5)) { & $enq $o.key $ctx 'n:5' }
      $hr = ([datetime]$o.at).ToString('yyyy-MM-ddTHH'); if ($e.lastHour -and $e.lastHour -ne $hr) { & $enq $o.key $ctx 'hourly' }; $e.lastHour = $hr
      if ($o.lb -and $e.lb -and $o.lb -ne $e.lb) { & $enq $o.key $ctx 'load' }; if ($o.lb) { $e.lb = "$($o.lb)" }
      # failure (timeout, oom, short; not a failed build): one safe step now; a timeout-class key moves only by the 10% rule (RFC 6298)
      if ($o.r -in 'timeout', 'oom', 'short' -and [double]$e.d -gt 0) { & $enq $o.key $ctx 'fail'; $e.lastFail = $st.cursor }
      if ($o.r -eq 'timeout' -and $sp.class -eq 'timeout') {
        $okv = [double[]]@($e.obs | Where-Object { $_[2] -eq 'ok' } | ForEach-Object { [double]$_[1] })
        if ($okv.Count -ge 5 -and (Get-KitQuantile $okv 0.99) -lt 0.1 * [double]$o.v) { $e.hangs = [int]$e.hangs + 1 }
      }
      elseif ($o.r -in 'timeout', 'oom', 'short' -and [double]$e.d -gt 0) {
        $cur = if ($null -ne $e.value) { [double]$e.value } else { [double]$e.d }; $dn = $sp.safe -eq 'down'; $f = if ($sp.how -eq 'aimd') { 2 } else { 1.5 }
        $need = switch ($o.r) { 'oom' { 1.2 * [double]$o.v } 'short' { if ($sp.how -ne 'aimd') { $sp.k * [double]$o.v } } default { $null } }
        $t = if ($dn) { [math]::Min($cur / $f, $(if ($null -ne $need) { $need } else { $cur })) } else { [math]::Max($cur * $f, [double]$need) }
        $t = [math]::Round([math]::Min($(if ($sp.ceil) { [double]$sp.ceil } else { 4 * [double]$e.d }), [math]::Max($(if ($sp.floor) { [double]$sp.floor } else { [double]$e.d / 4 }), $t)), 2)
        $e.hold = ([datetime]$st.cursor).AddDays(7).ToString('o'); $e.live = $true; $e.fresh = 0
        if ($t -ne $cur) { $e.rec = $t; $e.changed = $st.cursor; $e.dir = $(if ($dn) { 'down' } else { 'up' }); $e.why = "failure: $($o.r) at $($o.v)" }
      }
    }
    foreach ($key in @($st.byKey.Keys)) {
      $sp = Get-KitParamSpec $key; if (-not $sp -or $sp.how -eq 'config') { continue }
      foreach ($ctx in @($st.byKey[$key].Keys)) {
        $e = $st.byKey[$key][$ctx]; & $respec $e $sp $key $ctx; $d = [double]$e.d; $q = $st.queue["$key|$ctx"]
        if ($d -le 0 -or ($e.frozen -and [datetime]$e.frozen -gt $now)) { $st.queue.Remove("$key|$ctx"); continue }
        $c = if ($e.cad -is [Collections.IDictionary]) { $e.cad } else { @{ min = 60; stable = 0 } }
        $mn = if (@($q.why | Where-Object { $_ -in $script:KitUrgent }).Count) { 15 } else { [double]$c.min }   # an urgent trigger waits 15 min at most
        if (-not (($q -and (-not $e.evalAt -or ($now - [datetime]$e.evalAt).TotalMinutes -ge $mn)) -or -not $c.due -or $now -ge [datetime]$c.due)) { continue }   # debounced to its cadence
        $whys = @(if ($q) { $q.why } else { 'cadence' }); $st.queue.Remove("$key|$ctx"); $e.evalAt = $now.ToString('o'); Update-KitParamWindow $e $now $null
        $lo = if ($sp.floor) { [double]$sp.floor } else { $d / 4 }; $hi = if ($sp.ceil) { [double]$sp.ceil } else { 4 * $d }
        # rollback: 2x the failure rate after a change (2+ failures) -> old value, frozen 7 d
        $fails = { param($xs) @($xs | Where-Object { $_[2] -in 'timeout', 'oom', 'short' }).Count }
        if ($e.changed -and $null -ne $e.value) { $af = @($e.obs | Where-Object { [datetime]$_[0] -gt [datetime]$e.changed }); $bf = @($e.obs | Where-Object { [datetime]$_[0] -le [datetime]$e.changed })
          $ra = if ($af.Count) { (& $fails $af) / $af.Count } else { 0 }; $rb = if ($bf.Count) { (& $fails $bf) / $bf.Count } else { 0 }
          if ($af.Count -ge 5 -and (& $fails $af) -ge 2 -and $ra -gt 2 * $rb) {
            $old = @($st.history | Where-Object { $_.key -eq $key -and $_.ctx -eq $ctx -and "$($_.to)" -eq "$($e.value)" })[-1].from
            $e.rec = $old; $e.why = "rollback: failures $([int](100 * $ra))% after the change vs $([int](100 * $rb))% before"; $e.frozen = $now.AddDays(7).ToString('o'); $whys += 'rollback'
            $c.min = [math]::Min(1440, 4 * [double]$(if ($c.min) { $c.min } else { 60 }))
            & $flag 'WATCH' "param $key [$ctx] rolled back to $(if ($null -ne $old) { $old } else { "default $d" }) ($($e.why)); frozen 7 d" 'Nothing to do unless it repeats (bossy.ps1 param history).' } }
        $cur = if ($null -ne $e.rec) { [double]$e.rec } else { $d }; $r = if ($e.frozen -and [datetime]$e.frozen -gt $now) { $null } else { Get-KitParamRec $sp @(@(Get-KitParamHistory $e) + @($e.obs)) $cur $now $e.changed }
        $moved = $false
        if ($r) {
          foreach ($n in 'n', 'conf', 'p50', 'p90', 'max') { $e[$n] = $(if ($r[$n] -is [double]) { [math]::Round($r[$n], 3) } else { $r[$n] }) }
          if ($r.drift) { $whys += 'drift' }
          $t = [math]::Min($hi, [math]::Max($lo, $r.v)); $e.clamp = $t -ne $r.v
          $up = $t -gt $cur; $risky = $up -eq ($sp.safe -eq 'down'); $f = if ($risky) { $sp.down } else { $sp.up }
          if ((-not $e.changed -or ($now - [datetime]$e.changed).TotalHours -ge 24) -and -not ($risky -and ([int]$e.fresh -lt 5 -or ($e.hold -and [datetime]$e.hold -gt $now)))) {
            $t = [math]::Round($(if ($up) { [math]::Min($cur * (1 + $f), $t) } else { [math]::Max($cur * (1 - $f), $t) }), 2)
            if ($t -ne $cur -and [math]::Abs($t - $cur) -ge 0.99 * $cur * [math]::Min(0.1, $f)) { $e.rec = $t; $e.changed = $now.ToString('o'); $e.why = $r.why; $e.dir = $(if ($up) { 'up' } else { 'down' }); $e.fresh = 0; $moved = $true }   # 10% hysteresis
          }
        }
        $e.byLoad = @{}; foreach ($g in @($e.obs | Where-Object { $_.Count -gt 4 -and $_[4] -and $_[2] -eq 'ok' } | Group-Object { $_[4] })) { $e.byLoad[$g.Name] = @{ n = $g.Count; p90 = [math]::Round((Get-KitQuantile ([double[]]@($g.Group | ForEach-Object { [double]$_[1] })) 0.9), 3) } }   # per load bucket: shown, not applied
        # cadence: an urgent trigger -> the minimum (15); 3 stable passes -> x2 (max 1 d)
        if (@($whys | Where-Object { $_ -in @($script:KitUrgent) + 'drift' }).Count) { $c.min = 15; $c.stable = 0 }
        elseif ($moved) { $c.stable = 0 } elseif ([int]$c.stable -ge 2) { $c.min = [math]::Min(1440, 2 * [double]$c.min); $c.stable = 0 } else { $c.stable = [int]$c.stable + 1 }
        $c.lastTrig = "$($whys -join ',') $($now.ToString('o'))"; $c.due = $now.AddMinutes([double]$c.min).ToString('o'); $e.cad = $c
        $acc = $sp.gate -ne 'accuracy' -or (@($e.errs).Count -ge 10 -and (@($e.errs) | Measure-Object -Average).Average -le 0.2)
        $val = if ($mode -eq 'on' -and $null -ne $e.rec -and $acc -and ($e.live -or (($now - [datetime]$e.since).TotalDays -ge $shadow -and [double]$e.conf -ge 0.5))) { [double]$e.rec } else { $null }
        if ($null -ne $val -and $val -gt 2 * $d -and -not $st.approved["$key|$(if ($ctx -ne '_') { $ctx })"] -and -not $st.approved["$key|"]) {
          if (-not $e.ask) { $e.ask = $now.ToString('o'); & $flag 'WATCH' "param $key [$ctx] learned $val, past 2x its default ${d}: held at $(2 * $d)" "Owner decision (bossy.ps1 decide ask); yes -> bossy.ps1 param approve $key$(if ($ctx -ne '_') { " -Context '$ctx'" })" }
          $val = 2 * $d
        }
        if ("$val" -ne "$($e.value)") {
          $st.history = @(@($st.history | Where-Object { $_ }) + @{ at = $now.ToString('o'); key = $key; ctx = $ctx; from = $e.value; to = $val; why = "$($e.why)" } | Select-Object -Last 200)
          Write-KitParamChange $key $ctx $e.value $val "$($e.why)"; $e.value = $val
        }
      }
    }
    $st.lastPass = $now.ToString('o'); Write-KitAtomic $file ($st | ConvertTo-Json -Depth 8 -Compress)
  }
  $script:KitParamMemo.Clear(); $flags
}
# setup -WriteLocal leaves learned keys out of kit.local.json (a value there pins)
function Add-KitSpendObs($E, [string]$R = 'ok') { $d = $script:KitExample.budget.estimate.([string]$E.type); if ($E.type -and [double]$E.spend -gt 0 -and $null -ne $d) { Add-KitParamObs 'budget.estimate' $E.spend $E.type $R $d } }   # R short: a handoff (the estimate was too low)
function Add-KitActObs($State, [string[]]$Acts, [datetime]$Now, [hashtable]$Sec = @{}, [string[]]$Done = $null) {   # returns the ACT keys new since the last sweep
  # Sec: ACT key -> sweep section; Done: finished sections; an unfinished one (skipped, cut short, off-round) keeps its last ACTs, adds none
  $was = @($State.acts | Where-Object { $_ }); $ps = if ($State.actSec -is [Collections.IDictionary]) { $State.actSec } else { @{} }
  $open = { param($k, $m) $null -ne $Done -and $m[$k] -and $m[$k] -notin $Done }
  $carry = @($was | Where-Object { $_ -notin $Acts -and (& $open $_ $ps) })
  $held = @($Acts | Where-Object { $_ -notin $was -and (& $open $_ $Sec) })   # new from an unfinished section: unseen until it finishes
  $fresh = @($Acts | Where-Object { $_ -notin $was -and $_ -notin $held }); $new = $fresh.Count   # 2+ new ACTs in one sweep: the beat was too long (short)
  # censored: a gap over 2 beats (sleep, stopped coordinator) or a reboot since the last ACT
  $boot = Get-KitBootTime
  $gap = $State.report.at -and ($Now - [datetime]$State.report.at).TotalMinutes -gt 2 * [math]::Max(5, [double]$State.nextBeat)
  if ($gap -or ($State.lastAct -and $boot -gt [datetime]$State.lastAct)) { $State.lastAct = $null }
  if ($new) { if ($State.lastAct) { Add-KitParamObs 'supervise.heartbeatMinutes' ($Now - [datetime]$State.lastAct).TotalMinutes '' $(if ($new -ge 2) { 'short' } else { 'ok' }) 15 }; $State.lastAct = $Now.ToString('o') }
  $State.acts = @($Acts | Where-Object { $_ -notin $held }) + $carry; $State.actSec = @{}
  foreach ($k in $State.acts) { $s = if ($Sec[$k]) { $Sec[$k] } else { $ps[$k] }; if ($s) { $State.actSec[$k] = $s } }; $fresh
}
function Remove-KitLearnedKeys($Cfg) { foreach ($pk in @(Get-KitParamKeys -Learned)) { $o = $Cfg; $pp = $pk -split '\.'; foreach ($x in $pp[0..($pp.Count - 2)]) { $o = $o.$x }; if ($o) { $o.PSObject.Properties.Remove($pp[-1]) } } }
# bossy.ps1 param verbs (audited in history and params-changes.jsonl)
function Invoke-KitParamVerb([string]$Action, [string]$Key, [string]$Value, [string]$Context, [switch]$Json) {
  $st = Read-KitParams; $reg = @(Get-KitParamKeys)
  if ($Action -eq 'history') { $h = @($st.history | Where-Object { -not $Key -or $_.key -eq $Key } | Select-Object -Last 30); if ($Json) { return ConvertTo-Json @($h) -Depth 4 -Compress }; return @($h | ForEach-Object { "$(([datetime]$_.at).ToString('yyyy-MM-dd HH:mm')) $($_.key) [$($_.ctx)] $(if ($null -ne $_.from) { $_.from } else { 'default' }) -> $(if ($null -ne $_.to) { $_.to } else { 'default' }): $($_.why)" }) }
  if ($Action -eq 'show') {
    $hm = { param($t) if ($t) { ([datetime]$t).ToString('MM-dd HH:mm') } }
    $rows = foreach ($k in @($reg | Where-Object { -not $Key -or $_ -eq $Key })) { $sp = Get-KitParamSpec $k
      $cs = @(if ($st.byKey.$k) { $st.byKey.$k.Keys | Where-Object { -not $Context -or $_ -eq $Context } }); if (-not $cs.Count) { $rv = Resolve-KitParam $k $sp.default $Context $st; [pscustomobject]@{ key = $k; ctx = '_'; how = $sp.spec; default = $sp.default; effective = $rv[0]; source = $rv[1]; n = 0; state = $(if ($sp.how -eq 'config') { 'config' } elseif ($rv[1] -like 'pin*') { 'pinned' } else { 'default' }) }; continue }
      foreach ($c in $cs) { $e = $st.byKey.$k[$c]; $rv = Resolve-KitParam $k $e.d $(if ($c -ne '_') { $c }) $st; $q = $st.queue."$k|$c"
        [pscustomobject]@{ key = $k; ctx = $c; how = $sp.spec; default = $e.d; learned = $e.rec; effective = $rv[0]; source = $rv[1]; n = [int]$e.n; conf = $e.conf; p50 = $e.p50; p90 = $e.p90; max = $e.max; clamp = [bool]$e.clamp; changed = $e.changed; dir = $e.dir; why = $e.why; frozen = $e.frozen; nextRisky = @(@($(if ($e.changed) { ([datetime]$e.changed).AddDays(1) }), $(if ($e.hold) { [datetime]$e.hold }), (Get-KitNow)) | Sort-Object)[-1].ToString('o'); obsNeeded = [math]::Max(0, 5 - [int]$e.fresh); shadowLeft = [math]::Max(0, [math]::Ceiling([double](Get-KitSetting 'params.shadowDays' 14) - ((Get-KitNow) - [datetime]$e.since).TotalDays))
          cadence = $e.cad.min; due = $e.cad.due; trigger = $(if ($q) { "queued: $(@($q.why) -join ',')" } else { "$($e.cad.lastTrig)" -replace ' \S+$' }); byLoad = $e.byLoad; loadP90 = @(@($e.byLoad.Keys) | Sort-Object | ForEach-Object { "$_ $($e.byLoad[$_].p90)" }) -join ', '
          state = $(if ($rv[1] -like 'pin*' -or $rv[1] -eq 'env') { 'pinned' } elseif ($e.frozen -and [datetime]$e.frozen -gt (Get-KitNow)) { 'frozen' } elseif ($rv[1] -eq 'learned') { 'live' } elseif ($null -ne $e.rec) { 'shadow' } else { 'default' }) } } }
    if ($Json) { return ConvertTo-Json @($rows) -Depth 4 -Compress }
    $when = if (-not $Key) { @('What learns when (a pass every 15 min; a key is evaluated when due):', '| Trigger | Effect |', '|---|---|', '| fail: timeout, OOM, short | one step to the safe side now; evaluated within 15 min |',
        '| new context or rule, drift, load bucket change, wake, reboot, deploy | evaluated within 15 min; its cadence back to 15 min |', '| an hour of new data, 5 new observations, its cadence due | evaluated (cadence 15 min, x2 per 3 stable passes, max 1 d) |', '| how config | never learned: its default or a kit.local.json pin |', '') }
    return @($when) + @($rows | ForEach-Object { if (-not $_.n -and $null -eq $_.learned) { "$($_.key): $($_.effective) ($($_.source); $($_.state)$(if ($_.how -notmatch '^config') { ", no observations yet: $($_.how)" }))" } else { "$($_.key) [$($_.ctx)]: $($_.effective) ($($_.source)); $($_.state); default $($_.default), learned $(if ($null -ne $_.learned) { $_.learned } else { '-' })$(if ($_.shadowLeft) { ", shadow $($_.shadowLeft) d left" })$(if ($_.n) { "; n $($_.n) conf $($_.conf) p50 $($_.p50) p90 $($_.p90) max $($_.max)" })$(if ($_.clamp) { ' (clamped)' })$(if ($_.frozen) { "; frozen to $(([datetime]$_.frozen).ToString('MM-dd'))" })$(if ($_.changed) { "; last change $(& $hm $_.changed) $($_.dir): $($_.why)" })$(if ($null -ne $_.nextRisky) { "; next risky step from $(& $hm $_.nextRisky)$(if ($_.obsNeeded) { " + $($_.obsNeeded) obs" })" }); cadence $($_.cadence) min, due $(& $hm $_.due), trigger $($_.trigger)$(if ($_.loadP90) { "; p90 by load: $($_.loadP90)" })" } })
  }
  if ($Key -notin $reg) { return "ERROR unknown param '$Key' (skills/bossy/params.registry.json: $($reg -join ', '))" }
  if ($Action -eq 'pin' -and $Value -notmatch '^-?[\d.]+$') { return 'ERROR param pin <key> <number> [-Context <ctx>]' }
  $file = Get-KitPath param-state -Create; $ck = "$Key|$Context"; $cx = if ($Context) { $Context } else { '_' }
  Invoke-KitLocked $file {
    $s = Read-KitParams -Strict; foreach ($n in 'byKey', 'pins', 'approved') { if (-not $s[$n]) { $s[$n] = @{} } }
    $es = @(@(if ($s.byKey[$Key]) { if ($Context) { $s.byKey[$Key][$cx] } else { $s.byKey[$Key].Values } }) | Where-Object { $_ })   # no -Context: every context of the key
    switch ($Action) {
      'pin' { $s.pins[$ck] = @{ value = [double]$Value; at = (Get-KitNow).ToString('o') } }
      'unpin' { $s.pins.Remove($ck) }
      'approve' { $s.approved[$ck] = (Get-KitNow).ToString('o'); foreach ($e in $es) { $e.ask = $null } }
      'freeze' { foreach ($e in $es) { $e.frozen = (Get-KitNow).AddYears(10).ToString('o') } }
      'reset' { if ($s.byKey[$Key]) { if ($Context) { $s.byKey[$Key].Remove($cx) } else { $s.byKey.Remove($Key) } } }
    }
    foreach ($e in $es) { $e.evalAt = $null; if ($e.cad -is [Collections.IDictionary]) { $e.cad.due = $null } }   # an owner's verb: evaluated at the next pass
    $why = "$Action by $((Get-KitWho).agent)"; $to = $(if ($Action -eq 'pin') { [double]$Value })
    $s.history = @(@($s.history | Where-Object { $_ }) + @{ at = (Get-KitNow).ToString('o'); key = $Key; ctx = $cx; from = $null; to = $to; why = $why } | Select-Object -Last 200)
    Write-KitAtomic $file ($s | ConvertTo-Json -Depth 8 -Compress); Write-KitParamChange $Key $cx $null $to $why
  }
  "param $Key$(if ($Context) { " [$Context]" }): $Action$(if ($Action -eq 'pin') { " $Value" }) done"
}
# lines older than logs.keepDays (2 x the longest retro gap, >= 30 d) roll into logs-summary.jsonl per stream and month; retired
# lessons stay raw (tidy compares against them); one shared handle keeps lines appended meanwhile
$script:KitLogTrim = @{ 'signals' = @('skill', 'kind', 'text'); 'decisions-log' = @('event', 'agent', 'question'); 'deploy-log' = @('event', 'target', 'note') }
function Invoke-KitLogTrim([switch]$DryRun, [datetime]$Now = (Get-KitNow)) {
  $rs = Get-KitPath last-retro; if (-not $DryRun -and (Test-Path -LiteralPath $rs)) { try { Add-KitParamObs 'logs.keepDays' ($Now - [datetime](Get-Content -LiteralPath $rs -Raw).Trim()).TotalDays 'signals' } catch {} }
  $sumF = Get-KitPath logs-summary -Create; $seen = @{}; foreach ($l in @(Get-Content -LiteralPath $sumF -ErrorAction SilentlyContinue)) { $o = try { $l | ConvertFrom-Json } catch { $null }; if ($o) { $seen["$($o.stream)|$($o.period)|$($o.from)|$($o.to)|$($o.n)"] = 1 } }
  foreach ($sn in @($script:KitLogTrim.Keys | Sort-Object)) {
    $f = Get-KitPath $sn; if (-not (Test-Path -LiteralPath $f)) { continue }
    $by = $script:KitLogTrim[$sn]; $cut = $Now.AddDays(-[double](Get-KitParam 'logs.keepDays' $null $sn)); $old = [Collections.Generic.List[object]]::new(); $keep = [Collections.Generic.List[string]]::new()
    Invoke-KitLocked $f {
      $fs = [IO.FileStream]::new($f, 'Open', 'ReadWrite', 'ReadWrite, Delete'); $enc = [Text.UTF8Encoding]::new($false)
      try {
        $sr = [IO.StreamReader]::new($fs, $enc, $true, 65536, $true); $raw = $sr.ReadToEnd()
        foreach ($l in @($raw -split "`r?`n" | Where-Object { $_ })) { $o = try { $l | ConvertFrom-Json } catch { $null }
          if (-not $o.at -or [datetime]$o.at -ge $cut -or ($sn -eq 'signals' -and $o.kind -eq 'retired')) { $keep.Add($l) } else { $old.Add($o) } }
        if ($DryRun -or -not $old.Count) { return }
        foreach ($g in @($old | Group-Object { ([datetime]$_.at).ToString('yyyy-MM') })) {
          $cnt = [ordered]@{}; foreach ($x in $g.Group) { $kk = "$($x.($by[0]))$(if ($x.($by[1])) { "/$($x.($by[1]))" })"; $cnt[$kk] = [int]$cnt[$kk] + 1 }
          $facts = @($g.Group | Where-Object { "$($_.($by[2]))" } | Group-Object { "$($_.($by[2]))" } | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { $t = $_.Name; "$($_.Count)x $($t.Substring(0, [math]::Min(160, $t.Length)))" })
          $ats = @($g.Group | ForEach-Object { [datetime]$_.at } | Sort-Object); $from = $ats[0].ToString('o'); $to = $ats[-1].ToString('o')
          if (-not $seen["$sn|$($g.Name)|$from|$to|$($g.Count)"]) { Write-KitLog logs-summary summary ([ordered]@{ at = $Now.ToString('o'); stream = $sn; period = $g.Name; n = $g.Count; from = $from; to = $to; by = $cnt; facts = $facts }) }
        }
        $tail = $sr.ReadToEnd()   # appended since the first read: kept
        $b = $enc.GetBytes((@($keep) + @($tail -split "`r?`n" | Where-Object { $_ }) | ForEach-Object { "$_`n" }) -join '')
        $fs.Position = 0; $fs.Write($b, 0, $b.Length); $fs.SetLength($b.Length); $fs.Flush()
      } finally { $fs.Dispose() }
    }
    if ($old.Count) { [pscustomobject]@{ stream = $sn; rolled = $old.Count; kept = $keep.Count; days = [math]::Round(($Now - $cut).TotalDays) } }
  }
}
# ---- entry-scripts: one per area
$KitCmd = [pscustomobject]@{
  dev = Join-Path $KitConf.Kit 'skills/crafty/crafty.ps1'
  devtools = Join-Path $KitConf.Kit 'skills/crafty/devtools.py'
  spec     = Join-Path $KitConf.Kit 'skills/crafty/spec.mjs'
  qa       = Join-Path $KitConf.Kit 'skills/pokey/pokey.ps1'
  browser  = Join-Path $KitConf.Kit 'skills/pokey/browser.mjs'
  swarm    = Join-Path $KitConf.Kit 'skills/phoney/phoney.ps1'
  local    = Join-Path $KitConf.Kit 'skills/envy/envy.ps1'
  orch     = Join-Path $KitConf.Kit 'skills/bossy/bossy.ps1'
  kitbag  = Join-Path $KitConf.Kit 'skills/bossy/kitbag.py'
}
# a configured adapter no installed goody brings: installed on demand, then loaded
$__hostSet = (Get-KitValue 'gitHostType' '') -or (Get-KitValue 'gitHost' '') -or @(Get-KitValue 'repos' @()).Count   # no host configured: no git-host goody to fetch
foreach ($__need in @(@('tracker', $script:__trType), @('git-host', $(if ($__hostSet) { $script:HostType })), @('ci', ([string](Get-KitSetting 'ci.type' '')).ToLower()))) {
  if (-not $__need[1] -or $__need[1] -in 'host', 'none' -or $KitAdapters[$__need[0]][$__need[1]] -or "$script:__verb" -match '^(guard|guard-sendmessage|health)$') { continue }   # hooks stay fast
  if (Install-KitExtra (Get-KitExtraName $__need[0] $__need[1])) {
    foreach ($__plugin in @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName | Where-Object { $_ -notin $script:KitAdapterFiles })) { . $__plugin; $script:KitAdapterFiles += $__plugin }
  }
}
Add-KitExtraUse $script:KitEntry   # a goody's entry script (envy.ps1, phoney.ps1) in use
