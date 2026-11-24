#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# tracker-linear: Linear tracker (tracker.type linear).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ when tracker.type is linear; helpers come from lib.ps1.
# Sections: L6 helpers · L18 graphql · L33 tracker
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
# ---- graphql: calls, issue / label / user ids
# adapter:tracker/linear: GraphQL (LINEAR_API_KEY); ids = identifiers (ENG-12), list = team key, status = workflow state name
function __TrLin([string]$Q, [hashtable]$v = @{}) {
  if (-not $__trDry -and -not $env:LINEAR_API_KEY) { throw 'tracker (linear): set LINEAR_API_KEY' }
  $r = __TrHttp 'POST' 'https://api.linear.app/graphql' @{ query = $Q; variables = $v } @{ Authorization = "$env:LINEAR_API_KEY" }
  if ($r.errors) { throw "tracker (linear): $($r.errors[0].message)" }; $r.data
}
function __TrLinSet([string]$Id, [hashtable]$In) { $null = __TrLin 'mutation($id: String!, $in: IssueUpdateInput!) { issueUpdate(id: $id, input: $in) { success } }' @{ id = $Id; in = $In } }
function __TrLinId([string]$Id) { $u = (__TrLin 'query($id: String!) { issue(id: $id) { id } }' @{ id = $Id }).issue.id; if ($u) { $u } elseif ($__trDry) { "<uuid of $Id>" } else { throw "tracker (linear): no issue $Id" } }
function __TrLinLabel([string]$N, [string]$Team, [switch]$Make) {   # a workspace label or one of $Team (another team's label is refused on the issue)
  $l = @(@((__TrLin 'query($n: String!) { issueLabels(filter: { name: { eqIgnoreCase: $n } }) { nodes { id team { key } } } }' @{ n = $N }).issueLabels.nodes) | Where-Object { $_.id -and (-not $_.team -or "$($_.team.key)" -eq $Team) } | Sort-Object { [bool]$_.team } -Descending | ForEach-Object id)[0]
  if ($l -or -not $Make) { return $l }; $l = (__TrLin 'mutation($n: String!) { issueLabelCreate(input: { name: $n }) { issueLabel { id } } }' @{ n = $N }).issueLabelCreate.issueLabel.id
  if ($l) { $l } elseif ($__trDry) { "<label $N>" } else { throw "tracker (linear): label '$N' not created" }
}
function __TrLinUser([string]$N) { @((__TrLin 'query($n: String!) { users(filter: { or: [{ name: { eqIgnoreCase: $n } }, { displayName: { eqIgnoreCase: $n } }, { email: { eqIgnoreCase: $n } }] }) { nodes { id } } }' @{ n = $N }).users.nodes.id)[0] }
# ---- tracker: the linear verbs
Register-KitAdapter 'tracker' 'linear' @{
  'url' = { param($a) "https://linear.app/$(Get-KitSetting 'tracker.org' '<tracker.org>')/issue/$($a.id)" }
  'view' = { param($a)
    $i = (__TrLin 'query($id: String!) { issue(id: $id) { identifier title url description state { name } assignee { name } parent { identifier } team { key } labels { nodes { name } } children { nodes { identifier title url state { name } } } } }' @{ id = $a.id }).issue
    if (-not $i) { return }
    Add-KitTags ([pscustomobject]@{ id = $i.identifier; name = $i.title; status = [string]$i.state.name; url = $i.url; parent = $i.parent.identifier; assignees = @($i.assignee.name | Where-Object { $_ }); list = $i.team.key
      subtasks = @($i.children.nodes | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = $_.title; status = [string]$_.state.name; url = $_.url } }); description = [string]$i.description }) @($i.labels.nodes.name)
  }
  # waits on = a "blocks" relation from the blocker (read: inverseRelations); on = ids to add (missing only); returns what it waits on now
  'dependencies' = { param($a)
    $have = @(@((__TrLin 'query($id: String!) { issue(id: $id) { inverseRelations(first: 100) { nodes { type issue { identifier } } } } }' @{ id = $a.id }).issue.inverseRelations.nodes) | Where-Object { "$($_.type)" -eq 'blocks' -and $_.issue.identifier } | ForEach-Object { "$($_.issue.identifier)" })
    foreach ($on in @($a.on | Where-Object { $_ -and $_ -notin $have })) { $null = __TrLin 'mutation($in: IssueRelationCreateInput!) { issueRelationCreate(input: $in) { success } }' @{ in = @{ issueId = (__TrLinId $on); relatedIssueId = (__TrLinId $a.id); type = 'blocks' } }; $have += $on }
    $have }
  # labels by name, only the ones that change: add = a workspace or the issue's team label (workspace one made when missing); remove = the issue's own
  'labels' = { param($a) $i = (__TrLin 'query($id: String!) { issue(id: $id) { id team { key } labels { nodes { id name } } } }' @{ id = $a.id }).issue; $iid = if ($i.id) { $i.id } else { "<uuid of $($a.id)>" }
    $on = @($i.labels.nodes | Where-Object { $_ }); $hasL = { param($n) @($on | Where-Object { "$($_.name)" -ieq $n }) }
    foreach ($l in @($a.add | Where-Object { $_ -and -not (& $hasL $_).Count })) { $null = __TrLin 'mutation($id: String!, $l: String!) { issueAddLabel(id: $id, labelId: $l) { success } }' @{ id = $iid; l = (__TrLinLabel $l "$($i.team.key)" -Make) } }
    foreach ($l in @($a.remove | Where-Object { $_ })) { foreach ($x in @(& $hasL $l)) { $null = __TrLin 'mutation($id: String!, $l: String!) { issueRemoveLabel(id: $id, labelId: $l) { success } }' @{ id = $iid; l = $x.id } } } }
  'status' = { param($a)
    $s = @((__TrLin 'query($id: String!) { issue(id: $id) { team { states { nodes { id name } } } } }' @{ id = $a.id }).issue.team.states.nodes | Where-Object { $_.name -ieq $a.status })[0]
    if (-not $s -and -not $__trDry) { throw "tracker (linear): no workflow state '$($a.status)' in the team of $($a.id)" }
    __TrLinSet $a.id @{ stateId = $s.id }; "status of $($a.id): $($a.status)"
  }
  # a team's workflow states (scope = team key); type backlog / unstarted / started / completed / canceled
  'statuses' = { param($a)
    @(@((__TrLin 'query($k: String!) { teams(filter: { key: { eq: $k } }) { nodes { states { nodes { name type position } } } } }' @{ k = $a.scope }).teams.nodes)[0].states.nodes | Where-Object { $_.name } | Sort-Object { [double]$_.position } |
      ForEach-Object { [pscustomobject]@{ name = $_.name; type = @{ backlog = 'open'; unstarted = 'open'; completed = 'closed' }["$($_.type)"] ?? "$($_.type)" } })
  }
  'comment' = { param($a) $null = __TrLin 'mutation($id: String!, $b: String!) { commentCreate(input: { issueId: $id, body: $b }) { success } }' @{ id = $a.id; b = $a.text }; "commented on $($a.id)" }
  'comments' = { param($a) @((__TrLin 'query($id: String!) { issue(id: $id) { comments(first: 200) { nodes { id body createdAt user { name } } } } }' @{ id = $a.id }).issue.comments.nodes) | Where-Object { $_ } | ForEach-Object { __TrComment $_.user.name $_.createdAt $_.body $_.id } }
  'comment-edit' = { param($a) $null = __TrLin 'mutation($id: String!, $b: String!) { commentUpdate(id: $id, input: { body: $b }) { success } }' @{ id = $a.comment; b = $a.text }; "edited comment $($a.comment)" }   # lib.ps1 Set-TrackerKitComment
  'comment-delete' = { param($a) $null = __TrLin 'mutation($id: String!) { commentDelete(id: $id) { success } }' @{ id = $a.comment }; "deleted comment $($a.comment)" }
  'create' = { param($a)
    $in = @{ teamId = @((__TrLin 'query($k: String!) { teams(filter: { key: { eq: $k } }) { nodes { id } } }' @{ k = $a.list }).teams.nodes.id)[0]; title = $a.name; description = $a.description }
    if ($a.parent) { $in.parentId = (__TrLin 'query($id: String!) { issue(id: $id) { id } }' @{ id = $a.parent }).issue.id }
    if ($a.assignee) { $in.assigneeId = if ($a.assignee -match '^[0-9a-f-]{36}$') { $a.assignee } else { __TrLinUser $a.assignee } }
    if ($a.priority -match '^[1-4]$') { $in.priority = [int]$a.priority }   # Linear 1 urgent .. 4 low, as the kit
    $i = (__TrLin 'mutation($in: IssueCreateInput!) { issueCreate(input: $in) { issue { identifier url } } }' @{ in = $in }).issueCreate.issue
    if ($i) { [pscustomobject]@{ id = $i.identifier; url = $i.url } } elseif ($__trDry) { [pscustomobject]@{ id = '<new>'; url = '' } }
  }
  'describe' = { param($a) __TrLinSet $a.id @{ description = $a.text }; "described $($a.id)" }
  'rename' = { param($a) __TrLinSet $a.id @{ title = $a.name }; "renamed $($a.id)" }
  # move (K54): parentId (top: null), teamId from the team key (-List)
  'move' = { param($a) $in = @{}
    if ($a.list) { $tid = @((__TrLin 'query($k: String!) { teams(filter: { key: { eq: $k } }) { nodes { id } } }' @{ k = $a.list }).teams.nodes.id)[0]; if (-not $tid -and -not $__trDry) { throw "tracker (linear) move: no team '$($a.list)'" }; $in.teamId = $tid }
    if ($a.top) { $in.parentId = $null } elseif ($a.parent) { $in.parentId = (__TrLin 'query($id: String!) { issue(id: $id) { id } }' @{ id = $a.parent }).issue.id }
    __TrLinSet $a.id $in; "moved $($a.id)$(if ($a.list) { " to team $($a.list)" })$(if ($a.top) { ': top-level' } elseif ($a.parent) { " under $($a.parent)" })" }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $f = @{ state = @{ name = @{ eqIgnoreCase = $a.status } } }; if ($a.list) { $f.team = @{ key = @{ eq = $a.list } } }
    @((__TrLin 'query($f: IssueFilter) { issues(filter: $f, first: 200) { nodes { identifier title assignee { id name } } } }' @{ f = $f }).issues.nodes) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = [string]$_.title; status = $a.status; assignees = @($_.assignee | Where-Object { $_ } | ForEach-Object { __TrWho $_.id $_.name }) } }
  }
  'owner' = { param($a) $u = if ($a.name) { __TrLinUser $a.name }; if ($u) { $u } else { (__TrLin 'query { viewer { id } }').viewer.id } }
}
