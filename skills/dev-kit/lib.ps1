<#
Kit library (config, paths, OS, tracker + git-host adapters). Usage (pwsh 7): every kit script dot-sources it once:
 . (Join-Path <kit> 'skills/dev-kit/lib.ps1')
Functions only, silent. In: kit.local.json, kit.example.json (_paths), env KIT_* / CLAUDE_*. Exit codes: none.
Out: $KitConf, $KitCmd (entry scripts), Get-KitPath, Get-KitSetting, tracker verbs, Invoke-HostVerb, OS helpers.
Sections: 1 paths  2 config  3 OS  4 tracker  5 git host  6 entry scripts.
#>
# ===== 1. paths (kit.example.json _paths) =====
$script:KitRoot = Split-Path (Split-Path $PSScriptRoot)
$script:KitPathMap = (Get-Content (Join-Path $PSScriptRoot 'kit.example.json') -Raw | ConvertFrom-Json)._paths
function Get-KitRuntime { if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path $script:KitRoot $script:KitPathMap.runtimeDir } }
function Get-KitPath([Parameter(Mandatory)][string]$Name, [switch]$Create) {
  $m = $script:KitPathMap
  if ($Name -eq 'runtime') { $p = Get-KitRuntime; $dir = $true }
  elseif ($m.runtime.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.runtime.$Name; $p = Join-Path (Get-KitRuntime) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  elseif ($m.durable.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.durable.$Name; $p = Join-Path (Join-Path $script:KitRoot $m.stateDir) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  else { throw "Get-KitPath: unknown name '$Name' (see skills/dev-kit/kit.example.json _paths)" }
  if ($Create) { New-Item -ItemType Directory -Force $(if ($dir) { $p } else { Split-Path $p }) | Out-Null }
  $p
}
# cross-process <file>.lock, stale after 2 min; 130 s wait -> throw (never unlocked)
function Invoke-KitLocked([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body) {
  $lock = "$File.lock"; $fs = $null
  for ($i = 0; $i -lt 1300 -and -not $fs; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch {
      if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -gt 2) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }   # a live holder keeps it open: the remove fails
      Start-Sleep -Milliseconds 100
    }
  }
  # warn + return too: SilentlyContinue ignores a throw
  if (-not $fs) { $m = "Invoke-KitLocked: $lock still held after 130 s - not writing $File"; Write-Warning $m; throw $m; return }
  try { & $Body } finally { $fs.Dispose(); Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}
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
function Set-KitTaskFields([Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][hashtable]$Fields) {
  Update-KitTracking { param($t) if ($t.tasks[$Task]) { foreach ($k in $Fields.Keys) { $t.tasks[$Task][$k] = $Fields[$k] } } }
}

# ===== 2. config (kit.local.json) =====
$__devkit = $PSScriptRoot
$__kit = Split-Path (Split-Path $__devkit)
$__ws = Split-Path $__kit
$__cfg = $null
$__cfgFile = Join-Path $__devkit 'kit.local.json'
# kit worktree: the main clone's kit.local.json
if (-not (Test-Path $__cfgFile)) {
  $__cd = "$(git -C $__devkit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($__cd) { $__alt = Join-Path (Split-Path $__cd) 'skills/dev-kit/kit.local.json'; if (Test-Path $__alt) { $__cfgFile = $__alt } }
}
if (Test-Path $__cfgFile) { try { $__cfg = Get-Content $__cfgFile -Raw | ConvertFrom-Json } catch { Write-Warning "ignoring $__cfgFile (invalid JSON): $_" } }
function Get-KitValue([string]$Name, $Default) { if ($__cfg -and $null -ne $__cfg.$Name -and "$($__cfg.$Name)" -ne '') { return $__cfg.$Name }; $Default }   # arrays stay whole
function Get-KitSetting([string]$Path, $Default) {
  $cur = $__cfg
  foreach ($part in $Path -split '\.') {
    if ($null -eq $cur -or -not ($cur.PSObject.Properties.Name -contains $part)) { return $Default }
    $cur = $cur.$part
  }
  if ($null -eq $cur -or "$cur" -eq '') { return $Default }
  $cur
}
$__reportType = [string]$(if ($env:KIT_REPORT_TYPE) { $env:KIT_REPORT_TYPE } else { Get-KitSetting 'reports.type' $(if (Get-Command gws -ErrorAction SilentlyContinue) { 'gdocs' } else { 'markdown' }) })
$__trLp = [string](Get-KitSetting 'tracker.statusLabelPrefix' 'status:')   # github / gitlab status labels
$__trType = ([string]$(if ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { Get-KitSetting 'tracker.type' 'none' })).ToLower()
# task tag in branches (fix/<tag><id>-slug) and MR titles
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
  # session journals
  ClaudeProjectDir = (Join-Path (Join-Path $HOME '.claude/projects') ($__ws -replace '[^A-Za-z0-9]', '-'))
}

# pwsh -File passes `'T1','T2'` as ONE string; quoted items stay whole
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
if (-not $global:KitFetched) { $global:KitFetched = @{} }
# once per repo per process per 10 min (worktrees share it); $false = failed/timed out
function Invoke-GitFetch([string]$Dir, [int]$TimeoutSec = 60, [string[]]$Refs = @()) {
  $common = "$(git -C $Dir rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim(); if (-not $common) { return $false }
  $key = "$common|$($Refs -join ',')"
  if ($global:KitFetched.ContainsKey($key) -and ((Get-Date) - $global:KitFetched[$key].at).TotalMinutes -lt 10) { return $global:KitFetched[$key].ok }
  $a = @('-C', $Dir, 'fetch', '-q', '--prune', 'origin') + @($Refs | Where-Object { $_ })
  # one argv entry per argument (spaces broke Start-Process)
  $r = Invoke-KitExe git $a $TimeoutSec
  if ($r.timedOut) { Write-Warning "git fetch in $Dir timed out after $TimeoutSec s (skipped)" }
  elseif ($r.code) { Write-Warning "git fetch in $Dir failed (exit $($r.code)): $("$($r.err)".Trim() -split "`n" | Select-Object -Last 1)" }
  $ok = -not $r.timedOut -and $r.code -eq 0
  $global:KitFetched[$key] = @{ at = Get-Date; ok = $ok }; $ok
}
# ===== 3. OS helpers (Windows, Linux, macOS) =====
$KitIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$KitIsMac = (-not $KitIsWindows) -and ($PSVersionTable.OS -match 'Darwin' -or ((Test-Path variable:IsMacOS) -and $IsMacOS))

function Get-KitTemp { [IO.Path]::GetTempPath().TrimEnd([char]'\', [char]'/') }

function Get-ExeName([string]$Name) { if ($KitIsWindows) { "$Name.exe" } else { $Name } }

function Get-SysMem {
  $mx = @{}
  $kv = { param($lines, $re) $h = @{}; foreach ($l in $lines) { if ($l -match $re) { $h[$Matches[1]] = [double]$Matches[2] } }; $h }
  if ($KitIsWindows) {
    $total = (Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes, PoolPagedResidentBytes, PoolNonpagedBytes, CommittedBytes, CommitLimit
    $avail = $pm.AvailableMBytes / 1KB   # Available = free + standby (the cache is not "used")
    $mx = @{ PoolGB = [math]::Round(($pm.PoolPagedResidentBytes + $pm.PoolNonpagedBytes) / 1GB, 1); CommitGB = [math]::Round($pm.CommittedBytes / 1GB, 1); CommitLimitGB = [math]::Round($pm.CommitLimit / 1GB, 1) }
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
  [pscustomobject](@{ TotalGB = [math]::Round($total, 1); AvailGB = [math]::Round($avail, 1); FreeGB = [math]::Round($free, 1) } + $mx)
}

# Linux/macOS: available, as the page cache keeps MemFree ~0
function Get-FreeGB { $m = Get-SysMem; if ($KitIsWindows) { $m.FreeGB } else { $m.AvailGB } }

function Get-SysCpu {
  if ($KitIsWindows) { return [math]::Round([double](Get-CimInstance Win32_Processor -Property LoadPercentage | Measure-Object LoadPercentage -Average).Average, 0) }
  if (Test-Path /proc/stat) {
    $read = { $f = ((Get-Content /proc/stat -TotalCount 1) -split '\s+' | Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object { [double]$_ }); @{ idle = $f[3] + $f[4]; all = ($f | Measure-Object -Sum).Sum } }
    $a = & $read; Start-Sleep -Milliseconds 500; $b = & $read
    $d = $b.all - $a.all; if ($d -le 0) { return 0 }
    return [math]::Round(100 * (1 - ($b.idle - $a.idle) / $d), 0)
  }
  $sum = (ps -A -o %cpu= 2>$null | ForEach-Object { [double]"$_".Trim() } | Measure-Object -Sum).Sum
  [math]::Min(100, [math]::Round($sum / [Environment]::ProcessorCount, 0))
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
    # comm has spaces on macOS, 15 chars max on Linux: prefer the args exe it prefixes
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
# the tool's default compaction point; the kit sets none (README "Configuration" budget)
function Get-KitBudget([string]$Tool = '', [string]$Model = '', [int]$Window = 0) {
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).budget
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
    # 1M: Opus 4.7+, Sonnet 5+, Haiku 5.5+, Fable, bare aliases; else 200k unless [1m]
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
# free-RAM samples, 1/min, for the report's mean
function Add-KitMemSample([double]$Free) { try { $f = Get-KitPath mem-samples -Create; if (-not (Test-Path $f) -or ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -ge 60) { Add-Content $f "$((Get-Date).ToString('s'))`t$([math]::Round($Free, 1))" } } catch {} }
# spend = last transcript usage (input + cache + output): what the tool compacts on
function Get-KitSpend([string]$File) {
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $null }
  $t = @(Get-Content -LiteralPath $File -Tail 300)
  for ($i = $t.Count - 1; $i -ge 0; $i--) {
    if ($t[$i] -notmatch '"usage"') { continue }
    $o = try { $t[$i] | ConvertFrom-Json -Depth 40 } catch { continue }; $u = $o.message.usage; if (-not $u) { continue }
    return [pscustomobject]@{ spend = [int]($u.input_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens + $u.output_tokens); model = "$($o.message.model)" }
  }
}
# marker: board SESSION token or launch -Self line; this session first
function Find-KitTranscript([string]$Marker, [string]$Filter = '*.jsonl') {
  $root = if ($v = $env:KIT_TRANSCRIPTS) { $v } else { $KitConf.ClaudeProjectDir }; $sid = "$env:CLAUDE_CODE_SESSION_ID"
  foreach ($f in @(Get-ChildItem $root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } | Sort-Object { -not $sid -or $_.FullName -notmatch [regex]::Escape($sid) }, { -$_.LastWriteTime.Ticks })) {
    if (Select-String -LiteralPath $f.FullName -SimpleMatch $Marker -Quiet) { return $f.FullName }
  }
}

# holder = first non-shell ancestor + start time (pid reuse); Test-KitHolder: alive $true, gone $false, unknown $null
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
function Test-KitHolder($o) {
  if (-not $o -or -not $o.holderPid) { return $null }
  $p = Get-Process -Id ([int]$o.holderPid) -ErrorAction SilentlyContinue
  if (-not $p) { return $false }
  if ($o.holderStart) { try { return [math]::Abs(([datetimeoffset]$p.StartTime - [datetimeoffset]$o.holderStart).TotalSeconds) -lt 2 } catch {} }
  $true
}
# ---- liveness leases (README "Leases"): ONE rule for env services, test browsers, phones, sandboxes, builds
function Set-KitProp($o, [string]$k, $v) { if ($o -is [Collections.IDictionary]) { $o[$k] = $v } else { $o | Add-Member -Force NoteProperty $k $v } }
function New-KitLease([string]$Agent, [string]$Session = '', [int]$OwnerMinutes = 0, [int]$ProcessId = 0) {
  $l = [ordered]@{ agent = $Agent; session = $Session; at = (Get-Date).ToString('o') } + (Get-KitHolder)
  if ($OwnerMinutes) { $l.owner = $true; $l.until = (Get-Date).AddMinutes($OwnerMinutes).ToString('o') }   # only owner holds keep minutes
  if ($ProcessId) { $l.pid = $ProcessId }; $l
}
$script:KitLiveCache = @{}
function Get-KitLiveCached([string]$k, [scriptblock]$b) { $c = $script:KitLiveCache[$k]; if (-not $c -or ((Get-Date) - $c.at).TotalSeconds -gt 15) { $c = @{ at = Get-Date; v = (& $b) }; $script:KitLiveCache[$k] = $c }; $c.v }
# live: owner hold before until | pid | running workflow step (live-steps) | board beat (session, else agent) < idle.beatMinutes
# | coordinator: heartbeat < idle.beatMinutes | holder process
function Test-KitLive($l) {
  $now = Get-Date; $bm = [double](Get-KitSetting 'idle.beatMinutes' 20); $a = "$($l.agent)"
  if ($l.owner -or ($l.until -and -not $a -and -not $l.holderPid)) { return [datetime]$l.until -gt $now }   # a pre-lease hold keeps its minutes
  if ($l.pid -and (Get-Process -Id ([int]$l.pid) -ErrorAction SilentlyContinue)) { return $true }
  $ls = Get-KitLiveCached steps { try { $s = Get-Content (Get-KitPath live-steps) -Raw | ConvertFrom-Json; if (((Get-Date) - [datetime]$s.at).TotalMinutes -lt $bm) { $s } } catch {} }
  $mine = @($ls.labels | Where-Object { ($a -and (($_ -split ':', 2)[-1] -split '@')[0] -eq $a) -or ($l.lane -and $_ -match "@$([regex]::Escape($l.lane))$") })
  if (@($mine | Where-Object { $_ -in @($ls.running) }).Count) { return $true }
  $b = @(Get-KitLiveCached board { @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} }) } |
    Where-Object { $_.status -ne 'left' -and $(if ($l.session) { $_.session -eq $l.session } else { $_.agent -and $_.agent -in @($a, $l.holder) }) })
  if (@($b | Where-Object { ($now - [datetime]$_.beat).TotalMinutes -lt $bm -or ($_.pid -and (Get-Process -Id ([int]$_.pid) -ErrorAction SilentlyContinue)) }).Count) { return $true }
  if ($mine.Count -or $l.session) { return $false }   # its step finished / its board entry left or went quiet
  if ($a -match '^(main|coordinator)$') { $f = Get-Item (Get-KitPath supervise-state) -ErrorAction SilentlyContinue; if ($f -and ($now - $f.LastWriteTime).TotalMinutes -lt $bm) { return $true } }
  (Test-KitHolder $l) -eq $true
}
# keep? live: seen = now; else kept idle.graceMinutes past seen (graceLeft)
function Update-KitLease($l) {
  $now = Get-Date
  if (Test-KitLive $l) { Set-KitProp $l seen $now.ToString('o'); Set-KitProp $l graceLeft $null; return $true }
  if ($l.owner -or ($l.until -and -not $l.agent -and -not $l.holderPid)) { return $false }
  if (-not $l.seen) { Set-KitProp $l seen $now.ToString('o') }   # first seen dead: the grace starts now
  $left = [double](Get-KitSetting 'idle.graceMinutes' 10) - ($now - [datetime]$l.seen).TotalMinutes
  Set-KitProp $l graceLeft ([math]::Max(0, [math]::Ceiling($left))); $left -gt 0
}

