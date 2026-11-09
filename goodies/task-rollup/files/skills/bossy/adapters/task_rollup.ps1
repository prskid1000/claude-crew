<#
task_rollup.ps1 (goody task-rollup): a parent task's delivery status, triage and subtask Items checklists, all script-built,
dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 track rollup -Task <parent> [-From <brief dir | item table .md>]   -From stores the run's triage (item table + launch
    args) in the parent's task state; then rebuilds and writes what changed
  track run calls Invoke-KitTrackRollupHook: every parent with a not-done tracked subtask or a stored triage
Reads: task state (.state/tasks: track, docs), the git host (Invoke-HostVerb mr.get / mr.url; merged MRs cached for good),
the deploy log, the tracker (parent + its subtasks, one view per read). Writes (tracker adapter, only on a diff): the parent
description between <!-- kit:delivery --> / <!-- kit:triage --> markers, each subtask's "Items" checklist (adapter verb
checklist, else an <!-- kit:items --> description section), one comment per milestone (all merged, deployed to <env>, all closed).
No read while nothing local changed and track.rollupMinutes (30) has not passed: an unchanged run makes 0 calls.
Sections: L17 triage · L61 render · L126 rollup
Exit codes: 0 ok · 1 no item table in -From · 2 usage.
#>
#Requires -Version 7

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
  $all = @($la.agents); $per = [int]"$($la.batch)"
  $agents = @(for ($i = 0; $i -lt $all.Count; $i++) {
      $a = $all[$i]; $txt = "$($a.area) $($a.note)"
      $tid = if ($a.task) { "$($a.task)" } elseif ($txt -match '(?i)\btask\s+(?<t>(?=[\w-]*\d)[\w-]+)') { $Matches.t } else { '' }
      $repo = if ($a.repo) { "$($a.repo)" } else { @($names.Keys | Sort-Object Length -Descending | Where-Object { $txt -match "(?<![\w-])$([regex]::Escape($_))(?![\w-])" } | ForEach-Object { $names[$_] })[0] }
      [pscustomobject]@{ area = "$($a.id)"; task = $tid; repo = "$repo"; batch = $(if ($per -gt 0 -and $all.Count -gt $per) { [int][math]::Floor($i / $per) + 1 } else { 0 }); order = $i }
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
function Get-KitRollupHash([string]$Text) { [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$Text"))) }
# one subtask's items, severity first: fix items tick when merged; deferred / duplicate ones stay unticked with their reason
function Get-KitSubItems($Tri, [string]$Area, [string[]]$DoneIds, [bool]$AllDone) {
  @($Tri.rows | Where-Object { $_.area -eq $Area } | Sort-Object -Stable { Get-KitSevRank $_.sev } | ForEach-Object {
      $k = Get-KitItemKind $_.decision; $t = Get-KitCut $_.title 90
      $text = "$($_.id) · $($_.sev) · $(if ($k -eq 'fix') { $t } elseif ($k -eq 'defer') { "deferred: $t" } else { "$(Get-KitCut $_.decision 30): $t" })"
      [pscustomobject]@{ id = $_.id; text = $text; fix = ($k -eq 'fix'); done = ($k -eq 'fix' -and ($AllDone -or $DoneIds -contains $_.id)) } })
}
function Format-KitTriage($Tri, [hashtable]$Urls) {
  $rows = @($Tri.rows); $kinds = @('fix', 'defer', 'duplicate', 'already fixed')
  $cnt = { param($s, $k) @($rows | Where-Object { ($null -eq $s -or $_.sev -eq $s) -and ($null -eq $k -or (Get-KitItemKind $_.decision) -eq $k) }).Count }
  $sevs = @($rows | ForEach-Object sev | Select-Object -Unique | Sort-Object { Get-KitSevRank $_ })
  $l = @("**Triage** ($($Tri.source)): $($rows.Count) = $(@($kinds | Where-Object { & $cnt $null $_ } | ForEach-Object { "$(& $cnt $null $_) $_" }) -join ' · ')", '',
    "| Severity | $($kinds -join ' | ') | Total |", "|---$('|---' * ($kinds.Count + 1))|")
  foreach ($s in $sevs) { $l += "| $s | $(@($kinds | ForEach-Object { & $cnt $s $_ }) -join ' | ') | $(& $cnt $s $null) |" }
  $l += "| **Total** | $(@($kinds | ForEach-Object { & $cnt $null $_ }) -join ' | ') | **$($rows.Count)** |"
  $l += @('', '**Per subtask**')
  foreach ($a in @($Tri.agents)) {
    $mine = @($rows | Where-Object { $_.area -eq $a.area -and (Get-KitItemKind $_.decision) -eq 'fix' } | Sort-Object -Stable { Get-KitSevRank $_.sev }); if (-not $mine.Count) { continue }
    $by = @($mine | Group-Object sev | Sort-Object { Get-KitSevRank $_.Name } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ' · '
    $l += "- $(if ($Urls[$a.task]) { "[$($a.area)]($($Urls[$a.task]))" } else { $a.area }) → $(@($mine.id) -join ', ') ($($mine.Count): $by)"
  }
  $out = @($rows | Where-Object { (Get-KitItemKind $_.decision) -in 'defer', 'duplicate' })
  if ($out.Count) { $l += @('', '**Not in this wave**'); foreach ($r in $out) { $l += "- $($r.id) · $(if ((Get-KitItemKind $r.decision) -eq 'defer') { 'deferred' } else { $r.decision }) · $(Get-KitCut $r.title 140)$(if ($r.decisionId) { " · decision $($r.decisionId)" })" } }
  $l -join "`n"
}
# $Rows: one per subtask (Update-KitParentRollup); groups by repo (+ batch when the run had several), merge order inside
function Format-KitDelivery($Rows) {
  $n = $Rows.Count; $m = @($Rows | Where-Object merged).Count; $t = @($Rows | Where-Object inTest).Count; $c = @($Rows | Where-Object closed).Count
  $envs = @($Rows | ForEach-Object { @($_.envs) } | Group-Object | ForEach-Object { "$($_.Name) ($($_.Count))" })
  $notMerged = $n - $m; $undeployed = @($Rows | Where-Object { $_.merged -and -not @($_.envs).Count }).Count; $toTest = @($Rows | Where-Object { @($_.envs).Count -and -not $_.inTest -and -not $_.closed }).Count
  $next = if ($notMerged) { "merge: $notMerged subtask(s) not merged" } elseif ($undeployed) { "$undeployed merged, not deployed" } elseif ($toTest) { "move to in test: $toTest" } elseif ($t) { "QA: $t in test" } else { 'done' }
  $l = @("**Delivery status**: $m of $n merged · deployed: $(if ($envs.Count) { $envs -join ', ' } else { 'none' }) · $t in test · $c closed · next: $next")
  $multi = @($Rows | ForEach-Object batch | Select-Object -Unique).Count -gt 1
  foreach ($g in @($Rows | Group-Object { "$($_.repo)$(if ($multi) { ", batch $($_.batch)" })" } | Sort-Object { @($_.Group | ForEach-Object order | Measure-Object -Minimum).Minimum })) {
    $gr = @($g.Group | Sort-Object -Stable @{ Expression = { -not $_.merged } }, @{ Expression = { if ($_.merged) { @($_.mrs | ForEach-Object { ConvertTo-KitWhen $_.mergedAt } | Sort-Object)[-1] } else { [datetimeoffset]::MinValue } } }, order)
    $l += @('', "**$($g.Name) · $($gr.Count)**: $(@($gr | Where-Object merged).Count) merged · $(@($gr | Where-Object { @($_.envs).Count }).Count) deployed · $(@($gr | Where-Object closed).Count) closed", '',
      '| Subtask | Status | MRs (merge order) | Testing docs | Items | Updated |', '|---|---|---|---|---|---|')
    foreach ($r in $gr) {
      $mr = @($r.mrs | ForEach-Object { "$(if ($_.url) { "[!$($_.iid)]($($_.url))" } else { "!$($_.iid)" }) $($_.repo) $($_.state)$(if (@($_.envs).Count) { ' · ' + (@($_.envs) -join ', ') })" }) -join '<br>'
      $docs = @($(if ($r.human) { "[human]($($r.human))" }), $(if ($r.ai) { "[AI]($($r.ai))" }) | Where-Object { $_ }) -join ' · '
      $l += "| [$(Get-KitCut "$(if ($r.area) { "$($r.area) · " })$($r.name)" 80)]($($r.url)) | $($r.status) | $(if ($mr) { $mr } else { '—' }) | $(if ($docs) { $docs } else { '—' }) | $(if ($r.total) { "$($r.done)/$($r.total)" } else { '—' }) | $(if ($r.updated) { $r.updated.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '—' }) |"
    }
  }
  $l -join "`n"
}
# the owner's text stays: only <!-- kit:<name> --> ... <!-- /kit:<name> --> is replaced; new: after section $After, else under the testing-doc links
function Set-KitDescSection([string]$Desc, [string]$Name, [string]$Body, [string]$After) {
  $s = "<!-- kit:$Name -->"; $e = "<!-- /kit:$Name -->"; $block = "$s`n$Body`n$e"; $d = "$Desc" -replace "`r`n", "`n"
  $i = $d.IndexOf($s); $j = if ($i -ge 0) { $d.IndexOf($e, $i) } else { -1 }
  if ($i -ge 0 -and $j -gt $i) { return $d.Substring(0, $i) + $block + $d.Substring($j + $e.Length) }
  $ae = "<!-- /kit:$After -->"; $k = if ($After) { $d.IndexOf($ae) } else { -1 }
  if ($k -ge 0) { $p = $k + $ae.Length; return $d.Substring(0, $p) + "`n`n$block" + $d.Substring($p) }
  $lines = @($d -split "`n"); $last = 0
  for ($x = 0; $x -lt $lines.Count; $x++) { if ($lines[$x] -match '(?i)^\W{0,3}Testing doc \(') { $last = $x + 1 } elseif ($lines[$x].Trim()) { break } }
  (@((@($lines | Select-Object -First $last) -join "`n").Trim(), $block, (@($lines | Select-Object -Skip $last) -join "`n").Trim()) | Where-Object { $_ }) -join "`n`n"
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
  Get-KitRollupHash ((@($Subs | Sort-Object | ForEach-Object { $tr = $Tracking[$_]; $dx = (Read-KitState (Get-KitTaskFile $_)).docs; "$_=$(@($tr.mrs) -join ',')/$($tr.done)/$(@($dx.Values | ForEach-Object { $_.url }) -join ',')" }) + "$($lf.Length)" + ($Ro.triage | ConvertTo-Json -Depth 6 -Compress)) -join '|')
}
function Set-KitItemsChecklist([string]$Task, $Items) {
  $ad = $KitAdapters['tracker'][$__trType]
  if ($ad -and $ad.ContainsKey('checklist')) { return __TrA 'checklist' @{ id = $Task; name = 'Items'; items = @($Items | ForEach-Object { @{ text = $_.text; done = [bool]$_.done } }) } }
  Clear-TrackerMemo $Task; $tk = Get-TrackerTask $Task; if (-not $tk.name) { throw "tracker read of $Task failed" }
  $nd = Set-KitDescSection $tk.description 'items' ((@('**Items**') + @($Items | ForEach-Object { "- [$(if ($_.done) { 'x' } else { ' ' })] $($_.text)" })) -join "`n") ''
  if ($nd -ne ("$($tk.description)" -replace "`r`n", "`n")) { Set-TrackerDescription $Task $nd }
}
function Update-KitParentRollup([string]$Parent, [switch]$Force) {
  $ix = Read-KitState (Get-KitTaskFile $Parent); $ro = if ($ix.rollup -is [Collections.IDictionary]) { $ix.rollup } else { @{} }
  $trk = (Read-KitTracking).tasks; $known = @($ro.subtasks | Where-Object { $_ })
  $sig0 = Get-KitRollupLocalSig $ro $known $trk; $mins = [double](Get-KitSetting 'track.rollupMinutes' 30)
  if (-not $Force -and (@($ro.milestones) -contains 'closed' -or ($ro.localSig -eq $sig0 -and $ro.readAt -and ((Get-Date) - [datetime]$ro.readAt).TotalMinutes -lt $mins))) { return }   # all closed: final
  $stamp = { Update-KitTaskIndex $Parent { param($x) if ($x.rollup -isnot [Collections.IDictionary]) { $x.rollup = @{} }; $x.rollup.readAt = (Get-Date).ToString('o'); $x.rollup.localSig = $sig0 } }   # a failed or empty read waits too
  Clear-TrackerMemo $Parent; $pt = Get-TrackerTask $Parent; if (-not $pt.name) { & $stamp; return "ROLLUP ${Parent}: tracker read failed, nothing written" }
  $subs = @($pt.subtasks | Where-Object { $_.id }); if (-not $subs.Count) { & $stamp; return }
  $tri = ConvertTo-KitTriage $ro.triage; $areaOf = @{}; foreach ($a in @($tri.agents)) { if ($a.task) { $areaOf[$a.task] = $a } }
  $mc = @{}; if ($ro.mrs -is [Collections.IDictionary]) { foreach ($k in $ro.mrs.Keys) { $mc[$k] = $ro.mrs[$k] } }
  $dep = Get-KitDeployIndex; $allIds = @($tri.rows | ForEach-Object id); $did = [Collections.Generic.List[string]]::new()
  $rows = foreach ($sb in $subs) {
    $ag = $areaOf[$sb.id]; $sx = Read-KitState (Get-KitTaskFile $sb.id); $refs = @($trk[$sb.id].mrs | Where-Object { $_ })
    if (-not $refs.Count -and $ag.repo -and (Get-Command Find-TaskMrs -ErrorAction SilentlyContinue)) { $refs = @(Find-TaskMrs $sb.id @($ag.repo)) }
    $mrs = @(foreach ($ref in $refs) {
        if ("$ref" -notmatch '^(?<r>[^!]+)!(?<i>\d+)$') { continue }; $repo = $Matches.r; $iid = $Matches.i; $c = $mc["$ref"]; $mv = $null
        if (-not $c -or $c.state -notin 'merged', 'closed') {   # merged / closed are final: never fetched again
          $pp = ProjPath $repo; $mv = if ($pp) { try { Invoke-HostVerb 'mr.get' @{ repo = $pp; n = $iid } } catch { } }
          if (-not $mv.state -and $c) { $mv = $null }   # a failed read keeps what is known
        }
        if ($mv.state -or -not $c) {
          $st = switch ("$($mv.state)") { 'merged' { 'merged' } 'opened' { 'open' } 'closed' { 'closed' } default { if ($c) { $c.state } else { 'unknown' } } }
          $txt = "$($mv.title) $($mv.description) $($mv.source_branch)"
          $c = @{ state = $st; url = "$(if ($pp) { try { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $iid } } catch { } })"; mergedAt = "$((ConvertTo-KitWhen $mv.merged_at)?.ToString('o'))"; ids = @($allIds | Where-Object { $txt -match "(?<![\w-])$([regex]::Escape($_))(?![\w-])" }) }
          $mc["$ref"] = $c
        }
        if ($c.state -eq 'closed') { continue }
        [pscustomobject]@{ ref = "$ref"; repo = $repo; iid = $iid; url = $c.url; state = $c.state; mergedAt = $c.mergedAt; ids = @($c.ids); envs = @($dep["$ref"] | ForEach-Object env | Select-Object -Unique); deployedAt = @($dep["$ref"] | ForEach-Object at) }
      })
    $mrs = @(@($mrs | Where-Object state -eq 'merged' | Sort-Object { ConvertTo-KitWhen $_.mergedAt }) + @($mrs | Where-Object state -ne 'merged' | Sort-Object { [int]$_.iid }))
    $merged = $mrs.Count -gt 0 -and -not @($mrs | Where-Object state -ne 'merged').Count
    $envs = if ($merged) { @(@($mrs[0].envs) | Where-Object { $en = $_; -not @($mrs | Where-Object { @($_.envs) -notcontains $en }).Count }) } else { @() }
    $items = if ($ag) { @(Get-KitSubItems $tri $ag.area @($mrs | Where-Object state -eq 'merged' | ForEach-Object { @($_.ids) }) $merged) } else { @() }
    if ($items.Count) {
      $isig = Get-KitRollupHash (@($items | ForEach-Object { "$($_.text)|$($_.done)" }) -join "`n")
      if ($isig -ne "$($sx.itemsSig)") { try { $null = Set-KitItemsChecklist $sb.id $items; Update-KitTaskIndex $sb.id { param($x) $x.itemsSig = $isig }; $did.Add("items $($sb.id)") } catch { $did.Add("items $($sb.id) FAILED: $("$_".Split("`n")[0])") } }
    }
    $fx = @($items | Where-Object fix)
    $when = @(@($mrs | ForEach-Object { $_.mergedAt; @($_.deployedAt) }) + @($sx.docs.Values | ForEach-Object { $_.updated }) | ForEach-Object { ConvertTo-KitWhen $_ } | Where-Object { $_ } | Sort-Object)
    [pscustomobject]@{ id = $sb.id; name = $sb.name; url = $sb.url; status = $sb.status; area = "$($ag.area)"; order = $(if ($ag) { [int]$ag.order } else { 999 })
      repo = $(if ($ag.repo) { $ag.repo } elseif ($mrs.Count) { $mrs[0].repo } else { 'other' }); batch = $(if ($ag) { [int]$ag.batch } else { 0 })
      mrs = $mrs; merged = $merged; envs = $envs; human = "$($sx.docs.'testing-doc'.url)"; ai = "$($sx.docs.'testing-ai'.url)"
      done = @($fx | Where-Object done).Count; total = $fx.Count; inTest = (Test-TrackerStatus $sb.status 'inTest'); closed = (Test-TrackerStatus $sb.status 'closed'); updated = @($when)[-1] }
  }
  $rows = @($rows)
  $urls = @{}; foreach ($sb in $subs) { $urls[$sb.id] = $sb.url }
  $want = [ordered]@{ delivery = (Format-KitDelivery $rows) }; if ($tri -and $tri.rows.Count) { $want.triage = Format-KitTriage $tri $urls }
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
    $x.rollup.subtasks = $subIds; $x.rollup.mrs = $mc; $x.rollup.sections = $sec; $x.rollup.milestones = @($ms); $x.rollup.readAt = (Get-Date).ToString('o') }
  $sig1 = Get-KitRollupLocalSig (Read-KitState (Get-KitTaskFile $Parent)).rollup $subIds $trk
  Update-KitTaskIndex $Parent { param($x) $x.rollup.localSig = $sig1 }
  if ($did.Count) { "ROLLUP ${Parent}: $($did -join ' · ')" }
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
  foreach ($g in @(Get-ChildItem -LiteralPath (Get-KitPath tasks) -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $x = Read-KitState $g.FullName; if ($x.task -and $x.rollup -is [Collections.IDictionary]) { $parents["$($x.task)"] = 1 } }
  foreach ($t in @((Read-KitTracking).tasks.Values | Where-Object { $_.task -and -not $_.done })) {
    $x = Read-KitState (Get-KitTaskFile $t.task)
    if ($x -and $x.Contains('parent')) { if ($x.parent) { $parents["$($x.parent)"] = 1 }; continue }
    if ($look++ -ge 10) { continue }
    $tk = try { Get-TrackerTask $t.task } catch { $null }; if (-not $tk.name) { continue }
    $p = "$($tk.parent)"; Update-KitTaskIndex $t.task { param($y) $y.parent = $p }; if ($p) { $parents[$p] = 1 }
  }
  foreach ($p in @($parents.Keys)) { $o = try { Update-KitParentRollup $p } catch { "ROLLUP $p failed: $("$_".Split("`n")[0])" }; if ($o -and -not $Quiet) { $o } }
}
