#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (name order). Exit codes: none here (envy.ps1 verbs exit).
# shared builds: a lane stages a recorded copy of the same code + build config (reuseBuilds: own lane; shareBuild: any) or a
# crafty.ps1 check build of the same tree (shareCheckBuild); Build-Repo and Stage-Artifacts call these.
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
