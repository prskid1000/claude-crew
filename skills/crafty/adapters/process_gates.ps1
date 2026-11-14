#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (Set-TrackerStatus throws on a refusal).
# process-gate: Test-KitProcessGate (devtools.py process_gate is the python twin). Kind process-gate: verbs = gate names
# (promote merge finish bugFix mrBody); built-ins testingDocs (promote here; devtools.py: merge, finish, mrBody) and reproRow (bugFix, devtools.py).
# process.gates.<gate>: unset = pass · builtin:<name> · a command line (payload JSON on stdin, exit 0 = pass, stdout = why).
# a command with text on stdin, bounded: { code; out; err }
function Invoke-KitStdinExe([string]$Exe, [string[]]$A, [string]$In, [int]$TimeoutSec = 120) {
  $cmd = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return [pscustomobject]@{ code = 127; out = ''; err = "$Exe is not on PATH" } }
  $si = [Diagnostics.ProcessStartInfo]::new($cmd.Source); foreach ($x in @($A)) { $si.ArgumentList.Add([string]$x) }
  $si.RedirectStandardInput = $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($si); $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $w = [IO.StreamWriter]::new($p.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false)); $w.Write($In); $w.Close()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; return [pscustomobject]@{ code = -1; out = ''; err = "$Exe timed out after $TimeoutSec s" } }
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
