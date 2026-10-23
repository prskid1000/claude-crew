#Requires -Version 7
# Extra tracker-linear: Linear tracker (tracker.type linear).
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add tracker-linear); helpers come from lib.ps1.
# helpers only this extra uses (kept out of the core lib.ps1)
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
# adapter:tracker/linear: GraphQL (LINEAR_API_KEY); ids = identifiers (ENG-12), list = team key, status = workflow state name
function __TrLin([string]$Q, [hashtable]$v = @{}) {
  if (-not $__trDry -and -not $env:LINEAR_API_KEY) { throw 'tracker (linear): set LINEAR_API_KEY' }
  $r = __TrHttp 'POST' 'https://api.linear.app/graphql' @{ query = $Q; variables = $v } @{ Authorization = "$env:LINEAR_API_KEY" }
  if ($r.errors) { throw "tracker (linear): $($r.errors[0].message)" }; $r.data
}
function __TrLinSet([string]$Id, [hashtable]$In) { $null = __TrLin 'mutation($id: String!, $in: IssueUpdateInput!) { issueUpdate(id: $id, input: $in) { success } }' @{ id = $Id; in = $In } }
function __TrLinUser([string]$N) { @((__TrLin 'query($n: String!) { users(filter: { or: [{ name: { eqIgnoreCase: $n } }, { displayName: { eqIgnoreCase: $n } }, { email: { eqIgnoreCase: $n } }] }) { nodes { id } } }' @{ n = $N }).users.nodes.id)[0] }
Register-KitAdapter 'tracker' 'linear' @{
  'url' = { param($a) "https://linear.app/$(Get-KitSetting 'tracker.org' '<tracker.org>')/issue/$($a.id)" }
  'view' = { param($a)
    $i = (__TrLin 'query($id: String!) { issue(id: $id) { identifier title url description state { name } assignee { name } parent { identifier } team { key } children { nodes { identifier title url state { name } } } } }' @{ id = $a.id }).issue
    if (-not $i) { return }
    [pscustomobject]@{ id = $i.identifier; name = $i.title; status = [string]$i.state.name; url = $i.url; parent = $i.parent.identifier; assignees = @($i.assignee.name | Where-Object { $_ }); list = $i.team.key
      subtasks = @($i.children.nodes | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = $_.title; status = [string]$_.state.name; url = $_.url } }); description = [string]$i.description }
  }
  'status' = { param($a)
    $s = @((__TrLin 'query($id: String!) { issue(id: $id) { team { states { nodes { id name } } } } }' @{ id = $a.id }).issue.team.states.nodes | Where-Object { $_.name -ieq $a.status })[0]
    if (-not $s -and -not $__trDry) { throw "tracker (linear): no workflow state '$($a.status)' in the team of $($a.id)" }
    __TrLinSet $a.id @{ stateId = $s.id }; "status of $($a.id): $($a.status)"
  }
  'comment' = { param($a) $null = __TrLin 'mutation($id: String!, $b: String!) { commentCreate(input: { issueId: $id, body: $b }) { success } }' @{ id = $a.id; b = $a.text }; "commented on $($a.id)" }
  'comments' = { param($a) @((__TrLin 'query($id: String!) { issue(id: $id) { comments(first: 200) { nodes { body createdAt user { name } } } } }' @{ id = $a.id }).issue.comments.nodes) | Where-Object { $_ } | ForEach-Object { __TrComment $_.user.name $_.createdAt $_.body } }
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
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $f = @{ state = @{ name = @{ eqIgnoreCase = $a.status } } }; if ($a.list) { $f.team = @{ key = @{ eq = $a.list } } }
    @((__TrLin 'query($f: IssueFilter) { issues(filter: $f, first: 200) { nodes { identifier title assignee { id name } } } }' @{ f = $f }).issues.nodes) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.identifier; name = [string]$_.title; status = $a.status; assignees = @($_.assignee | Where-Object { $_ } | ForEach-Object { __TrWho $_.id $_.name }) } }
  }
  'owner' = { param($a) $u = if ($a.name) { __TrLinUser $a.name }; if ($u) { $u } else { (__TrLin 'query { viewer { id } }').viewer.id } }
}
