#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (name order). Exit codes: none here (envy.ps1 verbs exit).
# Sections: L4 shared builds · L133 lane pick · L183 start room · L227 thin artifacts
# ---- shared builds: a lane stages a recorded copy of the same code + build config (reuseBuilds: own lane; shareBuild: any) or a
# crafty.ps1 check build of the same tree (shareCheckBuild); Build-Repo and Stage-Artifacts call these; Write-Reactor: the {reactor} build flags.
$script:BuildKeys = @{}; $script:SharedStage = @{}; $script:CheckBuild = @{}
# a crafty.ps1 check build of this code (env tree = the check's tree), service folder and -P / -D flags (-DskipTests aside), its
# jar unchanged since -> @{ path; t }. services[].shareCheckBuild: true on, false off; unset: on for a Maven package build without
# prepare (its edits are in an env build only) or build env vars
function Find-CheckBuild([string]$e, $s) {
  $on = $s.shareCheckBuild -eq $true -or ($null -eq $s.shareCheckBuild -and "$($s.build)" -match '\b(mvn|mvnw|mvnd)\b.*\bpackage\b' -and -not "$($s.prepare)" -and -not (Get-KitProps $s.env).Count)
  if (-not $on -or $s.static -or -not $s.artifact -or $s.classpathFile) { return $null }   # classpathFile: only an env build writes the classpath file
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt; if (-not $wt -or -not (Test-Path -LiteralPath (Join-Path $wt '.git'))) { return $null }
  $tree = "$(git -C $wt rev-parse 'HEAD^{tree}' 2>$null)".Trim(); if (-not $tree) { return $null }
  $rec = try { Get-Content -LiteralPath (Join-Path (Get-KitPath check-builds) "$tree.json") -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
  if ("$($rec.rel)".TrimEnd('/') -ne [IO.Path]::GetRelativePath($wt, (SvcDir $e $s)).Replace('\', '/').TrimEnd('/')) { return $null }
  $flags = { param($c) (@("$c" -split '\s+' | Where-Object { $_ -match '^-[PD]' -and $_ -notmatch '^-D(skipTests|maven\.test\.skip)\b' } | Sort-Object) -join ' ') }
  if ((& $flags $s.build) -ne (& $flags $rec.cmd)) { return $null }
  $excl = if ($s.artifactExclude) { [string]$s.artifactExclude } else { 'original|sources|javadoc|plain' }
  $f = Get-ChildItem (Join-Path $rec.dir $s.artifact) -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch $excl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f -and $f.LastWriteTime -ge [datetime]$rec.start -and $f.LastWriteTime -le ([datetime]$rec.at).AddSeconds(5)) { @{ path = $f.FullName; t = $f.LastWriteTimeUtc } }   # rebuilt since: not that build
}
function BuildKey([string]$e, $s) {
  $sb = $s.shareBuild -eq $true
  if (-not ($sb -or (Opt 'reuseBuilds' $false)) -or -not $s.build -or -not $s.repo -or -not ($s.artifact -or $s.static)) { return $null }
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt; if (-not $wt -or -not (Test-Path -LiteralPath (Join-Path $wt '.git'))) { return $null }
  $n = 0; while ($sb -and $n -lt 10 -and "$(git -C $wt log -1 --format=%s "HEAD~$n" 2>$null)" -like 'localenv prepare*') { $n++ }   # lane paths only ({cache}, {env}, {dir}, {wt})
  $tree = Get-InputsHash $wt "HEAD~$n" @(Get-SvcInputs $e $s); if (-not $tree) { return $null }
  $cfg = [ordered]@{ tree = $tree; dir = "$($s.dir)"; build = "$($s.build)"; artifact = "$($s.artifact)"; static = "$($s.static)"; unpack = "$($s.unpack)"; prepare = "$($s.prepare)"; reactor = @($s.reactor); env = $s.env }
  if (-not $sb) { $cfg.lane = $e }
  if ($s.classpathFile) { $cfg.classpathFile = "$($s.classpathFile)" }   # only when set: switched-off keys stay as they were
  (Get-KitHash ($cfg | ConvertTo-Json -Depth 8 -Compress) SHA1).ToLower()
}
# services[].inputs: repo paths whose content decides the build (+ root files, always); unset: a Maven module = the top folder
# of services[].dir + the in-repo modules it depends on, else the whole tree (other stacks' imports are not known). A change
# elsewhere neither builds nor restarts it
function Get-SvcInputs([string]$e, $s) {
  if ($s.inputs) { return @($s.inputs | ForEach-Object { $p = "$_".Replace('\', '/').Trim('/'); if ($p) { $p } else { '.' } }) }
  $rel = "$($s.dir)".Replace('\', '/').Trim('/'); $dir = SvcDir $e $s
  if (-not $rel -or $rel -eq '.' -or -not (Test-Path -LiteralPath (Join-Path $dir 'pom.xml')) -or -not ($me = Get-KitPomInfo (Join-Path $dir 'pom.xml'))) { return @('.') }
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt
  @(@(($rel -split '/')[0]) + @((Get-KitReactorNeeds $me (Get-KitReactorPoms $dir).all).Values | ForEach-Object { [IO.Path]::GetRelativePath($wt, $_.dir).Replace('\', '/') } | Where-Object { $_ -notmatch '^\.\.' }) | Select-Object -Unique)
}
# a hash of $paths at $rev (+ the root's files: build config, lock files); $null: no such commit
function Get-InputsHash([string]$wt, [string]$rev, [string[]]$paths) {
  $tree = "$(git -C $wt rev-parse -q --verify "$rev^{tree}" 2>$null)".Trim(); if (-not $tree) { return $null }
  if ('.' -in $paths) { return $tree }
  $ids = @($paths | Sort-Object -Unique | ForEach-Object { "$_=$("$(git -C $wt rev-parse -q --verify "${tree}:$_" 2>$null)".Trim())" })
  if (-not @($ids | Where-Object { $_ -notmatch '=$' }).Count) { Write-Warning "services[].inputs $($paths -join ', '): no such path at $rev - keyed by the whole tree"; return $tree }   # a typo never pins the key
  $parts = @($ids) + @(git -C $wt ls-tree $tree | Where-Object { $_ -match '^\d+ blob ' })
  (Get-KitHash ($parts -join "`n") SHA1).ToLower()
}
# the train's per-service skip: names of repo $rn's managed services whose live release was built from the same inputs + build
# config (BuildKey; reuseBuilds / shareBuild) and is still on disk; Run-Train skips the repo when that is all of them
function Get-SameInputs([string]$e, [string]$rn, $st) {
  foreach ($s in @(EnvServices $e | Where-Object { (Managed $_) -and $_.repo -and (RepoOf $e $_) -eq $rn })) {
    $live = "$($st.services[$s.name].artifact)"; if (-not (Test-ReleaseArtifact $s $live)) { continue }
    $k = try { BuildKey $e $s } catch { $null }; if (-not $k) { continue }
    if (@(@(if ($st.builds -is [hashtable]) { $st.builds[$s.name] }) | Where-Object { $_ -and $_.key -eq $k -and "$($_.path)" -eq $live }).Count) { $s.name }
  }
}
# -> @{ lane; dir; path } of a recorded copy with this key (this lane first), else nothing; never throws
function Find-SharedBuild([string]$e, $s, [string]$key) {
  foreach ($l in @($e; if ($s.shareBuild -eq $true) { LaneNames $e | Where-Object { $_ -ne $e } })) {
    try { $st = Read-State $l; $hit = @(@(if ($st.builds -is [hashtable]) { $st.builds[$s.name] }) | Where-Object { $_ -and $_.key -eq $key -and $_.path -and (Test-Path -LiteralPath "$($_.path)") })[-1] } catch { continue }
    if ($hit) { return @{ lane = $l; dir = "$($hit.dir)"; path = "$($hit.path)" } }
  }
  $null
}
# {reactor}: services[].reactor module globs built in one reactor with the service's module ('-f <aggregator> -pl <module> -am');
# only modules in its parent chain (others lack its pluginManagement: from the local repository, doctor lists them)
function Get-PomParents([string]$pom) {   # groupId:artifactId of each parent found on disk (relativePath, default ../pom.xml)
  for ($i = 0; $i -lt 8 -and (Test-Path -LiteralPath $pom); $i++) {
    $x = try { [xml](Get-Content -LiteralPath $pom -Raw) } catch { break }; $p = $x.project.parent; if (-not $p) { break }
    "$($p.groupId):$($p.artifactId)"
    $pom = Join-Path (Split-Path $pom) $(if ($p.relativePath) { [string]$p.relativePath } else { '../pom.xml' }); if (Test-Path -LiteralPath $pom -PathType Container) { $pom = Join-Path $pom 'pom.xml' }
  }
}
function Get-ReactorModules([string]$e, $s) {
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt; $me = ([IO.Path]::GetRelativePath($wt, (SvcDir $e $s))).Replace('\', '/')
  $chain = @(Get-PomParents (Join-Path $wt "$me/pom.xml")); $use = @(); $skip = @()
  foreach ($d in @($s.reactor | ForEach-Object { Get-ChildItem (Join-Path $wt $_) -Directory -ErrorAction SilentlyContinue } | Where-Object { Test-Path (Join-Path $_.FullName 'pom.xml') })) {
    $rel = [IO.Path]::GetRelativePath($wt, $d.FullName).Replace('\', '/'); $mp = @(Get-PomParents (Join-Path $d.FullName 'pom.xml'))[0]
    if ($mp -and $mp -in $chain) { $use += $rel } else { $skip += $rel }
  }
  [pscustomobject]@{ wt = $wt; me = $me; use = @(@($use) + $me | Select-Object -Unique); skip = @($skip) }
}
function Write-Reactor([string]$e, $s) {
  $rm = Get-ReactorModules $e $s
  if ($rm.skip.Count) { Write-Host "[$e] $($s.name) reactor: from the local repository, not built (parent outside $($rm.me)'s chain): $($rm.skip -join ', ')" }
  Write-ReactorPom $rm.wt $s.name $rm.me $rm.use
}
function Write-ReactorPom([string]$wt, [string]$name, [string]$me, [string[]]$mods) {
  $f = Join-Path $wt ".localenv-reactor-$name.xml"
  Set-Content -LiteralPath $f "<project xmlns=`"http://maven.apache.org/POM/4.0.0`"><modelVersion>4.0.0</modelVersion><groupId>localenv</groupId><artifactId>reactor-$name</artifactId><version>0</version><packaging>pom</packaging><modules>$(($mods | ForEach-Object { "<module>$_</module>" }) -join '')</modules></project>" -Encoding utf8
  "-f `"$f`" -pl $me -am"
}
# Add-ToolFlags, Get-KitReactorBetween: crafty adapters/container-tests.ps1
# the folder holding one of $marks, from $from up to the worktree $wt; else $null
function Find-MarkerDir([string]$wt, [string]$from, [string[]]$marks) {
  $top = $wt.TrimEnd('\', '/'); for ($d = $from.TrimEnd('\', '/'); $d -and $d.Length -ge $top.Length; $d = Split-Path $d) { if (@($marks | Where-Object { Test-Path -LiteralPath (Join-Path $d $_) -PathType Leaf }).Count) { return $d } }
  $null
}
# a build depending on an in-repo module that its layers change or that is newer than its local-repo artefact (the target
# moved past the installed jar, envfix-kestrel-2): Maven builds those (and the modules between) in one reactor with it
# (-f <aggregator> -pl <module> -am), Gradle adds each build the layers change (--include-build); never installed: the local
# repository is shared by every lane and agent (envfix-5). Empty: none such, or an own -pl / -f / --include-build
function Get-LayerReactorFlags([string]$e, $s, [string]$cmd) {
  if ($cmd -match '(^|\s)(-pl|--projects|-f|--file|--include-build)(\s|=|$)') { return '' }
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt; if (-not $wt -or -not (Test-Path -LiteralPath (Join-Path $wt '.git'))) { return '' }
  $n = 0; while ($n -lt 50 -and "$(git -C $wt log -1 --format=%s "HEAD~$n" 2>$null)" -like 'localenv *') { $n++ }   # layer merges + prepare commits on the target
  $changed = @(if ($n) { git -C $wt -c core.quotepath=off diff --name-only "HEAD~$n" HEAD 2>$null | Where-Object { $_ } | ForEach-Object { Split-Path (Join-Path $wt $_) } })
  $svc = (SvcDir $e $s).TrimEnd('\', '/')
  if ($cmd -match '\b(mvn|mvnw|mvnd)\b' -and (Test-Path -LiteralPath (Join-Path $svc 'pom.xml'))) {
    $mods = @{}; foreach ($d in @($changed | Select-Object -Unique)) { if (($md = Find-MarkerDir $wt $d 'pom.xml') -and $md -ne $svc -and ($p = Get-KitPomInfo (Join-Path $md 'pom.xml'))) { $mods[$p.key] = $p } }
    $all = (Get-KitReactorPoms $svc).all; foreach ($k in $mods.Keys) { if (-not $all[$k]) { $all[$k] = $mods[$k] } }   # a module no aggregator lists
    $need = Get-KitReactorNeeds (Get-KitPomInfo (Join-Path $svc 'pom.xml')) $all
    $stale = Get-KitReactorStale $need $wt; foreach ($k in $stale.Keys) { if (-not $mods[$k]) { $mods[$k] = $stale[$k] } }
    if (-not $mods.Count) { return '' }
    $use = @(Get-KitReactorBetween $need $mods | ForEach-Object { [IO.Path]::GetRelativePath($wt, $need[$_].dir).Replace('\', '/') } | Sort-Object)
    if (-not $use.Count) { return '' }
    $me = [IO.Path]::GetRelativePath($wt, $svc).Replace('\', '/')
    Write-Host "[$e] $($s.name): in-repo deps $($use -join ', ') (changed by its layers or newer than their local-repo jar): built in one reactor with it, not taken from the local repository"
    return Write-ReactorPom $wt $s.name $me @(@($use) + $me)
  }
  if ($cmd -match '\bgradlew?\b') {
    $sm = 'settings.gradle', 'settings.gradle.kts'; $sep = [IO.Path]::DirectorySeparatorChar
    $inc = @($changed | Select-Object -Unique | ForEach-Object { Find-MarkerDir $wt $_ $sm } | Where-Object { $_ -and -not "$svc$sep".StartsWith("$_$sep", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -Unique)   # the service's own build or one enclosing it: not included
    if ($inc.Count) { Write-Host "[$e] $($s.name): layers change build(s) $(@($inc | ForEach-Object { [IO.Path]::GetRelativePath($wt, $_) }) -join ', '): included (--include-build)"; return (@($inc | ForEach-Object { "--include-build `"$_`"" }) -join ' ') }
  }
  ''
}
# ---- lane pick: envy.ps1 calls Select-Lane at -Env <env> (K58 lane opening); Get-LaneLoad, Get-LanesOpen
# a lane's users: agents with a layer, lease, hold or open deploy there; services up; train running
function Get-LaneLoad([string]$n) {
  $st = Read-State $n
  $who = @(@($st.leases.Keys | ForEach-Object { if ($st.leases[$_].agent) { $st.leases[$_].agent } else { ($_ -split '/')[0] } }) + @($st.holds.Keys) + @($st.release.repos.Values | ForEach-Object { @($_.layers) } | Where-Object { $_ } | ForEach-Object agent) + @($st.requests | Where-Object { $_.kind -eq 'deploy' -and $_.status -in 'queued', 'in-train' } | ForEach-Object agent))
  $lessees = @($st.leases.Keys | ForEach-Object { if ($st.leases[$_].agent) { $st.leases[$_].agent } else { ($_ -split '/')[0] } } | Where-Object { $_ } | Select-Object -Unique)
  [pscustomobject]@{ env = $n; agents = @($who | Where-Object { $_ } | Select-Object -Unique); leased = $lessees; up = @($st.services.Values | Where-Object { $_.status -eq 'up' }).Count; train = [bool]$st.train }
}
# -Lane k; else the lane the agent already uses; else (deploy / use / task) the least busy warm lane (K58 below); $pinned: an agent's
# -Env <lane k> (no K58 pick). A deploy onto a lane another agent leases waits for that lease: any free lane instead (v2-wave1 JCF)
function Select-Lane([string]$e, [string]$agent, [int]$k, [string]$action, [string]$id, [string]$pinned = '') {
  $names = @(LaneNames $e)
  if ($k) { if ($k -gt $names.Count) { throw "-Lane ${k}: $($names[0]) has $($names.Count) lane(s) (localEnv.envs.$($names[0]).lanes.max)" }; return $names[$k - 1] }
  $loads = @($names | ForEach-Object { Get-LaneLoad $_ })
  if ($id) { foreach ($n in $names) { if (@((Read-State $n).requests | Where-Object id -eq $id).Count) { return $n } } }   # wait -Id: the lane holding that request
  $mine = @($loads | Where-Object { $agent -in $_.agents -and (-not $pinned -or $_.env -eq $pinned) })[0]; if ($mine) { return $mine.env }   # a named lane: never another
  if ($action -notin 'deploy', 'use', 'task') { return $(if ($pinned) { $pinned } else { $e }) }
  # K58 (owner 2026-11-17): a warm lane (services up or a train) first, even shared; a cold one only past the queue wait
  # localEnv.lanes.openAfterMinutes (learned) with room for all its services; a person opens one with -Env <lane> / -Lane k
  $room = (Get-GateAvailGB (Get-SysMem)) - (KeepFreeGB)
  $fits = { param($n) (@(EnvServices $n | Where-Object { Managed $_ } | ForEach-Object { Need-GB $n $_ }) | Measure-Object -Sum).Sum -le $room }
  $warm = @($loads | Where-Object { $_.up -or $_.train }); if (-not $warm.Count) { $warm = @($loads[0]) }   # all cold: lane 1
  $best = if ($pinned) { @($loads | Where-Object env -eq $pinned)[0] } else { @($warm | Sort-Object @{ Expression = { $_.agents.Count + [int]$_.train } }, @{ Expression = { $_.up }; Descending = $true }, @{ Expression = { [array]::IndexOf($names, $_.env) } })[0] }
  $why = if ($pinned) { 'the lane -Env names' } else { 'warm lane, free' }
  $taken = @($best.leased | Where-Object { $_ -ne $agent })
  if ($pinned -and -not ($action -eq 'deploy' -and $taken.Count)) { return $pinned }   # no pick: the K58 lanePick reason stays
  $free = @($loads | Where-Object { -not @($_.leased | Where-Object { $_ -ne $agent }).Count -and -not $_.train -and ($_.up -or (& $fits $_.env)) } | Sort-Object @{ Expression = { $agent -in $_.agents }; Descending = $true }, @{ Expression = { $_.up -gt 0 }; Descending = $true }, @{ Expression = { $_.agents.Count } }, @{ Expression = { [array]::IndexOf($names, $_.env) } })   # K58: warm first
  if ($action -eq 'deploy' -and $taken.Count -and $free.Count) { $why = "$($best.env) leased by $($taken -join ', '): a free lane instead of waiting for that lease$(if ($pinned) { "; later calls: -Env $($free[0].env)" })"; $best = $free[0] }
  elseif ($pinned) { }
  elseif ($best.agents.Count + [int]$best.train) {
    $wait = [int](@($warm | ForEach-Object { Get-LaneWaitMin $_.env }) | Measure-Object -Minimum).Minimum; $after = [double](Get-KitParam 'localEnv.lanes.openAfterMinutes')
    $cold = @($loads | Where-Object { $_.env -notin $warm.env -and (& $fits $_.env) })[0]
    $why = if ($wait -lt $after) { "warm lanes busy, shared: queue wait $wait min < lanes.openAfterMinutes $after" } elseif (-not $cold) { "warm lanes busy, shared: queue wait $wait min, no cold lane with room" } else { "cold lane opened: warm lanes busy, queue wait $wait min >= lanes.openAfterMinutes $after" }
    if ($cold -and $wait -ge $after) { $best = $cold }
  }
  Update-State $names[0] { param($x) $x.lanePick = @{ at = (Now); env = $best.env; agent = $agent; why = $why } }
  Write-Host "[$($best.env)] lane $([array]::IndexOf($names, $best.env) + 1) of $($names[0]): $why ($(($loads | ForEach-Object { "$($_.env) $($_.agents.Count) agent(s)$(if (-not ($_.up -or $_.train)) { ' cold' })" }) -join ', ')); later calls with -Env $($names[0]) stay on it"
  $best.env
}
# a lane's queue wait: minutes its oldest queued request has waited (0: none; a running train alone is no wait, as the learned obs)
function Get-LaneWaitMin([string]$n) {
  $st = Read-State $n; $ats = @($st.requests | Where-Object { $_.status -eq 'queued' -and $_.at } | ForEach-Object at)
  [int](@($ats | ForEach-Object { ((Get-Date) - [datetime]$_).TotalMinutes }) + 0 | Measure-Object -Maximum).Maximum
}
# lanes open N of M (why): open = services up or a train; why = the last pick (Select-Lane)
function Get-LanesOpen([string]$e) {
  $names = @(LaneNames $e); if ($names.Count -lt 2) { return $null }
  $open = @($names | Where-Object { $l = Get-LaneLoad $_; $l.up -or $l.train }); $p = (Read-State $names[0]).lanePick
  [pscustomobject]@{ open = $open.Count; of = $names.Count; lanes = $open; why = $(if ($p) { "$(([datetime]$p.at).ToString('HH:mm')) $($p.agent) -> $($p.env): $($p.why)" } else { 'no pick yet' }) }
}
# ---- start room: a start waits for RAM (keep-free) and, past cpuMaxPct, its turn in the machine-wide CPU queue (envy.ps1 Start-Svc)
# a start's predicted cost: its slowest measured start (s), 120 until one is measured
function StartCostSec([string]$e, $s) { $xs = @((Get-LocalEnvHistory)["$e/$($s.name)/startSec"] | Where-Object { $_ }); if ($xs.Count) { [double]($xs | Measure-Object -Maximum).Maximum } else { 120.0 } }
# CPU queue (machine-wide, one ticket per start waiting for CPU): shortest predicted start first, each waited second takes one
# second off (aging: a big start never starves); only the head may start on a busy CPU
function StartQueueDir { $d = Join-Path (Get-KitPath localenv -Create) 'start-queue'; New-Item -ItemType Directory -Force $d | Out-Null; $d }
function Get-StartQueueHead {
  $now = Get-Date
  $ts = @(Get-ChildItem (StartQueueDir) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } } | Where-Object { $_ -and (Test-KitPid $_.pid $_.pstart) })
  @($ts | Sort-Object @{ e = { [double]$_.cost - ($now - [datetime]$_.since).TotalSeconds } }, @{ e = { [datetime]$_.since } })[0]
}
function Wait-Room([string]$e, $s) {
  $need = Need-GB $e $s; $keep = KeepFreeGB; $cost = StartCostSec $e $s; $small = $cost -le [double](Get-KitParam 'localEnv.cpuSmallStartSec')
  $t0 = Get-Date; $until = $t0.AddMinutes($script:RoomWaitMin); $said = $t0.AddMinutes(-5); $marked = $false; $roomOk = $false; $cpu0 = $null; $tk = $null; $by = 'room'
  try {
    while ($true) {
      $m = Get-SysMem; $cpu = if ($small) { 0 } else { Get-SysCpu }; $avail = Get-GateAvailGB $m   # a small start (localEnv.cpuSmallStartSec) never waits for CPU
      $ramOk = Test-GateStart ($avail - $need) $keep ((Get-Date) - $t0).TotalMinutes $m.TotalGB; $cpuOk = $cpu -lt $script:CpuMax
      if ($ramOk -and $cpuOk) { $roomOk = $true; return }
      $for = if ($ramOk) { 'CPU' } else { 'RAM' }
      if ($ramOk) { if (-not $cpu0) { $cpu0 = Get-Date } } else { $cpu0 = $null }   # CPU only delays: cpuWaitMinutes of busy CPU in a row, then it starts
      if (-not $cpu0 -and $tk) { Remove-Item -LiteralPath $tk -Force -ErrorAction SilentlyContinue; $tk = $null }   # waiting for RAM: out of the CPU queue
      if ($cpu0 -and -not $tk) { $tk = Join-Path (StartQueueDir) "$PID-$($s.name).json"; Write-KitAtomic $tk (@{ pid = $PID; pstart = "$(Get-KitPidStart $PID)"; env = $e; service = $s.name; cost = $cost; since = (Get-KitStamp stored $cpu0) } | ConvertTo-Json -Compress) }
      $head = if ($tk) { Get-StartQueueHead }; $mine = -not $head -or ("$($head.pid)" -eq "$PID" -and $head.service -eq $s.name)
      $lastF = Join-Path (StartQueueDir) 'last.admit'; $last = try { Get-Content -LiteralPath $lastF -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
      $spaced = -not $last -or ((Get-Date) - [datetime]$last.at).TotalSeconds -ge [math]::Min(60.0, [double]$last.cost)   # busy CPU: one big start at a time
      if ($cpu0 -and $mine -and $spaced -and ((Get-Date) - $cpu0).TotalMinutes -ge $script:CpuWaitMin) {
        Write-KitAtomic $lastF (@{ at = (Get-KitStamp stored (Get-Date)); cost = $cost } | ConvertTo-Json -Compress)
        "$(Get-Date -Format 'HH:mm:ss') [$e] CPU $cpu% for $($script:CpuWaitMin) min (localEnv.cpuWaitMinutes), first in the CPU queue (start ~$([int]$cost) s): starting $($s.name) anyway"; $roomOk = $true; $by = 'cpu-queue'; return }
      $eta = if ($cpu0) { $cpu0.AddMinutes($script:CpuWaitMin) } else { $until }
      if ($marked -ne $for) { Update-State $e { param($x) $v = $x.services[$s.name]; $v.status = 'waiting'; $v.waitFor = $for; $v.waitPid = $PID; $v.waitStart = Get-KitPidStart $PID; $v.waitSince = (Get-KitStamp stored $t0); $v.waitUntil = (Get-KitStamp stored $eta) }; $marked = $for }
      if (-not $ramOk -and (Get-Date) -gt $until) {
        $top = Get-SysProcs -NoCommandLine | Group-Object Name | ForEach-Object { [pscustomobject]@{ n = $_.Name; gb = [math]::Round(($_.Group | Measure-Object WorkingSet -Sum).Sum / 1GB, 1) } } | Sort-Object gb -Descending | Select-Object -First 6
        Update-State $e { param($x) $x.services[$s.name].status = 'failed'; $x.services[$s.name].why = 'no room to start' }; $marked = ''
        throw "[$e] no room to start $($s.name) after $($script:RoomWaitMin) min: needs $need GB + keep-free $keep GB, available $avail GB. Biggest: $(($top | ForEach-Object { "$($_.n) $($_.gb)G" }) -join ', ')"
      }
      if (((Get-Date) - $said).TotalSeconds -ge 60) { "$(Get-Date -Format 'HH:mm:ss') [$e] waiting for $for to start $($s.name): RAM avail $avail GB (need $need + keep $keep; after 20 min a 5% floor), CPU $cpu% (max $($script:CpuMax)%); $(if ($cpu0 -and -not $mine) { "behind $($head.env)/$($head.service) in the CPU queue" } elseif ($cpu0) { 'starts' } else { 'gives up' }) by $($eta.ToString('HH:mm'))"; $said = Get-Date }
      Start-Sleep 10
    }
  } finally {
    if ($tk) { Remove-Item -LiteralPath $tk -Force -ErrorAction SilentlyContinue }
    $ws = [int]((Get-Date) - $t0).TotalSeconds; if ($ws -ge 10) { Event $e 'start-wait' @{ service = $s.name; sec = $ws; for = $(if ($cpu0) { 'CPU' } else { 'RAM' }); cost = [int]$cost; started = $roomOk; by = $by } }   # wait per start, timestamped (kitlog at)
    if ($marked) { Update-State $e { param($x) $v = $x.services[$s.name]; if ($v.status -eq 'waiting') { if ($roomOk) { $v.waitFor = 'lock' } else { $v.status = 'down' } } } } }   # room got: still claimed while it waits for the start lock
}
# ---- thin artifacts: services[].classpathFile, a thin artifact + the build's classpath file -> <release>/classpath.txt and java.args (-cp "<artifact>;<libraries>"),
# so a restart or rollback starts what that release built; libraries stay in the Maven local repository, the repo's own module jars are copied
function JavaArgsFile([string]$artifact) { if ($artifact) { Join-Path $(if (Test-Path -LiteralPath $artifact -PathType Container) { $artifact } else { Split-Path $artifact }) 'java.args' } }
# a live release the train can keep: its artifact, and with classpathFile its java.args (one staged before the switch is rebuilt: a restart fails)
function Test-ReleaseArtifact($s, [string]$a) { [bool]($a -and (Test-Path -LiteralPath $a) -and -not ($s.classpathFile -and -not (Test-Path -LiteralPath (JavaArgsFile $a)))) }
function Write-JavaArgs([string]$e, $s, [string]$from, [string]$to, [string]$art) {
  $cpf = Join-Path $to 'classpath.txt'
  if ($from) {   # a shared stage brings the other lane's classpath.txt; java.args is always rewritten for this release's artifact
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "[$e] $($s.name): no classpath file $from after the build (services[].classpathFile: the build writes it, e.g. Maven dependency:build-classpath -Dmdep.outputFile=$($s.classpathFile))" }
    $wt = if ($s.repo) { (EnvRepos $e)[(RepoOf $e $s)].wt } else { '' }; $libDir = Join-Path $to 'lib'
    $entries = foreach ($p in @((Get-Content -LiteralPath $from -Raw).Trim() -split [regex]::Escape([IO.Path]::PathSeparator) | Where-Object { $_ })) {
      $rel = if ($wt) { [IO.Path]::GetRelativePath($wt, $p) } else { '..' }
      if (-not ($rel -match '^\.\.' -or [IO.Path]::IsPathRooted($rel))) {   # a reactor module's jar in the worktree: the next build rewrites (or cannot, while locked) it
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "[$e] $($s.name): classpath entry $p is not a jar (build to package so modules resolve to their jars)" }
        $null = New-Item -ItemType Directory -Force $libDir; Copy-Item -LiteralPath $p $libDir -Force; "lib/$(Split-Path $p -Leaf)"
      } else { $p }
    }
    Remove-Item -LiteralPath $cpf -Force -ErrorAction SilentlyContinue; Set-Content -LiteralPath $cpf (@($entries) -join [IO.Path]::PathSeparator) -NoNewline -Encoding utf8NoBOM
  } elseif (-not (Test-Path -LiteralPath $cpf)) { throw "[$e] $($s.name): the shared release has no classpath.txt (staged before services[].classpathFile was set): deploy again" }
  $cp = (@($art) + @((Get-Content -LiteralPath $cpf -Raw).Trim() -split [regex]::Escape([IO.Path]::PathSeparator) | Where-Object { $_ } | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $to $_ } }) | ForEach-Object { $_.Replace('\', '/') }) -join [IO.Path]::PathSeparator
  $ja = JavaArgsFile $art; Remove-Item -LiteralPath $ja -Force -ErrorAction SilentlyContinue   # a hard link from a shared stage is never written in place
  Set-Content -LiteralPath $ja "-cp `"$cp`"" -NoNewline -Encoding utf8NoBOM   # java @argfile: quoted, forward slashes (a backslash escapes in quotes)
}
function ReleaseDirOf([string]$root, [string]$art) { if (-not $art) { return $null }; $rel = [IO.Path]::GetRelativePath($root, $art); if ($rel -match '^\.\.') { return $null }; Join-Path $root (($rel -split '[\\/]')[0]) }
# -> the release folders past keepReleases that no service runs from (removed; -DryRun: listed only)
function Remove-OldReleases([string]$e, $s, [string]$root, [switch]$DryRun) {
  $inUse = @((Read-State $e).services.Values | ForEach-Object { ReleaseDirOf $root "$($_.artifact)" } | Where-Object { $_ })
  $old = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -notlike '_*' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:KeepReleases | Where-Object { $_.FullName -notin $inUse })
  if ($DryRun) { return @($old.FullName) }
  $old | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; @($old.FullName)
  $store = Join-Path $root '_lib'; if (-not (Test-Path -LiteralPath $store)) { return }
  $refs = @{}; foreach ($m in Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -notlike '_*' | ForEach-Object { Join-Path $_.FullName '.libs.json' } | Where-Object { Test-Path -LiteralPath $_ }) { foreach ($p in (Get-KitProps (Get-Content -LiteralPath $m -Raw | ConvertFrom-Json))) { $refs["$($p.Value)"] = $true } }
  Get-ChildItem -LiteralPath $store -File | Where-Object { -not $refs[$_.BaseName] } | Remove-Item -Force -ErrorAction SilentlyContinue   # no release links it
}
# no agent owns a lane build: that agent's release killed train builds (2026-11-25)
function LaneEnv([string]$e, $item) { $v = EnvVars $e $item; $v.CLAUDE_AGENT = ''; $v }
# a build the kit stopped (release, PAUSE) blames no layer: new layers and drops fail with "deploy again", the live release stays
function Set-KilledBuild([string]$why, $kept, [scriptblock]$isNew, $reqs, $cur, [string]$rn, $results) {
  $m = "${why}: not your branch, deploy again"
  foreach ($l in @($kept | Where-Object { & $isNew $_ })) { if ($l.request) { $results[$l.request] = @{ outcome = 'failed'; message = $m } } }
  foreach ($q in @($reqs | Where-Object { $_.kind -eq 'drop' -and @($cur[$rn].branch) -contains $_.branch })) { $results[$q.id] = @{ outcome = 'failed'; message = $m } }
}
