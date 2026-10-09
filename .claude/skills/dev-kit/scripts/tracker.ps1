<#
Tracker adapter: one small verb set for every issue tracker the kit talks to. Scripts and agents use this instead of a
tracker CLI, so the kit works with ClickUp, GitHub issues, GitLab issues, Jira - or no tracker at all.

As a script (structured results print as JSON):
  $TR = '<workspace>\.claude\skills\dev-kit\scripts\tracker.ps1'
  & $TR view <id>                        # { id, name, status, url, parent, assignees[], subtasks[{id,name,status,url}], list, description }
  & $TR status <id> <status>             # logical name (review, promoted, inTest, closed, ...) or the tracker's own status name
  & $TR comment <id> <text | file.md>
  & $TR comments <id>                    # [{ user, date, text }] oldest first
  & $TR create -List <list> -Name "<name>" -Description <text | file.md> [-Parent <id>] [-Assignee <user>] [-Priority 1-4]   # { id, url }
  & $TR url <id>
  & $TR describe <id> <text | file.md>   # replace the description
  & $TR attach <id> <file> [-Text "<comment>"]   # report/guide: GitHub/GitLab post the file's text as a comment; ClickUp/Jira attach it
  Options: -Type <backend> (else $env:KIT_TRACKER_TYPE, else kit.local.json tracker.type, else clickup) · -DryRun (or
  $env:KIT_TRACKER_DRYRUN=1): print the CLI / REST call instead of running it.

Dot-sourced (PowerShell callers):  . $TR [-Type x] [-DryRun]   then
  Get-TrackerTask, Set-TrackerStatus, Add-TrackerComment, Get-TrackerComments, New-TrackerTask, Get-TrackerUrl,
  Set-TrackerDescription, Add-TrackerAttachment, Resolve-TrackerStatus, Test-TrackerStatus <status> <logical...>

Backends (kit.local.json "tracker": { "type", "statuses", "repo", "list", "issueType", "subtaskType" }; docs/configuration.md):
  clickup  the clickup CLI (default when tracker.type is unset)
  github   gh issues in tracker.repo (owner/name): status = label "status:<x>", closed statuses close the issue;
           parent = "Part of #n" in the body + a task-list line "- [ ] #child" in the parent
  gitlab   glab api issues in tracker.repo (group/project), same label/state model; host from gitHost
  jira     REST v3 with $env:JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN; status = the transition whose name (or target
           status) matches; -List = project key; descriptions/comments are sent as plain-paragraph ADF
  none     no tracker: every call is logged and kept in <runtime>\tracker-none\ (create returns LOCAL-<n>), nothing fails
Logical statuses (tracker.statuses overrides any; a value may be a list - the first name is set, all names match):
  open, inProgress, review, promoted, inTest, closed
Works in PowerShell 7 (jira attachments need it); the rest also runs in Windows PowerShell 5.1.
#>
. (Join-Path $PSScriptRoot 'kitconfig.ps1')

# ---------- options (also when dot-sourced) ----------
$__trA = @($args); $__trPos = New-Object System.Collections.ArrayList; $__trOpt = @{}
for ($__i = 0; $__i -lt $__trA.Count; $__i++) {
  $__a = [string]$__trA[$__i]
  if ($__a -match '^-(DryRun|Json)$') { $__trOpt[$Matches[1]] = $true }
  elseif ($__a -match '^-(Type|List|Name|Description|Parent|Assignee|Priority|Text)$' -and $__i + 1 -lt $__trA.Count) { $__trOpt[$Matches[1]] = [string]$__trA[++$__i] }
  else { [void]$__trPos.Add($__a) }
}
$__trType = ([string]$(if ($__trOpt.Type) { $__trOpt.Type } elseif ($env:KIT_TRACKER_TYPE) { $env:KIT_TRACKER_TYPE } else { $KitConf.TrackerType })).ToLower()
$__trDry = [bool]($__trOpt.DryRun -or $env:KIT_TRACKER_DRYRUN -eq '1')
$__trRepo = [string](Get-KitSetting 'tracker.repo' '')
$__trRt = $KitConf.Runtime
if ($__trType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }

