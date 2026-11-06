<#
supervise_resources.ps1 (core): the machine's shared resources in bossy.ps1, dot-sourced by bossy.ps1
(skills/bossy/adapters/): build gate holders and queue, test locks, repeated build failures, the file cache flush (gate.cacheFlush),
phone leases, env leases, QA seats and claims, test browsers and their profiles, idle Gradle / Kotlin daemons, the RAM rows of
the supervise report, agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills), the report page (dashboard + Statistics from the logs; supervise.output, publish), seats and leases in board show and recover, the status resource rows, release (every lease of an agent).
Its hooks run inside the bossy.ps1 verb that calls them and use that verb's variables: supervise ($now, $mem, $keepFree, Within,
Left), cleanup ($now, $tmp, $DryRun, $actions, Gone, Old).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L13 builds · L46 supervise · L184 shells · L298 page · L539 release · L568 lines · L593 cleanup
#>
#Requires -Version 7
# ---- builds: repeated failures, cache flush
# gate history keys whose last 3 builds failed -> @{ key; who }: stale (last failure 60+ min old), its agent gone, or its agent built that dir green since -> no news
function Get-KitBuildFailures($Hist, [datetime]$Now, $Log = @(), [int]$Minutes = 60) {
  if (-not $Hist) { return }   # no gate history yet
  foreach ($k in @($Hist.Keys)) {
    $last = @($Hist[$k] | Select-Object -Last 3)
    if ($last.Count -ne 3 -or ($last | Where-Object { $_.ok }) -or -not $last[-1].at -or ($Now - [datetime]$last[-1].at).TotalMinutes -ge $Minutes) { continue }
    $failAt = [datetime]$last[-1].at; $dir = ($k -split '\|', 2)[-1]; $ends = @($Log | Where-Object { $_.event -eq 'end' -and $_.at })
    $who = @($ends | Where-Object { "$($_.kind)|$($_.project)" -eq $k -and [int]$_.code } | ForEach-Object owner)[-1]
    if ($who -and ((Test-KitLive @{ agent = $who }) -eq $false -or @($ends | Where-Object { $_.owner -eq $who -and -not [int]$_.code -and [datetime]$_.at -gt $failAt -and ("$($_.project)" -eq $dir -or "$($_.project)" -like "$dir/*" -or $dir -like "$($_.project)/*") }).Count)) { continue }
    [pscustomobject]@{ key = $k; who = $who }
  }
}
# a starved gate (its head waited 10+ min) while the file cache holds 25%+ of RAM: run gate.cacheFlush (an org command line, e.g. an
# elevated task) at most once per 30 min (stamp in the runtime cache); returns one flag or nothing, never throws
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
  for ($i = 0; $i -lt [math]::Min(5, [int]($TimeoutSec / 2)) -and $after -lt $Mem.AvailGB + 0.5; $i++) { Wait-KitPoll 2; $after = (Get-SysMem).AvailGB }   # a scheduled task flushes after its start returns; within the sweep budget
  [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: file cache flush: available $([math]::Round($Mem.AvailGB, 1)) -> $([math]::Round($after, 1)) GB"; action = 'Nothing to do.' }
}

# ---- supervise: resource flags and report rows
# supervise: flags, sweep lines, report rows and the largest waiting build (bossy.ps1 supervise section 3: before the slow sections)
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
  foreach ($bfx in Get-KitBuildFailures $hist $now @(Read-KitLog builds $now.AddHours(-24))) {   # the agent that ran them names the row
    $k = $bfx.key; $who = $bfx.who
    [pscustomobject]@{ level = 'WATCH'; what = "builds '$k' failed 3 times in a row"; kind = 'BUILDS'; who = $(if ($who) { $who } else { $k }); problem = "$k failed 3 times in a row"; next = "Check that agent's last build log"
      action = 'Repeated failing builds burn memory and turns; a setup-data cause (fixture, seed drift) -> spawn datay kind fixture, else help it or fix its brief.' } }
  if ($AutoFix -and (Within 'cache flush')) { Invoke-KitCacheFlush $wait $mem $now ([math]::Min(120, (Left))) }

  # phone leases whose holder is gone (phoney.ps1 shuts lanes down; dead emulators reboot on acquire)
  foreach ($lf in @(Get-ChildItem (Get-KitPath phones) -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $ls = try { Get-Content $lf.FullName -Raw | ConvertFrom-Json } catch { continue }; $age = [int]($now - [datetime]$ls.since).TotalMinutes
    if ($ls.agent -eq 'manual') {
      if ($age -ge 240) { & $flag 'WATCH' "phone $($ls.lane) booted by hand $([int]($age / 60)) h ago is still up" "If you are done with it: & $($KitCmd.swarm) release -Agent manual" }
      continue
    }
    if ($ls.agent -eq '__stopping__') { continue }
    $s0 = "$($ls.seen)"; $keep = Update-KitLease $ls
    if ($keep -and (-not $s0 -or ([datetime]$ls.seen - [datetime]$s0).TotalMinutes -ge 1) -and (Test-Path $lf.FullName)) { $ls | ConvertTo-Json -Depth 5 | Set-Content "$($lf.FullName).sv"; Move-Item "$($lf.FullName).sv" $lf.FullName -Force }   # atomic, never resurrects
    if ($keep) { if ($null -ne $ls.graceLeft) { $graceRows["phone $($ls.lane)"] = $ls.graceLeft }; continue }   # seen persists
    if ($AutoFix -and (Test-Path $KitCmd.swarm)) { $r = Invoke-KitLeaseReason "reclaim: no live holder for $($ls.graceMin) min" { & $KitCmd.swarm release -Agent $ls.agent 2>&1 }; & $flag 'INFO' "auto-fixed: reclaimed phone $($ls.lane) of $($ls.agent) (no live holder): $r" 'Nothing to do.' }
    else { & $flag 'ACT' "phone lease $($ls.lane) held by $($ls.agent): no live holder" "& $($KitCmd.swarm) release -Agent $($ls.agent)" }
  }
  # env leases and holds: envy.ps1 status prunes (and logs) the ones with no live holder past the grace
  if ($AutoFix -and $null -eq $script:KitEnvStatus -and (Within 'env leases')) { $null = Get-KitLocalEnvStatus }   # the local-env guard's status this round pruned them already

  # QA seats and claims of gone sessions (one line per gone session), orphan browser tabs
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
  "qa seats: $(@(Get-ChildItem (Join-Path $seatDir 'seats') -Filter *.json -ErrorAction SilentlyContinue).Count) taken"

  # RAM rows: test browsers, phones (up or waiting), builds; one process snapshot, each process counted once
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

# status rows (lib.ps1 status): agents queued at the build gate or waiting for a phone lane
# an agent past the prior-work gate (-Override / -NewTask, lib.ps1 Assert-KitPrior): one WATCH per override since the last beat
function Get-KitSuperviseFlagsPrior([switch]$AutoFix) {
  foreach ($e in @(Read-KitLog calls (Get-Date).AddMinutes(-(Get-KitBeatMinutes)) | Where-Object event -eq 'prior-override')) {
    [pscustomobject]@{ level = 'WATCH'; what = "prior override: $($e.what) $($e.task) ($($e.reason))"; action = 'Check it is no duplicate (crafty.ps1 prior -Task <id>); a duplicate: stop it, reuse the existing work' }
  }
}
function Get-KitStatusWaitResources {
  foreach ($t in @(Get-ChildItem (Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.owner -and (Test-KitPid $_.pid $_.start) })) {
    [pscustomobject]@{ agent = $t.owner; why = "build gate: RAM for $($t.kind)"; at = $t.since; next = 'the gate starts it when RAM frees' }
  }
  foreach ($w in @((Get-KitLockState).waiting)) { [pscustomobject]@{ agent = $w.holder; why = "test lock $($w.lock)"; at = $w.at; next = 'crafty.ps1 check takes it when its holder ends' } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 })) {
    $w = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }; [pscustomobject]@{ agent = $w.agent; why = "phone lane$(if ($w.lane) { " $($w.lane)" })"; at = $f.LastWriteTime; next = 'phoney.ps1 acquire hands it a lane' }
  }
}
# status: one row per resource from leases.jsonl (holder = an acquire < 24 h old not released since; phone lanes from their lease
# files); builds: supervise's RAM rows
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

