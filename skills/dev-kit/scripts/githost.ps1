<#
Git-host adapter: one call for GitLab and GitHub, so kit scripts never call glab / gh themselves.
Dot-source it (kitconfig.ps1 is loaded with it):  . <kit>/skills/dev-kit/scripts/githost.ps1

  Invoke-HostApi '<GitLab REST path>' [-Method GET|PUT|POST] [-Fields @{ k = v }]
  Get-HostProject <repo>      # 'group/repo' (gitlabGroup / owner for short names), URL-encoded for the path

Paths are written in GitLab REST form (projects/<url-encoded group/repo>/...). GitLab: passed to `glab api` unchanged.
GitHub (`gitHostType` = github, or a gitHost naming github): the paths the kit uses are translated to `gh api` calls and the
answers reshaped to the GitLab fields the callers read:
  merge_requests/<n> (+ /changes, /merge PUT, /cancel_merge_when_pipeline_succeeds POST), merge_requests?<query>,
  repository/merge_base, repository/commits/<ref>, repository/compare, pipelines?ref=, pipelines/<id>/jobs, jobs/<id>/trace
An MR = { iid, title, state opened|merged|closed, source_branch, target_branch, sha, merge_commit_sha, squash_commit_sha,
merged_at, draft, has_conflicts, detailed_merge_status, merge_when_pipeline_succeeds, web_url, head_pipeline { status } }.
Unknown path on GitHub -> a warning and $null. A failed call -> $null (callers treat it as unknown, never as a state).
Tests: tests/test-githost.ps1 (mocked CLIs).
#>
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
$script:HostType = [string](Get-KitValue 'gitHostType' $(if ($KitConf.GitHost -match 'github') { 'github' } else { 'gitlab' }))
if ($script:HostType -eq 'gitlab' -and -not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
if ($script:HostType -eq 'github' -and -not $env:GH_HOST -and (Get-KitValue 'githubHost' 'github.com') -ne 'github.com') { $env:GH_HOST = [string](Get-KitValue 'githubHost' 'github.com') }

function Get-HostProject([string]$Repo, [switch]$Raw) {
  $p = if ($Repo -match '/') { $Repo } elseif ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$Repo" } else { $Repo }
  if ($Raw) { $p } else { [uri]::EscapeDataString($p) }
}
function __HostJson($out) { $t = (@($out) | ForEach-Object { "$_" }) -join "`n"; if (-not $t.Trim()) { return $null }; try { $t | ConvertFrom-Json } catch { $null } }
function __Gh([string[]]$A) { if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }; $o = & gh @A 2>$null; if ($LASTEXITCODE) { return $null }; $o }
function __GhApi([string]$Path) { __HostJson (__Gh @('api', $Path)) }
function __Query([string]$q) { $h = @{}; foreach ($kv in ($q -split '&' | Where-Object { $_ })) { $k, $v = $kv -split '=', 2; $h[[uri]::UnescapeDataString($k)] = [uri]::UnescapeDataString("$v") }; $h }
function __GhChecks([string]$Repo, [string]$Sha) {
  if (-not $Sha) { return $null }
  $runs = @((__GhApi "repos/$Repo/commits/$Sha/check-runs?per_page=100").check_runs)
  if (-not $runs.Count) { return $null }
  $st = if ($runs | Where-Object { $_.conclusion -in 'failure', 'timed_out', 'cancelled', 'action_required' }) { 'failed' } elseif ($runs | Where-Object { $_.status -ne 'completed' }) { 'running' } else { 'success' }
  [pscustomobject]@{ status = $st }
}
function __GhMr($pr, [string]$Repo, [switch]$NoChecks) {
  if (-not $pr -or -not $pr.number) { return $null }
  $state = if ($pr.merged_at -or $pr.merged) { 'merged' } elseif ($pr.state -eq 'open') { 'opened' } else { 'closed' }
  [pscustomobject]@{ iid = $pr.number; title = $pr.title; state = $state; source_branch = $pr.head.ref; target_branch = $pr.base.ref; sha = $pr.head.sha
    merge_commit_sha = $pr.merge_commit_sha; squash_commit_sha = $null; merged_at = $pr.merged_at; updated_at = $pr.updated_at; draft = [bool]$pr.draft
    has_conflicts = ($pr.mergeable -eq $false); detailed_merge_status = $(if ($pr.mergeable_state -eq 'dirty') { 'conflict' } else { [string]$pr.mergeable_state })
    merge_when_pipeline_succeeds = [bool]$pr.auto_merge; web_url = $pr.html_url; head_pipeline = $(if ($NoChecks -or $state -ne 'opened') { $null } else { __GhChecks $Repo $pr.head.sha }) }
}
function __Files($files) { @($files | ForEach-Object { [pscustomobject]@{ new_path = $_.filename; old_path = $(if ($_.previous_filename) { $_.previous_filename } else { $_.filename }) } }) }

