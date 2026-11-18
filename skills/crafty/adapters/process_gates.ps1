#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (Set-TrackerStatus throws on a refusal).
# process-gate: Test-KitProcessGate (devtools.py process_gate is the python twin). Kind process-gate: verbs = gate names
# (promote merge finish bugFix mrBody); built-ins testingDocs (promote here; devtools.py: merge, finish, mrBody) and reproRow (bugFix, devtools.py).
# process.gates.<gate>: unset = pass · builtin:<name> · a command line (payload JSON on stdin, exit 0 = pass, stdout = why).
# Sections: L7 gate · L38 process docs · L75 waits
# ---- gate: process gates, a bounded stdin command
# a command with text on stdin, bounded: { code; out; err }
function Invoke-KitStdinExe([string]$Exe, [string[]]$A, [string]$In, [int]$TimeoutSec = 120) {
  $cmd = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return [pscustomobject]@{ code = 127; out = ''; err = "$Exe is not on PATH" } }
  $si = [Diagnostics.ProcessStartInfo]::new($cmd.Source); foreach ($x in @($A)) { $si.ArgumentList.Add([string]$x) }
  $si.RedirectStandardInput = $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($si); $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $w = [IO.StreamWriter]::new($p.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false)); $w.Write($In); $w.Close()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { Stop-KitProcessTree $p; return [pscustomobject]@{ code = -1; out = ''; err = "$Exe timed out after $TimeoutSec s" } }
  $p.WaitForExit(); [pscustomobject]@{ code = $p.ExitCode; out = $so.Result.TrimEnd(); err = $se.Result.TrimEnd() }
}
# -> { ok; why; how }: how = none | builtin:<name> | the command
function Test-KitProcessGate([Parameter(Mandatory)][ValidateSet('promote', 'merge', 'finish', 'bugFix', 'mrBody')][string]$Gate, [hashtable]$Payload = @{}) {
  $how = "$(Get-KitSetting "process.gates.$Gate" '')".Trim(); $res = { param($ok, $why) [pscustomobject]@{ ok = [bool]$ok; why = "$why".Trim(); how = $(if ($how) { $how } else { 'none' }) } }
  if (-not $how) { return & $res $true '' }
  if ($how -match '^builtin:(?<n>[\w-]+)$') {
    $ad = $KitAdapters['process-gate'][$Matches.n]
    if (-not ($ad -and $ad.ContainsKey($Gate))) { return & $res $false "process.gates.$Gate = $how`: no such built-in for this gate in pwsh (built-ins: README ""Adapters"" process-gate)" }
    $r = & $ad[$Gate] $Payload $Gate; return & $res $r.ok $r.why
  }
  $t = @(Split-KitCommand $how @{}); $p = @{} + $Payload; $p.gate = $Gate
  $r = Invoke-KitStdinExe $t[0] @($t | Select-Object -Skip 1) (ConvertTo-Json -InputObject $p -Depth 8 -Compress)
  & $res ($r.code -eq 0) $(if ("$($r.out)".Trim() -or $r.code -eq 0) { $r.out } else { "process.gates.$Gate hook exit $($r.code): $($r.err)" })
}
Register-KitAdapter 'process-gate' 'testingDocs' @{
  promote = { param($a) if ($KitConf.TrackerType -eq 'none' -and $env:KIT_DOC_GATE -ne '1') { return @{ ok = $true } }   # no tracker: nothing to read (KIT_DOC_GATE=1: tests)
    $l = Test-KitTaskDocLink "$($a.task)"; $need = (@(Get-KitProcessDocs | Where-Object required | ForEach-Object { "'$($_.label):'" }) -join ' and ')
    @{ ok = $l -eq $true; why = $(if ($l -ne $true) { "its description lacks $need links (devtools.py finish writes them) or the task could not be read" }) } }
}
# ---- process docs: testing docs (process.docs, else vocab.json), bug-run args, QA run gaps
function Get-KitProcessDocs {   # process.docs (an empty list = none), else vocab.json docs; required defaults to true
  $d = if ($__cfg -and $__cfg.process -and (Get-KitProps $__cfg.process).Name -contains 'docs') { $__cfg.process.docs } else { $script:KitVocab.docs }
  @(foreach ($x in @($d)) { if ($x.key -and $x.label) { [pscustomobject]@{ key = "$($x.key)"; label = "$($x.label)"; mrLabel = $(if ($x.mrLabel) { "$($x.mrLabel)" } else { "$($x.label)" })
          linkRx = $(if ($x.linkRx) { "$($x.linkRx)" } else { [regex]::Escape("$($x.label)") }); headerRx = "$($x.headerRx)"; required = $x.required -ne $false } } })
}
function Get-KitDocLabelRx { $l = @(Get-KitProcessDocs | ForEach-Object { [regex]::Escape($_.label) }); if ($l.Count) { "(?i)^\W{0,3}(?:$($l -join '|'))\W{0,3}:" } else { '' } }
# every required doc linked in the task description: $true / $false / $null (unread = unknown, never "no doc")
function Test-KitTaskDocLink([string]$Task) {
  try { $tt = Get-TrackerTask $Task } catch { return $null }
  if (-not $tt -or -not $tt.name) { return $null }
  $d = [string]$tt.description
  -not @(Get-KitProcessDocs | Where-Object required | Where-Object { $d -notmatch "(?im)^\W{0,3}$([regex]::Escape($_.label))\W{0,3}:[ \t*_]*[^\s*_]" }).Count   # an empty bold label is no link
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
# qa-runs/<run>/run.json or <run>/<code>/finalize.json at their fixed depth (a -Recurse walk listed every evidence file and
# matched scripts/run.json and archive-*/finalize.json copies); -SinceDays: written within that many days
function Get-KitQaRunFiles([ValidateSet('run.json', 'finalize.json')][string]$Name, [double]$SinceDays) {
  $root = Get-KitPath qa-runs; if (-not [IO.Directory]::Exists($root)) { return }
  $since = if ($SinceDays) { [datetime]::Now.AddDays(-$SinceDays) } else { [datetime]::MinValue }
  foreach ($rd in [IO.DirectoryInfo]::new($root).EnumerateDirectories()) {
    $dirs = if ($Name -eq 'run.json') { @($rd) } else { @(try { $rd.EnumerateDirectories() } catch { }) }
    foreach ($d in $dirs) { $f = [IO.FileInfo]::new((Join-Path $d.FullName $Name)); if ($f.Exists -and $f.LastWriteTime -gt $since) { $f } }
  }
}
# ---- waits: poll backoff, file-change wake, kit log start
# a poll's wait: -Seen unchanged since the last round doubles it up to poll.maxSec, a change resets it to -Base; never past -End
function Wait-KitBackoff([hashtable]$State, [string]$Seen, [double]$Base, [datetime]$End) {
  $State.wait = if ($Seen -cne $State.seen -or -not $State.wait) { $Base } else { [math]::Min([double](Get-KitParam 'poll.maxSec'), 2 * $State.wait) }; $State.seen = $Seen
  Start-Sleep -Seconds ([int][math]::Max(1.0, [math]::Min($State.wait, ($End - (Get-Date)).TotalSeconds + 1)))
}
# sleep up to -Seconds; a write to -File after the first 2 s ends it early (a loop's idle tick that a request wakes)
function Wait-KitFileChange([string]$File, [int]$Seconds) {
  $t0 = [IO.File]::GetLastWriteTimeUtc($File); for ($i = 0; $i -lt $Seconds; $i++) { Start-Sleep 1; if ($i -ge 2 -and [IO.File]::GetLastWriteTimeUtc($File) -ne $t0) { return } }
}
# Read-KitLog: rows append in time order ({"at":"<time>" first), so a binary search skips the older ones unparsed (a day's files
# parsed whole: ~0.8 s a call) -> the non-empty lines from 30 min before -Since on (slack for late rows; an unreadable time = late)
function Get-KitLogLines([string]$File, [datetime]$Since) {
  $Lines = "$(Get-Content -LiteralPath $File -Raw)" -split '\r?\n'
  $lo = 0; $hi = $Lines.Count; $atv = [datetimeoffset]::MinValue; $Cut = if ($Since.Year -gt 1) { $Since.AddMinutes(-30) } else { $Since }
  while ($lo -lt $hi) { $mid = [int][math]::Floor(($lo + $hi) / 2); $l = $Lines[$mid]
    if ($l.StartsWith('{"at":"') -and ($q = $l.IndexOf('"', 7)) -gt 7 -and [datetimeoffset]::TryParse($l.Substring(7, $q - 7), [ref]$atv) -and $atv.LocalDateTime -lt $Cut) { $lo = $mid + 1 } else { $hi = $mid } }
  for ($i = $lo; $i -lt $Lines.Count; $i++) { if ($Lines[$i]) { $Lines[$i] } }
}
