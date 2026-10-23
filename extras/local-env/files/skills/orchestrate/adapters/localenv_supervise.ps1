<#
localenv_supervise.ps1 (extra local-env): the local env in orch.ps1 supervise, dot-sourced by orch.ps1 (skills/orchestrate/adapters/):
env rows, owner holds, RESTART LOOP, UNKNOWN port owners, ERROR SPIKE. Its hook runs inside supervise (uses $now, Left);
Invoke-KitPauseLocalEnv in orch.ps1 pause.
Exit codes: none (functions only).
Sections: L9 logs · L35 rows · L69 supervise
#>
#Requires -Version 7
# ---- logs: new error lines per log, their classes
# new error lines per log since its last size (ERROR SPIKE); level words case-sensitive: "WARN ... Error while" is no error.
# Classes: expected (4xx of negative tests: bad.request, not found, validation) apart; else startup > connection > 5xx > error;
# dep = the host:port a connection line names (a startup failure caused by a dependency that was down)
$script:KitLogClasses = [ordered]@{
  expected   = '(?i)\bbad\.request\b|\bnot[ .]found\b|\bvalidation\b|MethodArgumentNotValid|ConstraintViolation|\b(BadRequest|NotFound|AccessDenied|Unauthorized|Forbidden)\w*\b|\b(status|HTTP/\S+)\W+4\d\d\b'
  startup    = '(?i)Application run failed|APPLICATION FAILED TO START|failed to start|BeanCreationException|\brolling back\b|\brollback\b'
  connection = '(?i)connection refused|Communications link failure|ConnectException|NoNodeAvailable|UnknownHostException|ECONNREFUSED|\b(elasticsearch|search|mysql|redis|kafka|rabbit\w*)\b.{0,40}\b(not reachable|unreachable|refused|timed? ?out|down)\b'
  '5xx'      = '(?i)\b(status|HTTP/\S+)\W+5\d\d\b'
}
function Get-KitLogErrors([string[]]$Files, $Sizes) {
  if (-not $Sizes) { $Sizes = @{} }   # first round: no sizes yet
  foreach ($x in $Files) {
    $i = Get-Item $x -ErrorAction SilentlyContinue; if (-not $i) { continue }
    $from = [long]$Sizes.($i.FullName); if (-not $Sizes.Contains($i.FullName)) { $from = $i.Length } elseif ($from -gt $i.Length) { $from = 0 }   # rotated: from 0
    $from = [math]::Max($from, $i.Length - 1MB)
    $new = if ($i.Length -gt $from) { $s = [IO.File]::Open($i.FullName, 'Open', 'Read', 'ReadWrite'); try { [void]$s.Seek($from, 'Begin'); [IO.StreamReader]::new($s).ReadToEnd() } finally { $s.Dispose() } } else { '' }
    $hits = @($new -split "`r?`n" | Where-Object { $_ -cmatch '\b(ERROR|FATAL)\b|Exception\b|Traceback|^\s*\w*Error:|(?i:\b(status|HTTP/\S+)\W+5\d\d\b)' })
    $C = $script:KitLogClasses; $real = @($hits | Where-Object { $_ -notmatch $C.expected -or $_ -match "$($C.startup)|$($C.connection)|$($C['5xx'])" })
    $cls = @('startup', 'connection', '5xx' | Where-Object { $k = $_; @($real | Where-Object { $_ -match $C[$k] }).Count })[0]
    $top = if ($cls) { @($real | Where-Object { $_ -match $C[$cls] })[0] } elseif ($real.Count) { $real[0] } else { @($hits)[0] }
    $cl = @($real | Where-Object { $_ -match $C.connection })[0]   # the address after the connection words, never a log timestamp
    $dep = if ("$cl" -match "(?:$($C.connection)).*?\b(?<h>localhost|\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z][\w-]*(?:\.[\w-]+)*):(?<p>\d{2,5})\b") { "$($Matches.h):$($Matches.p)" }
    [pscustomobject]@{ path = $i.FullName; size = $i.Length; errors = $real.Count; expected = $hits.Count - $real.Count; cls = $(if ($cls) { $cls } else { 'error' }); first = "$top".Trim(); dep = $dep }
  }
}
# ---- rows: env rows, pause
# local-env rows (pure on status -Json): up services + holders; a down one only while a lease / hold needs it (no lease = idle);
# one service on one port in several envs (a shared external DB) is one row: its envs and holders merged, its RAM once
function Get-KitEnvRows($Envs, [datetime]$now) {
  $rows = [Collections.Generic.List[object]]::new(); $fl = [Collections.Generic.List[object]]::new(); $own = @(); $up = [ordered]@{}
  foreach ($ev in @($Envs | Where-Object { $_.env -and @($_.services).Count })) {
    $holders = @(@($ev.leases) + @($ev.holds) | Where-Object { $_ })
    $down = @($ev.services | Where-Object { $d0 = $_.service; $_.state -notmatch '^up' -and @($holders | Where-Object { $d0 -in @($_.services) }).Count })
    foreach ($sv in @($ev.services | Where-Object { $_.state -match '^up' })) {
      $hl = @($holders | Where-Object { $sv.service -in @($_.services) }); $gl = @($hl | Where-Object { $null -ne $_.graceLeft } | ForEach-Object graceLeft | Sort-Object)[0]
      $key = if ($sv.port) { "$($sv.service):$($sv.port)" } else { "$($ev.env)/$($sv.service)" }; if (-not $up.Contains($key)) { $up[$key] = @{ svc = $sv.service; envs = @(); who = @(); gl = @(); gb = 0 } }
      $u = $up[$key]; $u.envs += $ev.env; $u.who += @($hl | ForEach-Object { if ($_.agent) { $_.agent } else { $_.who } }); $u.gl += @($gl | Where-Object { $null -ne $_ }); $u.gb = [math]::Max([double]$u.gb, [double]$sv.gb)
      $why = @($sv.need); $h1 = @($ev.holds | Where-Object { $sv.service -in @($_.services) -and $_.at -and ($now - [datetime]$_.at).TotalMinutes -ge 30 })[0]
      if ($h1 -and $why.Count -and -not @($why | Where-Object { $_ -notmatch '^hold:' }).Count) { $fl.Add([pscustomobject]@{ level = 'WATCH'; what = "$($ev.env) $($sv.service) kept up only by $($h1.who)'s hold for $([int]($now - [datetime]$h1.at).TotalMinutes) min (no lease)"; action = "Done with it: & $($KitCmd.local) unhold -Env $($ev.env) -Agent $($h1.who)" }) }
    }
    foreach ($h in @($ev.holds | Where-Object owner)) { $own += "owner hold $($ev.env) [$(@($h.services) -join ',')] until $($h.until) (unhold -Env $($ev.env) -Agent $($h.who) when done)" }
    if ($down.Count) { $rows.Add([pscustomobject]@{ name = "$($ev.env) · $(($down | ForEach-Object service) -join ' · ') (down)"; by = "$(@($down | ForEach-Object { if ("$($_.why)" -match 'memory|RAM') { 'memory' } elseif ($_.why) { "$($_.why)".Substring(0, [math]::Min(30, "$($_.why)".Length)) } else { $_.state } } | Select-Object -Unique) -join ', ')"; gb = 0 }) }
  }
  $ur = @(foreach ($u in $up.Values) { $g = @($u.gl | Sort-Object)[0]
    [pscustomobject]@{ name = $(if ($u.envs.Count -gt 1) { "$($u.svc) ($($u.envs -join ', '))" } else { "$($u.envs[0]) · $($u.svc)" }); by = "$((@($u.who) | Select-Object -Unique) -join ', ')$(if ($null -ne $g) { " (grace $g min)" })"; gb = $u.gb } }); if ($ur.Count) { $rows.InsertRange(0, [object[]]$ur) }
  [pscustomobject]@{ rows = @($rows); flags = @($fl); owner = @($own) }
}
# orch.ps1 pause: kit-started services no live lease or hold needs stop now (paused agents' leases are only in grace)
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
# ---- supervise: ERROR SPIKE flags, the supervise hook
# one log's new errors -> nothing (expected 4xx while a lease tests), ACT (startup, connection, 5xx: the cause, env, service,
# release), WATCH (other errors); a startup failure whose dependency is up again: restarted once (-AutoFix)
function Get-KitSpikeFlag($L, $Envs, [switch]$AutoFix) {
  $base = [IO.Path]::GetFileNameWithoutExtension($L.path); $ev = @($Envs | Where-Object { $_.env -and $base.StartsWith("$($_.env)-") } | Sort-Object { - "$($_.env)".Length })[0]
  $svc = if ($ev) { $base.Substring("$($ev.env)".Length + 1) } else { $base }; $where = if ($ev) { "$($ev.env) $svc (release r$($ev.release))" } else { $L.path }
  $n = $L.errors + $(if (-not @($ev.leases).Count) { $L.expected })   # 4xx with nobody testing: someone else's calls
  if ($n -le 0) { return }
  if ($L.cls -eq 'error') { return [pscustomobject]@{ level = 'WATCH'; what = "ERROR SPIKE: $n new error line(s) in $($L.path)"; action = "first: $($L.first)" } }
  if ($L.cls -eq 'startup' -and $L.dep -and $ev) {
    $up = $false; $tc = [Net.Sockets.TcpClient]::new(); try { $h, $p = $L.dep -split ':'; $up = $tc.ConnectAsync($h, [int]$p).Wait(1000) -and $tc.Connected } catch {} finally { $tc.Dispose() }
    $rf = Join-Path (Get-KitPath cache -Create) 'localenv-retries.json'; $tried = try { Get-Content $rf -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $tried) { $tried = @{} }
    $key = $L.path; foreach ($k0 in @($tried.Keys)) { if (((Get-Date) - [datetime]$tried[$k0]).TotalMinutes -ge 60) { $tried.Remove($k0) } }   # once per log an hour
    if ($up -and $AutoFix -and -not $tried[$key]) {
      $tried[$key] = (Get-Date).ToString('o'); $tried | ConvertTo-Json | Set-Content $rf
      $r = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'restart', '-Env', $ev.env, '-Services', $svc, '-Agent', 'supervise') ([math]::Min(120, (Left)))
      return [pscustomobject]@{ level = $(if ($r.code) { 'ACT' } else { 'INFO' }); what = "$(if ($r.code) { 'ERROR SPIKE' } else { 'auto-fixed' }): $where failed to start while $($L.dep) was down; it is up now: restarted once$(if ($r.code) { " - FAILED: $("$($r.out)".Trim())" })"; action = "& $($KitCmd.local) logs -Env $($ev.env) -Service $svc" }
    }
    if (-not $up) { return [pscustomobject]@{ level = 'ACT'; what = "ERROR SPIKE: $where failed to start: $($L.dep) is down: $($L.first)"; action = "Bring $($L.dep) up; the next heartbeat restarts $svc once (-AutoFix)." } }
  }
  [pscustomobject]@{ level = 'ACT'; what = "ERROR SPIKE: $where, $n new error line(s), $($L.cls): $($L.first)"; action = "& $($KitCmd.local) logs -Env $(if ($ev) { $ev.env } else { '<env>' }) -Service $svc; a branch layer in that release caused it -> its agent (board msg), else kitty kind env" }
}
# supervise section 7: env rows and flags, owner holds (info), restart loops, unknown port owners, new log errors (sizes cached per round)
function Get-KitSuperviseFlagsLocalEnv([switch]$AutoFix) {
  if (-not (Test-Path $KitCmd.local)) { return }
  $watch = { param($what, $action) [pscustomobject]@{ level = 'WATCH'; what = $what; action = $action } }
  $le = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') ([math]::Min(30, (Left)))
  $envs = @(try { "$($le.out)" | ConvertFrom-Json } catch { @() })
  $er = Get-KitEnvRows $envs $now
  $er.rows; $er.flags; foreach ($o in $er.owner) { [pscustomobject]@{ info = $o } }
  foreach ($sf in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $x = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $x) { continue }
    foreach ($sn in @($x.services.Keys)) {
      $n = @($x.services[$sn].restarts | Where-Object { $_ -and ($now - [datetime]$_).TotalMinutes -lt 30 }).Count
      if ($n -gt 2) { & $watch "RESTART LOOP: $($sf.BaseName) $sn restarted $n times in 30 min" "evidence localenv.ps1 logs -Env $($sf.BaseName) -Service $sn" }
    }
  }
  foreach ($ev in $envs) { foreach ($s in @($ev.services | Where-Object state -eq 'up (adopted)')) { & $watch "UNKNOWN: $($ev.env) $($s.service) port $($s.port) is served by a process the kit did not start" "stop it or change the port (localenv.ps1 status -Env $($ev.env))" } }
  $sizesFile = Join-Path (Get-KitPath cache -Create) 'localenv-log-sizes.json'
  $sizes = try { Get-Content $sizesFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $sizes) { $sizes = @{} }
  $logs = @(Get-ChildItem (Get-KitPath localenv-logs) -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-2) -and $_.BaseName -notmatch '-build$|^loop' } | ForEach-Object FullName)
  $seen = @{}
  foreach ($l in @(Get-KitLogErrors $logs $sizes)) { $seen[$l.path] = $l.size; foreach ($x in @(Get-KitSpikeFlag $l $envs -AutoFix:$AutoFix)) { $x } }
  $seen | ConvertTo-Json | Set-Content $sizesFile
}