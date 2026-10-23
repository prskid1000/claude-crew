<#
localenv_supervise.ps1 (extra local-env): the local env in orch.ps1 supervise, dot-sourced by orch.ps1 (skills/orchestrate/adapters/):
env rows, owner holds, RESTART LOOP, UNKNOWN port owners, ERROR SPIKE. Its hook runs inside supervise (uses $now, Left);
Invoke-KitPauseLocalEnv in orch.ps1 pause.
Exit codes: none (functions only).
#>
#Requires -Version 7
# new error lines per log since its last size (ERROR SPIKE); level words case-sensitive: "WARN ... Error while" is no error
function Get-KitLogErrors([string[]]$Files, $Sizes) {
  if (-not $Sizes) { $Sizes = @{} }   # first round: no sizes yet
  foreach ($x in $Files) {
    $i = Get-Item $x -ErrorAction SilentlyContinue; if (-not $i) { continue }
    $from = [long]$Sizes.($i.FullName); if (-not $Sizes.Contains($i.FullName)) { $from = $i.Length } elseif ($from -gt $i.Length) { $from = 0 }   # rotated: from 0
    $from = [math]::Max($from, $i.Length - 1MB)
    $new = if ($i.Length -gt $from) { $s = [IO.File]::Open($i.FullName, 'Open', 'Read', 'ReadWrite'); try { [void]$s.Seek($from, 'Begin'); [IO.StreamReader]::new($s).ReadToEnd() } finally { $s.Dispose() } } else { '' }
    $hits = @($new -split "`r?`n" | Where-Object { $_ -cmatch '\b(ERROR|FATAL)\b|Exception\b|Traceback|^\s*\w*Error:|(?i:\b(status|HTTP/\S+)\W+5\d\d\b)' })
    [pscustomobject]@{ path = $i.FullName; size = $i.Length; errors = $hits.Count; first = "$($hits | Select-Object -First 1)".Trim() }
  }
}
# local-env rows (pure on status -Json): up services + holders; a down one only while a lease / hold needs it (no lease = idle)
function Get-KitEnvRows($Envs, [datetime]$now) {
  $rows = [Collections.Generic.List[object]]::new(); $fl = [Collections.Generic.List[object]]::new(); $own = @()
  foreach ($ev in @($Envs | Where-Object { $_.env -and @($_.services).Count })) {
    $holders = @(@($ev.leases) + @($ev.holds) | Where-Object { $_ })
    $down = @($ev.services | Where-Object { $d0 = $_.service; $_.state -notmatch '^up' -and @($holders | Where-Object { $d0 -in @($_.services) }).Count })
    foreach ($sv in @($ev.services | Where-Object { $_.state -match '^up' })) {
      $hl = @($holders | Where-Object { $sv.service -in @($_.services) }); $gl = @($hl | Where-Object { $null -ne $_.graceLeft } | ForEach-Object graceLeft | Sort-Object)[0]
      $rows.Add([pscustomobject]@{ name = "$($ev.env) · $($sv.service)"; by = "$((@($hl | ForEach-Object { if ($_.agent) { $_.agent } else { $_.who } }) | Select-Object -Unique) -join ', ')$(if ($null -ne $gl) { " (grace $gl min)" })"; gb = $sv.gb })
      $why = @($sv.need); $h1 = @($ev.holds | Where-Object { $sv.service -in @($_.services) -and $_.at -and ($now - [datetime]$_.at).TotalMinutes -ge 30 })[0]
      if ($h1 -and $why.Count -and -not @($why | Where-Object { $_ -notmatch '^hold:' }).Count) { $fl.Add([pscustomobject]@{ level = 'WATCH'; what = "$($ev.env) $($sv.service) kept up only by $($h1.who)'s hold for $([int]($now - [datetime]$h1.at).TotalMinutes) min (no lease)"; action = "Done with it: & $($KitCmd.local) unhold -Env $($ev.env) -Agent $($h1.who)" }) }
    }
    foreach ($h in @($ev.holds | Where-Object owner)) { $own += "owner hold $($ev.env) [$(@($h.services) -join ',')] until $($h.until) (unhold -Env $($ev.env) -Agent $($h.who) when done)" }
    if ($down.Count) { $rows.Add([pscustomobject]@{ name = "$($ev.env) · $(($down | ForEach-Object service) -join ' · ') (down)"; by = "$(@($down | ForEach-Object { if ("$($_.why)" -match 'memory|RAM') { 'memory' } elseif ($_.why) { "$($_.why)".Substring(0, [math]::Min(30, "$($_.why)".Length)) } else { $_.state } } | Select-Object -Unique) -join ', ')"; gb = 0 }) }
  }
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
  foreach ($l in @(Get-KitLogErrors $logs $sizes)) { $seen[$l.path] = $l.size; if ($l.errors -gt 0) { & $watch "ERROR SPIKE: $($l.errors) new error line(s) in $($l.path)" "first: $($l.first)" } }
  $seen | ConvertTo-Json | Set-Content $sizesFile
}