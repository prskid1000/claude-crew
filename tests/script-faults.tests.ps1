#Requires -Version 7
<#
script-faults.tests.ps1: agents' own script failures (owner 2026-11-25): the guard rule script-faults (crafty adapters/guard-scripts.ps1:
python -c through a .bat shim, bash -n, PowerShell payloads, MSYS path conversion, wrapper folders, case-clashing agent scripts, Java
escapes at Write / Edit); kitbag.py faults capture from Claude Code transcripts (masked, cursor, recurring, leaks);
the supervise SCRIPT-FAULTS ACT.
Usage: pwsh -NoProfile -File <kit>/tests/script-faults.tests.ps1 (or tests/kit-tests.ps1 -Area script-faults).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/kitbag_admin.py', 'skills/bossy/ctx_hook.mjs')
$k = New-TestKit faults; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$sfAgents = TkPath $k agents -Create; $sfHere = Join-Path (Kd) 'sf-cwd'; New-Item -ItemType Directory -Force $sfHere, (Join-Path $sfHere 'api') | Out-Null
Set-Content (Join-Path $sfHere 'api/mvnw') '#!/bin/sh'
Set-Content (Join-Path $sfAgents 'clash.ps1') "param([string]`$Path)`n`$a = 'x'`nforeach (`$A in 1..2) { `$A }`n`$a" -Encoding utf8
Set-Content (Join-Path $sfAgents 'Old.java') "class Old { String a = `"\q`"; }" -Encoding utf8
# rows: tool (B Bash, P PowerShell, W Write, E Edit), command or file, content / old>>new, the class it denies ('' = allowed), KIT_PY_SHIM
$sfCases = @(
  @('B', "python -X utf8 -c `"import json`nprint(1)`"", '', 'py-shim-quote', 'C:/py/shims/python.bat'),
  @('B', "python -c 'print(d[`"x`"])'", '', 'py-shim-quote', 'C:/py/shims/python.bat'),
  @('B', "python -X utf8 -c `"print(open('x.json').read())`"", '', 'py-shim-quote', 'C:/py/shims/python.bat'),
  @('B', "python -X utf8 -c `"print(len('a') + 1)`"", '', '', 'C:/py/shims/python.bat'),
  @('B', "glab mr view 1 | python -X utf8 -c 'import json,sys; print(1)'", '', '', 'C:/py/shims/python.bat'),
  @('B', "`"C:/py/versions/3/python.exe`" -c `"import a`nb`"", '', '', 'C:/py/shims/python.bat'),
  @('B', "python -X utf8 -c `"import json`nprint(1)`"", '', '', '0'),
  @('P', "python -c `"import json`nprint(1)`"", '', 'py-shim-quote', 'C:/py/shims/python.bat'),
  @('B', 'echo "unclosed', '', 'sh-quote', '0'),
  @('B', "echo 'ok' && ls `"a b`" | head -2", '', '', '0'),
  @('P', 'Get-Item (', '', 'ps-parse', '0'),
  @('B', "pwsh -NoProfile -Command 'if (`$x -eq ''y'') { 1 '", '', 'ps-parse', '0'),
  @('B', 'pwsh -NoProfile -Command "`$a = 1; `$a"', '', 'ps-parse', '0'),
  @('B', 'P=x; pwsh -NoProfile -Command "\$env:A=''x''; $P go"', '', '', '0'),
  @('B', 'node api.mjs GET /api/roles/54', '', 'msys-path', '0'),
  @('B', 'MSYS_NO_PATHCONV=1 node api.mjs GET /api/roles/54; grep -rn /api/x src; node a.mjs /tmp/x', '', '', '0'),
  @('B', 'cd sub && ./mvnw -v', '', 'wrapper-path', '0'),
  @('B', 'cd api && ./mvnw -v', '', '', '0'),
  @('P', "& crafty.ps1 gate -Dir $sfHere -Cmd './mvnw -q test' -Log x.log", '', 'wrapper-path', '0'),
  @('P', "& crafty.ps1 gate -Dir $sfHere/api -Cmd './mvnw -q test' -Log x.log", '', '', '0'),
  @('B', 'cd $REPO && ./mvnw -v; cd ~/p && ./mvnw -v', '', '', '0'),
  @('B', "pwsh -NoProfile -File $sfAgents/clash.ps1 -Path x", '', 'ps-case-clash', '0'),
  @('B', "cat $sfAgents/clash.ps1; grep -n x $sfAgents/clash.ps1", '', '', '0'),
  @('W', "$sfAgents/param.ps1", "param([string]`$Path)`n`$path = Resolve-Path `$Path", '', '0'),
  @('W', "$sfAgents/new.ps1", "`$P = 'D:/x/a.ps1'`n`$p = 1", 'ps-case-clash', '0'),
  @('W', "$sfAgents/ok.ps1", "`$scriptPath = 'D:/x/a.ps1'`n`$scriptPath", '', '0'),
  @('W', "$sfAgents/A.java", "class A { String r = `"\\d+`"; char c = '\n'; String t = `"`"`"`n  a \d`n  `"`"`"; } // \d", 'java-escape', '0'),
  @('W', "$sfAgents/B.java", "class B { String r = `"\\d+\\s`"; /* \d */ char c = '\''; }", '', '0'),
  @('E', "$sfAgents/Old.java", 'class Old>>final class Old', '', '0'),
  @('E', "$sfAgents/Old.java", 'String a>>String b = "\w"; String a', 'java-escape', '0'),
  @('B', 'node read.mjs D:/k/.state/tracking.json', '', 'state-moved', '0'),
  @('B', 'git log -S .state/tracking.json; node a.mjs D:/k/.state/tracking.json.migrated', '', '', '0'),
  @('W', "$sfAgents/keyed.py", "d = open(r'D:/k/.state/tracking.json').read()", 'state-moved', '0'),
  @('W', "$sfAgents/notes.md", 'old path: .state/tracking.json (moved)', '', '0'),
  @('B', 'timeout 300 pwsh -NoProfile -Command "& bossy.ps1 decide wait -Id d1"', '', 'decide-wait-timeout', '0'),
  @('B', 'pwsh -NoProfile -File bossy.ps1 decide wait -Id d1 -MaxMinutes 8', '', '', '0'),
  @('B', "git show HEAD:a.js > /tmp/a.js; cat > x.py <<'EOF'`nd = open('/tmp/a.js').read()`nEOF`npython -X utf8 x.py", '', 'posix-path', '0'),
  @('B', "pwsh -NoProfile -Command `"python -X utf8 -c 'print(1)'`"", '', 'py-shell-source', '0'),
  @('B', 'sed -i "s/x/\\n/" gen.py', '', 'py-shell-source', '0'),
  @('B', 'sed -i "s/x/y/" gen.py; sed -i "s/a/\\n/" notes.md', '', '', '0')
)
$sfOut = Invoke-PsTest 'sf-guard' @'
$d, $here, $rows = $args[0], $args[1], ($args[2] | ConvertFrom-Json)
foreach ($c in $rows) {
  $env:KIT_PY_SHIM = $c[4]
  $ti = switch ($c[0]) { 'W' { @{ file_path = $c[1]; content = $c[2] } } 'E' { $p = $c[2] -split '>>'; @{ file_path = $c[1]; old_string = $p[0]; new_string = $p[1] } } default { @{ command = $c[1] } } }
  $j = @{ tool_name = @{ B = 'Bash'; P = 'PowerShell'; W = 'Write'; E = 'Edit' }[$c[0]]; cwd = $here; tool_input = $ti } | ConvertTo-Json -Compress -Depth 4
  $o = (& $d guard -Json $j) -join ''
  $got = if ($o -match '"permissionDecision":"deny"') { if ($o -match 'script-fault ([\w-]+)') { $Matches[1] } else { 'other: ' + ($o -replace '^.*Reason":"', '').Substring(0, 80) } } else { '' }
  "$(if ($got -eq $c[3]) { 'ok' } else { 'BAD' }) [$($c[0])] $($c[1] -replace '\s+', ' ') -> '$got' (want '$($c[3])')"
}
'@ @($D, $sfHere, ($sfCases | ConvertTo-Json -Compress -Depth 3))
$sfBad = @($sfOut | Where-Object { $_ -notmatch '^ok ' })
Expect "guard script-faults: $($sfCases.Count) rows (shim quotes, bash -n, PowerShell payloads, MSYS paths, wrapper folders, case clashes, Java escapes; allows) ($($sfBad -join ' | '))" ($sfOut.Count -eq $sfCases.Count -and -not $sfBad.Count)
# kitbag.py faults: one failure class seen by 3 agents across the 3 harnesses = due (secrets masked); a guarded class due only after its since day
$tx = Join-Path (Kd) 'tx'; $ws = Split-Path $k; $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); $at = "${day}T01:02:03.000Z"
$cl = Join-Path $tx 'claude/s1/subagents'; New-Item -ItemType Directory -Force $cl | Out-Null
foreach ($n in 1..3) {
  $use = @{ type = 'assistant'; timestamp = $at; message = @{ content = @(@{ type = 'tool_use'; id = "t$n"; name = 'Bash'; input = @{ command = 'python -c "x"' } }) } } | ConvertTo-Json -Compress -Depth 6
  $res = @{ type = 'user'; timestamp = $at; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = "t$n"; is_error = $true; content = "Exit code 1`n  File `"<string>`", line 1`n    ||  goto :error`nSyntaxError: invalid syntax" }) } } | ConvertTo-Json -Compress -Depth 6
  $use2 = $use.Replace("`"t$n`"", "`"u$n`"").Replace('python -c \"x\"', 'node frob.mjs'); $res2 = @{ type = 'user'; timestamp = $at; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = "u$n"; is_error = $true; content = "Exit code 1`nError: frobnicate failed token=abc123secret456" }) } } | ConvertTo-Json -Compress -Depth 6
  $use3 = $use.Replace("`"t$n`"", "`"r$n`"").Replace('python -c \"x\"', 'cat notes.md'); $res3 = @{ type = 'user'; timestamp = $at; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = "r$n"; is_error = $false; content = 'python shim echoes || goto :error' }) } } | ConvertTo-Json -Compress -Depth 6
  if ($n -eq 2) { $use2 = $use2.Replace('node frob.mjs', 'node login.mjs -Password hunter2xyz'); $res2 = $res2.Replace('frobnicate failed token=abc123secret456', 'login refused') }
  Set-Content (Join-Path $cl "agent-a$n.jsonl") @($use, $res, $use3, $res3, $(if ($n -le 2) { $use2; $res2 })) -Encoding utf8
}
foreach ($sec in 'zzz999secret', 'qqq777secret') {   # two more agents hit the same failure (other secrets: each masked)
  $fu = @{ type = 'assistant'; timestamp = $at; message = @{ content = @(@{ type = 'tool_use'; id = "f$sec"; name = 'Bash'; input = @{ command = 'node frob.mjs' } }) } } | ConvertTo-Json -Compress -Depth 6
  $fr = @{ type = 'user'; timestamp = $at; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = "f$sec"; is_error = $true; content = "Exit code 1`nError: frobnicate failed token=$sec" }) } } | ConvertTo-Json -Compress -Depth 6
  Set-Content (Join-Path $cl "agent-b$($sec.Substring(0, 3)).jsonl") @($fu, $fr) -Encoding utf8
}
$env:KIT_TRANSCRIPTS = Join-Path $tx 'claude'
$kb = Join-Path $k 'skills/bossy/kitbag.py'
$f1 = python -X utf8 $kb faults --json --days 7 | Out-String | ConvertFrom-Json; $f2 = python -X utf8 $kb faults --json --days 7 | Out-String | ConvertFrom-Json
$nx = python -X utf8 $kb faults next --n 2 | Out-String   # 2: from 2026-11-26 the guarded py-shim-quote is due too (same hits)
Remove-Item Env:KIT_TRANSCRIPTS
$frob = @($f1.items | Where-Object { $_.sig -like 'exit Error: frobnicate failed*' })[0]; $shim = @($f1.items | Where-Object cls -eq 'py-shim-quote')[0]
$logged = Get-Content (Join-Path $k ".state/audit/$day/faults.jsonl") -Raw
Expect "faults: 3 agents, one due signature (no prevention), secrets masked (=, spaced), no read of quoted fault text ($($frob.hits) $($frob.agents) $($frob.harness -join ',') due=$($frob.due))" ($frob.hits -eq 3 -and $frob.agents -eq 3 -and $frob.due -and $logged -notmatch 'secret456|zzz999|qqq777|hunter2|notes\.md' -and $logged -match 'token=\[redacted\]' -and $logged -match 'Password \[redacted\]')
Expect "faults: a guarded class (py-shim-quote) is due only after its since day; a second scan reads nothing new ($($shim.hits) due=$($shim.due) new=$($f2.new))" ($shim.hits -eq 3 -and $shim.due -eq ($day -gt '2026-11-27') -and $shim.prevent -match 'guard' -and $f1.new -eq 7 -and $f2.new -eq 0)
Expect "faults next: the top item and the open count ($($nx.Trim() -replace '\s+', ' '))" ($nx -match 'frobnicate' -and $nx -match 'faults next: [1-9]\d* open')
# a .get / .keys on a str or list (JSON of another shape) = data-shape (doc prevention); any other AttributeError stays py-exception
$fcPy = Join-Path (Kd) 'fault-class.py'
$fcDir = Join-Path $k 'skills/bossy'
Set-Content $fcPy @('import sys, importlib.util', "sys.path.insert(0, r'$fcDir')", 'import kitbag as kb', "spec = importlib.util.spec_from_file_location('kitbag_admin', r'$fcDir/kitbag_admin.py')",
  'a = importlib.util.module_from_spec(spec); a.__dict__.update({n: v for n, v in vars(kb).items() if not n.startswith("__")}); spec.loader.exec_module(a)',
  "print(a.fault_class('python r.py', `"AttributeError: 'str' object has no attribute 'get'`")[0], a.fault_class('python r.py', `"AttributeError: 'Foo' object has no attribute 'bar'`")[0], a.fault_known('pwsh -File bossy.ps1 learn -Read -Skill x | head', 'was unexpected at this time.'), a.fault_known('pwsh -File k.ps1 go', 'was unexpected at this time.'), a.fault_known('bossy.ps1 learn -Skill x -Read', 'was unexpected at this time.'), a.fault_known('bossy.ps1 learn -Read && python k.py', 'was unexpected at this time.'))") -Encoding utf8
