#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (tracker writes throw).
# task Items checklists: write one (adapter verb checklist, else a description section), item holds (counts match the task
# state), spec items, the parent's line per subtask; item text: lib.ps1 Format-KitItemText; rollup: bossy adapters/task_rollup.ps1;
# tracker move / group (K54)
# Sections: L7 items · L83 move · L126 status roles · L272 task text
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
  $c = if (-not $Refresh -and (Test-Path -LiteralPath $f) -and ((Get-Date) - [IO.File]::GetLastWriteTime($f)).TotalHours -lt 24) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
  $live = if ($c) { @($c.statuses) } else { $null }; $ad = $KitAdapters['tracker'][$__trType]
  if (-not $c -and -not $__trDry -and $ad -and ($ad.ContainsKey('statuses') -or ($ad.ContainsKey('*') -and ($__trType -ne 'command' -or (Get-KitMember (Get-KitSetting 'tracker.commands' $null) 'statuses'))))) {
    $live = try { @(__TrA 'statuses' @{ scope = $Scope } | Where-Object { "$($_.name)".Trim() } | ForEach-Object { [pscustomobject]@{ name = "$($_.name)".Trim(); type = "$($_.type)".ToLower() } }) } catch { Write-Warning "tracker ($__trType): statuses of $Scope not read ($("$_".Split("`n")[0])): default names"; $null }
    if (@($live).Count) { [IO.File]::WriteAllText($f, ([ordered]@{ scope = $Scope; type = $__trType; at = (Get-Date).ToString('o'); statuses = @($live) } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) } else { $live = $null }
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
    if ($lv.status) { $Cache[$id] = @{ at = (Get-Date).ToString('o'); st = "$($lv.status)" }; if (-not (& $bk $id "$($lv.status)" "$($lv.list)")) { continue } }; $id }
}
# every cached scope (supervise WATCH on unmapped names; a status read without its scope)
function Get-KitCachedScopeRoles {
  if ($null -eq $script:KitScopeAll) { $script:KitScopeAll = @(Get-ChildItem (Get-KitPath tracker-statuses) -Filter "$__trType-*.json" -ErrorAction SilentlyContinue | ForEach-Object { try { "$((Get-Content $_.FullName -Raw | ConvertFrom-Json).scope)" } catch { } } | Where-Object { $_ } | ForEach-Object { Get-KitScopeRoles $_ }) }
  $script:KitScopeAll
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
# a task name's kind and the rest: a configured prefix (tracker.kindPrefixes, bugPrefix), else a leading [Kind], else Feature
function Get-KitNameKind([string]$Name) {
  $kp = Get-KitSetting 'tracker.kindPrefixes' $null; $n = "$Name".TrimStart()
  foreach ($k in @(@(if ($kp) { (Get-KitProps $kp).Name }) + 'Feature', 'Bug', 'Chore' | Select-Object -Unique)) { $p = Get-KitKindPrefix $k; if ($p -and $n.StartsWith($p, 'OrdinalIgnoreCase')) { return [pscustomobject]@{ kind = $k; rest = $n.Substring($p.Length).Trim() } } }
  if ($n -match '^\[([^\]]+)\]\s*(.*)$') { [pscustomobject]@{ kind = $Matches[1]; rest = $Matches[2] } } else { [pscustomobject]@{ kind = 'Feature'; rest = $n } }
}
# a defect name under tracker.kindPrefixes.bug: a typed [Bug] / [Kind] prefix swapped for the configured one
function Format-KitBugName([string]$Name) { $bp = Get-KitKindPrefix 'bug'; if ("$Name".TrimStart().StartsWith($bp, 'OrdinalIgnoreCase')) { return "$Name".Trim() }; "$bp $((Get-KitNameKind $Name).rest)".Trim() }
function Test-KitBugName([string]$Name) { $p = Get-KitKindPrefix 'bug'; $n = "$Name".TrimStart(); ($p -and $n.StartsWith($p, 'OrdinalIgnoreCase')) -or $n -match '^\W*Bug\]' }
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
