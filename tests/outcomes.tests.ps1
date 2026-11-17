#Requires -Version 7
<#
tests/outcomes.tests.ps1: adapters/outcomes.ps1 offline: task outcome rows, the tidy digest summary, decision patterns, standing
rules (propose, the owner's approval, auto-answers, never for deploy, revoke).
Usage: pwsh -NoProfile -File tests/outcomes.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/outcomes.ps1') + @('github', 'gitlab', 'bitbucket', 'gitea', 'azure_devops', 'tracker_clickup', 'tracker_jira', 'tracker_linear', 'tracker_youtrack', 'tracker_azure' | ForEach-Object { "skills/crafty/adapters/$_.ps1" })   # copied into every New-TestKit kit (the link tests: each host and tracker adapter)
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
& $put tasks 't3.json' @{ task = 't3'; spec = @{ kind = 'Feature' }; track = @{ mrs = @('cs!4'); created = '2026-11-02T10:00:00+00:00' }; envRuns = @(); updated = (Get-Date).ToString('o') }   # a repo with no QA'd task: the "other" bar
$null = pwsh @np $fx 'Update-KitOutcomes'
$oh = & { . $O; Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o') }) } | Out-String
$fvMiss = @([regex]::Matches($oh, "data-ft='#oc-tasks' data-fv='([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $oh -notmatch "<li data-fk='([^']* )?$([regex]::Escape($_))( [^']*)?'>" })
Expect "dashboard: every repo segment's filter value names a listed task, the other bar too ($fvMiss)" (-not $fvMiss.Count -and $oh -match 'other \(cs\) <b>1</b>')
$bDay, $cDay = '2026-11-02T10:00:00+00:00', '2026-11-04T10:00:00+00:00' | ForEach-Object { ([datetimeoffset]$_).LocalDateTime.ToString('yyyy-MM-dd') }
$ocRaw = Get-Content (TkPath $k outcomes) -Raw
Expect 'outcome rows: promoted, closed and came-back times (UTC text; the earliest of reopen, a failing run, a [Bug])' ($ocRaw -match '"task":"t1".*"doneAt":"2026-11-01T14:00:00Z","closedAt":"2026-11-04T10:00:00Z","backAt":"2026-11-02T10:00:00Z"')
Expect 'dashboard: Kit internals has the Delivery fold, a stacked bar per repo, each segment labelled, clickable, its tasks listed by repo:bucket and day' ($oh -match 'id=sec-delivery' -and $oh -match '<span class=obn>api <b>2</b></span>' -and $oh -match "aria-label='api &#183; came back: 1' data-ft='#oc-tasks' data-fv='api:back'[^>]*>1</i>" -and $oh -match "aria-label='api &#183; not tested yet: 1'" -and $oh -match "<li data-fk='api:back web:back d$cDay d$bDay'>" -and $oh -match 'id=oc-tasks class=.ftl uc.><p class=fclr hidden>')
# buckets: came back first, then not tested, then passed by fix rounds (none recorded: no wave names the task)
$bk = pwsh @np $fx "@(@{ cameBack = `$true; stage = 'passed' }, @{ stage = 'deployed' }, @{ stage = 'passed' }, @{ stage = 'passed'; agents = @('A'); localRounds = 1 }, @{ stage = 'passed'; agents = @('A'); localRounds = 2; reviewFix = 0 }, @{ stage = 'passed'; agents = @('A'); localRounds = 3; reviewFix = 2 }) | ForEach-Object { Get-KitOutcomeBucket ([pscustomobject]`$_) }"
Expect "outcome buckets: back, wait, rounds not recorded, 0, 1, 3+ ($bk)" ("$bk" -eq 'back wait rna r0 r1 r3')
# a test run's QA chip: its env runs by name (<date>-<time>-<name>), else its tasks' runs inside its window
$qa = pwsh @np $fx "`$ix = @([pscustomobject]@{ task = 'q1'; envRuns = @([pscustomobject]@{ run = '2026-11-13-210657-p4-retest'; pass = 5; fail = 1; notTested = 0; at = '2026-11-13T21:30:00' }) }, [pscustomobject]@{ task = 'q2'; envRuns = @([pscustomobject]@{ run = 'other'; pass = 2; fail = 0; notTested = 1; at = '2026-11-13T21:20:00' }, [pscustomobject]@{ run = 'old'; pass = 9; fail = 0; notTested = 0; at = '2026-11-01T10:00:00' }) })
  `$q = Get-KitRunQa ([pscustomobject]@{ qaName = 'p4-retest'; tasks = @('q2'); started = '2026-11-13T21:00:00'; at = '2026-11-13T21:40:00' }) `$ix; `"`$(`$q.pass) `$(`$q.fail) `$(`$q.nt) `$(`$q.failed -join ',') `$(`$q.untested -join ',')`""
Expect "test run QA: 7 pass 1 fail 1 not tested, q1 failed testing, q2 untested, the old run of q2 left out ($qa)" ("$qa" -eq '7 1 1 q1 q2')
# links per adapter: the git host's mr.url and the tracker's url; display text = repo!n (gitlab, azure) or repo#n, an alias named by its repo; no web URL (tracker none) = text
$lk = foreach ($c in @(@('gitlab', 'clickup', 'api!7', 'abc123', 'backend!7 https://git.example/backend/-/merge_requests/7|abc123 https://app.clickup.com/t/abc123'),
    @('github', 'jira', 'grp/backend!7', 'AB-1', 'backend#7 https://git.example/grp/backend/pull/7|AB-1 https://jira.test/browse/AB-1'),
    @('bitbucket', 'linear', 'grp/backend!7', 'AB-1', 'backend#7 https://bitbucket.org/grp/backend/pull-requests/7|AB-1 https://linear.app/acme/issue/AB-1'),
    @('gitea', 'youtrack', 'grp/backend!7', 'AB-1', 'backend#7 https://git.example/grp/backend/pulls/7|AB-1 https://yt.test/issue/AB-1'),
    @('azure', 'azure', 'org/proj/backend!7', '42', 'backend!7 https://dev.azure.com/org/proj/_git/backend/pullrequest/7|42 https://dev.azure.com/acme/web/_workitems/edit/42'),
    @('gitlab', 'github', 'https://git.example/grp/backend/-/merge_requests/8', '12', 'backend!8 https://git.example/grp/backend/-/merge_requests/8|12 https://github.com/grp/issues-repo/issues/12'),
    @('gitlab', 'gitlab', 'grp/backend!7', '12', 'backend!7 https://git.example/grp/backend/-/merge_requests/7|12 https://git.example/grp/issues-repo/-/issues/12'),
    @('gitlab', 'none', 'grp/backend!7', 't-9', 'backend!7 https://git.example/grp/backend/-/merge_requests/7|t-9 '))) {
  & $J @{ gitHostType = $c[0]; gitHost = $(if ($c[0] -notin 'bitbucket', 'azure') { 'git.example' }); repos = @(@{ name = 'backend'; aliases = @('api') }); tracker = @{ type = $c[1]; repo = 'grp/issues-repo'; org = 'acme'; project = 'web' } } (Join-Path $k 'skills/crafty/kit.local.json')
  $env:JIRA_BASE_URL = 'https://jira.test'; $env:YOUTRACK_URL = 'https://yt.test'
  $got = pwsh @np $fx "`$m = Get-KitMrLink '$($c[2])'; `$t = Get-KitTaskLink '$($c[3])'; `"`$(`$m.text) `$(`$m.url)|`$(`$t.text) `$(`$t.url)`""
  if ("$got" -ne $c[4]) { "$($c[0])/$($c[1]): $got" } }
Remove-Item (Join-Path $k 'skills/crafty/kit.local.json'), Env:JIRA_BASE_URL, Env:YOUTRACK_URL -ErrorAction SilentlyContinue
Expect "page links per git host (gitlab github bitbucket gitea azure) and tracker (clickup jira linear youtrack azure github gitlab none) ($lk)" (-not $lk)
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

# a scope ask answered with its record pick records the scope word (devy's wt commit -ScopeOk); a split pick does not; -By coordinator: a hint
$scQ = 'Review blocks MR 9 on scope. Record ONE scope word (decide record -Gate scope -Item f/CU-1-x) for the 2 test files.'
$scA = pwsh @np $O decide ask -Run r -Agent devy -Item t1 -Question $scQ -Options 'A: record the scope word for both', 'B: split them into a separate MR' | Out-String; $scId = if ($scA -match 'DECISION (\S+)') { $Matches[1] }
$scR = pwsh @np $O decide answer -Id $scId -Answer 'A' | Out-String; $scW = if ($scR -match 'SCOPE RECORDED (\S+)') { $Matches[1] }
$scC = pwsh @np $O decide check -Id $scW -Gate scope -Item f/CU-1-x | Out-String; $scWt = pwsh @np $O decide wait -Id $scId -MaxMinutes 0 | Out-String
$sbA = pwsh @np $O decide ask -Run r -Agent devy -Item t1 -Question $scQ -Options 'A: record the scope word for both', 'B: split them into a separate MR' | Out-String; $sbId = if ($sbA -match 'DECISION (\S+)') { $Matches[1] }
$sbR = pwsh @np $O decide answer -Id $sbId -Answer 'B' | Out-String
$byC = pwsh @np $O decide record -Gate scope -Item f/CU-1-x -Question q -Answer yes -Source chat -By coordinator 2>&1 | Out-String
Expect "decide answer: a scope ask's record pick records gate scope on the branch (check WORD, wait names it); a split pick records none; record -By coordinator says omit -By ($scW)" ($scW -and $scC -match '^WORD ' -and $scWt -match "scope word: wt commit -ScopeOk $scW" -and $sbR -match 'no scope word' -and $sbR -notmatch 'SCOPE RECORDED' -and $byC -match 'omit -By')
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
