#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (name order). Exit codes: none here (envy.ps1 verbs exit).
# Sections: L4 shared builds · L67 lane pick · L110 thin artifacts
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
  $tree = "$(git -C $wt rev-parse "HEAD~$n^{tree}" 2>$null)".Trim(); if ($LASTEXITCODE -or -not $tree) { return $null }
  $cfg = [ordered]@{ tree = $tree; dir = "$($s.dir)"; build = "$($s.build)"; artifact = "$($s.artifact)"; static = "$($s.static)"; unpack = "$($s.unpack)"; prepare = "$($s.prepare)"; reactor = @($s.reactor); env = $s.env }
  if (-not $sb) { $cfg.lane = $e }
  if ($s.classpathFile) { $cfg.classpathFile = "$($s.classpathFile)" }   # only when set: switched-off keys stay as they were
  (Get-KitHash ($cfg | ConvertTo-Json -Depth 8 -Compress) SHA1).ToLower()
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
  $rm = Get-ReactorModules $e $s; $wt = $rm.wt; $me = $rm.me; $mods = $rm.use
  if ($rm.skip.Count) { Write-Host "[$e] $($s.name) reactor: from the local repository, not built (parent outside $me's chain): $($rm.skip -join ', ')" }
  $f = Join-Path $wt ".localenv-reactor-$($s.name).xml"
  Set-Content -LiteralPath $f "<project xmlns=`"http://maven.apache.org/POM/4.0.0`"><modelVersion>4.0.0</modelVersion><groupId>localenv</groupId><artifactId>reactor-$($s.name)</artifactId><version>0</version><packaging>pom</packaging><modules>$(($mods | ForEach-Object { "<module>$_</module>" }) -join '')</modules></project>" -Encoding utf8
  "-f `"$f`" -pl $me -am"
}
# ---- lane pick: envy.ps1 calls Select-Lane at -Env <env> (K58 lane opening); Get-LaneLoad, Get-LanesOpen
# a lane's users: agents with a layer, lease, hold or open deploy there; services up; train running
function Get-LaneLoad([string]$n) {
  $st = Read-State $n
  $who = @(@($st.leases.Keys | ForEach-Object { if ($st.leases[$_].agent) { $st.leases[$_].agent } else { ($_ -split '/')[0] } }) + @($st.holds.Keys) + @($st.release.repos.Values | ForEach-Object { @($_.layers) } | Where-Object { $_ } | ForEach-Object agent) + @($st.requests | Where-Object { $_.kind -eq 'deploy' -and $_.status -in 'queued', 'in-train' } | ForEach-Object agent))
  [pscustomobject]@{ env = $n; agents = @($who | Where-Object { $_ } | Select-Object -Unique); up = @($st.services.Values | Where-Object { $_.status -eq 'up' }).Count; train = [bool]$st.train }
}
# -Lane k; else the lane the agent already uses; else (deploy / use / task) the least busy warm lane (K58 below)
function Select-Lane([string]$e, [string]$agent, [int]$k, [string]$action, [string]$id) {
  $names = @(LaneNames $e)
  if ($k) { if ($k -gt $names.Count) { throw "-Lane ${k}: $($names[0]) has $($names.Count) lane(s) (localEnv.envs.$($names[0]).lanes.max)" }; return $names[$k - 1] }
  $loads = @($names | ForEach-Object { Get-LaneLoad $_ })
  if ($id) { foreach ($n in $names) { if (@((Read-State $n).requests | Where-Object id -eq $id).Count) { return $n } } }   # wait -Id: the lane holding that request
  $mine = @($loads | Where-Object { $agent -in $_.agents })[0]; if ($mine) { return $mine.env }
  if ($action -notin 'deploy', 'use', 'task') { return $e }
  # K58 (owner 2026-11-17): a warm lane (services up or a train) first, even shared; a cold one only past the queue wait
  # localEnv.lanes.openAfterMinutes (learned) with room for all its services; a person opens one with -Env <lane> / -Lane k
  $room = (Get-GateAvailGB (Get-SysMem)) - (KeepFreeGB)
  $fits = { param($n) (@(EnvServices $n | Where-Object { Managed $_ } | ForEach-Object { Need-GB $n $_ }) | Measure-Object -Sum).Sum -le $room }
  $warm = @($loads | Where-Object { $_.up -or $_.train }); if (-not $warm.Count) { $warm = @($loads[0]) }   # all cold: lane 1
  $best = @($warm | Sort-Object @{ Expression = { $_.agents.Count + [int]$_.train } }, @{ Expression = { $_.up }; Descending = $true }, @{ Expression = { [array]::IndexOf($names, $_.env) } })[0]
  $why = 'warm lane, free'
  if ($best.agents.Count + [int]$best.train) {
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
