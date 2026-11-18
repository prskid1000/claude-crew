#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none (doctor rows only).
# lane_standard.ps1: the lane service standard (reference.md "Lane service standard"), checked per env by doctor: every service
# (mysql, search, api, web, any new one) runs per lane and per product, keeps its data and logs on D:, starts at a lease and stops
# when idle. Rows: level `localEnv.laneStandard` (default WARN; FAIL stops a deploy), one per breach.
function Get-LanePathArgs([string]$Text) {
  @([regex]::Matches($Text, '(?i)(path\.data|path\.logs|datadir|data[-_]dir|log[-_]dir|log-error|defaults-file)[= ]\s*"?([^\s"]+)') | ForEach-Object { [pscustomobject]@{ key = $_.Groups[1].Value.ToLower(); path = $_.Groups[2].Value.Replace('\', '/').TrimEnd('/') } })
}
function Get-LaneStandardRows([string]$e) {
  $lvl = [string](Opt 'laneStandard' 'WARN'); $out = [Collections.Generic.List[object]]::new()
  $row = { param($t) $out.Add([pscustomobject]@{ level = $lvl; what = "lane standard: $t" }) }
  foreach ($s in EnvServices $e) {
    if ($s.external -and -not $s.start -and $s.port) { & $row "service $($s.name) :$($s.port) of $e is external (always on, shared by lanes and products): give it a start (+ init) per lane, data on D:" }
    $cmds = @($s.start, $s.init.cmd, $s.prepare) | Where-Object { $_ }
    foreach ($a in @($cmds | ForEach-Object { Get-LanePathArgs ([string]$_) })) {
      if ($a.key -ne 'defaults-file' -and $a.path -match '^(?i)C:/') { & $row "service $($s.name) of $e keeps $($a.key) on C: ($($a.path)): move it under the lane's folder on D:" }
    }
    # one data path per lane and product: another env running the same service on the same path shares its data
    foreach ($a in @($s.start | Where-Object { $_ } | ForEach-Object { Get-LanePathArgs ([string]$_) } | Where-Object { $_.key -in 'path.data', 'datadir', 'data-dir', 'data_dir' })) {
      foreach ($o in @(EnvNames | Where-Object { $_ -ne $e })) {
        $os = @(EnvServices $o | Where-Object { $_.name -eq $s.name -and $_.start })[0]
        if ($os -and @(Get-LanePathArgs ([string]$os.start) | Where-Object { $_.key -eq $a.key -and $_.path -eq $a.path }).Count) { & $row "service $($s.name) of $e shares $($a.key) $($a.path) with ${o}: one folder per lane (use {lane} and the env name)" }
      }
    }
  }
  $out
}
