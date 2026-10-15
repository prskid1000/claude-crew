<#
Waits for merge-request pipelines and reports them as JSON (one line), so a cheap agent (or a script) can route CI failures back to
the dev agent instead of scheduling a merge that will never happen.

  & <workspace>/.claude/skills/dev-kit/scripts/pipe-wait.ps1 -Mrs https://gitlab.example.com/group/api/-/merge_requests/12,https://... [-MaxMinutes 8]

Output: {"done":true|false,"mrs":[{"mr":url,"status":"success|failed|running|...","job":"<failed job>","error":"<last error lines>"}]}
done=false = some pipelines still running after -MaxMinutes (call again). Exit codes: 0 always (read the JSON; done=false = still running).
GitLab MRs (.../-/merge_requests/<n>) through glab; GitHub pull requests (.../pull/<n>) through gh (status = the PR's checks).
#>
param([Parameter(Mandatory)][string[]]$Mrs, [int]$MaxMinutes = 8)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'githost.ps1')   # Invoke-HostApi; the MR URL decides the host (a GitLab URL forces GitLab below)
$list = @($Mrs -split '\s*,\s*' | Where-Object { $_ })
# GitHub: the PR's check runs / commit statuses folded into the GitLab-style statuses the callers read
function GhState($url) {
  $pr = gh pr view $url --json state,statusCheckRollup 2>$null | ConvertFrom-Json
  if (-not $pr) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($pr.state -eq 'MERGED') { return [ordered]@{ mr = $url; status = 'merged' } }
  $checks = @($pr.statusCheckRollup)
  if (-not $checks.Count) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }
  $res = @($checks | ForEach-Object { if ($_.conclusion) { $_.conclusion } elseif ($_.state) { $_.state } else { $_.status } } | ForEach-Object { "$_".ToUpper() })
  $bad = @($checks | Where-Object { "$($_.conclusion)$($_.state)".ToUpper() -match 'FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE' })
  $o = [ordered]@{ mr = $url; status = $(if ($bad.Count) { 'failed' } elseif ($res | Where-Object { $_ -match 'PENDING|QUEUED|IN_PROGRESS|EXPECTED|WAITING|REQUESTED' }) { 'running' } else { 'success' }) }
  if ($bad.Count) {
    $o.job = $(if ($bad[0].name) { $bad[0].name } else { $bad[0].context })
    $link = if ($bad[0].detailsUrl) { $bad[0].detailsUrl } else { $bad[0].targetUrl }
    if ($link -match '/runs/(\d+)') { $o.error = ((gh run view $Matches[1] --repo ($url -replace '^https?://[^/]+/([^/]+/[^/]+)/pull/.*$', '$1') --log-failed 2>$null) -split "`n" | Where-Object { $_ -match '(?i)error|fail|exception' } | Select-Object -Last 8) -join "`n" }
    if (-not $o.error) { $o.error = "see $link" }
  }
  $o
}
function State($url) {
  if ($url -match '^https?://[^/]+/[^/]+/[^/]+/pull/\d+') { return GhState $url }
  if ($url -notmatch '^https?://(?<h>[^/]+)/(?<p>.+?)/-/merge_requests/(?<i>\d+)') { return [ordered]@{ mr = $url; status = 'bad-url' } }
  $proj = $Matches.p -replace '/', '%2F'; $iid = $Matches.i
  $env:GITLAB_HOST = $Matches.h; $script:HostType = 'gitlab'   # glab would otherwise ask gitlab.com (self-hosted servers: the MR's own host)
  $m = Invoke-HostApi "projects/$proj/merge_requests/$iid"
  if (-not $m) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($m.state -eq 'merged') { return [ordered]@{ mr = $url; status = 'merged' } }
  $p = $m.head_pipeline
  if (-not $p) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }
  $o = [ordered]@{ mr = $url; status = $p.status }
  if ($p.status -eq 'failed') {
    $job = @(Invoke-HostApi "projects/$proj/pipelines/$($p.id)/jobs" | Where-Object status -eq 'failed')[0]
    if ($job) {
      $o.job = $job.name
      $trace = ([string](Invoke-HostApi "projects/$proj/jobs/$($job.id)/trace")) -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' -replace '^\S+Z \d+O ', '' }
      $o.error = (@($trace | Where-Object { $_ -match '(?i)error|fail|invalid|exception|\[ERROR\]' } | Select-Object -Last 8) -join "`n")
    }
  }
  $o
}
$start = Get-Date; $end = $start.AddMinutes($MaxMinutes)
do {
  $states = @($list | ForEach-Object { State $_ })
  # right after a push the pipeline does not exist yet: 'no-pipeline' counts as busy for 3 min (after that: a repo without MR CI)
  $busy = @($states | Where-Object { $_.status -in 'created', 'pending', 'running', 'waiting_for_resource', 'preparing', 'scheduled' -or ($_.status -eq 'no-pipeline' -and ((Get-Date) - $start).TotalMinutes -lt 3) })
  if (-not $busy -or (Get-Date) -gt $end) { break }
  Start-Sleep 30
} while ($true)
[ordered]@{ done = (-not $busy); mrs = $states } | ConvertTo-Json -Depth 4 -Compress
