<#
Kit library: config, paths, OS, tracker + git-host adapters; every kit script dot-sources it once:
  . (Join-Path <kit> 'skills/dev-kit/lib.ps1')
Functions only, silent. In: dev-kit/kit.local.json, kit.example.json (_paths), env KIT_* / CLAUDE_*. Exit codes: none.
Out: $KitConf, $KitCmd (entry script paths), Get-KitPath, Get-KitSetting, tracker verbs (Get-TrackerTask, ...), Invoke-HostApi,
  OS helpers (Get-SysMem, Get-SysProcs, New-DirLink, ...).
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
# cross-process lock: exclusive <file>.lock, stale after 2 min; ~130 s wait -> throw (never unlocked)
function Invoke-KitLocked([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body) {
  $lock = "$File.lock"; $fs = $null
  for ($i = 0; $i -lt 1300 -and -not $fs; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch {
      if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -gt 2) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
      else { Start-Sleep -Milliseconds 100 }
    }
  }
  # also warn + return: SilentlyContinue (most scripts) ignores a throw
  if (-not $fs) { $m = "Invoke-KitLocked: $lock still held after 130 s - not writing $File"; Write-Warning $m; throw $m; return }
  try { & $Body } finally { $fs.Dispose(); Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}
# tracking.local.json (pwsh 7); -Strict: bad JSON -> <file>.bad-<time> + throw (never {} over all tasks)
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
# locked read-modify-write; atomic temp + move
function Update-KitTracking([Parameter(Mandatory)][scriptblock]$Change) {
  $f = Get-KitPath tracking -Create
  Invoke-KitLocked $f {
    $t = Read-KitTracking -Strict
    if ($t -isnot [hashtable]) { return }   # invalid file: never write {} over it
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
# kit worktree: no kit.local.json, use the main clone's
if (-not (Test-Path $__cfgFile)) {
  $__cd = "$(git -C $__devkit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($__cd) { $__alt = Join-Path (Split-Path $__cd) 'skills/dev-kit/kit.local.json'; if (Test-Path $__alt) { $__cfgFile = $__alt } }
}
if (Test-Path $__cfgFile) { try { $__cfg = Get-Content $__cfgFile -Raw | ConvertFrom-Json } catch { Write-Warning "ignoring $__cfgFile (invalid JSON): $_" } }
function Get-KitValue([string]$Name, $Default) {
  if ($__cfg -and ($__cfg.PSObject.Properties.Name -contains $Name) -and $null -ne $__cfg.$Name -and "$($__cfg.$Name)" -ne '') { return $__cfg.$Name }
  $Default
}
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
$__trType = ([string]$(if ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { Get-KitSetting 'tracker.type' 'none' })).ToLower()
# task tag: fix/<tag><id>-slug, MR titles; track -Discover searches it
$__trTag = [string](Get-KitSetting 'tracker.branchTag' $(switch ($__trType) { 'clickup' { 'CU-' } 'github' { 'GH-' } 'gitlab' { 'GL-' } default { '' } }))
$__repos = Get-KitValue 'reposRoot' $__ws
$__wtRoots = @(@($env:CLAUDE_WT_ROOT) + @(Get-KitValue 'worktreeRoots' @("$__repos-wt")) | Where-Object { $_ } | Select-Object -Unique)
$KitConf = [pscustomobject]@{
  Kit               = $__kit
  Workspace         = $__ws
  Runtime           = (Get-KitRuntime)
  ConfigFile        = $__cfgFile
  ReposRoot         = $__repos
  WorktreeRoots     = $__wtRoots                                  # dev.ps1 wt root (default <ReposRoot>-wt)
  GitHost           = [string](Get-KitValue 'gitHost' 'gitlab.com')
  GitlabGroup       = [string](Get-KitValue 'gitlabGroup' '')
  TrackerRepos      = @(Get-KitValue 'trackerRepos' @())
  RepoAliases       = (Get-KitValue 'repoAliases' $null)          # e.g. { "api": "backend", "web": "frontend" }
  ProtectedBranches = @(Get-KitValue 'protectedBranches' @())     # shared branches besides main/master/develop/release/*
  TrackerType       = $__trType
  TrackerTag        = $__trTag                                    # CU- (clickup), GH-, GL-, '' (jira, none)
  ReportType        = $__reportType.ToLower()
  MaxBrowserProfiles = [int](Get-KitSetting 'cleanup.maxBrowserProfiles' 4)
  # session journals: ~/.claude/projects/<workspace path, non-alnum -> '-'>
  ClaudeProjectDir  = (Join-Path (Join-Path $HOME '.claude/projects') ($__ws -replace '[^A-Za-z0-9]', '-'))
}

# pwsh -File passes `'T1','T2'` as ONE string; quoted items stay whole, the rest splits on -Sep
function Split-KitList([object[]]$Values, [string]$Sep = '[\s,]+') {
  @(foreach ($v in @($Values)) {
      $v = "$v"
      $q = [regex]::Matches($v, '''([^'']*)''|"([^"]*)"')
      if ($q.Count -and [regex]::Replace($v, '''[^'']*''|"[^"]*"', '') -match '^[\s,;]*$') { foreach ($m in $q) { $m.Groups[1].Value + $m.Groups[2].Value } }
      else { $v -split $Sep | ForEach-Object { $_.Trim().Trim("'", '"').Trim() } }
    }) | Where-Object { $_ }
}

# ----- git: no prompts, no hangs
if (-not $env:GIT_TERMINAL_PROMPT) { $env:GIT_TERMINAL_PROMPT = '0' }
if (-not $env:GIT_HTTP_LOW_SPEED_LIMIT) { $env:GIT_HTTP_LOW_SPEED_LIMIT = '1000'; $env:GIT_HTTP_LOW_SPEED_TIME = '30' }   # < 1 KB/s for 30 s = abort
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=15' }
$global:KitFetched = if ($global:KitFetched) { $global:KitFetched } else { @{} }
# fetch a repo once per process per 10 min (worktrees share it), wall-clocked; $false = failed/timed out
function Invoke-GitFetch([string]$Dir, [int]$TimeoutSec = 60, [string[]]$Refs = @()) {
  $common = "$(git -C $Dir rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim(); if (-not $common) { return $false }
  $key = "$common|$($Refs -join ',')"
  if ($global:KitFetched.ContainsKey($key) -and ((Get-Date) - $global:KitFetched[$key].at).TotalMinutes -lt 10) { return $global:KitFetched[$key].ok }
  $a = @('-C', $Dir, 'fetch', '-q', '--prune', 'origin') + @($Refs | Where-Object { $_ })
  # Invoke-KitExe: one argv entry per argument (spaces broke Start-Process), keeps stderr
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
  if ($KitIsWindows) {
    $total = (Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB
    $avail = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes).AvailableMBytes / 1KB
    $free = (Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1MB
  }
  elseif ($KitIsMac) {
    $total = [double](sysctl -n hw.memsize) / 1GB
    $vm = vm_stat
    $page = if (($vm | Select-Object -First 1) -match 'page size of (\d+)') { [double]$Matches[1] } else { 4096 }
    $n = @{}; foreach ($l in $vm) { if ($l -match '^(Pages [^:]+):\s+(\d+)') { $n[$Matches[1]] = [double]$Matches[2] } }
    $free = ($n['Pages free'] + $n['Pages speculative']) * $page / 1GB
    $avail = $free + ($n['Pages inactive'] + $n['Pages purgeable']) * $page / 1GB
  }
  else {
    $m = @{}; foreach ($l in Get-Content /proc/meminfo) { if ($l -match '^(\w+):\s+(\d+)') { $m[$Matches[1]] = [double]$Matches[2] } }
    $total = $m['MemTotal'] / 1MB
    $free = $m['MemFree'] / 1MB
    $avail = $(if ($m.ContainsKey('MemAvailable')) { $m['MemAvailable'] } else { $m['MemFree'] + $m['Cached'] + $m['Buffers'] }) / 1MB
  }
  [pscustomobject]@{ TotalGB = [math]::Round($total, 1); AvailGB = [math]::Round($avail, 1); FreeGB = [math]::Round($free, 1) }
}

# free RAM: Windows free physical; Linux/macOS available (page cache keeps MemFree ~0)
function Get-FreeGB { $m = Get-SysMem; if ($KitIsWindows) { $m.FreeGB } else { $m.AvailGB } }

# busy CPU % (all cores): Windows load, Linux /proc/stat 0.5 s, macOS ps %cpu / cores
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

# etime from ps: [[dd-]hh:]mm:ss
function ConvertFrom-PsElapsed([string]$e) {
  if ($e -notmatch '^(\d+-)?(\d+:){1,2}\d+$') { return $null }
  $d = 0; if ($e -match '^(\d+)-(.*)$') { $d = [int]$Matches[1]; $e = $Matches[2] }
  $p = @($e -split ':' | ForEach-Object { [int]$_ }); [array]::Reverse($p)
  $sec = $p[0] + 60 * $(if ($p.Count -gt 1) { $p[1] } else { 0 }) + 3600 * $(if ($p.Count -gt 2) { $p[2] } else { 0 }) + 86400 * $d
  (Get-Date).AddSeconds(-$sec)
}

function Get-SysProcs([string]$Name, [switch]$NoCommandLine) {   # -NoCommandLine: faster on Windows (no CommandLine/Created)
  $all = if ($KitIsWindows) {
    $props = if ($NoCommandLine) { 'ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize' } else { 'ProcessId', 'ParentProcessId', 'Name', 'CommandLine', 'WorkingSetSize', 'CreationDate' }
    foreach ($p in Get-CimInstance Win32_Process -Property $props -ErrorAction SilentlyContinue) {
      [pscustomobject]@{ Id = [int]$p.ProcessId; ParentId = [int]$p.ParentProcessId; Name = $p.Name; CommandLine = $p.CommandLine; WorkingSet = [double]$p.WorkingSetSize; Created = $p.CreationDate }
    }
  }
  else {
    # comm: last column, spaces on macOS, 15 chars on Linux: prefer the cmdline exe starting with comm
    $names = @{}
    foreach ($l in (ps -A -o pid= -o comm= 2>$null)) { if ($l -match '^\s*(\d+)\s+(.*)$') { $names[[int]$Matches[1]] = Split-Path $Matches[2].Trim() -Leaf } }
    foreach ($l in (ps -A -o pid= -o ppid= -o rss= -o etime= -o args= 2>$null)) {
      if ($l -notmatch '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s?(.*)$') { continue }
      $id = [int]$Matches[1]; $cl = $Matches[5]; $n = [string]$names[$id]
      $exe = Split-Path (($cl -split '\s+')[0]) -Leaf
      if ($n.Length -ge 15 -and $exe.StartsWith($n)) { $n = $exe }
      [pscustomobject]@{ Id = $id; ParentId = [int]$Matches[2]; Name = $n; CommandLine = $cl; WorkingSet = [double]$Matches[3] * 1KB; Created = (ConvertFrom-PsElapsed $Matches[4]) }
    }
  }
  if ($Name) { @($all | Where-Object { $_.Name -match $Name }) } else { @($all) }
}

function Stop-SysProcess([int]$Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
# ---- budget (README "Configuration" budget): per agent = the running tool's DEFAULT compaction point; the kit writes no compaction setting
function Get-KitBudget([string]$Tool = '', [string]$Model = '', [int]$Window = 0) {
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).budget
  $row = { param($n) $o = Get-KitSetting "budget.defaults.$n" $null; if ($o) { $o } else { $ex.defaults.$n } }
  $envs = @(Get-ChildItem env: | ForEach-Object Name)
  if (-not $Tool) { $Tool = if ($env:KIT_TOOL) { $env:KIT_TOOL } elseif ($env:CLAUDECODE) { 'claude' } elseif ($envs -like 'CODEX_*') { 'codex' } elseif ($envs -match 'ANTIGRAVITY') { 'antigravity' } else { 'unknown' } }
  $n = 'unknown'; $tok = 0; $src = ''
  if ($Tool -eq 'claude') {
    if (-not $Model) { $Model = "$env:ANTHROPIC_MODEL" }
    $m = $Model.ToLower(); $big = $m -match '\[1m\]|fable|^(opus|sonnet|haiku|inherit|default)?$'
    # 1M by default: Opus 4.7+, Sonnet 5+, Haiku 5.5+, Fable, the bare aliases; older ids 200k unless [1m]
    if ($m -match '(opus|sonnet|haiku)-(\d+)(?:-(\d)(?!\d))?') { $big = $big -or ([double]$Matches[2] + [double]"0$($Matches[3])" / 10) -ge @{ opus = 4.7; sonnet = 5; haiku = 5.5 }[$Matches[1]] }
    if ($big -or $m -match 'claude|opus|sonnet|haiku') {
      if ($env:CLAUDE_CODE_DISABLE_1M_CONTEXT -eq '1') { $big = $false }
      $n = if ($big) { 'claude-1m' } else { 'claude-200k' }; $tok = [int](& $row $n).tokens
      if ($env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $tok = [int]$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW; $src = 'env CLAUDE_CODE_AUTO_COMPACT_WINDOW' }
      if ($env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE) { $tok = [math]::Min($tok, [int]($(if ($big) { 1e6 } else { 2e5 }) * [double]$env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100)); $src = 'env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' }
    }
  } elseif ($Tool -eq 'codex') {
    $ch = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $tt = "$(Get-Content (Join-Path $ch 'config.toml') -Raw -ErrorAction SilentlyContinue)"
    if (-not $Model -and $tt -match '(?m)^\s*model\s*=\s*"([^"]+)"') { $Model = $Matches[1] }
    $mc = try { @((Get-Content (Join-Path $ch 'models_cache.json') -Raw | ConvertFrom-Json).models | Where-Object slug -eq $Model)[0] } catch { $null }
    $n = 'codex'
    if ($tt -match '(?m)^\s*model_auto_compact_token_limit\s*=\s*(\d+)') { $tok = [int]$Matches[1]; $src = 'config.toml model_auto_compact_token_limit' }
    elseif ($mc.auto_compact_token_limit) { $tok = [int]$mc.auto_compact_token_limit; $src = 'models_cache.json auto_compact_token_limit' }
    else {
      $w = if ($mc.context_window) { [double]$mc.context_window * $(if ($mc.effective_context_window_percent) { [double]$mc.effective_context_window_percent } else { 100 }) / 100 } else { $Window }
      $tok = [int]($w * [double](& $row $n).fraction)
    }
  } elseif ($Tool -eq 'antigravity' -and $Window) { $n = 'antigravity'; $tok = [int]($Window * [double](& $row $n).fraction) }
  if (-not $tok) { $n = 'unknown'; $tok = [int](& $row $n).tokens }
  $h = [double](Get-KitSetting 'budget.handoffAt' $ex.handoffAt)
  [pscustomobject]@{ tool = $Tool; model = $Model; row = $n; budget = $tok; handoff = [int]($tok * $h); handoffAt = $h; runStopAt = [double](Get-KitSetting 'budget.runStopAt' $ex.runStopAt); source = $(if ($src) { $src } else { (& $row $n).source }) }
}
# free-RAM samples (gate waits + supervise) for the report's mean
function Add-KitMemSample([double]$Free) { try { $f = Get-KitPath mem-samples -Create; if (-not (Test-Path $f) -or ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -ge 60) { Add-Content $f "$((Get-Date).ToString('s'))`t$([math]::Round($Free, 1))" } } catch {} }
# spend = the agent's context now: the last usage of its transcript (input + cache + output), what the tool compacts on
function Get-KitSpend([string]$File) {
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $null }
  $t = @(Get-Content -LiteralPath $File -Tail 300)
  for ($i = $t.Count - 1; $i -ge 0; $i--) {
    if ($t[$i] -notmatch '"usage"') { continue }
    $o = try { $t[$i] | ConvertFrom-Json -Depth 40 } catch { continue }; $u = $o.message.usage; if (-not $u) { continue }
    return [pscustomobject]@{ spend = [int]($u.input_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens + $u.output_tokens); model = "$($o.message.model)" }
  }
}
# the transcript holding a marker (board SESSION token, launch -Self line); this session first
function Find-KitTranscript([string]$Marker, [string]$Filter = '*.jsonl') {
  $root = if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }; $sid = "$env:CLAUDE_CODE_SESSION_ID"
  foreach ($f in @(Get-ChildItem $root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } | Sort-Object { -not $sid -or $_.FullName -notmatch [regex]::Escape($sid) }, { -$_.LastWriteTime.Ticks })) {
    if (Select-String -LiteralPath $f.FullName -SimpleMatch $Marker -Quiet) { return $f.FullName }
  }
}

# holder = first non-shell ancestor + start time (pid reuse); Test-KitHolder: $true alive, $false gone, $null unknown
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

# wall-clocked CLI -> { code, out, err, timedOut }; CLI functions (test mocks) run directly
function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60) {
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return [pscustomobject]@{ code = 127; out = ''; err = "$Exe is not on PATH"; timedOut = $false } }
  if ($cmd.CommandType -ne 'Application') {
    $o = @(& $Exe @A 2>&1); $c = [int]$LASTEXITCODE
    return [pscustomobject]@{ code = $c; out = (@($o | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"); err = (@($o | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"); timedOut = $false }
  }
  $si = [Diagnostics.ProcessStartInfo]::new($cmd.Source)
  foreach ($x in @($A)) { $si.ArgumentList.Add([string]$x) }
  $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true; $si.UseShellExecute = $false; $si.CreateNoWindow = $true
  $si.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($si)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; return [pscustomobject]@{ code = -1; out = ''; err = "$Exe timed out after $TimeoutSec s"; timedOut = $true } }
  $p.WaitForExit()
  [pscustomobject]@{ code = $p.ExitCode; out = $so.Result.TrimEnd(); err = $se.Result.TrimEnd(); timedOut = $false }
}
# transient errors retry (2 s, 6 s); -Connect: only errors proving nothing was sent
$script:KitTransient = '(?i)timed? ?out|connection (reset|refused|closed|aborted)|could not resolve|no such host|unreachable|dial tcp|\bEOF\b|TLS handshake|temporar|\b(429|500|502|503|504)\b|bad gateway|service unavailable|too many requests'
$script:KitNoConnect = '(?i)could not resolve|no such host|connection refused|unreachable|dial tcp'
function Test-KitTransient([string]$Text, [switch]$Connect) { $Text -match $(if ($Connect) { $script:KitNoConnect } else { $script:KitTransient }) }
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
  else { New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null }
}

