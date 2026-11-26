#Requires -Version 7
<#
task-clock.tests.ps1: the task clock (owner 2026-11-25: every task under budget.taskMinutes): clock rows from the verbs in
crafty/vocab.json clockPhases (Get-KitClockPhase, kitbag.py audited), the per-task clock (bossy adapters/task-clock.ps1), the supervise
TASK CLOCK ACT / WATCH, the clock on Delivery's task rows; the wave-brief split check; buildy review and CI together; a dead
workflow never holds promotion (track run); the USAGE LIMIT ACT; check python -Tests <folder>.
Usage: pwsh -NoProfile -File <kit>/tests/task-clock.tests.ps1 (or tests/kit-tests.ps1 -Area task-clock).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/task-clock.ps1', 'skills/crafty/adapters/precheck.py')
$k = New-TestKit taskclock; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $P = Join-Path $k 'skills/crafty/devtools.py'
# phase map: -Step picks '<verb>:<step>', else the verb; the task from -Task or -Branch (tracker.branchRx); an unmapped verb: none
$tcPh = & { . $O
  $a = Get-KitClockPhase 'crafty.ps1' 'check' @{ Step = 'test' }; $b = Get-KitClockPhase 'crafty.ps1' 'check' @{}; $c = Get-KitClockPhase 'crafty.ps1' 'wt lease' @{ Task = 'T1' }
  "$($a.phase)|$($b.phase)|$($c.phase) $($c.task)|$($null -eq (Get-KitClockPhase 'crafty.ps1' 'tracker view' @{ Task = 'T1' }))|$((Get-KitClockPhase 'crafty.ps1' 'check' @{ Step = 'e2e' }).phase)" }
