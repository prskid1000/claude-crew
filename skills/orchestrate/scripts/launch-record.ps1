<#
Restartable workflow launches. A session restart (usage limit, crash, a new terminal) stops every workflow it ran, and the
coordinator then had to rebuild each launch by hand (which script, which args, which QA run, the heartbeat). The coordinator
records every launch right after the Workflow tool returns its run id; at SessionStart kit-health.ps1 lists the runs that never
completed, with what is needed to resume them, plus QA run folders whose autoclose watcher is gone.

  $O = '<workspace>/.claude/skills/orchestrate/scripts'
  & $O/launch-record.ps1 -RunId <runId> -Script <kit>/workflows/dev-wave.js -ArgsJson '<the exact args JSON>'   # step 3 / step 7, after launch
  & $O/launch-record.ps1 -RunId <runId> -Script <path> -ArgsFile <args.json> [-RunDir <qa run>] [-Session <id>]
  & $O/launch-record.ps1 -Done -RunId <runId>     # E5: the workflow finished (any outcome)
  & $O/launch-record.ps1 -List [-Hours 24]         # unfinished launches (resume lines) + orphaned autoclose run folders
  & $O/launch-record.ps1 -List -Brief              # the same in one line per item (kit-health.ps1, SessionStart)

Record: <runtime>/work/launches/<runId>.json = { runId, script, args, argsFile, runDir, session, at, completed }. The args are
stored in full so the resume is exact: Workflow({ scriptPath: <script>, resumeFromRunId: <runId>, args: <args from the record> }).
runDir defaults to args.runDir (test-and-close). cleanup.ps1 prunes records older than 3 days.
#>
param(
  [string]$RunId, [string]$Script, [string]$ArgsJson, [string]$ArgsFile, [string]$RunDir, [string]$Session,
  [switch]$Done, [switch]$List, [switch]$Brief, [int]$Hours = 24
)
$ErrorActionPreference = 'Stop'
$kit = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/orchestrate/scripts -> <kit>
. (Join-Path $kit 'skills/dev-kit/scripts/kitpaths.ps1')
$dir = Get-KitPath launches -Create
$RunId = "$RunId".Trim().Trim('''"')
$safe = { param($id) ($id -replace '[^\w.-]', '_') }

if ($Done) {
  if (-not $RunId) { throw '-Done needs -RunId' }
  $f = Join-Path $dir "$(& $safe $RunId).json"
  if (-not (Test-Path -LiteralPath $f)) { Write-Host "[launch] no record for $RunId (nothing to mark)"; exit 0 }
  $r = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
  $r.completed = (Get-Date).ToString('o')
  $r | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $f -Encoding utf8
  Write-Host "[launch] $RunId marked completed"
  exit 0
}

if (-not $List) {
  if (-not $RunId -or -not $Script) { throw 'record a launch with -RunId <id> -Script <path> and -ArgsJson <json> or -ArgsFile <file>' }
  $raw = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw } elseif ($ArgsJson) { $ArgsJson } else { '{}' }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "the args are not valid JSON: $($_.Exception.Message)" }
  if (-not $RunDir -and $a -is [hashtable] -and $a.runDir) { $RunDir = [string]$a.runDir }
  $rec = [ordered]@{ runId = $RunId; script = $Script; args = $a; argsFile = $(if ($ArgsFile) { (Resolve-Path -LiteralPath $ArgsFile).Path } else { $null })
    runDir = $(if ($RunDir) { $RunDir } else { $null }); session = $(if ($Session) { $Session } else { $null }); at = (Get-Date).ToString('o'); completed = $null }
  $f = Join-Path $dir "$(& $safe $RunId).json"
  $rec | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $f -Encoding utf8
  Write-Host "[launch] recorded $RunId ($(Split-Path $Script -Leaf)) -> $f"
  exit 0
}

# -List: launches with no completion in the last -Hours, and QA run folders whose autoclose watcher stopped
$since = (Get-Date).AddHours(-$Hours)
$out = @()
foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime) {
  try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
  if ($r.completed) { continue }
  $at = try { [datetime]$r.at } catch { $f.LastWriteTime }
  if ($at -lt $since) { continue }
  $name = Split-Path ([string]$r.script) -Leaf
  $out += if ($Brief) { "$name $($r.runId) (resumeFromRunId $($r.runId), args $($f.FullName))" }
          else { "STOPPED? $name run $($r.runId) launched $($at.ToString('yyyy-MM-dd HH:mm'))$(if ($r.runDir) { ", runDir $($r.runDir)" })`n  resume: Workflow({ scriptPath: '$($r.script)', resumeFromRunId: '$($r.runId)', args: <args in $($f.FullName)> })`n  finished already: launch-record.ps1 -Done -RunId $($r.runId)" }
}
# autoclose (qa-kit) writes <run>/autoclose.log every few minutes while it watches; a recent run whose log went quiet with codes
# still unhandled has lost its watcher (it dies with the session or its -MaxHours)
$qa = Get-KitPath qa-runs
foreach ($d in Get-ChildItem -LiteralPath $qa -Directory -ErrorAction SilentlyContinue) {
  $rj = Join-Path $d.FullName 'run.json'
  if (-not (Test-Path -LiteralPath $rj) -or (Get-Item -LiteralPath $rj).LastWriteTime -lt $since) { continue }
  $log = Join-Path $d.FullName 'autoclose.log'
  if (-not (Test-Path -LiteralPath $log)) { continue }   # never started here (skipClose runs, retests): nothing to re-arm
  if ((Get-Item -LiteralPath $log).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { continue }   # still watching
  $codes = @(try { (Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json).items | ForEach-Object { [string]$_.code } } catch { })
  $handled = @(Get-Content -LiteralPath (Join-Path $d.FullName 'autoclose_done.txt') -ErrorAction SilentlyContinue)
  $open = @($codes | Where-Object { $_ -and $handled -notcontains $_ })
  if (-not $open.Count) { continue }
  $out += if ($Brief) { "autoclose gone for $($d.Name) ($($open.Count) unhandled)" }
          else { "ORPHANED autoclose: $($d.FullName) - $($open.Count) item(s) not handled ($($open -join ', ')); restart it (orchestrate step 7) once the workflow runs again" }
}
$out | ForEach-Object { $_ }
exit 0
