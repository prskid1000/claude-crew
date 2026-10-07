#Requires -Version 7   # ConvertFrom-Json -AsHashtable; under Windows PowerShell 5.1 every load is null and actions run on empty ids
<#
Coordinator's periodic check-up (what a human lead would look at every 10-15 minutes). Prints a compact digest and a list
of FLAGS with a suggested action each. The coordinator (main session) runs it on a loop and acts on the flags.

  & <workspace>\.claude\skills\orchestrate\scripts\supervise.ps1 [-Session <claude session id>] [-Json]

Looks at:
  - workflows of this project (journal.jsonl): agents running / finished, per-agent idle time (transcript not written)
  - agent board: active, stale (no heartbeat, not left), duplicates, claim clashes
  - memory gate: queue length, longest wait, running builds, repeated build failures per project
  - machine: RAM pressure, disk space; guard blocks in the last hour; contracts file age
  - phones: agents lease them (phone.ps1); with -AutoFix orphan leases are released and unleased idle phones shut down after 10 min
FLAG levels: ACT (do something now), WATCH (check again next round), INFO.
#>
param([string]$Session, [switch]$Json, [int]$IdleMin = 25, [switch]$AutoFix)   # -AutoFix: perform SAFE fixes itself (idle emulators) instead of only flagging
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$skills = Split-Path (Split-Path (Split-Path $PSCommandPath))   # <kit>\skills
. (Join-Path $skills 'dev-kit\scripts\kitconfig.ps1')
$swarm = Join-Path $skills 'android-swarm'
$now = Get-Date; $liveLabels = New-Object System.Collections.ArrayList; $doneLabels = New-Object System.Collections.ArrayList; $flags = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
function Flag($lvl, $what, $action) { [void]$flags.Add([pscustomobject]@{ level = $lvl; what = $what; action = $action }) }
function L($s) { [void]$lines.Add($s) }

# 1. workflows (newest first, this project's sessions)
$proj = $KitConf.ClaudeProjectDir   # this workspace's Claude Code sessions
$wfDirs = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents\workflows') -Directory } | Sort-Object LastWriteTime -Descending | Select-Object -First 6
foreach ($w in $wfDirs) {
  $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
  $ev = @(Get-Content $j | ForEach-Object { $_ | ConvertFrom-Json })
  $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($r in $ev | Where-Object type -eq 'result') { $res[$r.agentId] = $r }
  $done = [bool]($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' })
  if ($done -and (($now - $w.LastWriteTime).TotalHours -gt 2)) { continue }
  $running = @($started | Where-Object { -not $res.ContainsKey($_.agentId) })
  # An agent that died on an API error (e.g. 529 Overloaded) never writes a result and would look "running" forever. If a later
  # agent for the same item (label "<stage>:<code>[@lane]") has already finished, the workflow moved on: treat it as superseded.
  $itemOf = { param($label) (([string]$label -split ':', 2)[-1] -split '@')[0] }
  $finishedAt = @{}
  foreach ($s in $started) { if ($res.ContainsKey($s.agentId)) { $k = & $itemOf $s.label; $i = [array]::IndexOf($started, $s); if (-not $finishedAt.ContainsKey($k) -or $finishedAt[$k] -lt $i) { $finishedAt[$k] = $i } } }
  $running = @($running | Where-Object { $k = & $itemOf $_.label; -not ($finishedAt.ContainsKey($k) -and $finishedAt[$k] -gt [array]::IndexOf($started, $_)) })
  L ("workflow {0}: {1} agents, {2} finished, {3} running{4}" -f $w.Name, $started.Count, $res.Count, $running.Count, $(if ($done) { ' (complete)' }))
  # keep <runtime>\waves\<run>.json current for running dev waves: track.ps1 reads it to hold merges/promotions while an MR's
  # agent is still in review or fix (a wave nobody had reported on yet was invisible to it, and merge-after merged mid-review)
  if ($AutoFix -and $running.Count -and @($started | Where-Object { $_.label -match '^(build|review|fix):' }).Count) {
    & (Join-Path $PSScriptRoot 'wave-report.ps1') -Run $w.Name *> $null
  }
  foreach ($a in $running) {
    $tf = Get-ChildItem $w.FullName -Recurse -File -Filter "*$($a.agentId)*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idle = if ($tf) { [int]($now - $tf.LastWriteTime).TotalMinutes } else { -1 }
    L ("  {0,-18} idle {1} min" -f $a.label, $idle)
    if ($idle -ge 0 -and $idle -lt $IdleMin) { [void]$liveLabels.Add($a.label) }
    if ($idle -ge $IdleMin) { Flag 'WATCH' "$($a.label) in $($w.Name) has written nothing for $idle min" "Check its worktree/board status and the gate queue; if it is waiting on the gate that's fine. If idle > 60 min with no build, it may be stuck: let the workflow finish it, then resume that agent with RESUME_BRIEF." }
  }
  foreach ($r in $res.Values) {
    [void]$doneLabels.Add([string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label)
    $sum = [string]$r.result.summary + [string]$r.result.error
    # A collision only matters while the wave is still running (two writers right now). Once no agent of the workflow is running
    # it is over and wave-report.ps1 covers its outcome; an agent whose MRs all merged also shipped fine. (Build-stage results
    # report merged=false because merging happens later in the same wave, so "shipped" alone is not enough.)
    $shipped = $r.result.mrs -and -not @($r.result.mrs | Where-Object { -not $_.merged }).Count
    # agent-coordination wording only: a bare "duplicate" fired on bug summaries about duplicate orders/lines/names
    if ($running.Count -and -not $shipped -and $sum -match '(?i)duplicate (agent|copy|writer|instance|session)|(agent|copy|writer)s? collid|collid\w* with (another|an?other agent|agent)|another (agent|writer)|halted|stopped editing') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) in $($w.Name) reported a collision/halt" 'Read its result; resume it alone with RESUME_BRIEF after making sure no other writer is active (board.ps1 check).' }
    if ($r.result -and $r.result.mrs -and @($r.result.mrs).Count -eq 0 -and $sum -match '(?i)not done|no MRs') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) finished without MRs" 'Resume it (dev-wave mode resume) unless it was deliberately stopped.' }
  }
}

