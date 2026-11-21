<#
supervise_resources.ps1 (core): the machine's shared resources in bossy.ps1, dot-sourced by bossy.ps1
(skills/bossy/adapters/): build gate holders and queue, test locks, repeated build failures, the file cache flush (gate.cacheFlush),
phone leases, env leases, QA seats and claims, test browsers and their profiles, idle daemons (cleanup.idleDaemons), the RAM rows of
the supervise report, agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills), the report page (dashboard + Statistics from the logs; supervise.output, publish), seats and leases in board show and recover, the status resource rows, STUCK, pause and silent-run flags, release (every lease of an agent), launch: pauses it releases, a buildy launch's item tasks (-Self / -Check), stop-learn; sessions: several coordinators (run
owners for pause / resume / recover, a stepped-aside session's own flags, task claims), the step-age handoff.
Its hooks run inside the bossy.ps1 verb that calls them and use that verb's variables: supervise ($now, $mem, $keepFree, Within,
Left), cleanup ($now, $DryRun, $actions, Gone, Old).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L16 builds · L60 supervise · L361 shells · L540 page · L1061 release · L1106 lines · L1138 cleanup · L1205 launch ·
  L1322 pause · L1441 heartbeat · L1456 sessions · L1508 ci tasks ·
  L1566 the kit origin's default branch (kitBranch, else origin/HEAD)
#>
#Requires -Version 7
# ---- builds: repeated failures, cache flush
# keys with 3 failed builds in a row -> @{ key; who }, unless 60+ min old, agent gone or it built that dir green since
function Get-KitBuildFailures($Hist, [datetime]$Now, $Log = @(), [int]$Minutes = 60) {
  if (-not $Hist) { return }
  foreach ($k in @($Hist.Keys)) {
    $last = @($Hist[$k] | Select-Object -Last 3)
    if ($last.Count -ne 3 -or ($last | Where-Object { $_.ok }) -or -not $last[-1].at -or ($Now - [datetime]$last[-1].at).TotalMinutes -ge $Minutes) { continue }
    $failAt = [datetime]$last[-1].at; $dir = ($k -split '\|', 2)[-1]; $ends = @($Log | Where-Object { $_.event -eq 'end' -and $_.at })
    $who = @($ends | Where-Object { "$($_.kind)|$($_.project)" -eq $k -and [int]$_.code } | ForEach-Object owner)[-1]
    if ($who -and ((Test-KitLive @{ agent = $who }) -eq $false -or @($ends | Where-Object { $_.owner -eq $who -and -not [int]$_.code -and [datetime]$_.at -gt $failAt -and ("$($_.project)" -eq $dir -or "$($_.project)" -like "$dir/*" -or $dir -like "$($_.project)/*") }).Count)) { continue }
    [pscustomobject]@{ key = $k; who = $who }
  }
}
# over gate.buildsPerHour: the batching rule to that owner's inbox, once an hour (its gate prints it: a workflow step never beat it in)
function Send-KitBuildsRule([string]$Owner, [int]$N, [int]$Max, [datetime]$Now) {
  if (-not (Test-KitBoardAgent $Owner)) { return }   # a worktree-name owner: nobody reads its inbox
  $f = Get-InboxFile $Owner; $last = @(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { "$($_.ref)" -eq 'gate.buildsPerHour' } }) | Select-Object -Last 1
  if ($last -and ($Now - [datetime]$last.at).TotalMinutes -lt 60) { return "sent $(([datetime]$last.at).ToString('HH:mm'))" }
  Send-BoardMsg 'supervise' $Owner "$N gated builds in the last hour (gate.buildsPerHour $Max): batch your fixes into one rebuild; only the changed module and named tests (-Tests); a flaky test rerun alone; no build per small edit (crafty SKILL.md Rules, Builds)" 'rule' 'gate.buildsPerHour'
  "sent $($Now.ToString('HH:mm'))"
}
# gate head waited 10+ min, file cache 25%+ of RAM: run gate.cacheFlush (e.g. an elevated task), max once per 30 min
function Invoke-KitCacheFlush([int]$WaitMin, $Mem, [datetime]$Now, [int]$TimeoutSec = 120) {
  $cmd = "$(Get-KitSetting 'gate.cacheFlush' '')".Trim()
  if (-not $cmd -or $WaitMin -lt 10) { return }
  $stamp = Join-Path (Get-KitPath cache -Create) 'cache-flush.stamp'
  if ((Test-Path $stamp) -and ($Now - (Get-Item $stamp).LastWriteTime).TotalMinutes -lt 30) { return }
  $cacheGB = try {
    if ($KitIsWindows) { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop).SystemCacheResidentBytes / 1GB }   # \Memory\System Cache Resident Bytes
    elseif (Test-Path /proc/meminfo) { [double](([regex]::Match((Get-Content /proc/meminfo -Raw), '(?m)^Cached:\s+(\d+)')).Groups[1].Value) / 1MB }   # kB
    else { 0 }
  } catch { 0 }
  if ($cacheGB -lt 0.25 * $Mem.TotalGB) { return }
  Set-Content $stamp $Now.ToString('o')
  $r = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-Command', $cmd) $TimeoutSec
  if ($r.timedOut -or $r.code) {
    $why = if ($r.timedOut) { "timed out after $TimeoutSec s" } else { "exit $($r.code): $(@("$($r.err)`n$($r.out)" -split "`n" | Where-Object { $_.Trim() })[0])" }
    return [pscustomobject]@{ level = 'WATCH'; what = "file cache flush failed ($why)"; action = 'Check kit.local.json gate.cacheFlush; the gate keeps waiting for RAM.' }
  }
  $after = $Mem.AvailGB
  for ($i = 0; $i -lt [math]::Min(5, [int]($TimeoutSec / 2)) -and $after -lt $Mem.AvailGB + 0.5; $i++) { Wait-KitPoll 2; $after = (Get-SysMem).AvailGB }   # a scheduled task flushes after its start returns
  [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: file cache flush: available $([math]::Round($Mem.AvailGB, 1)) -> $([math]::Round($after, 1)) GB"; action = 'Nothing to do.' }
}

# ---- supervise: resource flags and report rows
# a run is live while a holder lives or its folder was written within stuckMinutes (a resumed run keeps its folder; lib Get-KitWorkflowStop)
function Test-KitRunLive($Dir, $Records) {
  if (@($Records | Where-Object { $_ -and (Test-KitHolder $_) -eq $true }).Count) { return $true }
  $q = (Get-Date).AddMinutes(-[double](Get-KitParam 'supervise.stuckMinutes')); "$Dir" -and [bool]@(Get-ChildItem -LiteralPath "$Dir" -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $q).Count
}
# STUCK rows (agents and steps, not their run): WATCH, ACT from 3x the threshold
function Get-KitStuckFlags($Rows, [datetime]$Now, [double]$StuckMin) {
  foreach ($r in @($Rows | Where-Object { $_.state -eq 'STUCK' -and -not $_.left })) {   # a run with running steps: its steps are the rows
    $m = if ($r.last) { [int]($Now - [datetime]$r.last).TotalMinutes } else { [int]::MaxValue }
    [pscustomobject]@{ level = $(if ($m -ge 3 * $StuckMin) { 'ACT' } else { 'WATCH' }); kind = 'STUCK'; who = "$($r.name) ($($r.task))"; age = $(if ($m -lt [int]::MaxValue) { "$m min" }); problem = "no progress$(if ($m -eq [int]::MaxValue) { ' for its whole run' }), nothing it waits on"; what = "STUCK $($r.name) ($($r.task)): no progress for $(if ($m -lt [int]::MaxValue) { "$m min" } else { 'its whole run' }), nothing it waits on"; action = "Read its transcript tail; resume it with RESUME_BRIEF or $($r.next -replace '^.*; resume it or ')." }
  }
}
# /testy has no live lead (2026-11-21): a tester's question in <qa-runs>/<run>/lead-notes.md ("- HH:mm CODE: ...?", pokey.ps1 lead-notes add)
# with no later line of its code, older than qa.questionWatchMinutes = a WATCH the coordinator answers
function Get-KitQaQuestionFlags([datetime]$Now = (Get-Date)) {
  $after = [double](Get-KitParam 'qa.questionWatchMinutes')
  foreach ($nf in @(Get-ChildItem -LiteralPath (Get-KitPath qa-runs) -Filter 'lead-notes.md' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $Now.AddHours(-24))) {
    $ls = @(Get-Content -LiteralPath $nf.FullName -Encoding utf8 | ForEach-Object { if ($_ -match '^- (\d\d):(\d\d) (\S+?): (.+)$') { [pscustomobject]@{ t = $nf.LastWriteTime.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]); c = $Matches[3]; x = $Matches[4].Trim() } } })
    for ($i = 0; $i -lt $ls.Count; $i++) { $q = $ls[$i]; if ($q.x -notmatch '\?$' -or @($ls | Select-Object -Skip ($i + 1) | Where-Object c -eq $q.c).Count) { continue }
      $age = ($Now - $q.t).TotalMinutes; if ($age -lt 0) { $age += 1440 }; if ($age -lt $after) { continue }   # a line from before midnight
      $run = Split-Path $nf.DirectoryName -Leaf
      [pscustomobject]@{ level = 'WATCH'; kind = 'QA QUESTION'; who = "$run $($q.c)"; age = "$([int]$age) min"; problem = $q.x; what = "QA QUESTION · $run $($q.c): $($q.x)"
        action = "Answer it: pokey.ps1 lead-notes add -RunDir $($nf.DirectoryName) -Code $($q.c) -Text '<answer>'" } } }
}
# every ACT / WATCH flag's age (owner 2026-11-19) = since its text (Get-KitFlagKey: counts vary) first showed; supervise-state
# flagSeen keeps first + last seen, an entry unseen for 2 h drops (a skipped section keeps its age); a producer's own age wins
function Set-KitFlagAge($Flags, $State, [datetime]$Now) {
  $seen = if ($State.flagSeen -is [Collections.IDictionary]) { $State.flagSeen } else { @{} }; $keep = @{}
  foreach ($f in @($Flags | Where-Object { $_.level -in 'ACT', 'WATCH' })) { $k = Get-KitFlagKey "$($f.what)"
    $first = try { ([datetime]$seen[$k].first).ToString('o') } catch { $Now.ToString('o') }; $keep[$k] = @{ first = $first; last = $Now.ToString('o') }   # ISO, never a culture string
    if (-not "$($f.age)".Trim()) { $f | Add-Member -Force NoteProperty age "$([int][math]::Max(0.0, ($Now - [datetime]$first).TotalMinutes)) min" } }
  foreach ($k in @($seen.Keys)) { if (-not $keep.ContainsKey($k) -and $(try { ($Now - [datetime]$seen[$k].last).TotalHours -lt 2 } catch { $false })) { $keep[$k] = $seen[$k] } }
  $State.flagSeen = $keep
}
# a guard deny's agent: its own agent field, else the status row whose transcript names its subagent id or session, else the session
function Get-KitDenyWho($D, $Rows) {
  if ("$($D.agent)".Trim()) { return "$($D.agent)" }; $id = "$($D.agentId)"; $sid = "$($D.session)"
  $r = @($Rows | Where-Object { $_.tx -and (($id -and "$($_.tx)".Contains($id)) -or ($sid -and [IO.Path]::GetFileNameWithoutExtension("$($_.tx)") -eq $sid)) })[0]
  if ($r) { ("$($r.name)" -split ' ')[0] } elseif ($sid) { "session $($sid.Substring(0, [math]::Min(8, $sid.Length)))" } else { 'unknown' }
}
# an active pause whose runs work (relaunched by hand): their agents stop next beat
function Get-KitPauseFlags($Pauses, $Active, [int]$WfAgents) {
  foreach ($p in @($Pauses | Where-Object { $_.state -eq 'paused' })) {
    $hit = @($Active | Where-Object { -not $_.paused -and ($_.run -eq $p.run -or ($p.run -eq '*' -and $_.run -notin @($p.released))) } | ForEach-Object run | Select-Object -Unique)
    if ($hit.Count -or ($p.run -eq '*' -and $WfAgents)) { [pscustomobject]@{ level = 'ACT'; what = "pause $(Split-Path "$($p.file)" -Leaf) ($($p.reason), since $(([datetime]$p.at).ToString('HH:mm'))) is active while run(s) work: $(if ($hit) { $hit -join ', ' } else { "$WfAgents workflow agent(s)" }); their agents stop at the next beat"; action = "Reason gone: & $($KitCmd.orch) resume -All (or -Run <run>); else pause those runs again." } }
  }
}
# a run silent 2+ days with unfinished agents: one WATCH ($Quiet remembers it), then skipped
function Get-KitSilentRun([string]$Name, [double]$SilentHours, $Quiet, [datetime]$Now) {
  if ($SilentHours -lt 48) { $Quiet.Remove($Name); return [pscustomobject]@{ skip = $false; flag = $null } }   # alive again: a later silence flags anew
  $flag = $null
  if (-not $Quiet.ContainsKey($Name)) {
    $Quiet[$Name] = $Now.ToString('o')
    $flag = [pscustomobject]@{ level = 'WATCH'; what = "run $Name silent $([int]($SilentHours / 24)) days with unfinished agents"; action = "Resume it (bossy.ps1 recover -RunId $Name) or let it go: this flag does not repeat" }
  }
  [pscustomobject]@{ skip = $true; flag = $flag }
}
# flags, sweep lines, report rows, largest waiting build (section 3, before the slow ones)
function Get-KitSuperviseGuardResources([switch]$AutoFix) {
  $flag = { param($level, $what, $action) [pscustomobject]@{ level = $level; what = $what; action = $action } }
  $rows = [Collections.Generic.List[object]]::new(); $graceRows = @{}

  # build gate: holders, queue, repeated failures; a holder in its grace shows its minutes left
  $ledger = Get-KitGateLedger
  $queue = @(Get-ChildItem (Join-Path $ledger 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $t = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($t -and (Test-KitPid $t.pid $t.start)) { $t } })
  $builds = @(Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { $t = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($t -and (Test-KitPid $t.pid $t.start)) { $t } })
  foreach ($t in @($builds | Where-Object { $_.gate })) {   # holder = its gate process (then its owner agent)
    $bl = @{ agent = $t.owner; pid = $t.gate; seen = $t.seen }; $keep = Update-KitLease $bl; if ("$($bl.seen)" -ne "$($t.seen)") { $t | Add-Member -Force seen $bl.seen; $t | ConvertTo-Json | Set-Content (Join-Path $ledger "$($t.pid).json") }
    $bp = Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue; if (-not $bp -or $bp.StartTime -gt ([datetime]$t.started).AddSeconds(5)) { continue }   # pid reused: not ours
    if ($keep) { if ($null -ne $bl.graceLeft) { $graceRows["build $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"] = $bl.graceLeft }; continue }
    if ($AutoFix) { $t | Add-Member -Force reclaimed "reclaim: no live holder for $($bl.graceMin) min"; $t | ConvertTo-Json | Set-Content (Join-Path $ledger "$($t.pid).json"); Stop-KitProcessTree $bp; & $flag 'INFO' "auto-fixed: stopped build $($t.kind) of $($t.owner) (pid $($t.pid)): no live holder" 'Nothing to do.' }
    else { & $flag 'ACT' "build $($t.kind) of $($t.owner) (pid $($t.pid)) runs with no live holder" 'supervise -AutoFix stops it.' }
  }
  $oldest = $queue | Sort-Object { [datetime]$_.since } | Select-Object -First 1
  $wait = if ($oldest) { [int]($now - [datetime]$oldest.since).TotalMinutes } else { 0 }
  "gate: $($builds.Count) running ($((@($builds | ForEach-Object { "$($_.kind)" }) -join ', '))), $($queue.Count) queued, longest wait $wait min"
  if ($wait -ge 30) { & $flag 'ACT' "gate: $($oldest.owner) $($oldest.kind) has waited $wait min" 'Memory-bound: start no new agents, run bossy.ps1 cleanup, ask the owner to close big apps; fewer agents per wave.' }
  elseif ($queue.Count -ge 6) { & $flag 'WATCH' "gate: $($queue.Count) builds queued" 'Do not launch more build-heavy agents until the queue drains.' }
  $hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
  $bLog = @(Read-KitLog builds $now.AddHours(-24)); $bph = [int](Get-KitParam 'gate.buildsPerHour')
  foreach ($bo in @(Get-KitBuildsByOwner @($bLog | Where-Object { $_.event -eq 'end' -and $_.at -and [datetime]$_.at -ge $now.AddHours(-1) }) | Where-Object { $bph -gt 0 -and $_.n -gt $bph })) {
    $sent = if ($AutoFix) { try { Send-KitBuildsRule $bo.name $bo.n $bph $now } catch { } }
    [pscustomobject]@{ level = 'WATCH'; what = "builds: $($bo.name) ran $($bo.n) gated builds ($($bo.min) build-min, $($bo.failed) failed) in the last hour, over gate.buildsPerHour $bph"; kind = 'BUILDS'; who = $bo.name
      problem = "$($bo.name): $($bo.n) builds in an hour"; next = $(if ($sent) { "Rule $sent to its inbox (its next gated build and beat print it); still over next hour: stop and brief it" } else { 'Tell that agent: one rebuild per batch of fixes, named tests only, a flaky test rerun alone' })
      action = 'crafty SKILL.md Rules "Builds": only what the change needs, fixes batched into one rebuild.' } }
  foreach ($bfx in Get-KitBuildFailures $hist $now $bLog) {
    $k = $bfx.key; $who = $bfx.who
    [pscustomobject]@{ level = 'WATCH'; what = "builds '$k' failed 3 times in a row"; kind = 'BUILDS'; who = $(if ($who) { $who } else { $k }); problem = "$k failed 3 times in a row"; next = "Check that agent's last build log"
      action = 'Repeated failing builds burn memory and turns; a setup-data cause (fixture, seed drift) -> spawn datay kind fixture, else help it or fix its brief.' } }
  if ($AutoFix -and (Within 'cache flush')) { Invoke-KitCacheFlush $wait $mem $now ([math]::Min(120.0, (Left))) }

  # phone leases with no live holder (dead emulators reboot on acquire)
  foreach ($lf in @(Get-ChildItem (Get-KitPath phones) -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $ls = try { Get-Content $lf.FullName -Raw | ConvertFrom-Json } catch { continue }; $age = [int]($now - [datetime]$ls.since).TotalMinutes
    if ($ls.agent -eq 'manual') {
      if ($age -ge 240) { & $flag 'WATCH' "phone $($ls.lane) booted by hand $([int]($age / 60)) h ago is still up" "If you are done with it: & $($KitCmd.swarm) release -Agent manual" }
      continue
    }
    if ($ls.agent -eq '__stopping__') { continue }
    $s0 = "$($ls.seen)"; $keep = Update-KitLease $ls
    if ($keep -and (-not $s0 -or ([datetime]$ls.seen - [datetime]$s0).TotalMinutes -ge 1) -and (Test-Path $lf.FullName)) { $ls | ConvertTo-Json -Depth 5 | Set-Content "$($lf.FullName).sv"; Move-Item "$($lf.FullName).sv" $lf.FullName -Force }   # atomic, never resurrects
    if ($keep) { if ($null -ne $ls.graceLeft) { $graceRows["phone $($ls.lane)"] = $ls.graceLeft }; continue }
    if ($AutoFix -and (Test-Path $KitCmd.swarm)) { $r = Invoke-KitLeaseReason "reclaim: no live holder for $($ls.graceMin) min" { & $KitCmd.swarm release -Agent $ls.agent 2>&1 }; & $flag 'INFO' "auto-fixed: reclaimed phone $($ls.lane) of $($ls.agent) (no live holder): $r" 'Nothing to do.' }
    else { & $flag 'ACT' "phone lease $($ls.lane) held by $($ls.agent): no live holder" "& $($KitCmd.swarm) release -Agent $($ls.agent)" }
  }
  # worktree slot leases with no live holder: released (uncommitted work -> a WIP commit, else parked for its branch)
  foreach ($lf in @(Get-ChildItem (Get-KitPath wt-slots) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $ls = try { Get-Content $lf.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($ls -isnot [pscustomobject] -or -not $ls.slot) { continue }   # a slot lease only, never another file in the folder
    if ($ls.parked) { $pa = [datetime]$(if ($ls.parkedAt) { $ls.parkedAt } else { $ls.since }); if (($now - $pa).TotalHours -ge 24) { & $flag 'WATCH' "slot $($ls.slot) parked $([int]($now - $pa).TotalHours) h: $($ls.parkedWhy)" "Its branch's next agent resumes it (crafty.ps1 wt lease -Branch $($ls.branch)); else commit or drop the files in $($ls.path), then wt release -Dir $($ls.path)" }; continue }
    $s0 = "$($ls.seen)"; $keep = Update-KitLease $ls
    if ($keep -and "$($ls.seen)" -ne $s0 -and (Test-Path $lf.FullName)) { Write-KitAtomic $lf.FullName ($ls | ConvertTo-Json -Depth 5) }
    if ($keep) { if ($null -ne $ls.graceLeft) { $graceRows["slot $($ls.slot)"] = $ls.graceLeft }; continue }
    if ($AutoFix) { $r = Invoke-KitLeaseReason "reclaim: no live holder for $($ls.graceMin) min" { & $KitCmd.dev wt release -Dir $ls.path 2>&1 | Select-Object -Last 1 }; & $flag 'INFO' "auto-fixed: released slot $($ls.slot) of $($ls.agent) (no live holder): $r" 'Nothing to do.' }
    else { & $flag 'ACT' "slot $($ls.slot) held by $($ls.agent): no live holder" "& $($KitCmd.dev) wt release -Dir $($ls.path)" }
  }
  # env leases: envy.ps1 status prunes (and logs) holderless ones past the grace, unless the local-env guard ran it
  if ($AutoFix -and $null -eq $script:KitEnvStatus -and (Within 'env leases')) { $null = Get-KitLocalEnvStatus }

  # QA seats / claims of gone sessions (a line per session), orphan browser tabs
  $seatDir = Get-KitPath qa-seats
  $goneSeats = @(foreach ($sf in @(Get-ChildItem (Join-Path $seatDir 'seats'), (Join-Path $seatDir 'claims') -Filter *.json -ErrorAction SilentlyContinue)) {
      $so = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $null }
      if ($so -and (Test-KitHolder $so) -eq $false) { [pscustomobject]@{ file = $sf.FullName; holder = "$($so.holderPid)"; what = "$(Split-Path $sf.DirectoryName -Leaf)/$($sf.BaseName)" } }
    })
  foreach ($g in $goneSeats | Group-Object holder) {
    $what = "$($g.Count) QA seat/claim file(s) of gone session process $($g.Name): $((@($g.Group | Select-Object -First 3 | ForEach-Object what)) -join ', ')$(if ($g.Count -gt 3) { ', …' })"
    if ($AutoFix) { $g.Group | ForEach-Object { Remove-Item $_.file -Force }; & $flag 'INFO' "auto-fixed: freed $what" 'Nothing to do.' }
    else { & $flag 'WATCH' $what 'supervise -AutoFix frees them.' }
  }
  if ($AutoFix -and (Within 'browser tabs') -and (Test-Path (Join-Path $KitConf.Kit 'skills/pokey/node_modules/puppeteer-core')) -and @(Get-ChildItem (Get-KitPath sessions) -Filter 'tabs-*.json' -ErrorAction SilentlyContinue).Count) {
    $r = Invoke-KitExe 'node' @('--input-type=module', '-e', "const m = await import('$([Uri]::new((Join-Path $KitConf.Kit 'skills/pokey/browser.mjs')).AbsoluteUri)'); console.log(await m.sweepAll())") (Left)
    if ($r.code -eq 0 -and "$($r.out)".Trim() -match '^[1-9]\d*$') { & $flag 'INFO' "auto-fixed: closed $($r.out.Trim()) orphan browser tab(s) (holder gone or left the board)" 'Nothing to do.' }
  }
  $taken = @(Get-ChildItem (Join-Path $seatDir 'seats') -Filter *.json -ErrorAction SilentlyContinue).Count   # total = taken + web seats the free RAM above the floor still fits
  "qa seats: $taken taken of $($taken + [math]::Max(0, [int][math]::Floor(([double]$mem.AvailGB - $keepFree) / [math]::Max(0.1, [double](Get-KitParam 'qa.seatGB' -Context web)))))"

  # RAM rows: browsers, phones, builds; one process snapshot, each counted once
  $ps = @(Get-KitSweepProcs); $kids = @{}; $byId = @{}; foreach ($p in $ps) { $kids[$p.ParentId] = @($kids[$p.ParentId]) + $p; $byId[$p.Id] = $p }
  $seen = @{}; $tree = { param($r) $g = 0.0; $st = [Collections.Stack]::new(); $st.Push($r); while ($st.Count) { $q = $st.Pop(); if (-not $q -or $seen[$q.Id]) { continue }; $seen[$q.Id] = 1; $g += $q.WorkingSet; foreach ($c in @($kids[$q.Id])) { if ($c) { $st.Push($c) } } }; $g / 1GB }
  $ports = try { Get-Content (Get-KitPath browser-ports) -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $ports) { $ports = @{} }; $keyOf = @{}; foreach ($k in $ports.Keys) { $keyOf["$($ports[$k])"] = $k }
  $isBrowser = { param($p) $p.Name -match '^(chrome|msedge|chromium)(\.exe)?$' }
  foreach ($b in @($ps | Where-Object { (& $isBrowser $_) -and -not ($byId[$_.ParentId] -and (& $isBrowser $byId[$_.ParentId])) })) {
    if ($b.CommandLine -notmatch '--remote-debugging-port=(\d+)' -or -not $keyOf[$Matches[1]]) { continue }
    $k = $keyOf[$Matches[1]]; $tf = Get-Item (Join-Path (Get-KitPath sessions) "tabs-$($k -replace '\|', '__').json") -ErrorAction SilentlyContinue; $tabs = try { Get-Content $tf.FullName -Raw | ConvertFrom-Json } catch { $null }
    $idleM = ($now - $(if ($tabs._idle) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$tabs._idle).LocalDateTime } else { [datetime]$b.Created })).TotalMinutes   # no tab holder since (browser.mjs sweep)
    if ($AutoFix -and $tabs._idle -and -not @((Get-KitProps $tabs) | Where-Object Name -notmatch '^_').Count -and $idleM -ge [double](Get-KitParam 'idle.graceMinutes')) {
      Stop-KitProcessTree (Get-Process -Id $b.Id -ErrorAction SilentlyContinue); & $flag 'INFO' "auto-fixed: closed test browser $k (no tab holder for $([int]$idleM) min)" 'Nothing to do.'; continue
    }
    $rows.Add([pscustomobject]@{ name = "browser $(($k -split '\|' | Where-Object { $_ }) -join '·')"; by = (@((Get-KitProps $tabs) | Where-Object { $_.Name -ne '_key' -and $_.Value.agent } | ForEach-Object { $_.Value.agent }) | Select-Object -Unique) -join ', '; gb = & $tree $b; pid = $b.Id })
  }
  $lanes = try { (Get-Content (Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json') -Raw | ConvertFrom-Json).lanes } catch { @() }
  foreach ($p in @($ps | Where-Object { $_.Name -match '^emulator' -and $_.CommandLine -match '-port\s+(\d+)' })) {
    # its own -port: $Matches after the filter above holds the last process's port (all three emulators were "phone Falcon");
    # no lane config (a kit worktree): the AVD name, which is the lane name (phoney avd create), never the serial
    $port = if ($p.CommandLine -match '-port\s+(\d+)') { $Matches[1] }; $ln = @($lanes | Where-Object { "$($_.port)" -eq $port })[0]
    $nm = if ($ln) { $ln.name } elseif ($p.CommandLine -match '-avd\s+"?([^\s"]+)') { $Matches[1] } else { "emulator-$port" }
    $ls = try { Get-Content (Join-Path (Get-KitPath phones) "$nm.json") -Raw | ConvertFrom-Json } catch { $null }
    $rows.Add([pscustomobject]@{ name = "phone $nm"; by = $(if ($ls) { $ls.agent } else { 'no lease' }); gb = & $tree $p; pid = $p.Id })
  }
  foreach ($wq in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalMinutes -lt 3 })) {   # queued / booting lanes
    $w = try { Get-Content $wq.FullName -Raw | ConvertFrom-Json } catch { continue }
    $held = @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.agent -eq $w.agent })[0]
    $rows.Add([pscustomobject]@{ name = "phone $(if ($held) { $held.lane } elseif ($w.lane) { $w.lane } else { 'next lane' })"; by = "$($w.agent) $(if ($held) { '(waiting for RAM)' } else { '(waiting for a lane)' })"; gb = 0 })
  }
  foreach ($sl in @(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.slot })) { $rows.Add([pscustomobject]@{ name = "slot $($sl.slot)"; by = $(if ($sl.parked) { "parked: $($sl.branch)" } else { "$($sl.agent) ($($sl.branch))" }); gb = 0 }) }   # one naming scheme: <pool>·<bird>
  foreach ($ev in @($script:KitEnvStatus | Where-Object { $_.env })) { $hs = @($ev.leases | Where-Object { $_.agent } | ForEach-Object agent); if ($hs.Count) { $rows.Add([pscustomobject]@{ name = "env $(Get-KitPoolLabel env $ev.env)"; by = $hs -join ', '; gb = 0 }) } }
  foreach ($t in @($builds | Where-Object { $_.kind -ne 'emulator' })) { $p = $byId[[int]$t.pid]; $rows.Add([pscustomobject]@{ name = "build $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"; by = $t.owner; gb = $(if ($p) { [math]::Max((& $tree $p), 0.1) } else { [double]$t.need }); pid = [int]$t.pid }) }
  $lks = Get-KitLockState   # repos[].exclusiveTests locks: holder + waiters (their RAM: the build rows)
  foreach ($k in @($lks.held.Keys)) { $h = $lks.held[$k]; $wn = @($lks.waiting | Where-Object { $_.lock -eq $k }); $rows.Add([pscustomobject]@{ name = "lock $k"; by = "$($h.holder) since $(([datetime]$h.at).ToString('HH:mm'))$(if ($wn.Count) { "; waiting: $(@($wn | ForEach-Object { $_.holder }) -join ', ')" })"; gb = 0 }) }
  foreach ($r in $rows) { if ($graceRows.ContainsKey($r.name)) { $r.by = "$($r.by) (grace $($graceRows[$r.name]) min)" }; $r }
  foreach ($x in @(Read-KitLog leases $now | Where-Object { $_.event -eq 'reclaim' -and $_.kind -in 'env', 'tab' })) { & $flag 'INFO' "auto-fixed: reclaimed $($x.kind) $($x.name) of $($x.agent) ($($x.reason))" 'Nothing to do.' }   # the env and tab sweeps above log, not print
  # idle holders: any leased resource (gpu, local-ai, lock, tab, ...) whose holders all went quiet 3x idle.graceMinutes (the kinds with a reclaim above end sooner)
  $quietMin = 3 * [double](Get-KitParam 'idle.graceMinutes')
  # quiet counts from the first beat that saw no live holder (an acquire row has no `seen`: its age alone flagged a holder dead 1 min)
  $idf = Join-Path (Get-KitPath cache -Create) 'idle-holders.json'; $idOld = try { Get-Content -LiteralPath $idf -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $idOld) { $idOld = @{} }; $idNew = @{}
  foreach ($ir in @(Get-KitResourceRows $now.AddHours(-24) | Where-Object { $null -ne $_.quiet })) {
    $idAt = if ($idOld[$ir.resource]) { [datetime]$idOld[$ir.resource] } else { $now }; $idNew[$ir.resource] = $idAt.ToString('o')
    $q = [int][math]::Min([double]$ir.quiet, ($now - $idAt).TotalMinutes)
    if ($q -ge $quietMin) { & $flag 'WATCH' "$($ir.resource) held by $($ir.holder): no live holder for $q min" "bossy.ps1 release -Agent $(@("$($ir.holder)" -split ', ')[0]) frees it (README Leases)" } }
  Write-KitAtomic $idf ($idNew | ConvertTo-Json -Compress)
  $need = [double](@(@($queue | ForEach-Object { [double]$_.need }) + 0) | Measure-Object -Maximum).Maximum
  if ($need) { [pscustomobject]@{ ramNeed = $need } }   # bossy.ps1 names the biggest rows of every adapter
}

# kit to-do (bossy K1): open "- [ ]" lines in <agents>/kitty/kit-*.md and no kitty on the board = nobody works them
function Get-KitSuperviseFlagsKitTodo([switch]$AutoFix, $Board = $entries) {
  $td = Join-Path (Get-KitPath agents) 'kitty'; if (-not (Test-Path $td) -or @($Board | Where-Object { $_.status -ne 'left' -and $_.beat -and ((Get-Date) - [datetime]$_.beat).TotalHours -lt [double](Get-KitParam 'supervise.kittyLiveHours') -and ($_.type -eq 'kitty' -or "$($_.agent)" -match '^kitty') }).Count) { return }
  $n = @(Get-ChildItem $td -Filter 'kit-*.md' -File | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_ -match '^\s*[-*] \[ \]' }).Count
  if ($n) { [pscustomobject]@{ level = 'ACT'; what = "kit to-do has $n open item(s), no kitty live"; action = "Spawn kitty (kind fix) on $td\kit-*.md (bossy K1)." } }
}