$__trStatus = [ordered]@{
  open = @('open', 'to do'); inProgress = @('in progress'); review = @('for review', 'in review'); promoted = @('promoted')
  inTest = @('in test', 'for test'); closed = @('closed', 'complete', 'done')
}
$__trCfgSt = Get-KitSetting 'tracker.statuses' $null
if ($__trCfgSt) { foreach ($__p in $__trCfgSt.PSObject.Properties) { $__trStatus[$__p.Name] = @($__p.Value | ForEach-Object { [string]$_ }) } }
if ($__trType -notin 'clickup', 'github', 'gitlab', 'jira', 'none') { Write-Warning "tracker: unknown tracker.type '$__trType' - using none"; $__trType = 'none' }

# ---------- helpers ----------
function Resolve-TrackerStatus([string]$Status) {
  # a logical name (review, inTest, ...) -> the tracker's status name; anything else passes through
  foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $Status) { return @($__trStatus[$k])[0] } }
  $Status
}
function Test-TrackerStatus([string]$Status, [string[]]$Logical) {
  # true when $Status (as read from the tracker) is one of the names of the given logical statuses
  foreach ($l in $Logical) { foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $l -and (@($__trStatus[$k]) | Where-Object { $_ -ieq "$Status".Trim() })) { return $true } } }
  $false
}
function __TrText([string]$s) {
  $isFile = $false; if ($s -and $s.Length -lt 260 -and $s -notmatch '[\r\n<>|"*?]') { try { $isFile = Test-Path -LiteralPath $s -PathType Leaf } catch {} }
  if ($isFile) { Get-Content -LiteralPath $s -Raw -Encoding utf8 } else { $s }
}
function __TrQuote([string[]]$a) { ($a | ForEach-Object { if ("$_" -match '[\s"]' -or "$_" -eq '') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' ' }
function __TrShort([string]$s) { $s = $s -replace "`r?`n", '\n'; if ($s.Length -gt 160) { $s.Substring(0, 157) + '...' } else { $s } }
function __TrCli([string]$Exe, [string[]]$A) {
  if ($__trDry) { Write-Host "DRYRUN: $Exe $(__TrShort (__TrQuote $A))"; return $null }
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { throw "tracker ($__trType): the '$Exe' CLI is not on PATH" }
  $out = & $Exe @A 2>&1
  (@($out) | ForEach-Object { "$_" }) -join "`n"
}
function __TrJson([string]$Out) {
  if (-not $Out) { return $null }
  $i = @($Out.IndexOf('{'), $Out.IndexOf('[')) | Where-Object { $_ -ge 0 } | Sort-Object | Select-Object -First 1
  if ($null -eq $i) { return $null }
  try { $Out.Substring($i) | ConvertFrom-Json } catch { $null }
}
function __TrTemp([string]$Text) { $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, $Text, (New-Object Text.UTF8Encoding $false)); $f }
function __TrStub([string]$Id) { [pscustomobject]@{ id = $Id; name = ''; status = ''; url = (Get-TrackerUrl $Id); parent = $null; assignees = @(); subtasks = @(); list = ''; description = '' } }
function __TrDate($d) { if ($d -match '^\d{10,}$') { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d).UtcDateTime.ToString('s') } elseif ($d) { ([datetime]$d).ToUniversalTime().ToString('s') } else { '' } }
function __TrPrio([string]$p) { switch ($p) { '1' { 'urgent' } '2' { 'high' } '3' { 'normal' } '4' { 'low' } default { $p } } }

