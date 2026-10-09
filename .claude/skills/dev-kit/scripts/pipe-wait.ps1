<#
Waits for merge-request pipelines and reports them as JSON (one line), so a cheap agent (or a script) can route CI failures back to
the dev agent instead of scheduling a merge that will never happen.

  & <workspace>/.claude/skills/dev-kit/scripts/pipe-wait.ps1 -Mrs https://gitlab.example.com/group/api/-/merge_requests/12,https://... [-MaxMinutes 8]

Output: {"done":true|false,"mrs":[{"mr":url,"status":"success|failed|running|...","job":"<failed job>","error":"<last error lines>"}]}
done=false = some pipelines still running after -MaxMinutes (call again). Exit 0 always (read the JSON). GitLab (glab) MRs only.
#>
param([Parameter(Mandatory)][string[]]$Mrs, [int]$MaxMinutes = 8)
$ErrorActionPreference = 'SilentlyContinue'
$list = @($Mrs -split '\s*,\s*' | Where-Object { $_ })
function State($url) {
  if ($url -notmatch '^https?://[^/]+/(?<p>.+?)/-/merge_requests/(?<i>\d+)') { return [ordered]@{ mr = $url; status = 'bad-url' } }
  $proj = $Matches.p -replace '/', '%2F'; $iid = $Matches.i
  $m = glab api "projects/$proj/merge_requests/$iid" 2>$null | ConvertFrom-Json
  if (-not $m) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($m.state -eq 'merged') { return [ordered]@{ mr = $url; status = 'merged' } }
  $p = $m.head_pipeline
  if (-not $p) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }
  $o = [ordered]@{ mr = $url; status = $p.status }
  if ($p.status -eq 'failed') {
    $job = @(glab api "projects/$proj/pipelines/$($p.id)/jobs" 2>$null | ConvertFrom-Json | Where-Object status -eq 'failed')[0]
    if ($job) {
      $o.job = $job.name
      $trace = (glab api "projects/$proj/jobs/$($job.id)/trace" 2>$null) -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' -replace '^\S+Z \d+O ', '' }
      $o.error = (@($trace | Where-Object { $_ -match '(?i)error|fail|invalid|exception|\[ERROR\]' } | Select-Object -Last 8) -join "`n")
    }
  }
  $o
}
$end = (Get-Date).AddMinutes($MaxMinutes)
do {
  $states = @($list | ForEach-Object { State $_ })
  $busy = @($states | Where-Object { $_.status -in 'created', 'pending', 'running', 'waiting_for_resource', 'preparing' })
  if (-not $busy -or (Get-Date) -gt $end) { break }
  Start-Sleep 30
} while ($true)
[ordered]@{ done = (-not $busy); mrs = $states } | ConvertTo-Json -Depth 4 -Compress