function Remove-DirLink([string]$Path) {
  if ($KitIsWindows) { cmd /c rmdir "$Path" | Out-Null }   # rmdir on a junction removes only the link
  else { & /bin/rm -f -- "$($Path.TrimEnd('/'))" }             # rm on a symlink (no slash, no -r) removes only the link
}

# never install: a farm of package links, workspace ones re-pointed to $WtRoot (Metro rejects outside files); else one junction
function Set-NodeModules([string]$To, [string]$From, [string]$SrcRoot, [string]$WtRoot) {
  $norm = { param($x) [IO.Path]::GetFullPath($x).TrimEnd('\', '/') }   # "a\.\node_modules" and "a\node_modules" are one path
  $To = & $norm $To; $From = & $norm $From; $SrcRoot = & $norm $SrcRoot; $WtRoot = & $norm $WtRoot
  $tgtOf = { param($i) $x = "$(@($i.Target)[0])"; if (-not [IO.Path]::IsPathRooted($x)) { $x = [IO.Path]::GetFullPath((Join-Path (Split-Path $i.FullName) $x)) }; $x.TrimEnd('\', '/') }
  $inSrc = { param($x) $x.StartsWith($SrcRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $x.StartsWith($SrcRoot + '/', [StringComparison]::OrdinalIgnoreCase) }
  $entries = @(Get-ChildItem -LiteralPath $From -Force -ErrorAction SilentlyContinue)
  $ws = @(foreach ($e in $entries) {
      if ($e.LinkType -and (& $inSrc (& $tgtOf $e))) { $e }
      elseif ($e.Name.StartsWith('@') -and -not $e.LinkType -and $e.PSIsContainer) { Get-ChildItem -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -and (& $inSrc (& $tgtOf $_)) } }
    })
  $mk = { param($path, $target) if ($KitIsWindows) { $null = New-Item -ItemType Junction -Path $path -Target $target } else { $null = New-Item -ItemType SymbolicLink -Path $path -Target $target } }
  $item = Get-Item -LiteralPath $To -Force -ErrorAction SilentlyContinue
  if (-not $ws.Count) {
    if ($item -and $item.LinkType -and (& $tgtOf $item) -eq $From.TrimEnd('\', '/')) { return $false }
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
      foreach ($c in Get-ChildItem -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue) { & $add $c (Join-Path $dest $c.Name) }
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
  foreach ($c in Get-ChildItem -LiteralPath $Path -Force) {
    if ($c.PSIsContainer -and -not $c.LinkType) {
      if (-not $c.Name.StartsWith('@')) { throw "Remove-NodeModules: $($c.FullName) is a real folder - $Path is not a link farm, nothing deleted" }
      $real = @(Get-ChildItem -LiteralPath $c.FullName -Force | Where-Object { -not $_.LinkType }) | Select-Object -First 1
      if ($real) { throw "Remove-NodeModules: $($real.FullName) is not a link - $Path is not a link farm, nothing deleted" }
    }
  }
  foreach ($c in Get-ChildItem -LiteralPath $Path -Force) {
    if ($c.LinkType) { & $unlink $c.FullName }
    elseif ($c.PSIsContainer) { foreach ($g in Get-ChildItem -LiteralPath $c.FullName -Force) { if ($g.LinkType) { & $unlink $g.FullName } else { throw "Remove-NodeModules: $($g.FullName) is not a link - not deleting a real folder" } }; Remove-Item -LiteralPath $c.FullName -Force }
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

# Windows: 'python' (python3 may be the Store stub); else python3 first
function Get-Python { if ($KitIsWindows) { 'python' } else { $p = Resolve-Tool python3 python; if ($p) { $p } else { 'python3' } } }

# `kittool.py prose` findings (templates.md "Writing standards") as warnings + strings; never cuts; -Path or -Text
function Test-KitProse([string]$Kind, [string]$Text, [string]$Path) {
  $tool = $KitCmd.kittool; if (-not $tool -or -not (Test-Path $tool)) { return @() }
  $tmp = $null
  if (-not $Path) { $tmp = Join-Path (Get-KitTemp) "kit-prose-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 6)).md"; [IO.File]::WriteAllText($tmp, $Text); $Path = $tmp }
  try { $r = & (Get-Python) -X utf8 $tool prose --kind $Kind $Path --json 2>$null | ConvertFrom-Json } catch { $r = $null } finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
  $found = @(if ($r) { $r.findings })
  foreach ($f in $found) { Write-Warning "[prose] $Kind`: $f (templates.md ""Writing standards"": rewrite, nothing was cut)" }
  $found
}
# detached from shell / tool timeouts: hidden (Windows), else `setsid nohup` (or nohup) to -Log (default OS temp)
function Start-Detached([string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path, [string]$Log) {
  if ($KitIsWindows) { $null = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden; return }
  if (-not $Log) { $Log = Join-Path (Get-KitTemp) "kit-bg-$([IO.Path]::GetFileNameWithoutExtension($FilePath))-$PID.log" }
  $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.UseShellExecute = $false
  $script = 'cd "$1" || exit 1; log=$2; shift 2; if command -v setsid >/dev/null 2>&1; then setsid nohup "$@" >"$log" 2>&1 </dev/null & else nohup "$@" >"$log" 2>&1 </dev/null & fi'
  foreach ($a in @('-c', $script, 'sh', $WorkingDirectory, $Log, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$a) }
  ([Diagnostics.Process]::Start($psi)).WaitForExit()
}

# pids listening on a local TCP port (Get-NetTCPConnection, lsof / fuser)
function Get-PortPids([int]$Port) {
  if ($KitIsWindows) { return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique) }
  if (Resolve-Tool lsof) { return @(lsof -t -nP -iTCP:$Port -sTCP:LISTEN 2>$null | ForEach-Object { [int]$_ } | Select-Object -Unique) }
  if (Resolve-Tool fuser) { return @(("$(fuser -n tcp $Port 2>$null)" -split '\s+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
  @()
}

function Test-PortListening([int]$Port) {
  if ($KitIsWindows) { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) }
  $t = [Net.Sockets.TcpClient]::new()
  try { $t.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $t.Connected } catch { $false } finally { $t.Dispose() }
}

function Get-AndroidSdk {
  foreach ($e in $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) { if ($e) { return $e } }
  if ($KitIsWindows) { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
  elseif ($KitIsMac) { Join-Path $HOME 'Library/Android/sdk' }
  else { Join-Path $HOME 'Android/Sdk' }
}

# ===== 4. tracker adapter (clickup | github | gitlab | jira | none) =====

# ----- options: Initialize-KitTracker [-Type <backend>] [-DryRun] (env KIT_TRACKER_TYPE / KIT_TRACKER_DRYRUN, else config)
function Initialize-KitTracker([string]$Type, [switch]$DryRun) {
  $script:__trType = ([string]$(if ($Type) { $Type } elseif ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { $KitConf.TrackerType })).ToLower()
  $script:__trDry = [bool]($DryRun -or $env:KIT_TRACKER_DRYRUN -eq '1')
  if ($script:__trType -notin 'clickup', 'github', 'gitlab', 'jira', 'none') { Write-Warning "tracker: unknown tracker.type '$($script:__trType)' - using none"; $script:__trType = 'none' }
  if ($script:__trType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }
}
Initialize-KitTracker
$__trRepo = [string](Get-KitSetting 'tracker.repo' '')
$__trNoneDir = Get-KitPath tracker-none   # 'none' tracker store (_paths)

$__trStatus = [ordered]@{
  open = @('open', 'to do'); inProgress = @('in progress'); review = @('for review', 'in review'); promoted = @('promoted')
  inTest = @('in test', 'for test'); failedTesting = @('failed testing', 'test failed'); closed = @('closed', 'complete', 'done')
}
$__trCfgSt = Get-KitSetting 'tracker.statuses' $null
if ($__trCfgSt) { foreach ($__p in $__trCfgSt.PSObject.Properties) { $__trStatus[$__p.Name] = @($__p.Value | ForEach-Object { [string]$_ }) } }

# ----- helpers
function Resolve-TrackerStatus([string]$Status) {
  # logical (review, inTest, ...) -> tracker status; else as is
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
  # read CLI output as UTF-8 (not the code page); reads + status sets retry transient errors, other writes only unsent
  $write = ("$($A[0..1] -join ' ')" -match '(?i)\b(comment|create|add|edit|attach|upload|new)\b' -and "$($A[0..1] -join ' ')" -notmatch '(?i)status') -or
    ("$($A -join ' ')" -match '(?i)(^|\s)(-X|--method)\s+(POST|PUT|PATCH|DELETE)\b' -and "$($A -join ' ')" -notmatch '(?i)status')
  $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  try { $r = Invoke-KitRetry { Invoke-KitExe $Exe $A (Get-KitNetTimeout) } -Connect:$write } finally { [Console]::OutputEncoding = $enc }
  $out = (@($r.out, $r.err) | Where-Object { $_ }) -join "`n"
  # a failing CLI (auth, unknown task) is no success; alias loop needs 'no matching status'
  if ($r.code -and $out -notmatch 'no matching status') { throw "tracker ($__trType): $Exe $($A[0..1] -join ' ') failed (exit $($r.code)): $(__TrShort $out)" }
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

# repo + number for github/gitlab ids: "12", "#12", "owner/name#12"
function __TrRef([string]$Id) {
  if ($Id -match '^(?<r>[^#\s]+)#(?<n>\S+)$') { return @($Matches.r, $Matches.n) }
  if (-not $__trRepo -and -not $__trDry) { throw "tracker ($__trType): set ""tracker"": { ""repo"": ""owner/name"" } in kit.local.json" }
  @($(if ($__trRepo) { $__trRepo } else { '<tracker.repo>' }), ($Id -replace '^#', ''))
}
function __TrLabelStatus($labels, [bool]$closed) {
  if ($closed) { return @($__trStatus.closed)[0] }
  $l = @($labels | Where-Object { $_ -like 'status:*' } | Select-Object -First 1)
  if ($l) { return ([string]$l[0]).Substring(7) }
  @($__trStatus.open)[0]
}
function __TrIsClosed([string]$name) { Test-TrackerStatus $name 'closed' }

# --- gitlab REST through glab api ---
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

# --- jira REST v3 ---
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
function __TrJira([string]$Method, [string]$Path, $Body, [string]$FilePath) {
  $base = if ($env:JIRA_BASE_URL) { $env:JIRA_BASE_URL.TrimEnd('/') } else { '<JIRA_BASE_URL>' }
  $uri = "$base/rest/api/3/$Path"
  if ($__trDry) { Write-Host "DRYRUN: $Method $uri$(if ($null -ne $Body) { '  body=' + (__TrShort ($Body | ConvertTo-Json -Depth 20 -Compress)) })$(if ($FilePath) { "  file=$FilePath" })"; return $null }
  if (-not $env:JIRA_BASE_URL -or -not $env:JIRA_EMAIL -or -not $env:JIRA_API_TOKEN) { throw 'tracker (jira): set JIRA_BASE_URL, JIRA_EMAIL and JIRA_API_TOKEN' }
  $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)"))
  $p = @{ Method = $Method; Uri = $uri; Headers = @{ Authorization = "Basic $auth"; Accept = 'application/json' }; TimeoutSec = (Get-KitNetTimeout) }
  if ($Method -eq 'GET') { $p.MaximumRetryCount = 2; $p.RetryIntervalSec = 3 }   # network loss: reads retry, writes never twice
  if ($FilePath) { $p.Headers['X-Atlassian-Token'] = 'no-check'; $p.Form = @{ file = Get-Item -LiteralPath $FilePath } }
  elseif ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json' }
  Invoke-RestMethod @p
}

# --- none: local log + store ---
function __TrNone([string]$Id, [string]$What, [scriptblock]$Change) {
  $d = Get-KitPath tracker-none -Create
  Add-Content (Get-KitPath tracker-log -Create) ("{0} {1} {2}" -f (Get-Date -Format s), $Id, (__TrShort $What)) -Encoding utf8
  if (-not $Id) { return $null }
  $f = Join-Path $d "$($Id -replace '[^\w.-]', '_').json"
  $o = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
  if ($Change) { if (-not $o) { $o = [pscustomobject]@{ id = $Id; name = ''; status = ''; parent = $null; list = ''; assignees = @(); description = ''; comments = @() } }; & $Change $o; $o | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8 }
  $o
}

# ----- verbs
function Get-TrackerUrl([string]$Id) {
  switch ($__trType) {
    'clickup' { "https://app.clickup.com/t/$Id" }
    'github' { $r, $n = __TrRef $Id; "https://$(Get-KitValue 'githubHost' 'github.com')/$r/issues/$n" }
    'gitlab' { $r, $n = __TrRef $Id; "https://$($KitConf.GitHost)/$r/-/issues/$n" }
    'jira' { "$(if ($env:JIRA_BASE_URL) { $env:JIRA_BASE_URL.TrimEnd('/') } else { '<JIRA_BASE_URL>' })/browse/$Id" }
    default { Join-Path $__trNoneDir "$($Id -replace '[^\w.-]', '_').json" }
  }
}

# reads memoised 90 s per process; writes drop the task's entry
$global:KitTrackerMemo = if ($global:KitTrackerMemo) { $global:KitTrackerMemo } else { @{} }
function Get-TrackerTask([string]$Id) {
  $mk = "$($__trType)|$Id"
  if ($global:KitTrackerMemo.ContainsKey($mk) -and ((Get-Date) - $global:KitTrackerMemo[$mk].at).TotalSeconds -lt 90) { return $global:KitTrackerMemo[$mk].v }
  $v = __Get-TrackerTask $Id
  if ($v -and $v.name) { $global:KitTrackerMemo[$mk] = @{ at = Get-Date; v = $v } }
  $v
}
function Clear-TrackerMemo([string]$Id) { $global:KitTrackerMemo.Remove("$($__trType)|$Id") }
function __Get-TrackerTask([string]$Id) {
  switch ($__trType) {
    'clickup' {
      $j = __TrJson (__TrCli 'clickup' @('task', 'view', $Id, '--json'))
      if (-not $j.id) { return (__TrStub $Id) }
      [pscustomobject]@{ id = $j.id; name = $j.name; status = [string]$j.status.status; url = $(if ($j.url) { $j.url } else { Get-TrackerUrl $j.id }); parent = $j.parent
        assignees = @($j.assignees | ForEach-Object { if ($_.username) { $_.username } else { $_.id } }); list = [string]$j.list.id
        subtasks = @($j.subtasks | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = [string]$_.status.status; url = Get-TrackerUrl $_.id } })
        description = [string]$(if ($j.markdown_description) { $j.markdown_description } else { $j.description }) }
    }
    'github' {
      $r, $n = __TrRef $Id
      $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'number,title,state,url,labels,assignees,body'))
      if (-not $j.number) { return (__TrStub $Id) }
      $body = [string]$j.body
      $par = if ($body -match '(?m)^Part of #(\d+)') { $Matches[1] } else { $null }
      $subs = @([regex]::Matches($body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
          $s = __TrJson (__TrCli 'gh' @('issue', 'view', $_, '-R', $r, '--json', 'number,title,state,labels'))
          [pscustomobject]@{ id = "$_"; name = $s.title; status = (__TrLabelStatus @($s.labels.name) ($s.state -eq 'CLOSED')); url = Get-TrackerUrl $_ } })
      [pscustomobject]@{ id = "$($j.number)"; name = $j.title; status = (__TrLabelStatus @($j.labels.name) ($j.state -eq 'CLOSED')); url = $j.url; parent = $par
        assignees = @($j.assignees.login); list = $r; subtasks = $subs; description = $body }
    }
    'gitlab' {
      $r, $n = __TrRef $Id
      $j = __TrGl 'GET' (__TrGlPath $Id) $null
      if (-not $j.iid) { return (__TrStub $Id) }
      $body = [string]$j.description
      $par = if ($body -match '(?m)^Part of #(\d+)') { $Matches[1] } else { $null }
      $subs = @([regex]::Matches($body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
          $s = __TrGl 'GET' (__TrGlPath $_) $null
          [pscustomobject]@{ id = "$_"; name = $s.title; status = (__TrLabelStatus @($s.labels) ($s.state -eq 'closed')); url = $s.web_url } })
      [pscustomobject]@{ id = "$($j.iid)"; name = $j.title; status = (__TrLabelStatus @($j.labels) ($j.state -eq 'closed')); url = $j.web_url; parent = $par
        assignees = @($j.assignees.username); list = $r; subtasks = $subs; description = $body }
    }
    'jira' {
      $j = __TrJira 'GET' "issue/$Id`?fields=summary,status,parent,assignee,subtasks,project,description" $null
      if (-not $j.key) { return (__TrStub $Id) }
      $f = $j.fields
      [pscustomobject]@{ id = $j.key; name = $f.summary; status = [string]$f.status.name; url = Get-TrackerUrl $j.key; parent = $f.parent.key
        assignees = @($f.assignee | Where-Object { $_ } | ForEach-Object { $_.displayName }); list = [string]$f.project.key
        subtasks = @($f.subtasks | ForEach-Object { [pscustomobject]@{ id = $_.key; name = $_.fields.summary; status = [string]$_.fields.status.name; url = Get-TrackerUrl $_.key } })
        description = (__TrAdfText $f.description).Trim() }
    }
    default {
      $o = __TrNone $Id 'view' $null
      if (-not $o) { return (__TrStub $Id) }
      $subs = @(Get-ChildItem $__trNoneDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
          Where-Object { $_.parent -eq $Id } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = $_.status; url = Get-TrackerUrl $_.id } })
      [pscustomobject]@{ id = $o.id; name = $o.name; status = $o.status; url = Get-TrackerUrl $o.id; parent = $o.parent; assignees = @($o.assignees); list = $o.list; subtasks = $subs; description = $o.description }
    }
  }
}

# network-lost writes -> .state/outbox.jsonl ("QUEUED ..."), replayed by supervise (Invoke-KitOutbox); KIT_NO_OUTBOX=1: off
function Add-KitOutbox([string]$Op, [string]$Id, [string]$Arg, [string]$Why) {
  $f = Get-KitPath outbox -Create
  $line = [ordered]@{ at = (Get-Date).ToString('o'); op = $Op; id = $Id; arg = $Arg; tracker = $__trType; tries = 0; why = $Why } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
  Write-Warning "tracker ($__trType): $Op $Id failed on the network ($Why): queued in the outbox; orch.ps1 supervise replays it"
  "QUEUED $Op $Id (network; outbox replays it)"
}
function Invoke-TrackerWrite([string]$Op, [string]$Id, [string]$Arg, [scriptblock]$Call) {
  try { & $Call }
  catch {
    $m = "$($_.Exception.Message)"
    if ($__trDry -or $env:KIT_NO_OUTBOX -eq '1' -or -not (Test-KitTransient $m)) { throw }
    Add-KitOutbox $Op $Id $Arg (__TrShort $m)
  }
}
# oldest first; network failures stay (tries + 1); GAVE UP (by hand): status > 24 h, 20 fails or real error; -DryRun lists
function Invoke-KitOutbox([switch]$DryRun) {
  $f = Get-KitPath outbox; if (-not (Test-Path $f)) { return }
  Invoke-KitLocked $f {
    $keep = [Collections.Generic.List[string]]::new()
    foreach ($l in @(Get-Content -LiteralPath $f | Where-Object { $_.Trim() })) {
      $e = try { $l | ConvertFrom-Json } catch { $null }; if (-not $e) { continue }
      if ($DryRun) { "QUEUED $($e.op) $($e.id) since $($e.at) (tries $($e.tries)): $($e.why)"; $keep.Add($l); continue }
      if ($e.op -eq 'status' -and ((Get-Date) - [datetime]$e.at).TotalHours -gt 24) { "GAVE UP $($e.op) $($e.id) -> $($e.arg): queued over 24 h ago (a person may have moved the task since)"; continue }
      try {
        $out = if ($e.op -eq 'status') { __Set-TrackerStatus $e.id $e.arg } else { __Add-TrackerComment $e.id $e.arg }
        "SENT $($e.op) $($e.id) (queued $($e.at)): $(__TrShort "$out")"
      } catch {
        $m = "$($_.Exception.Message)"; $e.tries = [int]$e.tries + 1; $e.why = __TrShort $m
        if ((Test-KitTransient $m) -and $e.tries -lt 20) { $keep.Add(($e | ConvertTo-Json -Compress)) }
        else { "GAVE UP $($e.op) $($e.id) after $($e.tries) tries: $($e.why)" }
      }
    }
    if ($keep.Count) { [IO.File]::WriteAllLines($f, $keep) } else { Remove-Item -LiteralPath $f -Force }
  }
}
function Set-TrackerStatus([string]$Id, [string]$Status) { Invoke-TrackerWrite 'status' $Id $Status { __Set-TrackerStatus $Id $Status } }
function Add-TrackerComment([string]$Id, [string]$Text) { $t = __TrText $Text; Invoke-TrackerWrite 'comment' $Id $t { __Add-TrackerComment $Id $t } }
function __Set-TrackerStatus([string]$Id, [string]$Status) {
  Clear-TrackerMemo $Id
  $name = Resolve-TrackerStatus $Status
  switch ($__trType) {
    'clickup' {
      # per-list status names ("for review" / "in review"): try each alias
      $names = @($name); foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $Status) { $names = @($__trStatus[$k]) } }
      foreach ($n in $names) { $out = __TrCli 'clickup' @('status', 'set', $n, $Id); if ("$out" -notmatch 'no matching status') { return $out } }
      # no alias on the list: fail (callers read success as done)
      if (-not $__trDry) { throw "tracker (clickup): no status '$($names -join "' / '")' on the list of task $Id (set tracker.statuses.$Status in kit.local.json)" }
      $out
    }
    'github' {
      $r, $n = __TrRef $Id
      $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'state,labels'))
      $old = @($j.labels.name | Where-Object { $_ -like 'status:*' -and $_ -ne "status:$name" })
      $edit = @('issue', 'edit', $n, '-R', $r); foreach ($o in $old) { $edit += @('--remove-label', $o) }
      if (__TrIsClosed $name) { if ($old) { $null = __TrCli 'gh' $edit }; __TrCli 'gh' @('issue', 'close', $n, '-R', $r) }
      else {
        if ($j.state -eq 'CLOSED') { $null = __TrCli 'gh' @('issue', 'reopen', $n, '-R', $r) }
        $null = __TrCli 'gh' @('label', 'create', "status:$name", '-R', $r, '--force', '--color', 'ededed')
        __TrCli 'gh' ($edit + @('--add-label', "status:$name"))
      }
    }
    'gitlab' {
      $j = __TrGl 'GET' (__TrGlPath $Id) $null
      $old = @($j.labels | Where-Object { $_ -like 'status:*' -and $_ -ne "status:$name" })
      $b = @{}; if ($old) { $b.remove_labels = $old -join ',' }
      if (__TrIsClosed $name) { $b.state_event = 'close' } else { $b.add_labels = "status:$name"; if ($j.state -eq 'closed') { $b.state_event = 'reopen' } }
      $res = __TrGl 'PUT' (__TrGlPath $Id) $b
      if ($res) { "status of #$($res.iid): $name" }
    }
    'jira' {
      $t = __TrJira 'GET' "issue/$Id/transitions" $null
      $tr = @($t.transitions | Where-Object { $_.name -ieq $name -or $_.to.name -ieq $name }) | Select-Object -First 1
      if (-not $tr -and -not $__trDry) { throw "tracker (jira): no transition to '$name' from the current status of $Id (have: $(@($t.transitions | ForEach-Object { $_.to.name }) -join ', '))" }
      $null = __TrJira 'POST' "issue/$Id/transitions" @{ transition = @{ id = $(if ($tr) { $tr.id } else { "<id of '$name'>" }) } }
      "status of $Id`: $name"
    }
    default { $null = __TrNone $Id "status $name" { param($o) $o.status = $name }; "status of $Id`: $name (tracker none)" }
  }
}

function __Add-TrackerComment([string]$Id, [string]$Text) {
  Clear-TrackerMemo $Id
  $Text = __TrText $Text
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('comment', 'add', $Id, $Text) }
    'github' {
      $r, $n = __TrRef $Id
      if ($__trDry) { return (__TrCli 'gh' @('issue', 'comment', $n, '-R', $r, '--body', $Text)) }
      $f = __TrTemp $Text; try { __TrCli 'gh' @('issue', 'comment', $n, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    'gitlab' { $res = __TrGl 'POST' (__TrGlPath $Id '/notes') @{ body = $Text }; if ($res) { "commented on #$((__TrRef $Id)[1])" } }
    'jira' { $res = __TrJira 'POST' "issue/$Id/comment" @{ body = (__TrAdf $Text) }; if ($res) { "commented on $Id" } }
    default { $null = __TrNone $Id "comment $Text" { param($o) $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = $Text }) }; "commented on $Id (tracker none)" }
  }
}

function Get-TrackerComments([string]$Id) {
  $c = switch ($__trType) {
    'clickup' { @(__TrJson (__TrCli 'clickup' @('comment', 'list', $Id, '--json'))) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.user.username; date = (__TrDate $_.date); text = [string]$_.comment_text } } }
    'github' { $r, $n = __TrRef $Id; @((__TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'comments'))).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.login; date = (__TrDate $_.createdAt); text = [string]$_.body } } }
    'gitlab' { @(__TrGl 'GET' (__TrGlPath $Id '/notes?sort=asc&per_page=100') $null) | Where-Object { $_ -and -not $_.system } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.username; date = (__TrDate $_.created_at); text = [string]$_.body } } }
    'jira' { @((__TrJira 'GET' "issue/$Id/comment?maxResults=200" $null).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.displayName; date = (__TrDate $_.created); text = (__TrAdfText $_.body).Trim() } } }
    default { @((__TrNone $Id 'comments' $null).comments) | Where-Object { $_ } }
  }
  @($c | Sort-Object date)
}

