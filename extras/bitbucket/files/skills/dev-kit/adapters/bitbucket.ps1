#Requires -Version 7
# Extra bitbucket: Bitbucket Cloud git host + Bitbucket Pipelines CI (gitHostType / ci bitbucket).
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add bitbucket); helpers come from lib.ps1.
# helpers only this extra uses (kept out of the core lib.ps1)
function __DiffFile($New, $Old = $null) { [pscustomobject]@{ new_path = "$New"; old_path = "$(if ($Old) { $Old } else { $New })" } }
function __KitAuto([string]$Repo, [string]$N, [switch]$Drop) { Update-KitTracking { param($t) if ($Drop) { $t.automerge.Remove("$Repo!$N") } else { $t.automerge["$Repo!$N"] = (Get-Date).ToString('s') } } }
function __Rest([string]$Base, [string]$Env, [string]$Auth, [string]$Method, [string]$Path, $Body, [switch]$Probe) {
  $u = "$(__HostSet 'url' $Base)/$Path"; $h = Get-KitAuth ([string](__HostSet 'tokenEnv' $Env)) $(if ($Auth -eq 'auto') { if ("$([Environment]::GetEnvironmentVariable([string](__HostSet 'tokenEnv' $Env)))" -match ':') { 'basic' } else { 'bearer' } } else { $Auth })
  if (-not $Probe) { return (Invoke-KitHttp $Method $u $Body $h) }
  try { $null = Invoke-RestMethod -Method $Method -Uri $u -Headers $h -ConnectionTimeoutSeconds (Get-KitNetTimeout); $true } catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { $false } else { $null } }
}
# adapter:git-host/bitbucket: Bitbucket Cloud REST 2.0; env BITBUCKET_TOKEN ("user:app-password" = basic, else bearer); no native merge-when-green
function __Bb([string]$Path, [string]$Method = 'GET', $Body, [switch]$Probe) { __Rest 'https://api.bitbucket.org/2.0' 'BITBUCKET_TOKEN' 'auto' $Method $Path $Body -Probe:$Probe }
function __BbMr($p) {
  if (-not $p.id) { return $null }
  __Mr @{ iid = $p.id; title = $p.title; state = $(switch ($p.state) { 'OPEN' { 'opened' } 'MERGED' { 'merged' } default { 'closed' } }); source_branch = $p.source.branch.name; target_branch = $p.destination.branch.name
    sha = $p.source.commit.hash; merge_commit_sha = $p.merge_commit.hash; merged_at = $(if ($p.state -eq 'MERGED') { $p.updated_on }); updated_at = $p.updated_on; draft = [bool]$p.draft; web_url = $p.links.html.href }
}
Register-KitAdapter 'git-host' 'bitbucket' @{
  'mr.get' = { param($a) __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)") }
  'mr.list' = { param($a)
    $st = @{ opened = @('OPEN'); merged = @('MERGED'); closed = @('DECLINED', 'SUPERSEDED') }["$($a.state)"]; if (-not $st) { $st = 'OPEN', 'MERGED', 'DECLINED' }
    $q = @(); if ($a.source_branch) { $q += "source.branch.name=`"$($a.source_branch)`"" }; if ($a.target_branch) { $q += "destination.branch.name=`"$($a.target_branch)`"" }; if ($a.search) { $q += "title~`"$($a.search)`"" }; if ($a.updated_after) { $q += "updated_on>$($a.updated_after)" }
    @((__Bb "repositories/$($a.repo)/pullrequests?pagelen=50$(($st | ForEach-Object { "&state=$_" }) -join '')$(if ($q) { '&q=' + (__Enc ($q -join ' AND ')) })").values | ForEach-Object { __BbMr $_ })
  }
  'mr.changes' = { param($a) [pscustomobject]@{ changes = @((__Bb "repositories/$($a.repo)/pullrequests/$($a.n)/diffstat?pagelen=100").values | ForEach-Object { [pscustomobject]@{ new_path = $(if ($_.new) { $_.new.path } else { $_.old.path }); old_path = $(if ($_.old) { $_.old.path } else { $_.new.path }) } }) } }
  'mr.create' = { param($a) __BbMr (__Bb "repositories/$($a.repo)/pullrequests" 'POST' @{ title = $a.title; description = $a.body; source = @{ branch = @{ name = $a.source } }; destination = @{ branch = @{ name = $a.target } }; close_source_branch = (__Del $a) }) }
  'mr.merge' = { param($a)
    if ($a.auto -and (Invoke-HostVerb 'ci.status' @{ repo = $a.repo; sha = $(if ($a.sha) { $a.sha } else { (__BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)")).sha }) } -NoMemo).status -ne 'success') { __KitAuto $a.repo $a.n; $m = __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)"); if ($m) { $m | Add-Member auto_merge 'kit' }; return $m }
    __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)/merge" 'POST' @{ merge_strategy = @{ merge = 'merge_commit'; rebase = 'fast_forward' }["$($a.method)"] ?? 'squash'; close_source_branch = (__Del $a) })
  }
  'mr.unauto' = { param($a) __KitAuto $a.repo $a.n -Drop; __BbMr (__Bb "repositories/$($a.repo)/pullrequests/$($a.n)") }
  'mr.url' = { param($a) "https://bitbucket.org/$($a.repo)/pull-requests/$($a.n)" }
  'repo.base' = { param($a) $c = __Bb "repositories/$($a.repo)/merge-base/$(__Enc $a.a)..$(__Enc $a.b)"; __CommitObj $c.hash }
  'repo.commit' = { param($a) $c = __Bb "repositories/$($a.repo)/commit/$(__Enc $a.ref)"; __CommitObj $c.hash $c.date }
  'repo.compare' = { param($a) $c = __Bb "repositories/$($a.repo)/diffstat/$(__Enc $a.to)..$(__Enc $a.from)?pagelen=100"; if ($c) { [pscustomobject]@{ diffs = @($c.values | ForEach-Object { __DiffFile "$($_.new.path)$(if (-not $_.new) { $_.old.path })" "$($_.old.path)$(if (-not $_.old) { $_.new.path })" }) } } }
}
# adapter:ci/bitbucket: Bitbucket Pipelines (job id = <pipeline uuid>/<step uuid>)
function __BbRun($p) { __CiRun $p.uuid $p.target.commit.hash $(if ($p.state.result.name) { __CiWord $p.state.result.name } elseif ($p.state.stage.name -eq 'PAUSED') { 'manual' } else { __CiWord $p.state.name }) $p.created_on $(if ($p.completed_on) { $p.completed_on } else { $p.created_on }) }
Register-KitAdapter 'ci' 'bitbucket' @{
  'runs' = { param($a) @(@((__Bb "repositories/$($a.repo)/pipelines?target.branch=$(__Enc $a.ref)&sort=-created_on&pagelen=$($a.per_page ?? 20)").values) | Where-Object { $_ } | ForEach-Object { __BbRun $_ } | Where-Object { -not $a.sha -or $_.sha -like "$($a.sha.Substring(0, [Math]::Min(12, $a.sha.Length)))*" }) }
  'jobs' = { param($a) @(@((__Bb "repositories/$($a.repo)/pipelines/$(__Enc $a.id)/steps?pagelen=100").values) | Where-Object { $_ } | ForEach-Object { __CiJob "$($a.id)/$($_.uuid)" $_.name (__BbRun $_).status $_.completed_on }) }
  'log' = { param($a) $p, $s = "$($a.id)" -split '/', 2; __Bb "repositories/$($a.repo)/pipelines/$(__Enc $p)/steps/$(__Enc $s)/log" }
  'status' = { param($a) if (-not $a.sha) { return $null }; $v = @((__Bb "repositories/$($a.repo)/commit/$($a.sha)/statuses?pagelen=100").values | Where-Object { $_ }); $st = __CiRoll @($v | ForEach-Object { __CiWord $_.state }); if ($st) { __CiStat @($v | ForEach-Object { if ("$($_.url)" -match '/pipelines/results/(\d+)') { $Matches[1] } })[0] $st } }
  'config' = { param($a) __Bb "repositories/$($a.repo)/src/$(__Enc $a.ref)/bitbucket-pipelines.yml" -Probe }
}
