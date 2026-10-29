#Requires -Version 7
# github (goody): GitHub / GitHub Enterprise as git host (gh), CI (Actions, check runs, commit statuses) and tracker (issues).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/; uses its shared helpers (__Cli, __Mr, __GhMr, __Files, __Ci*, __Tr*).
# Sections: L5 gh · L16 tracker · L61 git-host · L96 ci
# ---- gh: host, env, CLI and API calls
function __GhHost { [string](Get-KitValue 'githubHost' $(if ($script:HostType -eq 'github' -and $KitConf.GitHost -notmatch 'gitlab') { $KitConf.GitHost } else { 'github.com' })) }   # GHE: the origin host
# gh reads GH_HOST: a GitHub Enterprise origin sets it before the first call
function __GhEnv { if ($script:HostType -eq 'github' -and -not $env:GH_HOST -and (__GhHost) -ne 'github.com') { $env:GH_HOST = [string](__GhHost) } }
function __GhCli([string[]]$A) { __GhEnv; __TrCli 'gh' $A }
function __GhApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$Json) { __GhEnv; __Cli gh $Path $Method $Fields -Json:$Json }
function __Gh([string[]]$A) { __GhEnv; $r = Invoke-KitRetry { Invoke-KitExe gh $A (Get-KitNetTimeout) } -Connect; if ($r.code) { Write-Warning "githost: gh $($A[0..1] -join ' ') failed: $($r.err)" }; $r }
function __TrGhBody([string[]]$A, [string]$Text) {
  if ($__trDry) { return (__GhCli ($A + @('--body', $Text))) }
  $f = __TrTemp $Text; try { __GhCli ($A + @('--body-file', $f)) } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
# ---- tracker: GitHub issues
# adapter:tracker/github: gh CLI; status = a <tracker.statusLabelPrefix><name> label (closed = closed issue)
Register-KitAdapter 'tracker' 'github' @{
  'url' = { param($a) $r, $n = __TrRef $a.id; "https://$(__GhHost)/$r/issues/$n" }
  'view' = { param($a)
    $r, $n = __TrRef $a.id
    $j = __TrJson (__GhCli @('issue', 'view', $n, '-R', $r, '--json', 'number,title,state,url,labels,assignees,body')); if (-not $j.number) { return }
    __TrIssue $j.number $j.title (__TrLabelStatus @($j.labels.name) ($j.state -eq 'CLOSED')) $j.url @($j.assignees.login) $r ([string]$j.body) {
      $s = __TrJson (__GhCli @('issue', 'view', $_, '-R', $r, '--json', 'number,title,state,labels'))
      __TrSub "$_" $s.title (__TrLabelStatus @($s.labels.name) ($s.state -eq 'CLOSED')) (Get-TrackerUrl $_) }
  }
  'status' = { param($a)
    $r, $n = __TrRef $a.id; $name = $a.status
    $j = __TrJson (__GhCli @('issue', 'view', $n, '-R', $r, '--json', 'state,labels'))
    $old = @($j.labels.name | Where-Object { $_ -like "$__trLp*" -and $_ -ne "$__trLp$name" })
    $edit = @('issue', 'edit', $n, '-R', $r); foreach ($o in $old) { $edit += @('--remove-label', $o) }
    if (__TrIsClosed $name) { if ($old) { $null = __GhCli $edit }; return (__GhCli @('issue', 'close', $n, '-R', $r)) }
    if ($j.state -eq 'CLOSED') { $null = __GhCli @('issue', 'reopen', $n, '-R', $r) }
    $null = __GhCli @('label', 'create', "$__trLp$name", '-R', $r, '--force', '--color', 'ededed')
    __GhCli ($edit + @('--add-label', "$__trLp$name"))
  }
  'comment' = { param($a) $r, $n = __TrRef $a.id; __TrGhBody @('issue', 'comment', $n, '-R', $r) $a.text }
  'comments' = { param($a) $r, $n = __TrRef $a.id; @((__TrJson (__GhCli @('issue', 'view', $n, '-R', $r, '--json', 'comments'))).comments) | Where-Object { $_ } | ForEach-Object { __TrComment $_.author.login $_.createdAt $_.body } }
  'create' = { param($a)
    $r = __TrRepoOf $a.list; $c = @('issue', 'create', '-R', $r, '--title', $a.name)
    if ($a.assignee) { $c += @('--assignee', $a.assignee) }
    if ($a.priority) { $pl = "priority:$(__TrPrio $a.priority)"; $null = __GhCli @('label', 'create', $pl, '-R', $r, '--force', '--color', 'ededed'); $c += @('--label', $pl) }
    $out = __TrGhBody $c ((__TrPartOf $a) + $a.description)
    $num = if ("$out" -match '/issues/(\d+)') { $Matches[1] } elseif ($__trDry) { '<new>' } else { return }
    if ($a.parent) {   # task-list line = subtask
      $pn = $a.parent -replace '^.*#', ''
      $null = __TrGhBody @('issue', 'edit', $pn, '-R', $r) (([string](__TrJson (__GhCli @('issue', 'view', $pn, '-R', $r, '--json', 'body'))).body).TrimEnd() + "`n- [ ] #$num")
    }
    [pscustomobject]@{ id = "$num"; url = $(if ("$out" -match '(https://\S+/issues/\d+)') { $Matches[1] } else { Get-TrackerUrl "$r#$num" }) }
  }
  'describe' = { param($a) $r, $n = __TrRef $a.id; __TrGhBody @('issue', 'edit', $n, '-R', $r) $a.text }
  'rename' = { param($a) $r, $n = __TrRef $a.id; __GhCli @('issue', 'edit', $n, '-R', $r, '--title', $a.name) }
  'attach' = { param($a) __TrAttachText $a }
  'list' = { param($a)
    $c = @('issue', 'list', '-R', (__TrRepoOf $a.list), '--limit', '200', '--json', 'number,title,assignees')
    $c += if (__TrIsClosed $a.status) { @('--state', 'closed') } else { @('--state', 'open', '--label', "$__trLp$($a.status)") }
    @(__TrJson (__GhCli $c)) | Where-Object { $_ -and $_.number } | ForEach-Object { __TrRow "$($_.number)" ([string]$_.title) $a.status @($_.assignees | ForEach-Object { __TrWho $_.login $_.login }) }
  }
  'owner' = { param($a) [string](__GhCli @('api', 'user', '--jq', '.login')) }
}
# ---- git-host: pull requests, repos, branch protection
# adapter:git-host/github: gh (GH_HOST = githubHost); fork PR source = owner:branch
function __GhPr($a) { __GhMr (__GhApi "repos/$($a.repo)/pulls/$($a.n)") }
Register-KitAdapter 'git-host' 'github' @{
  'mr.get' = { param($a) __GhPr $a }
  'mr.list' = { param($a)
    $st = switch ("$($a.state)") { 'opened' { 'open' } { $_ -in 'merged', 'closed' } { 'closed' } default { 'all' } }
    $prs = if ($a.search) {
      $q = "repo:$($a.repo) is:pr $($a.search) in:title$(if ($a.state -eq 'merged') { ' is:merged' } elseif ($a.state -eq 'opened') { ' is:open' })"
      @((__GhApi "search/issues?q=$(__Enc $q)&per_page=50").items) | ForEach-Object { __GhApi "repos/$($a.repo)/pulls/$($_.number)" }
    } else { @(__GhApi "repos/$($a.repo)/pulls?state=$st&per_page=$($a.per_page ?? 100)$(if ($a.target_branch) { "&base=$(__Enc $a.target_branch)" })$(if ("$($a.source_branch)" -match ':') { "&head=$(__Enc $a.source_branch)" })") }
    @($prs | ForEach-Object { __GhMr $_ } | Where-Object { $_ -and ($a.state -ne 'merged' -or $_.state -eq 'merged') -and (-not $a.source_branch -or "$($a.source_branch)" -match ':' -or $_.source_branch -eq $a.source_branch) -and
        (-not $a.updated_after -or ($_.updated_at -and [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after)) })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = (__Files (__GhApi "repos/$($a.repo)/pulls/$($a.n)/files?per_page=100")) } }
  'mr.create' = { param($a) __GhMr (__GhApi "repos/$($a.repo)/pulls" 'POST' @{ head = $a.source; base = $a.target; title = $a.title; body = $a.body } -Json) }
  'mr.update' = { param($a) __GhMr (__GhApi "repos/$($a.repo)/pulls/$($a.n)" 'PATCH' @{ title = $a.title; body = $a.body } -Json) }   # devtools.py mr re-run: the open PR
  'mr.merge' = { param($a)
    $x = @('pr', 'merge', $a.n, '-R', $a.repo, "--$(if ($a.method -in 'merge', 'rebase') { $a.method } else { 'squash' })"); if (__Del $a) { $x += '--delete-branch' }; if ($a.sha) { $x += @('--match-head-commit', $a.sha) }
    if (-not $a.auto -or ("$((__Gh ($x + '--auto')).err)" -match 'clean status' -and (Invoke-HostVerb 'ci.status' @{ repo = $a.repo; sha = $(if ($a.sha) { $a.sha } else { (__GhPr $a).sha }) } -NoMemo).status -eq 'success')) { $null = __Gh $x }
    __GhPr $a
  }
  'mr.unauto' = { param($a) $null = __Gh @('pr', 'merge', $a.n, '-R', $a.repo, '--disable-auto'); __GhPr $a }
  'mr.url' = { param($a) "https://$(__GhHost)/$($a.repo)/pull/$($a.n)" }
  'repo.base' = { param($a) $c = __GhApi "repos/$($a.repo)/compare/$(__Enc $a.a)...$(__Enc $a.b)"; __CommitObj $c.merge_base_commit.sha }
  'repo.commit' = { param($a) $c = __GhApi "repos/$($a.repo)/commits/$(__Enc $a.ref)"; __CommitObj $c.sha $c.commit.committer.date }
  'repo.compare' = { param($a) $c = __GhApi "repos/$($a.repo)/compare/$(__Enc $a.from)...$(__Enc $a.to)"; if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } }
  # the kit origin (bossy.ps1 setup): ok | set | skip: no admin rights | failed: <why>; never loosens or overwrites a rule
  'branch.protect' = { param($a) __GhEnv; $p = "repos/$($a.repo)/branches/$(__Enc $a.branch)/protection"; $r = __Cli gh $p -Res; $no = "skip: no admin rights on $($a.repo)"
    if (-not $r) { return 'failed: gh not found' }
    if (-not $r.code) { $g = __HostJson $r.out; return $(if ($g.allow_force_pushes.enabled -or $g.allow_deletions.enabled) { 'failed: protected but force push or deletion allowed: turn them off by hand' } else { 'ok' }) }
    $why = "$($r.err)".Trim(); if ($why -notmatch 'Branch not protected') { return $(if ($why -match 'HTTP 40[34]') { $no } else { "failed: $why" }) }
    $s = __Cli gh $p 'PUT' @{ required_status_checks = $null; enforce_admins = $true; required_pull_request_reviews = $null; restrictions = $null; allow_force_pushes = $false; allow_deletions = $false } -Json -Res
    if (-not $s.code) { 'set' } elseif ("$($s.err)" -match 'HTTP 40[34]') { $no } else { "failed: $("$($s.err)".Trim())" } }
}
# ---- ci: Actions runs, check runs, statuses
# adapter:ci/github: Actions runs, check runs + commit statuses (external CI)
Register-KitAdapter 'ci' 'github' @{
  'runs' = { param($a) @(@((__GhApi "repos/$($a.repo)/actions/runs?branch=$(__Enc $a.ref)$(if ($a.sha) { "&head_sha=$($a.sha)" })&per_page=$($a.per_page ?? 20)").workflow_runs) | Where-Object { $_ } | ForEach-Object { __CiRun $_.id $_.head_sha (__CiWord ($_.conclusion ?? $_.status)) $_.created_at $_.updated_at }) }
  'jobs' = { param($a) @(@((__GhApi "repos/$($a.repo)/actions/runs/$($a.id)/jobs?per_page=100").jobs) | Where-Object { $_ } | ForEach-Object { __CiJob $_.id $_.name (__CiWord ($_.conclusion ?? $_.status)) $_.completed_at }) }
  'log' = { param($a) __GhApi "repos/$($a.repo)/actions/jobs/$($a.id)/logs" }
  'status' = { param($a) if (-not $a.sha) { return $null }
    $cr = @((__GhApi "repos/$($a.repo)/commits/$($a.sha)/check-runs?per_page=100").check_runs | Where-Object { $_ }); $cs = @((__GhApi "repos/$($a.repo)/commits/$($a.sha)/status").statuses | Where-Object { $_ })
    $st = __CiRoll (@($cr | ForEach-Object { if ($_.status -ne 'completed') { 'running' } else { __CiWord $_.conclusion } }) + @($cs | ForEach-Object { __CiWord $_.state })); if (-not $st) { return $null }
    __CiStat @($cr | ForEach-Object { if ("$($_.details_url)" -match '/runs/(\d+)') { $Matches[1] } })[0] $st }
  'config' = { param($a) __GhEnv; $r = __Cli gh "repos/$($a.repo)/contents/.github/workflows?ref=$(__Enc $a.ref)" -Res; if ($null -eq $r) { $null } elseif (-not $r.code) { $true } elseif ("$($r.out)$($r.err)" -match '\b404\b|Not Found') { $false } else { $null } }
}
