<#
task_rollup.ps1 (goody task-rollup): a parent task's delivery status, triage and subtask Items checklists, all script-built,
dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 track rollup -Task <parent> [-From <brief dir | item table .md>]   -From stores the run's triage (item table + launch
    args) in the parent's task state; then rebuilds and writes what changed
  track run calls Invoke-KitTrackRollupHook: every parent with a not-done tracked subtask or a stored triage
Reads: task state (.state/tasks: track), the git host (Invoke-HostVerb mr.get / mr.url; merged MRs cached for good),
the deploy log, the tracker (parent + its subtasks, one view per read). Writes (tracker adapter, only on a diff): the parent
description between <!-- kit:delivery --> / <!-- kit:triage --> markers, each subtask's "Items" checklist (adapter verb
checklist, else an <!-- kit:items --> description section), one comment per milestone (all merged, deployed to <env>, all closed).
Every subtask closed: one close-parent decision (decide ask -Gate close); the parent closes only on the owner's answer; a reopened parent rolls up again.
No read while nothing local changed and track.rollupMinutes (30) has not passed: an unchanged run makes 0 calls.
Sections: L19 triage · L63 render · L144 rollup · L231 items · L276 close
Exit codes: 0 ok · 1 no item table in -From · 2 usage.
#>
#Requires -Version 7
if (-not (Get-Command Set-KitTaskChecklist -ErrorAction Ignore)) { throw 'goody task-rollup needs a newer kit core (lib.ps1 Set-KitTaskChecklist): git pull the kit, then kitbag.py goody sync' }

# ---- triage: the brief's item table (columns ID, Area; Sev, Decision, Decision id, Title or the last column) + launch args (agents)
function ConvertFrom-KitMdTables([string]$Text) {
  $tables = [Collections.Generic.List[object]]::new(); $cur = $null
  foreach ($ln in ("$Text" -split "`r?`n")) {
    $t = $ln.Trim(); if ($t -notmatch '^\|.*\|$') { $cur = $null; continue }
    $cells = @($t.Substring(1, $t.Length - 2) -split '(?<!\\)\|' | ForEach-Object { ($_ -replace '\\\|', '|').Trim() })
    if (-not $cur) { $cur = @{ head = @($cells | ForEach-Object { ($_ -replace '\*', '').Trim().ToLower() }); rows = [Collections.Generic.List[object]]::new() }; $tables.Add($cur); continue }
    if ($t -match '^\|[\s:|-]+\|$') { continue }
    $r = @{}; for ($c = 0; $c -lt $cur.head.Count; $c++) { $r[$cur.head[$c]] = if ($c -lt $cells.Count) { $cells[$c] } else { '' } }; $cur.rows.Add($r)
  }
  $tables
}
function Read-KitTriage([string]$From) {
  $dir = if (Test-Path -LiteralPath $From -PathType Container) { $From } else { Split-Path $From }
  $mds = if (Test-Path -LiteralPath $From -PathType Leaf) { @(Get-Item -LiteralPath $From) } else { @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name) }
  $col = { param($h, [string]$rx) @($h | Where-Object { $_ -match $rx })[0] }
  $rows = @(); $source = ''
  foreach ($f in $mds) {
    foreach ($tb in @(ConvertFrom-KitMdTables (Get-Content -LiteralPath $f.FullName -Raw))) {
      $cid = & $col $tb.head '^id$'; $car = & $col $tb.head '^(area|agent)$'; if (-not $cid -or -not $car) { continue }
      $csev = & $col $tb.head '^sev'; $cdec = & $col $tb.head '^decision$'; $cdid = & $col $tb.head '^decision.?id$'
      $cti = & $col $tb.head '^(title|summary|name)$'; if (-not $cti) { $cti = & $col $tb.head 'reason|fix|why' }; if (-not $cti) { $cti = $tb.head[-1] }
      $rows = @(foreach ($r in $tb.rows) { if ($r[$cid]) { [pscustomobject]@{ id = $r[$cid]; sev = "$(if ($csev) { $r[$csev] })"; decision = "$(if ($cdec -and $r[$cdec]) { $r[$cdec] } else { 'fix' })"; area = $r[$car]; decisionId = "$(if ($cdid) { $r[$cdid] })"; title = "$($r[$cti])" } } })
      $source = $f.Name; break
    }
    if ($rows.Count) { break }
  }
  $la = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } } | Where-Object { $_.agents })[0]
  $names = @{}; foreach ($rp in @(Get-KitValue 'repos' @())) { foreach ($n in @($rp.name) + @($rp.aliases)) { if ($n) { $names["$n"] = "$($rp.name)" } } }
  $all = @($la.agents)
  $agents = @(for ($i = 0; $i -lt $all.Count; $i++) {
      $a = $all[$i]; $txt = "$($a.area) $($a.note)"
      $tid = if ($a.task) { "$($a.task)" } elseif ($txt -match '(?i)\btask\s+(?<t>(?=[\w-]*\d)[\w-]+)') { $Matches.t } else { '' }
      $repo = if ($a.repo) { "$($a.repo)" } else { @($names.Keys | Sort-Object Length -Descending | Where-Object { $txt -match "(?<![\w-])$([regex]::Escape($_))(?![\w-])" } | ForEach-Object { $names[$_] })[0] }
      [pscustomobject]@{ area = "$($a.id)"; task = $tid; repo = "$repo"; order = $i }
    })
  [pscustomobject]@{ source = $source; rows = $rows; agents = $agents }
}
# state JSON comes back as hashtables
function ConvertTo-KitTriage($T) {
  if (-not $T) { return $null }
  [pscustomobject]@{ source = "$($T.source)"; rows = @($T.rows | Where-Object { $_ } | ForEach-Object { [pscustomobject]$_ }); agents = @($T.agents | Where-Object { $_ } | ForEach-Object { [pscustomobject]$_ }) }
}

