<#
# Usage: dot-sourced by bossy.ps1 from adapters/. Exit codes: none here (its verbs exit through bossy.ps1).
localenv_supervise.ps1: the local env in bossy.ps1 supervise, dot-sourced by bossy.ps1 (skills/bossy/adapters/):
env rows, owner holds, STALE LAYER drops, RESTART LOOP, TRAIN STALLED, UNKNOWN port owners, ERROR SPIKE, status waits, CPU per service.
Its hook runs inside supervise (uses $now, $state, Within, Left); Invoke-KitPauseLocalEnv in bossy.ps1 pause.
Exit codes: none (functions only).
Sections: L10 logs · L47 rows · L77 pause · L89 spike · L121 flags · L246 waits · L257 cpu
#>
#Requires -Version 7
# ---- logs: new error lines per log, their classes
# new error lines per log since its last size (ERROR SPIKE); level words case-sensitive: "WARN ... Error while" is no error.
# Classes: expected (4xx of negative tests: bad.request, not found, validation) apart; else startup > connection > 5xx > error;
# dep = the host:port a connection line names (a startup failure caused by a dependency that was down)
# generic defaults; localEnv.logClasses { expected, startup, connection, 5xx } replaces a class (a framework's own words)
$script:KitLogClasses = [ordered]@{
  expected   = '(?i)\bbad[ .]request\b|\bnot[ .]found\b|\bvalidation\b|\b(status|HTTP/\S+)\W+4\d\d\b'
  startup    = '(?i)failed to start|\b(start(up)?|boot|run) failed\b|could not start'
  connection = '(?i)connection refused|ECONNREFUSED|ConnectException|UnknownHostException|could not connect|connection (timed out|reset)'
  '5xx'      = '(?i)\b(status|HTTP/\S+)\W+5\d\d\b'
}
foreach ($__k in @($script:KitLogClasses.Keys)) { $__v = Get-KitSetting "localEnv.logClasses.$__k" $null; if ($__v) { $script:KitLogClasses[$__k] = [string]$__v } }
function Get-KitLogErrors([string[]]$Files, $Sizes) {
  if (-not $Sizes) { $Sizes = @{} }   # first round: no sizes yet
  foreach ($x in $Files) {
    $i = Get-Item $x -ErrorAction SilentlyContinue; if (-not $i) { continue }
    $from = [long](Get-KitMember $Sizes ($i.FullName)); if (-not $Sizes.Contains($i.FullName)) { $from = $i.Length } elseif ($from -gt $i.Length) { $from = 0 }   # rotated: from 0
    $from = [math]::Max($from, $i.Length - 1MB)
    $new = if ($i.Length -gt $from) { $s = [IO.File]::Open($i.FullName, 'Open', 'Read', 'ReadWrite, Delete'); try { [void]$s.Seek($from, 'Begin'); [IO.StreamReader]::new($s).ReadToEnd() } finally { $s.Dispose() } } else { '' }
    $hits = @($new -split "`r?`n" | Where-Object { $_ -cmatch '\b(ERROR|FATAL)\b|Exception\b|Traceback|^\s*\w*Error:|(?i:\b(status|HTTP/\S+)\W+5\d\d\b)' })
    $C = $script:KitLogClasses; $real = @($hits | Where-Object { $_ -notmatch $C.expected -or $_ -match "$($C.startup)|$($C.connection)|$($C['5xx'])" })
    [pscustomobject](@{ path = $i.FullName; size = $i.Length; expected = $hits.Count - $real.Count; lines = @($real | Select-Object -First 200) } + (Get-KitLogClass $real $hits))
  }
}
# error lines -> count, class, first line, dependency (host:port of a connection line)
function Get-KitLogClass([string[]]$Real, [string[]]$Hits = @()) {
  $C = $script:KitLogClasses; $cls = @('startup', 'connection', '5xx' | Where-Object { $k = $_; @($Real | Where-Object { $_ -match $C[$k] }).Count })[0]
  $top = if ($cls) { @($Real | Where-Object { $_ -match $C[$cls] })[0] } elseif ($Real.Count) { $Real[0] } else { @($Hits)[0] }
  $cl = @($Real | Where-Object { $_ -match $C.connection })[0]   # the address after the connection words, never a log timestamp
  $dep = if ("$cl" -match "(?:$($C.connection)).*?\b(?<h>localhost|\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z][\w-]*(?:\.[\w-]+)*):(?<p>\d{2,5})\b") { "$($Matches.h):$($Matches.p)" }
  @{ errors = @($Real).Count; cls = $(if ($cls) { $cls } else { 'error' }); first = "$top".Trim(); dep = $dep }
}
# an error line's signature: no timestamp, [thread], ids, numbers or quoted values (known-noise key: supervise -Ack on the spike)
function Get-KitErrorSignature([string]$Line) {
  $t = ($Line -replace '^\W*\d{4}-\d\d-\d\d[T ][\d:.,]+\S*\s*', '' -replace '\[[^\]]*\]', '' -replace '(?i)\b[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', '<id>' -replace '=\S+', '=<v>' -replace '(?i)\b0x[0-9a-f]+\b|\d+', '#' -replace '(["'']).*?\1', '<v>' -replace '\s+', ' ').Trim()
  $t.Substring(0, [math]::Min(100, $t.Length))
}
# ---- rows: env rows
# local-env rows (pure on status -Json): up services + holders; a down one only while a lease / hold needs it (no lease = idle);
# one service on one port in several envs (a shared external DB) is one row: its envs and holders merged, its RAM once
function Get-KitEnvRows($Envs, [datetime]$now) {
  $rows = [Collections.Generic.List[object]]::new(); $fl = [Collections.Generic.List[object]]::new(); $own = @(); $up = [ordered]@{}
  foreach ($ev in @($Envs | Where-Object { $_.env -and @($_.services).Count })) {
    $holders = @(@($ev.leases) + @($ev.holds) | Where-Object { $_ })
    $down = @($ev.services | Where-Object { $d0 = $_.service; $_.state -notmatch '^(up|waiting)' -and @($holders | Where-Object { $d0 -in @($_.services) }).Count })
    foreach ($sv in @($ev.services | Where-Object { $_.state -match '^up' })) {
      $hl = @($holders | Where-Object { $sv.service -in @($_.services) }); $gl = @($hl | Where-Object { $null -ne $_.graceLeft } | ForEach-Object graceLeft | Sort-Object)[0]
      $key = if ($sv.port) { "$($sv.service):$($sv.port)" } else { "$($ev.env)/$($sv.service)" }; if (-not $up.Contains($key)) { $up[$key] = @{ svc = $sv.service; envs = @(); who = @(); gl = @(); gb = 0; ext = $false; port = $sv.port } }
      $u = $up[$key]; $u.envs += $ev.env; $u.ext = $u.ext -or "$($sv.state)" -match 'external'; $u.who += @($hl | ForEach-Object { if ($_.agent) { $_.agent } else { $_.who } }); $u.gl += @($gl | Where-Object { $null -ne $_ }); $u.gb = [math]::Max([double]$u.gb, [double]$sv.gb)
      $why = @($sv.need); $h1 = @($ev.holds | Where-Object { $sv.service -in @($_.services) -and $_.at -and ($now - [datetime]$_.at).TotalMinutes -ge (Get-KitParam 'localEnv.holdWatchMinutes') })[0]
      if ($h1 -and $why.Count -and -not @($why | Where-Object { $_ -notmatch '^hold:' }).Count) { $fl.Add([pscustomobject]@{ level = 'WATCH'; what = "$($ev.env) $($sv.service) kept up only by $($h1.who)'s hold for $([int]($now - [datetime]$h1.at).TotalMinutes) min (no lease)"; action = "Done with it: & $($KitCmd.local) unhold -Env $($ev.env) -Agent $($h1.who)" }) }
    }
    foreach ($h in @($ev.holds | Where-Object owner)) { $own += "owner hold $($ev.env) [$(@($h.services) -join ',')] until $($h.until) (unhold -Env $($ev.env) -Agent $($h.who) when done)" }
    # K20n: a down service a live (not grace) holder needs flags in the sweep that reads it, not only as a row
    # a stop the env controller made on purpose (idle, memory pressure: why "idle...") restarts on demand: WATCH, ACT only once a holder
    # has used the lane for localEnv.plannedDownActMinutes with the service still down
    $pdMin = [double](Get-KitParam 'localEnv.plannedDownActMinutes')
    foreach ($d1 in @($down | Where-Object { $_.state -notmatch '^start' })) { $lho = @($holders | Where-Object { $null -eq $_.graceLeft -and $d1.service -in @($_.services) }); $lh = @($lho | ForEach-Object { if ($_.agent) { $_.agent } else { $_.who } } | Select-Object -Unique)
      $planned = "$($d1.why)" -match '^idle'; $stale = @($lho | Where-Object { $null -ne $_.ageMin -and [double]$_.ageMin -ge $pdMin -and $null -ne $_.usedMinAgo -and [double]$_.usedMinAgo -le $pdMin }).Count
      $lvl = if ($d1.state -eq 'blocked' -or ($planned -and -not $stale)) { 'WATCH' } else { 'ACT' }
      if ($lh.Count) { $fl.Add([pscustomobject]@{ level = $lvl; what = "SERVICE DOWN: $($ev.env) $($d1.service) is $($d1.state)$(if ($d1.why) { " ($($d1.why))" }) while $($lh -join ', ') hold$(if ($lh.Count -eq 1) { 's' }) it"; action = $(if ($lvl -eq 'WATCH' -and $planned) { "Nothing to do: it starts on its holder's next use (ACT if still down after $pdMin min of use)" } else { "kitty kind env: & $($KitCmd.local) logs -Env $($ev.env) -Service $($d1.service), then restart -Env $($ev.env) -Services $($d1.service)" }) }) } }
    if ($down.Count) { $rows.Add([pscustomobject]@{ kind = 'env'; name = "$($ev.env) · $(($down | ForEach-Object service) -join ' · ') (down)"; by = "$(@($down | ForEach-Object { if ("$($_.why)" -match 'memory|RAM') { 'memory' } elseif ($_.why) { "$($_.why)".Substring(0, [math]::Min(30, "$($_.why)".Length)) } else { $_.state } } | Select-Object -Unique) -join ', ')"; gb = 0 }) }
  }
  $ur = @(foreach ($u in $up.Values) { $g = @($u.gl | Sort-Object)[0]
    [pscustomobject]@{ kind = 'env'; name = $(if ($u.envs.Count -gt 1) { "$($u.svc) ($($u.envs -join ', '))" } else { "$($u.envs[0]) · $($u.svc)" }); by = "$((@($u.who) | Select-Object -Unique) -join ', ')$(if ($null -ne $g) { " (grace $g min)" })"; gb = $u.gb; shared = $u.ext -or $u.envs.Count -gt 1; port = $u.port } }); if ($ur.Count) { $rows.InsertRange(0, [object[]]$ur) }   # shared: an external or multi-env service, always on, never an orphan
  [pscustomobject]@{ rows = @($rows); flags = @($fl); owner = @($own) }
}
# ---- pause: bossy.ps1 pause: kit-started services no live lease or hold needs stop now (paused agents' leases are only in grace)
function Invoke-KitPauseLocalEnv {
  if (-not (Test-Path $KitCmd.local)) { return }
  $st = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') 60
  foreach ($ev in @(try { "$($st.out)" | ConvertFrom-Json } catch { @() })) {
    $live = @(@($ev.leases) + @($ev.holds) | Where-Object { $_ -and $null -eq $_.graceLeft } | ForEach-Object { @($_.services) })
    $idle = @($ev.services | Where-Object { $_.state -eq 'up' -and $_.service -notin $live } | ForEach-Object service)
    if (-not $idle.Count) { continue }
    $dn = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'down', '-Env', $ev.env, '-Services', ($idle -join ',')) 180
    "local env $($ev.env): $(if ($dn.code) { "stopping $($idle -join ', ') FAILED: $($dn.out)" } else { "stopped $($idle -join ', ') (no live holder)" })"
  }
}
# ---- spike: ERROR SPIKE flags
# one log's new errors -> nothing (expected 4xx while a lease tests), ACT (startup, connection, 5xx: the cause, env, service,
# release), WATCH (other errors); a startup failure whose dependency is up again: restarted once (-AutoFix)
# -Known: noise:<env>:<signature> keys a supervise -Ack on an earlier spike stored; those lines never count again (that env only)
function Get-KitSpikeFlag($L, $Envs, [switch]$AutoFix, [string[]]$Known = @()) {
  $base = [IO.Path]::GetFileNameWithoutExtension($L.path); $ev = @($Envs | Where-Object { $_.env -and $base.StartsWith("$($_.env)-") } | Sort-Object { - "$($_.env)".Length })[0]
  $svc = if ($ev) { $base.Substring("$($ev.env)".Length + 1) } else { $base }; $where = if ($ev) { "$($ev.env) $svc (release r$($ev.release))" } else { $L.path }
  $sigOf = { param($x) "noise:$(if ($ev) { $ev.env } else { $base }):$(Get-KitErrorSignature $x)" }
  # expected on a local env (K50: a scheduled job that calls an outside system the machine cannot reach): localEnv.expectedErrors and
  # localEnv.envs.<env>.expectedErrors (regexes; a lane uses its env's), dropped like acknowledged noise
  $be = if (-not $ev) { '' } elseif ($null -ne (Get-KitSetting "localEnv.envs.$($ev.env)" $null)) { "$($ev.env)" } else { "$($ev.env)" -replace '\d+$' }
  $exp = @(@(Get-KitSetting 'localEnv.expectedErrors' @()) + @(if ($be) { Get-KitSetting "localEnv.envs.$be.expectedErrors" @() }) | Where-Object { $_ })
  $keep = { param($x) (& $sigOf $x) -notin $Known -and -not @($exp | Where-Object { try { "$x" -match $_ } catch { $false } }).Count }
  if (($Known.Count -or $exp.Count) -and $L.lines) { $kl = @($L.lines | Where-Object { & $keep $_ }); $L = [pscustomobject](@{ path = $L.path; expected = $L.expected; lines = $kl } + (Get-KitLogClass $kl)) }
  $n = $L.errors + $(if (-not @($ev.leases).Count) { $L.expected })   # 4xx with nobody testing: someone else's calls
  if ($n -le 0) { return }
  $cells = @{ kind = 'ERROR SPIKE'; who = $(if ($ev) { "$($ev.env) $svc" } else { $base }); problem = "$n new error line$(if ($n -ne 1) { 's' }) in $(if ($ev) { "$($ev.env) $svc" } else { $base }) log"; next = "$($L.cls): $(("$($L.first)" -replace '\s+', ' ').Trim() | ForEach-Object { if ($_.Length -gt 60) { $_.Substring(0, 60) } else { $_ } })"
    refs = @($L.lines | ForEach-Object { & $sigOf $_ } | Select-Object -Unique) }   # table cells (supervise -Brief, ~90 chars); what / action stay whole for the report; refs: -Ack marks them known noise
  if ($L.cls -eq 'error') { return [pscustomobject](@{ level = 'WATCH'; what = "ERROR SPIKE: $n new error line(s) in $($L.path)"; action = "first: $($L.first)" } + $cells) }
  if ($L.cls -eq 'startup' -and $L.dep -and $ev) {
    $up = $false; $tc = [Net.Sockets.TcpClient]::new(); try { $h, $p = $L.dep -split ':'; $up = $tc.ConnectAsync($h, [int]$p).Wait(1000) -and $tc.Connected } catch {} finally { $tc.Dispose() }
    $rf = Join-Path (Get-KitPath cache -Create) 'localenv-retries.json'; $tried = try { Get-Content $rf -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $tried) { $tried = @{} }
    $key = $L.path; foreach ($k0 in @($tried.Keys)) { if (((Get-Date) - [datetime]$tried[$k0]).TotalMinutes -ge (Get-KitParam 'localEnv.retryEveryMinutes')) { $tried.Remove($k0) } }   # once per log per window
    if ($up -and $AutoFix -and -not $tried[$key]) {
      $tried[$key] = (Get-Date).ToString('o'); $tried | ConvertTo-Json | Set-Content $rf
      $r = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'restart', '-Env', $ev.env, '-Services', $svc, '-Agent', 'supervise') ([math]::Min(120.0, (Left)))
      return [pscustomobject]@{ level = $(if ($r.code) { 'ACT' } else { 'INFO' }); what = "$(if ($r.code) { 'ERROR SPIKE' } else { 'auto-fixed' }): $where failed to start while $($L.dep) was down; it is up now: restarted once$(if ($r.code) { " - FAILED: $("$($r.out)".Trim())" })"; action = "& $($KitCmd.local) logs -Env $($ev.env) -Service $svc" }
    }
    if (-not $up) { return [pscustomobject](@{ level = 'ACT'; what = "ERROR SPIKE: $where failed to start: $($L.dep) is down: $($L.first)"; action = "Bring $($L.dep) up; the next heartbeat restarts $svc once (-AutoFix)." } + @{ kind = $cells.kind; who = $cells.who; problem = "$svc failed to start: $($L.dep) is down"; next = "bring $($L.dep) up" }) }
  }
  [pscustomobject](@{ level = 'ACT'; what = "ERROR SPIKE: $where, $n new error line(s), $($L.cls): $($L.first)"; action = "& $($KitCmd.local) logs -Env $(if ($ev) { $ev.env } else { '<env>' }) -Service $svc; a branch layer in that release caused it -> its agent (board msg), else kitty kind env" } + $cells)
}
# ---- flags: supervise section 7 (status -Json only): env rows and flags, owner holds (info), restart loops, trains
# waiting on leases or stalled, RAM floor moves, mark expiry / baseline age / short binlog, seed drift, unknown port owners, new log errors
# (sizes cached per round)
# the env rows early, among the machine guards: a sweep that runs out of budget later (track, network) still lists what holds RAM
# a failed or timed-out status -Json read -> its reason (K20n: silent empty rows hid a down service), $null when read
function Get-KitEnvStatusErr($Le) {
  if (-not $Le.code -and -not $Le.timedOut) { return $null }
  if (-not @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue).Count) { return $null }   # no env set up: nothing to read
  if ($Le.timedOut) { 'timed out' } else { "exit $($Le.code): $(("$($Le.err)$($Le.out)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1))" }
}
# status -Json (4-6 s, 11 s loaded: a pwsh child that loads envy) runs again only when what it reads changed: the env state files
# minus their clocks and RAM readings, the live pids they name, kit.local.json or envy.ps1; else at most every 10 min (its minute counts, lease prune)
function Get-KitEnvStatusKey {
  $sb = [Text.StringBuilder]::new(); $ids = @{}; foreach ($p in @(Get-SysProcs)) { $ids[[int]$p.Id] = 1 }
  foreach ($f in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object Name -match '^[^.]+\.json$' | Sort-Object Name)) {
    $t = try { [IO.File]::ReadAllText($f.FullName) } catch { "unread $($f.Length) $($f.LastWriteTimeUtc.Ticks)" }
    [void]$sb.Append($f.Name).Append('|').Append(($t -replace '"(seen|lastUse|lastNeed|beat|gb|peakGB)":\s*("[^"]*"|[-\d.eE+]+|null)', ''))
    foreach ($m in [regex]::Matches($t, '"(?:pid|waitPid)":\s*(\d+)')) { [void]$sb.Append("|$($m.Groups[1].Value)=$([int]$ids.ContainsKey([int]$m.Groups[1].Value))") }
  }
  foreach ($x in @($KitConf.ConfigFile, $KitCmd.local)) { if ($x -and (Test-Path -LiteralPath $x)) { [void]$sb.Append("|$x=$((Get-Item -LiteralPath $x).LastWriteTimeUtc.Ticks)") } }
  Get-KitHash $sb.ToString()
}
# sweep start (bossy.ps1 Start-KitSupervisePrefetch hooks): the cached answer, or the child started now and read by the guard hook
function Start-KitSupervisePrefetchLocalEnv {
  $script:KitEnvStatusRun = $null; if (-not (Test-Path $KitCmd.local)) { return }
  $key = Get-KitEnvStatusKey; $c = try { Read-KitText (Join-Path (Get-KitPath cache -Create) 'localenv-status.json') | ConvertFrom-Json } catch { $null }
  if ($c.key -eq $key -and "$($c.out)".Trim() -and ((Get-Date) - [datetime]$c.at).TotalMinutes -lt (Get-KitParam 'localEnv.statusCacheMinutes')) { $script:KitEnvStatusRun = @{ key = $key; out = "$($c.out)" }; return }
  $script:KitEnvStatusRun = @{ key = $key; h = $(try { Start-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') } catch { $null }) }
}
# -> Invoke-KitExe's shape; no prefetch (tests, a guard hook run alone): inline, uncached
function Read-KitEnvStatus {
  $r = $script:KitEnvStatusRun; $script:KitEnvStatusRun = $null
  if ($r.out) { return [pscustomobject]@{ code = 0; out = $r.out; err = ''; timedOut = $false } }
  if (-not $r.h) { return Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') ([math]::Min(30.0, (Left))) }
  $le = Receive-KitExe $r.h ([math]::Min(30.0, (Left)))
  if (-not $le.code -and -not $le.timedOut -and "$($le.out)".Trim()) { Write-KitAtomic (Join-Path (Get-KitPath cache -Create) 'localenv-status.json') (@{ key = $r.key; at = (Get-Date).ToString('o'); out = $le.out } | ConvertTo-Json -Compress) }
  $le
}
function Get-KitSuperviseGuardLocalEnv([switch]$AutoFix) {
  if (-not (Test-Path $KitCmd.local)) { return }
  $le = Read-KitEnvStatus
  $script:KitEnvStatus = @(try { "$($le.out)" | ConvertFrom-Json } catch { @() }); $script:KitEnvStatusErr = Get-KitEnvStatusErr $le; (Get-KitEnvRows $script:KitEnvStatus $now).rows
}
# a configured dep source that is not on disk: every wt new of its target and every lane on it fails (2026-11-19: 3x before anyone built it)
function Get-KitDepSourceFlags {
  foreach ($rc in @(Get-KitValue 'repos' @())) {
    $lb = $rc.linkFromByTarget; $srcs = @(@(if ($lb) { foreach ($t in @((Get-KitProps $lb).Name)) { (Get-KitMember $lb $t) } }) + @($rc.linkFrom) | Where-Object { $_ } | ForEach-Object { "$_" } | Sort-Object -Unique)
    foreach ($src in @($srcs | Where-Object { -not (Test-Path -LiteralPath $_) })) { [pscustomobject]@{ level = 'WATCH'; what = "DEP SOURCE MISSING: $($rc.name) $src (kit.local.json repos[].linkFrom / linkFromByTarget): wt new of that target fails"; action = 'create it (git worktree add --detach <path> origin/<target> + frozen-lockfile install) or fix kit.local.json; envy.ps1 doctor names the lanes it blocks' } }
  }
}
function Get-KitSuperviseFlagsLocalEnv([switch]$AutoFix) {
  if (-not (Test-Path $KitCmd.local)) { return }
  $watch = { param($what, $action) [pscustomobject]@{ level = 'WATCH'; what = $what; action = $action } }
  Get-KitDepSourceFlags
  # layers merged into the target, gone from origin or with no live holder past the grace: -AutoFix drops them, else WATCH
  # its git fetches took 33 s a round: in the background (lib.ps1 Invoke-KitBackground), this round shows the last finished run
  if (@(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue).Count -and (Within 'stale layers')) {
    $da = @('drop', '-Stale') + @(if (-not $AutoFix) { '-DryRun' })
    foreach ($ln in @(Invoke-KitBackground "envy.ps1 $($da -join ' ')" $KitCmd.local $da | Where-Object { $_ -match '^\[[^\]]+\] (drop|stale) ' })) {
      if ($AutoFix) { [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: $ln"; action = 'Nothing to do.' } } else { & $watch "STALE LAYER: $ln" 'supervise -AutoFix drops it (envy.ps1 drop -Stale).' }
    }
  }
  # old lane names (localenv-<lane>-<repo> worktrees): moved each sweep once their lane is idle (envy.ps1 lanes -Migrate -LanesOnly, background)
  $wr0 = @($KitConf.WorktreeRoots)[0]
  if ($wr0 -and @(Get-ChildItem -LiteralPath $wr0 -Directory -Filter 'localenv-*' -ErrorAction SilentlyContinue).Count -and (Within 'lane names')) {
    foreach ($ln in @(Invoke-KitBackground 'envy.ps1 lanes -Migrate -LanesOnly' $KitCmd.local @('lanes', '-Migrate', '-LanesOnly') | Where-Object { "$_" -match '^(moved|renamed|deleted|kept) ' })) {
      if ("$ln" -like 'kept *') { [pscustomobject]@{ info = "LANE NAMES: $ln" } } else { [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: $ln"; action = 'Nothing to do.' } } }
  }
  $early = $null -ne $script:KitEnvStatus   # the guard hook read status this round: its rows are out
  $envs = if ($early) { $script:KitEnvStatus } else { $le = Read-KitEnvStatus; @(try { "$($le.out)" | ConvertFrom-Json } catch { @() }) }
  $se = if ($early) { $script:KitEnvStatusErr } else { Get-KitEnvStatusErr $le }; $script:KitEnvStatus = $null; $script:KitEnvStatusErr = $null; $er = Get-KitEnvRows $envs $now
  if ($se) { [pscustomobject]@{ level = 'WATCH'; what = "LOCAL ENV STATUS unread this sweep: $se (down services cannot flag)"; action = "& $($KitCmd.local) status; slow or failing: kitty kind env" } }
  if (-not $early) { $er.rows }; $er.flags; foreach ($o in $er.owner) { [pscustomobject]@{ info = $o } }
  $cf = Join-Path (Get-KitPath cache -Create) 'localenv-supervise.json'; $last = try { Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $last) { $last = @{} }; $seenEnv = @{}
  $waitMin = [double](Get-KitParam 'localEnv.trainWaitFlagMinutes'); $stuckMin = [double](Get-KitParam 'supervise.stuckMinutes')
  foreach ($ev in $envs) {   # all from status -Json: never the env's state files
    foreach ($s in @($ev.services | Where-Object { $null -ne $_.waitMin -and [int]$_.waitMin -ge $stuckMin })) {   # a start waiting for room past the stuck time
      & $watch "START WAITS: $($ev.env) $($s.service) $($s.state) for $($s.waitMin) min; leases: $((@($ev.leases | ForEach-Object { $_.agent }) | Where-Object { $_ }) -join ', ')" "free RAM: & $($KitCmd.orch) cleanup (idle services, browsers), stop idle lanes; & $($KitCmd.local) status -Env $($ev.env)" }
    foreach ($s in @($ev.services | Where-Object { [int]$_.restarts30 -gt 2 })) { & $watch "RESTART LOOP: $($ev.env) $($s.service) restarted $($s.restarts30) times in 30 min" "evidence envy.ps1 logs -Env $($ev.env) -Service $($s.service)" }
    if ($ev.train -and @($ev.train.waitingFor).Count -and $ev.train.waitSince -and ($now - [datetime]$ev.train.waitSince).TotalMinutes -ge $waitMin) {
      & $watch "TRAIN WAITS: $($ev.env) train $($ev.train.id) waits $([int]($now - [datetime]$ev.train.waitSince).TotalMinutes) min for the lease(s) of $(@($ev.train.waitingFor) -join ', ')" 'holders: release when done (it deploys at leaseMinutes and tells them)'
    }
    $td = $ev.trainDead; if ($td) { $seenEnv["$($ev.env)/trainDead"] = $td.id }   # envy Prune ended it (worker gone or quiet past trainStallMinutes): once per train
    if ($td -and $td.id -ne $last["$($ev.env)/trainDead"]) {
      $fl = @($td.failed | Where-Object { $_ }); [pscustomobject]@{ level = 'ACT'; what = "TRAIN STALLED: $($ev.env) train $($td.id) in '$($td.phase)' ended $(([datetime]$td.at).ToString('HH:mm')): $($td.why); $(@($td.requests).Count) request(s) requeued$(if ($fl.Count) { ", $($fl -join ', ') failed (stalled twice or died 3 times)" })"
        action = "& $($KitCmd.local) status -Env $($ev.env) (the next train runs them); $(if ($fl.Count) { 'failed: their agents look at the build log and redeploy; ' })repeats: kitty kind env with envy.ps1 logs -Env $($ev.env)" }
    }
    if ($hr = $ev.halfRestored) { [pscustomobject]@{ level = 'ACT'; what = "HALF-RESTORED: $($ev.env) restore to $($hr.mark) failed part way $(([datetime]$hr.at).ToString('HH:mm')): $($hr.why)"; action = "nobody tests on it: kitty kind env, envy.ps1 restore -Env $($ev.env) -Mark $($hr.mark) again (or seed)" } }
    $kf = $ev.keepFreeGB; $was = $last["$($ev.env)/keepFreeGB"]; if ($null -ne $kf) { $seenEnv["$($ev.env)/keepFreeGB"] = [double]$kf }   # a failed / older status has no floor: nothing cached
    if ($null -ne $kf -and $null -ne $was -and [math]::Abs([double]$kf - [double]$was) -ge 1) { [pscustomobject]@{ level = 'INFO'; what = "RAM FLOOR: $($ev.env) keep-free moved $was -> $kf GB ($($ev.keepFree))"; action = 'Nothing to do (learned from 24 h of free RAM; localEnv.keepFreeGB fixes it).' } }
    if ($ev.marks) {
      $new = @($ev.marks.expired | Where-Object { $_ -notin @($last["$($ev.env)/expired"]) }); $seenEnv["$($ev.env)/expired"] = @($ev.marks.expired)
      if ($new.Count) { & $watch "MARKS EXPIRED: $($ev.env) $($new -join ', ') (the binlog keeps $($ev.marks.binlogDays) d)" "restore to them is gone; envy.ps1 doctor -Env $($ev.env)" }
      if (-not $ev.marks.baseline) { if (-not $ev.marks.dbDown) { & $watch "NO BASELINE MARK: $($ev.env)" "envy.ps1 seed -Env $($ev.env) (a green seed marks baseline-<date>)" } }   # a lane's DB at rest: its start marks it
      elseif ($ev.marks.binlogDays -and [double]$ev.marks.baselineAgeDays -gt [double]$ev.marks.binlogDays - 3) { & $watch "BASELINE EXPIRES: $($ev.env) $($ev.marks.baseline) is $($ev.marks.baselineAgeDays) d old, the binlog keeps $($ev.marks.binlogDays) d" "envy.ps1 seed -Env $($ev.env)" }
      if ($ev.marks.binlogDays -and [double]$ev.marks.binlogDays -lt [double](Get-KitParam 'localEnv.marks.keepDays')) { & $watch "SHORT BINLOG: $($ev.env) keeps $($ev.marks.binlogDays) d < marks.keepDays" "envy.ps1 doctor -Env $($ev.env) (it names the DB's retention setting)" }
    }
    if ($ev.seed -and -not $ev.seed.ok) { & $watch "SEED DRIFT: $($ev.env) $(@(@($ev.seed.missing) + @($ev.seed.drift)) -join ', ')" "envy.ps1 seed -Env $($ev.env) (ENV-FIX)" }
  }
  # no large writes (owner, 2026-11-18): a schema on an env's DB grown past data.maxRows / data.maxMB since its baseline (first
  # sight; reset by a shrink, a flag or 24 h) -> WATCH; sizes: a background envy.ps1 sql -Query schemaSizes (the engine's; the last run read)
  $dcRows = [long](Get-KitParam 'data.maxRows'); $dcMB = [double](Get-KitParam 'data.maxMB'); $dcBaseH = [double](Get-KitParam 'localEnv.dataBaselineHours'); $dcAt = $now.ToString('o')
  # rows may be estimates (the engine's statistics), so a row flag also needs 1 MB more
  foreach ($dk in @($last.Keys | Where-Object { "$_" -like '*/data' })) { $seenEnv[$dk] = $last[$dk] }   # a beat with no sizes (busy, DB down) keeps baselines
  foreach ($ev in @($envs | Where-Object { $_.schemaSizes -and -not ($_.marks -and $_.marks.dbDown) })) {
    $dcNow = @{}; foreach ($dl in @(Invoke-KitBackground "envy.ps1 sql data $($ev.env)" $KitCmd.local @('sql', '-Env', $ev.env, '-Query', 'schemaSizes'))) { $dc = "$dl" -split "`t"; if ($dc.Count -ge 3 -and $dc[1] -match '^\d+$') { $dcNow[$dc[0]] = @{ rows = [long]$dc[1]; mb = [double]$dc[2] } } }
    if (-not $dcNow.Count) { continue }
    $dcKey = "$($ev.env)/data"; $dcOld = $last[$dcKey]; $dcNew = @{}   # $dcOld none: first sight (baselines, no flag)
    foreach ($ds in $dcNow.Keys) { $dn = $dcNow[$ds]; $db = if (-not $dcOld) { $null } elseif ($dcOld[$ds]) { $dcOld[$ds] } else { @{ rows = 0; mb = 0; at = $dcAt } }
      $dr = if ($db) { $dn.rows - [long]$db.rows } else { 0 }; $dm = if ($db) { $dn.mb - [double]$db.mb } else { 0 }
      $dfl = ($dr -gt $dcRows -and $dm -ge 1) -or $dm -gt $dcMB
      if ($dfl) { & $watch "DATA GROWTH: $($ev.env) $ds +$dr rows / +$([math]::Round($dm)) MB since $(([datetime]$db.at).ToString('MM-dd HH:mm')) (data.maxRows $dcRows, data.maxMB $dcMB)" 'no large writes (AGENTS.md): find who loaded it (board, envy.ps1 status), drop the synthetic data; performance -> EXPLAIN / plans / the read-only replica' }
      $dcNew[$ds] = if (-not $db -or $dfl -or $dr -lt 0 -or $dm -lt 0 -or ($now - [datetime]$db.at).TotalHours -ge $dcBaseH) { @{ rows = $dn.rows; mb = $dn.mb; at = $dcAt } } else { $db } }
    $seenEnv[$dcKey] = $dcNew
  }
  $seenEnv | ConvertTo-Json -Depth 4 | Set-Content $cf
  foreach ($ev in $envs) { foreach ($s in @($ev.services | Where-Object state -eq 'up (adopted)')) { & $watch "UNKNOWN: $($ev.env) $($s.service) port $($s.port) is served by a process the kit did not start" "stop it or change the port (envy.ps1 status -Env $($ev.env))" } }
  $sizesFile = Join-Path (Get-KitPath cache -Create) 'localenv-log-sizes.json'
  $sizes = try { Get-Content $sizesFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $sizes) { $sizes = @{} }
  $logs = @(Get-ChildItem (Get-KitPath localenv-logs) -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-(Get-KitParam 'localEnv.logWindowHours')) -and $_.BaseName -notmatch '-build$|^loop' } | ForEach-Object FullName)
  $seen = @{}
  $known = @(if ($state.known) { $state.known.Keys | Where-Object { "$_".StartsWith('noise:') } })   # supervise's state: -Ack on a spike
  foreach ($l in @(Get-KitLogErrors $logs $sizes)) { $seen[$l.path] = $l.size; foreach ($x in @(Get-KitSpikeFlag $l $envs -AutoFix:$AutoFix -Known $known)) { $x } }
  $seen | ConvertTo-Json | Set-Content $sizesFile
}
# ---- waits: status rows (lib.ps1 status): an agent whose env request is queued or in a train is WAITING, not STUCK, while the
# env's controller beats (none: nothing serves the queue, the agent may be STUCK)
function Get-KitStatusWaitLocalEnv {
  foreach ($f in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -match '^[^.]+\.json$')) {   # <env>.json, not <env>.seed.json
    $st = try { Invoke-KitLocked $f.FullName { Get-Content -LiteralPath $f.FullName -Raw } | ConvertFrom-Json } catch { continue }
    if (-not ($st.loop.beat -and ((Get-Date) - [datetime]$st.loop.beat).TotalMinutes -lt (Get-KitParam 'localEnv.loopBeatMinutes') -and (Test-KitPid $st.loop.pid $st.loop.pstart))) { continue }
    foreach ($r in @($st.requests | Where-Object { $_.agent -and $_.status -in 'queued', 'in-train' })) {
      [pscustomobject]@{ agent = $r.agent; why = "$($f.BaseName) $($r.kind) $($r.id)$(if ($r.status -ne 'in-train') { " $($r.status)" })$(if ($st.train) { ", train $($st.train.id) $($st.train.phase -replace '^waiting for', 'waits for')" })"; at = $r.at; next = "envy.ps1 wait -Env $($f.BaseName) -Id $($r.id); a hung train: TRAIN STALLED" }
    }
  }
}
# ---- cpu: CPU + RAM per lane service on the supervise page (Update-KitCpuStats hook): its process tree root, pid + start checked;
# a stopped service with pid 0 (its row stays on the page)
function Get-KitCpuGroupsLocalEnv {
  foreach ($f in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $s = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($p in @(Get-KitProps $s.services)) { $up = $p.Value.pid -and $p.Value.status -eq 'up' -and (Test-KitPid $p.Value.pid $p.Value.pstart); [pscustomobject]@{ name = "$($f.BaseName) · $($p.Name)"; pid = $(if ($up) { [int]$p.Value.pid } else { 0 }) } } }
}
