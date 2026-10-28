<#
Kit library (config, paths, OS, tracker + git-host adapters). Usage (pwsh 7): every kit script dot-sources it once:
 . (Join-Path <kit> 'skills/crafty/lib.ps1')
Functions only, silent. In: kit.local.json, kit.example.json (_paths), env KIT_* / CLAUDE_*. Exit codes: none.
Out: $KitConf, $KitCmd (entry scripts), Get-KitPath, Get-KitSetting, tracker verbs, Invoke-HostVerb, OS helpers.
Sections: L10 paths · L98 config · L178 OS · L350 leases · L733 status · L910 tracker · L1145 git-host · L1261 kitlog ·
  L1373 params · L1536 entry-scripts
#>
#Requires -Version 7
# ---- paths: kit.example.json _paths
$script:KitRoot = Split-Path (Split-Path $PSScriptRoot)
$script:KitEntry = $MyInvocation.PSCommandPath   # the script that dot-sourced this file (Resolve-KitExtra runs it again)
$script:KitExample = Get-Content (Join-Path $PSScriptRoot 'kit.example.json') -Raw | ConvertFrom-Json; $script:KitPathMap = $script:KitExample._paths
function Get-KitRuntime { if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path $script:KitRoot $script:KitPathMap.runtimeDir } }
function Get-KitPath([Parameter(Mandatory)][string]$Name, [switch]$Create) {
  $m = $script:KitPathMap
  if ($Name -eq 'runtime') { $p = Get-KitRuntime; $dir = $true }
  elseif ($m.runtime.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.runtime.$Name; $p = Join-Path (Get-KitRuntime) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  elseif ($m.durable.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.durable.$Name; $p = Join-Path (Join-Path $script:KitRoot $m.stateDir) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  else { throw "Get-KitPath: unknown name '$Name' (see skills/crafty/kit.example.json _paths)" }
  if ($Create) { New-Item -ItemType Directory -Force $(if ($dir) { $p } else { Split-Path $p }) | Out-Null }
  $p
}
# cross-process <file>.lock, stale after 2 min (Windows: at once once its holder is gone, e.g. killed); 130 s wait -> throw (never unlocked)
function Invoke-KitLocked([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body) {
  $lock = "$File.lock"; $fs = $null
  for ($i = 0; $i -lt 1300 -and -not $fs; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch {
      # .NET, not Remove-Item: a lock its holder deletes in between made Remove-Item throw despite SilentlyContinue
      try { if ([IO.File]::Exists($lock) -and ($KitIsWindows -or ((Get-Date) - [IO.File]::GetLastWriteTime($lock)).TotalMinutes -gt 2)) { [IO.File]::Delete($lock) } } catch {}   # a live holder keeps it open: the delete fails
      Start-Sleep -Milliseconds 100
    }
  }
  # warn + return too: SilentlyContinue ignores a throw
  if (-not $fs) { $m = "Invoke-KitLocked: $lock still held after 130 s - not writing $File"; Write-Warning $m; throw $m; return }
  try { & $Body } finally { $fs.Dispose(); try { [IO.File]::Delete($lock) } catch {} }
}
# temp + rename in the same folder: a crash leaves the old file or the new one, never half of one; a reader holding it: retried
function Write-KitAtomic([Parameter(Mandatory)][string]$Path, [string]$Text) {
  $p = [IO.Path]::GetFullPath($Path, (Get-Location -PSProvider FileSystem).ProviderPath); $t = "$p.$PID.tmp"
  [IO.File]::WriteAllText($t, $Text, [Text.UTF8Encoding]::new($false))
  for ($i = 0; ; $i++) {
    try { [IO.File]::Move($t, $p, $true); return }
    catch {
      # Win32 87 "The parameter is incorrect" never clears on a retry (board join failed twice): copy over (not atomic), drop the temp
      if (Test-KitMoveUnsupported $_.Exception) { try { [IO.File]::Copy($t, $p, $true) } finally { [IO.File]::Delete($t) }; return }
      if ($i -ge 40) { [IO.File]::Delete($t); throw }; Start-Sleep -Milliseconds 50
    }
  }
}
# a rename the file system refuses outright (ArgumentException, Win32 87), not a reader holding the file (sharing, access: retried)
function Test-KitMoveUnsupported([Exception]$Err) {
  for ($e = $Err; $e; $e = $e.InnerException) {
    if ($e -is [ArgumentException] -or ($e.HResult -band 0xFFFF) -eq 87) { return $true }
    if ($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) { return $false }
  }
  $false
}
# names the kit makes (crafty.ps1 dir, briefs, checkpoints, snapshots): lowercase-kebab
function ConvertTo-KitSlug([string]$Text) { ("$Text".ToLower() -replace '[^a-z0-9.]+', '-').Trim('-.') }
# -Strict: bad JSON -> <file>.bad-<time> + throw (never {} over all tasks)
function Read-KitTracking([switch]$Strict) {
  $f = Get-KitPath tracking; $t = $null
  if (Test-Path $f) {
    try { $t = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable }
    catch {
      if ($Strict) { $bak = "$f.bad-$(Get-Date -Format yyyyMMddHHmmss)"; Copy-Item $f $bak -Force; $m = "tracking: $f is not valid JSON (copy: $bak) - fix or remove it; not writing: $_"; Write-Warning $m; throw $m; return $null }
      Write-Warning "tracking: $f is not valid JSON ($_)"
    }
  }
  if ($t -isnot [hashtable]) { $t = @{} }
  if ($t.tasks -isnot [hashtable]) { $t.tasks = @{} }
  if ($t.automerge -isnot [hashtable]) { $t.automerge = @{} }
  $t
}
function Update-KitTracking([Parameter(Mandatory)][scriptblock]$Change) {
  $f = Get-KitPath tracking -Create
  Invoke-KitLocked $f {
    $t = Read-KitTracking -Strict
    if ($t -isnot [hashtable]) { return }
    & $Change $t
    $t.version = 1
    $t | ConvertTo-Json -Depth 8 | Set-Content "$f.tmp" -Encoding utf8
    Move-Item "$f.tmp" $f -Force
  }
}
# a task deleted in the tracker (404 + "task not found"; never an outage page or a missing CLI): tracking drops it, the entry
# goes to the calls log, $true
function Remove-KitGoneTask([string]$Id, $Err) {
  if ("$Err" -notmatch '(?is)(?=.*\b404\b)(?=.*\b(task|issue|item|ticket)\b[^.]{0,30}\b(not found|does not exist|deleted)\b)|could not resolve to an? issue') { return $false }
  Update-KitTracking { param($t) Write-KitLog calls task-gone @{ task = $Id; error = "$Err"; entry = $t.tasks[$Id] }; $t.tasks.Remove($Id) }; $true
}
function Set-KitTaskFields([Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][hashtable]$Fields) {
  Update-KitTracking { param($t) if ($t.tasks[$Task]) { foreach ($k in $Fields.Keys) { $t.tasks[$Task][$k] = $Fields[$k] } } }
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
  Get-KitMemo $global:KitFetched $key 600 {
    $a = @('-C', $Dir, 'fetch', '-q', '--prune', 'origin') + @($Refs | Where-Object { $_ })
    $r = Invoke-KitExe git $a $TimeoutSec
    if ($r.timedOut) { Write-Warning "git fetch in $Dir timed out after $TimeoutSec s (skipped)" }
    elseif ($r.code) { Write-Warning "git fetch in $Dir failed (exit $($r.code)): $("$($r.err)".Trim() -split "`n" | Select-Object -Last 1)" }
    [bool](-not $r.timedOut -and $r.code -eq 0)
  }
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
# RAM every build, phone and QA seat leaves free: env, gate.keepFreeGB, else 15% of RAM (at least 6 GB)
function Get-KitKeepFreeGB {
  if ($env:CLAUDE_GATE_KEEP_FREE_GB) { return [double]$env:CLAUDE_GATE_KEEP_FREE_GB }
  [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15))))
}
# the system file cache stays resident until something needs RAM, which a gate never allows: half of it counts (crafty.ps1 gate, local env)
function Get-GateAvailGB($Mem) { [math]::Round([double]$Mem.AvailGB + 0.5 * [double]$Mem.CacheGB, 1) }
# the disk rescue's hold on a drive with kit paths (bossy.ps1 storage): new builds wait (crafty.ps1 gate; goodies may check it too), storage.holdMinutes
function Get-KitDiskHold { $hs = try { (Get-Content -LiteralPath (Join-Path (Get-KitPath storage) 'state.json') -Raw -ErrorAction Stop | ConvertFrom-Json).rescues } catch { $null }; @($hs.PSObject.Properties.Value | Where-Object { $_.kit -and ((Get-Date) - [datetime]$_.at).TotalMinutes -lt [double](Get-KitSetting 'storage.holdMinutes' 60) })[0] }
# a start that waited 20 min goes when it still leaves a hard floor (5% of RAM, at least 3 GB)
function Test-GateStart([double]$Left, [double]$KeepFree, [double]$WaitedMin, [double]$TotalGB) {
  $Left -ge $KeepFree -or ($WaitedMin -ge 20 -and $Left -ge [math]::Max(3, $TotalGB * 0.05))
}
# one process snapshot (working set, children, name per pid) for many Get-KitTreeGB calls
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
function Add-KitMemSample([double]$Free) { try { $f = Get-KitPath mem-samples -Create; if (-not (Test-Path $f) -or ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -ge 60) { Add-Content $f "$((Get-Date).ToString('s'))`t$([math]::Round($Free, 1))" } } catch {} }
function Get-KitSpend([string]$File) {
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $null }
  $t = @(Get-Content -LiteralPath $File -Tail 300)
  for ($i = $t.Count - 1; $i -ge 0; $i--) {
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
function Get-KitPidStart([int]$Id) { try { (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { '' } }
# the same process only with the same start time: a cold boot reuses pids. $Start untyped: JSON gives a DateTime
function Test-KitPid($Id, $Start) {
  $p = if ($Id) { Get-Process -Id ([int]$Id) -ErrorAction SilentlyContinue }; if (-not $p) { return $false }
  if ($Start) { try { return [math]::Abs(([datetimeoffset]$p.StartTime - [datetimeoffset]$Start).TotalSeconds) -lt 2 } catch {} }
  $true
}
function Test-KitHolder($o) { if (-not $o -or -not $o.holderPid) { return $null }; Test-KitPid $o.holderPid $o.holderStart }
# ---- leases: liveness leases (README "Leases"), ONE rule for env services, test browsers, phones, builds
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
  $now = Get-Date; $bm = [double](Get-KitSetting 'idle.beatMinutes' 20); $a = "$($l.agent)"
  if ($l.owner -or ($l.until -and -not $a -and -not $l.holderPid)) { return [datetime]$l.until -gt $now }   # a pre-lease hold keeps its minutes
  if ($l.pid -and (Test-KitPid $l.pid $l.pidStart)) { return $true }
  $ls = Get-KitLiveCached steps { try { $s = Get-Content (Get-KitPath live-steps) -Raw | ConvertFrom-Json; if (((Get-Date) - [datetime]$s.at).TotalMinutes -lt $bm) { $s } } catch {} }
  $mine = @($ls.labels | Where-Object { ($a -and (($_ -split ':', 2)[-1] -split '@')[0] -eq $a) -or ($l.lane -and $_ -match "@$([regex]::Escape($l.lane))$") })
  if (@($mine | Where-Object { $_ -in @($ls.running) }).Count) { return $true }
  $all = @(Get-KitLiveCached board { @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} }) } |
    Where-Object { if ($l.session) { $_.session -eq $l.session } else { ($_.agent -and $_.agent -in @($a, $l.holder)) -or ($l.holder -and $_.session -eq $l.holder) } })
  if (@($all | Where-Object { $_.status -ne 'left' -and (($now - [datetime]$_.beat).TotalMinutes -lt $bm -or ($_.pid -and (Test-KitPid $_.pid $_.pidStart))) }).Count) { return $true }
  if ($mine.Count -or $l.session) { return $false }   # its step finished / its board entry left or went quiet
  if ($a -match '^(main|coordinator)$') { $f = Get-Item (Get-KitPath supervise-state) -ErrorAction SilentlyContinue; if ($f -and ($now - $f.LastWriteTime).TotalMinutes -lt [math]::Max($bm, (Get-KitBeatMinutes) + 5)) { return $true } }   # its heartbeat writes it
  if ($all.Count -and -not @($all | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 3 * $bm }).Count) { return $false }   # left / long quiet: its holder pid is the shared session process (a subagent)
  (Test-KitHolder $l) -eq $true
}
# the coordinator's heartbeat interval now (min): the NEXT its last supervise printed, else supervise.heartbeatMinutes (15)
function Get-KitBeatMinutes {   # a NEXT older than 2 beats (the coordinator stopped) falls back to the base
  $s = try { Get-Content (Get-KitPath supervise-state) -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  if ($s.nextBeat -and $s.report.at -and ((Get-Date) - [datetime]$s.report.at).TotalMinutes -lt 2 * [double]$s.nextBeat) { [double]$s.nextBeat } else { [double](Get-KitParam 'supervise.heartbeatMinutes' 15) }
}
function Update-KitLease($l) {
  $now = Get-Date
  if (Test-KitLive $l) {   # seen once a minute: a state that only re-confirms a live holder stays unchanged (no rewrite)
    if ($null -ne $l.graceLeft -and $l.seen) { Add-KitParamObs 'idle.graceMinutes' ($now - [datetime]$l.seen).TotalMinutes -Default 10 }   # quiet, then alive again: how long a live holder goes silent
    if (-not $l.seen -or ($now - [datetime]$l.seen).TotalSeconds -ge 60) { Set-KitProp $l seen $now.ToString('o') }
    if ($null -ne $l.graceLeft) { Set-KitProp $l graceLeft $null; Set-KitProp $l graceMin $null; Set-KitProp $l released $null }; return $true
  }
  if ($l.owner -or ($l.until -and -not $l.agent -and -not $l.holderPid)) { return $false }
  if (-not $l.seen) { Set-KitProp $l seen $now.ToString('o') }   # first seen dead: the grace starts now
  if ($null -eq $l.graceMin) { Set-KitProp $l graceMin ([double](Get-KitParam 'idle.graceMinutes' 10)) }   # read once: a running grace keeps its value
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
# the same agent leasing again within 3 graces of a release by grace: it was alive, the grace too short (failure signal), counted once
function Test-KitLeaseBack([string]$Agent) {
  $r = if ($Agent) { (Read-KitParams).released.$Agent }; if (-not $r) { return }; $now = Get-KitNow; $gap = ($now - [datetime]$r.at).TotalMinutes
  if ($gap -le 3 * [double]$r.grace) { Add-KitParamObs 'idle.graceMinutes' ([double]$r.quiet + $gap) '' 'short' 10 }
  Set-KitLeaseReleased $Agent $null
}
# leases.jsonl: one line per acquire / release / reclaim / down of any held resource; past $KitLeaseLogMax keeps its newest half.
# KIT_LEASE_REASON: the caller's reason (bossy.ps1 release, the reaper); a release whose reason starts with "reclaim" logs as reclaim
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
# the GPU: one exclusive resource for the kinds in gpu.exclusive (e.g. emulator lanes); holders of one kind
# share it, another kind waits. A holder = a lease bound to a process, or a running process matching <kind>.processes
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
# GPU users from nvidia-smi: @{ usedMB; freeMB; procs = @(@{ pid; name; mb }) } (KIT_GPU_PROBE: a JSON file of that shape, null = no
# nvidia-smi; tests) · $null unknown. procs from the process table: --query-compute-apps omits graphics (G) users such as emulators
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
# a kind with idleExcept (regex of its own backend's process names): any other GPU process, or idleMaxMB (512) used while its backend
# is not running, blocks it (a job that needs the whole GPU)
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
# $true held (a kind gpu.exclusive does not list and no -MinFreeMB: always) · $false still held by another kind or GPU user after
# WaitMinutes ($script:KitGpuRefused = that blocker). -MinFreeMB: the caller's default for gpu.exclusive.<kind>.minFreeMB (0 = off);
# under it the caller waits like for a holder, also for a kind gpu.exclusive does not list (no lease kept then)
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
# -Holder: every lease of that holder (bossy.ps1 release), else the leases of -ProcessId
function Remove-KitGpu([int]$ProcessId = $PID, [string]$Holder) {
  $f = Get-KitGpuFile; if (-not (Test-Path $f)) { return }
  $mine = { param($x) if ($Holder) { $x.holder -eq $Holder } else { $x.pid -eq $ProcessId } }
  $gone = Invoke-KitLocked $f { $st = Get-KitGpuState; $g = @($st.leases | Where-Object { & $mine $_ }); $st.leases = @($st.leases | Where-Object { -not (& $mine $_) }); $st.waiting = @($st.waiting | Where-Object { -not (& $mine $_) }); Save-KitGpuState $f $st; $g }
  foreach ($g in @($gone)) { Write-KitLeaseLog release gpu $g.kind @{ agent = $g.holder; at = $g.at } }
}
# bossy.ps1 supervise: who holds the GPU, who waits for it; -AutoFix writes out (and logs) the leases of ended processes
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
function Get-KitNetTimeout([string]$Cli = '') { if ($env:KIT_NET_TIMEOUT_SEC) { [int]$env:KIT_NET_TIMEOUT_SEC } else { [int](Get-KitParam 'net.timeoutSec' 60 $Cli) } }
# one network CLI call, timed per CLI for net.timeoutSec (a timeout counts only under the learned value, not a caller's own cap)
function Invoke-KitNetExe([string]$Exe, [string[]]$A) {
  $cli = [IO.Path]::GetFileNameWithoutExtension($Exe).ToLower(); $t = Get-KitNetTimeout $cli; $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-KitExe $Exe $A $t
  if (-not $r.timedOut -and $r.code -ne 127) { Add-KitParamObs 'net.timeoutSec' $sw.Elapsed.TotalSeconds $cli -Default 60 } elseif ($r.timedOut -and -not $env:KIT_NET_TIMEOUT_SEC) { Add-KitParamObs 'net.timeoutSec' $t $cli 'timeout' 60 }
  $r
}
function Wait-KitPoll([int]$Seconds) { Start-Sleep -Milliseconds $(if ($env:KIT_POLL_MS) { [int]$env:KIT_POLL_MS } else { 1000 * $Seconds }) }   # KIT_POLL_MS: the tests' fake clock
function Invoke-KitRetry([scriptblock]$Call, [int]$Tries = $(if ($env:KIT_NET_TRIES) { [int]$env:KIT_NET_TRIES } else { 3 }), [switch]$Connect) {
  $delay = 2
  for ($i = 1; ; $i++) {
    $r = & $Call
    if ($r.code -eq 0 -or $i -ge $Tries -or -not (($r.timedOut -and -not $Connect) -or (Test-KitTransient "$($r.err) $($r.out)" -Connect:$Connect))) { return $r }
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
# ----- goodies (kitbag.py goody add <name>): adapters a config names but the kit does not ship; the files land in skills/crafty/adapters/
$script:KitExtraOf = @{ 'tracker/jira-server' = 'tracker-jira'; 'git-host/bitbucket' = 'bitbucket'; 'ci/bitbucket' = 'bitbucket'
  'tracker/gitlab' = 'gitlab'; 'git-host/gitlab' = 'gitlab'; 'ci/gitlab' = 'gitlab'
  'tracker/github' = 'github'; 'git-host/github' = 'github'; 'ci/github' = 'github'
  'git-host/azure' = 'azure-devops'; 'ci/azure' = 'azure-devops'; 'git-host/gitea' = 'gitea'; 'ci/gitea' = 'gitea' }
function Get-KitExtraName([string]$Kind, [string]$Name) { if ($script:KitExtraOf["$Kind/$Name"]) { $script:KitExtraOf["$Kind/$Name"] } else { "$Kind-$Name" } }
function Get-KitExtraLine([string]$Kind, [string]$Name) { "$Kind $Name is a goody: run kitbag.py goody add $(Get-KitExtraName $Kind $Name)" }
# on demand: `kitbag.py goody add <name> --auto` (unlisted: goody prune drops it once unused); KIT_EXTRA_AUTO=0 never; a failed try waits 1 h
function Install-KitExtra([string]$Name) {
  if (-not $Name -or $env:KIT_EXTRA_AUTO -eq '0' -or -not (Test-Path -LiteralPath $KitCmd.kitbag)) { return $false }
  $try = Join-Path (Get-KitPath extras-used -Create) "_try-$Name"
  if ((Test-Path -LiteralPath $try) -and ((Get-Date) - [IO.File]::GetLastWriteTime($try)).TotalMinutes -lt 60) { return $false }   # TODO-PARAM (fixed default)
  $r = Invoke-KitExe (Get-Python) @('-X', 'utf8', $KitCmd.kitbag, 'goody', 'add', $Name, '--auto') 180   # kitbag's lock serializes two installers
  Write-KitLog calls extra-auto @{ extra = $Name; code = $r.code }
  if ($r.code) { [IO.File]::WriteAllText($try, ''); Write-Warning "goody ${Name}: install on demand failed ($(@("$($r.err)$($r.out)" -split "`n" | Where-Object { $_.Trim() })[0]))"; return $false }
  [Console]::Error.WriteLine("goody ${Name}: installed on demand"); $true
}
# at a verb's start (nothing ran yet): install the goody and run the entry script's verb again, once; returns only when it could not
function Resolve-KitExtra([string]$Name) {
  if (-not $script:KitEntry -or $env:KIT_EXTRA_RETRY -eq $Name -or -not (Install-KitExtra $Name)) { return }
  $env:KIT_EXTRA_RETRY = $Name
  $again = @(@($script:__verb | Where-Object { $_ }) + @($script:__rest))   # a variable: @(...) inline would pass one array
  # each line to the host as it comes: callers capture this function's output ($null = Assert-KitExtra ...)
  try { & $script:KitEntry @again | ForEach-Object { Write-Host $(if ($_ -is [string]) { $_ } else { ($_ | Out-String).TrimEnd() }) }; $code = $LASTEXITCODE } finally { $env:KIT_EXTRA_RETRY = $null }
  exit $code
}
# a usage stamp per loaded goody file (<state>/extras-used/<kit path>, `/` -> `__`), touched once a day; kitbag.py goody prune reads it
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
# /tidy prep's local goodies cleanup: kitbag.py goody prune; -Days unset: the learned goodies.pruneDays (Get-KitParam), else 30
function Invoke-ExtrasPrune([double]$Days = 0, [switch]$DryRun) {
  $gp = Get-Command Get-KitParam -ErrorAction SilentlyContinue   # the learned-parameter framework, when installed
  if (-not $Days) { $Days = if ($gp) { try { [double](& $gp 'goodies.pruneDays' 30) } catch { 30 } } else { 30 } }   # TODO-PARAM (fixed default)
  $pa = @('-X', 'utf8', $KitCmd.kitbag, 'goody', 'prune', '--days', "$Days") + @(if ($DryRun) { '--dry-run' })
  & (Get-Python) @pa   # exit code in $LASTEXITCODE
}

# ---- status: one row per agent and workflow run from files only (board, journals, transcripts, decide, pauses, waits); no LLM, no network
# workflow run folders (<Claude project dir>/<session>/subagents/workflows/<run>) of every session, or of one
function Get-KitWorkflowDirs([string]$Session) {
  Get-ChildItem $(if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }) -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents/workflows') -Directory -ErrorAction SilentlyContinue }
}
# every parsed *.json of a state folder, each with its path in .file; a broken file is skipped
function Read-KitJsonFiles([string]$Dir, [string]$Filter = '*.json') {
  if (-not $Dir) { return }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue)) {
    $o = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }
    if ($o) { $o | Add-Member -Force NoteProperty file $f.FullName; $o }
  }
}
# agents of a journal still running: no result, no later finished start of the same item (a 529-dead agent writes no result),
# no later restart of the same label
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
# a transcript's tail only (they reach MBs): the last 512 KB, newest line first, only lines matching $Want parsed; $Each sets the
# fields (tool, what <= 1 line, ended, killed, version) and returns $true when it has all it needs; an unknown record sets nothing
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
# adapter:transcript/claude: <project dir>/<session>/subagents/**/agent-*.jsonl, a line per tool call and result; background task
# *.output files it names count as progress
Register-KitAdapter 'transcript' 'claude' @{
  'root' = { @{ dir = $(if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }); filter = '*.jsonl' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file '"tool_use"' { param($o, $s) $u = @($o.message.content | Where-Object { $_.type -eq 'tool_use' })[-1]
      if ($u) { $s.tool = "$($u.name)"; $s.what = "$($u.input.description)" }; [bool]$u }
    if (-not $s) { return }; if ($s.raw -match '"version":"([^"]+)"') { $s.version = "claude $($Matches[1])" }
    $outs = foreach ($m in [regex]::Matches($s.raw, 'tasks(?:\\\\|/)\w+\.output')) { $i = $s.raw.LastIndexOfAny([char[]]'"<> ', $m.Index) + 1; $s.raw.Substring($i, $m.Index + $m.Length - $i) -replace '\\\\', '\' }   # back to the path's start: a forward regex backtracks for seconds
    foreach ($o in @($outs | Select-Object -Unique)) { $f = Get-Item -LiteralPath $o -ErrorAction SilentlyContinue; if ($f -and $f.LastWriteTime -gt $s.at) { $s.at = $f.LastWriteTime } }
    $s }
}
# adapter:transcript/codex: $CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl {timestamp, type, payload}; line 1 session_meta (cli_version);
# the newest turn marker: task_complete = its turn ended
Register-KitAdapter 'transcript' 'codex' @{
  'root' = { @{ dir = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }) 'sessions'; filter = 'rollout-*.jsonl' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file 'function_call"|task_started|task_complete' { param($o, $s) $p = $o.payload
      if (-not $s.tool -and $o.type -eq 'response_item' -and $p.type -eq 'function_call') { $s.tool = "$($p.name)"; $g = try { "$($p.arguments)" | ConvertFrom-Json } catch { $null }; $s.what = "$(if ($g.cmd) { $g.cmd } else { $g.command })" }
      elseif ($null -eq $s.ended -and $o.type -eq 'event_msg' -and $p.type -in 'task_started', 'task_complete') { $s.ended = $p.type -eq 'task_complete' }
      $s.tool -and $null -ne $s.ended }
    if ($s) { $m = try { Get-Content -LiteralPath $s.file -TotalCount 1 | ConvertFrom-Json } catch { $null }; if ($m.payload.cli_version) { $s.version = "codex $($m.payload.cli_version)" } }; $s }
}
# adapter:transcript/antigravity: brain/<id>/.system_generated/logs/transcript.jsonl {step_index, type, status, tool_calls[{name, args}]};
# the parent's brain/<parent>/.system_generated/subagents/<id>.json state SUBAGENT_STATE_KILLED = killed
Register-KitAdapter 'transcript' 'antigravity' @{
  'root' = { @{ dir = Join-Path $HOME '.gemini/antigravity-cli/brain'; filter = 'transcript.jsonl' } }
  'last' = { param($a) $s = Read-KitTranscriptTail $a.file '"tool_calls"' { param($o, $s) $c = @($o.tool_calls)[-1]; if ($c.name) { $s.tool = "$($c.name)"; $s.what = "$($c.args.toolSummary)" }; [bool]$c.name }
    if ($s) { $id = Split-Path (Split-Path (Split-Path (Split-Path $s.file))) -Leaf; $brain = Split-Path (Split-Path (Split-Path (Split-Path $s.file)))
      $k = @(Get-Item -Force -Path (Join-Path $brain "*/.system_generated/subagents/$id.json") -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} })[0]
      $s.killed = "$($k.state)" -eq 'SUBAGENT_STATE_KILLED' }; $s }
}
# adapter:transcript/none: no transcript (another tool): board and journal only
Register-KitAdapter 'transcript' 'none' @{ 'root' = { $null }; 'last' = { $null } }
# adapter-end:transcript
function Get-KitTranscriptKind([string]$Tool) { if (-not $Tool) { 'claude' } elseif ($KitAdapters.transcript[$Tool]) { $Tool } else { 'none' } }
# first rule that holds: STOPPED (crashed, error, killed, session gone) · FINISHED (left, a journal result, turn complete) · WAITING
# (a named wait) · ACTIVE (progress within $StuckMin) · STUCK; then the since and next cells of that state
function Set-KitStatusState($R, [datetime]$Now, [double]$StuckMin) {
  $s = if ($R.stopped) { 'STOPPED' } elseif ($R.done) { 'FINISHED' } elseif ($R.wait) { 'WAITING' } elseif ($R.last -and ($Now - [datetime]$R.last).TotalMinutes -lt $StuckMin) { 'ACTIVE' } else { 'STUCK' }
  $rc = "bossy.ps1 recover$(if ($R.run) { " -Run $($R.run)" })"
  $R | Add-Member -Force NoteProperty state $s
  $R | Add-Member -Force NoteProperty since $(switch ($s) { 'ACTIVE' { $R.started } 'WAITING' { $R.waitAt } 'STUCK' { $R.last } default { $R.ended } })
  $R | Add-Member -Force NoteProperty next $(switch ($s) { 'WAITING' { $R.waitNext } 'STUCK' { "read its transcript tail; resume it or $rc" } 'STOPPED' { $rc } default { $R.next } }); $R
}
# rows: board entries (a beat within 6 h, left within 2 h), workflow runs (2 h after their last write, 48 h unfinished) and their running
# steps no board entry covers; $script:KitTxVersions = the transcript formats read (tool version)
function Get-KitStatusRows([datetime]$Now = (Get-Date), [string]$Session) {
  $stuck = [double](Get-KitSetting 'supervise.stuckMinutes' 20); $rows = [Collections.Generic.List[object]]::new(); $script:KitTxVersions = @{}
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
  # board entries first: a transcript inside a workflow folder names that run (the engine's folder id <-> the run's name)
  $recent = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { -not $_.takenOverBy -and ($Now - [datetime]$_.beat).TotalHours -lt $(if ($_.status -eq 'left') { 2 } else { 6 }) })   # supervise's window
  $runOf = @{}; foreach ($e in $recent) { if ("$($e.transcript)" -match '[\\/]workflows[\\/]([^\\/]+)[\\/]agent-' -and $e.run) { $runOf[$Matches[1]] = $e.run } }
  # workflow runs and their steps
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $steps = @{}; $runSteps = [Collections.Generic.List[object]]::new()
  foreach ($w in @(Get-KitWorkflowDirs $Session | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | Sort-Object LastWriteTime)) {   # oldest first: a relaunch's steps win
    $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
    $ev = @(Get-Content $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $jt = (Get-Item $j).LastWriteTime
    $lr = @($launch | Where-Object { $_.runId -eq $w.Name -or ($_.wfDir -and (Split-Path "$($_.wfDir)" -Leaf) -eq $w.Name) })
    $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x }
    $running = @(Get-JournalRunning $started @($res.Keys)); $seen = [Collections.Generic.List[object]]::new(); $seen.Add($jt)
    # the engine writes no end marker: a script only waits on its agents, so no running step for 2+ min = it ended (unless paused)
    $paused = [bool]@($lr | Where-Object { $_.paused -and -not $_.completed }).Count
    $fin = -not $paused -and ([bool]@($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count -or [bool]@($lr | Where-Object completed).Count -or ($started.Count -and -not $running.Count -and ($Now - $jt).TotalMinutes -ge 2))
    if (($Now - $jt).TotalHours -ge $(if ($fin) { 2 } else { 48 })) { continue }
    $run = @(@($lr | ForEach-Object run) + $runOf[$w.Name] + $w.Name | Where-Object { $_ })[0]
    if (-not @($lr).Count) { $lr = @($launch | Where-Object { $_.run -eq $run -and $_.cap }) }   # its self record: script, tokens spent, cap
    foreach ($s in $started) {
      $st = [pscustomobject]@{ label = [string]$s.label; run = $run; result = $res[$s.agentId].result; tf = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; tx = $null; covered = $false; jt = $jt }
      if ($s -in $running) { $st.tx = & $last 'claude' $st.tf; $seen.Add($st.tx.at); $runSteps.Add($st) }
      foreach ($k in @(LabelNames $st.label | ForEach-Object { "$run/$_"; if ($run -like 'wf_*') { "?/$_" } })) { if (-not ($steps[$k].tx -and -not $st.tx)) { $steps[$k] = $st } }   # the latest step of a name wins, a running one first; ?/ = run name unknown
    }
    $errs = @($res.Values | Where-Object { $_.result.error }).Count; $spent = @($lr.spent | Where-Object { $_ })[0]; $cap = @($lr.cap | Where-Object { $_ })[0]; $hold = @($lr | Where-Object holderPid)[0]
    $cw = @(foreach ($x in @($runSteps | Where-Object { $_.tf.StartsWith($w.FullName) })) { & $waitOf $run @(LabelNames $x.label) })   # every running step waits = the run waits
    $wp = if ($paused) { [pscustomobject]@{ why = 'owner pause'; at = @($lr.paused)[0]; next = "bossy.ps1 resume -Run $run" } } elseif (-not $running.Count) { & $waitOf $run @() } elseif ($cw.Count -eq $running.Count) { [pscustomobject]@{ why = "$($cw.Count) step(s): $($cw[0].why)"; at = @($cw.at | Sort-Object)[0]; next = $cw[0].next } }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$run (workflow)"; run = $run; left = $running.Count
          task = "$(@($lr.script | Where-Object { $_ } | ForEach-Object { Split-Path "$_" -Leaf })[0]) $($w.Name) · steps $($res.Count)/$($started.Count)$(if ($spent) { " · $(& $tok $spent) tokens$(if ($cap) { " of $(& $tok $cap)" })" })"
          stopped = $(if (-not $fin -and $hold -and (Test-KitHolder $hold) -eq $false) { 'session gone' }); done = $(if ($fin) { "$($res.Count)/$($started.Count) steps$(if ($errs) { ", $errs error(s)" })" })
          wait = $wp.why; waitAt = $wp.at; waitNext = $wp.next; last = & $max $seen; started = $w.CreationTime; ended = $jt; next = '' }) $Now $stuck))
  }
  # board entries; a running step of the same name is that agent now (a resume or env-fix step after its entry left)
  $trk = (Read-KitTracking).tasks
  foreach ($e in @($recent | Group-Object { "$($_.run)/$($_.agent)" } | ForEach-Object { $_.Group | Sort-Object { [datetime]$_.joined } | Select-Object -Last 1 })) {   # a re-join replaces its older entry
    $st = @($steps["$($e.run)/$($e.agent)"], $steps["?/$($e.agent)"] | Where-Object { $_ })[0]; if ($st) { $st.covered = $true }; $on = [bool]$st.tx
    $t = if ($on) { $st.tx } else { & $last $e.tool $(if ($e.transcript) { $e.transcript } elseif ($st) { $st.tf }) }
    $w = if ($e.paused -and -not $on) { [pscustomobject]@{ why = 'owner pause'; at = $e.paused; next = "bossy.ps1 resume -Run $($e.run)" } } else { & $waitOf $e.run @($e.agent) }
    if (-not $w -and "$($e.status)" -match '^(?i)wait' -and ($Now - [datetime]$e.beat).TotalMinutes -lt $stuck) { $w = [pscustomobject]@{ why = "$($e.status)"; at = $e.beat; next = '' } }   # its own words (e.g. waiting for area X1) while it beats
    $tn = foreach ($i in "$($e.items)" -split '[,\s]+') { $o = if ($i -and $trk) { $trk[$i] }; if ($o -and -not $o.done) { "track $i`: $(@($o.mrs).Count) MR(s) until promoted$(if ($o.holdPromotion) { " (held: $($o.holdPromotion))" })"; break } }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$($e.agent) ($($e.type))"; run = $e.run; task = (@($(if ($on) { $st.label }), $e.items, $e.run) | Where-Object { $_ }) -join ' · '
          stopped = $(if ($e.crashed -and -not $on) { 'crashed' } elseif ($e.status -ne 'left' -and (Test-KitHolder $e) -eq $false) { 'session gone' } elseif ($st.result.error) { "error: $($st.result.error)" } elseif ($t.killed) { 'killed' })
          done = $(if ($on) { '' } elseif ($e.handoffBrief) { 'handoff' } elseif (($e.status -eq 'left' -and -not $e.paused) -or ($st.result -and [datetime]$e.joined -le $st.jt)) { & $outcome $st } elseif ($t.ended) { 'turn complete' })
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = & $max @($e.beat, $t.at); doing = & $doing $t; started = $e.joined; ended = $(if ($e.crashed) { $e.crashed } else { $e.beat })
          next = $(if ($e.handoffBrief) { "a fresh $($e.type) from $(Split-Path "$($e.handoffBrief)" -Leaf)" } elseif ($tn) { $tn } elseif ("$($e.status)" -notin 'working', 'left') { "$($e.status)" }) }) $Now $stuck))
  }
  foreach ($st in @($runSteps | Where-Object { -not $_.covered })) {
    $w = & $waitOf $st.run @(LabelNames $st.label); $ty = try { (Get-Content ($st.tf -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json).agentType } catch { '' }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$((($st.label -split ':', 2)[-1] -split '@')[0]) ($(if ($ty) { $ty } else { 'step' }))"; run = $st.run; task = "$($st.label) · $($st.run)"
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = $(if ($st.tx) { $st.tx.at } else { $st.jt }); doing = & $doing $st.tx; started = (Get-Item -LiteralPath $st.tf -ErrorAction SilentlyContinue).CreationTime; next = '' }) $Now $stuck))
  }
  @($rows)
}
# markdown, one line per row (the coordinator pastes it as is); worst states first; cells cut to one line
function Format-KitStatusTable($Rows, $Now, $Versions) {
  $Now = if ($Now) { [datetime]$Now } else { Get-Date }
  $cut = { param($t, [int]$n = 60) $t = ("$t" -replace '[\r\n|]+', ' ').Trim(); if ($t.Length -gt $n) { $t.Substring(0, $n - 1) + '…' } else { $t } }
  $hm = { param($t) if ($t) { ([datetime]$t).ToString('HH:mm') } else { '—' } }
  '| Agent | Task / run | State | Since | Last progress | Next |'; '|---|---|---|---|---|---|'
  foreach ($r in @($Rows | Sort-Object { @{ STUCK = 0; STOPPED = 1; WAITING = 2; ACTIVE = 3; FINISHED = 4 }[$_.state] }, name)) {
    $sc = switch ($r.state) { 'ACTIVE' { "ACTIVE$(if ($r.left) { " ($($r.left) step$(if ($r.left -ne 1) { 's' }) left)" })" } 'WAITING' { "WAITING ($($r.wait))" } 'FINISHED' { "FINISHED: $($r.done)" }
      'STUCK' { "STUCK ($(if ($r.last) { "$([int]($Now - [datetime]$r.last).TotalMinutes) min" } else { 'no progress seen' }))" } default { "STOPPED ($($r.stopped))" } }
    "| $(& $cut $r.name 30) | $(& $cut $r.task) | $(& $cut $sc 80) | $(& $hm $r.since) | $(& $hm $r.last)$(if ($r.doing) { ' ' + (& $cut $r.doing) }) | $(if ($r.next) { & $cut $r.next 80 } else { '—' }) |"
  }
  if (-not @($Rows).Count) { '| — | nothing running | — | — | — | — |' }
  if ($Versions -and $Versions.Count) { "transcripts read: $(@($Versions.Values | Sort-Object) -join ', ')" }
}
# supervise flags of STUCK rows (agents and steps, not their run): WATCH, ACT from 3x the threshold
function Get-KitStuckFlags($Rows, [datetime]$Now, [double]$StuckMin) {
  foreach ($r in @($Rows | Where-Object { $_.state -eq 'STUCK' -and -not $_.left })) {   # a run with running steps: its steps are the rows
    $m = if ($r.last) { [int]($Now - [datetime]$r.last).TotalMinutes } else { [int]::MaxValue }
    [pscustomobject]@{ level = $(if ($m -ge 3 * $StuckMin) { 'ACT' } else { 'WATCH' }); what = "STUCK $($r.name) ($($r.task)): no progress for $(if ($m -lt [int]::MaxValue) { "$m min" } else { 'its whole run' }), nothing it waits on"; action = "Read its transcript tail; resume it with RESUME_BRIEF or $($r.next -replace '^.*; resume it or ')." }
  }
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
  $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  try { $r = Invoke-KitRetry { Invoke-KitNetExe $Exe $A } -Connect:$write } finally { [Console]::OutputEncoding = $enc }
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
function __TrComment($u, $d, $t) { [pscustomobject]@{ user = [string]$u; date = (__TrDate $d); text = [string]$t } }
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
function __TrNoneNote($o, [string]$t) { $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = $t }) }

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
# tracker clickup, github: goodies tracker-clickup, github (skills/crafty/adapters/)
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
# plugins: every installed goody registers its trackers, git hosts and CI here (before the tracker type is resolved)
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
function Set-TrackerStatus([string]$Id, [string]$Status) { Invoke-TrackerWrite 'status' $Id $Status { __Set-TrackerStatus $Id $Status } }
function Add-TrackerComment([string]$Id, [string]$Text) { $t = __TrText $Text; Invoke-TrackerWrite 'comment' $Id $t { __Add-TrackerComment $Id $t } }
function __Set-TrackerStatus([string]$Id, [string]$Status) { Clear-TrackerMemo $Id; __TrA 'status' @{ id = $Id; status = (Resolve-TrackerStatus $Status); logical = $Status } }
function __Add-TrackerComment([string]$Id, [string]$Text) { Clear-TrackerMemo $Id; __TrA 'comment' @{ id = $Id; text = (__TrText $Text) } }
function Get-TrackerComments([string]$Id) { @(__TrA 'comments' @{ id = $Id } | Where-Object { $_ } | Sort-Object date) }

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
function New-TrackerTask([string]$List, [string]$Name, [string]$Description, [string]$Parent, [string]$Assignee, [string]$Priority) {
  if (-not $List) { $List = [string](Get-KitSetting 'tracker.list' '') }
  if (-not $Assignee) { $Assignee = Get-TrackerOwner }   # assignee: the kit runner unless '-' (nobody)
  __TrA 'create' @{ list = $List; name = $Name; description = (__TrText $Description); parent = $(if ($Parent -and $Parent -ne '-') { $Parent }); assignee = $(if ($Assignee -and $Assignee -ne '-') { $Assignee }); priority = $Priority }
}
function Set-TrackerDescription([string]$Id, [string]$Text) { Clear-TrackerMemo $Id; __TrA 'describe' @{ id = $Id; text = (__TrText $Text) } }
function Set-TrackerName([string]$Id, [string]$Name) { Clear-TrackerMemo $Id; __TrA 'rename' @{ id = $Id; name = $Name } }
function Add-TrackerAttachment([string]$Id, [string]$File, [string]$Text) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "tracker: no such file $File" }
  __TrA 'attach' @{ id = $Id; file = $File; text = $Text; leaf = (Split-Path $File -Leaf) }
}
function Get-TrackerTasks([string]$List, [string]$Status) {
  if (-not $List) { $List = [string]$(if ($__trType -in 'github', 'gitlab') { $__trRepo } else { Get-KitSetting 'tracker.list' '' }) }
  __TrA 'list' @{ list = $List; status = (Resolve-TrackerStatus $Status); logical = $Status }
}