$fcOut = "$(python -X utf8 $fcPy 2>&1)".Trim()
Expect "faults: AttributeError .get on a str = data-shape, other attributes = py-exception, a learn -Read output is no fault ($fcOut)" ($fcOut -eq 'data-shape py-exception False True False True')
# records scanned before a class shipped are relabelled from their first error line: a prevented class, never due on its day
$rl = foreach ($n in 1..3) { @{ at = $at; harness = 'claude'; agent = "rl$n"; tool = 'Bash'; rc = 2; cls = 'kit-usage'; sig = 'kit-usage usage: board msg'; line = "usage: board msg -Agent <me> -To <id>"; cmd = 'pwsh -File bossy.ps1 board msg -To x -Text y'; prevent = '' } | ConvertTo-Json -Compress }
Add-Content (Join-Path $k ".state/audit/$day/faults.jsonl") $rl -Encoding utf8
$env:KIT_TRANSCRIPTS = Join-Path $tx 'claude'   # the fixtures only, never real transcripts
$f3 = python -X utf8 $kb faults --json --days 7 | Out-String | ConvertFrom-Json; Remove-Item Env:KIT_TRANSCRIPTS; $bm = @($f3.items | Where-Object { $_.sig -like '*usage: board msg*' })
Expect "faults: older records relabelled to a shipped class (board-msg-sender), not due on its day ($($bm.cls -join ',') due=$($bm.due -join ','))" ($bm.Count -eq 1 -and $bm[0].cls -eq 'board-msg-sender' -and $bm[0].hits -eq 3 -and $bm[0].due -eq ($day -gt '2026-11-25'))
# board msg without -Agent: the sender is -Session's agent, else KIT_AGENT / CLAUDE_AGENT; neither = usage, exit 2
$bmEnv = @($env:KIT_AGENT, $env:CLAUDE_AGENT); $env:KIT_AGENT = $null; $env:CLAUDE_AGENT = $null
$bmJ = pwsh -NoProfile -File $O board join -Agent bm-a -Run bm | Out-String; $bmS = if ($bmJ -match 'SESSION (\S+)') { $Matches[1] }
$null = pwsh -NoProfile -File $O board msg -Session $bmS -To bm-b -Text 'by session'
$env:CLAUDE_AGENT = 'bm-env'; $null = pwsh -NoProfile -File $O board msg -To bm-b -Text 'by env'; $env:CLAUDE_AGENT = $null
$bmU = pwsh -NoProfile -File $O board msg -To bm-b -Text 'nobody' | Out-String; $bmUc = $LASTEXITCODE; $bmI = pwsh -NoProfile -File $O board inbox -Agent bm-b | Out-String
$null = pwsh -NoProfile -File $O board leave -Session $bmS; $env:KIT_AGENT, $env:CLAUDE_AGENT = $bmEnv
Expect "board msg: sender from -Session, else the env; neither = usage exit 2 ($($bmI.Trim() -replace '\s+', ' '))" ($bmI -match 'from bm-a: by session' -and $bmI -match 'from bm-env: by env' -and $bmUc -eq 2 -and $bmU -match 'usage: board msg -Agent <me> \| -Session')
# event queue: a transcript quoting another agent's SESSION line drains nothing; a successor's join prints what the hook pushed before
$eqJ = pwsh -NoProfile -File $O board join -Agent eq-a -Run eq | Out-String; $eqS = if ($eqJ -match 'SESSION (\S+)') { $Matches[1] }
$eqT = Join-Path $k 'eq-a.jsonl'; $eqQ = Join-Path $k 'eq-q.jsonl'; "{`"t`":`"SESSION $eqS   (pass -Session $eqS to beat`"}" | Set-Content $eqT; Copy-Item $eqT $eqQ
$eqR = (Get-ChildItem $k -Recurse -Force -Filter "$eqS.json" | Select-Object -First 1).FullName; $eqRow = Get-Content $eqR -Raw | ConvertFrom-Json
$eqRow | Add-Member -Force NoteProperty transcript $eqT; $eqRow | ConvertTo-Json -Depth 6 | Set-Content $eqR
$eqH = { param($f) (@{ transcript_path = $f } | ConvertTo-Json -Compress | node (Join-Path (Split-Path $O) 'ctx_hook.mjs')) -join '' }
$null = pwsh -NoProfile -File $O board msg -Agent eq-lead -To eq-a -Text 'rule one'; $eq1 = & $eqH $eqQ; $eq2 = & $eqH $eqT
$null = pwsh -NoProfile -File $O board leave -Session $eqS; $null = pwsh -NoProfile -File $O board join -Agent eq-a -Run eq; $eq3 = pwsh -NoProfile -File $O board inbox -Agent eq-a | Out-String
Expect "event queue: a quoted SESSION line gets nothing, the row's own transcript gets the msg, a successor's join prints it again ($eq1 | $($eq3.Trim()))" (-not $eq1 -and $eq2 -match 'MESSAGE for eq-a .*rule one' -and $eq3 -match 'from eq-lead: rule one')
# supervise SCRIPT-FAULTS: open items and no fault kitty live = one ACT; a live kitty (subject script-faults) = none; cached per
# scriptFaults.scanMinutes (one kitbag run); 0 open = none
$sfl = & { . $O; $global:sfx = 0; $global:sfo = "exit Error: x · 3 hit(s)`nfaults next: 2 open script-fault(s) (0 new failed call(s) captured)"; function Invoke-KitExe { $global:sfx++; [pscustomobject]@{ code = 0; out = $global:sfo; err = '' } }
  $now = "$(Get-Date)"; $kb2 = @(@{ status = 'working'; type = 'kitty'; agent = 'kitty-3'; run = 'kitty-docker'; subject = 'docker'; beat = $now })
  $b1 = @(Get-KitSuperviseFlagsFaults -Board $kb2 | ForEach-Object { "$($_.level) $($_.what)" }) -join ';'
  $b2 = @(Get-KitSuperviseFlagsFaults -Board @($kb2 + @{ status = 'working'; type = 'kitty'; agent = 'kitty-5'; run = 'kitty-x'; subject = 'script-faults'; beat = $now })).Count
  $b3 = @(Get-KitSuperviseFlagsFaults -Board $kb2).Count; Remove-Item (Join-Path (Get-KitPath cache) 'faults-next.json'); $global:sfo = 'faults next: 0 open script-fault(s)'
  $actRx = '^ACT SCRIPT-FAULTS: 2 open .*top: exit Error: x\)$'; $b0 = @(Get-KitSuperviseFlagsFaults -Board $kb2).Count
  "$($b1 -match $actRx)|$b2|$b3|$global:sfx|$b0" }
Expect "supervise SCRIPT-FAULTS: ACT while items are open and no fault kitty lives; a live one = none; cached; 0 open = none ($sfl)" ($sfl -eq 'True|0|1|2|0')
Remove-TestKit $k
Complete-Tests
