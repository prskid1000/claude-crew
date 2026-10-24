#Requires -Version 7
<#
supervise.tests.ps1: bossy.ps1 supervise autonomy (board, flags, acks, run records), pause / launch / recover learn, track status lag, bugbrief args.
Usage: pwsh -NoProfile -File <kit>/tests/supervise.tests.ps1 (or tests/kit-tests.ps1 -Area supervise).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit supervise; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$bw = pwsh -NoProfile -Command ". '$O'; foreach (`$c in `$false, `$true) { Get-BugWfArgs b r B1 'T1 C1, C2, C3' 's1; s2; s3' @() `$c 'C:\k' 3>`$null | ConvertTo-Json -Compress -Depth 4 }"
Expect 'bugbrief args: sonnet for 3 checks unless -Complex, kitDir, a placeholder mandate (never a stored one)' ($bw[0] -notmatch 'complex' -and $bw[1] -match '"complex":true' -and $bw[0] -match '"kitDir":"C:/k"' -and $bw[0] -match "owner's words of this request" -and $bw[0] -notmatch 'review|roles')
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
Expect 'supervise -AutoFix: stale entries with a journal result or a finished parent leave as finished (INFO); a silent one stays WATCH; a finished run''s record closes' ((& $left 'review-PY-RET') -and (& $left 'revy-1400') -and -not (& $left 'H9') -and
  $sw -match '\[INFO\] auto-fixed: board entry review-PY-RET \(r1\) left: its workflow step has a journal result' -and $sw -match '\[INFO\] auto-fixed: board entry revy-1400 \(kit-fix\) left: every other agent of its run left' -and
  $sw -match '\[WATCH\] board entry H9 \(r2\) has no heartbeat' -and $sw -match '\[INFO\] auto-fixed: run wf_r3 finished: launch record closed' -and $lr3.completed -and $lr3.learned -match 'own|launch -Done')
# the next heartbeat: 5 on an ACT / ENV-FIX, half the base on storage / build streak / many agents, 30 idle machine, else back to the base
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
New-Journal wf_r5 @(@{ type = 'started'; agentId = 'd1'; label = 'test:A1' }, @{ type = 'result'; agentId = 'd1'; result = @{ error = 'seat lost' } }, @{ type = 'started'; agentId = 'd2'; label = 'test:A2' })
$null = pwsh @np $O launch -RunId wf_r5 -Script testy.js -ArgsJson '{"runDir":"C:/q/r5"}' 2>&1
foreach ($i in 1, 2) { $null = pwsh @np $O pause -Run r5 -Wait 0 2>&1 }
$sg = @(Get-Content (TkPath $k signals) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { "$($_.source)" -like 'stop:*' })
$s4 = @($sg | Where-Object ref -eq r4); $s5 = @($sg | Where-Object ref -eq r5)
Expect "stopped runs learn once: launch -Done x2 and pause x2 record their signals once, the report is written ($($s4.Count) $($s5.Count))" ($s4.Count -eq 2 -and @($s4 | Where-Object { $_.kind -eq 'failure' -and $_.text -match 'build:X1: boom' -and $_.skill -eq 'crafty' }).Count -and
  $s5.Count -eq 1 -and $s5[0].skill -eq 'pokey' -and $s5[0].text -eq 'test:A1: seat lost' -and $d1 -match 'learn: run r4 stopped by launch -Done - 2 signal' -and (Read-Json (Join-Path (TkPath $k waves) 'wf_r4.json')).run -eq 'wf_r4')
# worktree prune: remote branch gone + clean + idle worktreeDays -> the worktree goes, its local branch stays; uncommitted files: reported only
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
$null = Px $O supervise -AutoFix -Brief -Takeover -Session me 2>&1
$sr = Get-Content (TkPath $k supervise-report) -Raw
Expect 'supervise -AutoFix: a gone session''s QA seat + claims freed in ONE line' (@([regex]::Matches($sr, 'QA seat/claim')).Count -eq 1 -and $sr -match "freed 3 QA seat/claim file\(s\) of gone session process $($dp.Id)" -and -not @(Get-ChildItem $qs -Recurse -Filter *.json).Count -and $sr -match 'gate: \d+ running')
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
# label prefixes map to the new crew types
$nc = & { . $O; ((Get-KitLabelType 'spike'), (Get-KitLabelType 'migration-review:X1'), (Get-KitLabelType 'review:X1')) -join ','; Format-KitReport @{ agents = @(@{ type = 'rechy'; name = 'spike'; mode = 'spike' }); mem = @{ TotalGB = 8; AvailGB = 4 }; keepFree = 1 } -Agents }
Expect 'supervise: spike = rechy, migration-review = datay, their rows show' ($nc[0] -eq 'rechy,datay,revy' -and ($nc -join "`n") -match '\| 1 × rechy \| spike 1 \(spike\) \|')
# board: the same name in a live session 5 min after its beat = a parallel agent
$j3 = pwsh @np $O board join -Agent BY -Run rb | Out-String; $s3 = ($j3 -csplit 'SESSION ')[-1].Split(' ')[0]; $f3 = Join-Path (TkPath $k board) "$s3.json"
$e3 = Read-Json $f3; $e3.holderPid = $PID; $e3.holderStart = & { . (Lib); Get-KitPidStart $PID }; $e3.beat = (Get-Date).AddMinutes(-5).ToString('o'); & $J $e3 $f3
$j4 = pwsh @np $O board join -Agent BY -Run rb | Out-String; $b3 = pwsh @np $O board beat -Session $s3 | Out-String
Expect "board: a same-name agent in a live session is BY-2, no takeover ($j4)" ($j4 -match 'you are BY-2' -and $j4 -notmatch 'TAKEOVER|DUPLICATE' -and $b3 -notmatch 'TAKEN')
Remove-TestKit $k
Complete-Tests