# wall-clocked; functions (test mocks) run directly
function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60) {
  $res = { param($c, $o, $e, $t = $false) [pscustomobject]@{ code = $c; out = $o; err = $e; timedOut = $t } }
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd.CommandType -eq 'ExternalScript') { $app = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($app) { $cmd = $app } }   # an npm .ps1 shim: its .cmd keeps the timeout
  if (-not $cmd) { return & $res 127 '' "$Exe is not on PATH" }
  if ($cmd.CommandType -ne 'Application') {
    $o = @(& $Exe @A 2>&1); $c = [int]$LASTEXITCODE; $so = @(); $se = @()
    foreach ($x in $o) { if ($x -is [Management.Automation.ErrorRecord]) { $se += "$x" } else { $so += "$x" } }
    return & $res $c ($so -join "`n") ($se -join "`n")
  }
  $si = [Diagnostics.ProcessStartInfo]::new($cmd.Source)
  foreach ($x in @($A)) { $si.ArgumentList.Add([string]$x) }
  $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($si)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; return & $res -1 '' "$Exe timed out after $TimeoutSec s" $true }
  $p.WaitForExit()
  & $res $p.ExitCode $so.Result.TrimEnd() $se.Result.TrimEnd()
}
# transient errors retry (2 s, 6 s); -Connect: only errors proving nothing was sent
$script:KitNoConnect = '(?i)could not resolve|no such host|connection refused|unreachable|dial tcp'
$script:KitTransient = $script:KitNoConnect + '|timed? ?out|connection (reset|closed|aborted)|\bEOF\b|TLS handshake|temporar|\b(429|50[0234])\b|bad gateway|service unavailable|too many requests'
# an ErrorRecord: exception types / HTTP codes (any OS language) first
function Test-KitTransient($Text, [switch]$Connect) {
  for ($x = $Text.Exception; $x; $x = $x.InnerException) {
    $c = "$($x.SocketErrorCode)$($x.HttpRequestError)"
    if ($c -match '^(HostNotFound|ConnectionRefused|\w+Unreachable|TryAgain|NameResolutionError|ConnectionError)$' -or (-not $Connect -and ($c -match '^(ConnectionReset|ConnectionAborted|TimedOut)$' -or
        $x -is [TimeoutException] -or $x -is [Threading.Tasks.TaskCanceledException] -or [int]$(if ($x.StatusCode) { $x.StatusCode } else { $x.Response.StatusCode }) -in 429, 500, 502, 503, 504))) { return $true }
  }
  "$(if ($Text.Exception) { $Text.Exception.Message } else { $Text })" -match $(if ($Connect) { $script:KitNoConnect } else { $script:KitTransient })
}
# net.timeoutSec (60) / 3 tries; KIT_NET_TIMEOUT_SEC / KIT_NET_TRIES win (supervise lowers)
function Get-KitNetTimeout { if ($env:KIT_NET_TIMEOUT_SEC) { [int]$env:KIT_NET_TIMEOUT_SEC } else { [int](Get-KitSetting 'net.timeoutSec' 60) } }
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
  # both remove only the link (rm: no trailing slash, no -r)
  if ($KitIsWindows) { cmd /c rmdir "$Path" | Out-Null }
  else { & /bin/rm -f -- "$($Path.TrimEnd('/'))" }
}

# never install; workspace links re-point to $WtRoot (Metro rejects outside files)
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
  # Directory.Delete on a link removes only the link (fast)
  $unlink = { param($x) if ($KitIsWindows) { [IO.Directory]::Delete($x) } else { Remove-DirLink $x } }
  # farm = only links, files, @scope folders of links; else refuse before deleting
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

# python3 may be the Windows Store stub
function Get-Python { if ($KitIsWindows) { 'python' } else { $p = Resolve-Tool python3 python; if ($p) { $p } else { 'python3' } } }

# `kittool.py prose` findings as warnings + strings; never cuts
function Test-KitProse([string]$Kind, [string]$Text, [string]$Path) {
  $kt = $KitCmd.kittool; if (-not $kt -or -not (Test-Path $kt)) { return @() }
  $tmp = $null
  if (-not $Path) { $tmp = Join-Path (Get-KitTemp) "kit-prose-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 6)).md"; [IO.File]::WriteAllText($tmp, $Text); $Path = $tmp }
  try { $r = & (Get-Python) -X utf8 $kt prose --kind $Kind $Path --json 2>$null | ConvertFrom-Json } catch { $r = $null } finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
  $found = @(if ($r) { $r.findings })
  foreach ($f in $found) { Write-Warning "[prose] $Kind`: $f (templates.md ""Writing standards"": rewrite, nothing was cut)" }
  $found
}
# survives shell / tool timeouts
function Start-Detached([string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path, [string]$Log) {
  if ($KitIsWindows) { $null = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden; return }
  if (-not $Log) { $Log = Join-Path (Get-KitTemp) "kit-bg-$([IO.Path]::GetFileNameWithoutExtension($FilePath))-$PID.log" }
  $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.UseShellExecute = $false
  $script = 'cd "$1" || exit 1; log=$2; shift 2; s=; command -v setsid >/dev/null 2>&1 && s=setsid; $s nohup "$@" >"$log" 2>&1 </dev/null &'
  foreach ($a in @('-c', $script, 'sh', $WorkingDirectory, $Log, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$a) }
  ([Diagnostics.Process]::Start($psi)).WaitForExit()
}

function Get-PortPids([int]$Port) {
  if ($KitIsWindows) { return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ea 0 | Select-Object -ExpandProperty OwningProcess -Unique) }
  if (Resolve-Tool lsof) { return @(lsof -t -nP -iTCP:$Port -sTCP:LISTEN 2>$null | ForEach-Object { [int]$_ } | Select-Object -Unique) }
  if (Resolve-Tool fuser) { return @(("$(fuser -n tcp $Port 2>$null)" -split '\s+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
  @()
}

function Test-PortListening([int]$Port) {
  if ($KitIsWindows) { return @(Get-PortPids $Port).Count -gt 0 }
  $t = [Net.Sockets.TcpClient]::new()
  try { $t.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $t.Connected } catch { $false } finally { $t.Dispose() }
}

function Get-AndroidSdk {
  foreach ($e in $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) { if ($e) { return $e } }
  if ($KitIsWindows) { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
  elseif ($KitIsMac) { Join-Path $HOME 'Library/Android/sdk' }
  else { Join-Path $HOME 'Android/Sdk' }
}

# ----- adapters (README "Adapters"): kind -> name -> verb -> { param($a, $verb) }; '*' = any verb
if (-not $global:KitAdapters) { $global:KitAdapters = @{} }
function Register-KitAdapter([string]$Kind, [string]$Name, [hashtable]$Verbs) { if (-not $KitAdapters[$Kind]) { $KitAdapters[$Kind] = @{} }; $KitAdapters[$Kind][$Name] = $Verbs }
function Invoke-KitAdapter([string]$Kind, [string]$Name, [string]$Verb, [hashtable]$a = @{}) {
  $ad = $KitAdapters[$Kind][$Name]; $f = if (-not $ad) { $null } elseif ($ad.ContainsKey($Verb)) { $ad[$Verb] } else { $ad['*'] }
  if (-not $f) { Write-Warning "$Kind ($Name): no adapter or verb $Verb (README ""Adapters"")"; return $null }
  & $f $a $Verb
}
# $Commands.<verb> = a command line; {key} = one argv token (never re-split); stdout JSON, else text
function Invoke-KitCommand([string]$Kind, $Commands, [string]$Verb, [hashtable]$a) {
  $line = [string]$(if ($Commands) { $Commands.$Verb }); if (-not $line) { Write-Warning "$Kind (command): no commands.$Verb in kit.local.json"; return $null }
  $t = @([regex]::Matches($line, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object { [regex]::Replace($_.Groups[1].Value + $_.Groups[2].Value + $_.Groups[3].Value, '\{(\w+)\}', { param($m) [string]$a[$m.Groups[1].Value] }) })
  $r = Invoke-KitRetry { Invoke-KitExe $t[0] @($t | Select-Object -Skip 1) (Get-KitNetTimeout) } -Connect:($Verb -match 'create|merge|comment|attach|publish')
  if ($r.code) { $global:KitHostFailed = $true; Write-Warning "$Kind (command) $Verb failed (exit $($r.code)): $($r.err)"; return $null }
  $o = "$($r.out)".Trim(); if ($o -match '^[\[{]') { try { return ($o | ConvertFrom-Json) } catch {} }; $o
}
# GETs retry, writes never twice; failures warn + $null (= unknown)
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
  $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = (Get-KitNetTimeout) }
  if ($Method -eq 'GET') { $p.MaximumRetryCount = 2; $p.RetryIntervalSec = 3 }
  if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress)); $p.ContentType = 'application/json' }
  try { Invoke-RestMethod @p } catch { $global:KitHostFailed = $true; Write-Warning "http $Method $($Uri -replace '\?.*') failed: $($_.Exception.Message)"; $null }
}
# Authorization from env var $Env (bearer | basic: "user:secret" or ":pat" | token); never printed
function Get-KitAuth([string]$Env, [string]$Kind = 'bearer') {
  $t = [Environment]::GetEnvironmentVariable($Env); if (-not $t) { return @{} }
  @{ Authorization = switch ($Kind) { 'basic' { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($(if ($t -match ':') { $t } else { ":$t" }))) } 'token' { "token $t" } default { "Bearer $t" } } }
}

# ===== 4. tracker adapter (a Register-KitAdapter block per tracker.type) =====

# -Type / -DryRun, else env KIT_TRACKER_TYPE / KIT_TRACKER_DRYRUN, else config
function Initialize-KitTracker([string]$Type, [switch]$DryRun) {
  $script:__trType = ([string]$(if ($Type) { $Type } elseif ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { $KitConf.TrackerType })).ToLower()
  $script:__trDry = [bool]($DryRun -or $env:KIT_TRACKER_DRYRUN -eq '1')
  if (-not $KitAdapters.tracker[$script:__trType]) { Write-Warning "tracker: unknown tracker.type '$($script:__trType)' (have: $($KitAdapters.tracker.Keys -join ' ')) - using none"; $script:__trType = 'none' }
  if ($script:__trType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }
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
  # logical (review, inTest, ...) -> tracker name
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
  # UTF-8 output; reads + status sets retry transient errors, other writes only unsent ones
  $h2 = "$($A[0..1] -join ' ')"; $all = "$($A -join ' ')"
  $write = ($h2 -match '(?i)\b(comment|create|add|edit|attach|upload|new)\b' -and $h2 -notmatch '(?i)status') -or ($all -match '(?i)(^|\s)(-X|--method)\s+(POST|PUT|PATCH|DELETE)\b' -and $all -notmatch '(?i)status')
  $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  try { $r = Invoke-KitRetry { Invoke-KitExe $Exe $A (Get-KitNetTimeout) } -Connect:$write } finally { [Console]::OutputEncoding = $enc }
  $out = (@($r.out, $r.err) | Where-Object { $_ }) -join "`n"
  # a failing CLI (auth, unknown task) is no success; alias loop needs 'no matching status'
  if ($r.code -and $out -notmatch 'no matching status') { throw "tracker ($__trType): $Exe $h2 failed (exit $($r.code)): $(__TrShort $out)" }
  $out
}
function __TrJson([string]$Out) {
  if (-not $Out) { return $null }
  $i = @($Out.IndexOf('{'), $Out.IndexOf('[')) | Where-Object { $_ -ge 0 } | Sort-Object | Select-Object -First 1
  if ($null -eq $i) { return $null }
  try { $Out.Substring($i) | ConvertFrom-Json } catch { $null }
}
# a failure throws its cause (the outbox queues network losses); $File/$CType: upload or own body type
function __TrHttp([string]$Method, [string]$Uri, $Body, [hashtable]$H, [string]$File, [string]$CType) {
  if ($__trDry) { Write-Host "DRYRUN: $Method $Uri$(if ($null -ne $Body) { '  body=' + (__TrShort ($Body | ConvertTo-Json -Depth 20 -Compress)) })$(if ($File) { "  file=$File" })"; return $null }
  if (-not ($File -or $CType)) {
    $o = @(Invoke-KitHttp $Method $Uri $Body $H 3>&1); $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] })
    if ($w) { throw "tracker ($__trType): $($w[0].Message)" }; return ($o | ForEach-Object { $_ })
  }
  $p = @{ Method = $Method; Uri = $Uri; Headers = $H; TimeoutSec = (Get-KitNetTimeout) }
  if (-not $CType) { $p.Form = @{ file = Get-Item -LiteralPath $File } } elseif ($File) { $p.InFile = $File; $p.ContentType = $CType }
  else { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20 -Compress)); $p.ContentType = $CType }
  Invoke-RestMethod @p
}
function __TrBase([string]$Env) { $v = [Environment]::GetEnvironmentVariable($Env); if ($v) { $v.TrimEnd('/') } else { "<$Env>" } }
function __TrTemp([string]$Text) { $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, $Text, (New-Object Text.UTF8Encoding $false)); $f }
function __TrStub([string]$Id) { [pscustomobject]@{ id = $Id; name = ''; status = ''; url = (Get-TrackerUrl $Id); parent = $null; assignees = @(); subtasks = @(); list = ''; description = '' } }
function __TrDate($d) { if ($d -match '^\d{10,}$') { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d).UtcDateTime.ToString('s') } elseif ($d) { ([datetime]$d).ToUniversalTime().ToString('s') } else { '' } }
function __TrPrio([string]$p) { switch ($p) { '1' { 'urgent' } '2' { 'high' } '3' { 'normal' } '4' { 'low' } default { $p } } }
function __TrPrioName([string]$p, [string]$Names) { if ($p -match '^[1-4]$') { ($Names -split ' ')[[int]$p - 1] } else { $p } }
function __TrWho($id, $u) { [pscustomobject]@{ id = "$id"; username = "$u" } }
function __TrSub($i, $n, $s, $u) { [pscustomobject]@{ id = $i; name = $n; status = $s; url = $u } }
function __TrRow($i, $n, $s, $who) { [pscustomobject]@{ id = $i; name = $n; status = $s; assignees = $who } }
function __TrTask($i, $n, $s, $u, $p, $who, $l, $subs, $d) { [pscustomobject]@{ id = $i; name = $n; status = $s; url = $u; parent = $p; assignees = $who; list = $l; subtasks = $subs; description = $d } }
function __TrPartOf($a) { if ($a.parent) { "Part of #$($a.parent -replace '^.*#', '')`n`n" } }
function __TrNote($a) { if ($a.text) { Add-TrackerComment $a.id "$($a.text) (attached: $($a.leaf))" } }
# no attachments: the file's text as a comment
function __TrAttachText($a) {
  $b = Get-Content -LiteralPath $a.file -Raw -Encoding utf8
  if ($b.Length -gt 60000) { $b = $b.Substring(0, 60000) + "`n`n_(truncated: the full $($a.leaf) is in the QA run folder)_" }
  Add-TrackerComment $a.id ($(if ($a.text) { "$($a.text)`n`n" }) + $b)
}