# a WATCH per prior-gate override this beat (Assert-KitPrior) whose hits hold other work; none logged: flagged
function Get-KitSuperviseFlagsPrior([switch]$AutoFix) {
  $briefs = $null
  foreach ($e in @(Read-KitLog calls (Get-Date).AddMinutes(-(Get-KitBeatMinutes)) | Where-Object event -eq 'prior-override')) {
    $hits = ''
    if ($e.PSObject.Members['matched']) {
      if ($null -eq $briefs) { $briefs = @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { -not $_.completed -and $_.args.brief } | ForEach-Object { "$(Get-Content -LiteralPath $_.args.brief -Raw -ErrorAction SilentlyContinue)`n$($_.args | ConvertTo-Json -Depth 8 -Compress)" }) }
      $other = @(Get-KitPriorForeign $e $briefs); if (-not $other.Count) { continue }
      $hits = ": matches $(@($other | ForEach-Object { "$($_.kind) $($_.ref)" }) -join ', ')"
    }
    [pscustomobject]@{ level = 'WATCH'; what = "prior override: $($e.what) $($e.task) ($($e.reason))$hits"; action = 'Check it is no duplicate (crafty.ps1 prior -Task <id>); a duplicate: stop it, reuse the existing work' }
  }
}
# hits not its own (tagged), named in a live launch with it or as a sibling subtask
function Get-KitPriorForeign($Entry, [string[]]$Briefs) {
  $tag = "$($KitConf.TrackerTag)"; $has = { param($t, $id) "$t" -match "(?i)(?<![A-Za-z0-9])$([regex]::Escape("$id"))(?![A-Za-z0-9])" }   # whole ids: 7 is not in 17
  $parentOf = { param($id) "$((Read-KitState (Get-KitTaskFile "$id")).spec.parent)" }; $parentOf0 = & $parentOf $Entry.task
  # K46: a reason naming the hit's id, or its own task id against one hit, was weighed by id, not fuzzy text: no WATCH (6+ a day)
  $ownOne = $Entry.task -and (& $has $Entry.reason $Entry.task) -and @($Entry.matched | Where-Object { $_ }).Count -eq 1
  foreach ($h in @($Entry.matched | Where-Object { $_ })) {
    if ($h.tagged -or (& $has $h.ref "$tag$($Entry.task)") -or $ownOne -or (& $has $Entry.reason $h.ref)) { continue }
    $tid = if ($h.kind -eq 'task') { "$($h.ref)" } elseif ($tag -and "$($h.ref)" -match "(?i)$([regex]::Escape($tag))([A-Za-z0-9]+)") { $Matches[1] }
    $sib = $tid -and $parentOf0 -and (& $parentOf $tid) -eq $parentOf0
    if ($tid -and @($Briefs | Where-Object { $_ -and (& $has $_ $tid) -and ($sib -or (& $has $_ $Entry.task)) }).Count) { continue }
    $h
  }
}
# NO MRS (ended runs only): mrs [] saying not done; stale when another step of its item (local:, fix:, ship:) has MRs,
# or a named done / deferred task is open in tracking with an MR in its worktrees' repo (none known: any repo); -Tracking: tests
function Test-KitNoMrs($Started, $Results, [string]$Label, $Result, [string]$Summary, $Tracking) {
  if ($null -eq $Result.mrs -or @($Result.mrs).Count -or $Summary -notmatch '(?i)not done|no MRs') { return $false }
  $itemOf = { param($l) (([string]$l -split ':', 2)[-1] -split '@')[0] }; $item = & $itemOf $Label
  if (@($Results | Where-Object { $rid = $_.agentId; @($_.result.mrs).Count -and (& $itemOf ($Started | Where-Object agentId -eq $rid | Select-Object -First 1).label) -eq $item }).Count) { return $false }
  if (-not $Tracking) { if ($null -eq $script:KitTrackNoMrs) { $script:KitTrackNoMrs = Read-KitTracking }; $Tracking = $script:KitTrackNoMrs }
  $repos = @($Result.worktrees | Where-Object { $_ } | ForEach-Object { ("$_" -split '[\\/]')[-1] })
  foreach ($tid in @(@($Result.deferred) + @($Result.done) | ForEach-Object { if ($_.id) { $_.id } else { $_ } } | Where-Object { $_ } | Select-Object -Unique)) {
    foreach ($m in @($Tracking.tasks["$tid"] | Where-Object { -not $_.done } | ForEach-Object { $_.mrs } | Where-Object { $_ })) { $rp = ("$m" -split '!')[0]; if (-not $repos.Count -or @($repos | Where-Object { $_ -eq $rp -or $_ -like "*-$rp" }).Count) { return $false } }
  }
  $true
}
# status rows: agents waiting for the build gate, a test lock or a phone lane
function Get-KitStatusWaitResources {
  foreach ($t in @(Get-ChildItem (Join-Path (Get-KitGateLedger) 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.owner -and (Test-KitPid $_.pid $_.start) })) {
    [pscustomobject]@{ agent = $t.owner; why = "build gate: RAM for $($t.kind)"; at = $t.since; next = 'the gate starts it when RAM frees' }
  }
  foreach ($w in @((Get-KitLockState).waiting)) { [pscustomobject]@{ agent = $w.holder; why = "test lock $($w.lock)"; at = $w.at; next = 'crafty.ps1 check takes it when its holder ends' } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 })) {
    $w = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }; [pscustomobject]@{ agent = $w.agent; why = "phone lane$(if ($w.lane) { " $($w.lane)" })"; at = $f.LastWriteTime; next = 'phoney.ps1 acquire hands it a lane' }
  }
}
# a row per resource from leases.jsonl (holder = unreleased acquire < 24 h old; lanes from lease files)
# -Since: only rows logged from then (supervise: the 24 h of holds, not the whole 1 MB log a beat); quiet = minutes no holder lived
function Get-KitResourceRows([datetime]$Since = [datetime]::MinValue) {
  $held = [ordered]@{}; $last = @{}; $lf = Get-KitLogFile leases
  foreach ($x in @(if (Test-Path -LiteralPath $lf) { Get-KitLogLines $lf $Since })) {
    $o = try { $x | ConvertFrom-Json } catch { continue }; $r = "$($o.kind)|$($o.name)"
    if ($o.event -eq 'acquire' -and $o.kind -ne 'build' -and ((Get-Date) - [datetime]$o.at).TotalHours -lt 24) { if (-not $held[$r]) { $held[$r] = @{} }; $held[$r]["$($o.agent)"] = $o; continue }
    if ($o.event -ne 'down') { $last[$r] = $o }; if (-not $held[$r]) { $held[$r] = @{} }; if ($o.event -eq 'down') { $held[$r].Clear() } else { $held[$r].Remove("$($o.agent)") }
  }
  foreach ($p in @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.lane -and $_.agent -ne '__stopping__' })) { $held["lane|$($p.lane)"] = @{ "$($p.agent)" = [pscustomobject]@{ agent = $p.agent; session = $p.session; holder = $p.holder; at = $p.since; seen = $p.seen } } }
  foreach ($r in @($held.Keys)) {
    $hs = @($held[$r].Values); if ($r -like 'build|*') { continue }
    $live = @($hs | Where-Object { Test-KitLive @{ agent = $_.agent; session = $_.session; holder = $_.holder } })
    $rk, $rn = $r -split '\|', 2
    [pscustomobject]@{ key = $r; agents = @($hs | ForEach-Object { "$($_.agent)" }); resource = "$rk $((Get-KitPoolLabel $rk $rn) -replace '\|', ' ')"; holder = $(if ($hs.Count) { @($hs.agent) -join ', ' } else { 'free' })
      since = @($hs | ForEach-Object { $(if ($_.since) { $_.since } else { $_.at }) } | Where-Object { $_ } | Sort-Object)[0]
      seen = $(if ($live.Count) { 'live now' } elseif ($hs.Count) { "$(if (@($hs.seen | Where-Object { $_ })) { "$(([datetime]@($hs.seen | Where-Object { $_ })[0]).ToString('HH:mm')), " })no live holder" } else { '—' })
      used = Format-KitLeaseLast $last[$r]
      quiet = $(if ($hs.Count -and -not $live.Count) { $qt = @(@($hs | ForEach-Object { $_.seen; $_.since; $_.at }) | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]; if ($qt) { [int]((Get-Date) - $qt).TotalMinutes } }) }
  }
}
function Format-KitResourceTable($Rows) {
  if (-not @($Rows).Count) { return }
  ''; '| Resource | Holder | Since | Last seen | Last used |'; '|---|---|---|---|---|'
  foreach ($r in @($Rows | Sort-Object resource)) { "| $($r.resource) | $($r.holder) | $(if ($r.since) { ([datetime]$r.since).ToString('HH:mm') } else { '—' }) | $($r.seen) | $($r.used) |" }
}

# ONE WATCH for the owner's MRs merged in 24 h that no task tracks; each repo's host list cached 2 beats (min 30 min), the login a day
# per repo, at most 2 lists a beat, oldest first: 4 lists in one beat took 15 s of a 40 s sweep; a cut-short beat keeps the rest's lists
function Get-KitUntrackedMrFlag($State, [datetime]$Now, [scriptblock]$Within = { $true }) {
  $um = $State.untrackedMrs; if (-not $um -or $um.repos -isnot [Collections.IDictionary]) { $um = @{ user = "$($um.user)"; repos = @{} } }
  $ttl = [math]::Max(30.0, 2 * (Get-KitBeatMinutes)); $since = $Now.ToUniversalTime().AddHours(-24).ToString('o')
  $due = @(@(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ -and (-not $um.repos[$_] -or ($Now - [datetime]$um.repos[$_].at).TotalMinutes -ge $ttl) } |
    Sort-Object { if ($um.repos[$_]) { [datetime]$um.repos[$_].at } else { [datetime]::MinValue } } | Select-Object -First 2)
  if ($due.Count) {
    $hu = if ($State.hostUser.v -and ($Now - [datetime]$State.hostUser.at).TotalHours -lt 24) { $State.hostUser.v } else { $x = try { Get-KitHostUser } catch { '' }; if ($x) { $State.hostUser = @{ at = $Now.ToString('o'); v = $x } }; $x }
    if ($hu -and $hu -ne $um.user) { $um = @{ user = $hu; repos = @{} } }
    foreach ($rp in @(if ($hu) { $due })) {
      if (-not (& $Within)) { break }
      $got = $null; try { $got = @(Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = $since; per_page = 50 }) } catch { }; if ($null -eq $got) { continue }   # failed: retried next beat (an empty list is a result)
      $um.repos[$rp] = @{ at = $Now.ToString('o'); mrs = @(foreach ($m in @($got | Where-Object { $_.iid })) {
            @{ repo = $rp; iid = "$($m.iid)"; title = "$($m.title)"; branch = "$($m.source_branch)"; target = "$($m.target_branch)"; author = $(if ($m.author.username) { $m.author.username } else { "$($m.author)" }); merged_at = "$($m.merged_at)" } }) }
    }
    $State.untrackedMrs = $um
  }
  $um = @{ user = $um.user; mrs = @($um.repos.Values | ForEach-Object { $_.mrs }) }
  $tr = Read-KitTracking; $cut = $Now.ToUniversalTime().AddHours(-24)
  $ig =@{ tasks = @{ ignored = @{ mrs = @((Read-KitState (Get-KitPath mr-ignore)).mrs.Keys) } } }   # track ignore: not the owner's work
  $known = if ($State.known) { @($State.known.Keys) } else { @() }   # supervise -Ack on this flag: one decision per MR
  $un = @($um.mrs | Where-Object { $_ -and $um.user -and $_.author -eq $um.user -and -not (Test-KitDeployMr $_.repo $_.branch $_.target) -and $_.merged_at -and ([datetimeoffset]$_.merged_at).UtcDateTime -ge $cut -and "$($_.repo)!$($_.iid)" -notin $known -and -not (Test-KitMrTracked $_.repo $_.iid $tr) -and -not (Test-KitMrTracked $_.repo $_.iid $ig) })
  if (-not $un.Count) { return }
  $tg = Get-KitTaskTagRx; $refs = @($un | ForEach-Object { "$($_.repo)!$($_.iid)" })
  $adds = @($un | ForEach-Object { $tid = if ($tg -and "$($_.branch) $($_.title)" -match $tg) { $Matches.id } else { '<task>' }; "& $($KitCmd.orch) track add -Task $tid -Mrs '$($_.repo)!$($_.iid)'" })
  # cells are cut at 90 chars: full commands in the report's "All flags"
  [pscustomobject]@{ level = 'WATCH'; what = "$($un.Count) MR(s) of $($um.user) merged in 24 h tracked by no task: $(@($un | ForEach-Object { "$($_.repo)!$($_.iid) ($("$($_.title)".Substring(0, [math]::Min(50, "$($_.title)".Length))))" }) -join '; ')"
    action = "Link each to its task: $($adds -join '; ')$(if ($adds -match '<task>') { " (no task yet: & $($KitCmd.dev) tracker create -Spec <json> (crafty.ps1 'task spec'), never free text)" }); then track run (no task: supervise -Ack; not the owner's: track ignore -Mrs <MR> -Reason '<why>')."; kind = 'UNTRACKED MR'; who = $um.user; problem = "$(@($refs | Select-Object -First 5) -join ', ')$(if ($refs.Count -gt 5) { " +$($refs.Count - 5)" }) merged, no task"; next = 'track add -Task <id> -Mrs <MR> each (full: report)'; refs = $refs }
}

