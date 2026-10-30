#Requires -Version 7
<#
supervise.tests.ps1: bossy.ps1 supervise autonomy (board, flags, acks, run records), pause / launch / recover learn, track status lag, bugbrief args, storage.
Usage: pwsh -NoProfile -File <kit>/tests/supervise.tests.ps1 (or tests/kit-tests.ps1 -Area supervise).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit supervise; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$bw = pwsh -NoProfile -Command ". '$O'; foreach (`$c in `$false, `$true) { Get-BugWfArgs b r B1 'T1 C1, C2, C3' 's1; s2; s3' @() `$c 'C:\k' 3>`$null | ConvertTo-Json -Compress -Depth 4 }"
Expect 'bugbrief args: sonnet for 3 checks unless -Complex, kitDir, a placeholder mandate (never a stored one)' ($bw[0] -notmatch 'complex' -and $bw[1] -match '"complex":true' -and $bw[0] -match '"kitDir":"C:/k"' -and $bw[0] -match "owner's words of this request" -and $bw[0] -notmatch 'review|roles')
# bugbrief checks: every package (first text wins an id), no env-data untested check, no gallery row
$fc = pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; (Get-KitFailedChecks ""## Failed checks``n### T5 — a``n**Saw:** x (cause: env-data)"", ""## Untested checks``n### R1 — d``n**Saw:** none (cause: env-data)``n## Failed checks``n### R2 — o``n**Saw:** wrong | Independent re-test: same"", ""### R2 — o``n**Saw:** old``n## Screens``n### G1 — h (PASS)"").ForEach({ `"`$(`$_.id)=`$(`$_.saw)`" }) -join ','"
Expect "bugbrief: failed checks across packages ($fc)" ($fc -eq 'T5=x (cause: env-data),R2=wrong')
$jt = pwsh @np $O board join -Type rechy -Run w8 | Out-String; $ju = pwsh @np $O board join -Run w8 2>&1 | Out-String; $juc = $LASTEXITCODE
Expect "board join: -Type only = the agent id; neither = usage, exit 2 ($juc)" ($jt -match 'SESSION rechy-' -and $juc -eq 2 -and $ju -match 'usage: bossy\.ps1 board join -Agent')
$cx = pwsh -NoProfile -Command ". '$O'; Test-KitCollision 'H6a overwrote MR !8543 description with another agent''s body file from the shared /tmp (fixed from history); halted the push'; Test-KitCollision 'Halted: another agent is editing the same worktree'"
Expect 'supervise collision: a fix report naming another agent = no flag; a real collision = flag' ($cx[0] -eq 'False' -and $cx[1] -eq 'True')
$lg = Invoke-PsTest 'track-lag' @'
. $args[0]; $KitConf.GitlabGroup = 'g'; $global:st = @{ t1 = 'Open'; t2 = 'for review' }
Register-KitAdapter 'tracker' 'fake' @{ view = { param($a) [pscustomobject]@{ id = $a.id; name = 'n'; status = $global:st[$a.id] } }; status = { param($a) $global:st[$a.id] = $a.status; 'ok' } }; Initialize-KitTracker -Type fake
function Invoke-HostApi($p) { @{ state = $(if ($p -match '/1$') { 'opened' } else { 'merged' }) } }
Update-KitTracking { param($all) $all.tasks.t1 = @{ task = 't1'; mrs = @('web!1') }; $all.tasks.t2 = @{ task = 't2'; mrs = @('web!2'); holdPromotion = 'agent stopped'; mergedSeenAt = (Get-Date).AddHours(-2).ToString('s') } }
Invoke-Track run -Detail; "t1:$($global:st.t1)"
'@ @($O) | Out-String
Expect 'track: an open MR moves an Open task to review; merged 60+ min but held = LAG' ($lg -match "DONE t1: status 'Open' -> review" -and $lg -match 't1:for review' -and $lg -match "LAG t2: all MRs merged at \d\d:\d\d, status still 'for review' \(promotion HELD: agent stopped\)")
$pzf = Join-Path (TkPath $k pauses -Create) 'pause-zz.json'; & $J @{ at = '2026-10-23T12:34:00'; reason = 'C: full'; run = '*'; state = 'paused' } $pzf
$pzw = pwsh -NoProfile -Command ". '$O'; (Get-KitPauseFlags @(Read-KitJsonFiles (Get-KitPath pauses)) @([pscustomobject]@{ run = 'rx' }) 0).what"
$af = Join-Path (Kd) 'rx.json'; [IO.File]::WriteAllText($af, '{"brief":"C:/b/rx.md"}')
$pzl = pwsh @np $O launch -Self -Script buildy.js -Run rx -ArgsFile $af | Out-String; $pza = pwsh -NoProfile -Command ". '$O'; [bool](Get-KitActivePause rx); [bool](Get-KitActivePause ry)"; Remove-Item $pzf, (Join-Path (TkPath $k launches) 'self-buildy-rx*')   # a typed launch record pairs with a self record by time
Expect 'pause of all runs: supervise flags it while a run works; a relaunch releases only that run (recorded)' ($pzw -match 'pause pause-zz\.json \(C: full, since 12:34\) is active while run\(s\) work: rx' -and $pzl -match 'PAUSE pause-zz\.json \(C: full\) released for run rx' -and $pza[0] -eq 'False' -and $pza[1] -eq 'True')
# journals (KIT_TRANSCRIPTS/<session>/subagents/workflows/<id>) and board entries of a live holder (this process)
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx'
function New-Journal($id, [object[]]$Lines) { $d = New-Item -ItemType Directory -Force (Join-Path $env:KIT_TRANSCRIPTS "s1/subagents/workflows/$id"); $Lines | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 } | Set-Content (Join-Path $d 'journal.jsonl') }
$hs = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); $bd = TkPath $k board -Create
function New-Entry($agent, $run, $min, $status = 'working') { & $J @{ session = "s-$agent"; agent = $agent; run = $run; type = 'revy'; status = $status; beat = (Get-Date).AddMinutes(-$min).ToString('o'); joined = (Get-Date).AddHours(-1).ToString('o'); holderPid = $PID; holderStart = $hs } (Join-Path $bd "s-$agent.json") }
New-Journal wf_r1 @(@{ type = 'started'; agentId = 'a1'; label = 'review:PY-RET' }, @{ type = 'result'; agentId = 'a1'; result = @{ findings = @() } }, @{ type = 'started'; agentId = 'a2'; label = 'build:X2' })
New-Journal wf_r3 @(@{ type = 'started'; agentId = 'b1'; label = 'learn' }, @{ type = 'result'; agentId = 'b1'; result = @{ signals = 1 } }, @{ type = 'finished' })
New-Entry 'review-PY-RET' r1 49; New-Entry 'revy-1400' kit-fix 40; New-Entry 'kitty' kit-fix 41 'left'; New-Entry 'H9' r2 30
$null = pwsh @np $O launch -RunId wf_r3 -Script buildy.js -ArgsJson '{"brief":"C:/b/r3.md","run":"r3"}' 2>&1
$sj = pwsh @np $O supervise -AutoFix -Json | Out-String | ConvertFrom-Json; $sw = @($sj.flags | ForEach-Object { "[$($_.level)] $($_.what)" }) -join "`n"
$lr3 = Read-Json (Join-Path (TkPath $k launches) 'wf_r3.json'); $left = { param($a) $e = Read-Json (Join-Path $bd "s-$a.json"); $e.status -eq 'left' -and $e.finished }
Expect 'supervise -AutoFix: stale entries with a journal result or a finished parent leave as finished (INFO); a silent one = STUCK (WATCH); a finished run''s record closes' ((& $left 'review-PY-RET') -and (& $left 'revy-1400') -and -not (& $left 'H9') -and
  $sw -match '\[INFO\] auto-fixed: board entry review-PY-RET \(r1\) left: its workflow step has a journal result' -and $sw -match '\[INFO\] auto-fixed: board entry revy-1400 \(kit-fix\) left: every other agent of its run left' -and
  $sw -match '\[WATCH\] STUCK H9 \(revy\) \(r2\): no progress for 30 min' -and $sw -match '\[INFO\] auto-fixed: run wf_r3 finished: launch record closed' -and $lr3.completed -and $lr3.learned -match 'own|launch -Done')
