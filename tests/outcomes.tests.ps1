#Requires -Version 7
<#
tests/outcomes.tests.ps1: adapters/outcomes.ps1 offline: task outcome rows, the tidy digest summary, decision patterns, standing
rules (propose, the owner's approval, auto-answers, never for deploy, revoke); the stats-reset cutoff of the page's charts; the
token, cost and time split (adapters/usage.ps1 split: prices per type, transcript time, split cells, runs band).
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
Expect "dashboard: every repo segment's filter value names a listed task; one untested repo shows by its name, never 'other (x)' ($fvMiss)" (-not $fvMiss.Count -and $oh -match '<span class=obn>cs <b>1</b>' -and $oh -notmatch 'other \(cs\)')
$bDay, $cDay = '2026-11-02T10:00:00+00:00', '2026-11-04T10:00:00+00:00' | ForEach-Object { ([datetimeoffset]$_).LocalDateTime.ToString('yyyy-MM-dd') }
$ocRaw = Get-Content (TkPath $k outcomes) -Raw
Expect 'outcome rows: promoted, closed and came-back times (UTC text; the earliest of reopen, a failing run, a [Bug])' ($ocRaw -match '"task":"t1".*"doneAt":"2026-11-01T14:00:00Z","closedAt":"2026-11-04T10:00:00Z","backAt":"2026-11-02T10:00:00Z"')
Expect 'dashboard: Trends has the stacked bar per repo, each segment labelled, clickable, its tasks listed by repo:bucket and day' ($oh -match 'id=sec-trends' -and $oh -match '<span class=obn>api <b>2</b></span>' -and $oh -match "aria-label='api &#183; came back: 1' data-ft='#oc-tasks' data-fv='api:back'[^>]*>1</i>" -and $oh -match "aria-label='api &#183; not tested yet: 1'" -and $oh -match "<li data-fk='api:back web:back dc$cDay db$bDay'>" -and $oh -match 'id=oc-tasks class=.ftl uc.><p class=fclr hidden>')
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
$sbA = pwsh @np $O decide ask -Run r -Agent devy -Item t1 -Question $scQ -Options 'A: split them into a separate MR', 'B: do not record the scope word' | Out-String; $sbId = if ($sbA -match 'DECISION (\S+)') { $Matches[1] }
$sbR = pwsh @np $O decide answer -Id $sbId -Answer 'B' | Out-String
$byC = pwsh @np $O decide record -Gate scope -Item f/CU-1-x -Question q -Answer yes -Source chat -By coordinator 2>&1 | Out-String
Expect "decide answer: a scope ask's record pick records gate scope on the branch (check WORD, wait names it); a split pick records none; record -By coordinator says omit -By ($scW)" ($scW -and $scC -match '^WORD ' -and $scWt -match "scope word: wt commit -ScopeOk $scW" -and $sbR -match 'no scope word' -and $sbR -notmatch 'SCOPE RECORDED' -and $byC -match 'omit -By')
# buildy NONE word: -Gate a,b = the record's gate is one of them; -Item a,b = any of them, or the record's MR (2026-11-21: only the id's shape was checked)
$lg = @(@('merge,scope,other', 'X9,f/CU-1-x'), @('merge,other', 'f/CU-1-x'), @('merge,scope,other', 'X9,Y8')) | ForEach-Object { "$(pwsh @np $O decide check -Id $scW -Gate $_[0] -Item $_[1])"[0..1] -join '' }
$lmId = if ((pwsh @np $O decide record -Gate merge -Item t9 -Mrs 'api!7' -Question q -Answer yes -Source chat | Out-String) -match 'RECORDED (\S+)') { $Matches[1] }
$lm = @('N1,api!7', 'api!7') | ForEach-Object { pwsh @np $O decide check -Id $lmId -Gate 'merge,scope,other' -Item $_ | Out-String }
Expect "decide check lists: gate one of -Gate, item any of -Item or the record's MR ($($lg -join ' '))" ("$lg" -eq 'WO NO NO' -and @($lm -match '^WORD ').Count -eq 2)
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
Expect 'decide check: a standing rule answer is no person''s word' ($ck -match 'NO-WORD' -and $ck -match 'no person' -and $ck -match 'never an open option')   # retro 2205: NO-WORD names what to do meanwhile
$dd = pwsh @np $O decide ask -Run r -Agent opsy -Item staging -Gate deploy -Question 'Deploy the api to staging now?' -Options 'A: yes deploy', 'B: wait' | Out-String
Expect 'decide ask on a deploy gate: never auto-answered' ($dd -match 'pending' -and $dd -notmatch 'standing rule')
$sid = if ($rl -match 'APPROVED (sr-\w+) \[scope\]') { $Matches[1] }
$null = pwsh @np $O decide rules -Revoke $sid
$a2 = pwsh @np $O decide ask -Run r -Agent devy -Item t9 -Gate scope -Question 'Replay sends for earlier slots on create?' -Options 'A: Replay', 'B: No replay' | Out-String
Expect 'decide rules -Revoke: the rule stops answering; the rules file keeps only the deploy guidance' ($a2 -match 'pending' -and (Get-Content $md -Raw) -notmatch [regex]::Escape($sid))

# tidy prep: the digest carries the outcomes section
$tp = pwsh @np $O tidy prep -DryRun -Json | ConvertFrom-Json
Expect 'tidy prep: digest has the Outcomes section' ((Get-Content $tp.digest -Raw) -match '## Outcomes, 30 days')
# stats reset (owner 2026-11-20): the newest forgotten/stats-reset-<day> folder creation time (not its midnight) cuts what the charts read from kept logs; a wait across it is clipped
$cutT = & { . $O; $n = (Get-Date).Date.AddHours(12); $y = $n.Date.AddDays(-1); $fgDir = Get-KitPath forgotten -Create
  $cutDirs = @((Join-Path $fgDir "stats-reset-$($n.AddDays(-3).ToString('yyyyMMdd'))"), (Join-Path $fgDir "stats-reset-$($n.ToString('yyyyMMdd'))-101500")); foreach ($cd in $cutDirs) { $null = New-Item -ItemType Directory -Force $cd }; (Get-Item $cutDirs[0]).CreationTime = $n.AddDays(-3).Date; (Get-Item $cutDirs[1]).CreationTime = $n.Date
  $sCut = Get-KitStatsCutoff; $yDir = Join-Path (Get-KitPath audit) $y.ToString('yyyy-MM-dd'); $yNew = -not (Test-Path $yDir); $null = New-Item -ItemType Directory -Force $yDir
  $yBuilds = Join-Path $yDir 'builds.jsonl'; $yCalls = Join-Path $yDir 'calls.jsonl'
  @(@{ at = $y.AddHours(20).ToString('o'); event = 'start'; owner = 'old'; waitSec = 600 }, @{ at = $n.Date.AddMinutes(10).ToString('o'); event = 'start'; owner = 'mid'; waitSec = 1200 }, @{ at = $y.AddHours(20).ToString('o'); event = 'end'; kind = 'maven'; owner = 'old'; sec = 60; waitSec = 0; code = 0 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $yBuilds
  @(@{ at = $y.AddHours(9).ToString('s'); verb = 'board leave'; event = 'start'; pid = 7; args = '-Agent A -Status failed' }, @{ at = $y.AddHours(9).ToString('s'); verb = 'board leave'; event = 'end'; pid = 7; rc = 0 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $yCalls
  $qaRes = Join-Path (New-Item -ItemType Directory -Force (Join-Path (Get-KitPath qa-runs) 'cutq/T1')) 'results.json'; @{ checks = @(@{ result = 'PASS' }) } | ConvertTo-Json -Depth 4 | Set-Content $qaRes; (Get-Item $qaRes).LastWriteTime = $y.AddHours(20)
  $gr = { param($g) @($g.rows | Where-Object name -eq 'maven build').Count }; $wr = { param($w) $b = @($w.rows | Where-Object name -eq 'build gate')[0]; "$($b.n)/$([math]::Round($b.min))" }; $qr = { param($q) @($q.days | Where-Object { @($_.runs).run -contains 'cutq' }).Count }
  $dr = { param($ds) "$(@($ds | Where-Object day -eq $y.ToString('yyyy-MM-dd'))[0].failed)" }
  $uIn = [pscustomobject]@{ runs = @([pscustomobject]@{ id = 'a'; status = 'ended'; at = $y.AddHours(20).ToString('o'); steps = @([pscustomobject]@{ result = 'fail' }) }, [pscustomobject]@{ id = 'b'; status = 'ended'; at = $n.ToString('o'); steps = @([pscustomobject]@{ result = 'pass' }) }, [pscustomobject]@{ id = 'c'; status = 'running'; at = $y.ToString('o'); steps = @() }, [pscustomobject]@{ id = 'd'; status = 'ended'; started = $y.AddHours(23).ToString('o'); at = $n.ToString('o'); steps = @() })
    days = @([pscustomobject]@{ day = $y.ToString('yyyy-MM-dd'); tok = 5; cost = 1 }, [pscustomobject]@{ day = $n.ToString('yyyy-MM-dd'); tok = 7; cost = 2 }); mrList = @([pscustomobject]@{ ref = 'w!1'; day = $y.ToString('yyyy-MM-dd') }, [pscustomobject]@{ ref = 'w!2'; day = $n.ToString('yyyy-MM-dd') })
    merged = [pscustomobject]@{ source = 'host'; user = 'u'; n = 2 }; rates = [pscustomobject]@{ n = 2; fail = 1 } }
  $uCut = Select-KitUsageSince $uIn $sCut
  "$($sCut -eq $n.Date)|$(& $gr (Get-KitGateStats $n @()))$(& $gr (Get-KitGateStats $n @() -StatsFrom $sCut))|$(& $wr (Get-KitLeaseWaits $n)) $(& $wr (Get-KitLeaseWaits $n -StatsFrom $sCut))|$(& $qr (Get-KitQaDays $n)) $(& $qr (Get-KitQaDays $n -StatsFrom $sCut))|$(& $dr (Get-KitSuperviseDays $null $n 3))-$(& $dr (Get-KitSuperviseDays $null $n 3 -StatsFrom $sCut))|" +
    "$(@($uCut.runs.id) -join ',') $(@($uCut.days | ForEach-Object { "$($_.tok)" }) -join ',') $(@($uCut.mrList).Count)$($uCut.merged.n) $($uCut.rates.n)$($uCut.rates.fail) $([object]::ReferenceEquals((Select-KitUsageSince $uIn ([datetime]::MinValue)), $uIn)) $(@($uIn.runs).Count)" + "|$((Get-Item $cutDirs[1]).CreationTime = $n.Date.AddMinutes(615); (Get-KitStatsCutoff) -eq $n.Date.AddMinutes(615))"
  foreach ($cutF in @($yBuilds, $yCalls, $qaRes)) { Remove-Item -LiteralPath $cutF }; Remove-Item -LiteralPath (Split-Path $qaRes) -Recurse; Remove-Item -LiteralPath (Join-Path (Get-KitPath qa-runs) 'cutq'); foreach ($cd in $cutDirs) { Remove-Item -LiteralPath $cd }; if ($yNew) { Remove-Item -LiteralPath $yDir } }
Expect "stats reset: the newest stats-reset-<day> = cutoff; gate, waits (one clipped), QA, agents failed per day and usage (runs, day values, MRs, step outcomes) drop what came before it ($cutT)" ($cutT -eq 'True|10|2/30 1/10|1 0|1-|b,c ,7 11 10 True 4|True')
# split (owner 2026-11-20): cost per type (5-min vs 1-h writes), the time split from transcript gaps (gate queue = waiting), hourly tokens
$spc = & { . $O; $cs = Get-KitUsageCostSplit @(100, 10, 1000, 200, 50) 'claude-opus-5-5'
  "$(@($cs | ForEach-Object { [math]::Round($_, 6) }) -join '/') $([math]::Round((Get-KitUsageCost @(100, 10, 1000, 200, 50) 'claude-opus-5-5'), 6)) $($null -eq (Get-KitUsageCostSplit @(1, 1, 1, 0, 0) 'mystery-1'))" }
Expect "split cost: opus in/out/cache read/cache write (150 at 5-min 1.25x + 50 at 1-h 2x in), the total = their sum, an unknown model unpriced ($spc)" ($spc -eq '0.0004/0.0002/0.0002/0.00115 0.00195 True')
$spt = & { . $O; $tx = Join-Path $k 'split-tx.jsonl'; $t00 = [datetimeoffset]::Now.AddMinutes(-40); $ts = { param([int]$s) $t00.AddSeconds($s).ToString('o') }   # inside the 8-day hour window
  $use = { param($outN) """usage"":{""input_tokens"":100,""output_tokens"":$outN,""cache_read_input_tokens"":1000,""cache_creation_input_tokens"":200,""cache_creation"":{""ephemeral_5m_input_tokens"":150,""ephemeral_1h_input_tokens"":50}}" }
  @("{""type"":""user"",""message"":{""role"":""user"",""content"":""go""},""timestamp"":""$(& $ts 0)""}",
    "{""message"":{""model"":""claude-opus-5-5"",""id"":""msg_1"",""role"":""assistant"",""content"":[{""type"":""tool_use"",""id"":""t1"",""name"":""Bash"",""input"":{""command"":""pwsh crafty.ps1 check -Dir x""}}],$(& $use 10)},""type"":""assistant"",""timestamp"":""$(& $ts 10)""}",
    "{""type"":""user"",""message"":{""role"":""user"",""content"":[{""tool_use_id"":""t1"",""type"":""tool_result"",""content"":""[gate] starting: 9 GB available; queued 20 s\nok""}]},""timestamp"":""$(& $ts 70)""}",
    "{""message"":{""model"":""claude-opus-5-5"",""id"":""msg_2"",""role"":""assistant"",""content"":[{""type"":""text"",""text"":""done""}],$(& $use 5)},""type"":""assistant"",""timestamp"":""$(& $ts 80)""}",
    "{""type"":""user"",""message"":{""role"":""user"",""content"":""next""},""timestamp"":""$(& $ts 1200)""}",
    "{""message"":{""model"":""claude-opus-5-5"",""id"":""msg_3"",""role"":""assistant"",""content"":[{""type"":""tool_use"",""id"":""t2"",""name"":""Monitor"",""input"":{}}],$(& $use 1)},""type"":""assistant"",""timestamp"":""$(& $ts 1205)""}",
    "{""type"":""user"",""message"":{""role"":""user"",""content"":[{""tool_use_id"":""t2"",""type"":""tool_result"",""content"":""x""}]},""timestamp"":""$(& $ts 1505)""}") -join "`n" | Set-Content -LiteralPath $tx -NoNewline
  Add-Content -LiteralPath $tx "`n"; $left = [ref][long]1MB; $r = Update-KitUsageFile $tx $null $left
  $old = [ordered]@{ v = 3; off = 5L; in = 0L; out = 0L; cr = 0L; cw = 0L; cw1 = 0L; n = 0; tools = 0; model = ''; t0 = ''; t1 = ''; lastId = ''; lastU = @(0, 0, 0, 0, 0); days = @{} }; $r2 = Update-KitUsageFile $tx $old ([ref][long]1MB)
  $hs = @($r.hrs.Values); $ok1 = $r.tOk; $r.tOff = 0L; $r3 = Update-KitUsageFile $tx $r ([ref][long]1MB)   # an older reader moved off past the split
  "$(@($r.tm | ForEach-Object { [int]$_ }) -join '/') $ok1 out:$([long](@($hs | ForEach-Object { $_[1] }) | Measure-Object -Sum).Sum) $($r2.tOk)/$($r2.hrs.Count) $($r3.tOk)" }
Expect "split time: model = prompt or result -> answer (25 s), the build's 60 s minus its 20 s gate queue, waiting = queue + the monitor (320 s), idle prompt gaps out; hourly output 16; a record read from mid-file, or moved on by an older reader: partial ($spt)" ($spt -eq '25/40/0/0/0/320 True out:16 False/0 False')
$spf = & { . $O; $so1 = [pscustomobject]@{ tok = 193240000; cost = 38.3; in = 40000; out = 1200000; cw = 2000000; cr = 190000000; cs = @(0.2, 3.1, 30, 5); tm = @(40, 60, 10, 20, 10, 30); tmN = 1; min = 184 }
  $c = Format-KitSplitCell $so1 'tc' 'tip'; $t = Format-KitSplitCell $so1 'time' 'tip'; $n = Format-KitSplitCell ([pscustomobject]@{ tok = 5; min = 12 }) 'time' 'tip'; $h = Format-KitSplitCell $so1 'tokens' 'tip' (Get-KitSplitPeaks @($so1) 'tokens') -Heat
  $tip = Get-KitSplitTip $so1
  $tiles = { param($x) @([regex]::Matches($x, "<b class='kq k-(\w+) (k4|k2|kt)'[^>]*>([^<]*)(?:<small>([^<]*)</small>)?</b>") | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value) $($_.Groups[3].Value)$(if ($_.Groups[4].Success) { " $($_.Groups[4].Value)" })" }) -join ';' }
  "$(& $tiles $c)|$(& $tiles $t)|$($n -match '<small class=knr>wall clock</small>' -and $n -match '>12 min<')|$($h -match "^<i class='kst kd-tokens' title='tip'><span class=kr4><b class='kq k-out k4' style='--a:100%'>1\.2M</b>" -and $c -match "<span class=kb aria-hidden=true><i class='k-out' style='flex-grow:6'></i>")|$(@($tip -split "`n").Count) $($tip -match 'cache read 190M &#183; \$30\.00|cache read 190M · \$30\.00')" }
Expect "split cell: tokens · cost a line per type (output, fresh in, cache write, cache read), narrow work / cache, time model / tools / waiting, no data = the total + 'split not recorded' (time: 'wall clock'), a heat cell shaded per type; the tooltip all types with their cost ($spf)" ($spf -eq 'out k4 1.2M $3.10;in k4 40k $0.20;cw k4 2M $5.00;cr k4 190M $30.00;wk k2 1.2M $3.30;ca k2 192M $35.00;tot kt 193.2M $38.30|mo k4 40 min;to k4 1.7 h;wa k4 30 min;mo k2 40 min;tw k2 2.2 h;tot kt 3.1 h|True|True|7 True')
$lgd = & { . $O; $pt = [pscustomobject]@{ tm = $null; tmN = 3; tmAll = 74; wall = 288 }
  $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; $so = [pscustomobject]@{ tok = 9; in = 1; out = 2; cr = 3; cw = 3; tm = @(1, 1, 0, 0, 0, 1); wall = 50 }
  $mh = Format-KitMetricHeat @(@{ n = 'r'; v = @(1, $null, $null); sk = @('', 'tc', 'time'); so = @($null, $so, $so) }) @('a', 'b', 'c') 'x' 'mh'
  $gt = $mh -match "--gt:minmax\(48px,1fr\) minmax\(260px,3fr\) minmax\(190px,2\.2fr\);--xw:350px"
  "$(Format-KitLegend 'a b' "x's")|$(Format-KitSplitCell $pt 'time' (Get-KitSplitTip $pt))|$($gt -and (Format-KitSplitCell $so 'time' 't') -match "<b class='kq k-tot kt'>50 min</b>")|$(Format-KitCompactNum 4916)" }
$skh = & { . $O; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; $so =[pscustomobject]@{ tok = 9; in = 1; out = 2; cr = 3; cw = 3; tm = @(1, 1, 0, 0, 0, 1); wall = 50 }
  $mh = Format-KitMetricHeat @(@{ n = 'r'; v = @(1, $null, $null); sk = @('', 'tc', 'time'); so = @($null, $so, $so) }) @('a', 'b', 'c') 'x' 'mh'
  $hd = [regex]::Match($mh, "<span class='gs0 hrs dy'.*?</span></div>").Value
  @([regex]::Matches($hd, "<b class='kq k-(\w+) (k4|k2|kt)'>([^<]+)</b>") | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[3].Value)" }) -join ' ' }
Expect "split column head (owner 2026-11-20: no legend said which tile is which): tile names in the cells' own tile row, wide and narrow forms ($skh)" ($skh -eq 'out=out in=fresh cw=c-write cr=c-read wk=work ca=cache tot=total mo=model to=tools wa=wait mo=model tw=tools+wait tot=total')
$rtc = & { . $O; $n = [datetime]'2026-01-02T10:00:00'
  $rl = @(@{ k = 'devy'; n = 3; sum = 5000; avgMin = 50; p90Min = 60; tm = @(10, 5, 0, 0, 5, 10); tmN = 2; wallN = 1; models = @(); types = @() }, @{ k = 'fork'; n = 1; sum = 900; avgMin = 96; p90Min = 96; tmN = 0; wallN = 1; models = @(); types = @() })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ usage = [pscustomobject]@{ days = @(@{ day = $n.ToString('yyyy-MM-dd'); tok = 5900 }); byRole = $rl } } })
  $sp = $h.Substring($h.IndexOf('data-mk=spend-role'))
  "$($sp -match "<i class='kst kd-time'[^>]*><span class=kr4>.*?<b class='kq k-tot kt'[^>]*>15 min</b>") $($sp -match "<b>1\.6 h</b><small class=knr>wall clock</small>")" }
Expect "spend per role time cell: tiles and total over the steps with a split (avg 15 min, never the mixed 50); none: the avg wall clock, labelled ($rtc)" ($rtc -eq 'True True')
Expect "legend: keys visible, the explanation only in an (i) tooltip; a partial time split names its steps; split columns sized (--gt / --xw), the time total = elapsed; 4916 -> 4.9k ($lgd)" ($lgd -match '\|True\|4\.9k$' -and $lgd -match "^<div class=hk>a b <span class=hki tabindex=0 role=note title='x&#39;s' aria-label='x&#39;s'>&#9432;</span></div>\|" -and $lgd -match '<small class=knr>split: 3 of 74 steps</small>' -and $lgd -match '3 of 74 steps have one \(a transcript read before' -and $lgd -match '\|4\.9k$')
$spr = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $hk = $n.AddHours(-1).ToString('yyyy-MM-dd HH'); $st = [pscustomobject]@{ label = 'devy:A1'; role = 'devy'; at = $n.AddMinutes(-10).ToString('o'); min = 50; result = 'pass'; tok = 1000; in = 10; out = 90; cr = 800; cw = 100; cs = @(0.01, 0.2, 0.02, 0.05); tm = @(20, 10, 0, 0, 5, 15); hrs = @{ $hk = @(10, 90, 800, 100, 0.01, 0.2, 0.02, 0.05) }; mrs = @() }
  $run = [pscustomobject]@{ run = 'r1'; id = 'wf_1'; label = 'build a thing'; kind = 'build'; started = $n.AddHours(-2).ToString('o'); status = 'ended'; at = $n.AddMinutes(-10).ToString('o'); tok = 1000; cost = 0.28; in = 10; out = 90; cr = 800; cw = 100; cs = @(0.01, 0.2, 0.02, 0.05); tm = @(20, 10, 0, 0, 5, 15); tmN = 1; wall = 50; hrs = $st.hrs; steps = @($st); total = 1; done = 1; merged = 0; roles = 'devy 1' }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = @(); stats = [pscustomobject]@{ usage = [pscustomobject]@{ runs = @($run); days = @([pscustomobject]@{ day = $n.ToString('yyyy-MM-dd'); tok = 1000; cost = 0.28; in = 10; out = 90; cr = 800; cw = 100; cs = $run.cs }) } } })
  "$($h -match "class='gks w2 rtl'") $($h -match '<small>tokens (&#183;|·) cost</small>') $($h -match "class='gs hm sp rs'") $($h -match "title='$($n.AddHours(-1).ToString('HH:00')) &#183; build a thing &#183; 50 min active\noutput 90") $($h -match '>1 ended (&#183;|·) (1000|1k|1\.0k) tok (&#183;|·) \$0\.28<') $($h -match "class='gs hm dy[^']* sbr'") $($h -match 'class=kleg') $($h -notmatch "title='$($n.AddHours(-2).ToString('HH:00')) &#183; build a thing &#183; \d+ min active")" }
Expect "runs band: tokens · cost and time split columns, an hour cell = output tokens over minutes with the hour's split in its tooltip (an hour with no tokens: an empty upper part, never the shade as its number), the day header split; Per day tokens / cost split rows; one legend ($spr)" ($spr -eq 'True True True True True True True True')
# role time (owner 2026-11-20: coordinator "123.3 h"): a main session open 10 days = elapsed cut at the window; its avg time = active in the
# window (2 min; the 2 min 10 days ago out)
$um = { param($id, [int[]]$v, [string]$t) "{`"type`":`"assistant`",`"timestamp`":`"$t`",`"message`":{`"model`":`"claude-sonnet-5-5`",`"id`":`"$id`",`"role`":`"assistant`",`"content`":[],`"usage`":{`"input_tokens`":$($v[0]),`"cache_creation_input_tokens`":$($v[3]),`"cache_read_input_tokens`":$($v[2]),`"output_tokens`":$($v[1])}}}" }
$uc = Join-Path (Kd) 'uc'; $null = New-Item -ItemType Directory -Force $uc; $ucT = (Get-Date).Date.AddMinutes(1).ToUniversalTime(); $ucIso = { param($m) $ucT.AddMinutes($m).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
[IO.File]::WriteAllText("$uc/m1.jsonl", ("{`"type`":`"user`",`"timestamp`":`"$(& $ucIso (-14402))`",`"message`":{`"role`":`"user`",`"content`":`"old`"}}", (& $um 'msg_c1' 1, 1, 0, 0 (& $ucIso (-14400))), "{`"type`":`"user`",`"timestamp`":`"$(& $ucIso 0)`",`"message`":{`"role`":`"user`",`"content`":`"go`"}}", (& $um 'msg_c2' 1, 9, 0, 0 (& $ucIso 2)) -join "`n") + "`n")
[IO.File]::WriteAllText("$uc/m2.jsonl", (& $um 'msg_d1' 1, 9, 0, 0 (& $ucIso 2)) + "`n")
# m2: a record cached before the per-day split (whole-file tm of 600 min, begun 10 days ago): unsplit, its elapsed (wall clock) counts
$ucOut = Invoke-PsTest usage-time @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $f2 = (Get-Item (Join-Path $args[1] 'm2.jsonl')).FullName; $t1 = (Get-Date).Date.AddMinutes(3).ToUniversalTime()
$rec = [ordered]@{ v = 3; off = (Get-Item $f2).Length; in = 1; out = 9; cr = 0; cw = 0; cw1 = 0; n = 1; tools = 0; model = 'claude-sonnet-5-5'; t0 = $t1.AddDays(-10).ToString('o'); t1 = $t1.ToString('o'); lastId = 'msg_d1'; lastU = @(1, 9, 0, 0, 0)
  days = @{ "$((Get-Date).ToString('yyyy-MM-dd'))|claude-sonnet-5-5" = @(1, 9, 0, 0, 0) }; tm = @(36000, 0, 0, 0, 0, 0); tOk = $true; tL = ''; tK = ''; tC = 4; hrs = @{}; tOff = (Get-Item $f2).Length }
[IO.File]::WriteAllText((Get-KitPath usage-cache -Create), (@{ files = @{ $f2 = $rec } } | ConvertTo-Json -Depth 6 -Compress))
$u = Get-KitUsage -Seconds 30; $cr = @($u.byRole | Where-Object k -eq 'coordinator')[0]; $c1 = @($u.coord | Where-Object session -eq 'm1')[0]; $c2 = @($u.coord | Where-Object session -eq 'm2')[0]
"$(@($u.coord | Where-Object { [double]$_.min -gt 7 * 1440 }).Count)|$(@($c1.tm | ForEach-Object { [double]$_ }) -join ',')|$($null -eq $c2.tm)|$($cr.wallN)"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $uc) | Out-String
Expect "usage time: a session's elapsed is cut at the 7-day window; active minutes count the window's days only (m1: 2 of 4 min); a record cached before the per-day split and begun before the window: wall clock ($($ucOut.Trim()))" ($ucOut.Trim() -match '0\|2,0,0,0,0,0\|True\|1$')
# retro due (retro 1549): 7 signals + 30 guard blocks, no run finished = not due; a finished run or 25 signals = due
$rd = Invoke-PsTest retro-due @'
$null = . $args[0] 6>$null; $sg = Get-KitPath signals -Create; $at = (Get-Date).ToString('o')
1..7 | ForEach-Object { "{`"at`":`"$at`",`"kind`":`"friction`"}" } | Set-Content $sg; 1..30 | ForEach-Object { Write-KitLog guard deny @{} }
"a[$(Get-KitRetroDue)] b[$(Get-KitRetroDue -RunFinished)]"; 1..25 | ForEach-Object { "{`"at`":`"$at`",`"kind`":`"idea`"}" } | Add-Content $sg; "c[$(Get-KitRetroDue)]"
'@ @($O)
Expect "retro due: guard blocks alone never make it due; a finished run or retro.dueSignals (25) signals do ($rd)" ("$rd" -match 'a\[\] b\[7 signal\(s\) \+ 30 guard' -and "$rd" -match 'c\[32 signal')
Remove-TestKit $k
Complete-Tests
