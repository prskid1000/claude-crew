#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# tracker-clickup: ClickUp as the kit tracker through the clickup CLI (tracker.type clickup; tracker.list = the list id of
# new tasks; tracker.statuses = the list's status names; tracker.workspace = the workspace id for a list move, else the CLI's
# config). Dot-sourced by lib.ps1 before the tracker type is resolved.
# Sections: L7 helpers · L21 tracker
# ---- helpers: member ids, the stored token
function __TrClickupMemberId([string]$Who) {
  if (-not $Who) { return $null }
  $__trDry = $false
  $m = @(__TrJson (__TrCli 'clickup' @('member', 'list', '--json'))) | Where-Object { $_ -and ($_.username -eq $Who -or ($_.email -and $_.email -eq $Who)) } | Select-Object -First 1
  if ($m) { [string]$m.id } else { $null }
}
# the clickup CLI's stored API token for a REST call the CLI lacks (env CLICKUP_API_TOKEN, else its OS keyring entry
# clickup-cli:api_token; Windows Credential Manager only); never printed or logged
function __TrClickupToken {
  $t = "$env:CLICKUP_API_TOKEN"; if ($t) { return $t }
  if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) { throw 'tracker (clickup): no CLICKUP_API_TOKEN (the CLI keyring is read on Windows only)' }
  $t = & (Join-Path $script:KitLibDir 'flagged.ps1') credread -Text 'clickup-cli:api_token'; if (-not $t) { throw 'tracker (clickup): no stored token (clickup auth status; the owner logs in, never an agent)' }; $t
}
# ---- tracker: the adapter verbs
# comments: the CLI posts plain text (Markdown shows as typed) -> lib.ps1 ConvertTo-KitPlainText; descriptions render Markdown
# adapter:tracker/clickup: clickup CLI
Register-KitAdapter 'tracker' 'clickup' @{
  'caps' = @{ checklist = $true; subtasks = $true; commentEdit = $true; commentDelete = $true; statuses = $true; move = $true; attach = $true; dependencies = $true; labels = $true }
  # waits on (REST v2 dependency: task_id waits on depends_on); on = ids to add (missing only); returns what it waits on now
  'dependencies' = { param($a)
    $have = @(@((__TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--json'))).dependencies) | Where-Object { "$($_.task_id)" -eq $a.id } | ForEach-Object { "$($_.depends_on)" })
    foreach ($on in @($a.on | Where-Object { $_ -and $_ -notin $have })) {
      if ($__trDry) { Write-Host "DRYRUN: POST https://api.clickup.com/api/v2/task/$($a.id)/dependency depends_on=$on"; continue }
      $o = @(Invoke-KitHttp 'POST' "https://api.clickup.com/api/v2/task/$($a.id)/dependency" @{ depends_on = $on } @{ Authorization = (__TrClickupToken) } 3>&1)
      $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] }); if ($w) { throw "tracker (clickup) dependency $($a.id) -> ${on}: $($w[0].Message)" }; $have += $on }
    $have }
  # tags (lower case in ClickUp): REST v2 add tag to task
  'labels' = { param($a) foreach ($l in @($a.add)) { $u = "https://api.clickup.com/api/v2/task/$($a.id)/tag/$([uri]::EscapeDataString("$l".ToLower()))"
      if ($__trDry) { Write-Host "DRYRUN: POST $u"; continue }
      $o = @(Invoke-KitHttp 'POST' $u @{} @{ Authorization = (__TrClickupToken) } 3>&1); $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] }); if ($w) { throw "tracker (clickup) tag ${l}: $($w[0].Message)" } } }
  'url' = { param($a) "https://app.clickup.com/t/$($a.id)" }
  'view' = { param($a)
    $j = __TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--json')); if (-not $j.id) { return }
    __TrTask $j.id $j.name ([string]$j.status.status) $(if ($j.url) { $j.url } else { Get-TrackerUrl $j.id }) $j.parent @($j.assignees | Where-Object { $_ } | ForEach-Object { if ($_.username) { $_.username } else { $_.id } }) ([string]$j.list.id) @($j.subtasks | Where-Object { $_ } | ForEach-Object { __TrSub $_.id $_.name ([string]$_.status.status) (Get-TrackerUrl $_.id) }) ([string]$(if ($j.markdown_description) { $j.markdown_description } else { $j.description }))
  }
  'status' = { param($a)
    $names = @($a.names | Where-Object { $_ }); if (-not $names.Count) { $names = @($a.status) }   # the role's names in the task's list (lib.ps1 __Set-TrackerStatus)
    foreach ($n in $names) { $out = __TrCli 'clickup' @('status', 'set', $n, $a.id); if ("$out" -notmatch 'no matching status') { return $out } }
    if (-not $__trDry) { throw "tracker (clickup): no status '$($names -join "' / '")' on the list of task $($a.id) (crafty.ps1 tracker roles <list id>; tracker.statusMap.<list id>.$($a.logical) in kit.local.json)" }
  }
  # the list's live statuses (REST: the CLI lists a space's only; a list may override them); type open / custom / done / closed
  'statuses' = { param($a)
    $o = @(Invoke-KitHttp 'GET' "https://api.clickup.com/api/v2/list/$($a.scope)" $null @{ Authorization = (__TrClickupToken) } 3>&1)
    $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] }); if ($w) { throw "tracker (clickup) statuses: $($w[0].Message)" }
    @(@($o)[0].statuses | Where-Object { $_.status } | Sort-Object { [int]$_.orderindex } | ForEach-Object { [pscustomobject]@{ name = "$($_.status)"; type = "$($_.type)" } })
  }
  'comment' = { param($a) __TrCli 'clickup' @('comment', 'add', $a.id, (ConvertTo-KitPlainText $a.text)) }
  'comments' = { param($a) @(__TrJson (__TrCli 'clickup' @('comment', 'list', $a.id, '--json'))) | Where-Object { $_ } | ForEach-Object { __TrComment $_.user.username $_.date $_.comment_text $_.id } }
  'comment-edit' = { param($a) __TrCli 'clickup' @('comment', 'edit', $a.comment, (ConvertTo-KitPlainText $a.text)) }   # a kit comment's next round (lib.ps1 Set-TrackerKitComment)
  'comment-delete' = { param($a) __TrCli 'clickup' @('comment', 'delete', $a.comment, '--yes') }
  'create' = { param($a)
    # a subtask lives in its parent's list (ClickUp "subtasks in multiple lists" off): no list or another list -> the parent's, said on stderr
    $lid = $a.list; $pj = if ($a.parent -and -not $__trDry) { try { __TrJson (__TrCli 'clickup' @('task', 'view', $a.parent, '--json')) } catch { if (-not $lid) { throw } } }; $plid = if ($pj) { [string]$pj.list.id }   # a failed look-up with -List: that list
    # one subtask level (HTTP 400 ITEM_002): a parent that is itself a subtask -> its top-level parent, said on stderr (retro 1549: 4 errors)
    for ($up = 0; $pj.parent -and $up -lt 5; $up++) { [Console]::Error.WriteLine("WARNING: tracker: parent $($a.parent) is a subtask of $($pj.parent) (ClickUp nests one level): the new task goes under $($pj.parent)")
      $a.parent = [string]$pj.parent; $pj = __TrJson (__TrCli 'clickup' @('task', 'view', $a.parent, '--json')); $plid = [string]$pj.list.id }
    if ($plid -and $lid -and $plid -ne $lid) { [Console]::Error.WriteLine("WARNING: tracker: parent $($a.parent) is in list $plid, not ${lid}: the subtask goes to list $plid") }
    if ($plid) { $lid = $plid }
    if (-not $lid -and -not $__trDry) { throw 'tracker (clickup) create: no list (-List, tracker.list) and no parent to take it from' }
    $c = @('task', 'create', '--list-id', $lid, '--name', $a.name, '--markdown-description', $a.description, '--json'); $as = $a.assignee
    if ($a.priority) { $c += @('--priority', $a.priority) }
    if ($as -and $as -notmatch '^\d+$') {
      $as = try { __TrClickupMemberId $as } catch { Write-Warning "tracker: member lookup failed ($($_.Exception.Message))"; $null }
      if (-not $as) { [Console]::Error.WriteLine("WARNING: tracker: no ClickUp member '$($a.assignee)' (clickup member list): task unassigned (assigned=false)") }
    }
    if ($as) { $c += @('--assignee', $as) }
    if ($__trDry) { $null = __TrCli 'clickup' ($c + @(if ($a.parent) { '--parent', $a.parent })); return [pscustomobject]@{ id = '<new>'; url = ''; assigned = [bool]$as } }
    $t = if ($a.parent) { try { __TrJson (__TrCli 'clickup' ($c + @('--parent', $a.parent))) } catch { throw "tracker (clickup) create: subtask of $($a.parent) failed, nothing created: $($_.Exception.Message)" } } else { __TrJson (__TrCli 'clickup' $c) }   # never a silent top-level task
    if (-not $t.id) { return }
    [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }); assigned = [bool]$as }
  }
  'describe' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--markdown-description', $a.text) }
  'rename' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--name', $a.name) }
  # move (K54; the CLI has neither): -List = REST v3 home-list move (workspace: tracker.workspace, else the CLI's config), -Parent =
  # REST v2 PUT {parent}; a subtask lives in its parent's list (another list without -List: refused, link it in the parent's Items);
  # top-level: the API cannot (parent null is refused)
  'move' = { param($a)
    if ($a.top) { throw 'tracker (clickup) move: the API cannot make a subtask top-level (parent null is refused): do it in the app' }
    $lid = [string](__TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--json'))).list.id; $tl = if ($a.list) { "$($a.list)" } else { $lid }
    $plid = if ($a.parent) { [string](__TrJson (__TrCli 'clickup' @('task', 'view', $a.parent, '--json'))).list.id }
    if ($plid -and $tl -and $plid -ne $tl) { throw "tracker (clickup) move: $($a.id) is in list $tl, $($a.parent) in list ${plid}: a subtask lives in its parent's list (-List $plid moves it first; to keep its list, link it in the parent's Items)" }
    $calls = @(if ($a.list -and $a.list -ne $lid) {
        $ws = Get-KitSetting 'tracker.workspace' ''; if (-not $ws) { $cf = Join-Path $HOME '.config/clickup/config.yml'; if (Test-Path -LiteralPath $cf) { $ws = @((Get-Content -LiteralPath $cf) -match '^workspace:' -replace '^workspace:\s*', '' -replace '["'']')[0] } }
        if (-not $ws) { throw 'tracker (clickup) move: no workspace id (tracker.workspace in kit.local.json)' }
        , @('PUT', "https://api.clickup.com/api/v3/workspaces/$ws/tasks/$($a.id)/home_list/$($a.list)", $null) }
      if ($a.parent) { , @('PUT', "https://api.clickup.com/api/v2/task/$($a.id)", @{ parent = $a.parent }) })
    foreach ($c in $calls) {
      if ($__trDry) { Write-Host "DRYRUN: $($c[0]) $($c[1])$(if ($c[2]) { ' ' + ($c[2] | ConvertTo-Json -Compress) })"; continue }
      $o = @(Invoke-KitHttp $c[0] $c[1] $c[2] @{ Authorization = (__TrClickupToken) } 3>&1)
      $w = @($o | Where-Object { $_ -is [Management.Automation.WarningRecord] }); if ($w) { throw "tracker (clickup) move: $($w[0].Message)" } }
    "moved $($a.id)$(if ($a.list -and $a.list -ne $lid) { " to list $($a.list)" })$(if ($a.parent) { " under $($a.parent)" })" }
  'attach' = { param($a) __TrCli 'clickup' @('attachment', 'add', $a.id, $a.file); __TrNote $a }
  'list' = { param($a)
    # lib.ps1 Get-TrackerTasks already fell back to tracker.list, then trackerLists; without one the CLI exits 1 'no list specified'
    if (-not $a.list) { throw 'tracker list needs -List <id> (or tracker.list / trackerLists in kit.local.json)' }
    foreach ($pg in 0..6) {
      $arr = @(@(__TrJson (__TrCli 'clickup' @('task', 'list', '--list-id', $a.list, '--status', $a.status, '--page', "$pg", '--json'))) | Where-Object { $_ -and $_.id })
      foreach ($t in $arr) { __TrRow ([string]$t.id) ([string]$t.name) $a.status @($t.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
      if ($arr.Count -lt 100) { break }
    }
  }
  'owner' = { param($a) if ($a.name) { __TrClickupMemberId $a.name } }
  # one checklist by name: items keyed by their text up to the first ' · ' (added, renamed, resolved; a resolved one to untick is removed
  # and added again: the CLI cannot unresolve); prune: kit lines ('<key> · ...', key without spaces) not wanted and repeats removed, others' lines kept;
  # keepDone: a resolved unwanted line stays
  'checklist' = { param($a)
    $get = { @(__TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--jq', '.checklists'))) | Where-Object { $_ -and $_.name -eq $a.name } | Select-Object -First 1 }
    $key = { param($t) ("$t" -split ' · ', 2)[0].Trim() }
    $cl = & $get; if (-not $cl -and -not $__trDry) { $null = __TrCli 'clickup' @('task', 'checklist', 'add', $a.id, $a.name); $cl = & $get }
    if (-not $cl) { if ($__trDry) { return }; throw "tracker (clickup): checklist '$($a.name)' not created on $($a.id)" }
    $want = @{}; foreach ($w in @($a.items)) { $want[(& $key $w.text)] = $w }
    $have = @{}; $n = 0; $rm = 0
    foreach ($i in @($cl.items)) { $k = & $key $i.name
      $unw = $a.prune -and -not $want.ContainsKey($k) -and $k -notmatch '\s' -and "$($i.name)".Contains(' · ') -and -not ($a.keepDone -and $i.resolved)
      $gone = $have.ContainsKey($k) -or ($want.ContainsKey($k) -and $i.resolved -and -not $want[$k].done) -or $unw
      if ($gone -and ($a.prune -or -not $have.ContainsKey($k))) { $null = __TrCli 'clickup' @('task', 'checklist', 'item', 'remove', $cl.id, $i.id); $n++; if ($unw) { $rm++ } } elseif (-not $have.ContainsKey($k)) { $have[$k] = $i } }
    foreach ($w in @($a.items)) { $i = $have[(& $key $w.text)]; if (-not $i) { $null = __TrCli 'clickup' @('task', 'checklist', 'item', 'add', $cl.id, $w.text); $n++ } elseif ($i.name -cne $w.text) { $null = __TrCli 'clickup' @('task', 'checklist', 'item', 'edit', $cl.id, $i.id, '--name', $w.text); $n++ } }
    if (@($a.items | Where-Object done).Count) { $have = @{}; foreach ($i in @((& $get).items)) { $have[(& $key $i.name)] = $i } }
    foreach ($w in @($a.items | Where-Object done)) { $i = $have[(& $key $w.text)]; if ($i -and -not $i.resolved) { $null = __TrCli 'clickup' @('task', 'checklist', 'item', 'resolve', $cl.id, $i.id); $n++ } }
    "checklist $($a.name) on $($a.id): $n change(s), $rm removed"
  }
}
