#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (tracker writes throw).
# task Items checklists: write one (adapter verb checklist, else a description section), item holds (counts match the task
# state), spec items, the parent's line per subtask; item text: lib.ps1 Format-KitItemText; rollup: bossy adapters/task_rollup.ps1
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
