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
if (-not (Test-Path $ad)) { New-Item -ItemType Directory -Force (Split-Path $ad) | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters/task_rollup.ps1') $ad }
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
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ repos = @(@{ name = 'api-repo'; aliases = @('backend', 'api') }, @{ name = 'web-repo'; aliases = @('webui', 'web') }) }
$res = & {
  . (Lib); . $ad
  $p = (__TrA 'create' @{ name = 'Parent'; description = "**Testing doc (human):** [open](https://h)`n`nThe owner's words." }).id
  $s1 = (__TrA 'create' @{ name = 'API fixes'; parent = $p }).id; $s2 = (__TrA 'create' @{ name = 'Web fixes'; parent = $p; description = "**Items:** WEB1 (web-repo, grid): W-1, W-2 · WX: extra polish" }).id
  $null = __TrA 'create' @{ name = 'A person''s subtask (no kit state)'; parent = $p }
  $null = __TrNone $s1 'st' { param($o) $o.status = 'in test' }
  Set-JsonFile (Join-Path $bd 'launch-args.json') @{ batch = 1; agents = @(@{ id = 'API1'; items = 'A-1, A-2'; area = 'core (api-repo)'; note = "tracker task $s1" }, @{ id = 'WEB1'; items = 'W-1'; area = 'grid (web-repo)'; note = "tracker task $s2" }) }
  Update-KitTaskIndex $s1 { param($x) $x.track = @{ task = $s1; mrs = @('api-repo!7', 'api-repo!8'); done = $true }; $x.docs['testing-doc'] = @{ url = 'https://doc/h1'; updated = '2026-11-09T10:00:00Z' } }
  Update-KitTaskIndex $s2 { param($x) $x.track = @{ task = $s2; mrs = @('web-repo!3'); done = $false }; $x.itemIds = @('WEB1', 'WX') }   # its own Items list: area ids
  Set-Content (Get-KitPath deploy-log -Create) '{"event":"record","target":"stage","mrs":["api-repo!7","api-repo!8"],"at":"2026-11-09T12:00:00Z"}'
  $global:hostCalls = 0; $global:reads = 0; $global:writes = 0
  function ProjPath($r) { "g/$r" }
  function Invoke-HostVerb([string]$Verb, [hashtable]$A) {
    $global:hostCalls++; if ($Verb -eq 'mr.url') { return "https://git/$($A.repo)/$($A.n)" }
    @{ '7' = @{ state = 'merged'; merged_at = '2026-11-09T09:00:00Z'; title = 'fix: A-1 guard' }; '8' = @{ state = 'merged'; merged_at = '2026-11-09T08:00:00Z'; title = 'fix: A-2' }; '3' = @{ state = $(if ($global:m3) { 'merged' } else { 'opened' }); merged_at = '2026-11-09T11:00:00Z'; title = 'fix: W-1'; source_branch = 'f/CU-9-web1' } }[[string]$A.n] }
  $global:gtOrig = ${function:Get-TrackerTask}; $global:sdOrig = ${function:Set-TrackerDescription}; $global:acOrig = ${function:Add-TrackerComment}
  ${function:Get-TrackerTask} = { param($Id) $global:reads++; & $global:gtOrig $Id }
  ${function:Set-TrackerDescription} = { param($Id, $Text) $global:writes++; & $global:sdOrig $Id $Text }
  ${function:Add-TrackerComment} = { param($Id, $Text) $global:writes++; & $global:acOrig $Id $Text }
  $o1 = Invoke-TaskRollup -Task $p -From $bd
  $d1 = (__TrA 'view' @{ id = $p }).description; $i1 = (__TrA 'view' @{ id = $s1 }).description; $c1 = @(__TrA 'comments' @{ id = $p }).text
  $w1 = $global:writes; $h1 = $global:hostCalls
  $o2 = Invoke-TaskRollup -Task $p; $w2 = $global:writes - $w1; $h2 = $global:hostCalls - $h1
  $r0 = $global:reads; $o3 = Update-KitParentRollup $p; $r3 = $global:reads - $r0
  $j1 = (__TrA 'view' @{ id = $s2 }).description
  $global:m3 = $true; $o4 = Invoke-TaskRollup -Task $p; $c4 = @(__TrA 'comments' @{ id = $p }).text; $o5 = Invoke-TaskRollup -Task $p
  [pscustomobject]@{ j1 = $j1; j4 = (__TrA 'view' @{ id = $s2 }).description; u1 = (__TrA 'view' @{ id = $s1 }).url; fmt = "$(Format-KitItemText 'P4-X-01' 'Fix it' @('u1', 'u1', 'u2'))|$(Format-KitItemText 'JL' '' @())|$(Format-KitItemText 'PY4' 'api-repo: P4-PY-01 - merged' @())|$(Format-KitItemText 'X' 're-merged (done)' @())|$(@(Get-KitDescItems "**Items:**`n* JR (api-repo, refine): P4-JR-01`n* PS-01 invoice->site\_visit rule").text -join '/')"; sevs = (Format-KitSevCounts @(@{ sev = 'Cosmetic' }, @{ sev = 'Critical' }, @{ sev = '' }, @{ sev = 'critical' })); o1 = "$o1"; d1 = $d1; i1 = $i1; c1 = "$c1"; w2 = $w2; h2 = $h2; o2 = "$o2"; o3 = "$o3"; r3 = $r3; o4 = "$o4"; c4 = @($c4); o5 = "$o5"
    splice = (Set-KitDescSection "x`n<!-- kit:delivery -->`nold`n<!-- /kit:delivery -->`ny" 'delivery' 'new' '')
    after = (Set-KitDescSection "<!-- kit:delivery -->`nd`n<!-- /kit:delivery -->`n`nowner" 'triage' 'T' 'delivery') }
}
$d = $res.d1
Expect "rollup: delivery under the testing-doc links, triage after it, the owner's text kept ($($res.o1))" ($d -match '(?s)^\*\*Testing doc \(human\):\*\* \[open\]\(https://h\)\n\n<!-- kit:items -->\n\*\*Items\*\*\n- \[ \] API1 · API fixes · [^\n]+\n- \[ \] WEB1 · Web fixes · [^\n]+\n- \[ \] LOCAL-\d+ · A person''s subtask \(no kit state\) · [^\n]+\n<!-- /kit:items -->\n\n<!-- kit:delivery -->.*<!-- /kit:delivery -->\n\n<!-- kit:triage -->.*<!-- /kit:triage -->\n\nThe owner''s words\.$')
$apiRow = '| [API1 · API fixes](' + $res.u1 + ') | in test | [!8](https://git/g/api-repo/8) merged · stage<br>[!7](https://git/g/api-repo/7) merged · stage | 2/2 | 1C/1L | A-1, A-2 |'
Expect 'rollup delivery: summary, one table per repo (alias label) in merge order: subtask, status, MRs, items, severity, item ids; a subtask without kit state = a plain row' ($d -match '\*\*Delivery status\*\*: 1 of 3 merged · deployed: stage \(1\) · 1 in test · 0 closed · next: merge: 2 subtask\(s\) not merged' -and
  $d.Contains("**API (api-repo)**`n`n| Subtask | Status | MRs | Items | Severity | Item ids |`n|---|---|---|---|---|---|`n$apiRow") -and $d -match '\*\*Web \(web-repo\)\*\*' -and $d -match '\[!3\]\([^)]+\) open \| 0/1 \| 1M \| W-1 \|' -and
  $d -match '\*\*Other\*\*\n\n\|[^\n]+\n\|[^\n]+\n\| \[A person''s subtask[^\n]+\| — \| — \| — \| — \|' -and $d.IndexOf('**API') -lt $d.IndexOf('**Web') -and ($d -replace '(?s)<!-- kit:items -->.*<!-- /kit:items -->') -notmatch '(?m)^- ')
