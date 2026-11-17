#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (name order). Exit codes: none here (envy.ps1 verbs exit).
# shared builds: a lane stages a recorded copy of the same code + build config (reuseBuilds: own lane; shareBuild: any) or a
# crafty.ps1 check build of the same tree (shareCheckBuild); Build-Repo and Stage-Artifacts call these; Write-Reactor: the {reactor} build flags.
$script:BuildKeys = @{}; $script:SharedStage = @{}; $script:CheckBuild = @{}
# a crafty.ps1 check build of this code (env tree = the check's tree), service folder and -P / -D flags (-DskipTests aside), its
# jar unchanged since -> @{ path; t }. services[].shareCheckBuild: true on, false off; unset: on for a Maven package build without
# prepare (its edits are in an env build only) or build env vars
function Find-CheckBuild([string]$e, $s) {
  $on = $s.shareCheckBuild -eq $true -or ($null -eq $s.shareCheckBuild -and "$($s.build)" -match '\b(mvn|mvnw|mvnd)\b.*\bpackage\b' -and -not "$($s.prepare)" -and -not (Get-KitProps $s.env).Count)
  if (-not $on -or $s.static -or -not $s.artifact) { return $null }
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
