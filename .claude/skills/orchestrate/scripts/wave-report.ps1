<#
Readable summary of a finished (or running) workflow, built from its journal — the reliable source; the Workflow tool's
notification text is truncated and not plain JSON. Works for /dev-wave, /test-and-close and /kit-retro runs.

  & <workspace>\.claude\skills\orchestrate\scripts\wave-report.ps1 -Run wf_de575b4e-f98 [-Session <id>] [-Json]
  -> prints per-agent status, MRs, done/deferred, OPEN review findings (non-nit, not fixed by a fix: round), QA verdicts per package,
     learn-step changes; writes the same as JSON to <.claude-runtime>\waves\<run>.json for later rounds / follow-up briefs.
#>
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json)
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts\kitconfig.ps1')
$proj = $KitConf.ClaudeProjectDir   # this workspace's Claude Code sessions
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$dir = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Join-Path $_.FullName "subagents\workflows\$Run" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dir) { throw "workflow $Run not found under $proj" }
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
$running = @($ev | Where-Object type -eq 'started' | Where-Object { $_.agentId -notin @($ev | Where-Object type -eq 'result' | ForEach-Object agentId) } | ForEach-Object label)

$agents = [ordered]@{}; $findings = New-Object System.Collections.ArrayList; $qa = [ordered]@{}; $learn = $null
foreach ($x in $results) {
  $kind, $id = ($x.label -split ':', 2); $id = ($id -split '@')[0]
  switch ($kind) {
    { $_ -in 'build', 'fix' } {
      if ($x.r.mrs) { $agents[$id] = [ordered]@{ mrs = @($x.r.mrs | ForEach-Object { [ordered]@{ url = $_.url; merged = $_.merged } }); done = @($x.r.done); deferred = @($x.r.deferred); needsLiveCheck = @($x.r.needsLiveCheck); fixedRound = ($kind -eq 'fix') } }
      elseif (-not $agents.Contains($id)) { $agents[$id] = [ordered]@{ mrs = @(); done = @(); deferred = @(); note = ([string]$x.r).Substring(0, [math]::Min(300, ([string]$x.r).Length)) } }
    }
    'review' { foreach ($f in $x.r.findings) { [void]$findings.Add([ordered]@{ agent = $id; severity = $f.severity; file = $f.file; line = $f.line; problem = $f.problem; fix = $f.fix; mr = $f.mr }) } }
    { $_ -in 'test', 'retest' } { if ($x.r.checks) { $c = @($x.r.checks); $qa[$id] = [ordered]@{ checks = $c.Count; pass = @($c | Where-Object result -in 'PASS', 'PASS_WITH_NOTE').Count; fail = @($c | Where-Object result -eq 'FAIL').Count; notTested = @($c | Where-Object result -eq 'NOT_TESTED').Count } } }
    'close' { if ($qa.Contains($id)) { $qa[$id].published = [bool]$x.r.ok } }
    'learn' { $learn = $x.r }
  }
}
# A non-nit finding (blocking or should-fix) counts as addressed when that agent had a fix: round - the fix round answers every
# non-nit finding (fix, or a reasoned rebuttal in its summary). Listed separately so the lead can still read what was done.
$addressed = @($findings | Where-Object { $_.severity -ne 'nit' -and $agents[$_.agent].fixedRound })
$open = @($findings | Where-Object { $_.severity -ne 'nit' -and -not $agents[$_.agent].fixedRound })
$out = [ordered]@{ run = $Run; at = (Get-Date).ToString('s'); running = $running; agents = $agents; openFindings = $open; qa = $qa; learn = $learn }
New-Item -ItemType Directory -Force (Join-Path $rt 'waves') | Out-Null
$out | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rt "waves\$Run.json")
if ($Json) { $out | ConvertTo-Json -Depth 8; exit 0 }

"=== $Run $(if ($running) { "(running: $($running -join ', '))" } else { '(complete)' })"
# the agent's "merged" is a snapshot from when it finished (usually merge-when-green still pending): ask GitLab now
# (glab talks to the host it is logged in to; self-hosted: GITLAB_HOST / kit.local.json "gitHost")
foreach ($a in $agents.Values) { foreach ($m in $a.mrs) { if (-not $m.merged -and $m.url -match '://[^/]+/(?<p>.+?)/-/merge_requests/(?<i>\d+)') {
  $m.merged = ((glab api "projects/$($Matches.p -replace '/', '%2F')/merge_requests/$($Matches.i)" 2>$null | ConvertFrom-Json).state -eq 'merged') } } }
foreach ($k in $agents.Keys) { $a = $agents[$k]; '{0,-4} MRs {1}/{2} merged | done [{3}] | deferred {4}{5}' -f $k, @($a.mrs | Where-Object merged).Count, @($a.mrs).Count, ($a.done -join ','), @($a.deferred).Count, $(if ($a.note) { " | $($a.note.Substring(0, [math]::Min(80, $a.note.Length)))" }) }
foreach ($k in $qa.Keys) { $q = $qa[$k]; '{0,-5} {1}/{2} pass, {3} fail, {4} not tested{5}' -f $k, $q.pass, $q.checks, $q.fail, $q.notTested, $(if ($q.Contains('published')) { " | published: $($q.published)" }) }
if ($addressed.Count) { "--- review findings addressed in the fix round ($($addressed.Count)) - see each agent's fix-round summary"; $addressed | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line)" } }
if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $(([string]$_.problem).Substring(0, [math]::Min(150, ([string]$_.problem).Length)))" } }
if ($learn) { "--- learn: $($learn.signals) signal(s); lessons: $(@($learn.lessonsChanged).Count)" }
"saved: $(Join-Path $rt "waves\$Run.json")"