# ---- shells: agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills)
# one process snapshot per sweep
function Get-KitSweepProcs { if ($null -eq $script:KitSweepProcs) { $script:KitSweepProcs = @(Get-SysProcs) }; $script:KitSweepProcs }
# command: body of the harness's eval '...' (bash), else after -Command / -c
function Get-KitShellCommand([string]$CommandLine) {
  $c = "$CommandLine"
  if ($c -match "(?s)\beval '(.*)'\s*(<\s*/dev/null\s*)?&&\s*pwd -P" -or $c -match "(?s)\beval '(.*)'") { return ($Matches[1] -replace "'\\''", "'" -replace '\\"', '"').Trim() }
  if ($c -match '(?i)\s-e(?:c|n[a-z]*)?\s+([A-Za-z0-9+/=]{8,})') { try { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])).Trim() } catch {} }
  if ($c -match '(?is)\s-(?:c|Command)\s+(.*)$') { return ($Matches[1].Trim() -replace '^"(.*)"$', '$1' -replace '\\"', '"').Trim() }
  ($c -replace '^\s*("[^"]*"|\S+)\s*', '').Trim()
}
# table cell: quoting undone, cd / export preambles skipped, heredoc as "<cmd> <<EOF (heredoc, N lines)", 60 chars
function Get-KitShellShort([string]$Cmd) {
  $lines = @(("$Cmd" -replace "'""'""'", "'" -replace "'\\''", "'") -split "`r?`n"); $pre = '^\s*(?:(?:cd|Set-Location|pushd|export)\s+(?:"[^"]*"|''[^'']*''|[^\s;&]+)[^;&]*|\$env:\w+\s*=\s*[^;&]+)\s*(?:&&|;|$)\s*'
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $s = $lines[$i]; for ($n = 0; $n -lt 9 -and $s -match $pre; $n++) { $s = $s -replace $pre, '' }
    if (-not $s.Trim()) { continue }
    if ($s -match '<<-?\s*[''"]?(\w+)[''"]?') {
      $w = $Matches[1]; $end = $lines.Count; for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].Trim() -eq $w) { $end = $j; break } }
      $s = "$($s.Substring(0, $s.IndexOf('<<')).Trim()) <<$w (heredoc, $($end - $i - 1) lines)"
    }
    $s = ($s -replace '\s+', ' ').Trim(); return $(if ($s.Length -gt 60) { $s.Substring(0, 59) + '…' } else { $s })
  }
  "$Cmd".Trim()
}
# work dir: first cd, else -Dir (Git Bash /d/x -> D:/x); '' if unknown or relative
function Get-KitShellDir([string]$Cmd) {
  if ($Cmd -notmatch '(?:^|[\s;&|(])(?:cd|Set-Location|pushd)\s+("[^"]+"|''[^'']+''|[^\s;&|)]+)' -and $Cmd -notmatch '\s-Dir\s+("[^"]+"|''[^'']+''|[^\s;&|)]+)') { return '' }
  $d = $Matches[1].Trim('"', "'"); if ($KitIsWindows) { $d = $d -replace '^/([A-Za-z])(?=/|$)', '$1:' }
  if ($d -match '[$%`~]' -or ($KitIsWindows -and $d -notmatch '^[A-Za-z]:[\\/]|^\\\\') -or -not [IO.Path]::IsPathRooted($d)) { return '' }; $d
}
# shells whose parent is Claude Code (claude, or node running it); never this sweep's own chain
function Get-KitAgentShells($Procs) {
  $byId = @{}; foreach ($p in $Procs) { $byId[$p.Id] = $p }
  $mine = @{}; $q = $byId[$PID]; for ($i = 0; $q -and -not $mine[$q.Id] -and $i -lt 64; $i++) { $mine[$q.Id] = 1; $q = $byId[$q.ParentId] }
  foreach ($p in $Procs) {
    $par = $byId[$p.ParentId]
    if ($p.Name -match '^(bash|sh|zsh|pwsh|powershell)(\.exe)?$' -and -not $mine[$p.Id] -and $par -and ($par.Name -match '^claude(\.exe)?$' -or ($par.Name -match '^node(\.exe)?$' -and "$($par.CommandLine)" -match '(?i)claude-code|@anthropic-ai[\\/]claude|[\\/]claude(\.exe|\.js|\.mjs)?(\s|"|$)'))) { $p }
  }
}
# per new shell (key -> cmd, created): the transcript whose tool_use ran it, nearest its start ($null: none). One listing; per file
# only its last 16 MB (append-only: a new shell's line is near the end), searched with IndexOf (a Select-String per shell over the
# 90 MB coordinator transcript cost 20 s a sweep)
function Find-KitShellTranscripts([hashtable]$Want) {
  $out = @{}; $frags = @{}
  foreach ($k in @($Want.Keys)) { $f = "$(@([regex]::Matches($Want[$k].cmd, '[^"\\\r\n\t]{8,}') | Sort-Object Length -Descending)[0])"; if ($f) { $frags[$k] = $f.Substring(0, [math]::Min(120, $f.Length)) } }
  $r = Invoke-KitAdapter transcript claude root; if (-not $frags.Count -or -not $r.dir -or -not (Test-Path -LiteralPath $r.dir)) { return $out }
  $from = @($frags.Keys | ForEach-Object { $Want[$_].created } | Sort-Object)[0].AddMinutes(-1)
  foreach ($file in @(Get-ChildItem -LiteralPath $r.dir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $from } | ForEach-Object FullName)) {
    $text = Read-KitFileTail $file 16MB
    foreach ($k in @($frags.Keys)) {
      for ($i = $text.IndexOf($frags[$k], [StringComparison]::Ordinal); $i -ge 0; $i = $text.IndexOf($frags[$k], $e, [StringComparison]::Ordinal)) {
        $s0 = $text.LastIndexOf("`n", $i) + 1; $e = $text.IndexOf("`n", $i); if ($e -lt 0) { $e = $text.Length }; $line = $text.Substring($s0, $e - $s0)
        if ($line -notmatch '"tool_use"' -or ($line -match '"timestamp":"([^"]+)"' -and [math]::Abs(([datetimeoffset]$Matches[1] - [datetimeoffset]$Want[$k].created).TotalSeconds) -gt 120)) { continue }   # parse only lines near the shell's start
        $o = try { $line | ConvertFrom-Json -Depth 80 } catch { continue }
        $u = @($o.message.content | Where-Object { $_.type -eq 'tool_use' -and "$($_.input.command)".Contains($frags[$k]) })[0]; if (-not $u) { continue }
        $gap = if ($o.timestamp) { [math]::Abs(([datetimeoffset]$o.timestamp - [datetimeoffset]$Want[$k].created).TotalSeconds) } else { 1e9 }
        # K104: a Monitor tool call is a background shell too (no run_in_background key; 21 outlived their agents)
        $mon = "$($u.name)" -eq 'Monitor'
        if ($gap -le 120 -and (-not $out[$k] -or $gap -lt $out[$k].gap)) { $out[$k] = [pscustomobject]@{ file = $file; bg = ([bool]$u.input.run_in_background -or $mon); mon = $mon; gap = $gap; tuid = "$($u.id)"; out = (Find-KitShellOutputPath $text "$($u.id)") } }
      }
    }
  }
  $out
}
# owner: main transcript = coordinator; step finished = journal result; subagent = .meta.json finished (also set while idling on
# its shell); board entry: finished once left, live while its holder runs
function Get-KitShellOwner([string]$Tx, $Board) {
  if (-not $Tx) { return [pscustomobject]@{ name = 'unknown'; finished = $false; coordinator = $false } }
  $full = { param($x) [IO.Path]::GetFullPath("$x").TrimEnd('\', '/') }
  if ((& $full (Split-Path $Tx)) -eq (& $full (Invoke-KitAdapter transcript claude root).dir)) { return [pscustomobject]@{ name = 'coordinator'; finished = $false; coordinator = $true } }
  $e = @($Board | Where-Object { $_.transcript -and (& $full $_.transcript) -eq (& $full $Tx) } | Sort-Object { [datetime]$_.joined })[-1]
  $name = $e.agent; $fin = $e.status -eq 'left'; $id = if ($Tx -match 'agent-(\w+)\.jsonl$') { $Matches[1] } else { '' }
  $j = Join-Path (Split-Path $Tx) 'journal.jsonl'
  if (Test-Path -LiteralPath $j) {
    foreach ($l in @(Select-String -LiteralPath $j -SimpleMatch "`"$id`"" | ForEach-Object { try { $_.Line | ConvertFrom-Json } catch {} })) { if ($l.type -eq 'started' -and -not $name) { $name = (($l.label -split ':', 2)[-1] -split '@')[0] }; if ($l.type -eq 'result') { $fin = $true } }
  } else { $m = try { Read-KitText ($Tx -replace '\.jsonl$', '.meta.json') | ConvertFrom-Json } catch { $null }; if (-not $name) { $name = $m.agentType }; if ($m.finished) { $fin = $true } }
  $live = ($e -and $e.status -ne 'left' -and (Test-KitHolder $e) -ne $false) -or ($name -and (Test-KitLive ([pscustomobject]@{ agent = "$name" })) -eq $true)   # a running workflow step, gated command or fresh board entry
  [pscustomobject]@{ name = $(if ($name) { "$name" } else { "agent $id" }); finished = [bool]$fin; coordinator = $false; live = [bool]$live; last = (Get-KitLastActivity $Tx $e "$($e.tool)") }
}
# ORPHAN: owner finished and not live (Test-KitLive), tree not busy, idle idle.graceMinutes; or dir gone. STALLED: no CPU, IO or output
# growth (CPU vs the last sweep; CPU + IO between this sweep's two samples; its output file) for supervise.shellStuckMinutes.
# -AutoFix kills on the 2nd gone sweep, or the 1st if no poll loop and owner idle 20+ min. -ReadOnly (bossy.ps1 shells): no kill, no learning;
# -SampleAll: the sample pair for every shell (else only for shells with no CPU or output growth since the last sweep).
# A shell gone since the last sweep stays in $State.shells as ended (owner, last line, killed) for supervise.finishedMinutes.
function Get-KitShellSweep($State, [datetime]$Now, [switch]$AutoFix, $Procs = $(Get-KitSweepProcs), [scriptblock]$Sampler = { param($ids) Get-KitProcSample $ids }, [double]$GapSeconds = 2, [switch]$ReadOnly, [switch]$SampleAll) {
  $graceMin = [double](Get-KitParam 'idle.graceMinutes'); $pollRx = '(^|[\s;&|(])(until|while|for)\s|\bsleep\s+[-\d]|\bglab api\b|\bgh run watch\b|--watch\b|\bpipes\b|\b(envy|pokey|bossy)\.ps1\s+(\w+\s+)*wait\b'
  $stuckMin = [double](Get-KitParam 'supervise.shellStuckMinutes'); $old = if ($State.shells -is [Collections.IDictionary]) { $State.shells } else { @{} }; $new = @{}
  $kids = @{}; foreach ($p in $Procs) { if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[object]]::new() }; $kids[$p.ParentId].Add($p) }
  $gated = @(Read-KitJsonFiles (Get-KitGateLedger) | Where-Object { Test-KitPid $_.pid $_.start } | ForEach-Object { "$($_.pid)" })
  $board = @(Read-KitJsonFiles (Get-KitPath board)); $rows = [Collections.Generic.List[object]]::new(); $flags = [Collections.Generic.List[object]]::new()
  $shells = @(Get-KitAgentShells $Procs); $made0 = { param($p) if ($p.Created) { [datetime]$p.Created } else { $Now } }
  # Git Bash (MSYS) exec leaves a command's Windows parent dead: a process whose parent is gone joins the one shell whose command holds its arguments
  $alive = @{}; foreach ($p in $Procs) { $alive[$p.Id] = 1 }; $shCmd = @{}; foreach ($p in $shells) { $shCmd[$p.Id] = (Get-KitShellCommand $p.CommandLine) -replace '\s+', ' ' }
  if ($shCmd.Count) { foreach ($q in $Procs) {
    if ($alive.ContainsKey($q.ParentId) -or $shCmd.ContainsKey($q.Id)) { continue }
    $tail = ("$($q.CommandLine)" -replace '^\s*("[^"]*"|\S+)\s*', '' -replace '\s+', ' ').Trim(); if ($tail.Length -lt 12) { continue }
    $hit = @($shells | Where-Object { $shCmd[$_.Id].Contains($tail) })
    # K85: a git hook (MSYS sh exec -> its pwsh, parent dead) joins the shell running that git verb
    if (-not $hit.Count -and $tail -match '(?i)\b(pre-?push|pre-?commit|commit-msg|prepare-commit-msg|post-(checkout|merge|rewrite))\b') { $hit = @($shells | Where-Object { $shCmd[$_.Id] -match '\bgit(\.exe)?\s+(?:-\S+\s+(?:[^-\s]\S*\s+)?)*(push|commit|merge|pull|rebase|checkout|switch|cherry-pick|am)\b' }) }
    if ($hit.Count -gt 1 -and $q.Created) { $hit = @($hit | Where-Object { $_.Created -and [datetime]$_.Created -le [datetime]$q.Created } | Sort-Object { [datetime]$_.Created } | Select-Object -Last 1) }   # same command twice: the newest shell started before it
    if ($hit.Count -eq 1) { if (-not $kids.ContainsKey($hit[0].Id)) { $kids[$hit[0].Id] = [Collections.Generic.List[object]]::new() }; $kids[$hit[0].Id].Add($q) } } }
  $want = @{}; foreach ($p in $shells) { $m0 = & $made0 $p; $k0 = "$($p.Id)@$($m0.ToString('s'))"; if (-not ($old[$k0] -is [Collections.IDictionary] -and $old[$k0].ContainsKey('tx'))) { $want[$k0] = @{ cmd = (Get-KitShellCommand $p.CommandLine); created = $m0 } } }
  $found = if ($want.Count) { Find-KitShellTranscripts $want } else { @{} }   # once per shell: the tool_use line is written before the shell starts
  $seen = [Collections.Generic.List[object]]::new(); $trees = @{}
  foreach ($p in $shells) {
    $made = & $made0 $p; $age = ($Now - $made).TotalMinutes; $key = "$($p.Id)@$($made.ToString('s'))"
    $s = if ($old[$key] -is [Collections.IDictionary]) { $old[$key] } else { @{} }; $new[$key] = $s; if ($s.killed) { continue }; $cmd = Get-KitShellCommand $p.CommandLine
    if (-not $s.ContainsKey('tx')) { $f = $found[$key]; $s.tx = "$($f.file)"; $s.bg = [bool]$f.bg; $s.mon = [bool]$f.mon; $s.tuid = "$($f.tuid)"; $s.out = "$($f.out)" }
    if ($s.bg -and -not $s.out -and $s.tuid -and [int]$s.outTries -lt 5) { $s.outTries = [int]$s.outTries + 1; $s.out = Find-KitShellOutputPath (Read-KitFileTail $s.tx 16MB) $s.tuid }   # its tool_result is written after the shell starts
    $tree = @{}; $cpu = 0.0; $st = [Collections.Stack]::new(); $st.Push($p)
    $kc = @{}; while ($st.Count) { $q = $st.Pop(); if ($tree[$q.Id]) { continue }; $tree[$q.Id] = 1; $cpu += [double]$q.Cpu; if ($q -ne $p) { $kc["$($q.Id)@$($q.Created)"] = [double]$q.Cpu }; foreach ($c in @($kids[$q.Id])) { if ($c) { $st.Push($c) } } }
    $flat = $null -ne $p.Cpu -and $null -ne $s.cpu -and [math]::Abs($cpu - [double]$s.cpu) -lt 0.02
    $moved = -not $s.ContainsKey('activeTicks') -or ($null -ne $p.Cpu -and -not $flat)
    # busy (an Agent-tool owner is named by its type, so Test-KitLive misses it): a gated command in the tree, or a child that used 1+ s
    # CPU since last sweep (a new child: in all); a poll loop's sleep / curl children stay under it
    $base = $s.kids -is [Collections.IDictionary]
    $busy = @($tree.Keys | Where-Object { "$_" -in $gated }).Count -or @($kc.Keys | Where-Object { $kc[$_] - $(if ($base -and $s.kids.Contains($_)) { [double]$s.kids[$_] } else { 0 }) -ge 1 }).Count
    $s.cpu = $cpu; $s.kids = $kc; $s.age = [math]::Round($age, 1)
    if (-not $s.bg -and $age -lt 10) { continue }   # a foreground tool call ends within the Bash tool's 10 min cap
    $ot = Get-KitShellOutput $s.out; $outMoved = $ot -and ($ot.bytes -ne [long]$s.outBytes -or $ot.ticks -ne [long]$s.outTicks); if ($ot) { $s.outBytes = $ot.bytes; $s.outTicks = $ot.ticks; $s.last = $ot.last }
    $seen.Add([pscustomobject]@{ p = $p; s = $s; key = $key; made = $made; age = $age; cmd = $cmd; tree = $tree; cpu = $cpu; busy = $busy; moved = ($moved -or $outMoved); ot = $ot })
    if ($SampleAll -or -not ($moved -or $outMoved)) { $trees[$key] = @($tree.Keys) }   # the sample pair (and its wait) only for a shell that looks quiet
  }
  $nowDelta = Measure-KitTreeDelta $trees $Sampler $GapSeconds; $hbMin = [double](Get-KitParam 'supervise.heartbeatMinutes')
  foreach ($r in $seen) {
    $p = $r.p; $s = $r.s; $made = $r.made; $age = $r.age; $cmd = $r.cmd; $tree = $r.tree; $busy = $r.busy; $ot = $r.ot
    $s.listed = $true; $o = Get-KitShellOwner $s.tx $board; $dir = Get-KitShellDir $cmd; $gone = $dir -and -not (Test-Path -LiteralPath $dir)
    $dl = $nowDelta[$r.key]
    $act = $r.moved -or ($dl -and ($dl.cpu -ge 0.02 -or $dl.io -gt 0))
    if ($act -or -not $s.activeTicks) { $s.activeTicks = $Now.Ticks }
    $quiet = [math]::Max(0.0, ($Now.Ticks - [long]$s.activeTicks) / [double][TimeSpan]::TicksPerMinute)
    $stuck = -not $act -and $quiet -ge $stuckMin -and $age -ge $stuckMin
    if (-not $stuck) { $s.stuck = 0; $s.stuckAt = $null } elseif (-not $s.stuckAt -or ($Now - [datetime]$s.stuckAt).TotalMinutes * 2 -ge $hbMin) { $s.stuck = [int]$s.stuck + 1; $s.stuckAt = $Now.ToString('o') }
    $idle = if ($o.last) { ($Now - [datetime]$o.last).TotalMinutes } else { 1e9 }; $poll = $cmd -match $pollRx
    $ownerGone = $o.finished -and -not $o.live -and -not $busy -and $idle -ge $graceMin  # meta "finished" alone also marks an agent idling on this very shell
    if (-not $ownerGone) { $s.gone = 0; $s.goneAt = $null } elseif (-not $s.goneAt -or ($Now - [datetime]$s.goneAt).TotalMinutes * 2 -ge $hbMin) { $s.gone = [int]$s.gone + 1; $s.goneAt = $Now.ToString('o') }
    $why = @($(if ($ownerGone) { "owner $($o.name) finished, idle $([int]$idle) min" }), $(if ($gone) { "dir gone: $dir" }), $(if ($stuck) { "no CPU, IO or output for $([int]$quiet) min, $($s.stuck) sweep(s)" }) | Where-Object { $_ }) -join '; '
    $short = "$(if ($s.mon) { 'monitor: ' })$(Get-KitShellShort $cmd)"; $one = ($cmd -replace '\s+', ' ').Trim(); $s.owner = $o.name; $s.short = $short
    if ($ownerGone -and ($s.gone -ge 2 -or (-not $poll -and $idle -ge 20)) -and $AutoFix -and -not $ReadOnly -and (Test-KitPid $p.Id $made)) {
      if ($KitIsWindows) { taskkill /PID $p.Id /T /F 2>&1 | Out-Null } else { foreach ($t in @($tree.Keys)) { Stop-SysProcess $t } }
      $s.killed = $true; Write-KitLog calls shell-kill ([ordered]@{ pid = $p.Id; owner = $o.name; why = $why; dir = $dir; what = "killed shell $($p.Id) ($why): $($one.Substring(0, [math]::Min(300, $one.Length)))" })
      $flags.Add([pscustomobject]@{ level = 'INFO'; what = "auto-fixed: killed shell $($p.Id) of $($o.name) ($why): $short"; action = 'Nothing to do.' }); continue
    }
    $shellState = @($(if ($ownerGone -or $gone) { 'ORPHAN' }), $(if ($stuck) { 'STALLED' }) | Where-Object { $_ }) -join ', '; if (-not $shellState) { $shellState = 'running' }
    $tk = if ($KitIsWindows) { "taskkill /PID $($p.Id) /T /F" } else { "kill -TERM $($p.Id)" }
    $next = if ($shellState -eq 'running') { '' } elseif ($o.coordinator) { "yours: stop it (KillShell) or $tk" } elseif ($ownerGone) { "supervise -AutoFix kills it next sweep; now: $tk" } elseif ($o.live -or $busy) { "board msg $($o.name) to end it (live agent or busy tree: no taskkill)" } else { "$($o.name) ends it, else $tk" }   # arch-ok: hint text, $tk is per OS
    # progress: tree CPU s, CPU % of one core between the two samples, IO MB, child count, quiet min, output size / age / last line
    $rows.Add([pscustomobject]@{ pid = $p.Id; short = $short; cmd = $cmd; owner = $o.name; age = [math]::Round($age); state = $shellState; next = $next; dir = $dir
      cpu = [math]::Round($r.cpu, 1); cpuNow = $(if ($dl) { $dl.pct }); ioMB = $(if ($null -ne $dl.ioTotal) { [math]::Round($dl.ioTotal / 1MB, 1) }); kids = $tree.Count - 1; quiet = [math]::Round($quiet)
      outKB = $(if ($ot) { [math]::Round($ot.bytes / 1KB) }); outAge = $(if ($ot) { [math]::Round([math]::Max(0.0, ($Now - $ot.at).TotalMinutes)) }); last = "$($s.last)" })
    $s60 = $short.Substring(0, [math]::Min(60, $short.Length))
    if ($shellState -ne 'running') { $flags.Add([pscustomobject]@{ level = 'WATCH'; kind = "SHELL $shellState"; who = $o.name; age = "$([int]$age) min"; problem = "pid $($p.Id) $s60`: $why"; what = "SHELL $shellState pid $($p.Id) of $($o.name) ($s60): $why"; action = $next }) }
  }
  $finMin = [double](Get-KitSetting 'supervise.finishedMinutes' 30)
  foreach ($k in @($old.Keys)) {
    $g = $old[$k]; if ($new.ContainsKey($k) -or $g -isnot [Collections.IDictionary] -or -not $g.listed) { continue }
    if ($g.ended) { if (($Now.Ticks - [long]$g.ended) / [double][TimeSpan]::TicksPerMinute -lt $finMin) { $new[$k] = $g }; continue }
    if (-not $g.killed -and -not $ReadOnly) { Add-KitParamObs 'supervise.shellStuckMinutes' ([double]$g.age) -Default 30 }   # it ended on its own
    $ot = Get-KitShellOutput $g.out; if ($ot) { $g.last = $ot.last; $g.outBytes = $ot.bytes }; $g.ended = $Now.Ticks; $new[$k] = $g   # where it ended
  }
  $State.shells = $new
  [pscustomobject]@{ rows = @($rows); flags = @($flags) }
}
# board leave (owner 2026-11-19: a finished agent's shells die with it): its background shells (the transcript of its board row) are
# killed with their trees; never the leave call's own shell; $Hits / $Kill: tests
function Stop-KitLeftShells($Entry, $Procs = $(Get-KitSweepProcs), $Hits = $null, [scriptblock]$Kill = { param($id) if ($KitIsWindows) { taskkill /PID $id /T /F 2>&1 | Out-Null } else { Stop-SysProcess $id } }) {
  if (-not "$($Entry.transcript)") { return }; $full = { param($x) [IO.Path]::GetFullPath("$x").TrimEnd('\', '/') }
  $sh = @(Get-KitAgentShells $Procs); $want = @{}; foreach ($p in $sh) { $want["$($p.Id)"] = @{ cmd = (Get-KitShellCommand $p.CommandLine); created = $(if ($p.Created) { [datetime]$p.Created } else { Get-Date }) } }
  if ($null -eq $Hits) { $Hits = if ($want.Count) { Find-KitShellTranscripts $want } else { @{} } }
  foreach ($p in $sh) { $hit = $Hits["$($p.Id)"]; if (-not $hit -or -not $hit.bg -or (& $full $hit.file) -ne (& $full $Entry.transcript)) { continue }
    & $Kill $p.Id; Write-KitLog calls shell-kill ([ordered]@{ pid = $p.Id; owner = "$($Entry.agent)"; why = 'its agent left the board' }); "killed $(if ($hit.mon) { 'monitor' } else { 'shell' }) $($p.Id) of $($Entry.agent): $(Get-KitShellShort $want["$($p.Id)"].cmd)" } }
# supervise hook (section 3; uses $state, $now, Within): flags only (a count is no problem); rows go to $script:KitShellRows
function Get-KitSuperviseGuardShells([switch]$AutoFix) {
  $script:KitShellRows = @(); if (-not (Within 'shells')) { return }
  try { $sh = Get-KitShellSweep $state $now -AutoFix:$AutoFix; $script:KitShellRows = $sh.rows; $sh.flags }
  catch { [pscustomobject]@{ level = 'WATCH'; what = "shell sweep failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Get-KitShellSweep.' } }
}

# ---- page: report page and -Brief stdout (supervise.output)
# agents failed a day (null = no calls log): ended board leave -Status failed / blocked / error; closed days from $Prev
function Get-KitSuperviseDays($Prev, [datetime]$Now, [int]$Days = 7, [datetime]$StatsFrom = [datetime]::MinValue) {   # a day before StatsFrom (Get-KitStatsCutoff): no source
  $today = $Now.ToString('yyyy-MM-dd'); $kept = @{}; $cutDay = $StatsFrom.ToString('yyyy-MM-dd'); foreach ($pd in @($Prev | Where-Object { $_.final -and $null -ne $_.failed -and $null -ne $_.left })) { $kept["$($pd.day)"] = [pscustomobject]@{ day = "$($pd.day)"; final = $true; failed = $pd.failed; left = $pd.left } }   # older records: failed + left kept (a record without left: read again once)
  foreach ($i in 0..($Days - 1)) { $day = $Now.AddDays(-$i).ToString('yyyy-MM-dd')
    if ($day -lt $cutDay) { [pscustomobject]@{ day = $day; final = $false; failed = $null; left = $null }; continue }
    if ($kept.ContainsKey($day)) { $kept[$day]; continue }
    $rec = [ordered]@{ day = $day; final = $day -ne $today; failed = $null; left = $null }
    $cf = Join-Path (Get-KitPath audit) "$day/calls.jsonl"
    if (Test-Path -LiteralPath $cf) { $rec.failed = 0; $rec.left = 0; $stOf = @{}   # start event's -Status for its end (rc 'exit' = pwsh exit, success)
      foreach ($ev in @(Select-String -LiteralPath $cf -Pattern '"verb":"board leave"' | ForEach-Object { try { $_.Line | ConvertFrom-Json -ErrorAction Stop } catch { } })) {
        if ($ev.event -eq 'start') { $stOf["$($ev.pid)"] = if ("$($ev.args)" -match '-Status\s+(\w+)') { $Matches[1] } else { 'done' }; continue }
        if ($ev.event -eq 'end' -and "$($ev.rc)" -in '0', 'exit' -and $stOf["$($ev.pid)"] -in 'failed', 'blocked', 'error') { $rec.failed++ }; if ($ev.event -eq 'end' -and "$($ev.rc)" -in '0', 'exit') { $rec.left++ } } }
    [pscustomobject]$rec
  }
}
# RAM free (mem-samples), each drive's free and fill rate (disk lines, storage samples)
function Get-KitSuperviseSeries([string[]]$Lines, $Prev) {
  $thin = { param($vals, [int]$n = 48) $vals = @($vals); if ($vals.Count -le $n) { return $vals }; $step = $vals.Count / $n; foreach ($i in 0..($n - 1)) { $vals[[int][math]::Floor($i * $step)] } }
  $ram = @(Get-Content -LiteralPath (Get-KitPath mem-samples) -Tail 240 -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -match '\t([\d.]+)\s*$') { [double]$Matches[1] } })
  $seen = @{}; $disks = @(foreach ($l in @($Lines)) { if ("$l" -match '^\s*disk (\S+): ([\d.]+) GB free, (?:filling )?([+-]?[\d.]+) GB/h' -and -not $seen.ContainsKey($Matches[1])) {
    $dv = $Matches[1]; $seen[$dv] = 1; $fr = [double]$Matches[2]; $rt = [double]$Matches[3]
    $tot = try { [math]::Round([IO.DriveInfo]::new($dv).TotalSize / 1GB, 1) } catch { $null }
    $sm = if (Get-Command Get-KitStorageSamples -ErrorAction SilentlyContinue) { @(Get-KitStorageSamples $dv 480) } else { @() }
    $h1 = if ($sm.Count) { $hourAgo = @($sm | Where-Object { $_.t -le $sm[-1].t - 3600 })[-1]; if ($hourAgo) { [math]::Round($sm[-1].free - $hourAgo.free, 1) } }   # free now - an hour ago
    [ordered]@{ drive = $dv; at = (Get-Date).ToString('o'); free = $fr; rate = $rt; h1 = $h1; total = $tot; series = @(& $thin @($sm | ForEach-Object free)) } } })
  # no disk line this sweep: the last rows only while under 2 heartbeats old (an old copy passed for today's free space)
  [ordered]@{ ram = @(& $thin $ram); disks = @(if ($disks.Count) { $disks } else { $Prev.disks | Where-Object { $_ -and $_.at -and ((Get-Date) - [datetime]$_.at).TotalMinutes -le 2 * [double](Get-KitParam 'supervise.heartbeatMinutes') } }) }
}
# this sweep's tile values from its lines; null = no line
function Get-KitSuperviseNow([string[]]$Lines, [double]$GraceMinutes = 10) {
  $o = [ordered]@{ wfr = @(); run = 0; done = 0; total = $null; stale = @(); mem = $null; avail = $null; gr = $null; gq = $null; gw = $null; seats = $null; seatsMax = $null; disks = @(); secs = $null; slow = '' }
  $num = { param($s) [double]("$s" -replace ',', '.') }
  foreach ($l in @($Lines | ForEach-Object { "$_" })) {
    if ($l -match '^workflow (\S+): (\d+) agents, (\d+) finished, (\d+) running') { $o.wfr += [ordered]@{ id = $Matches[1]; run = [int]$Matches[4]; done = [int]$Matches[3]; total = [int]$Matches[2] }; $o.total += [int]$Matches[2]; $o.done += [int]$Matches[3]; $o.run += [int]$Matches[4] }
    elseif ($l -match '^\s+(.+?)\s+idle (\d+) min$') { if ([double]$Matches[2] -gt $GraceMinutes) { $o.stale += "$($Matches[1]) $($Matches[2]) min" } }
    elseif ($l -match '^memory: (\d+)% used, ([\d.,]+) GB available') { $o.mem = [int]$Matches[1]; $o.avail = & $num $Matches[2] }
    elseif ($l -match '^gate: (\d+) running .*, (\d+) queued, longest wait (\d+) min') { $o.gr = [int]$Matches[1]; $o.gq = [int]$Matches[2]; $o.gw = [int]$Matches[3] }
    elseif ($l -match '^qa seats: (\d+) taken(?: of (\d+))?') { $o.seats = [int]$Matches[1]; if ($Matches[2]) { $o.seatsMax = [int]$Matches[2] } }
    elseif ($l -match '^disk (\S+): ([\d.,]+) GB free, \+?(-?[\d.,]+) GB/h(?:.*full in ([\d.,]+) h)?' -and $Matches[1] -notin @($o.disks | ForEach-Object drive)) { $o.disks += [ordered]@{ drive = $Matches[1]; free = & $num $Matches[2]; rate = & $num $Matches[3]; ttf = $(if ($Matches[4]) { & $num $Matches[4] }) } }
    elseif ($l -match '^slowest: (.+?)(?:, |$)') { $o.slow = $Matches[1] }
    elseif ($l -match '^sweep: (\d+) s') { $o.secs = [int]$Matches[1] }
  }
  [pscustomobject]$o
}
# effective supervise.* settings: kit.example.json defaults, kit.local.json overrides (with the default), supervise.* params
function Get-KitSuperviseSettings($Params = @()) {
  $out = [ordered]@{}; $js = { param($v) if ($v -is [string] -or $v -is [ValueType]) { $v } else { $v | ConvertTo-Json -Compress -Depth 4 } }
  if ($script:KitExample.supervise -is [psobject]) { foreach ($p in (Get-KitProps $script:KitExample.supervise)) { $out["supervise.$($p.Name)"] = [pscustomobject]@{ value = (& $js $p.Value); source = 'default' } } }
  foreach ($p in @($Params | Where-Object { "$($_.key)" -like 'supervise.*' -and "$($_.ctx)" -in '', '_' })) {
    $out["$($p.key)"] = [pscustomobject]@{ value = $p.value; source = $(if ("$($p.source)" -match 'learned') { 'learned' } elseif ("$($p.source)" -match '^default') { 'default' } else { ("$($p.source)" -split ' ')[0] }) } }
  $set = Get-KitSetting 'supervise' $null
  if ($set -is [psobject]) { foreach ($p in (Get-KitProps $set)) { $k = "supervise.$($p.Name)"; $was = $out[$k]
      $out[$k] = [pscustomobject]@{ value = $(if ($p.Name -eq 'publish') { '(set)' } else { & $js $p.Value }); source = 'local'; default = $(if ($was -and "$($was.value)" -ne "$(& $js $p.Value)") { $was.value }) } } }
  [pscustomobject]$out
}
# page + .json, written atomically; returns its path; failure: a WATCH and '' (tables print)
function Write-KitSuperviseHtml($d, [string[]]$Sweep, [string]$Next) { try {
  $rk = @{ ACT = 0; WATCH = 1; INFO = 2 }
  $p = [IO.Path]::ChangeExtension((Get-KitPath supervise-report -Create), '.html'); $pj = [IO.Path]::ChangeExtension($p, '.json')
  $prior = try { Read-KitText $pj | ConvertFrom-Json } catch { $null }
  $fl = @(@($d.flags) + @($d.info | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }) | Sort-Object { $rk["$($_.level)"] })
  $fixedN = @($fl | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' }).Count
  $History = @(@([pscustomobject]@{ at = $d.at.ToString('o'); flags = @($d.flags | Where-Object level -ne 'INFO' | Select-Object level, what); active = @($d.rows | Where-Object state -ne 'FINISHED').Count; fixed = $fixedN }) + @($prior.history | Where-Object { $_ }) | Select-Object -First ([int](Get-KitSetting 'supervise.historySweeps' 12)))
  $series = try { Get-KitSuperviseSeries (@($Sweep) + @($fl | ForEach-Object what)) $prior.stats } catch { [ordered]@{ ram = @(); disks = @() } }
  $nowT = try { Get-KitSuperviseNow $Sweep ([double](Get-KitParam 'idle.graceMinutes')) } catch { $null }
  if ($nowT -and -not @($nowT.disks).Count) { $nowT.disks = @($series.disks | Where-Object { $_ } | ForEach-Object { [ordered]@{ drive = $_.drive; free = $_.free; rate = $_.rate; ttf = $null } }) }   # storage skipped this sweep: the last disk values
  $samples = @($prior.stats.live | Where-Object { $_ -and $_.at -and ($d.at - [datetime]$_.at).TotalDays -lt [double](Get-KitParam 'supervise.statsDays') -and [datetime]$_.at -lt $d.at })   # one per base heartbeat, 7 days: deltas and the 7-day line
  if ($samples.Count -ge 2 -and ([datetime]$samples[-1].at - [datetime]$samples[-2].at).TotalMinutes -lt [double](Get-KitParam 'supervise.heartbeatMinutes')) { $samples = @($samples | Select-Object -SkipLast 1) }
  if ($nowT) { $dFree = [ordered]@{}; foreach ($dk in $nowT.disks) { $dFree[$dk.drive] = $dk.free }
    $rs = [ordered]@{}; foreach ($r0 in @($d.resources | Where-Object { $_.name })) { $rs["$($r0.name)"] = [pscustomobject]@{ gb = $r0.gb; by = "$($r0.by)" } }   # each resource's RAM + holder: the cards' 24 h history
    $rsw = @((Get-KitRepoSweep).repos | Where-Object { $_ })   # the Branches tile's lines
    $samples += [pscustomobject]@{ at = $d.at.ToString('o'); run = $nowT.run; mem = $nowT.mem; gq = $nowT.gq; gw = $nowT.gw; seats = $nowT.seats; secs = $nowT.secs; br = $(if ($rsw.Count) { [int]($rsw | Measure-Object branches -Sum).Sum }); wt = $(if ($rsw.Count) { [int]($rsw | Measure-Object worktrees -Sum).Sum }); disks = [pscustomobject]$dFree; res = [pscustomobject]$rs } }
  $serr = [Collections.Generic.List[string]]::new(); $statsFrom = Get-KitStatsCutoff; $usage = Select-KitUsageSince (Read-KitUsageResult) $statsFrom   # budget -Usage writes it; nothing before the stats reset
  $stats = [ordered]@{ keepFree = $d.keepFree; usage = $usage; repos = (Get-KitRepoSweep); sync = @(try { Get-KitRepoSyncState } catch { $serr.Add("repo sync: $($_.Exception.Message)") }); days = @(try { Get-KitSuperviseDays $prior.stats.days $d.at -StatsFrom $statsFrom } catch { $serr.Add("days: $($_.Exception.Message)") }); ram = $series.ram; disks = $series.disks; now = $nowT; live = @($samples)
    paramDays = @(try { Get-KitParamDays $d.at } catch { $serr.Add("param days: $($_.Exception.Message)") })
    params = @(try { $apv = (Read-KitParams).approved; @(Invoke-KitParamVerb show -Json | ConvertFrom-Json) | ForEach-Object { [pscustomobject]@{ key = $_.key; ctx = $_.ctx; value = $_.effective
            source = "$(if ((Get-KitMember $apv "$($_.key)|$(if ($_.ctx -ne '_') { $_.ctx })") -or (Get-KitMember $apv "$($_.key)|")) { 'approved' } else { $_.state })$(if ($_.source -notmatch '^(default|learned|pin$)') { " · $($_.source)" })"
            learned = $(if ($null -ne $_.learned -and $_.learned -ne $_.effective) { $_.learned } else { '' }); default = $_.default; changed = $_.changed; why = $_.why } } } catch { $serr.Add("params: $($_.Exception.Message)") }) }
  $stats.settings = Get-KitSuperviseSettings $stats.params   # defaults + local overrides + learned params: never an empty section
  $stats.gate = try { Get-KitGateStats $d.at @($d.resources) -StatsFrom $statsFrom } catch { $serr.Add("gate: $($_.Exception.Message)") }
  $stats.waits = try { Get-KitLeaseWaits $d.at -StatsFrom $statsFrom } catch { $null }; $stats.qa = try { Get-KitQaDays $d.at -StatsFrom $statsFrom } catch { $null }; $stats.cpu = try { Update-KitCpuStats $prior.stats.cpu $d.at @($d.shells) @($d.resources) } catch { $serr.Add("cpu: $($_.Exception.Message)"); $prior.stats.cpu }   # adapters/supervise_stats.ps1
  $stats.writes = try { $wc = Get-Content -LiteralPath (Join-Path (Get-KitPath cache) 'supervise-writes.json') -Raw | ConvertFrom-Json; if ($wc.at) { Get-KitWriteView @($wc.samples) @(Get-Content -LiteralPath (Get-KitPath disk-writes) -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) $d.at } } catch { $null }   # Get-KitSuperviseFlagsWrites; history: Update-KitWriteHistory
  $stats.flagHours = try { Update-KitFlagHours $prior.stats.flagHours $d.at $fl } catch { $serr.Add("flag hours: $($_.Exception.Message)"); @($prior.stats.flagHours) }   # the flags heatmap: 24 h (history keeps 12 sweeps)
  # a failed source keeps its last data or none: the sweep says which, never a silent stale section
  if ($serr.Count) { $stats.errs = @($serr); $w2 = [pscustomobject]@{ level = 'WATCH'; what = "dashboard data not updated this sweep: $($serr -join '; ')"; action = 'Fix the named source (adapters/supervise_stats.ps1); its section shows its last data.' }
    $fl = @($fl) + $w2; $d.flags = @($d.flags) + $w2; if ($flags -is [Collections.IList]) { [void]$flags.Add($w2) } }
  $osNext = if (Get-Command Get-KitOsBeatNextSweep -ErrorAction SilentlyContinue) { try { (Get-KitOsBeatNextSweep $d.at).ToString('o') } catch { $null } }   # adapters/os_timer.ps1
  $j = [pscustomobject]@{ at = $d.at.ToString('o'); next = $Next; osNext = $osNext; flags = @($fl); agents = @($d.rows); mem = $d.mem; resources = @($d.resources); shells = @($d.shells); history = @($History); stats = $stats }
  # compact, no copy of usage.result.json (0.7 MB): each sweep rewrote 1.8 MB (NTFS journal churn); the page still shows it
  $sj = [ordered]@{}; foreach ($sk in $stats.Keys) { if ($sk -ne 'usage') { $sj[$sk] = $stats[$sk] } }; $sj.usageFile = (Get-KitPath usage-cache) -replace '\.json$', '.result.json'
  $jw = $j.PSObject.Copy(); $jw.stats = $sj; Write-KitAtomic $pj ($jw | ConvertTo-Json -Depth 9 -Compress)
  $runPages = @{}; Write-KitAtomic $p (ConvertTo-KitLaneText (Format-KitSuperviseHtml $j $runPages))   # shown lane names (K55); the json keeps ids
  foreach ($rk in @($runPages.Keys)) { $runPages[$rk] = ConvertTo-KitLaneText $runPages[$rk] }
  $rpd = Join-Path (Split-Path $p) 'supervise-runs'; $null = New-Item -ItemType Directory -Force $rpd   # a run's step table, linked from its row
  foreach ($rk in $runPages.Keys) { $rpf = Join-Path $rpd "$rk.html"; if (-not (Test-Path -LiteralPath $rpf) -or [IO.File]::ReadAllText($rpf) -cne $runPages[$rk]) { Write-KitAtomic $rpf $runPages[$rk] } }   # an ended run's page: written once
  Get-ChildItem -LiteralPath $rpd -Filter '*.html' -File -ErrorAction SilentlyContinue | Where-Object { -not $runPages.ContainsKey($_.BaseName) } | Remove-Item -Force -ErrorAction SilentlyContinue   # runs no longer shown
  $pub = [string](Get-KitSetting 'supervise.publish' '')   # the bytes never pass through the model
  if ($pub.Trim()) {   # encoded: Windows strips the double quotes of a joined -Command line
    $sp = @{ FilePath = 'pwsh'; ArgumentList = @('-NoProfile', '-NonInteractive', '-ec', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pub))); ErrorAction = 'Stop' }; if ($KitIsWindows) { $sp.WindowStyle = 'Hidden' }
    $env:KIT_SUPERVISE_HTML = $p; $env:KIT_SUPERVISE_RUNS = $rpd; try { Start-Process @sp | Out-Null } catch { Write-Warning "supervise.publish failed to start: $($_.Exception.Message)" } finally { Remove-Item Env:KIT_SUPERVISE_HTML, Env:KIT_SUPERVISE_RUNS -ErrorAction SilentlyContinue } }
  $p
  } catch { $w = [pscustomobject]@{ level = 'WATCH'; what = "supervise page failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Write-KitSuperviseHtml.' }; $d.flags = @($d.flags) + $w; if ($flags -is [Collections.IList]) { [void]$flags.Add($w) }
    # a failed build never leaves the last good page passing for this sweep: a minimal page that says so
    try { $ep = [IO.Path]::ChangeExtension((Get-KitPath supervise-report -Create), '.html'); Write-KitAtomic $ep "<!doctype html><meta charset=utf-8><title>Supervisor</title><body style='font:14px system-ui;padding:20px'><h1>Supervisor page failed</h1><p>$([Net.WebUtility]::HtmlEncode("$((Get-Date).ToString('yyyy-MM-dd HH:mm')): $($_.Exception.Message)"))</p><p>The sweep's flags and report still ran; the next sweep rebuilds this page.</p>" } catch { }; '' }   # $flags: the supervise verb's list (-Json, plain)
}
# one icon set for the words the page repeats (running, queued, today, wait, RAM, stuck): inline SVG, currentColor, <title> = tooltip
function Format-KitIcon([string]$Name, [string]$Label = $Name) {
  $p = switch ($Name) { 'run' { "<path fill=currentColor stroke=none d='M5 3.2v9.6L12.8 8z'/>" } 'queue' { "<path fill=none d='M4.5 2h7M4.5 14h7M5.5 2v1.8c0 2 5 2.4 5 4.2s-5 2.2-5 4.2V14M10.5 2v1.8c0 2-5 2.4-5 4.2s5 2.2 5 4.2V14'/>" }
    'today' { "<path fill=none d='M3 8.6l3.2 3.1L13 4.6'/>" } 'wait' { "<circle fill=none cx=8 cy=8 r=6 /><path fill=none d='M8 4.6V8l2.3 1.6'/>" } 'stuck' { "<path fill=none d='M8 2.2l6.3 11.3H1.7zM8 6.6v3.2M8 11.6v.1'/>" }
    'ram' { "<rect fill=none x=4 y=4 width=8 height=8 rx=1.2 /><path fill=none d='M6 1.6V4M10 1.6V4M6 12v2.4M10 12v2.4M1.6 6H4M1.6 10H4M12 6h2.4M12 10h2.4'/>" } default { throw "Format-KitIcon: unknown icon '$Name'" } }
  $l = [Net.WebUtility]::HtmlEncode($Label); "<svg class='ic i-$Name hit' viewBox='0 0 16 16' role=img aria-label='$l'><title>$l</title>$p</svg>" }
# pure (tests feed a sample); values HtmlEncoded; inline CSS / JS / SVG only: no request leaves the page; $Pages: filled with run id -> run page
function Format-KitSuperviseHtml($j, [hashtable]$Pages) {
  $iv = [cultureinfo]::InvariantCulture; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $n1 = { param($x) ([double]$x).ToString('0.#', $iv) }
  $toTime = { param($x) if ($x) { try { [datetime]$x } catch { $null } } }; $at = & $toTime $j.at; if (-not $at) { $at = Get-Date }
  $ago = { param($x) $tx = & $toTime $x; if (-not $tx) { return '' }; $m = [int][math]::Max(0.0, ($at - $tx).TotalMinutes); if ($m -lt 1) { 'now' } elseif ($m -lt 60) { "$m min" } elseif ($m -lt 1440) { "$([math]::Floor($m / 60)) h $($m % 60) min" } else { "$([math]::Floor($m / 1440)) d" } }
  $when = { param($x) $tx = & $toTime $x; if ($tx) { "<span class=tm>$($tx.ToString($(if ($tx.Date -eq $at.Date) { 'HH:mm' } else { 'MM-dd HH:mm' }))) · </span><span class=ago data-t='$($tx.ToString('o'))' title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $x)</span>" } else { '<span class=m>—</span>' } }   # .ago: the page JS recounts it live
  $minAgo = { param($v) if ("$v" -match '^\s*(\d+(?:\.\d+)?)(?: min)?\s*$') { & $when $at.AddMinutes(-[double]$Matches[1]) } else { & $e $v } }   # sweep-relative minutes -> a live age
  $stCls = { param($s) if ("$s" -match 'STUCK') { 's-stuck' } elseif ("$s" -match '^ACTIVE') { 's-act' } elseif ("$s" -match '^FINISHED') { 's-fin' } else { 's-oth' } }
  $bar = { param([double]$v, [double]$max, [string]$label, [string]$tone = '') if ($max -le 0) { return '' }; $pc = [math]::Min(100.0, 100 * $v / $max); $bc = if ($tone) { $tone } elseif ($pc -ge 100) { 'act' } elseif ($pc -ge 80) { 'watch' } else { 'sage' }
    "<span class=bar><i class=$bc style='width:$(& $n1 $pc)%'></i></span><span class=bl>$(& $e $label)</span>" }
  # every section folds: "<title> (<count>)" summary; count 0 = summary only; open state kept per id (page JS)
  $fold = { param([string]$id, [string]$title, $count, [string]$inner, [switch]$Open, [string]$tag = 'h3', [string]$cls = '', [string]$extra = '') $none = "$count" -eq '0'
    "<details class='sec $cls$(if ($none) { ' none' })' id=sec-$id$(if ($Open -and -not $none) { ' open' })><summary><$tag>$(& $e $title)</$tag>$(if ("$count" -ne '') { "<span class=cnt>($(if ($count -is [hashtable]) { $count.h } else { & $e $count }))</span>" })$extra</summary>$(if (-not $none) { "<div class=bd>$inner</div>" })</details>" }
  $section = { param([string]$id, [string]$title, $count, [string]$inner, [switch]$Open, [string]$extra = '') & $fold $id $title $count $inner -Open:$Open -tag h2 -cls top -extra $extra }
  # @{ h = html }: a built cell; data-k: header per cell on a phone; '~<col>': hidden on a phone; 10 rows, then "Show all (N)"
  $table = { param([string[]]$cols, $rows) $rs = @($rows); if (-not $rs.Count) { return '<p class=empty>None</p>' }
    $lo = @($cols | ForEach-Object { "$_".StartsWith('~') }); $cn = @($cols | ForEach-Object { "$_".TrimStart('~') })
    "<div class=tw><table><tr>$(@(for ($ci = 0; $ci -lt $cn.Count; $ci++) { "<th$(if ($lo[$ci]) { ' class=lo' })>$(& $e $cn[$ci])</th>" }) -join '')</tr>$(@(for ($ri = 0; $ri -lt $rs.Count; $ri++) { $r = $rs[$ri]; "<tr class=$(if ($ri -ge 10) { "'f more'" } else { 'f' })>$(@(for ($ci = 0; $ci -lt @($r).Count; $ci++) { $cv = @($r)[$ci]; $dk = "data-k='$(& $e $cn[$ci])'$(if ($lo[$ci]) { ' class=lo' })"; if ($cv -is [hashtable]) { "<td $dk>$($cv.h)</td>" } else { "<td $dk>$((& $e $cv) -replace '([|/\\])', '$1<wbr>')</td>" } }) -join '')</tr>" }) -join '')</table>$(if ($rs.Count -gt 10) { "<button type=button class=sa data-n=$($rs.Count)>Show all ($($rs.Count))</button>" })</div>" }   # <wbr>: keys and paths break at | / \, never mid-word
  # short-item lists (cards, tiles, bars): one auto-fill grid, min width per item, at most $max across (README "Using it");
  # masonry (data-mas) except the machine row, whose tiles stretch to one height
  $grid = { param([string]$cls, [string]$min, [object[]]$items, [int]$max = 0, [string]$tag = 'div') "<$tag class='cg $cls' style='--cmin:$min$(if ($max) { ";--cmax:$max" })'$(if ($cls -notmatch '\bmach\b') { " data-mas$(if ($cls -match '\b(stats|res)\b') { ' data-fill' })" })>$(@($items | Where-Object { $_ }) -join '')</$tag>" }
  # task and MR links through the tracker / git host adapters (lib.ps1 Get-KitTaskLink, Get-KitMrLink): text = id or repo!n, no URL = plain text
  $lnMemo = @{}; $lnk = { param($l) if ($l.url) { "<a class=xl href='$(& $e $l.url)' target=_blank rel=noopener>$(& $e $l.text)</a>" } else { "<span class=xl>$(& $e $l.text)</span>" } }
  $taskA = { param($id) $k = "t|$id"; if (-not $lnMemo.ContainsKey($k)) { $lnMemo[$k] = & $lnk (Get-KitTaskLink $id) }; $lnMemo[$k] }
  $mrA = { param($ref) $k = "m|$ref"; if (-not $lnMemo.ContainsKey($k)) { $lnMemo[$k] = & $lnk (Get-KitMrLink $ref) }; $lnMemo[$k] }
  # a value behind its icon (the icon's title names it): no repeated words; $z: a zero is dimmed
  $icv = { param([string]$ico, [string]$label, $v, [string]$unit = '') "<span class='iv$(if ("$v" -match '^[0—]$') { ' z' })'>$(Format-KitIcon $ico $label)$v$(if ($unit) { "<small>$unit</small>" })</span>" }
  $item = { param([string]$name, [string]$sub, [string]$inner = '', [string]$tail = '') "<div class='ci f' title='$(& $e "$name · $sub")'><div class=tn>$(& $e $name)$tail</div><div class=sm>$(& $e $sub)</div>$inner</div>" }   # a grid card: name (+ an icon value), one line, an optional full-width bar
  # stopped / crashed with no progress for one heartbeat: finished, not live (owner, 2026-11-13)
  $isFin = { param($a) if ("$($a.state)" -eq 'FINISHED') { return $true }; if ("$($a.state)" -notmatch '^(STOPPED|CRASHED)') { return $false }; $lt = & $toTime $(if ($a.last) { $a.last } else { $a.since }); $lt -and ($at - $lt).TotalMinutes -gt $hbMin }
  $agents = @($j.agents | Where-Object { $_ }); $flags = @($j.flags | Where-Object { $_ })
  # one agent = one row (owner 2026-11-19): a QA run's board row joins the live workflow whose launch record (run field, not the
  # glob) names that runDir; the workflow's row of that agent wins; a workflow over two QA runs keeps them apart
  $qaOf = @{}; foreach ($w in @($agents | Where-Object { "$($_.name)" -match '\(workflow\)$' -and "$($_.run)" } | ForEach-Object { "$($_.run)" } | Select-Object -Unique)) {
    $rds = @(foreach ($lf in @(Get-ChildItem (Get-KitPath launches) -Filter "self-*$w*.json" -ErrorAction SilentlyContinue)) { $lr = try { Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($lr -and "$($lr.run)" -eq $w -and "$($lr.runDir)") { Split-Path "$($lr.runDir)" -Leaf } }) | Select-Object -Unique
    if (@($rds).Count -eq 1) { $qaOf["$rds"] = $w } }
  if ($qaOf.Count) { $have = @{}; foreach ($a in $agents) { if (-not $qaOf.ContainsKey("$($a.run)")) { $have["$($a.run)|$($a.name)"] = 1 } }
    $agents = @(foreach ($a in $agents) { if (-not $qaOf.ContainsKey("$($a.run)")) { $a; continue }; $w = $qaOf["$($a.run)"]; if (-not $have.ContainsKey("$w|$($a.name)")) { $c = $a.PSObject.Copy(); $c.run = $w; $c } }) }
  $nAct = @($flags | Where-Object level -eq 'ACT').Count; $nWatch = @($flags | Where-Object level -eq 'WATCH').Count
  $hist = @($j.history | Where-Object { $_ }); [array]::Reverse($hist)   # oldest first
  $nextMin = if ("$($j.next)" -match '(\d+(?:\.\d+)?)') { $Matches[1] } else { 15 }   # stale: older than 2 heartbeats (amber), 4 (red)
  $hbMin = try { [double](Get-KitParam 'supervise.heartbeatMinutes') } catch { 0 }; if (-not ($hbMin -gt 0)) { $hbMin = [double]$nextMin }   # $isFin: one heartbeat
  $nxTail = if ("$($j.next)" -match '\((.+)\)\s*$') { " · $($Matches[1])" } else { '' }   # the pace reason, plain words
  # next = the OS timer's sweep (sure to run), not the session's NEXT (its cron waits while the session is busy); staleness stays on NEXT
  $dueMin = $nextMin; if ($osNext = & $toTime $j.osNext) { $dueMin = [math]::Round(($osNext - $at).TotalMinutes, 1); $nxTail = " · OS timer$nxTail" }
  $mem = $j.mem; $tot = [double]$mem.TotalGB; $avail = [double]$mem.AvailGB; $used = $tot - $avail; $st = $j.stats
  $diskLv = @{}; foreach ($f in @($flags | Where-Object level -in 'ACT', 'WATCH')) { if ("$($f.what)" -match '^disk (\S+?):' -and $diskLv[$Matches[1]] -ne 'ACT') { $diskLv[$Matches[1]] = $f.level } }   # storage floor / fill-rate flags per drive
  $disks = @($st.disks | Where-Object { $_ } | Sort-Object { $rk = $diskLv["$($_.drive)"]; if ($rk -eq 'ACT') { 0 } elseif ($rk -eq 'WATCH') { 1 } else { 2 } }, { [double]$_.free })   # every watched drive, a flagged one first
  $diskTone = { param($dv, [string]$hot = 'hot', [string]$warn = 'warn') $lvd = $diskLv["$dv"]; if ($lvd -eq 'ACT') { $hot } elseif ($lvd -eq 'WATCH') { $warn } else { '' } }
  # rate: GB/h over 11 min (storage verdict); the last hour's net change shows a drop it hides
  $diskRate = { param($dk, [switch]$Short) $r = [double]$dk.rate; $h1 = @($st.disks | Where-Object { $_ -and "$($_.drive)" -eq "$($dk.drive)" })[0].h1   # -Short: the tile line; the rest in its tooltip
    $rt = if ($r -ge 0.05) { "filling $(& $n1 $r) GB/h" } elseif ($r -le -0.05) { "freeing $(& $n1 (-$r)) GB/h" } else { 'steady' }; if ($Short) { return $rt }
    "$rt (11 min)$(if ($null -ne $h1) { " · last hour $(& $n1 ([math]::Abs([double]$h1))) GB $(if ([double]$h1 -lt 0) { 'used' } else { 'freed' })" })" }
  $markFile = Join-Path $script:KitRoot 'assets/claude-crew-mark.svg'; $mark = if (Test-Path -LiteralPath $markFile) { (Get-Content -LiteralPath $markFile -Raw) -replace '<\?xml[^>]*>\s*', '' -replace '\s+', ' ' } else { '' }
  # a flag over 25 words: a one-line summary that opens to the full text (owner, 2026-11-13)
  $brief = { param([string]$t) $s = $t -replace '\([^()]{40,}\)', '(…)' -replace '(?:[A-Za-z]:)?(?:[^\s:()]*[\\/]){2,}([^\s\\/:()]+)', '$1'; $wd = @($s -split '\s+' | Where-Object { $_ }); if ($wd.Count -gt 25) { ($wd[0..24] -join ' ') + ' …' } else { $s } }
  $long = { param([string]$t) if (@($t -split '\s+' | Where-Object { $_ }).Count -le 25) { return & $e $t }; "<details class=lx><summary>$(& $e (& $brief $t))</summary><div class=lf>$(& $e $t)</div></details>" }
  $info = @($flags | Where-Object level -eq 'INFO')
  # flags band (owner 2026-11-19): one table (Format-KitFlagTable), auto-fixes and notes folded in it, the 24 h heatmap behind a toggle; holds below
  $fixedI = @($info | Where-Object { "$($_.what)" -like 'auto-fixed:*' }); $holdI = @($info | Where-Object { "$($_.what)" -match '^HOLD \S+:' }); $restI = @($info | Where-Object { "$($_.what)" -notlike 'auto-fixed:*' -and "$($_.what)" -notmatch '^HOLD \S+:' })
  # a hold row: task (linked) · why (deferred count or who it waits on) · reason, wrapped; the release command once, below
  $holdRow = { param([string]$w) $null = $w -match '^HOLD (?<t>[^\s:]+):\s*(?<why>.*?)(?:;\s*release:\s*(?<cmd>.+))?$'; $tid = $Matches.t; $why = "$($Matches.why)"
    $its = @(if ($why -match '\((?<k>deferred items|waiting on [^:]+):\s*(?<l>.+)\)\s*$') { $hk = $Matches.k; ([regex]::Split($Matches.l, ',(?![^()]*\))')) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } } else { $hk = ''; $why })   # @(): one item stays a list, never its first letter
    $tl = & $taskA $tid
    "<li class='f hr'><b class=ht>$tl</b><span class=hn>$(if ($hk -like 'deferred*') { "$($its.Count) deferred" } elseif ($hk) { & $e $hk } else { 'held' })</span><span class=hw>$(& $e ($its -join ', '))</span></li>" }
  $holdCmd = @($holdI | ForEach-Object { if ("$($_.what)" -match ';\s*release:\s*(?<c>.+)$') { $Matches.c.Trim() -replace '-Task \S+', '-Task <task>' } } | Select-Object -Unique)
  # notes of one kind about several subjects ("RAM FLOOR: rm ...", "... hm ..." same rest): one line listing them
  $noteKey = { param([string]$w) if ($w -cmatch '^(?<k>[A-Z][A-Z0-9 -]+):\s*(?<s>\S+)\s+(?<r>.+)$') { $Matches } }
  $notes = @(@($restI | ForEach-Object { "$($_.what)" }) | Group-Object { $m = & $noteKey $_; if ($m) { "$($m.k)|$($m.r)" } else { $_ } } | ForEach-Object { if ($_.Count -gt 1) { $m0 = & $noteKey $_.Group[0]; "$($m0.k): $(@($_.Group | ForEach-Object { (& $noteKey $_).s }) -join ', ') $($m0.r)" } else { $_.Group[0] } })
  $flagBelow = $(if ($holdI.Count) { & $fold 'holds' 'Promotion holds' $holdI.Count "<ul class=hold>$(@($holdI | ForEach-Object { & $holdRow "$($_.what)" }) -join '')</ul>$(if ($holdCmd.Count) { "<p class=hc>release: $(@($holdCmd | ForEach-Object { "<code class=cp title='Click to copy'>$(& $e $_)</code>" }) -join ' ')</p>" })" -cls sub })
  $flagHtml = "$(Format-KitFlagTable $flags $fixedI $notes)<div id=fl-hist hidden>$(Format-KitFlagHeat $st.flagHours)</div>" + $(if ($flagBelow) { "<div class=fbl>$flagBelow</div>" })
  # statistics: the agents-failed day records ('—' = no source)
  $days = @($st.days | Where-Object { $_ }); $dayKey = { param([int]$back) $at.AddDays(-$back).ToString('yyyy-MM-dd') }
  $fmt = { param($v) if ($null -eq $v) { '—' } else { & $n1 $v } }
  # stats.now + 7 days of stats.live: a change shows in graphs, never as delta text (owner, 2026-11-14)
  $nw = $st.now; $lv = @($st.live | Where-Object { $_ })
  $agg = { param([scriptblock]$pick) $vs = @($lv | ForEach-Object $pick | Where-Object { $null -ne $_ }); if ($vs.Count) { & $n1 ($vs | Measure-Object -Maximum).Maximum } else { '—' } }   # 7-day peak
  # machine: RAM, gate and QA seats as tiles over Resources · 24 h (Format-KitMachineTop); disks (owner 2026-11-19: no Disks card): a row
  # per drive in its machine group (Writes metric: GB the drive filled per hour; free, % used and fill rate on the row) and free GB per
  # day per drive in Disk · 7 days
  $memPct = if ($null -ne $nw.mem) { $nw.mem } elseif ($tot) { [math]::Round(100 * $used / $tot) }; $memFree = if ($null -ne $nw.avail) { $nw.avail } elseif ($tot) { $avail }
  $dkTone = { param($dk, $ttf) $dv = "$($dk.drive)"; if (& $diskTone $dv) { & $diskTone $dv } elseif ($null -eq $ttf) { '' } elseif ($ttf -lt 24) { 'hot' } else { 'warn' } }
  $hr0 = $at.Date.AddHours($at.Hour - 23); $dDays = @(6..0 | ForEach-Object { & $dayKey $_ })
  $diskW = @(foreach ($dk in @(@(if (@($nw.disks | Where-Object { $_ }).Count) { $nw.disks } else { $disks }) | Where-Object { $_ } | Sort-Object -Stable { $tz = & $diskTone $_.drive; if ($tz -eq 'hot') { 0 } elseif ($tz) { 1 } else { 2 } })) {
    $dv = "$($dk.drive)"; $ttf = if ($null -ne $dk.ttf -and [double]$dk.ttf -lt 72) { [double]$dk.ttf }; $tn = & $dkTone $dk $ttf   # full-in only under 72 h
    $dt = [double]@($disks | Where-Object { "$($_.drive)" -eq $dv })[0].total; $pu = if ($dt) { [math]::Round(100 * ($dt - [double]$dk.free) / $dt) }
    $ser = @($lv | Where-Object { $_.at -and $_.disks -and $null -ne (Get-KitMember $_.disks $dv) } | ForEach-Object { [pscustomobject]@{ t = [datetime]$_.at; f = [double](Get-KitMember $_.disks $dv) } } | Sort-Object t)
    $fh = [double[]]::new(24); $fd7 = 0.0; $fday = 0.0; for ($si = 1; $si -lt $ser.Count; $si++) { $dd = [math]::Max(0.0, $ser[$si - 1].f - $ser[$si].f); $fd7 += $dd; if ($ser[$si].t -ge $at.Date) { $fday += $dd }
      $hi = [int][math]::Floor(($ser[$si].t - $hr0).TotalHours); if ($hi -ge 0 -and $hi -le 23) { $fh[$hi] += $dd } }   # filled = free GB dropped between two samples
    [pscustomobject]@{ n = "disk $dv"; a = "$(& $fmt $dk.free) GB free$(if ($null -ne $pu) { " · $pu% used" }) · $(& $diskRate $dk -Short)$(if ($null -ne $ttf) { " · full in $(& $n1 $ttf) h" })"; c = (& $diskRate $dk); tone = $tn; fnow = $dk.free
      h = @($fh); now = $fh[23]; peak = [double]($fh | Measure-Object -Maximum).Maximum; avg = [double]($fh | Measure-Object -Sum).Sum / 24; day = $fday; d7 = $fd7
      free = @(foreach ($dk0 in $dDays) { @($ser | Where-Object { $_.t.ToString('yyyy-MM-dd') -eq $dk0 } | ForEach-Object f)[-1] }) } })
  $wrX = [pscustomobject]@{ rows = @(@($st.writes.rows) + @($diskW)); more = @($st.writes.more); src = "$($st.writes.src)" }   # the drive rows ride the Writes rows
  $l24 = @($lv | Where-Object { $_.at -and [datetime]$_.at -ge $at.AddDays(-1) })
  $gs = $st.gate; $machTop = Format-KitMachineTop $gs $nw $memPct $memFree $tot ([double]$st.keepFree)   # tiles, RAM bar (supervise_stats.ps1)
  $machineHtml = "<div class=mcol>$(Format-KitResHeat $st.cpu $j.resources $l24 $tot $(if ($tot) { $used }) $wrX $st.waits $gs $machTop)$(Format-KitWritesCard $st.writes $diskW $dDays)</div>"
  # kit health rows of the Trends day heatmap (owner 2026-11-19): sweep s, agents failed / finished, branches, worktrees
  # kit health per day (Format-KitDayHeat): sweep s (stats.live samples), agents failed / finished (calls logs), branches and worktrees
  # (the day's last sample); 7 d: avg, sum or peak as the row's tooltip says
  $d7 = @(6..0 | ForEach-Object { & $dayKey $_ }); $dOf = { param($x) try { ([datetime]$x).ToString('yyyy-MM-dd') } catch { '' } }
  $avgOf = { param($vs) $v1 = @($vs | Where-Object { $null -ne $_ }); if ($v1.Count) { [double]($v1 | Measure-Object -Average).Average } else { $null } }   # $null keeps the day's slot
  $perDay = { param($src, [scriptblock]$pick, [scriptblock]$agg) @(foreach ($dk in $d7) { $in = @($src | Where-Object { (& $dOf $_.at) -eq $dk }); if ($in.Count) { & $agg @($in | ForEach-Object $pick) } else { $null } }) }
  $sw = & $perDay @($lv | Where-Object { $null -ne $_.secs }) { [double]$_.secs } $avgOf
  $dRec = { param([string]$k) @(foreach ($dk in $d7) { Get-KitMember @($days | Where-Object { "$($_.day)" -eq $dk })[0] $k }) }; $fd = & $dRec failed; $lf = & $dRec left
  $lastOf = { param($vs) @($vs)[-1] }; $br = & $perDay @($lv | Where-Object { $null -ne $_.br }) { [double]$_.br } $lastOf; $wt = & $perDay @($lv | Where-Object { $null -ne $_.wt }) { [double]$_.wt } $lastOf
  $s7 = { param($vs) $v1 = @($vs | Where-Object { $null -ne $_ }); if ($v1.Count) { Format-KitCompactNum ($v1 | Measure-Object -Sum).Sum } else { '—' } }; $a7 = { param($vs) $v1 = & $avgOf $vs; if ($null -ne $v1) { Format-KitCompactNum $v1 } else { '—' } }
  $p7 = { param($vs) $v1 = @($vs | Where-Object { $null -ne $_ }); if ($v1.Count) { Format-KitCompactNum ($v1 | Measure-Object -Maximum).Maximum } else { '—' } }
  $hRows = @(@{ n = 'sweep s'; mk = 'sweep-day'; sub = $(if ($nw.secs) { "now $(& $fmt $nw.secs) s" }); title = "seconds per sweep, the day's average; 7 d: average$(if ($nw.slow) { " · slowest step now: $($nw.slow)" })"; v = $sw; t = (& $a7 $sw); keep = $true },
    @{ n = 'agents failed'; mk = 'agents-failed-day'; title = 'agents that left the board failed, blocked or in error; 7 d: sum'; v = $fd; t = (& $s7 $fd); cls = 'fh l-act'; gl = $true },
    @{ n = 'agents finished'; mk = 'agents-left-day'; title = 'agents that left the board (any status); 7 d: sum'; v = $lf; t = (& $s7 $lf) },
    @{ n = 'branches'; mk = 'branches-day'; title = 'local branches over all repos, the day''s last sample; 7 d: peak (per repo now: the table below)'; v = $br; t = (& $p7 $br); cls = 'ws'; gl = $true },
    @{ n = 'worktrees'; mk = 'worktrees-day'; title = 'worktrees over all repos, the day''s last sample; 7 d: peak'; v = $wt; t = (& $p7 $wt); cls = 'ws' })
  foreach ($dr in $hRows) { $dr.d = $d7 }   # Trends aligns the rows by date
  $UP = Format-KitUsageHtml $st.usage
  # a command on one line, cut at 120 chars with an ellipsis in the text (no CSS clip), the whole one a click away
  $cmdCell = { param([string]$c) $full = "$c".Trim(); $one = $full -replace '\s+', ' '; if ($one -eq $full -and $one.Length -le 120) { return $one }
    $hd = if ($one.Length -gt 120) { $one.Substring(0, 119).TrimEnd() + '…' } else { $one }
    @{ h = "<details class=cmd><summary title='$(& $e $one)'>$(& $e $hd)</summary><div class=cmdf>$(& $e $full)</div></details>" } }
  # Dir only when a shell runs outside the kit, Next only when one has a step; Command takes the free width (colgroup)
  $shRows = @($j.shells | Where-Object { $_ }); $kitDirNorm = "$script:KitRoot".TrimEnd('\', '/') -replace '\\', '/'
  $shDir = { param($s) $dn = "$($s.dir)".TrimEnd('\', '/') -replace '\\', '/'; if ($dn -and $dn -ne $kitDirNorm) { "$($s.dir)" } else { '' } }
  $shDirOn = [bool]@($shRows | Where-Object { & $shDir $_ }).Count; $shNextOn = [bool]@($shRows | Where-Object { "$($_.next)".Trim() }).Count
  # progress (owner 2026-11-18) under the state: CPU now (the sweep's sample pair), quiet min, output size + age; the output's last line under the command
  $shProg = { param($s) @($(if ($null -ne $s.cpuNow) { "CPU $($s.cpuNow)%" }), $(if ($s.quiet) { "quiet $($s.quiet) min" }), $(if ($null -ne $s.outKB) { "out $($s.outKB) KB $(if ($s.outAge) { "$($s.outAge) min ago" } else { 'now' })" })) | Where-Object { $_ } }
  $shState = { param($s) $pl = @(& $shProg $s); if (-not $pl.Count) { return "$($s.state)" }; @{ h = "$(& $e $s.state)<div class=sm>$(@($pl | ForEach-Object { & $e $_ }) -join '<br>')</div>" } }
  $shCmd = { param($s) $cc = & $cmdCell "$($s.cmd)"; if (-not "$($s.last)".Trim()) { return $cc }; $wb = { param($x) (& $e $x) -replace '([|/\\])', '$1<wbr>' }; @{ h = "$(if ($cc -is [hashtable]) { $cc.h } else { & $wb $cc })<div class=sm>&#8250; $(& $wb $s.last)</div>" } }
  $shProgOn = [bool]@($shRows | Where-Object { @(& $shProg $_).Count }).Count
  $shCols = @('PID', 'Owner', 'Age', 'State') + @(if ($shDirOn) { 'Dir' }) + 'Command' + @(if ($shNextOn) { 'Next' })
  $shWidths = @('64px', '12%', '64px', $(if ($shProgOn) { '118px' } else { '76px' })) + @(if ($shDirOn) { '14%' }) + 'auto' + @(if ($shNextOn) { '15%' })
  $shAge = { param($v) if ("$v" -match '^\s*(\d+(?:\.\d+)?)(?: min)?\s*$') { $tx = $at.AddMinutes(-[double]$Matches[1]); "<span class=ago data-t='$($tx.ToString('o'))' title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $tx)</span>" } else { & $e $v } }
  $shellHtml = (& $table $shCols @($shRows | ForEach-Object { $sr = $_; , @(@($sr.pid, $sr.owner, @{ h = & $shAge $sr.age }, (& $shState $sr)) + @(if ($shDirOn) { & $shDir $sr }) + @(& $shCmd $sr) + @(if ($shNextOn) { "$($sr.next)" })) })) -replace '^<div class=tw><table>', "<div class=tw><table><colgroup>$(@($shWidths | ForEach-Object { "<col style='width:$_'>" }) -join '')</colgroup>"
  $setRows = @(if ($st.settings) { (Get-KitProps $st.settings) | ForEach-Object { , @($_.Name, $_.Value) } })
  $prm =@($st.params | Where-Object { $_ }); $hm = { param($x) if ($x) { try { ([datetime]$x).ToString('MM-dd HH:mm') } catch { "$x" } } else { '' } }   # '' keeps the cell: an empty result drops it from the row
  # Tuning (owner 2026-11-19: UI, not a dump table): a tile per key in its group's row (colour = source: learned sage, shadow plum, local
  # slate, default plain; the value inside; changed in 7 days outlined; tooltip: key, context, source, change, why), learned keys with
  # changes as a key x day heatmap (K100), the page Filter finds a key, the table one tap away
  $tv = { param($v) if ($null -eq $v) { '' } elseif ($v -is [string] -or $v -is [ValueType]) { "$v" } else { $v | ConvertTo-Json -Compress -Depth 4 } }
  # state (· suffix: config) -> words; pinned / frozen / shadow kept (a shadow is a proposal, not applied)
  $tSrc = { param([string]$s, [string]$note, $dflt) if ($s -match '· |config|override|local') { "local config$(if ("$dflt" -ne '') { " (default $dflt)" })" } elseif ($s -match '^(live|approved|learned)') { "learned ($s$(if ($note) { ", $note" }))" } elseif ($s -match '^default') { 'default' } else { "$s$(if ($note) { " ($note)" })" } }
  $tun = @(@($prm | ForEach-Object { [pscustomobject]@{ key = "$($_.key)"; ctx = $(if ("$($_.ctx)" -in '', '_') { '' } else { "$($_.ctx)" }); val = & $tv $_.value; dflt = & $tv $_.default; src = & $tSrc "$($_.source)" "$($_.learned)" $null; chg = & $hm $_.changed; chgAt = $(try { ([datetime]$_.changed).ToString('o') } catch { '' }); c7 = $(try { [datetime]$_.changed -ge $at.AddDays(-7) } catch { $false }); why = "$($_.why)" } }) +
    @($setRows | Where-Object { $sk = $_[0]; -not @($prm | Where-Object { "$($_.key)" -eq $sk -and "$($_.ctx)" -in '', '_' }).Count } | ForEach-Object { $sv = $_[1]; $hasSrc = $null -ne $sv -and (Get-KitProps $sv).Name -contains 'source'
      [pscustomobject]@{ key = $_[0]; ctx = ''; val = & $tv $(if ($hasSrc) { $sv.value } else { $sv }); dflt = $(if ($hasSrc) { & $tv $sv.default } else { '' }); src = $(if ($hasSrc) { & $tSrc "$($sv.source)" '' $sv.default } else { '' }); chg = ''; why = '' } }))
  # changed keys (owner 2026-11-20, K100; stats.paramDays): a row per key + scope (short label, full one in the tooltip), the latest change
  # first; a day cell = old→new (up slate, down plum, "→default" = a reset), the value now on the right
  $pv = { param($v) if ($null -eq $v -or "$v" -eq '') { 'default' } elseif ($v -is [ValueType] -and $v -isnot [bool]) { ([double]$v).ToString('0.##', $iv) } else { & $tv $v } }
  $pvc = { param($v) if ($v -is [ValueType] -and $v -isnot [bool] -and [math]::Abs([double]$v) -ge 1e4) { Format-KitCompactNum $v } else { & $pv $v } }   # a cell: 154k (the tooltip keeps the full value)
  $pScope ={ param([string]$c) @("$c" -split '\|' | Where-Object { $_ -and $_ -ne '_' } | ForEach-Object { $ps = @($_ -split '[\\/]' | Where-Object { $_ }); if ($ps.Count -gt 2) { $ps[-2..-1] -join '/' } else { $ps -join '/' } }) -join ' · ' }
  $pd = @($st.paramDays | Where-Object { $_ -and $_.key -and $null -ne $_.last }); $pdDates = @(6..0 | ForEach-Object { & $dayKey $_ })
  $drift = if ($pd.Count) { Format-KitDayHeat @($pd | ForEach-Object { $pr = $_; $ds = @(for ($i = 0; $i -lt 7; $i++) { @($pr.days)[$i] }); $sc = & $pScope "$($pr.ctx)"
        $full = "$($pr.key)$(if ("$($pr.ctx)" -notin '', '_') { " [$($pr.ctx)]" })"
        @{ n = "$(($pr.key -split '\.')[-1])$(if ($sc) { " · $sc" })"; title = "$full = $(& $pv $pr.cur) · $($pr.n) change(s) in 7 days, last $(& $hm $pr.last)$(if ($pr.why) { ": $($pr.why)" })"; mk = "param-day-$($pr.key)-$($pr.ctx)"; cls = 'pd'; keep = $true
          v = @($ds | ForEach-Object { if ($_) { [int]$_.c } else { $null } }); sh = @($ds | ForEach-Object { if ($_) { 45 } else { 0 } }); t = & $pv $pr.cur
          tx = @($ds | ForEach-Object { if (-not $_) { '' } elseif ($null -eq $_.t -or "$($_.t)" -eq '') { '→default' } elseif ($null -eq $_.f) { "→$(& $pvc $_.t)" } else { "$(& $pvc $_.f)→`u{200B}$(& $pvc $_.t)" } })   # zero-width space: a narrow cell wraps after the arrow, never inside a number
          dd = @($ds | ForEach-Object { if (-not $_) { '' } elseif ($null -eq $_.t -or "$($_.t)" -eq '') { 'rs' } elseif ($_.f -is [ValueType] -and $_.t -is [ValueType] -and $_.f -isnot [bool] -and $_.t -isnot [bool] -and [double]$_.t -ne [double]$_.f) { if ([double]$_.t -gt [double]$_.f) { 'up' } else { 'dn' } } else { 'ch' } })
          tips = @($ds | ForEach-Object { if (-not $_) { 'no change' } else { "$(& $pv $_.f) → $(& $pv $_.t)$(if ($_.c -gt 1) { " ($($_.c) changes)" })" } }) } }) $pdDates 'changed key · day' 'now' }
  # Settings (owner 2026-11-21: "it gets little confusing"): equal tiles, changed groups first; a tile = chevron, name, key count, a sage
  # "n changed" badge, a source bar; a click opens its key table in one panel under the tile's row (grid dense flow), one open at a time
  $srcK = { param([string]$s) if ($s -like 'learned*') { 'l' } elseif ($s -like 'shadow*') { 's' } elseif ($s -like 'local*') { 'c' } elseif ($s -in '', 'default') { 'd' } else { 'o' } }
  $srcW = @{ l = 'learned'; s = 'shadow'; c = 'local'; d = 'default' }
  # a key + scope's last change: old -> new (paramDays lf, cur)
  $pdLast = @{}; foreach ($pr in $pd) { $pdLast["$($pr.key)|$(if ("$($pr.ctx)" -in '', '_') { '' } else { "$($pr.ctx)" })"] = "$(& $pv $pr.lf) → $(& $pv $pr.cur)" }
  # a scope 'kind|path' -> kind and path columns; a lone path-like scope -> path
  $ctxP = { param([string]$c) if (-not $c) { return @('', '') }; if ($c -match '\|') { @($c -split '\|', 2) } elseif ($c -match '[\\/]|^\.') { @('', $c) } else { @($c, '') } }
  $tunGs = @($tun | Group-Object { ($_.key -split '\.')[0] } | Sort-Object { -[int][bool]@($_.Group | Where-Object c7).Count }, Name)
  $tunG = @(foreach ($g in $tunGs) { $gp = "$($g.Name)."; $gid = & $e ($g.Name -replace '[^\w-]', '-'); $g7 = @($g.Group | Where-Object { $_.c7 }).Count
      $gk = @($g.Group | ForEach-Object { $sk0 = & $srcK $_.src; if ($sk0 -eq 'o') { 'c' } else { $sk0 } })   # pinned / env: set by a person, counted as local
      $gMix = @(@('l', 's', 'c', 'd') | ForEach-Object { $kn = $_; [pscustomobject]@{ k = $kn; l = $srcW[$kn]; n = @($gk | Where-Object { $_ -eq $kn }).Count } })
      $gSay = "$($g.Name): $($g.Count) key$(if ($g.Count -ne 1) { 's' }), $(if ($g7) { "$g7 changed this week" } else { 'none changed this week' }), $(@($gMix | Where-Object n | ForEach-Object { "$($_.n) $($_.l)" }) -join ', ')"
      $gBar = "<span class=tgx aria-hidden=true>$(@($gMix | Where-Object n | ForEach-Object { "<i class=p$($_.k) style='flex-grow:$($_.n)'></i>" }) -join '')</span>"
      $cps = @($g.Group | ForEach-Object { , @(& $ctxP $_.ctx) }); $hasK = [bool]@($cps | Where-Object { $_[0] }).Count; $hasP = [bool]@($cps | Where-Object { $_[1] }).Count; $prevK = $null
      $rowsG = @($g.Group | Group-Object key | Sort-Object { -[int][bool]@($_.Group | Where-Object c7).Count }, Name | ForEach-Object { $_.Group | Sort-Object { -[int][bool]$_.c7 }, ctx })
      $trs = @(foreach ($r in $rowsG) { $sk = & $srcK $r.src; $cp = & $ctxP $r.ctx; $ft = $pdLast["$($r.key)|$($r.ctx)"]; $rep = $prevK -eq $r.key; $prevK = $r.key
          $sl = if ($srcW[$sk]) { $srcW[$sk] } else { ("$($r.src)" -split '[\s(]')[0] }
          "<tr class='f$(if ($r.c7) { ' c7' })' data-k='$(& $e $r.key)'><td class='tk$(if ($rep) { ' rep' })' data-s='$(& $e $r.key)' title='$(& $e "$($r.key)$(if ($r.why) { " · $($r.why)" })")'>$(if ($r.c7) { '<i class=cmk aria-hidden=true></i>' })$(& $e $(if ($r.key.StartsWith($gp)) { $r.key.Substring($gp.Length) } else { $r.key }))<span hidden> $(& $e "$($r.key) $($r.ctx)")</span></td>" +
          "$(if ($hasK) { "<td class=pth>$(& $e $cp[0])</td>" })$(if ($hasP) { "<td class=pth$(if ($cp[1]) { " title='$(& $e $cp[1])'" })>$(& $e $cp[1])</td>" })" +
          "<td class=tv>$(& $e $r.val)</td><td class=tv>$(& $e $r.dflt)</td><td title='$(& $e $(if ($r.src) { $r.src } else { 'default' }))'><i class='lgk p$(if ($sk -eq 'o') { 'c' } else { $sk })'></i>$(& $e $sl)</td><td data-s='$(& $e $r.chgAt)'>$(if ($r.chg) { & $e "$($r.chg)$(if ($ft) { " · $ft" })" })</td></tr>" })
      $cols = @('key|22%') + @(if ($hasK) { 'scope|11%' }) + @(if ($hasP) { 'path|auto' }) + @('value|10%', 'default|10%', 'source|10%', "changed · from → to|$(if ($hasP) { '18%' } else { 'auto' })")
      $tbl = "<div class=tw><table class=tkt><colgroup>$(@($cols | ForEach-Object { "<col style='width:$(($_ -split '\|')[1])'>" }) -join '')</colgroup><thead><tr>$(@($cols | ForEach-Object { "<th aria-sort=none><button type=button class=tks>$(& $e ($_ -split '\|')[0])</button></th>" }) -join '')</tr></thead><tbody>$($trs -join '')</tbody></table></div>"
      "<button type=button class='tgb$(if ($g7) { ' c7g' })' id=tg-$gid aria-expanded=false aria-controls=tp-$gid aria-label='$(& $e $gSay)'><span class=tgh><span class=tgn title='$(& $e $g.Name)'>$(& $e $g.Name)</span><small>$($g.Count)</small></span><span class=tgm>$(if ($g7) { "<span class=bdg>$g7 changed</span>" })</span>$gBar</button>" +
      "<section class='tgp f$(if ($g7) { ' c7g' })' id=tp-$gid data-t=tg-$gid aria-label='$(& $e $g.Name) keys'><div class=tph><b>$(& $e $g.Name)</b><small>$($g.Count) key$(if ($g.Count -ne 1) { 's' })</small>$(if ($g7) { "<span class=bdg>$g7 changed</span>" })<button type=button class=tpx aria-label='Close $(& $e $g.Name)' title='Close (Esc)'>×</button></div>$tbl</section>" })
  $tgBar = "<div class=tgc><input id=tgq type=search placeholder='Search keys' aria-label='Search settings keys'><button type=button class=tgk data-tga=ch aria-pressed=false>Changed only</button><button type=button class=tgk data-tga=all aria-pressed=false>Expand all</button><button type=button class=tgk data-tga=none>Collapse all</button></div>"
  $tLeg = Format-KitLegend "bar: <i class='lgk pl'></i>learned <i class='lgk ps'></i>shadow <i class='lgk pc'></i>local <i class='lgk pd'></i>default · <span class=bdg>n changed</span> = in 7 days" 'a tile = a key group; its bar = the share of its keys from each source (shadow = proposed, not applied; local = set in config or pinned) · tap a tile or press Enter: its keys open under its row; again or Esc closes · Expand all = every group as a list · tap a table header to sort'
  # owner 2026-11-19: no rendered table; its rows go to the clipboard as TSV
  $tTsv = (@("key`tcontext`tvalue`tsource`tchanged`twhy") + @($tun | Sort-Object key, ctx | ForEach-Object { (@($_.key, $_.ctx, $_.val, $(if ($_.src) { $_.src } else { 'default' }), $_.chg, $_.why) | ForEach-Object { "$_" -replace '[\t\r\n]+', ' ' }) -join "`t" })) -join "`n"
  # in the section header, right-aligned (owner 2026-11-20); its click never toggles the fold
  $tCopy = "<button type=button class='chip tsv' data-tsv='$(& $e $tTsv)' title='the $($tun.Count) rows as tab-separated text'>copy as TSV</button>"
  # all tile groups in one fold under the heatmap, closed by default (owner 2026-11-20); kept in kc-open, the filter opens it
  $tSet = & $fold 'settings' 'Settings' $(if ($tun.Count) { @{ h = & $e "$($tun.Count) keys · $(@($tun | Where-Object { $_.c7 }).Count) changed this week" } } else { 0 }) "$tgBar<div class=tgs data-mk=params-now>$($tunG -join '')</div>$tLeg" -cls sub
  $setHtml = & $fold 'tuning' 'Tuning' $tun.Count -extra $tCopy "$(if ($drift) { "<div class=pdk data-mk=param-day>$drift</div>$(Format-KitLegend "<i class='lgk pu'></i>up <i class='lgk pw'></i>down · →default = reset" 'now = the value today · hover a row for the full key, scope and why')" })$tSet" -cls sub
  $css = (Get-KitSupervisePageCss) + (Get-KitStatsCss)
  $fav = if ($mark) { "<link rel=icon href='data:image/svg+xml,$([Uri]::EscapeDataString($mark))'>" }
  $js = "(function(){var d=document,L=localStorage,S=sessionStorage,r=d.documentElement,a=d.getElementById('age'),t=new Date(a.dataset.at),n=+a.dataset.next||15,nx=d.getElementById('nx'),same=S.getItem('kc-at')==a.dataset.at;S.setItem('kc-at',a.dataset.at);" +   # same: a reload brought no new sweep
    "function ag(m){return m<1?'now':m<60?m+' min':m<1440?Math.floor(m/60)+' h '+m%60+' min':Math.floor(m/1440)+' d'}function u(){var w=Date.now(),m=Math.round((w-t)/6e4),o=Math.round((t-w)/6e4+(+nx.dataset.dn||n));a.textContent='updated '+(m<1?'just now':m<60?m+' min ago':m<2880?Math.round(m/60)+' h ago':Math.round(m/1440)+' d ago');a.className='chip '+(m>4*n?'bad':m>2*n?'warn':'ok');" +
    "nx.title='Next sweep '+nx.dataset.due+' ('+(o>0?'in '+ag(o):(same?'waiting for it':'due now')+(o<0?', overdue '+ag(-o):''))+')'+nx.dataset.tail;nx.textContent='next '+nx.dataset.due+(o<0?' (overdue)':'');d.querySelectorAll('.ago').forEach(function(e){e.textContent=ag(Math.max(0,Math.round((w-new Date(e.dataset.t))/6e4)))})}u();setInterval(u,1e4);" +
    "d.getElementById('tt').onclick=function(){var k=r.dataset.theme?r.dataset.theme=='dark':matchMedia('(prefers-color-scheme: dark)').matches;r.dataset.theme=k?'light':'dark';L.setItem('kc-theme',r.dataset.theme)};" +
    "var ar=d.getElementById('ar'),on=L.getItem('kc-ar')!=='0',tm;function sa(){ar.setAttribute('aria-pressed',on);ar.title=on?'Auto-refresh every 60 s':'Auto-refresh off';ar.setAttribute('aria-label',ar.title);clearTimeout(tm);if(on)tm=setTimeout(function(){if(d.querySelector('dialog.drw[open]')){sa();return}var p={};d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){if(e.scrollTop||e.scrollLeft)p[s.id+i]=[e.scrollTop,e.scrollLeft]})});S.setItem('kc-sp',JSON.stringify(p));S.setItem('kc-y',scrollY);location.reload()},6e4)}ar.onclick=function(){on=!on;L.setItem('kc-ar',on?'1':'0');sa()};sa();" +
    "function jp(k,f){try{return JSON.parse(L.getItem(k))||f}catch(e){return f}}var op=jp('kc-open',{});d.querySelectorAll('details.sec').forEach(function(s){if(s.classList.contains('none')){s.querySelector(':scope>summary').addEventListener('click',function(x){x.preventDefault()});return}if(s.id in op)s.open=op[s.id];s.querySelector(':scope>summary').addEventListener('click',function(){setTimeout(function(){delete s.dataset.fo;var o=jp('kc-open',{});o[s.id]=s.open;try{L.setItem('kc-open',JSON.stringify(o))}catch(e){}})})});" +   # the owner's own clicks only: a default never pins itself
    "var q=d.getElementById('q'),nm=d.getElementById('nm'),AL=jp('kc-all',[]);function tk(t){var s=t.closest('details'),h=s&&s.querySelector(':scope>summary>:first-child'),r=t.querySelector('tr');return(h?h.textContent:'')+':'+(r?r.textContent:'')}" +   # show all: kept per table
    "function sa0(){d.querySelectorAll('.tw').forEach(function(t){var b=t.querySelector(':scope>.sa');if(!b)return;var on=!!q.value||AL.indexOf(tk(t))>=0;t.classList.toggle('all',on);b.textContent=on?'Show fewer':'Show all ('+b.dataset.n+')'})}" +
    "d.addEventListener('click',function(x){var b=x.target.closest('.sa');if(!b)return;var k=tk(b.parentNode),i=AL.indexOf(k);if(i>=0)AL.splice(i,1);else AL.push(k);L.setItem('kc-all',JSON.stringify(AL));sa0();ca()});" +
    "d.querySelectorAll('.jl a').forEach(function(a){a.addEventListener('click',function(){for(var s=d.querySelector(a.getAttribute('href'));s;s=s.parentElement&&s.parentElement.closest('details'))s.open=true})});" +   # a jump opens its section and the bands around it
    "function tx(x){var s=x.textContent;x.querySelectorAll('svg title').forEach(function(t){s=s.replace(t.textContent,'')});return s.toLowerCase()}" +   # icon titles are no match ('gb', 'ram' would hit every card)
    "function fl(){var v=q.value.toLowerCase();S.setItem('kc-q',q.value);d.documentElement.classList.toggle('flq',!!v);d.querySelectorAll('.f').forEach(function(x){x.hidden=!!v&&tx(x).indexOf(v)<0});d.querySelectorAll('tbody.grp').forEach(function(g){g.hidden=!g.querySelector('tr.f:not([hidden])')});" +
    "d.querySelectorAll('details.lx').forEach(function(x){if(v&&tx(x).indexOf(v)>=0){if(!x.open){x.open=true;x.dataset.fo=1}}else if(!v&&x.dataset.fo){x.open=false;delete x.dataset.fo}});d.querySelectorAll('details.sec').forEach(function(s){if(v){if(!s.open&&s.querySelector('.f:not([hidden])')){s.open=true;s.dataset.fo=1}}else if(s.dataset.fo){s.open=false;delete s.dataset.fo}});nm.hidden=!v||!!d.querySelector('.f:not([hidden])');sa0()}q.oninput=fl;sa0();q.value=S.getItem('kc-q')||'';if(q.value)fl();d.addEventListener('keydown',function(x){if(x.key=='/'&&d.activeElement!=q){x.preventDefault();q.focus()}});" +
    "var SC='.bd,.info,.tw,.sy,.sxb';function cu(e){var v=e.scrollHeight>e.clientHeight+1,h=e.scrollWidth>e.clientWidth+1,c=e.classList,o=v||h;c.toggle('sc',o);if(o)e.tabIndex=0;else e.removeAttribute('tabindex');c.toggle('u',v&&e.scrollTop>1);c.toggle('d',v&&e.scrollTop+e.clientHeight<e.scrollHeight-1);c.toggle('l',h&&e.scrollLeft>1);c.toggle('r',h&&e.scrollLeft+e.clientWidth<e.scrollWidth-1)}" +
    "function ca(){d.querySelectorAll(SC).forEach(cu)}ca();addEventListener('resize',ca);d.addEventListener('toggle',ca,true);q.addEventListener('input',ca);" +
    # masonry (owner, 2026-11-13): a card grid ([data-mas]) packs cards in order into the shortest column; one column = plain flow
    # heights at the packed width (.msm), inner grids first; run twice (inner grids pack before outer ones)
    # a tile grid ([data-fill], owner 2026-11-14): of up to 3 column counts the one with the least empty area wins, then in each column the lowest
    # tile ending in a graph (else the last tile) stretches to the tallest column (.msl: that graph takes the room, capped; no gap under a short tile)
    "function pk(g,it,n,gp){g.style.setProperty('--mc',n);g.classList.add('msm');var hs=it.map(function(c){return c.getBoundingClientRect().height}),tp=[],pl=[],i;g.classList.remove('msm');for(i=0;i<n;i++)tp.push(0);it.forEach(function(c,j){var h=Math.ceil(hs[j]+gp),k=c.hasAttribute('data-end')&&!tp[n-1]?n-1:tp.indexOf(Math.min.apply(0,tp));pl.push([k,tp[k],h]);tp[k]+=h});" +
    # balance (owner 2026-11-18): greedy order can leave one column far taller; with few cards try every column split (order kept per column), the lowest tallest column wins
    "var L=it.length,hh=hs.map(function(x){return Math.ceil(x+gp)}),nz=Math.pow(n,L);if(nz<=20000&&!it.some(function(c){return c.hasAttribute('data-end')})){var bm=Math.max.apply(0,tp),ba=null,a=[],t2=[],z,y;for(z=1;z<nz;z++){y=z;for(i=0;i<L;i++){a[i]=y%n;y=Math.floor(y/n)}for(i=0;i<n;i++)t2[i]=0;for(i=0;i<L;i++)t2[a[i]]+=hh[i];var m2=Math.max.apply(0,t2);if(m2<bm-1&&Math.min.apply(0,t2)>0){bm=m2;ba=a.slice()}}" +
    "if(ba){for(i=0;i<n;i++)tp[i]=0;pl=[];for(i=0;i<L;i++){pl.push([ba[i],tp[ba[i]],hh[i]]);tp[ba[i]]+=hh[i]}}}" +
    "var mh=Math.max.apply(0,tp),em=0;tp.forEach(function(t){em+=(mh-t)*(g.clientWidth-(n-1)*gp)/n});return{n:n,pl:pl,tp:tp,mh:mh,em:em}}" +
    "function ms(){[].slice.call(d.querySelectorAll('[data-mas]')).reverse().forEach(function(g){var it=[].filter.call(g.children,function(c){return!c.hidden});g.classList.remove('msn','msm');it.forEach(function(c){c.style.gridColumn=c.style.gridRow=c.style.marginBottom='';c.classList.remove('msl');c.removeAttribute('data-short')});if(!g.clientWidth||it.length<2)return;" +
    "var cs=getComputedStyle(g),gp=parseFloat(cs.columnGap)||8,st=g.getAttribute('style')||'',mn=parseFloat((st.match(/--cmin:\s*([\d.]+)/)||[])[1])||200,mx=parseInt((st.match(/--cmax:\s*(\d+)/)||[])[1])||99,n=Math.max(1,Math.min(mx,it.length,Math.floor((g.clientWidth+gp)/(mn+gp))));if(n<2)return;" +
    "var fill=g.hasAttribute('data-fill'),b=pk(g,it,n,gp);if(fill)for(var m=n-1;m>=Math.max(2,n-2);m--){var r=pk(g,it,m,gp);if(r.em<b.em*0.8)b=r}g.style.setProperty('--mc',b.n);g.classList.add('msn');var la={};" +
    "it.forEach(function(c,j){var p=b.pl[j];c.style.gridColumn=p[0]+1;c.style.gridRow=(p[1]+1)+' / span '+p[2];(la[p[0]]=la[p[0]]||[]).push(j)});if(fill)Object.keys(la).forEach(function(k){var js=la[k],ex=b.mh-b.tp[k],t=js[js.length-1],sh=0;js.forEach(function(j){var l=it[j].lastElementChild;if(l&&l.matches('.spk,.dbr,.lcf'))t=j});" +
    # K74: the graph grows to 160 px at most (a taller row leaves room under the column, never an empty chart); no graph: no stretch;
    # a column left short is marked data-short (uiChecks skips it)
    "var lg=it[t].lastElementChild,e0=ex;ex=lg&&lg.matches('.spk,.dbr,.lcf')?Math.max(0,Math.min(ex,Math.floor(160-lg.getBoundingClientRect().height))):0;if(ex<e0)it[js[js.length-1]].setAttribute('data-short','');" +
    "js.forEach(function(j){var c=it[j],p=b.pl[j];if(j==t&&ex>0){c.style.gridRow=(p[1]+1)+' / span '+(p[2]+ex);c.style.marginBottom=gp+'px';c.classList.add('msl');sh=ex}else if(sh)c.style.gridRow=(p[1]+1+sh)+' / span '+p[2]})})})}" +
    "ms();ms();addEventListener('resize',ms);d.addEventListener('toggle',ms,true);q.addEventListener('input',ms);" +
    "window.uiChecks=function(){var o=[],h=d.querySelector('header.top');if(innerWidth>=1100&&h.offsetHeight>48)o.push({el:'header.top',why:'header '+h.offsetHeight+' px tall: one row at desktop width',text:''});d.querySelectorAll('.bar,.mb,.sb,.lt,.sbh,svg.spark').forEach(function(b){var n=b.nextElementSibling;if(b.getClientRects().length&&!(b.getAttribute('aria-label')||b.getAttribute('title')||n&&n.textContent.trim()))o.push({el:b.getAttribute('class'),why:'a bar without a text label',text:''})});" +
    "if(innerWidth>=1100)d.querySelectorAll('[data-row]').forEach(function(w){var hs=[].map.call(w.children,function(c){return c.getBoundingClientRect().height}).filter(function(h){return h>0}),g=hs.length>1?Math.max.apply(0,hs)-Math.min.apply(0,hs):0;if(g>48)o.push({el:w.className,why:'sibling heights differ by '+Math.round(g)+' px (max 48)',text:''})});" +   # dashboard-design.md: a row's siblings within 48 px
    "d.querySelectorAll('[data-mas]').forEach(function(g){var it=[].filter.call(g.children,function(c){return c.getClientRects().length}).map(function(c){var r=c.getBoundingClientRect();return{l:Math.round(r.left),t:r.top,b:r.bottom}}),ls=[],g0=g.getBoundingClientRect().top;it.forEach(function(x){if(ls.indexOf(x.l)<0)ls.push(x.l)});if(ls.length<2)return;" +
    "it.forEach(function(x){ls.forEach(function(l){if(l==x.l)return;var bt=g0;it.forEach(function(y){if(y.l==l&&y.t<x.t-1)bt=Math.max(bt,y.b)});if(x.t-bt>48)o.push({el:g.className,why:'a card starts '+Math.round(x.t-bt)+' px below free space in another column (max 48): pack the grid',text:''})})})});" +   # card grids: no card under a column with 48+ px free above it
    "d.querySelectorAll('[data-fill].msn').forEach(function(g){var bt={},sk={};[].forEach.call(g.children,function(c){if(!c.getClientRects().length)return;var r=c.getBoundingClientRect(),l=Math.round(r.left);bt[l]=Math.max(bt[l]||0,r.bottom);if(c.hasAttribute('data-short'))sk[l]=1});var v=Object.keys(bt).filter(function(k){return!sk[k]}).map(function(k){return bt[k]}),df=v.length>1?Math.round(Math.max.apply(0,v)-Math.min.apply(0,v)):0;if(df>48)o.push({el:g.className,why:'tile columns end '+df+' px apart (max 48): the last tile of each column stretches',text:''})});" +   # one tile row, one height
    "d.querySelectorAll('.msl').forEach(function(c){var l=c.lastElementChild,p=l&&l.previousElementSibling;while(p&&!p.getClientRects().length)p=p.previousElementSibling;if(!p||!c.getClientRects().length)return;var lr=l.getBoundingClientRect(),gp=Math.round(lr.top-p.getBoundingClientRect().bottom);if(gp>48||lr.height>175)o.push({el:c.className,why:'a stretched tile: '+(gp>48?gp+' px empty above its graph (max 48)':'graph '+Math.round(lr.height)+' px tall (max 175)'),text:(c.firstElementChild||c).textContent.slice(0,40)})});" +   # K74: no empty or oversized stretched graph
    "d.querySelectorAll('.ug,[data-mas].msn:not([data-fill])').forEach(function(g){var bt={};[].forEach.call(g.children,function(c){if(!c.getClientRects().length)return;var r=c.getBoundingClientRect(),l=Math.round(r.left);bt[l]=Math.max(bt[l]||0,r.bottom)});var v=Object.keys(bt).map(function(k){return bt[k]}),df=v.length>1?Math.round(Math.max.apply(0,v)-Math.min.apply(0,v)):0;if(df>80)o.push({el:g.className,why:'two-column section: columns end '+df+' px apart (max 80)',text:''})});" +   # owner 2026-11-17: no empty band in a two-column section
    "d.querySelectorAll('details.sub,details.sub>.bd,.st').forEach(function(c){if(!c.getClientRects().length||c.classList.contains('msl'))return;var p=null;[].forEach.call(c.children,function(x){if(!x.getClientRects().length||getComputedStyle(x).position=='absolute')return;var r=x.getBoundingClientRect();if(p&&r.top-p.bottom>32&&r.left<p.right&&r.right>p.left)o.push({el:c.className,why:'an empty band of '+Math.round(r.top-p.bottom)+' px inside a card (max 32)',text:(x.textContent||'').slice(0,40)});p=r})});" +   # owner 2026-11-19: no reserved empty height inside a card
    "d.querySelectorAll('details.top').forEach(function(s){var c=s.querySelector(':scope>summary>.cnt'),b=s.querySelector(':scope>.bd');if(!c||!b)return;(c.textContent.match(/[$]?\d[\d.,]*(%|[kMB]\b|\s?GB\b)|[$]\d[\d.,]*/g)||[]).forEach(function(v){var t=b.textContent,i=t.indexOf(v),hit=false;for(;i>=0&&!hit;i=t.indexOf(v,i+1))hit=!/[\d.]/.test(t.charAt(i-1))&&!/[\d.]/.test(t.charAt(i+v.length));if(hit)o.push({el:s.id,why:'headline value '+v+' in the band header and again inside it',text:c.textContent.trim()})})});return o};" +   # each number once: a band header never repeats a value its body shows
    "d.addEventListener('click',function(x){var c=x.target.closest('code.cp');if(!c)return;x.preventDefault();try{navigator.clipboard.writeText(c.textContent).then(function(){c.classList.add('ok');setTimeout(function(){c.classList.remove('ok')},1200)})}catch(e){}},true);" +   # a release command: click copies, the row stays as it is
    "var oc0=S.getItem('kc-oc');if(oc0&&d.querySelector('.ocb[data-oc=`"'+oc0+'`"]')){r.dataset.ocf=oc0;d.querySelectorAll('.ocb').forEach(function(o){o.setAttribute('aria-pressed',o.dataset.oc==oc0)})}" +   # kept across the 60 s reload
    "d.addEventListener('click',function(x){var b=x.target.closest('.ocb');if(!b)return;var k=b.dataset.oc,on=r.dataset.ocf!=k;if(on)r.dataset.ocf=k;else delete r.dataset.ocf;try{if(on)S.setItem('kc-oc',k);else S.removeItem('kc-oc')}catch(e){}d.querySelectorAll('.ocb').forEach(function(o){o.setAttribute('aria-pressed',on&&o.dataset.oc==k)});if(on){var s=d.getElementById('sec-runs');if(s){for(var p=s;p;p=p.parentElement&&p.parentElement.closest('details'))p.open=true;s.scrollIntoView({block:'start'})}}ms();ca()});" +   # outcome legend: only the runs with a step in it (inside Kit internals: open the bands around it)
    "var tp=d.createElement('div');tp.id='tip';tp.setAttribute('role','tooltip');tp.hidden=true;d.body.appendChild(tp);" +
    "function sh(el){var s=el&&(el.getAttribute('title')||(el.querySelector(':scope>title')||{}).textContent);if(!s){tp.hidden=true;return}tp.textContent=s;tp.hidden=false;var b=el.getBoundingClientRect(),w=tp.offsetWidth,g=tp.offsetHeight;tp.style.left=Math.max(4,Math.min(innerWidth-w-4,b.left))+'px';tp.style.top=(b.bottom+g+6>innerHeight?b.top-g-6:b.bottom+6)+'px'}" +
    "d.addEventListener('scroll',function(x){var e=x.target;if(e.matches&&e.matches(SC))cu(e);tp.hidden=true},true);" +   # touch has no hover: a tap shows the title
    "d.addEventListener('click',function(x){sh(x.target.closest('button')?null:x.target.closest('[title],.hit,circle.val'))});" +
    "d.addEventListener('focusin',function(x){sh(x.target.closest('button')?null:x.target.closest('[title]'))});" +
    # graphs (owner 2026-11-16): [data-tip] = a hover / focus tooltip kept inside its card (a chart column: beside it, never over its own labels);
    # [data-ft] = a click or Enter filters the [data-fk] rows of its targets to data-fv (again, Clear or Esc: all); .lgt = a legend button hides its line
    "function cbx(el){return(el.closest('.uc,.st,details.sub,.ftr')||d.body).getBoundingClientRect()}function tipAt(el){var s=el.dataset.tip;if(!s)return;tp.textContent=s;tp.dataset.k=1;tp.hidden=false;var c=cbx(el),b=el.getBoundingClientRect();tp.style.maxWidth=Math.max(160,Math.min(360,c.width-8))+'px';var w=tp.offsetWidth,g=tp.offsetHeight,l,t;" +
    "if(el.classList.contains('col')){l=b.left+b.width/2+10;if(l+w>c.right-4)l=b.left+b.width/2-w-10;t=c.top+Math.max(4,(c.height-g)/2)}else{l=b.left+b.width/2-w/2;t=b.top-g-6;if(t<Math.max(4,c.top))t=b.bottom+6}l=Math.max(c.left+4,Math.min(c.right-w-4,l));tp.style.left=Math.max(4,l)+'px';tp.style.top=Math.max(4,t)+'px'}" +
    "function tipOff(){if(tp.dataset.k){tp.hidden=true;delete tp.dataset.k}}d.addEventListener('mouseover',function(x){var t=x.target.closest('[data-tip]');if(t)tipAt(t);else tipOff()});d.addEventListener('focusin',function(x){var t=x.target.closest('[data-tip]');if(t)tipAt(t)});d.addEventListener('focusout',tipOff);" +
    "function fca(){d.querySelectorAll('[data-fsel]').forEach(function(g){delete g.dataset.fsel;g.querySelectorAll('.fo').forEach(function(r){r.classList.remove('fo')});g.querySelectorAll('.fclr').forEach(function(c){c.hidden=true})});d.querySelectorAll('[data-ft]').forEach(function(e){e.setAttribute('aria-pressed',false)});ms();ca()}" +
    "function fsel(src){var fv=src.dataset.fv,gs=d.querySelectorAll(src.dataset.ft),on=src.getAttribute('aria-pressed')!='true';fca();if(!on)return;gs.forEach(function(g){g.dataset.fsel=fv;g.querySelectorAll('[data-fk]').forEach(function(r){r.classList.toggle('fo',(' '+r.dataset.fk+' ').indexOf(' '+fv+' ')<0)});g.querySelectorAll('.fclr').forEach(function(c){c.hidden=false;c.querySelector('b').textContent=src.dataset.fl||fv});for(var p=g.closest('details');p;p=p.parentElement&&p.parentElement.closest('details'))p.open=true});src.setAttribute('aria-pressed',true);ms();ca()}" +
    "d.addEventListener('click',function(x){if(x.target.closest('.fclr button')){fca();return}var b=x.target.closest('.lgt');if(b){var k=b.dataset.s,h=b.closest('.lgw').classList.toggle('h'+k);b.setAttribute('aria-pressed',!h);return}var s=x.target.closest('[data-ft]');if(s&&!x.target.closest('a'))fsel(s)});" +
    "d.addEventListener('keydown',function(x){if(x.key=='Escape'){fca();tipOff();return}var s=x.target.closest&&x.target.closest('[data-ft]');if(s&&(x.key=='Enter'||x.key==' ')){x.preventDefault();fsel(s)}});" +
    # Settings tiles: one open group (its panel under the tile's row), Changed only, Expand all = list; kept in kc-tg, the search in kc-tgq
    "(function(){var g=d.querySelector('.tgs'),bx=d.getElementById('tgq');if(!g)return;var ts=jp('kc-tg',{});function sv(){try{L.setItem('kc-tg',JSON.stringify(ts))}catch(e){}}" +
    "function ap(){var lq=!!bx.value;g.classList.toggle('ch',!!ts.ch);g.classList.toggle('all',!!ts.all||lq);g.querySelectorAll('.tgb').forEach(function(b){var on=!ts.all&&!lq&&b.id==ts.op;b.setAttribute('aria-expanded',on);d.getElementById(b.getAttribute('aria-controls')).classList.toggle('on',on)});" +
    "d.querySelectorAll('[data-tga]').forEach(function(b){var k=b.dataset.tga;if(k!='none')b.setAttribute('aria-pressed',!!ts[k])});g.querySelectorAll('.tkt tbody').forEach(rep);ca()}" +
    "function sq(){var v=bx.value.toLowerCase();S.setItem('kc-tgq',bx.value);g.querySelectorAll('.tgp').forEach(function(p){var n=0;p.querySelectorAll('tbody tr').forEach(function(r){var o=!!v&&r.textContent.toLowerCase().indexOf(v)<0;r.classList.toggle('sx',o);if(!o)n++});p.classList.toggle('sx',!n)});ap()}" +
    # a key shows once per run of visible rows (filters, Changed only and sorting hide or move rows)
    "function rep(tb){var pk=null;tb.querySelectorAll('tr').forEach(function(r){if(!r.offsetParent)return;r.cells[0].classList.toggle('rep',r.dataset.k==pk);pk=r.dataset.k})}d.getElementById('q').addEventListener('input',function(){g.querySelectorAll('.tkt tbody').forEach(rep)});" +
    "d.addEventListener('click',function(x){var a=x.target.closest('[data-tga]');if(a){var k=a.dataset.tga;if(k=='none'){ts.all=false;ts.op=''}else ts[k]=!ts[k];sv();ap();return}if(!g.contains(x.target))return;var b=x.target.closest('.tgb');if(b){ts.op=ts.op==b.id?'':b.id;sv();ap();return}" +
    "var c=x.target.closest('.tpx');if(c){var t=c.closest('.tgp').dataset.t;ts.op='';ts.all=false;sv();ap();var tb=d.getElementById(t);if(tb)tb.focus();return}" +
    "var h=x.target.closest('.tks');if(h){var th=h.parentNode,tr=th.parentNode,ci=[].indexOf.call(tr.children,th),dn=th.getAttribute('aria-sort')=='ascending',tb=th.closest('table').tBodies[0];tr.querySelectorAll('th').forEach(function(z){z.setAttribute('aria-sort','none')});th.setAttribute('aria-sort',dn?'descending':'ascending');" +
    "[].slice.call(tb.rows).map(function(r){var cl=r.cells[ci];return[cl.dataset.s!=null?cl.dataset.s:cl.textContent.trim(),r]}).sort(function(p,q){var u=parseFloat(p[0]),w=parseFloat(q[0]),nu=String(u)==p[0],nv=String(w)==q[0],o=nu&&nv?u-w:nu?-1:nv?1:p[0].localeCompare(q[0]);return dn?-o:o}).forEach(function(z){tb.appendChild(z[1])});rep(tb)}});" +
    "d.addEventListener('keydown',function(x){if(x.key=='Escape'&&ts.op&&!ts.all&&!bx.value){var b=d.getElementById(ts.op);ts.op='';sv();ap();if(b)b.focus()}});bx.value=S.getItem('kc-tgq')||'';bx.oninput=sq;sq()})();" +
    "d.querySelectorAll('[data-tsv]').forEach(function(b){b.onclick=function(x){x.preventDefault();x.stopPropagation();navigator.clipboard.writeText(b.dataset.tsv).then(function(){b.textContent='copied'})}});" +
    "var sp=JSON.parse(S.getItem('kc-sp')||'{}'),y=S.getItem('kc-y');S.removeItem('kc-sp');S.removeItem('kc-y');d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){var v=sp[s.id+i];if(v){e.scrollTop=v[0];e.scrollLeft=v[1]}})});ca();if(y)scrollTo(0,+y)})()"   # after collapse + filter: the layout is final
  $head = "<header class=top><div class=brand>$mark<span>claude-crew</span><small>Supervisor</small></div><div class=meta><span id=age class=chip title='Last sweep $($at.ToString('yyyy-MM-dd HH:mm'))' data-at='$($at.ToString('o'))' data-next='$(& $e $nextMin)'></span><span id=nx title='$(& $e $j.next)' data-due='$($at.AddMinutes([double]$dueMin).ToString('HH:mm'))' data-dn='$(& $e $dueMin)' data-tail='$(& $e $nxTail)'>next $($at.AddMinutes([double]$dueMin).ToString('HH:mm'))</span></div><nav class=jl aria-label='Sections'>$((@(@('flags', 'Flags'), @('runs', 'Runs'), @('machine', 'Machine'), @('trends', 'Trends'), @('internals', 'Kit internals')) | ForEach-Object { "<a href='#sec-$($_[0])'>$($_[1])</a>" }) -join '')<span class='chip lv ACT'>$nAct ACT</span><span class='chip lv WATCH'>$nWatch WATCH</span></nav><div class=sp></div>" +
    "<div class=tb><input id=q type=search placeholder='Filter  ( / )' aria-label='Filter the page'><button id=ar class=ib type=button aria-pressed=true aria-label='Auto-refresh every 60 s' title='Auto-refresh every 60 s'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4' fill=none stroke=currentColor stroke-width=2 stroke-linecap=round /></svg></button><button id=tt class=ib type=button aria-label='Toggle theme' title='Toggle theme'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z' fill=currentColor /></svg></button></div></header>"
  # top to bottom (owner 2026-11-19): flags, runs, resources, shells; Kit internals (folded) = Trends + Tuning
  $nSh = @($j.shells | Where-Object { $_ }).Count
  # Trends (owner 2026-11-19): Delivery + Usage + kit health in one day heatmap, its tiles one strip, spend and repos as sub-blocks (adapters/outcomes.ps1)
  $oc = if (Get-Command Get-KitOutcomeStats -ErrorAction SilentlyContinue) { try { Get-KitOutcomeStats -StatsFrom (Get-KitStatsCutoff) } catch { $null } }
  $trends = try { Format-KitDeliveryHtml $oc $UP (Format-KitQaTile $st.qa $at) @(@($hRows) + @($UP.dayRows)) "$($UP.spend)$(Format-KitRepoGrid $st.repos $st.sync)" } catch { "<p class=m>Trends view failed: $(& $e $_.Exception.Message)</p>" }
  $runsH = try { Format-KitRunsTimeline @($st.usage.runs) $agents @($UP.pages.Keys) $st.usage.at } catch { "<p class=m>Runs view failed: $(& $e $_.Exception.Message)</p>" }
  if ($null -ne $Pages -and $UP.pages) { foreach ($pk in @($UP.pages.Keys)) { $Pages["$pk"] = "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Run $(& $e $pk)</title><style>$css</style><script>try{var t=localStorage.getItem('kc-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script></head><body><main class='wrap rpg'>$($UP.pages[$pk] -replace " data-tip='", " title='")</main></body></html>" } }
  $main = "<main class=wrap>" + (& $section 'flags' 'Flags' '' $flagHtml -Open -extra '<button type=button class=ga data-tg=fl-hist aria-expanded=false>24 h history</button>') +
    (& $section 'runs' 'Runs' "$(if ($UP.nRunning) { "$($UP.nRunning) running · " })$(if ($UP.runsN) { $UP.runsN } else { 'none ended in 7 days' })" "<p class=fclr hidden>Runs: <b></b> <button type=button>Clear</button></p>$runsH" -Open) +   # a Trends day click filters the runs
    (& $section 'machine' 'Machine and resources' '' $machineHtml -Open) + (& $section 'shells' 'Shells' $nSh "<div class='sxb fx sh'>$shellHtml</div>" -Open) +
    (& $section 'internals' 'Kit internals' '' ((& $fold 'trends' 'Trends' '' $trends -Open -cls sub) + $setHtml)) +
    "<p id=nm class=empty hidden>No match.</p><footer>Written by bossy.ps1 supervise each sweep (no model tokens) · data: supervise-report.json · times local (UTC$($at.ToString('zzz')))</footer></main>"
  "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><noscript><meta http-equiv=refresh content=60></noscript><title>Supervisor $($at.ToString('HH:mm'))$(if ($nAct) { " · $nAct ACT" })</title>$fav<style>$css</style><script>try{var t=localStorage.getItem('kc-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script></head><body>$head$main<script>$js</script><script>$(Get-KitStatsJs)</script></body></html>"
}
# page CSS: muted sage palette, light / dark (prefers-color-scheme; data-theme overrides)
function Get-KitSupervisePageCss {
  $dark = '--bg:#0c0c0c;--sf:#161b16;--sf2:#212a21;--fg:#d8dee9;--mt:#8a948a;--ln:#2e3a2e;--sage:#79a86a;--sage2:#9fd48c;--act:#dc9089;--watch:#e0ce8a;--slate:#7f9caa;--plum:#a993b0;--k2:#86a87a;--k3:#ab8f78;--k4:#7a8277;--kcap:.42;--hmt:#0c0c0c;--sh:0 4px 20px rgba(0,0,0,0.45)'
  ':root{--bg:#f4f7f4;--sf:#ffffff;--sf2:#eaefea;--fg:#1a221a;--mt:#5e6c5e;--ln:#d5dfd5;--sage:#647c64;--sage2:#79a86a;--act:#ce8f8a;--watch:#c4b06a;--slate:#5e7f8c;--plum:#8f7a98;--k2:#7f9a78;--k3:#a98a74;--k4:#a6aca2;--kcap:.6;--hmt:#1a221a;--sh:0 1px 3px rgba(26,34,26,.06),0 1px 2px rgba(26,34,26,.04)}' +
  "[data-theme=dark]{$dark}@media(prefers-color-scheme:dark){:root:not([data-theme=light]){$dark}}" +
  # no scrollbars (owner 2026-11-09): JS marks overflowing boxes .sc and their edges with more content (u d l r): faded by the mask
  '*{box-sizing:border-box;scrollbar-width:none}::-webkit-scrollbar{display:none}html{touch-action:manipulation}.sc{overscroll-behavior:contain;-webkit-overflow-scrolling:touch;--u:0px;--d:0px;--l:0px;--r:0px;mask:linear-gradient(#0000,#000 var(--u),#000 calc(100% - var(--d)),#0000),linear-gradient(90deg,#0000,#000 var(--l),#000 calc(100% - var(--r)),#0000);mask-composite:intersect}' +
  '.sc.u{--u:28px}.sc.d{--d:28px}.sc.l{--l:28px}.sc.r{--r:28px}.sc:focus-visible{outline:2px solid var(--sage);outline-offset:-2px}' +
  '#tip{position:fixed;z-index:9;max-width:min(360px,90vw);padding:6px 9px;border-radius:8px;background:var(--fg);color:var(--bg);font-size:12px;box-shadow:var(--sh);pointer-events:none;word-break:break-word}' +
  'body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Inter",sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}' +
  'b{font-weight:600}.m,.sm{color:var(--mt)}.sm{font-size:11.5px;margin-top:2px}h3{font-size:11.5px;font-weight:600;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;margin:12px 0 6px}' +
  'header.top{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;padding:6px 20px;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--ln)}' +
  '.brand{display:flex;align-items:center;gap:10px;font-weight:650;font-size:15px;letter-spacing:-.01em}.brand svg{width:26px;height:26px;flex:none}.brand small{color:var(--mt);font-weight:500;font-size:13px;padding-left:10px;border-left:1px solid var(--ln)}' +
  '.meta{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;color:var(--mt);font-size:12.5px}.meta b{color:var(--fg)}.sp{flex:1}' +
  'input[type=search]{font:inherit;font-size:12.5px;color:var(--fg);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;width:clamp(150px,18vw,260px);outline:none}.tb{display:flex;gap:8px}input[type=search]:focus{border-color:var(--sage)}' +
  'input[type=search],button{min-height:40px}button{min-width:40px;justify-content:center;font:inherit;font-size:12px;color:var(--mt);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;cursor:pointer;display:inline-flex;align-items:center}button:hover{color:var(--fg)}button[aria-pressed=true]{color:var(--sage2)}' +
  '.chip{display:inline-flex;align-items:center;gap:5px;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;letter-spacing:.03em;background:var(--sf2);color:var(--mt);white-space:nowrap}.chip::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;opacity:.85}' +
  '.chip.ok,.s-act{color:var(--sage2);background:color-mix(in srgb,var(--sage) 17%,transparent)}.chip.warn,.s-oth,.lv.WATCH{color:color-mix(in srgb,var(--watch) 55%,var(--fg));background:color-mix(in srgb,var(--watch) 16%,transparent)}.chip.bad,.s-stuck,.lv.ACT{color:color-mix(in srgb,var(--act) 55%,var(--fg));background:color-mix(in srgb,var(--act) 15%,transparent)}.s-fin{color:color-mix(in srgb,var(--slate) 55%,var(--fg));background:color-mix(in srgb,var(--slate) 14%,transparent)}' +
  # compact (owner 2026-11-13): 8-12 px gaps, cards as tall as their content
  '.wrap{max-width:1800px;margin:0 auto;padding:10px 20px 24px}.cg{display:flex;flex-wrap:wrap;gap:var(--cgap,8px);align-items:flex-start}.cg>*{flex:1 1 max(min(100%,var(--cmin,200px)),calc((100% - (var(--cmax,99) - 1) * var(--cgap,8px)) / var(--cmax,99)));min-width:0;box-sizing:border-box}' +
  'details.sec{background:var(--sf);border:1px solid var(--ln);border-radius:10px;box-shadow:var(--sh);margin-top:10px}.st .k{font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.07em;font-weight:600}' +
  '.spark{display:block;width:100%;height:22px;margin-top:4px}.spark .l{fill:none;stroke:currentColor;stroke-width:1.6;vector-effect:non-scaling-stroke;stroke-linejoin:round}.spark .a{fill:currentColor;opacity:.12}' +
  '.sage{color:color-mix(in srgb,var(--sage) 55%,var(--fg))}.act{color:color-mix(in srgb,var(--act) 55%,var(--fg))}.watch{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.slate{color:color-mix(in srgb,var(--slate) 55%,var(--fg))}' +
  '.fbl>details>.bd,.sxb{max-height:clamp(150px,40dvh,480px);overflow-y:auto}.sxb{max-height:clamp(150px,30dvh,320px)}' +   # long lists scroll inside; content never truncates, it wraps (owner 2026-11-10)
  '.fx table{table-layout:fixed;min-width:0}.fx th:last-child:nth-child(n+6){width:30%}tr.hl td{background:color-mix(in srgb,var(--sage) 12%,transparent)}.fx.sh th{width:auto!important}.sh .ago{white-space:nowrap}' +   # fixed layout, wrapping cells: no horizontal scroll at 1366 px
  'summary{list-style:none;cursor:pointer;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;padding:6px 12px;min-height:36px;user-select:none}summary::-webkit-details-marker{display:none}' +
  'summary h2{margin:0;font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:.07em}summary::after{content:"";margin-left:auto;width:7px;height:7px;border-right:1.5px solid var(--mt);border-bottom:1.5px solid var(--mt);transform:rotate(45deg);transition:transform .15s}details:not([open])>summary::after{transform:rotate(-45deg)}' +
  '.cnt{font-size:11.5px;color:var(--mt);font-variant-numeric:tabular-nums}.bd{padding:0 12px 10px}details.sub{border:1px solid var(--ln);border-radius:8px;margin-top:8px;align-self:start}details.sub>summary{min-height:30px;padding:4px 10px}summary :is(h3,h4){margin:0}details.st.sub{padding:0}details.st.sub>.bd{padding:0 10px 8px}details.none>summary{cursor:default}details.none>summary::after{display:none}summary:focus-visible{outline:2px solid var(--sage);outline-offset:-2px;border-radius:8px}.jl{display:flex;flex-wrap:wrap;gap:4px 10px;align-items:center;font-size:12px}.jl a{color:var(--mt);text-decoration:none}.jl a:hover,.jl a:focus-visible{color:var(--fg)}.lv.FIX{color:color-mix(in srgb,var(--sage) 55%,var(--fg));background:color-mix(in srgb,var(--sage) 15%,transparent)}summary .chip.lv{margin-left:2px}.tw:not(.all) tr.more{display:none}:is(.sa,.ga){margin:6px 0 2px;font:inherit;font-size:12px;background:var(--sf2);color:var(--fg);border:1px solid var(--ln);border-radius:6px;padding:2px 10px;cursor:pointer}.bar.sb3{display:inline-flex;gap:1px}.bar.sb3 i{border-radius:0}.bar i.mt{background:var(--mt)}.tm{color:var(--mt)}.dots{display:flex;flex-wrap:wrap;gap:3px;margin-top:6px}.dots i{width:8px;height:8px;border-radius:50%;border:1px solid var(--mt)}.dots i.on{background:var(--slate);border-color:var(--slate)}:is(td[data-k=Key],td[data-k=Context],td[data-k=Dir],td[data-k=Command]){font-family:ui-monospace,Consolas,monospace;font-size:11.5px}.fmas{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:8px;align-content:start;align-items:start}.fmas>.flag{margin:0}' +
  # the trend: a fixed-height tile, never stretched by the cards; one column: after them; holds: one compact row each
  '.ftr{margin:0;border:1px solid var(--ln);border-radius:8px;padding:6px 8px 4px;background:var(--sf);display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:6px;min-width:0;align-self:start}.fmas:not(.msn)>.ftr{order:9}.ftr figcaption{grid-column:1/-1;display:flex;flex-wrap:wrap;justify-content:space-between;gap:2px 8px;font-size:11px;color:var(--mt);margin-bottom:4px}.ftr figcaption b{font-weight:600;color:var(--fg)}.lgs{white-space:nowrap}.ftr .lcp{height:100px}.fty{display:flex;flex-direction:column;justify-content:space-between;font-size:10.5px;color:var(--mt);text-align:right;font-variant-numeric:tabular-nums}.ftr .ax{grid-column:2;margin-top:2px}' +
  '.fbl{display:flex;flex-wrap:wrap;gap:8px;align-items:flex-start;margin-top:8px}.fbl>details.sub{margin-top:0;flex:1 1 260px;min-width:0}.fbl>details[open]{flex-basis:100%;order:1}' +
  '.hold{list-style:none;margin:0;padding:0;display:grid;gap:4px}.hr{display:grid;grid-template-columns:minmax(90px,auto) auto minmax(0,1fr);gap:4px 10px;align-items:baseline;padding:4px 8px;font-size:12.5px;border-radius:6px;background:var(--sf2)}.hc{margin:6px 0 0;font-size:11.5px;color:var(--mt)}' +
  '.hn{color:var(--mt);font-size:11.5px;white-space:nowrap}.hw{overflow-wrap:anywhere;color:var(--mt)}.ht a{color:inherit}code.cp{font:11px ui-monospace,Consolas,monospace;overflow-wrap:anywhere;cursor:copy;color:var(--fg)}code.cp.ok{color:var(--sage2)}' +
  '@media(max-width:899px){.hr{grid-template-columns:minmax(0,auto) minmax(0,1fr)}.hr .hw{grid-column:1/-1}}' +
  '.lgd{display:inline-block;width:14px;height:0;border-top:2px solid var(--c);vertical-align:middle;margin:0 3px 0 6px}.lgd.ds{border-top-style:dashed}.lgd.dd{border-top-style:dotted}' +
  '.sh4{margin:6px 0 2px;font-size:12px;color:var(--mt)}' +
  '.cmd>summary{cursor:pointer;overflow-wrap:anywhere;display:block;padding:0;min-height:0}.cmd>summary::after{content:none}.cmd>summary .cnt{white-space:nowrap}.cmdf{white-space:pre-wrap;overflow-wrap:anywhere;margin-top:4px;font-size:11.5px}.lc{display:flex;flex-wrap:wrap;gap:3px;margin-top:2px}.chip.ls{font-size:10.5px;padding:0 6px;background:var(--sf2);color:var(--mt)}.chip.k-build{color:color-mix(in srgb,var(--slate) 55%,var(--fg))}.chip.k-test{color:color-mix(in srgb,var(--plum) 55%,var(--fg))}.chip.k-kit{color:var(--mt)}' +
  '.flag{border:1px solid var(--ln);border-left:3px solid var(--watch);border-radius:8px;padding:6px 10px}.flag.ACT{border-left-color:var(--act);background:color-mix(in srgb,var(--act) 5%,var(--sf))}' +
  '.flag .h{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--mt)}.flag .w{margin:3px 0 2px;word-break:break-word}.flag .n{font-size:12.5px;color:var(--mt);word-break:break-word}.flag .n b{color:var(--sage2);margin-right:4px}.dot{opacity:.5}' +
  '.info{list-style:none;margin:8px 0 0;padding:0;font-size:12.5px;color:var(--mt)}.info li{padding:2px 0 2px 14px;position:relative;word-break:break-word}.info li::before{content:"";position:absolute;left:2px;top:9px;width:5px;height:5px;border-radius:50%;background:var(--sage)}' +
  '.empty{margin:0;padding:8px;text-align:center;color:var(--mt);border:1px dashed var(--ln);border-radius:8px;font-size:12.5px}' +
  '.ax{display:flex;justify-content:space-between;gap:8px;font-size:11px;color:var(--mt);margin-top:4px}' +
  '.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:12.5px}th{text-align:left;font-weight:600;font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;padding:4px 6px;border-bottom:1px solid var(--ln);overflow-wrap:break-word}' +   # headers break between words only: their longest word sets the column's min width
  'td{padding:3px 6px;border-bottom:1px solid var(--ln);vertical-align:top;overflow-wrap:anywhere}tr:last-child td{border-bottom:0}tr.f:hover td{background:color-mix(in srgb,var(--sf2) 55%,transparent)}' +
  'tr.gh th{background:var(--sf2);color:var(--fg);text-transform:none;letter-spacing:0;white-space:normal;font-size:12.5px;padding:4px 6px;border-radius:0}.gn0{font-weight:650}' +
  '.gtg{all:unset;box-sizing:border-box;cursor:pointer;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px;width:100%}.gtg::before{content:"\25B8";color:var(--mt);transition:transform .15s}tbody.grp:not(.cl) .gtg::before{transform:rotate(90deg)}.gtg:focus-visible{outline:2px solid var(--sage);outline-offset:2px;border-radius:4px}.gcn{font-size:11.5px;font-weight:500;color:var(--mt)}tbody.grp.cl>tr.f{display:none}.flq tbody.grp.cl>tr.f:not([hidden]){display:table-row}summary>.ga{margin:0 0 0 auto;min-height:28px}summary:has(>.ga)::after{margin-left:12px}html:not(.flq) table.ag:not(:has(tbody.grp:not(.cl)))>thead{display:none}' +   # agent groups fold (owner 2026-11-17)
  '.bar{display:inline-block;width:88px;height:6px;border-radius:3px;background:var(--sf2);overflow:hidden;vertical-align:middle;margin:0 6px 0 12px}.bar i{display:block;height:100%;border-radius:3px;background:var(--sage)}.bar i.watch{background:var(--watch)}.bar i.slate{background:var(--slate)}.bar i.act{background:var(--act)}.bar i.plum{background:var(--plum)}.bl{font-size:11.5px;color:var(--mt);font-weight:500}' +
  'td .bar{margin-left:0;width:64px}' +
  '.st{border:1px solid var(--ln);border-radius:8px;padding:6px 10px;min-width:0}.st .v{font-size:19px;font-weight:620;letter-spacing:-.01em;line-height:1.3}.st .v small{font-size:12px;color:var(--mt);font-weight:500}' +
  '.st .w,.st .s{font-size:12px;color:var(--mt)}.st .s,.st .w,.st .v{overflow-wrap:anywhere}.st.warn{border-color:color-mix(in srgb,var(--watch) 50%,var(--ln))}.st.warn>.v,.dk.warn .v{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.st.hot{border-color:color-mix(in srgb,var(--act) 50%,var(--ln))}.st.hot>.v,.dk.hot .v{color:color-mix(in srgb,var(--act) 55%,var(--fg))}.st.lo .v{font-size:16px}' +
  '.dk .v{font-size:17px}' +
  '.ci{border:1px solid var(--ln);border-radius:8px;padding:6px 10px;min-width:0}.ci .sm,.tn{overflow-wrap:anywhere}.ci .bar{display:block;width:100%;margin:4px 0 2px}.bl:empty{display:none}' +
  'footer{margin-top:12px;text-align:center;font-size:11.5px;color:var(--mt)}[hidden]{display:none!important}' +
  # graphs: sparklines, meters (7-day peak tick), lease timelines, the agents-by-state bar, flag icons
  '.spk{margin:4px 0 0}.spw{position:relative}.spk .spark{margin-top:0;height:40px}.ya{position:absolute;left:2px;font-size:10px;line-height:1;color:var(--mt);background:color-mix(in srgb,var(--sf) 70%,transparent);padding:0 2px;border-radius:2px}.ya.hi{top:0}.ya.lo{bottom:0}.nd{position:absolute;right:0;width:7px;height:7px;margin-bottom:-3.5px;border-radius:50%;background:currentColor}.spk figcaption,.mc{display:block;font-size:10.5px;line-height:1.3;color:var(--mt)}.spark .mk{stroke:var(--fg);stroke-width:1;stroke-dasharray:2 2;vector-effect:non-scaling-stroke}' +
  '.mtr{display:flex;align-items:center;gap:8px;margin-top:3px}.mtr .mc{flex:none}.st .k small{text-transform:none;letter-spacing:0;font-weight:500}.mb{flex:1;position:relative;display:block;height:6px;border-radius:3px;background:var(--sf2)}.mb i{display:block;height:100%;border-radius:3px;background:var(--slate)}.mb i.act{background:var(--act)}.mb i.watch{background:var(--watch)}.mb .pk{position:absolute;top:-3px;width:2px;height:12px;margin-left:-1px;border-radius:1px;background:var(--fg)}' +
  '.lt{display:flex;height:5px;margin-top:3px;border-radius:2px;overflow:hidden;background:var(--sf2)}.lt i{display:block}.lt .h0{background:var(--sage)}.lt .h1{background:var(--slate)}.lt .h2{background:var(--plum)}.lt .h3{background:var(--watch)}.lt .hx{background:none}' +
  '.sbh{display:inline-flex;gap:1px;width:120px;height:8px;border-radius:4px;overflow:hidden;background:var(--sf2)}.sbh i.s-act{background:var(--sage)}.sbh i.s-oth{background:var(--watch)}.sbh i.s-stuck{background:var(--act)}.sbh i.s-fin{background:var(--slate)}' +
  # Activity: run chips; per-repo rows (light bar = branches, dark = worktrees); 7 daily bars, value above each
  '.rch{display:flex;flex-wrap:wrap;gap:4px;margin:3px 0}.rch:empty{display:none}.rch .chip{white-space:normal;overflow-wrap:anywhere}.rh>*{color:var(--mt);font-size:10.5px}' +
  '.dbr{margin:0}.dbr figcaption{font-size:10.5px;color:var(--mt)}.dbw,.dbx{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px;text-align:center}.dbw{height:46px;align-items:end;margin-top:4px}.dbc{display:flex;flex-direction:column;justify-content:flex-end;height:100%}.dbc i{min-height:1px;border-radius:2px 2px 0 0;background:var(--slate)}.dbc.on i{background:var(--act)}.dbc b{font-size:10px;line-height:12px}.dbc.z b{color:var(--mt);font-weight:500}.dbx{font-size:10px;color:var(--mt);border-top:1px solid var(--ln)}.dbx .x{color:var(--fg);font-weight:650}' +
  '.fi{width:14px;height:14px;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}' +
  # header: one row from 1100 px (ui-check: window.uiChecks), the filter widens on focus, icon buttons
  '@media(min-width:1100px){header.top{flex-wrap:nowrap;min-height:40px;padding:4px 16px}.jl{flex-wrap:nowrap;white-space:nowrap}}@media(pointer:fine){header.top :is(input,button){min-height:30px}header.top .ib{min-width:30px;padding:4px 7px}}header.top input[type=search]{width:120px;transition:width .15s}header.top input[type=search]:focus{width:220px}' +
  # step outcomes: one stacked bar + its legend with counts
  '.sb{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--sf2);margin:2px 0 4px}.sb i{display:block;min-width:2px}' +
  '.ocl{list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;gap:2px 12px;font-size:12px;color:var(--mt)}.ocl i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px}.ocl b{color:var(--fg)}' +
  # Usage: scroll boxes (sticky header), runs one line each, the chart's past days slate
  'h4{font-size:11.5px;font-weight:600;color:var(--mt);margin:0 0 4px}.sy{max-height:clamp(200px,42dvh,440px);overflow:auto}.sy>.tw{overflow:visible}.sy th{position:sticky;top:0;z-index:1;background:var(--sf)}.sy td{white-space:nowrap}.sy td:first-child{white-space:normal}td{font-variant-numeric:tabular-nums}' +
  '.ru{border:1px solid var(--ln);border-radius:8px;margin:0 0 4px}.ru>summary{display:flex;flex-wrap:wrap;align-items:center;gap:2px 10px;padding:4px 10px;min-height:32px;background:var(--sf2);border-radius:8px;font-size:12.5px;cursor:pointer}.ru[open]>summary{border-radius:8px 8px 0 0}.ru>summary .bar{margin:0}.ru>.sy,.ru>.tw{padding:0 4px 4px}' +
  # a running run: one line (.rh, as a run summary); ended runs: one short line each; .rk = the run page link; .ocb: the outcome filter
  '.ru>.rh{display:flex;flex-wrap:wrap;align-items:center;gap:2px 10px;padding:4px 10px;min-height:32px;background:var(--sf2);border-radius:8px;font-size:12.5px}.ru>.rh .bar{margin:0;background:var(--sf)}.rk{font-size:12px;color:var(--sage2);margin-left:auto}' +
  '.rfl{list-style:none;margin:6px 0 0;padding:0}.rfl>li{display:flex;flex-wrap:wrap;align-items:center;gap:2px 10px;padding:3px 6px;border-bottom:1px solid var(--ln);font-size:12.5px}.rfl .tm{color:var(--mt);font-variant-numeric:tabular-nums}.rpg h1{font-size:18px;margin:4px 0 8px}' +
  '.ocb{font:inherit;color:inherit;background:none;border:1px solid transparent;border-radius:6px;padding:1px 5px;cursor:pointer}.ocb b{margin-left:4px}.ocb[aria-pressed=true]{border-color:var(--sage);background:var(--sf2)}' +
  ((@('pass', 'empty', 'fail', 'stopped', 'running', 'stuck') | ForEach-Object { "[data-ocf=$_] #sec-runs [data-oc]:not([data-oc~=$_])" }) -join ',') + '{display:none}#tip{white-space:pre-line}' +
  # usage cards: the chart beside outcome bar + model table, the role table full width; none stretches
  '.ug{display:grid;gap:8px;margin-top:8px;align-items:start;grid-template-columns:minmax(0,1fr)}.uc{padding:6px 10px;min-width:0}.ru>summary .bar{background:var(--sf)}' +
  '@media(min-width:1100px){.ug{grid-template-columns:minmax(0,7fr) minmax(0,5fr)}.ur{grid-column:1/-1}}' +   # no empty column: Per role spans the row or fills the third
  '.lch{margin:4px 0 0}.lcp{position:relative}.lcp svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible}.lcp ol{list-style:none;margin:0;padding:0;position:absolute;inset:0}' +
  'svg .ar{stroke:none;fill:var(--c);opacity:.16}svg .ln{fill:none;stroke:var(--c);stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round;stroke-linecap:round}.ln.dash{stroke-width:1.4;stroke-dasharray:5 3}.ln.dot{stroke-width:1.6;stroke-dasharray:1 3;opacity:1}.avg{stroke:var(--mt);stroke-width:1;stroke-dasharray:2 4;vector-effect:non-scaling-stroke}' +
  '.t-sage{--c:var(--sage)}.t-slate{--c:var(--slate)}.t-act{--c:var(--act)}.t-watch{--c:var(--watch)}.t-plum{--c:var(--plum)}' +
  '.lcp li{position:absolute;top:0;bottom:0;width:calc(100% / var(--n));transform:translateX(-50%);border-radius:6px}.lcp li:hover{background:color-mix(in srgb,var(--fg) 5%,transparent)}' +
  '.dt{position:absolute;left:50%;width:7px;height:7px;margin:0 0 -3.5px -3.5px;border-radius:50%;background:var(--c);box-sizing:border-box}.dt.dash,.dt.dot{background:var(--sf);border:1.5px solid var(--c)}.lcp li.x .dt{width:11px;height:11px;margin:0 0 -5.5px -5.5px;box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 28%,transparent)}' +
  '.lcl{position:absolute;inset:0;pointer-events:none}.lcl b{position:absolute;transform:translate(-50%,-9px);display:flex;flex-direction:column;align-items:center;font-size:10.5px;font-weight:600;line-height:1.15;white-space:nowrap;font-variant-numeric:tabular-nums;color:var(--fg)}.lcl b.x{color:var(--sage2)}' +
  '.lcx{position:relative;height:16px;margin-top:3px;border-top:1px solid var(--ln);font-size:10.5px;color:var(--mt);font-variant-numeric:tabular-nums}.lcx span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}.lcx span.x{color:var(--fg);font-weight:650}' +
  '.lk{font-style:normal;font-size:11px}.lk::before{content:"";display:inline-block;width:16px;height:0;border-top:2px solid var(--c);margin-right:5px;vertical-align:3px}.lk.dash::before{border-top-style:dashed}.lk.avg::before{border-top:1px dotted var(--mt)}' +
  # interactive graphs: legend buttons hide a line (.h<k>), a picked column or segment, filtered rows (.fo), the hidden task list until a filter
  '.lcl b i{font-style:normal}.lcl b span:not(:first-child){font-size:10px;font-weight:500;color:var(--mt)}.lgb{display:flex;flex-wrap:wrap;gap:2px 6px;margin-top:4px}button.lgt{min-height:26px;min-width:0;padding:1px 6px;border-color:transparent;background:none}button.lgt[aria-pressed=false]{opacity:.45}button.lgt[aria-pressed=false] .lk{text-decoration:line-through}' +
  ((0..4 | ForEach-Object { ".lgw.h$_ .s$_" }) -join ',') + '{display:none}.lcp li{cursor:pointer}.lcp li[aria-pressed=true]{background:color-mix(in srgb,var(--sage) 18%,transparent)}.lcp li:focus-visible{outline:2px solid var(--sage);outline-offset:-2px}' +
  '.fo{display:none!important}.ftl:not([data-fsel]){display:none}.fclr{margin:4px 0;font-size:12px;color:var(--mt)}.fclr b{color:var(--fg)}.fclr button{min-height:26px;padding:1px 8px;margin-left:6px}' +
  '.obr{display:grid;grid-template-columns:minmax(90px,max-content) minmax(0,1fr);gap:8px;align-items:center;margin:4px 0;font-size:12px}.obn{overflow-wrap:anywhere}.obn b{color:var(--mt);font-weight:600;margin-left:4px}' +
  '.obar{display:flex;gap:1px;min-height:20px;border-radius:4px;overflow:hidden;background:var(--sf2)}.obar i{flex-basis:0;min-width:2.4em;display:flex;align-items:center;justify-content:center;font-style:normal;font-size:10.5px;font-weight:600;color:var(--fg);cursor:pointer}.obar i:hover,.obar i:focus-visible,.obar i[aria-pressed=true]{outline:2px solid var(--fg);outline-offset:-2px}' +
  '.ob-sage{background:color-mix(in srgb,var(--sage) 55%,var(--sf))}.ob-slate{background:color-mix(in srgb,var(--slate) 50%,var(--sf))}.ob-watch{background:color-mix(in srgb,var(--watch) 55%,var(--sf))}.ob-plum{background:color-mix(in srgb,var(--plum) 50%,var(--sf))}.ob-act{background:color-mix(in srgb,var(--act) 55%,var(--sf))}.ob-pale{background:color-mix(in srgb,var(--sage) 22%,var(--sf))}.ob-none{background:var(--sf2);box-shadow:inset 0 0 0 1px var(--ln)}.chip[class*=ob-]{color:var(--fg)}' +
  '.otl{list-style:none;margin:4px 0 0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:3px 12px;font-size:12px}.otl li{display:flex;flex-wrap:wrap;gap:2px 8px;align-items:center}.ftl{margin-top:8px}' +
  '.xl{color:color-mix(in srgb,var(--slate) 60%,var(--fg));font-size:12px;text-decoration:none;overflow-wrap:anywhere}a.xl:hover{text-decoration:underline}.lks{display:inline-flex;flex-wrap:wrap;gap:2px 8px}.rpl{font-size:12.5px;margin:6px 0}.dlc h4,.obc h4{margin:0 0 2px}' +
  # Spend: one row per role (grid columns), its step types under it; the model mix a stacked bar per role, its legend the model totals
  '.spt{width:100%;border-collapse:collapse;font-size:12.5px}.spt col.c0{width:22%}.spt col.cm{width:16%}.spt col.cs{width:110px}table.spt th{font-size:11px;font-weight:600;color:var(--mt);text-align:right;padding:3px 8px;border-bottom:1px solid var(--ln)}table.spt td{padding:3px 8px;text-align:right;font-variant-numeric:tabular-nums;border-top:1px solid var(--ln)}.spt tr :is(th,td):is(:first-child,:nth-child(4),:last-child){text-align:left}.spt tr :is(th,td):first-child{overflow-wrap:anywhere}' +
  '.spt .bar{margin:0;width:56px}.sb.mix{margin:0;height:10px}.sb.mix i{background:var(--c);min-width:3px}.ocl i[class^=t-]{background:var(--c)}.spt tr.spr td:first-child{font-weight:600}.spt tr.sty td{border-top:0;color:var(--mt);font-size:12px}.spt tr.sty td:first-child{padding-left:22px}.spt tbody:not(.op) tr.sty{display:none}' +
  '.spx{all:unset;cursor:pointer}.spx::before{content:"\25B8  ";color:var(--mt)}.spx[aria-expanded=true]::before{content:"\25BE  "}.spx:focus-visible{outline:2px solid var(--sage)}@media(max-width:640px){.spt :is(th,td):is(:nth-child(4),:nth-child(6)){display:none}}.rfl .gn0{overflow-wrap:anywhere;min-width:0}' +
  '.mcol{display:grid;gap:var(--cgap,8px);min-width:0}.cg.mach{align-items:stretch}.mach>.st{display:flex;flex-direction:column}.mach>.st>:last-child{margin-top:auto}' +
  # one line per kind on every width from 700 px (kind · hourly heatmap · numbers, aligned: .gk is display:contents); the side panel 300 px, wrapping
  '.gl{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:8px 20px;align-items:start}@media(max-width:900px){.gl{grid-template-columns:minmax(0,1fr)}}.gp{display:grid;gap:4px;margin-top:6px;min-width:0}.gp .s{overflow-wrap:anywhere}' +
  '.gks{display:grid;grid-template-columns:max-content minmax(120px,1fr) repeat(6,max-content);gap:5px 12px;align-items:center;margin-top:6px;font-size:11.5px}.gk{display:contents}.gn{font-weight:600;white-space:nowrap}.gc{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}.gc.z,.iv.z{color:color-mix(in srgb,var(--mt) 70%,var(--bg))}.iv.z .ic{color:inherit}.gk:not(.gh)>.gc .ic{display:none}.gc.nw,.gk:not(.gh)>.gc:nth-child(3):not(.z){color:var(--sage2);font-weight:650}.gk:not(.gh)>.gc:nth-child(4):not(.z){color:color-mix(in srgb,var(--watch) 55%,var(--fg));font-weight:650}.gh>*{color:var(--mt);font-size:10.5px;font-weight:600}.gh>.gc{display:inline-flex;justify-content:flex-end;align-items:center;gap:2px}.ic{width:13px;height:13px;flex:none;vertical-align:-2px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;color:var(--mt)}.ic.i-run{color:var(--sage2)}.ic.i-queue{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.ic.i-stuck{color:color-mix(in srgb,var(--act) 55%,var(--fg))}.iv{display:inline-flex;align-items:center;gap:3px;white-space:nowrap;margin-right:10px}.st .v .ic{width:15px;height:15px}.cnt .iv{margin-right:6px}.tn .iv{float:right;margin:0 0 0 8px;font-size:12px;color:var(--mt)}' +
  # hourly heatmap: 24 cells, shade = busy share of the hour (--a), the current hour outlined; hour labels in the header row
  ':is(.msn,.msm){display:grid!important;grid-template-columns:repeat(var(--mc),minmax(0,1fr));align-items:start}.msn{grid-auto-rows:1px;row-gap:0!important}:is(.msn,.msm)>*{align-self:start!important;margin:0}.msn>.msl{align-self:stretch!important;display:flex;flex-direction:column}.msl>:last-child{margin-top:auto}.msl>:is(.spk,.dbr,.lcf):last-child{flex:1 1 auto;display:flex;flex-direction:column;max-height:170px}.msl>.lcf:last-child>.lcp{flex:1;height:auto!important;min-height:40px}.msl>.spk:last-child>.spw{flex:1;min-height:40px}.msl>.spk:last-child .spark{position:absolute;inset:0;width:100%;height:100%}.msl>.dbr:last-child>.dbw{flex:1;height:auto;min-height:46px}' +
  # a long flag text: its summary opens the full text (click or tap; the filter opens a matching one)
  'details.lx>summary{display:inline;padding:0;min-height:0;cursor:pointer}details.lx>summary::after{content:" · full text";border:0;width:auto;height:auto;transform:none;margin:0;color:var(--sage2);font-size:11px}details.lx[open]>summary::after{content:" · less"}.lf{margin-top:3px;padding:4px 6px;border-radius:6px;background:var(--sf2);overflow-wrap:anywhere}' +
  '.hm{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:2px;height:16px}.hm i{border-radius:2px;font-style:normal;font-weight:600;font-size:10px;line-height:16px;text-align:center;font-variant-numeric:tabular-nums;letter-spacing:-.03em;color:var(--fg);overflow:hidden;white-space:nowrap;background:color-mix(in srgb,var(--slate) var(--a),var(--sf2));cursor:default}.hm i.nw{box-shadow:inset 0 0 0 1.5px var(--sage2)}.hm i:hover{box-shadow:inset 0 0 0 1.5px var(--fg)}' +
  '.hrs{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:2px}.hrs b{font-weight:500;white-space:nowrap}.hrs b.nw{text-align:right;color:var(--sage2)}.hk{font-size:10.5px;color:var(--mt);margin-top:4px}' +
  '@media(max-width:699px){.gks{grid-template-columns:minmax(0,1fr)}.gk{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:2px 6px}.gk>.gn,.gk>.gs,.gk>.gs0{grid-column:1/-1}.gh>.gn,.gh>.gc{display:none}.gk:not(.gh)>.gc .ic{display:inline-block;margin-right:2px}}' +
  '.uc .sy{max-height:clamp(200px,36dvh,360px)}.uc .tw>table:not(.ag){min-width:0}.uc :is(th,td){padding:3px 4px}.uc td{overflow-wrap:normal}.us td:first-child{overflow-wrap:anywhere}:is(.uc,.us) .sy td,.us td{white-space:normal}.sty td:first-child{overflow-wrap:anywhere}' +
  '@media(min-width:641px){.sty :is(th,td):not(:first-child),.us :is(th,td):nth-child(n+2):nth-child(-n+4),.rst :is(th,td):nth-child(n+4):nth-child(-n+6){text-align:right}}' +
  '.tw>table:not(.ag){min-width:520px}@media(max-width:640px){.ag .tm{display:none}.ag .ago{white-space:nowrap}.wrap{padding:8px}header.top{padding:6px 10px;position:static}.hs{display:none}.tb{width:100%}input[type=search]{flex:1;width:auto}' +
  # phone: a table row = a card, two fields a line (label above value), low-value columns ('~') hidden
  '.tw>table:not(.ag){min-width:0}.tw>table:not(.ag) tr:first-child{display:none}.tw>table:not(.ag),.tw>table:not(.ag) :is(tbody,tr,td){display:block;width:auto}.tw>table:not(.ag) tr{border-bottom:1px solid var(--ln);padding:4px 0}' +
  '.tw>table:not(.ag) tr{display:flex;flex-wrap:wrap}.tw>table:not(.ag) td{border:0;padding:1px 8px;display:block;flex:1 1 40%;min-width:0;text-align:left!important}.tw>table:not(.ag) td::before{content:attr(data-k);display:block;color:var(--mt);font-size:10.5px;text-transform:uppercase;letter-spacing:.06em}.tw .lo{display:none!important}.tw>table.tun td:empty{display:none}}'
}
# -Brief stdout (supervise.output): html = link, ACT / WATCH / fix lines, counts; chat = tables; both
function Format-KitSuperviseOut($d, $Shown, [string]$Path) {
  $o = if ($Path) { ([string](Get-KitSetting 'supervise.output' 'html')).Trim().ToLower() } else { 'chat' }; if ($o -notin 'chat', 'both') { $o = 'html' }
  if ($o -ne 'html') { Format-KitReport $Shown }; if ($o -eq 'chat') { return }
  "report: $(([Uri]$Path).AbsoluteUri) (updated $($d.at.ToString('HH:mm'))) · detail: $(([Uri][IO.Path]::ChangeExtension($Path, '.json')).AbsoluteUri)"
  foreach ($f in @($d.flags | Where-Object level -in 'ACT', 'WATCH' | Sort-Object { $_.level -ne 'ACT' })) {
    $c = Get-KitFlagCells $f; "$($f.level) · $(@($c.kind, $c.who, $c.problem | Where-Object { "$_".Trim() } | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() }) -join ' · ')$(if ("$($c.action)".Trim()) { " -> $(("$($c.action)" -replace '\s+', ' ').Trim())" })"
  }
  foreach ($f in @($d.flags | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' })) { "FIXED · $("$($f.what)" -replace '^auto-fixed:\s*')" }
  "$(@($d.rows | Where-Object state -ne 'FINISHED').Count) agent(s) active · $(@($d.flags | Where-Object level -eq 'ACT').Count) ACT · $(@($d.flags | Where-Object level -eq 'WATCH').Count) WATCH"
}

# ---- release: every lease of an agent (release, board leave, workflows after each stage); idempotent
# live gated builds of $Agent ('*' = all): its gate owner name, or a dir inside one of its worktrees (the owner may be a worktree name)
function Get-KitAgentBuilds([string]$Agent, [string[]]$Dirs = @()) {
  $in = { param($p) foreach ($w in $Dirs) { if ($w -and "$p".TrimEnd('\', '/').StartsWith($w.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return $true } }; $false }
  foreach ($bf in @(Get-ChildItem (Get-KitGateLedger)-Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json')) {
    $t = try { Get-Content $bf.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (($Agent -eq '*' -or $t.owner -eq $Agent -or (& $in $t.dir)) -and (Test-KitPid $t.pid $t.start)) { $t | Add-Member -Force NoteProperty file $bf.FullName; $t }   # a reused pid is not ours
  }
}
# killed, marked with $Reason (the gate prints it); release and pause stop them
function Stop-KitAgentBuilds([string]$Agent, [string]$Reason, [string[]]$Dirs = @()) {
  foreach ($t in @(Get-KitAgentBuilds $Agent $Dirs)) { $bp = Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue
    if ($bp) { $bf = $t.file; $t.PSObject.Members.Remove('file'); $t | Add-Member -Force reclaimed $Reason; $t | ConvertTo-Json | Set-Content $bf; Stop-KitProcessTree $bp; "$($t.owner) build: stopped $($t.kind) (pid $($t.pid))" } }
}
function Invoke-KitReleaseAgent([string[]]$Agent, [string]$Reason = 'agent finished') {
  $Agent = @(Split-KitList $Agent); if (-not $Agent.Count) { Stop-KitVerb 'usage: bossy.ps1 release -Agent <id>[,<id>] [-Reason <why>]' }
  Invoke-KitLeaseReason $Reason {
    $sub = { param($script, [string[]]$a) $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $script) + $a) 180; if ($r.code) { $script:KitReleaseFailed = $true; 'FAILED ' }; @("$($r.out) $($r.err)" -split "`r?`n" | Where-Object { $_.Trim() })[-1] }
    $envs = @(if (@(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue | Select-String -SimpleMatch -List @($Agent | ForEach-Object { "`"$_`"" })).Count) { Get-KitLocalEnvStatus })
    $tabs = @(Read-KitJsonFiles (Get-KitPath sessions) 'tabs-*.json' | ForEach-Object { (Get-KitProps $_).Value | Where-Object { $_.agent } })
    foreach ($a in $Agent) {
      $n = 0
      if ($KitCmd.swarm -and (Test-Path $KitCmd.swarm) -and @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object agent -eq $a).Count) { "$a phone: $(& $sub $KitCmd.swarm 'release', '-Agent', $a)"; $n++ }
      if (@(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.slot -and $_.agent -eq $a -and -not $_.parked }).Count) { "$a slot: $(& $sub $KitCmd.dev 'wt', 'release', '-Agent', $a, '-Reason', $Reason)"; $n++ }   # WIP commit or parked: never lost
      foreach ($ev in $envs) {
        if (@($ev.leases | Where-Object agent -eq $a).Count) { "$a env: $(& $sub $KitCmd.local 'release', '-Env', $ev.env, '-Agent', $a)"; $n++ }
        if (@($ev.holds | Where-Object who -eq $a).Count) { "$a env: $(& $sub $KitCmd.local 'unhold', '-Env', $ev.env, '-Agent', $a)"; $n++ }
        if (@($ev.repos | ForEach-Object { @($_.layers) } | Where-Object { $_ -and $_.agent -eq $a }).Count) { "$a env: $(& $sub $KitCmd.local 'drop', '-Env', $ev.env, '-Agent', $a, '-Note', $Reason)"; $n++ }   # paused / handed off: envy keeps them
      }
      $g0 = @((Get-KitGpuState).leases | Where-Object holder -eq $a).Count; if ($g0) { Remove-KitGpu -Holder $a; "$a gpu: $g0 lease(s) released"; $n++ }
      foreach ($x in @(Stop-KitAgentBuilds $a $Reason)) { $x; $n++ }
      if (@($tabs | Where-Object agent -eq $a).Count -and (Test-Path (Join-Path $KitConf.Kit 'skills/pokey/node_modules/puppeteer-core'))) {
        $r = Invoke-KitExe 'node' @('--input-type=module', '-e', "const m = await import('$([Uri]::new((Join-Path $KitConf.Kit 'skills/pokey/browser.mjs')).AbsoluteUri)'); console.log(await m.sweepAll('$($a -replace "'", '')'))") 120
        "$a tabs: $("$($r.out)".Trim()) closed"; $n++
      }
      # a hold only the leases log still has (its store dropped it without a release row): the idle-holder WATCH read it for 24 h
      # kinds whose stores were checked above and hold nothing of $a (a tab with no puppeteer, a parked slot: still held)
      $kinds = @('env', 'env-layer', 'gpu') + @(if (-not @($tabs | Where-Object agent -eq $a).Count) { 'tab' }) + @(if (-not @(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.slot -and $_.agent -eq $a }).Count) { 'slot' }) + @(if (-not @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object agent -eq $a).Count) { 'lane' })
      if (-not $n) { $lo = @(Get-KitResourceRows (Get-Date).AddHours(-24) | Where-Object { ($_.key -split '\|')[0] -in $kinds -and $_.agents -contains $a })
        foreach ($x in $lo) { $xk, $xn = $x.key -split '\|', 2; Write-KitLeaseLog release $xk $xn @{ agent = $a } "$Reason (no store held it: log row closed)" }
        if ($lo.Count) { "${a}: $($lo.Count) stale log hold(s) closed: $(@($lo.resource) -join ', ')" } else { "${a}: no lease held" } }
    }
  }
}

# ---- lines: board show and recover
# board show: QA seats and local-env leases
function Get-KitBoardLinesResources {
  foreach ($o in @(Read-KitJsonFiles (Join-Path (Get-KitPath qa-seats) 'seats'))) { "  seat: $($o.agent) $($o.kind) $($o.need) GB since $($o.since)$(if ((Test-KitHolder $o) -eq $false) { ' (holder gone)' })" }
  foreach ($ev in @(Get-KitLocalEnvStatus)) { foreach ($l in @($ev.leases | Where-Object { $_ })) { "  lease: $($ev.env) $($l.agent) on $(@($l.services) -join ', ') $(if ($l.until) { "until $($l.until)" } else { 'while live' })" } }
}
# envy.ps1 status -Json: the env's own report, never its files
function Get-KitLocalEnvStatus {
  if (-not $KitCmd.local -or -not (Test-Path $KitCmd.local)) { return }
  $r = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') 60
  @(try { "$($r.out)" | ConvertFrom-Json } catch { @() })
}

# recover: env and phone leases with no live holder (README "Leases")
function Get-KitRecoverLinesResources {
  foreach ($ev in @(Get-KitLocalEnvStatus)) {
    foreach ($l in @(@($ev.leases) + @($ev.holds) | Where-Object { $_ -and $null -ne $_.graceLeft })) { $a = if ($l.agent) { $l.agent } else { $l.who }; "== LEASE $($ev.env) $a [$(@($l.services) -join ',')]: no live holder, ends in $($l.graceLeft) min (now: envy.ps1 release|unhold -Env $($ev.env) -Agent $a)" }
  }
  foreach ($o in @(Read-KitJsonFiles (Get-KitPath phones))) {
    $name = [IO.Path]::GetFileNameWithoutExtension($o.file)
    $ls = @{}; if ($o.lane) { $ls[$o.agent] = $o } else { foreach ($p in @((Get-KitProps $o.leases)) + @((Get-KitProps $o.holds)) | Where-Object { $_ }) { $ls[$p.Name] = $p.Value } }
    foreach ($k in @($ls.Keys)) { if ($k -notin '__stopping__', 'manual' -and -not (Test-KitLive $ls[$k])) { "== LEASE $name $k [$(@($ls[$k].services) -join ',')]: no live holder, ends after idle.graceMinutes (now: $(if ($o.lane) { "phoney.ps1 release -Agent $k" } else { "envy.ps1 release|unhold -Env $name -Agent $k" }))" } }
  }
}

# board messages: the file and its reader live in crafty adapters/supervise_report.ps1 (the gate prints them too)
$script:KitMsgKinds = 'note', 'hold', 'dispute', 'rule', 'rollback', 'report', 'pause'   # board msg schema { kind, to, text, ref }
function Send-BoardMsg([string]$From, [string]$To, [string]$Text, [string]$Kind = 'note', [string]$Ref = '') {
  $f = Get-InboxFile $To; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $line = [ordered]@{ at = (Get-Date).ToString('o'); from = $From; to = $To; kind = $Kind; text = $Text; ref = $Ref; read = $false } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
}
# ---- cleanup: idle resources
# holderless test browsers, idle / surplus browser profiles, idle daemons (cleanup.idleDaemons)
function Invoke-KitCleanupResources {
  $profiles = Get-KitPath chrome-profiles
  $chromes = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|headless_shell|google chrome|microsoft edge|firefox|MiniBrowser|WebKitWebProcess)(\.exe)?$' | Where-Object { $_.CommandLine -match '--?headless|-juggler' -and $_.CommandLine -match [regex]::Escape($profiles) }
  $qaRuns = @(Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  $qaActive = @(Read-KitJsonFiles (Get-KitPath board) |
    Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt [double](Get-KitParam 'idle.beatMinutes') -and ($_.run -in $qaRuns -or "$($_.worktrees)" -match 'chrome:') }).Count
  # browsers go after idle.graceMinutes with no live tab holder (browser.mjs registry), never by age
  $ports = try { Get-Content (Get-KitPath browser-ports) -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $ports) { $ports = @{} }; $keyOf = @{}; foreach ($k in @($ports.Keys)) { $keyOf["$($ports[$k])"] = $k }
  foreach ($c in $chromes | Where-Object { $_.ParentId -notin $chromes.Id }) {
    $tabs = $null; if ($c.CommandLine -match '--remote-debugging-port=(\d+)' -and $keyOf[$Matches[1]]) { $tabs = try { Get-Content (Join-Path (Get-KitPath sessions) "tabs-$($keyOf[$Matches[1]] -replace '\|', '__').json") -Raw | ConvertFrom-Json } catch { $null } }
    if (@((Get-KitProps $tabs) | Where-Object { $_.Name -notmatch '^_' -and $_.Value.pid -and (Get-Process -Id ([int]$_.Value.pid) -ErrorAction SilentlyContinue) }).Count) { continue }
    $since = if ($tabs._idle) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$tabs._idle).LocalDateTime } else { [datetime]$c.Created }
    if (($now - $since).TotalMinutes -ge [double](Get-KitParam 'idle.graceMinutes')) { [void]$actions.Add("killed headless browser pid $($c.Id) (no live tab holder for $([int]($now - $since).TotalMinutes) min)"); if (-not $DryRun) { Stop-SysProcess $c.Id } }
  }
  $inUse = @($chromes | ForEach-Object { if ($_.CommandLine -match 'chrome-profiles[\\/](\d+)') { $Matches[1] } } | Sort-Object -Unique)
  foreach ($p in Get-ChildItem $profiles -Directory -ErrorAction SilentlyContinue) { if ($p.Name -notin $inUse -and (Old $p 24)) { Gone $p.FullName 'idle browser profile' } }
  $seatsActive = @(Read-KitJsonFiles (Join-Path (Get-KitPath qa-seats) 'seats') | Where-Object { (Test-KitHolder $_) -ne $false }).Count   # a live holder, not an age
  $maxProfiles = [math]::Max(0, [int]$KitConf.MaxBrowserProfiles)
  if (-not $seatsActive -and -not $qaActive) {
    # Chrome rewrites "Local State" on use
    $left = @(Get-ChildItem $profiles -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path $_.FullName } | ForEach-Object {
        $ls = Get-Item (Join-Path $_.FullName 'Local State') -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ dir = $_; used = $(if ($ls) { $ls.LastWriteTime } else { $_.LastWriteTime }) } } | Sort-Object used -Descending)
    foreach ($x in @($left | Select-Object -Skip $maxProfiles)) { if ($x.dir.Name -notin $inUse) { Gone $x.dir.FullName "browser profile beyond the newest $maxProfiles (cleanup.maxBrowserProfiles)" } }
  }
  # cleanup.idleDaemons [{ process, match, label, busyKinds }]: stopped after 10 min while no gate build of busyKinds runs (unset: none)
  $gl = Get-KitGateLedger
  foreach ($dm in @(Get-KitSetting 'cleanup.idleDaemons' @()) | Where-Object { $_ -and $_.match }) {
    if ($env:KIT_KEEP_DAEMONS) { break }   # tests: their own gate dir cannot see the machine's builds
    $busy = $dm.busyKinds -and @(Get-ChildItem $gl -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' |
      ForEach-Object { try { $e = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($e.kind -match $dm.busyKinds -and (Test-KitPid $e.pid $e.start)) { $e } } catch {} }).Count
    if ($busy) { continue }
    foreach ($d in Get-SysProcs -Name $(if ($dm.process) { "$($dm.process)" } else { '.' }) | Where-Object { $_.CommandLine -match $dm.match }) {
      if (($now - $d.Created).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($dm.label) { $dm.label } else { $dm.match }), $d.Id, ($d.WorkingSet / 1GB))); $script:freed += [long]$d.WorkingSet; if (-not $DryRun) { Stop-SysProcess $d.Id } }
    }
  }
}
# kept lock files (lib.ps1 Open-KitLockFile) whose file went outside the lock (a wait, lease or board file): unheld after a day -> gone
function Invoke-KitCleanupLocks {
  # kit locks sit at most 4 levels down (work/agents/<id>/x/y.json.lock); a full walk listed ~140k files (0.6 s)
  foreach ($lk in @(foreach ($rt in @((Get-KitPath work), (Get-KitPath cache))) { Get-ChildItem -LiteralPath $rt -Recurse -Depth 3 -File -Filter '*.lock' -Force -ErrorAction SilentlyContinue })) {
    $data = $lk.FullName -replace '\.lock$'
    if ($lk.Length -le 64 -and $data -match '\.(json|jsonl|md|txt)$' -and -not (Test-Path -LiteralPath $data) -and (Old $lk 24) -and -not (Test-KitLockHeld $data)) { Gone $lk.FullName 'lock file of a gone file' }
  }
}
# work/agents/<id> over cleanup.agentDirMaxMB (one kitty folder held 1.2 GB inside its 168 h keep): its oldest entries idle 24 h+ go
# until it fits; still over (all of it fresh) = a line in the cleanup report, so growth never stays silent
function Invoke-KitCleanupAgentDirs {
  $capB = [double](Get-KitParam 'cleanup.agentDirMaxMB') * 1MB
  $sizeOf = { param($p) [long](@(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) }
  foreach ($ad in @(Get-ChildItem -LiteralPath (Get-KitPath agents) -Directory -Force -ErrorAction SilentlyContinue)) {
    $parts = @(Get-ChildItem -LiteralPath $ad.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ item = $_; size = $(if ($_.PSIsContainer) { & $sizeOf $_.FullName } else { $_.Length }) } })
    $total = [long](@($parts | Measure-Object size -Sum).Sum); if ($total -le $capB) { continue }
    foreach ($pt in @($parts | Sort-Object { $_.item.LastWriteTime })) { if ($total -le $capB) { break }; if (Old $pt.item 24) { Gone $pt.item.FullName "agent folder over $([int]($capB / 1MB)) MB"; $total -= $pt.size } }
    if (-not $DryRun -and $total -gt $capB) { [void]$actions.Add([pscustomobject]@{ mb = 0; why = "OVER CAP agent folder $([int]($total / 1MB)) MB > $([int]($capB / 1MB)) MB, all of it written in the last 24 h"; path = $ad.FullName }) }
  }
}
# task files named by a CLI flag (.state/tasks/--help.json: a verb's flag taken as the task id; lib.ps1 now refuses such ids)
function Invoke-KitCleanupTaskFiles {
  foreach ($tf in @(Get-ChildItem -LiteralPath (Get-KitPath tasks) -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-KitTaskId $_.BaseName) })) { Gone $tf.FullName 'task file of an invalid task id' }
}
function Get-KitSuperviseFlagsScratch([switch]$AutoFix) {
  foreach ($l in @(Stop-KitScratchOrphans -DryRun:(-not $AutoFix)) + @(Stop-KitSuspendedOrphans -DryRun:(-not $AutoFix))) { [pscustomobject]@{ level = $(if ($AutoFix) { 'INFO' } else { 'WATCH' }); what = $(if ($AutoFix) { "auto-fixed: $l" } else { $l }); action = $(if ($AutoFix) { 'Nothing to do.' } else { 'supervise -AutoFix or bossy.ps1 cleanup stops it.' }) } }
}

