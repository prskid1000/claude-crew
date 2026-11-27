#Requires -Version 7
<#
outcomes-2.tests.ps1: outcome rows filled by script (outcomes.tests.ps1 is at its cap): the came-back reason (own QA checks
failed from envRuns failIds, else reopened), a [Bug] under a task never counts as its came-back, [Bug] links from runs, local
rounds from the goals doc's Rounds table; the split in the 'came back' tile, the outcomes group line and the task list.
Usage: pwsh -NoProfile -File <kit>/tests/outcomes-2.tests.ps1 (or tests/kit-tests.ps1 -Area outcomes-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/outcomes.ps1')
$k = New-TestKit outcomes2; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$fx = Join-Path $k 'fx.ps1'
Set-Content $fx "param([string]`$Code)`n. '$k/skills/crafty/lib.ps1'; . '$k/skills/bossy/adapters/outcomes.ps1'; Invoke-Expression `$Code"
$put = { param($Name, $File, $Obj) $d = TkPath $k $Name -Create; Set-Content (Join-Path $d $File) ($Obj | ConvertTo-Json -Depth 8) }
$now = (Get-Date).ToString('o'); $tr = { param($m) @{ mrs = @($m); created = '2026-11-01T10:00:00+00:00'; done = $true; doneAt = '2026-11-01T12:00:00+00:00' } }
# q1: own check F2 failed, its run raised [Bug] b7 · p1: own checks passed, a [Bug] b1 under it (owner 2026-11-26: not came back) · r1: reopened
& $put tasks 'q1.json' @{ task = 'q1'; spec = @{ kind = 'Feature' }; track = (& $tr 'api!1'); updated = $now
  envRuns = @(@{ run = 'R'; code = 'T1'; pass = 2; fail = 1; notTested = 0; failIds = @('F2'); bug = 'b7'; at = '2026-11-02T10:00:00+00:00' }) }
& $put tasks 'p1.json' @{ task = 'p1'; spec = @{ kind = 'Feature' }; track = (& $tr 'web!2'); updated = $now; envRuns = @(@{ run = 'R'; code = 'T2'; pass = 3; fail = 0; notTested = 0; failIds = @(); bug = ''; at = '2026-11-02T10:00:00+00:00' }) }
& $put tasks 'b1.json' @{ task = 'b1'; parent = 'p1'; spec = @{ kind = 'Bug' }; track = @{ mrs = @(); created = '2026-11-02T11:00:00+00:00' }; envRuns = @(); updated = $now }
& $put tasks 'r1.json' @{ task = 'r1'; spec = @{ kind = 'Feature' }; track = ((& $tr 'api!3') + @{ reopenedAt = '2026-11-03T10:00:00+00:00' }); envRuns = @(); updated = $now }
# q1's goals doc: a Rounds table of 3 rounds (no wave report names it)
$body = "# Goals`n## Rounds`n| Round | Date | Cases run | Result | Bugs found | Fix commit | Retest |`n|---|---|---|---|---|---|---|`n| 1 | d | all | FAIL | 1 | abc | - |`n| 2 | d | G2 | FAIL | 0 | def | - |`n| 3 | d | all | PASS | 0 | - | yes |`n"
& $put published 'q1_testing-ai.json' @{ key = 'q1:testing-ai'; rounds = @(@{ at = '2026-11-01 10:00'; label = ''; body = $body }) }
$null = pwsh @np $fx 'Update-KitOutcomes -All'
$rw = @{}; foreach ($r in @(Get-Content (TkPath $k outcomes) | ConvertFrom-Json)) { $rw["$($r.task)"] = $r }
Expect "outcome rows: came-back reason qa + its failing checks, [Bug] links counted ($($rw.q1.backWhy) $($rw.q1.backChecks) $($rw.q1.bugs))" ($rw.q1.cameBack -and $rw.q1.backWhy -eq 'qa' -and $rw.q1.backChecks -eq 'F2' -and $rw.q1.bugs -eq 1)
Expect "outcome rows: a [Bug] under a task whose own checks passed is no came-back; it still counts as a bug ($($rw.p1.cameBack) $($rw.p1.bugs))" (-not $rw.p1.cameBack -and $rw.p1.backWhy -eq '' -and $rw.p1.bugs -eq 1 -and -not $rw.p1.backAt)
Expect "outcome rows: reopened with no QA failure = came back, reason reopened ($($rw.r1.backWhy))" ($rw.r1.cameBack -and $rw.r1.backWhy -eq 'reopened')
Expect "outcome rows: local rounds from the goals doc's Rounds table ($($rw.q1.localRounds))" ($rw.q1.localRounds -eq 3)
$oh = & { . $O; Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o') }) } | Out-String
$sp = 'own QA checks failed 1 &#183; reopened \(MRs after promoted\) 1'
Expect 'dashboard: the came-back split in the tile, the outcomes group line, the task list (no new section)' ($oh -match "came back: [^']*$sp" -and $oh -match "came back 2 \($sp\)" -and $oh -match 'came back: own checks F2 failed' -and $oh -match 'came back: reopened')
# KPI tiles (owner 2026-11-26): after a stats reset only tasks started since it count; each tile names its n, under 5 it is greyed
& $put tasks 's1.json' @{ task = 's1'; spec = @{ kind = 'Feature' }; track = @{ mrs = @('api!9'); created = '2026-11-12T10:00:00+00:00'; done = $true; doneAt = '2026-11-12T13:00:00+00:00' }; envRuns = @(); updated = $now }
# q9: test-only (no track start, no build run): it starts at its first QA run; s1's start never moves later (its launch file ages out)
& $put tasks 'q9.json' @{ task = 'q9'; spec = @{ kind = 'Feature' }; track = @{ mrs = @() }; updated = $now; envRuns = @(@{ run = 'R'; code = 'T9'; pass = 1; fail = 0; notTested = 0; failIds = @(); bug = ''; at = '2026-11-13T10:00:00+00:00' }) }
$null = pwsh @np $fx 'Update-KitOutcomes -All'
& $put tasks 's1.json' @{ task = 's1'; spec = @{ kind = 'Feature' }; track = @{ mrs = @('api!9'); created = '2026-11-12T12:00:00+00:00'; done = $true; doneAt = '2026-11-12T13:00:00+00:00' }; envRuns = @(); updated = $now }
$null = pwsh @np $fx 'Update-KitOutcomes -All'
$ks = pwsh @np $fx '$a = Get-KitOutcomeStats; $b = Get-KitOutcomeStats -StatsFrom ([datetime]"2026-11-10"); "$($a.kpi.startOf)|$($b.kpi.startOf)|$($b.kpi.start)|$($b.tasks.Count)|$($b.kpi.backN)|$($b.kpi.firstN)|$(([datetimeoffset]($b.tasks | Where-Object id -eq s1).startAt).UtcDateTime.Hour)"'
$oh2 = & { . $O; Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o') }) } | Out-String
Expect "KPI tiles: no reset = every promoted task, after one only tasks started since (the lists keep all; a test-only task starts at its first QA run; a start never moves later); n on the tile, under 5 greyed ($ks)" ("$ks" -eq '4|1|1|6|1|1|10' -and $oh2 -match "class='tl few'" -and $oh2 -match 'QA first pass &#183; n \d' -and $oh2 -match 'n \d is under 5: too few to read')
# owner 2026-11-27: every number counts agents outside a workflow (Agent-tool spawns on the board, run with no launch record) next to
# workflow ones. sd1: a solo devy (start = its join, spend = its row), rounds from its goals doc; wf-run's devy and a QA runDir's checky
# belong to workflows (their launch records): no spend, no start, no run of their own
& $put tasks 'sd1.json' @{ task = 'sd1'; spec = @{ kind = 'Feature' }; track = @{ mrs = @('api!21'); created = '2026-11-20T20:00:00+00:00'; done = $true; doneAt = '2026-11-20T23:00:00+00:00' }; updated = $now
  envRuns = @(@{ run = 'R'; code = 'T3'; pass = 2; fail = 0; notTested = 0; failIds = @(); bug = ''; at = '2026-11-21T10:00:00+00:00' }) }
& $put published 'sd1_testing-ai.json' @{ key = 'sd1:testing-ai'; rounds = @(@{ at = '2026-11-20 12:00'; label = ''; body = $body }) }
$sdB = { param($ag, $ty, $run, $sp, $jn) & $put board "sd-$ag.json" @{ agent = $ag; type = $ty; session = "sd-$ag"; run = $run; items = 'sd1'; status = 'left'; joined = $jn; beat = (Get-Date).AddHours(-1).ToString('o'); spend = $sp; transcript = "C:\tx\$ag.jsonl" } }
& $put cache 'usage.result.json' @{ at = $now; agentSteps = @(@{ tf = 'C:/TX/devy-sd.jsonl'; label = 'devy sd'; role = 'devy'; at = $now; cx = @{ n = 2; pk = 900; s0 = 100; sum = 1000; car = @(0) * 8; add = @(0) * 8 } }, @{ tf = 'C:/tx/other.jsonl'; label = 'other'; role = 'devy'; at = $now; cx = @{ n = 1; pk = 5; s0 = 5; sum = 5; car = @(0) * 8; add = @(0) * 8 } }) }
& $sdB devy-sd devy solo-sd 4000 '2026-11-20T12:00:00+00:00'; & $sdB devy-wf devy wf-run 9000 '2026-11-19T00:00:00+00:00'; & $sdB checky-q checky qa-dir-1 700 '2026-11-19T00:00:00+00:00'
& $put launches 'self-buildy-wf-run.json' @{ script = 'C:/kit/workflows/buildy.js'; run = 'wf-run'; at = '2026-11-19T00:00:00+00:00'; spent = 0 }
& $put launches 'self-testy-qa.json' @{ script = 'C:/kit/workflows/testy.js'; run = 'qa-run'; runDir = 'C:/q/qa-dir-1'; at = '2026-11-19T00:00:00+00:00'; spent = 0 }
$null = pwsh @np $fx 'Update-KitOutcomes -All'; $sdR = @(Get-Content (TkPath $k outcomes) | ConvertFrom-Json | Where-Object task -eq 'sd1')[-1]
$sdK = & { . $O; $sdS = Get-KitOutcomeStats; $sdT = @($sdS.tasks | Where-Object id -eq sd1)[0]; $e = { param($x) "$x" }; $n1 = { param($x) "$x" }; $fold = { param($i, $t, $c, $h) $h }; $taskA = $mrA = $bar = $table = { '' }
  $sdU = Format-KitUsageHtml ([pscustomobject]@{ since = (Get-Date).AddDays(-6).ToString('o'); days = @([pscustomobject]@{ day = '2026-11-20'; tok = 1 }); runs = @() })
  "$($sdT.bucket)|$($sdT.rounds)|$($sdS.kpi.roundsOf)|$(@($sdU.boardRuns | ForEach-Object { "$($_.run):$($_.kind):$($_.spend)" }) -join ',')|$($sdU.runsN)|$(@($sdU.dayRuns['2026-11-20'] | ForEach-Object run) -join ',')" }
$sdBud = pwsh @np $O budget -Run solo-sd -Json | ConvertFrom-Json; $sdCx = @(pwsh @np $O usage -Context -Run solo-sd -Json | ConvertFrom-Json); $sdTp = Get-Content (pwsh @np $O tidy prep -DryRun -Json | ConvertFrom-Json).digest -Raw
Expect "agents outside a workflow: the row's start = the devy's join, its spend; rounds from the goals doc (r2, a KPI sample); one board run (not a workflow's devy or QA runDir), counted in Runs and runs started; budget -Run; usage -Context -Run; the tidy digest ($sdK)" ("$(@($sdCx.label) -join ',')" -eq 'devy sd' -and
  $sdR.spend -eq 4000 -and ([datetimeoffset]$sdR.startAt).UtcDateTime.ToString('yyyy-MM-ddTHH:mm') -eq '2026-11-20T12:00' -and $sdK -match '^r2\|2\|[1-9]\d*\|solo-sd:build:4000\|1 ended in 7 days\|solo-sd$' -and $sdBud.spent -eq 4000 -and $sdBud.agents -eq 1 -and -not $sdBud.workflow -and $sdTp -match 'solo-sd \(build, 1 agent\(s\), no workflow\) spent 4000')
Get-ChildItem (TkPath $k board) -Filter 'sd-*.json' | Remove-Item; Remove-Item (Join-Path (TkPath $k cache) 'usage.result.json')
# bossy.ps1 stats reset (owner 2026-11-26: DELETE, no archive): outcomes + clock stream gone, a cutoff for test checks; task files and QA runs kept
$cd = Join-Path (TkPath $k audit -Create) '2026-11-02'; $null = New-Item -ItemType Directory -Force $cd; '{"at":"2026-11-02T10:00:00Z","phase":"code"}' | Set-Content (Join-Path $cd 'clock.jsonl')
$qd = Join-Path (TkPath $k qa-runs -Create) 'testy-x/T1'; $null = New-Item -ItemType Directory -Force $qd; '{"checks":[]}' | Set-Content (Join-Path $qd 'results.json')
$dry = pwsh @np $O stats reset -DryRun | Out-String; $sr = pwsh @np $O stats reset | Out-String; $n3 = pwsh @np $fx 'Update-KitOutcomes'
Expect "stats reset: -DryRun deletes nothing; then outcomes and clock rows deleted and printed, a cutoff set, no row written back; tasks and QA runs kept ($n3)" (
  $dry -match 'would delete .*outcomes\.jsonl' -and $sr -match 'deleted .*outcomes\.jsonl' -and $sr -match 'deleted .*clock\.jsonl' -and $sr -match 'cutoff .*stats-reset' -and -not (Test-Path (TkPath $k outcomes)) -and
  -not (Test-Path (Join-Path $cd 'clock.jsonl')) -and "$n3" -eq '0' -and (Test-Path (Join-Path (TkPath $k tasks) 'q1.json')) -and (Test-Path (Join-Path $qd 'results.json')))
# 2026-11-26 (3 refusals with a word on record): a person's scope word names an item; wt commit / devtools.py ask by branch or MR, so
# the record takes the branches of the item's area (board entry -> its area's slot) and the MRs opened from them (scope log). Never: a
# denied ask, another area's MR of the same task, the worktree of an agent that left (its slot is someone else's now)
$zed = Join-Path (Kd) 'zed'; git init -q -b feat/ZED-1-other $zed; git -C $zed commit -q --allow-empty -m init
& $put board 'devy-9-a1.json' @{ agent = 'devy-9'; run = 'rs'; area = 'pay-area'; items = 'K1-fields K1-gate'; status = 'working' }
& $put board 'devy-8-a0.json' @{ agent = 'devy-8'; run = 'rs'; area = 'pay-area'; items = 'K1-fields'; status = 'left'; worktrees = @($zed) }
& $put wt-slots 'falcon-api.json' @{ slot = 'api-Falcon'; agent = 'pay-area'; branch = 'feat/PAY-9-fields-set' }
$null = pwsh @np $fx "Write-KitLog scope-log area @{ mr = 'api!41'; branch = 'feat/PAY-9-fields-set'; globs = @('src/**') }; Write-KitLog scope-log area @{ mr = 'web!7'; branch = 'feat/PAY-9-web'; globs = @('web/**') }"
$ci = { param($v) pwsh @np $O decide check -Gate scope -Item $v | Out-String }; $cm = { param($v) pwsh @np $O decide check -Gate scope -Mrs $v | Out-String }
$skA = pwsh @np $O decide ask -Gate scope -Run rs -Agent pay-area -Item K1-fields -Question 'Two files sit outside the area.' -Context 'today: the MR holds them' -Options 'A: record the scope word — they merge', 'B: split them out — a second MR' -Recommend A | Out-String
$skD = pwsh @np $O decide answer -Id $(if ($skA -match 'DECISION (\S+)') { $Matches[1] }) -Answer 'B' | Out-String; $skDeny = "$(& $ci feat/PAY-9-fields-set)$(& $cm 'api!41')"
$skR = pwsh @np $O decide record -Run rs -Gate scope -Item K1-fields -Question 'src outside the area?' -Answer yes -Source chat | Out-String
& $put board 'devy-7-z.json' @{ agent = 'devy-7'; run = 'rz'; area = 'pay-area'; items = 'Z9-x'; status = 'left' }   # a run that left: its area name is rs's now
$skZ = "$(pwsh @np $O decide record -Run rz -Gate scope -Item Z9-x -Question 'z outside?' -Answer yes -Source chat)" -replace '(?s)^.*RECORDED (\S+).*$', '$1'
$skZb = @((Get-Content (Join-Path (TkPath $k decisions) "$skZ.json") -Raw | ConvertFrom-Json).branches | Where-Object { $_ }).Count
$skB = & $ci feat/PAY-9-fields-set; $skM = & $cm 'api!41'; $skNo = "$(& $ci feat/OTHER-1-x)$(& $cm 'web!7')$(& $ci feat/ZED-1-other)"
Expect "scope word of an item: found by its area's branch and that branch's MR; a denied ask, another branch, the task's other MR, a left agent's worktree: none ($("$skB".Trim()))" (
  $skD -match 'no scope word' -and $skZb -eq 0 -and $skDeny -notmatch '(?m)^WORD ' -and $skR -match 'RECORDED' -and $skB -match '^WORD ' -and $skB -notmatch 'pin:' -and $skM -match '^WORD ' -and $skNo -notmatch '(?m)^WORD ')
# owner 2026-11-26 (board leave -Agent <id> -Force on a row supervise had left said "unknown session ''"): an agent whose rows all
# left = "already left", exit 0; -Force on a row that beats in a live session: kept, with why; -Session with -Force keeps the session
$bdir = TkPath $k board -Create; Get-ChildItem $bdir -Filter 'devy-*.json' | Remove-Item; $sesOf = { param($o) ("$o" -csplit 'SESSION ')[-1].Split(' ')[0] }
$fz = & $sesOf (pwsh @np $O board join -Agent FZ -Run rfz | Out-String); $fzKept = "$(pwsh @np $O board leave -Agent FZ -Force | Out-String)$LASTEXITCODE"
$o2Fz = Join-Path $bdir "$fz.json"; $o2Row0 = Read-Json $o2Fz; $o2Row0.status = 'left'; $o2Row0 | Add-Member -Force NoteProperty crashed (Get-Date).ToString('o'); & $J $o2Row0 $o2Fz
$fzOut = "$(pwsh @np $O board leave -Agent FZ -Force | Out-String)$LASTEXITCODE"
$fy = & $sesOf (pwsh @np $O board join -Agent FY -Run rfz | Out-String); $fyOut = pwsh @np $O board leave -Session $fy -Force | Out-String
Expect "board leave -Force: a beating row of a live session is kept (exit 1, why); a row already left (crashed) = already left, exit 0; -Session -Force leaves it ($($fzOut.Trim()) | $($fyOut.Trim()))" (
  $fzKept -match "board leave -Force: FZ \($([regex]::Escape($fz))\) beat 0 min ago in a live session: kept .*launch -Done" -and $fzKept.Trim().EndsWith('1') -and $fzOut -match "board leave: FZ already left \($([regex]::Escape($fz)), crashed, last beat \d\d:\d\d\): nothing to do" -and $fzOut.Trim().EndsWith('0') -and $fyOut -match "left \($([regex]::Escape($fy))\)")
# an area whose last report repeats a decision id (buildy.js asked it once, drops the repeat): one ACT with the id and question;
# also when a dead step was redone and when the area then ships its other MRs; not while a step of the area runs, not when the last
# report has no repeat or the decision was answered since; gone once a later run ships the area, and 24 h after the run's last write
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx-o2'
function New-O2Journal($id, [object[]]$Lines) { $d = New-Item -ItemType Directory -Force (Join-Path $env:KIT_TRANSCRIPTS "s1/subagents/workflows/$id"); $Lines | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 } | Set-Content (Join-Path $d 'journal.jsonl'); $d }
$o2St = { param($i, $l) @{ type = 'started'; agentId = $i; label = $l } }; $o2Rs = { param($i, $o2Ask, $mrs = @()) @{ type = 'result'; agentId = $i; result = @{ mrs = @($mrs); needsDecision = @($o2Ask) } } }
$o2Ask = { param($it, $id, $q) @{ item = $it; decisionId = $id; question = $q } }
$null = New-O2Journal wf_dl1 @((& $o2St p1 'build:pay'), (& $o2Rs p1 (& $o2Ask P1 dec-limit 'Limit 72 or 100?')), (& $o2St p2 'decide:pay'), @{ type = 'result'; agentId = 'p2'; result = @{} }, (& $o2St p3 'resume:pay'), (& $o2Rs p3 (& $o2Ask P1 dec-limit 'Limit: A 72 | B 100. No answer recorded.')),
  (& $o2St k1 'build:keep'), (& $o2Rs k1 (& $o2Ask K1 dec-keep 'Keep?')), (& $o2St k2 'resume:keep'), (& $o2Rs k2 @()),
  (& $o2St w1 'build:wait'), (& $o2Rs w1 (& $o2Ask W1 dec-wait 'Wait?')), (& $o2St w2 'resume:wait'), (& $o2Rs w2 (& $o2Ask W1 dec-wait 'Wait?')), (& $o2St w3 'decide:wait'), (& $o2St o1 'build:other'),
  (& $o2St x1 'build:dead'), (& $o2Rs x1 (& $o2Ask X1 dec-dead 'Dead?')), (& $o2St x2 'resume:dead'), (& $o2St x3 'resume:dead@redo'), (& $o2Rs x3 (& $o2Ask X1 dec-dead 'Dead?')),
  (& $o2St y1 'build:shipd'), (& $o2Rs y1 (& $o2Ask Y1 dec-ship 'Ship?')), (& $o2St y2 'resume:shipd'), (& $o2Rs y2 (& $o2Ask Y1 dec-ship 'Ship?')), (& $o2St y3 'ship:shipd'), (& $o2Rs y3 @() @(@{ url = 'https://h/g/api/-/merge_requests/6'; merged = $true })),
  (& $o2St z1 'build:ans'), (& $o2Rs z1 (& $o2Ask Z1 dec-ans 'Ans?')), (& $o2St z2 'resume:ans'), (& $o2Rs z2 (& $o2Ask Z1 dec-ans 'Ans?')))
& $put decisions 'dec-ans.json' @{ id = 'dec-ans'; status = 'answered'; answer = 'A'; at = $now; answeredAt = (Get-Date).AddMinutes(5).ToString('o') }
$dlFlags = { @((pwsh @np $O supervise -Json | Out-String | ConvertFrom-Json).flags | Where-Object { "$($_.what)" -match 'ended on decision' } | ForEach-Object { "[$($_.level)] $($_.what) -> $($_.action)" }) }
$dl1 = @(& $dlFlags); Start-Sleep -Milliseconds 1100
$null = New-O2Journal wf_dl2 @((& $o2St q1 'resume:pay'), (& $o2Rs q1 @() @(@{ url = 'https://h/g/api/-/merge_requests/5'; merged = $true })), (& $o2St q2 'build:more'))
$dl2 = @(& $dlFlags); Get-ChildItem (Join-Path $env:KIT_TRANSCRIPTS 's1/subagents/workflows/wf_dl1') | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-25) }; $dl3 = @(& $dlFlags)
Expect "supervise: an area ended on a decision it reported twice = one ACT naming the id and the question; a redone dead step and a later ship still flag; a running, a settled and an answered area: none; gone once a later run ships the area, all gone 24 h after the last write ($($dl1 -join ' // ') | $($dl2.Count) $($dl3.Count))" (
  $dl1.Count -eq 3 -and @($dl1 -match '^\[ACT\] area pay of run wf_dl1 ended on decision dec-limit, reported 2 times \(P1\): Limit: A 72 \| B 100\. No answer recorded\. -> .*decide answer -Id dec-limit').Count -eq 1 -and
  @($dl1 -match 'area dead of run wf_dl1 ended on decision dec-dead').Count -eq 1 -and @($dl1 -match 'area shipd of run wf_dl1 ended on decision dec-ship').Count -eq 1 -and $dl2.Count -eq 2 -and -not ($dl2 -match 'area pay ') -and $dl3.Count -eq 0)
