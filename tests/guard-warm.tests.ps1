#Requires -Version 7
<#
guard-warm.tests.ps1: the warm PreToolUse guard (guard_client.mjs + guard_server.ps1, K48): the same answers as crafty.ps1 guard,
a fast call once the server runs, a caller's env per call, a kit file change ends the server (the next call is plain again).
Usage: pwsh -NoProfile -File <kit>/tests/guard-warm.tests.ps1 (or tests/kit-tests.ps1 -Area guard-warm). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$TestKitFiles = @('skills/crafty/guard_client.mjs', 'skills/crafty/guard_server.ps1')
$k = New-TestKit gwarm; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $gc = Join-Path $k 'skills/crafty/guard_client.mjs'
$kw = (Resolve-Path -LiteralPath $k).Path.TrimEnd('\', '/'); $mine = { @($(if ($IsWindows) { Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' AND CommandLine LIKE '%guard[_]server%'" -Property ProcessId, CommandLine -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; CommandLine = $_.CommandLine } } } else { Get-Process pwsh -ErrorAction SilentlyContinue }) | Where-Object { "$($_.CommandLine)".Contains("$kw$([IO.Path]::DirectorySeparatorChar)skills") -and "$($_.CommandLine)" -like '*guard_server*' }) }   # this kit's servers only
$ins = @('git stash', 'git status --short', 'echo hi') | ForEach-Object { @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $_ } } | ConvertTo-Json -Compress -Depth 4 }
# the decision and its reason (key order differs per process)
$nz = { param($s) if ("$s".Trim()) { $h = ("$s" | ConvertFrom-Json).hookSpecificOutput; "$($h.permissionDecision)|$($h.permissionDecisionReason)|$($h.additionalContext)" } else { '' } }
$viaPlain = { param($j) & $nz (($j | pwsh @np $D guard) -join '') }
$viaClient = { param($j) & $nz (($j | node $gc) -join '') }
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