function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}) {
  if ($script:HostType -ne 'github') {
    $a = @('api'); if ($Method -ne 'GET') { $a += @('-X', $Method) }; $a += $Path
    foreach ($k in $Fields.Keys) { $a += @('-f', "$k=$($Fields[$k])") }
    if (-not (Get-Command glab -ErrorAction SilentlyContinue)) { return $null }
    $o = & glab @a 2>$null; if ($LASTEXITCODE) { return $null }
    if ($Path -match '/trace$') { return ((@($o) | ForEach-Object { "$_" }) -join "`n") }
    return (__HostJson $o)
  }
  if ($Path -notmatch '^projects/(?<p>[^/]+)/(?<rest>.+)$') { Write-Warning "githost (github): no translation for $Path"; return $null }
  $repo = [uri]::UnescapeDataString($Matches.p); $rest = $Matches.rest
  $qs = if ($rest -match '\?(?<q>.*)$') { __Query $Matches.q } else { @{} }
  $rest = $rest -replace '\?.*$', ''
  switch -Regex ($rest) {
    '^merge_requests/(?<n>\d+)$' { return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo) }
    '^merge_requests/(?<n>\d+)/changes$' { return [pscustomobject]@{ changes = (__Files (__GhApi "repos/$repo/pulls/$($Matches.n)/files?per_page=100")) } }
    '^merge_requests/(?<n>\d+)/merge$' {
      $a = @('pr', 'merge', $Matches.n, '-R', $repo, '--squash', '--delete-branch'); if ("$($Fields.merge_when_pipeline_succeeds)" -eq 'true') { $a += '--auto' }
      $null = __Gh $a; return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo)
    }
    '^merge_requests/(?<n>\d+)/cancel_merge_when_pipeline_succeeds$' { $null = __Gh @('pr', 'merge', $Matches.n, '-R', $repo, '--disable-auto'); return (__GhMr (__GhApi "repos/$repo/pulls/$($Matches.n)") $repo -NoChecks) }
    '^merge_requests$' {
      $st = switch ("$($qs.state)") { 'opened' { 'open' } 'merged' { 'closed' } 'closed' { 'closed' } default { 'all' } }
      $prs = if ($qs.search) {
        $q = "repo:$repo is:pr $($qs.search) in:title$(if ($qs.state -eq 'merged') { ' is:merged' } elseif ($qs.state -eq 'opened') { ' is:open' })"
        @((__GhApi "search/issues?q=$([uri]::EscapeDataString($q))&per_page=50").items) | ForEach-Object { __GhApi "repos/$repo/pulls/$($_.number)" }
      } else { @(__GhApi "repos/$repo/pulls?state=$st&per_page=$(if ($qs.per_page) { $qs.per_page } else { 100 })$(if ($qs.target_branch) { "&base=$([uri]::EscapeDataString($qs.target_branch))" })") }
      $out = @($prs | ForEach-Object { __GhMr $_ $repo -NoChecks } | Where-Object { $_ })
      if ($qs.state -eq 'merged') { $out = @($out | Where-Object { $_.state -eq 'merged' }) }
      if ($qs.updated_after) { $out = @($out | Where-Object { $_.updated_at -and [datetimeoffset]$_.updated_at -ge [datetimeoffset]$qs.updated_after }) }
      return $out
    }
    '^repository/merge_base$' {
      $refs = @([regex]::Matches($Path, 'refs\[\]=([^&]+)') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) })
      if ($refs.Count -lt 2) { return $null }
      $c = __GhApi "repos/$repo/compare/$([uri]::EscapeDataString($refs[0]))...$([uri]::EscapeDataString($refs[1]))"
      return $(if ($c.merge_base_commit.sha) { [pscustomobject]@{ id = $c.merge_base_commit.sha } } else { $null })
    }
    '^repository/commits/(?<r>.+)$' { $c = __GhApi "repos/$repo/commits/$($Matches.r)"; return $(if ($c.sha) { [pscustomobject]@{ id = $c.sha; committed_date = $c.commit.committer.date } } else { $null }) }
    '^repository/compare$' {
      $c = __GhApi "repos/$repo/compare/$([uri]::EscapeDataString($qs.from))...$([uri]::EscapeDataString($qs.to))"
      return $(if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } else { $null })
    }
    '^pipelines$' {
      $r = __GhApi "repos/$repo/actions/runs?branch=$([uri]::EscapeDataString($qs.ref))&per_page=$(if ($qs.per_page) { $qs.per_page } else { 20 })"
      return @(@($r.workflow_runs) | ForEach-Object { [pscustomobject]@{ id = $_.id; sha = $_.head_sha; created_at = $_.created_at; updated_at = $_.updated_at; status = $(if ($_.conclusion) { if ($_.conclusion -eq 'failure') { 'failed' } else { $_.conclusion } } else { 'running' }) } })
    }
    '^pipelines/(?<id>\d+)/jobs$' {
      $r = __GhApi "repos/$repo/actions/runs/$($Matches.id)/jobs?per_page=100"
      return @(@($r.jobs) | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; status = $(if ($_.conclusion) { if ($_.conclusion -eq 'failure') { 'failed' } else { $_.conclusion } } else { 'running' }); finished_at = $_.completed_at } })
    }
    '^jobs/(?<id>\d+)/trace$' { return ((@(__Gh @('api', "repos/$repo/actions/jobs/$($Matches.id)/logs")) | ForEach-Object { "$_" }) -join "`n") }
    default { Write-Warning "githost (github): no translation for $Path"; return $null }
  }
}