# ---- launch: pauses a launch releases; a buildy launch's item tasks (launch -Self, launch -Check)
# resumeFromRunId keeps the folder: its self record re-bound to this session (health, status, recover read its holder)
function Update-KitSelfHolder([string]$Dir, [string]$RunId, [string]$Script) {
  $c = @{}; $leaf = Split-Path "$Script" -Leaf   # no wfDir (budget -Run never ran): its launch -Self line in that run's folder, by args hash (48 h)
  $mine = { param($s) if ($s.wfDir) { return (Split-Path "$($s.wfDir)" -Leaf) -eq $RunId }; if ((Split-Path "$($s.script)" -Leaf) -ne $leaf -or -not $s.fnv -or ((Get-Date) - [datetime]$s.at).TotalHours -gt 48) { return $false }
    if (-not $c.ContainsKey('wd')) { $c.wd = @(Get-KitWorkflowDirs | Where-Object Name -eq $RunId) }; $c.wd.Count -and (Resolve-KitRunId ([pscustomobject]@{ selfFile = $s.file; leaf = $leaf; run = $s.run }) $c.wd -FnvOnly) -eq $RunId }
  foreach ($so in @(Read-KitJsonFiles $Dir 'self-*.json' | Where-Object { -not $_.completed -and (& $mine $_) })) {
    Invoke-KitLocked $so.file { $x = Get-Content -LiteralPath $so.file -Raw | ConvertFrom-Json -AsHashtable; foreach ($kv in (Get-KitHolder).GetEnumerator()) { $x[$kv.Key] = $kv.Value }; $x.Remove('crashed'); $x.rebound = (Get-Date).ToString('o'); Write-KitState $so.file $x }
    "re-bound $(Split-Path $so.file -Leaf) to this session"
  }
}
# run stopped before Learn: signals + report once (launch field learned)
function Invoke-KitStopLearn($S, [string]$By) {
  $recs = @(@($S.file, $S.selfFile) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
  if (-not $recs.Count -or @($recs | Where-Object { (Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json).learned }).Count) { return }
  $id = if ($S.runId) { $S.runId } else { Resolve-KitRunId $S @(Get-KitWorkflowDirs) }
  $wf = @(Get-KitWorkflowDirs | Where-Object { $id -and $_.Name -eq $id })[0]
  $jl = @(if ($wf -and (Test-Path (Join-Path $wf.FullName 'journal.jsonl'))) { Get-Content (Join-Path $wf.FullName 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} } })
  $lab = @{}; foreach ($e in $jl | Where-Object type -eq 'started') { $lab[$e.agentId] = [string]$e.label }
  $res = @($jl | Where-Object type -eq 'result'); $n = 0
  # no Learn phase (tidy): none skipped
  $wfs = if ($S.leaf) { Join-Path $KitConf.Kit "workflows/$($S.leaf)" }
  $noLearn = $wfs -and (Test-Path -LiteralPath $wfs) -and -not (Select-String -LiteralPath $wfs -Pattern "phase\('Learn'\)" -Quiet)
  if (-not @($jl | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count -and -not @($lab.Values | Where-Object { $_ -eq 'learn' }).Count) {
    $skill = if ($S.leaf -like 'buildy*') { 'crafty' } elseif ($S.leaf -like 'testy*') { 'pokey' } else { 'bossy' }
    $cut = { param($t) $t = "$t" -replace '\s+', ' '; $t.Substring(0, [math]::Min(200, $t.Length)) }
    $since = if ($S.at) { [datetime]$S.at } else { (Get-Date).AddDays(-2) }
    $sig = @(foreach ($r in $res) { $l = $lab[$r.agentId]
        if ($r.result.error) { , @('failure', "$l`: $(& $cut $r.result.error)") }
        if ($r.result.handoff) { , @('friction', "$l handed off at its budget: $(& $cut $r.result.handoff)") }
        $b = @($r.result.findings | Where-Object severity -eq 'blocking'); if ($l -like 'review:*' -and $b.Count) { , @('defect-missed', "$l`: $($b.Count) blocking finding(s), first: $(& $cut $b[0].problem)") }
        $nt = @($r.result.checks | Where-Object { $_.result -eq 'NOT_TESTED' }); if ($nt.Count) { , @('friction', "$l`: $($nt.Count) check(s) NOT_TESTED, first $($nt[0].id): $(& $cut $nt[0].observed)") }
        $nr = @($r.result.checks | Where-Object { "$($_.verify)" -match '(?i)not reproduced|inconclusive' }); if ($nr.Count) { , @('false-positive', "$l`: $($nr.Count) check(s) not reproduced or inconclusive in verify, first $($nr[0].id): $(& $cut $nr[0].verify)") } }
      $g = @(Read-KitLog guard $since | Where-Object { $_.event -eq 'deny' -and $_.run -eq $S.run }); if ($g.Count) { , @('rule-violation', "guard blocked $($g.Count) command(s), first: $(& $cut $g[0].why)") }
      foreach ($d in @(Read-KitLog decisions-log $since | Where-Object { $_.kind -eq 'envfix' -and $_.status -eq 'pending' -and $_.run -eq $S.run })) { , @('stale-env', "ENV-FIX $($d.agent): $(& $cut $d.question)") }
      if ($By -ne 'pause' -and -not $noLearn) { , @('friction', "run stopped by $By before its Learn phase: $($lab.Count) step(s), $($res.Count) result(s)") })
    foreach ($x in $sig) { Write-KitLog signals '' ([ordered]@{ skill = $skill; kind = $x[0]; text = $x[1]; ref = $S.run; source = "stop:$By" }); $n++ }
    if ($id) { $null = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.orch, 'report', '-Run', $id, '-Stopped') 30 }   # waves/<id>.json; bounded: pause must stay quick
  }
  Set-KitLaunchField $recs learned "$((Get-Date).ToString('o')) ($By)"
  "learn: run $($S.run) stopped by $By - $(if ($n) { "$n signal(s) recorded" } else { 'nothing to record (finished, its own Learn phase ran or a clean pause)' })"
}
# a (re)launch ends its pause and leaves a '*' pause
function Clear-KitPauseFor([string]$Run) {
  foreach ($p in @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($_.run -eq $Run -or ($_.run -eq '*' -and $Run -notin @($_.released))) })) {
    Invoke-KitLocked $p.file { $j = Get-Content -LiteralPath $p.file -Raw | ConvertFrom-Json
      if ($j.run -eq '*') { $j | Add-Member -Force NoteProperty released @(@($j.released | Where-Object { $_ }) + $Run) } else { $j.state = 'resumed'; $j | Add-Member -Force NoteProperty resumedAt (Get-Date).ToString('o') }
      $j | Add-Member -Force NoteProperty releasedBy @(@($j.releasedBy | Where-Object { $_ }) + "launch $Run $((Get-Date).ToString('o'))")
      Write-KitAtomic $p.file ($j | ConvertTo-Json -Depth 30) }
    "PAUSE $(Split-Path $p.file -Leaf) ($($p.reason)) released for run ${Run}: it was launched again"
  }
}
# every task: a description with an Items list (a [Bug] its own shape), written as its Items checklist (adapters/task_rollup.ps1); a subtask
# the whole template and a parent with the delivery section, rolled up from the brief dir's item table when it has one.
# One "TASKS REFUSED" line per gap; an unread task is skipped; -Check (-File) writes nothing
function Test-KitLaunchTasks($A, [string]$File, [string]$RunName = '') {
  if ($File) { $A = try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json -AsHashtable } catch { 'usage: launch -Check -ArgsFile <buildy args .json>'; exit 2 } }
  $ids = @(@($A.agents) | ForEach-Object { @("$($_.task)") + @(Get-KitItemTasks "$($_.items)") } | ForEach-Object { NormTask $_ } | Where-Object { $_ } | Select-Object -Unique -First 20)
  $bd = if ($A.brief) { Split-Path ([string]$A.brief) }; $gc = { param($n) Get-Command $n -ErrorAction SilentlyContinue }   # adapters/task_rollup.ps1
  $roll = & $gc Invoke-TaskRollup; $itemsFn = & $gc Update-KitTaskItems; $triFn = & $gc Read-KitTriage; $par = @{}; $read = 0
  $out = @(foreach ($id in $ids) {
      $t = try { Get-TrackerTask $id } catch { $null }; if (-not $t.name) { continue }; $read++; $p = "$($t.parent)"
      $il = Get-KitItemsLabel; $gap = @(Get-KitTaskTextGaps $t.name $t.description -Subtask | Where-Object { $p -or $_ -in 'a description', $il })   # the owner's own task: Items only
      if ((Read-KitState (Get-KitTaskFile $id)).itemsSig) { $gap = @($gap | Where-Object { $_ -ne $il }) }   # a kit checklist
      if ($gap.Count) { "TASKS REFUSED ${id}: its description lacks $($gap -join ', ') (templates.md task-description): $(if ($p) { "crafty.ps1 tracker update $id -Spec <json> (crafty.ps1 'task spec')" } else { "crafty.ps1 tracker scope -Task $id -Add '**$($il):** <ids>' (the owner's text stays)" })" }
      elseif ($itemsFn -and -not $File) { try { & $itemsFn $id $t } catch { "ITEMS $id failed: $("$_".Split("`n")[0])" } }
      if (-not $p -or $par.ContainsKey($p)) { continue }
      $pt = try { Get-TrackerTask $p } catch { $null }; $par[$p] = 1; if (-not $pt.name -or "$($pt.description)" -match '<!-- kit:delivery -->') { continue }
      if ($roll -and $triFn -and -not $File -and $bd -and @((& $triFn $bd).rows).Count) { & $roll -Task $p -From $bd -Quiet; Clear-TrackerMemo $p; if ("$((Get-TrackerTask $p).description)" -match '<!-- kit:delivery -->') { continue } }
      "TASKS REFUSED ${id}: parent $p has no delivery section: bossy.ps1 track rollup -Task $p -From <brief dir with an item table (ID, Area columns)>"
    })
  if ($ids.Count -and -not $read) { $out += "TASKS UNKNOWN: none of $($ids.Count) item task(s) read from the tracker: not checked" }
  $claims = Get-KitTaskClaims $(if ($RunName) { $RunName } else { Get-LaunchRunName $A })   # any session's live run: one run per task
  $out = @($ids | Where-Object { $claims[$_] } | ForEach-Object { "TASKS REFUSED ${_}: $($claims[$_]) works on it now: add the work to that run (bossy E8), never launch it twice" }) + $out
  $out; if (-not $File) { return }
  if (@($out -match '^TASKS REFUSED').Count) { exit 1 }; "TASKS ok: $(@($A.agents).Count) area(s)"; exit 0
}
# 2+ areas on one task (agents[].task, else args.task; owner, 2026-11-19: one task flipped 11 times): one subtask per area, made
# once (task state areaTasks), "<kind> <product> — <area id> <area> (<repos>)", the parent's assignee; prints "AREA TASK <area> <id>"
# (buildy.js: each devy's task), writes <brief dir>/area-tasks.json (track rollup: area -> task) and the launch record's areaTasks
# bossy.ps1 launch -Self of a buildy run: the task check (not on a resume), then the area subtasks when nothing was refused
function Invoke-KitLaunchTaskSteps($A, [string]$RunName, [string]$RecFile) {
  $tk = @(if ("$($A.mode)" -ne 'resume') { try { Test-KitLaunchTasks $A -RunName $RunName } catch { "TASKS UNKNOWN: $_" } }); $tk
  if (-not ($tk -match '^TASKS REFUSED')) { try { New-KitAreaTasks $A $RunName $RecFile } catch { "AREA TASKS UNKNOWN: $_" } }
}
function New-KitAreaTasks($A, [string]$RunName, [string]$RecFile) {
  $by = [ordered]@{}; foreach ($g in @($A.agents | Where-Object { $_.id })) { $t = NormTask "$(if ($g.task) { $g.task } else { $A.task })"; if ($t) { if (-not $by.Contains($t)) { $by[$t] = @() }; $by[$t] += , $g } }
  $bd = if ($A.brief) { Split-Path ([string]$A.brief) }; $rows = @(if ($bd -and (Get-Command Read-KitTriage -ErrorAction Ignore)) { (Read-KitTriage $bd).rows })
  $rc = @{}; if ($A.brief -and (Test-Path -LiteralPath $A.brief)) { foreach ($tb in @(ConvertFrom-KitMdTables (Get-Content -LiteralPath $A.brief -Raw))) { if ($tb.head -contains 'agent' -and $tb.head -contains 'repos') { foreach ($r in $tb.rows) { $rc["$($r['agent'])"] = ("$($r['repos'])" -split '[,\s]+' | ForEach-Object { ($_ -split '@')[0] } | Where-Object { $_ }) -join ', ' } } } }
  $map = [ordered]@{}
  foreach ($t in @($by.Keys)) { $gs = @($by[$t]); if ($gs.Count -lt 2) { continue }
    $pt = Get-TrackerTask $t; if (-not $pt.name) { "AREA TASKS UNKNOWN ${t}: not read from the tracker"; continue }
    $known = (Read-KitState (Get-KitTaskFile $t)).areaTasks; $nk = Get-KitNameKind "$($pt.name)"; $nm = $nk.rest; $kind = $nk.kind
    $h1 = if ($A.brief -and (Test-Path -LiteralPath $A.brief)) { "$(@(Get-Content -LiteralPath $A.brief -TotalCount 3 | Where-Object { $_ -match '^#\s' })[0])" -replace '^#\s*(?:[\w -]*brief:\s*)?' -replace [regex]::Escape($t) -replace ',?\s*\d{4}-\d{2}-\d{2}\s*$' }   # "# Wave brief: <name> <id>, <date>"
    $prod = if ($nm -match ' [—-] ') { ($nm -split ' [—-] ', 2)[0].Trim() } elseif ("$h1".Trim()) { "$h1".Trim() } else { ($nm -replace '\s*\([^)]*\)\s*$').Trim() }
    $url = if ($pt.url) { "$($pt.url)" } else { Get-TrackerUrl $t }
    foreach ($g in $gs) {
      $sid = "$(Get-KitMember $known "$($g.id)")"
      if ($sid -and "$(try { (Get-TrackerTask $sid).name } catch { '' })") { $map["$($g.id)"] = $sid; "AREA TASK $($g.id) $sid (kept)"; continue }
      $area = ("$($g.area)" -split '[,;(]')[0].Trim(); if ($area.Length -gt 60) { $area = $area.Substring(0, 60).Trim() }
      $its = @("$($g.items)" -split '[,\s]+' | Where-Object { $_ }); $rp = $rc["$($g.id)"]
      $spec = [ordered]@{ kind = $kind; title = "$prod — $($g.id) $area$(if ($rp) { " ($rp)" })"; parent = $t; code = "$($g.id)"; assignee = "$(@($pt.assignees)[0])"; newTask = "area $($g.id) of run $RunName"
        problem = "Area $($g.id) of $url`: $($g.area)"; goal = "Deliver items $($its -join ', ') (area $($g.id)) of the parent task."
        items = @($its | ForEach-Object { $iid = $_; $ti = "$(@($rows | Where-Object { "$($_.id)" -eq $iid } | ForEach-Object title)[0])"; [ordered]@{ code = $iid; desc = $(if ($ti) { $ti } else { $area }) } })
        acceptance = @("Items $($its -join ', ') meet the parent task's acceptance, tested on the local env."); links = @($url); proseOk = 'rendered from the brief' }
      $sf2 = Join-Path (Get-KitTemp) "area-task-$($g.id)-$PID.json"; [IO.File]::WriteAllText($sf2, ($spec | ConvertTo-Json -Depth 6))
      $o = (pwsh -NoProfile -NonInteractive -File $KitCmd.dev tracker create -Spec $sf2 2>&1 | Out-String); Remove-Item -LiteralPath $sf2 -ErrorAction SilentlyContinue; $j = try { $o.Substring($o.IndexOf('{')) | ConvertFrom-Json } catch { $null }
      if (-not $j.id) { "AREA TASK $($g.id) FAILED: $("$o" -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)"; continue }
      $map["$($g.id)"] = "$($j.id)"; "AREA TASK $($g.id) $($j.id) $($j.url)"
    }
    $mt = @{} + $map; Update-KitTaskIndex $t { param($x) $am = [ordered]@{}; if ($x.areaTasks -is [Collections.IDictionary]) { foreach ($k in $x.areaTasks.Keys) { $am[$k] = $x.areaTasks[$k] } }; foreach ($k in $mt.Keys) { $am[$k] = $mt[$k] }; $x.areaTasks = $am }
  }
  if (-not $map.Count) { return }
  if ($bd -and (Test-Path -LiteralPath $bd)) { Write-KitAtomic (Join-Path $bd 'area-tasks.json') (@{ agents = @($map.Keys | ForEach-Object { [ordered]@{ id = $_; task = $map[$_] } }) } | ConvertTo-Json -Depth 4) }
  if ($RecFile -and (Test-Path -LiteralPath $RecFile)) { $r = Read-KitState $RecFile; $r.areaTasks = $map; Write-KitState $RecFile $r }
}

# ---- pause: pause / pause -Status and the finisher behind them; finished runs closed (bossy.ps1 pause, resume, recover, health)
# one PAUSE text for the board message and every beat: fast (stopped builds are redone) and safe (no cut git / MR call)
function Get-KitPauseSteps([string]$Session) { "now: let a running git, push or MR call finish, never cut one; a build, test, env deploy or browser run stops (the kit stopped gated builds: that step is not done); crafty.ps1 checkpoint -Step <last done step> -Next 'redo: <the step you were in>', crafty.ps1 wt commit (WIP, no push), release your leases, then board leave -Session $Session -Status paused (again while it prints PAUSED); return no result" }
# returns in seconds: record + PAUSE messages + runs marked; waiting for agents, stop-learn and the local-env stop run in the
# background (-Wait <min> given: inline, as before). An agent stops only at a step boundary: a build or test step takes minutes.
function Start-KitPause {
param([string]$Run = '', [switch]$All, [string]$Reason = 'owner pause', [double]$Wait = 10, [switch]$Status, [string]$Finish, [switch]$Everyone)
if ($Status) { Show-KitPause; return }
if ($Finish) { Complete-KitPause $Finish $Wait; return }
if (-not ($Run -or $All)) { 'usage: bossy.ps1 pause -Run <run> | -All [-Reason "<why>"] [-Wait <min>: block until agents leave] [-Everyone] | -Status'; exit 2 }
$board0 = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -ne $false })
$foreign = if ($Everyone) { @{} } else { Get-KitForeignRuns @(@(Get-StoppedRuns -Hours 24 -All) + $board0) }   # another live coordinator's runs: its own pause
if ($Run -and $foreign[$Run]) { "OWNED: run $Run belongs to $($foreign[$Run]): pause it in that session, or add -Everyone"; exit 1 }
$pf = Join-Path (Get-KitPath pauses -Create) "pause-$(Get-Date -Format yyyy-MM-dd-HHmmss).json"
$rec = [ordered]@{ at = (Get-Date).ToString('o'); reason = $Reason; run = $(if ($All) { '*' } else { $Run }); state = 'pausing'; wait = $Wait; finisher = $(if ($PSBoundParameters.ContainsKey('Wait')) { $PID }); agents = @(); runs = @(); released = @($foreign.Keys) } + (Get-KitMe)
Write-KitState $pf $rec   # from now every board beat prints PAUSE
$mine = { param($x) ($All -or $x.run -eq $Run) -and -not $foreign["$($x.run)"] }
$live = @($board0 | Where-Object { (& $mine $_) -and ($Everyone -or $_.run -or -not (Get-KitRunOwner $_)) })   # a run's agents follow its owner
foreach ($b in $live) { Send-BoardMsg 'coordinator' $b.agent "PAUSE ($Reason): $(Get-KitPauseSteps $b.session)" 'pause' }
# a build or test blocks its agent for minutes: stopped now (queued ones leave the gate), the agent redoes that step after resume
$stoppedBuilds = @(if ($All -and -not $foreign.Count) { Stop-KitAgentBuilds '*' "PAUSE ($Reason): redo this step after resume" } else { foreach ($b in $live) { Stop-KitAgentBuilds $b.agent "PAUSE ($Reason): redo this step after resume" @($b.worktrees) } })
$closed = @(Close-KitFinishedRuns 24)   # after PAUSE went out: agents stop at once
# live runs, or stopped within 24 h: an older crashed run is not running, resume -All lists it
$runs = @(Get-StoppedRuns -Hours 24 -All | Where-Object { & $mine $_ })
foreach ($s in $runs) {
  Set-KitLaunchField @($s.file, $s.selfFile) paused $pf
  $rec.runs += [ordered]@{ run = $s.run; leaf = $s.leaf; runId = $s.runId; file = $s.file; selfFile = $s.selfFile; at = $s.at.ToString('o')
    launch = $(if ($s.file) { Get-Content -LiteralPath $s.file -Raw | ConvertFrom-Json }); self = $(if ($s.selfFile) { Get-Content -LiteralPath $s.selfFile -Raw | ConvertFrom-Json }) }   # cleanup may remove launches/
}
$rec.agents = @(foreach ($b in $live) { [ordered]@{ agent = $b.agent; run = $b.run; session = $b.session; board = $b.file; confirmed = $false } })
Invoke-KitLocked $pf { $cur = Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json; if ($cur.state -ne 'resumed') { Write-KitState $pf $rec } }   # a relaunch meanwhile released it
$closed
"PAUSE sent to $($live.Count) agent(s)$(if ($live.Count) { " ($(@($live.agent) -join ', '))" }); $($runs.Count) run(s) marked paused$(if ($runs.Count) { ": $(@($runs.run) -join ', ')" }); $($stoppedBuilds.Count) build(s) / test(s) stopped$(if ($stoppedBuilds.Count) { " ($($stoppedBuilds -join '; '))" })"
if ($PSBoundParameters.ContainsKey('Wait')) { "waiting up to $Wait min for each to leave at a checkpoint"; Complete-KitPause $pf $Wait; return }
$null = Invoke-KitBackground "pause-finish $(Split-Path $pf -LeafBase)" $KitCmd.orch @('pause', '-Finish', $pf, '-Wait', "$Wait")
"PAUSING: agents stop at their next step boundary (up to $Wait min; builds and tests were stopped, a git or MR call finishes first); local env stops after that"
"check: bossy.ps1 pause -Status (says when it is safe to power off); record: $pf"
}
# finished = an end marker, or its last step (the workflow's last phase) answered and none running; the engine writes no marker
function Test-KitJournalFinished([string]$Dir, [string]$Leaf, [double]$QuietMin = 2) {   # a live holder: callers pass 10
  $j = Join-Path $Dir 'journal.jsonl'; if (-not $Dir -or -not (Test-Path -LiteralPath $j) -or ((Get-Date) - (Get-Item -LiteralPath $j).LastWriteTime).TotalMinutes -lt $QuietMin) { return $false }
  $ev = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} })
  if (@($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count) { return $true }
  $st = @($ev | Where-Object type -eq 'started'); $res = @($ev | Where-Object type -eq 'result' | ForEach-Object agentId)
  $wf = Join-Path $KitConf.Kit "workflows/$Leaf"; if (-not $st.Count -or -not $Leaf -or -not (Test-Path -LiteralPath $wf) -or $st[-1].agentId -notin $res -or @(Get-JournalRunning $st $res).Count) { return $false }
  "$($st[-1].phase)" -eq @([regex]::Matches((Get-Content -LiteralPath $wf -Raw), "phase\('(\w+)'\)") | ForEach-Object { $_.Groups[1].Value })[-1]
}
# open launch records whose journal finished -> completed (nobody ran launch -Done); stale records made pause and resume scan them
function Close-KitFinishedRuns([int]$Hours = 168) {
  $wfs = @(Get-KitWorkflowDirs); $now = (Get-Date).ToString('o')
  foreach ($s in @(Get-StoppedRuns -Hours $Hours -Raw)) {
    $sj = if (-not $s.runId -and $s.selfFile) { Get-Content -LiteralPath $s.selfFile -Raw | ConvertFrom-Json }   # its own folder only, its args hash in it: no scan of every transcript
    $rx = [regex]::Escape("launch -Self -Script $($s.leaf) -Run '$($s.run)' ") + ".*-Fnv $($sj.fnv)"
    $wf = if ($s.runId) { @($wfs | Where-Object Name -eq $s.runId)[0] } elseif ($sj.wfDir -and $sj.fnv) { @($wfs | Where-Object { $_.FullName -eq "$($sj.wfDir)".TrimEnd('\', '/') -and @(Get-ChildItem $_.FullName -Filter 'agent-*.jsonl' | Where-Object { Select-String -LiteralPath $_.FullName -Pattern $rx -Quiet } | Select-Object -First 1).Count })[0] }
    $id = $wf.Name
    $hl = @(@($s.record) + @($sj) | Where-Object { $_ -and (Test-KitHolder $_) -eq $true }).Count
    if (-not $wf -or -not (Test-KitJournalFinished $wf.FullName $s.leaf $(if ($hl) { 10 } else { 2 }))) { continue }
    $fs = @(@($s.file, $s.selfFile) | Where-Object { $_ }); Set-KitLaunchField $fs completed $now
    foreach ($f in $fs) { if (-not (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).learned) { Set-KitLaunchField @($f) learned "$now (finished: journal)" } }   # its own Learn phase ran
    "closed finished run $($s.run) ($id): its journal ended at the last phase"
  }
}
function Get-KitPauseJob([string]$Pf) { $b = Join-Path (Get-KitPath background -Create) (ConvertTo-KitSlug "pause-finish $(Split-Path $Pf -LeafBase)"); [pscustomobject]@{ log = "$b.out"; live = [bool]$(try { $j = Get-Content -LiteralPath "$b.json" -Raw | ConvertFrom-Json; Test-KitPid $j.pid $j.start } catch { $false }) } }
function Get-KitPauseOpen($Rec) { @($Rec.agents | Where-Object { $e = try { Get-Content -LiteralPath $_.board -Raw | ConvertFrom-Json } catch { $null }; $e -and $e.status -ne 'left' -and (Test-KitHolder $e) -ne $false }) }
# not confirmed, yet safe to power off (fails closed): a checkpoint since the pause, a worktree, all clean (no uncommitted file, no git
# operation half done), no gated build, no local-env lease
function Test-KitPauseSafe($A, $At) {
  $ck = Get-KitCheckpoint $A.agent "$($A.run)"; if (-not $ck -or $ck.done -or -not $ck.updated -or ($At -and [datetimeoffset]"$($ck.updated)" -lt [datetimeoffset]"$At")) { return $false }
  $b = try { Get-Content -LiteralPath $A.board -Raw | ConvertFrom-Json } catch { $null }
  $wts = @(@($ck.worktrees) + @($b.worktrees) | Where-Object { "$_" -match '[\\/]' -and (Test-Path -LiteralPath "$_" -PathType Container) } | Select-Object -Unique)
  if (-not $wts.Count -or @(Get-KitAgentBuilds $A.agent $wts).Count) { return $false }
  if (@(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue | Select-String -SimpleMatch -List "`"$($A.agent)`"").Count) { return $false }   # its name in an env lease file
  foreach ($d in $wts) {
    $gd = "$(git -C $d rev-parse --absolute-git-dir 2>$null)".Trim()
    if (@(Get-KitWtState $d).dirty.Count -or ($gd -and @('index.lock', 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD' | Where-Object { Test-Path -LiteralPath (Join-Path $gd $_) }).Count)) { return $false }
  }
  $true
}
# wait for the agents, learn from the stopped runs, stop the local env, state paused; a resume meanwhile wins
function Complete-KitPause([string]$Pf, [double]$Wait) {
  $rec = Get-Content -LiteralPath $Pf -Raw | ConvertFrom-Json
  $until = (Get-Date).AddMinutes($Wait)
  $resumed = { (Get-Content -LiteralPath $Pf -Raw | ConvertFrom-Json).state -eq 'resumed' }
  # poll-ok: local pause file, bounded by -Wait minutes
  while ($true) { $open = @(Get-KitPauseOpen $rec); if (-not @($open | Where-Object { -not (Test-KitPauseSafe $_ $rec.at) }).Count -or (Get-Date) -ge $until -or (& $resumed)) { break }; Wait-KitPoll 15 }   # safe unconfirmed agents: no wait
  if (& $resumed) { "pause $Pf was resumed meanwhile: nothing stopped"; return }
  foreach ($s in @($rec.runs)) { Invoke-KitStopLearn ([pscustomobject]@{ run = $s.run; leaf = $s.leaf; runId = $s.runId; file = $s.file; selfFile = $s.selfFile; at = $s.at }) 'pause' }
  foreach ($a in @($rec.agents)) {
    $b = try { Get-Content -LiteralPath $a.board -Raw | ConvertFrom-Json } catch { $null }; $ck = Get-KitCheckpoint $a.agent "$($a.run)"
    $dirs = @(@($ck.worktrees) + @($b.worktrees | Where-Object { "$_" -match '[\\/]' -and (Test-Path -LiteralPath "$_" -PathType Container) }) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($kv in @{ confirmed = $a.session -notin @($open.session); next = $ck.next; checkpoint = $ck; worktrees = @($dirs | ForEach-Object { Get-KitWtState $_ }) }.GetEnumerator()) { $a | Add-Member -Force NoteProperty $kv.Key $kv.Value }
  }
  if (& $resumed) { "pause $Pf was resumed meanwhile: nothing stopped"; return }
  $hooks = @(Invoke-KitHooks Invoke-KitPause)   # localenv_supervise.ps1: stops unheld services
  if (& $resumed) { "resumed while the local env stopped: start what the run needs again (envy.ps1 up)" }
  # only this finisher's fields onto the current record: a resume's state / released written meanwhile stay
  Invoke-KitLocked $Pf { $now = Get-Content -LiteralPath $Pf -Raw | ConvertFrom-Json; if ($now.state -ne 'resumed') { $now.state = 'paused'; foreach ($kv in @{ finishedAt = (Get-Date).ToString('o'); notes = @($hooks | ForEach-Object { "$_" }); agents = @($rec.agents) }.GetEnumerator()) { $now | Add-Member -Force NoteProperty $kv.Key $kv.Value }; Write-KitState $Pf $now } }
  "PAUSED $(@($rec.agents).Count - $open.Count) of $(@($rec.agents).Count) agent(s) at a checkpoint$(if ($open.Count) { "; not confirmed: $(@($open.agent) -join ', ') (their last checkpoint and worktree hold the state; resume treats them as crashed)" }); $(@($rec.runs).Count) run(s) marked paused$(if (@($rec.runs).Count) { ": $(@($rec.runs.run) -join ', ')" })"
  $hooks
  "record: $Pf"
  $unsafe = @($open | Where-Object { -not (Test-KitPauseSafe $_ $rec.at) })
  if ($unsafe.Count) { "NOT safe yet: $(@($unsafe.agent) -join ', ') still working; wait (bossy.ps1 pause -Status) or power off anyway = a crash for them (resume starts them at their last checkpoint)" }
  else { "Safe to power off: nothing after this needs the network.$(if ($open.Count) { " $(@($open.agent) -join ', '): not confirmed, at a checkpoint with a clean worktree and no build (resume starts there)" })" }
  'Machine stays on: stop the workflow runs and the heartbeat (agents wait in board leave). Back: bossy.ps1 resume -All (or -Run <run>)'
}
# the newest open pause: who still works, safe to power off; a finisher that died is finished here (no wait)
function Show-KitPause {
  $p = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' } | Sort-Object { [datetimeoffset]$_.at })[-1]
  if (-not $p) { 'no pause in effect'; return }
  $job = Get-KitPauseJob $p.file
  if ($p.finisher -and (Get-Process -Id $p.finisher -ErrorAction SilentlyContinue)) { $job.live = $true }   # a -Wait pause finishes inline
  if ($p.state -eq 'pausing' -and -not $job.live) { Complete-KitPause $p.file 0; if (@(Get-KitPauseOpen $p | Where-Object { -not (Test-KitPauseSafe $_ $p.at) }).Count) { exit 1 }; return }
  $open = @(Get-KitPauseOpen $p); $unsafe = @($open | Where-Object { -not (Test-KitPauseSafe $_ $p.at) })
  "pause $($p.file): $($p.state) since $(([datetimeoffset]$p.at).ToString('HH:mm')) ($($p.reason)); $(@($p.agents).Count - $open.Count) of $(@($p.agents).Count) agent(s) stopped; $(@($p.runs).Count) run(s) paused$(if ($job.live) { "; finishing in the background (log $($job.log))" })"
  @($p.notes) | Where-Object { $_ }
  if ($unsafe.Count -or $p.state -ne 'paused') { "NOT safe yet: $(if ($unsafe.Count) { "$(@($unsafe.agent) -join ', ') still working" } else { 'local env still stopping' }); check again in a minute"; exit 1 }
  "Safe to power off: nothing after this needs the network.$(if ($open.Count) { " $(@($open.agent) -join ', '): not confirmed, at a checkpoint with a clean worktree and no build (resume starts there)" })"
}

# ---- heartbeat: the E1 cron call, an overdue coordinator (health), collision words in agent results (supervise)
function Get-KitBeatArmLine { "CronList has no heartbeat -> CronCreate cron '*/$([int](Get-KitParam 'supervise.heartbeatMinutes')) * * * *', recurring: true, durable: true, prompt ""$(Get-KitBeatPrompt)""" }
# health: the coordinator's beat passed while agents live (coordAt: not the OS timer's)
function Get-KitBeatOverdue([datetime]$Now = (Get-Date)) {
  $s = try { Read-KitText (Get-KitPath supervise-state) | ConvertFrom-Json } catch { $null }
  if (-not $s.report.at) { return }
  $last = [datetime]$(if ($s.coordAt) { $s.coordAt } else { $s.report.at }); $due = $last.AddMinutes([double](Get-KitParam 'supervise.heartbeatMinutes')); $late = [int]($Now - $due).TotalMinutes
  $bm = [double](Get-KitParam 'idle.beatMinutes')
  $live = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -notin 'left', 'crashed' -and $_.beat -and ($Now - [datetime]$_.beat).TotalHours -lt [double](Get-KitParam 'board.rowHours') -and ($a = Get-KitLastActivity "$($_.transcript)" $_ "$($_.tool)") -and ($Now - $a).TotalMinutes -lt $bm })   # board Active or writing its transcript
  if ($late -gt 0 -and $live.Count) { "heartbeat OVERDUE $late min: last beat $($last.ToString('HH:mm')), next was due $($due.ToString('HH:mm')), $($live.Count) agent(s) live: run supervise now; $(Get-KitBeatArmLine)" }
}
# 'another agent' alone appears in normal fix reports (false ACT)
function Test-KitCollision([string]$Text) {
  $Text -match '(?i)duplicate (agent|copy|writer|instance|session)|\b(agents?|cop(y|ies)|writers?|sessions?) collid|collid\w* with (an)?other (agent|writer|session)|two (agents|writers|sessions) (on|in|editing|writing) the same|another (agent|writer|session) (is|was) (also )?(editing|writing|running) (in |on )?(the same|this|my)|(halted|stopped editing)\b.{0,60}\b(another|other|duplicate|second) (agent|writer|session)'
}
# ---- sessions: several coordinators on one machine (Claude Code, Codex, Antigravity): run owners, routed flags, task claims, step age
# owner = the session process (holder) that wrote a launch record, board row or pause; this process's own, gone or unknown = mine
$script:KitMe = $null
# KIT_HOLDER_PID: tests, a detached shell; no session process above: cannot tell = mine
function Get-KitMe { if (-not $script:KitMe) { $script:KitMe = if ($env:KIT_HOLDER_PID) { [ordered]@{ holderPid = [int]$env:KIT_HOLDER_PID; holderStart = Get-KitPidStart $env:KIT_HOLDER_PID } } else { Get-KitHolder } }; $script:KitMe }
function Test-KitMine($R) { $m = Get-KitMe; -not $m.holderPid -or "$($R.holderPid)" -eq "$($m.holderPid)" }
function Get-KitRunOwner($S) {
  $recs = @(@($S.record) + @(if ($S.selfFile -and (Test-Path -LiteralPath $S.selfFile)) { try { Get-Content -LiteralPath $S.selfFile -Raw | ConvertFrom-Json } catch {} }) + @($S) | Where-Object { $_ -and $_.holderPid })
  if (@($recs | Where-Object { Test-KitMine $_ }).Count) { return }
  $o = @($recs | Where-Object { (Test-KitHolder $_) -eq $true })[0]; if ($o) { "the live session process $($o.holderPid)$(if ($o.tool) { " ($($o.tool))" })" }
}
# per run: its launch records decide (an agent may run under another process); board rows only for a run without one; all foreign
function Get-KitForeignRuns($Items) {
  $f = @{}; foreach ($g in @($Items | Where-Object { $_ -and $_.run } | Group-Object { "$($_.run)" })) {
    $use = @($g.Group | Where-Object leaf); if (-not $use.Count) { $use = @($g.Group) }
    $ow = @($use | ForEach-Object { Get-KitRunOwner $_ }); if ($ow.Count -and -not @($ow | Where-Object { -not $_ }).Count) { $f[$g.Name] = $ow[0] }
  }; $f
}
# resume / recover: a live coordinator's run is relaunched only by it (-Everyone: anyway)
function Get-KitOwnedLine($S, [bool]$Everyone) { if (-not $Everyone -and ($o = Get-KitRunOwner $S)) { "== OWNED: $($S.leaf) run $($S.run) belongs to $o (another coordinator): resume or recover it there, or add -Everyone" } }
# every heartbeat beats this session's `board join -Type coordinator` row (registry: board show lists each coordinator)
function Update-KitCoordinatorBeat { foreach ($e in @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.type -eq 'coordinator' -and $_.status -ne 'left' -and $_.holderPid -and "$($_.holderPid)" -eq "$((Get-KitMe).holderPid)" })) { try { Update-BoardEntry $e.file { param($x) $x.beat = (Get-Date).ToString('o'); $x } } catch {} } }
# one session supervises (lock); a session that steps aside prints that sweep's flags of its own runs (workflow folders, launch holders)
function Get-KitAsideFlags([string]$Me) {
  $st = try { Get-Content (Get-KitPath supervise-state) -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $st.lastFlags) { return }
  $rx = @(@(if ($Me) { Get-KitWorkflowDirs $Me | ForEach-Object { [regex]::Escape($_.Name) } }) + @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { -not $_.completed -and $_.holderPid -and (Test-KitMine $_) } | ForEach-Object { "\brun '?$([regex]::Escape($_.run))" }) |
    Select-Object -Unique | ForEach-Object { "(?<![\w-])$_(?![\w-])" })   # a workflow folder id anywhere; a run name only as 'run <name>' (short names hit other words)
  $fl = @($st.lastFlags | Where-Object { $t = "$($_.what) $($_.who)"; $_.level -and @($rx | Where-Object { $t -match $_ }).Count } | ForEach-Object { [pscustomobject]$_ })
  $fl = @(Select-KitFlags $fl $(if ($st.acks) { $st.acks } else { @{} }) (Get-Date) | Where-Object level -ne 'INFO'); if (-not $fl.Count) { return }
  "your runs' flags from that sweep ($(([datetime]$st.report.at).ToString('HH:mm'))):"; $fl | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" }
}
# launch -Self / -Check: a task an active builder (devy, or an untyped crafty row) of another run (any session) works on; its
# items only (a parent task in .task spans runs); reviewers and testers never claim
function Get-KitTaskClaims([string]$Run) {
  $bm = [double](Get-KitParam 'idle.beatMinutes'); $c = @{}
  $act = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and "$($_.type)" -in 'devy', '' -and $_.run -and $_.run -ne $Run -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $bm -and (Test-KitHolder $_) -ne $false })
  $selfs = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { -not $_.completed -and $_.run -in @($act.run) })
  foreach ($b in $act) {
    $txt = @("$($b.items)") + @($selfs | Where-Object run -eq $b.run | ForEach-Object { @($_.args.agents) | Where-Object { "$($_.id)" -eq $b.agent } | ForEach-Object { "$($_.items)" } })
    foreach ($t in @(Get-KitItemTasks ($txt -join ' '))) { if (-not $c[$t]) { $c[$t] = "run $($b.run) (agent $($b.agent), beat $(([datetime]$b.beat).ToString('HH:mm')))" } }
  }
  $c
}
# board beat: the HANDOFF line (spend at the handoff point, or one step longer than budget.stepHours)
function Get-KitHandoffLine($Me, [string]$Session, [string]$Why) { $hb = Join-Path (Get-KitPath briefs -Create) "$(ConvertTo-KitSlug "handoff-$($Me.agent)-$Session").md"; "HANDOFF: $Why`: write a resume brief: crafty.ps1 checkpoint -Agent $($Me.agent)$(if ("$($Me.run)") { " -Run $($Me.run)" }) -Step <last done> -Notes '<one line>' -Brief $hb, commit WIP, board leave -Session $Session -Handoff $hb, return handoff = $hb and stop: a fresh agent continues" }
function Get-KitStepAgeHandoff($Me, [string]$Session) {
  $h = [double](Get-KitSetting 'budget.stepHours' 2); if ($h -le 0 -or -not $Me.joined -or $Me.type -eq 'coordinator') { return }   # a coordinator has no steps
  $ck = Get-KitCheckpoint $Me.agent "$($Me.run)"; if (-not $ck.updated -or $ck.done) { return }   # agents that checkpoint their steps only
  $from = [datetimeoffset]$Me.joined; if ([datetimeoffset]$ck.updated -gt $from) { $from = [datetimeoffset]$ck.updated }   # the step since the last checkpoint (a resumed agent rejoins: joined)
  $age = ([datetimeoffset](Get-Date) - $from).TotalHours; if ($age -ge $h) { Get-KitHandoffLine $Me $Session ('one step running {0:0.0} h >= budget.stepHours {1}' -f $age, $h) }
}

# ---- ci tasks: test-only tasks a CI job raised, closed by bossy.ps1 track run once that job passes again
# a test-only task raised by a CI job (tracker.ciTaskPattern on its name): its description names the job URL, its pipeline and the
# Branch it failed on; that job passing again on that branch with the task's MRs in = its test (no testing docs, no person)
function Get-KitCiTask([string]$Task) {
  $rx = [string](Get-KitSetting 'tracker.ciTaskPattern' '')   # none = off (no task is CI-raised)
  if (-not $rx) { return $null }
  $tt = try { Get-TrackerTask $Task } catch { $null }
  if ("$($tt.name)" -notmatch $rx) { return $null }
  $d = "$($tt.description)" -replace '\\(?=[_*])', ''
  $ju = Invoke-HostVerb 'ci.parseUrl' @{ text = $d }   # the CI adapter reads its own job / run URLs; a CI without it: no job (bad)
  $bm = [regex]::Match($d, '(?im)^\W*Branch\W*:\W*(?<b>[\w./-]+)')
  $jn = if (-not "$($ju.job)") { @([regex]::Matches($d, '(?i)\bjob\s+[`''"](?<j>[\w.:-]{3,})[`''"]') | ForEach-Object { $_.Groups['j'].Value })[-1] }   # a pipeline link + a job name ("job `unit-test`"), no job URL
  [pscustomobject]@{ url = "$($ju.url)"; job = "$($ju.job)"; jobName = "$jn"; run = "$($ju.run)"; branch = $bm.Groups['b'].Value }
}
# pass = a newer run of the same job on the branch whose commit holds every merged MR of the job's repo; wait = none yet / still running
function Test-KitCiTaskJob($Ci, [string[]]$Mrs) {
  if (-not (($Ci.job -or $Ci.jobName) -and $Ci.run -and $Ci.branch)) { return @{ state = 'bad'; why = 'its description names no Job (URL or name), Pipeline or Branch' } }
  $refs = @($Mrs | Where-Object { "$_" -match '^[^!]+!\d+$' } | ForEach-Object { $r, $n = "$_" -split '!'; [pscustomobject]@{ repo = (ProjPath $r); n = $n } } | Where-Object repo)
  $repo = @($refs | Where-Object { $Ci.url -like "*/$($_.repo)/*" } | ForEach-Object repo)[0]; if (-not $repo) { $repo = @($refs.repo)[0] }
  if (-not $repo) { return @{ state = 'bad'; why = 'no MR ref to find its repo' } }
  $name = if ($Ci.jobName) { "$($Ci.jobName)" } else { "$(@(Invoke-HostVerb 'ci.jobs' @{ repo = $repo; id = $Ci.run }) | Where-Object { "$($_.id)" -eq $Ci.job } | ForEach-Object name | Select-Object -First 1)" }
  if (-not $name) { return @{ state = 'bad'; why = "job $($Ci.job) not found in run $($Ci.run) of $repo" } }
  $shas = @(foreach ($x in @($refs | Where-Object repo -eq $repo)) { $m = Invoke-HostVerb 'mr.get' @{ repo = $repo; n = $x.n }; @($m.merge_commit_sha, $m.squash_commit_sha, $m.sha | Where-Object { $_ })[0] })
  if (@($shas | Where-Object { -not $_ }).Count -or $shas.Count -ne @($refs | Where-Object repo -eq $repo).Count) { return @{ state = 'bad'; why = "an MR of $repo unreadable (no merge commit)" } }
  foreach ($run in @(Invoke-HostVerb 'ci.runs' @{ repo = $repo; ref = $Ci.branch } | Where-Object { [long]$_.id -gt [long]$Ci.run } | Sort-Object { [long]$_.id } -Descending)) {
    if (@($shas | Where-Object { "$((Invoke-HostVerb 'repo.base' @{ repo = $repo; a = $_; b = $run.sha }).id)" -ne $_ }).Count) { continue }   # the fix not in this commit yet
    $jb = @(Invoke-HostVerb 'ci.jobs' @{ repo = $repo; id = $run.id }) | Where-Object name -eq $name | Select-Object -First 1; if (-not $jb -or (__CiWord "$($jb.status)") -in 'skipped', 'manual') { continue }   # not run there: an older run decides
    $url = if ($jb.web_url) { "$($jb.web_url)" } elseif ($jb.url) { "$($jb.url)" } else { "$($Ci.url)" }
    switch (__CiWord "$($jb.status)") { 'success' { return @{ state = 'pass'; name = $name; url = $url } } { $_ -in 'failed', 'canceled' } { return @{ state = 'fail'; why = "CI job $name $($jb.status) again on $($Ci.branch) with the fix in: $url" } } default { return @{ state = 'wait'; why = "CI job $name $($jb.status) on $($Ci.branch): $url" } } }
  }
  @{ state = 'wait'; why = "no run of CI job $name on $($Ci.branch) with $(@($Mrs) -join ', ') in yet" }
}
# its job passed: closed + ONE QA comment (qa-result, edited in place) linking the passing job; state closed | wait | the reason
function Close-KitCiTask([string]$Task, $Ci, [string[]]$Mrs) {
  $cj = Test-KitCiTaskJob $Ci $Mrs; if ($cj.state -ne 'pass') { return @{ state = $cj.state; why = "CI task not closed: $($cj.why)" } }
  try { if ("$(Set-TrackerStatus $Task 'closed')" -like 'SKIPPED*') { return @{ state = 'wait'; why = 'CI task not closed: it follows its open subtasks' } } } catch { return @{ state = 'error'; why = "could not set status 'closed' (retried next run): $_" } }
  try { $null = Set-TrackerKitComment $Task 'qa-result' "QA: PASS · CI job $($cj.name) passed on $($Ci.branch) with $(@($Mrs | ForEach-Object { Format-KitMrLink $_ }) -join ', ') merged: $($cj.url)" } catch { Write-Warning "QA comment of $Task not written: $_" }
  @{ state = 'closed'; why = "all $(@($Mrs).Count) MRs merged, CI job $($cj.name) passed on $($Ci.branch) -> closed" }
}
# track (bossy.ps1): launched areas (track.planHours) no wave report lists done: a later batch or budget cut
function Get-KitPlannedAreas([string]$TaskId, $Since) {
  $TaskId = NormTask $TaskId
  if ($null -eq $script:planRecs) {
    $script:planRecs = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { $_.at -and ((Get-Date) - [datetime]$_.at).TotalHours -lt [double](Get-KitParam 'track.planHours') })
    $script:planDone = @{}; $planFrom = @($script:planRecs | ForEach-Object { [datetime]$_.at } | Sort-Object)[0]   # waves written since the oldest launch
    foreach ($wf in @(if ($planFrom) { Get-ChildItem (Get-KitPath waves) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $planFrom } })) {
      $wr = try { Get-Content -LiteralPath $wf.FullName -Raw | ConvertFrom-Json } catch { $null }
      foreach ($wa in @(if ($wr.agents) { (Get-KitProps $wr.agents) })) { if (@($wa.Value.done | Where-Object { $_ }).Count) { foreach ($wm in @($wa.Value.mrs)) { $script:planDone["$($wa.Name)|$(NormRef "$($wm.url)")"] = 1 } }; foreach ($dk in @((@($wa.Value.done) -join ' ') -split '[,\s]+' | Where-Object { $_ })) { $script:planDone["$($wa.Name)|$(NormTask $dk)"] = 1 } }
    }
  }
  @(foreach ($pr in $script:planRecs) {
      if ($Since -and [datetime]$pr.at -le [datetime]$Since) { continue }
      foreach ($pa in @($pr.args.agents | Where-Object { $_.id -and $_.items })) {
        $paT = NormTask "$(Get-KitMember $pr.areaTasks "$($pa.id)")"   # an area subtask (New-KitAreaTasks): its area counts as planned
        if ($paT -and $paT -eq $TaskId) { if (-not @((Read-KitTracking).tasks[$TaskId].mrs | Where-Object { $script:planDone["$($pa.id)|$(NormRef $_)"] }).Count) { "$($pa.id)" }; continue }   # delivered: a wave lists this area done with one of its MRs (area ids repeat across runs)
        if (@("$($pa.items)" -split '[,\s]+' | ForEach-Object { NormTask $_ }) -contains $TaskId -and -not $script:planDone["$($pa.id)|$TaskId"]) { "$($pa.id)" }
      } }) | Select-Object -Unique
}
# ---- the kit origin's default branch (kitBranch, else origin/HEAD): no force push or delete, direct push on (branch.protect; never product repos)
function Set-KitOriginProtection {
  $kit = $KitConf.Kit; $gl, $gh = $env:GITLAB_HOST, $env:GH_HOST
  $lines = if ("$(git -C $kit remote get-url origin 2>$null)" -notmatch '^(?:\w+://)?(?:[^@/]+@)?(?<h>[^/:\\]{2,})(?::\d+)?[:/](?<r>[^:\\]+?)(?:\.git)?/?$') { 'origin failed: no origin remote with a host' } else {
    $h, $repo, $t = $Matches.h, $Matches.r, (Get-HostKind $Matches.h)
    if ($t -eq 'gitlab') { $env:GITLAB_HOST = $h } elseif ($t -eq 'github') { $env:GH_HOST = $h }
    $kb = "$(Get-KitSetting 'kitBranch' '')".Trim(); if (-not $kb) { $kb = "$(git -C $kit symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/' }   # the kit's default branch
    if (-not $kb) { 'failed: no origin/HEAD (git remote set-head origin -a) and no kitBranch in kit.local.json' }
    foreach ($b in @($kb | Where-Object { $_ })) {
      if (-not (git -C $kit rev-parse --verify -q "refs/remotes/origin/$b" 2>$null)) { "$b failed: origin/$b not fetched (git fetch origin)"; continue }
      $r = try { Invoke-HostVerb 'branch.protect' @{ type = $t; repo = $repo; branch = $b } -NoMemo } catch { "failed: $_" }
      "$b $(if ($r) { $r } else { "failed: set it by hand on $h/$repo (force push off, deletion off, direct push on)" })"
    }
  }
  $env:GITLAB_HOST, $env:GH_HOST = $gl, $gh
  Set-Content (Get-KitPath kit-protect -Create) $lines
  $lines | ForEach-Object { "protect: $_" }
}
