#Requires -Version 7
# Goody tracker-clickup: ClickUp as the kit tracker through the clickup CLI (tracker.type clickup; tracker.list = the list id of
# new tasks; tracker.statuses = the list's status names). Dot-sourced by lib.ps1 before the tracker type is resolved.
function __TrClickupMemberId([string]$Who) {
  if (-not $Who) { return $null }
  $__trDry = $false
  $m = @(__TrJson (__TrCli 'clickup' @('member', 'list', '--json'))) | Where-Object { $_ -and ($_.username -eq $Who -or ($_.email -and $_.email -eq $Who)) } | Select-Object -First 1
  if ($m) { [string]$m.id } else { $null }
}
# adapter:tracker/clickup: clickup CLI
Register-KitAdapter 'tracker' 'clickup' @{
  'url' = { param($a) "https://app.clickup.com/t/$($a.id)" }
  'view' = { param($a)
    $j = __TrJson (__TrCli 'clickup' @('task', 'view', $a.id, '--json')); if (-not $j.id) { return }
    __TrTask $j.id $j.name ([string]$j.status.status) $(if ($j.url) { $j.url } else { Get-TrackerUrl $j.id }) $j.parent @($j.assignees | ForEach-Object { if ($_.username) { $_.username } else { $_.id } }) ([string]$j.list.id) @($j.subtasks | ForEach-Object { __TrSub $_.id $_.name ([string]$_.status.status) (Get-TrackerUrl $_.id) }) ([string]$(if ($j.markdown_description) { $j.markdown_description } else { $j.description }))
  }
  'status' = { param($a)
    $names = @($a.status); foreach ($k in @($__trStatus.Keys)) { if ($k -ieq $a.logical) { $names = @($__trStatus[$k]) } }
    foreach ($n in $names) { $out = __TrCli 'clickup' @('status', 'set', $n, $a.id); if ("$out" -notmatch 'no matching status') { return $out } }
    if (-not $__trDry) { throw "tracker (clickup): no status '$($names -join "' / '")' on the list of task $($a.id) (set tracker.statuses.$($a.logical) in kit.local.json)" }
  }
  'comment' = { param($a) __TrCli 'clickup' @('comment', 'add', $a.id, $a.text) }
  'comments' = { param($a) @(__TrJson (__TrCli 'clickup' @('comment', 'list', $a.id, '--json'))) | Where-Object { $_ } | ForEach-Object { __TrComment $_.user.username $_.date $_.comment_text $_.id } }
  'comment-edit' = { param($a) __TrCli 'clickup' @('comment', 'edit', $a.comment, $a.text) }   # a kit comment's next round (lib.ps1 Set-TrackerKitComment)
  'comment-delete' = { param($a) __TrCli 'clickup' @('comment', 'delete', $a.comment, '--yes') }
  'create' = { param($a)
    $c = @('task', 'create', '--list-id', $a.list, '--name', $a.name, '--markdown-description', $a.description, '--json'); $as = $a.assignee
    if ($a.priority) { $c += @('--priority', $a.priority) }
    if ($as -and $as -notmatch '^\d+$') {
      $as = try { __TrClickupMemberId $as } catch { Write-Warning "tracker: member lookup failed ($($_.Exception.Message))"; $null }
      if (-not $as) { [Console]::Error.WriteLine("WARNING: tracker: no ClickUp member '$($a.assignee)' (clickup member list): task unassigned (assigned=false)") }
    }
    if ($as) { $c += @('--assignee', $as) }
    if ($__trDry) { $null = __TrCli 'clickup' ($c + @(if ($a.parent) { '--parent', $a.parent })); return [pscustomobject]@{ id = '<new>'; url = ''; assigned = [bool]$as } }
    $t = if ($a.parent) { try { __TrJson (__TrCli 'clickup' ($c + @('--parent', $a.parent))) } catch { $null } }
    $dropped = $a.parent -and -not $t.id; if (-not $t.id) { $t = __TrJson (__TrCli 'clickup' $c) }
    if (-not $t.id) { return }
    if ($dropped) { $null = Add-TrackerComment $t.id "Related: $(Get-TrackerUrl $a.parent) (not its subtask: it is in another list)." }
    [pscustomobject]@{ id = $t.id; url = $(if ($t.url) { $t.url } else { Get-TrackerUrl $t.id }); assigned = [bool]$as }
  }
  'describe' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--markdown-description', $a.text) }
  'rename' = { param($a) __TrCli 'clickup' @('task', 'edit', $a.id, '--name', $a.name) }
  'attach' = { param($a) __TrCli 'clickup' @('attachment', 'add', $a.id, $a.file); __TrNote $a }
  'list' = { param($a)
    # lib.ps1 Get-TrackerTasks already fell back to tracker.list; without one the CLI exits 1 'no list specified'
    if (-not $a.list) { throw 'tracker list needs -List <id> (or tracker.list in kit.local.json)' }
    foreach ($pg in 0..6) {
      $arr = @(@(__TrJson (__TrCli 'clickup' @('task', 'list', '--list-id', $a.list, '--status', $a.status, '--page', "$pg", '--json'))) | Where-Object { $_ -and $_.id })
      foreach ($t in $arr) { __TrRow ([string]$t.id) ([string]$t.name) $a.status @($t.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
      if ($arr.Count -lt 100) { break }
    }
  }
  'owner' = { param($a) if ($a.name) { __TrClickupMemberId $a.name } }
}
