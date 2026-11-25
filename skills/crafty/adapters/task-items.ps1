#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (tracker writes throw).
# task Items checklists: write one (adapter verb checklist, else a description section), item holds (counts match the task
# state), spec items, the parent's line per subtask; item text: lib.ps1 Format-KitItemText; rollup: bossy adapters/task-rollup.ps1;
# tracker move / group (K54)
# Sections: L8 items · L93 move · L136 status roles · L295 task text · L312 naming · L456 track lines · L461 task ids ·
#   L477 tags · L542 order
# ---- items: checklists, holds, the parent's Items
$script:KitItemsSigV = 'prune1'   # in every Items signature: a new value rewrites each list once (prunes lines older writers left)
# a named checklist on a task ({ text; done }; items keyed by the text before the first ' · '; done = false unticks): adapter verb
# checklist, else a <!-- kit:<name> --> description section (always the whole list); -Prune: kit lines ('<key> · ...') not in $Items and repeats go;
# -KeepDone: a ticked line stays even when pruned
function Set-KitTaskChecklist([string]$Task, [string]$Name, $Items, [switch]$Prune, [switch]$KeepDone) {
  $seen = @{}; $Items = @($Items | Where-Object { $ky = ("$($_.text)" -split ' · ', 2)[0].Trim(); -not $seen[$ky]++ })   # one line per key
  if (__TrCan checklist) { return __TrA 'checklist' @{ id = $Task; name = $Name; prune = [bool]$Prune; keepDone = [bool]$KeepDone; items = @($Items | ForEach-Object { @{ text = $_.text; done = [bool]$_.done } }) } }
  Set-KitDescChecklist $Task $Name $Items -KeepDone:$KeepDone
}
# the checklist as a markdown task list in a <!-- kit:<name> --> description section (the whole list; GitHub / GitLab render it as
# their native checkboxes, other trackers as text): kit lines not in $Items go, -KeepDone keeps a ticked one
function Set-KitDescChecklist([string]$Task, [string]$Name, $Items, [switch]$KeepDone) {
  Clear-TrackerMemo $Task; $tk = Get-TrackerTask $Task; if (-not $tk.name) { throw "tracker read of $Task failed" }
  $sx = [regex]::Match(("$($tk.description)" -replace "`r`n", "`n"), "(?s)<!-- kit:$([regex]::Escape($Name.ToLower())) -->\n(.*?)\n<!-- /kit:"); $wk = @($Items | ForEach-Object { ("$($_.text)" -split ' · ', 2)[0].Trim() })
  $gone = @(if ($sx.Success) { @($sx.Groups[1].Value -split "`n" | Where-Object { $_ -match '^- \[( |x)\] (?<t>.+)$' -and $wk -notcontains ($Matches.t -split ' · ', 2)[0].Trim() } ) })
  $kd = @(if ($KeepDone) { @($gone | Where-Object { $_ -like '- `[x`]*' }) })
  $nd = Set-KitDescSection $tk.description $Name.ToLower() ((@("**$Name**") + @($Items | ForEach-Object { "- [$(if ($_.done) { 'x' } else { ' ' })] $($_.text)" }) + $kd) -join "`n") ''
  if ($nd -ne ("$($tk.description)" -replace "`r`n", "`n")) { $null = Set-TrackerDescription $Task $nd }
  "checklist $Name on ${Task}: $($gone.Count - $kd.Count) removed"
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
  $null = Set-KitTaskChecklist $Parent (Get-KitItemsLabel) $items -Prune; Update-KitTaskIndex $Parent { param($x) $x.parentItemsSig = $sig; $x.itemsFrom = 'subtasks' }
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
    $x.moves = @(@($x.moves | Where-Object { $_ }) + [ordered]@{ at = (Get-KitStamp); from = $mvFrom; parent = $(if ($mvTop) { '' } else { $mvParent }); list = $mvList }) }
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
# ---- status roles: fixed roles, the transition table, live names per scope (owner, 2026-11-19); lib.ps1 Set-TrackerStatus,
# Resolve-TrackerStatus, Test-TrackerStatus read them for every tracker.type
$script:KitStatusRoles = @('open', 'inProgress', 'review', 'failedReview', 'promoted', 'inTest', 'failedTesting', 'closed')
$script:KitStatusRank = [ordered]@{ open = 0; inProgress = 1; failedReview = 1; failedTesting = 1; review = 2; promoted = 3; inTest = 4; closed = 5 }
# the moves besides a forward one (rank up, never into a failed role); promoted -> failedTesting: QA found the change undeployed
$script:KitStatusEdges = @{ review = @('failedReview', 'inProgress'); failedReview = @('inProgress'); promoted = @('failedTesting'); inTest = @('failedTesting'); failedTesting = @('inProgress') }
function Test-KitStatusEdge([string]$From, [string]$To) {
  $rk = $script:KitStatusRank; if (-not $rk.Contains($From) -or -not $rk.Contains($To)) { return $true }   # a role the kit cannot read: no guess
  ($To -in @($script:KitStatusEdges[$From])) -or ($To -notin 'failedReview', 'failedTesting' -and $rk[$To] -gt $rk[$From])
}
# a scope = tracker.type + its container (ClickUp list, Jira project, Linear team, repo); adapter verb statuses = its live names
# ({ name, type }), cached a day (Get-KitPath tracker-statuses; again on an unknown name); tracker.statusMap.<scope>.<role>
# overrides (a name, a list, null = no such step; .other = names that are no role); tracker.statuses = the names of a scope without them
$script:KitScopeRoles = @{}
function Get-KitScopeRoles([string]$Scope, [switch]$Refresh) {
  $Scope = "$Scope".Trim(); if (-not $Scope) { return $null }
  $key = "$__trType|$Scope"; if (-not $Refresh -and $script:KitScopeRoles.ContainsKey($key)) { return $script:KitScopeRoles[$key] }
  $f = Join-Path (Get-KitPath tracker-statuses -Create) "$("$__trType-$Scope" -replace '[^\w.-]', '_').json"
  $c = if (-not $Refresh -and (Test-Path -LiteralPath $f) -and ((Get-Date) - [IO.File]::GetLastWriteTime($f)).TotalHours -lt [double](Get-KitParam 'tracker.statusCacheHours')) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
  $live = if ($c) { @($c.statuses) } else { $null }; $ad = $KitAdapters['tracker'][$__trType]
  if (-not $c -and -not $__trDry -and $ad -and ((__TrCan statuses) -or ($ad.ContainsKey('*') -and $__trType -ne 'command'))) {
    $live = try { @(__TrA 'statuses' @{ scope = $Scope } | Where-Object { "$($_.name)".Trim() } | ForEach-Object { [pscustomobject]@{ name = "$($_.name)".Trim(); type = "$($_.type)".ToLower() } }) } catch { Write-Warning "tracker ($__trType): statuses of $Scope not read ($("$_".Split("`n")[0])): default names"; $null }
    if (@($live).Count) { [IO.File]::WriteAllText($f, ([ordered]@{ scope = $Scope; type = $__trType; at = (Get-KitStamp); statuses = @($live) } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) } else { $live = $null }
  }
  $m = ConvertTo-KitScopeRoles $Scope $live; $m.fresh = -not $c; $script:KitScopeRoles[$key] = $m; $m
}
function ConvertTo-KitStatusWord([string]$Name) { ("$Name" -replace '[^\p{L}\p{N}]', '').ToLower() }
# live names -> roles: an override, else the role's default names found live, else (open, closed) the tracker's own open / done type
function ConvertTo-KitScopeRoles([string]$Scope, $Live) {
  $ov = Get-KitMember (Get-KitSetting 'tracker.statusMap' $null) $Scope; $set = @(if ($ov) { (Get-KitProps $ov).Name })
  $roles = [ordered]@{}
  foreach ($r in $script:KitStatusRoles) {
    $want = @($(if ($r -in $set) { Get-KitMember $ov $r } else { $__trStatus[$r] }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_" }); $ww = @($want | ForEach-Object { ConvertTo-KitStatusWord $_ })
    $roles[$r] = @(@(if ($null -eq $Live -or $r -in $set) { $want } else { foreach ($w in $ww) { $Live | Where-Object { (ConvertTo-KitStatusWord $_.name) -eq $w } | ForEach-Object name } }) | Select-Object -Unique)   # the default order: the first one is written
  }
  foreach ($t in @(@{ r = 'open'; k = 'open', 'new', 'unstarted' }, @{ r = 'closed'; k = 'closed', 'done', 'completed' })) {
    if ($Live -and $t.r -notin $set -and -not $roles[$t.r].Count) { $roles[$t.r] = @($Live | Where-Object { $_.type -in $t.k } | Select-Object -First 1 | ForEach-Object name) } }
  $other = @($(if ('other' -in $set) { Get-KitMember $ov 'other' } else { $script:KitVocab.statusOther }) | Where-Object { "$_".Trim() })
  $known = @(@($roles.Values | ForEach-Object { $_ }) + $other | ForEach-Object { ConvertTo-KitStatusWord $_ })
  [pscustomobject]@{ scope = $Scope; live = $null -ne $Live; names = @($Live | ForEach-Object name); roles = $roles; other = $other; fresh = $false
    unmapped = @(if ($Live) { $Live | Where-Object { (ConvertTo-KitStatusWord $_.name) -notin $known } | ForEach-Object name }) }
}
# github / gitlab statuses: open, closed, each status label, and every role's default name (its label is made on the first write)
function __TrLabelLive([string[]]$Labels) {
  $ls = @($Labels | Where-Object { "$_" -like "$__trLp*" } | ForEach-Object { "$_".Substring($__trLp.Length) })
  @([pscustomobject]@{ name = "$(@($__trStatus.open)[0])"; type = 'open' }; [pscustomobject]@{ name = "$(@($__trStatus.closed)[0])"; type = 'closed' }
    @($ls) + @(foreach ($r in @($__trStatus.Keys | Where-Object { $_ -notin 'open', 'closed' })) { if (-not @($ls | Where-Object { $_ -in @($__trStatus[$r]) }).Count) { @($__trStatus[$r])[0] } }) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ name = $_; type = 'custom' } })
}
# crafty.ps1 tracker roles <scope> (read live, cache renewed): one line per role, the live names of no role, the unmapped ones (exit 1)
function Show-KitScopeRoles([string]$Scope) {
  if (-not $Scope) { 'tracker: usage: tracker roles <scope: list / project / team id, repo>'; exit 2 }; $M = Get-KitScopeRoles $Scope -Refresh
  "scope $($M.scope) ($__trType, $(if ($M.live) { 'live names' } else { 'default names: no live list' })):"
  foreach ($r in @($M.roles.Keys)) { '  {0,-14} {1}' -f $r, $(if (@($M.roles[$r]).Count) { @($M.roles[$r]) -join ' / ' } else { '- (step skipped)' }) }
  $o = @($M.names | Where-Object { $_ -in $M.other }); if ($o.Count) { '  {0,-14} {1}' -f 'other (no role)', ($o -join ' / ') }
  if ($M.unmapped.Count) { "UNMAPPED: $($M.unmapped -join ', '): kit.local.json tracker.statusMap.$($M.scope).<role> (or .other)"; exit 1 }
}
# bossy.ps1 supervise: one WATCH per cached scope with live names of no role
function Get-KitScopeWatch {
  foreach ($m in @(Get-KitCachedScopeRoles | Where-Object { @($_.unmapped).Count })) { [pscustomobject]@{ what = "tracker scope $($m.scope): status(es) $(@($m.unmapped | ForEach-Object { "'$_'" }) -join ', ') map to no role"
      action = "kit.local.json tracker.statusMap.$($m.scope).<role> = '<name>' (.other: names that are no role); check: crafty.ps1 tracker roles $($m.scope)" } }
}
# bossy.ps1 supervise failedTesting: the ids still back in the dev flow; a cached view says so -> the live role decides (a person
# may have closed it since, 2026-11-19); the live view renews the cache
function Select-KitFailedLive([string[]]$Ids, $Trk, $Cache) {
  $bk = { param($id, $st, $sc) (Test-TrackerStatus $st 'failedTesting' $sc) -or ($Trk[$id].done -and (Test-TrackerStatus $st 'inProgress' $sc)) }
  foreach ($id in $Ids) {
    if (-not (& $bk $id "$($Cache[$id].st)")) { continue }; $lv = try { Clear-TrackerMemo $id; Get-TrackerTask $id } catch { $null }
    if ($lv.status) { $Cache[$id] = @{ at = (Get-KitStamp); st = "$($lv.status)" }; if (-not (& $bk $id "$($lv.status)" "$($lv.list)")) { continue } }; $id }
}
# every cached scope (supervise WATCH on unmapped names; a status read without its scope)
function Get-KitCachedScopeRoles {
  if ($null -eq $script:KitScopeAll) { $script:KitScopeAll = @(Get-ChildItem (Get-KitPath tracker-statuses) -Filter "$__trType-*.json" -ErrorAction SilentlyContinue | ForEach-Object { try { "$((Get-Content $_.FullName -Raw | ConvertFrom-Json).scope)" } catch { } } | Where-Object { $_ } | ForEach-Object { Get-KitScopeRoles $_ }) }
  $script:KitScopeAll
}
# a raw status name (no kit role) the scope's live list lacks: the refusal, before the tracker call (retro tidy-20261124-03: failedReview)
function Test-KitScopeStatus([string]$Scope, [string]$Status) {
  if (-not $Scope -or $__trStatus.Contains($Status) -or -not ($m = Get-KitScopeRoles $Scope) -or -not @($m.names).Count) { return '' }
  if (@($m.names | Where-Object { (ConvertTo-KitStatusWord $_) -eq (ConvertTo-KitStatusWord $Status) }).Count) { return '' }
  "scope $Scope has no status '$Status' (its statuses: $(@($m.names) -join ', '); a kit role: crafty.ps1 tracker roles $Scope)"
}
# a role's names in a scope ([] = the scope lacks it: skip that step), else the default names
function Get-KitRoleNames([string]$Role, [string]$Scope) {
  $m = if ($Scope) { Get-KitScopeRoles $Scope }; if ($m -and $m.roles.Contains($Role)) { return @($m.roles[$Role]) }
  @($__trStatus[$Role] | Where-Object { $_ })
}
function Find-KitRoleOf($Roles, [string]$Name) { $w = ConvertTo-KitStatusWord $Name; foreach ($k in @($Roles.Keys)) { if (@($Roles[$k] | Where-Object { (ConvertTo-KitStatusWord $_) -eq $w }).Count) { return $k } }; '' }
# a live name -> its role: the task's scope (read again once on an unknown name), the default names, then any cached scope; '' = none
function Get-TrackerStatusKey([string]$Name, [string]$Scope) {
  if (-not "$Name".Trim()) { return '' }
  if ($Scope -and ($m = Get-KitScopeRoles $Scope)) { $k = Find-KitRoleOf $m.roles $Name; if (-not $k -and $m.live -and -not $m.fresh -and $Name -notin $m.other) { $k = Find-KitRoleOf (Get-KitScopeRoles $Scope -Refresh).roles $Name }; if ($k) { return $k } }
  $k = Find-KitRoleOf $__trStatus $Name; if ($k) { return $k }
  foreach ($m in @(Get-KitCachedScopeRoles)) { $k = Find-KitRoleOf $m.roles $Name; if ($k) { return $k } }; ''
}
# a writing agent owns a task's code round from its inProgress / review write until promoted; a live owner blocks other agents
# (sibling or other-area MRs); the coordinator, supervise and people (no agent id) always write
function Get-KitStatusWriter { $a = "$(if ($script:KitWho) { $script:KitWho.agent })"; if ($a -and $a -notmatch '^(main|coordinator|supervise)$') { $a } else { '' } }
# lib.ps1 Set-TrackerStatus (owner, 2026-11-19, 11 flips on one task): why a write is skipped, '' = write. No write equal to the
# current status or this process's last one; only a role transition (Test-KitStatusEdge) but -Back '<why>' (a new code round on
# THAT task); a parent whose subtasks are open and read follows them (Sync-TrackerParent), failedTesting aside
# UNCHANGED: ... (no write, done) · SKIPPED: ... (refused: callers keep the task open); any open child holds a close too (owner, 2026-11-19)
function Test-KitStatusWrite([string]$Id, [string]$Status, [string]$Back, $Was) {
  $sc = "$($Was.list)"; $cur = if ($Was.status) { Get-TrackerStatusKey "$($Was.status)" $sc } else { '' }; if (-not $script:KitStatusSet) { $script:KitStatusSet = @{} }
  if ($Status -eq $cur -or (-not $cur -and "$($script:KitStatusSet[$Id])" -eq $Status)) { return "UNCHANGED: $Id status $Status (no write)" }
  $ag = Get-KitStatusWriter; $own = if ($ag -and $cur -in 'inProgress', 'review', 'failedReview') { "$((Read-KitState (Get-KitTaskFile $Id)).statusOwner)" }   # past review (a person moved it): no round to own
  if ($own -and $own -ne $ag -and (Test-KitLive @{ agent = $own })) { return "SKIPPED: $Id kept '$($Was.status)': $own owns its code round, not $ag" }
  if (-not $Back -and $cur -and -not (Test-KitStatusEdge $cur $Status)) { return "SKIPPED: $Id kept '$($Was.status)': $cur -> $Status is no role transition (a new code round on it: -Back '<why>')" }
  $subs = @($Was.subtasks | Where-Object { $_.id }); $open = @($subs | Where-Object { -not (Test-TrackerStatus "$($_.status)" 'closed') })
  if ($Status -eq 'failedTesting' -or -not $open.Count -or @($subs | Where-Object { -not (Get-TrackerStatusKey "$($_.status)" $sc) }).Count) { return '' }
  $sy = Sync-TrackerParent -ParentId $Id; "SKIPPED: $Id not set to $Status`: it follows its $($open.Count) open subtask(s)$(if ($sy) { " ($sy)" })"
}
# lib.ps1 Invoke-KitOutbox: a queued status is checked again when sent (the task may have moved on meanwhile)
function Send-KitQueuedStatus([string]$Id, [string]$Status) {
  $w = try { Clear-TrackerMemo $Id; Get-TrackerTask $Id } catch { $null }; $sk = Test-KitStatusWrite $Id $Status '' $w; if ($sk) { return "dropped: $sk" }; __Set-TrackerStatus $Id $Status "$($w.list)"
}
# after a write (not a queued or dry one): this process's memo, the round's owner, then the parent follows its children
function Complete-KitStatusWrite([string]$Id, [string]$Status, $R, $Was, [string]$Back) {
  if ("$R" -match '^QUEUED' -or $__trDry) { return }; $script:KitStatusSet[$Id] = $Status
  $ag = Get-KitStatusWriter; try { $tf = Get-KitTaskFile $Id   # the tracker write stands: an index failure never fails it
    if ($Status -in 'promoted', 'inTest', 'closed' -and (Read-KitState $tf).statusOwner) { Update-KitTaskIndex $Id { param($x) $x.Remove('statusOwner') } }
    elseif ($ag -and $Status -in 'inProgress', 'review' -and ($Back -or -not (Read-KitState $tf).statusOwner)) { Update-KitTaskIndex $Id { param($x) $x.statusOwner = $ag } } } catch { Write-Warning "tracker: round owner of $Id not kept: $_" }
  if ($Was.parent) { $null = Sync-TrackerParent $Id (Resolve-TrackerStatus $Status) -ParentId "$($Was.parent)" -Reopen:(Test-TrackerStatus "$($Was.status)" 'closed') }
  # env tags follow the status (kitbag.py TAG_GROUPS): promoted waits for a deploy; in test: deploys.ps1 sets on-<env>; closed: no env / decision
  $tg = switch ($Status) { 'promoted' { @('env=needs-deploy') } 'closed' { @('env=-', 'decision=-') } { $_ -in 'inProgress', 'failedTesting', 'failedReview' } { @('env=-') } }
  if ($tg) { $null = Set-KitTaskTags $Id $tg -Soft }
}
# the status a parent should have: the least advanced of its open subtasks, back too (a child's new fix round);
# a closed parent opens again for a new child or a reopened one (-Reopen); '' = leave it
function Get-KitParentStatusTarget([string]$ParentKey, [string[]]$ChildKeys, [switch]$NewChild, [switch]$Reopen) {
  $rk = $script:KitStatusRank; if (-not $rk.Contains($ParentKey)) { return '' }
  $open = @($ChildKeys | Where-Object { $_ -and $rk.Contains($_) -and $_ -ne 'closed' }); if (-not $open.Count) { return '' }
  $t = @($open | Sort-Object { $rk[$_] })[0]; if ($t -in 'failedTesting', 'failedReview') { $t = 'inProgress' }
  $go = if ($ParentKey -eq 'closed') { $NewChild -or $Reopen } else { $rk[$t] -ne $rk[$ParentKey] }   # both ways (owner 2026-11-19: a parent always equals its least complete open child)
  if ($go -and $t -ne $ParentKey) { $t } else { '' }
}
# one id two ways (a URL fragment '...#id', the branch tag of tracker.branchTag / vocab trackers.<type>): the bare id to compare
function ConvertTo-KitTrackerKey([string]$Id) {
  $v = "$Id".Trim() -replace '^.*#'; if ($KitConf.TrackerTag) { $v = $v -replace ('^' + [regex]::Escape($KitConf.TrackerTag)) }; $v
}
# -ChildId / -ChildStatus: the change just made (a tracker may still show the old one); no child: the parent's own subtasks as read.
# -ParentId: known by the caller. -DryRun: returns the plan, writes nothing. Never throws: the caller's write has already happened.
function Sync-TrackerParent([string]$ChildId, [string]$ChildStatus, [string]$ParentId, [switch]$NewChild, [switch]$Reopen, [switch]$DryRun, [int]$Depth = 0) {
  if ($__trDry -or $Depth -gt 3) { return }
  try {
    if (-not $ParentId -and $ChildId) { $ParentId = "$((Get-TrackerTask $ChildId).parent)" }; if (-not $ParentId) { return }
    Clear-TrackerMemo $ParentId; $p = Get-TrackerTask $ParentId; if (-not $p.name) { return }
    $nid = { param($x) ConvertTo-KitTrackerKey $x }; $found = $false
    $keys = @(foreach ($s in @($p.subtasks)) { if ($ChildStatus -and $ChildId -and (& $nid $s.id) -eq (& $nid $ChildId)) { $found = $true; Get-TrackerStatusKey $ChildStatus } else { Get-TrackerStatusKey "$($s.status)" } })
    if ($ChildStatus -and $ChildId -and -not $found) { $keys += Get-TrackerStatusKey $ChildStatus }   # a tracker may not list the child yet; no status given (a move): as the tracker shows it
    if (@($keys | Where-Object { -not $_ }).Count) { return }   # a subtask status the kit does not know (custom, empty): guess nothing
    $from = Get-TrackerStatusKey "$($p.status)" "$($p.list)"; $t = Get-KitParentStatusTarget $from $keys -NewChild:$NewChild -Reopen:$Reopen
    if (-not $t -or (Test-TrackerStatusOff $t) -or ("$($p.list)" -and -not @(Get-KitRoleNames $t "$($p.list)").Count)) { return }   # a role its scope lacks: never invented
    $plan = "parent ${ParentId}: $($p.status) -> $(Resolve-TrackerStatus $t) (follows its open subtasks)"
    if ($DryRun) { return $plan }
    Invoke-TrackerWrite 'status' $ParentId $t { __Set-TrackerStatus $ParentId $t "$($p.list)" } | Out-Null; Write-KitLog calls parent-status @{ task = $ParentId; from = "$($p.status)"; to = $t }
    Write-Host "tracker: $plan"
    if ($p.parent) { $null = Sync-TrackerParent $ParentId (Resolve-TrackerStatus $t) -ParentId "$($p.parent)" -Depth ($Depth + 1) }
    $plan
  } catch { Write-Warning "tracker: parent status of $ParentId not synced: $("$_".Split("`n")[0])" }
}
# ---- task text: kind prefixes, the task template and its gaps (lib.ps1 New-TrackerTask checks them)
# missing labels of a task text (templates.md task-description; -Subtask: Items too); a [Bug] keeps its own shape
function Get-KitTaskTextGaps([string]$Name, [string]$Text, [switch]$Subtask, [switch]$Bug) {   # -Bug: a keyed bug (its kind is a tag)
  if (-not "$Text".Trim()) { return @('a description') }; if ($Bug -or (Test-KitBugName $Name)) { return @() }
  @(foreach ($sec in @(Get-KitTaskTemplate)) { if ("$($sec.required)" -eq 'subtask' -and -not $Subtask) { continue }; if ("$($sec.required)" -eq 'False') { continue }
      $lb = (@($sec.label) + @($sec.alt) | Where-Object { $_ } | ForEach-Object { [regex]::Escape("$_") }) -join '|'
      if ($Text -notmatch "(?im)^(?:\s*\d+[.)])?\W{0,6}(?:$lb)\b(?:\s+\w+){0,2}(?:\s*\([^)\r\n]*\))?\W{0,3}(?::|\s+[-–—]|\s*$)") { "$($sec.label)" } })
}
# tracker.kindPrefixes (kind -> name prefix; bug: tracker.bugPrefix), tracker.nameFormat, tracker.taskTemplate: today's kit shapes by default
function Get-KitKindPrefix([string]$Kind) {
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $p = if ($kp) { @((Get-KitProps $kp) | Where-Object { $_.Name -ieq $Kind } | ForEach-Object { "$($_.Value)" })[0] }
  if ($p) { $p } elseif ($Kind -ieq 'bug') { [string](Get-KitSetting 'tracker.bugPrefix' '[Bug]') } elseif ($Kind) { "[$((Get-Culture).TextInfo.ToTitleCase($Kind.ToLower()))]" } else { '' }   # feature -> [Feature]
}
function Test-KitKindName([string]$Name) {   # a kit-rendered kind (tracker.kindPrefixes)
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $ks = @('feature', 'chore') + @(if ($kp) { (Get-KitProps $kp).Name }) | Where-Object { $_ -ine 'bug' } | Select-Object -Unique
  $n = "$Name".TrimStart(); [bool]@($ks | Where-Object { $n.StartsWith((Get-KitKindPrefix $_), 'OrdinalIgnoreCase') }).Count
}
# ---- naming: the kit key (kitbag.py naming, kit.local.json naming) at a name's start: <KEY> <outcome> (+ tags)
function Get-KitNameKey([string]$Name) { if ("$Name".TrimStart() -cmatch '^([A-Z]{2,6}-[A-Z]{2,6}-\d{2,})(?:\.\d+)?(?=\s|$)') { $Matches[1] } else { '' } }
function Remove-KitNameKey([string]$Name) { "$Name".TrimStart() -creplace '^[A-Z]{2,6}-[A-Z]{2,6}-\d{2,}(?:\.\d+)?\s+', '' }
function Test-KitNamingOn { [bool]@(Get-KitProps (Get-KitSetting 'naming.areas' $null)).Count }
# kitbag.py naming <verb> ...: its last stdout line, or a throw with its refusal
function Invoke-KitNaming([string[]]$Argv) {
  $lec = $global:LASTEXITCODE; $o = @(& (Get-Python) -X utf8 $KitCmd.kitbag naming @Argv 2>&1 | ForEach-Object { "$_" }); $rc = $global:LASTEXITCODE; $global:LASTEXITCODE = $lec
  if ($rc) { throw "kitbag.py naming $($Argv -join ' '): $($o -join ' ')" }; "$($o[-1])".Trim()
}
# owner 2026-11-24: a name says what it is, a number only breaks a tie; never a date or padding. -Dir: skips one whose <id>,
# <id>.json or <id>.md exists there. New-KitName: <kind>-<topic> <= 12 chars (tie -2; -Dir: vs that folder); New-KitId: <kind>-<n> where no word names it
function New-KitName([string]$Kind, [string]$Topic = '', [string]$Dir, [int]$Cap = 12) {
  $nid = Invoke-KitNaming (@('next', 'name', $Kind, $Topic, '--cap', $Cap) + @(if ($Dir) { '--dir', $Dir }))
  if ($nid -notmatch "^$([regex]::Escape($Kind))(?:-[a-z0-9]+)*$") { throw "kitbag.py naming next name $Kind gave '$nid'" }; $nid
}
# the one normaliser's shown form (kitbag.py naming shown, owner 2026-11-25): '<role>-<topic words> · <lowercase plain words>';
# Register-KitShownNames: one batch call for a page's rows, Get-KitShownName: memo hit (a miss: one call). Rows: @(kind, name, topic, role)
function Register-KitShownNames($Rows) { if ($script:KitShown -isnot [hashtable]) { $script:KitShown = @{} }
  if (@($Rows).Count -and @($Rows)[0] -is [string]) { $Rows = @(, @($Rows)) }   # one row: @() flattened it
  $miss = @(@($Rows) | Where-Object { $_ -and "$($_[1])" } | ForEach-Object { , @("$($_[0])", "$($_[1])", "$(@($_)[2])", "$(@($_)[3])") } | Where-Object { -not $script:KitShown.ContainsKey($_ -join "`t") })
  if (-not $miss.Count) { return }
  $inF = New-KitTempFile '.json'; [IO.File]::WriteAllText($inF, (ConvertTo-Json -InputObject @($miss | ForEach-Object { , $_ }) -Depth 3 -Compress))
  try { $outL = Invoke-KitNaming @('shown', '--in', $inF); $got = @($outL | ConvertFrom-Json) } catch { $got = @() } finally { Remove-Item -LiteralPath $inF -ErrorAction SilentlyContinue }
  for ($si = 0; $si -lt $miss.Count; $si++) { $script:KitShown[$miss[$si] -join "`t"] = $(if ($si -lt $got.Count -and "$($got[$si])") { "$($got[$si])" } else { $miss[$si][1] }) }   # no python: the name as given
}
function Get-KitShownName([string]$Kind, [string]$Name, [string]$Topic = '', [string]$Role = '') { if (-not $Name) { return '' }
  $sk = @($Kind, $Name, $Topic, $Role) -join "`t"; if ($script:KitShown -isnot [hashtable] -or -not $script:KitShown.ContainsKey($sk)) { Register-KitShownNames @(, @($Kind, $Name, $Topic, $Role)) }; $script:KitShown[$sk] }
# <role>-<area, subject or item words> (devy-ask-prompts, kitty-naming), else <role>-<n> (never reused: an old inbox); $Legacy -> aliases (msg -To)
function New-KitAgentId([string]$Type, [string]$Legacy = '', [string]$Area = '', [string[]]$Items = @(), [string]$Subject = '') { $f = Get-KitPath naming -Create; $role = $Type.ToLower()
  $ar = ("$Area" -replace '^(?i)area-', '').ToLower().Trim(); $topic = (@($(if ($ar -match '[a-z0-9]' -and $role -notlike "$ar*") { $ar }), $Subject, "$(@(Split-KitList $Items)[0])") | ForEach-Object { "$_".Trim() -replace '~', ' ' } | Where-Object { $_ }) -join ' ~ '   # the first with words
  $named = if ($topic -match '[a-z0-9]') { New-KitName $role $topic -Cap 16 }; if ($named -match "^$role(?:-\d+)?$") { $named = $null }
  $live = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' } | ForEach-Object { "$($_.agent)" })   # never a live id
  Invoke-KitLocked $f { $x = Read-KitState $f; if ($x -isnot [Collections.IDictionary]) { $x = @{} }; $k = "agent:$role"; $id = $named
    while (-not $id -or ($id -in $live -and -not $named -and $x[$k] -lt 999)) { $x[$k] = 1 + [int]$x[$k]; $id = "$role-$($x[$k])" }
    if ($Legacy) { if ($x.aliases -isnot [Collections.IDictionary]) { $x.aliases = @{} }; if (-not $x.aliases[$Legacy]) { $x.aliases[$Legacy] = $id } }; Write-KitState $f $x; $id } }
function Resolve-KitAgentAlias([string]$Id) { $a = (Read-KitState (Get-KitPath naming)).aliases; if ($a -is [Collections.IDictionary] -and $a[$Id]) { $a[$Id] } else { $Id } }
function New-KitId([string]$Kind, [string]$Dir, [switch]$Number) {
  for ($ni = 0; $ni -lt 100; $ni++) { $nid = Invoke-KitNaming @('next', 'id', $Kind); if ($nid -notmatch "^$([regex]::Escape($Kind))-[1-9]\d*$") { throw "kitbag.py naming next id $Kind gave '$nid'" }
    if (-not $Dir -or -not @("$nid", "$nid.json", "$nid.md" | Where-Object { Test-Path -LiteralPath (Join-Path $Dir $_) }).Count) { return $(if ($Number) { $nid.Substring($Kind.Length + 1) } else { $nid }) } }
  throw "New-KitId ${Kind}: 100 ids taken in $Dir"   # NAME-NUMBER: the maker itself
}
# an old id still resolves: dec-12 <-> dec-0012 (padded), whichever <id>[.json|.md] exists in $Dir; none: $Id as given
function Resolve-KitIdAlias([string]$Id, [string]$Dir) {
  $has = { param($c) @("$c", "$c.json", "$c.md" | Where-Object { Test-Path -LiteralPath (Join-Path $Dir $_) }).Count }
  if (-not $Id -or -not $Dir -or (& $has $Id) -or $Id -notmatch '^(?<k>[a-z]+(?:-[a-z]+)*)-0*(?<n>\d+)$') { return $Id }
  $alias = @("$($Matches.k)-$([int64]$Matches.n)", ("$($Matches.k)-" + "$([int64]$Matches.n)".PadLeft(4, '0')) | Where-Object { $_ -ne $Id -and (& $has $_) })
  if ($alias.Count) { $alias[0] } else { $Id }
}
# <file>.bak (latest), the one before moved to <file>.bak.prev (owner 2026-11-24: no counter, no date); lint NAME-BACKUP
function Get-KitBakName([string]$File) {
  if (Test-Path -LiteralPath "$File.bak" -PathType Leaf) { Move-Item -LiteralPath "$File.bak" "$File.bak.prev" -Force }
  "$File.bak"
}
# Set-TrackerName: an unkeyed new name of a keyed task keeps its key and [Type] (owner 2026-11-24: a hand rename dropped RM-AGT-001)
function Resolve-KitRenameName([string]$Id, [string]$Name) {
  if (-not (Test-KitNamingOn) -or (Get-KitNameKey $Name) -or -not ($rnKey = Get-KitNameKey "$((Get-TrackerTask $Id).name)")) { return $Name }
  if ("$Name".TrimStart() -notmatch '^\[') { $Name = "[$((Get-KitNameKind "$((Get-TrackerTask $Id).name)").kind)] $Name" }; Format-KitKeyedName $Name $rnKey
}
# a key for a new task: its own, else allocated from Area ("AREA" or "PRODUCT-AREA") or the parent's key; product: given, the parent's, the
# only one registered. '' when none can be derived (old-style name kept one version, with a warning)
function Get-KitNewTaskKey([string]$Name, [string]$Parent, [string]$Area, [switch]$NoAllocate) {
  if ($k = Get-KitNameKey $Name) { return $k }
  $pk = if ($Parent -and $Parent -ne '-') { Get-KitNameKey "$((Get-TrackerTask $Parent).name)" }; $pp = @("$pk" -split '-')
  $ar = @("$Area".ToUpper() -split '-' | Where-Object { $_ }); $prods = @((Get-KitProps (Get-KitSetting 'naming.products' $null)).Name)
  $a = if ($ar.Count) { $ar[-1] } elseif ($pk) { $pp[1] }; $p = if ($ar.Count -gt 1) { $ar[0] } elseif ($pk) { $pp[0] } elseif ($prods.Count -eq 1) { $prods[0] }
  if (-not ($a -and $p)) { [Console]::Error.WriteLine("WARNING: naming: '$Name' gets no key (pass the spec's area: one of $(@((Get-KitProps (Get-KitSetting 'naming.areas' $null)).Name) -join ' '), or a parent with a key); old-style names are accepted one version"); return '' }
  if ($NoAllocate) { return "$p-$a-000" }   # a dry run: the counter is not used
  Invoke-KitNaming @('next', 'key', $p, $a)
}
# <KEY> <outcome> (kitbag.py naming make title; owner 2026-11-24: the [Type] and area are tags); naming off or no key: the name as given.
# A [Type] prefix names the kind; a re-format of the made title keeps it ($script:KitTitleKind); $script:KitNameTags: the tags for create
$script:KitTitleKind = @{}
function Format-KitKeyedName([string]$Name, [string]$Key) {
  if (-not $Key) { return $Name }; $bare = (Remove-KitNameKey $Name).Trim(); $nk = Get-KitNameKind $bare
  $ty = if ($nk.rest -cne $bare) { $tk = (Get-Culture).TextInfo.ToTitleCase("$($nk.kind)".ToLower()); if ($tk -in 'Feature', 'Bug', 'Chore', 'Spike') { $tk } else { 'Feature' } } elseif ($script:KitTitleKind[$bare]) { $script:KitTitleKind[$bare] } else { 'Feature' }
  $nm = Invoke-KitNaming @('make', 'title', "key=$Key", "type=$ty", "outcome=$($nk.rest)")
  $script:KitTitleKind[(Remove-KitNameKey $nm).Trim()] = $ty; $script:KitNameTags = @("key=$Key", "kind=$ty"); $nm
}
# tracker update of an existing task (owner 2026-11-24): its live name stays (a hand rename, never re-made from the brief's area text); a
# typed title renames it; a key the live name lost comes back
function Get-KitKeptName([string]$Task, $Spec, [string]$Rendered, [string]$Key) {
  $Live = if ($Task) { Clear-TrackerMemo $Task; "$((Get-TrackerTask $Task).name)" }
  if (-not $Live -or "$($Spec.title)".Trim()) { return $Rendered }
  if ($Key -and $Key -notlike '*-000' -and -not (Get-KitNameKey $Live)) { "$Key $Live" } else { $Live }
}
# tracker create -Key: the keyed defect record with the name the kit gave it (a re-run renames only while the task still has it)
function Save-KitKeyedTask([string]$File, [string]$Key, [string]$Id) { Write-KitState $File ([ordered]@{ key = $Key; id = $Id; name = "$((Get-TrackerTask $Id).name)" })
  if ($Key -match '^qa-') { $null = Set-KitTaskTags $Id @('origin=qa-found') -Soft } }   # a QA run's defect
# a re-run: renamed while it holds that name; an older record without one only learns the live name (never renamed blind)
function Update-KitKeyedTask([string]$File, $Old, [string]$Live, [string]$Name, [string]$Key) {
  if ($Old.name -and $Live -ceq "$($Old.name)") { $null = Set-TrackerName $Old.id $Name }
  if (-not $Old.name -or $Live -ceq "$($Old.name)") { Save-KitKeyedTask $File $Key $Old.id }
}
function Resolve-KitTaskName([string]$Name, [string]$Parent, [string]$Area, [switch]$NoAllocate) { $script:KitNameTags = @(); if (-not (Test-KitNamingOn)) { return $Name }; Format-KitKeyedName $Name (Get-KitNewTaskKey $Name $Parent $Area -NoAllocate:$NoAllocate) }
# wt new / lease -Task without -Branch: <feat|fix>/<KEY>-<tracker tag>-<slug> (kitbag.py naming make branch; the tag keeps every
# branch -> task parser and the tracker's own links working); a task without a key: throw (pass -Branch)
function Get-KitTaskBranch([string]$Task) {
  $tk = Get-TrackerTask $Task; $nm = "$($tk.name)"; $ky = Get-KitNameKey $nm
  if (-not $ky) { throw "wt: task $Task has no kit key in its name ('$nm'): pass -Branch, or key the task first (kitbag.py naming)" }
  $nk = Get-KitNameKind $nm; $rest = $nk.rest -creplace '\s*\(was [^)]*\)\s*$', ''   # an old "<Area>: " head: make's clean drops it
  Invoke-KitNaming @('make', 'branch', "key=$ky", "type=$(if (Test-KitBugTask $tk) { 'fix' } else { 'feat' })", "slug=$rest", "tag=$($KitConf.TrackerTag)$Task")
}
# an explicit -Branch of a keyed task off the standard: a warning (old-style names accepted one version)
function Test-KitTaskBranch([string]$Task, [string]$Branch) {
  if (-not ($Task -and (Test-KitNamingOn))) { return }; $ky = Get-KitNameKey "$((Get-TrackerTask $Task).name)"
  if ($ky -and $Branch -cnotmatch "/$([regex]::Escape($ky))-") { [Console]::Error.WriteLine("WARNING: wt: branch '$Branch' of $ky is off the naming standard (<type>/$ky-<slug>; omit -Branch to get it): accepted one version") }
}
# naming on and the ask keyed: <Name> is in the ask's area (its key's AREA); naming off or an unkeyed ask: true
function Test-KitSameArea([string]$Name, [string]$Ask) {
  if (-not ((Test-KitNamingOn) -and $Ask -and $Ask -ne '-')) { return $true }; $ak = Get-KitNameKey "$((Get-TrackerTask $Ask).name)"
  if (-not $ak) { return $true }; $nk = Get-KitNameKey $Name; [bool]($nk -and ($nk -split '-')[1] -ceq ($ak -split '-')[1])
}
# a spec's key: its own, the title's, the live task's (a hand-renamed one keeps it), else allocated on create (-Allocate)
function Set-KitSpecKey($Spec, [string]$Task, [switch]$Allocate) {
  if (-not (Test-KitNamingOn)) { return }
  if ($Task -and ($lk = Get-KitNameKey "$((Get-TrackerTask $Task).name)")) { $Spec.key = $lk; return }   # the live key wins over a stored one
  if ($Spec.key) { return }
  $tk = Get-KitNameKey "$($Spec.title)"   # create: a typed key only names PRODUCT-AREA; the counter gives the number (owner 2026-11-23)
  $ar = if ($Spec.area) { (@($Spec.product, $Spec.area) | Where-Object { $_ }) -join '-' } elseif ($tk) { ($tk -split '-')[0..1] -join '-' }
  $k = if ($Task) { Get-KitNameKey "$((Get-TrackerTask $Task).name)" } else { Get-KitNewTaskKey (Remove-KitNameKey "$($Spec.title)") "$($Spec.parent)" $ar -NoAllocate:(-not $Allocate) }
  if ($k) { $Spec.key = $k }
}
# a task name's kind and the rest: a configured prefix (tracker.kindPrefixes, bugPrefix), else a leading [Kind], else Feature (a kit key first is skipped)
function Get-KitNameKind([string]$Name) {
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $n = Remove-KitNameKey $Name
  foreach ($k in @(@(if ($kp) { (Get-KitProps $kp).Name }) + 'Feature', 'Bug', 'Chore' | Select-Object -Unique)) { $p = Get-KitKindPrefix $k; if ($p -and $n.StartsWith($p, 'OrdinalIgnoreCase')) { return [pscustomobject]@{ kind = $k; rest = $n.Substring($p.Length).Trim() } } }
  if ($n -match '^\[([^\]]+)\]\s*(.*)$') { [pscustomobject]@{ kind = $Matches[1]; rest = $Matches[2] } } else { [pscustomobject]@{ kind = 'Feature'; rest = $n } }
}
# a defect name under tracker.kindPrefixes.bug: a typed [Bug] / [Kind] prefix swapped for the configured one
function Format-KitBugName([string]$Name) { $bp = Get-KitKindPrefix 'bug'; $ky = "$(Get-KitNameKey $Name) ".TrimStart(); $n = (Remove-KitNameKey $Name).Trim(); if ($n.StartsWith($bp, 'OrdinalIgnoreCase')) { return "$ky$n" }
  $nk = Get-KitNameKind $n; $kp = Get-KitSetting 'tracker.kindPrefixes' $null; "$ky$bp $(if ($nk.rest -ne $n -and $nk.kind -in @(@('Feature', 'Bug', 'Chore') + @(if ($kp) { (Get-KitProps $kp).Name }))) { $nk.rest } else { $n })".Trim() }   # a known kind's prefix swapped, [ui] kept
function Test-KitBugName([string]$Name) { $p = Get-KitKindPrefix 'bug'; $n = Remove-KitNameKey $Name; ($p -and $n.StartsWith($p, 'OrdinalIgnoreCase')) -or $n -match '^\W*Bug\]' }
function Get-KitTaskTemplate {
  $t = @(Get-KitSetting 'tracker.taskTemplate' $null | Where-Object { $_ -and $_.label })
  if ($t.Count) { return $t }
  @([pscustomobject]@{ key = 'problem'; label = 'Problem'; required = $true }, [pscustomobject]@{ key = 'goal'; label = 'Goal'; required = $true },
    [pscustomobject]@{ key = 'items'; label = 'Items'; alt = 'Bugs'; required = 'subtask' }, [pscustomobject]@{ key = 'acceptance'; label = 'Acceptance'; required = $true },
    [pscustomobject]@{ key = 'links'; label = 'Links'; required = $true })
}
# the items section's label (its checklist's name) and alt label from tracker.taskTemplate: one name for writer and reader
function Get-KitItemsLabel([switch]$All) {
  $s = @(Get-KitTaskTemplate | Where-Object { "$($_.key)" -eq 'items' })[0]; $l = if ($s) { "$($s.label)" } else { 'Items' }
  if ($All) { @($l) + @(@($s.alt) | Where-Object { $_ }) } else { $l }
}
# ---- track lines: ATTENTION / LAG lines a hold or a later status makes stale (lib.ps1 track, bossy.ps1 supervise)
# track's LAG / missing-doc ATTENTION of a task held on purpose: dropped (the background run may predate the hold)
function Test-KitHeldLine([string]$Line, [string[]]$Held) { $Line -match '^(LAG|ATTENTION) (?<tid>[^\s:]+):' -and $Matches.tid -in $Held -and ($Line -match '^LAG' -or $Line -match 'no (solution/testing comment|testing-doc link)|task id not readable') }
# a cached track-run ATTENTION about missing testing docs / solution whose task moved on since (devtools.py finish promoted it)
function Test-KitTrackLineStale([string]$Line) { $Line -match '^ATTENTION (?<t>\S+): .*(no (solution/testing comment|testing-doc link)|task id not readable)' -and (Test-TrackerStatus $(try { [string](Get-TrackerTask $Matches.t).status } catch { '' }) 'promoted', 'inTest', 'closed') }
# ---- task ids: a kit key -> the tracker's native id (lib.ps1 __TrA)
# a kit key (<PRODUCT>-<AREA>-<nnn>, kitbag.py naming) where the tracker wants its native id: the id a read of that keyed task recorded
# (cache task-keys.json), else refused with the hint (a display key read as unread showed as "no testing-doc link", run 1123)
function Resolve-TrackerId([string]$Id, [switch]$Soft) {
  if ($__trType -in 'none', 'local' -or $Id -cnotmatch '^[A-Z]{2,6}-[A-Z]{2,6}-\d{2,}$') { return $Id }
  $m = Read-KitState (Join-Path (Get-KitPath cache -Create) 'task-keys.json'); if ($m -and $m[$Id]) { return [string]$m[$Id] }
  if ($Soft) { return $Id }
  throw "tracker ($__trType): $Id is a kit key, not a $__trType task id: pass the native id (the task URL's id; the task's title starts with $Id)"
}
$script:KitKeyIds = @{}
function Save-TrackerKey($Task) {   # a keyed task read: key -> native id, once per process
  $ky = if ($Task -and $Task.name) { Get-KitNameKey "$($Task.name)" }
  if (-not $ky -or -not $Task.id -or "$($Task.id)" -ceq $ky -or $script:KitKeyIds[$ky] -eq "$($Task.id)") { return }
  $f = Join-Path (Get-KitPath cache -Create) 'task-keys.json'; $script:KitKeyIds[$ky] = "$($Task.id)"
  try { Invoke-KitLocked $f { $m = Read-KitState $f; if (-not $m) { $m = @{} }; if ($m[$ky] -ne "$($Task.id)") { $m[$ky] = "$($Task.id)"; Write-KitState $f $m } } } catch { Write-KitLog calls task-keys @{ key = $ky; error = "$_" } }
}
# ---- tags: kitbag.py naming tags (vocabulary, exclusive groups; owner 2026-11-24) on the tracker: native when the adapter can (caps
# labels: verb labels {id; add; remove}, view .tags), else a <!-- kit:tags --> "**Tags:** a, b" description line; naming off: none
function Add-KitTags($O, $Tags) { if ($O) { $O | Add-Member -Force -NotePropertyName tags -NotePropertyValue @(@($Tags) | Where-Object { "$_".Trim() -and "$_" -notlike "$__trLp*" } | ForEach-Object { "$_" }) -PassThru } }   # an adapter's view: its labels minus status labels
function Get-KitTaskTags([string]$Task, $T) {
  if (-not $T) { Clear-TrackerMemo $Task; $T = Get-TrackerTask $Task }
  if (__TrCan labels) { return @($T.tags | Where-Object { $_ }) }
  if (("$($T.description)" -replace "`r`n", "`n") -match '(?m)^\*\*Tags:\*\* (.+)$') { @($Matches[1] -split ',\s*' | Where-Object { $_.Trim() }) } else { @() }
}
# -Parts group=value | group=a,b | group=- (clear) | group=-value (drop one); key=<KEY> gives product + area. -Soft: a failure warns
function Set-KitTaskTags([string]$Task, [string[]]$Parts, [switch]$Soft) {
  $Parts = @($Parts | Where-Object { "$_".Trim() }); if (-not ($Task -and $Parts.Count -and (Test-KitNamingOn))) { return }
  try {
    $t = if (-not $__trDry) { Clear-TrackerMemo $Task; Get-TrackerTask $Task }; if (-not $__trDry -and -not $t.name) { throw "tracker read of $Task failed" }
    $have = @(if ($t) { Get-KitTaskTags $Task $t }); $j = Invoke-KitNaming (@('tags') + @(if ($have.Count) { '--have', ($have -join ',') }) + $Parts) | ConvertFrom-Json
    $tl = "tags of ${Task}: $(@($j.tags) -join ', ')$(if (-not (__TrCan labels)) { ' (description)' })"
    if (-not (@($j.add).Count + @($j.remove).Count)) { return "$tl (unchanged)" }; Write-KitTaskTags $Task $t $j; $tl
  } catch { if (-not $Soft) { throw }; [Console]::Error.WriteLine("WARNING: tracker tags on $Task not set ($($_.Exception.Message))") }   # stderr: stdout is JSON
}
# $J {tags; add; remove} onto the task $T: the labels verb, else its description line; the task index keeps the set
function Write-KitTaskTags([string]$Task, $T, $J) {
  if (-not (@($J.add).Count + @($J.remove).Count)) { return }
  if (__TrCan labels) { $null = __TrA 'labels' @{ id = $Task; add = @($J.add); remove = @($J.remove) } }
  elseif ($T) { $null = Set-TrackerDescription $Task (Set-KitDescSection $T.description 'tags' $(if (@($J.tags).Count) { "**Tags:** $(@($J.tags) -join ', ')" } else { '' }) '') }
  Clear-TrackerMemo $Task; if (-not $__trDry) { Update-KitTaskIndex $Task { param($x) $x.tags = @($J.tags) } }   # a later read in this process sees them
}
# ONE WATCH for kit tasks off the tag rule (owner 2026-11-25: one kind, one area, one product tag, no wave tag; kitbag.py naming scan); fix: tracker retag
function Get-KitTagGapFlag { $lec = $global:LASTEXITCODE; $rows = @(@(try { & (Get-Python) -X utf8 $KitCmd.kitbag naming scan --json 2>$null | Out-String | ConvertFrom-Json } catch { }) | Where-Object { $_.kind -eq 'tags' }); $global:LASTEXITCODE = $lec
  if (-not $rows.Count) { return }; $ids = @($rows | ForEach-Object { "$($_.where)" -replace '^tracking ' })
  [pscustomobject]@{ level = 'WATCH'; what = "$($rows.Count) kit task(s) off the tag rule: $(@($rows | Select-Object -First 5 | ForEach-Object { "$("$($_.where)" -replace '^tracking ') ($($_.why))" }) -join '; ')"; kind = 'TAGS'; who = 'tracker'
    action = "Dry run, then apply: & $($KitCmd.dev) tracker retag $($ids -join ',') -DryRun; then without -DryRun (a person's own tags stay)."; problem = "$($rows.Count) task(s): a kind / area / product tag missing or doubled, or a wave tag"; next = 'tracker retag <ids> -DryRun' }
}
# after tracker create (lib.ps1 New-TrackerTask): kind, product, area of the name Format-KitKeyedName made
function Set-KitNewTaskTags([string]$Task) { if ($Task -and @($script:KitNameTags).Count) { $null = Set-KitTaskTags $Task $script:KitNameTags -Soft } }
# a bug: a bug-prefixed name (unkeyed, old titles) or a bug tag (keyed titles carry the kind as a tag), live or in the task index
function Test-KitBugTask($T) {   # a subtask row without .tags (jira, azure, fallback trackers): its full read
  if (Test-KitBugName "$($T.name)") { return $true }
  $tg = @($T.tags) + @(if ($T.id) { (Read-KitState (Get-KitTaskFile "$($T.id)")).tags })
  if (-not @($tg | Where-Object { $_ }).Count -and $T.id -and -not ($T | Get-Member -Name tags) -and (Test-KitNamingOn) -and (Get-KitNameKey "$($T.name)")) { $tg = @(Get-KitTaskTags "$($T.id)") }
  'bug' -in $tg
}
# tracker tags <id> <group=value> ... | tracker retag <parent>[,<parent>] [-DryRun]: keyed titles + labels of the trees -> <KEY> <outcome>
# + tags (kitbag.py naming rename --plan; table in cache retag-<parent>.md); -DryRun: the table only (shown to the owner before an apply)
function Invoke-KitTagVerb([string]$Verb, [string]$Id, [string[]]$Rest) {
  if ($Verb -eq 'tags') { if (-not ($Id -and $Rest.Count)) { 'usage: tracker tags <id> <group>=<value> ... (kitbag.py naming tags: kind area product phase repo env risk decision origin test)'; exit 2 }; return Set-KitTaskTags $Id $Rest }
  if (-not $Id) { 'usage: tracker retag <parent>[,<parent>] [-DryRun]'; exit 2 }
  $Out = Join-Path (Get-KitPath cache -Create) "retag-$((Split-KitList $Id)[0] -replace '[^\w.-]', '_').md"
  $dry = $__trDry; $script:__trDry = $false   # the reads run for real; the writes below only without -DryRun
  $seen = @{}; $todo = [Collections.Generic.Queue[string]]::new(); foreach ($p in @(Split-KitList $Id)) { $todo.Enqueue($p) }
  $items = @(while ($todo.Count) { $k = $todo.Dequeue(); if ($seen.Contains($k)) { continue }; Clear-TrackerMemo $k; $tk = Get-TrackerTask $k; $seen[$k] = $tk
      if (-not $tk.name) { Write-Warning "retag: $k not readable: skipped"; continue }; foreach ($s in @($tk.subtasks)) { if ($s.id) { $todo.Enqueue("$($s.id)") } }
      if (Get-KitNameKey $tk.name) { $ot = if ("$($tk.description)" -match '\*\*Old title:\*\* ([^\r\n]+)') { "$(Get-KitNameKey $tk.name) $(Remove-KitNameKey ($Matches[1] -replace '\\([\[\]_*`#])', '$1'))" } else { "$($tk.name)" }   # a re-run plans from the first old title, the live key kept
      [ordered]@{ id = "$k"; title = $ot; tags = @(Get-KitTaskTags $k $tk); wave = "$((Read-KitState (Get-KitTaskFile $k)).order.wave)" } } })   # wave: tracker order's record
  $pf = New-KitTempFile; [IO.File]::WriteAllText($pf, (@{ items = $items } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  $lec = $global:LASTEXITCODE; $md = @(& (Get-Python) -X utf8 $KitCmd.kitbag naming rename --plan $pf 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^DRY RUN: nothing renamed' })   # keys stay: no seed hint
  $rows = @(& (Get-Python) -X utf8 $KitCmd.kitbag naming rename --plan $pf --json 2>$null | ConvertFrom-Json); $global:LASTEXITCODE = $lec; Remove-Item -LiteralPath $pf -Force
  [IO.File]::WriteAllLines($Out, [string[]]$md, [Text.UTF8Encoding]::new($false))
  $md; if ($dry) { "DRY RUN: $($rows.Count) keyed task(s), nothing changed; table: $Out"; return }
  foreach ($r in @($rows | Where-Object { -not @($_.problems).Count })) {
    $old = "$($seen[$r.id].name)"; if ($r.title -cne $old) { $null = Set-TrackerName $r.id $r.title }
    Write-KitTaskTags $r.id $seen[$r.id] $r
    if ($r.title -cne $old) { Clear-TrackerMemo $r.id; $tk = Get-TrackerTask $r.id   # the old title stays searchable (its codes), written once
      if ("$($tk.description)" -notmatch '<!-- kit:was -->') { $null = Set-TrackerDescription $r.id (Set-KitDescSection $tk.description 'was' "**Old title:** $old" '') } }
    "RETAGGED $($r.id): $($r.title) · $(@($r.tags) -join ', ')" }
  foreach ($r in @($rows | Where-Object { @($_.problems).Count })) { "SKIPPED $($r.id): $(@($r.problems) -join '; ')" }
}
# ---- order: waits-on links and wave tags (owner 2026-11-23: order and parallel work readable without titles)
# native when the tracker can (caps dependencies; wave: Set-KitTaskTags), else a <!-- kit:order --> description section; titles never change
function Set-KitTaskOrder([string]$Task, [string[]]$WaitsOn, [string]$Wave) {
  $WaitsOn = @($WaitsOn | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -ne $Task } | Select-Object -Unique); $nat = @()
  $Wave = "$Wave".Trim(); if ((Test-KitNamingOn) -and $Wave -match '(\d+)\s*$') { $Wave = "wave-$($Matches[1])" }   # naming on: "<brief> wave 2" -> wave-2 (owner 2026-11-24)
  if ($WaitsOn.Count -and (__TrCan dependencies)) { try { $null = __TrA 'dependencies' @{ id = $Task; on = $WaitsOn }; $nat += 'links' } catch { Write-Warning "tracker dependencies on $Task failed ($($_.Exception.Message)): a Waits on line instead" } }
  if ($Wave -and (Test-KitNamingOn)) { try { $null = Set-KitTaskTags $Task @("wave=$Wave"); $nat += 'tag' } catch { Write-Warning "tracker tags on $Task failed ($($_.Exception.Message)): a Wave line instead" } }
  elseif ($Wave -and (__TrCan labels)) { try { $null = __TrA 'labels' @{ id = $Task; add = @("Wave: $Wave") }; $nat += 'tag' } catch { Write-Warning "tracker labels on $Task failed ($($_.Exception.Message)): a Wave line instead" } }   # naming off: as before
  $ln = @(if ($WaitsOn.Count -and 'links' -notin $nat) { "**Waits on:** $($WaitsOn -join ', ')" }; if ($Wave -and 'tag' -notin $nat) { "**Wave:** $Wave" })
  if ($ln.Count) { Clear-TrackerMemo $Task; $tk = Get-TrackerTask $Task; if (-not $tk.name) { throw "tracker read of $Task failed" }
    $nd = Set-KitDescSection $tk.description 'order' ($ln -join "`n") ''; if ($nd -ne ("$($tk.description)" -replace "`r`n", "`n")) { $null = Set-TrackerDescription $Task $nd } }
  Update-KitTaskIndex $Task { param($x) $x.order = [ordered]@{ waitsOn = $WaitsOn; wave = $Wave } }
  "order of ${Task}: waits on $(if ($WaitsOn.Count) { $WaitsOn -join ', ' } else { 'nothing' })$(if ($Wave) { " · $Wave" }) ($((@(if ($nat.Count) { "native $($nat -join ', ')" }) + @(if ($ln.Count) { 'description' })) -join ' + '))"
}
# a parent's subtasks as waves (Kahn): wave n = tasks whose waits-on siblings are all in earlier waves; same wave, no link = parallel
function Get-KitTaskOrder([string]$Parent) {
  Clear-TrackerMemo $Parent; $pt = Get-TrackerTask $Parent; if (-not $pt.name) { throw "tracker read of $Parent failed" }
  $info = [ordered]@{}
  foreach ($k in @(@($pt.subtasks | ForEach-Object { "$($_.id)" }) | Where-Object { $_ } | Select-Object -Unique)) {
    $tk = Get-TrackerTask $k; $ix = (Read-KitState (Get-KitTaskFile $k)).order
    $sec = [regex]::Match(("$($tk.description)" -replace "`r`n", "`n"), '(?s)<!-- kit:order -->\n(.*?)\n<!-- /kit:order -->').Groups[1].Value
    $w = @(if (__TrCan dependencies) { @(__TrA 'dependencies' @{ id = $k; on = @() }) }) + @($ix.waitsOn) + @(if ($sec -match '(?m)^\*\*Waits on:\*\* (.+)$') { $Matches[1] -split ',\s*' })
    $wl = if ($ix.wave) { "$($ix.wave)" } elseif ($sec -match '(?m)^\*\*Wave:\*\* (.+)$') { $Matches[1].Trim() } else { '' }
    $info[$k] = [pscustomobject]@{ id = $k; name = "$($tk.name)"; waitsOn = @($w | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique); label = $wl; wave = 0 }
  }
  $left = [Collections.Generic.List[string]]::new([string[]]@($info.Keys)); $n = 0
  while ($left.Count) { $ready = @($left | Where-Object { $ti = $_; -not @($info[$ti].waitsOn | Where-Object { $left.Contains($_) }).Count }); if (-not $ready.Count) { break }
    $n++; foreach ($r in $ready) { $info[$r].wave = $n; [void]$left.Remove($r) } }
  $flags = @(if ($left.Count) { "CYCLE: $($left -join ', ') wait on each other: remove one link" }
    if ($info.Count -gt 1 -and -not @($info.Values | Where-Object { $_.waitsOn.Count }).Count) { "MISSING: no task under $Parent waits on another: all $($info.Count) look parallel (tracker order $Parent -Apply <brief>.order.json)" }
    foreach ($t in $info.Values) { foreach ($d in @($t.waitsOn | Where-Object { -not $info.Contains($_) })) { "OUTSIDE: $($t.id) waits on $d (not under $Parent)" }
      if ($t.label -match '(\d+)\s*$' -and [int]$Matches[1] -gt 1 -and -not $t.waitsOn.Count) { "MISSING: $($t.id) is labelled $($t.label) but waits on nothing" } })
  [pscustomobject]@{ parent = $Parent; tasks = @($info.Values); waves = $n; flags = $flags }
}
# the order as a table: one row per wave (its tasks run in parallel), then the flags
function Format-KitTaskOrder($Order) {
  @(Format-KitMdTable 'Wave', 'Tasks (parallel)', 'Waits on' @(foreach ($g in @($Order.tasks | Group-Object wave | Sort-Object { [int]$_.Name })) {
        , @($(if ([int]$g.Name) { $g.Name } else { 'cycle' }), (@($g.Group | ForEach-Object { "$($_.id) $($_.name)".Trim() }) -join '; '), (@($g.Group.waitsOn | Select-Object -Unique) -join ', ')) })) + @($Order.flags)
}
