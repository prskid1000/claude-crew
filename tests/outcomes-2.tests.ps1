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
Remove-TestKit $k
Complete-Tests
