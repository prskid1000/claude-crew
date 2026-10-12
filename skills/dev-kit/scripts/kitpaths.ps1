<#
Kit paths for PowerShell: the only place a .ps1 learns where runtime or durable local state lives. Cheap (no CLI lookups),
so hooks that run before every command (guard.ps1) can use it. kitconfig.ps1 dot-sources it.

  . (Join-Path <kit>/skills/dev-kit/scripts 'kitpaths.ps1')
  Get-KitPath qa-runs            # <runtime>/work/qa-runs         (names: kitpaths.json; 'runtime' = the runtime root)
  Get-KitPath guard-log -Create  # creates the folder (or a file's parent folder) first
  Get-KitPath tracking           # <kit>/tracking.local.json      (durable, git-ignored)

<runtime> = $env:CLAUDE_RUNTIME, else <kit>/.claude-runtime. The map itself is kitpaths.json next to this file.
#>
$script:KitRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/dev-kit/scripts -> <kit>
$script:KitPathMap = Get-Content (Join-Path $PSScriptRoot 'kitpaths.json') -Raw | ConvertFrom-Json
function Get-KitRuntime { if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path $script:KitRoot $script:KitPathMap.runtimeDir } }
function Get-KitPath([Parameter(Mandatory)][string]$Name, [switch]$Create) {
  $m = $script:KitPathMap
  if ($Name -eq 'runtime') { $p = Get-KitRuntime; $dir = $true }
  elseif ($m.runtime.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.runtime.$Name; $p = Join-Path (Get-KitRuntime) $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  elseif ($m.durable.PSObject.Properties.Name -contains $Name) { $rel = [string]$m.durable.$Name; $p = Join-Path $script:KitRoot $rel.TrimEnd('/'); $dir = $rel.EndsWith('/') }
  else { throw "Get-KitPath: unknown name '$Name' (see skills/dev-kit/scripts/kitpaths.json)" }
  if ($Create) { New-Item -ItemType Directory -Force $(if ($dir) { $p } else { Split-Path $p }) | Out-Null }
  $p
}
# Cross-process lock for a durable file (tracking.local.json is written by track.ps1 and devtools.py): a <file>.lock created
# exclusively; a lock older than 2 minutes is stale (its writer died) and is taken over. Not got within ~130 s -> throws (never
# runs the body unlocked: two writers would each drop the other's change).
function Invoke-KitLocked([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body) {
  $lock = "$File.lock"; $fs = $null
  for ($i = 0; $i -lt 1300 -and -not $fs; $i++) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None') }
    catch {
      if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -gt 2) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
      else { Start-Sleep -Milliseconds 100 }
    }
  }
  # Write-Warning + return too: under $ErrorActionPreference = 'SilentlyContinue' (most kit scripts) a throw does not stop the function
  if (-not $fs) { $m = "Invoke-KitLocked: $lock still held after 130 s - not writing $File"; Write-Warning $m; throw $m; return }
  try { & $Body } finally { $fs.Dispose(); Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}
# Durable task tracking (<kit>/tracking.local.json): { tasks: { <task>: {task, mrs, onMerged, done, ...} }, automerge: { <ref>: <time> } }.
# Writers: track.ps1 (tasks + automerge re-arm), devtools.py merge (automerge), supervise.ps1 (live/QA fields). Needs pwsh 7.
# -Strict (writers): invalid JSON is backed up to <file>.bad-<time> and throws, so a write never replaces every task with {}.
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
# Locked read-modify-write: & $Change $tracking; the result is written atomically (temp file + move).
function Update-KitTracking([Parameter(Mandatory)][scriptblock]$Change) {
  $f = Get-KitPath tracking -Create
  Invoke-KitLocked $f {
    $t = Read-KitTracking -Strict
    if ($t -isnot [hashtable]) { return }   # invalid file (Read-KitTracking warned/threw): never write {} over it
    & $Change $t
    $t.version = 1
    $t | ConvertTo-Json -Depth 8 | Set-Content "$f.tmp" -Encoding utf8
    Move-Item "$f.tmp" $f -Force
  }
}
# Set some fields of one tracked task without touching the rest (another process may have changed it since you read it).
function Set-KitTaskFields([Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][hashtable]$Fields) {
  Update-KitTracking { param($t) if ($t.tasks[$Task]) { foreach ($k in $Fields.Keys) { $t.tasks[$Task][$k] = $Fields[$k] } } }
}
