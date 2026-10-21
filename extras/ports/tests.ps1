#Requires -Version 7
<#
tests.ps1 (extra ports): TOML / YAML escaping, LF output, port_deploy keeps user files, port --check clean on a kit copy.
Usage: pwsh -NoProfile -File extras/ports/tests.ps1 -Kit <kit>   (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$plugin = Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_ports.py'
$script:fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
$res = @(& $py -X utf8 (Join-Path $PSScriptRoot 'ports_test.py') (Join-Path $Kit 'skills/orchestrate/kittool.py') $plugin 2>&1)
Expect 'ports: a quote and a backslash stay valid TOML / YAML, LF only' ($res -contains 'ports-escape:True')
Expect 'ports: port_deploy keeps user files, removes only stale generated ports' ($res -contains 'ports-deploy:True')
# port --check on a copy of the kit (not named .claude: no workspace copy is compared)
$root = Join-Path ([IO.Path]::GetTempPath()) "ports-kit-$PID"; $kc = Join-Path $root 'kit'
foreach ($f in @(git -C $Kit ls-files)) { $s1 = Join-Path $Kit $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
Copy-Item $plugin (Join-Path $kc 'skills/orchestrate')
$ck = & $py -X utf8 (Join-Path $kc 'skills/orchestrate/kittool.py') port --check 2>&1 | Out-String; $cc = $LASTEXITCODE
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Expect "ports: port --check is clean on the kit's own ports (exit $cc $($ck.Trim()))" ($cc -eq 0)
"$script:fails failure(s)"
exit [int]($script:fails -gt 0)