# ---- shells: background shells Claude Code agents started (supervise Shells table, ORPHAN / STUCK flags, -AutoFix kills)
# one full process snapshot per supervise sweep (RAM rows, shells)
function Get-KitSweepProcs { if ($null -eq $script:KitSweepProcs) { $script:KitSweepProcs = @(Get-SysProcs) }; $script:KitSweepProcs }
# the command a tool shell runs: the body of the harness's eval '...' (bash), else what follows -Command / -c
function Get-KitShellCommand([string]$CommandLine) {
  $c = "$CommandLine"
  if ($c -match "(?s)\beval '(.*)'\s*(<\s*/dev/null\s*)?&&\s*pwd -P" -or $c -match "(?s)\beval '(.*)'") { return ($Matches[1] -replace "'\\''", "'" -replace '\\"', '"').Trim() }
  if ($c -match '(?i)\s-(?:e|enc|EncodedCommand)\s+([A-Za-z0-9+/=]{8,})') { try { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])).Trim() } catch {} }
  if ($c -match '(?is)\s-(?:c|Command)\s+(.*)$') { return ($Matches[1].Trim() -replace '^"(.*)"$', '$1' -replace '\\"', '"').Trim() }
  ($c -replace '^\s*("[^"]*"|\S+)\s*', '').Trim()
}
# the table cell: shell quoting ('"'"' / '\'') undone, cd / export preambles skipped, a heredoc as "<cmd> <<EOF (heredoc, N lines)", 60 chars
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
# the folder it works in: its first cd, else -Dir (Git Bash /d/x -> D:/x); '' when unknown or not absolute
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
# the transcript whose Bash / PowerShell tool_use ran this command, nearest in time to the shell's start; $null: none
function Find-KitShellTranscript([string]$Cmd, [datetime]$Created) {
  $frag = "$(@([regex]::Matches($Cmd, '[^"\\\r\n\t]{8,}') | Sort-Object Length -Descending)[0])"; if (-not $frag) { return $null }
  $frag = $frag.Substring(0, [math]::Min(120, $frag.Length)); $r = Invoke-KitAdapter transcript claude root
  if (-not $r.dir -or -not (Test-Path -LiteralPath $r.dir)) { return $null }
  $files = @(Get-ChildItem -LiteralPath $r.dir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Created.AddMinutes(-1) } | ForEach-Object FullName)
  $best = $null
  foreach ($h in @(if ($files) { Select-String -LiteralPath $files -SimpleMatch -Pattern $frag -ErrorAction SilentlyContinue })) {
    if ($h.Line -notmatch '"tool_use"') { continue }
    $o = try { $h.Line | ConvertFrom-Json -Depth 80 } catch { continue }
    $u = @($o.message.content | Where-Object { $_.type -eq 'tool_use' -and "$($_.input.command)".Contains($frag) })[0]; if (-not $u) { continue }
    $gap = if ($o.timestamp) { [math]::Abs(([datetimeoffset]$o.timestamp - [datetimeoffset]$Created).TotalSeconds) } else { 1e9 }
    if ($gap -le 120 -and (-not $best -or $gap -lt $best.gap)) { $best = [pscustomobject]@{ file = $h.Path; bg = [bool]$u.input.run_in_background; gap = $gap } }
  }
  $best
}
# its owner: a main session transcript = the coordinator (never finished); a workflow step: finished = a journal result; an
# Agent-tool subagent: its .meta.json finished; a board entry on that transcript: finished once left
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
  [pscustomobject]@{ name = $(if ($name) { "$name" } else { "agent $id" }); finished = [bool]$fin; coordinator = $false }
}
# supervise: Shells rows + flags; State.shells (pid@start): transcript, CPU sample, flat and STUCK sweeps. ORPHAN = owner finished or
# its dir gone; STUCK = no CPU growth since the last sweep and older than supervise.shellStuckMinutes (learned: lifetimes of shells
# that ended on their own). -AutoFix kills a finished owner's shell in the same sweep (a poll loop never goes flat)
function Get-KitShellSweep($State, [datetime]$Now, [switch]$AutoFix, $Procs = $(Get-KitSweepProcs)) {
  $stuckMin = [double](Get-KitParam 'supervise.shellStuckMinutes'); $old = if ($State.shells -is [Collections.IDictionary]) { $State.shells } else { @{} }; $new = @{}
  $kids = @{}; foreach ($p in $Procs) { if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[object]]::new() }; $kids[$p.ParentId].Add($p) }
  $board = @(Read-KitJsonFiles (Get-KitPath board)); $rows = [Collections.Generic.List[object]]::new(); $flags = [Collections.Generic.List[object]]::new(); $all = 0
  foreach ($p in @(Get-KitAgentShells $Procs)) {
    $all++; $made = if ($p.Created) { [datetime]$p.Created } else { $Now }; $age = ($Now - $made).TotalMinutes; $key = "$($p.Id)@$($made.ToString('s'))"
    $s = if ($old[$key] -is [Collections.IDictionary]) { $old[$key] } else { @{} }; $new[$key] = $s; if ($s.killed) { continue }; $cmd = Get-KitShellCommand $p.CommandLine
    if (-not $s.ContainsKey('tx')) { $f = Find-KitShellTranscript $cmd $made; $s.tx = "$($f.file)"; $s.bg = [bool]$f.bg }   # once: the tool_use line is written before the shell starts
    $tree = @{}; $cpu = 0.0; $st = [Collections.Stack]::new(); $st.Push($p)
    while ($st.Count) { $q = $st.Pop(); if ($tree[$q.Id]) { continue }; $tree[$q.Id] = 1; $cpu += [double]$q.Cpu; foreach ($c in @($kids[$q.Id])) { if ($c) { $st.Push($c) } } }
    $flat = $null -ne $p.Cpu -and $null -ne $s.cpu -and [math]::Abs($cpu - [double]$s.cpu) -lt 0.02
    $s.cpu = $cpu; $s.age = [math]::Round($age, 1)
    if (-not $s.bg -and $age -lt 10) { continue }   # a foreground tool call ends within the Bash tool's 10 min cap
    $s.listed = $true; $o = Get-KitShellOwner $s.tx $board; $dir = Get-KitShellDir $cmd; $gone = $dir -and -not (Test-Path -LiteralPath $dir)
    $stuck = $flat -and $age -ge $stuckMin
    if (-not $stuck) { $s.stuck = 0; $s.stuckAt = $null } elseif (-not $s.stuckAt -or ($Now - [datetime]$s.stuckAt).TotalMinutes * 2 -ge [double](Get-KitParam 'supervise.heartbeatMinutes')) { $s.stuck = [int]$s.stuck + 1; $s.stuckAt = $Now.ToString('o') }
    $why = @($(if ($o.finished) { "owner $($o.name) finished" }), $(if ($gone) { "dir gone: $dir" }), $(if ($stuck) { "no CPU growth, $($s.stuck) sweep(s)" }) | Where-Object { $_ }) -join '; '
    $short = Get-KitShellShort $cmd; $one = ($cmd -replace '\s+', ' ').Trim()
    if ($o.finished -and $AutoFix -and (Test-KitPid $p.Id $made)) {
      if ($KitIsWindows) { taskkill /PID $p.Id /T /F 2>&1 | Out-Null } else { foreach ($t in @($tree.Keys)) { Stop-SysProcess $t } }
      $s.killed = $true; Write-KitLog calls shell-kill ([ordered]@{ pid = $p.Id; owner = $o.name; why = $why; dir = $dir; what = "killed shell $($p.Id) ($why): $($one.Substring(0, [math]::Min(300, $one.Length)))" })
      $flags.Add([pscustomobject]@{ level = 'INFO'; what = "auto-fixed: killed shell $($p.Id) of $($o.name) ($why): $short"; action = 'Nothing to do.' }); continue
    }
    $shellState = @($(if ($o.finished -or $gone) { 'ORPHAN' }), $(if ($stuck) { 'STUCK' }) | Where-Object { $_ }) -join ', '; if (-not $shellState) { $shellState = 'running' }
    $tk = "taskkill /PID $($p.Id) /T /F"
    $next = if ($shellState -eq 'running') { '' } elseif ($o.coordinator) { "yours: stop it (KillShell) or $tk" } elseif ($o.finished) { "supervise -AutoFix kills it; now: $tk" } else { "$($o.name) ends it, else $tk" }
    $rows.Add([pscustomobject]@{ pid = $p.Id; short = $short; cmd = $cmd; owner = $o.name; age = [math]::Round($age); state = $shellState; next = $next; dir = $dir })
    $s60 = $short.Substring(0, [math]::Min(60, $short.Length))
    if ($shellState -ne 'running') { $flags.Add([pscustomobject]@{ level = 'WATCH'; kind = "SHELL $shellState"; who = $o.name; age = "$([int]$age) min"; problem = "pid $($p.Id) $s60`: $why"; what = "SHELL $shellState pid $($p.Id) of $($o.name) ($s60): $why"; action = $next }) }
  }
  foreach ($k in @($old.Keys)) { $g = $old[$k]; if (-not $new.ContainsKey($k) -and $g -is [Collections.IDictionary] -and $g.listed -and -not $g.killed) { Add-KitParamObs 'supervise.shellStuckMinutes' ([double]$g.age) -Default 30 } }   # it ended on its own
  $State.shells = $new
  [pscustomobject]@{ rows = @($rows); flags = @($flags); line = "shells: $all agent shell(s), $($rows.Count) listed" }
}
# supervise hook (section 3; the verb's $state, $now, Within): the sweep line and flags; the rows go to $script:KitShellRows (report)
function Get-KitSuperviseGuardShells([switch]$AutoFix) {
  $script:KitShellRows = @(); if (-not (Within 'shells')) { return }
  try { $sh = Get-KitShellSweep $state $now -AutoFix:$AutoFix; $script:KitShellRows = $sh.rows; $sh.line; $sh.flags }
  catch { [pscustomobject]@{ level = 'WATCH'; what = "shell sweep failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Get-KitShellSweep.' } }
}

# ---- page: supervise's report page (every mode) and the -Brief stdout per supervise.output
# the page's Statistics, one record a day (null = no source that day): board join / leave in calls (runs, spawned, finished,
# failed, durations), decisions asked / answered, deploys, lessons; closed days come back from the last page json ($Prev)
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
      $byPid = @{}   # a start event's agent / run / -Status, for its end (rc 'exit' = a pwsh exit, also success)
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
# RAM free (mem-samples) and each drive's free / fill rate (the sweep's disk lines, storage samples) for the gauges and sparklines
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
# supervise's live dashboard (every mode): one self-contained page + its .json, rewritten atomically; returns its path; a failure:
# a WATCH and '' (that round prints the tables)
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
  $stats = [ordered]@{ keepFree = $d.keepFree; days = @(try { Get-KitSuperviseDays $prior.stats.days $d.at } catch { }); ram = $series.ram; disks = $series.disks; settings = [pscustomobject]$settings
    changes = @(Get-Content -LiteralPath (Get-KitPath params-changes) -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop | Select-Object at, key, ctx, from, to, why } catch { } }) }
  $j = [pscustomobject]@{ at = $d.at.ToString('o'); next = $Next; flags = @($fl); agents = @($d.rows); mem = $d.mem; resources = @($d.resources); shells = @($d.shells); history = @($History); sweep = @($Sweep); stats = $stats }
  Write-KitAtomic $pj ($j | ConvertTo-Json -Depth 6)
  Write-KitAtomic $p (Format-KitSuperviseHtml $j)
  $pub = [string](Get-KitSetting 'supervise.publish' '')   # the bytes never pass through the model
  if ($pub.Trim()) {   # encoded: Windows strips the double quotes of a joined -Command line
    $sp = @{ FilePath = 'pwsh'; ArgumentList = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pub))); ErrorAction = 'Stop' }; if ($KitIsWindows) { $sp.WindowStyle = 'Hidden' }
    $env:KIT_SUPERVISE_HTML = $p; try { Start-Process @sp | Out-Null } catch { Write-Warning "supervise.publish failed to start: $($_.Exception.Message)" } finally { Remove-Item Env:KIT_SUPERVISE_HTML -ErrorAction SilentlyContinue } }
  $p
  } catch { $w = [pscustomobject]@{ level = 'WATCH'; what = "supervise page failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Write-KitSuperviseHtml.' }; $d.flags = @($d.flags) + $w; if ($flags -is [Collections.IList]) { [void]$flags.Add($w) }; '' }   # $flags: the supervise verb's list (-Json, plain)
}
# the page from its json (pure: the tests feed a sample): header, KPI tiles, flags, gauges, history, agents, timeline, statistics,
# resources, shells, settings; every data value is HtmlEncoded; inline CSS / JS / SVG only (no request leaves the page)
function Format-KitSuperviseHtml($j) {
  $iv = [cultureinfo]::InvariantCulture; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $n1 = { param($x) ([double]$x).ToString('0.#', $iv) }
  $toTime = { param($x) if ($x) { try { [datetime]$x } catch { $null } } }; $at = & $toTime $j.at; if (-not $at) { $at = Get-Date }
  $ago = { param($x) $tx = & $toTime $x; if (-not $tx) { return '' }; $m = [int][math]::Max(0, ($at - $tx).TotalMinutes); if ($m -lt 1) { 'now' } elseif ($m -lt 60) { "$m min" } elseif ($m -lt 1440) { "$([math]::Floor($m / 60)) h $($m % 60) min" } else { "$([math]::Floor($m / 1440)) d" } }
  $when = { param($x) $tx = & $toTime $x; if ($tx) { "<span title='$($tx.ToString('yyyy-MM-dd HH:mm'))'>$(& $ago $x)</span>" } else { '<span class=m>—</span>' } }
  $big = { param($s) if ("$s".Trim() -match '^(\d+(?:\.\d+)?)\s*([kKmM]?)$') { $nv = [double]$Matches[1]; $nu = $Matches[2].ToLower(); $nv * $(if ($nu -eq 'k') { 1e3 } elseif ($nu -eq 'm') { 1e6 } else { 1 }) } }
  $stCls = { param($s) if ("$s" -match 'STUCK') { 's-stuck' } elseif ("$s" -match '^ACTIVE') { 's-act' } elseif ("$s" -match '^FINISHED') { 's-fin' } else { 's-oth' } }
  $spark = { param($vals, [string]$cls = 'sage') $vals = @($vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }); if ($vals.Count -lt 2) { return '' }
    $mx = ($vals | Measure-Object -Maximum).Maximum; $mn = ($vals | Measure-Object -Minimum).Minimum
    $pts = @(for ($i = 0; $i -lt $vals.Count; $i++) { "$(& $n1 (100 * $i / ($vals.Count - 1))),$(& $n1 $(if ($mx -eq $mn) { 12 } else { 22 - 20 * ($vals[$i] - $mn) / ($mx - $mn) }))" }) -join ' '
    "<svg class='spark $cls' viewBox='0 0 100 24' preserveAspectRatio=none aria-hidden=true><polygon class=a points='0,24 $pts 100,24'/><polyline class=l points='$pts'/></svg>" }
  $bar = { param([double]$v, [double]$max, [string]$label, [string]$tone = '') if ($max -le 0) { return '' }; $pc = [math]::Min(100, 100 * $v / $max); $bc = if ($tone) { $tone } elseif ($pc -ge 100) { 'act' } elseif ($pc -ge 80) { 'watch' } else { 'sage' }
    "<span class=bar><i class=$bc style='width:$(& $n1 $pc)%'></i></span><span class=bl>$(& $e $label)</span>" }
  $ring = { param([double]$pc, [string]$value, [string]$label, [string]$sub) $pc = [math]::Max(0, [math]::Min(100, $pc)); $rc = if ($pc -ge 90) { 'act' } elseif ($pc -ge 75) { 'watch' } else { 'sage' }; $arc = 2 * [math]::PI * 40 * 0.75
    "<figure class=gauge><svg viewBox='0 0 100 92' role=img aria-label='$(& $e $label): $(& $e $value)'><circle class=trk cx=50 cy=50 r=40 stroke-dasharray='$(& $n1 $arc) 999' transform='rotate(135 50 50)'/><circle class='val $rc' cx=50 cy=50 r=40 stroke-dasharray='$(& $n1 ($arc * $pc / 100)) 999' transform='rotate(135 50 50)'/><text x=50 y=50 class=gv>$(& $e $value)</text><text x=50 y=66 class=gl>$(& $e $label)</text></svg><figcaption>$(& $e $sub)</figcaption></figure>" }
  $section = { param([string]$id, [string]$title, $count, [string]$inner, [switch]$Closed) "<details class=sec id=sec-$id$(if (-not $Closed) { ' open' })><summary><h2>$(& $e $title)</h2>$(if ($null -ne $count) { "<span class=cnt>$(& $e $count)</span>" })</summary><div class=bd>$inner</div></details>" }
  $table = { param([string[]]$cols, $rows) if (-not @($rows).Count) { return '<p class=empty>None</p>' }
    "<div class=tw><table><tr>$(@($cols | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '')</tr>$(@(foreach ($r in @($rows)) { "<tr class=f>$(@($r | ForEach-Object { "<td>$(& $e $_)</td>" }) -join '')</tr>" }) -join '')</table></div>" }
  $agents = @($j.agents | Where-Object { $_ }); $live = @($agents | Where-Object state -ne 'FINISHED'); $flags = @($j.flags | Where-Object { $_ })
  $nAct = @($flags | Where-Object level -eq 'ACT').Count; $nWatch = @($flags | Where-Object level -eq 'WATCH').Count; $nFix = @($flags | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' }).Count
  $hist = @($j.history | Where-Object { $_ }); [array]::Reverse($hist)   # oldest first
  $hCount = { param($h, [string]$lv) @($h.flags | Where-Object level -eq $lv).Count }
  $nextMin = if ("$($j.next)" -match '(\d+(?:\.\d+)?)') { $Matches[1] } else { 15 }   # stale: older than 2 heartbeats (amber), 4 (red)
  $mem = $j.mem; $tot = [double]$mem.TotalGB; $avail = [double]$mem.AvailGB; $used = $tot - $avail; $st = $j.stats
  $disk = @($st.disks | Where-Object { $_ } | Sort-Object { [double]$_.free }) | Select-Object -First 1
  $markFile = Join-Path $script:KitRoot 'assets/claude-crew-mark.svg'; $mark = if (Test-Path -LiteralPath $markFile) { (Get-Content -LiteralPath $markFile -Raw) -replace '<\?xml[^>]*>\s*', '' -replace '\s+', ' ' } else { '' }
  # header + KPI tiles
  $tile = { param([string]$key, [string]$value, [string]$sub, [string]$sp, [string]$cls = '') "<div class='tile $cls'><div class=k>$(& $e $key)</div><div class=v>$(& $e $value)</div><div class=s>$(& $e $sub)</div>$sp</div>" }
  $kpi = '<section class=kpis>' + (& $tile 'Active agents' $live.Count "$($agents.Count - $live.Count) finished · $(@($agents | Where-Object { $_.state -match 'STUCK' }).Count) stuck" (& $spark @($hist | ForEach-Object active) 'sage')) +
    (& $tile 'ACT' $nAct 'needs you now' (& $spark @($hist | ForEach-Object { & $hCount $_ 'ACT' }) 'act') $(if ($nAct) { 'hot' })) +
    (& $tile 'WATCH' $nWatch 'resolve without asking' (& $spark @($hist | ForEach-Object { & $hCount $_ 'WATCH' }) 'watch')) +
    (& $tile 'FIXED' $nFix 'auto-fixed this sweep' (& $spark @($hist | ForEach-Object fixed) 'sage')) +
    (& $tile 'RAM used' $(if ($tot) { "$(& $n1 $used) / $(& $n1 $tot) GB" } else { '—' }) $(if ($tot) { "$(& $n1 $avail) GB free · floor $(& $n1 $st.keepFree) GB" } else { 'no sample' }) (& $spark @($st.ram) 'slate')) +
    (& $tile 'Disk free' $(if ($disk) { "$(& $n1 $disk.free) GB" } else { '—' }) $(if ($disk) { "$($disk.drive) · $(if ([double]$disk.rate -ge 0) { '+' })$(& $n1 $disk.rate) GB/h" } else { 'no sample' }) (& $spark @($disk.series) 'slate')) + '</section>'
  # flags: ACT, then WATCH, as cards with the next step; INFO in a list
  $card = { param($f) $c = Get-KitFlagCells $f; $lv = if ($f.level -eq 'ACT') { 'ACT' } else { 'WATCH' }
    "<article class='flag $lv f'><div class=h><span class='chip lv $lv'>$lv</span>$(@($c.kind, $c.who, $c.age | Where-Object { "$_".Trim() } | ForEach-Object { "<span>$(& $e $_)</span>" }) -join '<span class=dot>·</span>')</div><div class=w>$(& $e $c.problem)</div>$(if ("$($c.action)".Trim()) { "<div class=n><b>Next</b> $(& $e $c.action)</div>" })</article>" }
  $info = @($flags | Where-Object level -eq 'INFO')
  $flagHtml = $(if ($nAct + $nWatch) { @($flags | Where-Object level -in 'ACT', 'WATCH' | Sort-Object { $_.level -ne 'ACT' } | ForEach-Object { & $card $_ }) -join '' } else { '<p class=empty>No ACT or WATCH flags: all clear.</p>' }) +
    $(if ($info.Count) { "<ul class=info>$(@($info | ForEach-Object { "<li class=f>$(& $e $_.what)</li>" }) -join '')</ul>" })
  # gauges: RAM, disk, agents by state
  $byState = @($agents | Group-Object { & $stCls $_.state } | ForEach-Object { [pscustomobject]@{ cls = $_.Name; n = $_.Count; label = "$(@($_.Group)[0].state)" -replace '\s.*' } })
  $circ = 2 * [math]::PI * 38; $off = 0
  $arcs = @(foreach ($s in $byState) { $len = $circ * $s.n / [math]::Max(1, $agents.Count); "<circle class='val $($s.cls)' cx=50 cy=50 r=38 stroke-dasharray='$(& $n1 $len) $(& $n1 ($circ - $len))' stroke-dashoffset='$(& $n1 (-$off))' transform='rotate(-90 50 50)'><title>$(& $e $s.label): $($s.n)</title></circle>"; $off += $len })
  $donut = "<figure class=gauge><svg viewBox='0 0 100 92' role=img aria-label='agents by state'><circle class=trk cx=50 cy=50 r=38 />$($arcs -join '')<text x=50 y=50 class=gv>$($agents.Count)</text><text x=50 y=66 class=gl>agents</text></svg><figcaption>$(@($byState | ForEach-Object { "<span class='lg $($_.cls)'>$(& $e $_.label) $($_.n)</span>" }) -join ' ')</figcaption></figure>"
  $gauges = '<div class=gauges>' + $(if ($tot) { & $ring (100 * $used / $tot) "$([int](100 * $used / $tot))%" 'RAM' "$(& $n1 $avail) GB free" } else { & $ring 0 '—' 'RAM' 'no sample' }) +
    $(if ($disk -and [double]$disk.total) { & $ring (100 - 100 * [double]$disk.free / [double]$disk.total) "$([int](100 - 100 * [double]$disk.free / [double]$disk.total))%" "disk $($disk.drive)" "$(& $n1 $disk.free) GB free" } else { & $ring 0 '—' 'disk' 'no sample' }) + $donut + '</div>'
  # history: flags by level per sweep (stacked), oldest left
  $hMax = [math]::Max(1, (@($hist | ForEach-Object { (& $hCount $_ 'ACT') + (& $hCount $_ 'WATCH') + [int]$_.fixed }) + 0 | Measure-Object -Maximum).Maximum)
  $bw = 100 / [math]::Max(1, $hist.Count)
  $rects = @(for ($i = 0; $i -lt $hist.Count; $i++) { $h = $hist[$i]; $y = 60; $x = & $n1 ($i * $bw + $bw * 0.15); $w = & $n1 ($bw * 0.7)
    foreach ($seg in @(@('a', (& $hCount $h 'ACT')), @('w', (& $hCount $h 'WATCH')), @('x', [int]$h.fixed))) { if (-not $seg[1]) { continue }; $hh = 56 * $seg[1] / $hMax; $y -= $hh; "<rect class=$($seg[0]) x=$x y=$(& $n1 $y) width=$w height=$(& $n1 $hh) />" }
    "<rect class=hit x=$(& $n1 ($i * $bw)) y=0 width=$(& $n1 $bw) height=60><title>$(& $e $(try { ([datetime]$h.at).ToString('HH:mm') } catch { $h.at })): $(& $hCount $h 'ACT') ACT, $(& $hCount $h 'WATCH') WATCH, $([int]$h.fixed) fixed</title></rect>" })
  $histHtml = if ($hist.Count) { "<div class=hist><svg viewBox='0 0 100 60' preserveAspectRatio=none role=img aria-label='flags per sweep'>$($rects -join '')</svg><div class=ax><span>$(& $e $(try { ([datetime]$hist[0].at).ToString('HH:mm') } catch { '' }))</span><span><i class='lg act'>ACT</i> <i class='lg watch'>WATCH</i> <i class='lg sage'>FIXED</i></span><span>$(& $e $(try { ([datetime]$hist[-1].at).ToString('HH:mm') } catch { '' }))</span></div></div>" } else { '<p class=empty>No sweeps yet.</p>' }
  # agents, grouped by run: state chip, since, last progress; the run's steps and tokens as bars
  $groups = @($agents | Group-Object { "$($_.run)" } | Sort-Object { -not @($_.Group | Where-Object state -ne 'FINISHED').Count }, { -not $_.Name }, Name)
  $tokRuns = [Collections.Generic.List[object]]::new()
  $agentHtml = if (-not $agents.Count) { '<p class=empty>No agents on the board.</p>' } else { '<div class=tw><table class=ag><tr><th>State</th><th>Agent</th><th class=hs>Task</th><th>Since</th><th>Last progress</th><th class=hs>Doing · next</th></tr>' + (@(foreach ($g in $groups) {
    $wf = @($g.Group | Where-Object { "$($_.name)" -like '* (workflow)' }) | Select-Object -First 1; $meta = "$($wf.task) $($wf.done)"
    $steps = if ($meta -match '(\d+)/(\d+) steps|steps (\d+)/(\d+)') { if ($Matches[1]) { [double]$Matches[1], [double]$Matches[2] } else { [double]$Matches[3], [double]$Matches[4] } }
    $toks = if ($meta -match '([\d.]+[kKmM]?) tokens of ([\d.]+[kKmM]?)') { $tk = $Matches[1], $Matches[2]; (& $big $tk[0]), (& $big $tk[1]), "$($tk[0]) of $($tk[1]) tokens" }
    if ($toks -and $g.Name) { $tokRuns.Add(@($g.Name, $toks)) }
    "<tbody class=grp><tr class=gh><th colspan=6><span class=gn0>$(if ($g.Name) { & $e $g.Name } else { 'no run' })</span><span class=m> $($g.Count) agent(s) · $(@($g.Group | Where-Object state -ne 'FINISHED').Count) active</span>$(if ($steps) { & $bar $steps[0] $steps[1] "$($steps[0])/$($steps[1]) steps" 'sage' })$(if ($toks) { & $bar $toks[0] $toks[1] $toks[2] })</th></tr>" +
    (@(foreach ($a in @($g.Group | Sort-Object { $_.state -eq 'FINISHED' }, name)) { $sub = @($a.wait, $a.done, $a.stopped | Where-Object { "$_".Trim() }) -join ' · '
      "<tr class=f><td><span class='chip $(& $stCls $a.state)'>$(& $e ("$($a.state)" -replace '\s.*'))</span>$(if ($sub) { "<div class=sm>$(& $e $sub)</div>" })</td><td>$(& $e $a.name)</td><td class=hs>$(& $e $a.task)</td><td>$(& $when $a.since)</td><td>$(& $when $a.last)</td><td class=hs>$(& $e $a.doing)$(if ("$($a.next)".Trim()) { "<div class=sm>$(& $e $a.next)</div>" })</td></tr>" }) -join '') + '</tbody>' }) -join '') + '</table></div>' }
  # timeline: today's agent lifetimes (since -> last progress), coloured by state
  $lanes = @($agents | ForEach-Object { $s0 = & $toTime $(if ($_.started) { $_.started } else { $_.since }); $s1 = if ($_.state -eq 'FINISHED') { & $toTime $(if ($_.last) { $_.last } else { $_.ended }) } else { $at }
    if ($s0 -and $s0.Date -eq $at.Date) { [pscustomobject]@{ a = $_; t0 = $s0; t1 = $(if ($s1 -and $s1 -gt $s0) { $s1 } else { $s0 }) } } } | Sort-Object t0 | Select-Object -Last 40)
  $ganttHtml = if (-not $lanes.Count) { '<p class=empty>No agent started today.</p>' } else {
    $g0 = $lanes[0].t0; $span = [math]::Max(30, ($at - $g0).TotalMinutes); $pos = { param($tx) & $n1 (100 * ($tx - $g0).TotalMinutes / $span) }
    $ticks = @(for ($tk0 = $g0.Date.AddHours($g0.Hour + 1); $tk0 -lt $at; $tk0 = $tk0.AddHours($(if ($span -gt 600) { 2 } else { 1 }))) { "<span style='left:$(& $pos $tk0)%'>$($tk0.ToString('HH:mm'))</span>" })
    '<div class=gantt>' + (@($lanes | ForEach-Object { $w0 = [math]::Max(0.4, 100 * ($_.t1 - $_.t0).TotalMinutes / $span); $tip = "$($_.a.name) · $($_.a.state) · $($_.t0.ToString('HH:mm'))-$($_.t1.ToString('HH:mm'))"
      "<div class='gr f'><span class=gl0 title='$(& $e $tip)'>$(& $e $_.a.name)</span><span class=gt><i class='gb $(& $stCls $_.a.state)' style='left:$(& $pos $_.t0)%;width:$(& $n1 $w0)%' title='$(& $e $tip)'></i></span></div>" }) -join '') + "<div class=gx>$($ticks -join '')</div></div>" }
  # statistics: today vs yesterday, last 7 days vs the 7 before; '—' = no source
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
  $statsHtml = '<div class=stats>' + (& $card4 'Runs' 'runs') + (& $card4 'Agents spawned' 'spawned') + (& $card4 'Agents finished' 'finished' 1) + (& $card4 'Agents failed' 'failed' -1) +
    (& $statCard 'Avg agent duration' (& $avgOf 0) (& $avgOf 1) (& $avgOf $wk) $(if (& $same 'durN') { & $avgOf $pw }) 0 ' min') + (& $card4 'Deploys recorded' 'deploys') +
    (& $card4 'Decisions asked' 'asked') + (& $card4 'Decisions answered' 'answered' 1) + (& $card4 'Lessons recorded' 'lessons') +
    "<div class=st><div class=k>Flags auto-FIXED</div><div class=v>$(& $fmt (& $fxPct 0 $hist.Count))<small>%</small>$(if ($half) { & $trend (& $fxPct $half $hist.Count) (& $fxPct 0 $half) 1 })</div><div class=w>$(($fxFixed | Measure-Object -Sum).Sum) of $(($fxRaised | Measure-Object -Sum).Sum) flags, last $($hist.Count) sweeps</div></div></div>" +
    $(if ($tokRuns.Count) { '<h3>Tokens vs budget per run</h3><div class=toks>' + (@($tokRuns | ForEach-Object { "<div class=f><span class=tn>$(& $e $_[0])</span>$(& $bar $_[1][0] $_[1][1] $_[1][2])</div>" }) -join '') + '</div>' } else { '<h3>Tokens vs budget per run</h3><p class=empty>—</p>' })
  # resources, shells, settings
  $resMax = [math]::Max(0.01, (@($j.resources | ForEach-Object { [double]$_.gb }) + 0 | Measure-Object -Maximum).Maximum)
  $resHtml = if (-not @($j.resources | Where-Object { $_ }).Count) { '<p class=empty>No resource held.</p>' } else { '<div class=tw><table><tr><th>Resource</th><th>Holder</th><th>GB</th></tr>' + (@($j.resources | Where-Object { $_ } | Sort-Object { -[double]$_.gb } | ForEach-Object { "<tr class=f><td>$(& $e $_.name)</td><td>$(& $e $_.by)</td><td class=num>$(& $bar ([double]$_.gb) $resMax (& $n1 $_.gb) 'slate')</td></tr>" }) -join '') + '</table></div>' }
  $shellHtml = & $table 'PID', 'Owner', 'Age min', 'State', 'Dir', 'Command', 'Next' @($j.shells | Where-Object { $_ } | ForEach-Object { , @($_.pid, $_.owner, $_.age, $_.state, $_.dir, $_.cmd, $_.next) })
  $setRows = @(if ($st.settings) { $st.settings.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) } })
  $chg = @($st.changes | Where-Object { $_ }); [array]::Reverse($chg)
  $setHtml = (& $table 'Key', 'Value' $setRows) + '<h3>Recent learned changes</h3>' + (& $table 'When', 'Key', 'Context', 'From', 'To', 'Why' @($chg | ForEach-Object { , @($(try { ([datetime]$_.at).ToString('MM-dd HH:mm') } catch { $_.at }), $_.key, $_.ctx, $_.from, $_.to, $_.why) }))
  $css = Get-KitSupervisePageCss
  $fav = if ($mark) { "<link rel=icon href='data:image/svg+xml,$([Uri]::EscapeDataString($mark))'>" }
  $js = "(function(){var d=document,L=localStorage,S=sessionStorage,r=d.documentElement,a=d.getElementById('age'),t=new Date(a.dataset.at),n=+a.dataset.next||15;function u(){var m=Math.round((Date.now()-t)/6e4);a.textContent='updated '+(m<1?'just now':m<60?m+' min ago':m<2880?Math.round(m/60)+' h ago':Math.round(m/1440)+' d ago');a.className='chip '+(m>4*n?'bad':m>2*n?'warn':'ok')}u();setInterval(u,3e4);" +
    "d.getElementById('tt').onclick=function(){var k=r.dataset.theme?r.dataset.theme=='dark':matchMedia('(prefers-color-scheme: dark)').matches;r.dataset.theme=k?'light':'dark';L.setItem('kc-theme',r.dataset.theme)};" +
    "var ar=d.getElementById('ar'),on=L.getItem('kc-ar')!=='0',tm;function sa(){ar.setAttribute('aria-pressed',on);ar.textContent=on?'Auto-refresh 60 s':'Auto-refresh off';clearTimeout(tm);if(on)tm=setTimeout(function(){S.setItem('kc-y',scrollY);location.reload()},6e4)}ar.onclick=function(){on=!on;L.setItem('kc-ar',on?'1':'0');sa()};sa();var y=S.getItem('kc-y');if(y){scrollTo(0,+y);S.removeItem('kc-y')}" +
    "var cl=JSON.parse(L.getItem('kc-closed')||'[]');d.querySelectorAll('details.sec').forEach(function(s){if(cl.indexOf(s.id)>=0)s.open=false;s.addEventListener('toggle',function(){var c=JSON.parse(L.getItem('kc-closed')||'[]').filter(function(x){return x!=s.id});if(!s.open)c.push(s.id);L.setItem('kc-closed',JSON.stringify(c))})});" +
    "var q=d.getElementById('q');function fl(){var v=q.value.toLowerCase();S.setItem('kc-q',q.value);d.querySelectorAll('.f').forEach(function(x){x.hidden=!!v&&x.textContent.toLowerCase().indexOf(v)<0});d.querySelectorAll('tbody.grp').forEach(function(g){g.hidden=!g.querySelector('tr.f:not([hidden])')})}q.oninput=fl;q.value=S.getItem('kc-q')||'';if(q.value)fl();d.addEventListener('keydown',function(x){if(x.key=='/'&&d.activeElement!=q){x.preventDefault();q.focus()}})})()"
  $head = "<header class=top><div class=brand>$mark<span>claude-crew</span><small>Supervisor</small></div><div class=meta><span>Last sweep <b>$($at.ToString('yyyy-MM-dd HH:mm'))</b></span><span id=age class=chip data-at='$($at.ToString('o'))' data-next='$(& $e $nextMin)'></span><span>$(& $e $j.next)</span></div><div class=sp></div>" +
    "<input id=q type=search placeholder='Filter flags and agents  ( / )' aria-label='Filter flags and agents'><button id=ar type=button aria-pressed=true>Auto-refresh 60 s</button><button id=tt type=button aria-label='Toggle theme' title='Toggle theme'><svg viewBox='0 0 24 24' width=16 height=16 aria-hidden=true><path d='M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z' fill=currentColor /></svg></button></header>"
  $main = "<main class=wrap>$kpi<div class=cols><div>$(& $section 'flags' 'Flags' ($nAct + $nWatch) $flagHtml)</div><div>$(& $section 'health' 'Machine' $null $gauges)$(& $section 'history' "Last $($hist.Count) sweeps" $null $histHtml)</div></div>" +
    (& $section 'agents' 'Agents' $agents.Count $agentHtml) + (& $section 'timeline' 'Today' $lanes.Count $ganttHtml) + (& $section 'stats' 'Statistics' $null $statsHtml) +
    "<div class=cols2>$(& $section 'resources' 'Resources and leases' @($j.resources | Where-Object { $_ }).Count $resHtml)$(& $section 'shells' 'Shells' @($j.shells | Where-Object { $_ }).Count $shellHtml)</div>" +
    (& $section 'settings' 'Settings' $setRows.Count $setHtml -Closed) + (& $section 'sweep' 'Sweep log' @($j.sweep).Count "<pre>$(& $e (@($j.sweep) -join "`n"))</pre>" -Closed) +
    "<footer>Written by bossy.ps1 supervise each sweep (no model tokens) · data: supervise-report.json</footer></main>"
  "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><noscript><meta http-equiv=refresh content=60></noscript><title>Supervisor $($at.ToString('HH:mm'))$(if ($nAct) { " · $nAct ACT" })</title>$fav<style>$css</style><script>try{var t=localStorage.getItem('kc-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script></head><body>$head$main<script>$js</script></body></html>"
}
# the page's stylesheet: muted palette around sage #8FBF7F, light / dark (prefers-color-scheme, data-theme overrides)
function Get-KitSupervisePageCss {
  $dark = '--bg:#1a1d1a;--sf:#222622;--sf2:#2b302b;--fg:#dddbd2;--mt:#8f9489;--ln:#333832;--sage2:#a9cf9b;--act:#c08a80;--watch:#bfa874;--slate:#8d989f;--plum:#a891ad;--sh:none'
  ':root{--bg:#f3f2ed;--sf:#fbfaf6;--sf2:#eeece5;--fg:#2e332e;--mt:#73786f;--ln:#e0ded5;--sage:#8fbf7f;--sage2:#5f8a53;--act:#b9786d;--watch:#b49a5e;--slate:#87929a;--plum:#9a7f9f;--sh:0 1px 2px rgba(46,51,46,.05),0 1px 1px rgba(46,51,46,.03)}' +
  "[data-theme=dark]{$dark}@media(prefers-color-scheme:dark){:root:not([data-theme=light]){$dark}}" +
  '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:13.5px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}' +
  'b{font-weight:600}.m,.sm{color:var(--mt)}.sm{font-size:11.5px;margin-top:2px}h3{font-size:12px;font-weight:600;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;margin:20px 0 8px}' +
  'header.top{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;padding:10px 24px;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--ln)}' +
  '.brand{display:flex;align-items:center;gap:10px;font-weight:650;font-size:15px;letter-spacing:-.01em}.brand svg{width:28px;height:28px;flex:none}.brand small{color:var(--mt);font-weight:500;font-size:13px;padding-left:10px;border-left:1px solid var(--ln)}' +
  '.meta{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;color:var(--mt);font-size:12.5px}.meta b{color:var(--fg)}.sp{flex:1}' +
  'input[type=search]{font:inherit;font-size:12.5px;color:var(--fg);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;width:260px;max-width:100%;outline:none}input[type=search]:focus{border-color:var(--sage)}' +
  'button{font:inherit;font-size:12px;color:var(--mt);background:var(--sf);border:1px solid var(--ln);border-radius:8px;padding:6px 10px;cursor:pointer;display:inline-flex;align-items:center}button:hover{color:var(--fg)}button[aria-pressed=true]{color:var(--sage2)}' +
  '.chip{display:inline-flex;align-items:center;gap:5px;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;letter-spacing:.03em;background:var(--sf2);color:var(--mt);white-space:nowrap}.chip::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;opacity:.85}' +
  '.chip.ok,.s-act{color:var(--sage2);background:color-mix(in srgb,var(--sage) 17%,transparent)}.chip.warn,.s-oth,.lv.WATCH{color:var(--watch);background:color-mix(in srgb,var(--watch) 16%,transparent)}.chip.bad,.s-stuck,.lv.ACT{color:var(--act);background:color-mix(in srgb,var(--act) 15%,transparent)}.s-fin{color:var(--slate);background:color-mix(in srgb,var(--slate) 14%,transparent)}' +
  '.wrap{max-width:1680px;margin:0 auto;padding:20px 24px 40px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}' +
  '.tile,details.sec{background:var(--sf);border:1px solid var(--ln);border-radius:12px;box-shadow:var(--sh)}.tile{padding:14px 16px 10px;min-width:0}.tile .k,.st .k{font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.07em;font-weight:600}' +
  '.tile .v{font-size:24px;font-weight:620;letter-spacing:-.02em;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tile .s{font-size:12px;color:var(--mt);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tile.hot{border-color:color-mix(in srgb,var(--act) 45%,var(--ln))}.tile.hot .v{color:var(--act)}' +
  '.spark{display:block;width:100%;height:28px;margin-top:8px}.spark .l{fill:none;stroke:currentColor;stroke-width:1.6;vector-effect:non-scaling-stroke;stroke-linejoin:round}.spark .a{fill:currentColor;opacity:.12}' +
  '.sage{color:var(--sage)}.act{color:var(--act)}.watch{color:var(--watch)}.slate{color:var(--slate)}' +
  '.cols{display:grid;grid-template-columns:minmax(0,1.7fr) minmax(0,1fr);gap:0 16px}.cols2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 16px}@media(max-width:1100px){.cols,.cols2{grid-template-columns:minmax(0,1fr)}}' +
  'details.sec{margin-top:16px}summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:8px;padding:12px 16px;user-select:none}summary::-webkit-details-marker{display:none}' +
  'summary h2{margin:0;font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:.07em}summary::after{content:"";margin-left:auto;width:7px;height:7px;border-right:1.5px solid var(--mt);border-bottom:1.5px solid var(--mt);transform:rotate(45deg);transition:transform .15s}details:not([open])>summary::after{transform:rotate(-45deg)}' +
  '.cnt{font-size:11px;color:var(--mt);background:var(--sf2);border-radius:999px;padding:0 7px}.bd{padding:0 16px 16px}' +
  '.flag{border:1px solid var(--ln);border-left:3px solid var(--watch);border-radius:8px;padding:10px 12px;margin-bottom:8px}.flag.ACT{border-left-color:var(--act);background:color-mix(in srgb,var(--act) 5%,var(--sf))}' +
  '.flag .h{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--mt)}.flag .w{margin:6px 0 4px;word-break:break-word}.flag .n{font-size:12.5px;color:var(--mt);word-break:break-word}.flag .n b{color:var(--sage2);margin-right:4px}.dot{opacity:.5}' +
  '.info{list-style:none;margin:12px 0 0;padding:0;font-size:12.5px;color:var(--mt)}.info li{padding:4px 0 4px 14px;position:relative;word-break:break-word}.info li::before{content:"";position:absolute;left:2px;top:11px;width:5px;height:5px;border-radius:50%;background:var(--sage)}' +
  '.empty{margin:0;padding:18px;text-align:center;color:var(--mt);border:1px dashed var(--ln);border-radius:8px;font-size:12.5px}' +
  '.gauges{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}.gauge{margin:0;text-align:center}.gauge svg{width:100%;max-width:140px}.gauge circle{fill:none;stroke-width:9;stroke-linecap:round}.gauge .trk{stroke:var(--sf2)}.gauge .val{stroke:currentColor}' +
  '.gauge circle.s-act{stroke:var(--sage)}.gauge circle.s-fin{stroke:var(--slate)}.gauge circle.s-stuck{stroke:var(--act)}.gauge circle.s-oth{stroke:var(--watch)}.gauge circle[stroke-dashoffset]{stroke-linecap:butt}' +
  '.gv{font-size:17px;font-weight:650;fill:var(--fg);text-anchor:middle;dominant-baseline:middle}.gl{font-size:8.5px;fill:var(--mt);text-anchor:middle;text-transform:uppercase;letter-spacing:.08em}figcaption{font-size:11.5px;color:var(--mt)}' +
  '.lg{font-style:normal;font-size:11px;white-space:nowrap;background:none}.lg::before{content:"";display:inline-block;width:8px;height:8px;border-radius:2px;background:currentColor;margin-right:4px;vertical-align:0}' +
  '.hist svg{display:block;width:100%;height:84px}.hist .a{fill:var(--act)}.hist .w{fill:var(--watch)}.hist .x{fill:var(--sage)}.hist .hit{fill:transparent}.hist .hit:hover{fill:color-mix(in srgb,var(--fg) 6%,transparent)}.ax{display:flex;justify-content:space-between;gap:8px;font-size:11px;color:var(--mt);margin-top:6px}' +
  '.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:12.5px}th{text-align:left;font-weight:600;font-size:11px;color:var(--mt);text-transform:uppercase;letter-spacing:.06em;padding:6px 8px;border-bottom:1px solid var(--ln);white-space:nowrap}' +
  'td{padding:7px 8px;border-bottom:1px solid var(--ln);vertical-align:top;overflow-wrap:break-word}tr:last-child td{border-bottom:0}tr.f:hover td{background:color-mix(in srgb,var(--sf2) 55%,transparent)}' +
  'tr.gh th{background:var(--sf2);color:var(--fg);text-transform:none;letter-spacing:0;white-space:normal;font-size:12.5px;padding:7px 8px;border-radius:0}.gn0{font-weight:650}td.num{white-space:nowrap}' +
  '.bar{display:inline-block;width:88px;height:6px;border-radius:3px;background:var(--sf2);overflow:hidden;vertical-align:middle;margin:0 6px 0 12px}.bar i{display:block;height:100%;border-radius:3px;background:var(--sage)}.bar i.watch{background:var(--watch)}.bar i.slate{background:var(--slate)}.bar i.act{background:var(--act)}.bl{font-size:11.5px;color:var(--mt);font-weight:500}' +
  'td .bar{margin-left:0}.gantt{font-size:12px}.gr{display:grid;grid-template-columns:170px minmax(0,1fr);gap:10px;align-items:center;height:20px}.gl0{color:var(--mt);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
  '.gt{position:relative;height:8px;background:var(--sf2);border-radius:4px}.gb{position:absolute;top:0;bottom:0;border-radius:4px;min-width:3px}.gb.s-act{background:var(--sage)}.gb.s-fin{background:var(--slate)}.gb.s-stuck{background:var(--act)}.gb.s-oth{background:var(--watch)}' +
  '.gx{position:relative;height:18px;margin:4px 0 0 180px;font-size:10.5px;color:var(--mt)}.gx span{position:absolute;transform:translateX(-50%);white-space:nowrap}' +
  '.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px}.st{border:1px solid var(--ln);border-radius:10px;padding:12px 14px}.st .v{font-size:21px;font-weight:620;letter-spacing:-.01em;margin-top:2px}.st .v small{font-size:12px;color:var(--mt);font-weight:500}' +
  '.st .w{font-size:12px;color:var(--mt)}.tr{font-size:11.5px;font-weight:600;margin-left:8px;letter-spacing:0}.tr.good{color:var(--sage2)}.tr.bad{color:var(--act)}.tr.eq{color:var(--mt)}' +
  '.toks{display:grid;gap:6px}.toks .f{display:grid;grid-template-columns:minmax(0,240px) auto;align-items:center}.tn{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
  'pre{margin:0;white-space:pre-wrap;word-break:break-word;color:var(--mt);font:12px/1.55 ui-monospace,SFMono-Regular,Consolas,monospace}footer{margin-top:24px;text-align:center;font-size:11.5px;color:var(--mt)}[hidden]{display:none!important}' +
  '.tw>table:not(.ag){min-width:520px}@media(max-width:640px){.wrap{padding:12px}.stats{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.st{padding:10px}header.top{padding:8px 12px}.hs{display:none}input[type=search]{width:100%}.gr{grid-template-columns:96px minmax(0,1fr)}.gx{margin-left:106px}.tile .v{font-size:20px}.gauges{grid-template-columns:repeat(3,minmax(0,1fr))}.toks .f{grid-template-columns:minmax(0,1fr)}.toks .bar{margin-left:0}}'
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

# ---- release: every lease of an agent (bossy.ps1 release, board leave, the workflows after each agent stage); idempotent
function Invoke-KitReleaseAgent([string[]]$Agent, [string]$Reason = 'agent finished') {
  $Agent = @(Split-KitList $Agent); if (-not $Agent.Count) { [Console]::Error.WriteLine('usage: bossy.ps1 release -Agent <id>[,<id>] [-Reason <why>]'); exit 2 }
  Invoke-KitLeaseReason $Reason {
    $sub = { param($script, [string[]]$a) $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $script) + $a) 180; if ($r.code) { $script:KitReleaseFailed = $true; 'FAILED ' }; @("$($r.out) $($r.err)" -split "`r?`n" | Where-Object { $_.Trim() })[-1] }
    $envs = @(if (@(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue | Select-String -SimpleMatch -List @($Agent | ForEach-Object { "`"$_`"" })).Count) { Get-KitLocalEnvStatus }); $ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
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
      foreach ($bf in @(Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json')) {
        $t = try { Get-Content $bf.FullName -Raw | ConvertFrom-Json } catch { continue }; $bp = if ($t.owner -eq $a -and (Test-KitPid $t.pid $t.start)) { Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue }   # a reused pid is not ours
        if ($bp) { $t | Add-Member -Force reclaimed $Reason; $t | ConvertTo-Json | Set-Content $bf.FullName; try { $bp.Kill($true) } catch {}; "$a build: stopped $($t.kind) (pid $($t.pid))"; $n++ }
      }
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
# envy.ps1 status -Json (goody local-env): the env state as the env reports it, never its files
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
# cleanup: a deploymerge-* worktree (goody deploys) no board entry claims, idle past idle.graceMinutes (60 min at least: a merge
# waiting for its pipeline writes nothing): it blocks the next deploy merge
function Test-KitIdleDeployMerge([string]$Name, [string]$Dir, [string[]]$Claimed, $Newest, [datetime]$Now) {
  $Name -like 'deploymerge-*' -and $Dir.ToLower() -notin $Claimed -and $Newest -and ($Now - $Newest).TotalMinutes -ge [math]::Max(60, [double](Get-KitParam 'idle.graceMinutes'))
}
# cleanup: test browsers with no live tab holder, idle or surplus browser profiles, idle Gradle / Kotlin daemons
function Invoke-KitCleanupResources {
  $profiles = Get-KitPath chrome-profiles
  $chromes = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|headless_shell|google chrome|microsoft edge|firefox|MiniBrowser|WebKitWebProcess)(\.exe)?$' | Where-Object { $_.CommandLine -match '--?headless|-juggler' -and $_.CommandLine -match [regex]::Escape($profiles) }
  $qaRuns = @(Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  $qaActive = @(Read-KitJsonFiles (Get-KitPath board) |
    Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt [double](Get-KitParam 'idle.beatMinutes') -and ($_.run -in $qaRuns -or "$($_.worktrees)" -match 'chrome:') }).Count
  # a test browser goes once no live tab holder is left for idle.graceMinutes (browser.mjs registry), never by its age
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