# repo + number for github/gitlab ids: "12", "#12", "owner/name#12"
function __TrRef([string]$Id) {
  if ($Id -match '^(?<r>[^#\s]+)#(?<n>\S+)$') { return @($Matches.r, $Matches.n) }
  if (-not $__trRepo -and -not $__trDry) { throw "tracker ($__trType): set ""tracker"": { ""repo"": ""owner/name"" } in kit.local.json" }
  @($(if ($__trRepo) { $__trRepo } else { '<tracker.repo>' }), ($Id -replace '^#', ''))
}
function __TrLabelStatus($labels, [bool]$closed) {
  if ($closed) { return @($__trStatus.closed)[0] }
  $l = @($labels | Where-Object { $_ -like 'status:*' } | Select-Object -First 1)
  if ($l) { return ([string]$l[0]).Substring(7) }
  @($__trStatus.open)[0]
}
function __TrIsClosed([string]$name) { Test-TrackerStatus $name 'closed' }

# --- gitlab REST through glab api ---
function __TrGl([string]$Method, [string]$Path, $Body) {
  $a = @('api', '-X', $Method, $Path)
  if ($null -ne $Body) {
    if ($__trDry) { Write-Host "DRYRUN: glab api -X $Method $Path  body=$(__TrShort ($Body | ConvertTo-Json -Depth 10 -Compress))"; return $null }
    $f = __TrTemp ($Body | ConvertTo-Json -Depth 10 -Compress)
    try { return __TrJson (__TrCli 'glab' ($a + @('-H', 'Content-Type: application/json', '--input', $f))) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
  __TrJson (__TrCli 'glab' $a)
}
function __TrGlPath([string]$Id, [string]$Sub = '') { $r, $n = __TrRef $Id; "projects/$([uri]::EscapeDataString($r))/issues/$n$Sub" }

# --- jira REST v3 ---
function __TrAdf([string]$Text) {
  $paras = @(("$Text" -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' } | ForEach-Object { @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $_ }) } })
  if (-not $paras.Count) { $paras = @(@{ type = 'paragraph'; content = @() }) }
  @{ type = 'doc'; version = 1; content = $paras }
}
function __TrAdfText($n) {
  if ($null -eq $n) { return '' }
  if ($n -is [string]) { return $n }
  if ($n.type -eq 'text') { return [string]$n.text }
  $inner = (@($n.content) | ForEach-Object { __TrAdfText $_ }) -join ''
  if ($n.type -in 'paragraph', 'heading', 'listItem', 'codeBlock') { "$inner`n" } else { $inner }
}
function __TrJira([string]$Method, [string]$Path, $Body, [string]$FilePath) {
  $base = if ($env:JIRA_BASE_URL) { $env:JIRA_BASE_URL.TrimEnd('/') } else { '<JIRA_BASE_URL>' }
  $uri = "$base/rest/api/3/$Path"
  if ($__trDry) { Write-Host "DRYRUN: $Method $uri$(if ($null -ne $Body) { '  body=' + (__TrShort ($Body | ConvertTo-Json -Depth 20 -Compress)) })$(if ($FilePath) { "  file=$FilePath" })"; return $null }
  if (-not $env:JIRA_BASE_URL -or -not $env:JIRA_EMAIL -or -not $env:JIRA_API_TOKEN) { throw 'tracker (jira): set JIRA_BASE_URL, JIRA_EMAIL and JIRA_API_TOKEN' }
  $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)"))
  $p = @{ Method = $Method; Uri = $uri; Headers = @{ Authorization = "Basic $auth"; Accept = 'application/json' } }
  if ($FilePath) { $p.Headers['X-Atlassian-Token'] = 'no-check'; $p.Form = @{ file = Get-Item -LiteralPath $FilePath } }
  elseif ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json' }
  Invoke-RestMethod @p
}

# --- none: local log + store ---
function __TrNone([string]$Id, [string]$What, [scriptblock]$Change) {
  $d = Join-Path $__trRt 'tracker-none'; New-Item -ItemType Directory -Force $d | Out-Null
  Add-Content (Join-Path $d 'tracker.log') ("{0} {1} {2}" -f (Get-Date -Format s), $Id, (__TrShort $What)) -Encoding utf8
  if (-not $Id) { return $null }
  $f = Join-Path $d "$($Id -replace '[^\w.-]', '_').json"
  $o = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
  if ($Change) { if (-not $o) { $o = [pscustomobject]@{ id = $Id; name = ''; status = ''; parent = $null; list = ''; assignees = @(); description = ''; comments = @() } }; & $Change $o; $o | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8 }
  $o
}

# ---------- verbs ----------
function Get-TrackerUrl([string]$Id) {
  switch ($__trType) {
    'clickup' { "https://app.clickup.com/t/$Id" }
    'github' { $r, $n = __TrRef $Id; "https://$(Get-KitValue 'githubHost' 'github.com')/$r/issues/$n" }
    'gitlab' { $r, $n = __TrRef $Id; "https://$($KitConf.GitHost)/$r/-/issues/$n" }
    'jira' { "$(if ($env:JIRA_BASE_URL) { $env:JIRA_BASE_URL.TrimEnd('/') } else { '<JIRA_BASE_URL>' })/browse/$Id" }
    default { Join-Path (Join-Path $__trRt 'tracker-none') "$($Id -replace '[^\w.-]', '_').json" }
  }
}

function Get-TrackerTask([string]$Id) {
  switch ($__trType) {
    'clickup' {
      $j = __TrJson (__TrCli 'clickup' @('task', 'view', $Id, '--json'))
      if (-not $j.id) { return (__TrStub $Id) }
      [pscustomobject]@{ id = $j.id; name = $j.name; status = [string]$j.status.status; url = $(if ($j.url) { $j.url } else { Get-TrackerUrl $j.id }); parent = $j.parent
        assignees = @($j.assignees | ForEach-Object { if ($_.username) { $_.username } else { $_.id } }); list = [string]$j.list.id
        subtasks = @($j.subtasks | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = [string]$_.status.status; url = Get-TrackerUrl $_.id } })
        description = [string]$(if ($j.markdown_description) { $j.markdown_description } else { $j.description }) }
    }
    'github' {
      $r, $n = __TrRef $Id
      $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'number,title,state,url,labels,assignees,body'))
      if (-not $j.number) { return (__TrStub $Id) }
      $body = [string]$j.body
      $par = if ($body -match '(?m)^Part of #(\d+)') { $Matches[1] } else { $null }
      $subs = @([regex]::Matches($body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
          $s = __TrJson (__TrCli 'gh' @('issue', 'view', $_, '-R', $r, '--json', 'number,title,state,labels'))
          [pscustomobject]@{ id = "$_"; name = $s.title; status = (__TrLabelStatus @($s.labels.name) ($s.state -eq 'CLOSED')); url = Get-TrackerUrl $_ } })
      [pscustomobject]@{ id = "$($j.number)"; name = $j.title; status = (__TrLabelStatus @($j.labels.name) ($j.state -eq 'CLOSED')); url = $j.url; parent = $par
        assignees = @($j.assignees.login); list = $r; subtasks = $subs; description = $body }
    }
    'gitlab' {
      $r, $n = __TrRef $Id
      $j = __TrGl 'GET' (__TrGlPath $Id) $null
      if (-not $j.iid) { return (__TrStub $Id) }
      $body = [string]$j.description
      $par = if ($body -match '(?m)^Part of #(\d+)') { $Matches[1] } else { $null }
      $subs = @([regex]::Matches($body, '(?m)^\s*[-*] \[[ xX]\] #(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
          $s = __TrGl 'GET' (__TrGlPath $_) $null
          [pscustomobject]@{ id = "$_"; name = $s.title; status = (__TrLabelStatus @($s.labels) ($s.state -eq 'closed')); url = $s.web_url } })
      [pscustomobject]@{ id = "$($j.iid)"; name = $j.title; status = (__TrLabelStatus @($j.labels) ($j.state -eq 'closed')); url = $j.web_url; parent = $par
        assignees = @($j.assignees.username); list = $r; subtasks = $subs; description = $body }
    }
    'jira' {
      $j = __TrJira 'GET' "issue/$Id`?fields=summary,status,parent,assignee,subtasks,project,description" $null
      if (-not $j.key) { return (__TrStub $Id) }
      $f = $j.fields
      [pscustomobject]@{ id = $j.key; name = $f.summary; status = [string]$f.status.name; url = Get-TrackerUrl $j.key; parent = $f.parent.key
        assignees = @($f.assignee | Where-Object { $_ } | ForEach-Object { $_.displayName }); list = [string]$f.project.key
        subtasks = @($f.subtasks | ForEach-Object { [pscustomobject]@{ id = $_.key; name = $_.fields.summary; status = [string]$_.fields.status.name; url = Get-TrackerUrl $_.key } })
        description = (__TrAdfText $f.description).Trim() }
    }
    default {
      $o = __TrNone $Id 'view' $null
      if (-not $o) { return (__TrStub $Id) }
      $subs = @(Get-ChildItem (Join-Path $__trRt 'tracker-none') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
          Where-Object { $_.parent -eq $Id } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = $_.status; url = Get-TrackerUrl $_.id } })
      [pscustomobject]@{ id = $o.id; name = $o.name; status = $o.status; url = Get-TrackerUrl $o.id; parent = $o.parent; assignees = @($o.assignees); list = $o.list; subtasks = $subs; description = $o.description }
    }
  }
}

