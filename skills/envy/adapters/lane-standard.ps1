#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none (Get-Doctor: the doctor verb, its rows; lane worktrees: Ensure-Worktree, Sync-DepLinks, Resolve-SvcDir, Get-LaneWorktreeRows).
# lane-standard.ps1: Test-PortClash (one port, one owner) and the lane service standard (and, with localEnv.laneIds "bird" / "nn", no older lane ids in the config) (reference.md "Lane service standard"), checked per env by doctor: every service
# (mysql, search, api, web, any new one) runs per lane and per product, keeps its data and logs under the kit, off the system drive, starts at a lease and stops
# when idle. Rows: level `localEnv.laneStandard` (default WARN; FAIL stops a deploy), one per breach.
# Sections: L7 lane standard · L56 lane worktrees · L126 doctor
# ---- lane standard: doctor rows, port clashes, env aliases
function Get-LanePathArgs([string]$Text) {
  @([regex]::Matches($Text, '(?i)(path\.data|path\.logs|datadir|data[-_]dir|log[-_]dir|log-error|defaults-file)[= ]\s*"?([^\s"]+)') | ForEach-Object { [pscustomobject]@{ key = $_.Groups[1].Value.ToLower(); path = $_.Groups[2].Value.Replace('\', '/').TrimEnd('/') } })
}
function Get-LaneStandardRows([string]$e) {
  $sysDrive = "$env:SystemDrive"   # Windows only: POSIX data paths have no system drive rule
  $lvl = [string](Opt 'laneStandard' 'WARN'); $out = [Collections.Generic.List[object]]::new()
  $row = { param($t) $out.Add([pscustomobject]@{ level = $lvl; what = "lane standard: $t" }) }
  if ("$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'bird' -and $e -eq @(EnvNames)[0]) { foreach ($k in @($script:EnvKeysRaw | Where-Object { $_ -match '^(?<b>.+?)\d+$' -and $script:EnvKeysRaw -contains $Matches.b })) { & $row "old lane id envs.${k}: rename the key to <product>-<bird> (localEnv.laneIds bird)" } }
  if (($lm = @(Get-KitLaneMap)).Count -and $e -eq @(EnvNames)[0]) {   # laneIds "nn": override keys under their lane-<nn> id; an env's lanes stay inside its block of 10
    foreach ($r in @($lm | Where-Object { $_.k -gt 1 })) { foreach ($k in @($r.old, $r.bird | Where-Object { $_ -in $script:EnvKeysRaw })) { & $row "old lane id envs.${k}: rename the key to $($r.id) (localEnv.laneIds nn; mysql-base-move.ps1 -Config -Ids nn)" } }
    foreach ($g in @($lm | Group-Object env | Where-Object { $_.Count -gt 9 -and @($lm.env | Select-Object -Unique).Count -gt 1 })) { & $row "env $($g.Name): $($g.Count) lanes, laneIds nn allows 9 per env with 2+ envs (its ids would reach the next env's)" } }
  foreach ($s in EnvServices $e) {
    if ($s.external -and -not $s.start -and $s.port) { & $row "service $($s.name) :$($s.port) of $e is external (always on, shared by lanes and products): give it a start (+ init) per lane, data under the kit" }
    $cmds = @($s.start, $s.init.cmd, $s.prepare) | Where-Object { $_ }
    # a {token} no envy verb expands stays literal (the retired sandbox {suffix}: search ran on C:/.../rdata{suffix} folders)
    $known = 'port', 'debugPort', 'dir', 'wt', 'env', 'lane', 'bird', 'kit', 'workspace', 'artifact', 'javaArgs', 'lanIp', 'aot', 'aotFile', 'cache', 'reactor', 'tenant', 'mark', 'source', 'template', 'out'
    $txt = (@($cmds) + @($s.health) + @(Get-KitProps $s.env | ForEach-Object { "$($_.Value)" })) -join ' '
    foreach ($ph in @([regex]::Matches($txt, '(?<!\$)\{([A-Za-z]\w*)(?::[\w.-]+)?\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Where-Object { $_ -notin $known })) { $out.Add([pscustomobject]@{ level = 'WARN'; what = "service $($s.name) of ${e}: {$ph} is no envy placeholder, it stays literal text (reference.md Lanes, Config)" }) }
    foreach ($a in @($cmds | ForEach-Object { Get-LanePathArgs ([string]$_) })) {
      if ($a.key -ne 'defaults-file' -and $sysDrive -and $a.path.StartsWith("$sysDrive/", 'OrdinalIgnoreCase')) { & $row "service $($s.name) of $e keeps $($a.key) on the system drive $sysDrive ($($a.path)): move it under the lane's folder (.state/localenv/lanes)" }
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
# an old lane id (shop, shop2; laneIds nn: shop-kestrel too) -> today's id (bird: <product>-<bird>, nn: lane-<nn>), with a warning
function Resolve-EnvAlias([string]$n) { if ($n -and $script:EnvAlias.ContainsKey($n) -and -not (Get-KitMember $script:LE.envs $n)) { Write-Warning "old lane id '$n': use $($script:EnvAlias[$n]) (accepted for now)"; $script:EnvAlias[$n] } else { $n } }
# ---- lane worktrees: a lane repo's worktree and its dependency links (moved from envy.ps1 at its cap)
function Ensure-Worktree([string]$e, $r) {
  $co = $r.cfg.checkout; if ($r.wt -eq (Get-KitLaneWorktree $e $co -Old) -and -not (Test-Path "$($r.wt)/.git")) { $r.wt = Get-KitLaneWorktree $e $co -New }   # lanes -Migrate moved it since EnvRepos
  if ((Test-Path "$($r.wt)/.git") -and $r.wt -eq (Get-KitLaneWorktree $e $co -Old)) {   # old names: moved once the lane is idle (a service may run from it)
    $up = @((Read-State $e).services.Values | Where-Object { $_.status -in 'up', 'starting' }).Count
    $mv = Move-LaneWorktree $e $co $(if ($up) { "$up service(s) up" }); if ("$mv" -like 'moved*') { $r.wt = Get-KitLaneWorktree $e $co -New }; if ($mv) { Write-Host $mv }; return
  }
  if (Test-LaneWorktree $r.wt) { return }
  if (Test-Path -LiteralPath $r.wt) {   # a plain folder or a dead .git link: moved aside (cleanup sweep judges it), made again below
    if (-not (Test-DeadLaneDir $r.wt)) { throw "[$e] $($r.wt) has a live .git but is not its own git worktree (toplevel: $("$(git -C $r.wt rev-parse --show-toplevel 2>&1)".Trim())): check it by hand (never moved)" }
    $aside = "$($r.wt).stale-$(New-KitId stale -Number)"   # NAME-NUMBER: a tie only (the folder name says what it is); Move-Item into an existing folder nests
    Move-Item -LiteralPath $r.wt $aside; git -C $co worktree prune 2>$null | Out-Null
    Write-Warning "[$e] $($r.wt) was not its own git worktree: moved to $aside" }
  Write-Host "[$e] creating worktree $($r.wt) ($($r.name) @ $($r.target))"
  git -C $co branch -D "localenv/$e" 2>$null | Out-Null   # old names, no worktree: test merges only
  $wb = if ($r.branch) { $r.branch } else { Get-KitLaneBranch $e }; $wn = if ($r.wtName) { $r.wtName } else { "lane-$(Get-KitLaneSlug $e)" }   # a second target (EnvRepos): its own
  $out = @(& $KitCmd.dev wt new -Repo $r.cfg.checkout -Branch $wb -Target $r.target -Name $wn *>&1 | ForEach-Object { "$_" } | Where-Object { $_ }); $wx = $LASTEXITCODE; $out | ForEach-Object { Write-Host "  $_" }
  # a failed wt new (a missing dep source) surfaced here, not as Sync-Repo's "toplevel: )"
  if (-not (Test-LaneWorktree $r.wt)) { throw "[$e] lane worktree $($r.wt) ($($r.name) @ $($r.target)) not created: $(if ($out) { $out[-1] } else { "wt new exit $wx, no output" })" }
}
function Test-LaneWorktree([string]$d) { $top = "$(git -C $d rev-parse --show-toplevel 2>$null)".Trim(); [bool]($top -and [string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\', '/'), [IO.Path]::GetFullPath($d).TrimEnd('\', '/'), $(if ($KitIsWindows) { 'OrdinalIgnoreCase' } else { 'Ordinal' }))) }
# no .git, or a .git file whose gitdir is gone: safe to move aside; a live .git (another tree, a git error) never is
function Test-DeadLaneDir([string]$d) {
  $g = Join-Path $d '.git'; if (-not (Test-Path -LiteralPath $g)) { return $true }; if (Test-Path -LiteralPath $g -PathType Container) { return $false }
  $gd = ("$(Get-Content -LiteralPath $g -TotalCount 1)" -replace '^gitdir:\s*').Trim(); -not ($gd -and (Test-Path -LiteralPath $(if ([IO.Path]::IsPathRooted($gd)) { $gd } else { Join-Path $d $gd })))
}
# linkFromByTarget.<t>: a path or a list (per package folder the first source that has it), else linkFrom (its target), else the checkout
function Get-LaneDepSources($r) { $c = $r.cfg; @($(if ($c.linkFromByTarget -and (Get-KitMember $c.linkFromByTarget $r.target)) { (Get-KitMember $c.linkFromByTarget $r.target) } elseif ($c.linkFrom -and $r.target -eq $c.target) { $c.linkFrom } else { $c.checkout }) | ForEach-Object { "$_" }) }
# doctor: a missing dep source (WARN with a worktree, FAIL without: wt new refuses); a lane path that is not its own worktree: dead = WARN
# (refresh or -Fix, when the lane is idle, makes it again), a live .git = FAIL (by hand)
function Get-LaneWorktreeRows([string]$e, [switch]$Fix, $Repos) {
  if ($null -eq $Repos) { try { $Repos = @((EnvRepos $e).Values) } catch { return [pscustomobject]@{ level = 'FAIL'; what = "lane repos: $("$_".Split("`n")[0])" } } }
  foreach ($r in $Repos) {
    $ok = Test-LaneWorktree $r.wt; $miss = @(Get-LaneDepSources $r | Where-Object { -not (Test-Path -LiteralPath $_) })
    foreach ($m in $miss) { [pscustomobject]@{ level = $(if ($ok) { 'WARN' } else { 'FAIL' }); what = "$($r.name) @ $($r.target): dependency source $m is missing (kit.local.json repos[].linkFromByTarget): create it, else no new lane worktree" } }
    if ($ok -or -not (Test-Path -LiteralPath $r.wt)) { continue }   # not made yet: the next refresh makes it
    $what = "lane worktree $($r.wt) ($($r.name) @ $($r.target)) is not its own git worktree"
    if (-not (Test-DeadLaneDir $r.wt)) { [pscustomobject]@{ level = 'FAIL'; what = "${what}, its .git is live: check it by hand" }; continue }
    $busy = if ($Fix) { Get-LaneBusy $e (Read-State $e) }
    if ($Fix -and -not $miss.Count -and -not $busy) { try { Ensure-Worktree $e $r 6>$null 3>$null; Sync-DepLinks $e $r 6>$null; [pscustomobject]@{ level = 'OK'; what = "fixed: $what; made again" } } catch { [pscustomobject]@{ level = 'FAIL'; what = "-Fix: $("$_".Split("`n")[0])" } }; continue }
    [pscustomobject]@{ level = 'WARN'; what = "${what}: $(if ($miss.Count) { 'the missing dependency source blocks remaking it' } elseif ($busy) { "-Fix waits: lane in use ($busy)" } else { "refresh or envy.ps1 doctor -Env $e -Fix remakes it" })" }
  }
}
function Sync-DepLinks([string]$e, $r) {
  $srcs = Get-LaneDepSources $r
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
  if (-not (Test-Path $dir) -and $s.repo -and ($r = (EnvRepos $e)[(RepoOf $e $s)]) -and -not (Test-Path "$($r.wt)/.git")) { try { Ensure-Worktree $e $r } catch { if (-not (Test-Path "$($r.wt)/.git")) { throw } }; Sync-DepLinks $e $r; $dir = SvcDir $e $s }
  $dir
}
# ---- doctor: what an env needs to run (doctor verb; deploy stops on a FAIL): config, env file, scripts, JAVA_HOME, builds, ports, health
function Get-Doctor([string]$e, [switch]$Fix) {
  $c = Get-EnvCfg $e; $r = [Collections.Generic.List[object]]::new()
  $add = { param($lvl, $what) $r.Add([pscustomobject]@{ level = $lvl; env = $e; what = $what }) }
  foreach ($x in @(Test-PortClash)) { & $add 'FAIL' $x }
  foreach ($x in @(Get-LaneStandardRows $e) + @(Get-LaneWorktreeRows $e -Fix:$Fix)) { & $add $x.level $x.what }
  if ($c.sandbox) { & $add 'WARN' "envs.$e.sandbox: migration sandboxes are retired: remove the key" }
  foreach ($k in @('snapshot', 'restore', 'prune', 'keepDays', 'keep') | Where-Object { $null -ne (Get-KitMember $c.db $_) }) { & $add 'WARN' "envs.$e.db.$k : full-DB snapshots are retired (marks + restore + seed replace them): remove the key" }
  $dbDown = DbSvcDown $e   # a lane DB that starts with a lease: its checks wait for it
  if ($dbDown) { & $add OK "db service $((DbSvc $e).name) is down (it starts with a lease): db checks skipped" }
  elseif (Get-Command Get-DbMarkDoctor -ErrorAction SilentlyContinue) { foreach ($x in @(Get-DbMarkDoctor $e) + @(Get-DbTempDoctor $e) + @(if (Get-Command Get-DbExpectDoctor -ErrorAction SilentlyContinue) { Get-DbExpectDoctor $e }) + @(if (Get-Command Get-DbPoolDoctor -ErrorAction SilentlyContinue) { Get-DbPoolDoctor $e })) { & $add $x.level $x.what } }
  if ((MarksOn $e) -and -not $dbDown) {
    $st0 = Read-State $e; $b = @($st0.marks | Where-Object { $_ -and $_.kind -eq 'baseline' })[-1]
    if (-not $b) { & $add 'WARN' "no baseline mark: envy.ps1 seed -Env $e (a green seed marks baseline-<nnnn>)" }
    elseif ($st0.binlog.days -and ((Get-Date) - [datetime]$b.at).TotalDays -gt [double]$st0.binlog.days - 3) { & $add 'WARN' "baseline mark $($b.name) expires with the binlog ($($st0.binlog.days) d): seed -Env $e again" }   # TODO-PARAM (fixed default)
  }
  $f = if ($c.envFile) { [string]$c.envFile } else { Join-Path (Get-KitPath localenv-env) "$($c.group).env" }   # a lane's own file is optional
  if (-not (Test-Path -LiteralPath $f)) { & $add $(if ($c.envFile) { 'FAIL' } else { 'WARN' }) "env file $f is missing$(if (-not $c.envFile) { ' (secrets go there)' })" }
  $cmds = [ordered]@{}; $none = [pscustomobject]@{ port = '' }
  foreach ($p in @((Get-KitProps $c.db) | Where-Object { $_.Value -is [string] -and $_.Name -notmatch '^(_|engine$|name$|user$|host$|uri$|jdbc$|passwordEnv$|schemasQuery$|afterRevert$|flashbackExclude$|bin$)' -and $_.Value -ne 'liquibase' })) { $cmds["db.$($p.Name)"] = Expand-Placeholders $p.Value $e $none $KitConf.Workspace '' }
  foreach ($m in @($c.smoke | Where-Object { $_.cmd })) { $cmds["smoke '$($m.name)'"] = Expand-Placeholders ([string]$m.cmd) $e $none $KitConf.Workspace '' }
  foreach ($s in EnvServices $e) {
    if (($ce = Get-SvcConfigError $e $s)) { & $add 'FAIL' $ce; continue }
    $dir = try { SvcDir $e $s } catch { & $add 'FAIL' "$($s.name): $("$_".Split("`n")[0])"; continue }
    foreach ($k in 'start', 'build') { if ((Get-KitMember $s $k)) { $cmds["$($s.name).$k"] = Expand-Placeholders ([string](Get-KitMember $s $k)) $e $s $dir '' } }
    $v = try { EnvVars $e $s } catch { @{} }
    # a missing key starts a service that fails later (e.g. a 401); NAME=value pins a safety value (e.g. outbound calls to a closed port)
    foreach ($rk in @($s.requiredEnv | Where-Object { $_ })) {
      $rn, $rw = "$rk" -split '=', 2; $rg = "$($v[$rn])".Trim()
      if (-not $rg) { & $add 'FAIL' "$($s.name): requiredEnv $rn is not set (env file, envs.$e.env or the service's env)" }
      elseif ($null -ne $rw -and $rg -cne $rw) { & $add 'FAIL' "$($s.name): requiredEnv $rn must be '$rw' (envs.$e.env or localEnv.defaults.env)" }
    }
    $jh = if ($v.JAVA_HOME) { $v.JAVA_HOME } elseif ("$($s.start) $($s.build)" -match '\b(java|mvnw?|gradlew?)\b') { $env:JAVA_HOME } else { $null }
    if ($jh -and -not (Test-Path -LiteralPath (Join-Path $jh 'bin'))) { & $add 'FAIL' "$($s.name): JAVA_HOME $jh has no bin folder" }
    if ($s.reactor) { $rm = try { Get-ReactorModules $e $s } catch { $null }; if ($rm.skip.Count) { & $add 'WARN' "$($s.name).reactor: $($rm.skip -join ', ') not built (their parent is outside $($rm.me)'s chain: Maven default plugins); they come from the local repository" } }
    if ($s.unpack) { $uf = @(Read-KitLog env (Get-Date).AddDays(-7) | Where-Object { $_.env -eq $e -and $_.event -eq 'unpack-fallback' -and $_.service -eq $s.name }); if ($uf.Count) { & $add 'WARN' "$($s.name).unpack failed $($uf.Count)x in 7 d (the plain artifact was staged): $($uf[-1].why)" } }
    if ($s.classpathFile) {   # thin jar: start reads the release's argfile
      if ("$($s.start)" -notmatch '\{javaArgs\}') { & $add 'WARN' "$($s.name).classpathFile is set but start has no @`"{javaArgs}`"" }
      $ra = "$((Read-State $e).services[$s.name].artifact)"; if ($ra -and (Test-Path -LiteralPath $ra) -and -not (Test-Path -LiteralPath (JavaArgsFile $ra))) { & $add 'WARN' "$($s.name): the running release $(Split-Path $ra) has no java.args (staged before classpathFile): a restart fails until the next deploy" }
    }
    if ($s.artifact -and $s.repo) {
      if (-not (Test-Path -LiteralPath $dir)) { & $add 'WARN' "$($s.name): $dir does not exist yet (the first deploy / refresh creates it)" }
      elseif (-not $(if ($s.static) { Test-Path -LiteralPath (Join-Path $dir $s.static) -PathType Container } else { @(Get-ChildItem (Join-Path $dir $s.artifact) -File -ErrorAction SilentlyContinue).Count })) { & $add 'WARN' "$($s.name): nothing matches artifact $($s.artifact) in $dir yet (the next deploy / refresh builds it)" }
    }
    foreach ($u in @(@($s.health) + @($c.smoke | Where-Object { $_.url -and $_.service -eq $s.name } | ForEach-Object url) | Where-Object { $_ })) {
      if ("$u" -match '//localhost[:/]') { & $add 'WARN' "$($s.name): $u uses localhost: use http://127.0.0.1:{port} (localhost can resolve to ::1 first)" }
    }
    if (-not $s.port -or -not (Managed $s)) { continue }
    $pp = @(Get-PortPids ([int]$s.port)); if (-not $pp.Count) { continue }
    if (-not (Test-PortListening ([int]$s.port))) { & $add 'WARN' "$($s.name): port $($s.port) listens, but not on IPv4 (127.0.0.1 or the LAN address): bind 127.0.0.1 or 0.0.0.0"; continue }
    $x = (Read-State $e).services[$s.name]; $mine = if (Owned $x) { TreeIds ([int]$x.pid) } else { @() }
    $foreign = @($pp | Where-Object { $_ -notin $mine -and -not (EnvProcess $_ $e) })
    if ($foreign.Count) { & $add 'WARN' "$($s.name): port $($s.port) held by pid $($foreign -join ','), which the env did not start: a restart there fails" }
    if ($s.health -and -not (Healthy $e $s)) { & $add 'WARN' "$($s.name): $($s.health) does not answer (< 500) while the port is up" }
  }
  # a lane worktree not made yet (a service of a newly added repo): its start or deploy makes it, so its scripts only WARN
  $unmade = @(try { @((EnvRepos $e).Values | Where-Object { -not (Test-Path -LiteralPath "$($_.wt)/.git") } | ForEach-Object { [IO.Path]::GetFullPath($_.wt).TrimEnd('\', '/') }) } catch { @() })
  foreach ($k in $cmds.Keys) {
    foreach ($m in [regex]::Matches("$($cmds[$k])", '"([^"]+\.(?:ps1|py|sh|cmd|bat|mjs|js|exe))"|(?<![\w"''])((?:[A-Za-z]:[\\/]|/)[^\s"'']+\.(?:ps1|py|sh|cmd|bat|mjs|js|exe))(?=[\s"'']|$)')) {
      $path = @($m.Groups[1].Value, $m.Groups[2].Value | Where-Object { $_ })[0]
      if ($path -match '[{}]' -or -not [IO.Path]::IsPathRooted($path)) { continue }
      $full = [IO.Path]::GetFullPath($path); $inUnmade = @($unmade | Where-Object { $full.StartsWith("$_\", 'OrdinalIgnoreCase') -or $full.StartsWith("$_/", 'OrdinalIgnoreCase') }).Count
      if ($inUnmade -and -not (Test-Path -LiteralPath $path)) { & $add 'WARN' "${k}: script $path is in a lane worktree not made yet (the first start or deploy makes it; checked again then)" }
      elseif (-not (Test-Path -LiteralPath $path)) { & $add 'FAIL' "${k}: script $path does not exist" }
    }
  }
  @($r)
}
