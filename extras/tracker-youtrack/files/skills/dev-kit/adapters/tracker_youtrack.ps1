# Extra tracker-youtrack: YouTrack tracker (tracker.type youtrack).
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add tracker-youtrack); helpers come from lib.ps1.
# helpers only this extra uses (kept out of the core lib.ps1)
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
# adapter:tracker/youtrack: REST /api (YOUTRACK_URL + YOUTRACK_TOKEN); fields State / Assignee; changes by commands; list = project short name
function __TrYt([string]$Method, [string]$Path, $Body, [string]$File) {
  if (-not $__trDry -and -not ($env:YOUTRACK_URL -and $env:YOUTRACK_TOKEN)) { throw 'tracker (youtrack): set YOUTRACK_URL and YOUTRACK_TOKEN' }
  __TrHttp $Method "$(__TrBase YOUTRACK_URL)/api/$Path" $Body ((Get-KitAuth YOUTRACK_TOKEN) + @{ Accept = 'application/json' }) $File
}
function __TrYtCmd([string]$Id, [string]$Q) { $null = __TrYt 'POST' 'commands' @{ query = $Q; issues = @(@{ idReadable = $Id }) } }
function __TrYtF($i, [string]$N) { @($i.customFields | Where-Object { $_.name -eq $N })[0].value }
$__trYtFields = 'idReadable,summary,description,project(shortName),parent(issues(idReadable)),subtasks(issues(idReadable,summary,customFields(name,value(name)))),customFields(name,value(name,login))'
Register-KitAdapter 'tracker' 'youtrack' @{
  'url' = { param($a) "$(__TrBase YOUTRACK_URL)/issue/$($a.id)" }
  'view' = { param($a)
    $i = __TrYt 'GET' "issues/$($a.id)?fields=$__trYtFields" $null; if (-not $i.idReadable) { return }
    [pscustomobject]@{ id = $i.idReadable; name = $i.summary; status = [string](__TrYtF $i State).name; url = Get-TrackerUrl $i.idReadable; parent = @($i.parent.issues.idReadable)[0]
      assignees = @(__TrYtF $i Assignee | Where-Object { $_ } | ForEach-Object { $_.login }); list = [string]$i.project.shortName; description = [string]$i.description
      subtasks = @($i.subtasks.issues | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.idReadable; name = $_.summary; status = [string](__TrYtF $_ State).name; url = Get-TrackerUrl $_.idReadable } }) }
  }
  'status' = { param($a) __TrYtCmd $a.id "State {$($a.status)}"; "status of $($a.id): $($a.status)" }
  'comment' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)/comments?fields=id" @{ text = $a.text }; "commented on $($a.id)" }
  'comments' = { param($a) @(__TrYt 'GET' "issues/$($a.id)/comments?fields=text,created,author(login)&`$top=200" $null) | Where-Object { $_ } | ForEach-Object { __TrComment $_.author.login $_.created $_.text } }
  'create' = { param($a)
    $p = @(__TrYt 'GET' 'admin/projects?fields=id,shortName&$top=500' $null | Where-Object { $_.shortName -eq $a.list })[0]
    if (-not $p -and -not $__trDry) { throw "tracker (youtrack): no project '$($a.list)' (tracker.list = a project short name)" }
    $t = __TrYt 'POST' 'issues?fields=idReadable' @{ project = @{ id = $p.id }; summary = $a.name; description = $a.description }
    $id = if ($t.idReadable) { $t.idReadable } elseif ($__trDry) { '<new>' } else { return }
    $c = @(if ($a.parent) { "subtask of $($a.parent)" }; if ($a.assignee) { "for $($a.assignee)" }; if ($a.priority) { "Priority $(__TrPrioName $a.priority ([string](Get-KitSetting 'tracker.priorities' 'Critical Major Normal Minor')))" })
    if ($c) { __TrYtCmd $id ($c -join ' ') }
    [pscustomobject]@{ id = $id; url = Get-TrackerUrl $id }
  }
  'describe' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)?fields=idReadable" @{ description = $a.text }; "described $($a.id)" }
  'rename' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)?fields=idReadable" @{ summary = $a.name }; "renamed $($a.id)" }
  'attach' = { param($a) $null = __TrYt 'POST' "issues/$($a.id)/attachments?fields=id" $null $a.file; "attached $($a.leaf) to $($a.id)"; __TrNote $a }
  'list' = { param($a)
    $q = [uri]::EscapeDataString("$(if ($a.list) { "project: {$($a.list)} " })State: {$($a.status)}")
    @(__TrYt 'GET' "issues?query=$q&fields=idReadable,summary,customFields(name,value(login,name))&`$top=200" $null) | Where-Object { $_.idReadable } | ForEach-Object { [pscustomobject]@{ id = $_.idReadable; name = [string]$_.summary; status = $a.status; assignees = @(__TrYtF $_ Assignee | Where-Object { $_ } | ForEach-Object { __TrWho $_.login $_.name }) } }
  }
  'owner' = { param($a) $m = if ($a.name) { @(__TrYt 'GET' "users?query=$([uri]::EscapeDataString($a.name))&fields=login,fullName" $null | Where-Object { $_.fullName -eq $a.name })[0] }; [string]$(if ($m) { $m.login } else { (__TrYt 'GET' 'users/me?fields=login' $null).login }) }
}