# 2. agent board
$board = Join-Path $rt 'board'
$entries = @(Get-ChildItem $board -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
$active = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 })
$stale = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -ge 20 -and ($now - [datetime]$_.beat).TotalHours -lt 6 })
L "board: $($active.Count) active, $($stale.Count) stale"
foreach ($g in $active | Group-Object agent | Where-Object Count -gt 1) {
  # an agent that joined the board twice (same run) leaves its first entry behind: if only the newest entry still beats
  # it is a re-join, not two copies -> mark the old entries left instead of an ACT flag
  $byBeat = @($g.Group | Sort-Object { [datetime]$_.beat } -Descending); $newest = [datetime]$byBeat[0].beat
  $old = @($byBeat | Select-Object -Skip 1)
  # superseded = same run AND (it stopped beating 5+ min before the newest, OR it never beat after joining and joined within 2 min
  # of the newest entry: the same agent ran `board join` twice). A resumed copy joins much later and keeps beating -> real duplicate.
  $superseded = { param($o) $o.run -eq $byBeat[0].run -and ((($newest - [datetime]$o.beat).TotalMinutes -ge 5) -or
      ((([datetime]$o.beat - [datetime]$o.joined).TotalSeconds -lt 5) -and [math]::Abs(([datetime]$o.joined - [datetime]$byBeat[0].joined).TotalMinutes) -le 2)) }
  $rejoin = -not @($old | Where-Object { -not (& $superseded $_) }).Count
  if ($rejoin) {
    if ($AutoFix) { foreach ($o in $old) { $f = Join-Path $board "$($o.session).json"; if (Test-Path $f) { $j = Get-Content $f -Raw | ConvertFrom-Json; $j.status = 'left'; $j | ConvertTo-Json | Set-Content $f } }; Flag 'INFO' "auto-fixed: $($g.Name) re-joined the board; $($old.Count) old entry/entries marked left" 'Nothing to do.' }
    else { Flag 'WATCH' "$($g.Name) has $($g.Count) board entries but only the newest beats (re-join, not a duplicate)" 'Run supervise with -AutoFix to tidy the board.' }
    continue
  }
  Flag 'ACT' "DUPLICATE agent $($g.Name) active in $($g.Count) sessions" 'Stop the newer copy (TaskStop the resumed task, never the workflow agent); never SendMessage a workflow agent by id.'
}
# skip board entries whose agent the workflow journal shows as active (testers don't heartbeat during long checks)
$liveNames = @($liveLabels | ForEach-Object { (($_ -split ':')[-1] -split '@')[0] })
# agents whose workflow step finished (no copy still running) just forgot to `leave`: close their entry instead of flagging
$doneNames = @($doneLabels | ForEach-Object { (($_ -split ':')[-1] -split '@')[0] } | Where-Object { $_ -and $_ -notin $liveNames })
foreach ($s in $stale | Where-Object { $_.agent -in $doneNames }) {
  if ($AutoFix) { $f = Join-Path $board "$($s.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }; Flag 'INFO' "auto-fixed: board entry $($s.agent) marked left (its workflow step finished)" 'Nothing to do.' }
}
foreach ($s in $stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames }) {
  # -AutoFix marks entries silent >= 2 h as left later in this same run: report that, not a WATCH for something already handled
  if ($AutoFix -and ($now - [datetime]$s.beat).TotalHours -ge 2) { Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) silent $([int]($now - [datetime]$s.beat).TotalMinutes) min -> marked left" 'Nothing to do.'; continue }
  Flag 'WATCH' "board entry $($s.agent) ($($s.run)) has no heartbeat for $([int]($now - [datetime]$s.beat).TotalMinutes) min" 'It may have finished without leaving, or be stuck. Cross-check with the workflow journal.' }

