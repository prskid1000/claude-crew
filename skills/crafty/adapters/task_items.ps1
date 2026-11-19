#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (tracker writes throw).
# task Items checklists: write one (adapter verb checklist, else a description section), item holds (counts match the task
# state), spec items, the parent's line per subtask; item text: lib.ps1 Format-KitItemText; rollup: bossy adapters/task_rollup.ps1;
# tracker move / group (K54)
# Sections: L7 items · L83 move · L126 parent status · L181 task text
# ---- items: checklists, holds, the parent's Items
$script:KitItemsSigV = 'prune1'   # in every Items signature: a new value rewrites each list once (prunes lines older writers left)
# a named checklist on a task ({ text; done }; items keyed by the text before the first ' · '; done = false unticks): adapter verb
# checklist, else a <!-- kit:<name> --> description section (always the whole list); -Prune: kit lines ('<key> · ...') not in $Items and repeats go
function Set-KitTaskChecklist([string]$Task, [string]$Name, $Items, [switch]$Prune) {
  $seen = @{}; $Items = @($Items | Where-Object { $ky = ("$($_.text)" -split ' · ', 2)[0].Trim(); -not $seen[$ky]++ })   # one line per key
  $ad = $KitAdapters['tracker'][$__trType]
  if ($ad -and $ad.ContainsKey('checklist')) { return __TrA 'checklist' @{ id = $Task; name = $Name; prune = [bool]$Prune; items = @($Items | ForEach-Object { @{ text = $_.text; done = [bool]$_.done } }) } }
  Clear-TrackerMemo $Task; $tk = Get-TrackerTask $Task; if (-not $tk.name) { throw "tracker read of $Task failed" }
  $nd = Set-KitDescSection $tk.description $Name.ToLower() ((@("**$Name**") + @($Items | ForEach-Object { "- [$(if ($_.done) { 'x' } else { ' ' })] $($_.text)" })) -join "`n") ''
  if ($nd -ne ("$($tk.description)" -replace "`r`n", "`n")) { Set-TrackerDescription $Task $nd }
}
# why a task's items are not done although merged (owner, 2026-11-16: counts match the task state): id -> ' · <reason>' suffix.
# track.holdPromotion 'deferred items: <id> <why>, ...' (its own or another open task's) naming the id -> 'held: <why>'; a piece
# naming none of them: a phrase in exactly one item's words ('Try chat / Chat now') -> that item, the task's own id -> 'deferred',
# another id / task -> skipped, else key '' (one 'held' line); a launch area not delivered (Get-KitPlannedAreas) -> 'not delivered: <area>'
function Get-KitItemHolds([string]$Task, $Items, $Tracking) {
  if (-not $Tracking) { $Tracking = (Read-KitTracking).tasks }; $h = [ordered]@{}; $free = @(); $self = $false; $ids = @($Items | ForEach-Object id | Where-Object { $_ })
  $rxOf = { param($i) "(?<![\w-])$([regex]::Escape($i))(?![\w-])" }
  foreach ($t in @($Tracking.Values | Where-Object { $_.holdPromotion -and ("$($_.task)" -eq $Task -or -not $_.done) })) {
    $own = "$($t.task)" -eq $Task; $hp = "$($t.holdPromotion)".Trim()
    $ps = if ($hp -match '^deferred items:\s*(?<l>.+)$') { @([regex]::Split($Matches.l, ',(?![^()]*\))') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } elseif ($own) { @($hp) } else { @() }
    foreach ($p in $ps) {
      $hit = @($ids | Where-Object { $p -match (& $rxOf $_) })
      foreach ($i in $hit) { $why = ($p -replace (& $rxOf $i)).Trim(" `t:·,;–—-"); if (-not $h.Contains($i)) { $h[$i] = "held: $(if ($why) { $why } else { 'deferred' })" } }
      if ($hit.Count -or -not $own) { continue }
      $tok = ($p -split '[\s:]', 2)[0]
      if ($tok -eq $Task) { $self = $true; continue }
      if ($Tracking.Contains($tok) -or $tok -match '^(?=\S*\d)[A-Za-z][\w.]*(?:-[\w.]+)+$') { continue }   # another task or another task's item (HM-P2-WS01; 'S3 bucket' is text)
      $ph = @($p -split '\s*/\s*' | Where-Object { $_ }); $m = @($Items | Where-Object { $d = "$($_.desc)"; $d -and -not @($ph | Where-Object { $d.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }).Count })
      if ($m.Count -eq 1) { if (-not $h.Contains($m[0].id)) { $h[$m[0].id] = "held: $p" } } else { $free += $p }
    }
  }
  $pl = @(if ((Get-Command Get-KitPlannedAreas -ErrorAction Ignore) -and $Tracking.Contains($Task)) { Get-KitPlannedAreas $Task $Tracking[$Task].planReleased })
  foreach ($it in @($Items)) { $ar = @(@($it.area, $it.id) | Where-Object { $_ -and $pl -contains $_ })[0]; if ($ar -and -not $h.Contains($it.id)) { $h[$it.id] = "not delivered: $ar" } }
  $o = [ordered]@{}; foreach ($i in $ids) { if ($h.Contains($i) -and -not $o.Contains($i)) { $o[$i] = $h[$i] } }   # in item order
  if ($free.Count) { $o[''] = "held: $($free -join '; ')" } elseif ($self -and -not $o.Count) { $o[''] = 'held: deferred' }
  $o
}
# an item with its hold: unticked, its reason as the last ' · ' part; the task-level reason (key '') as one unticked 'held' line
function Set-KitItemHolds($Items, $Holds) {
  @(@($Items) | ForEach-Object { $w = if ($_.id) { $Holds["$($_.id)"] }; if ($w) { $_.text = "$($_.text) · $w"; $_.done = $false }; $_ }) +
  @(if ($Holds -and $Holds['']) { [pscustomobject]@{ id = 'held'; text = "held · $("$($Holds[''])" -replace '^held:\s*')"; done = $false } })
}
# the subtask's note on its parent's Items line: the held item ids, else the task-level reason
function Get-KitHeldNote($Holds) { $k = @($Holds.Keys | Where-Object { $_ }); if ($k.Count) { "held: $($k -join ', ')" } elseif ($Holds -and $Holds['']) { "$($Holds[''])" } else { '' } }
function ConvertTo-KitSpecItems($Spec, [string]$Task) {
  $its = @($Spec.items | Where-Object { $_.code } | ForEach-Object { [pscustomobject]@{ id = "$($_.code)"; desc = "$($_.desc)"; text = (Format-KitItemText "$($_.code)" "$($_.desc)" @($_.mrs)); done = [bool]$_.done } })
  if ($Task -and $its.Count) { $its = @(Set-KitItemHolds $its (Get-KitItemHolds $Task $its)) }; $its
}
# a parent's Items: its spec items + one per subtask "<code> · <name without [Kind]> · <URL>", ticked once closed and not held
# (its heldNote, written with its Items: ' · held: <ids>'); code: the subtask's spec, the parent spec's subtasks[{ id, code }],
# $CodeOf (rollup areas), else its id
function Update-KitParentItems([string]$Parent, $Pt, [hashtable]$CodeOf = @{}) {
  if (-not $Pt) { Clear-TrackerMemo $Parent; $Pt = Get-TrackerTask $Parent }; $subs = @($Pt.subtasks | Where-Object { $_.id }); if (-not $subs.Count) { return }
  $px = Read-KitState (Get-KitTaskFile $Parent); $items = @(ConvertTo-KitSpecItems $px.spec $Parent) + @(foreach ($s in $subs) { $sx = Read-KitState (Get-KitTaskFile $s.id); $sc = $sx.spec.code
      if (-not $sc) { $sc = @($px.spec.subtasks | Where-Object { "$($_.id)" -eq "$($s.id)" } | ForEach-Object code)[0] }
      [pscustomobject]@{ text = "$(Format-KitItemText $(if ($sc) { "$sc" } elseif ($CodeOf[$s.id]) { "$($CodeOf[$s.id])" } else { "$($s.id)" }) ("$($s.name)" -replace '^\s*\[[^\]]*\]\s*') @($s.url))$(if ($sx.heldNote) { " · $($sx.heldNote)" })"
        done = [bool](-not $sx.heldNote -and (Test-TrackerStatus "$($s.status)" 'closed')) } })
  $sig = ConvertTo-KitLetters (@($script:KitItemsSigV) + @($items | ForEach-Object { "$($_.text)|$($_.done)" }) -join ';'); if ($sig -eq "$($px.parentItemsSig)") { return }
  $null = Set-KitTaskChecklist $Parent 'Items' $items -Prune; Update-KitTaskIndex $Parent { param($x) $x.parentItemsSig = $sig; $x.itemsFrom = 'subtasks' }
  "parent items ${Parent}: $(@($items | Where-Object done).Count)/$($items.Count) done"
}
# merge by key: items / subtasks by code, decisions by id; any other field present replaces the stored one
function Merge-KitTaskSpec($Old, $New) {
  $m = [ordered]@{}; foreach ($k in @($Old.Keys)) { $m[$k] = $Old[$k] }
  foreach ($k in @($New.Keys)) {
    $key = @{ items = 'code'; subtasks = 'code'; decisions = 'id' }[$k]
    if (-not $key) { $m[$k] = $New[$k]; continue }
    # copies: the stored spec stays as read; an entry without its key is kept, never dropped (K65)
    $byKey = [ordered]@{}; $loose = @(); foreach ($e in @($m[$k]) + @($New[$k])) { if (-not $e) { continue }; if (-not ($e -is [Collections.IDictionary]) -or -not $e[$key]) { $loose += , $e; continue }
      $id = "$($e[$key])"; if (-not $byKey.Contains($id)) { $byKey[$id] = [ordered]@{} }; foreach ($f in $e.Keys) { $byKey[$id][$f] = $e[$f] } }
    $m[$k] = @(@($byKey.Values) + $loose)
  }
  $m
}
# ---- move: tracker move and group
# tracker move (K54): the adapter's move, then the task state (spec parent / list, a moves log) and the old and new parent's Items
function Move-KitTask([string]$Id, [string]$Parent = '', [string]$List = '', [switch]$Top, [switch]$DryRun) {
  $mvFrom = "$((Get-TrackerTask $Id).parent)"; $mvParent = $Parent; $mvList = $List; $mvTop = [bool]$Top
  $mvOut = Move-TrackerTask $Id -Parent $Parent -List $List -Top:$Top; if ($DryRun) { return $mvOut }
  Update-KitTaskIndex $Id { param($x) if ($x.spec -is [Collections.IDictionary]) { if ($mvTop) { $x.spec.Remove('parent') } elseif ($mvParent) { $x.spec.parent = $mvParent }; if ($mvList) { $x.spec.list = $mvList } }
    $x.moves = @(@($x.moves | Where-Object { $_ }) + [ordered]@{ at = (Get-Date).ToString('o'); from = $mvFrom; parent = $(if ($mvTop) { '' } else { $mvParent }); list = $mvList }) }
  @(@($mvOut) + @(foreach ($p in @($mvFrom, $mvParent) | Where-Object { $_ } | Select-Object -Unique) { try { Update-KitParentItems $p } catch { "parent items ${p}: $($_.Exception.Message)" } }) | Where-Object { $_ }) -join ' · '
}
# tracker group (K54; a wave's related tasks under one ask): the parent from -Spec when missing; a task in the parent's list -> moved
# under it (code: the parent's Items line naming it, its spec code, else its id); another list -> an Items line with its full URL (a
# subtask lives in its parent's list); the parent's spec (subtasks / items) and Items re-rendered; -DryRun: the plan only
function Invoke-KitTaskGroup([string]$Parent, [string[]]$Tasks, $Spec, [switch]$DryRun) {
  if (-not $Parent) {
    if ($DryRun) { return @("would create the parent from the spec ($($Spec.title)), then group: $($Tasks -join ', ')") }
    $Parent = "$((Publish-KitTaskSpec $Spec).id)"; if (-not $Parent) { throw 'tracker group: the parent was not created' } }
  $pt = Get-TrackerTask $Parent; if (-not $pt.name) { throw "tracker group: no task $Parent (UNKNOWN)" }
  $px = Read-KitState (Get-KitTaskFile $Parent); if ($px.spec -isnot [Collections.IDictionary]) { throw "tracker group: $Parent has no kit spec: tracker update $Parent -Spec <json> (crafty.ps1 ""task spec"") first" }
  $its = @($px.spec.items | Where-Object { $_ })
  $plan = @(foreach ($id in @($Tasks | Where-Object { $_ -and $_ -ne $Parent } | Select-Object -Unique)) { $t = Get-TrackerTask $id
      if (-not $t.name) { [pscustomobject]@{ id = $id; how = 'missing'; code = ''; list = '' }; continue }
      $tu = if ($t.url) { "$($t.url)" } else { Get-TrackerUrl $id }   # its URL first; a bare id only when it is no plain number (#12, !12, "12 files")
      $hit = @($its | Where-Object { "$($_.desc) $(@($_.mrs) -join ' ')".Contains($tu) })[0]
      if (-not $hit -and $id -notmatch '^\d+$') { $hit = @($its | Where-Object { "$($_.desc)" -match "(?<![\w!#/-])$([regex]::Escape($id))(?![\w])" })[0] }; $code = "$($hit.code)"
      if (-not $code) { $code = "$((Read-KitState (Get-KitTaskFile $id)).spec.code)" }; if (-not $code) { $code = $id }
      $how = if ("$($t.parent)" -eq $Parent) { 'already' } elseif (-not "$($pt.list)" -or "$($t.list)" -eq "$($pt.list)") { 'subtask' } else { 'link' }
      # short text: the parent's own line for it (URL cut), its subtask entry, else the task name
      $sd = if ($hit) { ("$($hit.desc)" -replace 'https?://\S+' -replace '[\s·,;]+$').Trim() } else { "$(@($px.spec.subtasks | Where-Object { "$($_.id)" -eq $id } | ForEach-Object desc)[0])" }
      [pscustomobject]@{ id = $id; code = "$code"; how = $how; name = $(if ($sd) { $sd } else { "$($t.name)" -replace '^\s*\[[^\]]*\]\s*' }); url = $(if ($t.url) { "$($t.url)" } else { Get-TrackerUrl $id }); list = "$($t.list)" } })
  $lines = @($plan | ForEach-Object { "$($_.how) $($_.id)$(if ($_.code -and $_.code -ne $_.id) { " ($($_.code))" })$(if ($_.how -eq 'link') { " · list $($_.list), parent list $($pt.list): Items link" })" })
  if ($DryRun) { return @("group under $Parent ($($pt.name)):") + $lines }
  $mv = @(foreach ($p in @($plan | Where-Object how -eq 'subtask')) { try { $null = Move-KitTask $p.id -Parent $Parent; $p } catch { $p.how = 'failed'; "  $($p.id): $($_.Exception.Message)" } })
  $subs = @($plan | Where-Object { $_.how -in 'subtask', 'already' }); $subCodes = @($subs | ForEach-Object code)
  # moved: a subtask entry { id, code } (its Items line comes from the subtask); linked: an item with the task URL (mrs: the line's
  # URLs; a URL in desc is cut by Format-KitItemText)
  $lk = @{}; foreach ($p in @($plan | Where-Object how -eq 'link')) { $lk[$p.code] = $p }; $sp = $px.spec
  $sp.items = @(@($its | Where-Object { "$($_.code)" -notin $subCodes } | ForEach-Object { $i = $_; if ($lk.ContainsKey("$($i.code)")) { $i.mrs = @(@($i.mrs) + $lk["$($i.code)"].url | Where-Object { $_ } | Select-Object -Unique); $lk.Remove("$($i.code)") }; $i }) +
    @($lk.Values | ForEach-Object { [ordered]@{ code = $_.code; desc = $_.name; mrs = @($_.url) } }))
  $sp.subtasks = @(@($sp.subtasks | Where-Object { $_ -and "$($_.id)" -notin @($subs | ForEach-Object id) }) + @($subs | ForEach-Object { [ordered]@{ code = $_.code; desc = $_.name; id = $_.id } }))
  Update-KitTaskIndex $Parent { param($x) $x.spec = $sp; $x.parentItemsSig = '' }
  $pub = try { Publish-KitTaskSpec ([ordered]@{}) -Task $Parent } catch { [pscustomobject]@{ parent = "the moves stand; $Parent text not re-rendered: $($_.Exception.Message) -> tracker update $Parent -Spec <shorter items / subtasks desc>" } }
  @("grouped under $Parent ($(Get-TrackerUrl $Parent)): $(@($plan | Where-Object how -eq 'subtask').Count) moved, $(@($plan | Where-Object how -eq 'already').Count) already, $(@($plan | Where-Object how -eq 'link').Count) linked$(if (@($plan | Where-Object how -in 'missing', 'failed').Count) { ", $(@($plan | Where-Object how -in 'missing', 'failed').Count) not grouped" })") + $lines + @($mv | Where-Object { $_ -is [string] }) + @("$($pub.parent)" | Where-Object { $_ })
}
# ---- parent status: a parent follows its open subtasks (owner, 2026-11-18); called by lib.ps1 Set-TrackerStatus, New-TrackerTask, Move-TrackerTask, above every tracker.type
$script:KitStatusRank = [ordered]@{ open = 0; inProgress = 1; failedTesting = 1; review = 2; promoted = 3; inTest = 4; closed = 5 }
# lib.ps1 Set-TrackerStatus (owner, 2026-11-19, 11 flips on one task): why a write is skipped, '' = write. No write equal to the
# current status or this process's last one; no step back (rank) but failedTesting or -Back '<why>' (a new code round on THAT task);
# a parent whose subtasks are open and read follows them (Sync-TrackerParent), failedTesting aside
# UNCHANGED: ... (no write, done) · SKIPPED: ... (refused: callers keep the task open); any open child holds a close too (owner, 2026-11-19)
function Test-KitStatusWrite([string]$Id, [string]$Status, [string]$Back, $Was) {
  $cur = if ($Was.status) { Get-TrackerStatusKey "$($Was.status)" } else { '' }; if (-not $script:KitStatusSet) { $script:KitStatusSet = @{} }
  if ($Status -eq $cur -or (-not $cur -and "$($script:KitStatusSet[$Id])" -eq $Status)) { return "UNCHANGED: $Id status $Status (no write)" }
  $rk = $script:KitStatusRank
  if (-not $Back -and $Status -ne 'failedTesting' -and $rk.Contains($cur) -and $rk.Contains($Status) -and $rk[$Status] -lt $rk[$cur]) { return "SKIPPED: $Id kept '$($Was.status)': $Status is a step back (only failedTesting, or -Back '<why>' for a new code round on it)" }
  $subs = @($Was.subtasks | Where-Object { $_.id }); $open = @($subs | Where-Object { -not (Test-TrackerStatus "$($_.status)" 'closed') })
  if ($Status -eq 'failedTesting' -or -not $open.Count -or @($subs | Where-Object { -not (Get-TrackerStatusKey "$($_.status)") }).Count) { return '' }
  $sy = Sync-TrackerParent -ParentId $Id; "SKIPPED: $Id not set to $Status`: it follows its $($open.Count) open subtask(s)$(if ($sy) { " ($sy)" })"
}
# lib.ps1 Invoke-KitOutbox: a queued status is checked again when sent (the task may have moved on meanwhile)
function Send-KitQueuedStatus([string]$Id, [string]$Status) {
  $sk = Test-KitStatusWrite $Id $Status '' $(try { Clear-TrackerMemo $Id; Get-TrackerTask $Id } catch { $null }); if ($sk) { return "dropped: $sk" }; __Set-TrackerStatus $Id $Status
}
# after a write (not a queued or dry one): this process's memo, then the parent follows its children
function Complete-KitStatusWrite([string]$Id, [string]$Status, $R, $Was) {
  if ("$R" -match '^QUEUED' -or $__trDry) { return }; $script:KitStatusSet[$Id] = $Status
  if ($Was.parent) { $null = Sync-TrackerParent $Id (Resolve-TrackerStatus $Status) -ParentId "$($Was.parent)" -Reopen:(Test-TrackerStatus "$($Was.status)" 'closed') }
}
function Get-TrackerStatusKey([string]$Name) { foreach ($k in @($__trStatus.Keys)) { if (@($__trStatus[$k]) | Where-Object { $_ -ieq "$Name".Trim() }) { return $k } }; '' }
# the status a parent should have: the least advanced of its open subtasks, back too (a child's new fix round);
# a closed parent opens again for a new child or a reopened one (-Reopen); '' = leave it
function Get-KitParentStatusTarget([string]$ParentKey, [string[]]$ChildKeys, [switch]$NewChild, [switch]$Reopen) {
  $rk = $script:KitStatusRank; if (-not $rk.Contains($ParentKey)) { return '' }
  $open = @($ChildKeys | Where-Object { $_ -and $rk.Contains($_) -and $_ -ne 'closed' }); if (-not $open.Count) { return '' }
  $t = @($open | Sort-Object { $rk[$_] })[0]; if ($t -eq 'failedTesting') { $t = 'inProgress' }
  $go = if ($ParentKey -eq 'closed') { $NewChild -or $Reopen } else { $rk[$t] -ne $rk[$ParentKey] }   # both ways (owner 2026-11-19: a parent always equals its least complete open child)
  if ($go -and $t -ne $ParentKey) { $t } else { '' }
}
# -ChildId / -ChildStatus: the change just made (a tracker may still show the old one); no child: the parent's own subtasks as read.
# -ParentId: known by the caller. -DryRun: returns the plan, writes nothing. Never throws: the caller's write has already happened.
function Sync-TrackerParent([string]$ChildId, [string]$ChildStatus, [string]$ParentId, [switch]$NewChild, [switch]$Reopen, [switch]$DryRun, [int]$Depth = 0) {
  if ($__trDry -or $Depth -gt 3) { return }
  try {
    if (-not $ParentId -and $ChildId) { $ParentId = "$((Get-TrackerTask $ChildId).parent)" }; if (-not $ParentId) { return }
    Clear-TrackerMemo $ParentId; $p = Get-TrackerTask $ParentId; if (-not $p.name) { return }
    $nid = { param($x) "$x".Trim() -replace '^(?:.*#|CU-)' }; $found = $false
    $keys = @(foreach ($s in @($p.subtasks)) { if ($ChildStatus -and $ChildId -and (& $nid $s.id) -eq (& $nid $ChildId)) { $found = $true; Get-TrackerStatusKey $ChildStatus } else { Get-TrackerStatusKey "$($s.status)" } })
    if ($ChildStatus -and $ChildId -and -not $found) { $keys += Get-TrackerStatusKey $ChildStatus }   # a tracker may not list the child yet; no status given (a move): as the tracker shows it
    if (@($keys | Where-Object { -not $_ }).Count) { return }   # a subtask status the kit does not know (custom, empty): guess nothing
    $from = Get-TrackerStatusKey "$($p.status)"; $t = Get-KitParentStatusTarget $from $keys -NewChild:$NewChild -Reopen:$Reopen
    if (-not $t -or (Test-TrackerStatusOff $t)) { return }
    $plan = "parent ${ParentId}: $($p.status) -> $(Resolve-TrackerStatus $t) (follows its open subtasks)"
    if ($DryRun) { return $plan }
    Invoke-TrackerWrite 'status' $ParentId $t { __Set-TrackerStatus $ParentId $t } | Out-Null; Write-KitLog calls parent-status @{ task = $ParentId; from = "$($p.status)"; to = $t }
    Write-Host "tracker: $plan"
    if ($p.parent) { $null = Sync-TrackerParent $ParentId (Resolve-TrackerStatus $t) -ParentId "$($p.parent)" -Depth ($Depth + 1) }
    $plan
  } catch { Write-Warning "tracker: parent status of $ParentId not synced: $("$_".Split("`n")[0])" }
}
# ---- task text: kind prefixes, the task template and its gaps (lib.ps1 New-TrackerTask checks them)
# missing labels of a task text (templates.md task-description; -Subtask: Items too); a [Bug] keeps its own shape
function Get-KitTaskTextGaps([string]$Name, [string]$Text, [switch]$Subtask) {
  if (-not "$Text".Trim()) { return @('a description') }; if (Test-KitBugName $Name) { return @() }
  @(foreach ($sec in @(Get-KitTaskTemplate)) { if ("$($sec.required)" -eq 'subtask' -and -not $Subtask) { continue }; if ("$($sec.required)" -eq 'False') { continue }
      $lb = (@($sec.label) + @($sec.alt) | Where-Object { $_ } | ForEach-Object { [regex]::Escape("$_") }) -join '|'
      if ($Text -notmatch "(?im)^(?:\s*\d+[.)])?\W{0,6}(?:$lb)\b(?:\s+\w+){0,2}(?:\s*\([^)\r\n]*\))?\W{0,3}(?::|\s+[-–—]|\s*$)") { "$($sec.label)" } })
}
# tracker.kindPrefixes (kind -> name prefix; bug: tracker.bugPrefix), tracker.nameFormat, tracker.taskTemplate: today's kit shapes by default
function Get-KitKindPrefix([string]$Kind) {
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $p = if ($kp) { @((Get-KitProps $kp) | Where-Object { $_.Name -ieq $Kind } | ForEach-Object { "$($_.Value)" })[0] }
  if ($p) { $p } elseif ($Kind -ieq 'bug') { [string](Get-KitSetting 'tracker.bugPrefix' '[Bug]') } elseif ($Kind) { "[$Kind]" } else { '' }
}
function Test-KitKindName([string]$Name) {   # a kit-rendered kind (tracker.kindPrefixes)
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $ks = @('feature', 'chore') + @(if ($kp) { (Get-KitProps $kp).Name }) | Where-Object { $_ -ine 'bug' } | Select-Object -Unique
  $n = "$Name".TrimStart(); [bool]@($ks | Where-Object { $n.StartsWith((Get-KitKindPrefix $_), 'OrdinalIgnoreCase') }).Count
}
function Test-KitBugName([string]$Name) { $p = Get-KitKindPrefix 'bug'; $n = "$Name".TrimStart(); ($p -and $n.StartsWith($p, 'OrdinalIgnoreCase')) -or $n -match '^\W*Bug\]' }
function Get-KitTaskTemplate {
  $t = @(Get-KitSetting 'tracker.taskTemplate' $null | Where-Object { $_ -and $_.label })
  if ($t.Count) { return $t }
  @([pscustomobject]@{ key = 'problem'; label = 'Problem'; required = $true }, [pscustomobject]@{ key = 'goal'; label = 'Goal'; required = $true },
    [pscustomobject]@{ key = 'items'; label = 'Items'; alt = 'Bugs'; required = 'subtask' }, [pscustomobject]@{ key = 'acceptance'; label = 'Acceptance'; required = $true },
    [pscustomobject]@{ key = 'links'; label = 'Links'; required = $true })
}
