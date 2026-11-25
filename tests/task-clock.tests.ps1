#Requires -Version 7
<#
task-clock.tests.ps1: the task clock (owner 2026-11-25: every task under budget.taskMinutes): clock rows from the verbs in
crafty/vocab.json clockPhases (Get-KitClockPhase, kitbag.py audited), the per-task clock (bossy adapters/task-clock.ps1), the supervise
TASK CLOCK ACT / WATCH, the page's Task clock section; the wave-brief split check; buildy review and CI together.
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
    (& $r 45 '123' investigate start a7), (& $r 44 '124' investigate start a8))
  Set-JsonFile (Join-Path (Get-KitPath tasks) 'T4.json') @{ task = 'T4'; schemaVersion = 1; track = @{ done = $true; doneAt = $n.AddMinutes(-30).ToString('o') } }
  $cl = @(Get-KitTaskClock $n -Rows $rows); $t1 = $cl | Where-Object task -eq 'T1'; $t4 = $cl | Where-Object task -eq 'T4'
  $fl = @(Get-KitSuperviseFlagsTaskClock -Pending @([pscustomobject]@{ id = 'd-9'; agent = 'a1' }) -At $n -Clock $cl | ForEach-Object { "$($_.level) $($_.what) => $($_.action)" })
  $t6 = $cl | Where-Object task -eq 'T6'
  "$([int]$t1.min) $($t1.now) $([int]$t1.spent.code) $($t4.done) $([int]$t4.min) $([int]$t6.spent.build)", ($fl -join ' || ') }
Expect "task clock: T1 40 min in build, a no-task row joins a1's T1 (code 1 min), T4 done at 20 min, T6 a killed build's start gives way (5 min) ($($tcF[0]))" ($tcF[0] -eq '40 build 1 True 20 5')
Expect "supervise TASK CLOCK: merged a minute ago (T6) none; numeric ids keep apart (task_123, task_124) ($($tcF[1]))" ($tcF[1] -notmatch 'T6' -and $tcF[1] -match 'TASK CLOCK task_123: not merged' -and $tcF[1] -match 'TASK CLOCK task_124:')
Expect "supervise TASK CLOCK: T1 ACT not merged + its decision, T2 ACT no MR, T3 WATCH investigate, T4 / T5 none ($($tcF[1]))" ($tcF[1] -match 'ACT TASK CLOCK T1: not merged at 40 min \(budget 30\); now build 5 min, waits on decision d-9 \(a1\) => Answer decision d-9 now' -and
  $tcF[1] -match '\|\| ACT TASK CLOCK T2: no MR at 22 min \(budget 20\)' -and $tcF[1] -match '\|\| WATCH TASK CLOCK T3: investigating 9 min \(time-box 8\)' -and $tcF[1] -notmatch 'T4|T5')
# the page: a Task clock section (elapsed bar vs the budget, now, labelled phase strip) from the clock stream
$tcH = & { . $O; $n = Get-Date
  foreach ($x in @(@(12, 'start', 'investigate'), @(4, 'end', 'investigate'), @(3, 'start', 'build'))) { Write-KitLog clock $x[1] @{ at = (Get-KitStamp stored $n.AddMinutes(-$x[0])); task = 'T8'; phase = $x[2] } @{ agent = 'a8'; run = 'r8' } }
  Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o') }) }
Expect 'page: Task clock section (open count), T8 12 of 30 min, now build, labelled phases' ($tcH -match "id=sec-tasks" -and $tcH -match '\(2 open &#183; 0 done' -and $tcH -match '12 of 30 min' -and $tcH -match 'build 3 min' -and $tcH -match "<td data-k='Agent'>a8</td>" -and $tcH -match 'investigate 8 &#183; build 3')
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
 return /^(build|fix|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, /^sh/.test(o.label) ? _merged(1) : {}) : _ok('[]') }
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl }
run(args, agent, _n, _n, pipeline).then(() => {
 const fx = calls.filter((c) => c.label === 'fix:X1')
 console.log(`ci-with-review:${ciAtReview === true}`)
 console.log(`one-fix-round:${fx.length === 1 && /null check/.test(fx[0].prompt) && /CI job test/.test(fx[0].prompt)}`)
 console.log(`shipped:${calls.some((c) => c.label === 'ship:X1')}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-review-ci $jsRc (Join-Path $src 'workflows/buildy.js')) 'buildy: #' 'ci-with-review', 'one-fix-round', 'shipped' -Show 6
Remove-TestKit $k
Complete-Tests