function Set-TrackerStatus([string]$Id, [string]$Status) {
  $name = Resolve-TrackerStatus $Status
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('status', 'set', $name, $Id) }
    'github' {
      $r, $n = __TrRef $Id
      $j = __TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'state,labels'))
      $old = @($j.labels.name | Where-Object { $_ -like 'status:*' -and $_ -ne "status:$name" })
      $edit = @('issue', 'edit', $n, '-R', $r); foreach ($o in $old) { $edit += @('--remove-label', $o) }
      if (__TrIsClosed $name) { if ($old) { $null = __TrCli 'gh' $edit }; __TrCli 'gh' @('issue', 'close', $n, '-R', $r) }
      else {
        if ($j.state -eq 'CLOSED') { $null = __TrCli 'gh' @('issue', 'reopen', $n, '-R', $r) }
        $null = __TrCli 'gh' @('label', 'create', "status:$name", '-R', $r, '--force', '--color', 'ededed')
        __TrCli 'gh' ($edit + @('--add-label', "status:$name"))
      }
    }
    'gitlab' {
      $j = __TrGl 'GET' (__TrGlPath $Id) $null
      $old = @($j.labels | Where-Object { $_ -like 'status:*' -and $_ -ne "status:$name" })
      $b = @{}; if ($old) { $b.remove_labels = $old -join ',' }
      if (__TrIsClosed $name) { $b.state_event = 'close' } else { $b.add_labels = "status:$name"; if ($j.state -eq 'closed') { $b.state_event = 'reopen' } }
      $res = __TrGl 'PUT' (__TrGlPath $Id) $b
      if ($res) { "status of #$($res.iid): $name" }
    }
    'jira' {
      $t = __TrJira 'GET' "issue/$Id/transitions" $null
      $tr = @($t.transitions | Where-Object { $_.name -ieq $name -or $_.to.name -ieq $name }) | Select-Object -First 1
      if (-not $tr -and -not $__trDry) { throw "tracker (jira): no transition to '$name' from the current status of $Id (have: $(@($t.transitions | ForEach-Object { $_.to.name }) -join ', '))" }
      $null = __TrJira 'POST' "issue/$Id/transitions" @{ transition = @{ id = $(if ($tr) { $tr.id } else { "<id of '$name'>" }) } }
      "status of $Id`: $name"
    }
    default { $null = __TrNone $Id "status $name" { param($o) $o.status = $name }; "status of $Id`: $name (tracker none)" }
  }
}