# failed checks in tracker texts (pokey.ps1 Format-Checks: "### <id> — <screen>" + "**Saw:**"), an id once (the first text
# wins); not env-data untested checks (the env's, not a code bug) nor gallery rows ("(PASS)") -> [ordered]@{ id; screen; saw }
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

# ---- git-host: git-host + ci adapters (README "Adapters"), Invoke-HostVerb <verb> @{ repo = '<group/name>'; n; ... }
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

# git hosts: goodies gitlab, github, bitbucket, azure-devops, gitea (skills/crafty/adapters/)
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
    detailed_merge_status = $(if ($p.mergeable_state -eq 'dirty' -or $p.mergeable -eq $false) { 'conflict' } else { [string]$p.mergeable_state }); merge_when_pipeline_succeeds = [bool]$p.auto_merge; web_url = $p.html_url }
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
  if ($Verb -in 'mr.create', 'mr.merge', 'mr.unauto') { $global:KitHostMemo.Clear() }
  elseif (-not $NoMemo) {
    $cached = Get-KitMemo $global:KitHostMemo $mk 90 { $null }
    if ($null -ne $cached) { return $cached }
  }
  $v = Invoke-KitAdapter $kind $name $v2 $A
  if ($Verb -eq 'mr.get' -and $v.state -eq 'opened' -and ($t -ne 'gitlab' -or $ci -ne 'gitlab')) { $v | Add-Member -Force head_pipeline (Invoke-HostVerb 'ci.status' @{ type = $t; repo = $A.repo; sha = $v.sha; ref = $v.source_branch; n = $A.n } -NoMemo:$NoMemo) }
  if ($Verb -notin 'mr.create', 'mr.merge', 'mr.unauto' -and $null -ne $v) { $global:KitHostMemo[$mk] = @{ at = Get-Date; v = $v; ok = $v } }
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
# merged (or -State opened) MRs of a branch, from the host (squash merges too: their tip is never in the target); $Dir = a checkout or git dir of the repo
function Get-MergedMrs([string]$Dir, [string]$Branch, [string]$Target, [string]$State = 'merged') {
  $url = "$(git -C $Dir remote get-url origin 2>$null)".Trim()
  if ($url -notmatch '^(?:https?://(?:[^@/]+@)?(?<host>[^/]+)/|[^@]+@(?<host>[^:]+):)(?<path>.+?)(?:\.git)?/?$') { return @() }
  $hostName = $Matches.host; $path = $Matches.path -replace '/_git/', '/' -replace '^v3/', ''
  $type = if ($hostName -eq $KitConf.GitHost) { $script:HostType } else { Get-HostKind $hostName }
  if ($type -eq 'gitlab') { $env:GITLAB_HOST = $hostName }
  $q = @{ repo = $path; type = $type; source_branch = $Branch; state = $State; per_page = 20 }; if ($Target) { $q.target_branch = $Target }
  @(Invoke-HostVerb 'mr.list' $q | Where-Object { $_ -and (-not $Target -or $_.target_branch -eq $Target) })
}

