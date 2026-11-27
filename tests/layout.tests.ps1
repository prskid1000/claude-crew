#Requires -Version 7
<#
layout.tests.ps1: the kit's place on disk: stray runtime folders (lint RUNTIME-STRAY), runtime resolution, the git hooks, run records (resumed run liveness, re-bind); 
testy's envy / phoney calls; tracked ports current; local files git-ignored; auto memory off.
Usage: pwsh -NoProfile -File <kit>/tests/layout.tests.ps1 (or tests/kit-tests.ps1 -Area layout).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit layout
# RUNTIME-STRAY: a runtime folder up to 3 levels into the workspace, not the kit's own or a kit checkout's
$rtName = (Get-Content (Join-Path $src 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json)._paths.runtimeDir
$strayWs = Split-Path $k
foreach ($sd in '.', 'repo', 'wt', 'a/b/c') { New-Item -ItemType Directory -Force (Join-Path $strayWs "$sd/$rtName") | Out-Null }
New-Item -ItemType File -Force (Join-Path $strayWs 'wt/skills/crafty/crafty.ps1') | Out-Null; New-Item -ItemType Directory -Force (Join-Path $k $rtName) | Out-Null
$strayFound = python -X utf8 -c "import sys, os; sys.path.insert(0, sys.argv[1]); import kitbag; print(sorted(os.path.relpath(p, sys.argv[2]).replace(os.sep, '/') for p in kitbag.stray_runtimes(sys.argv[3])))" (Join-Path $k 'skills/bossy') $strayWs $k
# a live run's stray (a file changed in the last hour) warns, never blocks; an idle one counts
$slF = New-Item -ItemType File -Force (Join-Path $strayWs "repo/$rtName/x.json"); $slNow = python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.stray_live(sys.argv[2]))" (Join-Path $k 'skills/bossy') (Split-Path $slF)
$slF.LastWriteTime = (Get-Date).AddHours(-3); $slOld = python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.stray_live(sys.argv[2]))" (Join-Path $k 'skills/bossy') (Split-Path $slF)
# an idle one a process sits in (its cwd: a removed worktree's runtime, 2026-11-27) is live: a WARN, never a blocked commit
$slHp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WorkingDirectory (Split-Path $slF) -PassThru -WindowStyle Hidden; Start-Sleep -Milliseconds 800
$slHeld = python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.stray_live(sys.argv[2]))" (Join-Path $k 'skills/bossy') (Split-Path $slF); Stop-Process -Id $slHp.Id -ErrorAction SilentlyContinue; $null = $slHp.WaitForExit(5000)
# a junction into the kit runtime is never live (its fresh files are the kit's own writes: a stuck WARN)
$slJ = Join-Path $strayWs "jl/$rtName"; New-Item -ItemType Directory -Force (Split-Path $slJ) | Out-Null; New-Item -ItemType Junction -Path $slJ -Value (Join-Path $strayWs "repo/$rtName") | Out-Null
(Get-Item $slF.FullName).LastWriteTime = Get-Date; $slLink = python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.stray_live(sys.argv[2]), kitbag.stray_link(sys.argv[2]))" (Join-Path $k 'skills/bossy') $slJ
(Get-Item $slJ).Delete()
foreach ($sd in $rtName, 'repo', 'wt', 'a', 'jl') { Remove-Item -Recurse -Force (Join-Path $strayWs $sd) }
Expect "lint RUNTIME-STRAY: <ws>/$rtName and <ws>/repo/$rtName only ($strayFound); a live one warns ($slNow / idle $slOld / held $slHeld); a junction is a link, never live ($slLink)" ($strayFound -eq "['$rtName', 'repo/$rtName']" -and "$slNow|$slOld" -eq 'True|False' -and ($slHeld -eq 'True' -or -not $IsWindows) -and $slLink -eq 'False True')
# a relative runtime override resolves from the kit, never the cwd
Set-Item Env:CLAUDE_RUNTIME 'rt-rel'
$relRuntimes = @((python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.runtime_dir())" (Join-Path $k 'skills/bossy')), (pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; Get-KitRuntime"))
Remove-Item Env:CLAUDE_RUNTIME
Expect "a relative runtime override resolves from the kit, never the cwd ($($relRuntimes -join ' | '))" (@($relRuntimes | Where-Object { [IO.Path]::GetFullPath($_) -eq [IO.Path]::GetFullPath((Join-Path $k 'rt-rel')) }).Count -eq 2)
# sweep: merged / local-copy branches + a merged clean worktree go, unpushed / open / protected stay; a junction skeleton no repo lists goes (its target stays)
$swBossy = Join-Path $k 'skills/bossy/bossy.ps1'; $swCrafty = Join-Path $k 'skills/crafty/crafty.ps1'; $sw = Join-Path (Kd) 'sw'; $so = Join-Path (Kd) 'so.git'; $sr = Join-Path (Kd) 'srepo'
$env:GIT_COMMITTER_DATE = (Get-Date).AddDays(-2).ToString('o'); git init -q --bare -b main $so; git clone -q $so $sr 2>$null; 'a' | Set-Content "$sr/a.txt"; Save-GitRepo $sr init; git -C $sr push -q origin main 2>$null
foreach ($b in 'f/merged', 'staging/x', 'f/open', 'f/local') { git -C $sr branch $b }
foreach ($b in 'f/open', 'f/local') { git -C $sr switch -q $b; $b | Set-Content "$sr/b.txt"; Save-GitRepo $sr $b }; git -C $sr push -q -u origin f/open 2>$null; git -C $sr switch -q main; git -C $sr branch mr7 f/open
git -C $sr worktree add -q -b f/wt "$sw/wt-srepo" 2>$null; git -C $sr worktree add -q -b f/wt2 "$sw/wt2-srepo" 2>$null; Remove-Item Env:GIT_COMMITTER_DATE
# wt2: a live board row without claims whose agent checkpointed it since joining (a kitty after its push) holds it
$heldRow = Join-Path (TkPath $k board -Create) 'kt-held.json'; & $J @{ agent = 'kt'; session = 'kt-held'; run = 'kr'; worktrees = @(); status = 'working'; joined = (Get-Date).AddHours(-1).ToString('o'); beat = (Get-Date).ToString('o') } $heldRow
& $J @{ agent = 'kt'; run = 'kr'; steps = @(@{ step = '8'; dir = "$sw\wt2-srepo"; at = (Get-Date).ToString('o') }) } (& { . (Lib); Get-KitCheckpointFile kt kr -Write })
$tgt = Join-Path (Kd) 'shared'; New-Item -ItemType Directory -Force "$tgt", "$sw/skel-srepo/sub", "$sw/note-srepo" | Out-Null; 'keep' | Set-Content "$tgt/f.txt"; 'mine' | Set-Content "$sw/note-srepo/n.txt"
$null = New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$sw/skel-srepo/sub/node_modules" -Value $tgt
foreach ($f in Get-ChildItem $sw -Recurse -Force -Attributes !ReparsePoint) { $f.LastWriteTime = (Get-Date).AddDays(-1) }
$swKl = "$k/skills/crafty/kit.local.json"; $swKlNew = -not (Test-Path $swKl); if ($swKlNew) { & $J @{ protectedBranchesBase = @('main', 'staging/*') } $swKl }   # legacy-like base
$swOut = pwsh @np $swBossy cleanup -WorktreesOnly -WorktreeRoot $sw -Detail 2>&1 | Out-String; if ($swKlNew) { Remove-Item $swKl }; $swBr = @(git -C $sr for-each-ref --format='%(refname:short)' refs/heads) -join ','
$swRm = @(1, 2 | ForEach-Object { "$(pwsh @np $swCrafty wt remove -Dir "$sw/wt-srepo" -Root $sw 2>&1) rc=$LASTEXITCODE" }); Remove-Item -LiteralPath $heldRow
Expect "sweep: merged, mr7, wt-srepo + f/wt gone; main, staging/x, f/open, f/local, checkpointed wt2, link target, note kept; skeleton gone; counts; wt remove after: gone, exit 0 ($swBr | $($swRm -join ' | '))" ($swBr -eq 'f/local,f/open,f/wt2,main,staging/x' -and -not (Test-Path "$sw/skel-srepo") -and (Test-Path "$tgt/f.txt") -and (Test-Path "$sw/note-srepo/n.txt") -and
  (Test-Path "$sw/wt2-srepo") -and $swOut -match 'wt2-srepo: held by a board agent' -and
  $swOut -match 'f/local in srepo: 1 commit\(s\) on no remote' -and $swOut -match 'open: origin/f/open not merged' -and (Get-Content -LiteralPath (TkPath $k repo-sweep) -Raw | ConvertFrom-Json).repos[0].branches -eq 5 -and
  $swOut -match 'worktree: merged' -and @($swRm -match 'already gone.*rc=0$').Count -eq 2)