function Add-TrackerComment([string]$Id, [string]$Text) {
  $Text = __TrText $Text
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('comment', 'add', $Id, $Text) }
    'github' {
      $r, $n = __TrRef $Id
      if ($__trDry) { return (__TrCli 'gh' @('issue', 'comment', $n, '-R', $r, '--body', $Text)) }
      $f = __TrTemp $Text; try { __TrCli 'gh' @('issue', 'comment', $n, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    'gitlab' { $res = __TrGl 'POST' (__TrGlPath $Id '/notes') @{ body = $Text }; if ($res) { "commented on #$((__TrRef $Id)[1])" } }
    'jira' { $res = __TrJira 'POST' "issue/$Id/comment" @{ body = (__TrAdf $Text) }; if ($res) { "commented on $Id" } }
    default { $null = __TrNone $Id "comment $Text" { param($o) $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = $Text }) }; "commented on $Id (tracker none)" }
  }
}

function Get-TrackerComments([string]$Id) {
  $c = switch ($__trType) {
    'clickup' { @(__TrJson (__TrCli 'clickup' @('comment', 'list', $Id, '--json'))) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.user.username; date = (__TrDate $_.date); text = [string]$_.comment_text } } }
    'github' { $r, $n = __TrRef $Id; @((__TrJson (__TrCli 'gh' @('issue', 'view', $n, '-R', $r, '--json', 'comments'))).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.login; date = (__TrDate $_.createdAt); text = [string]$_.body } } }
    'gitlab' { @(__TrGl 'GET' (__TrGlPath $Id '/notes?sort=asc&per_page=100') $null) | Where-Object { $_ -and -not $_.system } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.username; date = (__TrDate $_.created_at); text = [string]$_.body } } }
    'jira' { @((__TrJira 'GET' "issue/$Id/comment?maxResults=200" $null).comments) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ user = [string]$_.author.displayName; date = (__TrDate $_.created); text = (__TrAdfText $_.body).Trim() } } }
    default { @((__TrNone $Id 'comments' $null).comments) | Where-Object { $_ } }
  }
  @($c | Sort-Object date)
}

