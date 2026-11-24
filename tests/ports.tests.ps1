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
Expect 'ports.targets unset or unknown: off, no workspace copies (owner 2026-11-22)' ($res -contains 'ports-default-off:True')
Expect 'ports: hooks absolute, no double quotes (agy cmd /c); Codex cleanup + health -Flow async, KIT_TOOL; agy both detached, hidden' ($res -contains 'ports-hooks:True')
Expect "parity: every adapter verb and harness feature native, fallback or a declared gap on this kit ($($res -match '^parity-kit:'))" ($res -contains 'parity-kit:True []')
Expect 'parity: a verb on one adapter only fails (no family list); a family cap fails every sibling without it until a fallback' ($res -contains 'parity-sibling:True')
Expect 'parity: a renamed verb is missing though a nested @{ status = } remains; a dropped hook is missing though a longer one starts with it' ($res -contains 'parity-nested:True')
Expect 'parity: a declared gap the adapter now has, or one naming no adapter, fails' ($res -contains 'parity-gaps:True')
Expect 'parity: a Claude Code hook neither Codex nor Antigravity runs fails both until declared (gap / fallback)' ($res -contains 'parity-harness:True')
Expect "parity next: the org's adapter first, no none adapter, only fallback / gap cells, a no-such-feature gap left out, one without its link fails ($($res -match '^parity-next:'))" ($res -contains 'parity-next:True|True|True|True|True')
Expect 'ports: workspace skill links, org rules always-on (split under 24 KB) + AGENTS.override.md, none in the kit' ($res -contains 'ports-workspace:True')
Expect "ports.targets: every transition (both/codex/antigravity/none) keeps the chosen copies, removes only kit-written ones ($($res -match '^ports-targets:'))" ($res -contains 'ports-targets:True []')
Expect 'ports.targets: deselected folder gone when empty or clutter only, kept + listed with an authored file; clutter override; old copies by manifest' ($res -contains 'ports-folders:True True True True')
Expect 'ports: run_workflow bridge runs the .js; agent() -> agentType, role, workspace inherit, haiku -> flash; a failed agent = null' ($res -contains 'ports-workflow:True')
Expect "ports: crew tool allowlists: toolSets expand, grants only in the installed kit, filter clean strips / smudge adds them, step tool names, MCP servers no role grants ($($res -match '^ports-tools:'))" ($res -contains 'ports-tools:True True True True True')
Expect 'ports: owner decisions: blocking -> request_user_input (Codex Plan mode) / ask_question when listed, else text; FYI list' ($res -contains 'ports-ask:True')
Expect 'ports: agy runner phase / effort opts; its journal: launched, started + result per agent, done on success, finished on a failure' ($res -contains 'ports-journal:True')
Expect "ports: Codex docs carry the gates (anchors in the .js), approval never + network, workspace-write agents, test-login rules ($($res -match '^ports-codex:'))" ($res -contains 'ports-codex:True True True True')
Expect "ports: Codex exec policy forbids --no-verify after value-free flags and every reader on each literal logins path; other commands pass ($($res -match '^ports-codex-policy:'))" ($res -contains 'ports-codex-policy:True []')
# an Antigravity run's journal (<port-runs>/antigravity/...) is a workflow dir: Runs band, recover and resume see it
$k = New-TestKit 'port-runs'; $prT = Join-Path (Kd) 'no-transcripts'; New-Item -ItemType Directory -Force $prT | Out-Null
$prD = New-Item -ItemType Directory -Force (Join-Path (TkPath $k 'port-runs' -Create) 'antigravity/subagents/workflows/wf_agy-test')
Set-Content (Join-Path $prD 'journal.jsonl') @('{"type":"launched"}', '{"type":"started","agentId":"agy1","label":"build:A"}', '{"type":"result","agentId":"agy1","result":{"ok":true}}', '{"type":"done"}')
$prOut = pwsh -NoProfile -Command "`$env:KIT_TRANSCRIPTS = '$prT'; . '$(Lib)' 6>`$null; `$d = @(Get-KitWorkflowDirs 'antigravity'); `$ev = @(Get-Content (Join-Path `$d[0].FullName 'journal.jsonl') | ConvertFrom-Json); `"`$(`$d.Name) `$(Get-KitRunState `$d[0] @() `$ev)`"" 2>&1 | Out-String
Expect "ports: Get-KitWorkflowDirs lists Antigravity run journals; a done run is ended ($($prOut.Trim()))" ($prOut.Trim() -eq 'wf_agy-test ended')
Remove-TestKit $k
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
# the kittools git filter in a real repo: port --deploy renders a grant, commits and checkouts keep the manifest line, status clean
$k = New-TestKit 'tools-git'; $tg = Join-Path (Kd) 'tg/ws/.claude'
foreach ($sub in 'skills/bossy', 'skills/crafty', 'agents') { New-Item -ItemType Directory -Force (Join-Path $tg $sub) | Out-Null }
Copy-Item (Join-Path $src 'skills/bossy/*.py'), (Join-Path $src 'skills/bossy/*.json') (Join-Path $tg 'skills/bossy/'); Copy-Item (Join-Path $src 'skills/crafty/kit.example.json') (Join-Path $tg 'skills/crafty/')
Copy-Item (Join-Path $src 'agents/devy.md') (Join-Path $tg 'agents/'); Copy-Item (Join-Path $src '.gitattributes') $tg
Set-Content (Join-Path $tg 'AGENTS.md') 'x'; Set-Content (Join-Path $tg '.gitignore') "*.local.*`n.runtime/`n.state/`n__pycache__/"
git -C $tg init -q -b main; git -C $tg add -A; git -C $tg -c user.email=t@t -c user.name=t commit -qm init
Set-Content (Join-Path $tg 'skills/crafty/kit.local.json') '{"tools": {"roles": {"devy": ["mcp__db"]}}}'
& $py -X utf8 (Join-Path $tg 'skills/bossy/kitbag.py') port --deploy *>&1 | Out-Null
$tgLine = { @(Get-Content (Join-Path $tg 'agents/devy.md') | Where-Object { $_ -like 'tools:*' })[0] }
$tgR = & $tgLine; $tgS = "$(git -C $tg status --porcelain)"; $tgC = @(git -C $tg show HEAD:agents/devy.md | Where-Object { $_ -like 'tools:*' })[0]
Remove-Item (Join-Path $tg 'agents/devy.md'); git -C $tg checkout -- agents/devy.md; $tgO = & $tgLine; $tgS += "$(git -C $tg status --porcelain)"
Expect "ports: kittools filter: grant rendered + checked out ($tgO), never committed ($tgC), status clean [$tgS]" ($tgR -like '*, mcp__db' -and $tgO -eq $tgR -and $tgC -notlike '*mcp__db*' -and -not $tgS)
Remove-TestKit $k
Complete-Tests