Expect "item text: <id> · <plain description> · <MR URLs> (deduped, empty parts left out); Items words after the id, a (label) unwrapped, markdown escapes dropped, a status suffix (- merged) dropped ($($res.fmt))" ($res.fmt -eq 'P4-X-01 · Fix it · u1 u2|JL|PY4 · api-repo: P4-PY-01|X · re-merged|api-repo, refine: P4-JR-01/invoice->site_visit rule')
Expect "rollup severity cell: C H M L initials, another severity in full, none = ? ($($res.sevs))" ($res.sevs -eq '2C/1 Cosmetic/1 ?')
Expect 'rollup triage: severity x decision counts; not in this wave = a table (id, severity, verdict, reason)' ($d -match '5 = 3 fix · 1 defer · 1 duplicate' -and $d -match '\| Critical \| 1 \| 0 \| 0 \| 0 \| 1 \|' -and
  $d.Contains("**Not in this wave**`n`n| Id | Severity | Verdict | Reason |`n|---|---|---|---|`n| A-3 | High | deferred | owner: later (decision d-2) |`n| W-2 | Low | duplicate of W-1 | Same root cause |"))
Expect 'rollup items (no checklist verb): ticked when merged, deferred unticked with its reason, severity first' ($res.i1 -match '(?s)\*\*Items\*\*\n- \[x\] A-1 · Critical · Guard the / admin path · https://git/g/api-repo/7\n- \[ \] A-3 · High · deferred: owner: later\n- \[x\] A-2 · Low · Trim names · https://git/g/api-repo/8')
Expect 'rollup items: the task''s own area ids share the checklist, open while their MR is open, ticked once every MR naming them (branch segment) merged; the rest once all merged, with every MR URL; a triage row no MR names: the URLs of the area listing it' ($res.j1 -match '(?s)- \[ \] W-1[^\n]*\n- \[ \] W-2 · Low · duplicate of W-1: Same root cause · https://git/g/web-repo/3\n- \[ \] WEB1 · Fix the grid; Same root cause · https://git/g/web-repo/3\n- \[ \] WX · extra polish\n' -and $res.j4 -match '- \[x\] WEB1 · Fix the grid; Same root cause · https://git/g/web-repo/3\n- \[x\] WX · extra polish · https://git/g/web-repo/3' -and $d -match '\| 0/1 \| 1M \| W-1 \|')
Expect "rollup milestones: none yet (not all merged) ($($res.c1))" (-not $res.c1)
Expect "rollup: an unchanged second run writes nothing and fetches merged MRs never again ($($res.w2) writes, $($res.h2) host calls)" ($res.w2 -eq 0 -and $res.o2 -match 'no change' -and $res.h2 -le 2)
Expect "rollup: nothing changed locally + inside track.rollupMinutes -> no tracker read ($($res.r3) reads)" ($res.r3 -eq 0 -and -not $res.o3)
Expect "rollup milestone: all merged posted once; the next run posts nothing ($($res.o4) | $($res.o5))" (@($res.c4).Count -eq 1 -and $res.c4[0] -match '^All 2 subtasks merged: delivery status in the description\.$' -and $res.o4 -match 'milestone merged' -and $res.o5 -match 'no change')
Expect 'marker splice: only the section between markers changes; a new one goes after its -After section' ($res.splice -eq "x`n<!-- kit:delivery -->`nnew`n<!-- /kit:delivery -->`ny" -and $res.after -eq "<!-- kit:delivery -->`nd`n<!-- /kit:delivery -->`n`n<!-- kit:triage -->`nT`n<!-- /kit:triage -->`n`nowner")
# close: every subtask closed -> ONE close-parent ask (gate close), closed only on the owner's answer; a reopen re-asks; no subtasks: no ask.
# items: a task's own Items list as its checklist, ticked by merged MRs naming an id, all when its MRs are all merged
$cl = & {
  $env:KIT_TRACKER_TYPE = 'none'; . (Join-Path $k 'skills/bossy/bossy.ps1') 6>$null; $dd = Get-KitPath decisions -Create
  $view = { param($i) __TrA 'view' @{ id = $i } }; $st = { param($i, $s) $null = __TrNone $i 'st' { param($o) $o.status = $s } }
  $p = (__TrA 'create' @{ name = 'Close parent'; description = 'ask' }).id; $a = (__TrA 'create' @{ name = 'Sub a'; parent = $p }).id; $b = (__TrA 'create' @{ name = 'Sub b'; parent = $p }).id
  $solo = (__TrA 'create' @{ name = 'Solo'; description = 'x' }).id; & $st $a closed; & $st $solo closed
  $r0 = Update-KitParentRollup $p -Force; & $st $b closed; $r1 = Update-KitParentRollup $p -Force; $r2 = Update-KitParentRollup $p -Force
  $ask = (Read-KitState (Get-KitTaskFile $p)).rollup.closeAsk; $dec = Get-Content (Join-Path $dd "$ask.json") -Raw | ConvertFrom-Json; $n1 = @(Get-ChildItem $dd -Filter '*.json').Count; $s1 = (& $view $p).status
  $null = Invoke-Decide answer -Id $ask -Answer 'a lot of docs pending' -NoPublish; $null = Update-KitParentRollup $p; $d3 = (& $view $p).description; $r3b = Update-KitParentRollup $p; $act3 = (Read-KitState (Get-KitTaskFile $p)).rollup.closeActed
  & $st $b 'in progress'; $null = Update-KitParentRollup $p -Force; & $st $b closed; $r5 = Update-KitParentRollup $p -Force; $ask2 = (Read-KitState (Get-KitTaskFile $p)).rollup.closeAsk
  $null = Invoke-Decide answer -Id $ask2 -Answer 'A' -NoPublish; $r6 = Update-KitParentRollup $p; $null = Invoke-TaskRollup -Task $solo
  $it = (__TrA 'create' @{ name = 'Own'; description = "**Items (ids):** A1, A2 (deferred)`n`n- note" }).id; Update-KitTaskIndex $it { param($x) $x.track = @{ task = $it; mrs = @('api-repo!9'); done = $false } }
  function ProjPath($r) { "g/$r" }; function Invoke-HostVerb([string]$Verb, [hashtable]$A) { if ($Verb -eq 'mr.url') { return "https://git/$($A.repo)/$($A.n)" }; @{ state = 'merged'; title = 'fix: A1' } }
  $i1 = Update-KitTaskItems $it (& $view $it); $id1 = (& $view $it).description; $i2 = Update-KitTaskItems $it
  Update-KitTaskIndex $it { param($x) $x.track.done = $true }; $i3 = @(Invoke-KitTrackRollupHook) -join ' '
  $solo1 = (__TrA 'create' @{ name = 'Solo bug'; description = 'no list' }).id; Update-KitTaskIndex $solo1 { param($x) $x.track = @{ task = $solo1; mrs = @('api-repo!11', 'api-repo!12'); done = $true } }
  $solo2 = (__TrA 'create' @{ name = 'Late link'; description = 'no list' }).id; Update-KitTaskIndex $solo2 { param($x) $x.track = @{ task = $solo2; mrs = @('api-repo!13'); done = $false } }; $late = "$(Update-KitTaskItems $solo2 (& $view $solo2) -Force)|$((& $view $solo2).description)"
  $null = Update-KitTaskItems $solo1 (& $view $solo1) -Force; $oneItem = "$((& $view $solo1).description)|$(@(__TrA 'comments' @{ id = $solo1 }).Count)"
  $iSplit = @((Get-KitDescItemIds "**Items:** TP-01 block ListAgents, SendMessage, TaskStop, Agent · TP-02 keep logs (x) · **Decisions:** d1") -join '|'; (Get-KitDescItemIds "Items:`n- B3 · High · fix it`n- Fix the grid: now`nnext") -join '|'; (Get-KitDescItemIds "Items: A1, A2 · High") -join '|'; (Get-KitDescItemIds "Items: PS-04 golden cases T1, N1, A10") -join '|') -join ' / '
  $s6 = (& $view $p).status; $d6 = (& $view $p).description; $fin = (Read-KitState (Get-KitTaskFile $p)).rollup.parentClosed
  $null = Update-KitParentRollup $p; & $st $p 'in progress'; Update-KitTaskIndex $p { param($x) $x.rollup.readAt = (Get-Date).AddHours(-2).ToString('o') }; $null = Update-KitParentRollup $p -Force   # reopened: rolls up again (the verb forces)
  [pscustomobject]@{ r0 = "$r0"; r1 = "$r1"; r2 = "$r2"; gate = $dec.gate; dtask = $dec.task; n1 = $n1; s1 = $s1; d3 = $d3; ask = $ask; ask2 = $ask2; r3b = "$r3b"; act3 = $act3; r5 = "$r5"; r6 = "$r6"; s6 = $s6
    d6 = $d6; fin = $fin; reopen = "$((Read-KitState (Get-KitTaskFile $p)).rollup.parentClosed) $((& $view $p).status) $(@(Get-ChildItem $dd -Filter '*.json').Count)"; n7 = @(Get-ChildItem $dd -Filter '*.json').Count; i1 = "$i1"; id1 = $id1; i2 = "$i2"; i3 = $i3; it = $it; iSplit = $iSplit; oneItem = $oneItem; late = $late }
}
Expect "close: none while a subtask is open; all closed -> ONE ask (gate close, task = parent), the parent untouched ($($cl.r1) | $($cl.n1))" ($cl.r0 -notmatch 'close asked' -and $cl.r1 -match "close asked $($cl.ask)" -and $cl.r2 -notmatch 'close asked' -and $cl.n1 -eq 1 -and $cl.gate -eq 'close' -and $cl.dtask -and $cl.s1 -ne 'closed')
Expect "close: any answer but A (here 'a lot of ...') -> kept, acted on once (no re-read), shown in the delivery line; a reopened subtask spends it, all closed again asks once more; 'A' closes it, final ($($cl.r6))" ($cl.d3 -match 'parent kept open: a lot of docs pending' -and -not $cl.r3b -and $cl.act3 -eq $cl.ask -and $cl.ask2 -and $cl.ask2 -ne $cl.ask -and $cl.r5 -match 'close asked' -and
  $cl.r6 -match 'parent closed' -and $cl.s6 -eq 'closed' -and $cl.d6 -match '\*\*Delivery status\*\*:[^\n]* · parent closed' -and $cl.fin -eq $true -and $cl.reopen -eq 'False in progress 2')   # reopened by a person: rolls up again, never re-closed or re-asked
