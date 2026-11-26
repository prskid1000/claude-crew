#Requires -Version 7
<#
guard-warm.tests.ps1: the warm PreToolUse guard (guard_client.mjs + guard_server.ps1, K48): the same answers as crafty.ps1 guard,
a fast call once the server runs, a caller's env per call, a kit file change ends the server (the next call is plain again);
the plain guard's secrets and kit-evidence rules.
Usage: pwsh -NoProfile -File <kit>/tests/guard-warm.tests.ps1 (or tests/kit-tests.ps1 -Area guard-warm). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$TestKitFiles = @('skills/crafty/guard_client.mjs', 'skills/crafty/guard_server.ps1')
$k = New-TestKit gwarm; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $gc = Join-Path $k 'skills/crafty/guard_client.mjs'
$kw = (Resolve-Path -LiteralPath $k).Path.TrimEnd('\', '/'); $mine = { @($(if ($IsWindows) { Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' AND CommandLine LIKE '%guard[_]server%'" -Property ProcessId, CommandLine -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; CommandLine = $_.CommandLine } } } else { Get-Process pwsh -ErrorAction SilentlyContinue }) | Where-Object { "$($_.CommandLine)".Contains("$kw$([IO.Path]::DirectorySeparatorChar)skills") -and "$($_.CommandLine)" -like '*guard_server*' }) }   # this kit's servers only
# plain guard rules (moved from guard.tests.ps1: file cap)
# test logins (owner 2026-11-19): a command reading targets.local.json is denied; a grep of the bare name, check-ignore or ls pass
$sec = foreach ($c in @(@('cat', 'cat skills/pokey/targets.local.json'), @('gc', 'Get-Content D:\k\skills\pokey\targets.local.json | ConvertFrom-Json'), @('py', "python -c `"print(open('skills/pokey/targets.local.json').read())`""),
    @('sls', 'Select-String pass D:/k/skills/pokey/targets.local.json'), @('pattern', 'grep -n targets.local.json README.md; git check-ignore -q skills/pokey/targets.local.json; ls skills/pokey/targets.local.json'),
    @('msg', "git commit -m `"fix: never cat targets.local.json; copy names only`""), @('msgq', "git -C x commit -m 'docs: cp targets.local.json is denied'"),
    @('msgdoc', "git commit -m `"`$(cat <<'EOF'`nfix: a guard read of targets.local.json (copy)`nEOF`n)`""), @('wtmsg', "pwsh -File crafty.ps1 wt commit -Message 'cat targets.local.json no more'"),
    @('chain', "git commit -m 'x' && cat skills/pokey/targets.local.json"), @('subst', "git commit -m `"`$(cat skills/pokey/targets.local.json)`""),
    @('bsq', "git commit -m `"a\`" ; cat skills/pokey/targets.local.json ; echo `"b`""), @('sqq', "git commit -m 'x'' ; cat skills/pokey/targets.local.json ; echo ''y'"))) {
  "$($c[0]):$((& $D guard -Json (@{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress)) -join '' -match 'holds test logins.+user list -Target')" }
Expect "guard secrets: reads of targets.local.json denied (also chained after a commit or run inside its message), a name in a pattern or commit message text passes ($($sec -join ' '))" (($sec -join ' ') -eq 'cat:True gc:True py:True sls:True pattern:False msg:False msgq:False msgdoc:False wtmsg:False chain:True subst:True bsq:True sqq:True')
# tester evidence inside the kit's skills/ (2026-11-21: skills/shots/) is denied; the run's output folder passes
$ev = foreach ($c in @(@('write', 'Write', @{ file_path = "$k/skills/shots/F1-T1_01_x.jpeg"; content = 'x' }), @('bash', 'Bash', @{ command = "mkdir -p $k/skills/pokey/evidence/run" }),
    @('run', 'Write', @{ file_path = "$k/notes/F1/shots/F1-T1_01_x.jpeg"; content = 'x' }))) {
  "$($c[0]):$((& $D guard -Json (@{ tool_name = $c[1]; cwd = $k; tool_input = $c[2] } | ConvertTo-Json -Compress)) -join '' -match 'tester evidence inside the kit')" }
Expect "guard: evidence writes into <kit>/skills/**/shots|evidence denied, the run folder passes ($($ev -join ' '))" (($ev -join ' ') -eq 'write:True bash:True run:False')
# 2026-11-24: a password literal next to a login in an agent work file is denied; a targets lookup or a placeholder passes
$pwF = "$k/x/work/agents/a1/setup.mjs"
$pwc = foreach ($c in @(@('lit', 'Write', @{ file_path = $pwF; content = "const PW = 'Zq7-x9Lm'`ncall({ login, password: PW })" }), @('edit', 'Edit', @{ file_path = $pwF; old_string = 'a'; new_string = "{ user: 'qa1', password: `"Zq7-x9Lm`" }" }),
    @('look', 'Write', @{ file_path = $pwF; content = "const PW = B.targetOf('t').users['qa1'][1]`ncall({ login, password: PW })" }), @('tpl', 'Write', @{ file_path = $pwF; content = "{ login: '{user}', password: '{pass}' }" }),
    @('udd', 'Write', @{ file_path = $pwF; content = "launch({ args: ['--user-data-dir=' + dir] })`nconst pw = 'prof-1x9'" }), @('kit', 'Write', @{ file_path = "$k/notes/x.mjs"; content = "{ login: 'a', password: 'Zq7-x9Lm' }" }),
    @('heredoc', 'Bash', @{ command = "cat > '$pwF' <<'EOF'`nconst PW = 'Zq7-x9Lm'`ncall({ login, password: PW })`nEOF" }), @('rel', 'Bash', @{ command = "echo `"{ user: 'qa1', password: 'Zq7-x9Lm' }`" >> x/work/agents/a1/u.json" }),
    @('setc', 'PowerShell', @{ command = "Set-Content -Path '$pwF' -Value `"{ login: 'a', pwd: 'Zq7-x9Lm' }`"" }), @('hdlook', 'Bash', @{ command = "cat > '$pwF' <<'EOF'`nconst PW = B.targetOf('t').users['qa1'][1]`ncall({ login, password: PW })`nEOF" }),
    @('hdkit', 'Bash', @{ command = "cat > '$k/notes/x.mjs' <<'EOF'`n{ login: 'a', password: 'Zq7-x9Lm' }`nEOF" }),
    @('cdrel', 'Bash', @{ command = "cd '$k/x/work/agents/a1' && cat > u.json <<'EOF'`n{ user: 'qa1', password: 'Zq7-x9Lm' }`nEOF" }), @('var', 'Bash', @{ command = "F=$k/x/work/agents/a1/u.json; cat > `"`$F`" <<'EOF'`n{ user: 'qa1', password: 'Zq7-x9Lm' }`nEOF" }),
    @('valfirst', 'PowerShell', @{ command = "Set-Content -Value `"{ login: 'a', pwd: 'Zq7-x9Lm' }`" -Path '$pwF'" }), @('py', 'Bash', @{ command = "node -e `"require('fs').writeFileSync('$pwF', JSON.stringify({ login: 'a', password: 'Zq7-x9Lm' }))`"" }))) {
  "$($c[0]):$((& $D guard -Json (@{ tool_name = $c[1]; cwd = $k; tool_input = $c[2] } | ConvertTo-Json -Compress)) -join '' -match 'password literal next to a login.+pokey\.ps1 user create')" }
Expect "guard: a login's password literal in work/agents files denied (Write, Edit, a heredoc, echo >>, Set-Content, cd + relative, a variable, node); a targets lookup, a placeholder, a non-agent file pass ($($pwc -join ' '))" (($pwc -join ' ') -eq 'lit:True edit:True look:False tpl:False udd:False kit:False heredoc:True rel:True setc:True hdlook:False hdkit:False cdrel:True var:True valfirst:True py:True')
$ins = @('git stash', 'git status --short', 'echo hi') | ForEach-Object { @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $_ } } | ConvertTo-Json -Compress -Depth 4 }
# the decision and its reason (key order differs per process)
$nz = { param($s) if ("$s".Trim()) { $h = ("$s" | ConvertFrom-Json).hookSpecificOutput; "$($h.permissionDecision)|$($h.permissionDecisionReason)|$($h.additionalContext)" } else { '' } }
$viaPlain = { param($j) & $nz (($j | pwsh @np $D guard) -join '') }
$viaClient = { param($j) & $nz (($j | node $gc) -join '') }
# context rules in the client (owner 2026-11-22): a whole-file Read or a range over guard.readMaxLines (600) / readMaxKB (32) denied (a line
# counts up to the tool's 2000 chars), a small range or a small file passes; SQL: SELECT *, a row query without LIMIT or LIMIT over guard.sqlMaxRows (200) denied; aggregates, SHOW pass
$big = Join-Path (Kd) 'big.ps1'; Set-Content $big (1..700 | ForEach-Object { "# line $_" }); $wide = Join-Path (Kd) 'wide.md'; Set-Content $wide ('x' * 40000); $small = Join-Path (Kd) 'small.md'; Set-Content $small 'a'; $crlf = Join-Path (Kd) 'crlf.ps1'; [IO.File]::WriteAllText($crlf, ((1..700 | ForEach-Object { "# line $_" }) -join "`r`n"))
$cx = foreach ($c in @(@('big', 'Read', @{ file_path = $big }), @('wide', 'Read', @{ file_path = $wide }), @('range', 'Read', @{ file_path = $big; offset = 1; limit = 40 }), @('bigrange', 'Read', @{ file_path = $big; offset = 1; limit = 700 }), @('tail', 'Read', @{ file_path = $big; offset = 650 }), @('widerange', 'Read', @{ file_path = $wide; offset = 1; limit = 5 }), @('zero', 'Read', @{ file_path = $big; offset = 0; limit = 700 }), @('strtail', 'Read', @{ file_path = $big; offset = '650' }), @('crlf', 'Read', @{ file_path = $crlf; limit = 700 }),@('small', 'Read', @{ file_path = $small }),
    @('star', 'mcp__db__run_sql', @{ query = 'SELECT * FROM t LIMIT 5' }), @('nolim', 'mcp__db__run_sql', @{ query = "select id from t where n = 'limit 5'" }), @('over', 'mcp__db__run_sql', @{ query = 'select id from t limit 5000' }),
    @('lim', 'mcp__db__run_sql', @{ query = 'select id, name from t limit 50;' }), @('count', 'mcp__db__run_sql', @{ query = 'SELECT COUNT(*) FROM t' }), @('grp', 'mcp__db__run_sql', @{ query = 'select a, count(*) from t group by a' }), @('show', 'mcp__db__run_sql', @{ query = 'SHOW DATABASES' }),
    @('exists', 'mcp__db__run_sql', @{ sql = 'select id from t where exists (select * from u where u.t = t.id) limit 5' }), @('cte', 'mcp__db__run_sql', @{ sql = 'with x as (select a from t) select count(*) from x' }),
    @('tick', 'mcp__db__run_sql', @{ sql = 'select a from t where `c#` = 1 limit 5' }), @('inner', 'mcp__db__run_sql', @{ sql = 'select id from t where id in (select id from u limit 5)' }), @('pdf', 'Read', @{ file_path = "$big.pdf" }))) {
  "$($c[0]):$(@(& $viaClient (@{ tool_name = $c[1]; cwd = $k; tool_input = $c[2] } | ConvertTo-Json -Compress)) -join '' -replace '^deny\|.*', 'deny' -replace '^$', 'ok')" }
Expect "guard context: big / wide whole-file Reads, a 700-line range and wide or unbounded SQL denied, ranges, small files, LIMIT, aggregates pass ($($cx -join ' '))" (($cx -join ' ') -eq 'big:deny wide:deny range:ok bigrange:deny tail:ok widerange:ok zero:deny strtail:ok crlf:deny small:ok star:deny nolim:deny over:deny lim:ok count:ok grp:deny show:ok exists:ok cte:ok tick:ok inner:deny pdf:ok')
# a kit script is run, not read: a whole-file Read of the kit's own script over guard.kitScriptLines (60) denied with the pointer; its range, a short one, a copy outside the kit pass
$ksLong = Join-Path $k 'skills/crafty/zz-long.ps1'; Set-Content $ksLong (1..100 | ForEach-Object { "# line $_" }); $ksShort = Join-Path $k 'skills/crafty/zz-short.ps1'; Set-Content $ksShort '# a'; $ksOut = Join-Path (Kd) 'zz-long.ps1'; Copy-Item $ksLong $ksOut
$ks = foreach ($c in @(@('whole', @{ file_path = $ksLong }), @('head', @{ file_path = $ksLong; limit = 40 }), @('short', @{ file_path = $ksShort }), @('outside', @{ file_path = $ksOut }))) { "$($c[0]):$(@(& $viaClient (@{ tool_name = 'Read'; cwd = $k; tool_input = $c[1] } | ConvertTo-Json -Compress)) -join '' -replace '^deny\|.*run it, never read it whole.*', 'deny' -replace '^$', 'ok')" }
Expect "guard context: a kit script read whole is denied (run it; top 40 lines, then a section), its head, a short script and a copy outside the kit pass ($($ks -join ' '))" (($ks -join ' ') -eq 'whole:deny head:ok short:ok outside:ok')
Remove-Item $ksLong, $ksShort
# parity (harness guard on file reads and MCP SQL): Antigravity's view_file / call_mcp_tool / eager mcp_<server>_<tool> hit the same
# rules, answered as { decision, reason }; the test-logins file is denied to every CLI's file view
$lgF = Join-Path (Kd) 'skills/pokey/targets.local.json'; New-Item -ItemType Directory -Force (Split-Path $lgF) | Out-Null; Set-Content $lgF '{}'
$ag = foreach ($c in @(@('big', 'view_file', @{ AbsolutePath = $big }), @('range', 'view_file', @{ AbsolutePath = (ConvertTo-Json $big); StartLine = '1'; EndLine = '40' }), @('bigrange', 'view_file', @{ AbsolutePath = $big; StartLine = 1; EndLine = 700 }),
    @('logins', 'view_file', @{ AbsolutePath = $lgF }), @('star', 'call_mcp_tool', @{ ServerName = 'db'; ToolName = 'run_sql'; Arguments = (@{ query = 'SELECT * FROM t LIMIT 5' } | ConvertTo-Json -Compress) }),
    @('lim', 'call_mcp_tool', @{ ServerName = 'db'; ToolName = 'run_sql'; Arguments = @{ query = 'select id from t limit 5' } }), @('docs', 'call_mcp_tool', @{ ServerName = 'docs'; ToolName = 'search'; Arguments = @{ query = 'select everything' } }),
    @('eager', 'mcp_db_run_sql', @{ query = 'select id from t' }))) {
  $agO = (@{ conversationId = 'c1'; toolCall = @{ name = $c[1]; args = $c[2] } } | ConvertTo-Json -Compress -Depth 5 | node $gc) -join ''
  "$($c[0]):$(($agO | ConvertFrom-Json).decision)" }
Expect "guard context on Antigravity: view_file caps, the logins file and SQL via call_mcp_tool / mcp_<server>_<tool> denied as decision deny; a range, LIMIT and non-SQL MCP allowed ($($ag -join ' '))" (($ag -join ' ') -eq 'big:deny range:allow bigrange:deny logins:deny star:deny lim:allow docs:allow eager:deny')
$plain = @($ins | ForEach-Object { & $viaPlain $_ })
# K75: a cold call past the client's hook-time bound under load passes once with no answer; answers are compared without that bound
$env:KIT_GUARD_TIMEOUT_MS = '120000'
# a deadline, not a count (720 looks took 17 min under load); one CIM query per look, its rows carry CommandLine (a Process object
# re-queries CIM per .CommandLine read: 224 -> 68 ms a look)
$waitOne = { $wDue = (Get-Date).AddSeconds((Get-TestBound 60)); while ((Get-Date) -lt $wDue -and @(& $mine).Count -ne 1) { Start-Sleep -Milliseconds 500 }; @(& $mine).Count }
$first = @($ins | ForEach-Object { & $viaClient $_ })   # no server yet: the plain path, and a server starts
$srvN = & $waitOne; Start-Sleep -Seconds 2   # it loads the kit; a second one started by a later cold call exits
$warm = @($ins | ForEach-Object { & $viaClient $_ })
$odd = @(0..($ins.Count - 1) | Where-Object { $first[$_] -ne $plain[$_] -or $warm[$_] -ne $plain[$_] } | ForEach-Object { "$_ plain=[$($plain[$_])] cold=[$($first[$_])] warm=[$($warm[$_])]" })
Expect "warm guard: the same answers as crafty.ps1 guard, cold and warm ($($odd -join ' ; ') | n $($plain.Count)/$($first.Count)/$($warm.Count) plain0=[$($plain[0])])" ($odd.Count -eq 0 -and $first.Count -eq $ins.Count -and $warm.Count -eq $ins.Count -and $plain[0] -match 'git stash is shared')
Expect "warm guard: one server runs after the first cold calls ($srvN)" ($srvN -eq 1)
# timing (K74): plain and warm interleaved, best of each (a load burst hits both); KIT_TESTS_SLACK eases the 2x margin, warm still wins
$ms = @(); $pms = @(); foreach ($j in $ins + $ins) { $sw = [Diagnostics.Stopwatch]::StartNew(); $null = & $viaPlain $j; $pms += [int]$sw.Elapsed.TotalMilliseconds; $sw.Restart(); $null = & $viaClient $j; $ms += [int]$sw.Elapsed.TotalMilliseconds }
$wmin = @($ms | Sort-Object)[0]; $pmin = @($pms | Sort-Object)[0]
Expect "warm guard: warm calls faster than plain ones in the same run (best warm $wmin ms x $([math]::Round(2 / (Get-TestBound 1), 2)) < best plain $pmin ms)" ($wmin * 2 / (Get-TestBound 1) -lt $pmin)
$env:KIT_LIVE_EDIT = '1'; $null = & $viaClient $ins[0]; Remove-Item Env:KIT_LIVE_EDIT; $le2 = & $viaClient $ins[0]
Expect 'warm guard: the caller''s KIT_* env counts for its call only' ($le2 -eq $plain[0])
$rt = "$(pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; Get-KitRuntime")".Trim().Replace('\', '/'); $wo = @("$rt/zzbogus/a.txt", "$rt/work/agents/x/a.txt") | ForEach-Object { @{ tool_name = 'Write'; cwd = $k; tool_input = @{ file_path = $_; content = 'x' } } | ConvertTo-Json -Compress -Depth 4 }
$wp = @($wo | ForEach-Object { & $viaPlain $_ }); $ww = @($wo | ForEach-Object { & $viaClient $_ })
Expect "warm guard: one call's layout note never carries into the next ($($ww -join ' ~ '))" (($ww -join '~') -eq ($wp -join '~') -and $wp[0] -match 'layout' -and $wp[1] -notmatch 'layout')
$null = & $viaClient $ins[0]; $null = & $waitOne; $old = @((& $mine).Id); Set-Content (Join-Path $k 'skills/crafty/kit.local.json') '{}'; $after = & $viaClient $ins[0]
for ($i = 0; $i -lt 20 -and @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Milliseconds 250 }
Expect "warm guard: a kit file change ends the server ($($old -join ',')); that call gets the plain answer" ($old.Count -eq 1 -and $after -eq $plain[0] -and -not @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count)
$env:KIT_GUARD_WARM = '0'; $off = & $viaClient $ins[0]; Remove-Item Env:KIT_GUARD_WARM
Expect 'warm guard: KIT_GUARD_WARM=0 = the plain path' ($off -eq $plain[0])
Remove-Item Env:KIT_GUARD_TIMEOUT_MS; & $mine | Stop-Process -ErrorAction SilentlyContinue
# K67: a guard crash (parse error, non-JSON stdout, timeout, no pwsh) blocks the call (exit 2) and logs it; KIT_GUARD_BYPASS=1 lets it through
# crafty.ps1 is a hard link to the source kit: unlink before every write (TEST-WRITE)
$env:KIT_GUARD_WARM = '0'; $ok0 = [IO.File]::ReadAllText($D); $put = { param($t) Remove-Item -LiteralPath $D; [IO.File]::WriteAllText($D, $t) }
& $put "$ok0`nfunction Broken {"; $cr1 = @($ins[2] | node $gc 2>&1); $rc1 = $LASTEXITCODE
$env:KIT_GUARD_BYPASS = '1'; $cr2 = @($ins[2] | node $gc 2>&1); $rc2 = $LASTEXITCODE; Remove-Item Env:KIT_GUARD_BYPASS
$nodeExe = (Get-Command node).Source; $path0 = $env:PATH; $env:PATH = Split-Path $nodeExe; $cr3 = @($ins[2] | & $nodeExe $gc 2>&1); $rc3 = $LASTEXITCODE; $env:PATH = $path0
& $put "[Console]::Error.WriteLine('Authorization: Bearer SECRETX client_secret: SECRETY GITLAB_TOKEN=SECRETZ'); 'not json'; exit 0"; $cr4 = @($ins[2] | node $gc 2>&1); $rc4 = $LASTEXITCODE
$env:KIT_GUARD_TIMEOUT_MS = '1500'; & $put 'Start-Sleep -Seconds 9'; $tin = $ins[2] -replace 'echo hi', 'echo slow'; $null = $tin | node $gc 2>&1; $rc5 = $LASTEXITCODE; $cr6 = @($tin | node $gc 2>&1); $rc6 = $LASTEXITCODE; Remove-Item Env:KIT_GUARD_TIMEOUT_MS
& $put $ok0; Remove-Item Env:KIT_GUARD_WARM
$gl = @(Get-ChildItem -LiteralPath "$(pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; Get-KitPath audit")".Trim() -Recurse -Filter guard.jsonl -ErrorAction SilentlyContinue | Get-Content); $glog = @($gl | ConvertFrom-Json | Where-Object event -eq 'crash')
Expect "guard crash: blocked with exit 2 and the reason ($rc1 $($cr1 -join ' '))" ($rc1 -eq 2 -and "$cr1" -match 'kit guard crashed .*call blocked .*KIT_GUARD_BYPASS')
Expect "guard crash: KIT_GUARD_BYPASS=1 lets the call through with a note ($rc2)" ($rc2 -eq 0 -and "$cr2" -match 'systemMessage.*unguarded')
Expect "guard crash: no pwsh and non-JSON stdout block (secrets masked); a timeout passes once, logged; the same input slow again blocks ($rc3 $rc4 $rc5 $rc6 $cr4)" ($rc3 -eq 2 -and "$cr3" -match 'ENOENT' -and $rc4 -eq 2 -and "$cr4" -match 'Authorization \[redacted\]' -and "$gl $cr4" -notmatch 'SECRET[XYZ]' -and $rc5 -eq 0 -and $rc6 -eq 2 -and @($gl -match '"event":"timeout"').Count -ge 1)
# a fresh test kit: its guard log holds only these
Expect "guard crash: each logged as guard event crash, the switch marked ($($glog.Count))" ($glog.Count -eq 5 -and @($glog | Where-Object letThrough).Count -eq 1 -and $glog[0].tool -eq 'Bash' -and $gl[0] -match '"at":"[^"]+[+-]\d\d:\d\d"')
$sv = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') supervise 2>&1 | Out-String
Expect "guard crash: supervise raises ACT with the count ($(([regex]::Match($sv, '.{0,20}guard crashed[^\r\n]{0,60}')).Value))" ($sv -match 'ACT.{0,40}guard crashed 5x')
# K67r: a crafty.ps1 that does not load marks it once; the next calls start no server (the mark stays unchanged) until crafty.ps1 changes
# cold calls below: no hook-time bound (a load timeout passes once with no answer, a second one on the same input is a crash)
$env:KIT_GUARD_TIMEOUT_MS = '120000'; & $mine | Stop-Process -ErrorAction SilentlyContinue; & $put "$ok0`nfunction Broken {"; $nlm = { @(Get-ChildItem "$k/$((Read-Json "$k/skills/crafty/kit.example.json")._paths.runtimeDir)/cache" -Filter 'kit-guard-*.noload' -ErrorAction SilentlyContinue) }
$null = $ins[2] | node $gc 2>&1; for ($i = 0; $i -lt 40 -and -not (& $nlm).Count; $i++) { Start-Sleep -Milliseconds 250 }; $nl1 = @(& $nlm | ForEach-Object { $_.LastWriteTimeUtc.Ticks })
$null = $ins[2] | node $gc 2>&1; Start-Sleep -Seconds 4; $nl2 = @(& $nlm | ForEach-Object { $_.LastWriteTimeUtc.Ticks }); & $put $ok0
Expect "warm guard: a crafty.ps1 that does not load is marked once, later calls start no server per call ($($nl1 -join ',') / $($nl2 -join ','))" ($nl1.Count -eq 1 -and "$nl1" -eq "$nl2")
Expect 'guard crash: a healthy guard after the fix answers as before' (($ins[0] | node $gc) -join '' -match 'git stash is shared')
Remove-Item Env:KIT_GUARD_TIMEOUT_MS; Start-Sleep -Seconds 1; & $mine | Stop-Process -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
