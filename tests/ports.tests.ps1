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
Expect 'ports: the Codex guard hook matches shell, apply_patch and MCP SQL tools (parity: guard on MCP SQL), no other MCP tool' ($res -contains 'ports-codex-mcp:True')
Expect 'ports: Codex and agy reads / MCP calls run guard_client.mjs (agy: view_file, call_mcp_tool, mcp_*); agy run_command keeps crafty.ps1 guard; a spaced path pipes stdin through pwsh' ($res -contains 'ports-guard-reads:True')
Expect 'ports: agy agents get their tools by agy name (+ call_mcp_tool); one with no agy name leaves the list unset' ($res -contains 'ports-agy-tools:True')
Expect "parity: every adapter verb and harness feature native, fallback or a declared gap on this kit ($($res -match '^parity-kit:'))" ($res -contains 'parity-kit:True []')
Expect 'parity: a verb on one adapter only fails (no family list); a family cap fails every sibling without it until a fallback' ($res -contains 'parity-sibling:True')
Expect 'parity: a renamed verb is missing though a nested @{ status = } remains; a dropped hook is missing though a longer one starts with it' ($res -contains 'parity-nested:True')
Expect 'parity: a declared gap the adapter now has, or one naming no adapter, fails' ($res -contains 'parity-gaps:True')
Expect "parity from code (owner 2026-11-24): an adapter registered but undeclared is walked and fails, a verb that only throws UNSUPPORTED is missing, a verb code calls in no list fails and is a cell on every adapter, a fallback no adapter uses fails ($($res -match '^parity-code:'))" ($res -contains 'parity-code:True|True|True|True|True|True')
Expect 'parity: a Claude Code hook neither Codex nor Antigravity runs fails both until declared (gap / fallback)' ($res -contains 'parity-harness:True')
Expect "parity next: the org's adapter first, no none adapter, only fallback / gap cells, a no-such-feature gap and an accepted fallback left out, one without its link fails, an accepted native cell or one without a reason fails ($($res -match '^parity-next:'))" ($res -contains 'parity-next:True|True|True|True|True|True|True')
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
# parity (harness run journals): a Codex by-hand run journals each step (kitbag.py port --journal), the same records: the Runs band sees it
$cjKb = Join-Path $k 'skills/bossy/kitbag.py'; $cjRc = @(foreach ($cjA in @(@('launched', '--workflow', 'buildy'), @('started', '--agent', 'th-1', '--label', 'build:A', '--phase', 'Build'), @('result', '--agent', 'th-1'))) { & $py -X utf8 $cjKb port --journal $cjA[0] --run r1 @($cjA | Select-Object -Skip 1) *> $null; $LASTEXITCODE })
$cjMid = pwsh -NoProfile -Command "`$env:KIT_TRANSCRIPTS = '$prT'; . '$(Lib)' 6>`$null; `$d = @(Get-KitWorkflowDirs 'codex'); `$ev = @(Get-Content (Join-Path `$d[0].FullName 'journal.jsonl') | ConvertFrom-Json); `"`$(`$d.Name) `$(@(`$ev).Count)`"" 2>&1 | Out-String
& $py -X utf8 $cjKb port --journal done --run r1 *> $null; & $py -X utf8 $cjKb port --journal started --run r1 *> $null; $cjBad = $LASTEXITCODE
$cjOut = pwsh -NoProfile -Command "`$env:KIT_TRANSCRIPTS = '$prT'; . '$(Lib)' 6>`$null; `$d = @(Get-KitWorkflowDirs 'codex'); `$ev = @(Get-Content (Join-Path `$d[0].FullName 'journal.jsonl') | ConvertFrom-Json); `"`$(`$d.Name) `$(Get-KitRunState `$d[0] @() `$ev)`"" 2>&1 | Out-String
Expect "ports: a Codex run's journal lines (kitbag.py port --journal) list as a workflow dir; done = ended; started without --agent refused ($($cjRc -join ',') | $($cjMid.Trim()) | $($cjOut.Trim()) | $cjBad)" (($cjRc -join ',') -eq '0,0,0' -and $cjMid.Trim() -eq 'wf_cdx-r1 3' -and $cjOut.Trim() -eq 'wf_cdx-r1 ended' -and $cjBad -eq 2)
# parity (harness Monitor and background-shell check): a Codex exec_command and an Antigravity run_command shell are found in their
# transcripts (codex / agy parents) and die with their agent; the other one stays
$cxg = & { . (Join-Path $k 'skills/bossy/bossy.ps1'); $mt = Get-Date; $env:KIT_TRANSCRIPTS = $prT; $env:KIT_TRANSCRIPTS_CODEX = Join-Path (Kd) 'txc'; $env:KIT_TRANSCRIPTS_ANTIGRAVITY = Join-Path (Kd) 'txa'
  $cxF = Join-Path $env:KIT_TRANSCRIPTS_CODEX '2026/01/02/rollout-x.jsonl'; $agF = Join-Path $env:KIT_TRANSCRIPTS_ANTIGRAVITY 'c1/.system_generated/logs/transcript.jsonl'
  foreach ($d in $cxF, $agF) { $null = New-Item -ItemType Directory -Force (Split-Path $d) }
  $cxC = 'tail -f D:/x/codex-watch.out'; $agC = 'tail -f D:/x/agy-watch.out'
  @{ timestamp = $mt.ToUniversalTime().ToString('o'); type = 'response_item'; payload = @{ type = 'function_call'; name = 'exec_command'; call_id = 'c9'; arguments = (@{ cmd = $cxC } | ConvertTo-Json -Compress) } } | ConvertTo-Json -Depth 9 -Compress | Set-Content $cxF
  @{ type = 'PLANNER_RESPONSE'; tool_calls = @(@{ name = 'run_command'; args = @{ CommandLine = (ConvertTo-Json $agC); WaitMsBeforeAsync = '500' } }) } | ConvertTo-Json -Depth 9 -Compress | Set-Content $agF
  $ps = @([pscustomobject]@{ Id = 5; ParentId = 1; Name = 'codex.exe' }, [pscustomobject]@{ Id = 6; ParentId = 1; Name = 'agy.exe' },
    [pscustomobject]@{ Id = 7; ParentId = 5; Name = 'bash.exe'; CommandLine = "bash -lc '$cxC'"; Created = $mt }, [pscustomobject]@{ Id = 8; ParentId = 6; Name = 'pwsh.exe'; CommandLine = "pwsh -Command $agC"; Created = $mt })
  $got = "$(@(Get-KitAgentShells $ps | ForEach-Object Id) -join ',')"
  $a = @(Stop-KitLeftShells ([pscustomobject]@{ agent = 'cx'; transcript = $cxF }) $ps $null { }); $b = @(Stop-KitLeftShells ([pscustomobject]@{ agent = 'ag'; transcript = $agF }) $ps $null { })
  Remove-Item Env:KIT_TRANSCRIPTS, Env:KIT_TRANSCRIPTS_CODEX, Env:KIT_TRANSCRIPTS_ANTIGRAVITY; "$got|$a|$b" }
Expect "background shells on Codex and Antigravity: found under codex / agy, each killed with its own agent only ($cxg)" ($cxg -match '^7,8\|killed shell 7 of cx: [^|]*\|killed shell 8 of ag: ' -and $cxg -notmatch 'shell 8 of cx|shell 7 of ag')
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
