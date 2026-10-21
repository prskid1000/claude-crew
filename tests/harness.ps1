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
