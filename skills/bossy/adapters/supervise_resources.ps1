<#
supervise_resources.ps1 (core): the machine's shared resources in bossy.ps1, dot-sourced by bossy.ps1
(skills/bossy/adapters/): build gate holders and queue, test locks, repeated build failures, the file cache flush (gate.cacheFlush),
phone leases, env leases, QA seats and claims, test browsers and their profiles, idle Gradle / Kotlin daemons, the RAM rows of
the supervise report, agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills), the report page (dashboard + Statistics from the logs; supervise.output, publish), seats and leases in board show and recover, the status resource rows, STUCK, pause and silent-run flags, release (every lease of an agent), launch: pauses it releases, a buildy launch's item tasks (-Self / -Check), stop-learn; sessions: several coordinators (run
owners for pause / resume / recover, a stepped-aside session's own flags, task claims), the step-age handoff.
Its hooks run inside the bossy.ps1 verb that calls them and use that verb's variables: supervise ($now, $mem, $keepFree, Within,
Left), cleanup ($now, $tmp, $DryRun, $actions, Gone, Old).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L15 builds · L47 supervise · L244 shells · L373 page · L678 usage · L820 release · L859 lines · L884 cleanup ·
  L920 launch · L998 pause · L1116 sessions
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
# gate head waited 10+ min, file cache 25%+ of RAM: run gate.cacheFlush (e.g. an elevated task), max once per 30 min
function Invoke-KitCacheFlush([int]$WaitMin, $Mem, [datetime]$Now, [int]$TimeoutSec = 120) {
  $cmd = "$(Get-KitSetting 'gate.cacheFlush' '')".Trim()
  if (-not $cmd -or $WaitMin -lt 10) { return }
  $stamp = Join-Path (Get-KitPath cache -Create) 'cache-flush.stamp'
  if ((Test-Path $stamp) -and ($Now - (Get-Item $stamp).LastWriteTime).TotalMinutes -lt 30) { return }
  $cacheGB = try { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop).SystemCacheResidentBytes / 1GB } catch { 0 }   # \Memory\System Cache Resident Bytes
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
  $ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
  $queue = @(Get-ChildItem (Join-Path $ledger 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $t = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($t -and (Test-KitPid $t.pid $t.start)) { $t } })
  $builds = @(Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { $t = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($t -and (Test-KitPid $t.pid $t.start)) { $t } })
  foreach ($t in @($builds | Where-Object { $_.gate })) {   # holder = its gate process (then its owner agent)
    $bl = @{ agent = $t.owner; pid = $t.gate; seen = $t.seen }; $keep = Update-KitLease $bl; if ("$($bl.seen)" -ne "$($t.seen)") { $t | Add-Member -Force seen $bl.seen; $t | ConvertTo-Json | Set-Content (Join-Path $ledger "$($t.pid).json") }
    $bp = Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue; if (-not $bp -or $bp.StartTime -gt ([datetime]$t.started).AddSeconds(5)) { continue }   # pid reused: not ours
    if ($keep) { if ($null -ne $bl.graceLeft) { $graceRows["build $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"] = $bl.graceLeft }; continue }
    if ($AutoFix) { $t | Add-Member -Force reclaimed "reclaim: no live holder for $($bl.graceMin) min"; $t | ConvertTo-Json | Set-Content (Join-Path $ledger "$($t.pid).json"); try { $bp.Kill($true) } catch {}; & $flag 'INFO' "auto-fixed: stopped build $($t.kind) of $($t.owner) (pid $($t.pid)): no live holder" 'Nothing to do.' }
    else { & $flag 'ACT' "build $($t.kind) of $($t.owner) (pid $($t.pid)) runs with no live holder" 'supervise -AutoFix stops it.' }
  }
  $oldest = $queue | Sort-Object { [datetime]$_.since } | Select-Object -First 1
  $wait = if ($oldest) { [int]($now - [datetime]$oldest.since).TotalMinutes } else { 0 }
  "gate: $($builds.Count) running ($((@($builds | ForEach-Object { "$($_.kind)" }) -join ', '))), $($queue.Count) queued, longest wait $wait min"
  if ($wait -ge 30) { & $flag 'ACT' "gate: $($oldest.owner) $($oldest.kind) has waited $wait min" 'Memory-bound: start no new agents, run bossy.ps1 cleanup, ask the owner to close big apps; fewer agents per wave.' }
  elseif ($queue.Count -ge 6) { & $flag 'WATCH' "gate: $($queue.Count) builds queued" 'Do not launch more build-heavy agents until the queue drains.' }
  $hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
  foreach ($bfx in Get-KitBuildFailures $hist $now @(Read-KitLog builds $now.AddHours(-24))) {
    $k = $bfx.key; $who = $bfx.who
    [pscustomobject]@{ level = 'WATCH'; what = "builds '$k' failed 3 times in a row"; kind = 'BUILDS'; who = $(if ($who) { $who } else { $k }); problem = "$k failed 3 times in a row"; next = "Check that agent's last build log"
      action = 'Repeated failing builds burn memory and turns; a setup-data cause (fixture, seed drift) -> spawn datay kind fixture, else help it or fix its brief.' } }
  if ($AutoFix -and (Within 'cache flush')) { Invoke-KitCacheFlush $wait $mem $now ([math]::Min(120, (Left))) }

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
    if ($AutoFix -and $tabs._idle -and -not @($tabs.PSObject.Properties | Where-Object Name -notmatch '^_').Count -and $idleM -ge [double](Get-KitSetting 'idle.graceMinutes' 10)) {
      try { (Get-Process -Id $b.Id).Kill($true) } catch {}; & $flag 'INFO' "auto-fixed: closed test browser $k (no tab holder for $([int]$idleM) min)" 'Nothing to do.'; continue
    }
    $rows.Add([pscustomobject]@{ name = "browser $(($k -split '\|' | Where-Object { $_ }) -join '·')"; by = (@($tabs.PSObject.Properties | Where-Object { $_.Name -ne '_key' -and $_.Value.agent } | ForEach-Object { $_.Value.agent }) | Select-Object -Unique) -join ', '; gb = & $tree $b })
  }
  $lanes = try { (Get-Content (Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json') -Raw | ConvertFrom-Json).lanes } catch { @() }
  foreach ($p in @($ps | Where-Object { $_.Name -match '^emulator' -and $_.CommandLine -match '-port\s+(\d+)' })) {
    $port = $Matches[1]; $ln = @($lanes | Where-Object { "$($_.port)" -eq $port })[0]; $nm = if ($ln) { $ln.name } else { "emulator-$port" }
    $ls = try { Get-Content (Join-Path (Get-KitPath phones) "$nm.json") -Raw | ConvertFrom-Json } catch { $null }
    $rows.Add([pscustomobject]@{ name = "phone $nm"; by = $(if ($ls) { $ls.agent } else { 'no lease' }); gb = & $tree $p })
  }
  foreach ($wq in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalMinutes -lt 3 })) {   # queued / booting lanes
    $w = try { Get-Content $wq.FullName -Raw | ConvertFrom-Json } catch { continue }
    $held = @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.agent -eq $w.agent })[0]
    $rows.Add([pscustomobject]@{ name = "phone $(if ($held) { $held.lane } elseif ($w.lane) { $w.lane } else { 'next lane' })"; by = "$($w.agent) $(if ($held) { '(waiting for RAM)' } else { '(waiting for a lane)' })"; gb = 0 })
  }
  foreach ($t in @($builds | Where-Object { $_.kind -ne 'emulator' })) { $p = $byId[[int]$t.pid]; $rows.Add([pscustomobject]@{ name = "build $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"; by = $t.owner; gb = $(if ($p) { [math]::Max((& $tree $p), 0.1) } else { [double]$t.need }) }) }
  $lks = Get-KitLockState   # repos[].exclusiveTests locks: holder + waiters (their RAM: the build rows)
  foreach ($k in @($lks.held.Keys)) { $h = $lks.held[$k]; $wn = @($lks.waiting | Where-Object { $_.lock -eq $k }); $rows.Add([pscustomobject]@{ name = "lock $k"; by = "$($h.holder) since $(([datetime]$h.at).ToString('HH:mm'))$(if ($wn.Count) { "; waiting: $(@($wn | ForEach-Object { $_.holder }) -join ', ')" })"; gb = 0 }) }
  foreach ($r in $rows) { if ($graceRows.ContainsKey($r.name)) { $r.by = "$($r.by) (grace $($graceRows[$r.name]) min)" }; $r }
  foreach ($x in @(Read-KitLog leases $now | Where-Object { $_.event -eq 'reclaim' -and $_.kind -in 'env', 'tab' })) { & $flag 'INFO' "auto-fixed: reclaimed $($x.kind) $($x.name) of $($x.agent) ($($x.reason))" 'Nothing to do.' }   # the env and tab sweeps above log, not print
  $need = [double](@(@($queue | ForEach-Object { [double]$_.need }) + 0) | Measure-Object -Maximum).Maximum
  if ($need) { [pscustomobject]@{ ramNeed = $need } }   # bossy.ps1 names the biggest rows of every goody
}

# a WATCH per prior-gate override this beat (Assert-KitPrior) whose hits hold other work; none logged: flagged
function Get-KitSuperviseFlagsPrior([switch]$AutoFix) {
  $briefs = $null
  foreach ($e in @(Read-KitLog calls (Get-Date).AddMinutes(-(Get-KitBeatMinutes)) | Where-Object event -eq 'prior-override')) {
    $hits = ''
    if ($e.PSObject.Properties['matched']) {
      if ($null -eq $briefs) { $briefs = @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { -not $_.completed -and $_.args.brief } | ForEach-Object { Get-Content -LiteralPath $_.args.brief -Raw -ErrorAction SilentlyContinue }) }
      $other = @(Get-KitPriorForeign $e $briefs); if (-not $other.Count) { continue }
      $hits = ": matches $(@($other | ForEach-Object { "$($_.kind) $($_.ref)" }) -join ', ')"
    }
    [pscustomobject]@{ level = 'WATCH'; what = "prior override: $($e.what) $($e.task) ($($e.reason))$hits"; action = 'Check it is no duplicate (crafty.ps1 prior -Task <id>); a duplicate: stop it, reuse the existing work' }
  }
}
# hits neither its own task's (tagged) nor a task its live brief names beside it
function Get-KitPriorForeign($Entry, [string[]]$Briefs) {
  $tag = "$($KitConf.TrackerTag)"; $has = { param($t, $id) "$t" -match "(?i)(?<![A-Za-z0-9])$([regex]::Escape("$id"))(?![A-Za-z0-9])" }   # whole ids: 7 is not in 17
  foreach ($h in @($Entry.matched | Where-Object { $_ })) {
    if ($h.tagged -or (& $has $h.ref "$tag$($Entry.task)")) { continue }
    $tid = if ($h.kind -eq 'task') { "$($h.ref)" } elseif ($tag -and "$($h.ref)" -match "(?i)$([regex]::Escape($tag))([A-Za-z0-9]+)") { $Matches[1] }
    if ($tid -and @($Briefs | Where-Object { $_ -and (& $has $_ $tid) -and (& $has $_ $Entry.task) }).Count) { continue }
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
  foreach ($t in @(Get-ChildItem (Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.owner -and (Test-KitPid $_.pid $_.start) })) {
    [pscustomobject]@{ agent = $t.owner; why = "build gate: RAM for $($t.kind)"; at = $t.since; next = 'the gate starts it when RAM frees' }
  }
  foreach ($w in @((Get-KitLockState).waiting)) { [pscustomobject]@{ agent = $w.holder; why = "test lock $($w.lock)"; at = $w.at; next = 'crafty.ps1 check takes it when its holder ends' } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 })) {
    $w = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }; [pscustomobject]@{ agent = $w.agent; why = "phone lane$(if ($w.lane) { " $($w.lane)" })"; at = $f.LastWriteTime; next = 'phoney.ps1 acquire hands it a lane' }
  }
}
# a row per resource from leases.jsonl (holder = unreleased acquire < 24 h old; lanes from lease files)
function Get-KitResourceRows {
  $held = [ordered]@{}; $last = @{}; $lf = Get-KitLogFile leases
  foreach ($x in @(if (Test-Path -LiteralPath $lf) { Get-Content -LiteralPath $lf })) {
    $o = try { $x | ConvertFrom-Json } catch { continue }; $r = "$($o.kind)|$($o.name)"
    if ($o.event -eq 'acquire' -and $o.kind -ne 'build' -and ((Get-Date) - [datetime]$o.at).TotalHours -lt 24) { if (-not $held[$r]) { $held[$r] = @{} }; $held[$r]["$($o.agent)"] = $o; continue }
    if ($o.event -ne 'down') { $last[$r] = $o }; if (-not $held[$r]) { $held[$r] = @{} }; if ($o.event -eq 'down') { $held[$r].Clear() } else { $held[$r].Remove("$($o.agent)") }
  }
  foreach ($p in @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.lane -and $_.agent -ne '__stopping__' })) { $held["lane|$($p.lane)"] = @{ "$($p.agent)" = [pscustomobject]@{ agent = $p.agent; session = $p.session; holder = $p.holder; at = $p.since; seen = $p.seen } } }
  foreach ($r in @($held.Keys)) {
    $hs = @($held[$r].Values); if ($r -like 'build|*') { continue }
    $live = @($hs | Where-Object { Test-KitLive @{ agent = $_.agent; session = $_.session; holder = $_.holder } })
    [pscustomobject]@{ resource = $r -replace '\|', ' '; holder = $(if ($hs.Count) { @($hs.agent) -join ', ' } else { 'free' })
      since = @($hs | ForEach-Object { $(if ($_.since) { $_.since } else { $_.at }) } | Where-Object { $_ } | Sort-Object)[0]
      seen = $(if ($live.Count) { 'live now' } elseif ($hs.Count) { "$(if (@($hs.seen | Where-Object { $_ })) { "$(([datetime]@($hs.seen | Where-Object { $_ })[0]).ToString('HH:mm')), " })no live holder" } else { '—' })
      used = Format-KitLeaseLast $last[$r] }
  }
}
function Format-KitResourceTable($Rows) {
  if (-not @($Rows).Count) { return }
  ''; '| Resource | Holder | Since | Last seen | Last used |'; '|---|---|---|---|---|'
  foreach ($r in @($Rows | Sort-Object resource)) { "| $($r.resource) | $($r.holder) | $(if ($r.since) { ([datetime]$r.since).ToString('HH:mm') } else { '—' }) | $($r.seen) | $($r.used) |" }
}

