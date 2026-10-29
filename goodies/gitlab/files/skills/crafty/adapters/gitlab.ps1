#Requires -Version 7
# gitlab (goody): GitLab / self-hosted GitLab through the glab CLI: git host (MRs, merge, auto-merge, branch.protect), CI
# (pipelines, jobs, logs) and tracker (issues; status = a <tracker.statusLabelPrefix><name> label, closed = closed issue).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/; uses its shared helpers (__Cli, __Enc, __Del, __CiStat, __Tr*).
# Sections: L6 glab · L10 git-host · L32 ci · L42 tracker
# ---- glab: host and API calls
# glab reads GITLAB_HOST: a self-hosted GitLab (git host or tracker) sets it before the first call
function __GlEnv { if (-not $env:GITLAB_HOST -and $KitConf.GitHost -and $KitConf.GitHost -ne 'gitlab.com' -and ($script:HostType -eq 'gitlab' -or $script:__trType -eq 'gitlab')) { $env:GITLAB_HOST = $KitConf.GitHost } }
function __Gp($a, [string]$Rest, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) { __GlEnv; __Cli glab "projects/$(__Enc $a.repo)$Rest" $Method $Fields -Json:$Json -Res:$Res }
# ---- git-host: merge requests, repository, branch protection
# adapter:git-host/gitlab: glab api
Register-KitAdapter 'git-host' 'gitlab' @{
  'mr.get' = { param($a) __Gp $a "/merge_requests/$($a.n)" }
  'mr.list' = { param($a) @(__Gp $a "/merge_requests?$(($a.Keys | Where-Object { $_ -notin 'repo', 'type' } | Sort-Object | ForEach-Object { "$_=$(__Enc $a[$_])" }) -join '&')") }
  'mr.changes' = { param($a) __Gp $a "/merge_requests/$($a.n)/changes" }
  'mr.create' = { param($a) __Gp $a "/merge_requests" 'POST' @{ source_branch = $a.source; target_branch = $a.target; title = $a.title; description = $a.body; remove_source_branch = (__Del $a); squash = $a.method -eq 'squash' } -Json }
  'mr.update' = { param($a) __Gp $a "/merge_requests/$($a.n)" 'PUT' @{ title = $a.title; description = $a.body } -Json }   # devtools.py mr re-run: the open MR
  'mr.merge' = { param($a) $f = @{ squash = "$($a.method -eq 'squash')".ToLower(); should_remove_source_branch = "$((__Del $a))".ToLower() }; if ($a.sha) { $f.sha = $a.sha }; if ($a.auto) { $f.merge_when_pipeline_succeeds = 'true' }; __Gp $a "/merge_requests/$($a.n)/merge" 'PUT' $f }
  'mr.unauto' = { param($a) __Gp $a "/merge_requests/$($a.n)/cancel_merge_when_pipeline_succeeds" 'POST' }
  'mr.url' = { param($a) "https://$($KitConf.GitHost)/$($a.repo)/-/merge_requests/$($a.n)" }
  'repo.base' = { param($a) __Gp $a "/repository/merge_base?refs[]=$(__Enc $a.a)&refs[]=$(__Enc $a.b)" }
  'repo.commit' = { param($a) __Gp $a "/repository/commits/$(__Enc $a.ref)" }
  'repo.compare' = { param($a) __Gp $a "/repository/compare?from=$(__Enc $a.from)&to=$(__Enc $a.to)$(if ($a.straight) { '&straight=true' })" }
  # the kit origin (bossy.ps1 setup): ok | set | skip: no admin rights | failed: <why>; never loosens or overwrites a rule
  'branch.protect' = { param($a) $r = __Gp $a "/protected_branches/$(__Enc $a.branch)" -Res; $no = "skip: no admin rights on $($a.repo)"
    if (-not $r) { return 'failed: glab not found' }
    if (-not $r.code) { return $(if ((__HostJson $r.out).allow_force_push) { 'failed: protected but force push allowed: turn it off by hand' } else { 'ok' }) }
    $why = "$($r.out) $($r.err)".Trim(); if ($why -match '\b403\b') { return $no }; if ($why -notmatch '404 (Branch )?Not Found') { return "failed: $why" }
    $s = __Gp $a '/protected_branches' 'POST' @{ name = $a.branch; push_access_level = 40; merge_access_level = 40; allow_force_push = 'false' } -Res
    if (-not $s.code) { 'set' } elseif ("$($s.out) $($s.err)" -match '\b40[34]\b') { $no } else { "failed: $("$($s.out) $($s.err)".Trim())" } }
}
# ---- ci: pipelines
# adapter:ci/gitlab
Register-KitAdapter 'ci' 'gitlab' @{
  'runs' = { param($a) @(__Gp $a "/pipelines?ref=$(__Enc $a.ref)$(if ($a.sha) { "&sha=$($a.sha)" })&per_page=$($a.per_page ?? 20)") }
  'jobs' = { param($a) @(__Gp $a "/pipelines/$($a.id)/jobs?per_page=100") }
  'log' = { param($a) __Gp $a "/jobs/$($a.id)/trace" }
  'status' = { param($a) $p = @(__Gp $a "/pipelines?sha=$($a.sha)&per_page=1")[0]; if ($p.id) { __CiStat $p.id $p.status } }
  'config' = { param($a) $p = __Gp $a ''; if (-not $p.id) { return $null }; if ($p.only_allow_merge_if_pipeline_succeeds -or $p.ci_config_path -or $p.auto_devops_enabled) { return $true }
    $r = __Gp $a "/repository/files/.gitlab-ci.yml?ref=$(__Enc $a.ref)" -Res; if (-not $r.code) { $true } elseif ("$($r.out)$($r.err)" -match '\b404\b' -and "$($r.out)$($r.err)" -notmatch 'file_name') { $false } else { $null } }
}
# ---- tracker: GitLab issues
function __TrGl([string]$Method, [string]$Path, $Body) {
  __GlEnv
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
