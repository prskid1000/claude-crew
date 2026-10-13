<#
Readable summary of a finished (or running) workflow, built from its journal — the reliable source; the Workflow tool's
notification text is truncated and not plain JSON. Works for /dev-wave, /test-and-close and /kit-retro runs.

  & <workspace>/.claude/skills/orchestrate/scripts/wave-report.ps1 -Run wf_de575b4e-f98 [-Session <id>] [-Detail] [-Json]
  -> default (compact): one totals line, then only what needs the lead: agents with unmerged MRs / deferrals / notes, QA packages
     with FAIL or NOT_TESTED, OPEN review findings (non-nit, not fixed by a fix: round), learn-step changes.
     -Detail: every agent and package, done lists, deferral reasons, live checks, full findings with their fix.
     Always writes the full JSON to <runtime>/work/waves/<run>.json (Get-KitPath waves) for later rounds / follow-up briefs.
#>
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts\kitconfig.ps1')
$proj = $KitConf.ClaudeProjectDir   # this workspace's Claude Code sessions
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$dir = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Join-Path $_.FullName "subagents\workflows\$Run" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dir) { throw "workflow $Run not found under $proj" }
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
# running = started without a result, minus (as supervise.ps1 does) steps superseded by a later finished agent for the same item
# (died on an API error, retried) and every step of a workflow the lead stopped (supervise.ps1 -MarkStopped)
$started = @($ev | Where-Object type -eq 'started'); $doneIds = @($ev | Where-Object type -eq 'result' | ForEach-Object agentId)
$itemOf = { param($l) (([string]$l -split ':', 2)[-1] -split '@')[0] }
$lastDone = @{}; for ($i = 0; $i -lt $started.Count; $i++) { if ($started[$i].agentId -in $doneIds) { $lastDone[(& $itemOf $started[$i].label)] = $i } }
$running = @(for ($i = 0; $i -lt $started.Count; $i++) { $s = $started[$i]; if ($s.agentId -notin $doneIds -and -not ($lastDone[(& $itemOf $s.label)] -gt $i)) { $s.label } })
if (Test-Path (Join-Path (Get-KitPath stopped) $Run)) { $running = @() }

