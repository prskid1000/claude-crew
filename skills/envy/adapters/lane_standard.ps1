#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none (doctor rows only).
# lane_standard.ps1: Test-PortClash (one port, one owner) and the lane service standard (and, with localEnv.laneIds "bird", no old <product><k> lane ids in the config) (reference.md "Lane service standard"), checked per env by doctor: every service
# (mysql, search, api, web, any new one) runs per lane and per product, keeps its data and logs on D:, starts at a lease and stops
# when idle. Rows: level `localEnv.laneStandard` (default WARN; FAIL stops a deploy), one per breach.
function Get-LanePathArgs([string]$Text) {
  @([regex]::Matches($Text, '(?i)(path\.data|path\.logs|datadir|data[-_]dir|log[-_]dir|log-error|defaults-file)[= ]\s*"?([^\s"]+)') | ForEach-Object { [pscustomobject]@{ key = $_.Groups[1].Value.ToLower(); path = $_.Groups[2].Value.Replace('\', '/').TrimEnd('/') } })
}
function Get-LaneStandardRows([string]$e) {
  $lvl = [string](Opt 'laneStandard' 'WARN'); $out = [Collections.Generic.List[object]]::new()
  $row = { param($t) $out.Add([pscustomobject]@{ level = $lvl; what = "lane standard: $t" }) }
  if ("$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'bird' -and $e -eq @(EnvNames)[0]) { foreach ($k in @($script:EnvKeysRaw | Where-Object { $_ -match '^(?<b>.+?)\d+$' -and $script:EnvKeysRaw -contains $Matches.b })) { & $row "old lane id envs.${k}: rename the key to <product>-<bird> (localEnv.laneIds bird)" } }
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
function Test-PortClash {
  $by = @{}
  foreach ($n in EnvNames) {
    foreach ($s in @((Get-KitMember $script:LE.envs $n).services | Where-Object { $_ -and $_.port })) {
      foreach ($pp in @(@{ p = $s.port; w = "$n/$($s.name)"; x = [bool]$s.external; c = [string]$s.start }, $(if ($s.debugPort) { @{ p = $s.debugPort; w = "$n/$($s.name) (debug)"; x = $false; c = '' } })) | Where-Object { $_ }) {
        $by["$($pp.p)"] = @(@($by["$($pp.p)"]) + @([pscustomobject]@{ who = $pp.w; external = $pp.x; start = $pp.c }) | Where-Object { $_ })
      }
    }
  }
  foreach ($port in $by.Keys) {
    $u = @($by[$port]); if ($u.Count -lt 2) { continue }
    # one external service shared by several envs (same start or none) is fine
    if (@($u | Where-Object { -not $_.external }).Count -or @($u.start | Select-Object -Unique).Count -gt 1) { "port $port is claimed by $(($u.who) -join ', ')" }
  }
}
# an old lane id (rm, rm2) -> its <product>-<bird> id (localEnv.laneIds bird), with a warning
function Resolve-EnvAlias([string]$n) { if ($n -and $script:EnvAlias.ContainsKey($n) -and -not (Get-KitMember $script:LE.envs $n)) { Write-Warning "old lane id '$n': use $($script:EnvAlias[$n]) (accepted for now)"; $script:EnvAlias[$n] } else { $n } }