# assignee = tracker.owner, else OS user's full name among members (ClickUp/Jira id), else the CLI user (GitHub/GitLab)
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
$script:__trOwner = $null
function Get-TrackerOwner {
  if ($null -ne $script:__trOwner) { return $script:__trOwner }
  $o = [string](Get-KitSetting 'tracker.owner' '')
  if (-not $o -and -not $__trDry) {
    $name = __TrOsFullName
    try {
      switch ($__trType) {
        'clickup' { if ($name) { $id = __TrClickupMemberId $name; if ($id) { $o = $id } } }
        'jira' { if ($name) { $m = @(__TrJira 'GET' "user/search?query=$([uri]::EscapeDataString($name))" $null) | Where-Object { $_.displayName -eq $name } | Select-Object -First 1; $o = if ($m) { [string]$m.accountId } else { [string](__TrJira 'GET' 'myself' $null).accountId } } }
        'github' { $o = [string](__TrCli 'gh' @('api', 'user', '--jq', '.login')) }
        'gitlab' { $o = [string](__TrGl 'GET' 'user' $null).username }
        default { $o = $name }
      }
    } catch { Write-Warning "tracker: could not resolve the task owner '$name' ($($_.Exception.Message)); new tasks stay unassigned" }
  }
  $script:__trOwner = ([string]$o).Trim(); $script:__trOwner
}
function New-TrackerTask([string]$List, [string]$Name, [string]$Description, [string]$Parent, [string]$Assignee, [string]$Priority) {
  $Description = __TrText $Description
  if (-not $List) { $List = [string](Get-KitSetting 'tracker.list' '') }
  if (-not $Assignee) { $Assignee = Get-TrackerOwner }   # assignee: the kit runner unless '-' (nobody)
  switch ($__trType) {
    'clickup' {
      $a = @('task', 'create', '--list-id', $List, '--name', $Name, '--markdown-description', $Description, '--json')
      if ($Priority) { $a += @('--priority', $Priority) }
      # ClickUp needs a member id: name/email lookup; unresolved -> warn, unassigned
      if ($Assignee -and $Assignee -ne '-' -and $Assignee -notmatch '^\d+$') {
        $id = try { __TrClickupMemberId $Assignee } catch { Write-Warning "tracker: member lookup failed ($($_.Exception.Message))"; $null }
        if ($id) { $Assignee = $id } else { [Console]::Error.WriteLine("WARNING: tracker: no ClickUp member '$Assignee' (clickup member list): creating the task unassigned (assigned=false)"); $Assignee = '' }
      }
      $assigned = [bool]($Assignee -and $Assignee -ne '-')
      if ($assigned) { $a += @('--assignee', $Assignee) }
      $t = if ($Parent -and $Parent -ne '-' -and -not $__trDry) { try { __TrJson (__TrCli 'clickup' ($a + @('--parent', $Parent))) } catch { $null } } else { $null }
      if ($__trDry) { $null = __TrCli 'clickup' ($a + @(if ($Parent -and $Parent -ne '-') { '--parent', $Parent })); return [pscustomobject]@{ id = '<new>'; url = ''; assigned = $assigned } }
      $dropped = $false
      # ClickUp rejects cross-list parents: create in the list, link by comment
      if (-not $t.id) { $dropped = [bool]($Parent -and $Parent -ne '-'); $t = __TrJson (__TrCli 'clickup' $a) }
      if (-not $t.id) { return $null }
      if ($dropped) { $null = Add-TrackerComment $t.id "Related: $(Get-TrackerUrl $Parent) (could not be created as its subtask: it is in another list)." }
      [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }); assigned = $assigned }
    }
    'github' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $body = $(if ($Parent -and $Parent -ne '-') { "Part of #$($Parent -replace '^.*#', '')`n`n" }) + $Description
      $a = @('issue', 'create', '-R', $r, '--title', $Name)
      if ($Assignee -and $Assignee -ne '-') { $a += @('--assignee', $Assignee) }
      if ($Priority) { $pl = "priority:$(__TrPrio $Priority)"; $null = __TrCli 'gh' @('label', 'create', $pl, '-R', $r, '--force', '--color', 'ededed'); $a += @('--label', $pl) }
      if ($__trDry) { $null = __TrCli 'gh' ($a + @('--body', $body)); $out = $null }
      else { $f = __TrTemp $body; try { $out = __TrCli 'gh' ($a + @('--body-file', $f)) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
      $num = if ("$out" -match '/issues/(\d+)') { $Matches[1] } elseif ($__trDry) { '<new>' } else { return $null }
      if ($Parent -and $Parent -ne '-') {   # task-list line: view <parent> shows it as subtask
        $pn = $Parent -replace '^.*#', ''
        $pb = [string](__TrJson (__TrCli 'gh' @('issue', 'view', $pn, '-R', $r, '--json', 'body'))).body
        $nb = $pb.TrimEnd() + "`n- [ ] #$num"
        if ($__trDry) { $null = __TrCli 'gh' @('issue', 'edit', $pn, '-R', $r, '--body', $nb) } else { $f = __TrTemp $nb; try { $null = __TrCli 'gh' @('issue', 'edit', $pn, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
      }
      [pscustomobject]@{ id = "$num"; url = $(if ("$out" -match '(https://\S+/issues/\d+)') { $Matches[1] } else { Get-TrackerUrl "$r#$num" }) }
    }
    'gitlab' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $b = @{ title = $Name; description = $(if ($Parent -and $Parent -ne '-') { "Part of #$($Parent -replace '^.*#', '')`n`n" }) + $Description }
      if ($Priority) { $b.labels = "priority:$(__TrPrio $Priority)" }
      if ($Assignee -and $Assignee -ne '-') { $u = @(__TrGl 'GET' "users?username=$([uri]::EscapeDataString($Assignee))" $null) | Select-Object -First 1; if ($u.id) { $b.assignee_ids = @($u.id) } }
      $t = __TrGl 'POST' "projects/$([uri]::EscapeDataString($r))/issues" $b
      $iid = if ($t.iid) { $t.iid } elseif ($__trDry) { '<new>' } else { return $null }
      if ($Parent -and $Parent -ne '-') {
        $pid0 = "$r#$($Parent -replace '^.*#', '')"
        $p = __TrGl 'GET' (__TrGlPath $pid0) $null
        $null = __TrGl 'PUT' (__TrGlPath $pid0) @{ description = ([string]$p.description).TrimEnd() + "`n- [ ] #$iid" }
      }
      [pscustomobject]@{ id = "$iid"; url = $(if ($t.web_url) { $t.web_url } else { Get-TrackerUrl "$r#$iid" }) }
    }
    'jira' {
      $isSub = [bool]($Parent -and $Parent -ne '-')
      $f = @{ project = @{ key = $List }; summary = $Name; description = (__TrAdf $Description)
        issuetype = @{ name = $(if ($isSub) { Get-KitSetting 'tracker.subtaskType' 'Subtask' } else { Get-KitSetting 'tracker.issueType' 'Task' }) } }
      if ($isSub) { $f.parent = @{ key = $Parent } }
      if ($Assignee -and $Assignee -ne '-') { $f.assignee = @{ accountId = $Assignee } }
      if ($Priority) { $f.priority = @{ name = $(switch ($Priority) { '1' { 'Highest' } '2' { 'High' } '3' { 'Medium' } '4' { 'Low' } default { $Priority } }) } }
      $t = __TrJira 'POST' 'issue' @{ fields = $f }
      if (-not $t.key) { if ($__trDry) { return [pscustomobject]@{ id = '<new>'; url = '' } }; return $null }
      [pscustomobject]@{ id = $t.key; url = Get-TrackerUrl $t.key }
    }
    default {
      $d = Get-KitPath tracker-none -Create
      $n = 1 + @(Get-ChildItem $d -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count
      while (Test-Path (Join-Path $d "LOCAL-$n.json")) { $n++ }
      $id = "LOCAL-$n"
      $null = __TrNone $id "create $Name" { param($o) $o.name = $Name; $o.status = @($__trStatus.open)[0]; $o.parent = $(if ($Parent -and $Parent -ne '-') { $Parent }); $o.list = $List; $o.assignees = @($Assignee | Where-Object { $_ -and $_ -ne '-' }); $o.description = $Description }
      [pscustomobject]@{ id = $id; url = Get-TrackerUrl $id }
    }
  }
}

function Set-TrackerDescription([string]$Id, [string]$Text) {
  Clear-TrackerMemo $Id
  $Text = __TrText $Text
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('task', 'edit', $Id, '--markdown-description', $Text) }
    'github' {
      $r, $n = __TrRef $Id
      if ($__trDry) { return (__TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--body', $Text)) }
      $f = __TrTemp $Text; try { __TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    'gitlab' { $null = __TrGl 'PUT' (__TrGlPath $Id) @{ description = $Text }; "described #$((__TrRef $Id)[1])" }
    'jira' { $null = __TrJira 'PUT' "issue/$Id" @{ fields = @{ description = (__TrAdf $Text) } }; "described $Id" }
    default { $null = __TrNone $Id 'describe' { param($o) $o.description = $Text }; "described $Id (tracker none)" }
  }
}

function Set-TrackerName([string]$Id, [string]$Name) {
  Clear-TrackerMemo $Id
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('task', 'edit', $Id, '--name', $Name) }
    'github' { $r, $n = __TrRef $Id; __TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--title', $Name) }
    'gitlab' { $null = __TrGl 'PUT' (__TrGlPath $Id) @{ title = $Name }; "renamed #$((__TrRef $Id)[1])" }
    'jira' { $null = __TrJira 'PUT' "issue/$Id" @{ fields = @{ summary = $Name } }; "renamed $Id" }
    default { $null = __TrNone $Id "rename $Name" { param($o) $o.name = $Name }; "renamed $Id (tracker none)" }
  }
}

function Add-TrackerAttachment([string]$Id, [string]$File, [string]$Text) {
  # GitHub/GitLab: text as comment (no attachments); ClickUp/Jira: attach file
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "tracker: no such file $File" }
  $leaf = Split-Path $File -Leaf
  switch ($__trType) {
    { $_ -in 'github', 'gitlab' } {
      $body = Get-Content -LiteralPath $File -Raw -Encoding utf8
      if ($body.Length -gt 60000) { $body = $body.Substring(0, 60000) + "`n`n_(truncated: the full $leaf is in the QA run folder)_" }
      Add-TrackerComment $Id ($(if ($Text) { "$Text`n`n" }) + $body)
    }
    'clickup' { __TrCli 'clickup' @('attachment', 'add', $Id, $File); if ($Text) { Add-TrackerComment $Id "$Text (attached: $leaf)" } }
    'jira' { $null = __TrJira 'POST' "issue/$Id/attachments" $null $File; "attached $leaf to $Id"; if ($Text) { Add-TrackerComment $Id "$Text (attached: $leaf)" } }
    default { $null = __TrNone $Id "attach $File" { param($o) $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = "$Text [attachment: $File]" }) }; "attached $leaf to $Id (tracker none)" }
  }
}