# 3. memory gate
$ledger = Join-Path $env:TEMP 'claude-build-gate'
$queue = @(Get-ChildItem (Join-Path $ledger 'queue') -Filter '*.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
$runningB = @(Get-ChildItem $ledger -Filter '*.json' | Where-Object Name -ne 'history.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
$oldest = $queue | Sort-Object { [datetime]$_.since } | Select-Object -First 1
$wait = if ($oldest) { [int]($now - [datetime]$oldest.since).TotalMinutes } else { 0 }
L "gate: $($runningB.Count) running ($((@($runningB | ForEach-Object { "$($_.kind)" }) -join ', '))), $($queue.Count) queued, longest wait $wait min"
if ($wait -ge 30) { Flag 'ACT' "gate: $($oldest.owner) $($oldest.kind) has waited $wait min" 'Memory is the bottleneck: pause starting new agents/workflows, stop idle headless browsers (cleanup.ps1), or ask the user to close big apps. Consider -MaxParallel or fewer agents per wave.' }
elseif ($queue.Count -ge 6) { Flag 'WATCH' "gate: $($queue.Count) builds queued" 'Do not launch more build-heavy agents until the queue drains.' }
$hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
foreach ($k in $hist.Keys) { $last = @($hist[$k] | Select-Object -Last 3); if ($last.Count -eq 3 -and -not ($last | Where-Object { $_.ok })) { Flag 'WATCH' "builds '$k' failed 3 times in a row" 'Look at that agent: repeated failing builds burn memory turns; it may need help or a brief fix.' } }

# 3b. idle emulators: running but no active app test lane and no board claim uses them
$stateFile = Join-Path $rt 'supervise-state.json'
$state = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $state) { $state = @{} }; if (-not $state.idleSince) { $state.idleSince = @{} }
$adb = Join-Path $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }) 'platform-tools\adb.exe'
if (Test-Path $adb) {
  $serials = @(& $adb devices 2>$null | Where-Object { $_ -match '^(emulator-\d+)\s+device' } | ForEach-Object { $Matches[1] })
  $swarmCfg = try { Get-Content (Join-Path $swarm 'swarm.config.json') -Raw | ConvertFrom-Json } catch { $null }
  # Agents own phones through leases (android-swarm\phone.ps1 acquire/release): they boot, wait and shut down phones themselves.
  # The supervisor is only the safety net: (1) a lease whose holder is gone (no live workflow step on that lane, not active on the
  # board, older than 30 min) is released, which shuts the phone down; (2) a running phone with NO lease (booted by hand) and our
  # app closed for 10 min is shut down.
  $P = Join-Path $swarm 'phone.ps1'
  $leaseDir = Join-Path $rt 'phones'
  foreach ($lf in @(Get-ChildItem $leaseDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $ls = Get-Content $lf.FullName -Raw | ConvertFrom-Json
    $laneLive = @($liveLabels | Where-Object { $_ -match "@$([regex]::Escape($ls.lane))$" }).Count
    $boardLive = @($active | Where-Object { $_.agent -eq $ls.agent }).Count
    $age = [int]($now - [datetime]$ls.since).TotalMinutes
    if ($ls.agent -eq 'manual') {   # booted by hand (phone.ps1 acquire -Agent manual): the user owns it; never reclaimed, only a reminder
      if ($age -ge 240) { Flag 'WATCH' "phone $($ls.lane) booted by hand $([int]($age / 60)) h ago is still up" "If you are done with it: & $P release -Agent manual" }
      continue
    }
    if ($laneLive -or $boardLive -or $age -lt 30) { continue }
    if ($AutoFix) { $r = & $P release -Agent $ls.agent 2>&1; Flag 'INFO' "auto-fixed: released orphan phone lease $($ls.lane) held by $($ls.agent) for $age min: $r" 'Its holder is gone (crashed or finished without release).' }
    else { Flag 'ACT' "phone lease $($ls.lane) held by $($ls.agent) for $age min, holder not active" "& $P release -Agent $($ls.agent)" }
  }
  $pkg = if ($swarmCfg) { $swarmCfg.app.package } else { $null }
  foreach ($sr in $serials) {
    $lane = if ($swarmCfg) { ($swarmCfg.lanes | Where-Object { "emulator-$($_.port)" -eq $sr } | Select-Object -First 1).name } else { $null }
    if ($lane -and (Test-Path (Join-Path $leaseDir "$lane.json"))) { $state.idleSince.Remove($sr) | Out-Null; continue }   # leased: its agent decides
    $appRunning = $pkg -and [bool]((& $adb -s $sr shell pidof $pkg 2>$null) -join '').Trim()
    if ($appRunning) { $state.idleSince.Remove($sr) | Out-Null; continue }
    if (-not $state.idleSince.ContainsKey($sr)) { $state.idleSince[$sr] = $now.ToString('o') }
    $idleFor = [int]($now - [datetime]$state.idleSince[$sr]).TotalMinutes
    if ($AutoFix -and $idleFor -ge 10 -and $lane) {
      & (Join-Path $swarm 'swarm-down.ps1') -Lanes $lane -KeepBrowsers | Out-Null
      $state.idleSince.Remove($sr) | Out-Null
      Flag 'INFO' "auto-fixed: shut down unleased emulator $sr ($lane): app closed for $idleFor min" 'Agents get phones with phone.ps1 acquire.'
    } else { Flag $(if ($idleFor -ge 10) { 'ACT' } else { 'WATCH' }) "unleased emulator $sr ($lane): app closed for $idleFor min" "& $(Join-Path $swarm 'swarm-down.ps1') -Lanes $lane -KeepBrowsers (or run supervise with -AutoFix)." }
  }
  # 3c. crashed / hung emulators. Emulators run without a console window (swarm-up.ps1), so a dead one is invisible: its
  # processes stay up holding RAM while adb shows it offline or not at all. Kill: (a) emulator/qemu processes of a lane whose
  # serial is not 'device' and whose newest process is older than 8 min (normal boot < 6 min); (b) an emulator.exe whose qemu
  # child is gone (qemu crashed) for 2+ min.
  if ($swarmCfg) {
    $adbState = @{}; foreach ($ln in @(& $adb devices 2>$null)) { if ($ln -match '^(emulator-\d+)\s+(\S+)') { $adbState[$Matches[1]] = $Matches[2] } }
    $emuProcs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'emulator%' OR Name LIKE 'qemu-system%'" -ErrorAction SilentlyContinue)
    foreach ($ln in $swarmCfg.lanes) {
      $sr = "emulator-$($ln.port)"
      $mine = @($emuProcs | Where-Object { $_.CommandLine -match "-port\s+$($ln.port)\b" })
      if (-not $mine.Count) { continue }
      $youngest = [int](($mine | ForEach-Object { ($now - $_.CreationDate).TotalMinutes } | Measure-Object -Minimum).Minimum)
      $qemu = @($mine | Where-Object Name -like 'qemu-system*')
      $why = if ($adbState[$sr] -ne 'device' -and $youngest -ge 8) { "adb shows it '$(if ($adbState[$sr]) { $adbState[$sr] } else { 'absent' })' $youngest min after start (crashed or hung)" }
             elseif (-not $qemu.Count -and $youngest -ge 2) { "emulator.exe is up but its qemu process is gone (crashed)" }
      if (-not $why) { continue }
      $leased = Test-Path (Join-Path $leaseDir "$($ln.name).json")
      if ($AutoFix) {
        $mine | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Flag 'INFO' "auto-fixed: killed dead emulator $sr ($($ln.name)): $why$(if ($leased) { '; its lease holder re-boots it on its next phone.ps1 acquire' })" 'Nothing to do.'
      } else { Flag 'ACT' "dead emulator $sr ($($ln.name)): $why" "Kill it: & $(Join-Path $swarm 'swarm-down.ps1') -Lanes $($ln.name) -KeepBrowsers (or run supervise with -AutoFix)." }
    }
  }
}
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile

# 4. machine
$tot = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB; $avail = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).AvailableMBytes / 1KB
$pct = [int](100 * (1 - $avail / $tot)); L "memory: $pct% used, $([math]::Round($avail,1)) GB available"
if ($pct -ge 90) { Flag 'ACT' "RAM $pct% used" 'Hold new launches; run cleanup.ps1; check for orphaned java/node/chrome from finished agents.' }
$drive = $KitConf.Workspace.Substring(0, 1)   # the drive the workspace (repos, worktrees, runtime) lives on
$disk = Get-PSDrive $drive; $freeGB = [math]::Round($disk.Free / 1GB); L "disk ${drive}: $freeGB GB free"
if ($freeGB -lt 30) { Flag 'ACT' "disk ${drive}: only $freeGB GB free" 'Run cleanup.ps1; remove finished worktrees.' }
$gl = Join-Path $rt 'guard.log'
$blocks = @(Get-Content $gl | Where-Object { $_ -match '^(\S+)\t' -and ($now - [datetime]$Matches[1]).TotalMinutes -lt 60 })
if ($blocks.Count -ge 3) { Flag 'WATCH' "guard blocked $($blocks.Count) commands in the last hour" 'Agents are tripping a rule: read guard.log; add a contracts note or a lesson so they stop.' }