# post-rewrite runs post-merge after a rebase (pull --rebase), not after an amend
$hookRepo = Join-Path (Kd) 'hookrepo'; $hookDir = Join-Path (Kd) 'hookdir'; New-Item -ItemType Directory -Force $hookDir | Out-Null
Copy-Item (Join-Path $src '.githooks/post-rewrite') $hookDir; [IO.File]::WriteAllText((Join-Path $hookDir 'post-merge'), "#!/bin/sh`necho ran >> `"`$(git rev-parse --git-dir)/pm`"`n")
git init -q -b main $hookRepo; git -C $hookRepo config core.hooksPath $hookDir; git -C $hookRepo commit -q --allow-empty -m a; git -C $hookRepo checkout -q -b side; git -C $hookRepo commit -q --allow-empty -m b
git -C $hookRepo commit -q --amend --allow-empty -m b2; $afterAmend = Test-Path "$hookRepo/.git/pm"
git -C $hookRepo checkout -q main; git -C $hookRepo commit -q --allow-empty -m c; git -C $hookRepo checkout -q side; git -C $hookRepo rebase -q main 2>$null
Expect "post-rewrite: a rebase runs post-merge, an amend does not (amend $afterAmend, rebase $(Test-Path "$hookRepo/.git/pm"))" (-not $afterAmend -and (Test-Path "$hookRepo/.git/pm"))
# run records on disk: a resumed run's liveness and its self record re-bound
$O = Join-Path $k 'skills/bossy/bossy.ps1'; $ld = TkPath $k launches -Create
$wfr = New-Item -ItemType Directory -Force (Join-Path (Kd) 'wf/wf_r2'); $txr = Join-Path $wfr 'agent-a1.jsonl'; '{}' | Set-Content $txr
$rb = Invoke-PsTest rebind @'
$null = . $args[0] 6>$null; $d = Get-Item $args[1]; $old = (Get-Date).AddHours(-3); $dead = @{ holderPid = 999999; holderStart = '2020-01-01T00:00:00Z' }
$me = [pscustomobject]@{ runId = 'wf_r2'; script = 'x/buildy.js'; at = (Get-Date).ToString('o'); holderPid = $PID; holderStart = (Get-KitPidStart $PID); file = 'r.json'; args = @{ brief = 'C:/b/w.md' } }
$sf = [pscustomobject](@{ script = 'x/buildy.js'; run = 'w-1'; at = $old.ToString('o'); wfDir = $d.FullName; file = (Join-Path $d.Parent 'self-w.json') } + $dead); $sf | ConvertTo-Json | Set-Content $sf.file
$rd = [pscustomobject](@{ runId = 'wf_r2'; script = 'x/buildy.js'; at = $old.ToString('o'); file = 'r.json'; args = @{ brief = 'C:/b/w.md' } } + $dead)
$a = @(Get-StoppedRunsOf @($me) @($sf) $old.AddHours(-1) $false).Count; $b = @(Get-StoppedRunsOf @($rd) @($sf) $old.AddHours(-1) $false).Count; $c = "$(Get-KitWorkflowStop $d @($sf, $me))"
(Get-Item $args[2]).LastWriteTime = $old; "$a $b $c|$(@(Get-StoppedRunsOf @($rd) @($sf) $old.AddHours(-1) $false).Count) $(Get-KitWorkflowStop $d @($sf, $rd))"
'@ @($O, "$wfr", $txr) | Out-String
[IO.File]::WriteAllText((Join-Path $ld 'self-buildy-w-1.json'), (@{ script = 'buildy.js'; run = 'w-1'; at = (Get-Date).ToString('o'); wfDir = "$wfr"; holderPid = 999999; crashed = 'x' } | ConvertTo-Json))
$rbo = pwsh @np $O launch -RunId wf_r2 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/w.md"}' 2>&1 | Out-String; $rbs = Read-Json (Join-Path $ld 'self-buildy-w-1.json')
Expect "resumed run: live record or fresh step transcript = not stopped, quiet + dead holders = session gone; launch -RunId re-binds its self record ($($rb.Trim()))" ($rb.Trim() -eq '0 0 |1 session gone' -and $rbo -match 're-bound self-buildy-w-1' -and -not $rbs.crashed -and $rbs.holderPid -ne 999999)
Remove-Item (Join-Path $ld 'self-buildy-w-1.json'), (Join-Path $ld 'wf_r2.json') -Force
$tx3 = New-Item -ItemType Directory -Force (Join-Path (Kd) 'tx3/s1/subagents/workflows/wf_r3'); "launch -Self -Script buildy.js -Run 'w-3' -ArgsFile a.json -Fnv abcd1234" | Set-Content (Join-Path $tx3 'agent-x.jsonl')
[IO.File]::WriteAllText((Join-Path $ld 'self-buildy-w-3.json'), (@{ script = 'buildy.js'; run = 'w-3'; at = (Get-Date).ToString('o'); fnv = 'abcd1234'; holderPid = 999999; crashed = 'x' } | ConvertTo-Json))
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx3'; $rb3 = pwsh @np $O launch -RunId wf_r3 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/w3.md"}' 2>&1 | Out-String; Remove-Item Env:KIT_TRANSCRIPTS
Expect 'launch -RunId: a self record without wfDir re-bound by its launch -Self line (args hash) in that run folder' ($rb3 -match 're-bound self-buildy-w-3' -and -not (Read-Json (Join-Path $ld 'self-buildy-w-3.json')).crashed)
Remove-Item (Join-Path $ld 'self-buildy-w-3.json'), (Join-Path $ld 'wf_r3.json') -Force
# usage: per message id (a repeated content block counts once), appended lines only, a partial last line waits; steps, rounds, outcomes, background agents, cost, page
$ux = Join-Path (Kd) 'ux'; $uw = New-Item -ItemType Directory -Force "$ux/s1/subagents/workflows/wf_u1"; $ub = "$ux/s1/subagents"
$um = { param($id, [int[]]$v, [string]$t, [string]$extra = '') "{`"type`":`"assistant`",`"timestamp`":`"$t`",`"message`":{`"model`":`"claude-sonnet-5-5`",`"id`":`"$id`",`"role`":`"assistant`",`"content`":[$extra],`"usage`":{`"input_tokens`":$($v[0]),`"cache_creation_input_tokens`":$($v[3]),`"cache_read_input_tokens`":$($v[2]),`"output_tokens`":$($v[1])}}}" }
$t0 = (Get-Date).Date.AddMinutes(1).ToUniversalTime(); $iso = { param($m) $t0.AddMinutes($m).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
[IO.File]::WriteAllText("$uw/agent-a1.jsonl", ((& $um 'msg_1' 10, 5, 1000, 100 (& $iso 0) '{"type":"tool_use"}'), (& $um 'msg_1' 10, 50, 1000, 100 (& $iso 1)), (& $um 'msg_2' 1, 20, 2000, 0 (& $iso 10)) -join "`n") + "`n")
[IO.File]::WriteAllText("$uw/agent-a2.jsonl", (& $um 'msg_9' 1, 1, 0, 0 (& $iso 12)) + "`n"); [IO.File]::WriteAllText("$ub/agent-b1.jsonl", (& $um 'msg_7' 0, 7, 0, 0 (& $iso 5)) + "`n")
'{"agentType":"devy","model":"sonnet"}' | Set-Content "$uw/agent-a1.meta.json"; '{"agentType":"revy"}' | Set-Content "$uw/agent-a2.meta.json"; '{"agentType":"revy","description":"review x"}' | Set-Content "$ub/agent-b1.meta.json"
(@{ type = 'started'; agentId = 'a1'; label = 'build:X1' }, @{ type = 'result'; agentId = 'a1'; result = @{ summary = 'ok'; mrs = @(@{ url = 'u/1'; merged = $true }) } }, @{ type = 'started'; agentId = 'a2'; label = 'review:X1' }, @{ type = 'result'; agentId = 'a2'; result = @{ error = 'boom' } } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) | Set-Content "$uw/journal.jsonl"
(Get-Item "$ux/s1").LastWriteTime = (Get-Date).AddDays(-10)   # a coordinator session started 10 days ago, its runs today (the page showed 0)
(Get-Item "$uw/journal.jsonl").LastWriteTime = $t0.ToLocalTime().AddMinutes(12); (Get-Item $uw).CreationTime = $t0.ToLocalTime(); (Get-Item $uw).LastWriteTime = $t0.ToLocalTime()   # a run folder's write time stays at its last new file: wall = to the last step's write (12 min, was 0)
$uo = Invoke-PsTest usage @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $a = Get-KitUsage -Seconds 30
Add-Content -LiteralPath $args[2] -Value ((Get-Content -LiteralPath $args[3] -Raw).Trim() -replace 'msg_9', 'msg_8') -NoNewline; [IO.File]::AppendAllText($args[2], "`n{`"type`":`"assistant`",`"message`":{`"usage`"")
$b = Get-KitUsage -Seconds 30; $r = $b.runs[0]; $s1 = @($r.steps | Where-Object label -eq 'build:X1')[0]
"$($a.runs[0].tok)|$($r.tok)|$($s1.out)|$($s1.tools)|$($s1.min)|$($r.merged)|$($r.done)/$($r.total)|$($b.rates.fail)|$($b.bg[0].tok)|$($b.bg[0].roles)|$([math]::Round($s1.cost, 6))|$($r.loop)|$(@($b.days)[-1].tok)|$(@($b.byType).k -join ',')|$($r.wall)"
$pgs = @{}; $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ usage = $b } }) $pgs
$cardGrid = @("<details class='sec sub st uc dlr' id=sec-dl-days open><summary><h4>Per day", "<span class=gn title='est. cost per day", "<div class=tls data-mk=trend-tiles>", "data-oc=fail aria-pressed=false", "class='sec sub st uc ur' id=sec-u-spend><summary><h4>Per role</h4>", '</span><span class=fsm>Top: ', "data-mk=spend-role>", '.ur{grid-column:1/-1}') | Where-Object { -not $h.Contains($_) }
# column counts: run steps 8 (right-align nth-child ranges)
$thCount = { param($open, $in = $h) ([regex]::Match($in, [regex]::Escape($open) + '.*?</tr>', 'Singleline').Value | Select-String '<th[ >]' -AllMatches).Matches.Count }
$colCounts = "7 $(& $thCount "class='sy rst'>" @($pgs.Values)[0])"
"$($h -notmatch 'Tokens today') $($h -match "data-g='rr-[^']+' data-oc=" -and $h -match "<button type=button class='tl ocb' data-oc=fail") $($h -notmatch 'Agents outside workflows') $(-not $cardGrid -and $colCounts -eq '7 8' -and @($pgs.Values)[0] -match 'class=kleg' -and $h -notmatch 'class=ut>|Per model|Per step type|sec-u-rolecost|class=spd')"
# a transcript last written before today moves to usage.cold.json, which a later call leaves unchanged; totals the same
$cfu = Get-KitPath usage-cache; $cfc = $cfu -replace '\.json$', '.cold.json'; [IO.File]::SetLastWriteTime(($args[2] -replace 'agent-a2', 'agent-a1'), (Get-Date).Date.AddHours(-2))
$null = Get-KitUsage -Seconds 30; $cold1 = [IO.File]::ReadAllText($cfc); $d = Get-KitUsage -Seconds 30
$cold2 = [IO.File]::ReadAllText($cfc); [IO.File]::SetLastWriteTime(($args[2] -replace 'agent-a2', 'agent-a1'), (Get-Date)); $e = Get-KitUsage -Seconds 30   # written again today: back to the hot file
"$($cold1 -match 'agent-a1' -and $cold1 -notmatch 'agent-a2' -and $cold1 -ceq $cold2 -and $d.runs[0].tok -eq $b.runs[0].tok -and [IO.File]::ReadAllText($cfc) -notmatch 'agent-a1' -and [IO.File]::ReadAllText($cfu) -match 'agent-a1' -and $e.runs[0].tok -eq $b.runs[0].tok)"
# board-only agents: tokens from their own transcript (usage agentSteps by path), "No usage record" only without one (R2: its row + agent
# line; standalone agents under one Other row: R1's tokens on it, R2's line says none); a finished
# agent's time = joined -> ended (90 min), never its state's since (0 min, owner screenshot 2026-11-21)
$bo = @([pscustomobject]@{ name = 'R1 (revy)'; run = 'solo'; state = 'ACTIVE'; since = (Get-Date).AddMinutes(-5).ToString('o'); tx = $args[4] }, [pscustomobject]@{ name = 'R2 (revy)'; run = 'solo'; state = 'ACTIVE'; since = (Get-Date).AddMinutes(-5).ToString('o'); tx = '' },
  [pscustomobject]@{ name = 'K1 (kitty)'; run = 'kit-x'; state = 'FINISHED'; started = (Get-Date).AddMinutes(-100).ToString('o'); since = (Get-Date).AddMinutes(-10).ToString('o'); ended = (Get-Date).AddMinutes(-10).ToString('o'); tx = '' })
$hb = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); agents = $bo; stats = [pscustomobject]@{ usage = $e } }); "bo:$(@($e.agentSteps | Where-Object { $_.tf -like '*agent-b1.jsonl' }).tok) $(([regex]::Matches($hb, '>No usage record<')).Count) $(($kx = @($hb -split "data-g='rr-" | Where-Object { $_.StartsWith('board-kit-x') })[0]) -match '<span class=gc>90 min</span>' -and $kx -match ' [1-9]\d* min active')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $ux, "$uw/agent-a2.jsonl", "$uw/agent-a2.jsonl", "$ub/agent-b1.jsonl") | Out-String
$uv = @($uo.Trim() -split "`r?`n")
Expect "usage: an old session folder's new runs count; dedupe by message id, appended lines, partial line waits; runs, steps, outcomes, cost, card grids, cold cache, board-only tokens by transcript ($($uv -join ' // '))" ($uv[-4] -eq '3183|3185|70|1|10|1|2/2|1|7|revy 1|0.001272|4|3192|build,agent,review|12' -and $uv[-3] -eq 'True True True True' -and $uv[-2] -eq 'True' -and $uv[-1] -eq 'bo:7 3 True')
# status: one agent joined twice (with -Type, then with -Run) on one transcript = one row (active agents not inflated)
$jvTx = Join-Path (Kd) 'JV.jsonl'; '{}' | Set-Content $jvTx; $jvB = TkPath $k board -Create; $jvNow = (Get-Date).ToString('o')
foreach ($jvE in @{ session = 's-JVz'; agent = 'JV'; run = 'rr'; type = '' }, @{ session = 's-JV'; agent = 'JV'; run = ''; type = 'devy' }, @{ session = 's-KZ1'; agent = 'KZ'; run = 'r1'; status = 'left' }, @{ session = 's-KZ2'; agent = 'KZ'; run = 'r2'; handoff = 773600; capBy = 'cap0.8'; ctxCheck = @{ decision = 'continue'; ctx = 180000 } }) { $jvR = @{ type = 'devy'; status = 'working'; beat = $jvNow; joined = $jvNow; transcript = $jvTx }; foreach ($kv in $jvE.GetEnumerator()) { $jvR[$kv.Key] = $kv.Value }; & $J $jvR (Join-Path $jvB "$($jvE.session).json") }   # KZ: left, re-joined live
$jv = Invoke-PsTest 'dupjoin' '$null = . $args[0] 6>$null; @(Get-KitStatusRows | Where-Object { $_.name -match "^(JV|KZ) " } | ForEach-Object { "$($_.name)/$($_.run)" }) -join ","; "B:" + @(Get-KitStatusRows | Where-Object { $_.name -match "^KZ " }).budget' @($O)
$jvBud = "$jv" -replace '(?s)^.*B:', ''; $jv = "$jv" -replace '(?s)\s*B:.*$', ''
Expect "status: a board row's budget = effective handoff, its source and the last context check (dashboard tooltip) ($jvBud)" ($jvBud.Trim() -eq 'handoff at 774k (cap0.8) · context check continue at 180k')
Expect "status: two board entries of one agent on one transcript = one row, the typed one, a live re-join over its left twin ($jv)" ((@("$jv".Trim() -split ',') | Sort-Object) -join ',' -eq 'JV (devy)/,KZ (devy)/r2')
# org and project facts live only in local files: each stays git-ignored (pre-push also blocks them)
$ignRel = @('ROLES.local.md', 'rules/org.local.md', 'LESSONS.local.md', 'skills/crafty/kit.local.json', 'skills/pokey/targets.local.json', 'settings.local.json', "$rtName/", '.state/')
$ignOut = @(git -C $src check-ignore --no-index -- @ignRel); Expect "gitignore: org and local files never reach git ($($ignOut.Count) of $($ignRel.Count) ignored)" ($ignOut.Count -eq $ignRel.Count)
# kit memory (AGENTS.md "Memory"): settings.json turns harness auto memory off; setup drops a local opt-in unless memory.keepDefault
$memSl = Join-Path $k 'settings.local.json'; $memCfg = Join-Path $k 'skills/crafty/kit.local.json'; $memOld = if (Test-Path $memCfg) { [IO.File]::ReadAllText($memCfg) }
[IO.File]::WriteAllText($memSl, '{ "autoMemoryEnabled": true }'); [IO.File]::WriteAllText($memCfg, '{}')
$null = pwsh @np $O setup -Exclude -Quiet 2>&1; $memOff = -not (Get-Content $memSl -Raw | ConvertFrom-Json -AsHashtable).ContainsKey('autoMemoryEnabled')
[IO.File]::WriteAllText($memCfg, '{ "memory": { "keepDefault": true } }'); $null = pwsh @np $O setup -Exclude -Quiet 2>&1; $memOn = (Get-Content $memSl -Raw | ConvertFrom-Json).autoMemoryEnabled -eq $true
if ($null -ne $memOld) { [IO.File]::WriteAllText($memCfg, $memOld) } else { Remove-Item $memCfg }; Remove-Item $memSl
Expect "memory: settings.json autoMemoryEnabled false; setup drops a local opt-in ($memOff), keeps it under memory.keepDefault ($memOn)" ((Get-Content (Join-Path $src 'settings.json') -Raw | ConvertFrom-Json).autoMemoryEnabled -eq $false -and $memOff -and $memOn)
Remove-TestKit $k
Complete-Tests
