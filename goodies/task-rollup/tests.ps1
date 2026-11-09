#Requires -Version 7
<#
tests.ps1 (goody task-rollup): triage parsing, the delivery / triage Markdown, the marker splice (owner text kept), and a parent
rollup end to end on tracker none with a recorded git host: sections, Items, milestones; a second run writes nothing.
Usage: kitbag.py goody test task-rollup (next to the kit's tests/harness.ps1; New-TestKit gets this goody's files).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit rollup; $ad = Join-Path $k 'skills/bossy/adapters/task_rollup.ps1'
if (-not (Test-Path $ad)) { New-Item -ItemType Directory -Force (Split-Path $ad) | Out-Null; Copy-Item (Join-Path $PSScriptRoot 'files/skills/bossy/adapters/task_rollup.ps1') $ad }
$bd = Join-Path (Kd) 'brief'; New-Item -ItemType Directory -Force $bd | Out-Null
Set-Content (Join-Path $bd 'triage.md') @'
# Triage
| ID | Sev | Verdict | Decision | Area | Decision id | Reason / fix |
|---|---|---|---|---|---|---|
| A-1 | Critical | Confirmed | fix | API1 | d-1 | Guard the \| admin path |
| A-2 | Low | Confirmed | fix | API1 |  | Trim names |
| A-3 | High | Plausible | defer | API1 | d-2 | owner: later |
| W-1 | Medium | Confirmed | fix | WEB1 |  | Fix the grid |
| W-2 | Low | Plausible | duplicate of W-1 | WEB1 |  | Same root cause |

| Severity | fix |
|---|---|
| Critical | 1 |
'@
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ repos = @(@{ name = 'api-repo' }, @{ name = 'web-repo' }) }
$res = & {
  . (Lib); . $ad
  $p = (__TrA 'create' @{ name = 'Parent'; description = "**Testing doc (human):** [open](https://h)`n`nThe owner's words." }).id
  $s1 = (__TrA 'create' @{ name = 'API fixes'; parent = $p }).id; $s2 = (__TrA 'create' @{ name = 'Web fixes'; parent = $p }).id
  $null = __TrA 'create' @{ name = 'A person''s subtask (no kit state)'; parent = $p }
  $null = __TrNone $s1 'st' { param($o) $o.status = 'in test' }
  Set-JsonFile (Join-Path $bd 'launch-args.json') @{ batch = 1; agents = @(@{ id = 'API1'; items = 'A-1, A-2'; area = 'core (api-repo)'; note = "tracker task $s1" }, @{ id = 'WEB1'; items = 'W-1'; area = 'grid (web-repo)'; note = "tracker task $s2" }) }
  Update-KitTaskIndex $s1 { param($x) $x.track = @{ task = $s1; mrs = @('api-repo!7', 'api-repo!8'); done = $true }; $x.docs['testing-doc'] = @{ url = 'https://doc/h1'; updated = '2026-11-09T10:00:00Z' } }
  Update-KitTaskIndex $s2 { param($x) $x.track = @{ task = $s2; mrs = @('web-repo!3'); done = $false } }
  Set-Content (Get-KitPath deploy-log -Create) '{"event":"record","target":"stage","mrs":["api-repo!7","api-repo!8"],"at":"2026-11-09T12:00:00Z"}'
  $global:hostCalls = 0; $global:reads = 0; $global:writes = 0
  function ProjPath($r) { "g/$r" }
  function Invoke-HostVerb([string]$Verb, [hashtable]$A) {
    $global:hostCalls++; if ($Verb -eq 'mr.url') { return "https://git/$($A.repo)/$($A.n)" }
    @{ '7' = @{ state = 'merged'; merged_at = '2026-11-09T09:00:00Z'; title = 'fix: A-1 guard' }; '8' = @{ state = 'merged'; merged_at = '2026-11-09T08:00:00Z'; title = 'fix: A-2' }; '3' = @{ state = $(if ($global:m3) { 'merged' } else { 'opened' }); merged_at = '2026-11-09T11:00:00Z'; title = 'fix: W-1' } }[[string]$A.n] }
  $global:gtOrig = ${function:Get-TrackerTask}; $global:sdOrig = ${function:Set-TrackerDescription}; $global:acOrig = ${function:Add-TrackerComment}
  ${function:Get-TrackerTask} = { param($Id) $global:reads++; & $global:gtOrig $Id }
  ${function:Set-TrackerDescription} = { param($Id, $Text) $global:writes++; & $global:sdOrig $Id $Text }
  ${function:Add-TrackerComment} = { param($Id, $Text) $global:writes++; & $global:acOrig $Id $Text }
  $o1 = Invoke-TaskRollup -Task $p -From $bd
  $d1 = (__TrA 'view' @{ id = $p }).description; $i1 = (__TrA 'view' @{ id = $s1 }).description; $c1 = @(__TrA 'comments' @{ id = $p }).text
  $w1 = $global:writes; $h1 = $global:hostCalls
  $o2 = Invoke-TaskRollup -Task $p; $w2 = $global:writes - $w1; $h2 = $global:hostCalls - $h1
  $r0 = $global:reads; $o3 = Update-KitParentRollup $p; $r3 = $global:reads - $r0
  $global:m3 = $true; $o4 = Invoke-TaskRollup -Task $p; $c4 = @(__TrA 'comments' @{ id = $p }).text; $o5 = Invoke-TaskRollup -Task $p
  [pscustomobject]@{ o1 = "$o1"; d1 = $d1; i1 = $i1; c1 = "$c1"; w2 = $w2; h2 = $h2; o2 = "$o2"; o3 = "$o3"; r3 = $r3; o4 = "$o4"; c4 = @($c4); o5 = "$o5"
    splice = (Set-KitDescSection "x`n<!-- kit:delivery -->`nold`n<!-- /kit:delivery -->`ny" 'delivery' 'new' '')
    after = (Set-KitDescSection "<!-- kit:delivery -->`nd`n<!-- /kit:delivery -->`n`nowner" 'triage' 'T' 'delivery') }
}
$d = $res.d1
Expect "rollup: delivery under the testing-doc links, triage after it, the owner's text kept ($($res.o1))" ($d -match '(?s)^\*\*Testing doc \(human\):\*\* \[open\]\(https://h\)\n\n<!-- kit:delivery -->.*<!-- /kit:delivery -->\n\n<!-- kit:triage -->.*<!-- /kit:triage -->\n\nThe owner''s words\.$')
Expect 'rollup delivery: summary, one group per repo, merge order, deploy env, docs, items done/total; a subtask without kit state = a plain row' ($d -match '\*\*Delivery status\*\*: 1 of 3 merged · deployed: stage \(1\) · 1 in test · 0 closed · next: merge: 2 subtask\(s\) not merged' -and $d -match '\*\*other, batch 0 · 1\*\*' -and
  $d -match '\*\*api-repo, batch 1 · 1\*\*: 1 merged · 1 deployed · 0 closed' -and $d -match '\[!8\]\(https://git/g/api-repo/8\) api-repo merged · stage<br>\[!7\]' -and $d -match '\[human\]\(https://doc/h1\)' -and $d -match '\| 2/2 \|' -and $d -match '\| 0/1 \|' -and $d -match '\*\*web-repo, batch 2 · 1\*\*')