# 5. ONE heartbeat does the housekeeping too (no separate crons): tracker statuses, stale board entries, due cleanup
if ($AutoFix) {
  $S = Split-Path $PSCommandPath
  # who (an active board agent, heartbeat < 30 min) has this MR's source branch checked out in one of its worktrees?
  function OwnerOf($repo, $iid) {
    $proj = if ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$repo" } else { $repo }
    $src = (glab api "projects/$([uri]::EscapeDataString($proj))/merge_requests/$iid" 2>$null | ConvertFrom-Json).source_branch
    if (-not $src) { return $null }
    foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 30 })) {
      foreach ($w in @($e.worktrees)) {
        $paths = if ([IO.Path]::IsPathRooted("$w")) { @("$w") } else { @($KitConf.WorktreeRoots | ForEach-Object { Join-Path $_ "$w" }) }
        foreach ($wp in $paths) { if ((Test-Path $wp) -and (git -C $wp branch --show-current 2>$null) -eq $src) { return $e.agent } }
      }
    }
    $null
  }
  foreach ($l in @(& "$S\track.ps1" run)) {
    if ($l -match '^(DONE|COMMENTED)') { Flag 'INFO' "auto-fixed: $l" 'Tracker moved the task; nothing to do.' }
    elseif ($l -match '^HOLD') { Flag 'INFO' $l 'Merge/promotion waits for the review or fix round; it resumes by itself.' }
    elseif ($l -match '^ATTENTION .*no solution/testing comment') { Flag 'ACT' $l 'Post the solution, MR links and how-to-test steps on the task (clickup comment add <id> "<text>").' }
    elseif ($l -match '^ATTENTION .* (?<repo>[\w.-]+)!(?<iid>\d+) opened \((conflict|pipeline \w+)\)' -and ($owner = OwnerOf $Matches.repo $Matches.iid)) {
      Flag 'INFO' "$l - being handled by $owner" 'An active agent has that MR branch checked out; re-check next round.'
    }
    elseif ($l -match '^ATTENTION') { Flag 'ACT' $l 'A tracked MR failed its pipeline, was closed or has merge conflicts (a sibling MR changed the same lines): get it fixed or rebased (resume its agent with RESUME_BRIEF; the agent may have stopped).' }
  }
  # promoted tasks whose MRs went live on a test environment: QA can start now (never guess "not deployed yet" by hand)
  $D = Join-Path (Split-Path (Split-Path $S)) 'qa-kit\scripts\deployed.ps1'
  foreach ($f in Get-ChildItem (Join-Path $rt 'tracking') -Filter '*.json') {
    $o = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable
    if (-not $o.done -or $o.liveOn -or -not $o.doneAt -or ($now - [datetime]$o.doneAt).TotalDays -gt 3) { continue }
    if ($o.liveCheckedAt -and ($now - [datetime]$o.liveCheckedAt).TotalMinutes -lt 10) { continue }   # deploys take > 10 min; don't re-ask the git host every run
    $rows = @(& $D -Mrs (@($o.mrs) -join ',') -Json | ConvertFrom-Json)
    $o.liveCheckedAt = $now.ToString('o')
    $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -ne 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
    if ($live.Count) { $o.liveOn = @($live) }
    $o | ConvertTo-Json -Depth 5 | Set-Content $f.FullName
    $covered = if ($live.Count) { @(Get-ChildItem (Join-Path $rt 'qa-runs') -Recurse -Filter 'run.json' -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($o.task) } | ForEach-Object { $_.Directory.Name }) } else { @() }
    if ($live.Count -and $covered.Count) {   # a QA run already has it (often closed already): nothing to launch
      Flag 'INFO' "LIVE $($o.task) on $($live -join ', '), already in QA run $($covered -join ', ')" 'Covered; nothing to do.'
    }
    elseif ($live.Count) {
      Flag 'ACT' "LIVE $($o.task): all MRs ($(@($o.mrs) -join ', ')) deployed to $($live -join ', ')" 'Ready for QA: add it to a /test-and-close run (retest its failed checks) unless a run already covers it.'
    }
  }
  foreach ($s in $stale | Where-Object { ($now - [datetime]$_.beat).TotalHours -ge 2 }) {   # finished without `leave`
    $f = Join-Path $board "$($s.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }
  }
  # under memory pressure clean now (idle Gradle/Kotlin daemons alone held ~6 GB at 91%); otherwise only when due
  if ($pct -ge 85) { foreach ($l in @(& "$S\cleanup.ps1" | Select-Object -First 1)) { Flag 'INFO' "auto-fixed: RAM $pct% -> cleanup.ps1: $l" 'Re-check memory next round.' } }
  else { & "$S\cleanup.ps1" -IfDue -Quiet }
}