Expect "clock phase: check -Step test / e2e = local, check = build, wt lease -Task = investigate + task, tracker view = none ($tcPh)" ($tcPh -eq 'local|build|investigate T1|True|local')
# end to end: a mapped devtools verb writes start + end rows (task from a tracked task argument, rc); an unmapped one and a dry
# run (mr --check: the body gate before any MR) none
Set-JsonFile (Join-Path (TkPath $k tasks -Create) 'T7.json') @{ task = 'T7'; schemaVersion = 1 }
$null = python -X utf8 $P proof T7 2>&1; $null = python -X utf8 $P docgaps 2>&1; $null = python -X utf8 $P mr T7 --check 2>&1
$tcRows = & { . $O; @(Read-KitLog clock (Get-Date).AddMinutes(-5)) }
$tcE = @($tcRows | ForEach-Object { "$($_.event) $($_.phase) $($_.task) $($_.rc)" }) -join ';'
Expect "clock rows: devtools.py proof T7 = start + end (task T7, its rc); docgaps (unmapped), mr --check none ($tcE)" ($tcE -match '^start local T7 ;end local T7 \d+$')
# the clock + flags: T1 40 min not merged (open build, a pending decision) -> ACT naming the decision; T2 22 min no MR -> ACT; T3
# investigating 9 min -> WATCH; T4 done; T5 idle 4 h -> none; a row with no task joins its agent's task
$tcF = & { . $O; $n = Get-Date; $r = { param($m, $t, $p, $e, $ag, $rc = 0) [pscustomobject]@{ at = $n.AddMinutes(-$m).ToString('o'); task = $t; phase = $p; event = $e; agent = $ag; run = 'r1'; rc = $rc } }
  $rows = @((& $r 40 'T1' investigate start a1), (& $r 30 'T1' investigate end a1), (& $r 29 '' code start a1), (& $r 28 '' code end a1), (& $r 5 'T1' build start a1),
    (& $r 22 'T2' investigate start a2), (& $r 21 'T2' investigate end a2), (& $r 9 'T3' investigate start a3), (& $r 2 'T3' investigate end a3),
    (& $r 50 'T4' investigate start a4), (& $r 45 'T4' mr end a4), (& $r 300 'T5' investigate start a5),
    (& $r 60 'T6' build start a6), (& $r 9 'T6' build start a6), (& $r 4 'T6' build end a6), (& $r 3 'T6' mr end a6), (& $r 2 'T6' merge start a6), (& $r 1 'T6' merge end a6),
    (& $r 45 '123' investigate start a7), (& $r 44 '124' investigate start a8),
    (& $r 600 'T9' investigate start a9), (& $r 590 'T9' investigate end a9), (& $r 60 'T9' build start a9b), (& $r 50 'T9' build end a9b),
    (& $r 260 'T10' investigate start a10), (& $r 200 'T10' local end a10), (& $r 40 'T11' investigate start a11), (& $r 5 'T12' code start a12), (& $r -2 'T12' local start a12))
  # owner 2026-11-26: live-agent time only (T9: a9 600..560 + a9b 70..now = 110, not 600); T10's agent left: stopped; T11 merged 10
  # min ago: done, its clock stopped; T12's row 2 min after Now (written while supervise ran): not yet, nowMin never negative
  $bo = { param($ag, $j, $b, $st = 'working', $it = '') [pscustomobject]@{ agent = $ag; items = $it; status = $st; joined = $n.AddMinutes(-$j).ToString('o'); beat = $n.AddMinutes(-$b).ToString('o') } }
  $brd = @((& $bo a1 45 1), (& $bo a2 25 1), (& $bo a3 10 1), (& $bo a4 55 30 left), (& $bo a6 61 1), (& $bo a7 46 1), (& $bo a8 45 1), (& $bo a9 600 560 left), (& $bo x 70 1 'waiting CI' 'T9 (fix round 2)'),
    (& $bo a10 270 200 left), (& $bo a11 45 1), (& $bo a12 6 1))
  Set-JsonFile (Join-Path (Get-KitPath tasks) 'T4.json') @{ task = 'T4'; schemaVersion = 1; track = @{ done = $true; doneAt = $n.AddMinutes(-30).ToString('o') } }
  Set-JsonFile (Join-Path (Get-KitPath tasks) 'T11.json') @{ task = 'T11'; schemaVersion = 1; track = @{ done = $false; mergedSeenAt = $n.AddMinutes(-10).ToString('o') } }
  $cl = @(Get-KitTaskClock $n -Rows $rows -Board $brd); $t1 = $cl | Where-Object task -eq 'T1'; $t4 = $cl | Where-Object task -eq 'T4'
  $fl = @(Get-KitSuperviseFlagsTaskClock -Pending @([pscustomobject]@{ id = 'd-9'; agent = 'a1' }) -At $n -Clock $cl | ForEach-Object { "$($_.level) $($_.what) => $($_.action)" })
  $t6 = $cl | Where-Object task -eq 'T6'; $tx = @{}; foreach ($c in $cl) { $tx[$c.task] = $c }
  "$([int]$t1.min) $($t1.now) $([int]$t1.spent.code) $($t4.done) $([int]$t4.min) $([int]$t6.spent.build)", ($fl -join ' || '),
  "$([int]$tx.T9.min) $($tx.T9.stopped) $([int]$tx.T10.min) $($tx.T10.stopped) $($tx.T11.done) $([int]$tx.T11.min) $($tx.T12.now) $($tx.T12.nowMin -ge 0) $($tx.T5.stopped)" }
Expect "task clock: T1 40 min in build, a no-task row joins a1's T1 (code 1 min), T4 done at 20 min, T6 a killed build's start gives way (5 min) ($($tcF[0]))" ($tcF[0] -eq '40 build 1 True 20 5')
Expect "task clock (owner 2026-11-26): T9 110 live-agent min (not 600 wall), T10 agent gone = stopped at 60, T11 merged = done at 30, T12 a later row ignored (code, nowMin >= 0), T5 no board entry + 5 h quiet = stopped ($($tcF[2]))" ($tcF[2] -eq '110 False 60 True True 30 code True True')
Expect "supervise TASK CLOCK: T9 ACT on live time (110), stopped T10 and merged T11 none ($($tcF[1]))" ($tcF[1] -match 'ACT TASK CLOCK T9: not merged at 110 min' -and $tcF[1] -notmatch 'T10|T11')
Expect "supervise TASK CLOCK: merged a minute ago (T6) none; numeric ids keep apart (task_123, task_124) ($($tcF[1]))" ($tcF[1] -notmatch 'T6' -and $tcF[1] -match 'TASK CLOCK task_123: not merged' -and $tcF[1] -match 'TASK CLOCK task_124:')
Expect "supervise TASK CLOCK: T1 ACT not merged + its decision, T2 ACT no MR, T3 WATCH investigate, T4 / T5 none ($($tcF[1]))" ($tcF[1] -match 'ACT TASK CLOCK T1: not merged at 40 min \(budget 30\); now build 5 min, waits on decision d-9 \(a1\) => Answer decision d-9 now' -and
  $tcF[1] -match '\|\| ACT TASK CLOCK T2: no MR at 22 min \(budget 20\)' -and $tcF[1] -match '\|\| WATCH TASK CLOCK T3: investigating 9 min \(time-box 8\)' -and $tcF[1] -notmatch 'T4|T5')