# launch -Done: the closed run's rows (its run name, its run folder's name) are left and their leases released; kept: a row that
# joined or beat after the run's last write (a one-off agent under the run's name), a name a live launch also uses, another run, the
# coordinator. A run its journal closed (Invoke-KitHooks Close-KitFinishedRuns): rows only, past their beat window
$hsO2 = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); $ldir = TkPath $k launches -Create; $o2Ago = { param($m) (Get-Date).AddMinutes(-$m).ToString('o') }
$o2Dn = New-O2Journal wf_dn1 @((& $o2St d1 'test:T1')); (Get-Item (Join-Path $o2Dn 'journal.jsonl')).LastWriteTime = (Get-Date).AddMinutes(-30)
& $J @{ runId = 'wf_dn1'; script = 'C:/kit/workflows/testy.js'; args = @{ run = 'rdn-shared'; runDir = 'C:/q/rdn-2' }; at = (& $o2Ago 90) } (Join-Path $ldir 'wf_dn1.json')
& $J @{ runId = 'wf_dn9'; script = 'C:/kit/workflows/testy.js'; args = @{ run = 'rdn-shared' }; at = (& $o2Ago 20); holderPid = $PID; holderStart = $hsO2 } (Join-Path $ldir 'wf_dn9.json')
$o2Row = { param($ag, $run, $joinedMin, $type = 'checky', $beatMin = 1) & $J @{ session = "s-$ag"; agent = $ag; run = $run; type = $type; status = 'working'; beat = (& $o2Ago $beatMin); joined = (& $o2Ago $joinedMin); holderPid = $PID; holderStart = $hsO2 } (Join-Path $bdir "s-$ag.json") }
& $o2Row DN1 rdn-2 60 checky 45; & $o2Row DN2 rdn-shared 60 checky 45; & $o2Row DN3 rdn-other 60 checky 45; & $o2Row DN4 rdn-2 60 coordinator 45; & $o2Row DN5 rdn-2 5; & $o2Row DN6 rdn-2 60
& $o2Row RF1 rfin 60 checky 45; & $o2Row RF2 rfin 60; & $J @{ script = 'C:/kit/workflows/testy.js'; run = 'rfin'; at = (& $o2Ago 90); completed = (& $o2Ago 3) } (Join-Path $ldir 'self-testy-rfin-0a0a0a0a.json')
& $J @{ leases = @(@{ holder = 'DN1'; kind = 'vision'; pid = $PID; pidStart = $hsO2 }, @{ holder = 'DN5'; kind = 'vision'; pid = $PID; pidStart = $hsO2 }, @{ holder = 'DN6'; kind = 'vision'; pid = $PID; pidStart = $hsO2 }, @{ holder = 'RF1'; kind = 'vision'; pid = $PID; pidStart = $hsO2 }) } (Join-Path (TkPath $k runtimes -Create) 'gpu.json')
$dnOut = pwsh @np $O launch -Done -RunId wf_dn1 *>&1 | Out-String; $rfOut = pwsh -NoProfile -Command ". '$O'; Invoke-KitHooks Close-KitFinishedRuns" | Out-String; $rf1 = Read-Json (Join-Path $bdir 's-RF1.json')
$dnSt = @('DN1', 'DN2', 'DN3', 'DN4', 'DN5', 'DN6', 'RF1', 'RF2' | ForEach-Object { "$_=$((Read-Json (Join-Path $bdir "s-$_.json")).status)" }) -join ' '; $dn1 = Read-Json (Join-Path $bdir 's-DN1.json')
$dnGpu = @((Read-Json (Join-Path (TkPath $k runtimes) 'gpu.json')).leases | ForEach-Object holder) -join ','
Expect "launch -Done: the run's quiet row left (closedBy), its lease released; a later row, a row that still beats, a live launch's name, another run and the coordinator kept; a journal-closed run: its quiet row left, lease kept, no output ($dnSt | gpu $dnGpu | $(@($dnOut -split "`n" | Where-Object { $_ -match 'board:' }) -join ''))" (
  $dnSt -eq 'DN1=left DN2=working DN3=working DN4=working DN5=working DN6=working RF1=left RF2=working' -and $dn1.closedBy -eq 'launch -Done' -and $dn1.finished -and $dnGpu -eq 'DN5,DN6,RF1' -and $rf1.closedBy -eq 'run finished' -and -not "$rfOut".Trim() -and $dnOut -match '\[launch\] board: 1 row\(s\) of the closed run left \(DN1 \[rdn-2\]\)' -and (Read-Json (Join-Path $ldir 'wf_dn1.json')).completed)
# launch -Self SUM covers the task lines: buildy.js recOk takes the real output, refuses it without its TASKS line or with one re-worded
$sumArgs = Join-Path (Kd) 'sum-args.json'; [IO.File]::WriteAllText($sumArgs, '{"brief":"C:/b/sum.md","agents":[{"id":"s1","items":"S1","task":"zz9sum1"}]}')
$sumOut = (pwsh @np $O launch -Self -Script buildy.js -Run sum-run -ArgsFile $sumArgs -Plan 'devy/sonnet:1' | Out-String) -replace "`r", ''
$sumFmt = pwsh -NoProfile -Command ". '$O'; `$l = Format-KitLaunchLines @(`"TASKS REFUSED t1: lacks `u{2014} Items  ``nnext line`", 'AREA TASK a1 T1 https://t/T1', '', 'note'); `"`$(`$l.Count)|`$(`$l[0])|`$(Get-KitLaunchSum (@('CONFIG {}') + `$l))|`$(Get-KitFnv `"CONFIG {}``nTASKS REFUSED t1: lacks ? Items``nAREA TASK a1 T1 https://t/T1`")`""
$sumT = (pwsh @np $O launch -Self -Script testy.js -Run sum-t -ArgsFile $sumArgs -Plan 'checky/sonnet:1' | Out-String) -replace "`r", ''
$sumJs = Join-Path (Kd) 'sum-check.mjs'; $sumIn = Join-Path (Kd) 'sum-out.txt'; [IO.File]::WriteAllText($sumIn, $sumOut); [IO.File]::WriteAllText("$sumIn.t", $sumT)
Set-Content $sumJs @'
import { readFileSync } from 'node:fs'
const src = (f) => readFileSync(f, 'utf8'), pick = (s, rx) => (rx.exec(s) || [''])[0]
for (const [name, f, plan, out] of [['buildy', process.argv[2], undefined, src(process.argv[4])], ['testy', process.argv[3], 'p', src(process.argv[4] + '.t')]]) {
 const s = src(f), recOk = new Function(`${pick(s, /^(function fnv\(s\)|const fnv = ).*$/m)}\n${pick(s, /^const jl = .*$/m)}\n${pick(s, /^const recOk = .*$/m)}\nreturn recOk`)()
 console.log(`${name}:${recOk(out, plan)}:${recOk(out.replace(/^TASKS .*\n/m, ''), plan)}:${recOk(out.replace(/^TASKS UNKNOWN/m, 'TASKS  UNKNOWN'), plan)}`)
}
'@
$sumRes = @(node $sumJs (Join-Path $src 'workflows/buildy.js') (Join-Path $src 'workflows/testy.js') $sumIn 2>&1) -join ' '
Expect "launch -Self SUM: its TASKS / AREA TASK lines are in the hash (one line each, ASCII); buildy.js refuses a dropped or re-worded task line; testy.js (no task lines) reads its own ($sumRes | $sumFmt | $(@($sumOut -split "`n" | Where-Object { $_ -match '^(TASKS|SUM)' }) -join ' / '))" (
  $sumOut -match '(?m)^TASKS UNKNOWN' -and $sumRes -match 'buildy:true:false:false testy:true' -and $sumFmt -match '^4\|TASKS REFUSED t1: lacks \? Items\|SUM (\w{8})\|\1$')
Remove-TestKit $k
Complete-Tests