# 6. new bug tasks raised by QA that no bug-fix agent owns yet (parents taken from the QA runs' tracker config)
$parents = @(Get-ChildItem (Join-Path $rt 'qa-runs') -Directory | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'run.json') -Raw | ConvertFrom-Json).tracker.parent } catch {} } | Where-Object { $_ } | Select-Object -Unique)
$tracked = @(Get-ChildItem (Join-Path $rt 'tracking') -Filter '*.json' | ForEach-Object BaseName)
# New QA bug tasks are fixed at once, all open ones in ONE wave. $openRuns only adds a note that a run is still testing.
$openRuns = @{}
foreach ($rd in Get-ChildItem (Join-Path $rt 'qa-runs') -Directory | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }) {
  try { $rj = Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { continue }
  $left = @($rj.items | Where-Object { -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) }).Count   # held.json = skipClose item finished
  if ($left -and $rj.tracker.parent) { $openRuns[$rj.tracker.parent] = "$($rd.Name) ($left item(s) left)" }
}
foreach ($par in $parents) {
  $subs = (clickup task view $par --json 2>$null | ConvertFrom-Json).subtasks
  $new = @($subs | Where-Object { $_.name -match '^\[Bug\].*failed checks' -and $_.status.status -in 'Open', 'to do' -and $_.id -notin $tracked })
  if (-not $new.Count) { continue }
  $list = ($new | ForEach-Object { "$($_.id) $($_.name.Substring(0, [math]::Min(70, $_.name.Length)))" }) -join '; '
  # Fix at once (the owner's standing mandate: QA bugs are fixed without waiting to be asked) - but as ONE wave for every bug open
  # right now, not one wave per bug. A still-running QA run is only mentioned: later bugs from it go into the next wave.
  $note = if ($openRuns[$par]) { " (run $($openRuns[$par]) is still testing: later bugs go into the next wave)" } else { '' }
  Flag 'ACT' "$($new.Count) new QA bug task(s) not being fixed$note`: $list" "Start the fixes now as ONE wave: & $PSScriptRoot\bug-brief.ps1 -Task <id> -Agent B-<code> -Repos <repos> [-Hints ...] per task (writes the brief, starts tracking, prints /dev-wave args incl. mandate), combine the briefs into one file with a section per agent, then launch a single /dev-wave."
}