# ---- kitlog: every log line (kit.example.json _paths.log); one call line pair per verb (Invoke-KitVerb)
$script:KitLogMap = $script:KitPathMap.log
function Protect-KitText([string]$s) { if ($s) { foreach ($m in $script:KitLogMap.mask) { $s = $s -replace $m[0], $m[1] } }; $s }
function Protect-KitValue($v, [int]$d = 0) {
  if ($null -eq $v -or $v -is [ValueType]) { return $v }
  if ($v -is [string]) { return Protect-KitText $v }
  $isD = $v -is [Collections.IDictionary]
  if (($isD -or $v -is [Management.Automation.PSCustomObject]) -and $d -lt 5) {
    $o = [ordered]@{}; foreach ($k in @(if ($isD) { $v.Keys } else { $v.PSObject.Properties.Name })) { $o["$k"] = if ("$k" -match $script:KitLogMap.secretKey) { '[redacted]' } else { Protect-KitValue $(if ($isD) { $v[$k] } else { $v.$k }) ($d + 1) } }; return $o }
  if ($v -is [Collections.IEnumerable] -and $d -lt 5) { return , @($v | ForEach-Object { Protect-KitValue $_ ($d + 1) }) }
  Protect-KitText "$v"
}
# a stream with a durable name = that file, else audit/<date>/<stream>.jsonl
function Get-KitLogFile([string]$Stream, [datetime]$Day = (Get-Date), [switch]$Create) {
  if ($Stream -notin $script:KitLogMap.streams) { throw "kitlog: unknown stream '$Stream' (kit.example.json _paths.log.streams)" }
  if ($script:KitPathMap.durable.PSObject.Properties.Name -contains $Stream) { return Get-KitPath $Stream -Create:$Create }
  $p = Join-Path (Get-KitPath audit) "$($Day.ToString('yyyy-MM-dd'))/$Stream.jsonl"; if ($Create) { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null }; $p
}
# run / agent / task: the call's -Run -Agent -Task, its -Session's board entry, the board entry claiming its -Dir / -Worktree, KIT_AGENT / KIT_RUN
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
# one JSON line, appended whole (concurrent writers: shared append, retried); logging never breaks a verb
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
# the lines of streams since a time (default 24 h), each with .stream; a bad line is skipped
function Read-KitLog([string[]]$Stream = $script:KitLogMap.streams, [datetime]$Since = (Get-Date).AddDays(-1)) {
  foreach ($s in $Stream) {
    $files = if ($script:KitPathMap.durable.PSObject.Properties.Name -contains $s) { Get-KitPath $s } else { Get-ChildItem (Get-KitPath audit) -Directory -ErrorAction SilentlyContinue | Where-Object Name -ge $Since.ToString('yyyy-MM-dd') | Sort-Object Name | ForEach-Object { Join-Path $_.FullName "$s.jsonl" } }
    foreach ($f in @($files | Where-Object { Test-Path -LiteralPath $_ })) {
      foreach ($l in Get-Content -LiteralPath $f) { $o = try { $l | ConvertFrom-Json } catch { $null }; if ($o.at -and [datetime]$o.at -ge $Since) { $o | Add-Member -Force NoteProperty stream $s; $o } }
    }
  }
}
# a text's words (4+ letters, common ones dropped); two word sets' overlap (Jaccard)
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
  # call lines (calls stream): start, then end with rc (0 returned, 1 crash, 2 bad parameters; a verb's own exit: rc 'exit', its code is not visible here) and ms
  $script:KitLogOn = $Fn -notmatch '^Invoke-Guard'; $sw = [Diagnostics.Stopwatch]::StartNew(); $script:KitRc = 'exit'   # guards run on every tool call: they log their denials
  $end = { param([string]$Why) if ($script:KitLogOn) { $script:KitLogOn = $false; Write-KitLog calls end (@{ pid = $PID; rc = $script:KitRc; ms = $sw.ElapsedMilliseconds } + $(if ($Why) { @{ error = $Why } } else { @{} })) } }   # rc 2: the usage message (tidy digest "Script errors")
  # a crash exits 1 (2 = bad parameters), never 0: a statement error alone lets `pwsh -File` exit 0, a throw keeps a caller's stale $LASTEXITCODE
  $run = { param([object[]]$pa, [hashtable]$nm)
    $script:KitWho = Get-KitWho $nm; if ($script:KitLogOn) { Write-KitLog calls start @{ pid = $PID; args = (ConvertTo-KitArgs @($Tokens | Select-Object -Skip ([int]$sub))) } }
    try { try { & $Fn @pa @nm; $script:KitRc = 0 } catch {
    if ($_.Exception -is [Management.Automation.ParameterBindingException] -and $_.InvocationInfo.MyCommand.Name -eq $Fn) { $script:KitRc = 2; $why = "$($Fn -replace '^Invoke-', ''): $($_.Exception.Message)"; & $end $why; [Console]::Error.WriteLine($why); exit 2 }
    $script:KitRc = 1; Write-KitLog calls error @{ error = "$_ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" }; & $end
    if ($KitVerbOnError) { & $KitVerbOnError $_ }; [Console]::Error.WriteLine("$($Fn -replace '^Invoke-', '') FAILED: $_ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"); exit 1 } } finally { & $end } }
  if (-not $own.Count) { if ($Tokens.Count -and "$($Tokens[0])" -in '--help', '-h', '-?', '-help') { & $help }; & $run $Tokens @{}; return }
  $named = @{}; $pos = [Collections.Generic.List[object]]::new(); $i = 0
  while ($i -lt $Tokens.Count) {
    $t = "$($Tokens[$i])"
    if ($t -in '--help', '-?' -or ($t -in '-h', '-help' -and -not @($own | Where-Object { $_ -ieq $t.TrimStart('-') }).Count)) { & $help }
    if ($t -match '^--\w') { [Console]::Error.WriteLine("$($Fn -replace '^Invoke-', ''): unknown option $t (parameters take one dash; --help prints the usage)"); exit 2 }   # usage error = exit 2
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
  & $run $pos.ToArray() $named
}
# ---- params: learned parameters (README "Configuration" params; kit.example.json _manifest.params = which keys learn and how)
function Get-KitNow { if ($env:KIT_NOW) { [datetime]$env:KIT_NOW } else { Get-Date } }   # KIT_NOW: the tests' fake clock
function Get-KitParamSpec([string]$Key) {   # '<how> q=.95 k=1.5 up=.25 down=.1 min=5 safe=up gate=accuracy'; up = a safe step, down = a risky one
  $s = "$($script:KitExample._manifest.params.$Key)"; if (-not $s) { return $null }
  $w = @($s -split '\s+'); $o = @{ how = $w[0]; q = 0.95; k = 1.5; up = 0.25; down = 0.1; min = 5; safe = 'up'; gate = '' }
  foreach ($x in $w | Select-Object -Skip 1) { $kv = $x -split '=', 2; $o[$kv[0]] = if ($kv[1] -match '^[\d.]+$') { [double]$kv[1] } else { $kv[1] } }
  $o.down = [math]::Min(0.1, $o.down); $o   # a risky step (toward failures): at most 10%
}
function Read-KitParams([switch]$Strict) {   # -Strict (writers): only a missing file reads as empty; a broken one throws, never overwritten
  $f = Get-KitPath param-state; if ($Strict -and -not (Test-Path -LiteralPath $f)) { return @{} }
  try { $s = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($s) { $s } else { @{} } } catch { if ($Strict) { throw "param state $f unreadable: $_" }; @{} }
}
# value + source; precedence: KIT_PARAM_<KEY> > kit.local.json <key> or <key>.<context> (a pin) > param pin > learned (params.learning on) > default
function Resolve-KitParam([string]$Key, $Default, [string]$Context, $St) {
  $ev = [Environment]::GetEnvironmentVariable('KIT_PARAM_' + ($Key -replace '\W', '_').ToUpper()); if ($ev) { return @([double]$ev, 'env') }
  foreach ($p in @($Key) + @(if ($Context) { "$Key.$Context" })) { $c = Get-KitSetting $p $null; if ($null -ne $c -and ($c -is [ValueType] -or $c -is [string])) { return @($c, 'pin (kit.local.json)') } }
  $pn = $St.pins."$Key|$Context"; if ($null -eq $pn) { $pn = $St.pins."$Key|" }; if ($null -ne $pn) { return @($pn.value, 'pin') }   # a pin without context: every context
  $e = $St.byKey.$Key.$(if ($Context) { $Context } else { '_' })
  if ($null -ne $e.value -and "$(Get-KitSetting 'params.learning' 'on')" -eq 'on') { return @([double]$e.value, 'learned') }
  @($Default, $(if ($null -ne $e.rec) { 'default (learned in shadow)' } else { 'default' }))
}
$script:KitParamMemo = @{}
# the reader every call site uses: never throws, the default on any error, state cached 60 s
function Get-KitParam([Parameter(Mandatory)][string]$Key, $Default, [string]$Context = '') {
  try { (Resolve-KitParam $Key $Default $Context (Get-KitMemo $script:KitParamMemo state 60 { Read-KitParams }))[0] } catch { $Default }
}
# one observation (kitlog params): $Default = the fixed default the call site used (clamps); Result ok | fail | timeout (censored) | oom
function Add-KitParamObs([string]$Key, [double]$Value, [string]$Context = '', [string]$Result = 'ok', [double]$Default = 0) {
  if (-not (Get-KitParamSpec $Key) -or "$(Get-KitSetting 'params.learning' 'on')" -eq 'off') { return }
  Write-KitLog params obs ([ordered]@{ at = (Get-KitNow).ToString('o'); key = $Key; ctx = $Context; v = [math]::Round($Value, 3); r = $Result; d = $Default })
}
function Get-KitQuantile([double[]]$V, [double]$Q, [double[]]$W) {
  if (-not $V.Count) { return $null }; if (-not $W) { $W = @(foreach ($x in $V) { 1.0 }) }
  $ix = @(0..($V.Count - 1) | Sort-Object { $V[$_] }); $tot = ($W | Measure-Object -Sum).Sum; $acc = 0.0
  foreach ($i in $ix) { $acc += $W[$i]; if ($acc -ge $Q * $tot - 1e-9) { return $V[$i] } }; $V[$ix[-1]]
}
# a key's recommendation from its window: quantile (q of ok samples x k; > 10% timed out: step up) | peak (decaying q95 x k, half-life
# 7 d; an OOM: 1.2 x its peak) | ewma (mean + k sigma); spikes > median + 5 MAD dropped; last 5 off the median by 3 MAD: the window restarts
function Get-KitParamRec($Spec, [object[]]$Obs, [double]$Cur, [datetime]$Now, $Since) {   # Since: the last change (its timeouts already stepped)
  $all = @($Obs); $ok = @($all | Where-Object { $_[2] -in 'ok', 'short' }); $new = @($all | Where-Object { -not $Since -or [datetime]$_[0] -gt [datetime]$Since })
  if ($Spec.how -eq 'quantile' -and $new.Count -ge $Spec.min -and @($new | Where-Object { $_[2] -eq 'timeout' }).Count -gt 0.1 * $new.Count) { return @{ v = $Cur * (1 + $Spec.up); n = $all.Count; conf = 1; why = 'over 10% timed out: step up' } }
  $v = [double[]]@($ok | ForEach-Object { [double]$_[1] }); if ($v.Count -lt $Spec.min) { return $null }
  $med = Get-KitQuantile $v 0.5; $mad = Get-KitQuantile ([double[]]@($v | ForEach-Object { [math]::Abs($_ - $med) })) 0.5; $why = ''
  if ($mad -gt 0) {
    $keep = @(0..($v.Count - 1) | Where-Object { $v[$_] -le $med + 5 * $mad }); if ($keep.Count -lt $v.Count) { $why = "$($v.Count - $keep.Count) spike(s) dropped; " }
    $ok = @($keep | ForEach-Object { , $ok[$_] }); $v = [double[]]@($keep | ForEach-Object { $v[$_] })
    if ($v.Count -ge 10 -and [math]::Abs((Get-KitQuantile ([double[]]@($v | Select-Object -Last 5)) 0.5) - $med) -gt 3 * $mad) { $ok = @($ok | Select-Object -Last 5); $v = [double[]]@($v | Select-Object -Last 5); $why += 'drift: window restarted; ' }
  }
  $x = switch ($Spec.how) {
    'peak' {
      $w = [double[]]@($ok | ForEach-Object { [math]::Pow(0.5, [math]::Max(0, ($Now - [datetime]$_[0]).TotalDays) / 7) })
      $p = (Get-KitQuantile $v 0.95 $w) * $Spec.k; $oom = @($all | Where-Object { $_[2] -eq 'oom' } | ForEach-Object { [double]$_[1] })
      if ($oom.Count) { $p = [math]::Max($p, 1.2 * ($oom | Measure-Object -Maximum).Maximum); $why += 'OOM bump; ' }; $p; $why += "peak q95 x$($Spec.k)" }
    'ewma' { $m = $v[0]; $var = 0.0; foreach ($y in $v) { $dl = $y - $m; $m += 0.3 * $dl; $var = 0.7 * ($var + 0.3 * $dl * $dl) }; $m + $Spec.k * [math]::Sqrt($var); $why += "ewma + $($Spec.k) sigma" }
    default { (Get-KitQuantile $v $Spec.q) * $Spec.k; $why += "p$([int](100 * $Spec.q)) x$($Spec.k)" }
  }
  $mean = ($v | Measure-Object -Average).Average; $sd = [math]::Sqrt((($v | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / $v.Count)
  $conf = $v.Count / ($v.Count + 5) * $(if ($Spec.how -eq 'quantile' -or -not $mean) { 1 } else { 1 - [math]::Min(1, $sd / $mean) })
  @{ v = $x; n = $v.Count; conf = [math]::Round($conf, 2); p50 = $med; p90 = (Get-KitQuantile $v 0.9); max = ($v | Measure-Object -Maximum).Maximum; why = $why }
}
# the one writer (supervise -AutoFix each heartbeat; tidy prep): new observations into .state/params.json, then each key / context's
# learned value: slow (one change a day: a safe step within up, a risky one at most 10% after 5 fresh observations; 10% hysteresis),
# default/4..default x4, shadow params.shadowDays, past 2x the default an owner yes (param approve); a failure signal steps to the safe
# side at once and holds risky steps 7 d. Each use reads the value when it starts (a running one keeps its own). Returns flags.
function Invoke-ParamLearn {
  $mode = "$(Get-KitSetting 'params.learning' 'on')"; if ($mode -eq 'off') { return }
  $now = Get-KitNow; $file = Get-KitPath param-state -Create; $flags = [Collections.Generic.List[object]]::new()
  $shadow = [double](Get-KitSetting 'params.shadowDays' 14)
  $flag = { param($l, $w, $a) $flags.Add([pscustomobject]@{ level = $l; what = $w; action = $a }) }
  Invoke-KitLocked $file {
    $st = Read-KitParams -Strict; foreach ($n in 'byKey', 'pins', 'approved') { if (-not $st[$n]) { $st[$n] = @{} } }
    $since = if ($st.cursor) { [datetime]$st.cursor } else { $now.AddDays(-30) }
    foreach ($o in @(Read-KitLog params $since.AddDays(-1) | Where-Object { $_.event -eq 'obs' -and [datetime]$_.at -gt $since } | Sort-Object { [datetime]$_.at })) {
      $st.cursor = ([datetime]$o.at).ToString('o'); $sp = Get-KitParamSpec $o.key; if (-not $sp) { continue }
      $ctx = if ($o.ctx) { "$($o.ctx)" } else { '_' }; if (-not $st.byKey[$o.key]) { $st.byKey[$o.key] = @{} }
      $e = $st.byKey[$o.key][$ctx]; if (-not $e) { $e = $st.byKey[$o.key][$ctx] = @{ since = $st.cursor; obs = @() } }
      if ([double]$o.d) { $e.d = [double]$o.d }
      if ($sp.gate -eq 'accuracy' -and $o.r -eq 'ok' -and [double]$o.v) { $est = if ($null -ne $e.rec) { [double]$e.rec } else { [double]$e.d }; $e.errs = @(@($e.errs) + [math]::Round([math]::Abs($est - [double]$o.v) / [double]$o.v, 3) | Where-Object { $null -ne $_ } | Select-Object -Last 10) }
      $w = [Collections.Generic.List[object]]::new(); foreach ($x in @($e.obs)) { if (($now - [datetime]$x[0]).TotalDays -le 30) { $w.Add($x) } }   # a List: @() would flatten a lone [at, v, r]
      $w.Add(@($st.cursor, [double]$o.v, "$($o.r)")); while ($w.Count -gt 50) { $w.RemoveAt(0) }; $e.obs = $w.ToArray()
      $e.fresh = [int]$e.fresh + 1
      # a failure signal (the value was too tight: timeout, oom, short): one step to the safe side now (x1.5, or the need x k when
      # higher), used from the next use; no risky step for 7 d. A failed build is not one.
      if ($o.r -in 'timeout', 'oom', 'short' -and [double]$e.d -gt 0) {
        $cur = if ($null -ne $e.value) { [double]$e.value } else { [double]$e.d }; $dn = $sp.safe -eq 'down'
        $need = switch ($o.r) { 'oom' { 1.2 * [double]$o.v } 'short' { $sp.k * [double]$o.v } default { $null } }
        $t = if ($dn) { [math]::Min($cur / 1.5, $(if ($null -ne $need) { $need } else { $cur })) } else { [math]::Max($cur * 1.5, [double]$need) }
        $t = [math]::Round([math]::Min(4 * [double]$e.d, [math]::Max([double]$e.d / 4, $t)), 2)
        $e.hold = ([datetime]$st.cursor).AddDays(7).ToString('o'); $e.live = $true; $e.fresh = 0
        if ($t -ne $cur) { $e.rec = $t; $e.changed = $st.cursor; $e.dir = $(if ($dn) { 'down' } else { 'up' }); $e.why = "failure: $($o.r) at $($o.v)" }
      }
    }
    foreach ($key in @($st.byKey.Keys)) {
      $sp = Get-KitParamSpec $key; if (-not $sp) { continue }
      foreach ($ctx in @($st.byKey[$key].Keys)) {
        $e = $st.byKey[$key][$ctx]; $d = [double]$e.d; if ($d -le 0 -or ($e.frozen -and [datetime]$e.frozen -gt $now)) { continue }
        $cur = if ($null -ne $e.rec) { [double]$e.rec } else { $d }; $r = Get-KitParamRec $sp @($e.obs) $cur $now $e.changed
        if ($r) {
          foreach ($n in 'n', 'conf', 'p50', 'p90', 'max') { $e[$n] = $(if ($r[$n] -is [double]) { [math]::Round($r[$n], 3) } else { $r[$n] }) }
          $t = [math]::Min(4 * $d, [math]::Max($d / 4, $r.v)); $e.clamp = $t -ne $r.v
          $up = $t -gt $cur; $risky = $up -eq ($sp.safe -eq 'down'); $f = if ($risky) { $sp.down } else { $sp.up }
          if ((-not $e.changed -or ($now - [datetime]$e.changed).TotalHours -ge 24) -and -not ($risky -and ([int]$e.fresh -lt 5 -or ($e.hold -and [datetime]$e.hold -gt $now)))) {
            $t = [math]::Round($(if ($up) { [math]::Min($cur * (1 + $f), $t) } else { [math]::Max($cur * (1 - $f), $t) }), 2)
            if ($t -ne $cur -and [math]::Abs($t - $cur) -ge 0.99 * $cur * [math]::Min(0.1, $f)) { $e.rec = $t; $e.changed = $now.ToString('o'); $e.why = $r.why; $e.dir = $(if ($up) { 'up' } else { 'down' }); $e.fresh = 0 }   # 10% hysteresis (a smaller step: that step)
          }
        }
        $acc = $sp.gate -ne 'accuracy' -or (@($e.errs).Count -ge 10 -and (@($e.errs) | Measure-Object -Average).Average -le 0.2)
        $val = if ($mode -eq 'on' -and $null -ne $e.rec -and $acc -and ($e.live -or (($now - [datetime]$e.since).TotalDays -ge $shadow -and [double]$e.conf -ge 0.5))) { [double]$e.rec } else { $null }
        if ($null -ne $val -and $val -gt 2 * $d -and -not $st.approved["$key|$(if ($ctx -ne '_') { $ctx })"] -and -not $st.approved["$key|"]) {
          if (-not $e.ask) { $e.ask = $now.ToString('o'); & $flag 'WATCH' "param $key [$ctx] learned $val, past 2x its default ${d}: held at $(2 * $d)" "Owner decision (bossy.ps1 decide ask); yes -> bossy.ps1 param approve $key$(if ($ctx -ne '_') { " -Context '$ctx'" })" }
          $val = 2 * $d
        }
        if ("$val" -ne "$($e.value)") {
          $st.history = @(@($st.history | Where-Object { $_ }) + @{ at = $now.ToString('o'); key = $key; ctx = $ctx; from = $e.value; to = $val; why = "$($e.why)" } | Select-Object -Last 200)
          & $flag 'INFO' "param $key [$ctx]: $(if ($null -ne $e.value) { $e.value } else { "default $d" }) -> $(if ($null -ne $val) { $val } else { "default $d" }) ($($e.why); n $($e.n))" 'Nothing to do (bossy.ps1 param show).'
          Write-KitLog params change ([ordered]@{ key = $key; ctx = $ctx; from = $e.value; to = $val; why = "$($e.why)" })
          $e.value = $val
        }
      }
    }
    Write-KitAtomic $file ($st | ConvertTo-Json -Depth 8 -Compress)
  }
  $script:KitParamMemo.Clear(); $flags
}
# observations bossy.ps1 records: a finished agent's spend (board leave), minutes between new ACTs (supervise); setup -WriteLocal
# leaves learned keys out of a new kit.local.json (a value there pins)
function Add-KitSpendObs($E, [string]$R = 'ok') { $d = $script:KitExample.budget.estimate.([string]$E.type); if ($E.type -and [double]$E.spend -gt 0 -and $null -ne $d) { Add-KitParamObs 'budget.estimate' $E.spend $E.type $R $d } }   # R short: a handoff (the estimate was too low)
function Add-KitActObs($State, [string[]]$Acts, [datetime]$Now) {
  $new = @($Acts | Where-Object { $_ -notin @($State.acts) }).Count   # 2+ new ACTs in one sweep piled up between beats: short (the beat was too long)
  if ($new) { if ($State.lastAct) { Add-KitParamObs 'supervise.heartbeatMinutes' ($Now - [datetime]$State.lastAct).TotalMinutes '' $(if ($new -ge 2) { 'short' } else { 'ok' }) 15 }; $State.lastAct = $Now.ToString('o') }
  $State.acts = $Acts
}
function Remove-KitLearnedKeys($Cfg) { foreach ($pk in @($script:KitExample._manifest.params.PSObject.Properties.Name)) { $o = $Cfg; $pp = $pk -split '\.'; foreach ($x in $pp[0..($pp.Count - 2)]) { $o = $o.$x }; if ($o) { $o.PSObject.Properties.Remove($pp[-1]) } } }
# bossy.ps1 param show / history / pin / unpin / freeze / reset / approve (audited in history)
function Invoke-KitParamVerb([string]$Action, [string]$Key, [string]$Value, [string]$Context, [switch]$Json) {
  $st = Read-KitParams; $reg = @($script:KitExample._manifest.params.PSObject.Properties.Name)
  if ($Action -eq 'history') { $h = @($st.history | Where-Object { -not $Key -or $_.key -eq $Key } | Select-Object -Last 30); if ($Json) { return ConvertTo-Json @($h) -Depth 4 -Compress }; return @($h | ForEach-Object { "$(([datetime]$_.at).ToString('yyyy-MM-dd HH:mm')) $($_.key) [$($_.ctx)] $(if ($null -ne $_.from) { $_.from } else { 'default' }) -> $(if ($null -ne $_.to) { $_.to } else { 'default' }): $($_.why)" }) }
  if ($Action -eq 'show') {
    $rows = foreach ($k in @($reg | Where-Object { -not $Key -or $_ -eq $Key })) {
      $cs = @(if ($st.byKey.$k) { $st.byKey.$k.Keys | Where-Object { -not $Context -or $_ -eq $Context } }); if (-not $cs.Count) { [pscustomobject]@{ key = $k; ctx = '_'; how = "$($script:KitExample._manifest.params.$k)"; source = 'default'; n = 0 }; continue }
      foreach ($c in $cs) { $e = $st.byKey.$k[$c]; $rv = Resolve-KitParam $k $e.d $(if ($c -ne '_') { $c }) $st
        [pscustomobject]@{ key = $k; ctx = $c; how = "$($script:KitExample._manifest.params.$k)"; default = $e.d; learned = $e.rec; effective = $rv[0]; source = $rv[1]; n = [int]$e.n; conf = $e.conf; p50 = $e.p50; p90 = $e.p90; max = $e.max; clamp = [bool]$e.clamp; changed = $e.changed; dir = $e.dir; why = $e.why; frozen = $e.frozen; nextRisky = @(@($(if ($e.changed) { ([datetime]$e.changed).AddDays(1) }), $(if ($e.hold) { [datetime]$e.hold }), (Get-KitNow)) | Sort-Object)[-1].ToString('o'); obsNeeded = [math]::Max(0, 5 - [int]$e.fresh); shadowLeft = [math]::Max(0, [math]::Ceiling([double](Get-KitSetting 'params.shadowDays' 14) - ((Get-KitNow) - [datetime]$e.since).TotalDays)) } } }
    if ($Json) { return ConvertTo-Json @($rows) -Depth 4 -Compress }
    return @($rows | ForEach-Object { if (-not $_.n -and $null -eq $_.default) { "$($_.key): no observations yet ($($_.how))" } else { "$($_.key) [$($_.ctx)]: $($_.effective) ($($_.source)); default $($_.default), learned $(if ($null -ne $_.learned) { $_.learned } else { '-' })$(if ($_.shadowLeft) { ", shadow $($_.shadowLeft) d left" })$(if ($_.n) { "; n $($_.n) conf $($_.conf) p50 $($_.p50) p90 $($_.p90) max $($_.max)" })$(if ($_.clamp) { ' (clamped)' })$(if ($_.frozen) { "; frozen to $(([datetime]$_.frozen).ToString('MM-dd'))" })$(if ($_.changed) { "; last change $(([datetime]$_.changed).ToString('MM-dd HH:mm')) $($_.dir): $($_.why)" })$(if ($null -ne $_.nextRisky) { "; next risky step from $(([datetime]$_.nextRisky).ToString('MM-dd HH:mm'))$(if ($_.obsNeeded) { " + $($_.obsNeeded) obs" })" })" } })
  }
  if ($Key -notin $reg) { return "ERROR unknown param '$Key' (kit.example.json _manifest.params: $($reg -join ', '))" }
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
    $s.history = @(@($s.history | Where-Object { $_ }) + @{ at = (Get-KitNow).ToString('o'); key = $Key; ctx = $cx; from = $null; to = $(if ($Action -eq 'pin') { [double]$Value }); why = "$Action by $((Get-KitWho).agent)" } | Select-Object -Last 200)
    Write-KitAtomic $file ($s | ConvertTo-Json -Depth 8 -Compress)
  }
  "param $Key$(if ($Context) { " [$Context]" }): $Action$(if ($Action -eq 'pin') { " $Value" }) done"
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
# an adapter the config names (tracker.type, the git host, ci.type) that no installed goody brings: installed on demand, then loaded
$__hostSet = (Get-KitValue 'gitHostType' '') -or (Get-KitValue 'gitHost' '') -or @(Get-KitValue 'repos' @()).Count   # no host configured: no git-host goody to fetch
foreach ($__need in @(@('tracker', $script:__trType), @('git-host', $(if ($__hostSet) { $script:HostType })), @('ci', ([string](Get-KitSetting 'ci.type' '')).ToLower()))) {
  if (-not $__need[1] -or $__need[1] -in 'host', 'none' -or $KitAdapters[$__need[0]][$__need[1]] -or "$script:__verb" -match '^(guard|guard-sendmessage|health)$') { continue }   # hooks stay fast
  if (Install-KitExtra (Get-KitExtraName $__need[0] $__need[1])) {
    foreach ($__plugin in @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName | Where-Object { $_ -notin $script:KitAdapterFiles })) { . $__plugin; $script:KitAdapterFiles += $__plugin }
  }
}
Add-KitExtraUse $script:KitEntry   # a goody's entry script (envy.ps1, phoney.ps1) in use