# github/gitlab ids: "12", "#12", "owner/name#12"
function __GhHost { [string](Get-KitValue 'githubHost' $(if ($script:HostType -eq 'github' -and $KitConf.GitHost -notmatch 'gitlab') { $KitConf.GitHost } else { 'github.com' })) }   # GHE: the origin host
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
# parent from "Part of #n", subtasks from task-list lines "- [ ] #n" ($Sub maps each)
function __TrIssue($Num, $Name, $St, $Url, $Who, $Repo, [string]$Body, [scriptblock]$Sub) {
  __TrTask "$Num" $Name $St $Url $(if ($Body -match '(?m)^Part of #(\d+)') { $Matches[1] }) $Who $Repo @([regex]::Matches($Body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object $Sub) $Body
}
# --body-file: no argv length / quoting limits
function __TrGhBody([string[]]$A, [string]$Text) {
  if ($__trDry) { return (__TrCli 'gh' ($A + @('--body', $Text))) }
  $f = __TrTemp $Text; try { __TrCli 'gh' ($A + @('--body-file', $f)) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
function __TrGl([string]$Method, [string]$Path, $Body) {
  $a = @('api', '-X', $Method, $Path)
  if ($null -ne $Body) {
    if ($__trDry) { Write-Host "DRYRUN: glab api -X $Method $Path  body=$(__TrShort ($Body | ConvertTo-Json -Depth 10 -Compress))"; return $null }
    $f = __TrTemp ($Body | ConvertTo-Json -Depth 10 -Compress)
    try { return __TrJson (__TrCli 'glab' ($a + @('-H', 'Content-Type: application/json', '--input', $f))) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
  __TrJson (__TrCli 'glab' $a)
}
function __TrGlPath([string]$Id, [string]$Sub = '') { $r, $n = __TrRef $Id; "projects/$([uri]::EscapeDataString($r))/issues/$n$Sub" }

# jira: Cloud = REST v3 + ADF; jira-server = v2 + plain text
function __TrAdf([string]$Text) {
  $paras = @(("$Text" -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' } | ForEach-Object { @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $_ }) } })
  if (-not $paras.Count) { $paras = @(@{ type = 'paragraph'; content = @() }) }
  @{ type = 'doc'; version = 1; content = $paras }
}
function __TrAdfText($n) {
  if ($null -eq $n) { return '' }
  if ($n -is [string]) { return $n }
  if ($n.type -eq 'text') { return [string]$n.text }
  $inner = (@($n.content) | ForEach-Object { __TrAdfText $_ }) -join ''
  if ($n.type -in 'paragraph', 'heading', 'listItem', 'codeBlock') { "$inner`n" } else { $inner }
}
function __TrJDoc([string]$t) { if ($__trType -eq 'jira') { __TrAdf $t } else { $t } }
function __TrJira([string]$Method, [string]$Path, $Body, [string]$FilePath) {
  $h = if ($__trType -ne 'jira' -and $env:JIRA_TOKEN) { Get-KitAuth JIRA_TOKEN } elseif ($env:JIRA_EMAIL -and $env:JIRA_API_TOKEN) { @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)")) } } else { @{} }
  if (-not $__trDry -and -not ($env:JIRA_BASE_URL -and $h.Authorization)) { throw "tracker ($__trType): set JIRA_BASE_URL and JIRA_EMAIL + JIRA_API_TOKEN$(if ($__trType -ne 'jira') { ' (or JIRA_TOKEN)' })" }
  $h.Accept = 'application/json'; if ($FilePath) { $h['X-Atlassian-Token'] = 'no-check' }
  __TrHttp $Method "$(__TrBase JIRA_BASE_URL)/rest/api/$(if ($__trType -eq 'jira') { 3 } else { 2 })/$Path" $Body $h $FilePath
}

# none: local log + store
function __TrNone([string]$Id, [string]$What, [scriptblock]$Change) {
  $d = Get-KitPath tracker-none -Create
  Add-Content (Get-KitPath tracker-log -Create) ("{0} {1} {2}" -f (Get-Date -Format s), $Id, (__TrShort $What)) -Encoding utf8
  if (-not $Id) { return $null }
  $f = Join-Path $d "$($Id -replace '[^\w.-]', '_').json"
  $o = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
  if ($Change) { if (-not $o) { $o = [pscustomobject]@{ id = $Id; name = ''; status = ''; parent = $null; list = ''; assignees = @(); description = ''; comments = @() } }; & $Change $o; $o | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8 }
  $o
}
function __TrNoneAll { Get-ChildItem $__trNoneDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } }
function __TrNoneNote($o, [string]$t) { $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = $t }) }

# owner = tracker.owner, else the OS user's full name among members, else the CLI user
function __TrOsFullName {
  $n = ''
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    try { $n = (Get-LocalUser $env:USERNAME -ErrorAction Stop).FullName } catch {}
    if (-not $n) { try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement; $n = [System.DirectoryServices.AccountManagement.UserPrincipal]::Current.DisplayName } catch {} }
  } else { try { $n = ((getent passwd $env:USER) -split ':')[4] -split ',' | Select-Object -First 1 } catch {} }
  if (-not $n) { try { $n = git config --global user.name } catch {} }
  ([string]$n).Trim()
}
# read-only, so it runs under -DryRun
function __TrClickupMemberId([string]$Who) {
  if (-not $Who) { return $null }
  $__trDry = $false
  $m = @(__TrJson (__TrCli 'clickup' @('member', 'list', '--json'))) | Where-Object { $_ -and ($_.username -eq $Who -or ($_.email -and $_.email -eq $Who)) } | Select-Object -First 1
  if ($m) { [string]$m.id } else { $null }
}

# ----- backends: $a = id, text, status (tracker name), logical, name, list, parent, assignee, priority, file, leaf
# adapter:tracker/clickup: clickup CLI
Register-KitAdapter 'tracker' 'clickup' @{
  'url' = { param($a) "https://app.clickup.com/t/$($a.id)" }
  'view' = { param($a)
    $j = __TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--json')); if (-not $j.id) { return }
    __TrTask $j.id $j.name ([string]$j.status.status) $(if ($j.url) { $j.url } else { Get-TrackerUrl $j.id }) $j.parent @($j.assignees | ForEach-Object { if ($_.username) { $_.username } else { $_.id } }) ([string]$j.list.id) @($j.subtasks | ForEach-Object { __TrSub $_.id $_.name ([string]$_.status.status) (Get-TrackerUrl $_.id) }) ([string]$(if ($j.markdown_description) { $j.markdown_description } else { $j.description }))
  }
  'status' = { param($a)
    # per-list status names: try each alias; none fits = fail
    $names = @($a.status); foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $a.logical) { $names = @($__trStatus[$k]) } }
    foreach ($n in $names) { $out = __TrCli 'clickup' @('status', 'set', $n, $a.id); if ("$out" -notmatch 'no matching status') { return $out } }
    if (-not $__trDry) { throw "tracker (clickup): no status '$($names -join "' / '")' on the list of task $($a.id) (set tracker.statuses.$($a.logical) in kit.local.json)" }
  }
  'comment' = { param($a) __TrCli 'clickup' @('comment', 'add', $a.id, $a.text) }
  'comments' = { param($a) @(__TrJson (__TrCli 'clickup' @('comment', 'list', $a.id, '--json'))) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.user.username; date = (__TrDate $_.date); text = [string]$_.comment_text } } }
  'create' = { param($a)
    $c = @('task', 'create', '--list-id', $a.list, '--name', $a.name, '--markdown-description', $a.description, '--json'); $as = $a.assignee
    if ($a.priority) { $c += @('--priority', $a.priority) }
    # ClickUp needs a member id
    if ($as -and $as -notmatch '^\d+$') {
      $as = try { __TrClickupMemberId $as } catch { Write-Warning "tracker: member lookup failed ($($_.Exception.Message))"; $null }
      if (-not $as) { [Console]::Error.WriteLine("WARNING: tracker: no ClickUp member '$($a.assignee)' (clickup member list): task unassigned (assigned=false)") }
    }
    if ($as) { $c += @('--assignee', $as) }
    if ($__trDry) { $null = __TrCli 'clickup' ($c + @(if ($a.parent) { '--parent', $a.parent })); return [pscustomobject]@{ id = '<new>'; url = ''; assigned = [bool]$as } }
    # ClickUp rejects cross-list parents: link by comment
    $t = if ($a.parent) { try { __TrJson (__TrCli 'clickup' ($c + @('--parent', $a.parent))) } catch { $null } }
    $dropped = $a.parent -and -not $t.id; if (-not $t.id) { $t = __TrJson (__TrCli 'clickup' $c) }
    if (-not $t.id) { return }
    if ($dropped) { $null = Add-TrackerComment $t.id "Related: $(Get-TrackerUrl $a.parent) (not its subtask: it is in another list)." }
    [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }); assigned = [bool]$as }
  }
  'describe' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--markdown-description', $a.text) }
  'rename' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--name', $a.name) }
  'attach' = { param($a) __TrCli 'clickup' @('attachment', 'add', $a.id, $a.file); __TrNote $a }
  'list' = { param($a)
    foreach ($pg in 0..6) {
      $arr = @(@(__TrJson (__TrCli 'clickup' @('task', 'list', '--list-id', $a.list, '--status', $a.status, '--page', "$pg", '--json'))) | Where-Object { $_ -and $_.id })
      foreach ($t in $arr) { __TrRow ([string]$t.id) ([string]$t.name) $a.status @($t.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
      if ($arr.Count -lt 100) { break }
    }
  }
  'owner' = { param($a) if ($a.name) { __TrClickupMemberId $a.name } }
}
# adapter:tracker/github: gh CLI; status = a <tracker.statusLabelPrefix><name> label (closed = closed issue)
Register-KitAdapter 'tracker' 'github' @{
  'url' = { param($a) $r, $n = __TrRef $a.id; "https://$(__GhHost)/$r/issues/$n" }
  'view' = { param($a)
    $r, $n = __TrRef $a.id
    $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'number,title,state,url,labels,assignees,body')); if (-not $j.number) { return }
    __TrIssue $j.number $j.title (__TrLabelStatus @($j.labels.name) ($j.state -eq 'CLOSED')) $j.url @($j.assignees.login) $r ([string]$j.body) {
      $s = __TrJson (__TrCli 'gh' @('issue', 'view', $_, '-R', $r, '--json', 'number,title,state,labels'))
      __TrSub "$_" $s.title (__TrLabelStatus @($s.labels.name) ($s.state -eq 'CLOSED')) (Get-TrackerUrl $_) }
  }
  'status' = { param($a)
    $r, $n = __TrRef $a.id; $name = $a.status
    $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'state,labels'))
    $old = @($j.labels.name | Where-Object { $_ -like "$__trLp*" -and $_ -ne "$__trLp$name" })
    $edit = @('issue', 'edit', $n, '-R', $r); foreach ($o in $old) { $edit += @('--remove-label', $o) }
    if (__TrIsClosed $name) { if ($old) { $null = __TrCli 'gh' $edit }; return (__TrCli 'gh' @('issue', 'close', $n, '-R', $r)) }
    if ($j.state -eq 'CLOSED') { $null = __TrCli 'gh' @('issue', 'reopen', $n, '-R', $r) }
    $null = __TrCli 'gh' @('label', 'create', "$__trLp$name", '-R', $r, '--force', '--color', 'ededed')
    __TrCli 'gh' ($edit + @('--add-label', "$__trLp$name"))
  }
  'comment' = { param($a) $r, $n = __TrRef $a.id; __TrGhBody @('issue', 'comment', $n, '-R', $r) $a.text }
  'comments' = { param($a) $r, $n = __TrRef $a.id; @((__TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'comments'))).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.login; date = (__TrDate $_.createdAt); text = [string]$_.body } } }
  'create' = { param($a)
    $r = __TrRepoOf $a.list; $c = @('issue', 'create', '-R', $r, '--title', $a.name)
    if ($a.assignee) { $c += @('--assignee', $a.assignee) }
    if ($a.priority) { $pl = "priority:$(__TrPrio $a.priority)"; $null = __TrCli 'gh' @('label', 'create', $pl, '-R', $r, '--force', '--color', 'ededed'); $c += @('--label', $pl) }
    $out = __TrGhBody $c ((__TrPartOf $a) + $a.description)
    $num = if ("$out" -match '/issues/(\d+)') { $Matches[1] } elseif ($__trDry) { '<new>' } else { return }
    if ($a.parent) {   # task-list line = subtask
      $pn = $a.parent -replace '^.*#', ''
      $null = __TrGhBody @('issue', 'edit', $pn, '-R', $r) (([string](__TrJson (__TrCli 'gh' @('issue', 'view', $pn, '-R', $r, '--json', 'body'))).body).TrimEnd() + "`n- [ ] #$num")
    }
    [pscustomobject]@{ id = "$num"; url = $(if ("$out" -match '(https://\S+/issues/\d+)') { $Matches[1] } else { Get-TrackerUrl "$r#$num" }) }
  }
  'describe' = { param($a) $r, $n = __TrRef $a.id; __TrGhBody @('issue', 'edit', $n, '-R', $r) $a.text }
  'rename' = { param($a) $r, $n = __TrRef $a.id; __TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--title', $a.name) }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $c = @('issue', 'list', '-R', (__TrRepoOf $a.list), '--limit', '200', '--json', 'number,title,assignees')
    $c += if (__TrIsClosed $a.status) { @('--state', 'closed') } else { @('--state', 'open', '--label', "$__trLp$($a.status)") }
    @(__TrJson (__TrCli 'gh' $c)) | Where-Object { $_ -and $_.number } | ForEach-Object { __TrRow "$($_.number)" ([string]$_.title) $a.status @($_.assignees | ForEach-Object { __TrWho $_.login $_.login }) }
  }
  'owner' = { param($a) [string](__TrCli 'gh' @('api', 'user', '--jq', '.login')) }
}
# adapter:tracker/gitlab: glab api; labels, parent, subtasks as on github
Register-KitAdapter 'tracker' 'gitlab' @{
  'url' = { param($a) $r, $n = __TrRef $a.id; "https://$($KitConf.GitHost)/$r/-/issues/$n" }
  'view' = { param($a)
    $j = __TrGl 'GET' (__TrGlPath $a.id) $null; if (-not $j.iid) { return }
    __TrIssue $j.iid $j.title (__TrLabelStatus @($j.labels) ($j.state -eq 'closed')) $j.web_url @($j.assignees.username) (__TrRef $a.id)[0] ([string]$j.description) {
      $s = __TrGl 'GET' (__TrGlPath $_) $null; __TrSub "$_" $s.title (__TrLabelStatus @($s.labels) ($s.state -eq 'closed')) $s.web_url }
  }
  'status' = { param($a)
    $p = __TrGlPath $a.id; $name = $a.status; $j = __TrGl 'GET' $p $null
    $old = @($j.labels | Where-Object { $_ -like "$__trLp*" -and $_ -ne "$__trLp$name" })
    $b = @{}; if ($old) { $b.remove_labels = $old -join ',' }
    if (__TrIsClosed $name) { $b.state_event = 'close' } else { $b.add_labels = "$__trLp$name"; if ($j.state -eq 'closed') { $b.state_event = 'reopen' } }
    $res = __TrGl 'PUT' $p $b; if ($res) { "status of #$($res.iid): $name" }
  }
  'comment' = { param($a) $res = __TrGl 'POST' (__TrGlPath $a.id '/notes') @{ body = $a.text }; if ($res) { "commented on #$((__TrRef $a.id)[1])" } }
  'comments' = { param($a) @(__TrGl 'GET' (__TrGlPath $a.id '/notes?sort=asc&per_page=100') $null) | Where-Object { $_ -and -not $_.system } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.username; date = (__TrDate $_.created_at); text = [string]$_.body } } }
  'create' = { param($a)
    $r = __TrRepoOf $a.list; $b = @{ title = $a.name; description = (__TrPartOf $a) + $a.description }
    if ($a.priority) { $b.labels = "priority:$(__TrPrio $a.priority)" }
    if ($a.assignee) { $u = @(__TrGl 'GET' "users?username=$([uri]::EscapeDataString($a.assignee))" $null) | Select-Object -First 1; if ($u.id) { $b.assignee_ids = @($u.id) } }
    $t = __TrGl 'POST' "projects/$([uri]::EscapeDataString($r))/issues" $b
    $iid = if ($t.iid) { $t.iid } elseif ($__trDry) { '<new>' } else { return }
    if ($a.parent) { $p = __TrGlPath "$r#$($a.parent -replace '^.*#', '')"; $null = __TrGl 'PUT' $p @{ description = ([string](__TrGl 'GET' $p $null).description).TrimEnd() + "`n- [ ] #$iid" } }
    [pscustomobject]@{ id = "$iid"; url = $(if ($t.web_url) { $t.web_url } else { Get-TrackerUrl "$r#$iid" }) }
  }
  'describe' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id) @{ description = $a.text }; "described #$((__TrRef $a.id)[1])" }
  'rename' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id) @{ title = $a.name }; "renamed #$((__TrRef $a.id)[1])" }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $q = if (__TrIsClosed $a.status) { 'state=closed' } else { "state=opened&labels=$([uri]::EscapeDataString("$__trLp$($a.status)"))" }
    @(__TrGl 'GET' "projects/$([uri]::EscapeDataString((__TrRepoOf $a.list)))/issues?$q&per_page=100" $null) | Where-Object { $_ -and $_.iid } | ForEach-Object { __TrRow "$($_.iid)" ([string]$_.title) $a.status @($_.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
  }
  'owner' = { param($a) [string](__TrGl 'GET' 'user' $null).username }
}
# adapter:tracker/jira: Jira Cloud (JIRA_BASE_URL + JIRA_EMAIL + JIRA_API_TOKEN), also jira-server
Register-KitAdapter 'tracker' 'jira' @{
  'url' = { param($a) "$(__TrBase JIRA_BASE_URL)/browse/$($a.id)" }
  'view' = { param($a)
    $j = __TrJira 'GET' "issue/$($a.id)?fields=summary,status,parent,assignee,subtasks,project,description" $null; if (-not $j.key) { return }
    $f = $j.fields
    __TrTask $j.key $f.summary ([string]$f.status.name) (Get-TrackerUrl $j.key) $f.parent.key @($f.assignee | Where-Object { $_ } | ForEach-Object { $_.displayName }) ([string]$f.project.key) @($f.subtasks | ForEach-Object { __TrSub $_.key $_.fields.summary ([string]$_.fields.status.name) (Get-TrackerUrl $_.key) }) (__TrAdfText $f.description).Trim()
  }
  'status' = { param($a)
    $id = $a.id; $name = $a.status; $t = __TrJira 'GET' "issue/$id/transitions" $null
    $tr = @($t.transitions | Where-Object { $_.name -ieq $name -or $_.to.name -ieq $name }) | Select-Object -First 1
    if (-not $tr -and -not $__trDry) { throw "tracker ($__trType): no transition to '$name' from the current status of $id (have: $(@($t.transitions | ForEach-Object { $_.to.name }) -join ', '))" }
    $null = __TrJira 'POST' "issue/$id/transitions" @{ transition = @{ id = $(if ($tr) { $tr.id } else { "<id of '$name'>" }) } }; "status of $id`: $name"
  }
  'comment' = { param($a) $res = __TrJira 'POST' "issue/$($a.id)/comment" @{ body = (__TrJDoc $a.text) }; if ($res) { "commented on $($a.id)" } }
  'comments' = { param($a) @((__TrJira 'GET' "issue/$($a.id)/comment?maxResults=200" $null).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.displayName; date = (__TrDate $_.created); text = (__TrAdfText $_.body).Trim() } } }
  'create' = { param($a)
    $f = @{ project = @{ key = $a.list }; summary = $a.name; description = (__TrJDoc $a.description)
      issuetype = @{ name = $(if ($a.parent) { Get-KitSetting 'tracker.subtaskType' 'Subtask' } else { Get-KitSetting 'tracker.issueType' 'Task' }) } }
    if ($a.parent) { $f.parent = @{ key = $a.parent } }
    if ($a.assignee) { $f.assignee = if ($__trType -eq 'jira') { @{ accountId = $a.assignee } } else { @{ name = $a.assignee } } }
    if ($a.priority) { $f.priority = @{ name = (__TrPrioName $a.priority ([string](Get-KitSetting 'tracker.priorities' 'Highest High Medium Low'))) } }
    $t = __TrJira 'POST' 'issue' @{ fields = $f }
    if ($t.key) { [pscustomobject]@{ id = $t.key; url = Get-TrackerUrl $t.key } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) $null = __TrJira 'PUT' "issue/$($a.id)" @{ fields = @{ description = (__TrJDoc $a.text) } }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrJira 'PUT' "issue/$($a.id)" @{ fields = @{ summary = $a.name } }; "renamed $($a.id)" }
  'attach' = { param($a) $null = __TrJira 'POST' "issue/$($a.id)/attachments" $null $a.file; "attached $($a.leaf) to $($a.id)"; __TrNote $a }
  'list' = { param($a)
    $q = [uri]::EscapeDataString("project = `"$($a.list)`" AND status = `"$($a.status)`"")
    $j = __TrJira 'GET' "$(if ($__trType -eq 'jira') { 'search/jql' } else { 'search' })?jql=$q&fields=summary,assignee&maxResults=200" $null
    @($j.issues) | Where-Object { $_ -and $_.key } | ForEach-Object { __TrRow $_.key ([string]$_.fields.summary) $a.status @($_.fields.assignee | Where-Object { $_ } | ForEach-Object { __TrWho $(if ($_.accountId) { $_.accountId } else { $_.name }) $_.displayName }) }
  }
  'owner' = { param($a)
    if (-not $a.name) { return }
    $cl = $__trType -eq 'jira'; $k = if ($cl) { 'accountId' } else { 'name' }
    $m = @(__TrJira 'GET' "user/search?$(if ($cl) { 'query' } else { 'username' })=$([uri]::EscapeDataString($a.name))" $null) | Where-Object { $_.displayName -eq $a.name } | Select-Object -First 1
    [string]$(if ($m) { $m.$k } else { (__TrJira 'GET' 'myself' $null).$k })
  }
}
# adapter:tracker/jira-server: Server / Data Center = jira verbs on REST v2 (JIRA_TOKEN bearer or email + token)
Register-KitAdapter 'tracker' 'jira-server' @{ '*' = { param($a, $v) & $KitAdapters.tracker.jira[$v] $a $v } }
# adapter:tracker/linear: GraphQL (LINEAR_API_KEY); ids = identifiers (ENG-12), list = team key, status = workflow state name
function __TrLin([string]$Q, [hashtable]$v = @{}) {
  if (-not $__trDry -and -not $env:LINEAR_API_KEY) { throw 'tracker (linear): set LINEAR_API_KEY' }
  $r = __TrHttp 'POST' 'https://api.linear.app/graphql' @{ query = $Q; variables = $v } @{ Authorization = "$env:LINEAR_API_KEY" }
  if ($r.errors) { throw "tracker (linear): $($r.errors[0].message)" }; $r.data
}
function __TrLinSet([string]$Id, [hashtable]$In) { $null = __TrLin 'mutation($id: String!, $in: IssueUpdateInput!) { issueUpdate(id: $id, input: $in) { success } }' @{ id = $Id; in = $In } }
function __TrLinUser([string]$N) { @((__TrLin 'query($n: String!) { users(filter: { or: [{ name: { eqIgnoreCase: $n } }, { displayName: { eqIgnoreCase: $n } }, { email: { eqIgnoreCase: $n } }] }) { nodes { id } } }' @{ n = $N }).users.nodes.id)[0] }
Register-KitAdapter 'tracker' 'linear' @{
  'url' = { param($a) "https://linear.app/$(Get-KitSetting 'tracker.org' '<tracker.org>')/issue/$($a.id)" }
  'view' = { param($a)
    $i = (__TrLin 'query($id: String!) { issue(id: $id) { identifier title url description state { name } assignee { name } parent { identifier } team { key } children { nodes { identifier title url state { name } } } } }' @{ id = $a.id }).issue
    if (-not $i) { return }
    [pscustomobject]@{ id = $i.identifier; name = $i.title; status = [string]$i.state.name; url = $i.url; parent = $i.parent.identifier; assignees = @($i.assignee.name | Where-Object { $_ }); list = $i.team.key
      subtasks = @($i.children.nodes | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = $_.title; status = [string]$_.state.name; url = $_.url } }); description = [string]$i.description }
  }
  'status' = { param($a)
    $s = @((__TrLin 'query($id: String!) { issue(id: $id) { team { states { nodes { id name } } } } }' @{ id = $a.id }).issue.team.states.nodes | Where-Object { $_.name -ieq $a.status })[0]
    if (-not $s -and -not $__trDry) { throw "tracker (linear): no workflow state '$($a.status)' in the team of $($a.id)" }
    __TrLinSet $a.id @{ stateId = $s.id }; "status of $($a.id): $($a.status)"
  }
  'comment' = { param($a) $null = __TrLin 'mutation($id: String!, $b: String!) { commentCreate(input: { issueId: $id, body: $b }) { success } }' @{ id = $a.id; b = $a.text }; "commented on $($a.id)" }
  'comments' = { param($a) @((__TrLin 'query($id: String!) { issue(id: $id) { comments(first: 200) { nodes { body createdAt user { name } } } } }' @{ id = $a.id }).issue.comments.nodes) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.user.name; date = (__TrDate $_.createdAt); text = [string]$_.body } } }
  'create' = { param($a)
    $in = @{ teamId = @((__TrLin 'query($k: String!) { teams(filter: { key: { eq: $k } }) { nodes { id } } }' @{ k = $a.list }).teams.nodes.id)[0]; title = $a.name; description = $a.description }
    if ($a.parent) { $in.parentId = (__TrLin 'query($id: String!) { issue(id: $id) { id } }' @{ id = $a.parent }).issue.id }
    if ($a.assignee) { $in.assigneeId = if ($a.assignee -match '^[0-9a-f-]{36}$') { $a.assignee } else { __TrLinUser $a.assignee } }
    if ($a.priority -match '^[1-4]$') { $in.priority = [int]$a.priority }   # Linear 1 urgent .. 4 low, as the kit
    $i = (__TrLin 'mutation($in: IssueCreateInput!) { issueCreate(input: $in) { issue { identifier url } } }' @{ in = $in }).issueCreate.issue
    if ($i) { [pscustomobject]@{ id = $i.identifier; url = $i.url } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) __TrLinSet $a.id @{ description = $a.text }; "described $($a.id)" }
  'rename' = { param($a) __TrLinSet $a.id @{ title = $a.name }; "renamed $($a.id)" }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $f = @{ state = @{ name = @{ eqIgnoreCase = $a.status } } }; if ($a.list) { $f.team = @{ key = @{ eq = $a.list } } }
    @((__TrLin 'query($f: IssueFilter) { issues(filter: $f, first: 200) { nodes { identifier title assignee { id name } } } }' @{ f = $f }).issues.nodes) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = [string]$_.title; status = $a.status; assignees = @($_.assignee | Where-Object { $_ } | ForEach-Object { __TrWho $_.id $_.name }) } }
  }
  'owner' = { param($a) $u = if ($a.name) { __TrLinUser $a.name }; if ($u) { $u } else { (__TrLin 'query { viewer { id } }').viewer.id } }
}
# adapter:tracker/azure: Azure Boards work items (REST 7.1; tracker.org + tracker.project, AZURE_DEVOPS_EXT_PAT); list = area path; HTML text
function __TrAz([string]$Method, [string]$Path, $Body, [string]$CType, [string]$File) {
  if (-not $__trDry -and -not $env:AZURE_DEVOPS_EXT_PAT) { throw 'tracker (azure): set AZURE_DEVOPS_EXT_PAT' }
  $u = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '<tracker.org>')/$(if ($Path -notmatch '^/') { [uri]::EscapeDataString((Get-KitSetting 'tracker.project' '<tracker.project>')) + '/' })_apis/$($Path.TrimStart('/'))"
  __TrHttp $Method "$u$(if ($u -match '\?') { '&' } else { '?' })api-version=7.1$(if ($Path -match '/comments') { '-preview.4' })" $Body (Get-KitAuth AZURE_DEVOPS_EXT_PAT basic) $File $CType
}
function __TrAzSet($Id, $F) { __TrAz 'PATCH' "wit/workitems/$Id" @(foreach ($k in @($F.Keys)) { @{ op = 'add'; path = "/fields/$k"; value = $F[$k] } }) 'application/json-patch+json' }
function __TrHtml([string]$t) { [Net.WebUtility]::HtmlEncode($t) -replace "`r?`n", '<br>' }
function __TrUnHtml([string]$t) { [Net.WebUtility]::HtmlDecode(($t -replace '<br\s*/?>|</(p|div|li)>', "`n" -replace '<[^>]+>')).Trim() }
Register-KitAdapter 'tracker' 'azure' @{
  'url' = { param($a) "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '<tracker.org>')/$(Get-KitSetting 'tracker.project' '<tracker.project>')/_workitems/edit/$($a.id)" }
  'view' = { param($a)
    $j = __TrAz 'GET' "wit/workitems/$($a.id)?`$expand=relations" $null; if (-not $j.id) { return }
    $f = $j.fields; $rel = { param($t) @($j.relations | Where-Object { $_.rel -eq "System.LinkTypes.Hierarchy-$t" } | ForEach-Object { $_.url -replace '^.*/' }) }; $kids = @(& $rel Forward)
    [pscustomobject]@{ id = "$($j.id)"; name = $f.'System.Title'; status = [string]$f.'System.State'; url = Get-TrackerUrl $j.id; parent = @(& $rel Reverse)[0]
      assignees = @($f.'System.AssignedTo'.displayName | Where-Object { $_ }); list = [string]$f.'System.AreaPath'; description = (__TrUnHtml $f.'System.Description')
      subtasks = @(if ($kids) { (__TrAz 'GET' "wit/workitems?ids=$($kids -join ',')&fields=System.Title,System.State" $null).value | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; name = $_.fields.'System.Title'; status = [string]$_.fields.'System.State'; url = Get-TrackerUrl $_.id } } }) }
  }
  'status' = { param($a) $null = __TrAzSet $a.id @{ 'System.State' = $a.status }; "status of $($a.id): $($a.status)" }
  'comment' = { param($a) $null = __TrAz 'POST' "wit/workItems/$($a.id)/comments" @{ text = (__TrHtml $a.text) }; "commented on $($a.id)" }
  'comments' = { param($a) @((__TrAz 'GET' "wit/workItems/$($a.id)/comments" $null).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.createdBy.displayName; date = (__TrDate $_.createdDate); text = (__TrUnHtml $_.text) } } }
  'create' = { param($a)
    $o = @(foreach ($kv in ([ordered]@{ 'System.Title' = $a.name; 'System.Description' = (__TrHtml $a.description); 'System.AreaPath' = $a.list; 'System.AssignedTo' = $a.assignee; 'Microsoft.VSTS.Common.Priority' = $(if ($a.priority -match '^[1-4]$') { [int]$a.priority }) }).GetEnumerator()) { if ($kv.Value) { @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value } } })
    if ($a.parent) { $o += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '')/_apis/wit/workItems/$($a.parent)" } } }
    $t = __TrAz 'POST' "wit/workitems/`$$([uri]::EscapeDataString((Get-KitSetting 'tracker.issueType' 'Task')))" $o 'application/json-patch+json'
    if ($t.id) { [pscustomobject]@{ id = "$($t.id)"; url = Get-TrackerUrl $t.id } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) $null = __TrAzSet $a.id @{ 'System.Description' = (__TrHtml $a.text) }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrAzSet $a.id @{ 'System.Title' = $a.name }; "renamed $($a.id)" }
  'attach' = { param($a)
    $u = __TrAz 'POST' "wit/attachments?fileName=$([uri]::EscapeDataString($a.leaf))" $null 'application/octet-stream' $a.file
    $null = __TrAz 'PATCH' "wit/workitems/$($a.id)" @(@{ op = 'add'; path = '/relations/-'; value = @{ rel = 'AttachedFile'; url = $u.url } }) 'application/json-patch+json'; "attached $($a.leaf) to $($a.id)"; __TrNote $a
  }
  'list' = { param($a)
    $q = "SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = @project AND [System.State] = '$($a.status -replace "'", "''")'$(if ($a.list) { " AND [System.AreaPath] UNDER '$($a.list -replace "'", "''")'" })"
    $ids = @((__TrAz 'POST' 'wit/wiql?$top=200' @{ query = $q }).workItems.id | Where-Object { $_ })
    if ($ids) { (__TrAz 'GET' "wit/workitems?ids=$($ids -join ',')&fields=System.Title,System.AssignedTo" $null).value | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; name = [string]$_.fields.'System.Title'; status = $a.status; assignees = @($_.fields.'System.AssignedTo' | Where-Object { $_ } | ForEach-Object { __TrWho $_.uniqueName $_.displayName }) } } }
  }
  'owner' = { param($a) if ($a.name) { $a.name } else { [string](__TrAz 'GET' '/connectionData' $null).authenticatedUser.providerDisplayName } }
}
# adapter:tracker/youtrack: REST /api (YOUTRACK_URL + YOUTRACK_TOKEN); fields State / Assignee; changes by commands; list = project short name
function __TrYt([string]$Method, [string]$Path, $Body, [string]$File) {
  if (-not $__trDry -and -not ($env:YOUTRACK_URL -and $env:YOUTRACK_TOKEN)) { throw 'tracker (youtrack): set YOUTRACK_URL and YOUTRACK_TOKEN' }
  __TrHttp $Method "$(__TrBase YOUTRACK_URL)/api/$Path" $Body ((Get-KitAuth YOUTRACK_TOKEN) + @{ Accept = 'application/json' }) $File
}
function __TrYtCmd([string]$Id, [string]$Q) { $null = __TrYt 'POST' 'commands' @{ query = $Q; issues = @(@{ idReadable = $Id }) } }
function __TrYtF($i, [string]$N) { @($i.customFields | Where-Object { $_.name -eq $N })[0].value }
$__trYtFields = 'idReadable,summary,description,project(shortName),parent(issues(idReadable)),subtasks(issues(idReadable,summary,customFields(name,value(name)))),customFields(name,value(name,login))'
Register-KitAdapter 'tracker' 'youtrack' @{
  'url' = { param($a) "$(__TrBase YOUTRACK_URL)/issue/$($a.id)" }
  'view' = { param($a)
    $i = __TrYt 'GET' "issues/$($a.id)?fields=$__trYtFields" $null; if (-not $i.idReadable) { return }
    [pscustomobject]@{ id = $i.idReadable; name = $i.summary; status = [string](__TrYtF $i State).name; url = Get-TrackerUrl $i.idReadable; parent = @($i.parent.issues.idReadable)[0]
      assignees = @(__TrYtF $i Assignee | Where-Object { $_ } | ForEach-Object { $_.login }); list = [string]$i.project.shortName; description = [string]$i.description
      subtasks = @($i.subtasks.issues | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.idReadable; name = $_.summary; status = [string](__TrYtF $_ State).name; url = Get-TrackerUrl $_.idReadable } }) }
  }
  'status' = { param($a) __TrYtCmd $a.id "State {$($a.status)}"; "status of $($a.id): $($a.status)" }
  'comment' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)/comments?fields=id" @{ text = $a.text }; "commented on $($a.id)" }
  'comments' = { param($a) @(__TrYt 'GET' "issues/$($a.id)/comments?fields=text,created,author(login)&`$top=200" $null) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.login; date = (__TrDate $_.created); text = [string]$_.text } } }
  'create' = { param($a)
    $p = @(__TrYt 'GET' 'admin/projects?fields=id,shortName&$top=500' $null | Where-Object { $_.shortName -eq $a.list })[0]
    if (-not $p -and -not $__trDry) { throw "tracker (youtrack): no project '$($a.list)' (tracker.list = a project short name)" }
    $t = __TrYt 'POST' 'issues?fields=idReadable' @{ project = @{ id = $p.id }; summary = $a.name; description = $a.description }
    $id = if ($t.idReadable) { $t.idReadable } elseif ($__trDry) { '<new>' } else { return }
    $c = @(if ($a.parent) { "subtask of $($a.parent)" }; if ($a.assignee) { "for $($a.assignee)" }; if ($a.priority) { "Priority $(__TrPrioName $a.priority ([string](Get-KitSetting 'tracker.priorities' 'Critical Major Normal Minor')))" })
    if ($c) { __TrYtCmd $id ($c -join ' ') }
    [pscustomobject]@{ id = $id; url = Get-TrackerUrl $id }
  }
  'describe' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)?fields=idReadable" @{ description = $a.text }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)?fields=idReadable" @{ summary = $a.name }; "renamed $($a.id)" }
  'attach' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)/attachments?fields=id" $null $a.file; "attached $($a.leaf) to $($a.id)"; __TrNote $a }
  'list' = { param($a)
    $q = [uri]::EscapeDataString("$(if ($a.list) { "project: {$($a.list)} " })State: {$($a.status)}")
    @(__TrYt 'GET' "issues?query=$q&fields=idReadable,summary,customFields(name,value(login,name))&`$top=200" $null) | Where-Object { $_.idReadable } | ForEach-Object { [pscustomobject]@{ id = $_.idReadable; name = [string]$_.summary; status = $a.status; assignees = @(__TrYtF $_ Assignee | Where-Object { $_ } | ForEach-Object { __TrWho $_.login $_.name }) } }
  }
  'owner' = { param($a) $m = if ($a.name) { @(__TrYt 'GET' "users?query=$([uri]::EscapeDataString($a.name))&fields=login,fullName" $null | Where-Object { $_.fullName -eq $a.name })[0] }; [string]$(if ($m) { $m.login } else { (__TrYt 'GET' 'users/me?fields=login' $null).login }) }
}
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
Initialize-KitTracker