function Get-TrackerTasks([string]$List, [string]$Status) {
  # <List>: ClickUp list id, GitHub owner/name, GitLab group/project, Jira key
  $st = Resolve-TrackerStatus $Status
  if (-not $List) { $List = [string]$(if ($__trType -in 'github', 'gitlab') { $__trRepo } else { Get-KitSetting 'tracker.list' '' }) }
  $who = { param($id, $u) [pscustomobject]@{ id = "$id"; username = "$u" } }
  switch ($__trType) {
    'clickup' {
      foreach ($pg in 0..6) {
        $arr = @(__TrJson (__TrCli 'clickup' @('task', 'list', '--list-id', $List, '--status', $st, '--page', "$pg", '--json')))
        $arr = @($arr | Where-Object { $_ -and $_.id })
        foreach ($t in $arr) { [pscustomobject]@{ id = [string]$t.id; name = [string]$t.name; status = $st; assignees = @($t.assignees | ForEach-Object { & $who $_.id $_.username }) } }
        if ($arr.Count -lt 100) { break }
      }
    }
    'github' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $a = @('issue', 'list', '-R', $r, '--limit', '200', '--json', 'number,title,assignees')
      $a += if (__TrIsClosed $st) { @('--state', 'closed') } else { @('--state', 'open', '--label', "status:$st") }
      @(__TrJson (__TrCli 'gh' $a)) | Where-Object { $_ -and $_.number } | ForEach-Object { [pscustomobject]@{ id = "$($_.number)"; name = [string]$_.title; status = $st; assignees = @($_.assignees | ForEach-Object { & $who $_.login $_.login }) } }
    }
    'gitlab' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $q = if (__TrIsClosed $st) { 'state=closed' } else { "state=opened&labels=$([uri]::EscapeDataString("status:$st"))" }
      @(__TrGl 'GET' "projects/$([uri]::EscapeDataString($r))/issues?$q&per_page=100" $null) | Where-Object { $_ -and $_.iid } | ForEach-Object { [pscustomobject]@{ id = "$($_.iid)"; name = [string]$_.title; status = $st; assignees = @($_.assignees | ForEach-Object { & $who $_.id $_.username }) } }
    }
    'jira' {
      $jql = "project = `"$List`" AND status = `"$st`""
      $j = __TrJira 'GET' "search/jql?jql=$([uri]::EscapeDataString($jql))&fields=summary,assignee&maxResults=200" $null
      @($j.issues) | Where-Object { $_ -and $_.key } | ForEach-Object { [pscustomobject]@{ id = $_.key; name = [string]$_.fields.summary; status = $st; assignees = @($_.fields.assignee | Where-Object { $_ } | ForEach-Object { & $who $_.accountId $_.displayName }) } }
    }
    default {
      @(Get-ChildItem $__trNoneDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
          Where-Object { (-not $List -or "$($_.list)" -eq $List) -and ((Test-TrackerStatus "$($_.status)" $Status) -or "$($_.status)" -ieq $st) } |
          ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = $_.status; assignees = @($_.assignees | ForEach-Object { & $who $_ $_ }) } })
    }
  }
}

