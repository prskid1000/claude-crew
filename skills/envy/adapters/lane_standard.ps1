#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none (doctor rows; lane worktrees: Ensure-Worktree, Sync-DepLinks, Resolve-SvcDir).
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
# ---- lane worktrees: a lane repo's worktree and its dependency links (moved from envy.ps1 at its cap)
function Ensure-Worktree([string]$e, $r) {
  $co = $r.cfg.checkout; if ($r.wt -eq (Get-KitLaneWorktree $e $co -Old) -and -not (Test-Path "$($r.wt)/.git")) { $r.wt = Get-KitLaneWorktree $e $co -New }   # lanes -Migrate moved it since EnvRepos
  if ((Test-Path "$($r.wt)/.git") -and $r.wt -eq (Get-KitLaneWorktree $e $co -Old)) {   # old names: moved once the lane is idle (a service may run from it)
    $up = @((Read-State $e).services.Values | Where-Object { $_.status -in 'up', 'starting' }).Count
    $mv = Move-LaneWorktree $e $co $(if ($up) { "$up service(s) up" }); if ("$mv" -like 'moved*') { $r.wt = Get-KitLaneWorktree $e $co -New }; if ($mv) { Write-Host $mv }; return
  }
  if (Test-Path "$($r.wt)/.git") { return }
  Write-Host "[$e] creating worktree $($r.wt) ($($r.name) @ $($r.target))"
  git -C $co branch -D "localenv/$e" 2>$null | Out-Null   # old names, no worktree: test merges only
  $wb = if ($r.branch) { $r.branch } else { Get-KitLaneBranch $e }; $wn = if ($r.wtName) { $r.wtName } else { "lane-$(Get-KitLaneSlug $e)" }   # a second target (EnvRepos): its own
  & $KitCmd.dev wt new -Repo $r.cfg.checkout -Branch $wb -Target $r.target -Name $wn | ForEach-Object { Write-Host "  $_" }
}
function Sync-DepLinks([string]$e, $r) {
  $c = $r.cfg
  # linkFromByTarget.<t>: a path or a list (per package folder the first source that has it)
  $srcs = @(if ($c.linkFromByTarget -and (Get-KitMember $c.linkFromByTarget ($r.target))) { Get-KitMember $c.linkFromByTarget ($r.target) } elseif ($c.linkFrom -and $r.target -eq $c.target) { $c.linkFrom } else { $c.checkout }) | ForEach-Object { "$_" }
  foreach ($s in $srcs) { if (-not (Test-Path $s)) { Write-Warning "[$e] dependency source $s for $($r.name) @ $($r.target) does not exist"; return } }
  $srcs = @($srcs | ForEach-Object { (Resolve-Path $_).Path }); $src = $srcs[0]
  foreach ($pj in (git -C $r.wt ls-files -- 'package.json' '*/package.json' | Where-Object { $_ -notmatch 'node_modules/' })) {
    $rel = Split-Path $pj; if (-not $rel) { $rel = '.' }
    $src = @($srcs | Where-Object { Test-Path (Join-Path $_ (Join-Path $rel 'node_modules')) })[0]; if (-not $src) { $src = $srcs[0] }
    $from = Join-Path $src (Join-Path $rel 'node_modules'); $to = Join-Path $r.wt (Join-Path $rel 'node_modules')
    if ((Test-Path $from) -and (Set-NodeModules $to $from $src $r.wt)) { Write-Host "[$e] $($r.name): $(Join-Path $rel 'node_modules') linked from $src" }
  }
  foreach ($l in Get-DirLinks $r.wt 4 | Where-Object { $_.Name -eq '.venv' }) {
    $rel = [IO.Path]::GetRelativePath($r.wt, $l.FullName); $want = Join-Path $srcs[0] $rel
    if (-not (Test-Path $want) -or "$(@($l.Target)[0])".TrimEnd('\', '/') -eq $want.TrimEnd('\', '/')) { continue }
    Remove-DirLink $l.FullName; New-DirLink $l.FullName $want
    Write-Host "[$e] $($r.name): $rel now links $want"
  }
}
# a service's start: its config error, else its dir (the lane worktree made when missing)
# a service config that cannot start (a target with no repo ran from a cwd-relative dir: "folder ... does not exist", restarted 3x / 30 min)
function Get-SvcConfigError([string]$e, $s) { if (-not $s.repo -and $s.target) { "[$e] $($s.name): config: target $($s.target) needs a repo (kit.local.json localEnv.envs.$e.services[$($s.name)].repo): not started, no retry until the config changes" } }
# its lane worktree made at its start when no train made it yet (a second target, K61e)
function Resolve-SvcDir([string]$e, $s) {
  if (($ce = Get-SvcConfigError $e $s)) { throw $ce }
  $dir = SvcDir $e $s
  if (-not (Test-Path $dir) -and $s.repo -and ($r = (EnvRepos $e)[(RepoOf $e $s)]) -and -not (Test-Path "$($r.wt)/.git")) { Ensure-Worktree $e $r; Sync-DepLinks $e $r; $dir = SvcDir $e $s }
  $dir
}