# ----- verbs: dispatch to the tracker.type backend
function __TrA([string]$Verb, [hashtable]$A) { Invoke-KitAdapter 'tracker' $__trType $Verb $A }
function Get-TrackerUrl([string]$Id) { __TrA 'url' @{ id = $Id } }

# reads memoised 90 s; writes drop the entry
if (-not $global:KitTrackerMemo) { $global:KitTrackerMemo = @{} }
function Get-TrackerTask([string]$Id) {
  $mk = "$($__trType)|$Id"
  if ($global:KitTrackerMemo.ContainsKey($mk) -and ((Get-Date) - $global:KitTrackerMemo[$mk].at).TotalSeconds -lt 90) { return $global:KitTrackerMemo[$mk].v }
  $v = __Get-TrackerTask $Id
  if ($v -and $v.name) { $global:KitTrackerMemo[$mk] = @{ at = Get-Date; v = $v } }
  $v
}
function Clear-TrackerMemo([string]$Id) { $global:KitTrackerMemo.Remove("$($__trType)|$Id") }
function __Get-TrackerTask([string]$Id) { $v = __TrA 'view' @{ id = $Id }; if ($v.id) { $v } else { __TrStub $Id } }

# network-lost writes -> outbox ("QUEUED ..."), replayed by supervise; KIT_NO_OUTBOX=1: off
function Add-KitOutbox([string]$Op, [string]$Id, [string]$Arg, [string]$Why) {
  $f = Get-KitPath outbox -Create
  $line = [ordered]@{ at = (Get-Date).ToString('o'); op = $Op; id = $Id; arg = $Arg; tracker = $__trType; tries = 0; why = $Why } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
  Write-Warning "tracker ($__trType): $Op $Id failed on the network ($Why): queued; orch.ps1 supervise replays it"
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
# network failures stay (tries + 1); GAVE UP (by hand): status > 24 h, 20 fails or a real error
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
# <List>: ClickUp list id, GitHub owner/name, GitLab group/project, Jira project key
function Get-TrackerTasks([string]$List, [string]$Status) {
  if (-not $List) { $List = [string]$(if ($__trType -in 'github', 'gitlab') { $__trRepo } else { Get-KitSetting 'tracker.list' '' }) }
  __TrA 'list' @{ list = $List; status = (Resolve-TrackerStatus $Status); logical = $Status }
}

# ===== 5. git-host + ci adapters (README "Adapters"): Invoke-HostVerb <verb> @{ repo = '<group/name>'; n; ... } =====
# MRs are GitLab-shaped (__GhMr: iid, state opened|merged|closed, ..., head_pipeline { id, status }); CI words: __CiWord.
function Get-HostKind([string]$HostName) { switch -Regex ($HostName) { 'github' { 'github' } 'bitbucket' { 'bitbucket' } 'dev\.azure\.com|visualstudio\.com' { 'azure' } 'gitea|forgejo|codeberg' { 'gitea' } default { 'gitlab' } } }
# gitHost unset: the origin host of the first repos[] checkout
if (-not (Get-KitValue 'gitHost' '') -and ($__o = @(@(Get-KitValue 'repos' @()).checkout | Where-Object { $_ -and (Test-Path $_) })[0]) -and "$(git -C $__o remote get-url origin 2>$null)" -match '^(?:\w+://)?(?:[^@/]+@)?(?:ssh\.)?([^/:]+)') { $KitConf.GitHost = $Matches[1] }
$script:HostType = [string](Get-KitValue 'gitHostType' (Get-HostKind $KitConf.GitHost))
if ($script:HostType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
if ($script:HostType -eq 'github' -and -not $env:GH_HOST -and (__GhHost) -ne 'github.com') { $env:GH_HOST = [string](__GhHost) }
# MR/PR URL of any host -> @{ repo; n; type } (Azure: org/project/repo)
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
# repos[] (name, alias or last path segment) key: mergeMethod, deleteBranch, ci
function Get-RepoConf([string]$Repo, [string]$Key, $Default) {
  $n = ("$Repo" -split '/')[-1]
  foreach ($r in @(Get-KitValue 'repos' @())) { if (($r.name -in $n, $Repo -or @($r.aliases) -contains $n) -and "$($r.$Key)" -ne '') { return $r.$Key } }
  $Default
}
function Get-KitCiType([string]$Repo, [string]$HostT = $script:HostType) { $c = [string](Get-RepoConf $Repo 'ci' 'host'); if ($c -eq 'external') { $c = [string](Get-KitSetting 'ci.type' 'host') }; if ($c -eq 'host') { $HostT } else { $c } }
function __HostJson($out) { $t = (@($out) | ForEach-Object { "$_" }) -join "`n"; if (-not $t.Trim()) { return $null }; try { $t | ConvertFrom-Json } catch { $null } }
function __Enc([string]$s) { [uri]::EscapeDataString($s) }
function __Del($a) { [bool](Get-RepoConf $a.repo 'deleteBranch' $true) }
function __Query([string]$q) { $h = @{}; foreach ($kv in ($q -split '&' | Where-Object { $_ })) { $k, $v = $kv -split '=', 2; $h[[uri]::UnescapeDataString($k)] = [uri]::UnescapeDataString("$v") }; $h }
function __HostSet([string]$Key, $Default) { Get-KitSetting "gitHostApi.$Key" $Default }
# glab / gh api: -Fields as -f k=v or -Json; -Res = { code, out, err }
function __Cli([string]$Exe, [string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) {
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }
  $a = @('api'); if ($Method -ne 'GET') { $a += @('-X', $Method) }; $a += $Path; $f = $null
  if ($Json) { $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, ($Fields | ConvertTo-Json -Compress -Depth 10)); $a += @('-H', 'Content-Type: application/json', '--input', $f) }
  else { foreach ($k in $Fields.Keys) { $a += @('-f', "$k=$($Fields[$k])") } }
  try { $r = Invoke-KitRetry { Invoke-KitExe $Exe $a (Get-KitNetTimeout) } -Connect:($Method -ne 'GET') } finally { if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
  if ($Res) { return $r }
  if ($r.code) { $global:KitHostFailed = $true; if ($r.timedOut -or (Test-KitTransient $r.err)) { Write-Warning "githost: $Exe api $Path failed on the network: $($r.err)" }; return $null }
  if ($Path -match '/(trace|logs)$') { return $r.out }
  __HostJson $r.out
}
function __Gp($a, [string]$Rest, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) { __Cli glab "projects/$(__Enc $a.repo)$Rest" $Method $Fields -Json:$Json -Res:$Res }
function __Gl([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) { __Cli glab $Path $Method $Fields -Json:$Json -Res:$Res }
function __GhApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json) { __Cli gh $Path $Method $Fields -Json:$Json }
function __Gh([string[]]$A) { $r = Invoke-KitRetry { Invoke-KitExe gh $A (Get-KitNetTimeout) } -Connect; if ($r.code) { Write-Warning "githost: gh $($A[0..1] -join ' ') failed: $($r.err)" }; $r }
# REST: gitHostApi.url, token env gitHostApi.tokenEnv (never printed); -Probe: 2xx $true, 404 $false, else $null
function __Rest([string]$Base, [string]$Env, [string]$Auth, [string]$Method, [string]$Path, $Body, [switch]$Probe) {
  $u = "$(__HostSet 'url' $Base)/$Path"; $h = Get-KitAuth ([string](__HostSet 'tokenEnv' $Env)) $(if ($Auth -eq 'auto') { if ("$([Environment]::GetEnvironmentVariable([string](__HostSet 'tokenEnv' $Env)))" -match ':') { 'basic' } else { 'bearer' } } else { $Auth })
  if (-not $Probe) { return (Invoke-KitHttp $Method $u $Body $h) }
  try { $null = Invoke-RestMethod -Method $Method -Uri $u -Headers $h -ConnectionTimeoutSeconds (Get-KitNetTimeout); $true } catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { $false } else { $null } }
}
function __Files($files) { @($files | ForEach-Object { [pscustomobject]@{ new_path = $_.filename; old_path = $(if ($_.previous_filename) { $_.previous_filename } else { $_.filename }) } }) }
function __CiWord([string]$w) {
  switch -Regex ($w) { '^(success|successful|succeeded|neutral|passed)$' { 'success' } '^(skipped|not_built|not_executed)$' { 'skipped' } '^(cancel+ed|aborted|stopped)$' { 'canceled' }
    '^(fail|failure|failed|error|errored|broken|infrastructure_fail|timed_out|action_required|startup_failure|unstable|partiallysucceeded)$' { 'failed' } '^(manual|paused|blocked|waiting)$' { 'manual' } '^scheduled$' { 'scheduled' } '^(pending|queued|created|notstarted|postponed)$' { 'pending' } default { 'running' } }
}
function __CiRoll([string[]]$s) { $s = @($s | Where-Object { $_ }); if (-not $s.Count) { return $null }; foreach ($w in 'failed', 'canceled', 'running', 'pending', 'manual', 'scheduled') { if ($s -contains $w) { return $w } }; if ($s -contains 'success') { 'success' } else { 'skipped' } }
# emulated merge-when-green: the intent in tracking.automerge; orch.ps1 track run merges once green
function __KitAuto([string]$Repo, [string]$N, [switch]$Drop) { Update-KitTracking { param($t) if ($Drop) { $t.automerge.Remove("$Repo!$N") } else { $t.automerge["$Repo!$N"] = (Get-Date).ToString('s') } } }

# adapter:git-host/gitlab: glab api
Register-KitAdapter 'git-host' 'gitlab' @{
  'mr.get' = { param($a) __Gp $a "/merge_requests/$($a.n)" }
  'mr.list' = { param($a) @(__Gp $a "/merge_requests?$(($a.Keys | Where-Object { $_ -notin 'repo', 'type' } | Sort-Object | ForEach-Object { "$_=$(__Enc $a[$_])" }) -join '&')") }
  'mr.changes' = { param($a) __Gp $a "/merge_requests/$($a.n)/changes" }
  'mr.create' = { param($a) __Gp $a "/merge_requests" 'POST' @{ source_branch = $a.source; target_branch = $a.target; title = $a.title; description = $a.body; remove_source_branch = (__Del $a); squash = $a.method -eq 'squash' } -Json }
  'mr.merge' = { param($a) $f = @{ squash = "$($a.method -eq 'squash')".ToLower(); should_remove_source_branch = "$((__Del $a))".ToLower() }; if ($a.sha) { $f.sha = $a.sha }; if ($a.auto) { $f.merge_when_pipeline_succeeds = 'true' }; __Gp $a "/merge_requests/$($a.n)/merge" 'PUT' $f }
  'mr.unauto' = { param($a) __Gp $a "/merge_requests/$($a.n)/cancel_merge_when_pipeline_succeeds" 'POST' }
  'mr.url' = { param($a) "https://$($KitConf.GitHost)/$($a.repo)/-/merge_requests/$($a.n)" }
  'repo.base' = { param($a) __Gp $a "/repository/merge_base?refs[]=$(__Enc $a.a)&refs[]=$(__Enc $a.b)" }
  'repo.commit' = { param($a) __Gp $a "/repository/commits/$(__Enc $a.ref)" }
  'repo.compare' = { param($a) __Gp $a "/repository/compare?from=$(__Enc $a.from)&to=$(__Enc $a.to)$(if ($a.straight) { '&straight=true' })" }
}
# adapter:git-host/github: gh (GH_HOST = githubHost); fork PR source = owner:branch
function __GhPr($a) { __GhMr (__GhApi "repos/$($a.repo)/pulls/$($a.n)") }
# the kit's MR shape (host fields mapped in)
function __Mr([hashtable]$H) {
  $o = [ordered]@{ iid = $null; title = ''; state = ''; source_branch = ''; target_branch = ''; sha = ''; merge_commit_sha = $null; squash_commit_sha = $null; merged_at = $null
    updated_at = $null; draft = $false; has_conflicts = $false; detailed_merge_status = ''; merge_when_pipeline_succeeds = $false; web_url = ''; head_pipeline = $null }
  foreach ($k in $H.Keys) { $o[$k] = $H[$k] }; [pscustomobject]$o
}
function __GhMr($p) {
  if (-not $p -or -not $p.number) { return $null }
  [pscustomobject]@{ iid = $p.number; title = $p.title; state = $(if ($p.merged_at -or $p.merged) { 'merged' } elseif ($p.state -eq 'open') { 'opened' } else { 'closed' }); source_branch = $p.head.ref; target_branch = $p.base.ref
    sha = $p.head.sha; merge_commit_sha = $p.merge_commit_sha; merged_at = $p.merged_at; updated_at = $p.updated_at; draft = [bool]$p.draft; has_conflicts = ($p.mergeable -eq $false)
    detailed_merge_status = $(if ($p.mergeable_state -eq 'dirty' -or $p.mergeable -eq $false) { 'conflict' } else { [string]$p.mergeable_state }); merge_when_pipeline_succeeds = [bool]$p.auto_merge; web_url = $p.html_url; squash_commit_sha = $null; head_pipeline = $null }
}
Register-KitAdapter 'git-host' 'github' @{
  'mr.get' = { param($a) __GhPr $a }
  'mr.list' = { param($a)
    $st = switch ("$($a.state)") { 'opened' { 'open' } { $_ -in 'merged', 'closed' } { 'closed' } default { 'all' } }
    $prs = if ($a.search) {
      $q = "repo:$($a.repo) is:pr $($a.search) in:title$(if ($a.state -eq 'merged') { ' is:merged' } elseif ($a.state -eq 'opened') { ' is:open' })"
      @((__GhApi "search/issues?q=$(__Enc $q)&per_page=50").items) | ForEach-Object { __GhApi "repos/$($a.repo)/pulls/$($_.number)" }
    } else { @(__GhApi "repos/$($a.repo)/pulls?state=$st&per_page=$($a.per_page ?? 100)$(if ($a.target_branch) { "&base=$(__Enc $a.target_branch)" })$(if ("$($a.source_branch)" -match ':') { "&head=$(__Enc $a.source_branch)" })") }
    @($prs | ForEach-Object { __GhMr $_ } | Where-Object { $_ -and ($a.state -ne 'merged' -or $_.state -eq 'merged') -and (-not $a.source_branch -or "$($a.source_branch)" -match ':' -or $_.source_branch -eq $a.source_branch) -and
        (-not $a.updated_after -or ($_.updated_at -and [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after)) })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = (__Files (__GhApi "repos/$($a.repo)/pulls/$($a.n)/files?per_page=100")) } }
  'mr.create' = { param($a) __GhMr (__GhApi "repos/$($a.repo)/pulls" 'POST' @{ head = $a.source; base = $a.target; title = $a.title; body = $a.body } -Json) }
  'mr.merge' = { param($a)
    $x = @('pr', 'merge', $a.n, '-R', $a.repo, "--$(if ($a.method -in 'merge', 'rebase') { $a.method } else { 'squash' })"); if (__Del $a) { $x += '--delete-branch' }; if ($a.sha) { $x += @('--match-head-commit', $a.sha) }
    # no required checks: --auto refused ("clean status"): merge now only when green
    if (-not $a.auto -or ("$((__Gh ($x + '--auto')).err)" -match 'clean status' -and (Invoke-HostVerb 'ci.status' @{ repo = $a.repo; sha = $(if ($a.sha) { $a.sha } else { (__GhPr $a).sha }) } -NoMemo).status -eq 'success')) { $null = __Gh $x }
    __GhPr $a
  }
  'mr.unauto' = { param($a) $null = __Gh @('pr', 'merge', $a.n, '-R', $a.repo, '--disable-auto'); __GhPr $a }
  'mr.url' = { param($a) "https://$(__GhHost)/$($a.repo)/pull/$($a.n)" }
  'repo.base' = { param($a) $c = __GhApi "repos/$($a.repo)/compare/$(__Enc $a.a)...$(__Enc $a.b)"; if ($c.merge_base_commit.sha) { [pscustomobject]@{ id = $c.merge_base_commit.sha } } }
  'repo.commit' = { param($a) $c = __GhApi "repos/$($a.repo)/commits/$(__Enc $a.ref)"; if ($c.sha) { [pscustomobject]@{ id = $c.sha; committed_date = $c.commit.committer.date } } }
  'repo.compare' = { param($a) $c = __GhApi "repos/$($a.repo)/compare/$(__Enc $a.from)...$(__Enc $a.to)"; if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } }
}
# adapter:git-host/bitbucket: Bitbucket Cloud REST 2.0; env BITBUCKET_TOKEN ("user:app-password" = basic, else bearer); no native merge-when-green
function __Bb([string]$Path, [string]$Method = 'GET', $Body, [switch]$Probe) { __Rest 'https://api.bitbucket.org/2.0' 'BITBUCKET_TOKEN' 'auto' $Method $Path $Body -Probe:$Probe }
function __BbMr($p) {
  if (-not $p.id) { return $null }
  __Mr @{ iid = $p.id; title = $p.title; state = $(switch ($p.state) { 'OPEN' { 'opened' } 'MERGED' { 'merged' } default { 'closed' } }); source_branch = $p.source.branch.name; target_branch = $p.destination.branch.name
    sha = $p.source.commit.hash; merge_commit_sha = $p.merge_commit.hash; merged_at = $(if ($p.state -eq 'MERGED') { $p.updated_on }); updated_at = $p.updated_on; draft = [bool]$p.draft; web_url = $p.links.html.href }
}
Register-KitAdapter 'git-host' 'bitbucket' @{
  'mr.get' = { param($a) __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)") }
  'mr.list' = { param($a)
    $st = @{ opened = @('OPEN'); merged = @('MERGED'); closed = @('DECLINED', 'SUPERSEDED') }["$($a.state)"]; if (-not $st) { $st = 'OPEN', 'MERGED', 'DECLINED' }
    $q = @(); if ($a.source_branch) { $q += "source.branch.name=`"$($a.source_branch)`"" }; if ($a.target_branch) { $q += "destination.branch.name=`"$($a.target_branch)`"" }; if ($a.search) { $q += "title~`"$($a.search)`"" }; if ($a.updated_after) { $q += "updated_on>$($a.updated_after)" }
    @((__Bb "repositories/$($a.repo)/pullrequests?pagelen=50$(($st | ForEach-Object { "&state=$_" }) -join '')$(if ($q) { '&q=' + (__Enc ($q -join ' AND ')) })").values | ForEach-Object { __BbMr $_ })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = @((__Bb "repositories/$($a.repo)/pullrequests/$($a.n)/diffstat?pagelen=100").values | ForEach-Object { [pscustomobject]@{ new_path = $(if ($_.new) { $_.new.path } else { $_.old.path }); old_path = $(if ($_.old) { $_.old.path } else { $_.new.path }) } }) } }
  'mr.create' = { param($a) __BbMr (__Bb "repositories/$($a.repo)/pullrequests" 'POST' @{ title = $a.title; description = $a.body; source = @{ branch = @{ name = $a.source } }; destination = @{ branch = @{ name = $a.target } }; close_source_branch = (__Del $a) }) }
  'mr.merge' = { param($a)
    if ($a.auto -and (Invoke-HostVerb 'ci.status' @{ repo = $a.repo; sha = $(if ($a.sha) { $a.sha } else { (__BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)")).sha }) } -NoMemo).status -ne 'success') { __KitAuto $a.repo $a.n; $m = __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)"); if ($m) { $m | Add-Member auto_merge 'kit' }; return $m }
    __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)/merge" 'POST' @{ merge_strategy = @{ merge = 'merge_commit'; rebase = 'fast_forward' }["$($a.method)"] ?? 'squash'; close_source_branch = (__Del $a) })
  }
  'mr.unauto' = { param($a) __KitAuto $a.repo $a.n -Drop; __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)") }
  'mr.url' = { param($a) "https://bitbucket.org/$($a.repo)/pull-requests/$($a.n)" }
  'repo.base' = { param($a) $c = __Bb "repositories/$($a.repo)/merge-base/$(__Enc $a.a)..$(__Enc $a.b)"; if ($c.hash) { [pscustomobject]@{ id = $c.hash } } }
  'repo.commit' = { param($a) $c = __Bb "repositories/$($a.repo)/commit/$(__Enc $a.ref)"; if ($c.hash) { [pscustomobject]@{ id = $c.hash; committed_date = $c.date } } }
  'repo.compare' = { param($a) $c = __Bb "repositories/$($a.repo)/diffstat/$(__Enc $a.to)..$(__Enc $a.from)?pagelen=100"; if ($c) { [pscustomobject]@{ diffs = @($c.values | ForEach-Object { [pscustomobject]@{ new_path = "$($_.new.path)$(if (-not $_.new) { $_.old.path })"; old_path = "$($_.old.path)$(if (-not $_.old) { $_.new.path })" } }) } } }
}
# adapter:git-host/azure: Azure DevOps Repos REST 7.1; repo = org/project/repo; env AZURE_DEVOPS_EXT_PAT (basic); auto-complete = merge-when-green
function __Az([string]$Repo, [string]$Path, [string]$Method = 'GET', $Body) {
  $o, $p, $r = "$Repo" -split '/', 3
  $u = "$o/$(if ($Path -notlike '/*') { "$p/" })_apis/$($Path.TrimStart('/') -replace '\{repo\}', (__Enc $r))"
  __Rest 'https://dev.azure.com' 'AZURE_DEVOPS_EXT_PAT' 'basic' $Method "$u$(if ($u -match '\?') { '&' } else { '?' })api-version=7.1" $Body
}
function __AzSha([string]$Repo, [string]$Ref) { if ($Ref -match '^[0-9a-f]{40}$') { $Ref } else { @((__Az $Repo "git/repositories/{repo}/refs?filter=heads/$(__Enc $Ref)").value)[0].objectId } }
function __AzMr($p) {
  if (-not $p.pullRequestId) { return $null }
  __Mr @{ iid = $p.pullRequestId; title = $p.title; state = $(switch ($p.status) { 'active' { 'opened' } 'completed' { 'merged' } default { 'closed' } }); source_branch = $p.sourceRefName -replace '^refs/heads/'
    target_branch = $p.targetRefName -replace '^refs/heads/'; sha = $p.lastMergeSourceCommit.commitId; merge_commit_sha = $p.lastMergeCommit.commitId; merged_at = $(if ($p.status -eq 'completed') { $p.closedDate })
    updated_at = $(if ($p.closedDate) { $p.closedDate } else { $p.creationDate }); draft = [bool]$p.isDraft; has_conflicts = $p.mergeStatus -eq 'conflicts'; detailed_merge_status = $(if ($p.mergeStatus -eq 'conflicts') { 'conflict' } else { [string]$p.mergeStatus })
    merge_when_pipeline_succeeds = [bool]$p.autoCompleteSetBy; web_url = "$($p.repository.webUrl)/pullrequest/$($p.pullRequestId)" }
}
Register-KitAdapter 'git-host' 'azure' @{
  'mr.get' = { param($a) __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)") }
  'mr.list' = { param($a)
    $q = "searchCriteria.status=$(@{ opened = 'active'; merged = 'completed'; closed = 'abandoned' }["$($a.state)"] ?? 'all')&`$top=$($a.per_page ?? 100)$(if ($a.source_branch) { "&searchCriteria.sourceRefName=refs/heads/$(__Enc $a.source_branch)" })$(if ($a.target_branch) { "&searchCriteria.targetRefName=refs/heads/$(__Enc $a.target_branch)" })"
    @((__Az $a.repo "git/repositories/{repo}/pullrequests?$q").value | ForEach-Object { __AzMr $_ } | Where-Object { (-not $a.search -or $_.title -like "*$($a.search)*") -and (-not $a.updated_after -or [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after) })
  }
  'mr.changes' = { param($a) $it = @((__Az $a.repo "git/repositories/{repo}/pullRequests/$($a.n)/iterations").value)[-1].id
    [pscustomobject]@{ changes = @((__Az $a.repo "git/repositories/{repo}/pullRequests/$($a.n)/iterations/$it/changes").changeEntries | ForEach-Object { [pscustomobject]@{ new_path = "$($_.item.path)".TrimStart('/'); old_path = "$(if ($_.originalPath) { $_.originalPath } else { $_.item.path })".TrimStart('/') } }) } }
  'mr.create' = { param($a) __AzMr (__Az $a.repo 'git/repositories/{repo}/pullrequests' 'POST' @{ sourceRefName = "refs/heads/$($a.source)"; targetRefName = "refs/heads/$($a.target)"; title = $a.title; description = $a.body }) }
  'mr.merge' = { param($a)
    $sha = if ($a.sha) { $a.sha } else { (__AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)")).sha }
    $b = @{ completionOptions = @{ mergeStrategy = @{ merge = 'noFastForward'; rebase = 'rebase' }["$($a.method)"] ?? 'squash'; deleteSourceBranch = (__Del $a) } }
    if ($a.auto) { $b.autoCompleteSetBy = @{ id = (__Az $a.repo '/connectionData').authenticatedUser.id } } else { $b.status = 'completed'; $b.lastMergeSourceCommit = @{ commitId = $sha } }
    __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)" 'PATCH' $b)
  }
  'mr.unauto' = { param($a) __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)" 'PATCH' @{ autoCompleteSetBy = @{ id = '00000000-0000-0000-0000-000000000000' } }) }
  'mr.url' = { param($a) $o, $p, $r = "$($a.repo)" -split '/', 3; "$(__HostSet 'url' 'https://dev.azure.com')/$o/$p/_git/$r/pullrequest/$($a.n)" }
  'repo.base' = { param($a) $c = @((__Az $a.repo "git/repositories/{repo}/commits/$(__AzSha $a.repo $a.a)/mergebases?otherCommitId=$(__AzSha $a.repo $a.b)").value)[0]; if ($c.commitId) { [pscustomobject]@{ id = $c.commitId } } }
  'repo.commit' = { param($a) $s = __AzSha $a.repo $a.ref; $c = if ($s) { __Az $a.repo "git/repositories/{repo}/commits/$s" }; if ($c.commitId) { [pscustomobject]@{ id = $c.commitId; committed_date = $c.committer.date } } }
  'repo.compare' = { param($a) $t = { param($r) if ($r -match '^[0-9a-f]{40}$') { 'commit' } else { 'branch' } }
    $c = __Az $a.repo "git/repositories/{repo}/diffs/commits?baseVersion=$(__Enc $a.from)&baseVersionType=$(& $t $a.from)&targetVersion=$(__Enc $a.to)&targetVersionType=$(& $t $a.to)"
    if ($c) { [pscustomobject]@{ diffs = @($c.changes | Where-Object { $_.item.gitObjectType -ne 'tree' } | ForEach-Object { [pscustomobject]@{ new_path = "$($_.item.path)".TrimStart('/'); old_path = "$(if ($_.sourceServerItem) { $_.sourceServerItem } else { $_.item.path })".TrimStart('/') } }) } } }
}
# adapter:git-host/gitea: Gitea / Forgejo REST v1 (url default https://<gitHost>/api/v1); env GITEA_TOKEN
function __Gt([string]$Path, [string]$Method = 'GET', $Body, [switch]$Probe) { __Rest "https://$($KitConf.GitHost)/api/v1" 'GITEA_TOKEN' 'token' $Method $Path $Body -Probe:$Probe }
Register-KitAdapter 'git-host' 'gitea' @{
  'mr.get' = { param($a) __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)") }
  'mr.list' = { param($a)
    @(@(__Gt "repos/$($a.repo)/pulls?state=$(@{ opened = 'open'; merged = 'closed'; closed = 'closed' }["$($a.state)"] ?? 'all')&limit=50") | ForEach-Object { __GhMr $_ } | Where-Object { $_ -and ($a.state -notin 'merged', 'closed' -or $_.state -eq $a.state) -and
        (-not $a.source_branch -or $_.source_branch -eq $a.source_branch) -and (-not $a.target_branch -or $_.target_branch -eq $a.target_branch) -and (-not $a.search -or $_.title -like "*$($a.search)*") -and (-not $a.updated_after -or [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after) })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = (__Files (__Gt "repos/$($a.repo)/pulls/$($a.n)/files?limit=100")) } }
  'mr.create' = { param($a) __GhMr (__Gt "repos/$($a.repo)/pulls" 'POST' @{ head = $a.source; base = $a.target; title = $a.title; body = $a.body }) }
  'mr.merge' = { param($a) $null = __Gt "repos/$($a.repo)/pulls/$($a.n)/merge" 'POST' @{ Do = $(if ($a.method -in 'merge', 'rebase') { $a.method } else { 'squash' }); delete_branch_after_merge = (__Del $a); head_commit_id = "$($a.sha)"; merge_when_checks_succeed = [bool]$a.auto }
    $m = __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)"); if ($m -and $a.auto -and $m.state -eq 'opened') { $m.merge_when_pipeline_succeeds = $true }; $m }
  'mr.unauto' = { param($a) $null = __Gt "repos/$($a.repo)/pulls/$($a.n)/merge" 'DELETE'; __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)") }
  'mr.url' = { param($a) "https://$($KitConf.GitHost)/$($a.repo)/pulls/$($a.n)" }
  # no merge-base API: b...a lists a's commits missing from b; none = a is the base, else the oldest one's parent
  'repo.base' = { param($a) $c = __Gt "repos/$($a.repo)/compare/$(__Enc $a.b)...$(__Enc $a.a)"; if ($null -eq $c) { return $null }
    [pscustomobject]@{ id = $(if (-not $c.total_commits) { $a.a } else { @(@($c.commits) | Sort-Object { $_.created })[0].parents[0].sha }) } }
  'repo.commit' = { param($a) $c = @(__Gt "repos/$($a.repo)/commits?sha=$(__Enc $a.ref)&limit=1&stat=false")[0]; if ($c.sha) { [pscustomobject]@{ id = $c.sha; committed_date = $c.commit.committer.date } } }
  'repo.compare' = { param($a) $c = __Gt "repos/$($a.repo)/compare/$(__Enc $a.from)...$(__Enc $a.to)"; if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } }
}
# adapter:git-host/command: gitHostApi.commands.<verb>
Register-KitAdapter 'git-host' 'command' @{ '*' = { param($a, $v) Invoke-KitCommand 'git-host' (__HostSet 'commands' $null) $v $a } }
# adapter-end:git-host

# CI (repos[].ci: host (default) | none | external = ci.type | a name): status = { id, status } of a sha; config = has CI (true/false/$null)
# adapter:ci/gitlab
Register-KitAdapter 'ci' 'gitlab' @{
  'runs' = { param($a) @(__Gp $a "/pipelines?ref=$(__Enc $a.ref)$(if ($a.sha) { "&sha=$($a.sha)" })&per_page=$($a.per_page ?? 20)") }
  'jobs' = { param($a) @(__Gp $a "/pipelines/$($a.id)/jobs?per_page=100") }
  'log' = { param($a) __Gp $a "/jobs/$($a.id)/trace" }
  'status' = { param($a) $p = @(__Gp $a "/pipelines?sha=$($a.sha)&per_page=1")[0]; if ($p.id) { [pscustomobject]@{ id = $p.id; status = $p.status } } }
  'config' = { param($a) $p = __Gp $a ''; if (-not $p.id) { return $null }; if ($p.only_allow_merge_if_pipeline_succeeds -or $p.ci_config_path -or $p.auto_devops_enabled) { return $true }
    $r = __Gp $a "/repository/files/.gitlab-ci.yml?ref=$(__Enc $a.ref)" -Res; if (-not $r.code) { $true } elseif ("$($r.out)$($r.err)" -match '\b404\b' -and "$($r.out)$($r.err)" -notmatch 'file_name') { $false } else { $null } }
}
# adapter:ci/github: Actions runs, check runs + commit statuses (external CI)
Register-KitAdapter 'ci' 'github' @{
  'runs' = { param($a) @(@((__GhApi "repos/$($a.repo)/actions/runs?branch=$(__Enc $a.ref)$(if ($a.sha) { "&head_sha=$($a.sha)" })&per_page=$($a.per_page ?? 20)").workflow_runs) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.id; sha = $_.head_sha; created_at = $_.created_at; updated_at = $_.updated_at; status = (__CiWord ($_.conclusion ?? $_.status)) } }) }
  'jobs' = { param($a) @(@((__GhApi "repos/$($a.repo)/actions/runs/$($a.id)/jobs?per_page=100").jobs) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = (__CiWord ($_.conclusion ?? $_.status)); finished_at = $_.completed_at } }) }
  'log' = { param($a) __GhApi "repos/$($a.repo)/actions/jobs/$($a.id)/logs" }
  'status' = { param($a) if (-not $a.sha) { return $null }
    $cr = @((__GhApi "repos/$($a.repo)/commits/$($a.sha)/check-runs?per_page=100").check_runs | Where-Object { $_ }); $cs = @((__GhApi "repos/$($a.repo)/commits/$($a.sha)/status").statuses | Where-Object { $_ })
    $st = __CiRoll (@($cr | ForEach-Object { if ($_.status -ne 'completed') { 'running' } else { __CiWord $_.conclusion } }) + @($cs | ForEach-Object { __CiWord $_.state })); if (-not $st) { return $null }
    [pscustomobject]@{ id = @($cr | ForEach-Object { if ("$($_.details_url)" -match '/runs/(\d+)') { $Matches[1] } })[0]; status = $st } }
  'config' = { param($a) $r = __Cli gh "repos/$($a.repo)/contents/.github/workflows?ref=$(__Enc $a.ref)" -Res; if ($null -eq $r) { $null } elseif (-not $r.code) { $true } elseif ("$($r.out)$($r.err)" -match '\b404\b|Not Found') { $false } else { $null } }
}
# adapter:ci/bitbucket: Bitbucket Pipelines (job id = <pipeline uuid>/<step uuid>)
function __BbRun($p) { [pscustomobject]@{ id = $p.uuid; sha = $p.target.commit.hash; created_at = $p.created_on; updated_at = $(if ($p.completed_on) { $p.completed_on } else { $p.created_on }); status = $(if ($p.state.result.name) { __CiWord $p.state.result.name } elseif ($p.state.stage.name -eq 'PAUSED') { 'manual' } else { __CiWord $p.state.name }) } }
Register-KitAdapter 'ci' 'bitbucket' @{
  'runs' = { param($a) @(@((__Bb "repositories/$($a.repo)/pipelines?target.branch=$(__Enc $a.ref)&sort=-created_on&pagelen=$($a.per_page ?? 20)").values) | Where-Object { $_ } | ForEach-Object { __BbRun $_ } | Where-Object { -not $a.sha -or $_.sha -like "$($a.sha.Substring(0, [Math]::Min(12, $a.sha.Length)))*" }) }
  'jobs' = { param($a) @(@((__Bb "repositories/$($a.repo)/pipelines/$(__Enc $a.id)/steps?pagelen=100").values) | Where-Object { $_ } | ForEach-Object { $s = __BbRun $_; [pscustomobject]@{ id = "$($a.id)/$($_.uuid)"; name = $_.name; status = $s.status; finished_at = $_.completed_on } }) }
  'log' = { param($a) $p, $s = "$($a.id)" -split '/', 2; __Bb "repositories/$($a.repo)/pipelines/$(__Enc $p)/steps/$(__Enc $s)/log" }
  'status' = { param($a) if (-not $a.sha) { return $null }; $v = @((__Bb "repositories/$($a.repo)/commit/$($a.sha)/statuses?pagelen=100").values | Where-Object { $_ }); $st = __CiRoll @($v | ForEach-Object { __CiWord $_.state }); if ($st) { [pscustomobject]@{ id = @($v | ForEach-Object { if ("$($_.url)" -match '/pipelines/results/(\d+)') { $Matches[1] } })[0]; status = $st } } }
  'config' = { param($a) __Bb "repositories/$($a.repo)/src/$(__Enc $a.ref)/bitbucket-pipelines.yml" -Probe }
}
# adapter:ci/azure: Azure Pipelines builds (job id = <build id>/<log id>)
Register-KitAdapter 'ci' 'azure' @{
  'runs' = { param($a) $rid = (__Az $a.repo 'git/repositories/{repo}').id
    @(@((__Az $a.repo "build/builds?repositoryId=$rid&repositoryType=TfsGit&branchName=refs/heads/$(__Enc $a.ref)&`$top=$($a.per_page ?? 20)").value) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.id; sha = $_.sourceVersion; created_at = $_.queueTime; updated_at = $(if ($_.finishTime) { $_.finishTime } else { $_.queueTime }); status = (__CiWord $(if ($_.status -eq 'completed') { $_.result } else { $_.status })) } } | Where-Object { -not $a.sha -or $_.sha -eq $a.sha }) }
  'jobs' = { param($a) @(@((__Az $a.repo "build/builds/$($a.id)/timeline").records) | Where-Object { $_ -and $_.type -eq 'Job' } | ForEach-Object { [pscustomobject]@{ id = "$($a.id)/$($_.log.id)"; name = $_.name; status = (__CiWord $(if ($_.state -eq 'completed') { $_.result } else { $_.state })); finished_at = $_.finishTime } }) }
  'log' = { param($a) $b, $l = "$($a.id)" -split '/', 2; __Az $a.repo "build/builds/$b/logs/$l" }
  # a PR's builds run on refs/pull/<n>/merge; a plain commit: its commit statuses
  'status' = { param($a) $b = if ($a.n) { @((__Az $a.repo "build/builds?branchName=refs/pull/$($a.n)/merge&`$top=1").value)[0] }
    if ($b.id) { return [pscustomobject]@{ id = $b.id; status = (__CiWord $(if ($b.status -eq 'completed') { $b.result } else { $b.status })) } }
    if ($a.sha) { $st = __CiRoll @(@((__Az $a.repo "git/repositories/{repo}/commits/$($a.sha)/statuses").value) | Where-Object { $_ } | ForEach-Object { __CiWord $_.state }); if ($st) { [pscustomobject]@{ id = $null; status = $st } } } }
  'config' = { param($a) $d = __Az $a.repo "build/definitions?repositoryId=$((__Az $a.repo 'git/repositories/{repo}').id)&repositoryType=TfsGit"; if ($null -eq $d) { $null } else { [bool]$d.count } }
}
# adapter:ci/gitea: Gitea Actions tasks + commit statuses (no job log API: the log is the run link)
Register-KitAdapter 'ci' 'gitea' @{
  'runs' = { param($a) @(@((__Gt "repos/$($a.repo)/actions/tasks?limit=50").workflow_runs) | Where-Object { $_ -and $_.head_branch -eq $a.ref -and (-not $a.sha -or $_.head_sha -eq $a.sha) } | ForEach-Object { [pscustomobject]@{ id = $_.id; sha = $_.head_sha; created_at = $_.created_at; updated_at = $_.updated_at; status = (__CiWord $_.status); url = $_.url } }) }
  'jobs' = { param($a) @(@((__Gt "repos/$($a.repo)/actions/tasks?limit=50").workflow_runs) | Where-Object { "$($_.id)" -eq "$($a.id)" } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = (__CiWord $_.status); finished_at = $_.updated_at } }) }
  'log' = { param($a) "no log API on Gitea: see https://$($KitConf.GitHost)/$($a.repo)/actions/runs/$($a.id)" }
  'status' = { param($a) if (-not $a.sha) { return $null }; $s = __Gt "repos/$($a.repo)/commits/$($a.sha)/status"; $st = __CiRoll @(@($s.statuses) | ForEach-Object { __CiWord $_.status }); if ($st) { [pscustomobject]@{ id = $null; status = $st } } }
  'config' = { param($a) $r = @('.gitea/workflows', '.github/workflows') | ForEach-Object { __Gt "repos/$($a.repo)/contents/$_`?ref=$(__Enc $a.ref)" -Probe }; if ($r -contains $true) { $true } elseif ($r -contains $null) { $null } else { $false } }
}
# adapter:ci/jenkins: Jenkins REST (ci.url, ci.job = the multibranch job path, default "job/{repo}"; env ci.tokenEnv = JENKINS_TOKEN "user:api-token"); run id = <branch>#<build>
function __Jk([string]$Repo, [string]$Ref, [string]$Tail) {
  $job = ([string](Get-KitSetting 'ci.job' 'job/{repo}')) -replace '\{repo\}', (("$Repo" -split '/')[-1])
  Invoke-KitHttp 'GET' "$(([string](Get-KitSetting 'ci.url' '')).TrimEnd('/'))/$job/job/$(__Enc (__Enc $Ref))/$Tail" $null (Get-KitAuth ([string](Get-KitSetting 'ci.tokenEnv' 'JENKINS_TOKEN')) 'basic')
}
function __JkRun($b, [string]$Ref) { [pscustomobject]@{ id = "$Ref#$($b.number)"; sha = @($b.actions.lastBuiltRevision.SHA1 | Where-Object { $_ })[0]; created_at = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp).UtcDateTime.ToString('o')
  updated_at = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp + [long]$b.duration).UtcDateTime.ToString('o'); status = $(if ($b.building) { 'running' } else { __CiWord $b.result }) } }
