#Requires -Version 7
<#
ports.tests.ps1: TOML / YAML escaping, LF output, port_deploy keeps user files, ports.targets transitions and cleanup, port --check clean on a kit copy.
Usage: pwsh -NoProfile -File <kit>/tests/ports.tests.ps1 (or tests/kit-tests.ps1 -Area ports).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/heartbeat.ps1', 'skills/bossy/kitbag_ports.py')   # copied into every New-TestKit kit
$plugin = Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/kitbag_ports.py'
$res = @(& $py -X utf8 (Join-Path $PSScriptRoot 'ports_test.py') (Join-Path $src 'skills/bossy/kitbag.py') $plugin 2>&1)
Expect 'ports: a quote and a backslash stay valid TOML / YAML, LF only' ($res -contains 'ports-escape:True')
Expect 'ports: port_deploy keeps user files, removes only stale generated ports' ($res -contains 'ports-deploy:True')
Expect 'ports: hooks absolute, no double quotes (agy cmd /c); Codex cleanup async + KIT_TOOL; agy cleanup detached, hidden' ($res -contains 'ports-hooks:True')
Expect 'ports: workspace skill links, org rules always-on (split under 24 KB) + AGENTS.override.md, none in the kit' ($res -contains 'ports-workspace:True')
Expect "ports.targets: every transition (both/codex/antigravity/none) keeps the chosen copies, removes only kit-written ones ($($res -match '^ports-targets:'))" ($res -contains 'ports-targets:True []')
Expect 'ports.targets: deselected folder gone when empty or clutter only, kept + listed with an authored file; clutter override; old copies by manifest' ($res -contains 'ports-folders:True True True True')
Expect 'ports: run_workflow bridge runs the .js; agent() -> agentType, role, workspace inherit, haiku -> flash; a failed agent = null' ($res -contains 'ports-workflow:True')
Expect 'ports: owner decisions: blocking -> request_user_input (Codex Plan mode) / ask_question when listed, else text; FYI list' ($res -contains 'ports-ask:True')
$beatRx = 'Get-KitBeatPrompt \{ "Run & .+? supervise -AutoFix -Brief\. (.+?)" \}'
$libBeat = if ((Get-Content (Join-Path $src 'skills/crafty/lib.ps1') -Raw) -match $beatRx) { $Matches[1] }
$portBeat = & $py -X utf8 -c "import ast, sys; t = ast.parse(open(sys.argv[1], encoding='utf-8').read()); print(next(ast.literal_eval(n.value) for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], 'id', '') == 'E1_PROMPT'))" $plugin
Expect 'ports: E1 heartbeat prompt = lib.ps1 Get-KitBeatPrompt word for word, no stdout paste' ($libBeat -and "$portBeat".EndsWith($libBeat) -and "$portBeat" -notmatch 'verbatim')
# port then port --check on a copy of the kit (not named .claude: no workspace copy is compared). main's committed ports may
# predate this branch's plugin (main's pre-push checks those): reported, not failed
$root = Join-Path ([IO.Path]::GetTempPath()) "ports-kit-$PID"; $kc = Join-Path $root 'kit'
Copy-KitTree $kc
Copy-Item $plugin (Join-Path $kc 'skills/bossy')
$kbp = Join-Path $kc 'skills/bossy/kitbag.py'
$null = & $py -X utf8 $kbp port --check 2>&1; $main = if ($LASTEXITCODE) { "main's ports predate this plugin: regenerate on main" } else { "main's ports current" }
$pt = & $py -X utf8 $kbp port 2>&1 | Out-String; $pc = $LASTEXITCODE
$ck = & $py -X utf8 $kbp port --check 2>&1 | Out-String; $cc = $LASTEXITCODE
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Expect "ports: port, then port --check is clean (idempotent, byte-stable) on a kit copy; $main (exit $pc/$cc $($ck.Trim()) $(if ($pc) { $pt.Trim() }))" ($pc -eq 0 -and $cc -eq 0)
Complete-Tests