# ---- shells: agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills)
# one process snapshot per sweep
function Get-KitSweepProcs { if ($null -eq $script:KitSweepProcs) { $script:KitSweepProcs = @(Get-SysProcs) }; $script:KitSweepProcs }
# command: body of the harness's eval '...' (bash), else after -Command / -c
function Get-KitShellCommand([string]$CommandLine) {
  $c = "$CommandLine"
  if ($c -match "(?s)\beval '(.*)'\s*(<\s*/dev/null\s*)?&&\s*pwd -P" -or $c -match "(?s)\beval '(.*)'") { return ($Matches[1] -replace "'\\''", "'" -replace '\\"', '"').Trim() }
  if ($c -match '(?i)\s-(?:e|enc|EncodedCommand)\s+([A-Za-z0-9+/=]{8,})') { try { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])).Trim() } catch {} }
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
    $text = try { $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite, Delete'); try { $n = [int][math]::Min($fs.Length, 16MB); $null = $fs.Seek(-$n, 'End'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n); [Text.Encoding]::UTF8.GetString($b, 0, $got) } finally { $fs.Dispose() } } catch { '' }
    foreach ($k in @($frags.Keys)) {
      for ($i = $text.IndexOf($frags[$k], [StringComparison]::Ordinal); $i -ge 0; $i = $text.IndexOf($frags[$k], $e, [StringComparison]::Ordinal)) {
        $s0 = $text.LastIndexOf("`n", $i) + 1; $e = $text.IndexOf("`n", $i); if ($e -lt 0) { $e = $text.Length }; $line = $text.Substring($s0, $e - $s0)
        if ($line -notmatch '"tool_use"' -or ($line -match '"timestamp":"([^"]+)"' -and [math]::Abs(([datetimeoffset]$Matches[1] - [datetimeoffset]$Want[$k].created).TotalSeconds) -gt 120)) { continue }   # parse only lines near the shell's start
        $o = try { $line | ConvertFrom-Json -Depth 80 } catch { continue }
        $u = @($o.message.content | Where-Object { $_.type -eq 'tool_use' -and "$($_.input.command)".Contains($frags[$k]) })[0]; if (-not $u) { continue }
        $gap = if ($o.timestamp) { [math]::Abs(([datetimeoffset]$o.timestamp - [datetimeoffset]$Want[$k].created).TotalSeconds) } else { 1e9 }
        if ($gap -le 120 -and (-not $out[$k] -or $gap -lt $out[$k].gap)) { $out[$k] = [pscustomobject]@{ file = $file; bg = [bool]$u.input.run_in_background; gap = $gap } }
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
  } else { $m = try { Get-Content -LiteralPath ($Tx -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }; if (-not $name) { $name = $m.agentType }; if ($m.finished) { $fin = $true } }
  $live = $e -and $e.status -ne 'left' -and (Test-KitHolder $e) -ne $false
  [pscustomobject]@{ name = $(if ($name) { "$name" } else { "agent $id" }); finished = [bool]$fin; coordinator = $false; live = [bool]$live; last = (Get-KitLastActivity $Tx $e "$($e.tool)") }
}
# ORPHAN: owner finished, off the board, idle idle.graceMinutes; or dir gone. STUCK: no CPU growth, older than supervise.shellStuckMinutes.
# -AutoFix kills on the 2nd gone sweep, or the 1st if no poll loop and owner idle 20+ min
function Get-KitShellSweep($State, [datetime]$Now, [switch]$AutoFix, $Procs = $(Get-KitSweepProcs)) {
  $graceMin = [double](Get-KitParam 'idle.graceMinutes'); $pollRx = '(^|[\s;&|(])(until|while|for)\s|\bsleep\s+[-\d]|\bglab api\b|\bgh run watch\b|--watch\b|\bpipes\b|\b(envy|pokey|bossy)\.ps1\s+(\w+\s+)*wait\b'
  $stuckMin = [double](Get-KitParam 'supervise.shellStuckMinutes'); $old = if ($State.shells -is [Collections.IDictionary]) { $State.shells } else { @{} }; $new = @{}
  $kids = @{}; foreach ($p in $Procs) { if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[object]]::new() }; $kids[$p.ParentId].Add($p) }
  $board = @(Read-KitJsonFiles (Get-KitPath board)); $rows = [Collections.Generic.List[object]]::new(); $flags = [Collections.Generic.List[object]]::new()
  $shells = @(Get-KitAgentShells $Procs); $made0 = { param($p) if ($p.Created) { [datetime]$p.Created } else { $Now } }
  $want = @{}; foreach ($p in $shells) { $m0 = & $made0 $p; $k0 = "$($p.Id)@$($m0.ToString('s'))"; if (-not ($old[$k0] -is [Collections.IDictionary] -and $old[$k0].ContainsKey('tx'))) { $want[$k0] = @{ cmd = (Get-KitShellCommand $p.CommandLine); created = $m0 } } }
  $found = if ($want.Count) { Find-KitShellTranscripts $want } else { @{} }   # once per shell: the tool_use line is written before the shell starts
  foreach ($p in $shells) {
    $made = & $made0 $p; $age = ($Now - $made).TotalMinutes; $key = "$($p.Id)@$($made.ToString('s'))"
    $s = if ($old[$key] -is [Collections.IDictionary]) { $old[$key] } else { @{} }; $new[$key] = $s; if ($s.killed) { continue }; $cmd = Get-KitShellCommand $p.CommandLine
    if (-not $s.ContainsKey('tx')) { $f = $found[$key]; $s.tx = "$($f.file)"; $s.bg = [bool]$f.bg }
    $tree = @{}; $cpu = 0.0; $st = [Collections.Stack]::new(); $st.Push($p)
    while ($st.Count) { $q = $st.Pop(); if ($tree[$q.Id]) { continue }; $tree[$q.Id] = 1; $cpu += [double]$q.Cpu; foreach ($c in @($kids[$q.Id])) { if ($c) { $st.Push($c) } } }
    $flat = $null -ne $p.Cpu -and $null -ne $s.cpu -and [math]::Abs($cpu - [double]$s.cpu) -lt 0.02
    $s.cpu = $cpu; $s.age = [math]::Round($age, 1)
    if (-not $s.bg -and $age -lt 10) { continue }   # a foreground tool call ends within the Bash tool's 10 min cap
    $s.listed = $true; $o = Get-KitShellOwner $s.tx $board; $dir = Get-KitShellDir $cmd; $gone = $dir -and -not (Test-Path -LiteralPath $dir)
    $stuck = $flat -and $age -ge $stuckMin
    $hbMin = [double](Get-KitParam 'supervise.heartbeatMinutes')
    if (-not $stuck) { $s.stuck = 0; $s.stuckAt = $null } elseif (-not $s.stuckAt -or ($Now - [datetime]$s.stuckAt).TotalMinutes * 2 -ge $hbMin) { $s.stuck = [int]$s.stuck + 1; $s.stuckAt = $Now.ToString('o') }
    $idle = if ($o.last) { ($Now - [datetime]$o.last).TotalMinutes } else { 1e9 }; $poll = $cmd -match $pollRx
    $ownerGone = $o.finished -and -not $o.live -and $idle -ge $graceMin   # meta "finished" alone also marks an agent idling on this very shell
    if (-not $ownerGone) { $s.gone = 0; $s.goneAt = $null } elseif (-not $s.goneAt -or ($Now - [datetime]$s.goneAt).TotalMinutes * 2 -ge $hbMin) { $s.gone = [int]$s.gone + 1; $s.goneAt = $Now.ToString('o') }
    $why = @($(if ($ownerGone) { "owner $($o.name) finished, idle $([int]$idle) min" }), $(if ($gone) { "dir gone: $dir" }), $(if ($stuck) { "no CPU growth, $($s.stuck) sweep(s)" }) | Where-Object { $_ }) -join '; '
    $short = Get-KitShellShort $cmd; $one = ($cmd -replace '\s+', ' ').Trim()
    if ($ownerGone -and ($s.gone -ge 2 -or (-not $poll -and $idle -ge 20)) -and $AutoFix -and (Test-KitPid $p.Id $made)) {
      if ($KitIsWindows) { taskkill /PID $p.Id /T /F 2>&1 | Out-Null } else { foreach ($t in @($tree.Keys)) { Stop-SysProcess $t } }
      $s.killed = $true; Write-KitLog calls shell-kill ([ordered]@{ pid = $p.Id; owner = $o.name; why = $why; dir = $dir; what = "killed shell $($p.Id) ($why): $($one.Substring(0, [math]::Min(300, $one.Length)))" })
      $flags.Add([pscustomobject]@{ level = 'INFO'; what = "auto-fixed: killed shell $($p.Id) of $($o.name) ($why): $short"; action = 'Nothing to do.' }); continue
    }
    $shellState = @($(if ($ownerGone -or $gone) { 'ORPHAN' }), $(if ($stuck) { 'STUCK' }) | Where-Object { $_ }) -join ', '; if (-not $shellState) { $shellState = 'running' }
    $tk = "taskkill /PID $($p.Id) /T /F"
    $next = if ($shellState -eq 'running') { '' } elseif ($o.coordinator) { "yours: stop it (KillShell) or $tk" } elseif ($ownerGone) { "supervise -AutoFix kills it next sweep; now: $tk" } else { "$($o.name) ends it, else $tk" }
    $rows.Add([pscustomobject]@{ pid = $p.Id; short = $short; cmd = $cmd; owner = $o.name; age = [math]::Round($age); state = $shellState; next = $next; dir = $dir })
    $s60 = $short.Substring(0, [math]::Min(60, $short.Length))
    if ($shellState -ne 'running') { $flags.Add([pscustomobject]@{ level = 'WATCH'; kind = "SHELL $shellState"; who = $o.name; age = "$([int]$age) min"; problem = "pid $($p.Id) $s60`: $why"; what = "SHELL $shellState pid $($p.Id) of $($o.name) ($s60): $why"; action = $next }) }
  }
  foreach ($k in @($old.Keys)) { $g = $old[$k]; if (-not $new.ContainsKey($k) -and $g -is [Collections.IDictionary] -and $g.listed -and -not $g.killed) { Add-KitParamObs 'supervise.shellStuckMinutes' ([double]$g.age) -Default 30 } }   # it ended on its own
  $State.shells = $new
  [pscustomobject]@{ rows = @($rows); flags = @($flags) }
}
# supervise hook (section 3; uses $state, $now, Within): flags only (a count is no problem); rows go to $script:KitShellRows
function Get-KitSuperviseGuardShells([switch]$AutoFix) {
  $script:KitShellRows = @(); if (-not (Within 'shells')) { return }
  try { $sh = Get-KitShellSweep $state $now -AutoFix:$AutoFix; $script:KitShellRows = $sh.rows; $sh.flags }
  catch { [pscustomobject]@{ level = 'WATCH'; what = "shell sweep failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Get-KitShellSweep.' } }
}

# ---- page: report page and -Brief stdout (supervise.output)
# Statistics, a record a day (null = no source): calls board join / leave, decisions, deploys, lessons; closed days from $Prev
function Get-KitSuperviseDays($Prev, [datetime]$Now, [int]$Days = 14) {
  $today = $Now.ToString('yyyy-MM-dd'); $kept = @{}; foreach ($pd in @($Prev | Where-Object { $_.final })) { $kept["$($pd.day)"] = $pd }
  $srcs = [ordered]@{ asked = 'decisions-log', '"event":"pending"'; answered = 'decisions-log', '"event":"answered"'; deploys = 'deploy-log', '"event":"record"'; lessons = 'signals', '"text":' }
  $logText = @{}; $perDay = @{}
  foreach ($sk in $srcs.Keys) { $ln = $srcs[$sk][0]
    if (-not $logText.ContainsKey($ln)) { $lf = Get-KitPath $ln; $logText[$ln] = if (Test-Path -LiteralPath $lf) { , @(Get-Content -LiteralPath $lf -ErrorAction SilentlyContinue) } }
    if ($null -eq $logText[$ln]) { continue }
    $cnt = @{}; foreach ($l in $logText[$ln]) { if ($l.Contains($srcs[$sk][1]) -and $l -match '"at":"(\d{4}-\d\d-\d\d)') { $cnt[$Matches[1]] = 1 + [int]$cnt[$Matches[1]] } }; $perDay[$sk] = $cnt }
  foreach ($i in 0..($Days - 1)) { $day = $Now.AddDays(-$i).ToString('yyyy-MM-dd')
    if ($kept.ContainsKey($day)) { $kept[$day]; continue }
    $rec = [ordered]@{ day = $day; final = $day -ne $today; runs = $null; spawned = $null; finished = $null; failed = $null; durSum = $null; durN = $null }
    foreach ($sk in $srcs.Keys) { $rec[$sk] = if ($perDay.ContainsKey($sk)) { [int]$perDay[$sk][$day] } }
    $cf = Join-Path (Get-KitPath audit) "$day/calls.jsonl"
    if (Test-Path -LiteralPath $cf) {
      $evs = @(Select-String -LiteralPath $cf -Pattern '"verb":"board (join|leave)"' | ForEach-Object { try { $_.Line | ConvertFrom-Json -ErrorAction Stop } catch { } } | Sort-Object { [datetime]$_.at })
      $joined = @{}; $runIds = @{}; $durs = [Collections.Generic.List[double]]::new(); $rec.spawned = 0; $rec.finished = 0; $rec.failed = 0
      $byPid = @{}   # start event's agent / run / -Status for its end (rc 'exit' = pwsh exit, success)
      foreach ($ev in $evs) { $ea = "$($ev.args)"
        if ($ev.event -eq 'start') { $byPid["$($ev.pid)"] = @{ agent = $(if ($ev.agent) { "$($ev.agent)" } elseif ($ea -match '-Agent\s+(\S+)') { $Matches[1] }); run = $(if ($ev.run) { "$($ev.run)" } elseif ($ea -match '-Run\s+(\S+)') { $Matches[1] }); status = $(if ($ea -match '-Status\s+(\w+)') { $Matches[1] } else { 'done' }) }; continue }
        if ($ev.event -ne 'end' -or "$($ev.rc)" -notin '0', 'exit') { continue }
        $sv = $byPid["$($ev.pid)"]; $who = if ($ev.agent) { "$($ev.agent)" } else { $sv.agent }; $rn = if ($ev.run) { "$($ev.run)" } else { $sv.run }
        if ($ev.verb -eq 'board join') { $rec.spawned++; if ($who) { $joined[$who] = [datetime]$ev.at }; if ($rn) { $runIds[$rn] = 1 } }
        elseif ($sv.status -in 'failed', 'blocked', 'error') { $rec.failed++ }
        elseif (-not $sv -or $sv.status -eq 'done') { $rec.finished++; if ($who -and $joined.ContainsKey($who)) { $durs.Add(([datetime]$ev.at - $joined[$who]).TotalMinutes); $joined.Remove($who) } } }   # paused / stopped / needsDecision: neither; a stay across midnight has no duration
      $rec.runs = $runIds.Count; $rec.durSum = [math]::Round(($durs | Measure-Object -Sum).Sum, 1); $rec.durN = $durs.Count
    }
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
    $ds = if (Get-Command Get-KitStorageSamples -ErrorAction SilentlyContinue) { @(Get-KitStorageSamples $dv 480 | ForEach-Object free) } else { @() }
    [ordered]@{ drive = $dv; free = $fr; rate = $rt; total = $tot; series = @(& $thin $ds) } } })
  [ordered]@{ ram = @(& $thin $ram); disks = @(if ($disks.Count) { $disks } else { $Prev.disks | Where-Object { $_ } }) }
}
# this sweep's Statistics tiles from its lines (workflows, idle steps, memory, gate, QA seats, disks, time); null = no line
function Get-KitSuperviseNow([string[]]$Lines, [double]$GraceMinutes = 10) {
  $o = [ordered]@{ wfs = @(); run = 0; done = 0; total = $null; stale = @(); mem = $null; avail = $null; gr = $null; gq = $null; gw = $null; seats = $null; seatsMax = $null; disks = @(); secs = $null; slow = '' }
  $num = { param($s) [double]("$s" -replace ',', '.') }
  foreach ($l in @($Lines | ForEach-Object { "$_" })) {
    if ($l -match '^workflow (\S+): (\d+) agents, (\d+) finished, (\d+) running') { $o.wfs += $Matches[1]; $o.total += [int]$Matches[2]; $o.done += [int]$Matches[3]; $o.run += [int]$Matches[4] }
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
# page + .json, written atomically; returns its path; failure: a WATCH and '' (tables print)
function Write-KitSuperviseHtml($d, [string[]]$Sweep, [string]$Next) { try {
  $rk = @{ ACT = 0; WATCH = 1; INFO = 2 }
  $p = [IO.Path]::ChangeExtension((Get-KitPath supervise-report -Create), '.html'); $pj = [IO.Path]::ChangeExtension($p, '.json')
  $prior = try { Get-Content -LiteralPath $pj -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  $fl = @(@($d.flags) + @($d.info | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }) | Sort-Object { $rk["$($_.level)"] })
  $fixedN = @($fl | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' }).Count
  $History = @(@([pscustomobject]@{ at = $d.at.ToString('o'); flags = @($d.flags | Where-Object level -ne 'INFO' | Select-Object level, what); active = @($d.rows | Where-Object state -ne 'FINISHED').Count; fixed = $fixedN }) + @($prior.history | Where-Object { $_ }) | Select-Object -First ([int](Get-KitSetting 'supervise.historySweeps' 12)))
  $set = Get-KitSetting 'supervise' $null; $settings = [ordered]@{}
  if ($set) { foreach ($sp0 in $set.PSObject.Properties) { $settings["supervise.$($sp0.Name)"] = if ($sp0.Name -eq 'publish') { '(set)' } else { $sp0.Value | ConvertTo-Json -Compress -Depth 4 } } }
  $series = try { Get-KitSuperviseSeries (@($Sweep) + @($fl | ForEach-Object what)) $prior.stats } catch { [ordered]@{ ram = @(); disks = @() } }
  $nowT = try { Get-KitSuperviseNow $Sweep ([double](Get-KitParam 'idle.graceMinutes')) } catch { $null }
  if ($nowT -and -not @($nowT.disks).Count) { $nowT.disks = @($series.disks | Where-Object { $_ } | ForEach-Object { [ordered]@{ drive = $_.drive; free = $_.free; rate = $_.rate; ttf = $null } }) }   # storage skipped this sweep: the last disk values
  $samples = @($prior.stats.live | Where-Object { $_ -and $_.at -and ($d.at - [datetime]$_.at).TotalDays -lt [double](Get-KitParam 'supervise.statsDays') -and [datetime]$_.at -lt $d.at })   # one per base heartbeat, 7 days: deltas and the 7-day line
  if ($samples.Count -ge 2 -and ([datetime]$samples[-1].at - [datetime]$samples[-2].at).TotalMinutes -lt [double](Get-KitParam 'supervise.heartbeatMinutes')) { $samples = @($samples | Select-Object -SkipLast 1) }
  if ($nowT) { $dFree = [ordered]@{}; foreach ($dk in $nowT.disks) { $dFree[$dk.drive] = $dk.free }
    $samples += [pscustomobject]@{ at = $d.at.ToString('o'); run = $nowT.run; mem = $nowT.mem; gq = $nowT.gq; gw = $nowT.gw; seats = $nowT.seats; secs = $nowT.secs; disks = [pscustomobject]$dFree } }
  $usage = Read-KitUsageResult   # budget -Usage writes it
  $stats = [ordered]@{ keepFree = $d.keepFree; usage = $usage; repos = (Get-KitRepoSweep); days = @(try { Get-KitSuperviseDays $prior.stats.days $d.at } catch { }); ram = $series.ram; disks = $series.disks; now = $nowT; live = @($samples); settings = [pscustomobject]$settings
    changes = @(Get-Content -LiteralPath (Get-KitPath params-changes) -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop | Select-Object at, key, ctx, from, to, why } catch { } })
    params = @(try { $apv = (Read-KitParams).approved; @(Invoke-KitParamVerb show -Json | ConvertFrom-Json) | ForEach-Object { [pscustomobject]@{ key = $_.key; ctx = $_.ctx; value = $_.effective
            source = "$(if ($apv."$($_.key)|$(if ($_.ctx -ne '_') { $_.ctx })" -or $apv."$($_.key)|") { 'approved' } else { $_.state })$(if ($_.source -notmatch '^(default|learned|pin$)') { " · $($_.source)" })"
            learned = $(if ($null -ne $_.learned -and $_.learned -ne $_.effective) { $_.learned } else { '' }); changed = $_.changed; why = $_.why } } } catch { }) }
  $j = [pscustomobject]@{ at = $d.at.ToString('o'); next = $Next; flags = @($fl); agents = @($d.rows); mem = $d.mem; resources = @($d.resources); shells = @($d.shells); history = @($History); stats = $stats }
  Write-KitAtomic $pj ($j | ConvertTo-Json -Depth 9)
  Write-KitAtomic $p (Format-KitSuperviseHtml $j)
  $pub = [string](Get-KitSetting 'supervise.publish' '')   # the bytes never pass through the model
  if ($pub.Trim()) {   # encoded: Windows strips the double quotes of a joined -Command line
    $sp = @{ FilePath = 'pwsh'; ArgumentList = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pub))); ErrorAction = 'Stop' }; if ($KitIsWindows) { $sp.WindowStyle = 'Hidden' }
    $env:KIT_SUPERVISE_HTML = $p; try { Start-Process @sp | Out-Null } catch { Write-Warning "supervise.publish failed to start: $($_.Exception.Message)" } finally { Remove-Item Env:KIT_SUPERVISE_HTML -ErrorAction SilentlyContinue } }
  $p
  } catch { $w = [pscustomobject]@{ level = 'WATCH'; what = "supervise page failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Write-KitSuperviseHtml.' }; $d.flags = @($d.flags) + $w; if ($flags -is [Collections.IList]) { [void]$flags.Add($w) }; '' }   # $flags: the supervise verb's list (-Json, plain)
}
# pure (tests feed a sample); values HtmlEncoded; inline CSS / JS / SVG only: no request leaves the page
function Format-KitSuperviseHtml($j) {
  $iv = [cultureinfo]::InvariantCulture; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $n1 = { param($x) ([double]$x).ToString('0.#', $iv) }
  $toTime = { param($x) if ($x) { try { [datetime]$x } catch { $null } } }; $at = & $toTime $j.at; if (-not $at) { $at = Get-Date }
  $ago = { param($x) $tx = & $toTime $x; if (-not $tx) { return '' }; $m = [int][math]::Max(0, ($at - $tx).TotalMinutes); if ($m -lt 1) { 'now' } elseif ($m -lt 60) { "$m min" } elseif ($m -lt 1440) { "$([math]::Floor($m / 60)) h $($m % 60) min" } else { "$([math]::Floor($m / 1440)) d" } }
  $when = { param($x) $tx = & $toTime $x; if ($tx) { "<span class=ago data-t='$($tx.ToString('o'))' title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $x)</span>" } else { '<span class=m>—</span>' } }   # .ago: the page JS recounts it live
  $minAgo = { param($v) if ("$v" -match '^\s*(\d+(?:\.\d+)?)(?: min)?\s*$') { & $when $at.AddMinutes(-[double]$Matches[1]) } else { & $e $v } }   # sweep-relative minutes -> a live age
  $big = { param($s) if ("$s".Trim() -match '^(\d+(?:\.\d+)?)\s*([kKmM]?)$') { $nv = [double]$Matches[1]; $nu = $Matches[2].ToLower(); $nv * $(if ($nu -eq 'k') { 1e3 } elseif ($nu -eq 'm') { 1e6 } else { 1 }) } }
  $stCls = { param($s) if ("$s" -match 'STUCK') { 's-stuck' } elseif ("$s" -match '^ACTIVE') { 's-act' } elseif ("$s" -match '^FINISHED') { 's-fin' } else { 's-oth' } }
  $spark = { param($vals, [string]$cls = 'sage') $vals = @($vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }); if ($vals.Count -lt 2) { return '' }
    $mx = ($vals | Measure-Object -Maximum).Maximum; $mn = ($vals | Measure-Object -Minimum).Minimum
    $pts = @(for ($i = 0; $i -lt $vals.Count; $i++) { "$(& $n1 (100 * $i / ($vals.Count - 1))),$(& $n1 $(if ($mx -eq $mn) { 12 } else { 22 - 20 * ($vals[$i] - $mn) / ($mx - $mn) }))" }) -join ' '
    "<svg class='spark $cls' viewBox='0 0 100 24' preserveAspectRatio=none aria-hidden=true><polygon class=a points='0,24 $pts 100,24'/><polyline class=l points='$pts'/></svg>" }
  $bar = { param([double]$v, [double]$max, [string]$label, [string]$tone = '') if ($max -le 0) { return '' }; $pc = [math]::Min(100, 100 * $v / $max); $bc = if ($tone) { $tone } elseif ($pc -ge 100) { 'act' } elseif ($pc -ge 80) { 'watch' } else { 'sage' }
    "<span class=bar><i class=$bc style='width:$(& $n1 $pc)%'></i></span><span class=bl>$(& $e $label)</span>" }
  $ring = { param([double]$pc, [string]$value, [string]$label, [string]$sub, [string]$tone = '') $pc = [math]::Max(0, [math]::Min(100, $pc)); $rc = if ($pc -ge 90 -or $tone -eq 'act') { 'act' } elseif ($pc -ge 75 -or $tone -eq 'watch') { 'watch' } else { 'sage' }; $arc = 2 * [math]::PI * 40 * 0.75
    "<figure class=gauge><svg viewBox='0 0 100 92' role=img aria-label='$(& $e $label): $(& $e $value)'><circle class=trk cx=50 cy=50 r=40 stroke-dasharray='$(& $n1 $arc) 999' transform='rotate(135 50 50)'/><circle class='val $rc' cx=50 cy=50 r=40 stroke-dasharray='$(& $n1 ($arc * $pc / 100)) 999' transform='rotate(135 50 50)'/><text x=50 y=50 class=gv>$(& $e $value)</text><text x=50 y=66 class=gl>$(& $e $label)</text></svg><figcaption>$(& $e $sub)</figcaption></figure>" }
  $section = { param([string]$id, [string]$title, $count, [string]$inner, [switch]$Closed) "<details class=sec id=sec-$id$(if (-not $Closed) { ' open' })><summary><h2>$(& $e $title)</h2>$(if ($null -ne $count) { "<span class=cnt>$(& $e $count)</span>" })</summary><div class=bd>$inner</div></details>" }
  $table = { param([string[]]$cols, $rows) if (-not @($rows).Count) { return '<p class=empty>None</p>' }
    "<div class=tw><table><tr>$(@($cols | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '')</tr>$(@(foreach ($r in @($rows)) { "<tr class=f>$(@(for ($ci = 0; $ci -lt @($r).Count; $ci++) { $cv = @($r)[$ci]; $dk = & $e $cols[$ci]; if ($cv -is [hashtable]) { "<td data-k='$dk'>$($cv.h)</td>" } else { "<td data-k='$dk'>$(& $e $cv)</td>" } }) -join '')</tr>" }) -join '')</table></div>" }   # @{ h = html }: a cell already built; data-k: its header, shown per cell on a phone
  # every list of short items (cards, tiles, bars, key-value pairs): one auto-fill grid, min width per item, at most $max across (README "Using it")
  $grid = { param([string]$cls, [string]$min, [object[]]$items, [int]$max = 0, [string]$tag = 'div') "<$tag class='cg $cls' style='--cmin:$min$(if ($max) { ";--cmax:$max" })'>$(@($items | Where-Object { $_ }) -join '')</$tag>" }
  $item = { param([string]$name, [string]$sub, [string]$inner = '') "<div class='ci f' title='$(& $e "$name · $sub")'><div class=tn>$(& $e $name)</div><div class=sm>$(& $e $sub)</div>$inner</div>" }   # a grid card: name, one line, an optional full-width bar
  $agents = @($j.agents | Where-Object { $_ }); $live = @($agents | Where-Object state -ne 'FINISHED'); $flags = @($j.flags | Where-Object { $_ })
  $nAct = @($flags | Where-Object level -eq 'ACT').Count; $nWatch = @($flags | Where-Object level -eq 'WATCH').Count; $nFix = @($flags | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' }).Count
  $hist = @($j.history | Where-Object { $_ }); [array]::Reverse($hist)   # oldest first
  $hCount = { param($h, [string]$lv) @($h.flags | Where-Object level -eq $lv).Count }
  $nextMin = if ("$($j.next)" -match '(\d+(?:\.\d+)?)') { $Matches[1] } else { 15 }   # stale: older than 2 heartbeats (amber), 4 (red)
  $nxTail = if ("$($j.next)" -match '\((.+)\)\s*$') { " · $($Matches[1])" } else { '' }   # the pace reason, plain words
  $mem = $j.mem; $tot = [double]$mem.TotalGB; $avail = [double]$mem.AvailGB; $used = $tot - $avail; $st = $j.stats
  $diskLv = @{}; foreach ($f in @($flags | Where-Object level -in 'ACT', 'WATCH')) { if ("$($f.what)" -match '^disk (\S+?):' -and $diskLv[$Matches[1]] -ne 'ACT') { $diskLv[$Matches[1]] = $f.level } }   # storage floor / fill-rate flags per drive
  $disks = @($st.disks | Where-Object { $_ } | Sort-Object { $rk = $diskLv["$($_.drive)"]; if ($rk -eq 'ACT') { 0 } elseif ($rk -eq 'WATCH') { 1 } else { 2 } }, { [double]$_.free })   # every watched drive, a flagged one first
  $diskTone = { param($dv, [string]$hot = 'hot', [string]$warn = 'warn') $lvd = $diskLv["$dv"]; if ($lvd -eq 'ACT') { $hot } elseif ($lvd -eq 'WATCH') { $warn } else { '' } }
  $markFile = Join-Path $script:KitRoot 'assets/claude-crew-mark.svg'; $mark = if (Test-Path -LiteralPath $markFile) { (Get-Content -LiteralPath $markFile -Raw) -replace '<\?xml[^>]*>\s*', '' -replace '\s+', ' ' } else { '' }
  $tile = { param([string]$key, [string]$value, [string]$sub, [string]$sp, [string]$cls = '') "<div class='tile $cls'><div class=k>$(& $e $key)</div><div class=v>$(& $e $value)</div><div class=s>$(& $e $sub)</div>$sp</div>" }
  $kpi = & $grid kpis 170px (@((& $tile 'Active agents' $live.Count "$($agents.Count - $live.Count) finished · $(@($agents | Where-Object { $_.state -match 'STUCK' }).Count) stuck" (& $spark @($hist | ForEach-Object active) 'sage')),
    (& $tile 'ACT' $nAct 'needs you now' (& $spark @($hist | ForEach-Object { & $hCount $_ 'ACT' }) 'act') $(if ($nAct) { 'hot' })),
    (& $tile 'WATCH' $nWatch 'resolve without asking' (& $spark @($hist | ForEach-Object { & $hCount $_ 'WATCH' }) 'watch')),
    (& $tile 'FIXED' $nFix 'auto-fixed this sweep' (& $spark @($hist | ForEach-Object fixed) 'sage')),
    (& $tile 'RAM used' $(if ($tot) { "$(& $n1 $used) / $(& $n1 $tot) GB" } else { '—' }) $(if ($tot) { "$(& $n1 $avail) GB free · floor $(& $n1 $st.keepFree) GB" } else { 'no sample' }) (& $spark @($st.ram) 'slate'))) + @(if ($disks.Count) { foreach ($dk in $disks) { $tn = & $diskTone $dk.drive; & $tile "Disk $($dk.drive) free" "$(& $n1 $dk.free) GB" "$(if ([double]$dk.rate -ge 0) { '+' })$(& $n1 $dk.rate) GB/h$(if ($tn) { " · $($diskLv["$($dk.drive)"])" })" (& $spark @($dk.series) $(if ($tn -eq 'hot') { 'act' } elseif ($tn) { 'watch' } else { 'slate' })) $tn } } else { & $tile 'Disk free' '—' 'no sample' '' })) ([math]::Min(8, 5 + [math]::Max(1, $disks.Count)))
  $card = { param($f) $c = Get-KitFlagCells $f; $lv = if ($f.level -eq 'ACT') { 'ACT' } else { 'WATCH' }
    "<article class='flag $lv f'><div class=h><span class='chip lv $lv'>$lv</span>$(@(@($c.kind, $c.who | Where-Object { "$_".Trim() } | ForEach-Object { "<span>$(& $e $_)</span>" }) + @(if ("$($c.age)".Trim()) { & $minAgo $c.age })) -join '<span class=dot>·</span>')</div><div class=w>$(& $e $c.problem)</div>$(if ("$($c.action)".Trim()) { "<div class=n><b>Next</b> $(& $e $c.action)</div>" })</article>" }
  $info = @($flags | Where-Object level -eq 'INFO')
  $flagHtml = $(if ($nAct + $nWatch) { & $grid flags 340px @($flags | Where-Object level -in 'ACT', 'WATCH' | Sort-Object { $_.level -ne 'ACT' } | ForEach-Object { & $card $_ }) } else { '<p class=empty>No ACT or WATCH flags: all clear.</p>' }) +
    $(if ($info.Count) { & $grid info 280px @($info | ForEach-Object { "<li class=f>$(& $e $_.what)</li>" }) 0 ul })
  $byState = @($agents | Group-Object { & $stCls $_.state } | ForEach-Object { [pscustomobject]@{ cls = $_.Name; n = $_.Count; label = "$(@($_.Group)[0].state)" -replace '\s.*' } })
  $circ = 2 * [math]::PI * 38; $off = 0
  $arcs = @(foreach ($s in $byState) { $len = $circ * $s.n / [math]::Max(1, $agents.Count); "<circle class='val $($s.cls)' cx=50 cy=50 r=38 stroke-dasharray='$(& $n1 $len) $(& $n1 ($circ - $len))' stroke-dashoffset='$(& $n1 (-$off))' transform='rotate(-90 50 50)'><title>$(& $e $s.label): $($s.n)</title></circle>"; $off += $len })
  $donut = "<figure class=gauge><svg viewBox='0 0 100 92' role=img aria-label='agents by state'><circle class=trk cx=50 cy=50 r=38 />$($arcs -join '')<text x=50 y=50 class=gv>$($agents.Count)</text><text x=50 y=66 class=gl>agents</text></svg><figcaption>$(@($byState | ForEach-Object { "<span class='lg $($_.cls)'>$(& $e $_.label) $($_.n)</span>" }) -join ' ')</figcaption></figure>"
  $gauges = & $grid gauges 80px (@($(if ($tot) { & $ring (100 * $used / $tot) "$([int](100 * $used / $tot))%" 'RAM' "$(& $n1 $avail) GB free" } else { & $ring 0 '—' 'RAM' 'no sample' })) + @($(if ($disks.Count) { foreach ($dk in $disks) { $up = if ([double]$dk.total) { 100 - 100 * [double]$dk.free / [double]$dk.total }; & $ring ([double]$up) $(if ($null -ne $up) { "$([int]$up)%" } else { '—' }) "disk $($dk.drive)" "$(& $n1 $dk.free) GB free$(if (& $diskTone $dk.drive) { " · $($diskLv["$($dk.drive)"])" })" (& $diskTone $dk.drive 'act' 'watch') } } else { & $ring 0 '—' 'disk' 'no sample' })) + @($donut)) ([math]::Min(6, 2 + [math]::Max(1, $disks.Count)))
  # history: flags by level per sweep (stacked), oldest left
  $hMax = [math]::Max(1, (@($hist | ForEach-Object { (& $hCount $_ 'ACT') + (& $hCount $_ 'WATCH') + [int]$_.fixed }) + 0 | Measure-Object -Maximum).Maximum)
  $bw = 100 / [math]::Max(1, $hist.Count)
  $rects = @(for ($i = 0; $i -lt $hist.Count; $i++) { $h = $hist[$i]; $y = 60; $x = & $n1 ($i * $bw + $bw * 0.15); $w = & $n1 ($bw * 0.7)
    foreach ($seg in @(@('a', (& $hCount $h 'ACT')), @('w', (& $hCount $h 'WATCH')), @('x', [int]$h.fixed))) { if (-not $seg[1]) { continue }; $hh = 56 * $seg[1] / $hMax; $y -= $hh; "<rect class=$($seg[0]) x=$x y=$(& $n1 $y) width=$w height=$(& $n1 $hh) />" }
    "<rect class=hit x=$(& $n1 ($i * $bw)) y=0 width=$(& $n1 $bw) height=60><title>$(& $e $(try { ([datetime]$h.at).ToString('HH:mm') } catch { $h.at })): $(& $hCount $h 'ACT') ACT, $(& $hCount $h 'WATCH') WATCH, $([int]$h.fixed) fixed</title></rect>" })
  $histHtml = if ($hist.Count) { "<div class=hist><svg viewBox='0 0 100 60' preserveAspectRatio=none role=img aria-label='flags per sweep'>$($rects -join '')</svg><div class=ax><span>$(& $e $(try { ([datetime]$hist[0].at).ToString('HH:mm') } catch { '' }))</span><span><i class='lg act'>ACT</i> <i class='lg watch'>WATCH</i> <i class='lg sage'>FIXED</i></span><span>$(& $e $(try { ([datetime]$hist[-1].at).ToString('HH:mm') } catch { '' }))</span></div></div>" } else { '<p class=empty>No sweeps yet.</p>' }
  # agents by run; steps and tokens as bars
  $groups = @($agents | Group-Object { "$($_.run)" } | Sort-Object { -not @($_.Group | Where-Object state -ne 'FINISHED').Count }, { -not $_.Name }, Name)
  $agentHtml = if (-not $agents.Count) { '<p class=empty>No agents on the board.</p>' } else { '<div class=tw><table class=ag><tr><th>State</th><th>Agent</th><th class=hs>Task</th><th>Since</th><th>Last progress</th><th class=hs>Doing · next</th></tr>' + (@(foreach ($g in $groups) {
    $wf = @($g.Group | Where-Object { "$($_.name)" -like '* (workflow)' }) | Select-Object -First 1; $meta = "$($wf.task) $($wf.done)"
    $steps = if ($meta -match '(\d+)/(\d+) steps|steps (\d+)/(\d+)') { if ($Matches[1]) { [double]$Matches[1], [double]$Matches[2] } else { [double]$Matches[3], [double]$Matches[4] } }
    $toks = if ($meta -match '([\d.]+[kKmM]?) tokens of ([\d.]+[kKmM]?)') { $tk = $Matches[1], $Matches[2]; (& $big $tk[0]), (& $big $tk[1]), "$($tk[0]) of $($tk[1]) tokens" }
    "<tbody class=grp><tr class=gh><th colspan=6><span class=gn0>$(if ($g.Name) { & $e $g.Name } else { 'no run' })</span><span class=m> $($g.Count) agent(s) · $(@($g.Group | Where-Object state -ne 'FINISHED').Count) active</span>$(if ($steps) { & $bar $steps[0] $steps[1] "$($steps[0])/$($steps[1]) steps" 'sage' })$(if ($toks) { & $bar $toks[0] $toks[1] $toks[2] })</th></tr>" +
    (@(foreach ($a in @($g.Group | Sort-Object { $_.state -eq 'FINISHED' }, name)) { $sub = @($a.wait, $a.done, $a.stopped | Where-Object { "$_".Trim() }) -join ' · '
      "<tr class=f><td><span class='chip $(& $stCls $a.state)'>$(& $e ("$($a.state)" -replace '\s.*'))</span>$(if ($sub) { "<div class=sm>$(& $e $sub)</div>" })</td><td>$(& $e $a.name)</td><td class=hs>$(& $e $a.task)</td><td>$(& $when $a.since)</td><td>$(& $when $a.last)</td><td class=hs>$(& $e $a.doing)$(if ("$($a.next)".Trim()) { "<div class=sm>$(& $e $a.next)</div>" })</td></tr>" }) -join '') + '</tbody>' }) -join '') + '</table></div>' }
  $lanes = @($agents | ForEach-Object { $s0 = & $toTime $(if ($_.started) { $_.started } else { $_.since }); $s1 = if ($_.state -eq 'FINISHED') { & $toTime $(if ($_.last) { $_.last } else { $_.ended }) } else { $at }
    if ($s0 -and $s0.Date -eq $at.Date) { [pscustomobject]@{ a = $_; t0 = $s0; t1 = $(if ($s1 -and $s1 -gt $s0) { $s1 } else { $s0 }) } } } | Sort-Object t0 | Select-Object -Last 40)
  $ganttHtml = if (-not $lanes.Count) { '<p class=empty>No agent started today.</p>' } else {
    $g0 = $lanes[0].t0; $span = [math]::Max(30, ($at - $g0).TotalMinutes); $pos = { param($tx) & $n1 (100 * ($tx - $g0).TotalMinutes / $span) }
    $ticks = @(for ($tk0 = $g0.Date.AddHours($g0.Hour + 1); $tk0 -lt $at; $tk0 = $tk0.AddHours($(if ($span -gt 600) { 2 } else { 1 }))) { $tp = & $pos $tk0; "<span style='$(if ([double]$tp -gt 94) { 'right:0;transform:none' } else { "left:$tp%" })'>$($tk0.ToString('HH:mm'))</span>" })   # near the right edge: aligned inside, never past it
    '<div class=gantt>' + (@($lanes | ForEach-Object { $w0 = [math]::Max(0.4, 100 * ($_.t1 - $_.t0).TotalMinutes / $span); $tip = "$($_.a.name) · $($_.a.state) · $($_.t0.ToString('HH:mm'))-$($_.t1.ToString('HH:mm'))"
      "<div class='gr f'><span class=gl0 title='$(& $e $tip)'>$(& $e $_.a.name)</span><span class=gt><i class='gb $(& $stCls $_.a.state)' style='left:$(& $pos $_.t0)%;width:$(& $n1 $w0)%' title='$(& $e $tip)'></i></span></div>" }) -join '') + "<div class=gx>$($ticks -join '')</div></div>" }
  # statistics: today vs yesterday, 7 days vs the 7 before; '—' = no source
  $days = @($st.days | Where-Object { $_ }); $dayKey = { param([int]$back) $at.AddDays(-$back).ToString('yyyy-MM-dd') }
  $sumOf = { param([string]$key, [int[]]$backs) $vals = @(foreach ($b in $backs) { $rec = $days | Where-Object day -eq (& $dayKey $b) | Select-Object -First 1; if ($rec -and $null -ne $rec.$key) { [double]$rec.$key } }); if ($vals.Count) { ($vals | Measure-Object -Sum).Sum } }
  $wk = 0..6; $pw = 7..13
  $trend = { param($cur, $prev, [int]$Sense = 0) if ($null -eq $cur -or $null -eq $prev) { return '' }; $dv = [double]$cur - [double]$prev; if ([math]::Abs($dv) -lt 1e-9) { return '<span class="tr eq">= 0</span>' }   # Sense: 1 up is good, -1 up is bad, 0 neutral
    "<span class='tr $(if (-not $Sense) { 'eq' } elseif (($dv -gt 0) -eq ($Sense -gt 0)) { 'good' } else { 'bad' })'>$(if ($dv -gt 0) { '▲' } else { '▼' }) $(& $n1 ([math]::Abs($dv)))</span>" }
  $fmt = { param($v) if ($null -eq $v) { '—' } else { & $n1 $v } }
  $statCard = { param([string]$label, $t, $y, $w, $pv, [int]$Sense = 0, [string]$unit = '') "<div class=st><div class=k>$(& $e $label)</div><div class=v>$(& $fmt $t)<small>$unit</small>$(& $trend $t $y $Sense)</div><div class=w>7 days $(& $fmt $w)$unit $(& $trend $w $pv $Sense)</div></div>" }
  $avgOf = { param([int[]]$backs) $sm = & $sumOf 'durSum' $backs; $cn = & $sumOf 'durN' $backs; if ($cn) { [math]::Round($sm / $cn) } }
  $same = { param([string]$key) @($days | Where-Object { $null -ne $_.$key -and $_.day -in @($wk | ForEach-Object { & $dayKey $_ }) }).Count -eq @($days | Where-Object { $null -ne $_.$key -and $_.day -in @($pw | ForEach-Object { & $dayKey $_ }) }).Count }   # a week arrow only over equal logged days
  $card4 = { param([string]$label, [string]$key, [int]$Sense = 0) & $statCard $label (& $sumOf $key 0) (& $sumOf $key 1) (& $sumOf $key $wk) $(if (& $same $key) { & $sumOf $key $pw }) $Sense }
  $fxRaised = @($hist | ForEach-Object { (& $hCount $_ 'ACT') + (& $hCount $_ 'WATCH') + [int]$_.fixed }); $fxFixed = @($hist | ForEach-Object { [int]$_.fixed })
  $fxPct = { param([int]$from, [int]$to) $rs = 0; $fs = 0; for ($i = $from; $i -lt $to; $i++) { $rs += $fxRaised[$i]; $fs += $fxFixed[$i] }; if ($rs) { [math]::Round(100 * $fs / $rs) } }
  $half = [int][math]::Floor($hist.Count / 2)
  # this sweep (stats.now): value, change since the previous sample, 7 days of samples (stats.live)
  $nw = $st.now; $lv = @($st.live | Where-Object { $_ }); $pv = if ($lv.Count -ge 2) { $lv[-2] }
  $agg = { param([scriptblock]$pick, [string]$how) $vs = @($lv | ForEach-Object $pick | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }); if (-not $vs.Count) { return '—' }; $m = $vs | Measure-Object -Average -Maximum -Minimum; & $n1 $(if ($how -eq 'avg') { $m.Average } elseif ($how -eq 'min') { $m.Minimum } else { $m.Maximum }) }
  $nowCard = { param([string]$label, [string]$vHtml, [string]$sub, [string]$week, [string]$cls = '') "<div class='st $cls'><div class=k>$(& $e $label)</div><div class=v>$vHtml</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })<div class=w>$(& $e $week)</div></div>" }
  $nowHtml = if (-not $nw) { '' } else { $nst = @($nw.stale | Where-Object { $_ })
    '<h3>This sweep</h3>' + (& $grid stats 170px @(
    (& $nowCard 'Live agents' "$(& $fmt $nw.run)<small> running</small>$(& $trend $nw.run $pv.run)" "$(if ($null -ne $nw.total) { "$($nw.done) of $($nw.total) done · $(@($nw.wfs) -join ', ')" } else { 'no workflow running' })$(if ($nst.Count) { " · $($nst.Count) stale: $($nst -join ', ')" })" "7 days peak $(& $agg { $_.run } max) running" $(if ($nst.Count) { 'warn' })) +
    (& $nowCard 'Memory' "$(& $fmt $nw.mem)<small>% used</small>$(& $trend $nw.mem $pv.mem -1)" "$(& $fmt $nw.avail) GB available" "7 days avg $(& $agg { $_.mem } avg)% · peak $(& $agg { $_.mem } max)%" $(if ($nw.mem -ge 90) { 'hot' } elseif ($nw.mem -ge 75) { 'warn' })) +
    (& $nowCard 'Build gate' "$(& $fmt $nw.gr)<small> running · </small>$(& $fmt $nw.gq)<small> queued</small>$(& $trend $nw.gq $pv.gq -1)" "longest wait $(& $fmt $nw.gw) min" "7 days peak wait $(& $agg { $_.gw } max) min · queue $(& $agg { $_.gq } max)" $(if ($nw.gw -ge 30) { 'hot' } elseif ($nw.gq -ge 6) { 'warn' })) +
    (& $nowCard 'QA seats' "$(& $fmt $nw.seats)<small> / $(& $fmt $nw.seatsMax)</small>$(& $trend $nw.seats $pv.seats)" 'taken / fit in free RAM' "7 days peak $(& $agg { $_.seats } max) taken") +
    (@(foreach ($dk in @($nw.disks | Where-Object { $_ } | Sort-Object -Stable { $tz = & $diskTone $_.drive; if ($tz -eq 'hot') { 0 } elseif ($tz) { 1 } else { 2 } })) { $dv = "$($dk.drive)"; $ttf = if ($null -ne $dk.ttf -and [double]$dk.ttf -lt 72) { [double]$dk.ttf }   # full-in only under 72 h
      & $nowCard "Disk $dv" "$(& $fmt $dk.free)<small> GB free</small>$(& $trend $dk.free $(if ($pv.disks) { $pv.disks.$dv }) 1)" "$(if ([double]$dk.rate -ge 0) { '+' })$(& $n1 $dk.rate) GB/h$(if ($null -ne $ttf) { " · full in $(& $n1 $ttf) h" })" "7 days low $(& $agg { if ($_.disks) { $_.disks.$dv } } min) GB" $(if (& $diskTone $dv) { & $diskTone $dv } elseif ($null -eq $ttf) { '' } elseif ($ttf -lt 24) { 'hot' } else { 'warn' }) }) -join '') +
    $(if (($rr = @($st.repos.repos | Where-Object { $_ })).Count) { $sumR = { param($k) ($rr | ForEach-Object { [int]$_.$k } | Measure-Object -Sum).Sum }   # bossy.ps1 cleanup writes it
      & $nowCard 'Branches · worktrees' "$(& $sumR branches)<small> br · </small>$(& $sumR worktrees)<small> wt</small>" (@($rr | ForEach-Object { "$($_.repo) $($_.branches)/$($_.worktrees)" }) -join ' · ') "$(& $sumR removable) to clean · $(& $sumR kept) kept (unpushed, open, dirty) · cleanup $(try { ([datetime]$st.repos.at).ToString('MM-dd HH:mm') } catch { '?' })" $(if ((& $sumR removable) -gt 0) { 'warn' }) }) +
    (& $nowCard 'Sweep time' "$(& $fmt $nw.secs)<small> s</small>$(& $trend $nw.secs $pv.secs -1)" $nw.slow "7 days avg $(& $agg { $_.secs } avg) s · peak $(& $agg { $_.secs } max) s" 'lo'))) + '<h3>Today and 7 days</h3>' }
  $statsHtml = $nowHtml + (& $grid stats 170px @((& $card4 'Runs' 'runs') + (& $card4 'Agents spawned' 'spawned') + (& $card4 'Agents finished' 'finished' 1) + (& $card4 'Agents failed' 'failed' -1) +
    (& $statCard 'Avg agent duration' (& $avgOf 0) (& $avgOf 1) (& $avgOf $wk) $(if (& $same 'durN') { & $avgOf $pw }) 0 ' min') + (& $card4 'Deploys recorded' 'deploys') +
    (& $card4 'Decisions asked' 'asked') + (& $card4 'Decisions answered' 'answered' 1) + (& $card4 'Lessons recorded' 'lessons') +
    "<div class=st><div class=k>Flags auto-FIXED</div><div class=v>$(& $fmt (& $fxPct 0 $hist.Count))<small>%</small>$(if ($half) { & $trend (& $fxPct $half $hist.Count) (& $fxPct 0 $half) 1 })</div><div class=w>$(($fxFixed | Measure-Object -Sum).Sum) of $(($fxRaised | Measure-Object -Sum).Sum) flags, last $($hist.Count) sweeps</div></div>")) +
    (Format-KitUsageHtml $st.usage)
  $resMax = [math]::Max(0.01, (@($j.resources | ForEach-Object { [double]$_.gb }) + 0 | Measure-Object -Maximum).Maximum)
  $resHtml = if (-not @($j.resources | Where-Object { $_ }).Count) { '<p class=empty>No resource held.</p>' } else { & $grid res 260px @($j.resources | Where-Object { $_ } | Sort-Object { -[double]$_.gb } | ForEach-Object { & $item $_.name "$($_.by) · $(& $n1 $_.gb) GB" (& $bar ([double]$_.gb) $resMax '' 'slate') }) }
  $shellHtml = & $table 'PID', 'Owner', 'Age', 'State', 'Dir', 'Command', 'Next' @($j.shells | Where-Object { $_ } | ForEach-Object { , @($_.pid, $_.owner, @{ h = & $minAgo $_.age },$_.state, $_.dir, $_.cmd, $_.next) })
  $setRows = @(if ($st.settings) { $st.settings.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) } })
  $chg = @($st.changes | Where-Object { $_ }); [array]::Reverse($chg); $prm = @($st.params | Where-Object { $_ }); $hm = { param($x) if ($x) { try { ([datetime]$x).ToString('MM-dd HH:mm') } catch { "$x" } } else { '' } }   # '' keeps the cell: an empty result drops it from the row
  $setHtml = $(if ($chg.Count) { '<h3>Recent changes</h3>' + ((& $table 'When', 'Key', 'Context', 'From', 'To', 'Why' @($chg | ForEach-Object { , @((& $hm $_.at), $_.key, $_.ctx, $_.from, $_.to, $_.why) })) -replace '<tr class=f>', '<tr class="f hl">') }) +
    '<h3>Parameters</h3>' + (& $table 'Key', 'Context', 'Value', 'Source', 'Learned', 'Changed', 'Why' @($prm | ForEach-Object { , @($_.key, $_.ctx, $_.value, $_.source, $_.learned, (& $hm $_.changed), $_.why) })) +
    $(if ($setRows.Count) { '<h3>Config (supervise.*)</h3>' + (& $grid kv 240px @($setRows | ForEach-Object { & $item $_[0] "$(if ($null -eq $_[1]) { '' } elseif ($_[1] -is [string] -or $_[1] -is [ValueType]) { $_[1] } else { $_[1] | ConvertTo-Json -Compress -Depth 4 })" })) })
  $css = Get-KitSupervisePageCss
  $fav = if ($mark) { "<link rel=icon href='data:image/svg+xml,$([Uri]::EscapeDataString($mark))'>" }
  $js = "(function(){var d=document,L=localStorage,S=sessionStorage,r=d.documentElement,a=d.getElementById('age'),t=new Date(a.dataset.at),n=+a.dataset.next||15,nx=d.getElementById('nx'),same=S.getItem('kc-at')==a.dataset.at;S.setItem('kc-at',a.dataset.at);" +   # same: a reload brought no new sweep
    "function ag(m){return m<1?'now':m<60?m+' min':m<1440?Math.floor(m/60)+' h '+m%60+' min':Math.floor(m/1440)+' d'}function u(){var w=Date.now(),m=Math.round((w-t)/6e4),o=Math.round((t-w)/6e4+n);a.textContent='updated '+(m<1?'just now':m<60?m+' min ago':m<2880?Math.round(m/60)+' h ago':Math.round(m/1440)+' d ago');a.className='chip '+(m>4*n?'bad':m>2*n?'warn':'ok');" +
    "nx.textContent='Next sweep '+nx.dataset.due+' ('+(o>0?'in '+ag(o):(same?'waiting for it':'due now')+(o<0?', overdue '+ag(-o):''))+')'+nx.dataset.tail;d.querySelectorAll('.ago').forEach(function(e){e.textContent=ag(Math.max(0,Math.round((w-new Date(e.dataset.t))/6e4)))})}u();setInterval(u,1e4);" +
    "d.getElementById('tt').onclick=function(){var k=r.dataset.theme?r.dataset.theme=='dark':matchMedia('(prefers-color-scheme: dark)').matches;r.dataset.theme=k?'light':'dark';L.setItem('kc-theme',r.dataset.theme)};" +
    "var ar=d.getElementById('ar'),on=L.getItem('kc-ar')!=='0',tm;function sa(){ar.setAttribute('aria-pressed',on);ar.textContent=on?'Auto-refresh 60 s':'Auto-refresh off';clearTimeout(tm);if(on)tm=setTimeout(function(){var p={};d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){if(e.scrollTop||e.scrollLeft)p[s.id+i]=[e.scrollTop,e.scrollLeft]})});S.setItem('kc-sp',JSON.stringify(p));S.setItem('kc-y',scrollY);location.reload()},6e4)}ar.onclick=function(){on=!on;L.setItem('kc-ar',on?'1':'0');sa()};sa();" +
    "var cl=JSON.parse(L.getItem('kc-closed')||'[]');d.querySelectorAll('details.sec').forEach(function(s){if(cl.indexOf(s.id)>=0)s.open=false;s.addEventListener('toggle',function(){var c=JSON.parse(L.getItem('kc-closed')||'[]').filter(function(x){return x!=s.id});if(!s.open)c.push(s.id);L.setItem('kc-closed',JSON.stringify(c))})});" +
    "var q=d.getElementById('q');function fl(){var v=q.value.toLowerCase();S.setItem('kc-q',q.value);d.querySelectorAll('.f').forEach(function(x){x.hidden=!!v&&x.textContent.toLowerCase().indexOf(v)<0});d.querySelectorAll('tbody.grp').forEach(function(g){g.hidden=!g.querySelector('tr.f:not([hidden])')})}q.oninput=fl;q.value=S.getItem('kc-q')||'';if(q.value)fl();d.addEventListener('keydown',function(x){if(x.key=='/'&&d.activeElement!=q){x.preventDefault();q.focus()}});" +
    "var SC='.bd,.info,.tw,.sy';function cu(e){var v=e.scrollHeight>e.clientHeight+1,h=e.scrollWidth>e.clientWidth+1,c=e.classList,o=v||h;c.toggle('sc',o);if(o)e.tabIndex=0;else e.removeAttribute('tabindex');c.toggle('u',v&&e.scrollTop>1);c.toggle('d',v&&e.scrollTop+e.clientHeight<e.scrollHeight-1);c.toggle('l',h&&e.scrollLeft>1);c.toggle('r',h&&e.scrollLeft+e.clientWidth<e.scrollWidth-1)}" +
    "function ca(){d.querySelectorAll(SC).forEach(cu)}ca();addEventListener('resize',ca);d.addEventListener('toggle',ca,true);q.addEventListener('input',ca);" +
    "var tp=d.createElement('div');tp.id='tip';tp.setAttribute('role','tooltip');tp.hidden=true;d.body.appendChild(tp);" +
    "function sh(el){var s=el&&(el.getAttribute('title')||(el.querySelector(':scope>title')||{}).textContent);if(!s){tp.hidden=true;return}tp.textContent=s;tp.hidden=false;var b=el.getBoundingClientRect(),w=tp.offsetWidth,g=tp.offsetHeight;tp.style.left=Math.max(4,Math.min(innerWidth-w-4,b.left))+'px';tp.style.top=(b.bottom+g+6>innerHeight?b.top-g-6:b.bottom+6)+'px'}" +
    "d.addEventListener('scroll',function(x){var e=x.target;if(e.matches&&e.matches(SC))cu(e);tp.hidden=true},true);" +   # touch has no hover: a tap shows the title
    "d.addEventListener('click',function(x){sh(x.target.closest('button')?null:x.target.closest('[title],.hit,circle.val'))});" +
    "d.addEventListener('focusin',function(x){sh(x.target.closest('button')?null:x.target.closest('[title]'))});" +
    "var sp=JSON.parse(S.getItem('kc-sp')||'{}'),y=S.getItem('kc-y');S.removeItem('kc-sp');S.removeItem('kc-y');d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){var v=sp[s.id+i];if(v){e.scrollTop=v[0];e.scrollLeft=v[1]}})});ca();if(y)scrollTo(0,+y)})()"   # after collapse + filter: the layout is final
  $head = "<header class=top><div class=brand>$mark<span>claude-crew</span><small>Supervisor</small></div><div class=meta><span>Last sweep <b>$($at.ToString('yyyy-MM-dd HH:mm'))</b></span><span id=age class=chip data-at='$($at.ToString('o'))' data-next='$(& $e $nextMin)'></span><span id=nx title='$(& $e $j.next)' data-due='$($at.AddMinutes([double]$nextMin).ToString('HH:mm'))' data-tail='$(& $e $nxTail)'>Next sweep $($at.AddMinutes([double]$nextMin).ToString('HH:mm'))$(& $e $nxTail)</span></div><div class=sp></div>" +
    "<div class=tb><input id=q type=search placeholder='Filter flags and agents  ( / )' aria-label='Filter flags and agents'><button id=ar type=button aria-pressed=true>Auto-refresh 60 s</button><button id=tt type=button aria-label='Toggle theme' title='Toggle theme'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z' fill=currentColor /></svg></button></div></header>"
  $main = "<main class=wrap>$kpi<div class=cols><div>$(& $section 'flags' 'Flags' ($nAct + $nWatch) $flagHtml)</div><div>$(& $section 'health' 'Machine' $null $gauges)$(& $section 'history' "Last $($hist.Count) sweeps" $null $histHtml)$(& $section 'resources' 'Resources and leases' @($j.resources | Where-Object { $_ }).Count $resHtml)</div></div>" +
    (& $section 'agents' 'Agents' $agents.Count $agentHtml) + (& $section 'shells' 'Shells' @($j.shells | Where-Object { $_ }).Count $shellHtml) +   # full width: 7 wrapping columns never fit the side column
    (& $section 'timeline' 'Today' $lanes.Count $ganttHtml) + (& $section 'stats' 'Statistics' $null $statsHtml) +
    (& $section 'settings' 'Settings' ($prm.Count + $setRows.Count) $setHtml -Closed) +
    "<footer>Written by bossy.ps1 supervise each sweep (no model tokens) · data: supervise-report.json</footer></main>"
  "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><noscript><meta http-equiv=refresh content=60></noscript><title>Supervisor $($at.ToString('HH:mm'))$(if ($nAct) { " · $nAct ACT" })</title>$fav<style>$css</style><script>try{var t=localStorage.getItem('kc-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script></head><body>$head$main<script>$js</script></body></html>"
}
# page CSS: muted sage palette, light / dark (prefers-color-scheme; data-theme overrides)
function Get-KitSupervisePageCss {
  $dark = '--bg:#0c0c0c;--sf:#161b16;--sf2:#212a21;--fg:#d8dee9;--mt:#8a948a;--ln:#2e3a2e;--sage:#79a86a;--sage2:#9fd48c;--act:#dc9089;--watch:#e0ce8a;--slate:#8fbbd4;--plum:#c495d4;--sh:0 4px 20px rgba(0,0,0,0.45)'
  ':root{--bg:#f4f7f4;--sf:#ffffff;--sf2:#eaefea;--fg:#1a221a;--mt:#5e6c5e;--ln:#d5dfd5;--sage:#647c64;--sage2:#79a86a;--act:#ce8f8a;--watch:#c4b06a;--slate:#5f93a8;--plum:#a074b0;--sh:0 1px 3px rgba(26,34,26,.06),0 1px 2px rgba(26,34,26,.04)}' +
  "[data-theme=dark]{$dark}@media(prefers-color-scheme:dark){:root:not([data-theme=light]){$dark}}" +
  # no scrollbars (owner 2026-11-09): wheel, touch and keys still scroll; JS marks overflowing boxes .sc and the edges with more content (u d l r) -> faded by the mask
  '*{box-sizing:border-box;scrollbar-width:none}::-webkit-scrollbar{display:none}html{touch-action:manipulation}.sc{overscroll-behavior:contain;-webkit-overflow-scrolling:touch;--u:0px;--d:0px;--l:0px;--r:0px;mask:linear-gradient(#0000,#000 var(--u),#000 calc(100% - var(--d)),#0000),linear-gradient(90deg,#0000,#000 var(--l),#000 calc(100% - var(--r)),#0000);mask-composite:intersect}' +
  '.sc.u{--u:28px}.sc.d{--d:28px}.sc.l{--l:28px}.sc.r{--r:28px}.sc:focus-visible{outline:2px solid var(--sage);outline-offset:-2px}' +
  '#tip{position:fixed;z-index:9;max-width:min(360px,90vw);padding:6px 9px;border-radius:8px;background:var(--fg);color:var(--bg);font-size:12px;box-shadow:var(--sh);pointer-events:none;word-break:break-word}' +
  'body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Inter",sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}' +
  'b{font-weight:600}.m,.sm{color:var(--mt)}.sm{font-size:11.5px;margin-top:2px}h3{font-size:12px;font-weight:600;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;margin:20px 0 8px}' +
  'header.top{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;padding:10px 24px;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--ln)}' +
  '.brand{display:flex;align-items:center;gap:10px;font-weight:650;font-size:15px;letter-spacing:-.01em}.brand svg{width:28px;height:28px;flex:none}.brand small{color:var(--mt);font-weight:500;font-size:13px;padding-left:10px;border-left:1px solid var(--ln)}' +
  '.meta{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;color:var(--mt);font-size:12.5px}.meta b{color:var(--fg)}.sp{flex:1}' +
  'input[type=search]{font:inherit;font-size:12.5px;color:var(--fg);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;width:clamp(150px,18vw,260px);outline:none}.tb{display:flex;gap:8px}input[type=search]:focus{border-color:var(--sage)}' +
  'input[type=search],button{min-height:40px}button{min-width:40px;justify-content:center;font:inherit;font-size:12px;color:var(--mt);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;cursor:pointer;display:inline-flex;align-items:center}button:hover{color:var(--fg)}button[aria-pressed=true]{color:var(--sage2)}' +
  '.chip{display:inline-flex;align-items:center;gap:5px;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;letter-spacing:.03em;background:var(--sf2);color:var(--mt);white-space:nowrap}.chip::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;opacity:.85}' +
  '.chip.ok,.s-act{color:var(--sage2);background:color-mix(in srgb,var(--sage) 17%,transparent)}.chip.warn,.s-oth,.lv.WATCH{color:var(--watch);background:color-mix(in srgb,var(--watch) 16%,transparent)}.chip.bad,.s-stuck,.lv.ACT{color:var(--act);background:color-mix(in srgb,var(--act) 15%,transparent)}.s-fin{color:var(--slate);background:color-mix(in srgb,var(--slate) 14%,transparent)}' +
  '.wrap{max-width:1680px;margin:0 auto;padding:20px 24px 40px}.kpis,.stats{--cgap:12px}.gauges{--cgap:8px}.cg{display:grid;gap:var(--cgap,10px);grid-template-columns:repeat(auto-fill,minmax(min(100%,max(var(--cmin,200px),calc((100% - (var(--cmax,99) - 1) * var(--cgap,10px)) / var(--cmax,99)))),1fr))}' +
  '.tile,details.sec{background:var(--sf);border:1px solid var(--ln);border-radius:12px;box-shadow:var(--sh)}.tile{padding:14px 16px 10px;min-width:0}.tile .k,.st .k{font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.07em;font-weight:600}' +
  '.tile .v{font-size:24px;font-weight:620;letter-spacing:-.02em;margin-top:2px;overflow-wrap:anywhere}.tile .s{font-size:12px;color:var(--mt);overflow-wrap:anywhere}.tile.hot{border-color:color-mix(in srgb,var(--act) 45%,var(--ln))}.tile.hot .v{color:var(--act)}.tile.warn{border-color:color-mix(in srgb,var(--watch) 45%,var(--ln))}.tile.warn .v{color:var(--watch)}' +
  '.spark{display:block;width:100%;height:28px;margin-top:8px}.spark .l{fill:none;stroke:currentColor;stroke-width:1.6;vector-effect:non-scaling-stroke;stroke-linejoin:round}.spark .a{fill:currentColor;opacity:.12}' +
  '.sage{color:var(--sage)}.act{color:var(--act)}.watch{color:var(--watch)}.slate{color:var(--slate)}' +
  '.cols{display:grid;grid-template-columns:minmax(0,1.7fr) minmax(0,1fr);gap:0 16px}@media(max-width:1100px){.cols{grid-template-columns:minmax(0,1fr)}}@media(min-width:700px) and (max-width:1100px){.cols>div:last-child{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 16px;align-items:start}#sec-resources{grid-column:1/-1}}' +   # tablet: side sections 2 across, resources full width
  # fixed heights (owner 2026-11-09): flags fill the right column (44px = one-line summary); bodies scroll; content never truncates, it wraps (owner 2026-11-10)
  '.cols>div:first-child{position:relative;min-height:420px}#sec-flags{position:absolute;inset:0;top:16px;margin:0}#sec-flags:not([open]){bottom:auto}#sec-flags .bd{position:absolute;inset:44px 0 0;overflow-y:auto}' +
  '#sec-resources .bd,#sec-shells .bd{max-height:clamp(150px,30dvh,320px);overflow-y:auto}' +
  '#sec-shells table,#sec-settings table{table-layout:fixed;min-width:0}#sec-settings th:last-child:nth-child(n+6){width:30%}tr.hl td{background:color-mix(in srgb,var(--sage) 12%,transparent)}#sec-shells th:nth-child(1){width:64px}#sec-shells th:is(:nth-child(3),:nth-child(4)){width:76px}' +   # fixed layout, wrapping cells: no horizontal scroll at 1366 px
  '@media(max-width:1100px){.cols>div:first-child{min-height:0}#sec-flags,#sec-flags .bd{position:static;margin-top:16px}#sec-flags .bd{margin:0;max-height:clamp(240px,60dvh,640px)}}' +
  'details.sec{margin-top:16px}summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:8px;padding:12px 16px;min-height:44px;user-select:none}summary::-webkit-details-marker{display:none}' +
  'summary h2{margin:0;font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:.07em}summary::after{content:"";margin-left:auto;width:7px;height:7px;border-right:1.5px solid var(--mt);border-bottom:1.5px solid var(--mt);transform:rotate(45deg);transition:transform .15s}details:not([open])>summary::after{transform:rotate(-45deg)}' +
  '.cnt{font-size:11px;color:var(--mt);background:var(--sf2);border-radius:999px;padding:0 7px}.bd{padding:0 16px 16px}' +
  '.flag{border:1px solid var(--ln);border-left:3px solid var(--watch);border-radius:8px;padding:10px 12px;margin-bottom:8px}.flag.ACT{border-left-color:var(--act);background:color-mix(in srgb,var(--act) 5%,var(--sf))}' +
  '.flag .h{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--mt)}.flag .w{margin:6px 0 4px;word-break:break-word}.flag .n{font-size:12.5px;color:var(--mt);word-break:break-word}.flag .n b{color:var(--sage2);margin-right:4px}.dot{opacity:.5}' +
  '.info{list-style:none;margin:12px 0 0;padding:0;font-size:12.5px;color:var(--mt);max-height:clamp(160px,40dvh,360px);overflow-y:auto}.info li{padding:4px 0 4px 14px;position:relative;word-break:break-word}.info li::before{content:"";position:absolute;left:2px;top:11px;width:5px;height:5px;border-radius:50%;background:var(--sage)}' +
  '.empty{margin:0;padding:18px;text-align:center;color:var(--mt);border:1px dashed var(--ln);border-radius:8px;font-size:12.5px}' +
  '.gauge{margin:0;text-align:center}.gauge svg{width:100%;max-width:140px}.gauge circle{fill:none;stroke-width:6.5;stroke-linecap:round}.gauge .trk{stroke:var(--sf2)}.gauge .val{stroke:currentColor}' +
  '.gauge circle.s-act{stroke:var(--sage)}.gauge circle.s-fin{stroke:var(--slate)}.gauge circle.s-stuck{stroke:var(--act)}.gauge circle.s-oth{stroke:var(--watch)}.gauge circle[stroke-dashoffset]{stroke-linecap:butt}' +
  '.gv{font-size:17px;font-weight:650;fill:var(--fg);text-anchor:middle;dominant-baseline:middle}.gl{font-size:8.5px;fill:var(--mt);text-anchor:middle;text-transform:uppercase;letter-spacing:.08em}figcaption{font-size:11.5px;color:var(--mt)}' +
  '.lg{font-style:normal;font-size:11px;background:none}.lg::before{content:"";display:inline-block;width:8px;height:8px;border-radius:2px;background:currentColor;margin-right:4px;vertical-align:0}' +
  '.hist svg{display:block;width:100%;height:84px}.hist .a{fill:var(--act)}.hist .w{fill:var(--watch)}.hist .x{fill:var(--sage)}.hist .hit{fill:transparent}.hist .hit:hover{fill:color-mix(in srgb,var(--fg) 6%,transparent)}.ax{display:flex;justify-content:space-between;gap:8px;font-size:11px;color:var(--mt);margin-top:6px}' +
  '.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:12.5px}th{text-align:left;font-weight:600;font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;padding:6px 8px;border-bottom:1px solid var(--ln);overflow-wrap:break-word}' +   # headers break between words only: their longest word sets the column's min width
  'td{padding:7px 8px;border-bottom:1px solid var(--ln);vertical-align:top;overflow-wrap:anywhere}tr:last-child td{border-bottom:0}tr.f:hover td{background:color-mix(in srgb,var(--sf2) 55%,transparent)}' +
  'tr.gh th{background:var(--sf2);color:var(--fg);text-transform:none;letter-spacing:0;white-space:normal;font-size:12.5px;padding:7px 8px;border-radius:0}.gn0{font-weight:650}' +
  '.bar{display:inline-block;width:88px;height:6px;border-radius:3px;background:var(--sf2);overflow:hidden;vertical-align:middle;margin:0 6px 0 12px}.bar i{display:block;height:100%;border-radius:3px;background:var(--sage)}.bar i.watch{background:var(--watch)}.bar i.slate{background:var(--slate)}.bar i.act{background:var(--act)}.bl{font-size:11.5px;color:var(--mt);font-weight:500}' +
  'td .bar{margin-left:0}.gantt{font-size:12px}.gr{display:grid;grid-template-columns:170px minmax(0,1fr);gap:10px;align-items:center;min-height:20px}.gl0{color:var(--mt);overflow-wrap:anywhere}' +
  '.gt{position:relative;height:8px;background:var(--sf2);border-radius:4px;overflow:hidden}.gb{position:absolute;top:0;bottom:0;border-radius:4px;min-width:3px}.gb.s-act{background:var(--sage)}.gb.s-fin{background:var(--slate)}.gb.s-stuck{background:var(--act)}.gb.s-oth{background:var(--watch)}' +
  '.gx{position:relative;height:18px;margin:4px 0 0 180px;font-size:10.5px;color:var(--mt)}.gx span{position:absolute;transform:translateX(-50%);white-space:nowrap}' +
  '.st{border:1px solid var(--ln);border-radius:10px;padding:12px 14px}.st .v{font-size:21px;font-weight:620;letter-spacing:-.01em;margin-top:2px}.st .v small{font-size:12px;color:var(--mt);font-weight:500}' +
  '.st .w,.st .s{font-size:12px;color:var(--mt)}.st .s,.st .w,.st .v{overflow-wrap:anywhere}.st.warn{border-color:color-mix(in srgb,var(--watch) 50%,var(--ln))}.st.warn .v{color:var(--watch)}.st.hot{border-color:color-mix(in srgb,var(--act) 50%,var(--ln))}.st.hot .v{color:var(--act)}.st.lo .v{font-size:16px}' +
  '.tr{font-size:11.5px;font-weight:600;margin-left:8px;letter-spacing:0}.tr.good{color:var(--sage2)}.tr.bad{color:var(--act)}.tr.eq{color:var(--mt)}' +
  '.ci{border:1px solid var(--ln);border-radius:10px;padding:8px 12px;min-width:0}.ci .sm,.tn{overflow-wrap:anywhere}.ci .bar{display:block;width:100%;margin:6px 0 2px}.bl:empty{display:none}.flags .flag{margin:0}' +
  'footer{margin-top:24px;text-align:center;font-size:11.5px;color:var(--mt)}[hidden]{display:none!important}' +
  # Usage: fixed-height scroll boxes (sticky header), runs collapsed to one line, the chart's past days slate
  'h4{font-size:11.5px;font-weight:600;color:var(--mt);margin:14px 0 6px}.sy{max-height:clamp(200px,42dvh,440px);overflow:auto}.sy>.tw{overflow:visible}.sy th{position:sticky;top:0;z-index:1;background:var(--sf)}.sy td{white-space:nowrap}.sy td:first-child{white-space:normal}td{font-variant-numeric:tabular-nums}.hist .w0{fill:var(--slate)}' +
  '.ru{border:1px solid var(--ln);border-radius:10px;margin:0 0 6px}.ru>summary{display:flex;flex-wrap:wrap;align-items:center;gap:4px 10px;padding:7px 10px;background:var(--sf2);border-radius:10px;font-size:12.5px;cursor:pointer}.ru[open]>summary{border-radius:10px 10px 0 0}.ru>summary .bar{margin:0}.ru>.sy{padding:0 4px 4px}' +
  '.tw>table:not(.ag){min-width:520px}@media(max-width:640px){.wrap{padding:12px}.stats{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.st{padding:10px}header.top{padding:8px 12px;position:static}.hs{display:none}.tb{width:100%}input[type=search]{flex:1;width:auto}.gr{grid-template-columns:96px minmax(0,1fr)}.gx{margin-left:106px}.gx span:nth-child(even){display:none}.tile .v{font-size:20px}.gauges{grid-template-columns:repeat(3,minmax(0,1fr))}' +
  # phone: a table row = a card, one "header value" line per cell (7 columns never fit 390 px)
  '.tw>table:not(.ag){min-width:0}.tw>table:not(.ag) tr:first-child{display:none}.tw>table:not(.ag),.tw>table:not(.ag) :is(tbody,tr,td){display:block;width:auto}.tw>table:not(.ag) tr{border-bottom:1px solid var(--ln);padding:6px 0}' +
  '.tw>table:not(.ag) td{border:0;padding:2px 8px;display:grid;grid-template-columns:88px minmax(0,1fr);gap:8px}.tw>table:not(.ag) td::before{content:attr(data-k);color:var(--mt);font-size:11px;text-transform:uppercase;letter-spacing:.06em}}'
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

# ---- usage: tokens, cost, time per run, step, role, model (Statistics "Usage"); transcripts parsed incrementally, cached
# one transcript's totals since its last read offset (append-only files); Claude: per message id (a message repeats per content block), Codex: last cumulative count
function Update-KitUsageFile([string]$Path, $Rec, [ref]$Left) {
  $fi = [IO.FileInfo]::new($Path); if (-not $fi.Exists) { return $Rec }
  if (-not $Rec -or $null -eq $Rec.days -or [long]$Rec.off -gt $fi.Length) { $Rec = [ordered]@{ off = 0L; in = 0L; out = 0L; cr = 0L; cw = 0L; n = 0; tools = 0; model = ''; t0 = ''; t1 = ''; lastId = ''; lastU = @(0, 0, 0, 0); days = @{} } }
  $n = [int][math]::Min([math]::Min($fi.Length - [long]$Rec.off, [math]::Max([long]0, [long]$Left.Value)), [long]256MB); if ($n -le 0) { return $Rec }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
  try { $null = $fs.Seek([long]$Rec.off, 'Begin'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  if ($got -le 0) { return $Rec }; $end = [Array]::LastIndexOf($b, [byte]10, $got - 1); if ($end -lt 0) { return $Rec }   # no whole line yet; shrunk meanwhile
  $Left.Value -= $end + 1; $Rec.off = [long]$Rec.off + $end + 1
  $num = { param($l, [string]$k) $m = [regex]::Match($l, """$k"":(\d+)"); if ($m.Success) { [long]$m.Groups[1].Value } else { 0L } }
  foreach ($l in [Text.Encoding]::UTF8.GetString($b, 0, $end).Split([char]10)) {
    $ts = [regex]::Match($l, '"timestamp":"([^"]+)"'); if ($ts.Success) { if (-not $Rec.t0) { $Rec.t0 = $ts.Groups[1].Value }; $Rec.t1 = $ts.Groups[1].Value }
    if ($l.Contains('"total_token_usage"')) {   # codex rollout: cumulative
      $m = [regex]::Match($l, '"total_token_usage":\{([^}]*)\}'); if ($m.Success) { $u = $m.Groups[1].Value; $Rec.cr = & $num $u 'cached_input_tokens'; $Rec.in = (& $num $u 'input_tokens') - $Rec.cr; $Rec.out = & $num $u 'output_tokens'; $Rec.n++ }; continue }
    if (-not $l.Contains('"usage"') -or -not $l.Contains('"assistant"')) { continue }
    $Rec.tools += ([regex]::Matches($l, '"type":"tool_use"')).Count
    $md = [regex]::Match($l, '"model":"([^"]+)"'); if ($md.Success -and $md.Groups[1].Value -ne '<synthetic>') { $Rec.model = $md.Groups[1].Value }
    $uu = @((& $num $l 'input_tokens'), (& $num $l 'output_tokens'), (& $num $l 'cache_read_input_tokens'), (& $num $l 'cache_creation_input_tokens'))
    $id = [regex]::Match($l, '"id":"(msg_[^"]+)"').Groups[1].Value
    if ($id -and $id -eq $Rec.lastId) { $p = @($Rec.lastU) } else { $p = @(0, 0, 0, 0); $Rec.n++ }
    $Rec.in += $uu[0] - $p[0]; $Rec.out += $uu[1] - $p[1]; $Rec.cr += $uu[2] - $p[2]; $Rec.cw += $uu[3] - $p[3]; $Rec.lastId = $id; $Rec.lastU = $uu
    if ($ts.Success) { if ($null -eq $Rec.days) { $Rec.days = @{} }; $dk = ([datetimeoffset]$ts.Groups[1].Value).LocalDateTime.ToString('yyyy-MM-dd'); $Rec.days[$dk] = [long]$Rec.days[$dk] + ($uu | Measure-Object -Sum).Sum - ($p | Measure-Object -Sum).Sum }   # tokens by the day they were spent
  }
  $Rec
}
# USD per million tokens [input, output, cache read, cache write] by model-name part (budget.prices); unknown model: $null
function Get-KitUsageCost($R, [string]$Model) {
  $pr = Get-KitSetting 'budget.prices' $null; if (-not $pr) { if ($null -eq $script:KitPrices) { $script:KitPrices = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget.prices }; $pr = $script:KitPrices }; if (-not $pr) { return $null }
  $hit = @($pr.PSObject.Properties | Where-Object { $_.Name -notlike '_*' -and $Model -like "*$($_.Name)*" })[0]; if (-not $hit) { return $null }
  $v = @($hit.Value | ForEach-Object { [double]$_ }); ([double]$R.in * $v[0] + [double]$R.out * $v[1] + [double]$R.cr * $v[2] + [double]$R.cw * $v[3]) / 1e6
}
# budget -Usage: supervise runs it in the background each sweep; the page reads its cache
function Show-KitUsage([double]$Seconds, [bool]$Json) {
  $u = Get-KitUsage -Seconds $Seconds; $d0 = @($u.days)[-1]
  if ($Json) { $u | ConvertTo-Json -Depth 8 -Compress; return }
  "usage: today $($d0.tok) tokens$(if ($null -ne $d0.cost) { ", est. `$$($d0.cost)" }); 7 days $(($u.days | Measure-Object tok -Sum).Sum) tokens, $(@($u.runs).Count) run(s), $((@($u.bg) | Measure-Object n -Sum).Sum) agent(s) outside workflows$(if ($u.partial) { '; transcripts still being read (run again)' })"
}
function Get-KitPct($Vals, [double]$P) { $s = @($Vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($P * $s.Count))] }
# runs, steps, background agents of the last $Days days; parses for at most $Seconds (the cache keeps offsets: the rest next call); stored with the result
function Get-KitUsage([datetime]$Now = (Get-Date), [int]$Days = 7, [double]$Seconds = 60) {
  $cf = Get-KitPath usage-cache -Create; $cache = try { (Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable).files } catch { $null }; if ($cache -isnot [hashtable]) { $cache = @{} }
  $root = (Invoke-KitAdapter transcript claude root).dir; $since = $Now.AddDays(-$Days); $stop = (Get-Date).AddSeconds($Seconds); $left = [ref][long]2GB; $seen = @{}
  $read = { param([string]$f) $seen[$f] = 1; try { if ((Get-Date) -lt $stop -and $left.Value -gt 0) { $cache[$f] = Update-KitUsageFile $f $cache[$f] $left }; if ([IO.FileInfo]::new($f).Length -gt [long]$cache[$f].off + 64KB) { $script:KitUsagePartial = $true } } catch { }; $cache[$f] }   # a vanished file: its last totals; a half-written line is no backlog
  $script:KitUsagePartial = $false
  $lk = "$cf.lock"; if ((Test-Path -LiteralPath $lk) -and ((Get-Date) - [IO.File]::GetLastWriteTime($lk)).TotalMinutes -gt 10) { Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }   # a killed run's
  try { $lkh = [IO.File]::Open($lk, 'CreateNew', 'Write', 'None') } catch { return (Read-KitUsageResult) }   # another run reads: its last result
  try {
  $meta = { param([string]$f) try { Get-Content -LiteralPath ($f -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
  $mins = { param($r) if ($r.t0 -and $r.t1) { [math]::Round(([datetimeoffset]$r.t1 - [datetimeoffset]$r.t0).TotalMinutes, 1) } }
  $tot = { param($r) [long]$r.in + [long]$r.out + [long]$r.cr + [long]$r.cw }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $stuck = [double](Get-KitParam 'supervise.stuckMinutes')
  $runs = [Collections.Generic.List[object]]::new(); $steps = [Collections.Generic.List[object]]::new(); $bg = @{}
  foreach ($sd in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {   # no age filter: a session folder keeps its creation time while its runs go on for days
    $sub = Join-Path $sd.FullName 'subagents'; if (-not (Test-Path -LiteralPath $sub)) { continue }
    foreach ($w in @(Get-ChildItem -LiteralPath (Join-Path $sub 'workflows') -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {
      $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path -LiteralPath $j)) { continue }
      $ev = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x.result }
      $rec = @(Get-KitWorkflowRecords $w $ev $launch); $name = @(@($rec | ForEach-Object run) + $w.Name | Where-Object { $_ })[0]; $cap = @($rec.cap | Where-Object { $_ })[0]; $spent = @($rec.spent | Where-Object { $_ })[0]
      $live = -not (Get-KitWorkflowStop $w $rec) -and -not @($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count
      $labels = @{}; $noRes = @{}; $rs = [Collections.Generic.List[object]]::new()
      foreach ($s in @($ev | Where-Object type -eq 'started')) {
        $f = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; if (-not (Test-Path -LiteralPath $f)) { continue }
        $u = & $read $f; $m = & $meta $f; $lb = [string]$s.label; $labels[$lb] = 1 + [int]$labels[$lb]
        $r = $res[$s.agentId]; $age = ($Now - [IO.File]::GetLastWriteTime($f)).TotalMinutes
        $out = if ($r) { if ($r.error) { 'fail' } elseif (-not "$($r.summary)$($r.output)".Trim() -and -not @($r.mrs).Count) { 'empty' } else { 'pass' } } elseif ($live -and $age -lt $stuck) { 'running' } elseif ($live) { 'stuck' } else { 'stopped' }
        $model = if ($u.model) { $u.model } else { "$($m.model)" }
        $st = [pscustomobject]@{ run = $name; label = $lb; type = (($lb -split ':')[0] -creplace '-[A-Z][\w-]*$'); role = "$($m.agentType)"; model = $model; in = [long]$u.in; out = [long]$u.out; cr = [long]$u.cr; cw = [long]$u.cw; tok = (& $tot $u); cost = (Get-KitUsageCost $u $model)
          min = (& $mins $u); tools = [int]$u.tools; result = $out; round = $labels[$lb]; retry = [int]$noRes[$lb]; days = $u.days; at = $(if ($u.t1) { ([datetimeoffset]$u.t1).LocalDateTime.ToString('o') } else { [IO.File]::GetLastWriteTime($f).ToString('o') }); mrs = @($r.mrs | Where-Object merged | ForEach-Object { "$(if ($_.url) { $_.url } else { $_.ref })" }) }
        if (-not $r) { $noRes[$lb] = 1 + [int]$noRes[$lb] }; $rs.Add($st); $steps.Add($st) }   # retry: earlier starts of the label with no result
      if (-not $rs.Count) { continue }
      $items = @(@($rec | ForEach-Object { $_.args.agents }) | ForEach-Object { "$($_.items)" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique).Count
      $runs.Add([pscustomobject]@{ run = $name; id = $w.Name; status = $(if ($live) { 'running' } else { 'ended' }); cap = [long]$cap; spent = [long]$spent; tok = [long]($rs | Measure-Object tok -Sum).Sum; cost = $(if (@($rs | Where-Object { $null -ne $_.cost }).Count) { [math]::Round(($rs | Measure-Object cost -Sum).Sum, 2) })
          in = [long]($rs | Measure-Object in -Sum).Sum; out = [long]($rs | Measure-Object out -Sum).Sum; cr = [long]($rs | Measure-Object cr -Sum).Sum; cw = [long]($rs | Measure-Object cw -Sum).Sum
          wall = [math]::Round(($w.LastWriteTime - $w.CreationTime).TotalMinutes); roles = (@($rs | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = @($rs | Where-Object { $_.result -in 'pass', 'empty', 'fail' }).Count; total = $rs.Count; merged = @($rs.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = $items
          loop = [long](@($rs | Where-Object { $_.type -in 'review', 'fix' }) | Measure-Object tok -Sum).Sum; at = $w.LastWriteTime.ToString('o'); steps = @($rs) }) }
    foreach ($f in @(Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # Agent-tool spawns, by coordinator session
      $u = & $read $f.FullName; $m = & $meta $f.FullName; $k = $sd.Name; if (-not $bg[$k]) { $bg[$k] = [ordered]@{ session = $k; n = 0; tok = 0L; cost = $null; roles = @{}; at = '' } }
      $model = if ($u.model) { $u.model } else { "$($m.model)" }; $c = Get-KitUsageCost $u $model; $g = $bg[$k]; $g.n++; $g.tok += & $tot $u; if ($null -ne $c) { $g.cost = [double]$g.cost + $c }
      $rl = if ($m.agentType) { "$($m.agentType)" } else { 'agent' }; $g.roles[$rl] = 1 + [int]$g.roles[$rl]; if ($f.LastWriteTime.ToString('o') -gt $g.at) { $g.at = $f.LastWriteTime.ToString('o') }
      $steps.Add([pscustomobject]@{ run = ''; label = "$($m.description)"; type = 'agent'; role = $rl; model = $model; in = [long]$u.in; out = [long]$u.out; cr = [long]$u.cr; cw = [long]$u.cw; tok = (& $tot $u); cost = $c; min = (& $mins $u); tools = [int]$u.tools; result = 'pass'; round = 1; retry = 0; days = $u.days; at = $f.LastWriteTime.ToString('o'); mrs = @() }) }
  }
  foreach ($k in @($cache.Keys)) { if (-not $seen[$k]) { $cache.Remove($k) } }   # older than $Days: dropped
  $grp = { param([string]$by) @($steps | Where-Object { $_.$by -and $_.tok } | Group-Object $by | ForEach-Object { $g = @($_.Group); [pscustomobject]@{ k = $_.Name; n = $g.Count; avg = [long]($g | Measure-Object tok -Average).Average; p50 = (Get-KitPct $g.tok 0.5); p90 = (Get-KitPct $g.tok 0.9); avgMin = $(if (@($g.min | Where-Object { $null -ne $_ }).Count) { [math]::Round(($g.min | Where-Object { $null -ne $_ } | Measure-Object -Average).Average, 1) }); p90Min = (Get-KitPct $g.min 0.9) } } | Sort-Object { -$_.avg * $_.n }) }
  $wf = @($steps | Where-Object run); $ended = @($wf | Where-Object result -in 'pass', 'empty', 'fail', 'stuck')
  $top = { param([double]$h) @($steps | Where-Object { ($Now - [datetime]$_.at).TotalHours -le $h } | Sort-Object { -$_.tok } | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ label = $(if ($_.run) { "$($_.label) · $($_.run)" } else { $_.label }); role = $_.role; model = $_.model; tok = $_.tok; min = $_.min } }) }
  $dayRows = @(foreach ($i in 0..($Days - 1)) { $dk = $Now.AddDays(-$i).ToString('yyyy-MM-dd'); $ds = @($steps | Where-Object { $_.days -and [long]$_.days[$dk] }); $tk = [long](@($ds | ForEach-Object { [long]$_.days[$dk] }) | Measure-Object -Sum).Sum
      $dc = @($ds | Where-Object { $null -ne $_.cost -and $_.tok } | ForEach-Object { [double]$_.cost * [long]$_.days[$dk] / [double]$_.tok })   # cost split by the day's share of its tokens
      [pscustomobject]@{ day = $dk; tok = $tk; cost = $(if ($dc.Count) { [math]::Round(($dc | Measure-Object -Sum).Sum, 2) }); runs = @($ds | Where-Object run | ForEach-Object run | Select-Object -Unique).Count; merged = @(@($steps | Where-Object { "$($_.at)".StartsWith($dk) }).mrs | Where-Object { $_ } | Select-Object -Unique).Count } })
  [Array]::Reverse($dayRows)
  $usageOut = [pscustomobject]@{ at = $Now.ToString('o'); partial = $script:KitUsagePartial; runs = @($runs | Sort-Object at -Descending); bg = @($bg.Values | ForEach-Object { [pscustomobject]@{ session = $_.session; n = $_.n; tok = $_.tok; cost = $(if ($null -ne $_.cost) { [math]::Round($_.cost, 2) }); roles = (@($_.roles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ') } } | Sort-Object { -$_.tok })
    byType = (& $grp type); byRole = (& $grp role); byModel = (& $grp model)
    rates = [pscustomobject]@{ n = $ended.Count; empty = @($ended | Where-Object result -eq 'empty').Count; fail = @($ended | Where-Object result -eq 'fail').Count; stuck = @($wf | Where-Object result -eq 'stuck').Count }
    top24 = (& $top 24); top7 = (& $top (24 * $Days)); days = $dayRows }
  try { Write-KitAtomic $cf (@{ files = $cache } | ConvertTo-Json -Depth 5 -Compress); Write-KitAtomic ($cf -replace '\.json$', '.result.json') ($usageOut | ConvertTo-Json -Depth 8 -Compress) } catch {}
  $usageOut
  } finally { $lkh.Dispose(); Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }
}
# the last budget -Usage result (the page, a run that finds the lock taken)
function Read-KitUsageResult { try { Get-Content -LiteralPath ((Get-KitPath usage-cache) -replace '\.json$', '.result.json') -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 } catch { $null } }
# Statistics "Usage" (budget -Usage result): KPI strip, 7-day chart, runs (collapsed, steps in a scroll box), per type / role / model, top 5, background agents;
# called by Format-KitSuperviseHtml: its helpers ($e $n1 $grid $table $bar $trend $at) by dynamic scope
function Format-KitUsageHtml($U) {
  if (-not $U -or -not @($U.days).Count) { return '<h3>Usage</h3><p class=empty>No usage yet: bossy.ps1 budget -Usage runs each sweep.</p>' }
  $tk = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 1e6) { "$(& $n1 ([double]$v / 1e6))M" } elseif ([double]$v -ge 1e3) { "$([math]::Round([double]$v / 1e3))k" } else { "$([long]$v)" } }
  $usd = { param($v) if ($null -eq $v) { '—' } else { '$' + ([double]$v).ToString('0.00', [cultureinfo]::InvariantCulture) } }
  $mn = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 90) { "$(& $n1 ([double]$v / 60)) h" } else { "$(& $n1 $v) min" } }
  $dy = @($U.days | Where-Object { $_ }); $td = $dy[-1]; $prev = @($dy | Select-Object -SkipLast 1)
  $avg = { param([string]$k) $vs = @($prev | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Average).Average } }
  $sum = { param([string]$k) $vs = @($dy | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Sum).Sum } }
  $runs = @($U.runs | Where-Object { $_ }); $wfTok = [double](($runs | Measure-Object tok -Sum).Sum); $loop = [double](($runs | Measure-Object loop -Sum).Sum)
  $merged = [int](($runs | Measure-Object merged -Sum).Sum); $items = [int](($runs | Measure-Object items -Sum).Sum); $rt = $U.rates; $bgs = @($U.bg | Where-Object { $_ })
  $card = { param([string]$label, [string]$v, [string]$sub, [string]$w, [string]$cls = '') "<div class='st $cls'><div class=k>$(& $e $label)</div><div class=v>$v</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })<div class=w>$(& $e $w)</div></div>" }
  $pct = { param($a, $b) if ([double]$b) { [math]::Round(100 * [double]$a / [double]$b) } }
  $vs = { param($cur, $base) if ($null -eq $cur -or -not [double]$base) { return '' }; $p = [math]::Round(100 * ([double]$cur - [double]$base) / [double]$base)   # vs the 7-day average
    "<span class='tr $(if ($p -gt 0) { 'bad' } elseif ($p -lt 0) { 'good' } else { 'eq' })'>$(if ($p -gt 0) { '▲' } elseif ($p -lt 0) { '▼' } else { '=' }) $([math]::Abs($p))%</span>" }
  $kpis = & $grid stats 170px @(
    (& $card 'Tokens today' "$(& $tk $td.tok)$(& $vs $td.tok (& $avg 'tok'))" "vs 7-day avg $(& $tk (& $avg 'tok'))" "7 days $(& $tk (& $sum 'tok'))"),
    (& $card 'Est. cost today' "$(& $usd $td.cost)$(& $vs $td.cost (& $avg 'cost'))" "vs 7-day avg $(& $usd (& $avg 'cost')) (budget.prices)" "7 days $(& $usd (& $sum 'cost'))"),
    (& $card 'Tokens per merged MR' "$(if ($merged) { & $tk ($wfTok / $merged) } else { '—' })" "$merged MR(s) merged · $items item(s): $(if ($items) { & $tk ($wfTok / $items) } else { '—' }) per item" '7 days, workflow runs'),
    (& $card 'Review + fix share' "$(if ($wfTok) { & $n1 (& $pct $loop $wfTok) } else { '—' })<small>%</small>" "$(& $tk $loop) of $(& $tk $wfTok) workflow tokens" '7 days' $(if ($wfTok -and $loop / $wfTok -gt 0.5) { 'warn' })),
    (& $card 'Steps empty · failed · stuck' "$(& $n1 (& $pct $rt.empty $rt.n))<small>%</small> · $(& $n1 (& $pct $rt.fail $rt.n))<small>%</small> · $([int]$rt.stuck)" "$($rt.empty) empty, $($rt.fail) failed of $($rt.n) ended steps" '7 days' $(if ($rt.stuck -or $rt.fail) { 'warn' })),
    (& $card 'Agents outside workflows' "$(& $tk (($bgs | Measure-Object tok -Sum).Sum))" "$(($bgs | Measure-Object n -Sum).Sum) agent(s) in $($bgs.Count) session(s)" "est. $(& $usd (($bgs | Where-Object { $null -ne $_.cost } | Measure-Object cost -Sum).Sum))"))
  # 7 days: tokens per day, today last; tooltip has cost, runs, merged MRs
  $mx = [math]::Max(1, (@($dy | ForEach-Object { [double]$_.tok }) + 0 | Measure-Object -Maximum).Maximum); $bw = 100 / [math]::Max(1, $dy.Count)
  $bars = @(for ($i = 0; $i -lt $dy.Count; $i++) { $d0 = $dy[$i]; $hh = 56 * [double]$d0.tok / $mx; $x = & $n1 ($i * $bw + $bw * 0.2)
    "<rect class=$(if ($i -eq $dy.Count - 1) { 'x' } else { 'w0' }) x=$x y=$(& $n1 (60 - $hh)) width=$(& $n1 ($bw * 0.6)) height=$(& $n1 $hh) /><rect class=hit x=$(& $n1 ($i * $bw)) y=0 width=$(& $n1 $bw) height=60><title>$(& $e "$($d0.day): $(& $tk $d0.tok) tokens · $(& $usd $d0.cost) · $($d0.runs) run(s) · $($d0.merged) MR(s) merged")</title></rect>" })
  $chart = "<div class=hist><svg viewBox='0 0 100 60' preserveAspectRatio=none role=img aria-label='tokens per day, 7 days'>$($bars -join '')</svg><div class=ax><span>$(& $e ("$($dy[0].day)".Substring(5)))</span><span>tokens per day · today $(& $tk $td.tok)</span><span>$(& $e ("$($td.day)".Substring(5)))</span></div></div>"
  $stepRows = { param($ss) @($ss | ForEach-Object { , @($_.label, $_.role, ("$($_.model)" -replace '^claude-'), (& $tk $_.tok), "$(& $tk $_.in) / $(& $tk $_.out) / $(& $tk $_.cr) / $(& $tk $_.cw)", (& $mn $_.min), $_.tools, @{ h = "<span class='chip $(switch ($_.result) { 'pass' { 's-act' } 'running' { 's-fin' } 'stuck' { 's-stuck' } 'fail' { 's-stuck' } default { 's-oth' } })'>$(& $e $_.result)</span>" }, "$($_.round)$(if ($_.retry) { " · retry $($_.retry)" })") }) }
  $runHtml = @(foreach ($r in @($runs | Select-Object -First 25)) {   # newest 25: the page stays light
      $cp = "<span class=bl>$(& $tk $r.tok) tokens</span>$(if ($r.cap) { & $bar ([double]$r.spent) ([double]$r.cap) "budget $(& $tk $r.spent) of $(& $tk $r.cap)" })"   # budget = context spend (budget -Run), not billed tokens
      "<details class='ru f'><summary><span class=gn0>$(& $e $r.run)</span><span class='chip $(if ($r.status -eq 'running') { 's-act' } else { 's-fin' })'>$(& $e $r.status)</span>$cp<span class=m>$(& $usd $r.cost) · $(& $mn $r.wall) · $($r.done)/$($r.total) steps · $($r.merged) merged · $(& $e $r.roles)</span></summary>" +
      "<div class=sy>$(& $table 'Step', 'Role', 'Model', 'Tokens', 'In / out / cache r / w', 'Time', 'Tools', 'Result', 'Round' (& $stepRows @($r.steps | Sort-Object { -$_.tok })))</div></details>" }) -join ''
  $aggT = { param([string]$title, $rows) "<div><h4>$(& $e $title)</h4><div class=sy>$(& $table 'Key', 'N', 'Avg', 'p50', 'p90', 'Avg time', 'p90 time' @($rows | ForEach-Object { , @(("$($_.k)" -replace '^claude-'), $_.n, (& $tk $_.avg), (& $tk $_.p50), (& $tk $_.p90), (& $mn $_.avgMin), (& $mn $_.p90Min)) }))</div></div>" }
  $topT = { param($rows) & $table 'Step', 'Role', 'Model', 'Tokens', 'Time' @($rows | ForEach-Object { , @($_.label, $_.role, ("$($_.model)" -replace '^claude-'), (& $tk $_.tok), (& $mn $_.min)) }) }
  "<h3>Usage: tokens, cost, time (7 days$(if ($U.partial) { '; transcripts still being read' }))</h3>" + $kpis + $chart +
    "<h4>Runs ($($runs.Count)$(if ($runs.Count -gt 25) { ', newest 25' }))</h4><div class='rus sy'>$(if ($runHtml) { $runHtml } else { '<p class=empty>None</p>' })</div>" +
    (& $grid aggs 460px @((& $aggT 'Per step type' $U.byType), (& $aggT 'Per role' $U.byRole), (& $aggT 'Per model' $U.byModel))) +
    (& $grid aggs 460px @("<div><h4>Top 5 steps, 24 h</h4>$(& $topT $U.top24)</div>", "<div><h4>Top 5 steps, 7 days</h4>$(& $topT $U.top7)</div>")) +
    "<h4>Agents outside workflows, by session</h4>" + (& $table 'Session', 'Agents', 'Tokens', 'Est. cost', 'Roles' @($bgs | ForEach-Object { , @($_.session, $_.n, (& $tk $_.tok), (& $usd $_.cost), $_.roles) }))
}
# ---- release: every lease of an agent (release, board leave, workflows after each stage); idempotent
# live gated builds of $Agent ('*' = all): its gate owner name, or a dir inside one of its worktrees (the owner may be a worktree name)
function Get-KitAgentBuilds([string]$Agent, [string[]]$Dirs = @()) {
  $in = { param($p) foreach ($w in $Dirs) { if ($w -and "$p".TrimEnd('\', '/').StartsWith($w.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return $true } }; $false }
  foreach ($bf in @(Get-ChildItem (Join-Path (Get-KitTemp) 'claude-build-gate') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json')) {
    $t = try { Get-Content $bf.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (($Agent -eq '*' -or $t.owner -eq $Agent -or (& $in $t.dir)) -and (Test-KitPid $t.pid $t.start)) { $t | Add-Member -Force NoteProperty file $bf.FullName; $t }   # a reused pid is not ours
  }
}
# killed, marked with $Reason (the gate prints it); release and pause stop them
function Stop-KitAgentBuilds([string]$Agent, [string]$Reason, [string[]]$Dirs = @()) {
  foreach ($t in @(Get-KitAgentBuilds $Agent $Dirs)) { $bp = Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue
    if ($bp) { $bf = $t.file; $t.PSObject.Properties.Remove('file'); $t | Add-Member -Force reclaimed $Reason; $t | ConvertTo-Json | Set-Content $bf; try { $bp.Kill($true) } catch {}; "$($t.owner) build: stopped $($t.kind) (pid $($t.pid))" } }
}
function Invoke-KitReleaseAgent([string[]]$Agent, [string]$Reason = 'agent finished') {
  $Agent = @(Split-KitList $Agent); if (-not $Agent.Count) { Stop-KitVerb 'usage: bossy.ps1 release -Agent <id>[,<id>] [-Reason <why>]' }
  Invoke-KitLeaseReason $Reason {
    $sub = { param($script, [string[]]$a) $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $script) + $a) 180; if ($r.code) { $script:KitReleaseFailed = $true; 'FAILED ' }; @("$($r.out) $($r.err)" -split "`r?`n" | Where-Object { $_.Trim() })[-1] }
    $envs = @(if (@(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue | Select-String -SimpleMatch -List @($Agent | ForEach-Object { "`"$_`"" })).Count) { Get-KitLocalEnvStatus })
    $tabs = @(Read-KitJsonFiles (Get-KitPath sessions) 'tabs-*.json' | ForEach-Object { $_.PSObject.Properties.Value | Where-Object { $_.agent } })
    foreach ($a in $Agent) {
      $n = 0
      if ($KitCmd.swarm -and (Test-Path $KitCmd.swarm) -and @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object agent -eq $a).Count) { "$a phone: $(& $sub $KitCmd.swarm 'release', '-Agent', $a)"; $n++ }
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
      if (-not $n) { "${a}: no lease held" }
    }
  }
}

# ---- lines: board show and recover
# board show: QA seats and local-env leases
function Get-KitBoardLinesResources {
  foreach ($o in @(Read-KitJsonFiles (Join-Path (Get-KitPath qa-seats) 'seats'))) { "  seat: $($o.agent) $($o.kind) $($o.need) GB since $($o.since)$(if ((Test-KitHolder $o) -eq $false) { ' (holder gone)' })" }
  foreach ($ev in @(Get-KitLocalEnvStatus)) { foreach ($l in @($ev.leases | Where-Object { $_ })) { "  lease: $($ev.env) $($l.agent) on $(@($l.services) -join ', ') $(if ($l.until) { "until $($l.until)" } else { 'while live' })" } }
}
# envy.ps1 status -Json (goody local-env): the env's own report, never its files
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
    $ls = @{}; if ($o.lane) { $ls[$o.agent] = $o } else { foreach ($p in @($o.leases.PSObject.Properties) + @($o.holds.PSObject.Properties) | Where-Object { $_ }) { $ls[$p.Name] = $p.Value } }
    foreach ($k in @($ls.Keys)) { if ($k -notin '__stopping__', 'manual' -and -not (Test-KitLive $ls[$k])) { "== LEASE $name $k [$(@($ls[$k].services) -join ',')]: no live holder, ends after idle.graceMinutes (now: $(if ($o.lane) { "phoney.ps1 release -Agent $k" } else { "envy.ps1 release|unhold -Env $name -Agent $k" }))" } }
  }
}

# ---- cleanup: idle resources
# holderless test browsers, idle / surplus browser profiles, idle Gradle / Kotlin daemons
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
    if (@($tabs.PSObject.Properties | Where-Object { $_.Name -notmatch '^_' -and $_.Value.pid -and (Get-Process -Id ([int]$_.Value.pid) -ErrorAction SilentlyContinue) }).Count) { continue }
    $since = if ($tabs._idle) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$tabs._idle).LocalDateTime } else { [datetime]$c.Created }
    if (($now - $since).TotalMinutes -ge [double](Get-KitSetting 'idle.graceMinutes' 10)) { [void]$actions.Add("killed headless browser pid $($c.Id) (no live tab holder for $([int]($now - $since).TotalMinutes) min)"); if (-not $DryRun) { Stop-SysProcess $c.Id } }
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
  $gradleBusy = @(Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' |
    ForEach-Object { try { $e = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($e.kind -match 'android|gradle' -and (Test-KitPid $e.pid $e.start)) { $e } } catch {} }).Count
  if (-not $gradleBusy -and -not $env:KIT_KEEP_DAEMONS) {   # tests: their own gate dir cannot see the machine's builds
    foreach ($d in Get-SysProcs -Name '^java(\.exe)?$' | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' }) {
      if (($now - $d.Created).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($d.CommandLine -match 'Kotlin') { 'Kotlin daemon' } else { 'Gradle daemon' }), $d.Id, ($d.WorkingSet / 1GB))); $script:freed += [long]$d.WorkingSet; if (-not $DryRun) { Stop-SysProcess $d.Id } }
    }
  }
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
# every task: a description with an Items list (a [Bug] its own shape), written as its Items checklist (goody task-rollup); a subtask
# the whole template and a parent with the delivery section, rolled up from the brief dir's item table when it has one.
# One "TASKS REFUSED" line per gap; an unread task is skipped; -Check (-File) writes nothing
function Test-KitLaunchTasks($A, [string]$File, [string]$RunName = '') {
  if ($File) { $A = try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json -AsHashtable } catch { 'usage: launch -Check -ArgsFile <buildy args .json>'; exit 2 } }
  $ids = @(@($A.agents) | ForEach-Object { @("$($_.task)") + @(Get-KitItemTasks "$($_.items)") } | ForEach-Object { NormTask $_ } | Where-Object { $_ } | Select-Object -Unique -First 20)
  $bd = if ($A.brief) { Split-Path ([string]$A.brief) }; $gc = { param($n) Get-Command $n -ErrorAction SilentlyContinue }   # goody task-rollup
  $roll = & $gc Invoke-TaskRollup; $itemsFn = & $gc Update-KitTaskItems; $triFn = & $gc Read-KitTriage; $par = @{}; $read = 0
  $out = @(foreach ($id in $ids) {
      $t = try { Get-TrackerTask $id } catch { $null }; if (-not $t.name) { continue }; $read++; $p = "$($t.parent)"
      $gap = @(Get-KitTaskTextGaps $t.name $t.description -Subtask | Where-Object { $p -or $_ -in 'a description', 'Items' })   # the owner's own task: Items only
      if ((Read-KitState (Get-KitTaskFile $id)).itemsSig) { $gap = @($gap | Where-Object { $_ -ne 'Items' }) }   # a kit checklist
      if ($gap.Count) { "TASKS REFUSED ${id}: its description lacks $($gap -join ', ') (templates.md task-description): $(if ($p) { "crafty.ps1 tracker describe $id -File <md>" } else { "crafty.ps1 tracker scope -Task $id -Add '**Items:** <ids>' (the owner's text stays)" })" }
      elseif ($itemsFn -and -not $File) { try { & $itemsFn $id $t } catch { "ITEMS $id failed: $("$_".Split("`n")[0])" } }
      if (-not $p -or $par.ContainsKey($p)) { continue }
      $pt = try { Get-TrackerTask $p } catch { $null }; $par[$p] = 1; if (-not $pt.name -or "$($pt.description)" -match '<!-- kit:delivery -->') { continue }
      if ($roll -and $triFn -and -not $File -and $bd -and @((& $triFn $bd).rows).Count) { & $roll -Task $p -From $bd -Quiet; Clear-TrackerMemo $p; if ("$((Get-TrackerTask $p).description)" -match '<!-- kit:delivery -->') { continue } }
      "TASKS REFUSED ${id}: parent $p has no delivery section: bossy.ps1 track rollup -Task $p -From <brief dir with an item table (ID, Area columns)>$(if (-not $roll) { ' (goody task-rollup: kitbag.py goody add task-rollup)' })"
    })
  if ($ids.Count -and -not $read) { $out += "TASKS UNKNOWN: none of $($ids.Count) item task(s) read from the tracker: not checked" }
  $claims = Get-KitTaskClaims $(if ($RunName) { $RunName } else { Get-LaunchRunName $A })   # any session's live run: one run per task
  $out = @($ids | Where-Object { $claims[$_] } | ForEach-Object { "TASKS REFUSED ${_}: $($claims[$_]) works on it now: add the work to that run (bossy E8), never launch it twice" }) + $out
  $out; if (-not $File) { return }
  if (@($out -match '^TASKS REFUSED').Count) { exit 1 }; "TASKS ok: $(@($A.agents).Count) area(s)"; exit 0
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
foreach ($b in $live) { Send-BoardMsg 'coordinator' $b.agent "PAUSE ($Reason): $(Get-KitPauseSteps $b.session)" }
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
  while ($true) { $open = @(Get-KitPauseOpen $rec); if (-not @($open | Where-Object { -not (Test-KitPauseSafe $_ $rec.at) }).Count -or (Get-Date) -ge $until -or (& $resumed)) { break }; Wait-KitPoll 15 }   # safe unconfirmed agents: no wait
  if (& $resumed) { "pause $Pf was resumed meanwhile: nothing stopped"; return }
  foreach ($s in @($rec.runs)) { Invoke-KitStopLearn ([pscustomobject]@{ run = $s.run; leaf = $s.leaf; runId = $s.runId; file = $s.file; selfFile = $s.selfFile; at = $s.at }) 'pause' }
  foreach ($a in @($rec.agents)) {
    $b = try { Get-Content -LiteralPath $a.board -Raw | ConvertFrom-Json } catch { $null }; $ck = Get-KitCheckpoint $a.agent "$($a.run)"
    $dirs = @(@($ck.worktrees) + @($b.worktrees | Where-Object { "$_" -match '[\\/]' -and (Test-Path -LiteralPath "$_" -PathType Container) }) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($kv in @{ confirmed = $a.session -notin @($open.session); next = $ck.next; checkpoint = $ck; worktrees = @($dirs | ForEach-Object { Get-KitWtState $_ }) }.GetEnumerator()) { $a | Add-Member -Force NoteProperty $kv.Key $kv.Value }
  }
  if (& $resumed) { "pause $Pf was resumed meanwhile: nothing stopped"; return }
  $hooks = @(Invoke-KitHooks Invoke-KitPause)   # goody local-env: stops unheld services
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
function Get-KitHandoffLine($Me, [string]$Session, [string]$Why) { $hb = Join-Path (Get-KitPath briefs -Create) "$(ConvertTo-KitSlug "handoff-$($Me.agent)-$Session").md"; "HANDOFF: $Why`: write a resume brief (templates.md ""Resume brief"") to $hb, commit WIP, board leave -Session $Session -Handoff $hb, return handoff = $hb and stop: a fresh agent continues" }
function Get-KitStepAgeHandoff($Me, [string]$Session) {
  $h = [double](Get-KitSetting 'budget.stepHours' 2); if ($h -le 0 -or -not $Me.joined -or $Me.type -eq 'coordinator') { return }   # a coordinator has no steps
  $ck = Get-KitCheckpoint $Me.agent "$($Me.run)"; if (-not $ck.updated -or $ck.done) { return }   # agents that checkpoint their steps only
  $from = [datetimeoffset]$Me.joined; if ([datetimeoffset]$ck.updated -gt $from) { $from = [datetimeoffset]$ck.updated }   # the step since the last checkpoint (a resumed agent rejoins: joined)
  $age = ([datetimeoffset](Get-Date) - $from).TotalHours; if ($age -ge $h) { Get-KitHandoffLine $Me $Session ('one step running {0:0.0} h >= budget.stepHours {1}' -f $age, $h) }
}