Expect "close: a task without subtasks is never asked about (its flow unchanged) ($($cl.n7) decisions)" ($cl.n7 -eq 2)
Expect "items: the task's own Items list -> its checklist, an id a merged MR names ticked; unchanged = no write; all ticked once its MRs are all merged ($($cl.i1) | $($cl.i3))" ($cl.i1 -match '1/2 done' -and $cl.id1 -match '(?s)\*\*Items\*\*\n- \[x\] A1 · https://git/g/api-repo/9\n- \[ \] A2 · deferred' -and -not $cl.i2 -and $cl.i3 -match "items $($cl.it): 2/2 done")
Expect "items: one MRs item (no Items list) resolved at once when its only MR is already merged, before promotion (track add of a late-linked merged MR) ($($cl.late))" ($cl.late -match '^items \S+: 1/1 done\|' -and $cl.late -match '- \[x\] MRs')
Expect "items: split on ' · ' and bullets, on ',' only after a bare id (never inside an item's text: 'PS-04 golden cases T1, N1'); id = its leading token; a **Label:** piece ends the list ($($cl.iSplit))" ($cl.iSplit -eq 'TP-01|TP-02 / B3|Fix the grid / A1|A2|High / PS-04')
Expect "items: a task without an Items list gets ONE item 'MRs · <task name> · <MR URLs>', no MRs comment ($($cl.oneItem))" ($cl.oneItem -match '(?s)- \[x\] MRs · Solo bug · https://git/g/api-repo/11 https://git/g/api-repo/12.*\|0$')
# a briefy item table (ID | Phase | Owner area | Ports | Title), areas spread over subtasks, a { id, task } map; a task without subtasks
$bf = & {
  $env:KIT_TRACKER_TYPE = 'none'; . (Join-Path $k 'skills/bossy/bossy.ps1') 6>$null; $view = { param($i) __TrA 'view' @{ id = $i } }
  $b1 = Join-Path (Kd) 'brief-b'; $b2 = Join-Path (Kd) 'brief-c'; New-Item -ItemType Directory -Force $b1, $b2 | Out-Null
  Set-Content (Join-Path $b1 'items.md') "| ID | Phase | Owner area | Ports RM | Title |`n|---|---|---|---|---|`n| H-P1-S01 | P1 | HS | P1-JS-01 | HM tables ``agent`` |`n| H-P1-C01 | P1 | HC | P1-JC-02 | Chat with an agent |`n| H-P2-C01 | P2 | HC | P2-JT-05 | Unattended chats |"
  Set-Content (Join-Path $b2 'items.md') "| ID | Area | Title |`n|---|---|---|`n| R-1 | RX | Old item |"
  $p = (__TrA 'create' @{ name = 'Feature parent' }).id
  $s1 = (__TrA 'create' @{ name = '[Feature] HM P1: store'; parent = $p; description = "**Items:**`n- HS (java, store): H-P1-S01`n- HC (java, chat): H-P1-C01" }).id
  $s2 = (__TrA 'create' @{ name = '[Feature] HM P2: triggers'; parent = $p; description = "**Items:**`n- HC (java, chat): H-P2-C01" }).id
  Set-JsonFile (Join-Path $b1 'rollup-agents.json') @{ agents = @(@{ id = 'HM-P1'; task = $s1 }, @{ id = 'HM-P2'; task = $s2 }) }
  $o = Invoke-TaskRollup -Task $p -From "$b1;$b2"; $i1 = (& $view $s1).description; $i2 = (& $view $s2).description; $pd = (& $view $p).description
  $null = __TrNone $s2 'st' { param($x) $x.status = 'closed' }; $null = Invoke-TaskRollup -Task $p; $pd2 = (& $view $p).description
  $leaf = (__TrA 'create' @{ name = 'Leaf'; description = "**Items:**`n- HS (java, store): H-P1-S01" }).id; $ol = Invoke-TaskRollup -Task $leaf -From $b1
  $solo = (__TrA 'create' @{ name = 'Solo' }).id; $os = Invoke-TaskRollup -Task $solo
  [pscustomobject]@{ o = "$o"; i1 = $i1; i2 = $i2; pd = $pd; pd2 = $pd2; ol = "$ol"; ld = (& $view $leaf).description; os = "$os"; s1 = $s1; s2 = $s2 }
}
Expect "rollup -From 'a;b': briefy columns (Owner area, Ports -> '(ports X)'); a subtask's items = the ids its Items list names, beside its area items ($($bf.o))" ($bf.o -match '4 item\(s\)' -and $bf.i1 -match '(?s)- \[ \] H-P1-S01 · HM tables agent \(ports P1-JS-01\)\n- \[ \] H-P1-C01 · Chat with an agent \(ports P1-JC-02\)\n- \[ \] HS · HM tables agent \(ports P1-JS-01\)\n- \[ \] HC · Chat with an agent' -and $bf.i1 -notmatch 'H-P2-C01' -and $bf.i2 -match '- \[ \] H-P2-C01 · Unattended chats' -and $bf.i2 -notmatch 'H-P1')
Expect "rollup parent: its Items checklist = one item per subtask '<code> · <name without [Kind]> · <URL>', ticked once closed" ($bf.pd -match "(?s)\*\*Items\*\*\n- \[ \] HM-P1 · HM P1: store · \S*$($bf.s1)\S*\n- \[ \] HM-P2 · HM P2: triggers · " -and $bf.pd2 -match '- \[x\] HM-P2 · HM P2: triggers')
Expect "rollup without subtasks: the item table -> its own Items checklist; none stored -> says so ($($bf.ol) | $($bf.os))" ($bf.ld -match '- \[ \] H-P1-S01 · HM tables agent \(ports P1-JS-01\)' -and $bf.ld -notmatch 'H-P1-C01' -and $bf.ol -match 'its Items checklist only' -and $bf.os -match 'nothing to write')
Remove-TestKit $k
Complete-Tests
