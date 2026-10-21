# Extra tracker-gitlab: GitLab issues as the kit tracker (tracker.type gitlab); labels, parent, subtasks as on github.
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add tracker-gitlab); helpers come from lib.ps1.
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
# adapter:tracker/gitlab: glab api; labels, parent, subtasks as on github
Register-KitAdapter 'tracker' 'gitlab' @{
  'url' = { param($a) $r, $n = __TrRef $a.id; "https://$($KitConf.GitHost)/$r/-/issues/$n" }
  'view' = { param($a)
    $j = __TrGl 'GET' (__TrGlPath $a.id) $null; if (-not $j.iid) { return }
    __TrIssue $j.iid $j.title (__TrLabelStatus @($j.labels) ($j.state -eq 'closed')) $j.web_url @($j.assignees.username) (__TrRef $a.id)[0] ([string]$j.description) {
      $s = __TrGl 'GET' (__TrGlPath $_) $null; __TrSub "$_" $s.title (__TrLabelStatus @($s.labels) ($s.state -eq 'closed')) $s.web_url }
  }
  'status' = { param($a)
    $p = __TrGlPath $a.id; $name = $a.status; $j = __TrGl 'GET' $p $null
    $old = @($j.labels | Where-Object { $_ -like "$__trLp*" -and $_ -ne "$__trLp$name" })
    $b = @{}; if ($old) { $b.remove_labels = $old -join ',' }
    if (__TrIsClosed $name) { $b.state_event = 'close' } else { $b.add_labels = "$__trLp$name"; if ($j.state -eq 'closed') { $b.state_event = 'reopen' } }
    $res = __TrGl 'PUT' $p $b; if ($res) { "status of #$($res.iid): $name" }
  }
  'comment' = { param($a) $res = __TrGl 'POST' (__TrGlPath $a.id '/notes') @{ body = $a.text }; if ($res) { "commented on #$((__TrRef $a.id)[1])" } }
  'comments' = { param($a) @(__TrGl 'GET' (__TrGlPath $a.id '/notes?sort=asc&per_page=100') $null) | Where-Object { $_ -and -not $_.system } | ForEach-Object { __TrComment $_.author.username $_.created_at $_.body } }
  'create' = { param($a)
    $r = __TrRepoOf $a.list; $b = @{ title = $a.name; description = (__TrPartOf $a) + $a.description }
    if ($a.priority) { $b.labels = "priority:$(__TrPrio $a.priority)" }
    if ($a.assignee) { $u = @(__TrGl 'GET' "users?username=$([uri]::EscapeDataString($a.assignee))" $null) | Select-Object -First 1; if ($u.id) { $b.assignee_ids = @($u.id) } }
    $t = __TrGl 'POST' "projects/$([uri]::EscapeDataString($r))/issues" $b
    $iid = if ($t.iid) { $t.iid } elseif ($__trDry) { '<new>' } else { return }
    if ($a.parent) { $p = __TrGlPath "$r#$($a.parent -replace '^.*#', '')"; $null = __TrGl 'PUT' $p @{ description = ([string](__TrGl 'GET' $p $null).description).TrimEnd() + "`n- [ ] #$iid" } }
    [pscustomobject]@{ id = "$iid"; url = $(if ($t.web_url) { $t.web_url } else { Get-TrackerUrl "$r#$iid" }) }
  }
  'describe' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id) @{ description = $a.text }; "described #$((__TrRef $a.id)[1])" }
  'rename' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id) @{ title = $a.name }; "renamed #$((__TrRef $a.id)[1])" }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $q = if (__TrIsClosed $a.status) { 'state=closed' } else { "state=opened&labels=$([uri]::EscapeDataString("$__trLp$($a.status)"))" }
    @(__TrGl 'GET' "projects/$([uri]::EscapeDataString((__TrRepoOf $a.list)))/issues?$q&per_page=100" $null) | Where-Object { $_ -and $_.iid } | ForEach-Object { __TrRow "$($_.iid)" ([string]$_.title) $a.status @($_.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
  }
  'owner' = { param($a) [string](__TrGl 'GET' 'user' $null).username }
}