# status rows, one per state; transcripts (Claude, Codex, Antigravity shapes) with set mtimes
$tx = { param($f, [string[]]$Lines, [int]$Min = 1) New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content $f $Lines; (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-$Min); $f }
$ago = { param($m) (Get-Date).AddMinutes(-$m).ToString('o') }; $wd = Join-Path $env:KIT_TRANSCRIPTS 's1/subagents/workflows/wf_s1'
New-Journal wf_s1 (@(1..31 | ForEach-Object { @{ type = 'started'; agentId = "x$_"; label = "test:$(if ($_ -eq 1) { 'S1' } else { "T$_" })" }, @{ type = 'result'; agentId = "x$_"; result = @{ summary = "S$_ shipped !1$_" } } }) + @{ type = 'started'; agentId = 'x32'; label = 'build:S32' })
$null = & $tx "$wd/agent-x32.jsonl" '{"type":"assistant","version":"2.9","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"🧪 Run the tests"}}]}}'
& $J @{ run = 'sr'; script = 'C:/k/buildy.js'; wfDir = $wd; cap = 2e7; spent = 1.5e6; at = (& $ago 60) } (Join-Path (TkPath $k launches) 'self-buildy-sr.json')
$cx = & $tx (Join-Path (Kd) 'codex/rollout-1.jsonl') '{"type":"session_meta","payload":{"cli_version":"0.157.0","agent_role":"devy"}}', '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"npm test\"}"}}', '{"type":"event_msg","payload":{"type":"task_complete"}}', '{"type":"brand_new_kind","payload":{}}'
$ag = & $tx (Join-Path (Kd) 'brain/c1/.system_generated/logs/transcript.jsonl') '{"step_index":4,"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command","args":{"toolSummary":"Run unit tests"}}]}'
& $J @{ conversationId = 'c1'; state = 'SUBAGENT_STATE_KILLED'; subagentDescriptor = @{ typeName = 'checky' } } (Join-Path (Kd) 'brain/p1/.system_generated/subagents/c1.json')
$se = { param($a, [hashtable]$x) $b = @{ session = "s-$a"; agent = $a; run = 'sr'; type = 'devy'; status = 'working'; beat = (& $ago 1); joined = (& $ago 90); holderPid = $PID; holderStart = $hs }; foreach ($kx in $x.Keys) { $b[$kx] = $x[$kx] }; & $J $b (Join-Path $bd "s-$a.json") }
& $se S1 @{ status = 'left'; transcript = (& $tx (Join-Path (Kd) 'S1.jsonl') '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Reporting results, leaving the board"}}]}}' 0) }
& $se S2 @{ beat = (& $ago 30) }; & $se S3 @{ beat = (& $ago 30) }; & $se S4 @{ status = 'left'; crashed = (& $ago 5) }; & $se S5 @{ beat = (& $ago 40); transcript = (& $tx (Join-Path (Kd) 'S5.jsonl') '{}') }
& $se S6 @{}; & $se S7 @{ tool = 'codex'; transcript = $cx }; & $se S8 @{ tool = 'antigravity'; transcript = $ag; status = 'running tests' }
& $J @{ id = 'e-1'; kind = 'envfix'; run = 'sr'; agent = 'S2'; status = 'pending'; at = (& $ago 20) } (Join-Path (TkPath $k decisions -Create) 'e-1.json')
& $J @{ waiting = @(@{ kind = 'lanes'; holder = 'S6'; heldBy = 'vision x'; pid = $PID; pidStart = $hs; at = (& $ago 3) }) } (Join-Path (TkPath $k runtimes -Create) 'gpu.json')
# an older folder of run sr (its S32 finished; the newer one runs S32 again), a run whose only step waits, a paused run between steps
$wj = { param($id, $run, [object[]]$L, $m, $x = @{}) New-Journal $id $L; (Get-Item "$(Split-Path $wd)/$id/journal.jsonl").LastWriteTime = (Get-Date).AddMinutes(-$m); & $J (@{ runId = $id; run = $run } + $x) (Join-Path (TkPath $k launches) "$id.json") }
& $wj wf_s0 sr @(@{ type = 'started'; agentId = 'x0'; label = 'build:S32' }, @{ type = 'result'; agentId = 'x0'; result = @{ summary = 'old' } }) 60; & $se S32 @{ status = 'left' }
& $wj wf_s2 sp @(@{ type = 'started'; agentId = 'y1'; label = 'build:P1' }) 30; $null = & $tx "$(Split-Path $wd)/wf_s2/agent-y1.jsonl" '{}' 30
& $J @{ id = 'e-2'; kind = 'envfix'; run = 'sp'; agent = 'P1'; status = 'pending'; at = (& $ago 25) } (Join-Path (TkPath $k decisions) 'e-2.json')
& $wj wf_s3 sq @(@{ type = 'started'; agentId = 'z1'; label = 'build:Q1' }, @{ type = 'result'; agentId = 'z1'; result = @{} }) 5 @{ paused = (& $ago 4) }
& $se S9 @{ beat = (& $ago 30) }; $null = & $tx (Join-Path $env:KIT_TRANSCRIPTS 's1/subagents/agent-a9.jsonl') '{"message":{"content":[{"type":"tool_result","content":"SESSION s-S9 (pass -Session)"}]}}'   # an Agent-tool subagent no beat mapped
$st = Invoke-PsTest 'status' '. $args[0]; $r = Get-KitStatusRows; Format-KitStatusTable $r (Get-Date) $script:KitTxVersions; Get-KitStuckFlags $r (Get-Date) 20 | ForEach-Object { "[$($_.level)] $($_.what)" }' @($O)
$sv = { param($n, $rx) [bool]@($st | Where-Object { $_ -match "^\| $([regex]::Escape($n)) \|[^|]*\| $rx" }).Count }
$lt = Invoke-PsTest 'livetx' '. $args[0]; @(Get-KitLiveTranscripts (Get-Date) 10).Name -join ","' @($O)
Expect "status: a stale beat but a fresh transcript (found by its SESSION line, kept in the entry) = ACTIVE; NEXT counts it ($lt)" ((& $sv 'S9 (devy)' 'ACTIVE') -and (Read-Json "$bd/s-S9.json").transcript -match 'agent-a9' -and "$lt" -match 'agent-a9')
$fr = Invoke-PsTest 'finished' '. $args[0]; $n = Get-Date; (Select-KitBriefRows @(foreach ($m in 31, 29) { [pscustomobject]@{ name = "f$m"; state = "FINISHED"; ended = $n.AddMinutes(-$m) } }; [pscustomobject]@{ name = "s"; state = "STUCK"; ended = $n.AddDays(-1) }) $n).name -join ","' @($O)
Expect "-Brief table: FINISHED 31 min ago hidden, 29 min ago shown, STUCK always ($fr)" ("$fr" -match '^f29,s$')
Expect "status: one row per state, transcripts first ($($st -join ' // '))" ((& $sv 'sr (workflow)' 'ACTIVE \(1 step left\)') -and @($st -match 'buildy\.js wf_s1 · steps 31/32 · 1\.5M tokens of 20M').Count -and (& $sv 'S32 (devy)' 'ACTIVE \| .* Bash: 🧪 Run the tests') -and -not @($st -match 'S32 \(step\)|STUCK sp').Count -and (& $sv 'sp (workflow)' 'WAITING: env fix e-2 \|') -and (& $sv 'sq (workflow)' 'WAITING: owner pause') -and
  (& $sv 'S1 (devy)' 'FINISHED: S1 shipped !11 \|') -and (& $sv 'S2 (devy)' 'WAITING: env fix e-1') -and (& $sv 'S3 (devy)' 'STUCK \(30 min\)') -and (& $sv 'S4 (devy)' 'STOPPED \(crashed\)') -and (& $sv 'S5 (devy)' 'ACTIVE') -and
  (& $sv 'S6 (devy)' 'WAITING: GPU, held by vision x') -and (& $sv 'S7 (devy)' 'FINISHED: turn complete \| .* exec_ command: npm test') -and (& $sv 'S8 (devy)' 'STOPPED \(killed\) \| .* run_command: Run unit tests') -and
  @($st -match '^transcripts read: claude 2\.9, codex 0\.157\.0$').Count -and @($st -match '^\[WATCH\] STUCK S3 \(devy\) \(sr\): no progress for 30 min').Count -and
  @(pwsh @np $O status -Json | ConvertFrom-Json | Where-Object { $_.name -eq 'S2 (devy)' -and $_.state -eq 'WAITING' }).Count)