# 7. capacity: scale QA workers with memory. Seats (qa-kit\scripts\qa-seat.ps1) already hold new agents back while free RAM < keepFreeGB,
#    so shrinking is automatic. Growing: if a QA run has items nobody has started and memory has room, say how many extra workers fit.
$keepFree = try { $v = (Get-Content (Join-Path $skills 'qa-kit\targets.local.json') -Raw | ConvertFrom-Json).keepFreeGB; if ($v) { [double]$v } else { 8 } } catch { 8 }
$freeNow = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
$seatDir = Join-Path $rt 'qa-seats'
$seatsNow = @(Get-ChildItem (Join-Path $seatDir 'seats') -Filter *.json -ErrorAction SilentlyContinue).Count
$waitNow = @(Get-ChildItem (Join-Path $seatDir 'wait') -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddMinutes(-3) }).Count
L "qa seats: $seatsNow taken, $waitNow waiting for memory; free RAM $freeNow GB"
foreach ($rd in Get-ChildItem (Join-Path $rt 'qa-runs') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-8) }) {
  $run = try { Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { $null }
  if (-not $run) { continue }
  $queued = @($run.items | Where-Object { $_.lane -ne 'app' -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) -and
      -not (Test-Path (Join-Path $seatDir "claims\$($rd.Name)__$($_.code).json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\shots")) } | ForEach-Object code)
  if (-not $queued) { continue }
  # a run launched before seats/claims existed: its agents don't claim items, so an extra worker would test the same items twice
  $legacy = @($run.items | Where-Object { (Test-Path (Join-Path $rd.FullName "$($_.code)\shots")) -and -not (Test-Path (Join-Path $seatDir "claims\$($rd.Name)__$($_.code).json")) }).Count
  if ($legacy) { continue }
  $room = [math]::Floor(($freeNow - $keepFree) / 1.5)          # a web tester needs ~1.5 GB; keep keepFreeGB free
  if ($room -ge 2 -and $waitNow -eq 0) {
    $n = [math]::Min($room, $queued.Count)
    Flag 'INFO' "capacity: $($rd.Name) has $($queued.Count) queued item(s) ($($queued -join ', ')) and room for ~$room more QA agents ($freeNow GB free)" "Add workers: Workflow test-and-close with args { runDir: '$($rd.FullName)', kitDir: '$($KitConf.Kit)', instance: 'w<next>', webParallel: $n, only: [$(($queued | ForEach-Object { "'$_'" }) -join ', ')] } - item claims stop two runs testing the same item."
  } elseif ($freeNow -lt $keepFree) { Flag 'WATCH' "memory tight ($freeNow GB free): QA seats are holding new agents back" 'Do not launch more agents until it recovers; close big apps if it persists.' }
}

$out = [pscustomobject]@{ at = $now.ToString('s'); summary = @($lines); flags = @($flags) }
if ($Json) { $out | ConvertTo-Json -Depth 4; exit 0 }
"=== supervise $($now.ToString('HH:mm')) ==="; $lines
if ($flags.Count) { '--- FLAGS'; $flags | Sort-Object { @{ ACT = 0; WATCH = 1; INFO = 2 }[$_.level] } | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" } } else { '--- no flags: all good' }
$global:LASTEXITCODE = 0
