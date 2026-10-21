#Requires -Version 7
<#
tests.ps1 (extra ports): TOML / YAML escaping, LF output, port_deploy keeps user files, port --check clean on a kit copy.
Usage: kittool.py extra test ports (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kittool.py extra test: the kit's harness
$plugin = Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_ports.py'
$res = @(& $py -X utf8 (Join-Path $PSScriptRoot 'ports_test.py') (Join-Path $src 'skills/orchestrate/kittool.py') $plugin 2>&1)
Expect 'ports: a quote and a backslash stay valid TOML / YAML, LF only' ($res -contains 'ports-escape:True')
Expect 'ports: port_deploy keeps user files, removes only stale generated ports' ($res -contains 'ports-deploy:True')
# port --check on a copy of the kit (not named .claude: no workspace copy is compared)
$root = Join-Path ([IO.Path]::GetTempPath()) "ports-kit-$PID"; $kc = Join-Path $root 'kit'
Copy-KitTree $kc
Copy-Item $plugin (Join-Path $kc 'skills/orchestrate')
$ck = & $py -X utf8 (Join-Path $kc 'skills/orchestrate/kittool.py') port --check 2>&1 | Out-String; $cc = $LASTEXITCODE
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Expect "ports: port --check is clean on the kit's own ports (exit $cc $($ck.Trim()))" ($cc -eq 0)
Complete-Tests