$nb = pwsh -NoProfile -Command ". '$O'; foreach (`$c in @(15, 1, 0, 0, 0, 2, 2, 1), @(15, 0, 1, 0, 0, 2, 2, 1), @(15, 0, 0, 1, 0, 2, 2, 1), @(15, 0, 0, 0, 3, 2, 2, 1), @(15, 0, 0, 0, 0, 9, 9, 3), @(15, 0, 0, 0, 0, 0, 0, 0), @(15, 0, 0, 0, 0, 2, 0, 2), @(15, 0, 0, 0, 0, 2, 2, 1), @(5, 0, 0, 0, 0, 2, 2, 1), @(30, 0, 0, 0, 0, 2, 2, 1)) { `$n = Get-KitNextBeat `$c[0] 15 `$c[1] `$c[2] ([bool]`$c[3]) `$c[4] `$c[5] `$c[6] `$c[7]; `"`$(`$n.min) `$(`$n.why)`" }"
Expect "heartbeat NEXT: ACT 5, ENV-FIX 5, storage / 3 failed builds / many agents 8, nothing runs 30, all idle 22, normal 15, back toward 15 from 5 and 30 ($($nb -join ' | '))" (($nb -join '|') -eq '5 1 ACT open|5 1 ENV-FIX open|8 storage anomaly|8 3 failed builds in a row|8 9 live agents|30 nothing runs|22 every agent idle|15 normal|10 back toward 15|22 back toward 15' -and $sj.nextBeat.min -ge 5 -and $sj.nextBeat.min -le 30 -and (Read-Json (TkPath $k supervise-state)).nextBeat -eq $sj.nextBeat.min)
$bt = pwsh -NoProfile -Command ". '$O'; `$f = Get-KitPath supervise-state; `$s = Get-Content `$f -Raw | ConvertFrom-Json -AsHashtable; `$s.nextBeat = 30; `$s.report.at = (Get-Date).AddMinutes(-10).ToString('s'); `$s | ConvertTo-Json -Depth 5 | Set-Content `$f; Get-KitBeatMinutes; `$s.report.at = (Get-Date).AddMinutes(-70).ToString('s'); `$s | ConvertTo-Json -Depth 5 | Set-Content `$f; Get-KitBeatMinutes"
Expect "heartbeat: the last NEXT holds for 2 beats, then the base (a stopped coordinator) ($($bt -join ','))" (($bt -join ',') -eq '30,15')
$ak = pwsh @np $O supervise -Ack 'ERROR SPIKE: 3 new error line(s) in D:\x\rm-api.log' -Reason 'expected 4xx' | Out-String
$sf = pwsh -NoProfile -Command ". '$O'; `$a = (Get-Content (Get-KitPath supervise-state) -Raw | ConvertFrom-Json -AsHashtable).acks; Select-KitFlags @([pscustomobject]@{ level = 'ACT'; what = 'ERROR SPIKE: 5 new error line(s) in D:\x\rm-api.log' }, [pscustomobject]@{ level = 'ACT'; what = 'HANDOFF X1 (r) 16 min ago' }, [pscustomobject]@{ level = 'ACT'; what = 'HANDOFF X1 (r) 17 min ago' }, [pscustomobject]@{ level = 'ACT'; what = 'HANDOFF X2 (r) 16 min ago' }) `$a (Get-Date) | ForEach-Object what"
Expect 'supervise -Ack hides that flag (counts differ) 24 h; one line per problem, ids apart (X1, X2)' ($ak -match 'acknowledged for 24 h' -and $sf.Count -eq 3 -and $sf[0] -eq 'HANDOFF X1 (r) 16 min ago' -and $sf[1] -eq 'HANDOFF X2 (r) 16 min ago' -and $sf[2] -match '1 acknowledged flag\(s\) hidden')
# stopped runs learn once: launch -Done twice, pause twice
New-Journal wf_r4 @(@{ type = 'started'; agentId = 'c1'; label = 'build:X1' }, @{ type = 'result'; agentId = 'c1'; result = @{ error = 'boom: local env down' } })
$null = pwsh @np $O launch -RunId wf_r4 -Script buildy.js -ArgsJson '{"brief":"C:/b/r4.md","run":"r4"}' 2>&1
$d1 = pwsh @np $O launch -Done -RunId wf_r4 2>&1 | Out-String; $null = pwsh @np $O launch -Done -RunId wf_r4 2>&1
New-Journal wf_r5 @(@{ type = 'started'; agentId = 'd1'; label = 'test:A1' }, @{ type = 'result'; agentId = 'd1'; result = @{ error = 'seat lost'; checks = @(@{ id = 'c1'; result = 'NOT_TESTED'; observed = 'lost' }, @{ id = 'c2'; verify = 'not reproduced' }) } }, @{ type = 'started'; agentId = 'd2'; label = 'test:A2' })
$null = pwsh @np $O launch -RunId wf_r5 -Script testy.js -ArgsJson '{"runDir":"C:/q/r5"}' 2>&1
foreach ($i in 1, 2) { $null = pwsh @np $O pause -Run r5 -Wait 0 2>&1 }
$sg = @(Get-Content (TkPath $k signals) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { "$($_.source)" -like 'stop:*' })
$s4 = @($sg | Where-Object ref -eq r4); $s5 = @($sg | Where-Object ref -eq r5)
Expect "stopped runs learn once: launch -Done x2 and pause x2 record their signals once (QA: NOT_TESTED, unreproduced checks), the report is written ($($s4.Count) $($s5.Count))" ($s4.Count -eq 2 -and @($s4 | Where-Object { $_.kind -eq 'failure' -and $_.text -match 'build:X1: boom' -and $_.skill -eq 'crafty' }).Count -and
  $s5.Count -eq 3 -and $s5[0].skill -eq 'pokey' -and $s5[0].text -eq 'test:A1: seat lost' -and $s5[1].text -match 'NOT_TESTED, first c1: lost' -and $s5[2].kind -eq 'false-positive' -and $d1 -match 'learn: run r4 stopped by launch -Done - 2 signal' -and (Read-Json (Join-Path (TkPath $k waves) 'wf_r4.json')).run -eq 'wf_r4')
$null = pwsh @np $O board nosuch 2>&1; $bpc = $LASTEXITCODE; $bpe = & { . (Join-Path $k 'skills/crafty/lib.ps1'); (Read-KitLog calls ([datetime]0) | Where-Object { "$($_.rc)" -eq '2' } | Select-Object -Last 1).error }
Expect "a bad parameter: exit 2, its call line keeps the why ($bpc)" ($bpc -eq 2 -and $bpe -match '^board: .*nosuch')
$mu = 'https://h.x/g/r/-/merge_requests/1'   # build and fix spell one MR two ways (case, slash): one row
New-Journal wf_r9 @(foreach ($l in 'build', 'fix') { @{ type = 'started'; agentId = $l; label = "${l}:X1" }; @{ type = 'result'; agentId = $l; result = @{ mrs = @(@{ url = $mu; merged = $true }) } }; $mu = $mu.Replace('h.x', 'H.X') + '/' })
$rm6 = @((pwsh -NoProfile -Command ". '$O'; function Invoke-HostVerb { @{ state = 'opened' } }; Invoke-Report -Run wf_r9 -Json" | Out-String | ConvertFrom-Json).agents.X1.mrs)
Expect "report: an agent's merged: true loses to the host's state now ($($rm6.mergeState))" ($rm6.Count -eq 1 -and -not $rm6[0].merged -and $rm6[0].mergeState -eq 'OPEN')
$lp = TkPath $k logs -Create; Set-Content "$lp/k4.log" (1..5000); Set-Content "$lp/k6.log" (1..5001); $hw = [IO.FileStream]::new("$lp/k6.log", 'Open', 'Write', 'ReadWrite')
try { $cd = pwsh @np $O cleanup -DryRun -WorktreeRoot (Join-Path (Kd) 'no') 2>&1 | Out-String } finally { $hw.Dispose() }
Expect 'cleanup: a log over 5000 lines rotates while a writer holds it; 5000 lines stay' ($cd -match 'rotated.*k6\.log' -and $cd -notmatch 'k4')
New-Item -ItemType Directory -Force "$k/workflows" | Out-Null; Copy-Item (Join-Path $src 'workflows/tidy.js') "$k/workflows/"
New-Journal wf_r6 @(@{ type = 'started'; agentId = 'e1'; label = 'prep' }, @{ type = 'result'; agentId = 'e1'; result = @{ ok = $true } })
$null = pwsh @np $O launch -RunId wf_r6 -Script tidy.js -ArgsJson '{"run":"r6"}' 2>&1; $d6 = pwsh @np $O launch -Done -RunId wf_r6 2>&1 | Out-String
$s6 = @(Get-Content (TkPath $k signals) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.ref -eq 'r6' })
Expect "launch -Done on a run without a Learn phase: no skipped-Learn signal ($($s6.Count))" (-not $s6.Count -and $d6 -match 'learn: run r6 stopped by launch -Done - nothing to record')
$wr = Join-Path (Kd) 'wtr'; $bo = Join-Path (Kd) 'wto.git'; git init -q --bare -b main $bo; git clone -q $bo "$wr-main" 2>$null; 'a' | Set-Content "$wr-main/a.txt"; Save-GitRepo "$wr-main" init; git -C "$wr-main" push -q origin main 2>$null
foreach ($n in 'gone', 'dirty') { git -C "$wr-main" worktree add -q -b "f/$n" "$wr/$n" 2>$null; "$n" | Set-Content "$wr/$n/$n.txt"; Save-GitRepo "$wr/$n" $n; git -C "$wr/$n" push -q -u origin "f/$n" 2>$null; git -C "$wr-main" push -q origin --delete "f/$n" 2>$null }
'edit' | Add-Content "$wr/dirty/dirty.txt"; foreach ($f in Get-ChildItem $wr -Recurse -File -Force) { $f.LastWriteTime = (Get-Date).AddDays(-9) }
$wp = pwsh @np $O cleanup -WorktreesOnly -WorktreeRoot $wr 2>&1 | Out-String
Expect "cleanup: a clean worktree whose remote branch is gone goes after worktreeDays (branch kept); one with uncommitted files is only reported" (-not (Test-Path "$wr/gone") -and (git -C "$wr-main" branch --list 'f/gone') -and (Test-Path "$wr/dirty/dirty.txt") -and $wp -match 'remote branch gone' -and $wp -match 'dirty \(f/dirty\): uncommitted files, idle 9 d: kept')
Remove-Item Env:KIT_TRANSCRIPTS
Remove-TestKit $k
# ---- resources (was the goody supervise-resources)
$k = New-TestKit sres
$O = Join-Path $k 'skills/bossy/bossy.ps1'
# gate.cacheFlush: a starved gate + a big file cache -> one flush per 30 min; a failing command = one WATCH
$cft = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Get-KitSetting($Key, $Default) { if ($Key -eq 'gate.cacheFlush') { 'flush-now' } else { $Default } }
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
$global:runs = 0; function Invoke-KitExe($Exe, $A, $TimeoutSec) { $global:runs++; [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
function Get-SysMem { [pscustomobject]@{ TotalGB = 64; AvailGB = 9 } }
$m = [pscustomobject]@{ TotalGB = 64; AvailGB = 3 }; $n = Get-Date
$a = Invoke-KitCacheFlush 12 $m $n; $b = Invoke-KitCacheFlush 12 $m $n
"once:$($a.what -eq 'auto-fixed: file cache flush: available 3 -> 9 GB' -and -not $b -and $global:runs -eq 1)"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp')
"short:$(-not (Invoke-KitCacheFlush 5 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 4GB } }
"small:$(-not (Invoke-KitCacheFlush 12 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 1; out = ''; err = 'Access is denied.'; timedOut = $false } }
$fl = Invoke-KitCacheFlush 12 $m $n
"fail:$($fl.level -eq 'WATCH' -and $fl.what -match 'exit 1: Access is denied')"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp'); function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
$global:polls = 0; function Get-SysMem { $global:polls++; [pscustomobject]@{ TotalGB = 64; AvailGB = 3 } }   # no gain: polls only within its budget
$nb = Invoke-KitCacheFlush 12 $m $n 2
"budget:$($global:polls -eq 1 -and $nb.what -match 'available 3 -> 3 GB')"
'@
Expect-Each (Invoke-PsTest 'cache-flush' $cft @($O)) 'cache flush: #' @('once', 'short', 'small', 'fail', 'budget')
$bf = & { . $O; $n = Get-Date; $f = { param($h, $ok) @{ ok = $ok; at = $n.AddHours(-$h).ToString('o') } }
  @(Get-KitBuildFailures @{ old = @((& $f 150 $false), (& $f 149 $false), (& $f 148 $false)); new = @((& $f 3 $false), (& $f 2 $false), (& $f 1 $false)); mixed = @((& $f 3 $false), (& $f 2 $true), (& $f 1 $false)) } $n) -join ',' }
Expect 'build failures: 3 failed in a row flag only when the last is < 24 h old' ($bf -eq 'new')
# a gone session's QA seat + claims freed in ONE line; board show lists seats and env leases
$dp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden; $dp.WaitForExit()
$qs = TkPath $k qa-seats -Create; foreach ($x in 'seats/s1', 'claims/r1__A1', 'claims/r1__A2') { Set-JsonFile (Join-Path $qs "$x.json") @{ agent = 'test:Q9'; holderPid = $dp.Id } }
$za = "$k/skills/bossy/adapters/z.ps1"; 'function Get-KitSuperviseGuardZ { @{ info = ''zi'' }; @{ level = ''WATCH''; what = ''w '' * 50 } }' > $za
$sb = Px $O supervise -AutoFix -Brief -Takeover -Session me 2>&1 | Out-String; Remove-Item $za
$sr = Get-Content (TkPath $k supervise-report) -Raw
Expect 'supervise -AutoFix: a gone session''s QA seat + claims freed in ONE line' (@([regex]::Matches($sr, 'QA seat/claim')).Count -eq 1 -and $sr -match "freed 3 QA seat/claim file\(s\) of gone session process $($dp.Id)" -and -not @(Get-ChildItem $qs -Recurse -Filter *.json).Count -and $sr -match 'gate: \d+ running')
$wc = ($sr -split '## Agents \(whole cells\)')[1]; Expect 'supervise -Brief: whole cells + INFO in the report, named under a cut' ($wc -match '## All flags' -and $wc -notmatch '\(full: report\)' -and $wc -match '\| INFO \| zi' -and $sb -match 'cut cells whole: ')
$sd = Join-Path $qs 'seats'; New-Item -ItemType Directory -Force $sd | Out-Null
'{"agent":"test:Q1","kind":"web","need":2,"since":"2026-10-16T10:00:00"}' | Set-Content "$sd/q1.json"
# the env's leases come from envy.ps1 status -Json (a stub here): never its state files
New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy') | Out-Null
"'[{`"env`":`"shop`",`"leases`":[{`"agent`":`"devy-A1`",`"services`":[`"api`"],`"until`":null,`"graceLeft`":7}],`"holds`":[]}]'" | Set-Content (Join-Path $k 'skills/envy/envy.ps1')
$bs = Px $O board show | Out-String; $rc = Px $O recover | Out-String
Expect 'board show lists QA seats and env leases; recover lists the lease with no live holder' ($bs -match 'seat: test:Q1 web 2 GB' -and $bs -match 'lease: shop devy-A1 on api' -and $rc -match '== LEASE shop devy-A1 \[api\]: no live holder, ends in 7 min')
"`n## kitty`n- board slot" | Add-Content "$k/LESSONS.md"; $sg = TkPath $k signals
'idea', 'win', 'retired' | ForEach-Object { @{ at = '2099-01-01'; skill = 'kitty'; kind = $_; text = 'board slot' } | ConvertTo-Json -Compress } | Add-Content $sg
$tp = pwsh @np $O tidy prep -DryRun -Json | ConvertFrom-Json; $tg = Get-Content $tp.digest -Raw; pwsh @np $O tidy done -At '2026-01-02T03:04' >$null
Expect 'tidy prep: group, lesson, retired; done stamps' (-not $tp.stamped -and $tg -match '(?s)2x kitty \[idea,win\].*-> lesson.*<- retired' -and (Get-Content (TkPath $k last-retro)) -match 'T03:04:00')
# board: the same name in a live session 5 min after its beat = a parallel agent
$j3 = pwsh @np $O board join -Agent BY -Run rb | Out-String; $s3 = ($j3 -csplit 'SESSION ')[-1].Split(' ')[0]; $f3 = Join-Path (TkPath $k board) "$s3.json"
$e3 = Read-Json $f3; $e3.holderPid = $PID; $e3.holderStart = & { . (Lib); Get-KitPidStart $PID }; $e3.beat = (Get-Date).AddMinutes(-5).ToString('o'); & $J $e3 $f3
$j4 = pwsh @np $O board join -Agent BY -Run rb | Out-String; $b3 = pwsh @np $O board beat -Session $s3 | Out-String
Expect "board: a same-name agent in a live session is BY-2, no takeover ($j4)" ($j4 -match 'you are BY-2' -and $j4 -notmatch 'TAKEOVER|DUPLICATE' -and $b3 -notmatch 'TAKEN')
# storage: verdicts, learned normal, folder sizes, drill-down, db watchdog, rescue hold
$sd = Join-Path (Kd) 'stree'; foreach ($f in 'a/x/1.bin', 'a/y/2.bin', 'b/3.bin') { New-Item -ItemType Directory -Force (Split-Path "$sd/$f") | Out-Null; [IO.File]::WriteAllBytes("$sd/$f", [byte[]]::new(1MB)) }
'if ($env:USE10) { 1..10 | ForEach-Object { "$_ 0.6 10 q$_" } } else { "42 0.5 900 SELECT 1"; "43 7 30 SELECT big" }' | Set-Content "$sd/use.ps1"; 'param($i) Add-Content (Join-Path $PSScriptRoot killed.txt) $i' | Set-Content "$sd/kill.ps1"
$sto = Invoke-PsTest storage @'
$null = . $args[0] 6>$null; $sd = $args[1]
$c = [pscustomobject]@{ watchFreeGB = 50; actHours = 1; factor = 10; minRateGBh = 5; scanDropGB = 1; actFreeGB = 30; drillGB = 1; flatDays = 7; holdMinutes = 60; sampleSeconds = 60; watch = @()
  db = @{ use = "pwsh -NoProfile -File `"$sd/use.ps1`""; kill = "pwsh -NoProfile -File `"$sd/kill.ps1`" {id}"; maxGB = 5 } }
function Get-KitStorageConf { $c }
$xs = { param($f, $pm) @(0..20 | ForEach-Object { [pscustomobject]@{ t = 1e6 + 60 * $_; free = $f + $pm * (20 - $_) } }) }
foreach ($x in @(40, 0.12, 0.2), @(600, 0.12, 0.2), @(3, 0.12, 0.2), @(600, 0.12, 2), @(600, 0, 0.2), @(20, 0, 0.2, 0)) { $v = Get-KitDiskVerdict (& $xs $x[0] $x[1]) $c $x[2] ($x.Count -lt 4); "v:$($v.level),$($v.rescue),$($v.scan)" }
$b = @(0..20 | ForEach-Object { [pscustomobject]@{ t = 1e6 + 60 * $_; free = 8 + [math]::Max(0, 2 - 0.7 * $_) } }); $v = Get-KitDiskVerdict $b $c; "burst:$($v.level),$($v.rescue)"
"normal:$(Get-KitDiskNormal @(0..10 | ForEach-Object { [pscustomobject]@{ t = 3600 * $_; free = 100 - 0.5 * $_ } }))"
$m = Measure-KitFolders $sd @("$sd/a".Replace('/', [IO.Path]::DirectorySeparatorChar)); $ak = "$sd/a".Replace('/', [IO.Path]::DirectorySeparatorChar).ToLower()
"folders:$($m.sizes[$ak] / 1MB):$((@($m.kids[$ak].Values) | Sort-Object) -join ',')"
$fo = @{ tracked = @{ R = @{ src = 'default' }; L = @{ src = 'learned'; flat = (Get-Date).AddDays(-8).ToString('s') } } }
$g = Update-KitTracked $fo @{ sizes = @{ R = 13; L = 2 }; kids = @{ R = @{ 'R/a' = 1.2; 'R/b' = 7.8 } } } @{ sizes = @{ R = 10; L = 2 }; kids = @{ R = @{ 'R/a' = 1; 'R/b' = 5 } } } $c
"drill:$($g[0].path)+$($g[0].gb):$(@($fo.tracked.Keys | Sort-Object) -join ',')"
$q = @(Get-KitDbQueries $c); $null = Invoke-KitStorageTick -Force; $env:USE10 = '1'; $null = Invoke-KitStorageTick -Force; $z = [pscustomobject]@{ drive = 'Z'; kit = $true; free = 3; rate = 9; ttf = 0.3 }
Invoke-KitDiskRescue $c $z @($q | Where-Object id -ne 43); Invoke-KitDiskRescue $c $z $q; $h1 = (Get-KitDiskHold).drive
Set-KitStorageState { param($s) $s.rescues.Z.at = (Get-Date).AddHours(-2).ToString('o') }
"db:$($q.Count):$((Get-Content "$sd/killed.txt") -join ','):hold $h1/$([bool](Get-KitDiskHold))"
[IO.File]::WriteAllText((Get-KitStorageFile Q), (@(0..2 | ForEach-Object { '{"t":' + ([DateTimeOffset]::Now.ToUnixTimeSeconds() - 60 * $_) + ',"free":' + (50 + $_) + ',"size":100}' }) -join "`n") + "`n")
Invoke-Storage -Drive Q -Since 1h
'@ @($O, $sd)
Expect 'storage verdicts: odd fill ACT + rescue, far WATCH, full in 1 h rescue, normal OK, 1 GB/beat scan, kit drives only, burst no rescue' ((($sto | Where-Object { $_ -like 'v:*' -or $_ -like 'burst:*' }) -join ' ') -eq 'v:ACT,True,True v:WATCH,False,True v:ACT,True,True v:OK,False,True v:OK,False,False v:OK,False,False burst:ACT,False')
Expect 'storage: the learned normal = the median hourly fill rate' ($sto -contains 'normal:0.5')
Expect 'storage: one enumeration gives a folder''s size and each child''s' ($sto -contains 'folders:2:1048576,1048576')
Expect 'storage: the grown folder''s grown child becomes tracked; a learned folder flat 7 days drops out' ($sto -contains 'drill:R+3:R,R/b')
Expect 'storage: over maxGB killed (43), small not; rescue kills the temp holder (42) once per 10 min, holds builds' ($sto -contains 'db:2:43,42:hold Z/False')
Expect 'bossy.ps1 storage: the timeline of a drive with its db kills' ((($sto -join "`n") -match '(?m)^== Q: 3 sample') -and ($sto -join "`n") -match 'db-kill: SELECT big')
$le = Invoke-PsTest 'leases' @'
. $args[0]; $gs = ${function:Get-KitSetting}; function Get-KitSetting($p, $d) { if ($p -eq 'gpu.exclusive') { [pscustomobject]@{ lanes = 1 } } else { & $gs $p $d } }
$s = ((Invoke-KitVerb Invoke-Board join, -Agent, AP, -Run, r | Out-String) -split 'SESSION ')[1].Split()[0]
$null = Use-KitGpu -Kind lanes -Holder AP; $null = Use-KitGpu -Kind lanes -Holder AP -ProcessId (Get-Process -Id $PID).Parent.Id; $null = Invoke-KitVerb Invoke-Board leave, -Session, $s
"dead:$(-not (Test-KitLive @{ agent = 'AP'; holderPid = $PID }))"
$g = Get-Content (Get-KitPath leases) | ConvertFrom-Json | % { $_.event + $_.reason }; $ok = "$g" -match '^acquire releaseleft the board \(AP'; "log:$ok"
$ok = (Invoke-KitVerb Invoke-Status @() | Out-String) -match 'gpu lanes \| free .+ AP \(release: left'; "status:$ok"
$KitLeaseLogMax = 300; 1..6 | % { Write-KitLeaseLog acquire tab $_ }; "trim:$(@(Get-Content (Get-KitPath leases)).Count -lt 8)"
'"LY"' > "$(Get-KitPath localenv -Create)/e.json"; function Get-KitLocalEnvStatus { @{ env = 'e'; repos = @(@{ layers = @(@{ agent = 'LY' }) }) } }; function Invoke-KitExe { $script:kx = "$($args[1])"; @{ out = 'q' } }
"layer:$("$(Invoke-KitReleaseAgent LY)" -match '^LY env: q' -and $kx -match 'drop -Env e -Agent LY -Note agent finished$')"
'@ @($O)
Expect-Each $le 'leases (left = dead): #' 'dead', 'log', 'status', 'trim', 'layer'
$jr = Invoke-Js wf-rel @'
const c = _mock(_pass); await run({ brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'X1' }] }, c.agent, _n, _n, pipeline); const L = c.calls.map((x) => x.label)
console.log(`release:${L.indexOf('release-X1') > L.indexOf('build:X1') && L.filter((l) => l === 'release-X1').length === 2 && /release -Agent 'X1' -Reason 'agent finished'/.test(c.calls.find((x) => x.label === 'release-X1').prompt)}`)
'@ (Join-Path $src 'workflows/buildy.js')
Expect-Each $jr 'buildy: # (after the build stage and the run)' 'release'
# supervise: the owner's MRs merged in 24 h that no task tracks = one WATCH; the host list is cached one beat, tracking re-read
$um = @'
$o, $add = $args; . $o; $KitConf.TrackerType = 'command'; $KitConf.TrackerTag = 'TT-'; $KitConf.TrackerRepos = @('shop')
function Get-KitHostUser { 'me' }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { if ($Verb -ne 'mr.list') { return }; "hostcalls:1"| Out-File -Append (Join-Path (Get-KitPath cache -Create) 'um-calls.txt')
  $h = { param($n) (Get-Date).ToUniversalTime().AddHours(-$n).ToString('o') }
  @([pscustomobject]@{ iid = 8729; title = 'fix: test support root'; source_branch = 'fix/TT-7-root'; author = @{ username = 'me' }; merged_at = (& $h 1) },
    [pscustomobject]@{ iid = 8725; title = 'feat: x'; source_branch = 'f/TT-7-x'; author = @{ username = 'me' }; merged_at = (& $h 2) },
    [pscustomobject]@{ iid = 1; title = 'other'; author = @{ username = 'you' }; merged_at = (& $h 1) }, [pscustomobject]@{ iid = 3; title = 'deploy'; source_branch = 'main'; author = @{ username = 'me' }; merged_at = (& $h 1) },
    [pscustomobject]@{ iid = 2; title = 'old'; author = 'me'; merged_at = (& $h 30) }) }