# ---- render: pure Markdown builders and the marker splice
$script:KitSevOrder = @('critical', 'high', 'medium', 'low')
function Get-KitSevRank([string]$Sev) { $i = [array]::IndexOf($script:KitSevOrder, "$Sev".Trim().ToLower()); if ($i -lt 0) { 9 } else { $i } }
function Get-KitItemKind([string]$Decision) { if ($Decision -match '(?i)^dup') { 'duplicate' } elseif ($Decision -match '(?i)defer') { 'defer' } elseif ($Decision -match '(?i)already') { 'already fixed' } else { 'fix' } }
function Get-KitCut([string]$Text, [int]$Max) { $t = ("$Text" -replace '\s+', ' ' -replace '\|', '/').Trim(); if ($t.Length -gt $Max) { $t.Substring(0, $Max - 1) + '…' } else { $t } }
# state and JSON reads turn ISO strings into [datetime]; both -> [datetimeoffset] (UTC kept), else $null
function ConvertTo-KitWhen($Value) { if ($Value -is [datetime]) { [datetimeoffset]$Value } elseif ($Value -is [datetimeoffset]) { $Value } elseif ("$Value") { try { [datetimeoffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture) } catch { $null } } }
# the ids an MR names: in its title, description or branch, or as a whole branch segment (f/CU-1-jr names area JR)
function Get-KitMrNamedIds([string[]]$Ids, $Mv) {
  $txt = "$($Mv.title) $($Mv.description) $($Mv.source_branch)"; $seg = @("$($Mv.source_branch)" -split '[/_-]' | Where-Object { $_ })
  @($Ids | Where-Object { $_ } | Select-Object -Unique | Where-Object { $txt -match "(?<![\w-])$([regex]::Escape($_))(?![\w-])" -or $seg -contains $_ })
}
# a task's tracked MR refs, one per MR (bossy.ps1 NormRef: old state may hold <group>/<repo>!<iid> next to <repo>!<iid>)
function Get-KitTrackRefs($Mrs) { $nr = Get-Command NormRef -ErrorAction Ignore; @(@($Mrs) | Where-Object { $_ } | ForEach-Object { if ($nr) { NormRef $_ } else { "$_" } } | Select-Object -Unique) }
function Get-KitRollupHash([string]$Text) { [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$Text"))) }
# a checklist item, readable by the owner: "<id> · <plain description> · <MR URLs>"; the id leads (adapters key items by the text
# before the first ' · ', so a later text renames the item in place); empty parts left out
function Format-KitItemText([string]$Id, [string]$Desc, $Urls) {
  $Desc = $Desc -replace '`' -replace '\[([^\]]*)\]\([^)]*\)', '$1' -replace 'https?://\S+' -replace '(?<![\w-])[\w./-]+!\d+' -replace '(?i)(?:\s+[–—-]\s*|\s*\()(?:merged|done|deployed|closed)\)?\s*$' -replace '[\s·,;:–—-]+$'   # links live in the URL part, a status suffix in the tick
  (@($Id, (Get-KitCut $Desc 110), (@($Urls | Where-Object { $_ } | Select-Object -Unique) -join ' ')) | Where-Object { $_ }) -join ' · ' }
# an Items piece's text naming triage ids -> their titles (plain words), else the text itself
function Get-KitItemDesc([string]$Desc, $Rows) {
  $hit = @(@($Rows) | Where-Object { $_.id -and $Desc -match "(?<![\w-])$([regex]::Escape($_.id))(?![\w-])" })
  if ($hit.Count) { @($hit | ForEach-Object { $_.title }) -join '; ' } else { $Desc }
}
# one subtask's items, severity first: fix items tick when merged; deferred / duplicate ones stay unticked with their reason.
# URLs: the MRs naming the id, else those naming an area whose Items words list it ($DescMap: area id -> words), else (fix) all once merged
function Get-KitSubItems($Tri, [string]$Area, [string[]]$DoneIds, [bool]$AllDone, $Mrs, $DescMap = @{}) {
  @($Tri.rows | Where-Object { $_.area -eq $Area } | Sort-Object -Stable { Get-KitSevRank $_.sev } | ForEach-Object {
      $k = Get-KitItemKind $_.decision; $t = Get-KitCut $_.title 90; $rid = $_.id
      $d = "$(if ($_.sev) { "$($_.sev) · " })$(if ($k -eq 'fix') { $t } elseif ($k -eq 'defer') { "deferred: $t" } else { "$(Get-KitCut $_.decision 30): $t" })"
      $own = @($Mrs | Where-Object { @($_.ids) -contains $rid })
      if (-not $own.Count) { $ar = @($DescMap.Keys | Where-Object { "$($DescMap[$_])" -match "(?<![\w-])$([regex]::Escape($rid))(?![\w-])" }); $own = @($Mrs | Where-Object { $mi = @($_.ids); @($ar | Where-Object { $mi -contains $_ }).Count }) }
      if (-not $own.Count -and $AllDone -and $k -eq 'fix') { $own = @($Mrs) }
      $text = Format-KitItemText $rid $d @($own | ForEach-Object url)
      [pscustomobject]@{ id = $rid; sev = "$($_.sev)"; text = $text; fix = ($k -eq 'fix'); done = ($k -eq 'fix' -and ($AllDone -or $DoneIds -contains $rid)) } })
}
# counts of severity x decision, then the items not in this wave (per-subtask ids live in the delivery tables)
function Format-KitTriage($Tri) {
  $rows = @($Tri.rows); $kinds = @('fix', 'defer', 'duplicate', 'already fixed')
  $cnt = { param($s, $k) @($rows | Where-Object { ($null -eq $s -or $_.sev -eq $s) -and ($null -eq $k -or (Get-KitItemKind $_.decision) -eq $k) }).Count }
  $sevs = @($rows | ForEach-Object sev | Select-Object -Unique | Sort-Object { Get-KitSevRank $_ })
  $l = @("**Triage** ($($Tri.source)): $($rows.Count) = $(@($kinds | Where-Object { & $cnt $null $_ } | ForEach-Object { "$(& $cnt $null $_) $_" }) -join ' · ')", '',
    "| Severity | $($kinds -join ' | ') | Total |", "|---$('|---' * ($kinds.Count + 1))|")
  foreach ($s in $sevs) { $l += "| $s | $(@($kinds | ForEach-Object { & $cnt $s $_ }) -join ' | ') | $(& $cnt $s $null) |" }
  $l += "| **Total** | $(@($kinds | ForEach-Object { & $cnt $null $_ }) -join ' | ') | **$($rows.Count)** |"
  $out = @($rows | Where-Object { (Get-KitItemKind $_.decision) -in 'defer', 'duplicate' })
  if ($out.Count) {
    $l += @('', '**Not in this wave**', '', '| Id | Severity | Verdict | Reason |', '|---|---|---|---|')
    foreach ($r in $out) { $l += "| $(Get-KitCut $r.id 40) | $(Get-KitCut $r.sev 20) | $(if ((Get-KitItemKind $r.decision) -eq 'defer') { 'deferred' } else { Get-KitCut $r.decision 40 }) | $(Get-KitCut $r.title 140)$(if ($r.decisionId) { " (decision $($r.decisionId))" }) |" }
  }
  $l -join "`n"
}
# a repo's table heading: its shortest alias (API, UI ... in capitals) + the name, e.g. "API (backend)"
$script:KitAcronyms = @('api', 'ui', 'db', 'cli', 'sdk', 'ios', 'cs', 'ai', 'ml', 'etl')
function Get-KitRepoLabel([string]$Repo) {
  $al = @(@(@(Get-KitValue 'repos' @()) | Where-Object { "$($_.name)" -eq $Repo } | ForEach-Object { @($_.aliases) }) | Where-Object { $_ } | Sort-Object -Stable Length)[0]
  if (-not $al) { return $(if ($Repo -eq 'other') { 'Other' } else { $Repo }) }
  "$(if ($script:KitAcronyms -contains "$al".ToLower()) { "$al".ToUpper() } else { "$al".Substring(0, 1).ToUpper() + "$al".Substring(1) }) ($Repo)"
}
# fix items per severity: 11C/1H (C H M L initials, another severity in full, zero counts left out)
function Format-KitSevCounts($Items) { @(@($Items) | Group-Object sev | Sort-Object { Get-KitSevRank $_.Name } | ForEach-Object { $sn = "$($_.Name)".Trim(); "$($_.Count)$(if ((Get-KitSevRank $sn) -lt 9) { $sn.Substring(0, 1).ToUpper() } elseif ($sn) { " $(Get-KitCut $sn 20)" } else { ' ?' })" }) -join '/' }
# $Rows: one per subtask (Update-KitParentRollup): the summary line, then one table per repo, merge order inside
function Format-KitDelivery($Rows, [string]$Note) {
  $n = $Rows.Count; $m = @($Rows | Where-Object merged).Count; $t = @($Rows | Where-Object inTest).Count; $c = @($Rows | Where-Object closed).Count
  $envs = @($Rows | ForEach-Object { @($_.envs) } | Group-Object | ForEach-Object { "$($_.Name) ($($_.Count))" })
  $notMerged = $n - $m; $undeployed = @($Rows | Where-Object { $_.merged -and -not @($_.envs).Count }).Count; $toTest = @($Rows | Where-Object { @($_.envs).Count -and -not $_.inTest -and -not $_.closed }).Count
  $next = if ($notMerged) { "merge: $notMerged subtask(s) not merged" } elseif ($undeployed) { "$undeployed merged, not deployed" } elseif ($toTest) { "move to in test: $toTest" } elseif ($t) { "QA: $t in test" } else { 'done' }
  $l = @("**Delivery status**: $m of $n merged · deployed: $(if ($envs.Count) { $envs -join ', ' } else { 'none' }) · $t in test · $c closed · next: $next$(if ($Note) { " · $Note" })")
  foreach ($g in @($Rows | Group-Object repo | Sort-Object { @($_.Group | ForEach-Object order | Measure-Object -Minimum).Minimum })) {
    $gr = @($g.Group | Sort-Object -Stable @{ Expression = { -not $_.merged } }, @{ Expression = { if ($_.merged) { @($_.mrs | ForEach-Object { ConvertTo-KitWhen $_.mergedAt } | Sort-Object)[-1] } else { [datetimeoffset]::MinValue } } }, order)
    $l += @('', "**$(Get-KitRepoLabel $g.Name)**", '', '| Subtask | Status | MRs | Items | Severity | Item ids |', '|---|---|---|---|---|---|')
    foreach ($r in $gr) {
      $mr = @($r.mrs | ForEach-Object { "$(if ($_.url) { "[!$($_.iid)]($($_.url))" } else { "!$($_.iid)" })$(if ($_.repo -ne $g.Name) { " $($_.repo)" }) $($_.state)$(if (@($_.envs).Count) { ' · ' + (@($_.envs) -join ', ') })" }) -join '<br>'
      $fx = @($r.items | Where-Object fix); $sv = Format-KitSevCounts $fx
      $l += "| [$(Get-KitCut "$(if ($r.area) { "$($r.area) · " })$($r.name)" 80)]($($r.url)) | $(Get-KitCut $r.status 40) | $(if ($mr) { $mr } else { '—' }) | $(if ($fx.Count) { "$(@($fx | Where-Object done).Count)/$($fx.Count)" } else { '—' }) | $(if ($sv) { $sv } else { '—' }) | $(if ($fx.Count) { Get-KitCut (@($fx.id) -join ', ') 4000 } else { '—' }) |"
    }
  }
  $l -join "`n"
}

# ---- rollup: read (throttled), build, write on a diff
function Get-KitDeployIndex {
  $ix = @{}; $f = Get-KitPath deploy-log
  foreach ($ln in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
    $d = try { $ln | ConvertFrom-Json } catch { $null }; if ($d.event -ne 'record' -or -not $d.target) { continue }
    foreach ($ref in @($d.mrs)) { if (-not $ix.ContainsKey("$ref")) { $ix["$ref"] = @() }; $ix["$ref"] += [pscustomobject]@{ env = "$($d.target)"; at = (ConvertTo-KitWhen $d.at) } }
  }
  $ix
}
# what the local state says about a parent's subtasks: equal + fresh -> no read
function Get-KitRollupLocalSig($Ro, [string[]]$Subs, $Tracking) {
  $lf = Get-Item -LiteralPath (Get-KitPath deploy-log) -ErrorAction SilentlyContinue
  Get-KitRollupHash ((@($Subs | Sort-Object | ForEach-Object { $tr = $Tracking[$_]; "$_=$(@($tr.mrs) -join ',')/$($tr.done)" }) + "$($lf.Length)" + ($Ro.triage | ConvertTo-Json -Depth 6 -Compress)) -join '|')
}
function Set-KitItemsChecklist([string]$Task, $Items) { Set-KitTaskChecklist $Task 'Items' $Items }   # lib.ps1: checklist verb, else a description section
function Update-KitParentRollup([string]$Parent, [switch]$Force) {
  $ix = Read-KitState (Get-KitTaskFile $Parent); $ro = if ($ix.rollup -is [Collections.IDictionary]) { $ix.rollup } else { @{} }
  $trk = (Read-KitTracking).tasks; $known = @($ro.subtasks | Where-Object { $_ })
  $sig0 = Get-KitRollupLocalSig $ro $known $trk; $mins = [double](Get-KitSetting 'track.rollupMinutes' 30)
  $ans = $ro.closeAsk -and $ro.closeActed -ne $ro.closeAsk -and (Get-KitCloseAsk "$($ro.closeAsk)").status -eq 'answered'   # a new answer: act now
  $fresh = $ro.readAt -and ((Get-Date) - [datetime]$ro.readAt).TotalMinutes -lt $mins
  if (-not $Force -and (($ro.parentClosed -and $fresh) -or (-not $ro.parentClosed -and -not $ans -and $ro.localSig -eq $sig0 -and $fresh))) { return }   # a closed parent: its status read once per rollupMinutes
  $stamp = { Update-KitTaskIndex $Parent { param($x) if ($x.rollup -isnot [Collections.IDictionary]) { $x.rollup = @{} }; $x.rollup.readAt = (Get-Date).ToString('o'); $x.rollup.localSig = $sig0 } }   # a failed or empty read waits too
  Clear-TrackerMemo $Parent; $pt = Get-TrackerTask $Parent; if (-not $pt.name) { & $stamp; return "ROLLUP ${Parent}: tracker read failed, nothing written" }
  if ($ro.parentClosed -and (Test-TrackerStatus $pt.status 'closed')) { if (-not $Force) { & $stamp; return } }   # still closed: final
  elseif ($ro.parentClosed) {   # -Force too: the old answer never re-closes it
    Update-KitTaskIndex $Parent { param($x) $x.rollup.parentClosed = $false; $x.rollup.closeHold = 'reopened' }; $ro.parentClosed = $false; $ro.closeHold = 'reopened' }   # reopened: its delivery table updates again
  $subs = @($pt.subtasks | Where-Object { $_.id }); if (-not $subs.Count) { & $stamp; return }
  $tri = ConvertTo-KitTriage $ro.triage; $areaOf = @{}; foreach ($a in @($tri.agents)) { if ($a.task) { $areaOf[$a.task] = $a } }
  $mc = @{}; if ($ro.mrs -is [Collections.IDictionary]) { foreach ($k in $ro.mrs.Keys) { $mc[$k] = $ro.mrs[$k] } }
  $dep = Get-KitDeployIndex; $allIds = @($tri.rows | ForEach-Object id); $did = [Collections.Generic.List[string]]::new()
  $rows = foreach ($sb in $subs) {
    $ag = $areaOf[$sb.id]; $sx = Read-KitState (Get-KitTaskFile $sb.id); $refs = @(Get-KitTrackRefs $trk[$sb.id].mrs)
    if (-not $refs.Count -and $ag.repo -and (Get-Command Find-TaskMrs -ErrorAction SilentlyContinue)) { $refs = @(Find-TaskMrs $sb.id @($ag.repo)) }
    $mrs = @(foreach ($ref in $refs) {
        if ("$ref" -notmatch '^(?<r>[^!]+)!(?<i>\d+)$') { continue }; $repo = $Matches.r; $iid = $Matches.i; $c = $mc["$ref"]; $mv = $null
        if (-not $c -or $c.state -notin 'merged', 'closed') {   # merged / closed are final: never fetched again
          $pp = ProjPath $repo; $mv = if ($pp) { try { Invoke-HostVerb 'mr.get' @{ repo = $pp; n = $iid } } catch { } }
          if (-not $mv.state -and $c) { $mv = $null }   # a failed read keeps what is known
        }
        if ($mv.state -or -not $c) {
          $st = switch ("$($mv.state)") { 'merged' { 'merged' } 'opened' { 'open' } 'closed' { 'closed' } default { if ($c) { $c.state } else { 'unknown' } } }
          $c = @{ state = $st; url = "$(if ($pp) { try { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $iid } } catch { } })"; mergedAt = "$((ConvertTo-KitWhen $mv.merged_at)?.ToString('o'))"; ids = @(Get-KitMrNamedIds (@($allIds) + @($sx.itemIds)) $mv) }
          $mc["$ref"] = $c
        }
        if ($c.state -eq 'closed') { continue }
        [pscustomobject]@{ ref = "$ref"; repo = $repo; iid = $iid; url = $c.url; state = $c.state; mergedAt = $c.mergedAt; ids = @($c.ids); envs = @($dep["$ref"] | ForEach-Object env | Select-Object -Unique); deployedAt = @($dep["$ref"] | ForEach-Object at) }
      })
    $mrs = @(@($mrs | Where-Object state -eq 'merged' | Sort-Object { ConvertTo-KitWhen $_.mergedAt }) + @($mrs | Where-Object state -ne 'merged' | Sort-Object { [int]$_.iid }))
    $merged = $mrs.Count -gt 0 -and -not @($mrs | Where-Object state -ne 'merged').Count
    $envs = if ($merged) { @(@($mrs[0].envs) | Where-Object { $en = $_; -not @($mrs | Where-Object { @($_.envs) -notcontains $en }).Count }) } else { @() }
    if ($ag -and $sx -and -not $sx.Contains('itemDesc') -and ($stk = try { Get-TrackerTask $sb.id } catch { $null }).name) {   # its own Items words: from the subtask's Items list, read once
      $di0 = @(Get-KitDescItems $stk.description); $sx.itemDesc = @{}; foreach ($e in $di0) { $sx.itemDesc[$e.id] = $e.text }; if ($di0.Count) { $sx.itemIds = @($di0.id) }
      $dsc = $sx.itemDesc; $dids = @($sx.itemIds); Update-KitTaskIndex $sb.id { param($x) $x.itemDesc = $dsc; $x.itemIds = $dids } }
    $items = if ($ag) { @(Get-KitSubItems $tri $ag.area @($mrs | Where-Object state -eq 'merged' | ForEach-Object { @($_.ids) }) $merged $mrs $(if ($sx.itemDesc -is [Collections.IDictionary]) { $sx.itemDesc } else { @{} })) } else { @() }
    if ($items.Count) {   # the task's own Items ids (areas) share the checklist: one ticks once every MR naming it merged, all once all merged
      $tid = @($items.id); $items += @(@($sx.itemIds) | Where-Object { $_ -and $tid -notcontains $_ } | ForEach-Object { $di = $_; $nm = @($mrs | Where-Object { @($_.ids) -contains $di })
          [pscustomobject]@{ id = $di; sev = ''; text = (Format-KitItemText $di (Get-KitItemDesc "$($sx.itemDesc[$di])" $tri.rows) $(if ($nm.Count) { @($nm.url) } elseif ($merged) { @($mrs.url) })); fix = $false; done = ($merged -or ($nm.Count -and -not @($nm | Where-Object state -ne 'merged').Count)) } })
      $isig = Get-KitRollupHash (@($items | ForEach-Object { "$($_.text)|$($_.done)" }) -join "`n")
      if ($isig -ne "$($sx.itemsSig)") { try { $null = Set-KitItemsChecklist $sb.id $items; Update-KitTaskIndex $sb.id { param($x) $x.itemsSig = $isig; $x.itemsFrom = 'triage' }; $did.Add("items $($sb.id)") } catch { $did.Add("items $($sb.id) FAILED: $("$_".Split("`n")[0])") } }
    }
    [pscustomobject]@{ id = $sb.id; name = $sb.name; url = $sb.url; status = $sb.status; area = "$($ag.area)"; order = $(if ($ag) { [int]$ag.order } else { 999 })
      repo = $(if ($ag.repo) { $ag.repo } elseif ($mrs.Count) { $mrs[0].repo } else { 'other' }); mrs = $mrs; merged = $merged; envs = $envs; items = $items
      inTest = (Test-TrackerStatus $sb.status 'inTest'); closed = (Test-TrackerStatus $sb.status 'closed') }
  }
  $rows = @($rows); $pc = Update-KitParentClose $Parent $pt $rows $ro; if ($pc.did) { $did.Add($pc.did) }
  $want = [ordered]@{ delivery = (Format-KitDelivery $rows $pc.note) }; if ($tri -and $tri.rows.Count) { $want.triage = Format-KitTriage $tri }
  $sec = @{}; if ($ro.sections -is [Collections.IDictionary]) { foreach ($k in $ro.sections.Keys) { $sec[$k] = $ro.sections[$k] } }
  $desc = "$($pt.description)"; $nd = $desc -replace "`r`n", "`n"; $changed = @()
  foreach ($k in $want.Keys) { $h = Get-KitRollupHash $want[$k]; if ($sec[$k] -ne $h -or $nd.IndexOf("<!-- kit:$k -->") -lt 0) { $nd = Set-KitDescSection $nd $k $want[$k] $(if ($k -eq 'triage') { 'delivery' }); $sec[$k] = $h; $changed += $k } }
  if ($changed.Count) { try { $null = Set-TrackerDescription $Parent $nd; $did.Add("description ($($changed -join ', '))") } catch { $did.Add("description FAILED: $("$_".Split("`n")[0])"); foreach ($k in $changed) { $sec.Remove($k) } } }
  $ms = @($ro.milestones | Where-Object { $_ }); $kit = @($rows | Where-Object { $_.area -or $trk.ContainsKey($_.id) }); $n = $kit.Count   # only subtasks the kit tracks or triaged
  $due = [ordered]@{}
  if ($n -and -not @($kit | Where-Object { -not $_.merged }).Count) { $due['merged'] = "All $n subtasks merged: delivery status in the description." }
  foreach ($en in @($kit | ForEach-Object { @($_.envs) } | Select-Object -Unique)) { if (-not @($kit | Where-Object { @($_.envs) -notcontains $en }).Count) { $due["deployed:$en"] = "All $n subtasks deployed to ${en}: delivery status in the description." } }
  if ($n -and -not @($kit | Where-Object { -not $_.closed }).Count) { $due['closed'] = "All $n subtasks closed." }
  foreach ($k in @($due.Keys | Where-Object { $ms -notcontains $_ })) { try { $null = Add-TrackerComment $Parent $due[$k]; $ms += $k; $did.Add("milestone $k") } catch { $did.Add("milestone $k FAILED: $("$_".Split("`n")[0])") } }
  $subIds = @($subs.id)
  Update-KitTaskIndex $Parent { param($x)
    if ($x.rollup -isnot [Collections.IDictionary]) { $x.rollup = @{} }
    $x.rollup.subtasks = $subIds; $x.rollup.mrs = $mc; $x.rollup.sections = $sec; $x.rollup.milestones = @($ms); $x.rollup.readAt = (Get-Date).ToString('o')
    $x.rollup.closeAsk = "$($pc.ask)"; $x.rollup.closeActed = "$($pc.acted)"; $x.rollup.parentClosed = $pc.note -eq 'parent closed' }
  $sig1 = Get-KitRollupLocalSig (Read-KitState (Get-KitTaskFile $Parent)).rollup $subIds $trk
  Update-KitTaskIndex $Parent { param($x) $x.rollup.localSig = $sig1 }
  if ($did.Count) { "ROLLUP ${Parent}: $($did -join ' · ')" }
}

# ---- items: every built task's own "Items" checklist from its description's Items list (launch -Self / -Check write it, track run
# ticks it: an id a merged MR names, all once the task's MRs are all merged); a subtask with triage rows keeps the rollup's checklist
function Get-KitDescItemIds([string]$Text) { @(Get-KitDescItems $Text | ForEach-Object id) }
# the Items list as { id; text = its words after the id (JR (api-repo, refine): P4-JR-01 -> 'api-repo, refine: P4-JR-01') }
function Get-KitDescItems([string]$Text) {
  $ls = @("$Text" -split "`r?`n"); $o = @(); $idRx = '^(?<id>[A-Za-z]+-?\d[\w-]*)(?![\w-])'
  for ($i = 0; $i -lt $ls.Count; $i++) {
    if ($ls[$i] -notmatch '(?i)^\W{0,6}(?:Items|Bugs)\b[^:]*:\W*(?<l>.*)$') { continue }
    # items split on ' · ' and list bullets; a piece on ',' / ';' only when the first part is a bare id and each part starts with one ("A1, A2 (x)"), never inside an item's text
    $o = @(foreach ($seg in $Matches.l -split ' · ') { $cs = @($seg -split '[,;]' | ForEach-Object { ($_ -replace '[`*]', '').Trim() } | Where-Object { $_ }); if ($cs.Count -gt 1 -and $cs[0] -match "$idRx\s*(\([^)]*\))?$" -and -not @($cs | Where-Object { $_ -notmatch $idRx }).Count) { $cs } else { $seg } })
    for ($j = $i + 1; $j -lt $ls.Count -and $ls[$j] -match '^\s*[-*]\s+(\[.\]\s*)?(?<b>.+)$'; $j++) { $o += $Matches.b }; break
  }
  # a **Label:** piece is the next field; an item's id = its leading id token (TP-01), else its text before ( or :
  $seen = @{}
  @($o | Where-Object { $_ -notmatch '^\s*\*\*[^*]+:\*\*' } | ForEach-Object { $t = ($_ -replace '[`*]', '' -replace '\\(?=[_*])').Trim()
      $id = if ($t -match $idRx) { $Matches.id } else { (($t -split ' · ')[0] -replace '\s*[(:].*$', '').Trim() }
      $r = $t.Substring([Math]::Min($t.Length, $t.IndexOf($id) + $id.Length)) -replace '^[\s·:,–—-]+'; if ($r -match '^\((?<p>[^)]*)\)\s*:?\s*(?<q>.*)$') { $r = (@($Matches.p, $Matches.q) | Where-Object { $_ }) -join ': ' }
      if ($id -and -not $seen[$id]) { $seen[$id] = 1; [pscustomobject]@{ id = $id; text = $r.Trim() } } })
}
# no Items list: ONE item "MRs · <task name> · <MR URLs>" carries the links; -Force: a final checklist is written again (track add)
function Update-KitTaskItems([string]$Task, $T, [switch]$Force) {
  $x = Read-KitState (Get-KitTaskFile $Task); if ($x.itemsFrom -eq 'triage' -or ($x.itemsFinal -and -not $Force)) { return }
  $dsc = @{}; if ($T) { foreach ($e in @(Get-KitDescItems $T.description)) { $dsc[$e.id] = $e.text } } elseif ($x.itemDesc -is [Collections.IDictionary]) { foreach ($k in $x.itemDesc.Keys) { $dsc[$k] = $x.itemDesc[$k] } }
  $ids = @(@(if ($T) { Get-KitDescItemIds $T.description } else { $x.itemIds }) | Where-Object { $_ }); $tr = (Read-KitTracking).tasks[$Task]
  $one = -not $ids.Count -or "$ids" -eq 'MRs'; if ($one) { if (-not @($tr.mrs).Count) { return }; $ids = @('MRs'); if ($T.name) { $dsc.MRs = $T.name } }
  $mc = @{}; if ($x.itemsMrs -is [Collections.IDictionary]) { foreach ($k in $x.itemsMrs.Keys) { $mc[$k] = $x.itemsMrs[$k] } }; $named = @{}
  $look = -not $x.itemsReadAt -or ((Get-Date) - [datetime]$x.itemsReadAt).TotalMinutes -ge [double](Get-KitSetting 'track.rollupMinutes' 30)
  foreach ($ref in @(Get-KitTrackRefs $tr.mrs)) {
    if (($look -or $Force) -and -not $mc.Contains("$ref") -and "$ref" -match '^(?<r>[^!]+)!(?<i>\d+)$') {   # merged MRs only, each read once
      $pp = ProjPath $Matches.r; $mv = if ($pp) { try { Invoke-HostVerb 'mr.get' @{ repo = $pp; n = $Matches.i } } catch { } }
      if ("$($mv.state)" -eq 'merged') { $mc["$ref"] = @(Get-KitMrNamedIds $ids $mv) }
    }
    $u = if ("$ref" -match '^(?<r>[^!]+)!(?<i>\d+)$' -and ($pp = ProjPath $Matches.r)) { try { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $Matches.i } } catch { } }
    foreach ($y in @(if ($one) { 'MRs' } else { $mc["$ref"] })) { if ($y) { $named[$y] = @($named[$y]) + @($u) | Where-Object { $_ } } }
  }
  $all = @(Get-KitTrackRefs $tr.mrs | ForEach-Object { if ("$_" -match '^(?<r>[^!]+)!(?<i>\d+)$' -and ($pp = ProjPath $Matches.r)) { try { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $Matches.i } } catch { } } })
  $allIn = $one -and @(Get-KitTrackRefs $tr.mrs).Count -and -not @(Get-KitTrackRefs $tr.mrs | Where-Object { -not $mc.Contains("$_") }).Count   # the one MRs item: resolved once every MR merged, even linked late (an Items list: by the ids its MRs name)
  $items = @($ids | ForEach-Object { [pscustomobject]@{ text = (Format-KitItemText $_ $dsc[$_] $(if ($named[$_]) { $named[$_] } elseif ($tr.done -or $allIn) { $all })); done = [bool]($tr.done -or $allIn -or (-not $one -and $named.Contains($_))) } })
  $sig = Get-KitRollupHash (@($items | ForEach-Object { "$($_.text)|$($_.done)" }) -join "`n")
  if ($look -or $Force) { Update-KitTaskIndex $Task { param($y) $y.itemsReadAt = (Get-Date).ToString('o'); $y.itemsMrs = $mc } }; if ($sig -eq "$($x.itemsSig)") { return }
  $null = Set-KitItemsChecklist $Task $items; $fin = -not @($items | Where-Object { -not $_.done }).Count
  Update-KitTaskIndex $Task { param($y) $y.itemsSig = $sig; $y.itemsFrom = 'desc'; $y.itemIds = $ids; $y.itemDesc = $dsc; $y.itemsMrs = $mc; $y.itemsFinal = $fin }
  "items ${Task}: $(@($items | Where-Object done).Count)/$($items.Count) done"
}

# ---- close: every subtask in the tracker's closed status -> ONE close-parent decision; the parent closes only on the owner's answer
# (owner, 2026-11-11; a task without subtasks never gets here). Reopened subtask: an answered ask is spent, the next all-closed asks again
function Get-KitCloseAsk([string]$Id) { $f = if ($Id) { Join-Path (Get-KitPath decisions) "$Id.json" }; if ($f -and (Test-Path -LiteralPath $f)) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } }
function Update-KitParentClose([string]$Parent, $Pt, $Rows, $Ro) {
  $ask = "$($Ro.closeAsk)"; $d = Get-KitCloseAsk $ask
  if (Test-TrackerStatus "$($Pt.status)" 'closed') { return @{ ask = $ask; note = 'parent closed' } }
  if (-not $Rows.Count -or @($Rows | Where-Object { -not $_.closed }).Count) { if ($Ro.closeHold) { Update-KitTaskIndex $Parent { param($y) $y.rollup.closeHold = '' } }; return @{ ask = $(if ($d.status -eq 'pending') { $ask }); note = '' } }
  if ($Ro.closeHold) { return @{ ask = ''; note = 'parent reopened: no close ask until a subtask reopens' } }   # a person reopened it: never closed again by the old answer
  if (-not $d) {
    $o = Invoke-Decide ask -Run rollup -Agent coordinator -Item $Parent -Task $Parent -Gate close -Question "All $($Rows.Count) subtasks of $Parent are closed: close the parent?" -Options 'A: close the parent — every subtask is closed', 'B: keep it open — the answer says why' -Recommend A
    $nid = if ("$o" -match 'DECISION (\S+) pending') { $Matches[1] }; Update-KitTaskIndex $Parent { param($y) if ($y.rollup -isnot [Collections.IDictionary]) { $y.rollup = @{} }; $y.rollup.closeAsk = "$nid" }; return @{ ask = "$nid"; note = "parent: close asked ($nid)"; did = "close asked $nid" }
  }
  if ($d.status -ne 'answered') { return @{ ask = $ask; note = "parent: close asked ($ask)" } }
  $acted = @{ ask = $ask; acted = $ask }
  if ("$($d.answer)" -cnotmatch '^\s*A\s*(?:[:.)—-]|$)' -and "$($d.answer)" -notmatch '^\s*close(?: it| the parent)?\s*\.?\s*$') { return $acted + @{ note = "parent kept open: $(Get-KitCut $d.answer 80) ($ask)" } }
  try { $null = Set-TrackerStatus $Parent closed; $acted + @{ note = 'parent closed'; did = "parent closed ($ask)" } } catch { @{ ask = $ask; note = "parent: close failed, retried next run ($ask)"; did = "parent close FAILED: $("$_".Split("`n")[0])" } }
}

# ---- verb and hook
function Invoke-TaskRollup([string]$Task, [string]$From, [switch]$Quiet) {
  if (-not $Task) { 'usage: bossy.ps1 track rollup -Task <parent> [-From <brief dir | item table .md>]'; exit 2 }
  if ($From) {
    $tri = Read-KitTriage $From; if (-not @($tri.rows).Count) { "track rollup: no item table with ID and Area columns in $From"; exit 1 }
    Update-KitTaskIndex $Task { param($x) if ($x.rollup -isnot [Collections.IDictionary]) { $x.rollup = @{} }; $x.rollup.triage = $tri }
    "track rollup: $(@($tri.rows).Count) item(s), $(@($tri.agents).Count) area(s) from $($tri.source) stored on $Task"
  }
  $o = Update-KitParentRollup $Task -Force; if ($o) { $o } elseif (-not $Quiet) { "ROLLUP ${Task}: no change" }
}
# parents: a stored triage, or the tracker parent of a not-done tracked task (looked up once per task, 10 per run)
function Invoke-KitTrackRollupHook([switch]$Quiet) {
  $parents = [ordered]@{}; $look = 0
  foreach ($g in @(Get-ChildItem -LiteralPath (Get-KitPath tasks) -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $x = Read-KitState $g.FullName; if ($x.task -and $x.rollup -is [Collections.IDictionary]) { $parents["$($x.task)"] = 1 }
    if ($x.task -and $x.itemsFrom -eq 'desc' -and -not $x.itemsFinal) { $o = try { Update-KitTaskItems "$($x.task)" } catch { "ITEMS $($x.task) failed: $("$_".Split("`n")[0])" }; if ($o -and -not $Quiet) { $o } } }
  foreach ($t in @((Read-KitTracking).tasks.Values | Where-Object { $_.task -and -not $_.done })) {
    $x = Read-KitState (Get-KitTaskFile $t.task)
    if ($x -and $x.Contains('parent')) { if ($x.parent) { $parents["$($x.parent)"] = 1 }; continue }
    if ($look++ -ge 10) { continue }
    $tk = try { Get-TrackerTask $t.task } catch { $null }; if (-not $tk.name) { continue }
    $p = "$($tk.parent)"; Update-KitTaskIndex $t.task { param($y) $y.parent = $p }; if ($p) { $parents[$p] = 1 }
  }
  foreach ($p in @($parents.Keys)) { $o = try { Update-KitParentRollup $p } catch { "ROLLUP $p failed: $("$_".Split("`n")[0])" }; if ($o -and -not $Quiet) { $o } }
}
