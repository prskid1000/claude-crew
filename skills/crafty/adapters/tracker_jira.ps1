#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# tracker-jira: Jira Cloud and Jira Server / Data Center trackers (tracker.type jira | jira-server).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ when tracker.type is jira | jira-server; helpers come from lib.ps1.
# Sections: L6 helpers · L20 texts · L73 tracker
# ---- helpers: only this adapter uses them (kept out of the core lib.ps1)
function __TrBase([string]$Env) { $v = [Environment]::GetEnvironmentVariable($Env); if ($v) { $v.TrimEnd('/') } else { "<$Env>" } }
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
function __TrPrioName([string]$p, [string]$Names) { if ($p -match '^[1-4]$') { ($Names -split ' ')[[int]$p - 1] } else { $p } }
# ---- texts: Markdown <-> ADF (cloud) and wiki (server)
# Markdown (lib.ps1 ConvertFrom-KitMarkdown) -> ADF: tables, bullet lists, strong / code / link marks, line breaks
function __TrAdfPara([string]$s) {
  $runs = @(foreach ($r in ConvertFrom-KitMdInline $s) {
      switch ($r.mark) {
        'br' { @{ type = 'hardBreak' } }
        'bold' { @{ type = 'text'; text = $r.text; marks = @(@{ type = 'strong' }) } }
        'code' { @{ type = 'text'; text = $r.text; marks = @(@{ type = 'code' }) } }
        'link' { @{ type = 'text'; text = $r.text; marks = @(@{ type = 'link'; attrs = @{ href = $r.url } }) } }
        default { if ($r.text) { @{ type = 'text'; text = $r.text } } } } })
  @{ type = 'paragraph'; content = $runs }
}
function __TrAdf([string]$Text) {
  $out = [Collections.Generic.List[object]]::new()
  foreach ($b in @(ConvertFrom-KitMarkdown $Text)) {
    if ($b.type -eq 'table') { $out.Add(@{ type = 'table'; content = @(for ($ri = 0; $ri -lt $b.rows.Count; $ri++) { @{ type = 'tableRow'; content = @($b.rows[$ri] | ForEach-Object { @{ type = $(if ($ri) { 'tableCell' } else { 'tableHeader' }); content = @(__TrAdfPara $_) } }) } }) }) }
    elseif ($b.type -eq 'item') { $li = @{ type = 'listItem'; content = @(__TrAdfPara $b.text) }; if ($out.Count -and $out[-1].type -eq 'bulletList') { $out[-1].content += $li } else { $out.Add(@{ type = 'bulletList'; content = @($li) }) } }
    else { $out.Add((__TrAdfPara $b.text)) }
  }
  if (-not $out.Count) { $out.Add(@{ type = 'paragraph'; content = @() }) }
  @{ type = 'doc'; version = 1; content = $out.ToArray() }
}
# ADF -> the Markdown it came from (tables, lists, marks), so a description splice keeps the rest as it was
function __TrAdfText($n) {
  if ($null -eq $n) { return '' }
  if ($n -is [string]) { return $n }
  if ($n.type -eq 'text') {
    $t = [string]$n.text
    foreach ($mk in @($n.marks)) { if ($mk.type -eq 'strong') { $t = "**$t**" } elseif ($mk.type -eq 'code') { $t = '`' + $t + '`' } elseif ($mk.type -eq 'link') { $t = "[$t]($($mk.attrs.href))" } }
    return $t
  }
  if ($n.type -eq 'hardBreak') { return "`n" }
  if ($n.type -eq 'table') {
    $tr = @(@($n.content) | ForEach-Object { '| ' + (@(@($_.content) | ForEach-Object { ((@($_.content) | ForEach-Object { __TrAdfText $_ }) -join "`n").Trim() -replace '\|', '\|' -replace '\n+', '<br>' }) -join ' | ') + ' |' })
    if (-not $tr.Count) { return '' }
    return ((@($tr[0], "|$('---|' * @($n.content[0].content).Count)") + @($tr | Select-Object -Skip 1)) -join "`n") + "`n"
  }
  $inner = (@($n.content) | ForEach-Object { __TrAdfText $_ }) -join ''
  if ($n.type -eq 'listItem') { "- $($inner.Trim())`n" } elseif ($n.type -in 'paragraph', 'heading', 'codeBlock') { "$inner`n" } else { $inner }
}
# Markdown -> Jira wiki (server): ||head|| / |cell| tables, * items, *bold*, {{code}}, [text|url], \\ breaks; a stray | in a cell -> /
function __TrWikiRuns([string]$s) {
  -join @(foreach ($r in ConvertFrom-KitMdInline $s) { switch ($r.mark) { 'br' { ' \\ ' } 'bold' { "*$($r.text)*" } 'code' { "{{$($r.text)}}" } 'link' { "[$($r.text -replace '[\[\]|]', ' ')|$($r.url)]" } default { $r.text } } })
}
function __TrWiki([string]$Text) {
  @(foreach ($b in @(ConvertFrom-KitMarkdown $Text)) {
      if ($b.type -eq 'table') {
        for ($ri = 0; $ri -lt $b.rows.Count; $ri++) { $sep = if ($ri) { '|' } else { '||' }; $sep + (@($b.rows[$ri] | ForEach-Object { $c = (__TrWikiRuns $_) -replace '\|(?![^\[]*\])', '/'; if ($c.Trim()) { $c } else { ' ' } }) -join $sep) + $sep }
      }
      elseif ($b.type -eq 'item') { "* $(__TrWikiRuns $b.text)" } else { __TrWikiRuns $b.text }
    }) -join "`n"
}
function __TrJDoc([string]$t) { if ($__trType -eq 'jira') { __TrAdf $t } else { __TrWiki $t } }   # Markdown marks would show as typed
# ---- tracker: REST calls and the jira / jira-server verbs
function __TrJira([string]$Method, [string]$Path, $Body, [string]$FilePath) {
  $h = if ($__trType -ne 'jira' -and $env:JIRA_TOKEN) { Get-KitAuth JIRA_TOKEN } elseif ($env:JIRA_EMAIL -and $env:JIRA_API_TOKEN) { @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)")) } } else { @{} }
  if (-not $__trDry -and -not ($env:JIRA_BASE_URL -and $h.Authorization)) { throw "tracker ($__trType): set JIRA_BASE_URL and JIRA_EMAIL + JIRA_API_TOKEN$(if ($__trType -ne 'jira') { ' (or JIRA_TOKEN)' })" }
  $h.Accept = 'application/json'; if ($FilePath) { $h['X-Atlassian-Token'] = 'no-check' }
  __TrHttp $Method "$(__TrBase JIRA_BASE_URL)/rest/api/$(if ($__trType -eq 'jira') { 3 } else { 2 })/$Path" $Body $h $FilePath
}
# adapter:tracker/jira: Jira Cloud (JIRA_BASE_URL + JIRA_EMAIL + JIRA_API_TOKEN), also jira-server
Register-KitAdapter 'tracker' 'jira' @{
  'url' = { param($a) "$(__TrBase JIRA_BASE_URL)/browse/$($a.id)" }
  'view' = { param($a)
    $j = __TrJira 'GET' "issue/$($a.id)?fields=summary,status,parent,assignee,subtasks,project,description" $null; if (-not $j.key) { return }
    $f = $j.fields
    __TrTask $j.key $f.summary ([string]$f.status.name) (Get-TrackerUrl $j.key) $f.parent.key @($f.assignee | Where-Object { $_ } | ForEach-Object { $_.displayName }) ([string]$f.project.key) @($f.subtasks | ForEach-Object { __TrSub $_.key $_.fields.summary ([string]$_.fields.status.name) (Get-TrackerUrl $_.key) }) (__TrAdfText $f.description).Trim()
  }
  'status' = { param($a)
    $id = $a.id; $name = $a.status; $t = __TrJira 'GET' "issue/$id/transitions" $null
    $tr = @($t.transitions | Where-Object { $_.name -ieq $name -or $_.to.name -ieq $name }) | Select-Object -First 1
    if (-not $tr -and -not $__trDry) { throw "tracker ($__trType): no transition to '$name' from the current status of $id (have: $(@($t.transitions | ForEach-Object { $_.to.name }) -join ', '))" }
    $null = __TrJira 'POST' "issue/$id/transitions" @{ transition = @{ id = $(if ($tr) { $tr.id } else { "<id of '$name'>" }) } }; "status of $id`: $name"
  }
  'comment' = { param($a) $res = __TrJira 'POST' "issue/$($a.id)/comment" @{ body = (__TrJDoc $a.text) }; if ($res) { "commented on $($a.id)" } }
  'comments' = { param($a) @((__TrJira 'GET' "issue/$($a.id)/comment?maxResults=200" $null).comments) | Where-Object { $_ } | ForEach-Object { __TrComment $_.author.displayName $_.created ((__TrAdfText $_.body).Trim()) $_.id } }
  'comment-edit' = { param($a) $null = __TrJira 'PUT' "issue/$($a.id)/comment/$($a.comment)" @{ body = (__TrJDoc $a.text) }; "edited comment $($a.comment)" }   # lib.ps1 Set-TrackerKitComment
  'comment-delete' = { param($a) $null = __TrJira 'DELETE' "issue/$($a.id)/comment/$($a.comment)" $null; "deleted comment $($a.comment)" }
  'create' = { param($a)
    $f = @{ project = @{ key = $a.list }; summary = $a.name; description = (__TrJDoc $a.description)
      issuetype = @{ name = $(if ($a.parent) { Get-KitSetting 'tracker.subtaskType' 'Subtask' } else { Get-KitSetting 'tracker.issueType' 'Task' }) } }
    if ($a.parent) { $f.parent = @{ key = $a.parent } }
    if ($a.assignee) { $f.assignee = if ($__trType -eq 'jira') { @{ accountId = $a.assignee } } else { @{ name = $a.assignee } } }
    if ($a.priority) { $f.priority = @{ name = (__TrPrioName $a.priority ([string](Get-KitSetting 'tracker.priorities' 'Highest High Medium Low'))) } }
    $t = __TrJira 'POST' 'issue' @{ fields = $f }
    if ($t.key) { [pscustomobject]@{ id = $t.key; url = Get-TrackerUrl $t.key } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) $null = __TrJira 'PUT' "issue/$($a.id)" @{ fields = @{ description = (__TrJDoc $a.text) } }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrJira 'PUT' "issue/$($a.id)" @{ fields = @{ summary = $a.name } }; "renamed $($a.id)" }
  'attach' = { param($a) $null = __TrJira 'POST' "issue/$($a.id)/attachments" $null $a.file; "attached $($a.leaf) to $($a.id)"; __TrNote $a }
  'list' = { param($a)
    $q = [uri]::EscapeDataString("project = `"$($a.list)`" AND status = `"$($a.status)`"")
    $j = __TrJira 'GET' "$(if ($__trType -eq 'jira') { 'search/jql' } else { 'search' })?jql=$q&fields=summary,assignee&maxResults=200" $null
    @($j.issues) | Where-Object { $_ -and $_.key } | ForEach-Object { __TrRow $_.key ([string]$_.fields.summary) $a.status @($_.fields.assignee | Where-Object { $_ } | ForEach-Object { __TrWho $(if ($_.accountId) { $_.accountId } else { $_.name }) $_.displayName }) }
  }
  'owner' = { param($a)
    if (-not $a.name) { return }
    $cl = $__trType -eq 'jira'; $k = if ($cl) { 'accountId' } else { 'name' }
    $m = @(__TrJira 'GET' "user/search?$(if ($cl) { 'query' } else { 'username' })=$([uri]::EscapeDataString($a.name))" $null) | Where-Object { $_.displayName -eq $a.name } | Select-Object -First 1
    [string]$(if ($m) { $m.$k } else { (__TrJira 'GET' 'myself' $null).$k })
  }
}
# adapter:tracker/jira-server: Server / Data Center = jira verbs on REST v2 (JIRA_TOKEN bearer or email + token)
Register-KitAdapter 'tracker' 'jira-server' @{ '*' = { param($a, $v) & $KitAdapters.tracker.jira[$v] $a $v } }
