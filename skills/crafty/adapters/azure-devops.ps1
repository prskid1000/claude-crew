#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# azure-devops: Azure DevOps Repos git host + Azure Pipelines CI (gitHostType / ci azure).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ when config selects azure; helpers come from lib.ps1.
# Sections: L6 helpers · L14 git-host · L67 ci
# ---- helpers: only this adapter uses them (kept out of the core lib.ps1)
function __DiffFile($New, $Old = $null) { [pscustomobject]@{ new_path = "$New"; old_path = "$(if ($Old) { $Old } else { $New })" } }
function __ProtectFail([string]$Repo) { if ($global:KitHttpCode -eq 403) { "skip: no admin rights on $Repo" } else { "failed: http $(if ($global:KitHttpCode) { $global:KitHttpCode } else { 'no answer' })" } }   # branch.protect: the failed call's status (Invoke-KitHttp)
function __Rest([string]$Base, [string]$Env, [string]$Auth, [string]$Method, [string]$Path, $Body, [switch]$Probe) {
  $u = "$(__HostSet 'url' $Base)/$Path"; $h = Get-KitAuth ([string](__HostSet 'tokenEnv' $Env)) $(if ($Auth -eq 'auto') { if ("$([Environment]::GetEnvironmentVariable([string](__HostSet 'tokenEnv' $Env)))" -match ':') { 'basic' } else { 'bearer' } } else { $Auth })
  if (-not $Probe) { return (Invoke-KitHttp $Method $u $Body $h) }
  try { $null = Invoke-RestMethod -Method $Method -Uri $u -Headers $h -ConnectionTimeoutSeconds (Get-KitNetTimeout); $true } catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { $false } else { $null } }
}
# ---- git-host: pull requests, repository, branch protection
# adapter:git-host/azure: Azure DevOps Repos REST 7.1; repo = org/project/repo; env AZURE_DEVOPS_EXT_PAT (basic); auto-complete = merge-when-green
function __Az([string]$Repo, [string]$Path, [string]$Method = 'GET', $Body) {
  $o, $p, $r = "$Repo" -split '/', 3
  $u = "$o/$(if ($Path -notlike '/*') { "$p/" })_apis/$($Path.TrimStart('/') -replace '\{repo\}', (__Enc $r))"
  __Rest 'https://dev.azure.com' 'AZURE_DEVOPS_EXT_PAT' 'basic' $Method "$u$(if ($u -match '\?') { '&' } else { '?' })api-version=7.1" $Body
}
function __AzSha([string]$Repo, [string]$Ref) { if ($Ref -match '^[0-9a-f]{40}$') { $Ref } else { @((__Az $Repo "git/repositories/{repo}/refs?filter=heads/$(__Enc $Ref)").value)[0].objectId } }
function __AzMr($p) {
  if (-not $p.pullRequestId) { return $null }
  __Mr @{ iid = $p.pullRequestId; title = $p.title; state = $(switch ($p.status) { 'active' { 'opened' } 'completed' { 'merged' } default { 'closed' } }); source_branch = $p.sourceRefName -replace '^refs/heads/'
    target_branch = $p.targetRefName -replace '^refs/heads/'; sha = $p.lastMergeSourceCommit.commitId; merge_commit_sha = $p.lastMergeCommit.commitId; merged_at = $(if ($p.status -eq 'completed') { $p.closedDate })
    updated_at = $(if ($p.closedDate) { $p.closedDate } else { $p.creationDate }); draft = [bool]$p.isDraft; has_conflicts = $p.mergeStatus -eq 'conflicts'; detailed_merge_status = $(if ($p.mergeStatus -eq 'conflicts') { 'conflict' } else { [string]$p.mergeStatus })
    merge_when_pipeline_succeeds = [bool]$p.autoCompleteSetBy; web_url = "$($p.repository.webUrl)/pullrequest/$($p.pullRequestId)"; author = [string]$p.createdBy.uniqueName; description = [string]$p.description }
}
Register-KitAdapter 'git-host' 'azure' @{
  'mr.get' = { param($a) __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)") }
  'mr.list' = { param($a)
    $q = "searchCriteria.status=$(@{ opened = 'active'; merged = 'completed'; closed = 'abandoned' }["$($a.state)"] ?? 'all')&`$top=$($a.per_page ?? 100)$(if ($a.source_branch) { "&searchCriteria.sourceRefName=refs/heads/$(__Enc $a.source_branch)" })$(if ($a.target_branch) { "&searchCriteria.targetRefName=refs/heads/$(__Enc $a.target_branch)" })"
    @((__Az $a.repo "git/repositories/{repo}/pullrequests?$q").value | ForEach-Object { __AzMr $_ } | Where-Object { (-not $a.search -or $_.title -like "*$($a.search)*") -and (-not $a.updated_after -or [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after) -and (-not $a.author_username -or $_.author -eq $a.author_username) })
  }
  'mr.update' = { param($a) __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)" 'PATCH' @{ title = $a.title; description = $a.body }) }   # devtools.py mr re-run: the open PR
  'mr.changes' = { param($a) $it = @((__Az $a.repo "git/repositories/{repo}/pullRequests/$($a.n)/iterations").value)[-1].id
    [pscustomobject]@{ changes = @((__Az $a.repo "git/repositories/{repo}/pullRequests/$($a.n)/iterations/$it/changes").changeEntries | ForEach-Object { [pscustomobject]@{ new_path = "$($_.item.path)".TrimStart('/'); old_path = "$(if ($_.originalPath) { $_.originalPath } else { $_.item.path })".TrimStart('/') } }) } }
  'mr.create' = { param($a) __AzMr (__Az $a.repo 'git/repositories/{repo}/pullrequests' 'POST' @{ sourceRefName = "refs/heads/$($a.source)"; targetRefName = "refs/heads/$($a.target)"; title = $a.title; description = $a.body }) }
  'mr.labels' = { param($a) foreach ($l in @($a.labels)) { $null = __Az $a.repo "git/repositories/{repo}/pullRequests/$($a.n)/labels" 'POST' @{ name = $l } }; [pscustomobject]@{ labels = @($a.labels) } }   # devtools.py mr_labels
  'mr.merge' = { param($a)
    $sha = if ($a.sha) { $a.sha } else { (__AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)")).sha }
    $b = @{ completionOptions = @{ mergeStrategy = @{ merge = 'noFastForward'; rebase = 'rebase' }["$($a.method)"] ?? 'squash'; deleteSourceBranch = (__Del $a) } }
    if ($a.auto) { $b.autoCompleteSetBy = @{ id = (__Az $a.repo '/connectionData').authenticatedUser.id } } else { $b.status = 'completed'; $b.lastMergeSourceCommit = @{ commitId = $sha } }
    __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)" 'PATCH' $b)
  }
  'mr.unauto' = { param($a) __AzMr (__Az $a.repo "git/repositories/{repo}/pullrequests/$($a.n)" 'PATCH' @{ autoCompleteSetBy = @{ id = '00000000-0000-0000-0000-000000000000' } }) }
  'mr.url' = { param($a) $o, $p, $r = "$($a.repo)" -split '/', 3; "$(__HostSet 'url' 'https://dev.azure.com')/$o/$p/_git/$r/pullrequest/$($a.n)" }
  # the token's user (uniqueName = a PR's createdBy.uniqueName); no repo given: the first configured repo names the organization
  'whoami' = { param($a) $rr = if ($a.repo) { $a.repo } else { Get-HostProject "$(@(@(Get-KitValue 'repos' @()).name | Where-Object { $_ })[0])" -Raw }
    $u = (__Az $rr '/connectionData').authenticatedUser; $ac = [regex]::Match(($u | ConvertTo-Json -Depth 4 -Compress), '"Account":\{[^}]*"\$value":"([^"]+)"').Groups[1].Value; [string]$(if ($ac) { $ac } else { $u.providerDisplayName }) }
  'repo.base' = { param($a) $c = @((__Az $a.repo "git/repositories/{repo}/commits/$(__AzSha $a.repo $a.a)/mergebases?otherCommitId=$(__AzSha $a.repo $a.b)").value)[0]; __CommitObj $c.commitId }
  'repo.commit' = { param($a) $s = __AzSha $a.repo $a.ref; $c = if ($s) { __Az $a.repo "git/repositories/{repo}/commits/$s" }; __CommitObj $c.commitId $c.committer.date }
  'repo.compare' = { param($a) $t = { param($r) if ($r -match '^[0-9a-f]{40}$') { 'commit' } else { 'branch' } }
    $c = __Az $a.repo "git/repositories/{repo}/diffs/commits?baseVersion=$(__Enc $a.from)&baseVersionType=$(& $t $a.from)&targetVersion=$(__Enc $a.to)&targetVersionType=$(& $t $a.to)"
    if ($c) { [pscustomobject]@{ diffs = @($c.changes | Where-Object { $_.item.gitObjectType -ne 'tree' } | ForEach-Object { __DiffFile "$($_.item.path)".TrimStart('/') "$(if ($_.sourceServerItem) { $_.sourceServerItem } else { $_.item.path })".TrimStart('/') }) } } }
  # the kit origin (bossy.ps1 setup): deny ForcePush (bit 8: rewrite and delete) on the branch to [project]\Contributors (Git
  # Repositories security namespace); pushes stay open; ok when any deny of it is set; never loosens one
  'branch.protect' = { param($a) $o, $p, $r = "$($a.repo)" -split '/', 3; $ns = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'
    $rp = __Az $a.repo 'git/repositories/{repo}'; if (-not $rp.id) { return (__ProtectFail $a.repo) }
    $tok = "repoV2/$($rp.project.id)/$($rp.id)/refs/heads/$(@("$($a.branch)" -split '/' | ForEach-Object { [Convert]::ToHexString([Text.Encoding]::Unicode.GetBytes($_)).ToLower() }) -join '/')"
    $acl = __Az $a.repo "/accesscontrollists/$ns`?token=$(__Enc $tok)"; if ($null -eq $acl) { return (__ProtectFail $a.repo) }
    if (@([regex]::Matches(($acl | ConvertTo-Json -Depth 6 -Compress), '"deny":(\d+)') | Where-Object { [int]$_.Groups[1].Value -band 8 }).Count) { return 'ok' }   # acesDictionary: descriptor -> { allow, deny }
    $id = @((__Rest 'https://vssps.dev.azure.com' 'AZURE_DEVOPS_EXT_PAT' 'basic' 'GET' "$o/_apis/identities?searchFilter=General&filterValue=$(__Enc "[$p]\Contributors")&queryMembership=None&api-version=7.1" $null).value)[0]
    if (-not $id.descriptor) { return (__ProtectFail $a.repo) }
    if ($null -eq (__Az $a.repo "/accesscontrolentries/$ns" 'POST' @{ token = $tok; merge = $true; accessControlEntries = @(@{ descriptor = $id.descriptor; allow = 0; deny = 8 }) })) { return (__ProtectFail $a.repo) }
    'set' }
}
# ---- ci: runs, jobs, logs, status, URLs
# adapter:ci/azure: Azure Pipelines builds (job id = <build id>/<log id>)
Register-KitAdapter 'ci' 'azure' @{
  'runs' = { param($a) $rid = (__Az $a.repo 'git/repositories/{repo}').id
    @(@((__Az $a.repo "build/builds?repositoryId=$rid&repositoryType=TfsGit&branchName=refs/heads/$(__Enc $a.ref)&`$top=$($a.per_page ?? 20)").value) | Where-Object { $_ } | ForEach-Object { __CiRun $_.id $_.sourceVersion (__CiWord $(if ($_.status -eq 'completed') { $_.result } else { $_.status })) $_.queueTime $(if ($_.finishTime) { $_.finishTime } else { $_.queueTime }) } | Where-Object { -not $a.sha -or $_.sha -eq $a.sha }) }
  'jobs' = { param($a) @(@((__Az $a.repo "build/builds/$($a.id)/timeline").records) | Where-Object { $_ -and $_.type -eq 'Job' } | ForEach-Object { __CiJob "$($a.id)/$($_.log.id)" $_.name (__CiWord $(if ($_.state -eq 'completed') { $_.result } else { $_.state })) $_.finishTime }) }
  'log' = { param($a) $b, $l = "$($a.id)" -split '/', 2; __Az $a.repo "build/builds/$b/logs/$l" }
  # .../_build/results?buildId=<n>[&j=<job record id>] in a text -> @{ url; run = n; job = <n>/<that record's log id> (timeline) }
  'parseUrl' = { param($a) $m = [regex]::Match("$($a.text)", '(?<url>https?://[^\s)\]]+?/(?<op>[^/\s]+/[^/\s]+)/_build/results\?[^\s)\]]*?buildId=(?<n>\d+)[^\s)\]]*)'); if (-not $m.Success) { return @{} }
    $n = $m.Groups['n'].Value; $j = [regex]::Match($m.Groups['url'].Value, '[?&]j=(?<j>[0-9a-fA-F-]{36})').Groups['j'].Value
    $lg = if ($j) { @(@((__Az "$($m.Groups['op'].Value)/_" "build/builds/$n/timeline").records) | Where-Object { $_.id -eq $j })[0].log.id }
    @{ url = $m.Groups['url'].Value; run = $n; job = $(if ($lg) { "$n/$lg" } else { '' }) } }
  'status' = { param($a) $b = if ($a.n) { @((__Az $a.repo "build/builds?branchName=refs/pull/$($a.n)/merge&`$top=1").value)[0] }
    if ($b.id) { return __CiStat $b.id (__CiWord $(if ($b.status -eq 'completed') { $b.result } else { $b.status })) }
    if ($a.sha) { $st = __CiRoll @(@((__Az $a.repo "git/repositories/{repo}/commits/$($a.sha)/statuses").value) | Where-Object { $_ } | ForEach-Object { __CiWord $_.state }); if ($st) { __CiStat $null $st } } }
  'config' = { param($a) $d = __Az $a.repo "build/definitions?repositoryId=$((__Az $a.repo 'git/repositories/{repo}').id)&repositoryType=TfsGit"; if ($null -eq $d) { $null } else { [bool]$d.count } }
}
