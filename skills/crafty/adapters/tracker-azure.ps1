#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# tracker-azure: Azure Boards tracker (tracker.type azure).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ when tracker.type is azure; helpers come from lib.ps1.
# Sections: L6 helpers · L18 rest · L28 html · L54 tracker
# ---- helpers: only this adapter uses them (kept out of the core lib.ps1)
function __TrHttp([string]$Method, [string]$Uri, $Body, [hashtable]$H, [string]$File, [string]$CType) {
  if ($__trDry) { Write-Host "DRYRUN: $Method $Uri$(if ($null -ne $Body) { '  body=' + (__TrShort ($Body | ConvertTo-Json -Depth 20 -Compress)) })$(if ($File) { "  file=$File" })"; return $null }
  if (-not ($File -or $CType)) {
    $o = @(Invoke-KitHttp $Method $Uri $Body $H 3>&1); $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] })
    if ($w) { throw "tracker ($__trType): $($w[0].Message)" }; return ($o | ForEach-Object { $_ })
  }
  $p = @{ Method = $Method; Uri = $Uri; Headers = $H; TimeoutSec = (Get-KitNetTimeout) }
  if (-not $CType) { $p.Form = @{ file = Get-Item -LiteralPath $File } } elseif ($File) { $p.InFile = $File; $p.ContentType = $CType }
  else { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20 -Compress)); $p.ContentType = $CType }
  Invoke-RestMethod @p
}
# ---- rest: Azure DevOps REST calls
# adapter:tracker/azure: Azure Boards work items (REST 7.1; tracker.org + tracker.project, AZURE_DEVOPS_EXT_PAT); list = area path; HTML text
function __TrAz([string]$Method, [string]$Path, $Body, [string]$CType, [string]$File) {
  if (-not $__trDry -and -not $env:AZURE_DEVOPS_EXT_PAT) { throw 'tracker (azure): set AZURE_DEVOPS_EXT_PAT' }
  $u = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '<tracker.org>')/$(if ($Path -notmatch '^/') { [uri]::EscapeDataString((Get-KitSetting 'tracker.project' '<tracker.project>')) + '/' })_apis/$($Path.TrimStart('/'))"
  __TrHttp $Method "$u$(if ($u -match '\?') { '&' } else { '?' })api-version=7.1$(if ($Path -match '/comments') { '-preview.4' })" $Body (Get-KitAuth AZURE_DEVOPS_EXT_PAT basic) $File $CType
}
function __TrAzSet($Id, $F) { __TrAz 'PATCH' "wit/workitems/$Id" @(foreach ($k in @($F.Keys)) { @{ op = 'add'; path = "/fields/$k"; value = $F[$k] } }) 'application/json-patch+json' }
# a checklist item (child Task tagged kit-checklist): no subtask, no listed task
function __TrAzCl($W) { @("$($W.fields.'System.Tags')" -split ';\s*') -contains 'kit-checklist' }
# ---- html: Markdown <-> HTML texts
# Markdown (lib.ps1 ConvertFrom-KitMarkdown) -> HTML: tables, lists, b / code / a, br (Markdown marks would show as typed)
function __TrHtmlRuns([string]$s) {
  -join @(foreach ($r in ConvertFrom-KitMdInline $s) { $e = [Net.WebUtility]::HtmlEncode($r.text); switch ($r.mark) { 'br' { '<br>' } 'bold' { "<b>$e</b>" } 'code' { "<code>$e</code>" } 'link' { "<a href=`"$([Net.WebUtility]::HtmlEncode($r.url))`">$e</a>" } default { $e } } })
}
function __TrHtml([string]$t) {
  $h = [Collections.Generic.List[string]]::new()
  foreach ($b in @(ConvertFrom-KitMarkdown $t)) {
    if ($b.type -eq 'table') { $h.Add('<table>' + (-join @(for ($ri = 0; $ri -lt $b.rows.Count; $ri++) { $c = if ($ri) { 'td' } else { 'th' }; '<tr>' + (-join @($b.rows[$ri] | ForEach-Object { "<$c>$(__TrHtmlRuns $_)</$c>" })) + '</tr>' })) + '</table>') }
    elseif ($b.type -eq 'item') { $li = "<li>$(__TrHtmlRuns $b.text)</li></ul>"; if ($h.Count -and $h[-1].EndsWith('</ul>')) { $h[-1] = $h[-1].Substring(0, $h[-1].Length - 5) + $li } else { $h.Add("<ul>$li") } }
    else { $h.Add("<div>$(__TrHtmlRuns $b.text)</div>") }
  }
  -join $h
}
# HTML -> Markdown (tables, lists, marks), so a description splice keeps the rest as it was
function __TrUnHtmlRuns([string]$s) {
  $s = $s -replace '(?is)<a\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>', '[$2]($1)' -replace '(?i)</?(b|strong)>', '**' -replace '(?i)</?code>', '`'
  [Net.WebUtility]::HtmlDecode(($s -replace '(?i)<br\s*/?>|</(p|div|li|h\d)>', "`n" -replace '(?i)<li[^>]*>', '- ' -replace '<[^>]+>'))
}
function __TrUnHtml([string]$t) {
  (-join @([regex]::Split("$t", '(?is)(<table\b.*?</table>)') | ForEach-Object {
        if ($_ -notmatch '(?is)^<table\b') { return (__TrUnHtmlRuns $_) }
        $rs = @([regex]::Matches($_, '(?is)<tr[^>]*>(.*?)</tr>') | ForEach-Object { '| ' + (@([regex]::Matches($_.Groups[1].Value, '(?is)<t([dh])[^>]*>(.*?)</t\1>') | ForEach-Object { (__TrUnHtmlRuns $_.Groups[2].Value).Trim() -replace '\|', '\|' -replace '\n+', '<br>' }) -join ' | ') + ' |' })
        if ($rs.Count) { "`n" + ((@($rs[0], "|$('---|' * ([regex]::Matches($rs[0], '(?<!\\)\|').Count - 1))") + @($rs | Select-Object -Skip 1)) -join "`n") + "`n" }
      }) -replace '\n\n+(?=\| )', "`n").Trim()
}
# ---- tracker: the azure verbs
Register-KitAdapter 'tracker' 'azure' @{
  'url' = { param($a) "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '<tracker.org>')/$(Get-KitSetting 'tracker.project' '<tracker.project>')/_workitems/edit/$($a.id)" }
  'view' = { param($a)
    $j = __TrAz 'GET' "wit/workitems/$($a.id)?`$expand=relations" $null; if (-not $j.id) { return }
    $f = $j.fields; $rel = { param($t) @($j.relations | Where-Object { $_.rel -eq "System.LinkTypes.Hierarchy-$t" } | ForEach-Object { $_.url -replace '^.*/' }) }; $kids = @(& $rel Forward)
    Add-KitTags ([pscustomobject]@{ id = "$($j.id)"; name = $f.'System.Title'; status = [string]$f.'System.State'; url = Get-TrackerUrl $j.id; parent = @(& $rel Reverse)[0]
      assignees = @($f.'System.AssignedTo'.displayName | Where-Object { $_ }); list = [string]$f.'System.AreaPath'; description = (__TrUnHtml $f.'System.Description')
      subtasks = @(if ($kids) { (__TrAz 'GET' "wit/workitems?ids=$($kids -join ',')&fields=System.Title,System.State,System.Tags" $null).value | Where-Object { -not (__TrAzCl $_) } | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; name = $_.fields.'System.Title'; status = [string]$_.fields.'System.State'; url = Get-TrackerUrl $_.id } } }) }) @("$($f.'System.Tags')" -split ';\s*')
  }
  'status' = { param($a) $null = __TrAzSet $a.id @{ 'System.State' = $a.status }; "status of $($a.id): $($a.status)" }
  # the states of tracker.issueType in the project (scope = area path; states are per type, not per area); category Proposed -> open, Completed -> closed, Removed / Resolved custom (no role, as linear canceled)
  'statuses' = { param($a)
    @((__TrAz 'GET' "wit/workitemtypes/$([uri]::EscapeDataString((Get-KitSetting 'tracker.issueType' 'Task')))/states" $null).value | Where-Object { $_.name } |
      ForEach-Object { [pscustomobject]@{ name = "$($_.name)"; type = @{ Proposed = 'open'; Completed = 'closed' }["$($_.category)"] ?? 'custom' } })
  }
  'comment' = { param($a) $null = __TrAz 'POST' "wit/workItems/$($a.id)/comments" @{ text = (__TrHtml $a.text) }; "commented on $($a.id)" }
  'comments' = { param($a) @((__TrAz 'GET' "wit/workItems/$($a.id)/comments" $null).comments) | Where-Object { $_ } | ForEach-Object { __TrComment $_.createdBy.displayName $_.createdDate (__TrUnHtml $_.text) $_.id } }
  'comment-edit' = { param($a) $null = __TrAz 'PATCH' "wit/workItems/$($a.id)/comments/$($a.comment)" @{ text = (__TrHtml $a.text) }; "edited comment $($a.comment)" }   # lib.ps1 Set-TrackerKitComment
  'comment-delete' = { param($a) $null = __TrAz 'DELETE' "wit/workItems/$($a.id)/comments/$($a.comment)" $null; "deleted comment $($a.comment)" }
  'create' = { param($a)
    $o = @(foreach ($kv in ([ordered]@{ 'System.Title' = $a.name; 'System.Description' = (__TrHtml $a.description); 'System.AreaPath' = $a.list; 'System.AssignedTo' = $a.assignee; 'Microsoft.VSTS.Common.Priority' = $(if ($a.priority -match '^[1-4]$') { [int]$a.priority }) }).GetEnumerator()) { if ($kv.Value) { @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value } } })
    if ($a.parent) { $o += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '')/_apis/wit/workItems/$($a.parent)" } } }
    $t = __TrAz 'POST' "wit/workitems/`$$([uri]::EscapeDataString((Get-KitSetting 'tracker.issueType' 'Task')))" $o 'application/json-patch+json'
    if ($t.id) { [pscustomobject]@{ id = "$($t.id)"; url = Get-TrackerUrl $t.id } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) $null = __TrAzSet $a.id @{ 'System.Description' = (__TrHtml $a.text) }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrAzSet $a.id @{ 'System.Title' = $a.name }; "renamed $($a.id)" }
  # tags: System.Tags ('a; b'), the whole set written back
  'labels' = { param($a) $h = @("$((__TrAz 'GET' "wit/workitems/$($a.id)?fields=System.Tags" $null).fields.'System.Tags')" -split ';\s*' | Where-Object { $_ -and $_ -notin @($a.remove) })
    $null = __TrAzSet $a.id @{ 'System.Tags' = (@($h + @($a.add | Where-Object { $_ -and $_ -notin $h })) -join '; ') } }
  # waits on = a Predecessor link (Dependency-Reverse); on = ids to add (missing only, one PATCH); returns what it waits on now
  'dependencies' = { param($a)
    $have = @(@((__TrAz 'GET' "wit/workitems/$($a.id)?`$expand=relations" $null).relations) | Where-Object { $_.rel -eq 'System.LinkTypes.Dependency-Reverse' } | ForEach-Object { "$($_.url -replace '^.*/')" })
    $new = @($a.on | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -notin $have } | Select-Object -Unique)
    if ($new) { $null = __TrAz 'PATCH' "wit/workitems/$($a.id)" @($new | ForEach-Object { @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Dependency-Reverse'; url = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '')/_apis/wit/workItems/$_" } } }) 'application/json-patch+json' }
    @($have) + $new }
  # move (K54): the old parent link out (top or a new parent), the new one in; -List = area path
  'move' = { param($a)
    $rels = @((__TrAz 'GET' "wit/workitems/$($a.id)?`$expand=relations" $null).relations)
    $o = @(for ($i = $rels.Count - 1; $i -ge 0; $i--) { if ("$($rels[$i].rel)" -eq 'System.LinkTypes.Hierarchy-Reverse' -and ($a.top -or $a.parent)) { @{ op = 'remove'; path = "/relations/$i" } } })
    if ($a.parent) { $o += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '')/_apis/wit/workItems/$($a.parent)" } } }
    if ($a.list) { $o += @{ op = 'add'; path = '/fields/System.AreaPath'; value = $a.list } }
    $null = __TrAz 'PATCH' "wit/workitems/$($a.id)" $o 'application/json-patch+json'
    "moved $($a.id)$(if ($a.list) { " to $($a.list)" })$(if ($a.top) { ': top-level' } elseif ($a.parent) { " under $($a.parent)" })" }
  'attach' = { param($a)
    $u = __TrAz 'POST' "wit/attachments?fileName=$([uri]::EscapeDataString($a.leaf))" $null 'application/octet-stream' $a.file
    $null = __TrAz 'PATCH' "wit/workitems/$($a.id)" @(@{ op = 'add'; path = '/relations/-'; value = @{ rel = 'AttachedFile'; url = $u.url } }) 'application/json-patch+json'; "attached $($a.leaf) to $($a.id)"; __TrNote $a
  }
  'list' = { param($a)
    $q = "SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = @project AND NOT [System.Tags] CONTAINS 'kit-checklist' AND [System.State] = '$($a.status -replace "'", "''")'$(if ($a.list) { " AND [System.AreaPath] UNDER '$($a.list -replace "'", "''")'" })"
    $ids = @((__TrAz 'POST' 'wit/wiql?$top=200' @{ query = $q }).workItems.id | Where-Object { $_ })
    if ($ids) { (__TrAz 'GET' "wit/workitems?ids=$($ids -join ',')&fields=System.Title,System.AssignedTo" $null).value | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; name = [string]$_.fields.'System.Title'; status = $a.status; assignees = @($_.fields.'System.AssignedTo' | Where-Object { $_ } | ForEach-Object { __TrWho $_.uniqueName $_.displayName }) } } }
  }
  'owner' = { param($a) if ($a.name) { $a.name } else { [string](__TrAz 'GET' '/connectionData' $null).authenticatedUser.providerDisplayName } }
  # the board checklist = child Task work items (learn.microsoft.com/azure/devops/boards/boards/add-task-checklists): one per item, tagged
  # kit-checklist + kit-checklist-<name>, keyed by the text before the first ' · '; tick = Task's Completed state, untick = its Proposed one;
  # prune: unwanted kit lines ('<key> · ...') and repeats deleted (keepDone: a done one stays); the old description section goes
  'checklist' = { param($a)
    $tg = "kit-checklist-$("$($a.name)".ToLower() -replace '[\s;,]+', '-')"; $key = { param($t) ("$t" -split ' · ', 2)[0].Trim() }
    $j = __TrAz 'GET' "wit/workitems/$($a.id)?`$expand=relations" $null; if (-not $j.id) { if ($__trDry) { return }; throw "tracker (azure): $($a.id) not found" }
    $kids = @($j.relations | Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' } | ForEach-Object { $_.url -replace '^.*/' })
    $mine = @(if ($kids) { (__TrAz 'GET' "wit/workitems?ids=$($kids -join ',')&fields=System.Title,System.State,System.Tags" $null).value | Where-Object { @("$($_.fields.'System.Tags')" -split ';\s*') -contains $tg } })
    $sts = @((__TrAz 'GET' 'wit/workitemtypes/Task/states' $null).value); $closed = "$(@($sts | Where-Object category -eq 'Completed')[0].name)"; $open = "$(@($sts | Where-Object category -eq 'Proposed')[0].name)"
    $want = @{}; foreach ($w in @($a.items)) { $want[(& $key $w.text)] = $w }
    $have = @{}; $n = 0; $rm = 0
    foreach ($i in $mine) { $k = & $key $i.fields.'System.Title'; $dn = "$($i.fields.'System.State')" -eq $closed
      $unw = $a.prune -and -not $want.ContainsKey($k) -and $k -notmatch '\s' -and "$($i.fields.'System.Title')".Contains(' · ') -and -not ($a.keepDone -and $dn)
      if ($unw -or ($a.prune -and $have.ContainsKey($k))) { $null = __TrAz 'DELETE' "wit/workitems/$($i.id)" $null; $n++; if ($unw) { $rm++ } } elseif (-not $have.ContainsKey($k)) { $have[$k] = $i } }
    foreach ($w in @($a.items)) { $i = $have[(& $key $w.text)]; $ws = if ($w.done) { $closed } else { $open }
      if (-not $i) {
        $o = @(@{ op = 'add'; path = '/fields/System.Title'; value = $w.text }, @{ op = 'add'; path = '/fields/System.Tags'; value = "kit-checklist; $tg" }, @{ op = 'add'; path = '/fields/System.AreaPath'; value = $j.fields.'System.AreaPath' },
          @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "https://dev.azure.com/$(Get-KitSetting 'tracker.org' '')/_apis/wit/workItems/$($a.id)" } })
        $t = __TrAz 'POST' 'wit/workitems/$Task' @($o | Where-Object { $null -ne $_.value }) 'application/json-patch+json'; $n++
        if ($w.done -and $t.id) { $null = __TrAzSet $t.id @{ 'System.State' = $closed } }   # a new item starts in the Proposed state
        continue }
      $f = [ordered]@{}; if ("$($i.fields.'System.Title')" -cne $w.text) { $f['System.Title'] = $w.text }
      if (("$($i.fields.'System.State')" -eq $closed) -ne [bool]$w.done -and $ws) { $f['System.State'] = $ws }
      if ($f.Count) { $null = __TrAzSet $i.id $f; $n++ } }
    $md = __TrUnHtml $j.fields.'System.Description'; $nm = [regex]::Escape("$($a.name)".ToLower()); $sx = "(?s)\n*<!-- kit:$nm -->.*?<!-- /kit:$nm -->"
    if ($md -match $sx) { $null = __TrAzSet $a.id @{ 'System.Description' = (__TrHtml ($md -replace $sx).Trim()) } }   # the fallback's copy, now stale
    "checklist $($a.name) on $($a.id): $n change(s), $rm removed"
  }
}
