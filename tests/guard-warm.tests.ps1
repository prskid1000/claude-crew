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
$kw = (Resolve-Path -LiteralPath $k).Path.TrimEnd('\', '/'); $mine = { @(Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".Contains("$kw$([IO.Path]::DirectorySeparatorChar)skills") -and "$($_.CommandLine)" -like '*guard_server*' }) }   # this kit's servers only
$ins = @('git stash', 'git status --short', 'echo hi') | ForEach-Object { @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $_ } } | ConvertTo-Json -Compress -Depth 4 }
# the decision and its reason (key order differs per process)
$nz = { param($s) if ("$s".Trim()) { $h = ("$s" | ConvertFrom-Json).hookSpecificOutput; "$($h.permissionDecision)|$($h.permissionDecisionReason)|$($h.additionalContext)" } else { '' } }
$viaPlain = { param($j) & $nz (($j | pwsh @np $D guard) -join '') }
$viaClient = { param($j) & $nz (($j | node $gc) -join '') }
$pms = @(); $plain = @($ins | ForEach-Object { $sw = [Diagnostics.Stopwatch]::StartNew(); & $viaPlain $_; $pms += [int]$sw.Elapsed.TotalMilliseconds })
$med = { param($v) @($v | Sort-Object)[[int](@($v).Count / 2)] }   # warm vs plain in the same run: a loaded suite slows both
$first = @($ins | ForEach-Object { & $viaClient $_ })   # no server yet: the plain path, and a server starts
for ($i = 0; $i -lt 60 -and (& $mine).Count -ne 1; $i++) { Start-Sleep -Milliseconds 250 }; Start-Sleep -Seconds 2   # it loads the kit; a second one started by a later cold call exits
$ms = @(); $warm = @($ins | ForEach-Object { $sw = [Diagnostics.Stopwatch]::StartNew(); & $viaClient $_; $ms += [int]$sw.Elapsed.TotalMilliseconds })
Expect "warm guard: the same answers as crafty.ps1 guard (cold and warm), a server runs, warm calls fast ($($ms -join ' ') ms)" (($first -join '~') -eq ($plain -join '~') -and ($warm -join '~') -eq ($plain -join '~') -and $plain[0] -match 'git stash is shared' -and (& $mine).Count -eq 1 -and (& $med $ms) * 2 -lt (& $med $pms))
$env:KIT_LIVE_EDIT = '1'; $null = & $viaClient $ins[0]; Remove-Item Env:KIT_LIVE_EDIT; $le2 = & $viaClient $ins[0]
Expect 'warm guard: the caller''s KIT_* env counts for its call only' ($le2 -eq $plain[0])
$rt = "$(pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; Get-KitRuntime")".Trim().Replace('\', '/'); $wo = @("$rt/zzbogus/a.txt", "$rt/work/agents/x/a.txt") | ForEach-Object { @{ tool_name = 'Write'; cwd = $k; tool_input = @{ file_path = $_; content = 'x' } } | ConvertTo-Json -Compress -Depth 4 }
$wp = @($wo | ForEach-Object { & $viaPlain $_ }); $ww = @($wo | ForEach-Object { & $viaClient $_ })
Expect "warm guard: one call's layout note never carries into the next ($($ww -join ' ~ '))" (($ww -join '~') -eq ($wp -join '~') -and $wp[0] -match 'layout' -and $wp[1] -notmatch 'layout')
$old = @((& $mine).Id); Set-Content (Join-Path $k 'skills/crafty/kit.local.json') '{}'; $after = & $viaClient $ins[0]
for ($i = 0; $i -lt 20 -and @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Milliseconds 250 }
Expect "warm guard: a kit file change ends the server ($($old -join ',')); that call gets the plain answer" ($old.Count -eq 1 -and $after -eq $plain[0] -and -not @(Get-Process -Id $old -ErrorAction SilentlyContinue).Count)
$env:KIT_GUARD_WARM = '0'; $off = & $viaClient $ins[0]; Remove-Item Env:KIT_GUARD_WARM
Expect 'warm guard: KIT_GUARD_WARM=0 = the plain path' ($off -eq $plain[0])
& $mine | Stop-Process -ErrorAction SilentlyContinue
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
Expect 'guard crash: a healthy guard after the fix answers as before' (($ins[0] | node $gc) -join '' -match 'git stash is shared')
Start-Sleep -Seconds 1; & $mine | Stop-Process -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
