#Requires -Version 7
<#
harness.ps1: the shared helpers every tests/<area>.tests.ps1 dot-sources (not run on its own).
Usage: . (Join-Path $PSScriptRoot 'harness.ps1') at the top of an area file; Complete-Tests at its end.
Exit codes: none here; Complete-Tests ends the area file with 0 pass · 1 a check failed.
#>
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot   # the kit
$script:fails = 0
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # own runtime + state per test kit
$np = '-NoProfile', '-File'   # pwsh @np <script>
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$env:KIT_POLL_MS = '200'; $env:CLAUDE_GATE_KEEP_FREE_GB = '0'   # Wait-KitPoll fake clock; test builds are tiny: never queue for RAM
$env:TEMP = $env:TMP = Join-Path ([IO.Path]::GetTempPath()) "kit-tests-$PID"; New-Item -ItemType Directory -Force $env:TEMP | Out-Null   # own temp: never the machine's build-gate queue
# `pwsh -NoProfile -File <kit script>` from a test runs in this process (0.07 s, not a 0.7 s start): streams, exit code, cwd, env and
# globals as a child sees them; stdin readers and gate / check (console writers) stay processes; KIT_TESTS_SPAWN=1: always processes
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
function pwsh {
  $a = @($args); $in = @($input)
  if ($env:KIT_TESTS_SPAWN -or $in.Count -or $a.Count -lt 3 -or $a[0] -ne '-NoProfile' -or $a[1] -ne '-File' -or "$($a[2])" -notmatch '\.ps1$' -or "$($a[3])" -in 'gate', 'check', 'guard' -or
    "$((Get-PSCallStack)[1].ScriptName)" -notlike "$PSScriptRoot*") { $in | & $pwshExe @a; return }
  $ErrorActionPreference = 'Continue'; $here = Get-Location; $envs = [Environment]::GetEnvironmentVariables(); $g0 = @((Get-Variable -Scope Global).Name)
  $ew = [IO.StringWriter]::new(); $e0 = [Console]::Error; [Console]::SetError($ew); $i0 = [Console]::In; [Console]::SetIn([IO.StringReader]::new('')); $global:LASTEXITCODE = 0
  $rest = @($a | Select-Object -Skip 3)
  try { & $a[2] @rest *>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { Write-Error -ErrorRecord $_ } else { "$_" } } }
  catch { Write-Error -ErrorRecord $_; $global:LASTEXITCODE = 1 }
  finally {
    $code = $global:LASTEXITCODE; [Console]::SetError($e0); [Console]::SetIn($i0); Set-Location $here
    Get-Variable -Scope Global | Where-Object Name -NotIn $g0 | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue   # memos ($KitTrackerMemo, ...) die with a process
    $now = [Environment]::GetEnvironmentVariables(); foreach ($n in $now.Keys) { if (-not $envs.Contains($n)) { [Environment]::SetEnvironmentVariable($n, $null) } }
    foreach ($n in $envs.Keys) { if ($now[$n] -ne $envs[$n]) { [Environment]::SetEnvironmentVariable($n, $envs[$n]) } }
    if ("$ew") { Write-Error "$ew".TrimEnd() }
    $global:LASTEXITCODE = $code
  }
}

function Kd { Split-Path $k }
function Px { $input | pwsh -NoProfile -File @args }
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
# one Expect per key: a "<key>:true" line in $res ('#' in $label = the key); -Show N: N lines on a miss
function Expect-Each($res, [string]$label, [string[]]$keys, [int]$Show = 0) {
  foreach ($x in $keys) { Expect $label.Replace('#', $x) (@($res | Where-Object { "$_" -eq "${x}:true" }).Count -eq 1) }
  if ($Show -and @($res | Where-Object { "$_" -match ':true$' }).Count -ne $keys.Count) { $res | Select-Object -First $Show }
}
# a script run in its own pwsh: .out = stdout + stderr as one string, .code = its exit code
function Invoke-TestScript {
  $out = $input | pwsh -NoProfile -File @args 2>&1 | Out-String
  [pscustomobject]@{ out = $out; code = $LASTEXITCODE }
}
# table-driven cases: each row = @(name, { run }, { param($r) check $r }); one Expect per row
function Expect-Cases([object[]]$Cases) {
  foreach ($case in $Cases) { $result = & $case[1]; Expect $case[0] (& $case[2] $result) }
}
function Invoke-PsTest([string]$Name, [string]$Script, $ArgsToPass = @()) { $f = Join-Path (Kd) "$Name.ps1"; Set-Content $f $Script -Encoding utf8; @(pwsh @np $f @ArgsToPass 2>&1) }
function Set-JsonFile([string]$Path, $Obj, [int]$Depth = 8) {
  $d = Split-Path $Path; if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  $Obj | ConvertTo-Json -Depth $Depth | Set-Content $Path -Encoding utf8
}
$J = { param($o, $f, [int]$d = 8) Set-JsonFile $f $o $d }
# a throw-away kit copy (the scripts the tests run) in %TEMP%; one per area file
function New-TestKit([string]$name) {
  $k = Join-Path ([IO.Path]::GetTempPath()) "kit-test-$name-$PID\.claude"
  foreach ($f in 'skills/dev-kit/lib.ps1', 'skills/dev-kit/kit.example.json', 'skills/dev-kit/dev.ps1', 'skills/dev-kit/devtools.py', 'skills/qa-kit/qa.ps1',
      'skills/orchestrate/orch.ps1', 'skills/local-env/localenv.ps1', 'LESSONS.md') {
    $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path $src $f) $d
  }
  $k
}
function TkPath($tkDir, $tkName, [switch]$Create) { & { . (Join-Path $tkDir 'skills/dev-kit/lib.ps1'); Get-KitPath $tkName -Create:$Create } }
function Remove-TestKit($k) { Remove-Item (Kd) -Recurse -Force -ErrorAction SilentlyContinue }
function Complete-Tests { "$script:fails failure(s)"; exit [int]($script:fails -gt 0) }
