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
Sections: L15 builds · L47 supervise · L253 shells · L382 page · L908 usage · L1129 release · L1168 lines · L1201 cleanup ·
  L1237 launch · L1315 pause · L1433 heartbeat · L1448 sessions · L1500 ci tasks · L1552 the kit origin's main and goodies
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
    if ($AutoFix -and $tabs._idle -and -not @($tabs.PSObject.Properties | Where-Object Name -notmatch '^_').Count -and $idleM -ge [double](Get-KitParam 'idle.graceMinutes')) {
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
    if ($e.PSObject.Properties['matched']) {
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
  foreach ($h in @($Entry.matched | Where-Object { $_ })) {
    if ($h.tagged -or (& $has $h.ref "$tag$($Entry.task)")) { continue }
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
# agents failed a day (null = no calls log): ended board leave -Status failed / blocked / error; closed days from $Prev
function Get-KitSuperviseDays($Prev, [datetime]$Now, [int]$Days = 7) {
  $today = $Now.ToString('yyyy-MM-dd'); $kept = @{}; foreach ($pd in @($Prev | Where-Object { $_.final -and $null -ne $_.failed })) { $kept["$($pd.day)"] = [pscustomobject]@{ day = "$($pd.day)"; final = $true; failed = $pd.failed } }   # older records: only failed is kept
  foreach ($i in 0..($Days - 1)) { $day = $Now.AddDays(-$i).ToString('yyyy-MM-dd')
    if ($kept.ContainsKey($day)) { $kept[$day]; continue }
    $rec = [ordered]@{ day = $day; final = $day -ne $today; failed = $null }
    $cf = Join-Path (Get-KitPath audit) "$day/calls.jsonl"
    if (Test-Path -LiteralPath $cf) { $rec.failed = 0; $stOf = @{}   # start event's -Status for its end (rc 'exit' = pwsh exit, success)
      foreach ($ev in @(Select-String -LiteralPath $cf -Pattern '"verb":"board leave"' | ForEach-Object { try { $_.Line | ConvertFrom-Json -ErrorAction Stop } catch { } })) {
        if ($ev.event -eq 'start') { $stOf["$($ev.pid)"] = if ("$($ev.args)" -match '-Status\s+(\w+)') { $Matches[1] } else { 'done' }; continue }
        if ($ev.event -eq 'end' -and "$($ev.rc)" -in '0', 'exit' -and $stOf["$($ev.pid)"] -in 'failed', 'blocked', 'error') { $rec.failed++ } } }
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
    [ordered]@{ drive = $dv; free = $fr; rate = $rt; h1 = $h1; total = $tot; series = @(& $thin @($sm | ForEach-Object free)) } } })
  [ordered]@{ ram = @(& $thin $ram); disks = @(if ($disks.Count) { $disks } else { $Prev.disks | Where-Object { $_ } }) }
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
# page + .json, written atomically; returns its path; failure: a WATCH and '' (tables print)
# the gate's card row of a build: kind (crafty.ps1 GateKinds) to a plain group; a local env's build = env deploy
function Get-KitGateGroup([string]$Kind, [string]$Who) {
  if ($Who -match 'localenv-') { return 'env deploy' }
  switch -regex ($Kind) { '^maven-test$' { 'maven test' } '^maven$' { 'maven build' } '^(web-build|rn-bundle)$' { 'web build' } '^(typecheck|tsc-lint)$' { 'typecheck / lint' }
    '^(js-test|ng-test)$' { 'js tests' } '^python$' { 'python' } '^(e2e|cypress)$' { 'cypress / e2e' } '^docker$' { 'docker' } '^(android-build|android-test|gradle)$' { 'android' } '^emulator$' { 'emulator' } default { 'other' } }
}
# the gate from its builds log (24 h), not a sweep sample (one missed a build between sweeps):
# per group running / queued now, done today, avg / peak wait, RAM promised, an hourly heatmap (24 clock hours, the last = the current one:
# @(builds ended, busy min, max wait min) each, h0 = the first hour); phone lanes and emulators
function Get-KitGateStats([datetime]$Now = (Get-Date), $Resources = @()) {
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $from = $h0; $led = Join-Path (Get-KitTemp) 'claude-build-gate'; $rd = { param($f) try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
  $at = { param($v) if ($v -is [datetime]) { $v } else { try { [datetime]"$v" } catch { $null } } }
  $run = @(Get-ChildItem $led -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ -and $_.pid -and (Test-KitPid $_.pid $_.start) })
  $que = @(Get-ChildItem (Join-Path $led 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ })
  $ends = @(Read-KitLog builds $from | Where-Object { $_.event -eq 'end' -and (& $at $_.at) })
  $g = [ordered]@{}; $row = { param($n) if (-not $g.Contains($n)) { $g[$n] = [ordered]@{ name = $n; running = 0; queued = 0; done = 0; waits = [Collections.Generic.List[double]]::new(); ram = 0.0; peakGB = 0.0; hours = @(0..23 | ForEach-Object { , @(0, 0.0, 0.0) }) } }; $g[$n] }
  # busy minutes spread over the clock hours a build overlapped; its count and wait go to the hour it ended in
  $busy = { param($r, [datetime]$s1, [datetime]$e1) for ($hi = [math]::Max(0, [int][math]::Floor(($s1 - $h0).TotalHours)); $hi -le [math]::Min(23, [int][math]::Floor(($e1 - $h0).TotalHours)); $hi++) {
      $hs = $h0.AddHours($hi); $ov = ([datetime]::new([math]::Min($e1.Ticks, $hs.AddHours(1).Ticks)) - [datetime]::new([math]::Max($s1.Ticks, $hs.Ticks))).TotalMinutes; if ($ov -gt 0) { $r.hours[$hi][1] += $ov } } }
  foreach ($x in $ends) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $e1 = & $at $x.at; $s1 = $e1.AddSeconds(-[double]$x.sec); $wm = [double]$x.waitSec / 60
    if ($e1 -ge $Now.Date) { $r.done++; $r.waits.Add($wm) }; & $busy $r $s1 $e1; $hi = [int][math]::Floor(($e1 - $h0).TotalHours); if ($hi -ge 0 -and $hi -le 23) { $r.hours[$hi][0]++; $r.hours[$hi][2] = [math]::Max($r.hours[$hi][2], $wm) } }
  foreach ($x in @(Read-KitLog builds $Now.Date | Where-Object { $_.event -eq 'start' })) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $r.peakGB = [math]::Max($r.peakGB, [double]$x.needGB) }
  foreach ($x in $run) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.dir)"); $r.running++; $r.ram += [double]$x.need; $s1 = & $at $x.started; if ($s1) { & $busy $r $s1 $Now } }
  foreach ($x in $que) { (& $row (Get-KitGateGroup "$($x.kind)" "$($x.owner)")).queued++ }
  $rows = @($g.Values | ForEach-Object { [pscustomobject]@{ name = $_.name; running = $_.running; queued = $_.queued; done = $_.done; ram = [math]::Round($_.ram, 1); peakGB = [math]::Round($_.peakGB, 1)
        waitAvg = $(if ($_.waits.Count) { [math]::Round(($_.waits | Measure-Object -Average).Average, 1) } else { 0 }); waitMax = $(if ($_.waits.Count) { [math]::Round(($_.waits | Measure-Object -Maximum).Maximum, 1) } else { 0 })
        hours = @($_.hours | ForEach-Object { , @([int]$_[0], [math]::Round($_[1], 1), [math]::Round($_[2], 1)) }) } } | Sort-Object { - ($_.running * 1000 + $_.queued * 100 + $_.done) })
  $lanes = @(try { (Get-Content (Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json') -Raw -ErrorAction Stop | ConvertFrom-Json).lanes } catch { })
  [pscustomobject]@{ h0 = $h0.ToString('o'); running = $run.Count; queued = $que.Count; today = [int](($rows | Measure-Object done -Sum).Sum); waitMax = [double](@($rows.waitMax) + 0 | Measure-Object -Maximum).Maximum
    ram = [math]::Round([double](($run | Measure-Object need -Sum).Sum), 1); rows = $rows
    lanes = $lanes.Count; leased = @($lanes | Where-Object { $_.name -and (Test-Path (Join-Path (Get-KitPath phones) "$($_.name).json")) }).Count; emulators = @($Resources | Where-Object { "$($_.name)" -like 'phone *' }).Count
    browsers = @($Resources | Where-Object { "$($_.name)" -like 'browser *' }).Count; browserGB = [math]::Round([double](@($Resources | Where-Object { "$($_.name)" -like 'browser *' } | ForEach-Object { [double]$_.gb }) + 0 | Measure-Object -Sum).Sum, 1) }   # leases, never gated
}
# effective supervise.* settings: kit.example.json defaults, kit.local.json overrides (with the default), supervise.* params
function Get-KitSuperviseSettings($Params = @()) {
  $out = [ordered]@{}; $js = { param($v) if ($v -is [string] -or $v -is [ValueType]) { $v } else { $v | ConvertTo-Json -Compress -Depth 4 } }
  if ($script:KitExample.supervise -is [psobject]) { foreach ($p in $script:KitExample.supervise.PSObject.Properties) { $out["supervise.$($p.Name)"] = [pscustomobject]@{ value = (& $js $p.Value); source = 'default' } } }
  foreach ($p in @($Params | Where-Object { "$($_.key)" -like 'supervise.*' -and "$($_.ctx)" -in '', '_' })) {
    $out["$($p.key)"] = [pscustomobject]@{ value = $p.value; source = $(if ("$($p.source)" -match 'learned') { 'learned' } elseif ("$($p.source)" -match '^default') { 'default' } else { ("$($p.source)" -split ' ')[0] }) } }
  $set = Get-KitSetting 'supervise' $null
  if ($set -is [psobject]) { foreach ($p in $set.PSObject.Properties) { $k = "supervise.$($p.Name)"; $was = $out[$k]
      $out[$k] = [pscustomobject]@{ value = $(if ($p.Name -eq 'publish') { '(set)' } else { & $js $p.Value }); source = 'local'; default = $(if ($was -and "$($was.value)" -ne "$(& $js $p.Value)") { $was.value }) } } }
  [pscustomobject]$out
}
function Write-KitSuperviseHtml($d, [string[]]$Sweep, [string]$Next) { try {
  $rk = @{ ACT = 0; WATCH = 1; INFO = 2 }
  $p = [IO.Path]::ChangeExtension((Get-KitPath supervise-report -Create), '.html'); $pj = [IO.Path]::ChangeExtension($p, '.json')
  $prior = try { Get-Content -LiteralPath $pj -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
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
  $usage = Read-KitUsageResult   # budget -Usage writes it
  $stats = [ordered]@{ keepFree = $d.keepFree; usage = $usage; repos = (Get-KitRepoSweep); days = @(try { Get-KitSuperviseDays $prior.stats.days $d.at } catch { }); ram = $series.ram; disks = $series.disks; now = $nowT; live = @($samples)
    changes = @(Get-Content -LiteralPath (Get-KitPath params-changes) -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop | Select-Object at, key, ctx, from, to, why } catch { } })
    params = @(try { $apv = (Read-KitParams).approved; @(Invoke-KitParamVerb show -Json | ConvertFrom-Json) | ForEach-Object { [pscustomobject]@{ key = $_.key; ctx = $_.ctx; value = $_.effective
            source = "$(if ($apv."$($_.key)|$(if ($_.ctx -ne '_') { $_.ctx })" -or $apv."$($_.key)|") { 'approved' } else { $_.state })$(if ($_.source -notmatch '^(default|learned|pin$)') { " · $($_.source)" })"
            learned = $(if ($null -ne $_.learned -and $_.learned -ne $_.effective) { $_.learned } else { '' }); changed = $_.changed; why = $_.why } } } catch { }) }
  $stats.settings = Get-KitSuperviseSettings $stats.params   # defaults + local overrides + learned params: never an empty section
  $stats.gate = try { Get-KitGateStats $d.at @($d.resources) } catch { $null }
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
# lines, never bars (owner, 2026-11-13): $Points = @{ label; tip; x = highlighted }; $Series = @{ vals; tone; style solid | dash | dot; area; fmt;
# max }, each its own scale; -Labels: values above the dots; $Avg: dotted line of series 1; a hover column per point; -Bare: the svg only
function Format-KitLineChart($Points, $Series, [string]$Aria, [int]$Height = 96, $Avg = $null, [switch]$Labels, [switch]$Bare) {
  $civ = [cultureinfo]::InvariantCulture; $ce = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $cn1 = { param($x) ([double]$x).ToString('0.##', $civ) }
  $pts = @($Points); $n = $pts.Count; $ss = @($Series | Where-Object { $_ }); if (-not $n -or -not $ss.Count) { return '' }
  $pad = if ($n -eq 1) { 50 } elseif ($Labels) { 7 } else { 2 }; $top = if ($Labels) { 34 } else { 8 }
  $xOf = { param($i) if ($n -eq 1) { 50 } else { $pad + (100 - 2 * $pad) * $i / ($n - 1) } }
  $yOf = { param($v, $mx) 4 + (96 - 4 - $top) * [math]::Max(0, [double]$v) / $mx }   # % from the bottom
  $mxOf = @(foreach ($s in $ss) { if ($s.max) { [double]$s.max } else { [math]::Max(1e-9, [double](@(@($s.vals) | ForEach-Object { [double]$_ }) + 0 | Measure-Object -Maximum).Maximum) } })
  $svg = @(for ($k = 0; $k -lt $ss.Count; $k++) { $s = $ss[$k]
      $xy = @(for ($i = 0; $i -lt $n; $i++) { "$(& $cn1 (& $xOf $i)),$(& $cn1 (100 - (& $yOf @($s.vals)[$i] $mxOf[$k])))" }) -join ' '
      if ($s.area) { "<polygon class='ar t-$($s.tone)' fill-opacity=.16 points='$(& $cn1 (& $xOf 0)),100 $xy $(& $cn1 (& $xOf ($n - 1))),100'/>" }
      "<polyline class='ln t-$($s.tone) $($s.style)' fill=none points='$xy'/>" })   # fill=none: an unstyled polyline fills black
  if ($null -ne $Avg -and [double]$Avg -gt 0) { $ay = & $cn1 (100 - (& $yOf $Avg $mxOf[0])); $svg += "<line class=avg x1=0 x2=100 y1=$ay y2=$ay />" }
  $svgHtml = "<svg viewBox='0 0 100 100' preserveAspectRatio=none aria-hidden=true>$($svg -join '')</svg>"
  if ($Bare) { return $svgHtml }
  $labs = [Collections.Generic.List[string]]::new()   # value labels in their own layer: a hover column holds no text (narrow, it reads as squeezed)
  $cols = @(for ($i = 0; $i -lt $n; $i++) { $p = $pts[$i]; $ys = @(for ($k = 0; $k -lt $ss.Count; $k++) { & $yOf @($ss[$k].vals)[$i] $mxOf[$k] })
      $dots = @(for ($k = 0; $k -lt $ss.Count; $k++) { "<i class='dt t-$($ss[$k].tone) $($ss[$k].style)' style='bottom:$(& $cn1 $ys[$k])%'></i>" }) -join ''
      if ($Labels) { $ls = @($ss | Where-Object fmt | ForEach-Object { & $_.fmt @($_.vals)[$i] }); if ($ls.Count) { $labs.Add("<b$(if ($p.x) { ' class=x' }) style='left:$(& $cn1 (& $xOf $i))%;bottom:$(& $cn1 ($ys | Measure-Object -Maximum).Maximum)%'>$(& $ce $ls[0])$(@($ls | Select-Object -Skip 1 | ForEach-Object { "<small>$(& $ce $_)</small>" }) -join '')</b>") } }
      "<li$(if ($p.x) { ' class=x' }) style='left:$(& $cn1 (& $xOf $i))%' title='$(& $ce $p.tip)' aria-label='$(& $ce $p.tip)'>$dots</li>" })
  $xl = @(for ($i = 0; $i -lt $n; $i++) { if ($pts[$i].label) { "<span$(if ($pts[$i].x) { ' class=x' }) style='left:$(& $cn1 (& $xOf $i))%'>$(& $ce $pts[$i].label)</span>" } })
  "<figure class=lch style='--n:$n'><div class=lcp style='height:$($Height)px' role=img aria-label='$(& $ce $Aria)'>$svgHtml$(if ($labs.Count) { "<div class=lcl aria-hidden=true>$($labs -join '')</div>" })<ol>$($cols -join '')</ol></div>$(if ($xl.Count) { "<div class=lcx>$($xl -join '')</div>" })</figure>"
}
# one icon set for the words the page repeats (running, queued, today, wait, RAM, stuck): inline SVG, currentColor, <title> = tooltip
function Format-KitIcon([string]$Name, [string]$Label = $Name) {
  $p = switch ($Name) { 'run' { "<path fill=currentColor stroke=none d='M5 3.2v9.6L12.8 8z'/>" } 'queue' { "<path fill=none d='M4.5 2h7M4.5 14h7M5.5 2v1.8c0 2 5 2.4 5 4.2s-5 2.2-5 4.2V14M10.5 2v1.8c0 2-5 2.4-5 4.2s5 2.2 5 4.2V14'/>" }
    'today' { "<path fill=none d='M3 8.6l3.2 3.1L13 4.6'/>" } 'wait' { "<circle fill=none cx=8 cy=8 r=6 /><path fill=none d='M8 4.6V8l2.3 1.6'/>" } 'stuck' { "<path fill=none d='M8 2.2l6.3 11.3H1.7zM8 6.6v3.2M8 11.6v.1'/>" }
    'ram' { "<rect fill=none x=4 y=4 width=8 height=8 rx=1.2 /><path fill=none d='M6 1.6V4M10 1.6V4M6 12v2.4M10 12v2.4M1.6 6H4M1.6 10H4M12 6h2.4M12 10h2.4'/>" } default { throw "Format-KitIcon: unknown icon '$Name'" } }
  $l = [Net.WebUtility]::HtmlEncode($Label); "<svg class='ic i-$Name hit' viewBox='0 0 16 16' role=img aria-label='$l'><title>$l</title>$p</svg>" }
# pure (tests feed a sample); values HtmlEncoded; inline CSS / JS / SVG only: no request leaves the page
function Format-KitSuperviseHtml($j) {
  $iv = [cultureinfo]::InvariantCulture; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $n1 = { param($x) ([double]$x).ToString('0.#', $iv) }
  $toTime = { param($x) if ($x) { try { [datetime]$x } catch { $null } } }; $at = & $toTime $j.at; if (-not $at) { $at = Get-Date }
  $ago = { param($x) $tx = & $toTime $x; if (-not $tx) { return '' }; $m = [int][math]::Max(0, ($at - $tx).TotalMinutes); if ($m -lt 1) { 'now' } elseif ($m -lt 60) { "$m min" } elseif ($m -lt 1440) { "$([math]::Floor($m / 60)) h $($m % 60) min" } else { "$([math]::Floor($m / 1440)) d" } }
  $when = { param($x) $tx = & $toTime $x; if ($tx) { "<span class=tm>$($tx.ToString($(if ($tx.Date -eq $at.Date) { 'HH:mm' } else { 'MM-dd HH:mm' }))) · </span><span class=ago data-t='$($tx.ToString('o'))' title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $x)</span>" } else { '<span class=m>—</span>' } }   # .ago: the page JS recounts it live
  $minAgo = { param($v) if ("$v" -match '^\s*(\d+(?:\.\d+)?)(?: min)?\s*$') { & $when $at.AddMinutes(-[double]$Matches[1]) } else { & $e $v } }   # sweep-relative minutes -> a live age
  $stCls = { param($s) if ("$s" -match 'STUCK') { 's-stuck' } elseif ("$s" -match '^ACTIVE') { 's-act' } elseif ("$s" -match '^FINISHED') { 's-fin' } else { 's-oth' } }
  # sparkline (40 px): max / min left, a dot on now; caption = what, now, low / peak; $lo = 0: from 0; < 2 values: none
  # $avg: a dotted line ("<avgLabel> <v>"); -Step: step line; -NoNow: the headline shows now
  $spark = { param($vals, [string]$cls, [string]$what, [string]$mark = '', $lo = $null, [string]$unit = '', $avg = $null, [string]$avgLabel = 'avg', [switch]$Step, [switch]$NoNow) $vals = @($vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }); if ($vals.Count -lt 2) { return '' }
    $mx = ($vals | Measure-Object -Maximum).Maximum; $mn = if ($null -ne $lo) { [double]$lo } else { ($vals | Measure-Object -Minimum).Minimum }; $xs = { param($i) & $n1 (100 * $i / ($vals.Count - 1)) }
    if ($null -ne $avg) { $mx = [math]::Max($mx, [double]$avg); $mn = [math]::Min($mn, [double]$avg) }
    $yv = { param($v) if ($mx -eq $mn) { 20 } else { 38 - 34 * ($v - $mn) / ($mx - $mn) } }
    $pts = @(for ($i = 0; $i -lt $vals.Count; $i++) { if ($Step -and $i) { "$(& $xs $i),$(& $n1 (& $yv $vals[$i - 1]))" }; "$(& $xs $i),$(& $n1 (& $yv $vals[$i]))" }) -join ' '
    $mv = if ($mark) { if ($mark -eq 'low') { ($vals | Measure-Object -Minimum).Minimum } else { ($vals | Measure-Object -Maximum).Maximum } }
    $cap = "$what$(if (-not $NoNow) { " · now $(& $n1 $vals[-1])$unit" })$(if ($mark) { " · $mark $(& $n1 $mv)$unit" })$(if ($null -ne $avg) { " · $avgLabel $(& $n1 $avg)$unit" })"
    $avL = if ($null -ne $avg) { $ay = & $n1 (& $yv ([double]$avg)); "<line class=mk x1=0 x2=100 y1=$ay y2=$ay />" }
    "<figure class='spk $cls'><div class=spw><svg class=spark viewBox='0 0 100 40' preserveAspectRatio=none role=img aria-label='$(& $e "$cap, y $(& $n1 $mn)-$(& $n1 $mx)$unit")'><polygon class=a fill=currentColor points='0,40 $pts 100,40'/><polyline class=l fill=none points='$pts'/>$avL</svg>" +
    "<span class='ya hi'>$(& $n1 $mx)$(& $e $unit)</span><span class='ya lo'>$(& $n1 $mn)$(& $e $unit)</span><i class=nd style='bottom:$(& $n1 (100 * (40 - (& $yv $vals[-1])) / 40))%'></i></div><figcaption>$(& $e $cap)</figcaption></figure>" }
  # a meter: value of max with its caption; $peak = a marker (the 7-day peak)
  $meter = { param([double]$v, [double]$max, [string]$cap, [string]$tone = 'slate', $peak = $null) if ($max -le 0) { return '' }; $w = { param($x) & $n1 ([math]::Max(0, [math]::Min(100, 100 * $x / $max))) }
    "<div class=mtr><span class=mb role=img aria-label='$(& $e $cap)'><i class=$tone style='width:$(& $w $v)%'></i>$(if ($null -ne $peak) { "<b class=pk style='left:$(& $w ([double]$peak))%'></b>" })</span><span class=mc>$(& $e $cap)</span></div>" }
  $bar = { param([double]$v, [double]$max, [string]$label, [string]$tone = '') if ($max -le 0) { return '' }; $pc = [math]::Min(100, 100 * $v / $max); $bc = if ($tone) { $tone } elseif ($pc -ge 100) { 'act' } elseif ($pc -ge 80) { 'watch' } else { 'sage' }
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
  $grid = { param([string]$cls, [string]$min, [object[]]$items, [int]$max = 0, [string]$tag = 'div') "<$tag class='cg $cls' style='--cmin:$min$(if ($max) { ";--cmax:$max" })'$(if ($cls -notmatch '\bmach\b') { ' data-mas' })>$(@($items | Where-Object { $_ }) -join '')</$tag>" }
  # a value behind its icon (the icon's title names it): no repeated words; $z: a zero is dimmed
  $icv = { param([string]$ico, [string]$label, $v, [string]$unit = '') "<span class='iv$(if ("$v" -match '^[0—]$') { ' z' })'>$(Format-KitIcon $ico $label)$v$(if ($unit) { "<small>$unit</small>" })</span>" }
  $item = { param([string]$name, [string]$sub, [string]$inner = '', [string]$tail = '') "<div class='ci f' title='$(& $e "$name · $sub")'><div class=tn>$(& $e $name)$tail</div><div class=sm>$(& $e $sub)</div>$inner</div>" }   # a grid card: name (+ an icon value), one line, an optional full-width bar
  # stopped / crashed with no progress for one heartbeat: finished, not live (owner, 2026-11-13)
  $isFin = { param($a) if ("$($a.state)" -eq 'FINISHED') { return $true }; if ("$($a.state)" -notmatch '^(STOPPED|CRASHED)') { return $false }; $lt = & $toTime $(if ($a.last) { $a.last } else { $a.since }); $lt -and ($at - $lt).TotalMinutes -gt $hbMin }
  $agents = @($j.agents | Where-Object { $_ }); $flags = @($j.flags | Where-Object { $_ })
  $nAct = @($flags | Where-Object level -eq 'ACT').Count; $nWatch = @($flags | Where-Object level -eq 'WATCH').Count
  $hist = @($j.history | Where-Object { $_ }); [array]::Reverse($hist)   # oldest first
  $hCount = { param($h, [string]$lv) @($h.flags | Where-Object level -eq $lv).Count }
  $nextMin = if ("$($j.next)" -match '(\d+(?:\.\d+)?)') { $Matches[1] } else { 15 }   # stale: older than 2 heartbeats (amber), 4 (red)
  $hbMin = try { [double](Get-KitParam 'supervise.heartbeatMinutes') } catch { 0 }; if (-not ($hbMin -gt 0)) { $hbMin = [double]$nextMin }   # $isFin: one heartbeat
  $live = @($agents | Where-Object { -not (& $isFin $_) })
  $nxTail = if ("$($j.next)" -match '\((.+)\)\s*$') { " · $($Matches[1])" } else { '' }   # the pace reason, plain words
  $mem = $j.mem; $tot = [double]$mem.TotalGB; $avail = [double]$mem.AvailGB; $used = $tot - $avail; $st = $j.stats
  $diskLv = @{}; foreach ($f in @($flags | Where-Object level -in 'ACT', 'WATCH')) { if ("$($f.what)" -match '^disk (\S+?):' -and $diskLv[$Matches[1]] -ne 'ACT') { $diskLv[$Matches[1]] = $f.level } }   # storage floor / fill-rate flags per drive
  $disks = @($st.disks | Where-Object { $_ } | Sort-Object { $rk = $diskLv["$($_.drive)"]; if ($rk -eq 'ACT') { 0 } elseif ($rk -eq 'WATCH') { 1 } else { 2 } }, { [double]$_.free })   # every watched drive, a flagged one first
  $diskTone = { param($dv, [string]$hot = 'hot', [string]$warn = 'warn') $lvd = $diskLv["$dv"]; if ($lvd -eq 'ACT') { $hot } elseif ($lvd -eq 'WATCH') { $warn } else { '' } }
  # rate: GB/h over 11 min (storage verdict); the last hour's net change shows a drop it hides
  $diskRate = { param($dk, [switch]$Short) $r = [double]$dk.rate; $h1 = @($st.disks | Where-Object { $_ -and "$($_.drive)" -eq "$($dk.drive)" })[0].h1   # -Short: the tile line; the rest in its tooltip
    $rt = if ($r -ge 0.05) { "filling $(& $n1 $r) GB/h" } elseif ($r -le -0.05) { "freeing $(& $n1 (-$r)) GB/h" } else { 'steady' }; if ($Short) { return $rt }
    "$rt (11 min)$(if ($null -ne $h1) { " · last hour $(& $n1 ([math]::Abs([double]$h1))) GB $(if ([double]$h1 -lt 0) { 'used' } else { 'freed' })" })" }
  $markFile = Join-Path $script:KitRoot 'assets/claude-crew-mark.svg'; $mark = if (Test-Path -LiteralPath $markFile) { (Get-Content -LiteralPath $markFile -Raw) -replace '<\?xml[^>]*>\s*', '' -replace '\s+', ' ' } else { '' }
  # an icon per flag kind (first match on kind + problem); the kind also stays as text
  $fIco = @(@('STUCK|\bidle\b|stale|silent|pause', 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2'), @('disk|storage', 'M4 6c0-3 16-3 16 0v12c0 3-16 3-16 0zM4 6c0 3 16 3 16 0'), @('memory|\bRAM\b|gate|cache', 'M7 7h10v10H7zM9 3v4M15 3v4M9 17v4M15 17v4M3 9h4M3 15h4M17 9h4M17 15h4'),
    @('phone|lane|emulator', 'M8 2h8v20H8zM11 18h2'), @('lease|holder|ORPHAN|\block', 'M10 14a4 4 0 0 0 6 0l3-3a4 4 0 0 0-6-6l-1 1M14 10a4 4 0 0 0-6 0l-3 3a4 4 0 0 0 6 6l1-1'),
    @('build|compile|\btests?\b', 'M14 4l6 6-3 3-6-6zM11 7L3 15l3 3 8-8'), @('deploy|release', 'M12 2c4 3 5 8 3 13H9C7 10 8 5 12 2zM9 15l-3 4h3M15 15l3 4h-3M12 8h.01'),
    @('\bMR\b|task|tracker|promot|merge|decision', 'M5 12l4 4 10-10'), @('kit|lint|retro|param', 'M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2'),
    @('agent|shell', 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2'), @('.', 'M5 21V4h12l-2 4 2 4H5'))
  # a flag over 25 words: a one-line summary that opens to the full text (owner, 2026-11-13)
  $brief = { param([string]$t) $s = $t -replace '\([^()]{40,}\)', '(…)' -replace '(?:[A-Za-z]:)?(?:[^\s:()]*[\\/]){2,}([^\s\\/:()]+)', '$1'; $wd = @($s -split '\s+' | Where-Object { $_ }); if ($wd.Count -gt 25) { ($wd[0..24] -join ' ') + ' …' } else { $s } }
  $long = { param([string]$t) if (@($t -split '\s+' | Where-Object { $_ }).Count -le 25) { return & $e $t }; "<details class=lx><summary>$(& $e (& $brief $t))</summary><div class=lf>$(& $e $t)</div></details>" }
  $card ={ param($f) $c = Get-KitFlagCells $f; $lv = if ($f.level -eq 'ACT') { 'ACT' } else { 'WATCH' }; $ic = @($fIco | Where-Object { "$($c.kind) $($c.problem)" -match "(?i)$($_[0])" })[0]
    "<article class='flag $lv f' data-fit><div class=h><span class='chip lv $lv'>$lv</span><svg class=fi viewBox='0 0 24 24' aria-hidden=true><path fill=none d='$($ic[1])'/></svg>$(@(@($c.kind, $c.who | Where-Object { "$_".Trim() } | ForEach-Object { "<span>$(& $e $_)</span>" }) + @(if ("$($c.age)".Trim()) { & $minAgo $c.age })) -join '<span class=dot>·</span>')</div><div class=w>$(& $long $c.problem)</div>$(if ("$($c.action)".Trim()) { "<div class=n><b>Next</b> $(& $long $c.action)</div>" })</article>" }
  $info = @($flags | Where-Object level -eq 'INFO')
  # history: flags per sweep as lines, oldest left (ACT solid, WATCH dashed, FIXED dotted: told apart without colour)
  $hMax = [math]::Max(1, (@($hist | ForEach-Object { [math]::Max([math]::Max((& $hCount $_ 'ACT'), (& $hCount $_ 'WATCH')), [int]$_.fixed) }) + 0 | Measure-Object -Maximum).Maximum)
  $hSeries = @(@{ vals = @($hist | ForEach-Object { & $hCount $_ 'ACT' }); tone = 'act'; style = 'solid'; max = $hMax }, @{ vals = @($hist | ForEach-Object { & $hCount $_ 'WATCH' }); tone = 'watch'; style = 'dash'; max = $hMax }, @{ vals = @($hist | ForEach-Object { [int]$_.fixed }); tone = 'sage'; style = 'dot'; max = $hMax })
  # flags band: masonry cards | the trend (280 px, cards' height); below: fixed, promotion holds, notes (folded)
  $fixedI = @($info | Where-Object { "$($_.what)" -like 'auto-fixed:*' }); $holdI = @($info | Where-Object { "$($_.what)" -match '^HOLD \S+:' }); $restI = @($info | Where-Object { "$($_.what)" -notlike 'auto-fixed:*' -and "$($_.what)" -notmatch '^HOLD \S+:' })
  $flagCards = if ($nAct + $nWatch) { "<div class=fmas style='--cmin:300px' data-mas>$(@($flags | Where-Object level -in 'ACT', 'WATCH' | Sort-Object { $_.level -ne 'ACT' } | ForEach-Object { & $card $_ }) -join '')</div>" } else { '<p class=empty>All clear: no ACT or WATCH flag.</p>' }
  $fixedHtml = $(if ($fixedI.Count) { & $fold 'fixed' 'Fixed this sweep' $fixedI.Count (& $grid info 280px @($fixedI | ForEach-Object { "<li class=f>$(& $e ("$($_.what)" -replace '^auto-fixed:\s*'))</li>" }) 0 ul) -cls sub })
  # in the side panel only: the history trend (each count once: the header chips are this sweep, the chart the last 12)
  $trendFig = if ($hist.Count -ge 2) { "<figure class=ftr><div class=lcp role=img aria-label='flags per sweep, last $($hist.Count) sweeps'>$(Format-KitLineChart @($hist) $hSeries '' -Bare)</div><figcaption>flags per sweep, last $($hist.Count) · <i class='lgd t-act'></i>ACT <i class='lgd t-watch ds'></i>WATCH <i class='lgd t-sage dd'></i>FIXED · peak $hMax</figcaption></figure>" }
  # a hold row: task (linked) · why (deferred count or who it waits on) · reason, wrapped; the release command once, below
  $holdRow = { param([string]$w) $null = $w -match '^HOLD (?<t>[^\s:]+):\s*(?<why>.*?)(?:;\s*release:\s*(?<cmd>.+))?$'; $tid = $Matches.t; $why = "$($Matches.why)"
    $its = @(if ($why -match '\((?<k>deferred items|waiting on [^:]+):\s*(?<l>.+)\)\s*$') { $hk = $Matches.k; ([regex]::Split($Matches.l, ',(?![^()]*\))')) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } } else { $hk = ''; $why })   # @(): one item stays a list, never its first letter
    $url = try { "$(Get-TrackerUrl $tid)" } catch { '' }; $tl = if ($url -match '^https?://') { "<a href='$(& $e $url)' target=_blank rel=noopener>$(& $e $tid)</a>" } else { & $e $tid }
    "<li class='f hr'><b class=ht>$tl</b><span class=hn>$(if ($hk -like 'deferred*') { "$($its.Count) deferred" } elseif ($hk) { & $e $hk } else { 'held' })</span><span class=hw>$(& $e ($its -join ', '))</span></li>" }
  $holdCmd = @($holdI | ForEach-Object { if ("$($_.what)" -match ';\s*release:\s*(?<c>.+)$') { $Matches.c.Trim() -replace '-Task \S+', '-Task <task>' } } | Select-Object -Unique)
  # notes of one kind about several subjects ("RAM FLOOR: rm ...", "... hm ..." same rest): one line listing them
  $noteKey = { param([string]$w) if ($w -cmatch '^(?<k>[A-Z][A-Z0-9 -]+):\s*(?<s>\S+)\s+(?<r>.+)$') { $Matches } }
  $notes = @(@($restI | ForEach-Object { "$($_.what)" }) | Group-Object { $m = & $noteKey $_; if ($m) { "$($m.k)|$($m.r)" } else { $_ } } | ForEach-Object { if ($_.Count -gt 1) { $m0 = & $noteKey $_.Group[0]; "$($m0.k): $(@($_.Group | ForEach-Object { (& $noteKey $_).s }) -join ', ') $($m0.r)" } else { $_.Group[0] } })
  $flagBelow = $(if ($holdI.Count) { & $fold 'holds' 'Promotion holds' $holdI.Count "<ul class=hold>$(@($holdI | ForEach-Object { & $holdRow "$($_.what)" }) -join '')</ul>$(if ($holdCmd.Count) { "<p class=hc>release: $(@($holdCmd | ForEach-Object { "<code class=cp title='Click to copy'>$(& $e $_)</code>" }) -join ' ')</p>" })" -cls sub }) + $(if ($notes.Count) { & $fold 'notes' 'Notes' $notes.Count (& $grid info 280px @($notes | ForEach-Object { "<li class=f>$(& $e $_)</li>" }) 0 ul) -cls sub })
  # the folded lists share one row (an open one: full width)
  $flagHtml = $(if ($trendFig) { "<div class=fl data-row>$flagCards$trendFig</div>" } else { $flagCards }) + $(if ("$fixedHtml$flagBelow") { "<div class=fbl>$fixedHtml$flagBelow</div>" })
  # live agents by run, what each does now; finished ones folded (steps, tokens, cost: Runs)
  # the leases an agent holds, on its row: a resource whose holder list names the agent's id (the name's first word)
  $leaseOf = { param($nm) $aid = ("$nm" -split ' ')[0]; if (-not $aid -or "$nm" -notmatch ' \(') { return '' }; $hs = @($j.resources | Where-Object { $_ -and "$($_.by)" -match "(^|[\s,;:])$([regex]::Escape($aid))([\s,;]|$)" })
    if ($hs.Count) { "<div class=lc>$(@($hs | ForEach-Object { "<span class='chip ls' title='$(& $e "$($_.name) · $(& $n1 $_.gb) GB")'>$(& $e $_.name)</span>" }) -join '')</div>" } }
  $agT = { param($list) '<div class=tw><table class=ag><tr><th>State</th><th>Agent</th><th class=hs>Task</th><th>Since</th><th>Last progress</th><th class=hs>Doing · next</th></tr>' + (@(foreach ($g in @($list | Group-Object { if ("$($_.run)" -in '', 'solo') { '' } else { "$($_.run)" } } | Sort-Object { -not $_.Name }, Name)) {
    $rl = if ($g.Name) { "$(@($st.usage.runs | Where-Object { $_ -and "$($_.run)" -eq $g.Name -and "$($_.label)".Trim() })[0].label)".Trim() }   # a run's label (mandate or area) when it has one
    "<tbody class=grp><tr class=gh><th colspan=6><span class=gn0>$(if (-not $g.Name) { 'standalone agents' } elseif ($rl) { "$(& $e $rl) <small>$(& $e $g.Name)</small>" } else { & $e $g.Name })</span></th></tr>" +
    (@(foreach ($a in @($g.Group | Sort-Object name)) { $sub = @($a.wait, $a.done, $a.stopped | Where-Object { "$_".Trim() }) -join ' · '
      "<tr class=f><td><span class='chip $(& $stCls $a.state)'>$(& $e ("$($a.state)" -replace '\s.*'))</span>$(if ($sub) { "<div class=sm>$(& $e $sub)</div>" })</td><td>$(& $e $a.name)$(& $leaseOf $a.name)</td><td class=hs>$(& $e ("$($a.task)" -replace ' · steps \d+/\d+ · [\d.]+[kKmMB]? tokens of [\d.]+[kKmMB]?'))</td><td>$(& $when $a.since)</td><td>$(& $when $a.last)</td><td class=hs>$(& $e $a.doing)$(if ("$($a.next)".Trim()) { "<div class=sm>$(& $e $a.next)</div>" })</td></tr>" }) -join '') + '</tbody>' }) -join '') + '</table></div>' }
  $fin = @($agents | Where-Object { & $isFin $_ })
  # agents by state: one stacked bar in the Agents header, its counts as the section's text
  $byState = @(@(@('s-act', 'running'), @('s-oth', 'waiting'), @('s-stuck', 'stuck'), @('s-fin', 'done today')) | ForEach-Object { $cl = $_[0]; $nb = @($agents | Where-Object { $(if (& $isFin $_) { 's-fin' } else { & $stCls $_.state }) -eq $cl }).Count; if ($nb) { [pscustomobject]@{ c = $cl; n = $nb; t = "$nb $($_[1])" } } })
  $agBar = if ($byState.Count) { "<span class=sbh role=img aria-label='$(& $e ($byState.t -join ', '))'>$(@($byState | ForEach-Object { "<i class=$($_.c) style='flex:$($_.n)'></i>" }) -join '')</span>" }
  $agLive = @($byState | Where-Object c -ne 's-fin'); $agCnt = if (-not $byState.Count) { 0 } elseif ($agLive.Count) { @{ h = @($agLive | ForEach-Object { & $icv $(switch ($_.c) { 's-act' { 'run' } 's-stuck' { 'stuck' } default { 'queue' } }) ($_.t -replace '^\d+ ') $_.n }) -join '' } } else { '' }   # live states as icon counts
  $agentHtml = $(if ($live.Count) { & $agT $live } else { '<p class=empty>No live agent.</p>' }) + $(if ($fin.Count) { & $fold 'agents-done' 'Finished today' $fin.Count (& $agT $fin) -cls sub })
  # statistics: the agents-failed day records ('—' = no source)
  $days = @($st.days | Where-Object { $_ }); $dayKey = { param([int]$back) $at.AddDays(-$back).ToString('yyyy-MM-dd') }
  $fmt = { param($v) if ($null -eq $v) { '—' } else { & $n1 $v } }
  $fxRaised = @($hist | ForEach-Object { (& $hCount $_ 'ACT') + (& $hCount $_ 'WATCH') + [int]$_.fixed }); $fxFixed = @($hist | ForEach-Object { [int]$_.fixed })
  # stats.now + 7 days of stats.live: a change shows in graphs, never as delta text (owner, 2026-11-14)
  $nw = $st.now; $lv = @($st.live | Where-Object { $_ })
  $agg = { param([scriptblock]$pick) $vs = @($lv | ForEach-Object $pick | Where-Object { $null -ne $_ }); if ($vs.Count) { & $n1 ($vs | Measure-Object -Maximum).Maximum } else { '—' } }   # 7-day peak
  $nowCard = { param([string]$label, [string]$vHtml, [string]$sub, [string]$week, [string]$cls = '', [string]$sp = '') "<div class='st $cls' data-fit><div class=k>$(& $e $label)</div><div class=v>$vHtml</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })$(if ($week) { "<div class=w>$(& $e $week)</div>" })$sp</div>" }
  # machine row: memory (the board's sample), all watched disks in one tile, build gate + QA seats in one tile
  $memPct = if ($null -ne $nw.mem) { $nw.mem } elseif ($tot) { [math]::Round(100 * $used / $tot) }; $memFree = if ($null -ne $nw.avail) { $nw.avail } elseif ($tot) { $avail }
  $dkTone = { param($dk, $ttf) $dv = "$($dk.drive)"; if (& $diskTone $dv) { & $diskTone $dv } elseif ($null -eq $ttf) { '' } elseif ($ttf -lt 24) { 'hot' } else { 'warn' } }
  $dkRows = @(foreach ($dk in @(@(if (@($nw.disks | Where-Object { $_ }).Count) { $nw.disks } else { $disks }) | Where-Object { $_ } | Sort-Object -Stable { $tz = & $diskTone $_.drive; if ($tz -eq 'hot') { 0 } elseif ($tz) { 1 } else { 2 } })) {
    $dv = "$($dk.drive)"; $ttf = if ($null -ne $dk.ttf -and [double]$dk.ttf -lt 72) { [double]$dk.ttf }; $tn = & $dkTone $dk $ttf   # full-in only under 72 h
    $dt = [double]@($disks | Where-Object { "$($_.drive)" -eq $dv })[0].total; $dw = @($lv | ForEach-Object { if ($_.disks) { $_.disks.$dv } } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $mtr = if ($dt) { & $meter ($dt - [double]$dk.free) $dt "$([math]::Round(100 * ($dt - [double]$dk.free) / $dt))% of $(& $n1 $dt) GB used" $(if ($tn -eq 'hot') { 'act' } elseif ($tn) { 'watch' } else { 'slate' }) $(if ($dw.Count) { $dt - ($dw | Measure-Object -Minimum).Minimum }) }
    [pscustomobject]@{ tone = $tn; h = "<div class='dk $tn' title='$(& $e (& $diskRate $dk))'><div class=v><span class=dn0>$(& $e $dv)</span> $(& $fmt $dk.free)<small>$(& $e " GB free · $(& $diskRate $dk -Short)$(if ($null -ne $ttf) { " · full in $(& $n1 $ttf) h" })")</small></div>$mtr$(& $spark $dw 'slate' 'free GB, 7 days' 'low')</div>" } })
  # QA seats as slots (filled = taken), up to 24; the numbers stay in the tile
  $dots = { param($u, $m) $u = [int]$u; $m = [math]::Min(24, [int]$m); if ($m -le 0) { return '' }; "<div class=dots role=img aria-label='$u of $m QA seats taken'>$(@(1..$m | ForEach-Object { "<i$(if ($_ -le $u) { ' class=on' })></i>" }) -join '')</div>" }
  $l24 = @($lv | Where-Object { $_.at -and [datetime]$_.at -ge $at.AddDays(-1) }); $memPk = & $agg { $_.mem }; $usedGB = if ($tot -and $null -ne $memPct) { $tot * [double]$memPct / 100 }
  # build gate: a row per kind from its history; RAM capacity dots; QA seats, phone lanes, emulators
  $gs = $st.gate; $gateOld = 
(& $nowCard 'Build gate · QA seats' "$(& $icv run 'running builds' (& $fmt $nw.gr))$(& $icv queue 'queued builds' (& $fmt $nw.gq))<small> · seats </small>$(& $fmt $nw.seats)<small> / $(& $fmt $nw.seatsMax)</small>" "longest wait $(& $fmt $nw.gw) min · 7-day peak $(& $agg { $_.gw }) min" '' $(if ($nw.gw -ge 30) { 'hot' } elseif ($nw.gq -ge 6) { 'warn' }) "$(& $dots $nw.seats $nw.seatsMax)$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queue, 24 h' 'peak' 0)")
  $gateCard = if (-not $gs) { $gateOld } else {
    $fl = [math]::Max(0, [double]$j.mem.AvailGB - [double]$st.keepFree); $gb = [math]::Min(24, [int][math]::Ceiling([double]$gs.ram + $fl))   # 1 dot = 1 GB: promised to running builds, then free above the floor
    $ramDots = if ($gb -gt 0) { "<div class=dots role=img aria-label='RAM for builds: $(& $n1 $gs.ram) GB promised, $(& $n1 $fl) GB free above the floor'>$(@(1..$gb | ForEach-Object { "<i$(if ($_ -le [math]::Round([double]$gs.ram)) { ' class=on' })></i>" }) -join '')</div><div class=s>RAM: $(& $n1 $gs.ram) GB promised · $(& $n1 $fl) GB free above the $(& $n1 $st.keepFree) GB floor</div>" }
    # one line per kind: name · 24 h heatmap (square-root shade: a short build still shows) · running, queued, today, waits, RAM
    # under one header row (hour labels, icons); zeros dimmed (owner, 2026-11-13)
    $gCols = @(@('run', 'running builds', ''), @('queue', 'queued builds', ''), @('today', 'builds today', ''), @('wait', 'wait avg, min', 'avg'), @('wait', 'wait peak, min', 'peak'), @('ram', 'RAM GB: now, or up to (24 h peak)', 'GB'))
    $h0 = try { [datetime]$gs.h0 } catch { $null }; if (-not $h0) { $h0 = $at.Date.AddHours($at.Hour - 23) }
    $hLab = @(for ($hi = 0; $hi -lt 21; $hi++) { if ($h0.AddHours($hi).Hour % 6 -eq 0) { "<b style='grid-column:$($hi + 1)/span 2'>$($h0.AddHours($hi).ToString('HH'))</b>" } }) + "<b class=nw style='grid-column:23/span 2'>now</b>"
    $gHead = "<div class='gk gh'><span class=gn>kind · hour</span><span class='gs0 hrs' aria-hidden=true>$($hLab -join '')</span>$(@($gCols | ForEach-Object { "<span class=gc>$(Format-KitIcon $_[0] $_[1])$(if ($_[2]) { "<small>$($_[2])</small>" })</span>" }) -join '')</div>"
    $heat = { param($kr, [string]$nm) $hs = @($kr.hours); "<span class='gs hm' role=img aria-label='$(& $e "$nm, builds per hour, last 24 h")'>$(@(for ($hi = 0; $hi -lt 24; $hi++) { $hv = if ($hi -lt $hs.Count) { @($hs[$hi]) } else { @(0, 0, 0) }; $bm = [double]$hv[1]
          "<i$(if ($hi -eq 23) { ' class=nw' }) style='--a:$(if ($bm -gt 0) { & $n1 ([math]::Round(25 + 75 * [math]::Sqrt([math]::Min(1, $bm / 60)))) } else { 0 })%' title='$(& $e "$($h0.AddHours($hi).ToString('HH:00'))$(if ($hi -eq 23) { ' (now)' }) · $nm · $([int]$hv[0]) builds · $(& $n1 $bm) build-min · max wait $(& $n1 $hv[2]) min")'></i>" }) -join '')</span>" }
    $kRows = @($gs.rows | Where-Object { $_ } | ForEach-Object { $kr = $_; $nm = "$($kr.name)"
        $ram = if ([double]$kr.ram) { @((& $n1 $kr.ram), "$(& $n1 $kr.ram) GB now", ' nw') } elseif ([double]$kr.peakGB) { @("≤$(& $n1 $kr.peakGB)", "up to $(& $n1 $kr.peakGB) GB", '') } else { @('—', 'no RAM sample', ' z') }
        $vals = @("$([int]$kr.running)", "$([int]$kr.queued)", "$([int]$kr.done)", (& $n1 $kr.waitAvg), (& $n1 $kr.waitMax))
        $w = "$($vals[0]) running · $($vals[1]) queued · $($vals[2]) today · wait avg $($vals[3]) / peak $($vals[4]) min · $($ram[1])"
        # each cell carries its icon too: shown only under 700 px, where a row sits far from the header row
        $cells = @(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($vals[$ci] -eq '0') { ' z' })' title='$(& $e "${nm}: $($vals[$ci]) $($gCols[$ci][1])")'>$(Format-KitIcon $gCols[$ci][0] $gCols[$ci][1])$($vals[$ci])</span>" }) + "<span class='gc$($ram[2])' title='$(& $e "${nm}: $($ram[1])")'>$(Format-KitIcon ram 'RAM GB')$(& $e $ram[0])</span>"
        "<div class=gk><span class=gn title='$(& $e "${nm}: $w")'>$(& $e $nm)</span>$(& $heat $kr $nm)$($cells -join '')</div>" })
    "<div class='st $(if ($gs.waitMax -ge 30) { 'hot' } elseif ($gs.queued -ge 6) { 'warn' })' data-fit><div class=k>Build gate · QA seats</div><div class=v>$(& $icv run 'running builds' (& $fmt $gs.running))$(& $icv queue 'queued builds' (& $fmt $gs.queued))$(& $icv today 'builds today' (& $fmt $gs.today))$(& $icv wait 'longest wait today' (& $n1 $gs.waitMax) ' min')</div>" +
    "<div class=gl><div>$(if ($kRows.Count) { "<div class=gks>$gHead$($kRows -join '')</div><div class=hk>shade = busy minutes in that hour · outlined = now · tap a cell for builds and waits</div>" } else { '<div class=s>no gated build in 24 h</div>' })</div>" +
    "<div class=gp>$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queued builds, 24 h' 'peak' 0)$ramDots$(& $dots $nw.seats $nw.seatsMax)<div class=s>QA seats $(& $fmt $nw.seats) / $(& $fmt $nw.seatsMax)</div>$(if ($gs.lanes) { "<div class=s>phone lanes $($gs.leased) / $($gs.lanes) leased · emulators $($gs.emulators) running</div>" })$(if ($gs.browsers) { "<div class=s>test browsers $($gs.browsers) ($(& $n1 $gs.browserGB) GB, leased)</div>" })</div></div></div>" }
  # rows of like height (owner, 2026-11-13): Memory | Disks, then the Build gate full width
  $machCards = @(
    (& $nowCard 'Memory' "$(& $fmt $memPct)<small>% used</small>" "$(if ($usedGB) { "$(& $n1 $usedGB) / $(& $n1 $tot) GB used · " })$(& $fmt $memFree) GB free · floor $(& $fmt $st.keepFree) GB" "" $(if ($memPct -ge 90) { 'hot' } elseif ($memPct -ge 75) { 'warn' }) "$(if ($usedGB) { & $meter $usedGB $tot "$(if ($memPk -ne '—') { "tick = 7-day peak $memPk%" } else { "of $(& $n1 $tot) GB" })" 'slate' $(if ($memPk -ne '—') { $tot * [double]$memPk / 100 }) })$(& $spark @($l24 | ForEach-Object mem) 'slate' 'used %, 24 h' 'peak' $null '%')"),
    "<div class='st $(if ($dkRows.tone -contains 'hot') { 'hot' } elseif (@($dkRows | Where-Object tone).Count) { 'warn' })' data-fit><div class=k>Disks$(if ($lv.Count) { '<small> · tick = 7-day peak use</small>' })</div>$(if ($dkRows.Count) { & $grid dks 190px @($dkRows.h) 2 } else { '<div class=v>—</div><div class=s>no sample</div>' })</div>",
    $gateCard)
  $machineHtml = "<div class=mcol>$(& $grid 'stats mach' 300px @($machCards[0], $machCards[1]) 2)$($machCards[2])</div>"
  # Activity (owner, 2026-11-14): actionable tiles, each number once, history as labelled graphs
  $nst = @($nw.stale | Where-Object { $_ }); $runOf = @{}; foreach ($ur in @($st.usage.runs | Where-Object { $_.id })) { $runOf["$($ur.id)"] = $ur }
  $wfTile = if ($nw) { "<div class='st$(if ($nst.Count) { ' warn' })' data-fit><div class=k>Workflow steps now</div><div class=v>$(& $icv run 'running steps' (& $fmt $nw.run))<small>running$(if ($null -ne $nw.total) { " · </small>$($nw.done)/$($nw.total)<small> steps" })</small></div><div class=rch>" +
    (@($nw.wfr | Where-Object { [int]$_.run } | ForEach-Object { $ur = $runOf["$($_.id)"]; "<span class='chip s-act' title='$(& $e "$(@($_.id, $ur.label | Where-Object { $_ }) -join ' · ') · $($_.done)/$($_.total) steps · $($_.run) running")'>$(& $e $(if ($ur.run) { $ur.run } else { $_.id }))</span>" }) -join '') +
    "</div>$(if ($nst.Count) { "<div class=s>$($nst.Count) stale: $(& $e ($nst -join ', '))</div>" })$(& $spark @($l24.run) 'sage' 'running steps, 24 h' 'peak' 0 '' -Step -NoNow)</div>" }
  # branches · worktrees (bossy.ps1 cleanup): a row per repo, by count; daily totals (else per sweep) as two lines
  $brTile = if (($rr = @($st.repos.repos | Where-Object { [int]$_.branches + [int]$_.worktrees } | Sort-Object { -[int]$_.branches }, { -[int]$_.worktrees })).Count) {
    $sm = @{}; foreach ($k in 'branches', 'worktrees', 'kept', 'removable') { $sm[$k] = [int](@($rr.$k) + 0 | Measure-Object -Sum).Sum }; $bMax = [math]::Max(1, (@($rr.branches) + @($rr.worktrees) | Measure-Object -Maximum).Maximum)
    $bs = @($lv | Where-Object { $null -ne $_.br }); $bd = @($bs | Group-Object { ([datetime]$_.at).Date } | ForEach-Object { $_.Group[-1] }); $bp = if ($bd.Count -ge 2) { $bd } else { @($bs | Select-Object -Last 24) }
    $brChart = if ($bp.Count -ge 2) { $bLo = [math]::Max(0, (@($bp.br) + @($bp.wt) | Measure-Object -Minimum).Minimum - 2); $bTop = (@($bp.br) + @($bp.wt) | Measure-Object -Maximum).Maximum; $bWin = "last $($bp.Count) $(if ($bd.Count -ge 2) { 'days' } else { 'sweeps' })"
      "<div class=lcp style='height:40px;margin-top:4px' role=img aria-label='branches and worktrees, $bWin, y $bLo-$bTop'>$(Format-KitLineChart @($bp | ForEach-Object { @{} }) @(foreach ($s in @('br', 'sage', 'solid'), @('wt', 'slate', 'dash')) { @{ vals = @($bp | ForEach-Object { [int]$_.($s[0]) - $bLo }); tone = $s[1]; style = $s[2]; max = [math]::Max(1, $bTop - $bLo) } }) '' -Bare)</div><div class=ax><span><i class='lk t-sage'>branches</i> <i class='lk t-slate dash'>worktrees</i></span><span class=gc>$bWin · y $bLo-$bTop</span></div>" }
    "<div class='st$(if ($sm.removable) { ' warn' })' data-fit><div class=k>Branches · worktrees</div><div class=v>$($sm.branches)<small> br · </small>$($sm.worktrees)<small> wt</small></div><div class=rpt><div class='rp rh'><span class=rn>repo</span><span></span><span class=rc><i class=sw1></i>br</span><span class=rc><i class=sw2></i>wt</span></div>" +
    (@($rr | ForEach-Object { "<div class=rp title='$(& $e "$($_.repo): $([int]$_.branches) branches · $([int]$_.worktrees) worktrees$(if ($_.kept) { " · $($_.kept) kept" })")'><span class=rn>$(& $e $_.repo)</span><span class=rbr aria-hidden=true><i style='width:$(& $n1 (100 * $_.branches / $bMax))%'></i><b style='width:$(& $n1 (100 * $_.worktrees / $bMax))%'></b></span><span class=rc>$(if ($_.branches) { $_.branches })</span><span class=rc>$(if ($_.worktrees) { $_.worktrees })</span></div>" }) -join '') +
    "</div>$brChart<div class=s>$($sm.kept) kept (unpushed/open/dirty) · $($sm.removable) to clean · cleanup $(try { ([datetime]$st.repos.at).ToString('HH:mm') } catch { '?' })</div></div>" }
  $swAll = @($lv.secs | Where-Object { $null -ne $_ })   # sweep time: slowest step, 24 h with the 7-day average dotted
  $swTile = if ($nw) { & $nowCard 'Sweep time' "$(& $fmt $nw.secs)<small> s</small>" $nw.slow '' 'lo' (& $spark @($l24.secs) 'slate' 'sweep, 24 h' 'peak' $null ' s' $(if ($swAll.Count) { ($swAll | Measure-Object -Average).Average }) '7-day avg' -NoNow) }
  # agents failed: the 7-day total, a labelled bar per day
  $fd = @(6..0 | ForEach-Object { $dk = & $dayKey $_; [pscustomobject]@{ d = $dk; v = @($days | Where-Object { "$($_.day)" -eq $dk -and $null -ne $_.failed })[0].failed; x = -not $_ } }); $fdK = @($fd.v | Where-Object { $null -ne $_ }); $fdMax = [math]::Max(1, ($fdK + 0 | Measure-Object -Maximum).Maximum); $fdN = ($fdK | Measure-Object -Sum).Sum
  $failTile = "<div class='st$(if ($fdN) { ' warn' })' data-fit><div class=k>Agents failed</div><div class=v>$(if ($fdK.Count) { $fdN } else { '—' })<small> in 7 days</small></div>" + $(if ($fdK.Count) { "<figure class=dbr><div class=dbw role=img aria-label='agents failed per day, 7 days'>$(@($fd | ForEach-Object { "<span class='dbc$(if ($_.v) { ' on' } else { ' z' })' title='$($_.d): $(if ($null -ne $_.v) { "$($_.v) failed" } else { 'no calls log' })'><b>$(if ($null -ne $_.v) { $_.v } else { '—' })</b><i style='height:calc((100% - 12px) * $(& $n1 ($_.v / $fdMax)))'></i></span>" }) -join '')</div>" +
    "<div class=dbx>$(@($fd | ForEach-Object { if ($_.x) { '<span class=x>today</span>' } else { "<span>$(([datetime]$_.d).ToString('ddd', $iv))</span>" } }) -join '')</div><figcaption>agents failed per day, 7 days</figcaption></figure>" }) + '</div>'
  $fxSum = ($fxFixed + 0 | Measure-Object -Sum).Sum; $rxSum = ($fxRaised + 0 | Measure-Object -Sum).Sum   # flags auto-fixed: the share over the window, % per sweep
  $fxTile = "<div class=st data-fit><div class=k>Flags auto-FIXED</div><div class=v>$(if ($rxSum) { [math]::Round(100 * $fxSum / $rxSum) } else { '—' })<small>%</small></div><div class=w>$fxSum of $rxSum flags</div>$(& $spark @(for ($i = 0; $i -lt $hist.Count; $i++) { if ($fxRaised[$i]) { [math]::Round(100 * $fxFixed[$i] / $fxRaised[$i]) } }) 'sage' "per sweep, last $($hist.Count)" 'peak' 0 '%')</div>"
  $kitTiles = & $grid stats 220px @($wfTile, $brTile, $swTile, $failTile, $fxTile)
  $UP = Format-KitUsageHtml $st.usage
  # a resource card: RAM over 24 h (samples' res) as a sparkline; a leasable one its holders as a timeline (a colour each, idle empty);
  # shared (row.shared): never an orphan; leasable with no live holder: orphan (released after idle.graceMinutes)
  $resCard = { param($r) $nm = "$($r.name)"; $pts = @(@($l24 | Where-Object { [datetime]$_.at -lt $at } | ForEach-Object { $x = if ($_.res) { $_.res.$nm }; [pscustomobject]@{ gb = $(if ($x) { [double]$x.gb } else { 0 }); by = "$(if ($x) { $x.by })".Trim(); at = $_.at } }) + [pscustomobject]@{ gb = [double]$r.gb; by = "$($r.by)".Trim(); at = $at })
    $by = "$($r.by)".Trim(); $orphan = -not $r.shared -and $by -match '^$|\(grace|^no lease$'; $hs = @($pts.by | Where-Object { $_ } | Select-Object -Unique)
    $tl = if (-not $r.shared -and $pts.Count -ge 2) { "<div class=lt role=img aria-label='$(& $e "holders, 24 h: $(if ($hs.Count) { $hs -join ', ' } else { 'none' })")'>$(@(for ($i = 0; $i -lt $pts.Count; $i++) { $h0 = $pts[$i].by; $k = $i; while ($k + 1 -lt $pts.Count -and $pts[$k + 1].by -eq $h0) { $k++ }
      "<i class=h$(if ($h0) { [array]::IndexOf($hs, $h0) % 4 } else { 'x' }) style='width:$(& $n1 (100 * ($k - $i + 1) / $pts.Count))%' title='$(& $e "$(if ($h0) { $h0 } else { 'idle' }) $(([datetime]$pts[$i].at).ToString('HH:mm'))-$(([datetime]$pts[$k].at).ToString('HH:mm'))")'></i>"; $i = $k }) -join '')</div>" }
    $ri = & $item $nm "$(if ($r.shared) { 'shared · always on' } elseif ($by) { $by } else { 'no live holder' })" "$(if (@($pts | Where-Object gb).Count) { & $spark $pts.gb 'slate' 'RAM GB, 24 h' '' 0 })$tl" $(if ([double]$r.gb) { & $icv ram 'RAM GB now' (& $n1 $r.gb) ' GB' })
    if ($orphan) { $ri -replace "^<div class='ci f'", "<div class='ci f orphan'" } else { $ri } }
  $resHtml = if (-not @($j.resources | Where-Object { $_ }).Count) { '<p class=empty>No resource held.</p>' } else { & $grid res 260px @($j.resources | Where-Object { $_ } | Sort-Object { -[double]$_.gb } | ForEach-Object { & $resCard $_ }) }
  # a command on one line, cut at 120 chars with an ellipsis in the text (no CSS clip), the whole one a click away
  $cmdCell = { param([string]$c) $full = "$c".Trim(); $one = $full -replace '\s+', ' '; if ($one -eq $full -and $one.Length -le 120) { return $one }
    $hd = if ($one.Length -gt 120) { $one.Substring(0, 119).TrimEnd() + '…' } else { $one }
    @{ h = "<details class=cmd><summary title='$(& $e $one)'>$(& $e $hd)</summary><div class=cmdf>$(& $e $full)</div></details>" } }
  # Dir only when a shell runs outside the kit, Next only when one has a step; Command takes the free width (colgroup)
  $shRows = @($j.shells | Where-Object { $_ }); $kitDirNorm = "$script:KitRoot".TrimEnd('\', '/') -replace '\\', '/'
  $shDir = { param($s) $dn = "$($s.dir)".TrimEnd('\', '/') -replace '\\', '/'; if ($dn -and $dn -ne $kitDirNorm) { "$($s.dir)" } else { '' } }
  $shDirOn = [bool]@($shRows | Where-Object { & $shDir $_ }).Count; $shNextOn = [bool]@($shRows | Where-Object { "$($_.next)".Trim() }).Count
  $shCols = @('PID', 'Owner', 'Age', 'State') + @(if ($shDirOn) { 'Dir' }) + 'Command' + @(if ($shNextOn) { 'Next' })
  $shWidths = @('64px', '12%', '64px', '76px') + @(if ($shDirOn) { '14%' }) + 'auto' + @(if ($shNextOn) { '15%' })
  $shAge = { param($v) if ("$v" -match '^\s*(\d+(?:\.\d+)?)(?: min)?\s*$') { $tx = $at.AddMinutes(-[double]$Matches[1]); "<span class=ago data-t='$($tx.ToString('o'))' title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $tx)</span>" } else { & $e $v } }
  $shellHtml = (& $table $shCols @($shRows | ForEach-Object { $sr = $_; , @(@($sr.pid, $sr.owner, @{ h = & $shAge $sr.age }, $sr.state) + @(if ($shDirOn) { & $shDir $sr }) + @(& $cmdCell "$($sr.cmd)") + @(if ($shNextOn) { "$($sr.next)" })) })) -replace '^<div class=tw><table>', "<div class=tw><table><colgroup>$(@($shWidths | ForEach-Object { "<col style='width:$_'>" }) -join '')</colgroup>"
  $setRows = @(if ($st.settings) { $st.settings.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) } })
  $chg = @($st.changes | Where-Object { $_ }); [array]::Reverse($chg); $prm = @($st.params | Where-Object { $_ }); $hm = { param($x) if ($x) { try { ([datetime]$x).ToString('MM-dd HH:mm') } catch { "$x" } } else { '' } }   # '' keeps the cell: an empty result drops it from the row
  # Tuning: every tunable once, by area; source = default / local config / learned; the last 10 changes inside
  $tv = { param($v) if ($null -eq $v) { '' } elseif ($v -is [string] -or $v -is [ValueType]) { "$v" } else { $v | ConvertTo-Json -Compress -Depth 4 } }
  # state (· suffix: config) -> words; pinned / frozen / shadow stay their own word (a shadow is a proposal, not applied)
  $tSrc = { param([string]$s, [string]$note, $dflt) if ($s -match '· |config|override|local') { "local config$(if ("$dflt" -ne '') { " (default $dflt)" })" } elseif ($s -match '^(live|approved|learned)') { "learned ($s$(if ($note) { ", $note" }))" } elseif ($s -match '^default') { 'default' } else { "$s$(if ($note) { " ($note)" })" } }
  $tun = @(@($prm | ForEach-Object { [pscustomobject]@{ key = "$($_.key)"; ctx = $(if ("$($_.ctx)" -in '', '_') { '' } else { "$($_.ctx)" }); val = & $tv $_.value; src = & $tSrc "$($_.source)" "$($_.learned)" $null; chg = & $hm $_.changed; why = "$($_.why)" } }) +
    @($setRows | Where-Object { $sk = $_[0]; -not @($prm | Where-Object { "$($_.key)" -eq $sk -and "$($_.ctx)" -in '', '_' }).Count } | ForEach-Object { $sv = $_[1]; $hasSrc = $null -ne $sv -and $sv.PSObject.Properties.Name -contains 'source'
      [pscustomobject]@{ key = $_[0]; ctx = ''; val = & $tv $(if ($hasSrc) { $sv.value } else { $sv }); src = $(if ($hasSrc) { & $tSrc "$($sv.source)" '' $sv.default } else { '' }); chg = ''; why = '' } }))
  $tunT = '<div class=tw><table class=tun><tr><th>Key</th><th>Context</th><th>Value</th><th>Source</th><th class=lo>Changed</th><th class=hs>Why</th></tr>' + (@(foreach ($g in @($tun | Group-Object { ($_.key -split '\.')[0] } | Sort-Object Name)) {
      "<tbody class=grp><tr class=gh><th colspan=6><span class=gn0>$(& $e $g.Name)</span> <span class=cnt>($($g.Count))</span></th></tr>" + (@($g.Group | Sort-Object key, ctx | ForEach-Object { "<tr class=f><td data-k=Key>$((& $e $_.key) -replace '\.', '.<wbr>')</td><td data-k=Context>$(& $e $_.ctx)</td><td data-k=Value>$((& $e $_.val) -replace '([,/|])', '$1<wbr>')</td><td data-k=Source>$(& $e $_.src)</td><td data-k=Changed class=lo>$(& $e $_.chg)</td><td data-k=Why class=hs>$(& $e $_.why)</td></tr>" }) -join '') + '</tbody>' }) -join '') + '</table></div>'
  $chgL = if ($chg.Count) { "<h4 class=sh4>Recent changes</h4>" + (& $grid info 280px @($chg | Select-Object -First 10 | ForEach-Object { "<li class=f>$(& $e "$(& $hm $_.at) $($_.key)$(if ("$($_.ctx)" -notin '', '_') { " [$($_.ctx)]" }) $($_.from) -> $($_.to)$(if ($_.why) { ": $($_.why)" })")</li>" }) 0 ul) }
  $setHtml = & $fold 'tuning' 'Tuning' $tun.Count "$chgL<div class=fx>$tunT</div>" -cls sub
  $css = Get-KitSupervisePageCss
  $fav = if ($mark) { "<link rel=icon href='data:image/svg+xml,$([Uri]::EscapeDataString($mark))'>" }
  $js = "(function(){var d=document,L=localStorage,S=sessionStorage,r=d.documentElement,a=d.getElementById('age'),t=new Date(a.dataset.at),n=+a.dataset.next||15,nx=d.getElementById('nx'),same=S.getItem('kc-at')==a.dataset.at;S.setItem('kc-at',a.dataset.at);" +   # same: a reload brought no new sweep
    "function ag(m){return m<1?'now':m<60?m+' min':m<1440?Math.floor(m/60)+' h '+m%60+' min':Math.floor(m/1440)+' d'}function u(){var w=Date.now(),m=Math.round((w-t)/6e4),o=Math.round((t-w)/6e4+n);a.textContent='updated '+(m<1?'just now':m<60?m+' min ago':m<2880?Math.round(m/60)+' h ago':Math.round(m/1440)+' d ago');a.className='chip '+(m>4*n?'bad':m>2*n?'warn':'ok');" +
    "nx.title='Next sweep '+nx.dataset.due+' ('+(o>0?'in '+ag(o):(same?'waiting for it':'due now')+(o<0?', overdue '+ag(-o):''))+')'+nx.dataset.tail;nx.textContent='next '+nx.dataset.due+(o<0?' (overdue)':'');d.querySelectorAll('.ago').forEach(function(e){e.textContent=ag(Math.max(0,Math.round((w-new Date(e.dataset.t))/6e4)))})}u();setInterval(u,1e4);" +
    "d.getElementById('tt').onclick=function(){var k=r.dataset.theme?r.dataset.theme=='dark':matchMedia('(prefers-color-scheme: dark)').matches;r.dataset.theme=k?'light':'dark';L.setItem('kc-theme',r.dataset.theme)};" +
    "var ar=d.getElementById('ar'),on=L.getItem('kc-ar')!=='0',tm;function sa(){ar.setAttribute('aria-pressed',on);ar.title=on?'Auto-refresh every 60 s':'Auto-refresh off';ar.setAttribute('aria-label',ar.title);clearTimeout(tm);if(on)tm=setTimeout(function(){var p={};d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){if(e.scrollTop||e.scrollLeft)p[s.id+i]=[e.scrollTop,e.scrollLeft]})});S.setItem('kc-sp',JSON.stringify(p));S.setItem('kc-y',scrollY);location.reload()},6e4)}ar.onclick=function(){on=!on;L.setItem('kc-ar',on?'1':'0');sa()};sa();" +
    "function jp(k,f){try{return JSON.parse(L.getItem(k))||f}catch(e){return f}}var op=jp('kc-open',{});d.querySelectorAll('details.sec').forEach(function(s){if(s.classList.contains('none')){s.querySelector(':scope>summary').addEventListener('click',function(x){x.preventDefault()});return}if(s.id in op)s.open=op[s.id];s.querySelector(':scope>summary').addEventListener('click',function(){setTimeout(function(){var o=jp('kc-open',{});o[s.id]=s.open;L.setItem('kc-open',JSON.stringify(o))})})});" +   # the owner's own clicks only: a default never pins itself
    "var q=d.getElementById('q'),nm=d.getElementById('nm'),AL=jp('kc-all',[]);function tk(t){var s=t.closest('details'),h=s&&s.querySelector(':scope>summary>:first-child'),r=t.querySelector('tr');return(h?h.textContent:'')+':'+(r?r.textContent:'')}" +   # show all: kept per table
    "function sa0(){d.querySelectorAll('.tw').forEach(function(t){var b=t.querySelector(':scope>.sa');if(!b)return;var on=!!q.value||AL.indexOf(tk(t))>=0;t.classList.toggle('all',on);b.textContent=on?'Show fewer':'Show all ('+b.dataset.n+')'})}" +
    "d.addEventListener('click',function(x){var b=x.target.closest('.sa');if(!b)return;var k=tk(b.parentNode),i=AL.indexOf(k);if(i>=0)AL.splice(i,1);else AL.push(k);L.setItem('kc-all',JSON.stringify(AL));sa0();ca()});" +
    "d.querySelectorAll('.jl a').forEach(function(a){a.addEventListener('click',function(){for(var s=d.querySelector(a.getAttribute('href'));s;s=s.parentElement&&s.parentElement.closest('details'))s.open=true})});" +   # a jump opens its section and the bands around it
    "function tx(x){var s=x.textContent;x.querySelectorAll('svg title').forEach(function(t){s=s.replace(t.textContent,'')});return s.toLowerCase()}" +   # icon titles are no match ('gb', 'ram' would hit every card)
    "function fl(){var v=q.value.toLowerCase();S.setItem('kc-q',q.value);d.querySelectorAll('.f').forEach(function(x){x.hidden=!!v&&tx(x).indexOf(v)<0});d.querySelectorAll('tbody.grp').forEach(function(g){g.hidden=!g.querySelector('tr.f:not([hidden])')});" +
    "d.querySelectorAll('details.lx').forEach(function(x){if(v&&tx(x).indexOf(v)>=0){if(!x.open){x.open=true;x.dataset.fo=1}}else if(!v&&x.dataset.fo){x.open=false;delete x.dataset.fo}});if(v)d.querySelectorAll('details.sec').forEach(function(s){if(s.querySelector('.f:not([hidden])'))s.open=true});nm.hidden=!v||!!d.querySelector('.f:not([hidden])');sa0()}q.oninput=fl;sa0();q.value=S.getItem('kc-q')||'';if(q.value)fl();d.addEventListener('keydown',function(x){if(x.key=='/'&&d.activeElement!=q){x.preventDefault();q.focus()}});" +
    "var SC='.bd,.info,.tw,.sy,.sxb';function cu(e){var v=e.scrollHeight>e.clientHeight+1,h=e.scrollWidth>e.clientWidth+1,c=e.classList,o=v||h;c.toggle('sc',o);if(o)e.tabIndex=0;else e.removeAttribute('tabindex');c.toggle('u',v&&e.scrollTop>1);c.toggle('d',v&&e.scrollTop+e.clientHeight<e.scrollHeight-1);c.toggle('l',h&&e.scrollLeft>1);c.toggle('r',h&&e.scrollLeft+e.clientWidth<e.scrollWidth-1)}" +
    "function ca(){d.querySelectorAll(SC).forEach(cu)}ca();addEventListener('resize',ca);d.addEventListener('toggle',ca,true);q.addEventListener('input',ca);" +
    # masonry (owner, 2026-11-13): a card grid ([data-mas]) packs cards in order into the shortest column; one column = plain flow
    # heights measured at the packed width (.msm), inner grids first; run twice (an inner grid before its outer one packed)
    "function ms(){[].slice.call(d.querySelectorAll('[data-mas]')).reverse().forEach(function(g){var it=[].filter.call(g.children,function(c){return!c.hidden});g.classList.remove('msn','msm');it.forEach(function(c){c.style.gridColumn=c.style.gridRow=''});if(!g.clientWidth||it.length<2)return;" +
    "var cs=getComputedStyle(g),gp=parseFloat(cs.columnGap)||8,mn=parseFloat(cs.getPropertyValue('--cmin'))||200,mx=parseInt(cs.getPropertyValue('--cmax'))||99,n=Math.max(1,Math.min(mx,it.length,Math.floor((g.clientWidth+gp)/(mn+gp))));if(n<2)return;g.style.setProperty('--mc',n);g.classList.add('msm');" +
    "var hs=it.map(function(c){return c.getBoundingClientRect().height});g.classList.remove('msm');g.classList.add('msn');var tp=[];for(var i=0;i<n;i++)tp.push(0);it.forEach(function(c,j){var h=Math.ceil(hs[j]+gp),k=tp.indexOf(Math.min.apply(0,tp));c.style.gridColumn=k+1;c.style.gridRow=(tp[k]+1)+' / span '+h;tp[k]+=h})})}ms();ms();addEventListener('resize',ms);d.addEventListener('toggle',ms,true);q.addEventListener('input',ms);" +
    "window.uiChecks=function(){var o=[],h=d.querySelector('header.top');if(innerWidth>=1100&&h.offsetHeight>48)o.push({el:'header.top',why:'header '+h.offsetHeight+' px tall: one row at desktop width',text:''});d.querySelectorAll('.bar,.mb,.sb,.lt,.sbh,svg.spark').forEach(function(b){var n=b.nextElementSibling;if(b.getClientRects().length&&!(b.getAttribute('aria-label')||b.getAttribute('title')||n&&n.textContent.trim()))o.push({el:b.getAttribute('class'),why:'a bar without a text label',text:''})});" +
    "if(innerWidth>=1100)d.querySelectorAll('[data-row]').forEach(function(w){var hs=[].map.call(w.children,function(c){return c.getBoundingClientRect().height}).filter(function(h){return h>0}),g=hs.length>1?Math.max.apply(0,hs)-Math.min.apply(0,hs):0;if(g>48)o.push({el:w.className,why:'sibling heights differ by '+Math.round(g)+' px (max 48)',text:''})});" +   # dashboard-design.md: a row's siblings within 48 px
    "d.querySelectorAll('[data-mas]').forEach(function(g){var it=[].filter.call(g.children,function(c){return c.getClientRects().length}).map(function(c){var r=c.getBoundingClientRect();return{l:Math.round(r.left),t:r.top,b:r.bottom}}),ls=[],g0=g.getBoundingClientRect().top;it.forEach(function(x){if(ls.indexOf(x.l)<0)ls.push(x.l)});if(ls.length<2)return;" +
    "it.forEach(function(x){ls.forEach(function(l){if(l==x.l)return;var bt=g0;it.forEach(function(y){if(y.l==l&&y.t<x.t-1)bt=Math.max(bt,y.b)});if(x.t-bt>48)o.push({el:g.className,why:'a card starts '+Math.round(x.t-bt)+' px below free space in another column (max 48): pack the grid',text:''})})})});" +   # card grids: no card under a column with 48+ px free above it
    "d.querySelectorAll('details.top').forEach(function(s){var c=s.querySelector(':scope>summary>.cnt'),b=s.querySelector(':scope>.bd');if(!c||!b)return;(c.textContent.match(/[$]?\d[\d.,]*(%|[kMB]\b|\s?GB\b)|[$]\d[\d.,]*/g)||[]).forEach(function(v){var t=b.textContent,i=t.indexOf(v),hit=false;for(;i>=0&&!hit;i=t.indexOf(v,i+1))hit=!/[\d.]/.test(t.charAt(i-1))&&!/[\d.]/.test(t.charAt(i+v.length));if(hit)o.push({el:s.id,why:'headline value '+v+' in the band header and again inside it',text:c.textContent.trim()})})});return o};" +   # each number once: a band header never repeats a value its body shows
    "d.addEventListener('click',function(x){var c=x.target.closest('code.cp');if(!c)return;x.preventDefault();try{navigator.clipboard.writeText(c.textContent).then(function(){c.classList.add('ok');setTimeout(function(){c.classList.remove('ok')},1200)})}catch(e){}},true);" +   # a release command: click copies, the row stays as it is
    "var tp=d.createElement('div');tp.id='tip';tp.setAttribute('role','tooltip');tp.hidden=true;d.body.appendChild(tp);" +
    "function sh(el){var s=el&&(el.getAttribute('title')||(el.querySelector(':scope>title')||{}).textContent);if(!s){tp.hidden=true;return}tp.textContent=s;tp.hidden=false;var b=el.getBoundingClientRect(),w=tp.offsetWidth,g=tp.offsetHeight;tp.style.left=Math.max(4,Math.min(innerWidth-w-4,b.left))+'px';tp.style.top=(b.bottom+g+6>innerHeight?b.top-g-6:b.bottom+6)+'px'}" +
    "d.addEventListener('scroll',function(x){var e=x.target;if(e.matches&&e.matches(SC))cu(e);tp.hidden=true},true);" +   # touch has no hover: a tap shows the title
    "d.addEventListener('click',function(x){sh(x.target.closest('button')?null:x.target.closest('[title],.hit,circle.val'))});" +
    "d.addEventListener('focusin',function(x){sh(x.target.closest('button')?null:x.target.closest('[title]'))});" +
    "var sp=JSON.parse(S.getItem('kc-sp')||'{}'),y=S.getItem('kc-y');S.removeItem('kc-sp');S.removeItem('kc-y');d.querySelectorAll('details.sec').forEach(function(s){s.querySelectorAll(SC).forEach(function(e,i){var v=sp[s.id+i];if(v){e.scrollTop=v[0];e.scrollLeft=v[1]}})});ca();if(y)scrollTo(0,+y)})()"   # after collapse + filter: the layout is final
  $head = "<header class=top><div class=brand>$mark<span>claude-crew</span><small>Supervisor</small></div><div class=meta><span id=age class=chip title='Last sweep $($at.ToString('yyyy-MM-dd HH:mm'))' data-at='$($at.ToString('o'))' data-next='$(& $e $nextMin)'></span><span id=nx title='$(& $e $j.next)' data-due='$($at.AddMinutes([double]$nextMin).ToString('HH:mm'))' data-tail='$(& $e $nxTail)'>next $($at.AddMinutes([double]$nextMin).ToString('HH:mm'))</span></div><nav class=jl aria-label='Sections'>$((@(@('flags', 'Flags'), @('agents', 'Agents'), @('runs', 'Runs'), @('machine', 'Machine'), @('internals', 'Kit internals')) | ForEach-Object { "<a href='#sec-$($_[0])'>$($_[1])</a>" }) -join '')<span class='chip lv ACT'>$nAct ACT</span><span class='chip lv WATCH'>$nWatch WATCH</span></nav><div class=sp></div>" +
    "<div class=tb><input id=q type=search placeholder='Filter  ( / )' aria-label='Filter the page'><button id=ar class=ib type=button aria-pressed=true aria-label='Auto-refresh every 60 s' title='Auto-refresh every 60 s'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4' fill=none stroke=currentColor stroke-width=2 stroke-linecap=round /></svg></button><button id=tt class=ib type=button aria-label='Toggle theme' title='Toggle theme'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z' fill=currentColor /></svg></button></div></header>"
  # each number once, in acting order: flags, live agents, runs, machine; usage and kit state folded in Kit internals
  $nRes = @($j.resources | Where-Object { $_ }).Count; $nSh = @($j.shells | Where-Object { $_ }).Count
  # one folded band (owner, 2026-11-13); its header repeats no number of the page
  $intHtml = (& $fold 'usage' 'Usage, 7 days' '' $UP.usage -Open -cls sub) + (& $fold 'activity' 'Activity' $null $kitTiles -cls sub) + $setHtml
  # open: flags, agents, runs, machine, resources; Kit internals folded (the page remembers each fold)
  # Shells: a fold only when one runs; none = one muted word in the Resources header
  $mrHtml = $machineHtml + (& $fold 'resources' 'Resources and leases' $nRes "<div class=sxb>$resHtml</div>" -Open -cls sub -extra $(if (-not $nSh) { '<span class=cnt>· no shell running</span>' })) + $(if ($nSh) { & $fold 'shells' 'Shells' $nSh "<div class='sxb fx sh'>$shellHtml</div>" -Open -cls sub })
  $main = "<main class=wrap>" + (& $section 'flags' 'Flags' '' $flagHtml -Open) + (& $section 'agents' 'Agents' $agCnt $agentHtml -Open -extra $agBar) +
    (& $section 'runs' 'Runs, 7 days' $(if ($UP.runs) { $UP.runsN } else { 0 }) $UP.runs -Open) +
    (& $section 'machine' 'Machine and resources' '' $mrHtml -Open) +
    (& $section 'internals' 'Kit internals' '' $intHtml) +
    "<p id=nm class=empty hidden>No match.</p><footer>Written by bossy.ps1 supervise each sweep (no model tokens) · data: supervise-report.json · times local (UTC$($at.ToString('zzz')))</footer></main>"
  "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><noscript><meta http-equiv=refresh content=60></noscript><title>Supervisor $($at.ToString('HH:mm'))$(if ($nAct) { " · $nAct ACT" })</title>$fav<style>$css</style><script>try{var t=localStorage.getItem('kc-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script></head><body>$head$main<script>$js</script></body></html>"
}
# page CSS: muted sage palette, light / dark (prefers-color-scheme; data-theme overrides)
function Get-KitSupervisePageCss {
  $dark = '--bg:#0c0c0c;--sf:#161b16;--sf2:#212a21;--fg:#d8dee9;--mt:#8a948a;--ln:#2e3a2e;--sage:#79a86a;--sage2:#9fd48c;--act:#dc9089;--watch:#e0ce8a;--slate:#8fbbd4;--plum:#c495d4;--sh:0 4px 20px rgba(0,0,0,0.45)'
  ':root{--bg:#f4f7f4;--sf:#ffffff;--sf2:#eaefea;--fg:#1a221a;--mt:#5e6c5e;--ln:#d5dfd5;--sage:#647c64;--sage2:#79a86a;--act:#ce8f8a;--watch:#c4b06a;--slate:#5f93a8;--plum:#a074b0;--sh:0 1px 3px rgba(26,34,26,.06),0 1px 2px rgba(26,34,26,.04)}' +
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
  '.cnt{font-size:11.5px;color:var(--mt);font-variant-numeric:tabular-nums}.bd{padding:0 12px 10px}details.sub{border:1px solid var(--ln);border-radius:8px;margin-top:8px;align-self:start}details.sub>summary{min-height:30px;padding:4px 10px}summary :is(h3,h4){margin:0}details.st.sub{padding:0}details.st.sub>.bd{padding:0 10px 8px}details.none>summary{cursor:default}details.none>summary::after{display:none}summary:focus-visible{outline:2px solid var(--sage);outline-offset:-2px;border-radius:8px}.jl{display:flex;flex-wrap:wrap;gap:4px 10px;align-items:center;font-size:12px}.jl a{color:var(--mt);text-decoration:none}.jl a:hover,.jl a:focus-visible{color:var(--fg)}.lv.FIX{color:color-mix(in srgb,var(--sage) 55%,var(--fg));background:color-mix(in srgb,var(--sage) 15%,transparent)}summary .chip.lv{margin-left:2px}.tw:not(.all) tr.more{display:none}.sa{margin:6px 0 2px;font:inherit;font-size:12px;background:var(--sf2);color:var(--fg);border:1px solid var(--ln);border-radius:6px;padding:2px 10px;cursor:pointer}.bar.sb3{display:inline-flex;gap:1px}.bar.sb3 i{border-radius:0}.bar i.mt{background:var(--mt)}.tm{color:var(--mt)}.dots{display:flex;flex-wrap:wrap;gap:3px;margin-top:6px}.dots i{width:8px;height:8px;border-radius:50%;border:1px solid var(--mt)}.dots i.on{background:var(--slate);border-color:var(--slate)}:is(td[data-k=Key],td[data-k=Context],td[data-k=Dir],td[data-k=Command]){font-family:ui-monospace,Consolas,monospace;font-size:11.5px}.fl{display:grid;gap:8px;align-items:stretch}@media(min-width:1100px){.fl{grid-template-columns:minmax(0,1fr) 280px}}.fmas{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:8px;align-content:start;align-items:start}.fmas>.flag{margin:0}' +
  # the trend stretches to the cards (chart up to 240 px); holds: one compact row each
  '.ftr{margin:0;border:1px solid var(--ln);border-radius:8px;padding:8px;background:var(--sf);display:flex;flex-direction:column;min-width:0}.ftr .lcp{flex:1;min-height:56px;max-height:240px}.ftr figcaption{font-size:11px;color:var(--mt);margin-top:4px}' +
  '.fbl{display:flex;flex-wrap:wrap;gap:8px;align-items:flex-start;margin-top:8px}.fbl>details.sub{margin-top:0;flex:1 1 260px;min-width:0}.fbl>details[open]{flex-basis:100%;order:1}' +
  '.hold{list-style:none;margin:0;padding:0;display:grid;gap:4px}.hr{display:grid;grid-template-columns:minmax(90px,auto) auto minmax(0,1fr);gap:4px 10px;align-items:baseline;padding:4px 8px;font-size:12.5px;border-radius:6px;background:var(--sf2)}.hc{margin:6px 0 0;font-size:11.5px;color:var(--mt)}' +
  '.hn{color:var(--mt);font-size:11.5px;white-space:nowrap}.hw{overflow-wrap:anywhere;color:var(--mt)}.ht a{color:inherit}code.cp{font:11px ui-monospace,Consolas,monospace;overflow-wrap:anywhere;cursor:copy;color:var(--fg)}code.cp.ok{color:var(--sage2)}' +
  '@media(max-width:899px){.hr{grid-template-columns:minmax(0,auto) minmax(0,1fr)}.hr .hw{grid-column:1/-1}}' +
  '.lgd{display:inline-block;width:14px;height:0;border-top:2px solid var(--c);vertical-align:middle;margin:0 3px 0 6px}.lgd.ds{border-top-style:dashed}.lgd.dd{border-top-style:dotted}' +
  '.sh4{margin:6px 0 2px;font-size:12px;color:var(--mt)}.cg.res{align-items:stretch}' +
  '.cmd>summary{cursor:pointer;overflow-wrap:anywhere;display:block;padding:0;min-height:0}.cmd>summary::after{content:none}.cmd>summary .cnt{white-space:nowrap}.cmdf{white-space:pre-wrap;overflow-wrap:anywhere;margin-top:4px;font-size:11.5px}.lc{display:flex;flex-wrap:wrap;gap:3px;margin-top:2px}.chip.ls{font-size:10.5px;padding:0 6px;background:var(--sf2);color:var(--mt)}.ci.orphan{border-color:color-mix(in srgb,var(--watch) 55%,var(--ln));background:color-mix(in srgb,var(--watch) 9%,var(--sf))}.chip.k-build{color:color-mix(in srgb,var(--slate) 55%,var(--fg))}.chip.k-test{color:color-mix(in srgb,var(--plum) 55%,var(--fg))}.chip.k-kit{color:var(--mt)}' +
  '.flag{border:1px solid var(--ln);border-left:3px solid var(--watch);border-radius:8px;padding:6px 10px}.flag.ACT{border-left-color:var(--act);background:color-mix(in srgb,var(--act) 5%,var(--sf))}' +
  '.flag .h{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--mt)}.flag .w{margin:3px 0 2px;word-break:break-word}.flag .n{font-size:12.5px;color:var(--mt);word-break:break-word}.flag .n b{color:var(--sage2);margin-right:4px}.dot{opacity:.5}' +
  '.info{list-style:none;margin:8px 0 0;padding:0;font-size:12.5px;color:var(--mt)}.info li{padding:2px 0 2px 14px;position:relative;word-break:break-word}.info li::before{content:"";position:absolute;left:2px;top:9px;width:5px;height:5px;border-radius:50%;background:var(--sage)}' +
  '.empty{margin:0;padding:8px;text-align:center;color:var(--mt);border:1px dashed var(--ln);border-radius:8px;font-size:12.5px}' +
  '.ax{display:flex;justify-content:space-between;gap:8px;font-size:11px;color:var(--mt);margin-top:4px}' +
  '.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:12.5px}th{text-align:left;font-weight:600;font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;padding:4px 6px;border-bottom:1px solid var(--ln);overflow-wrap:break-word}' +   # headers break between words only: their longest word sets the column's min width
  'td{padding:3px 6px;border-bottom:1px solid var(--ln);vertical-align:top;overflow-wrap:anywhere}tr:last-child td{border-bottom:0}tr.f:hover td{background:color-mix(in srgb,var(--sf2) 55%,transparent)}' +
  'tr.gh th{background:var(--sf2);color:var(--fg);text-transform:none;letter-spacing:0;white-space:normal;font-size:12.5px;padding:4px 6px;border-radius:0}.gn0{font-weight:650}' +
  '.bar{display:inline-block;width:88px;height:6px;border-radius:3px;background:var(--sf2);overflow:hidden;vertical-align:middle;margin:0 6px 0 12px}.bar i{display:block;height:100%;border-radius:3px;background:var(--sage)}.bar i.watch{background:var(--watch)}.bar i.slate{background:var(--slate)}.bar i.act{background:var(--act)}.bar i.plum{background:var(--plum)}.bl{font-size:11.5px;color:var(--mt);font-weight:500}' +
  'td .bar{margin-left:0;width:64px}' +
  '.st{border:1px solid var(--ln);border-radius:8px;padding:6px 10px;min-width:0}.st .v{font-size:19px;font-weight:620;letter-spacing:-.01em;line-height:1.3}.st .v small{font-size:12px;color:var(--mt);font-weight:500}' +
  '.st .w,.st .s{font-size:12px;color:var(--mt)}.st .s,.st .w,.st .v{overflow-wrap:anywhere}.st.warn{border-color:color-mix(in srgb,var(--watch) 50%,var(--ln))}.st.warn>.v,.dk.warn .v{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.st.hot{border-color:color-mix(in srgb,var(--act) 50%,var(--ln))}.st.hot>.v,.dk.hot .v{color:color-mix(in srgb,var(--act) 55%,var(--fg))}.st.lo .v{font-size:16px}' +
  '.dks{--cgap:6px}.dk .v{font-size:17px}.dn0{font-weight:650}' +
  '.ci{border:1px solid var(--ln);border-radius:8px;padding:6px 10px;min-width:0}.ci .sm,.tn{overflow-wrap:anywhere}.ci .bar{display:block;width:100%;margin:4px 0 2px}.bl:empty{display:none}' +
  'footer{margin-top:12px;text-align:center;font-size:11.5px;color:var(--mt)}[hidden]{display:none!important}' +
  # graphs: sparklines, meters (7-day peak tick), lease timelines, the agents-by-state bar, flag icons
  '.spk{margin:4px 0 0}.spw{position:relative}.spk .spark{margin-top:0;height:40px}.ya{position:absolute;left:2px;font-size:10px;line-height:1;color:var(--mt);background:color-mix(in srgb,var(--sf) 70%,transparent);padding:0 2px;border-radius:2px}.ya.hi{top:0}.ya.lo{bottom:0}.nd{position:absolute;right:0;width:7px;height:7px;margin-bottom:-3.5px;border-radius:50%;background:currentColor}.spk figcaption,.mc{display:block;font-size:10.5px;line-height:1.3;color:var(--mt)}.spark .mk{stroke:var(--fg);stroke-width:1;stroke-dasharray:2 2;vector-effect:non-scaling-stroke}' +
  '.mtr{display:flex;align-items:center;gap:8px;margin-top:3px}.mtr .mc{flex:none}.st .k small{text-transform:none;letter-spacing:0;font-weight:500}.mb{flex:1;position:relative;display:block;height:6px;border-radius:3px;background:var(--sf2)}.mb i{display:block;height:100%;border-radius:3px;background:var(--slate)}.mb i.act{background:var(--act)}.mb i.watch{background:var(--watch)}.mb .pk{position:absolute;top:-3px;width:2px;height:12px;margin-left:-1px;border-radius:1px;background:var(--fg)}' +
  '.lt{display:flex;height:5px;margin-top:3px;border-radius:2px;overflow:hidden;background:var(--sf2)}.lt i{display:block}.lt .h0{background:var(--sage)}.lt .h1{background:var(--slate)}.lt .h2{background:var(--plum)}.lt .h3{background:var(--watch)}.lt .hx{background:none}' +
  '.sbh{display:inline-flex;gap:1px;width:120px;height:8px;border-radius:4px;overflow:hidden;background:var(--sf2)}.sbh i.s-act{background:var(--sage)}.sbh i.s-oth{background:var(--watch)}.sbh i.s-stuck{background:var(--act)}.sbh i.s-fin{background:var(--slate)}' +
  # Activity: run chips; per-repo rows (light bar = branches, dark = worktrees); 7 daily bars, value above each
  '.rch{display:flex;flex-wrap:wrap;gap:4px;margin:3px 0}.rch:empty{display:none}.rch .chip{white-space:normal;overflow-wrap:anywhere}.rpt{display:grid;grid-template-columns:minmax(0,max-content) minmax(36px,1fr) 2em 2em;gap:2px 8px;align-items:center;font-size:11.5px;margin:4px 0}.rp{display:contents}.rc{text-align:right}.rh>*{color:var(--mt);font-size:10.5px}' +
  '.rbr{position:relative;height:6px;border-radius:3px;background:var(--sf2)}.rbr>*{position:absolute;inset:0 auto 0 0;border-radius:3px}.rbr i,.sw1{background:color-mix(in srgb,var(--sage) 40%,var(--sf2))}.rbr b,.sw2{background:var(--slate)}.rh i{display:inline-block;width:7px;height:7px;margin-right:3px}' +
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
  # usage cards: the chart beside outcome bar + model table, the role table full width; none stretches
  '.ug{display:grid;gap:8px;margin-top:8px;align-items:start;grid-template-columns:minmax(0,1fr)}.ucol{display:grid;gap:8px;min-width:0}.uc{padding:6px 10px;min-width:0}.ru>summary .bar{background:var(--sf)}' +
  '@media(min-width:1100px){.ug{grid-template-columns:minmax(0,7fr) minmax(0,5fr)}.ur{grid-column:1/-1}}' +   # no empty column: Per role spans the row or fills the third
  '.lch{margin:4px 0 0}.lcp{position:relative}.lcp svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible}.lcp ol{list-style:none;margin:0;padding:0;position:absolute;inset:0}' +
  'svg .ar{stroke:none;fill:var(--c);opacity:.16}svg .ln{fill:none;stroke:var(--c);stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round;stroke-linecap:round}.ln.dash{stroke-width:1.4;stroke-dasharray:5 3}.ln.dot{stroke-width:1.6;stroke-dasharray:1 3;opacity:1}.avg{stroke:var(--mt);stroke-width:1;stroke-dasharray:2 4;vector-effect:non-scaling-stroke}' +
  '.t-sage{--c:var(--sage)}.t-slate{--c:var(--slate)}.t-act{--c:var(--act)}.t-watch{--c:var(--watch)}.t-plum{--c:var(--plum)}' +
  '.lcp li{position:absolute;top:0;bottom:0;width:calc(100% / var(--n));transform:translateX(-50%);border-radius:6px}.lcp li:hover{background:color-mix(in srgb,var(--fg) 5%,transparent)}' +
  '.dt{position:absolute;left:50%;width:7px;height:7px;margin:0 0 -3.5px -3.5px;border-radius:50%;background:var(--c);box-sizing:border-box}.dt.dash,.dt.dot{background:var(--sf);border:1.5px solid var(--c)}.lcp li.x .dt{width:11px;height:11px;margin:0 0 -5.5px -5.5px;box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 28%,transparent)}' +
  '.lcl{position:absolute;inset:0;pointer-events:none}.lcl b{position:absolute;transform:translate(-50%,-9px);display:flex;flex-direction:column;align-items:center;font-size:10.5px;font-weight:600;line-height:1.15;white-space:nowrap;font-variant-numeric:tabular-nums;color:var(--fg)}.lcl b small{font-size:10px;font-weight:500;color:var(--mt)}.lcl b.x{color:var(--sage2)}' +
  '.lcx{position:relative;height:16px;margin-top:3px;border-top:1px solid var(--ln);font-size:10.5px;color:var(--mt);font-variant-numeric:tabular-nums}.lcx span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}.lcx span.x{color:var(--fg);font-weight:650}' +
  '.lk{font-style:normal;font-size:11px}.lk::before{content:"";display:inline-block;width:16px;height:0;border-top:2px solid var(--c);margin-right:5px;vertical-align:3px}.lk.dash::before{border-top-style:dashed}.lk.avg::before{border-top:1px dotted var(--mt)}' +
  '.mcol{display:grid;gap:var(--cgap,8px);min-width:0}.cg.mach{align-items:stretch}.mach>.st{display:flex;flex-direction:column}.mach>.st>.spk:last-child{margin-top:auto}' +
  # one line per kind on every width from 700 px (kind · hourly heatmap · numbers, aligned: .gk is display:contents); the side panel 300 px, wrapping
  '.gl{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:8px 20px;align-items:start}@media(max-width:900px){.gl{grid-template-columns:minmax(0,1fr)}}.gp{display:grid;gap:4px;margin-top:6px;min-width:0}.gp .s{overflow-wrap:anywhere}' +
  '.gks{display:grid;grid-template-columns:max-content minmax(120px,1fr) repeat(6,max-content);gap:5px 12px;align-items:center;margin-top:6px;font-size:11.5px}.gk{display:contents}.gn{font-weight:600;white-space:nowrap}.gc{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}.gc.z,.iv.z{color:color-mix(in srgb,var(--mt) 70%,var(--bg))}.iv.z .ic{color:inherit}.gk:not(.gh)>.gc .ic{display:none}.gc.nw,.gk:not(.gh)>.gc:nth-child(3):not(.z){color:var(--sage2);font-weight:650}.gk:not(.gh)>.gc:nth-child(4):not(.z){color:color-mix(in srgb,var(--watch) 55%,var(--fg));font-weight:650}.gh>*{color:var(--mt);font-size:10.5px;font-weight:600}.gh>.gc{display:inline-flex;justify-content:flex-end;align-items:center;gap:2px}.ic{width:13px;height:13px;flex:none;vertical-align:-2px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;color:var(--mt)}.ic.i-run{color:var(--sage2)}.ic.i-queue{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.ic.i-stuck{color:color-mix(in srgb,var(--act) 55%,var(--fg))}.iv{display:inline-flex;align-items:center;gap:3px;white-space:nowrap;margin-right:10px}.st .v .ic{width:15px;height:15px}.cnt .iv{margin-right:6px}.tn .iv{float:right;margin:0 0 0 8px;font-size:12px;color:var(--mt)}' +
  # hourly heatmap: 24 cells, shade = busy share of the hour (--a), the current hour outlined; hour labels in the header row
  ':is(.msn,.msm){display:grid!important;grid-template-columns:repeat(var(--mc),minmax(0,1fr));align-items:start}.msn{grid-auto-rows:1px;row-gap:0!important}:is(.msn,.msm)>*{align-self:start!important;margin:0}' +
  # a long flag text: its summary opens the full text (click or tap; the filter opens a matching one)
  'details.lx>summary{display:inline;padding:0;min-height:0;cursor:pointer}details.lx>summary::after{content:" · full text";border:0;width:auto;height:auto;transform:none;margin:0;color:var(--sage2);font-size:11px}details.lx[open]>summary::after{content:" · less"}.lf{margin-top:3px;padding:4px 6px;border-radius:6px;background:var(--sf2);overflow-wrap:anywhere}' +
  '.hm{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:2px;height:14px}.hm i{border-radius:2px;background:color-mix(in srgb,var(--slate) var(--a),var(--sf2));cursor:default}.hm i.nw{box-shadow:inset 0 0 0 1.5px var(--sage2)}.hm i:hover{box-shadow:inset 0 0 0 1.5px var(--fg)}' +
  '.hrs{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:2px}.hrs b{font-weight:500;white-space:nowrap}.hrs b.nw{text-align:right;color:var(--sage2)}.hk{font-size:10.5px;color:var(--mt);margin-top:4px}' +
  '@media(max-width:699px){.gks{grid-template-columns:minmax(0,1fr)}.gk{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:2px 6px}.gk>.gn,.gk>.gs,.gk>.gs0{grid-column:1/-1}.gh>.gn,.gh>.gc{display:none}.gk:not(.gh)>.gc .ic{display:inline-block;margin-right:2px}}' +
  '.uc .sy{max-height:clamp(200px,36dvh,360px)}.uc .tw>table:not(.ag){min-width:0}.uc :is(th,td){padding:3px 4px}.uc td{overflow-wrap:normal}.us td:first-child,.ur td:first-child{overflow-wrap:anywhere}:is(.uc,.us) .sy td,.us td{white-space:normal}.ua td:first-child{white-space:nowrap}' +
  '@media(min-width:641px){.ua :is(th,td):not(:first-child),.us :is(th,td):nth-child(n+2):nth-child(-n+4),.ru :is(th,td):nth-child(n+4):nth-child(-n+7),:is(.ur,.um) :is(th,td):not(:first-child){text-align:right}}' +
  '.tw>table:not(.ag){min-width:520px}@media(max-width:640px){.ag .tm{display:none}.ag .ago{white-space:nowrap}.wrap{padding:8px}header.top{padding:6px 10px;position:static}.hs{display:none}.tb{width:100%}input[type=search]{flex:1;width:auto}' +
  # phone: a table row = a card, two fields a line (label above value), low-value columns ('~') hidden
  '.tw>table:not(.ag){min-width:0}.tw>table:not(.ag) tr:first-child{display:none}.tw>table:not(.ag),.tw>table:not(.ag) :is(tbody,tr,td){display:block;width:auto}.tw>table:not(.ag) tr{border-bottom:1px solid var(--ln);padding:4px 0}' +
  '.tw>table:not(.ag) tr{display:flex;flex-wrap:wrap}.tw>table:not(.ag) td{border:0;padding:1px 8px;display:block;flex:1 1 40%;min-width:0;text-align:left!important}.tw>table:not(.ag) td::before{content:attr(data-k);display:block;color:var(--mt);font-size:10.5px;text-transform:uppercase;letter-spacing:.06em}.tw .lo{display:none!important}.tw>table.tun tr.gh{display:block}.tw>table.tun tr.gh th{display:block;text-align:left}.tw>table.tun td:empty{display:none}}'
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
# token vector [in, out, cache read, cache write, of it 1-hour cache write]; days = that vector per local day (the 7-day window cuts by day)
function Update-KitUsageFile([string]$Path, $Rec, [ref]$Left) {
  $fi = [IO.FileInfo]::new($Path); if (-not $fi.Exists) { return $Rec }
  if (-not $Rec -or $null -eq $Rec.days -or [int]$Rec.v -lt 3 -or [long]$Rec.off -gt $fi.Length) { $Rec = [ordered]@{ v = 3; off = 0L; in = 0L; out = 0L; cr = 0L; cw = 0L; cw1 = 0L; n = 0; tools = 0; model = ''; t0 = ''; t1 = ''; lastId = ''; lastU = @(0, 0, 0, 0, 0); days = @{} } }   # older cache: no per-day + model vectors, reread
  $n = [int][math]::Min([math]::Min($fi.Length - [long]$Rec.off, [math]::Max([long]0, [long]$Left.Value)), [long]256MB); if ($n -le 0) { return $Rec }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
  try { $null = $fs.Seek([long]$Rec.off, 'Begin'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  if ($got -le 0) { return $Rec }; $end = [Array]::LastIndexOf($b, [byte]10, $got - 1); if ($end -lt 0) { return $Rec }   # no whole line yet; shrunk meanwhile
  $Left.Value -= $end + 1; $Rec.off = [long]$Rec.off + $end + 1
  $num = { param($l, [string]$k) $m = [regex]::Match($l, """$k"":(\d+)"); if ($m.Success) { [long]$m.Groups[1].Value } else { 0L } }
  foreach ($l in [Text.Encoding]::UTF8.GetString($b, 0, $end).Split([char]10)) {
    $ts = [regex]::Match($l, '"timestamp":"([^"]+)"'); if ($ts.Success) { if (-not $Rec.t0) { $Rec.t0 = $ts.Groups[1].Value }; $Rec.t1 = $ts.Groups[1].Value }
    $was = @([long]$Rec.in, [long]$Rec.out, [long]$Rec.cr, [long]$Rec.cw, [long]$Rec.cw1)
    if ($l.Contains('"total_token_usage"')) {   # codex rollout: cumulative
      $m = [regex]::Match($l, '"total_token_usage":\{([^}]*)\}'); if (-not $m.Success) { continue }; $u = $m.Groups[1].Value; $Rec.cr = & $num $u 'cached_input_tokens'; $Rec.in = (& $num $u 'input_tokens') - $Rec.cr; $Rec.out = & $num $u 'output_tokens'; $Rec.n++ }
    elseif (-not $l.Contains('"usage"') -or -not $l.Contains('"assistant"')) { continue }
    else {
      $Rec.tools += ([regex]::Matches($l, '"type":"tool_use"')).Count
      $md = [regex]::Match($l, '"model":"([^"]+)"'); if ($md.Success -and $md.Groups[1].Value -ne '<synthetic>') { $Rec.model = $md.Groups[1].Value }
      $uu = @((& $num $l 'input_tokens'), (& $num $l 'output_tokens'), (& $num $l 'cache_read_input_tokens'), (& $num $l 'cache_creation_input_tokens'), (& $num $l 'ephemeral_1h_input_tokens'))   # no breakdown: all 5-minute writes
      $id = [regex]::Match($l, '"id":"(msg_[^"]+)"').Groups[1].Value
      if ($id -and $id -eq $Rec.lastId) { $p = @($Rec.lastU) } else { $p = @(0, 0, 0, 0, 0); $Rec.n++ }
      $Rec.in += $uu[0] - $p[0]; $Rec.out += $uu[1] - $p[1]; $Rec.cr += $uu[2] - $p[2]; $Rec.cw += $uu[3] - $p[3]; $Rec.cw1 += $uu[4] - $p[4]; $Rec.lastId = $id; $Rec.lastU = $uu }
    if ($ts.Success) { if ($null -eq $Rec.days) { $Rec.days = @{} }; $dk = "$(([datetimeoffset]$ts.Groups[1].Value).LocalDateTime.ToString('yyyy-MM-dd'))|$($Rec.model)"   # tokens by day and model (a /model switch mid-session)
      $dv = @(if ($Rec.days[$dk]) { $Rec.days[$dk] } else { 0, 0, 0, 0, 0 }); $now5 = @([long]$Rec.in, [long]$Rec.out, [long]$Rec.cr, [long]$Rec.cw, [long]$Rec.cw1)
      $Rec.days[$dk] = @(for ($i = 0; $i -lt 5; $i++) { [long]$dv[$i] + $now5[$i] - $was[$i] }) }
  }
  $Rec
}
# a file record's token vectors of the given days (keys yyyy-MM-dd|model): [{ day; model; v }]
function Get-KitUsageParts($Rec, [string[]]$DayKeys) {
  if (-not $Rec -or -not $Rec.days) { return }
  foreach ($kv in $Rec.days.GetEnumerator()) { $dk, $md = "$($kv.Key)" -split '[|]', 2; if ($dk -in $DayKeys) { [pscustomobject]@{ day = $dk; model = $md; v = [long[]]@($kv.Value | ForEach-Object { [long]$_ }) } } }
}
# USD per million tokens (budget.prices, list prices 2026-11-03; derived, not listed: 5-min writes 1.25x in, 1-h 2x in, haiku cache read 0.1x in; key = model id without claude-, also its dated / [1m] variant and alias: sonnet = sonnet-*); [in, out, cache read, 5-min write, 1-h write (else 2x in)]
# $Tok = token vector [in, out, cache read, cache write, of it 1 h]; unknown model: $null (the page lists it as not priced)
function Get-KitUsageCost($Tok, [string]$Model) {
  $pr = Get-KitSetting 'budget.prices' $null; if (-not $pr) { if ($null -eq $script:KitPrices) { $script:KitPrices = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget.prices }; $pr = $script:KitPrices }; if (-not $pr -or -not $Model) { return $null }
  $id = $Model.ToLower() -replace '\[[^\]]*\]$' -replace '^claude-'; $pv = $null
  foreach ($p in @($pr.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) { if ($id -eq $p.Name -or $id.StartsWith("$($p.Name)-") -or ($id -notmatch '-' -and $p.Name -like "$id-*")) { $pv = $p.Value; break } }
  if ($null -eq $pv -or @($pv).Count -lt 4) { return $null }   # pwsh names ignore case: never $v next to $V
  $pv = @($pv | ForEach-Object { [double]$_ }); $w1 = if ($pv.Count -gt 4) { $pv[4] } else { 2 * $pv[0] }   # 4 values: 1-hour writes at 2x input
  ([double]$Tok[0] * $pv[0] + [double]$Tok[1] * $pv[1] + [double]$Tok[2] * $pv[2] + ([double]$Tok[3] - [double]$Tok[4]) * $pv[3] + [double]$Tok[4] * $w1) / 1e6
}
# budget -Usage: supervise runs it in the background each sweep; the page reads its cache
function Show-KitUsage([double]$Seconds, [bool]$Json) {
  $u = Get-KitUsage -Seconds $Seconds; $d0 = @($u.days)[-1]
  if ($Json) { $u | ConvertTo-Json -Depth 8 -Compress; return }
  "usage: today $($d0.tok) tokens$(if ($null -ne $d0.cost) { ", est. `$$($d0.cost)" }); 7 days $(($u.days | Measure-Object tok -Sum).Sum) tokens, $(@($u.runs).Count) run(s), $((@($u.bg) | Measure-Object n -Sum).Sum) agent(s) outside workflows, $(@($u.coord).Count) coordinator session(s)$(if (@($u.unpriced).Count) { "; not priced (add to budget.prices): $(@($u.unpriced | ForEach-Object { "$($_.model) $($_.tok) tokens" }) -join ', ')" })$(if ($u.partial) { '; transcripts still being read (run again)' })"
}
# the git host's merged MRs of this machine's login since $Since (deploy MRs left out); cached 2 beats in the usage cache; $null = no login or no repos
# days as yyyy-MM-dd: ConvertFrom-Json turns ISO date-times into DateTime
function Get-KitUsageHostMrs([datetime]$Since, [datetime]$Now, $Prev) {
  if ($Prev -and "$($Prev.since)" -eq $Since.ToString('yyyy-MM-dd') -and ($Now - [datetime]$Prev.at).TotalMinutes -lt 2 * (Get-KitBeatMinutes)) { return $Prev }
  $repos = @(@(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ }); if (-not $repos.Count) { return $null }
  $hu = try { Get-KitHostUser } catch { '' }; if (-not $hu) { return $null }; $cut = $Since.ToUniversalTime(); $hostErr = $false
  $mrs = @(foreach ($rp in $repos) { foreach ($m in @(try { Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = $cut.ToString('o'); per_page = 100 } } catch { $hostErr = $true }) | Where-Object { $_.iid -and $_.merged_at }) {
        $au = if ($m.author.username) { $m.author.username } else { "$($m.author)" }
        if ((-not $au -or $au -eq $hu) -and ([datetimeoffset]$m.merged_at).UtcDateTime -ge $cut -and -not (Test-KitDeployMr $rp "$($m.source_branch)" "$($m.target_branch)")) { @{ ref = "$rp!$($m.iid)"; day = ([datetimeoffset]$m.merged_at).LocalDateTime.ToString('yyyy-MM-dd') } } } })
  if ($hostErr) { return $Prev }   # a failed list is no 0 merged: the last list (or workflow MRs), retried next beat
  @{ at = $Now.ToString('o'); since = $Since.ToString('yyyy-MM-dd'); user = $hu; mrs = @($mrs | Sort-Object { $_.ref } -Unique) }
}
function Get-KitPct($Vals, [double]$P) { $s = @($Vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($P * $s.Count))] }
# runs, steps, background agents of the last $Days days; parses for at most $Seconds (the cache keeps offsets: the rest next call); stored with the result
# one window for every number: the $Days calendar days ending today (tokens cut by the day they were spent)
# a run's human label: its mandate's first words, else the first agent's area or items, else the brief's file name (the run id: the tooltip)
function Get-KitRunLabel($A) {
  $s = @(@($A.mandate) + @(@($A.agents)[0].area) + @(@($A.agents)[0].items) + @(if ($A.brief) { [IO.Path]::GetFileNameWithoutExtension("$($A.brief)") }) | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() } | Where-Object { $_ -and $_ -notmatch '^<' })[0]
  if ("$s".Length -gt 48) { $s = ($s.Substring(0, 47) -replace '\s+\S*$', '') + '…' }; "$s"
}
function Get-KitUsage([datetime]$Now = (Get-Date), [int]$Days = 7, [double]$Seconds = 60) {
  $cf = Get-KitPath usage-cache -Create; $all = try { Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; $cache = $all.files; if ($cache -isnot [hashtable]) { $cache = @{} }
  $root = (Invoke-KitAdapter transcript claude root).dir; $since = $Now.Date.AddDays(1 - $Days); $stop = (Get-Date).AddSeconds($Seconds); $left = [ref][long]2GB; $seen = @{}
  $dayKeys = @(foreach ($i in ($Days - 1)..0) { $Now.AddDays(-$i).ToString('yyyy-MM-dd') }); $unp = @{}; $mcost = @{}
  $read = { param([string]$f) $seen[$f] = 1; try { if ((Get-Date) -lt $stop -and $left.Value -gt 0) { $cache[$f] = Update-KitUsageFile $f $cache[$f] $left }; if ([IO.FileInfo]::new($f).Length -gt [long]$cache[$f].off + 64KB) { $script:KitUsagePartial = $true } } catch { }; $cache[$f] }   # a vanished file: its last totals; a half-written line is no backlog
  $script:KitUsagePartial = $false
  $lk = "$cf.lock"; if ((Test-Path -LiteralPath $lk) -and ((Get-Date) - [IO.File]::GetLastWriteTime($lk)).TotalMinutes -gt 10) { Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }   # a killed run's
  try { $lkh = [IO.File]::Open($lk, 'CreateNew', 'Write', 'None') } catch { return (Read-KitUsageResult) }   # another run reads: its last result
  try {
  $meta = { param([string]$f) try { Get-Content -LiteralPath ($f -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
  $mins = { param($r) if ($r.t0 -and $r.t1) { [math]::Round(([datetimeoffset]$r.t1 - [datetimeoffset]$r.t0).TotalMinutes, 1) } }
  $tok4 = { param($v) [long]$v[0] + [long]$v[1] + [long]$v[2] + [long]$v[3] }
  $price = { param($v, [string]$model) $c = Get-KitUsageCost $v $model; $tk = & $tok4 $v; if ($null -eq $c -and $tk) { $mk = if ($model) { $model } else { '(no model)' }; $unp[$mk] = [long]$unp[$mk] + $tk }; $c }
  # a step from a file record: its in-window tokens; $x = the step's own fields; $null = no tokens in the window (spent before it)
  # each day + model part priced at its own model; dayc = day -> [tokens, cost]; an older cache record (no parts yet) waits for its reread
  $mkStep = { param($u, [string]$model, [hashtable]$x) if ($u.days -and $u.days.Count -and [int]$u.v -lt 3) { return }
    $v = [long[]]::new(5); $cs = $null; $dc = @{}; foreach ($pt in @(Get-KitUsageParts $u $dayKeys)) { for ($i = 0; $i -lt 5; $i++) { $v[$i] += $pt.v[$i] }; $pm = if ($pt.model) { $pt.model } else { $model }; $c = & $price $pt.v $pm
      if ($null -ne $c) { $cs = [double]$cs + $c; $mcost[$pm] = [double]$mcost[$pm] + $c }; $d0 = @($dc[$pt.day]); $dc[$pt.day] = @(([long]$d0[0] + (& $tok4 $pt.v)), $(if ($null -ne $c -or $null -ne $d0[1]) { [double]$d0[1] + [double]$c })) }
    $tk = & $tok4 $v; if (-not $tk -and $u.days -and $u.days.Count) { return }
    $o = [ordered]@{ run = ''; wid = ''; label = ''; type = ''; role = ''; model = $model; in = $v[0]; out = $v[1]; cr = $v[2]; cw = $v[3]; cw1 = $v[4]; tok = $tk; cost = $cs; min = (& $mins $u); tools = [int]$u.tools; result = 'pass'; round = 1; retry = 0; dayc = $dc; at = ''; mrs = @() }
    foreach ($kv in $x.GetEnumerator()) { $o[$kv.Key] = $kv.Value }; [pscustomobject]$o }
  $atOf = { param($u, [string]$f) if ($u.t1) { ([datetimeoffset]$u.t1).LocalDateTime.ToString('o') } else { [IO.File]::GetLastWriteTime($f).ToString('o') } }
  # empty = a result whose every field but ok is empty (a missing mrs is no MR)
  $isEmpty = { param($r) -not @($r.PSObject.Properties | Where-Object { $_.Name -ne 'ok' -and $_.Value -and "$($_.Value)".Trim() }).Count }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $stuck = [double](Get-KitParam 'supervise.stuckMinutes')
  $runs = [Collections.Generic.List[object]]::new(); $steps = [Collections.Generic.List[object]]::new(); $bg = @{}; $coord = [Collections.Generic.List[object]]::new()
  foreach ($sd in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {   # no age filter: a session folder keeps its creation time while its runs go on for days
    $sub = Join-Path $sd.FullName 'subagents'; if (-not (Test-Path -LiteralPath $sub)) { continue }
    foreach ($w in @(Get-ChildItem -LiteralPath (Join-Path $sub 'workflows') -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {
      $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path -LiteralPath $j)) { continue }
      $ev = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x.result }
      $failed = @{}; foreach ($x in $ev | Where-Object type -eq 'failed') { $failed["$($x.agentId)"] = 1 }   # the engine's own failure: no result line
      $rec = @(Get-KitWorkflowRecords $w $ev $launch); $name = @(@($rec | ForEach-Object run) + $w.Name | Where-Object { $_ })[0]; $cap = @($rec.cap | Where-Object { $_ })[0]; $spent = @($rec.spent | Where-Object { $_ })[0]
      $live = -not (Get-KitWorkflowStop $w $rec) -and -not @($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count
      $labels = @{}; $noRes = @{}; $rs = [Collections.Generic.List[object]]::new()
      foreach ($s in @($ev | Where-Object type -eq 'started')) {
        $f = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; if (-not (Test-Path -LiteralPath $f)) { continue }
        $u = & $read $f; $m = & $meta $f; $lb = [string]$s.label; $labels[$lb] = 1 + [int]$labels[$lb]
        $r = $res[$s.agentId]; $age = ($Now - [IO.File]::GetLastWriteTime($f)).TotalMinutes
        $out = if ($r) { if ($r.error -or $r.ok -eq $false) { 'fail' } elseif (& $isEmpty $r) { 'empty' } else { 'pass' } } elseif ($failed["$($s.agentId)"]) { 'fail' } elseif ($live -and $age -lt $stuck) { 'running' } elseif ($live) { 'stuck' } else { 'stopped' }
        $model = if ($u.model) { $u.model } else { "$($m.model)" }
        $st = & $mkStep $u $model @{ run = $name; wid = $w.Name; label = $lb; type = (($lb -split ':')[0] -creplace '-[A-Z][\w-]*$'); role = "$($m.agentType)"; result = $out; round = $labels[$lb]; retry = [int]$noRes[$lb]; at = (& $atOf $u $f)
          mrs = @($r.mrs | Where-Object merged | ForEach-Object { "$(if ($_.url) { $_.url } else { $_.ref })" }) }
        if (-not $r) { $noRes[$lb] = 1 + [int]$noRes[$lb] }; if ($st) { $rs.Add($st); $steps.Add($st) } }   # retry: earlier starts of the label with no result
      if (-not $rs.Count) { continue }
      $items = @(@($rec | ForEach-Object { $_.args.agents }) | ForEach-Object { "$($_.items)" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique).Count
      $a0 = @($rec | ForEach-Object args | Where-Object { $_ })[0]; $scr = [IO.Path]::GetFileName("$(@($rec.script | Where-Object { $_ })[0])")
      $runs.Add([pscustomobject]@{ run = $name; id = $w.Name; label = (Get-KitRunLabel $a0); kind = $(if ($scr -match 'testy') { 'test' } elseif ($scr -match 'buildy') { 'build' } elseif ($scr -match 'tidy|retro') { 'kit' } else { '' }); started = $w.CreationTime.ToString('o'); status = $(if ($live) { 'running' } else { 'ended' }); cap = [long]$cap; spent = [long]$spent; tok = [long]($rs | Measure-Object tok -Sum).Sum; cost = $(if (@($rs | Where-Object { $null -ne $_.cost }).Count) { [math]::Round(($rs | Measure-Object cost -Sum).Sum, 2) })
          in = [long]($rs | Measure-Object in -Sum).Sum; out = [long]($rs | Measure-Object out -Sum).Sum; cr = [long]($rs | Measure-Object cr -Sum).Sum; cw = [long]($rs | Measure-Object cw -Sum).Sum
          wall = [math]::Round(($w.LastWriteTime - $w.CreationTime).TotalMinutes); roles = (@($rs | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = @($rs | Where-Object { $_.result -in 'pass', 'empty', 'fail' }).Count; total = $rs.Count; merged = @($rs.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = $items
          loop = [long](@($rs | Where-Object { $_.type -in 'review', 'fix' }) | Measure-Object tok -Sum).Sum; at = $w.LastWriteTime.ToString('o'); steps = @($rs) }) }
    foreach ($f in @(Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # Agent-tool spawns, by coordinator session
      $u = & $read $f.FullName; $m = & $meta $f.FullName; $k = $sd.Name; $model = if ($u.model) { $u.model } else { "$($m.model)" }; $rl = if ($m.agentType) { "$($m.agentType)" } else { 'agent' }
      $st = & $mkStep $u $model @{ label = "$($m.description)"; type = 'agent'; role = $rl; at = $f.LastWriteTime.ToString('o') }; if (-not $st) { continue }
      if (-not $bg[$k]) { $bg[$k] = [ordered]@{ session = $k; n = 0; tok = 0L; cost = $null; roles = @{}; at = '' } }; $g = $bg[$k]; $g.n++; $g.tok += $st.tok; if ($null -ne $st.cost) { $g.cost = [double]$g.cost + $st.cost }
      $g.roles[$rl] = 1 + [int]$g.roles[$rl]; if ($st.at -gt $g.at) { $g.at = $st.at }; $steps.Add($st) }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # main sessions: the coordinator's own turns
    $u = & $read $f.FullName; $st = & $mkStep $u "$($u.model)" @{ label = "session $($f.BaseName)"; type = 'coordinator'; role = 'coordinator'; at = (& $atOf $u $f.FullName) }; if (-not $st -or -not $st.tok) { continue }
    $steps.Add($st); $coord.Add([pscustomobject]@{ session = $f.BaseName; model = $st.model; tok = $st.tok; cost = $(if ($null -ne $st.cost) { [math]::Round($st.cost, 2) }); min = $st.min; at = $st.at }) }
  foreach ($k in @($cache.Keys)) { if (-not $seen[$k]) { $cache.Remove($k) } }   # older than $Days: dropped
  $grp = { param([string]$by) @($steps | Where-Object { $_.$by -and $_.tok } | Group-Object $by | ForEach-Object { $g = @($_.Group); [pscustomobject]@{ k = $_.Name; n = $g.Count; sum = [long]($g | Measure-Object tok -Sum).Sum; cost = $(if (@($g | Where-Object { $null -ne $_.cost }).Count) { [math]::Round((@($g | Where-Object { $null -ne $_.cost }) | Measure-Object cost -Sum).Sum, 2) }); avg = [long]($g | Measure-Object tok -Average).Average; p50 = (Get-KitPct $g.tok 0.5); p90 = (Get-KitPct $g.tok 0.9); avgMin = $(if (@($g.min | Where-Object { $null -ne $_ }).Count) { [math]::Round(($g.min | Where-Object { $null -ne $_ } | Measure-Object -Average).Average, 1) }); p90Min = (Get-KitPct $g.min 0.9) } } | Sort-Object { -$_.avg * $_.n }) }
  $wf = @($steps | Where-Object run); $ended = @($wf | Where-Object result -in 'pass', 'empty', 'fail', 'stopped')   # stopped: ended with no result
  $hostMrs = Get-KitUsageHostMrs $since $Now $all.host
  $dayRows = @(foreach ($dk in $dayKeys) { $ds = @($steps | Where-Object { $_.dayc[$dk] }); $tk = 0L; $dc = [Collections.Generic.List[double]]::new()
      foreach ($x in $ds) { $dv = @($x.dayc[$dk]); $tk += [long]$dv[0]; if ($null -ne $dv[1]) { $dc.Add([double]$dv[1]) } }
      [pscustomobject]@{ day = $dk; tok = $tk; cost = $(if ($dc.Count) { [math]::Round(($dc | Measure-Object -Sum).Sum, 2) }); runs = @($ds | Where-Object wid | ForEach-Object wid | Select-Object -Unique).Count
        merged = $(if ($hostMrs) { @($hostMrs.mrs | Where-Object { "$($_.day)" -eq $dk }).Count } else { @(@($steps | Where-Object { "$($_.at)".StartsWith($dk) }).mrs | Where-Object { $_ } | Select-Object -Unique).Count }) } })
  $usageOut = [pscustomobject]@{ at = $Now.ToString('o'); since = $since.ToString('o'); partial = $script:KitUsagePartial; runs = @($runs | Sort-Object at -Descending); bg = @($bg.Values | ForEach-Object { [pscustomobject]@{ session = $_.session; n = $_.n; tok = $_.tok; cost = $(if ($null -ne $_.cost) { [math]::Round($_.cost, 2) }); roles = (@($_.roles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ') } } | Sort-Object { -$_.tok })
    coord = @($coord | Sort-Object { -$_.tok }); modelCost = @($mcost.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = [math]::Round($_.Value, 2) } }); unpriced = @($unp.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ model = $_.Key; tok = $_.Value } })
    merged = $(if ($hostMrs) { [pscustomobject]@{ source = 'host'; user = $hostMrs.user; n = @($hostMrs.mrs).Count } } else { [pscustomobject]@{ source = 'workflows'; user = ''; n = @($wf.mrs | Where-Object { $_ } | Select-Object -Unique).Count } })
    byType = (& $grp type); byRole = (& $grp role); byModel = (& $grp model)
    rates = [pscustomobject]@{ n = $ended.Count; empty = @($ended | Where-Object result -eq 'empty').Count; fail = @($ended | Where-Object result -eq 'fail').Count; stopped = @($ended | Where-Object result -eq 'stopped').Count; stuck = @($wf | Where-Object result -eq 'stuck').Count; running = @($wf | Where-Object result -eq 'running').Count }
    days = $dayRows }
  try { Write-KitAtomic $cf (@{ files = $cache; host = $hostMrs } | ConvertTo-Json -Depth 7 -Compress); Write-KitAtomic ($cf -replace '\.json$', '.result.json') ($usageOut | ConvertTo-Json -Depth 10 -Compress) } catch {}
  $usageOut
  } finally { $lkh.Dispose(); Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }
}
# the last budget -Usage result (the page, a run that finds the lock taken)
function Read-KitUsageResult { try { Get-Content -LiteralPath ((Get-KitPath usage-cache) -replace '\.json$', '.result.json') -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 } catch { $null } }
# the page's usage parts (budget -Usage result), each number once: runs (one line each, steps folded), usage (today tiles, step
# outcomes bar, 7-day chart, role and model tables with share bars), top 5 steps (7 days, today marked), internals (per step type, sessions when 2+)
# called by Format-KitSuperviseHtml: its helpers ($e $n1 $grid $table $bar $trend $at) by dynamic scope
function Format-KitUsageHtml($U) {
  if (-not $U -or -not @($U.days).Count) { return [pscustomobject]@{ runs = ''; runsN = $null; usage = '<p class=empty>No usage yet: bossy.ps1 budget -Usage runs each sweep.</p>'; internals = '' } }
  $tk = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 1e9) { "$(& $n1 ([math]::Round([double]$v / 1e9, 2)))B" } elseif ([double]$v -ge 1e6) { "$(& $n1 ([double]$v / 1e6))M" } elseif ([double]$v -ge 1e3) { "$([math]::Round([double]$v / 1e3))k" } else { "$([long]$v)" } }
  $usd = { param($v) if ($null -eq $v) { '—' } else { '$' + ([double]$v).ToString($(if ([double]$v -ge 1000) { '#,0' } else { '0.00' }), [cultureinfo]::InvariantCulture) } }
  $mn = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 90) { "$(& $n1 ([double]$v / 60)) h" } else { "$(& $n1 $v) min" } }
  $dy = @($U.days | Where-Object { $_ }); $td = $dy[-1]; $prev = @($dy | Select-Object -SkipLast 1)
  $avg = { param([string]$k) $vs = @($prev | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Average).Average } }
  $sum = { param([string]$k) $vs = @($dy | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Sum).Sum } }
  $runs = @($U.runs | Where-Object { $_ }); $wfTok = [double](($runs | Measure-Object tok -Sum).Sum); $loop = [double](($runs | Measure-Object loop -Sum).Sum)
  $merged = [int](($runs | Measure-Object merged -Sum).Sum); $items = [int](($runs | Measure-Object items -Sum).Sum); $rt = $U.rates; $bgs = @($U.bg | Where-Object { $_ }); $cos = @($U.coord | Where-Object { $_ })
  $allTok = [double](& $sum 'tok'); $hm = $U.merged; $onHost = $hm.source -eq 'host'; $unp = @($U.unpriced | Where-Object { $_ })
  $card = { param([string]$label, [string]$v, [string]$sub, [string]$w, [string]$cls = '') "<div class='st $cls' data-fit><div class=k>$(& $e $label)</div><div class=v>$v</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })$(if ($w) { "<div class=w>$(& $e $w)</div>" })</div>" }
  $pct = { param($a, $b) if ([double]$b) { [math]::Round(100 * [double]$a / [double]$b) } }
  # step outcomes: one stacked bar, counts in its legend (a part-of-whole with 4-6 parts reads better as one bar than a donut)
  $oc = @(@(@('pass', ([double]$rt.n - $rt.empty - $rt.fail - $rt.stopped), 'sage'), @('empty', $rt.empty, 'watch'), @('failed', $rt.fail, 'act'), @('stopped', $rt.stopped, 'slate'), @('running', $rt.running, 'mt'), @('stuck', $rt.stuck, 'plum')) | Where-Object { [double]$_[1] -gt 0 })
  $ocAll = [double](($oc | ForEach-Object { [double]$_[1] } | Measure-Object -Sum).Sum)
  $ocHtml = "<div class=sb role=img aria-label='workflow steps by outcome'>$(@($oc | ForEach-Object { "<i style='width:$(& $n1 (100 * [double]$_[1] / $ocAll))%;background:var(--$($_[2]))' title='$($_[0]): $([int]$_[1])'></i>" }) -join '')</div><ul class=ocl>$(@($oc | ForEach-Object { "<li><i style='background:var(--$($_[2]))'></i>$($_[0]) <b>$([int]$_[1])</b></li>" }) -join '')</ul>"
  # today's tokens and cost: the Per day chart's labelled today point (no tile repeats them)
  $kpis = & $grid stats 170px @(
    $(if ($onHost) { $hn = [int]$hm.n; & $card 'Tokens per merged MR' "$(if ($hn) { & $tk ($allTok / $hn) } else { '—' })" "$hn MR(s) merged on the git host by $($hm.user) · $merged reported by workflows · $items item(s)" 'all tokens' }
      else { & $card 'Tokens per MR reported by workflows' "$(if ($merged) { & $tk ($wfTok / $merged) } else { '—' })" "$merged MR(s) reported merged by workflows (no git-host login) · $items item(s): $(if ($items) { & $tk ($wfTok / $items) } else { '—' }) per item" 'workflow runs' }),
    ((& $card 'Review + fix share' "$(if ($wfTok) { & $n1 (& $pct $loop $wfTok) } else { '—' })<small>%</small>" '' '' $(if ($wfTok -and $loop / $wfTok -gt 0.5) { 'warn' })) -replace '</div>$', "$(if ($wfTok) { & $meter $loop $wfTok 'of the workflow tokens · tick = 50% (warn)' $(if ($loop / $wfTok -gt 0.5) { 'watch' } else { 'slate' }) ($wfTok / 2) } else { '<div class=s>of the workflow tokens</div>' })</div>")) 2
  $ocCard = & $fold 'u-outcome' 'Workflow steps by outcome' ([int]$ocAll) $ocHtml -Open -tag h4 -cls "sub st uc $(if ($rt.stuck -or $rt.fail) { 'warn' })"
  # 7 days as lines (owner: no bar charts): est. cost = the solid filled line (left scale), tokens = the dashed line (right scale), a value
  # label per dot, today highlighted, the dotted 7-day average; the 7-day total once, in the title
  $dpts = @(for ($i = 0; $i -lt $dy.Count; $i++) { $d0 = $dy[$i]; $isToday = $i -eq $dy.Count - 1
      @{ label = $(if ($isToday) { 'today' } else { "$($d0.day)".Substring(5) }); x = $isToday; tip = "$($d0.day)$(if ($isToday) { ' (today)' }): $(& $tk $d0.tok) tokens · est. $(& $usd $d0.cost) · $($d0.runs) run(s) · $($d0.merged) MR(s) merged" } })
  $cAvg = & $avg 'cost'; $cMax = [double](@($dy | ForEach-Object { [double]$_.cost }) + 0 | Measure-Object -Maximum).Maximum; $tMax = [double](@($dy | ForEach-Object { [double]$_.tok }) + 0 | Measure-Object -Maximum).Maximum
  $lines = Format-KitLineChart $dpts @(@{ vals = @($dy | ForEach-Object { if ($null -eq $_.cost) { $null } else { [double]$_.cost } }); tone = 'sage'; style = 'solid'; area = $true; fmt = { param($v) if ($null -eq $v) { '—' } else { '$' + [math]::Round([double]$v) } } },
    @{ vals = @($dy | ForEach-Object { [double]$_.tok }); tone = 'slate'; style = 'dash'; fmt = { param($v) & $tk $v } }) "est. cost and tokens per day, $($dy.Count) days" 150 $cAvg -Labels
  $chart = & $fold 'u-days' 'Per day' "$(& $tk (& $sum 'tok')) tokens · $(& $usd (& $sum 'cost')) in 7 days" -Open -tag h4 -cls 'sub st uc' -inner "$lines<div class=ax><span><i class='lk t-sage solid'>est. cost (left, 0-$(& $usd $cMax))</i> <i class='lk t-slate dash'>tokens (right, 0-$(& $tk $tMax))</i></span>$(if ($cAvg) { "<span><i class='lk avg'>7-day avg $(& $usd $cAvg) (budget.prices)</i></span>" })</div>$(if ($unp.Count) { "<p class=m>not priced: $(& $e (@($unp | ForEach-Object { "$($_.model) $(& $tk $_.tok)" }) -join ', '))</p>" })"
  # role and model: one table each, the share as an inline bar (exact values in the cells, the bar for the comparison)
  $roles = @($U.byRole | Where-Object { $_ } | Sort-Object { -[double]$_.sum }); $rAll = [double](($roles | Measure-Object sum -Sum).Sum)
  $roleT = & $fold 'u-roles' 'Per role (coordinator, workflows, agents outside them)' $roles.Count -Open -tag h4 -cls 'sub st uc ur' -inner "$(& $table 'Role', '~Steps', 'Tokens', 'Share', 'Est. cost', '~Avg time', '~p90 time' @($roles | ForEach-Object { , @($_.k, $_.n, (& $tk $_.sum), @{ h = "<span>$(& $bar ([double]$_.sum) $rAll "$(& $pct $_.sum $rAll)%" 'slate')</span>" }, (& $usd $_.cost), (& $mn $_.avgMin), (& $mn $_.p90Min)) }))"
  $mdl = @($U.byModel | Where-Object { $_ } | Sort-Object { -[double]$_.cost }); $cAll = [double](($mdl | Where-Object { $null -ne $_.cost } | Measure-Object cost -Sum).Sum)
  $modelT = & $fold 'u-models' 'Per model' $mdl.Count -Open -tag h4 -cls 'sub st uc um' -inner "$(& $table 'Model', '~Steps', 'Tokens', 'Est. cost', 'Cost share', '~Avg time' @($mdl | ForEach-Object { , @(("$($_.k)" -replace '^claude-'), $_.n, (& $tk $_.sum), (& $usd $_.cost), @{ h = "<span>$(if ($cAll -and $null -ne $_.cost) { & $bar ([double]$_.cost) $cAll "$(& $pct $_.cost $cAll)%" 'plum' } else { '—' })</span>" }, (& $mn $_.avgMin)) }))"
  $stepRows = { param($ss) @($ss | ForEach-Object { , @($_.label, $_.role, ("$($_.model)" -replace '^claude-'), (& $tk $_.tok), "$(& $tk $_.in) / $(& $tk $_.out) / $(& $tk $_.cr) / $(& $tk $_.cw)", (& $mn $_.min), $_.tools, @{ h = "<span class='chip $(switch ($_.result) { 'pass' { 's-act' } 'running' { 's-fin' } 'stuck' { 's-stuck' } 'fail' { 's-stuck' } default { 's-oth' } })'>$(& $e $_.result)</span>" }, "$($_.round)$(if ($_.retry) { " · retry $($_.retry)" })") }) }
  # a run: its human label (mandate / area, the run id in the tooltip), kind chip, resumed, outcome-split step bar; budget bar while running or over 80%
  $kindOf = { param($r) if ($r.kind) { "$($r.kind)" } elseif ("$($r.roles)" -match '^(kitty \d+( · )?)+$') { 'kit' } elseif ("$($r.roles)" -match 'checky') { 'test' } else { 'build' } }
  $resumed = @{}; $firstOf = @{}; foreach ($r in @($runs | Sort-Object { "$(if ($_.started) { $_.started } else { $_.at })" })) { if ($firstOf.ContainsKey("$($r.run)")) { $resumed["$($r.id)"] = 1 } else { $firstOf["$($r.run)"] = 1 } }
  # steps by outcome in one bar (pass, empty, failed, running, stuck, stopped), each part titled with its count
  $segBar = { param($r) $tot = [math]::Max(1, [int]$r.total); $ps = @(foreach ($o in @(@('pass', 'sage'), @('empty', 'watch'), @('fail', 'act'), @('running', 'slate'), @('stuck', 'plum'), @('stopped', 'mt'))) { $n = @($r.steps | Where-Object result -eq $o[0]).Count; if ($n) { [pscustomobject]@{ k = $o[0]; c = $o[1]; n = $n } } })
    "<span class='bar sb3' title='$(& $e (@($ps | ForEach-Object { "$($_.k) $($_.n)" }) -join ' · '))'>$(@($ps | ForEach-Object { "<i class=$($_.c) style='width:$(& $n1 (100 * $_.n / $tot))%'></i>" }) -join '')</span><span class=bl>$($r.done)/$($r.total) steps</span>" }
  $runRow = { param($r) $bp = if ($r.cap) { [double]$r.spent / [double]$r.cap } else { 0 }; $lb = if ("$($r.label)".Trim()) { $r.label } else { $r.run }
      "<details class='ru f'><summary><span class=gn0 title='$(& $e "$($r.run) · $($r.id)")'>$(& $e $lb)</span><span class='chip k-$(& $e (& $kindOf $r))'>$(& $e (& $kindOf $r))</span>$(if ($resumed["$($r.id)"]) { "<span class='chip s-oth'>resumed</span>" })$(if ($r.status -eq 'running') { "<span class='chip s-act'>running</span>" })$(& $segBar $r)" +
      "<span class=m>$(& $tk $r.tok) tokens · $(& $usd $r.cost) · $(& $mn $r.wall)</span>$(if ([int]$r.merged) { "<span class='chip s-act'>$($r.merged) merged</span>" })$(if ($r.cap -and ($r.status -eq 'running' -or $bp -ge 0.8)) { & $bar ([double]$r.spent) ([double]$r.cap) "budget $(& $tk $r.spent) of $(& $tk $r.cap)" $(if ($bp -ge 0.8) { 'watch' }) })</summary>" +   # budget = context spend (budget -Run), not billed tokens
      "<div class=sy>$(& $table 'Step', 'Role', '~Model', 'Tokens', '~In / out / cache r / w', 'Elapsed', '~Tools', 'Result', '~Round' (& $stepRows @($r.steps | Sort-Object { -$_.tok })))</div></details>" }
  # dev and QA runs: running ones on top, then one fold per day (today open) with its one-line sum; kit runs (tidy, retro) not shown
  $devRuns = @($runs | Where-Object { (& $kindOf $_) -ne 'kit' })
  $dayOf = { param($r) try { ([datetimeoffset]"$(if ($r.started) { $r.started } else { $r.at })").LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } }
  $daySum = { param($g) "$($g.Count) runs · $(($g | Measure-Object done -Sum).Sum) steps · $(& $tk ($g | Measure-Object tok -Sum).Sum) tokens · $(& $usd (($g | Where-Object { $null -ne $_.cost } | Measure-Object cost -Sum).Sum)) · $(($g | Measure-Object merged -Sum).Sum) merged" }
  $shown = @($devRuns | Where-Object status -ne 'running' | Sort-Object { "$($_.at)" } -Descending | Select-Object -First 25)   # newest 25 ended with their step tables: the page stays light
  $runHtml = (@($devRuns | Where-Object status -eq 'running' | ForEach-Object { & $runRow $_ }) -join '') + (@(foreach ($g in @($devRuns | Where-Object status -ne 'running' | Group-Object { & $dayOf $_ } | Sort-Object Name -Descending)) {
      $dn = if ($g.Name -eq $at.ToString('yyyy-MM-dd')) { 'Today' } elseif ($g.Name -eq $at.AddDays(-1).ToString('yyyy-MM-dd')) { 'Yesterday' } elseif ($g.Name) { $g.Name.Substring(5) } else { 'Undated' }
      $old = @($g.Group | Where-Object { $shown -notcontains $_ }).Count
      & $fold "runs-$($g.Name)" $dn (& $daySum @($g.Group)) ((@($g.Group | Where-Object { $shown -contains $_ } | ForEach-Object { & $runRow $_ }) -join '') + $(if ($old) { "<p class=m>$old older run(s): supervise-report.json</p>" })) -Open:($dn -eq 'Today') -cls sub }) -join '')
  $aggT = "<div class='uc ua'><h4>tokens avg / p50 / p90 · time = elapsed</h4><div class=sy>$(& $table 'Key', 'N', 'Avg', '~p50', '~p90', 'Avg time', '~p90 time' @($U.byType | Where-Object { $_ } | ForEach-Object { , @($_.k, $_.n, (& $tk $_.avg), (& $tk $_.p50), (& $tk $_.p90), (& $mn $_.avgMin), (& $mn $_.p90Min)) }))</div></div>"
  # one session = its role row already; 2+ = a folded split per session
  $sess = $(if ($cos.Count -ge 2) { "<details class=ru><summary>Coordinator sessions ($($cos.Count))</summary><div class='sy us'>$(& $table 'Session', 'Tokens', 'Est. cost', 'Elapsed', 'Model' @($cos | ForEach-Object { , @($_.session, (& $tk $_.tok), (& $usd $_.cost), (& $mn $_.min), ("$($_.model)" -replace '^claude-')) }))</div></details>" }) +
    $(if ($bgs.Count -ge 2) { "<details class=ru><summary>Agents outside workflows, by session ($($bgs.Count))</summary><div class='sy us'>$(& $table 'Session', 'Agents', 'Tokens', 'Est. cost', 'Roles' @($bgs | ForEach-Object { , @($_.session, $_.n, (& $tk $_.tok), (& $usd $_.cost), $_.roles) }))</div></details>" })
  $nRunning = @($devRuns | Where-Object status -eq 'running').Count
  [pscustomobject]@{ runsN = @{ h = "<span class='iv$(if (-not $nRunning) { ' z' })'>$(Format-KitIcon run 'running runs')$nRunning</span> · $($devRuns.Count) in 7 days" }; runs = $(if ($runHtml) { "<div class='rus sy'>$runHtml</div>" } else { '<p class=empty>None</p>' })
    usage = "$(if ($U.partial) { '<p class=m>Transcripts still being read: numbers grow next sweep.</p>' })$kpis<div class=ug>$chart<div class=ucol>$ocCard$modelT</div>$roleT</div>$(& $fold 'steps' 'Per step type' @($U.byType | Where-Object { $_ }).Count "$aggT$sess" -cls sub)"   # folded: the page fits ~3 screens at 1366
    usageN = "$(& $tk $td.tok) tokens today" }
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

# board messages (bossy.ps1 board msg | inbox): one jsonl per agent
function Get-InboxFile([string]$Agent) { Join-Path (Get-KitPath board -Create) "inbox/$($Agent.ToLower() -replace '[^\w.-]', '_').jsonl" }
$script:KitMsgKinds = 'note', 'hold', 'dispute', 'rule', 'rollback', 'report', 'pause'   # board msg schema { kind, to, text, ref }
function Send-BoardMsg([string]$From, [string]$To, [string]$Text, [string]$Kind = 'note', [string]$Ref = '') {
  $f = Get-InboxFile $To; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $line = [ordered]@{ at = (Get-Date).ToString('o'); from = $From; to = $To; kind = $Kind; text = $Text; ref = $Ref; read = $false } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
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

# ---- heartbeat: the E1 cron call, an overdue coordinator (health), collision words in agent results (supervise)
function Get-KitBeatArmLine { "CronList has no heartbeat -> CronCreate cron '*/$([int](Get-KitParam 'supervise.heartbeatMinutes')) * * * *', recurring: true, durable: true, prompt ""$(Get-KitBeatPrompt)""" }
# health: the coordinator's beat passed while agents live (coordAt: not the OS timer's)
function Get-KitBeatOverdue([datetime]$Now = (Get-Date)) {
  $s = try { Get-Content (Get-KitPath supervise-state) -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
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
  $rx = [string](Get-KitSetting 'tracker.ciTaskPattern' '^\W*\[[^\]]*Unit Test\]'); $tt = try { Get-TrackerTask $Task } catch { $null }
  if (-not $rx -or "$($tt.name)" -notmatch $rx) { return $null }
  $d = "$($tt.description)" -replace '\\(?=[_*])', ''
  $jm = [regex]::Match($d, '(?<url>https?://[^\s)\]]+?/jobs/(?<id>\d+))'); $pm = [regex]::Match($d, '/pipelines/(?<id>\d+)'); $bm = [regex]::Match($d, '(?im)^\W*Branch\W*:\W*(?<b>[\w./-]+)')
  [pscustomobject]@{ url = $jm.Groups['url'].Value; job = $jm.Groups['id'].Value; run = $pm.Groups['id'].Value; branch = $bm.Groups['b'].Value }
}
# pass = a newer run of the same job on the branch whose commit holds every merged MR of the job's repo; wait = none yet / still running
function Test-KitCiTaskJob($Ci, [string[]]$Mrs) {
  if (-not ($Ci.job -and $Ci.run -and $Ci.branch)) { return @{ state = 'bad'; why = 'its description names no Job URL, Pipeline or Branch' } }
  $refs = @($Mrs | Where-Object { "$_" -match '^[^!]+!\d+$' } | ForEach-Object { $r, $n = "$_" -split '!'; [pscustomobject]@{ repo = (ProjPath $r); n = $n } } | Where-Object repo)
  $repo = @($refs | Where-Object { $Ci.url -like "*/$($_.repo)/*" } | ForEach-Object repo)[0]; if (-not $repo) { $repo = @($refs.repo)[0] }
  if (-not $repo) { return @{ state = 'bad'; why = 'no MR ref to find its repo' } }
  $name = "$(@(Invoke-HostVerb 'ci.jobs' @{ repo = $repo; id = $Ci.run }) | Where-Object { "$($_.id)" -eq $Ci.job } | ForEach-Object name | Select-Object -First 1)"
  if (-not $name) { return @{ state = 'bad'; why = "job $($Ci.job) not found in run $($Ci.run) of $repo" } }
  $shas = @(foreach ($x in @($refs | Where-Object repo -eq $repo)) { $m = Invoke-HostVerb 'mr.get' @{ repo = $repo; n = $x.n }; @($m.merge_commit_sha, $m.squash_commit_sha, $m.sha | Where-Object { $_ })[0] })
  if (@($shas | Where-Object { -not $_ }).Count -or $shas.Count -ne @($refs | Where-Object repo -eq $repo).Count) { return @{ state = 'bad'; why = "an MR of $repo unreadable (no merge commit)" } }
  foreach ($run in @(Invoke-HostVerb 'ci.runs' @{ repo = $repo; ref = $Ci.branch } | Where-Object { [long]$_.id -gt [long]$Ci.run } | Sort-Object { [long]$_.id } -Descending)) {
    if (@($shas | Where-Object { "$((Invoke-HostVerb 'repo.base' @{ repo = $repo; a = $_; b = $run.sha }).id)" -ne $_ }).Count) { continue }   # the fix not in this commit yet
    $jb = @(Invoke-HostVerb 'ci.jobs' @{ repo = $repo; id = $run.id }) | Where-Object name -eq $name | Select-Object -First 1; if (-not $jb -or (__CiWord "$($jb.status)") -in 'skipped', 'manual') { continue }   # not run there: an older run decides
    $url = if ($jb.web_url) { "$($jb.web_url)" } else { $Ci.url -replace "/jobs/$($Ci.job)\b", "/jobs/$($jb.id)" }
    switch (__CiWord "$($jb.status)") { 'success' { return @{ state = 'pass'; name = $name; url = $url } } { $_ -in 'failed', 'canceled' } { return @{ state = 'fail'; why = "CI job $name $($jb.status) again on $($Ci.branch) with the fix in: $url" } } default { return @{ state = 'wait'; why = "CI job $name $($jb.status) on $($Ci.branch): $url" } } }
  }
  @{ state = 'wait'; why = "no run of CI job $name on $($Ci.branch) with $(@($Mrs) -join ', ') in yet" }
}
# its job passed: closed + ONE QA comment (qa-result, edited in place) linking the passing job; state closed | wait | the reason
function Close-KitCiTask([string]$Task, $Ci, [string[]]$Mrs) {
  $cj = Test-KitCiTaskJob $Ci $Mrs; if ($cj.state -ne 'pass') { return @{ state = $cj.state; why = "CI task not closed: $($cj.why)" } }
  try { $null = Set-TrackerStatus $Task 'closed' } catch { return @{ state = 'error'; why = "could not set status 'closed' (retried next run): $_" } }
  try { $null = Set-TrackerKitComment $Task 'qa-result' "QA: PASS · CI job $($cj.name) passed on $($Ci.branch) with $(@($Mrs) -join ', ') merged: $($cj.url)" } catch { Write-Warning "QA comment of $Task not written: $_" }
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
      foreach ($wa in @(if ($wr.agents) { $wr.agents.PSObject.Properties })) { foreach ($dk in @((@($wa.Value.done) -join ' ') -split '[,\s]+' | Where-Object { $_ })) { $script:planDone["$($wa.Name)|$(NormTask $dk)"] = 1 } }
    }
  }
  @(foreach ($pr in $script:planRecs) {
      if ($Since -and [datetime]$pr.at -le [datetime]$Since) { continue }
      foreach ($pa in @($pr.args.agents | Where-Object { $_.id -and $_.items })) {
        if (@("$($pa.items)" -split '[,\s]+' | ForEach-Object { NormTask $_ }) -contains $TaskId -and -not $script:planDone["$($pa.id)|$TaskId"]) { "$($pa.id)" }
      } }) | Select-Object -Unique
}
# ---- the kit origin's main and goodies: no force push or delete, direct push on (branch.protect; never product repos)
function Set-KitOriginProtection {
  $kit = $KitConf.Kit; $gl, $gh = $env:GITLAB_HOST, $env:GH_HOST
  $lines = if ("$(git -C $kit remote get-url origin 2>$null)" -notmatch '^(?:\w+://)?(?:[^@/]+@)?(?<h>[^/:\\]{2,})(?::\d+)?[:/](?<r>[^:\\]+?)(?:\.git)?/?$') { 'origin failed: no origin remote with a host' } else {
    $h, $repo, $t = $Matches.h, $Matches.r, (Get-HostKind $Matches.h)
    if ($t -eq 'gitlab') { $env:GITLAB_HOST = $h } elseif ($t -eq 'github') { $env:GH_HOST = $h }
    foreach ($b in 'main', 'goodies') {
      if (-not (git -C $kit rev-parse --verify -q "refs/remotes/origin/$b" 2>$null)) { "$b failed: origin/$b not fetched (git fetch origin)"; continue }
      $r = try { Invoke-HostVerb 'branch.protect' @{ type = $t; repo = $repo; branch = $b } -NoMemo } catch { "failed: $_" }
      "$b $(if ($r) { $r } else { "failed: set it by hand on $h/$repo (force push off, deletion off, direct push on)" })"
    }
  }
  $env:GITLAB_HOST, $env:GH_HOST = $gl, $gh
  Set-Content (Get-KitPath kit-protect -Create) $lines
  $lines | ForEach-Object { "protect: $_" }
}