Update-KitTracking { param($t) $t.tasks['T7'] = @{ task = 'T7'; mrs = @('shop!8725') + @(if ($add) { 'shop!8729' }) } }
Invoke-Supervise -Json -Takeover
'@
$u1 = Invoke-PsTest 'untracked-mr' $um @($O, '') | Out-String; $u2 = Invoke-PsTest 'untracked-mr' $um @($O, '1') | Out-String
$ig = Px $O track ignore -Mrs 'shop!8729' -Reason 'not mine' | Out-String; $u3 = Invoke-PsTest 'untracked-mr' $um @($O, '') | Out-String
$uc = @(Get-Content (Join-Path (TkPath $k cache) 'um-calls.txt') -ErrorAction SilentlyContinue).Count
Expect "supervise: an untracked merged MR of the owner = one WATCH with its track add; tracked or track ignore -> gone; host listed once per beat ($uc)" ($ig -match 'ignored shop!8729' -and $u3 -notmatch 'tracked by no task' -and $u1 -match '1 MR\(s\) of me merged in 24 h tracked by no task: shop!8729 \(fix: test support root\)' -and
  $u1 -match "track add -Task 7 -Mrs 'shop!8729'" -and $u1 -match 'shop!8729 merged, no task' -and $u1 -match 'full: report' -and $u1 -notmatch 'shop!(8725|1|2|3)\b' -and $u2 -notmatch 'tracked by no task' -and $uc -eq 1)
Remove-TestKit $k
Complete-Tests