$agents = [ordered]@{}; $findings = New-Object System.Collections.ArrayList; $qa = [ordered]@{}; $learn = $null
foreach ($x in $results) {
  $kind, $id = ($x.label -split ':', 2); $id = ($id -split '@')[0]
  switch ($kind) {
    { $_ -in 'build', 'fix' } {
      $p = if ($agents.Contains($id)) { $agents[$id] } else { $null }
      if ($x.r -is [System.Management.Automation.PSCustomObject]) {
        # a report object: read done/deferred/live checks from it even with no MRs (an agent that deferred everything still has a
        # report; it once showed as "deferred 0" plus a raw @{mrs=...} dump). A fix round reports only the MRs it touched: merge with
        # the build round's by URL, and deferred items by id (the newer entry wins).
        $rm = @($x.r.mrs | Where-Object { $_ }); $urls = @($rm | ForEach-Object url)
        $mrs = @(@($p.mrs | Where-Object { $_ -and $_.url -notin $urls }) + @($rm | ForEach-Object { [ordered]@{ url = $_.url; merged = [bool]$_.merged; mergeState = $(if ($_.mergeState) { [string]$_.mergeState } elseif ($_.merged) { 'MERGED' } else { 'OPEN' }) } }))
        $nd = @($x.r.deferred | Where-Object { $_ }); $ndIds = @($nd | ForEach-Object id)
        $agents[$id] = [ordered]@{ mrs = $mrs; done = @(@($p.done) + @($x.r.done) | Where-Object { $_ } | Select-Object -Unique)
          deferred = @(@($p.deferred | Where-Object { $_ -and $_.id -notin $ndIds }) + $nd)
          needsLiveCheck = @(@($p.needsLiveCheck) + @($x.r.needsLiveCheck) | Where-Object { $_ } | Select-Object -Unique); fixedRound = ($kind -eq 'fix' -or [bool]$p.fixedRound) }
        if (-not $mrs.Count -and $x.r.summary) { $agents[$id].note = ([string]$x.r.summary).Substring(0, [math]::Min(300, ([string]$x.r.summary).Length)) }
      }
      elseif (-not $p) { $agents[$id] = [ordered]@{ mrs = @(); done = @(); deferred = @(); needsLiveCheck = @(); note = ([string]$x.r).Substring(0, [math]::Min(300, ([string]$x.r).Length)) } }
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
$wavesDir = Get-KitPath waves -Create
$out | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $wavesDir "$Run.json")
if ($Json) { $out | ConvertTo-Json -Depth 8; exit 0 }

"=== $Run $(if ($running) { "(running: $($running -join ', '))" } else { '(complete)' })"
# the agent's "merged" is a snapshot from when it finished (usually merge-when-green still pending): ask GitLab now
# (glab talks to the host it is logged in to; self-hosted: GITLAB_HOST / kit.local.json "gitHost")
foreach ($a in $agents.Values) { foreach ($m in $a.mrs) { if (-not $m.merged -and $m.url -match '://[^/]+/(?<p>.+?)/-/merge_requests/(?<i>\d+)') {
  $h = glab api "projects/$($Matches.p -replace '/', '%2F')/merge_requests/$($Matches.i)" 2>$null | ConvertFrom-Json
  if ($h.state -eq 'merged') { $m.merged = $true; $m.mergeState = 'MERGED' } elseif ($h.merge_when_pipeline_succeeds) { $m.mergeState = 'SCHEDULED' } }
  elseif (-not $m.merged -and $m.url -match '://[^/]+/[^/]+/[^/]+/pull/\d+') {   # GitHub PRs
  $h = gh pr view $m.url --json state,autoMergeRequest 2>$null | ConvertFrom-Json
  if ($h.state -eq 'MERGED') { $m.merged = $true; $m.mergeState = 'MERGED' } elseif ($h.autoMergeRequest) { $m.mergeState = 'SCHEDULED' } } } }
function Sum($xs, $k) { [int](@($xs | ForEach-Object { $_[$k] }) | Measure-Object -Sum).Sum }
$isSched = { param($m) -not $m.merged -and $m.mergeState -eq 'SCHEDULED' }
$cut = { param($s, $n) $s = [string]$s; $s.Substring(0, [math]::Min($n, $s.Length)) }
if ($Detail) {
  foreach ($k in $agents.Keys) { $a = $agents[$k]; $sc = @($a.mrs | Where-Object { & $isSched $_ }).Count
    '{0,-4} MRs {1}/{2} merged{3} | done [{4}] | deferred {5}{6}' -f $k, @($a.mrs | Where-Object merged).Count, @($a.mrs).Count, $(if ($sc) { ", $sc scheduled" }), ($a.done -join ','), @($a.deferred).Count, $(if ($a.note) { " | $(& $cut $a.note 80)" })
    foreach ($m in @($a.mrs | Where-Object { -not $_.merged })) { "       MR $($m.mergeState): $($m.url)" }
    foreach ($d in @($a.deferred)) { "       deferred $($d.id): $($d.reason)" }
    foreach ($c in @($a.needsLiveCheck)) { "       live check: $c" } }
  foreach ($k in $qa.Keys) { $q = $qa[$k]; '{0,-5} {1}/{2} pass, {3} fail, {4} not tested{5}' -f $k, $q.pass, $q.checks, $q.fail, $q.notTested, $(if ($q.Contains('published')) { " | published: $($q.published)" }) }
  if ($addressed.Count) { "--- review findings addressed in the fix round ($($addressed.Count)) - see each agent's fix-round summary"; $addressed | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line)" } }
  if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $($_.problem)`n      fix: $($_.fix)" } }
} else {
  $am = @($agents.Values | ForEach-Object { @($_.mrs) }); $qv = @($qa.Values)
  $parts = @()
  if ($agents.Count) { $parts += "agents $($agents.Count): MRs $(@($am | Where-Object merged).Count)/$($am.Count) merged, $(@($am | Where-Object { & $isSched $_ }).Count) scheduled, done $(@($agents.Values | ForEach-Object { @($_.done) }).Count), deferred $(@($agents.Values | ForEach-Object { @($_.deferred) }).Count), findings open $($open.Count) / addressed $($addressed.Count)" }
  if ($qa.Count) { $parts += "QA $($qa.Count) pkg: pass $((Sum $qv 'pass'))/$((Sum $qv 'checks')), fail $((Sum $qv 'fail')), not tested $((Sum $qv 'notTested')), published $(@($qv | Where-Object { $_.Contains('published') -and $_.published }).Count)/$($qa.Count)" }
  if ($parts) { $parts -join ' | ' }
  foreach ($k in $agents.Keys) { $a = $agents[$k]; $um = @($a.mrs | Where-Object { -not $_.merged }).Count; $sc = @($a.mrs | Where-Object { & $isSched $_ }).Count; $dc = @($a.deferred).Count
    if ($um -or $dc -or $a.note) { '  {0}: {1}{2}{3}' -f $k, $(if ($um) { "$um MR(s) not merged$(if ($sc) { " ($sc scheduled)" }) " }), $(if ($dc) { "deferred $dc ($(@($a.deferred | ForEach-Object id) -join ',')) " }), $(if ($a.note) { "| $(& $cut $a.note 80)" }) } }
  foreach ($k in $qa.Keys) { $q = $qa[$k]; if ($q.fail -or $q.notTested -or ($q.Contains('published') -and -not $q.published)) { '  {0}: fail {1}, not tested {2}{3}' -f $k, $q.fail, $q.notTested, $(if ($q.Contains('published') -and -not $q.published) { ', NOT published' }) } }
  if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $(& $cut $_.problem 100)" } }
}
if ($learn) { "--- learn: $($learn.signals) signal(s); lessons: $(@($learn.lessonsChanged).Count)" }
if ($Detail) { "saved: $(Join-Path $wavesDir "$Run.json")" } else { "(full: -Detail or waves\$Run.json)" }
# every finished run ends with a kit retro (orchestrate E14) when signals arrived since the last one (as retro-nudge.ps1 counts them)
if (-not $running) {
  $sig = Get-KitPath signals; $mark = Get-KitPath last-retro
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  if ((Test-Path $sig) -and (Get-Content $sig | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since } | Select-Object -First 1)) { 'ACT  retro due: /kit-retro (E14)' }
}
