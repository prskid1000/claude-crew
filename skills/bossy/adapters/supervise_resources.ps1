<#
supervise_resources.ps1 (core): the machine's shared resources in bossy.ps1, dot-sourced by bossy.ps1
(skills/bossy/adapters/): build gate holders and queue, repeated build failures, the file cache flush (gate.cacheFlush),
phone leases, env leases, QA seats and claims, test browsers and their profiles, idle Gradle / Kotlin daemons, the RAM rows of
the supervise report, agents' background shells (Shells table, ORPHAN / STUCK, -AutoFix kills), seats and leases in board show and recover, the status resource rows, release (every lease of an agent).
Its hooks run inside the bossy.ps1 verb that calls them and use that verb's variables: supervise ($now, $mem, $keepFree, Within,
Left), cleanup ($now, $tmp, $DryRun, $actions, Gone, Old).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L13 builds · L42 supervise · L168 shells · L273 release · L302 lines · L327 cleanup
#>
#Requires -Version 7
# ---- builds: repeated failures, cache flush
# gate history keys whose last 3 builds failed; old failures (a path since fixed) are no news: the last one must be < 24 h old
function Get-KitBuildFailures($Hist, [datetime]$Now) {
  if (-not $Hist) { return }   # no gate history yet
  foreach ($k in @($Hist.Keys)) {
    $last = @($Hist[$k] | Select-Object -Last 3)
    if ($last.Count -eq 3 -and -not ($last | Where-Object { $_.ok }) -and $last[-1].at -and ($Now - [datetime]$last[-1].at).TotalHours -lt 24) { $k }
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
  foreach ($k in Get-KitBuildFailures $hist $now) { & $flag 'WATCH' "builds '$k' failed 3 times in a row" 'Look at that agent: repeated failing builds burn memory turns; a setup-data cause (fixture, seed drift) -> spawn datay kind fixture, else it may need help or a brief fix.' }
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
  if ($AutoFix -and (Within 'env leases')) { $null = Get-KitLocalEnvStatus }

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
  foreach ($r in $rows) { if ($graceRows.ContainsKey($r.name)) { $r.by = "$($r.by) (grace $($graceRows[$r.name]) min)" }; $r }
  foreach ($x in @(Read-KitLog leases $now | Where-Object { $_.event -eq 'reclaim' -and $_.kind -in 'env', 'tab' })) { & $flag 'INFO' "auto-fixed: reclaimed $($x.kind) $($x.name) of $($x.agent) ($($x.reason))" 'Nothing to do.' }   # the env and tab sweeps above log, not print
  $need = [double](@(@($queue | ForEach-Object { [double]$_.need }) + 0) | Measure-Object -Maximum).Maximum
  if ($need) { [pscustomobject]@{ ramNeed = $need } }   # bossy.ps1 names the biggest rows of every goody
}

# status rows (lib.ps1 status): agents queued at the build gate or waiting for a phone lane
function Get-KitStatusWaitResources {
  foreach ($t in @(Get-ChildItem (Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.owner -and (Test-KitPid $_.pid $_.start) })) {
    [pscustomobject]@{ agent = $t.owner; why = "build gate: RAM for $($t.kind)"; at = $t.since; next = 'the gate starts it when RAM frees' }
  }
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
# its first line without a leading cd, for the table
function Get-KitShellShort([string]$Cmd) {
  $s = ((@("$Cmd" -split "`r?`n" | Where-Object { $_.Trim() })[0]) -replace '^\s*(cd|Set-Location|pushd)\s+("[^"]*"|''[^'']*''|\S+)\s*(&&|;)\s*', '' -replace '\s+', ' ').Trim()
  if ($s) { $s } else { "$Cmd".Trim() }
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
# that ended on their own). -AutoFix kills only a finished owner's shell whose dir is gone or that was STUCK 2+ sweeps
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
    if ($o.finished -and ($gone -or $s.stuck -ge 2) -and $AutoFix -and (Test-KitPid $p.Id $made)) {
      if ($KitIsWindows) { taskkill /PID $p.Id /T /F 2>&1 | Out-Null } else { foreach ($t in @($tree.Keys)) { Stop-SysProcess $t } }
      $s.killed = $true; Write-KitLog calls shell-kill ([ordered]@{ pid = $p.Id; owner = $o.name; why = $why; dir = $dir; what = "killed shell $($p.Id) ($why): $($one.Substring(0, [math]::Min(300, $one.Length)))" })
      $flags.Add([pscustomobject]@{ level = 'INFO'; what = "auto-fixed: killed shell $($p.Id) of $($o.name) ($why): $short"; action = 'Nothing to do.' }); continue
    }
    $shellState = @($(if ($o.finished -or $gone) { 'ORPHAN' }), $(if ($stuck) { 'STUCK' }) | Where-Object { $_ }) -join ', '; if (-not $shellState) { $shellState = 'running' }
    $tk = "taskkill /PID $($p.Id) /T /F"
    $next = if ($shellState -eq 'running') { '' } elseif ($o.coordinator) { "yours: stop it (KillShell) or $tk" } elseif ($o.finished) { "supervise -AutoFix kills it once its dir is gone or STUCK 2 sweeps; now: $tk" } else { "$($o.name) ends it, else $tk" }
    $rows.Add([pscustomobject]@{ pid = $p.Id; short = $short; cmd = $cmd; owner = $o.name; age = [math]::Round($age); state = $shellState; next = $next; dir = $dir })
    $s60 = $short.Substring(0, [math]::Min(60, $short.Length))
    if ($shellState -ne 'running') { $flags.Add([pscustomobject]@{ level = 'WATCH'; kind = "SHELL $shellState"; who = $o.name; age = "$([int]$age) min"; problem = "pid $($p.Id) $s60`: $why"; what = "SHELL $shellState pid $($p.Id) of $($o.name) ($s60): $why"; action = $next }) }
  }
  foreach ($k in @($old.Keys)) { $g = $old[$k]; if (-not $new.ContainsKey($k) -and $g -is [Collections.IDictionary] -and $g.listed -and -not $g.killed) { Add-KitParamObs 'supervise.shellStuckMinutes' ([double]$g.age) -Default 30 } }   # it ended on its own
  $State.shells = $new
  [pscustomobject]@{ rows = @($rows); flags = @($flags); line = "shells: $all agent shell(s), $($rows.Count) listed" }
}
# supervise hook (section 3; the verb's $state, $now, Within): the sweep line and flags; the rows go to $script:KitShells (report)
function Get-KitSuperviseGuardShells([switch]$AutoFix) {
  $script:KitShells = @(); if (-not (Within 'shells')) { return }
  try { $sh = Get-KitShellSweep $state $now -AutoFix:$AutoFix; $script:KitShells = $sh.rows; $sh.line; $sh.flags }
  catch { [pscustomobject]@{ level = 'WATCH'; what = "shell sweep failed: $($_.Exception.Message)"; action = 'Fix adapters/supervise_resources.ps1 Get-KitShellSweep.' } }
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
  if (-not $gradleBusy) {
    foreach ($d in Get-SysProcs -Name '^java(\.exe)?$' | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' }) {
      if (($now - $d.Created).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($d.CommandLine -match 'Kotlin') { 'Kotlin daemon' } else { 'Gradle daemon' }), $d.Id, ($d.WorkingSet / 1GB))); $script:freed += [long]$d.WorkingSet; if (-not $DryRun) { Stop-SysProcess $d.Id } }
    }
  }
}
