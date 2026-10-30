#Requires -Version 7
<#
tests.ps1 (goody ports): TOML / YAML escaping, LF output, port_deploy keeps user files, port --check clean on a kit copy.
Usage: kitbag.py goody test ports (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kitbag.py goody test: the kit's harness
$plugin = Join-Path $PSScriptRoot 'files/skills/bossy/kitbag_ports.py'
$res = @(& $py -X utf8 (Join-Path $PSScriptRoot 'ports_test.py') (Join-Path $src 'skills/bossy/kitbag.py') $plugin 2>&1)
Expect 'ports: a quote and a backslash stay valid TOML / YAML, LF only' ($res -contains 'ports-escape:True')
Expect 'ports: port_deploy keeps user files, removes only stale generated ports' ($res -contains 'ports-deploy:True')
Expect 'ports: hooks absolute, no double quotes (agy cmd /c); Codex cleanup async + KIT_TOOL; agy cleanup detached, hidden' ($res -contains 'ports-hooks:True')
Expect 'ports: workspace skill links, org rules always-on (split under 24 KB) + AGENTS.override.md, none in the kit' ($res -contains 'ports-workspace:True')
Expect 'ports: run_workflow bridge runs the .js; agent() -> agentType, role, workspace inherit, haiku -> flash; a failed agent = null' ($res -contains 'ports-workflow:True')
Expect 'ports: owner decisions: blocking -> request_user_input (Codex Plan mode) / ask_question when listed, else text; FYI list' ($res -contains 'ports-ask:True')
# port --check on a copy of the kit (not named .claude: no workspace copy is compared)
$root = Join-Path ([IO.Path]::GetTempPath()) "ports-kit-$PID"; $kc = Join-Path $root 'kit'
Copy-KitTree $kc
Copy-Item $plugin (Join-Path $kc 'skills/bossy')
$ck = & $py -X utf8 (Join-Path $kc 'skills/bossy/kitbag.py') port --check 2>&1 | Out-String; $cc = $LASTEXITCODE
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Expect "ports: port --check is clean on the kit's own ports (exit $cc $($ck.Trim()))" ($cc -eq 0)
Complete-Tests
