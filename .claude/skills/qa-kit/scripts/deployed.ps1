#Requires -Version 7
<#
Is a merged MR live on a test environment? Answers from the CI, not from memory: the MR's merge commit must be on
the deploy branch AND on a pipeline on that branch whose deploy job succeeded. "On" = an ancestor, or (squashed "merge main
into staging" / cherry-picks) the MR is on its target branch and none of its files differ between that branch and the deploy ref.

  $D = '<kit>\skills\qa-kit\scripts\deployed.ps1'
  & $D -Mrs backend!812,web!415                     # one line per MR per deploy target, exit 0 when every MR is live
  & $D -Mrs backend!812 -Target staging -Json       # machine-readable

Deploy targets come from dev-kit\kit.local.json: repos[].deploys = [{ "target": "staging", "branch": "staging",
"job": "deploy-staging" }]. A repo deployed by hand (no CI job) uses { "target": ..., "awsStack": "<CloudFormation stack>", "region": ... }:
live when the stack was updated after the merge. A repo without deploys reports NO-TARGET.
Use it before holding a QA item as "not deployed yet", and supervise.ps1 -AutoFix uses it to flag promoted tasks that went live.
#>
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\kitconfig.ps1')
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$group = $KitConf.GitlabGroup
$repos = @(Get-KitValue 'repos' @())
function Repo($name) { $repos | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1 }
# memoised: supervise checks many MRs on the same branches/pipelines each round (unmemoised: 100+ sequential API calls, > 2 min)
$memo = @{}
function Api($path) { if (-not $memo.ContainsKey($path)) { $memo[$path] = glab api $path 2>$null | ConvertFrom-Json }; $memo[$path] }
function IsAncestor($p, $sha, $ref) { if ($sha -eq $ref) { return $true }; (Api "projects/$p/repository/merge_base?refs[]=$sha&refs[]=$([uri]::EscapeDataString($ref))").id -eq $sha }
# A squashed "merge main into staging" (or a cherry-pick) carries the MR's content without its commit: ancestry says no.
# Fallback: the MR is on its target branch (e.g. main) and none of its files differ between that branch and $ref.
function ContentOn($p, $mr, $sha, $ref) {
  # cheap guard first (supervise runs this for many MRs): a ref last committed before the merge cannot hold it
  $head = Api "projects/$p/repository/commits/$([uri]::EscapeDataString($ref))"
  if (-not $head -or ($mr.merged_at -and [datetimeoffset]$head.committed_date -lt [datetimeoffset]$mr.merged_at)) { return $false }
  if (-not (IsAncestor $p $sha $mr.target_branch)) { return $false }
  $files = @((Api "projects/$p/merge_requests/$($mr.iid)/changes?access_raw_diffs=true").changes | ForEach-Object { $_.new_path; $_.old_path } | Sort-Object -Unique)
  if (-not $files.Count) { return $false }
  $cmp = Api "projects/$p/repository/compare?from=$([uri]::EscapeDataString($ref))&to=$([uri]::EscapeDataString($mr.target_branch))&straight=true"
  if (-not $cmp) { return $false }
  -not @($cmp.diffs | Where-Object { $files -contains $_.new_path -or $files -contains $_.old_path }).Count
}
function OnRef($p, $mr, $sha, $ref) { (IsAncestor $p $sha $ref) -or (ContentOn $p $mr $sha $ref) }

$out = foreach ($m in @($Mrs -split '\s*,\s*' | Where-Object { $_ })) {
  if ($m -notmatch '^(?<repo>[\w.-]+)!(?<iid>\d+)$') { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'expected <repo>!<iid>' }; continue }
  $r = Repo $Matches.repo; $iid = $Matches.iid
  if (-not $r) { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'repo not in kit.local.json' }; continue }
  $p = [uri]::EscapeDataString($(if ($group) { "$group/$($r.name)" } else { $r.name })); $ref = "$($r.name)!$iid"
  $mr = Api "projects/$p/merge_requests/$iid"
  if ($mr.state -ne 'merged') { [pscustomobject]@{ mr = $ref; target = ''; state = 'NOT-MERGED'; detail = "$($mr.state)" }; continue }
  $sha = if ($mr.squash_commit_sha) { $mr.squash_commit_sha } else { $mr.merge_commit_sha }
  $deps = @($r.deploys | Where-Object { -not $Target -or $_.target -eq $Target })
  if (-not $deps.Count) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'NO-TARGET'; detail = 'no deploys configured for this repo' }; continue }
  foreach ($d in $deps) {
    if ($d.awsStack) {   # deployed by hand (no CI job): live only if the CloudFormation stack was updated after the merge
      $upd = aws cloudformation describe-stacks --region $(if ($d.region) { $d.region } else { 'eu-west-1' }) --stack-name $d.awsStack --query 'Stacks[0].[LastUpdatedTime,StackStatus]' --output text 2>$null
      if (-not $upd) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "cannot read stack $($d.awsStack) (aws sts get-caller-identity?)" }; continue }
      $at, $st = "$upd" -split '\s+'
      if ([datetimeoffset]$at -gt [datetimeoffset]$mr.merged_at -and $st -match 'COMPLETE$' -and $st -notmatch 'ROLLBACK') { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "stack $($d.awsStack) updated $at after the merge (by hand: confirm the build was from the merged branch)" } }
      else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "stack $($d.awsStack) last updated $at ($st), merged $($mr.merged_at)" } }
      continue
    }
    if (-not (OnRef $p $mr $sha $d.branch)) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "not on $($d.branch) yet" }; continue }
    $hit = $null
    # a pipeline created before the merge cannot contain it: skip those without asking for their jobs
    foreach ($pl in @(Api "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10") | Where-Object { -not $mr.merged_at -or [datetimeoffset]$_.created_at -ge [datetimeoffset]$mr.merged_at }) {
      $job = @(Api "projects/$p/pipelines/$($pl.id)/jobs?per_page=100") | Where-Object { $_.name -eq $d.job } | Select-Object -First 1
      if ($job.status -eq 'success' -and ($pl.sha -eq $sha -or (OnRef $p $mr $sha $pl.sha))) { $hit = $job; break }
    }
    if ($hit) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "$($d.job) finished $($hit.finished_at)" } }
    else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "on $($d.branch), but no successful $($d.job) includes it yet" } }
  }
}
if ($Json) { $out | ConvertTo-Json -Depth 3 } else { $out | ForEach-Object { "{0,-13} {1,-18} {2,-12} {3}" -f $_.state, $_.mr, $_.target, $_.detail } }
exit $(if (@($out | Where-Object { $_.state -ne 'DEPLOYED' }).Count) { 1 } else { 0 })