Register-KitAdapter 'ci' 'jenkins' @{
  'runs' = { param($a) @(@((__Jk $a.repo $a.ref "api/json?tree=builds[number,result,building,timestamp,duration,actions[lastBuiltRevision[SHA1]]]{0,$($a.per_page ?? 20)}").builds) | Where-Object { $_ } | ForEach-Object { __JkRun $_ $a.ref } | Where-Object { -not $a.sha -or $_.sha -eq $a.sha }) }
  'jobs' = { param($a) $r, $n = "$($a.id)" -split '#', 2; @(@((__Jk $a.repo $r "$n/wfapi/describe").stages) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $a.id; name = $_.name; status = (__CiWord $_.status); finished_at = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.startTimeMillis + [long]$_.durationMillis).UtcDateTime.ToString('o') } }) }
  'log' = { param($a) $r, $n = "$($a.id)" -split '#', 2; __Jk $a.repo $r "$n/consoleText" }
  'status' = { param($a) if (-not $a.ref -or -not $a.sha) { return $null }; $b = @(Invoke-KitAdapter 'ci' 'jenkins' 'runs' $a)[0]; if ($b) { [pscustomobject]@{ id = $b.id; status = $b.status } } }
  'config' = { param($a) [bool](Get-KitSetting 'ci.url' '') }
}
# adapter:ci/command: ci.commands.<verb>
Register-KitAdapter 'ci' 'command' @{ '*' = { param($a, $v) Invoke-KitCommand 'ci' (Get-KitSetting 'ci.commands' $null) $v $a } }
# adapter:ci/none
Register-KitAdapter 'ci' 'none' @{ 'runs' = { @() }; 'jobs' = { @() }; 'log' = { '' }; 'status' = { $null }; 'config' = { $false } }
# adapter-end:ci