# ===== 5. git-host adapter (GitLab / GitHub) =====
$script:HostType = [string](Get-KitValue 'gitHostType' $(if ($KitConf.GitHost -match 'github') { 'github' } else { 'gitlab' }))
if ($script:HostType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
if ($script:HostType -eq 'github' -and -not $env:GH_HOST -and (Get-KitValue 'githubHost' 'github.com') -ne 'github.com') { $env:GH_HOST = [string](Get-KitValue 'githubHost' 'github.com') }

function Get-HostProject([string]$Repo, [switch]$Raw) {
  $p = if ($Repo -match '/') { $Repo } elseif ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$Repo" } else { $Repo }
  if ($Raw) { $p } else { [uri]::EscapeDataString($p) }
}
function __HostJson($out) { $t = (@($out) | ForEach-Object { "$_" }) -join "`n"; if (-not $t.Trim()) { return $null }; try { $t | ConvertFrom-Json } catch { $null } }
function __Gh([string[]]$A) {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
  $r = Invoke-KitRetry { Invoke-KitExe gh $A (Get-KitNetTimeout) } -Connect:($A[0] -ne 'api')   # api = reads here
  if ($r.code) { if ($r.timedOut -or (Test-KitTransient $r.err)) { Write-Warning "githost: gh $($A[0..1] -join ' ') failed on the network: $($r.err)" }; return $null }
  @($r.out -split "`n")
}
function __GhApi([string]$Path) { __HostJson (__Gh @('api', $Path)) }
function __Query([string]$q) { $h = @{}; foreach ($kv in ($q -split '&' | Where-Object { $_ })) { $k, $v = $kv -split '=', 2; $h[[uri]::UnescapeDataString($k)] = [uri]::UnescapeDataString("$v") }; $h }
function __GhChecks([string]$Repo, [string]$Sha) {
  if (-not $Sha) { return $null }
  $runs = @((__GhApi "repos/$Repo/commits/$Sha/check-runs?per_page=100").check_runs)
  if (-not $runs.Count) { return $null }
  $st = if ($runs | Where-Object { $_.conclusion -in 'failure', 'timed_out', 'cancelled', 'action_required' }) { 'failed' } elseif ($runs | Where-Object { $_.status -ne 'completed' }) { 'running' } else { 'success' }
  [pscustomobject]@{ status = $st }
}
function __GhMr($pr, [string]$Repo, [switch]$NoChecks) {
  if (-not $pr -or -not $pr.number) { return $null }
  $state = if ($pr.merged_at -or $pr.merged) { 'merged' } elseif ($pr.state -eq 'open') { 'opened' } else { 'closed' }
  [pscustomobject]@{ iid = $pr.number; title = $pr.title; state = $state; source_branch = $pr.head.ref; target_branch = $pr.base.ref; sha = $pr.head.sha
    merge_commit_sha = $pr.merge_commit_sha; squash_commit_sha = $null; merged_at = $pr.merged_at; updated_at = $pr.updated_at; draft = [bool]$pr.draft
    has_conflicts = ($pr.mergeable -eq $false); detailed_merge_status = $(if ($pr.mergeable_state -eq 'dirty') { 'conflict' } else { [string]$pr.mergeable_state })
    merge_when_pipeline_succeeds = [bool]$pr.auto_merge; web_url = $pr.html_url; head_pipeline = $(if ($NoChecks -or $state -ne 'opened') { $null } else { __GhChecks $Repo $pr.head.sha }) }
}
function __Files($files) { @($files | ForEach-Object { [pscustomobject]@{ new_path = $_.filename; old_path = $(if ($_.previous_filename) { $_.previous_filename } else { $_.filename }) } }) }

# GETs memoised 90 s per process; writes clear it
$global:KitHostMemo = if ($global:KitHostMemo) { $global:KitHostMemo } else { @{} }
# -NoMemo: poll loops need fresh states
function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) {
  $mk = "$($script:HostType)|$Path"
  if ($Method -ne 'GET') { $global:KitHostMemo.Clear() }
  elseif (-not $NoMemo -and $global:KitHostMemo.ContainsKey($mk) -and ((Get-Date) - $global:KitHostMemo[$mk].at).TotalSeconds -lt 90) { return $global:KitHostMemo[$mk].v }
  $v = __Invoke-HostApi $Path $Method $Fields
  if ($Method -eq 'GET' -and $null -ne $v) { $global:KitHostMemo[$mk] = @{ at = Get-Date; v = $v } }
  $v
}
function __Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}) {
  if ($script:HostType -ne 'github') {
    $a = @('api'); if ($Method -ne 'GET') { $a += @('-X', $Method) }; $a += $Path
    foreach ($k in $Fields.Keys) { $a += @('-f', "$k=$($Fields[$k])") }
    if (-not (Get-Command glab -ErrorAction SilentlyContinue)) { return $null }
    # GETs retry transient errors, writes only unsent; hung calls end at net.timeoutSec
    $r = Invoke-KitRetry { Invoke-KitExe glab $a (Get-KitNetTimeout) } -Connect:($Method -ne 'GET')
    if ($r.code) { if ($r.timedOut -or (Test-KitTransient $r.err)) { Write-Warning "githost: glab api $Path failed on the network: $($r.err)" }; return $null }
    $o = @($r.out -split "`n")
    if ($Path -match '/trace$') { return ((@($o) | ForEach-Object { "$_" }) -join "`n") }
    return (__HostJson $o)
  }
  if ($Path -notmatch '^projects/(?<p>[^/]+)/(?<rest>.+)$') { Write-Warning "githost (github): no translation for $Path"; return $null }
  $repo = [uri]::UnescapeDataString($Matches.p); $rest = $Matches.rest
  $qs = if ($rest -match '\?(?<q>.*)$') { __Query $Matches.q } else { @{} }
  $rest = $rest -replace '\?.*$', ''
  switch -Regex ($rest) {
    '^merge_requests/(?<n>\d+)$' { return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo) }
    '^merge_requests/(?<n>\d+)/changes$' { return [pscustomobject]@{ changes = (__Files (__GhApi "repos/$repo/pulls/$($Matches.n)/files?per_page=100")) } }
    '^merge_requests/(?<n>\d+)/merge$' {
      $a = @('pr', 'merge', $Matches.n, '-R', $repo, '--squash', '--delete-branch'); if ("$($Fields.merge_when_pipeline_succeeds)" -eq 'true') { $a += '--auto' }
      $null = __Gh $a; return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo)
    }
    '^merge_requests/(?<n>\d+)/cancel_merge_when_pipeline_succeeds$' { $null = __Gh @('pr', 'merge', $Matches.n, '-R', $repo, '--disable-auto'); return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo -NoChecks) }
    '^merge_requests$' {
      $st = switch ("$($qs.state)") { 'opened' { 'open' } 'merged' { 'closed' } 'closed' { 'closed' } default { 'all' } }
      $prs = if ($qs.search) {
        $q = "repo:$repo is:pr $($qs.search) in:title$(if ($qs.state -eq 'merged') { ' is:merged' } elseif ($qs.state -eq 'opened') { ' is:open' })"
        @((__GhApi "search/issues?q=$([uri]::EscapeDataString($q))&per_page=50").items) | ForEach-Object { __GhApi "repos/$repo/pulls/$($_.number)" }
      } else { @(__GhApi "repos/$repo/pulls?state=$st&per_page=$(if ($qs.per_page) { $qs.per_page } else { 100 })$(if ($qs.target_branch) { "&base=$([uri]::EscapeDataString($qs.target_branch))" })$(if ($qs.source_branch) { "&head=$([uri]::EscapeDataString("$(($repo -split '/')[0]):$($qs.source_branch)"))" })") }
      $out = @($prs | ForEach-Object { __GhMr $_ $repo -NoChecks } | Where-Object { $_ })
      if ($qs.state -eq 'merged') { $out = @($out | Where-Object { $_.state -eq 'merged' }) }
      if ($qs.updated_after) { $out = @($out | Where-Object { $_.updated_at -and [datetimeoffset]$_.updated_at -ge [datetimeoffset]$qs.updated_after }) }
      return $out
    }
    '^repository/merge_base$' {
      $refs = @([regex]::Matches($Path, 'refs\[\]=([^&]+)') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) })
      if ($refs.Count -lt 2) { return $null }
      $c = __GhApi "repos/$repo/compare/$([uri]::EscapeDataString($refs[0]))...$([uri]::EscapeDataString($refs[1]))"
      return $(if ($c.merge_base_commit.sha) { [pscustomobject]@{ id = $c.merge_base_commit.sha } } else { $null })
    }
    '^repository/commits/(?<r>.+)$' { $c = __GhApi "repos/$repo/commits/$($Matches.r)"; return $(if ($c.sha) { [pscustomobject]@{ id = $c.sha; committed_date = $c.commit.committer.date } } else { $null }) }
    '^repository/compare$' {
      $c = __GhApi "repos/$repo/compare/$([uri]::EscapeDataString($qs.from))...$([uri]::EscapeDataString($qs.to))"
      return $(if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } else { $null })
    }
    '^pipelines$' {
      $r = __GhApi "repos/$repo/actions/runs?branch=$([uri]::EscapeDataString($qs.ref))&per_page=$(if ($qs.per_page) { $qs.per_page } else { 20 })"
      return @(@($r.workflow_runs) | ForEach-Object { [pscustomobject]@{ id = $_.id; sha = $_.head_sha; created_at = $_.created_at; updated_at = $_.updated_at; status = $(if ($_.conclusion) { if ($_.conclusion -eq 'failure') { 'failed' } else { $_.conclusion } } else { 'running' }) } })
    }
    '^pipelines/(?<id>\d+)/jobs$' {
      $r = __GhApi "repos/$repo/actions/runs/$($Matches.id)/jobs?per_page=100"
      return @(@($r.jobs) | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = $(if ($_.conclusion) { if ($_.conclusion -eq 'failure') { 'failed' } else { $_.conclusion } } else { 'running' }); finished_at = $_.completed_at } })
    }
    '^jobs/(?<id>\d+)/trace$' { return ((@(__Gh @('api', "repos/$repo/actions/jobs/$($Matches.id)/logs")) | ForEach-Object { "$_" }) -join "`n") }
    default { Write-Warning "githost (github): no translation for $Path"; return $null }
  }
}

