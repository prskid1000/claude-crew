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
Remove-TestKit $k
Complete-Tests