function New-TrackerTask([string]$List, [string]$Name, [string]$Description, [string]$Parent, [string]$Assignee, [string]$Priority) {
  $Description = __TrText $Description
  if (-not $List) { $List = [string](Get-KitSetting 'tracker.list' '') }
  switch ($__trType) {
    'clickup' {
      $a = @('task', 'create', '--list-id', $List, '--name', $Name, '--markdown-description', $Description, '--json')
      if ($Priority) { $a += @('--priority', $Priority) }
      if ($Assignee -and $Assignee -ne '-') { $a += @('--assignee', $Assignee) }
      $t = if ($Parent -and $Parent -ne '-' -and -not $__trDry) { __TrJson (__TrCli 'clickup' ($a + @('--parent', $Parent))) } else { $null }
      if ($__trDry) { $null = __TrCli 'clickup' ($a + @(if ($Parent -and $Parent -ne '-') { '--parent', $Parent })); return [pscustomobject]@{ id = '<new>'; url = '' } }
      $dropped = $false
      # ClickUp refuses a subtask whose parent lives in another list: create it in the list and link it with a comment
      if (-not $t.id) { $dropped = [bool]($Parent -and $Parent -ne '-'); $t = __TrJson (__TrCli 'clickup' $a) }
      if (-not $t.id) { return $null }
      if ($dropped) { $null = Add-TrackerComment $t.id "Related: $(Get-TrackerUrl $Parent) (could not be created as its subtask: it is in another list)." }
      [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }) }
    }
    'github' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $body = $(if ($Parent -and $Parent -ne '-') { "Part of #$($Parent -replace '^.*#', '')`n`n" }) + $Description
      $a = @('issue', 'create', '-R', $r, '--title', $Name)
      if ($Assignee -and $Assignee -ne '-') { $a += @('--assignee', $Assignee) }
      if ($Priority) { $pl = "priority:$(__TrPrio $Priority)"; $null = __TrCli 'gh' @('label', 'create', $pl, '-R', $r, '--force', '--color', 'ededed'); $a += @('--label', $pl) }
      if ($__trDry) { $null = __TrCli 'gh' ($a + @('--body', $body)); $out = $null }
      else { $f = __TrTemp $body; try { $out = __TrCli 'gh' ($a + @('--body-file', $f)) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
      $num = if ("$out" -match '/issues/(\d+)') { $Matches[1] } elseif ($__trDry) { '<new>' } else { return $null }
      if ($Parent -and $Parent -ne '-') {   # task list line in the parent, so view <parent> lists it as a subtask
        $pn = $Parent -replace '^.*#', ''
        $pb = [string](__TrJson (__TrCli 'gh' @('issue', 'view', $pn, '-R', $r, '--json', 'body'))).body
        $nb = $pb.TrimEnd() + "`n- [ ] #$num"
        if ($__trDry) { $null = __TrCli 'gh' @('issue', 'edit', $pn, '-R', $r, '--body', $nb) } else { $f = __TrTemp $nb; try { $null = __TrCli 'gh' @('issue', 'edit', $pn, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
      }
      [pscustomobject]@{ id = "$num"; url = $(if ("$out" -match '(https://\S+/issues/\d+)') { $Matches[1] } else { Get-TrackerUrl "$r#$num" }) }
    }
    'gitlab' {
      $r = if ($List -match '/') { $List } else { (__TrRef '0')[0] }
      $b = @{ title = $Name; description = $(if ($Parent -and $Parent -ne '-') { "Part of #$($Parent -replace '^.*#', '')`n`n" }) + $Description }
      if ($Priority) { $b.labels = "priority:$(__TrPrio $Priority)" }
      if ($Assignee -and $Assignee -ne '-') { $u = @(__TrGl 'GET' "users?username=$([uri]::EscapeDataString($Assignee))" $null) | Select-Object -First 1; if ($u.id) { $b.assignee_ids = @($u.id) } }
      $t = __TrGl 'POST' "projects/$([uri]::EscapeDataString($r))/issues" $b
      $iid = if ($t.iid) { $t.iid } elseif ($__trDry) { '<new>' } else { return $null }
      if ($Parent -and $Parent -ne '-') {
        $pid0 = "$r#$($Parent -replace '^.*#', '')"
        $p = __TrGl 'GET' (__TrGlPath $pid0) $null
        $null = __TrGl 'PUT' (__TrGlPath $pid0) @{ description = ([string]$p.description).TrimEnd() + "`n- [ ] #$iid" }
      }
      [pscustomobject]@{ id = "$iid"; url = $(if ($t.web_url) { $t.web_url } else { Get-TrackerUrl "$r#$iid" }) }
    }
    'jira' {
      $isSub = [bool]($Parent -and $Parent -ne '-')
      $f = @{ project = @{ key = $List }; summary = $Name; description = (__TrAdf $Description)
        issuetype = @{ name = $(if ($isSub) { Get-KitSetting 'tracker.subtaskType' 'Subtask' } else { Get-KitSetting 'tracker.issueType' 'Task' }) } }
      if ($isSub) { $f.parent = @{ key = $Parent } }
      if ($Assignee -and $Assignee -ne '-') { $f.assignee = @{ accountId = $Assignee } }
      if ($Priority) { $f.priority = @{ name = $(switch ($Priority) { '1' { 'Highest' } '2' { 'High' } '3' { 'Medium' } '4' { 'Low' } default { $Priority } }) } }
      $t = __TrJira 'POST' 'issue' @{ fields = $f }
      if (-not $t.key) { if ($__trDry) { return [pscustomobject]@{ id = '<new>'; url = '' } }; return $null }
      [pscustomobject]@{ id = $t.key; url = Get-TrackerUrl $t.key }
    }
    default {
      $d = Join-Path $__trRt 'tracker-none'; New-Item -ItemType Directory -Force $d | Out-Null
      $n = 1 + @(Get-ChildItem $d -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count
      while (Test-Path (Join-Path $d "LOCAL-$n.json")) { $n++ }
      $id = "LOCAL-$n"
      $null = __TrNone $id "create $Name" { param($o) $o.name = $Name; $o.status = @($__trStatus.open)[0]; $o.parent = $(if ($Parent -and $Parent -ne '-') { $Parent }); $o.list = $List; $o.assignees = @($Assignee | Where-Object { $_ -and $_ -ne '-' }); $o.description = $Description }
      [pscustomobject]@{ id = $id; url = Get-TrackerUrl $id }
    }
  }
}

function Set-TrackerDescription([string]$Id, [string]$Text) {
  $Text = __TrText $Text
  switch ($__trType) {
    'clickup' { __TrCli 'clickup' @('task', 'edit', $Id, '--markdown-description', $Text) }
    'github' {
      $r, $n = __TrRef $Id
      if ($__trDry) { return (__TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--body', $Text)) }
      $f = __TrTemp $Text; try { __TrCli 'gh' @('issue', 'edit', $n, '-R', $r, '--body-file', $f) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    'gitlab' { $null = __TrGl 'PUT' (__TrGlPath $Id) @{ description = $Text }; "described #$((__TrRef $Id)[1])" }
    'jira' { $null = __TrJira 'PUT' "issue/$Id" @{ fields = @{ description = (__TrAdf $Text) } }; "described $Id" }
    default { $null = __TrNone $Id 'describe' { param($o) $o.description = $Text }; "described $Id (tracker none)" }
  }
}

function Add-TrackerAttachment([string]$Id, [string]$File, [string]$Text) {
  # A report or guide file: GitHub/GitLab get its text as a comment (they have no task attachments); ClickUp/Jira attach the file
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "tracker: no such file $File" }
  $leaf = Split-Path $File -Leaf
  switch ($__trType) {
    { $_ -in 'github', 'gitlab' } {
      $body = Get-Content -LiteralPath $File -Raw -Encoding utf8
      if ($body.Length -gt 60000) { $body = $body.Substring(0, 60000) + "`n`n_(truncated: the full $leaf is in the QA run folder)_" }
      Add-TrackerComment $Id ($(if ($Text) { "$Text`n`n" }) + $body)
    }
    'clickup' { __TrCli 'clickup' @('attachment', 'add', $Id, $File); if ($Text) { Add-TrackerComment $Id "$Text (attached: $leaf)" } }
    'jira' { $null = __TrJira 'POST' "issue/$Id/attachments" $null $File; "attached $leaf to $Id"; if ($Text) { Add-TrackerComment $Id "$Text (attached: $leaf)" } }
    default { $null = __TrNone $Id "attach $File" { param($o) $o.comments = @(@($o.comments) + [pscustomobject]@{ user = [Environment]::UserName; date = (Get-Date).ToUniversalTime().ToString('s'); text = "$Text [attachment: $File]" }) }; "attached $leaf to $Id (tracker none)" }
  }
}

# ---------- script mode ----------
if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
$__v = if ($__trPos.Count) { $__trPos[0] } else { '' }
$__id = if ($__trPos.Count -gt 1) { $__trPos[1] } else { '' }
$__x = if ($__trPos.Count -gt 2) { ($__trPos[2..($__trPos.Count - 1)]) -join ' ' } else { '' }
function __TrOut($o) { if ($null -ne $o) { ConvertTo-Json -InputObject $o -Depth 6 } }
switch ($__v) {
  'view' { __TrOut (Get-TrackerTask $__id) }
  'status' { Set-TrackerStatus $__id $__x }
  'comment' { Add-TrackerComment $__id $(if ($__x) { $__x } else { $__trOpt.Text }) }
  'comments' { __TrOut @(Get-TrackerComments $__id) }
  'create' { __TrOut (New-TrackerTask -List $__trOpt.List -Name $__trOpt.Name -Description $__trOpt.Description -Parent $__trOpt.Parent -Assignee $__trOpt.Assignee -Priority $__trOpt.Priority) }
  'url' { Get-TrackerUrl $__id }
  'describe' { Set-TrackerDescription $__id $(if ($__x) { $__x } else { $__trOpt.Description }) }
  'attach' { Add-TrackerAttachment $__id $__trPos[2] $__trOpt.Text }
  default { Get-Content $PSCommandPath -TotalCount 34 | Select-Object -Skip 1; exit 1 }
}
