#Requires -Version 7
# Goody gitea: Gitea / Forgejo git host + Gitea Actions CI (gitHostType / ci gitea).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ (kitbag.py goody add gitea); helpers come from lib.ps1.
# helpers only this goody uses (kept out of the core lib.ps1)
function __Rest([string]$Base, [string]$Env, [string]$Auth, [string]$Method, [string]$Path, $Body, [switch]$Probe) {
  $u = "$(__HostSet 'url' $Base)/$Path"; $h = Get-KitAuth ([string](__HostSet 'tokenEnv' $Env)) $(if ($Auth -eq 'auto') { if ("$([Environment]::GetEnvironmentVariable([string](__HostSet 'tokenEnv' $Env)))" -match ':') { 'basic' } else { 'bearer' } } else { $Auth })
  if (-not $Probe) { return (Invoke-KitHttp $Method $u $Body $h) }
  try { $null = Invoke-RestMethod -Method $Method -Uri $u -Headers $h -ConnectionTimeoutSeconds (Get-KitNetTimeout); $true } catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { $false } else { $null } }
}
# adapter:git-host/gitea: Gitea / Forgejo REST v1 (url default https://<gitHost>/api/v1); env GITEA_TOKEN
function __Gt([string]$Path, [string]$Method = 'GET', $Body, [switch]$Probe) { __Rest "https://$($KitConf.GitHost)/api/v1" 'GITEA_TOKEN' 'token' $Method $Path $Body -Probe:$Probe }
Register-KitAdapter 'git-host' 'gitea' @{
  'mr.get' = { param($a) __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)") }
  'mr.list' = { param($a)
    @(@(__Gt "repos/$($a.repo)/pulls?state=$(@{ opened = 'open'; merged = 'closed'; closed = 'closed' }["$($a.state)"] ?? 'all')&limit=50") | ForEach-Object { __GhMr $_ } | Where-Object { $_ -and ($a.state -notin 'merged', 'closed' -or $_.state -eq $a.state) -and
        (-not $a.source_branch -or $_.source_branch -eq $a.source_branch) -and (-not $a.target_branch -or $_.target_branch -eq $a.target_branch) -and (-not $a.search -or $_.title -like "*$($a.search)*") -and (-not $a.updated_after -or [datetimeoffset]$_.updated_at -ge [datetimeoffset]$a.updated_after) })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = (__Files (__Gt "repos/$($a.repo)/pulls/$($a.n)/files?limit=100")) } }
  'mr.create' = { param($a) __GhMr (__Gt "repos/$($a.repo)/pulls" 'POST' @{ head = $a.source; base = $a.target; title = $a.title; body = $a.body }) }
  'mr.merge' = { param($a) $null = __Gt "repos/$($a.repo)/pulls/$($a.n)/merge" 'POST' @{ Do = $(if ($a.method -in 'merge', 'rebase') { $a.method } else { 'squash' }); delete_branch_after_merge = (__Del $a); head_commit_id = "$($a.sha)"; merge_when_checks_succeed = [bool]$a.auto }
    $m = __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)"); if ($m -and $a.auto -and $m.state -eq 'opened') { $m.merge_when_pipeline_succeeds = $true }; $m }
  'mr.unauto' = { param($a) $null = __Gt "repos/$($a.repo)/pulls/$($a.n)/merge" 'DELETE'; __GhMr (__Gt "repos/$($a.repo)/pulls/$($a.n)") }
  'mr.url' = { param($a) "https://$($KitConf.GitHost)/$($a.repo)/pulls/$($a.n)" }
  'repo.base' = { param($a) $c = __Gt "repos/$($a.repo)/compare/$(__Enc $a.b)...$(__Enc $a.a)"; if ($null -eq $c) { return $null }
    __CommitObj $(if (-not $c.total_commits) { $a.a } else { @(@($c.commits) | Sort-Object { $_.created })[0].parents[0].sha }) }
  'repo.commit' = { param($a) $c = @(__Gt "repos/$($a.repo)/commits?sha=$(__Enc $a.ref)&limit=1&stat=false")[0]; __CommitObj $c.sha $c.commit.committer.date }
  'repo.compare' = { param($a) $c = __Gt "repos/$($a.repo)/compare/$(__Enc $a.from)...$(__Enc $a.to)"; if ($c) { [pscustomobject]@{ diffs = (__Files $c.files) } } }
}
# adapter:ci/gitea: Gitea Actions tasks + commit statuses (no job log API: the log is the run link)
Register-KitAdapter 'ci' 'gitea' @{
  'runs' = { param($a) @(@((__Gt "repos/$($a.repo)/actions/tasks?limit=50").workflow_runs) | Where-Object { $_ -and $_.head_branch -eq $a.ref -and (-not $a.sha -or $_.head_sha -eq $a.sha) } | ForEach-Object { __CiRun $_.id $_.head_sha (__CiWord $_.status) $_.created_at $_.updated_at $_.url }) }
  'jobs' = { param($a) @(@((__Gt "repos/$($a.repo)/actions/tasks?limit=50").workflow_runs) | Where-Object { "$($_.id)" -eq "$($a.id)" } | ForEach-Object { __CiJob $_.id $_.name (__CiWord $_.status) $_.updated_at }) }
  'log' = { param($a) "no log API on Gitea: see https://$($KitConf.GitHost)/$($a.repo)/actions/runs/$($a.id)" }
  'status' = { param($a) if (-not $a.sha) { return $null }; $s = __Gt "repos/$($a.repo)/commits/$($a.sha)/status"; $st = __CiRoll @(@($s.statuses) | ForEach-Object { __CiWord $_.status }); if ($st) { __CiStat $null $st } }
  'config' = { param($a) $r = @('.gitea/workflows', '.github/workflows') | ForEach-Object { __Gt "repos/$($a.repo)/contents/$_`?ref=$(__Enc $a.ref)" -Probe }; if ($r -contains $true) { $true } elseif ($r -contains $null) { $null } else { $false } }
}
