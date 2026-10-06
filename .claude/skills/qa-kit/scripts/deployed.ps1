#Requires -Version 7
<#
Is a merged MR live on a test environment? Answers from the CI, not from memory: the MR's merge commit must be an ancestor of
the deploy branch AND of a pipeline on that branch whose deploy job succeeded.

  $D = '<kit>\skills\qa-kit\scripts\deployed.ps1'
  & $D -Mrs backend!812,web!415                     # one line per MR per deploy target, exit 0 when every MR is live
  & $D -Mrs backend!812 -Target staging -Json       # machine-readable

Deploy targets come from dev-kit\kit.local.json: repos[].deploys = [{ "target": "staging", "branch": "staging",
"job": "deploy-staging" }]. A repo without deploys reports NO-TARGET.
Use it before holding a QA item as "not deployed yet", and supervise.ps1 -AutoFix uses it to flag promoted tasks that went live.
#>
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\kitconfig.ps1')
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$group = $KitConf.GitlabGroup
$repos = @(Get-KitValue 'repos' @())
function Repo($name) { $repos | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1 }
function Api($path) { glab api $path 2>$null | ConvertFrom-Json }
function IsAncestor($p, $sha, $ref) { (Api "projects/$p/repository/merge_base?refs[]=$sha&refs[]=$([uri]::EscapeDataString($ref))").id -eq $sha }

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
    if (-not (IsAncestor $p $sha $d.branch)) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "not on $($d.branch) yet" }; continue }
    $hit = $null
    foreach ($pl in @(Api "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10")) {
      $job = @(Api "projects/$p/pipelines/$($pl.id)/jobs?per_page=100") | Where-Object { $_.name -eq $d.job } | Select-Object -First 1
      if ($job.status -eq 'success' -and ($pl.sha -eq $sha -or (IsAncestor $p $sha $pl.sha))) { $hit = $job; break }
    }
    if ($hit) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "$($d.job) finished $($hit.finished_at)" } }
    else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "on $($d.branch), but no successful $($d.job) includes it yet" } }
  }
}
if ($Json) { $out | ConvertTo-Json -Depth 3 } else { $out | ForEach-Object { "{0,-13} {1,-18} {2,-12} {3}" -f $_.state, $_.mr, $_.target, $_.detail } }
exit $(if (@($out | Where-Object { $_.state -ne 'DEPLOYED' }).Count) { 1 } else { 0 })