# pwsh -File splits `-List 'a b','c d'`; switches take no value
function Invoke-KitVerb([string]$Fn, [object[]]$Tokens) {
  $Tokens = @($Tokens)
  # --help / -h / -? (not a value): header, exit 0; other --flags in a param slot: unknown option, not positional
  $src = $MyInvocation.PSCommandPath
  $help = { if ($src -and (Test-Path $src)) { (Get-Content $src -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1' | Write-Output }; exit 0 }
  $meta = (Get-Command $Fn).Parameters
  $own = @($meta.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
  if (-not $own.Count) { if ($Tokens.Count -and "$($Tokens[0])" -in '--help', '-h', '-?', '-help') { & $help }; & $Fn @Tokens; return }
  $named = @{}; $pos = [Collections.Generic.List[object]]::new(); $i = 0
  while ($i -lt $Tokens.Count) {
    $t = "$($Tokens[$i])"
    if ($t -in '--help', '-?' -or ($t -in '-h', '-help' -and -not @($own | Where-Object { $_ -ieq $t.TrimStart('-') }).Count)) { & $help }
    if ($t -match '^--\w') { throw "$($Fn -replace '^Invoke-', ''): unknown option $t (parameters take one dash; --help prints the usage)" }
    if ($t -match '^-([A-Za-z][\w-]*)(?::(.*))?$') {
      $n = $Matches[1]; $inline = $Matches[2]
      $p = @($own | Where-Object { $_ -ieq $n }); if (-not $p.Count) { $p = @($own | Where-Object { @($meta[$_].Aliases) -contains $n }) }; if (-not $p.Count) { $p = @($own | Where-Object { $_ -like "$n*" }) }
      if ($p.Count -ne 1) { throw "$($Fn -replace '^Invoke-', ''): unknown or ambiguous parameter -$n" }
      $pm = $meta[$p[0]]; $i++
      # splatted hashtable (& x.ps1 @{ Mode = 'None' }) arrives as '-Mode:', 'None' (value next)
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
  dev      = Join-Path $KitConf.Kit 'skills/dev-kit/dev.ps1'
  devtools = Join-Path $KitConf.Kit 'skills/dev-kit/devtools.py'
  spec     = Join-Path $KitConf.Kit 'skills/dev-kit/spec.mjs'
  qa       = Join-Path $KitConf.Kit 'skills/qa-kit/qa.ps1'
  browser  = Join-Path $KitConf.Kit 'skills/qa-kit/browser.mjs'
  swarm    = Join-Path $KitConf.Kit 'skills/android-swarm/swarm.ps1'
  local    = Join-Path $KitConf.Kit 'skills/local-env/localenv.ps1'
  orch     = Join-Path $KitConf.Kit 'skills/orchestrate/orch.ps1'
  kittool  = Join-Path $KitConf.Kit 'skills/orchestrate/kittool.py'
}