Expect 'rollup triage: severity x decision counts, per-subtask ids by severity, deferred and duplicate with reason' ($d -match '5 = 3 fix · 1 defer · 1 duplicate' -and $d -match '\| Critical \| 1 \| 0 \| 0 \| 0 \| 1 \|' -and $d -match '- \[API1\]\([^)]+\) → A-1, A-2 \(2: 1 Critical · 1 Low\)' -and $d -match '- A-3 · deferred · owner: later · decision d-2' -and $d -match '- W-2 · duplicate of W-1 · Same root cause')
Expect 'rollup items (no checklist verb): ticked when merged, deferred unticked with its reason, severity first' ($res.i1 -match '(?s)\*\*Items\*\*\n- \[x\] A-1 · Critical · Guard the / admin path\n- \[ \] A-3 · High · deferred: owner: later\n- \[x\] A-2 · Low · Trim names')
Expect "rollup milestones: none yet (not all merged) ($($res.c1))" (-not $res.c1)
Expect "rollup: an unchanged second run writes nothing and fetches merged MRs never again ($($res.w2) writes, $($res.h2) host calls)" ($res.w2 -eq 0 -and $res.o2 -match 'no change' -and $res.h2 -le 2)
Expect "rollup: nothing changed locally + inside track.rollupMinutes -> no tracker read ($($res.r3) reads)" ($res.r3 -eq 0 -and -not $res.o3)
Expect "rollup milestone: all merged posted once; the next run posts nothing ($($res.o4) | $($res.o5))" (@($res.c4).Count -eq 1 -and $res.c4[0] -match '^All 2 subtasks merged: delivery status in the description\.$' -and $res.o4 -match 'milestone merged' -and $res.o5 -match 'no change')
Expect 'marker splice: only the section between markers changes; a new one goes after its -After section' ($res.splice -eq "x`n<!-- kit:delivery -->`nnew`n<!-- /kit:delivery -->`ny" -and $res.after -eq "<!-- kit:delivery -->`nd`n<!-- /kit:delivery -->`n`n<!-- kit:triage -->`nT`n<!-- /kit:triage -->`n`nowner")
Remove-TestKit $k
Complete-Tests