# reads memoised 90 s (-NoMemo: polls), writes clear it; an open MR's head_pipeline = its repo's CI adapter
$global:KitHostMemo = if ($global:KitHostMemo) { $global:KitHostMemo } else { @{} }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  $t = if ($A.type) { $A.type } else { $script:HostType }
  if ($Verb -in 'mr.merge', 'mr.create' -and -not $A.method) { $A.method = [string](Get-RepoConf $A.repo 'mergeMethod' 'squash') }
  $ci = Get-KitCiType $A.repo $t
  $kind, $name, $v2 = if ($Verb -like 'ci.*') { 'ci', $ci, $Verb.Substring(3) } else { 'git-host', $t, $Verb }
  $mk = "$name|$Verb|$(($A.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&')"
  if ($Verb -in 'mr.create', 'mr.merge', 'mr.unauto') { $global:KitHostMemo.Clear() }
  elseif (-not $NoMemo -and $global:KitHostMemo.ContainsKey($mk) -and ((Get-Date) - $global:KitHostMemo[$mk].at).TotalSeconds -lt 90) { return $global:KitHostMemo[$mk].v }
  $v = Invoke-KitAdapter $kind $name $v2 $A
  if ($Verb -eq 'mr.get' -and $v.state -eq 'opened' -and ($t -ne 'gitlab' -or $ci -ne 'gitlab')) { $v | Add-Member -Force head_pipeline (Invoke-HostVerb 'ci.status' @{ type = $t; repo = $A.repo; sha = $v.sha; ref = $v.source_branch; n = $A.n } -NoMemo:$NoMemo) }
  if ($Verb -notin 'mr.create', 'mr.merge', 'mr.unauto' -and $null -ne $v) { $global:KitHostMemo[$mk] = @{ at = Get-Date; v = $v } }
  $v
}
# GitLab REST paths (older callers) -> verbs
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

