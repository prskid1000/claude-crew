#Requires -Version 7
<#
tests/outcomes.tests.ps1: adapters/outcomes.ps1 offline: task outcome rows, the tidy digest summary, decision patterns, standing
rules (propose, the owner's approval, auto-answers, never for deploy, revoke).
Usage: pwsh -NoProfile -File tests/outcomes.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/outcomes.ps1')   # copied into every New-TestKit kit
$k = New-TestKit outcomes; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$fx = Join-Path $k 'fx.ps1'   # runs adapter functions on the test kit
Set-Content $fx "param([string]`$Code)`n. '$k/skills/crafty/lib.ps1'; . '$k/skills/bossy/adapters/outcomes.ps1'; Invoke-Expression `$Code"
$put = { param($Name, $File, $Obj) $d = TkPath $k $Name -Create; Set-Content (Join-Path $d $File) ($Obj | ConvertTo-Json -Depth 8) }

# outcome rows: QA failed then passed + reopened (came back), a wave's rounds, a run's spend
& $put tasks 't1.json' @{ task = 't1'; spec = @{ kind = 'Feature' }; track = @{ mrs = @('api!1', 'web!2'); created = '2026-11-01T10:00:00+00:00'; done = $true; doneAt = '2026-11-01T14:00:00+00:00'; reopenedAt = '2026-11-03T10:00:00+00:00' }
  envRuns = @(@{ env = 'test'; pass = 3; fail = 1; notTested = 0; at = '2026-11-02T10:00:00+00:00' }, @{ env = 'test'; pass = 4; fail = 0; notTested = 0; at = '2026-11-04T10:00:00+00:00' }); updated = (Get-Date).ToString('o') }
& $put tasks 't2.json' @{ task = 't2'; parent = 't1'; spec = @{ kind = 'Bug' }; track = @{ mrs = @('api!3'); created = '2026-11-02T10:00:00+00:00'; done = $true; doneAt = '2026-11-02T11:00:00+00:00' }; envRuns = @(); updated = (Get-Date).ToString('o') }
& $put waves 'wf_1.json' @{ run = 'wf_1'; at = (Get-Date).ToString('o'); agents = @{ A1 = @{ done = @('t1'); localRounds = 3; fixedRound = $true; deferred = @(@{ id = 't1:x'; kind = 'code'; reason = 'local loop refused: lane busy behind another lease holder' }) }
    A2 = @{ done = @('t2'); localRounds = 1; fixedRound = $false; deferred = @(@{ id = 't2:x'; kind = 'code'; reason = 'local loop refused: lane busy behind another holder lease' }) } } }
& $put launches 'self-buildy-r1.json' @{ run = 'r1'; script = 'buildy.js'; spent = 1000; argsRaw = '{"tasks":["t1","t2"]}' }
$n1 = pwsh @np $fx 'Update-KitOutcomes -All'; $n2 = pwsh @np $fx 'Update-KitOutcomes'
$rows = @(Get-Content (TkPath $k outcomes) | ConvertFrom-Json); $r1 = $rows | Where-Object task -eq 't1'
Expect 'outcomes: one row per task, a second sweep with no change writes none' ("$n1" -eq '2' -and "$n2" -eq '0' -and $rows.Count -eq 2)
Expect 'outcomes: first pass, came back, rounds, a [Bug] under it, spend split, hours' (-not $r1.qaFirstPass -and $r1.cameBack -and $r1.stage -eq 'passed' -and $r1.localRounds -eq 3 -and $r1.reviewFix -eq 1 -and $r1.bugs -eq 1 -and $r1.spend -eq 500 -and $r1.hPromoted -eq 4 -and $r1.area -eq 'api,web')
$lines = pwsh @np $fx 'Get-KitOutcomeLines' | Out-String
Expect 'outcomes summary: totals, worst area, agent rounds, a repeat cause' ($lines -match 'QA first pass 0/1, came back 1' -and $lines -match 'area api: 2 task\(s\)' -and $lines -match 'agent A1: 3 fix round' -and $lines -match 'cause 2x: local loop refused')
$oh = & { . $O; Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o') }) } | Out-String
Expect 'dashboard: Kit internals has the Outcomes fold, one labelled first-pass bar per area' ($oh -match 'id=sec-outcomes' -and $oh -match "aria-label='first pass 0/1'" -and $oh -match 'api: 2 task\(s\)')
Remove-Item (Join-Path (TkPath $k waves) 'wf_1.json'); (Get-Item (Join-Path (TkPath $k tasks) 't2.json')).LastWriteTime = (Get-Date).AddMinutes(1)
$n3 = pwsh @np $fx 'Update-KitOutcomes'
Expect 'outcomes: an aged-out wave report never shrinks the rounds (no new row)' ("$n3" -eq '0')

# decision patterns: one topic, the same owner choice 3x
$log = TkPath $k decisions-log -Create
$dl = { param($id, $q, $a, $gate = '', $by = 'owner') ([ordered]@{ at = (Get-Date).ToString('o'); event = 'answered'; id = $id; kind = 'decision'; gate = $gate; question = $q; answer = $a; by = $by; status = 'answered' } | ConvertTo-Json -Compress) }
Set-Content $log @(
  (& $dl 'd-1' 'X-1: on create, replay sends for earlier slots?' 'NO REPLAY (first send is the next slot)' 'scope'),
  (& $dl 'd-2' 'X-2 (HM): on edit, replay sends for earlier slots?' 'B: no replay (Recommended)' 'scope'),
  (& $dl 'd-3' 'X-3: on re-activate, replay sends for earlier slots?' 'No replay' 'scope'),
  (& $dl 'd-4' 'X-4: on re-activate, replay sends for earlier slots?' 'No replay' 'scope' 'coordinator'),
  (& $dl 'd-5' 'Deploy the api to staging now?' 'yes deploy' 'deploy'), (& $dl 'd-6' 'Deploy the api to staging tonight?' 'yes deploy' 'deploy'), (& $dl 'd-7' 'Deploy the api to staging again?' 'yes deploy' 'deploy'))
$pat = @(pwsh @np $fx 'Get-KitDecisionPatterns | ConvertTo-Json -Depth 4 -Compress' | ConvertFrom-Json)
$pr = $pat | Where-Object gate -eq 'scope'; $pd = $pat | Where-Object gate -eq 'deploy'
Expect 'patterns: 3 owner answers -> one proposal (an agent answer does not count); deploy -> guidance only' ($pat.Count -eq 2 -and @($pr.evidence).Count -eq 3 -and 'd-4' -notin $pr.evidence -and $pr.auto -and -not $pd.auto)
Add-Content $log (& $dl 'd-8' 'X-5: on create, replay sends for earlier slots?' 'Yes, replay every missed slot' 'scope')
$pat2 = @(pwsh @np $fx 'Get-KitDecisionPatterns | ConvertTo-Json -Depth 4 -Compress' | ConvertFrom-Json)
Expect 'patterns: one contrary answer -> no proposal for that topic' (-not @($pat2 | Where-Object gate -eq 'scope').Count)
Set-Content $log @(Get-Content $log | Select-Object -SkipLast 1)
$cw = pwsh @np $fx '"$(Test-KitSameChoice (Get-KitChoiceWords ''Replay'') (Get-KitChoiceWords "B: Don''t replay"))|$(Test-KitSameChoice (Get-KitChoiceWords ''Keep both'') (Get-KitChoiceWords ''Cannot keep both''))|$(Test-KitRuleSensitive '''' ''Delete the old tenant rows?'')|$(Test-KitRuleSensitive '''' ''Show the user-visible copy?'')"'
Expect 'choices: a contraction is a no; sensitive: delete, tenant, user-visible asks never auto' ("$cw" -eq 'False|False|True|True')

# standing rules: one ask, the owner's A, auto-answers (never deploy), a gate check refuses it, revoke
$po = pwsh @np $O decide rules -Propose | Out-String
$askId = if ($po -match 'ask (d-\S+)') { $Matches[1] }
Expect 'decide rules -Propose: two proposals, one pending ask' ($po -match 'PROPOSED 2 standing rule' -and $askId -and (pwsh @np $O decide list -Pending | Out-String) -match 'standing-rules')
$null = pwsh @np $O decide answer -Id $askId -Answer 'approve all except the deploy one'
$rx = pwsh @np $O decide rules | Out-String
Expect 'an unclear pick ("except") approves nothing; the rules wait for the next ask' ($rx -notmatch 'APPROVED' -and ([regex]::Matches($rx, 'PROPOSED')).Count -eq 2)
$po2 = pwsh @np $O decide rules -Propose | Out-String; $askId2 = if ($po2 -match 'ask (d-\S+)') { $Matches[1] }
$null = pwsh @np $O decide answer -Id $askId2 -Answer 'A: approve all'
$md = Join-Path $k 'rules/standing-rules.local.md'; $rl = pwsh @np $O decide rules | Out-String
Expect 'owner A -> approved (date, by), rules/standing-rules.local.md written, deploy one marked guidance' ((Test-Path $md) -and (Get-Content $md -Raw) -match 'guidance: never auto-answered' -and (Get-Content $md -Raw) -match 'approved \d{4}-\d\d-\d\d by owner' -and ([regex]::Matches($rl, 'APPROVED')).Count -eq 2)
$aa = pwsh @np $O decide ask -Run r -Agent devy -Item t9 -Gate scope -Question 'Replay sends for earlier slots on re-activate?' -Options 'A: Replay — send missed', 'B: No replay — next slot only' | Out-String
$aid = if ($aa -match 'DECISION (\S+)') { $Matches[1] }
Expect 'decide ask matching an approved rule -> answered by it, option B, logged' ($aa -match 'ANSWERED by standing rule sr-' -and $aa -match 'B: No replay' -and (pwsh @np $O decide wait -Id $aid -MaxMinutes 0 | Out-String) -match '^ANSWERED')
$ck = pwsh @np $O decide check -Id $aid -Gate scope -Item t9 | Out-String
Expect 'decide check: a standing rule answer is no person''s word' ($ck -match 'NO-WORD' -and $ck -match 'no person')
$dd = pwsh @np $O decide ask -Run r -Agent opsy -Item staging -Gate deploy -Question 'Deploy the api to staging now?' -Options 'A: yes deploy', 'B: wait' | Out-String
Expect 'decide ask on a deploy gate: never auto-answered' ($dd -match 'pending' -and $dd -notmatch 'standing rule')
$sid = if ($rl -match 'APPROVED (sr-\w+) \[scope\]') { $Matches[1] }
$null = pwsh @np $O decide rules -Revoke $sid
$a2 = pwsh @np $O decide ask -Run r -Agent devy -Item t9 -Gate scope -Question 'Replay sends for earlier slots on create?' -Options 'A: Replay', 'B: No replay' | Out-String
Expect 'decide rules -Revoke: the rule stops answering; the rules file keeps only the deploy guidance' ($a2 -match 'pending' -and (Get-Content $md -Raw) -notmatch [regex]::Escape($sid))

# tidy prep: the digest carries the outcomes section
$tp = pwsh @np $O tidy prep -DryRun -Json | ConvertFrom-Json
Expect 'tidy prep: digest has the Outcomes section' ((Get-Content $tp.digest -Raw) -match '## Outcomes, 30 days')
Remove-TestKit $k
Complete-Tests
