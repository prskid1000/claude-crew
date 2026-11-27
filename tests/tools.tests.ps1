#Requires -Version 7
<#
tools.tests.ps1: crew tool allowlists, the kittools git filter, MCP lines, Character blocks (kitbag.py tools), adapter parity.
Usage: pwsh -NoProfile -File <kit>/tests/tools.tests.ps1 (or tests/kit-tests.ps1 -Area tools).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$admin = Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/kitbag_admin.py'
$res = @(& $py -X utf8 (Join-Path $PSScriptRoot 'tools_test.py') (Join-Path $src 'skills/bossy/kitbag.py') $admin 2>&1)
Expect "tools: crew tool allowlists: toolSets expand, grants only in the installed kit, filter clean strips / smudge adds them, step tool names, MCP servers no role grants ($($res -match '^tools-lines:'))" ($res -contains 'tools-lines:True True True True True')
Expect "parity: every adapter verb native, fallback or a declared gap on this kit ($($res -match '^parity-kit:'))" ($res -contains 'parity-kit:True []')
Expect 'parity: a verb on one adapter only fails (no family list); a family cap fails every sibling without it until a fallback' ($res -contains 'parity-sibling:True')
Expect 'parity: a renamed verb is missing though a nested @{ status = } remains' ($res -contains 'parity-nested:True')
Expect 'parity: a declared gap the adapter now has, or one naming no adapter, fails' ($res -contains 'parity-gaps:True')
Expect 'parity: braces in strings and comments are no code; verbs after them are read (retro tidy-6)' ($res -contains 'parity-strings:True')
Expect "parity from code (owner 2026-11-24): an adapter registered but undeclared fails, a verb that only throws UNSUPPORTED is missing, a verb code calls in no list fails, a fallback no adapter uses fails ($($res -match '^parity-code:'))" ($res -contains 'parity-code:True|True|True|True|True|True')
Expect "parity next: the org's adapter first, no none adapter, only fallback / gap cells, a no-such-feature gap and an accepted fallback left out, one without its link fails ($($res -match '^parity-next:'))" ($res -contains 'parity-next:True|True|True|True|True|True|True')
# tools --write on a kit copy: Character blocks and tools lines already match the manifest, nothing rewritten; a drifted block is restored
$root = Join-Path ([IO.Path]::GetTempPath()) "tools-kit-$PID"; $kc = Join-Path $root 'kit'
Copy-KitTree $kc
$kbp = Join-Path $kc 'skills/bossy/kitbag.py'; $ag = Join-Path $kc 'agents/revy.md'
$before = [IO.File]::ReadAllText($ag)
$tw = & $py -X utf8 $kbp tools --write 2>&1 | Out-String; $twc = $LASTEXITCODE; $same = [IO.File]::ReadAllText($ag) -eq $before
[IO.File]::WriteAllText($ag, ($before -replace '\*\*Character:\*\* traits: [^·]+', '**Character:** traits: drifted '))
$null = & $py -X utf8 $kbp tools --write 2>&1; $back = [IO.File]::ReadAllText($ag) -eq $before
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Expect "tools --write: idempotent on a clean kit, a drifted Character block restored from the manifest (exit $twc, same $same, restored $back $($tw.Trim()))" ($twc -eq 0 -and $same -and $back)
# the kittools git filter in a real repo: tools --deploy renders a grant, commits and checkouts keep the manifest line, status clean
$k = New-TestKit 'tools-git'; $tg = Join-Path (Kd) 'tg/ws/.claude'
foreach ($sub in 'skills/bossy', 'skills/crafty', 'agents') { New-Item -ItemType Directory -Force (Join-Path $tg $sub) | Out-Null }
Copy-Item (Join-Path $src 'skills/bossy/*.py'), (Join-Path $src 'skills/bossy/*.json') (Join-Path $tg 'skills/bossy/'); Copy-Item (Join-Path $src 'skills/crafty/kit.example.json') (Join-Path $tg 'skills/crafty/')
Copy-Item (Join-Path $src 'agents/devy.md') (Join-Path $tg 'agents/'); Copy-Item (Join-Path $src '.gitattributes') $tg
Set-Content (Join-Path $tg 'AGENTS.md') 'x'; Set-Content (Join-Path $tg '.gitignore') "*.local.*`n.runtime/`n.state/`n__pycache__/"
git -C $tg init -q -b main; git -C $tg add -A; git -C $tg -c user.email=t@t -c user.name=t commit -qm init
Set-Content (Join-Path $tg 'skills/crafty/kit.local.json') '{"tools": {"roles": {"devy": ["mcp__db"]}}}'
& $py -X utf8 (Join-Path $tg 'skills/bossy/kitbag.py') tools --deploy *>&1 | Out-Null
$tgLine = { @(Get-Content (Join-Path $tg 'agents/devy.md') | Where-Object { $_ -like 'tools:*' })[0] }
$tgR = & $tgLine; $tgS = "$(git -C $tg status --porcelain)"; $tgC = @(git -C $tg show HEAD:agents/devy.md | Where-Object { $_ -like 'tools:*' })[0]
Remove-Item (Join-Path $tg 'agents/devy.md'); git -C $tg checkout -- agents/devy.md; $tgO = & $tgLine; $tgS += "$(git -C $tg status --porcelain)"
Expect "tools: kittools filter: grant rendered + checked out ($tgO), never committed ($tgC), status clean [$tgS]" ($tgR -like '*, mcp__db' -and $tgO -eq $tgR -and $tgC -notlike '*mcp__db*' -and -not $tgS)
Remove-TestKit $k
Complete-Tests