# pwsh -File splits `-List 'a b','c d'`; switches take no value
function Invoke-KitVerb([string]$Fn, [object[]]$Tokens) {
  $Tokens = @($Tokens)
  # --help / -h / -? (not a value): header, exit 0; other --flags: unknown option
  $src = $MyInvocation.PSCommandPath
  $help = { if ($src -and (Test-Path $src)) { (Get-Content $src -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1' | Write-Output }; exit 0 }
  $meta = (Get-Command $Fn).Parameters
  $own = @($meta.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
  if (-not $own.Count) { if ($Tokens.Count -and "$($Tokens[0])" -in '--help', '-h', '-?', '-help') { & $help }; & $Fn @Tokens; return }
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
      # a splatted @{ Mode = 'None' } arrives as -Mode: then the value
      if ($inline -eq '') { $inline = $null; if ($pm.SwitchParameter -and $i -lt $Tokens.Count -and ($Tokens[$i] -is [bool] -or "$($Tokens[$i])" -match '^(true|false)$')) { $inline = "$($Tokens[$i])"; $i++ } }
      if ($pm.SwitchParameter) { $named[$p[0]] = if ($null -ne $inline) { $inline -notmatch '^(\$?false|0)$' } else { $true }; continue }
      $vals = [Collections.Generic.List[object]]::new(); if ($null -ne $inline) { $vals.Add($inline) }
      while ($i -lt $Tokens.Count -and "$($Tokens[$i])" -notmatch '^-[A-Za-z][\w-]*(:.*)?$') { $vals.Add($Tokens[$i]); $i++ }
      $named[$p[0]] = if ($pm.ParameterType.IsArray) { @($vals) } elseif ($vals.Count -gt 1) { @($vals) -join ',' } elseif ($vals.Count) { $vals[0] } else { '' }
    } else { $pos.Add($Tokens[$i]); $i++ }
  }
  $pa = $pos.ToArray(); & $Fn @pa @named
}
# ===== 6. entry scripts (one per area) =====
$KitCmd = [pscustomobject]@{
  dev = Join-Path $KitConf.Kit 'skills/dev-kit/dev.ps1'
  devtools = Join-Path $KitConf.Kit 'skills/dev-kit/devtools.py'
  spec     = Join-Path $KitConf.Kit 'skills/dev-kit/spec.mjs'
  qa       = Join-Path $KitConf.Kit 'skills/qa-kit/qa.ps1'
  browser  = Join-Path $KitConf.Kit 'skills/qa-kit/browser.mjs'
  swarm    = Join-Path $KitConf.Kit 'skills/android-swarm/swarm.ps1'
  local    = Join-Path $KitConf.Kit 'skills/local-env/localenv.ps1'
  orch     = Join-Path $KitConf.Kit 'skills/orchestrate/orch.ps1'
  kittool  = Join-Path $KitConf.Kit 'skills/orchestrate/kittool.py'
}