# the page (owner 2026-11-26: no own section): the clock on Delivery's task row (elapsed bar vs the budget, now, labelled phase strip), the Delivery line's count
$tcH = & { . $O; $n = Get-Date
  foreach ($x in @(@(12, 'start', 'investigate'), @(4, 'end', 'investigate'), @(3, 'start', 'build'))) { Write-KitLog clock $x[1] @{ at = (Get-KitStamp stored $n.AddMinutes(-$x[0])); task = 'T8'; phase = $x[2] } @{ agent = 'a8'; run = 'r8' } }
  Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o') }) }
Expect 'page: T8 on a task row of Delivery (no board entry: phases only, 11 of 30 min; now build, labelled phases), the Delivery line counts the live clocks, no Task clock section' ($tcH -notmatch 'id=sec-tasks' -and $tcH -match "<li data-fk='st:open'>[^\n]*?T8[^\n]*?<span class=tck" -and $tcH -match '11 of 30 min' -and $tcH -match 'now build 3 min' -and $tcH -match 'investigate 8 &#183; build 3' -and $tcH -match 'task clock: 2 live')
# wave-brief split check (owner 2026-11-25): shared files or same repo + task in sequence = refused, nothing written; disjoint = rendered
$sgDir = Join-Path (Kd) 'split'; New-Item -ItemType Directory -Force $sgDir | Out-Null
$sgCase = { param($nm, $ag, $ov = '') Set-JsonFile "$sgDir/$nm.json" @{ name = $nm; today = 'x'; mandate = @('m'); task = 'T1'; overlaps = $ov; agents = $ag }
  $sgOut = python -X utf8 $P render wave-brief "$sgDir/$nm.json" "$sgDir/$nm.md" 2>&1 | Out-String; "$($sgOut -match 'wave-brief refused')/$(Test-Path "$sgDir/$nm.md")" }
$sg = @((& $sgCase share @(@{ id = 'web-a'; items = 'A1'; area = 'a'; repos = 'web'; paths = @('src/app/**') }, @{ id = 'web-b'; items = 'A2'; area = 'b'; repos = 'web'; paths = @('src/app/x.ts') })),
  (& $sgCase seq @(@{ id = 'api-a'; items = 'A1'; area = 'a'; repos = 'api'; paths = @('m1/**') }, @{ id = 'api-b'; items = 'A2'; area = 'b'; repos = 'api'; paths = @('m2/**'); dependsOn = @('api-a') })),
  (& $sgCase hook @(@{ id = 'web-a'; items = 'A1'; area = 'a'; repos = 'web'; paths = @('src/a/**', 'src/routes.ts') }, @{ id = 'web-b'; items = 'A2'; area = 'b'; repos = 'web'; paths = @('src/b/**', 'src/routes.ts') }) 'src/routes.ts one-line hook'),
  (& $sgCase xrepo @(@{ id = 'api-a'; items = 'A1'; area = 'a'; repos = 'api'; paths = @('src/**') }, @{ id = 'web-b'; items = 'A2'; area = 'b'; repos = 'web'; paths = @('src/**'); dependsOn = @('api-a') })),
  (& $sgCase num @(@{ id = 'area-ACC-2'; items = 'A1'; area = 'a'; paths = @('a/**') })),
  (& $sgCase wild @(@{ id = 'web-a'; items = 'A1'; area = 'a'; paths = @('**/*.ts') }, @{ id = 'web-b'; items = 'A2'; area = 'b'; paths = @('src/x.ts') }) 'src one-line hook')) -join ' '
Expect "wave-brief split: shared glob and same-repo sequence refused (nothing written); a named hook and cross-repo producer rendered; a numbered id refused; **/*.ts vs a file refused, overlaps text no substring excuse ($sg)" ($sg -eq 'True/False True/False False/True False/True True/False True/False')
# buildy: CI starts with the review (not after it); a CI failure and a review finding go to ONE fix round
$jsRc = @'
const calls = []; let reviewDone = false, ciAtReview = null
const agent = async (p, o) => { calls.push({ label: o.label, prompt: p })
 if (/^review:/.test(o.label)) { await new Promise((r) => setTimeout(r, 30)); reviewDone = true; return { findings: calls.filter((c) => c.label === 'review:X1').length > 1 ? [] : [{ mr: '1', file: 'a.ts', line: 3, severity: 'blocking', problem: 'null check', fix: 'add it' }] } }
 if (/^ci:/.test(o.label)) { if (ciAtReview === null) ciAtReview = !reviewDone; return { done: true, mrs: calls.filter((c) => /^ci:/.test(c.label)).length > 1 ? [] : [{ mr: '1', status: 'failed', job: 'test', error: 'boom' }] } }
 return /^(build|fix|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, /^sh/.test(o.label) ? _merged(1) : {}) : /^record-args/.test(o.label) ? _rec() : _ok('[]') }
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl }
run(args, agent, _n, _n, pipeline).then(() => {
 const fx = calls.filter((c) => c.label === 'fix:X1')
 console.log(`ci-with-review:${ciAtReview === true}`)
 console.log(`one-fix-round:${fx.length === 1 && /null check/.test(fx[0].prompt) && /CI job test/.test(fx[0].prompt)}`)
 console.log(`shipped:${calls.some((c) => c.label === 'ship:X1')}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-review-ci $jsRc (Join-Path $src 'workflows/buildy.js')) 'buildy: #' 'ci-with-review', 'one-fix-round', 'shipped' -Show 6
$lfd = TkPath $k launches -Create
# track HOLD on a dead workflow (owner 2026-11-26): merged MRs, a fix step open in the wave journal; its run marked done (launch -Done
# on a self record: no runId, its wfDir names the run) or its folder quiet 3x supervise.stuckMinutes -> no hold; a live run's step holds
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'txh'; $wvd = TkPath $k waves -Create
foreach ($dw in @('wf_dn1', 31, 5, $true), @('wf_qt1', 32, 90, $false), @('wf_lv1', 33, 1, $false), @('wf_qt2', 35, 90, $false)) {   # qt2: + an open blocking review finding
  $wd = New-Item -ItemType Directory -Force (Join-Path $env:KIT_TRANSCRIPTS "s1/subagents/workflows/$($dw[0])"); $jf = Join-Path $wd 'journal.jsonl'; $mu = "https://h/g/web/-/merge_requests/$($dw[1])"
  @('{"type":"started","agentId":"a0","label":"build:W1","phase":"Build"}', "{""type"":""result"",""agentId"":""a0"",""result"":{""mrs"":[{""url"":""$mu""}]}}") + @(if ($dw[1] -eq 35) {
      '{"type":"started","agentId":"a2","label":"review:W1","phase":"Review"}', "{""type"":""result"",""agentId"":""a2"",""result"":{""findings"":[{""severity"":""blocking"",""mr"":""$mu"",""file"":""a.ts"",""line"":3,""problem"":""p""}]}}" }) +
    @('{"type":"started","agentId":"a1","label":"fix:W1","phase":"Fix"}') | Set-Content $jf; (Get-Item $jf).LastWriteTime = (Get-Date).AddMinutes(-$dw[2])
  & $J @{ run = $dw[0]; at = (Get-Date).ToString('o'); running = @('fix:W1'); agents = @{ W1 = @{ mrs = @(@{ url = "https://h/g/web/-/merge_requests/$($dw[1])" }) } } } (Join-Path $wvd "$($dw[0]).json")
  (Get-Item (Join-Path $wvd "$($dw[0]).json")).LastWriteTime = (Get-Date).AddMinutes(-10)
  if ($dw[3]) { & $J @{ script = 'buildy.js'; run = 'hm-x'; wfDir = $wd.FullName; completed = (Get-Date).ToString('o'); at = (Get-Date).AddHours(-2).ToString('o') } (Join-Path $lfd "self-buildy-hm-x-$($dw[0]).json") }
  if ($dw[0] -eq 'wf_lv1') { foreach ($sh in 'done', 'open') { & $J (@{ script = 'buildy.js'; run = "sh-$sh"; wfDir = $wd.FullName; at = (Get-Date).ToString('o') } + $(if ($sh -eq 'done') { @{ completed = (Get-Date).ToString('o') } } else { @{} })) (Join-Path $lfd "self-buildy-sh-$sh.json") } }   # one folder, a done and a live run: not finished
}
$dh = Invoke-PsTest 'dead-hold' @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = 'merged' } }
function Get-TrackerTask($id) { [pscustomobject]@{ status = 'review'; subtasks = @() } }
"finished:$((Get-KitFinishedRuns) -join ',')"
foreach ($t in @('dh31', 31), @('dh32', 32), @('dh33', 33), @('dh35', 35)) { Invoke-Track add -Task $t[0] -Mrs "g/web!$($t[1])" -Detail }
'@ @($O) | Out-String; Remove-Item Env:KIT_TRANSCRIPTS
Expect "track run: a dead workflow's open fix step or blocking finding never holds promotion (run done: wf_dn1; quiet 90 min: wf_qt1, wf_qt2); a live one holds (wf_lv1) ($($dh.Trim() -replace '\s+', ' '))" ($dh -match 'finished:[^\r\n]*wf_dn1' -and $dh -notmatch 'finished:[^\r\n]*wf_lv1' -and $dh -notmatch 'HOLD dh3[125]' -and $dh -match 'DONE dh35' -and $dh -match 'HOLD dh33: MRs merged but fix:W1 \(wf_lv1\) still in review/fix')
# owner 2026-11-26 (a dev-env change: a task for the MR, no testing docs, no QA, closed on merge): tags chore + dev-env, track add -OnMerged closed
$dvTag = & $py -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') naming tags --have feature,website kind=chore flow=dev-env 2>&1 | Out-String; $dvBad = & $py -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') naming tags flow=staging 2>&1 | Out-String
Expect "naming tags kind=chore flow=dev-env: chore replaces feature, dev-env added, another's tag kept; an unknown flow value refused ($($dvTag.Trim()))" ((($dvTag | ConvertFrom-Json).tags -join ',') -eq 'chore,website,dev-env' -and $dvBad -match "flow tag 'staging': not in the vocabulary")
$dvOut = Invoke-PsTest 'dev-env-close' @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]
$global:dvSets = @()
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = 'merged' } }
function Get-TrackerTask($id) { [pscustomobject]@{ status = 'review'; subtasks = @() } }
function Set-TrackerStatus($id, $s) { $global:dvSets += "$id=$s" }
function Get-TrackerComments { }; function Start-Process { }
Invoke-Track add -Task dv1 -Mrs 'g/web!41' -OnMerged closed; Invoke-Track add -Task dv2 -Mrs 'g/web!42'
"sets:$($global:dvSets -join ',')"
'@ @($O) | Out-String
Expect "track add -OnMerged closed (a dev-env change): closed once its MRs merge, no missing-testing-comment line; a plain task is promoted and gets that line ($(@($dvOut -split "`n" | Where-Object { $_ -match '^sets:|^(DONE|ATTENTION) dv\d' } | ForEach-Object { $_.Trim() }) -join ' // '))" ($dvOut -match 'sets:dv1=closed,dv2=promoted' -and $dvOut -match 'DONE dv1: all 1 MRs merged -> status closed' -and $dvOut -notmatch 'ATTENTION dv1' -and $dvOut -match 'ATTENTION dv2: merged, but no solution/testing comment')
# precheck --kind dev-env on a branch diff: a new key keeps every default; a changed value = DEFAULTS; no kind: no DEFAULTS; an unknown kind: usage
$dvRepo = Join-Path (Kd) 'dv-repo'; New-Item -ItemType Directory -Force $dvRepo | Out-Null; 'retries = 3' | Set-Content "$dvRepo/app.cfg"; Save-GitRepo $dvRepo i
git -C $dvRepo update-ref refs/remotes/origin/main HEAD; git -C $dvRepo checkout -q -b feat/DV9-lane
Set-JsonFile (Join-Path (Kd) 'dv-mr.json') @{ task = 'DV9'; type = 'chore'; scope = ''; change = 'lane host key'; summary = 'Lane host'; changes = @(@{ text = 'New key' }); checksRun = @(@{ name = 'env'; result = 'PASS' }); notRun = 'nothing'; risks = @(@{ text = 'none: one key' }) }
$dvPc = { param($dvKind) @((& $py -X utf8 $P precheck DV9 --dir $dvRepo --spec (Join-Path (Kd) 'dv-mr.json') @dvKind --json 2>$null | Out-String | ConvertFrom-Json) | ForEach-Object code) }
"retries = 3`nlane_host = lane" | Set-Content "$dvRepo/app.cfg"; Save-GitRepo $dvRepo 'chore: lane host key'; $dvNew = & $dvPc @('--kind', 'dev-env')
"retries = 5`nlane_host = lane" | Set-Content "$dvRepo/app.cfg"; Save-GitRepo $dvRepo 'chore: more retries'; $dvChg = & $dvPc @('--kind', 'dev-env'); $dvPlain = & $dvPc @()
$null = & $py -X utf8 $P precheck DV9 --kind staging 2>&1; $dvBadKind = $LASTEXITCODE
Expect "precheck --kind dev-env: a new key passes DEFAULTS, a changed value fails it, no kind runs no DEFAULTS, an unknown kind exits 2 ($($dvNew -join ',') | $($dvChg -join ',') | $($dvPlain -join ',') | $dvBadKind)" ('DEFAULTS' -notin $dvNew -and 'LOOP' -in $dvNew -and 'DEFAULTS' -in $dvChg -and 'DEFAULTS' -notin $dvPlain -and 'LOOP' -in $dvPlain -and $dvBadKind -eq 2)
# a /buildy area of kind dev-env: devy is told its kind, the merge passes the docs gate as 'dev-env <area>' (DEFAULTS runs), the track
# step registers -OnMerged closed, the report says exempt, the deploy batch leaves its MR out; resumed after its merge: no human
# testing doc step (postmerge); a plain area: none of these
$dvJs = @'
const pass = { status: 'PASS', failing: [] }, logs = []
const mr = (o, merged) => { const m = _merged(/D1$/.test(o.label) ? 7 : 8); return merged ? m : { mrs: [{ ...m.mrs[0], merged: false, mergeState: 'OPEN' }] } }   // an MR per area
const { calls, agent } = _mock((p, o) => /^build:/.test(o.label) ? _rep(pass, mr(o, false)) : /^(ship|postmerge):/.test(o.label) ? _rep(pass, mr(o, true)) : /^review:/.test(o.label) ? { findings: [] } : undefined, '[]')
const ags = [{ id: 'D1', items: 'A1', kind: 'dev-env' }, { id: 'D2', items: 'A2' }], o = await run({ brief: 'C:/b/w.md', mandate: ['m'], ..._kl, agents: ags }, agent, (m) => logs.push(m), _n, pipeline)
const P = (l) => (calls.find((c) => c.label === l) || {}).prompt || ''
console.log(`dv-ship:${/merge <wt> <iid> --no-docs 'dev-env D1'/.test(P('ship:D1')) && !/--no-docs/.test(P('ship:D2')) && /kind: dev-env\)/.test(P('build:D1'))}`)
console.log(`dv-track:${/track add -Discover -Mrs '[^']+' -OnMerged closed/.test(P('track:D1')) && /track add -Discover/.test(P('track:D2')) && !/-OnMerged/.test(P('track:D2'))}`)
console.log(`dv-deploy:${/merge_requests\/8/.test(P('deploy-batch')) && !/merge_requests\/7/.test(P('deploy-batch'))}`)
const mm = (n) => ({ skip: ['build', 'review', 'ci', 'merge'], mrs: [{ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged: true }] }), n0 = calls.length
await run({ brief: 'C:/b/w.md', ..._kl, mode: 'resume', resume: { D1: mm(7), D2: mm(8) }, agents: ags }, agent, _n, _n, pipeline); const L2 = calls.slice(n0).map((c) => c.label)
console.log(`dv-resume:${L2.includes('postmerge:D2') && !L2.includes('postmerge:D1')}`)
console.log(`dv-report:${o.testerGuides.some((g) => g.agent === 'D1' && g.docsExempt) && o.testerGuides.some((g) => g.agent === 'D2' && !g.docsExempt) && !logs.some((l) => /^D1: no human testing doc/.test(l))}`)
'@
Expect-Each (Invoke-Js dv-buildy $dvJs (Join-Path $src 'workflows/buildy.js')) 'buildy kind dev-env: # (merge --no-docs dev-env, track -OnMerged closed, no deploy request, no human doc asked, none after a resume)' 'dv-ship', 'dv-track', 'dv-deploy', 'dv-resume', 'dv-report' -Show 6
# usage limit (owner 2026-11-26): two agents of two runs hit one weekly limit -> ONE ACT naming it, its reset, the models and runs; an older one (4 h) none
$ulT = Join-Path (Kd) 'txul'
foreach ($ul in @('wf_ul1', 'claude-m-a', 0), @('wf_ul2', 'claude-m-b', 0), @('wf_ul3', 'claude-m-c', 240)) {
  $uf = Join-Path (New-Item -ItemType Directory -Force (Join-Path $ulT "s1/subagents/workflows/$($ul[0])")) 'agent-a1.jsonl'
  @("{""type"":""assistant"",""message"":{""model"":""$($ul[1])"",""content"":[{""type"":""text"",""text"":""work""}]}}",
    '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You''ve hit your weekly limit · resets Dec 2, 8:30am (UTC)"}]},"apiError":"usage_limit_reached"}') | Set-Content $uf
  (Get-Item $uf).LastWriteTime = (Get-Date).AddMinutes(-$ul[2]) }
$ulO = Invoke-PsTest usage-limit @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]
@(Get-KitSuperviseFlagsUsageLimit) | ForEach-Object { "$($_.level)|$($_.what)|$($_.who)" }
'@ @($O, $ulT)
Expect "usage limit: one ACT for one limit text (reset time, both models, both runs), a 4 h old one out ($($ulO -join ' ; '))" (@($ulO).Count -eq 1 -and "$ulO" -match "^ACT\|USAGE LIMIT: You've hit your weekly limit · resets Dec 2, 8:30am \(UTC\)\|claude-m-a, claude-m-b in run\(s\) wf_ul1, wf_ul2$")
# python -Tests <folder>: its test_*.py scripts run directly, never `unittest <folder>` (0 tests, exit 5: retro 1709) (from crafty-check.tests: its cap)
$pvd = Join-Path (Kd) 'py-val'; New-Item -ItemType Directory -Force "$pvd/validation" | Out-Null; 'x==1' | Set-Content "$pvd/requirements.txt"
'print("ok")' | Set-Content "$pvd/validation/test_alpha.py"; 'print("ok")' | Set-Content "$pvd/validation/helper.py"
New-Item -ItemType Directory -Force "$pvd/cases/sub" | Out-Null; "import unittest`nclass T(unittest.TestCase):`n    def test_a(self): pass" | Set-Content "$pvd/cases/sub/test_c.py"
$pvc = pwsh @np $D check -Dir $pvd -Step test -Tests cases -Show 2>&1 | Out-String
Expect "check python -Tests <folder with test cases>: the runner gets the folder ($($pvc.Trim() -replace '\s+', ' '))" ($pvc -match 'test\s*:.*\bcases\b' -and $pvc -notmatch 'test_c\.py')
$pvo = pwsh @np $D check -Dir $pvd -Step test -Tests validation -Show 2>&1 | Out-String
Expect "check python -Tests <folder>: each test_*.py run with python, no unittest ($($pvo.Trim() -replace '\s+', ' '))" ($pvo -match 'test\s*:.*"validation/test_alpha\.py"' -and $pvo -notmatch 'unittest|helper\.py')
Remove-TestKit $k
Complete-Tests
