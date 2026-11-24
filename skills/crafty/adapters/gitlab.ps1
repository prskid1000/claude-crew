#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# gitlab: GitLab / self-hosted GitLab through the glab CLI: git host (MRs, merge, auto-merge, branch.protect), CI
# (pipelines, jobs, logs) and tracker (issues; status = a <tracker.statusLabelPrefix><name> label, closed = closed issue).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/; uses its shared helpers (__Cli, __Enc, __Del, __CiStat, __Tr*).
# Sections: L7 glab · L13 git-host · L40 ci · L55 tracker
# ---- glab: host and API calls
# glab reads GITLAB_HOST: a self-hosted GitLab (git host or tracker) sets it before the first call
function __GlEnv { if (-not $env:GITLAB_HOST -and $KitConf.GitHost -and $KitConf.GitHost -ne 'gitlab.com' -and ($script:HostType -eq 'gitlab' -or $script:__trType -eq 'gitlab')) { $env:GITLAB_HOST = $KitConf.GitHost } }
function __Gp($a, [string]$Rest, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json, [switch]$Res) { __GlEnv; __Cli glab "projects/$(__Enc $a.repo)$Rest" $Method $Fields -Json:$Json -Res:$Res }
# a job's failure_reason -> the kit's reason: script | timeout | infra | canceled | unknown ('' when it did not fail)
function __GlReason([string]$R) { switch -Regex ($R) { '^$' { '' } '^script_failure$' { 'script' } 'timeout' { 'timeout' } '^(runner_|ci_quota|api_|scheduler_|data_integrity|archived_|unmet_prereq|missing_dependency|stale_schedule|no_matching_runner|environment_creation|deployment_rejected|stuck)' { 'infra' } 'cancel' { 'canceled' } default { 'unknown' } } }
# ---- git-host: merge requests, repository, branch protection
# adapter:git-host/gitlab: glab api
Register-KitAdapter 'git-host' 'gitlab' @{
  'mr.get' = { param($a) __Gp $a "/merge_requests/$($a.n)" }
  'mr.list' = { param($a) $q = @{} + $a; if ($q.searchIn) { $q['in'] = $q.searchIn }; $q.Remove('searchIn')   # searchIn: title | title,source_branch (GitLab in=)
    @(__Gp $a "/merge_requests?$(($q.Keys | Where-Object { $_ -notin 'repo', 'type' } | Sort-Object | ForEach-Object { "$_=$(__Enc $q[$_])" }) -join '&')") }
  'mr.changes' = { param($a) __Gp $a "/merge_requests/$($a.n)/changes" }
  'mr.create' = { param($a) __Gp $a "/merge_requests" 'POST' @{ source_branch = $a.source; target_branch = $a.target; title = $a.title; description = $a.body; remove_source_branch = (__Del $a); squash = $a.method -eq 'squash' } -Json }
  'mr.update' = { param($a) __Gp $a "/merge_requests/$($a.n)" 'PUT' @{ title = $a.title; description = $a.body } -Json }   # devtools.py mr re-run: the open MR
  'mr.labels' = { param($a) $null = __Gp $a "/merge_requests/$($a.n)" 'PUT' @{ add_labels = (@($a.labels) -join ',') } -Json; [pscustomobject]@{ labels = @($a.labels) } }   # devtools.py mr_labels: the task's tags
  'mr.merge' = { param($a) $f = @{ squash = "$($a.method -eq 'squash')".ToLower(); should_remove_source_branch = "$((__Del $a))".ToLower() }; if ($a.sha) { $f.sha = $a.sha }; if ($a.auto) { $f.merge_when_pipeline_succeeds = 'true' }; __Gp $a "/merge_requests/$($a.n)/merge" 'PUT' $f }
  'mr.unauto' = { param($a) __Gp $a "/merge_requests/$($a.n)/cancel_merge_when_pipeline_succeeds" 'POST' }
  'mr.url' = { param($a) "https://$($KitConf.GitHost)/$($a.repo)/-/merge_requests/$($a.n)" }
  # GitLab references (docs.gitlab.com/user/markdown/#gitlab-specific-references): !<n> = an MR of $a.repo; URLs, [group/]project!<n>: core
  'mr.parseRef' = { param($a) ConvertFrom-KitMrShortRef $a '^!(?<n>\d+)$' 'gitlab' }
  'whoami' = { param($a) __GlEnv; [string](__Cli glab 'user').username }
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
  'jobs' = { param($a) @(__Gp $a "/pipelines/$($a.id)/jobs?per_page=100" | Where-Object { $_ } | ForEach-Object { $_ | Add-Member -Force NoteProperty reason (__GlReason "$($_.failure_reason)") -PassThru }) }
  # failed jobs only, server-side (docs.gitlab.com/api/jobs/#list-pipeline-jobs scope[]=failed: no 100-job page miss); allowed failures last
  'failure' = { param($a) $j = @(@(__Gp $a "/pipelines/$($a.id)/jobs?scope[]=failed&per_page=100") | Where-Object { $_ } | Sort-Object -Stable { [bool]$_.allow_failure })[0]
    if ($j) { Get-KitCiFailure $a -Job ($j | Add-Member -Force NoteProperty reason (__GlReason "$($j.failure_reason)") -PassThru) } }
  'log' = { param($a) $l = __Gp $a "/jobs/$($a.id)/trace"; if ($null -eq $l) { return $null }; ((@($l) -join "`n") -split "`n" | ForEach-Object { $_ -replace '^\S+Z \d+O ', '' }) -join "`n" }   # runner timestamp prefix off
  # https://<host>/<path>/-/jobs/<id> and /-/pipelines/<id> in a text (a CI-raised task) -> @{ url; job; run }
  'parseUrl' = { param($a) $j = [regex]::Match("$($a.text)", '(?<url>https?://[^\s)\]]+?/jobs/(?<id>\d+))'); $p = [regex]::Match("$($a.text)", '/pipelines/(?<id>\d+)'); @{ url = $j.Groups['url'].Value; job = $j.Groups['id'].Value; run = $p.Groups['id'].Value } }
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
    Add-KitTags (__TrIssue $j.iid $j.title (__TrLabelStatus @($j.labels) ($j.state -eq 'closed')) $j.web_url @($j.assignees.username) (__TrRef $a.id)[0] ([string]$j.description) {
      $s = __TrGl 'GET' (__TrGlPath $_) $null; Add-KitTags (__TrSub "$_" $s.title (__TrLabelStatus @($s.labels) ($s.state -eq 'closed')) $s.web_url) @($s.labels) }) @($j.labels)
  }
  'status' = { param($a)
    $p = __TrGlPath $a.id; $name = $a.status; $j = __TrGl 'GET' $p $null
    $old = @($j.labels | Where-Object { $_ -like "$__trLp*" -and $_ -ne "$__trLp$name" })
    $b = @{}; if ($old) { $b.remove_labels = $old -join ',' }
    if (__TrIsClosed $name) { $b.state_event = 'close' } else { $b.add_labels = "$__trLp$name"; if ($j.state -eq 'closed') { $b.state_event = 'reopen' } }
    $res = __TrGl 'PUT' $p $b; if ($res) { "status of #$($res.iid): $name" }
  }
  'statuses' = { param($a) __TrLabelLive @(__TrGl 'GET' "projects/$([uri]::EscapeDataString($a.scope))/labels?per_page=100" $null).name }   # as on github
  'comment' = { param($a) $res = __TrGl 'POST' (__TrGlPath $a.id '/notes') @{ body = $a.text }; if ($res) { "commented on #$((__TrRef $a.id)[1])" } }
  # GitLab's checklist is a task list in the issue description (docs.gitlab.com/user/markdown/#task-lists)
  'checklist' = { param($a) Set-KitDescChecklist $a.id $a.name $a.items -KeepDone:([bool]$a.keepDone) }
  'comments' = { param($a) @(__TrGl 'GET' (__TrGlPath $a.id '/notes?sort=asc&per_page=100') $null) | Where-Object { $_ -and -not $_.system } | ForEach-Object { __TrComment $_.author.username $_.created_at $_.body $_.id } }
  'comment-edit' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id "/notes/$($a.comment)") @{ body = $a.text }; "edited comment $($a.comment)" }   # lib.ps1 Set-TrackerKitComment
  'comment-delete' = { param($a) $null = __TrGl 'DELETE' (__TrGlPath $a.id "/notes/$($a.comment)") $null; "deleted comment $($a.comment)" }
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
  # move (K54): -List = the issue move API to that project; -Parent = a task-list line on the parent (as create); top: refused
  'move' = { param($a) $r, $n = __TrRef $a.id
    if ($a.top) { throw "tracker (gitlab) move: a subtask is a task-list line on its parent: remove '- [ ] #$n' there by hand" }
    if ($a.list -and $a.parent) { throw 'tracker (gitlab) move: -List and -Parent in two calls (the move gives a new number)' }
    if ($a.list) { $pid0 = (__TrGl 'GET' "projects/$([uri]::EscapeDataString((__TrRepoOf $a.list)))" $null).id; $t = __TrGl 'POST' (__TrGlPath $a.id '/move') @{ to_project_id = $pid0 }; return "moved #$n to $($a.list)$(if ($t.iid) { " as #$($t.iid)" })" }
    $pr = if ("$($a.parent)" -match '^(?<r>[^#]+)#\d+$') { $Matches.r } else { $r }; $ref = if ($pr -eq $r) { "#$n" } else { "$r#$n" }   # a parent in another project: its project
    $p = __TrGlPath "$pr#$($a.parent -replace '^.*#', '')"; $b = ([string](__TrGl 'GET' $p $null).description).TrimEnd()
    if ($b -notmatch "(?m)^- \[[ x]\] $([regex]::Escape($ref))\b") { $null = __TrGl 'PUT' $p @{ description = $b + "`n- [ ] $ref" } }; "moved #${n} under $($a.parent)" }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $q = if (__TrIsClosed $a.status) { 'state=closed' } else { "state=opened&labels=$([uri]::EscapeDataString("$__trLp$($a.status)"))" }
    @(__TrGl 'GET' "projects/$([uri]::EscapeDataString((__TrRepoOf $a.list)))/issues?$q&per_page=100" $null) | Where-Object { $_ -and $_.iid } | ForEach-Object { __TrRow "$($_.iid)" ([string]$_.title) $a.status @($_.assignees | ForEach-Object { __TrWho $_.id $_.username }) }
  }
  # waits on = an is_blocked_by issue link (blocking links: GitLab Premium; refused on Free -> the description line)
  'dependencies' = { param($a) $r, $n = __TrRef $a.id
    $have = @(@(__TrGl 'GET' (__TrGlPath $a.id '/links') $null) | Where-Object { "$($_.link_type)" -eq 'is_blocked_by' } | ForEach-Object { "$($_.iid)" })
    foreach ($on in @($a.on | ForEach-Object { "$_" -replace '^.*#' } | Where-Object { $_ -and $_ -notin $have })) { $null = __TrGl 'POST' (__TrGlPath $a.id '/links') @{ target_project_id = $r; target_issue_iid = $on; link_type = 'is_blocked_by' }; $have += $on }
    $have }
  'labels' = { param($a) $null = __TrGl 'PUT' (__TrGlPath $a.id) @{ add_labels = (@($a.add) -join ','); remove_labels = (@($a.remove) -join ',') } }
  'owner' = { param($a) [string](__TrGl 'GET' 'user' $null).username }
}
