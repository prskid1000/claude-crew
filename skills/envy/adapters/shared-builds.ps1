#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (name order). Exit codes: none here (envy.ps1 verbs exit).
# Sections: L5 shared builds · L145 java incremental · L313 lane pick · L363 start room · L407 thin artifacts ·
#   L449 lane priority · L509 static server
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
# envy seed: a failed create while a started managed service is not healthy (a deploy restarting it: HTTP 000) -> the hint, else ''
function Get-SeedDownHint([string]$e) {
  $st = Read-State $e; $down = @(EnvServices $e | Where-Object { (Managed $_) -and "$($st.services["$($_.name)"].status)" -notin '', 'down', 'stopped' -and -not (Healthy $e $_) } | ForEach-Object { "$($_.name)" })
  if ($down.Count) { "; $($down -join ', ') not up yet ($(@($down | ForEach-Object { "$($st.services[$_].status)" }) -join ', ')): re-run seed when envy.ps1 status shows it up" } else { '' }
}
# warm lane (owner 2026-11-25): the live target commit a train keeps a repo on (a release exists, its wanted layers = the live
# ones, no refresh in the train): a target move alone rebuilds nothing; else '' (Sync-Repo takes origin/<target>)
function Get-TrainPinBase($st, [string]$rn, [string[]]$wantKeys, [string[]]$liveKeys, [string[]]$kinds) {
  $lv = $st.release.repos[$rn]
  if ([int]$st.release.n -gt 0 -and $lv.targetSha -and 'refresh' -notin $kinds -and (@($wantKeys) -join '|') -eq (@($liveKeys) -join '|')) { "$($lv.targetSha)" } else { '' }
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
# ---- java incremental: services[].javaIncremental (true | { fullEvery, fullWhen, alwaysWith, maxFiles, mergeIndex }; reference.md): a
# Maven build compiles only the sources changed since its last good build plus their dependants (useIncrementalCompilation=false);
# Build-Repo runs Get-JavaIncPlan, then Step-JavaInc after each run (next: the full fallback or the verify build); Get-BuildWrites
function Get-JavaIncOpts($s) {
  $o = if ($s.javaIncremental -is [bool]) { $null } else { $s.javaIncremental }
  @{ fullEvery = [int]$(if ($o.fullEvery) { $o.fullEvery } else { 10 }); maxFiles = [int]$(if ($o.maxFiles) { $o.maxFiles } else { 2000 }); fullWhen = [string]$o.fullWhen
    alwaysWith = [string]$(if ($null -ne $o.alwaysWith) { $o.alwaysWith } else { '@Mapper([^A-Za-z0-9_]|$)' })   # git grep -E; generated from types they never name (nested mappings)
    mergeIndex = [string]$(if ($null -ne $o.mergeIndex) { $o.mergeIndex } else { 'entity/index' }) }   # an aggregating processor's index (JPA entities, enum values)
}
# @{ mode incremental | verify | full; cmd; base; why; head; n; touched } or $null (off, not Maven); full: no baseline, a pom,
# a deleted or other-module source, too many files, or a compile set matching fullWhen
function Get-JavaIncPlan([string]$e, $s, [string]$dir, [string]$cmd) {
  if (-not $s.javaIncremental -or $cmd -notmatch '\b(mvn|mvnw|mvnd)\b' -or -not (Test-Path -LiteralPath (Join-Path $dir 'pom.xml'))) { return $null }
  $o = Get-JavaIncOpts $s; $wt = (EnvRepos $e)[(RepoOf $e $s)].wt; $rec = Get-KitMember (Read-State $e).javaInc $s.name
  $rel = [IO.Path]::GetRelativePath($wt, $dir).Replace('\', '/'); $src = if ($rel -eq '.') { 'src/main/java' } else { "$rel/src/main/java" }
  $p = @{ base = $cmd; cmd = $cmd; mode = 'full'; why = ''; head = "$(git -C $wt rev-parse HEAD 2>$null)".Trim(); n = [int]$rec.n; phase = 1; dir = $dir; wt = $wt; src = $src; touched = 0 }
  $full = { param($why) $p.mode = 'full'; $p.cmd = $cmd; $p.why = $why; Reset-JavaIncStatus $dir; $p }
  $cls = Join-Path $dir 'target/classes'
  if (Test-Path -LiteralPath (Join-Path $dir 'target/javainc-full.pending')) { return (& $full 'last full run unfinished') }   # killed or failed after its clean
  if (-not $rec.sha -or -not (Test-Path -LiteralPath $cls) -or -not @([IO.Directory]::EnumerateFiles($cls, '*.class', [IO.SearchOption]::AllDirectories) | Select-Object -First 1).Count) { return (& $full 'no baseline build') }   # a cleaned full run that never finished: none
  $null = git -C $wt cat-file -e "$($rec.sha)^{commit}" 2>$null; if ($LASTEXITCODE) { return (& $full 'baseline commit gone') }
  if ($rec.deps -and $rec.deps -ne (Get-JavaDepsPrint $e $s $wt)) { return (& $full 'a dependency jar changed') }   # stale mode skips Maven's own dependency check
  $java = @(); $gone = @()
  foreach ($row in @(git -C $wt -c core.quotepath=off diff --name-status --no-renames $rec.sha 2>$null | Where-Object { $_ })) {
    $how, $f = $row -split "`t", 2
    if ($f -match '(^|/)src/test/') { continue }
    if ($f -match '(^|/)(pom\.xml|lombok\.config|\.mvn/.+|src/main/(?!resources/|java/).+)$') { return (& $full "build input changed: $f") }   # .proto and other generated-source inputs
    if ($f -notmatch '\.java$') { continue }
    if (-not $f.StartsWith("$src/")) { return (& $full "source outside the module: $f") }
    if ($how -eq 'D') { $gone += $f } else { $java += $f }
  }
  foreach ($f in @($rec.dirty | Where-Object { $_ -and $_ -notin $java })) { if (Test-Path -LiteralPath (Join-Path $wt $f)) { $java += $f } else { $gone += $f } }   # last build's uncommitted edits (maybe reverted)
  if ($gone.Count) { Remove-JavaClasses $wt $dir $src $gone -Generated; return (& $full "$($gone.Count) deleted source(s)") }
  $p.mode = if ($p.n + 1 -ge $o.fullEvery) { 'verify' } else { 'incremental' }
  $p.cmd = Add-ToolFlags $cmd '-Dmaven.compiler.useIncrementalCompilation=false'
  if (-not $java.Count) { $p.why = 'no main source changed'; return $p }
  $set = @(Get-JavaDependants $wt $src $java $o.alwaysWith $cls)
  if ($set.Count -gt $o.maxFiles) { return (& $full "$($set.Count) sources to compile (maxFiles $($o.maxFiles))") }
  $hit = @(if ($o.fullWhen) { $set | Where-Object { [regex]::IsMatch([IO.File]::ReadAllText((Join-Path $wt $_)), $o.fullWhen) } | Select-Object -First 1 })
  if ($hit.Count) { return (& $full "fullWhen matches $($hit[0])") }
  Remove-JavaClasses $wt $dir $src $java
  if ($o.mergeIndex) { $p.idx = Join-Path $dir "target/generated-sources/annotations/$($o.mergeIndex)"; $p.snap = Get-JavaIndexSnap $p.idx; $p.fqns = @($set | ForEach-Object { $_.Substring($src.Length + 1) -replace '\.java$' -replace '/', '.' }) }
  $now = [datetime]::UtcNow; foreach ($f in $set) { [IO.File]::SetLastWriteTimeUtc((Join-Path $wt $f), $now) }   # stale = newer than its class
  $p.touched = $set.Count; $p.why = "$($java.Count) changed, $($set.Count) compiled"; $p
}
# file name -> @{ text; t } of an index folder
function Get-JavaIndexSnap([string]$root) {
  $h = @{}; if (Test-Path -LiteralPath $root) { foreach ($fi in [IO.DirectoryInfo]::new($root).EnumerateFiles()) { $h[$fi.Name] = @{ text = [IO.File]::ReadAllText($fi.FullName); t = $fi.LastWriteTimeUtc } } }
  $h
}
# the processor wrote only what this compile saw: a '.<value>' file (types holding that enum value) = what it wrote + the old types
# it did not see (a seen type's old entry it did not write: that value is gone); an entity file (one class) not rewritten whose class
# was compiled: that entity name is gone. Exact for the Hibernate processor's entity index (verify builds compare it)
function Merge-JavaIndex($p) {
  if (-not $p.idx -or -not (Test-Path -LiteralPath $p.idx)) { return }
  $now = Get-JavaIndexSnap $p.idx; $tok = { param($t) @("$t" -split '\s+' | Where-Object { $_ }) }
  $wrote = @($now.Keys | Where-Object { -not $p.snap[$_] -or $p.snap[$_].t -ne $now[$_].t })
  $seen = [Collections.Generic.HashSet[string]]::new([string[]]@($wrote | Where-Object { $_.StartsWith('.') } | ForEach-Object { & $tok $now[$_].text }))
  foreach ($name in @($p.snap.Keys)) {
    $f = Join-Path $p.idx $name; $old = $p.snap[$name].text
    if ($name.StartsWith('.')) {
      $keep = @(@(& $tok $old | Where-Object { -not $seen.Contains($_) }) + @(if ($name -in $wrote) { & $tok $now[$name].text }) | Select-Object -Unique)
      $txt = (@([Linq.Enumerable]::OrderBy([string[]]$keep, [Func[string, string]] { $args[0] }, [StringComparer]::Ordinal)) | ForEach-Object { "$_ " }) -join ''
      if (-not $keep.Count) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } elseif ($txt -ne "$($now[$name].text)") { [IO.File]::WriteAllText($f, $txt) }
    } elseif ($name -notin $wrote -and "$old".Trim() -in $p.fqns) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  }
}
# worktree paths of the changed sources + every source naming one of them, a subclass of one (transitively) or its metamodel
# (<Name>_) + every source whose last classes reference one (a chained call or var names its owner only in bytecode) + alwaysWith
function Get-JavaDependants([string]$wt, [string]$src, [string[]]$changed, [string]$always, [string]$cls) {
  $leaf = { param($f) [IO.Path]::GetFileNameWithoutExtension($f) }
  $names = [Collections.Generic.HashSet[string]]::new([string[]]@($changed | ForEach-Object { & $leaf $_ })); $hier = @($changed)
  $pf = Join-Path (Get-KitPath localenv -Create) "javainc-$PID.txt"; $w = '[^A-Za-z0-9_$]'
  $grep = { param([string[]]$pat, [string[]]$how) [IO.File]::WriteAllText($pf, (($pat -join "`n") + "`n")); @(git -C $wt -c core.quotepath=off grep -l @how -f $pf -- $src 2>$null | Where-Object { $_ }) }
  try {
    $todo = @($names)
    for ($i = 0; $todo.Count -and $i -lt 10; $i++) {
      $tx = "(extends|implements)[^{]*$w($(@($todo | ForEach-Object { [regex]::Escape($_) }) -join '|'))($w|$)"   # whole text: extends and the type on separate lines
      $sub = @(& $grep @($todo) @('-w', '-F') | Where-Object { [regex]::IsMatch([IO.File]::ReadAllText((Join-Path $wt $_)), $tx) -and $names.Add((& $leaf $_)) })
      $hier += $sub; $todo = @($sub | ForEach-Object { & $leaf $_ })
    }
    $out = @($changed) + @(& $grep @(@($names) + @($names | ForEach-Object { "$($_)_" })) @('-w', '-F'))
    if ($cls -and (Test-Path -LiteralPath $cls)) {
      $int = @($hier | ForEach-Object { [regex]::Escape(($_.Substring($src.Length + 1) -replace '\.java$')) })
      $rx = [regex]::new("($($int -join '|'))_?(?![A-Za-z0-9_])")
      foreach ($fi in [IO.DirectoryInfo]::new($cls).EnumerateFiles('*.class', [IO.SearchOption]::AllDirectories)) {
        if ($rx.IsMatch([Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($fi.FullName)))) {
          $sf = "$src/" + ([IO.Path]::GetRelativePath($cls, $fi.FullName).Replace('\', '/') -replace '(\$.*)?\.class$') + '.java'
          if (Test-Path -LiteralPath (Join-Path $wt $sf)) { $out += $sf }   # processor output (XImpl, X_) has no source: its source regenerates it
        }
      }
    }
    if ($always) { [IO.File]::WriteAllText($pf, "$always`n"); $out += @(& $grep @($always) @('-E')) }
    @($out | Select-Object -Unique)
  } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
}
# the classes of these sources (X.class, X$*.class); -Generated: a deleted source's processor output too (X_, XImpl)
function Remove-JavaClasses([string]$wt, [string]$dir, [string]$src, [string[]]$files, [switch]$Generated) {
  foreach ($f in $files) {
    $pkg = Split-Path ($f.Substring($src.Length + 1)); $x = [IO.Path]::GetFileNameWithoutExtension($f)
    $pats = @("$x.class", "$x`$*.class") + @(if ($Generated) { "$($x)_.class", "$($x)_`$*.class", "$($x)Impl.class", "$($x)_.java", "$($x)Impl.java" })
    foreach ($root in (Join-Path $dir "target/classes/$pkg"), (Join-Path $dir "target/generated-sources/annotations/$pkg")) {
      if (Test-Path -LiteralPath $root) { foreach ($pt in $pats) { Get-ChildItem -LiteralPath $root -Filter $pt -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } }
    }
  }
}
# a full run = a clean compile: no recorded inputs (maven-compiler recompiles the module), no class or processor file left over
# (Maven deletes old outputs only from the createdFiles.lst this removes: a removed inner class would ship)
function Reset-JavaIncStatus([string]$dir) {
  if (Test-Path -LiteralPath (Join-Path $dir 'target')) { [IO.File]::WriteAllText((Join-Path $dir 'target/javainc-full.pending'), '') }   # a good build removes it
  Remove-Item -LiteralPath (Join-Path $dir 'target/maven-status/maven-compiler-plugin/compile'), (Join-Path $dir 'target/generated-sources/annotations') -Recurse -Force -ErrorAction SilentlyContinue
  $c = Join-Path $dir 'target/classes'; if (Test-Path -LiteralPath $c) { foreach ($f in [IO.Directory]::EnumerateFiles($c, '*.class', [IO.SearchOption]::AllDirectories)) { [IO.File]::Delete($f) } }
}
# the jars outside the worktree a build's classpathFile lists (saved after a good build): path, size and time per jar, hashed
function Get-JavaDepsPrint([string]$e, $s, [string]$wt, [switch]$Save) {
  $keep = Join-Path (Get-KitPath localenv -Create) "run/$e/$($s.name)/javainc-deps.txt"
  if ($Save) {
    $cp = if ($s.classpathFile) { Join-Path (SvcDir $e $s) $s.classpathFile }; if (-not $cp -or -not (Test-Path -LiteralPath $cp)) { return '' }
    $jars = @((Get-Content -LiteralPath $cp -Raw) -split [regex]::Escape([IO.Path]::PathSeparator) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith($wt, [StringComparison]::OrdinalIgnoreCase) })
    $null = New-Item -ItemType Directory -Force (Split-Path $keep); Set-Content -LiteralPath $keep $jars -Encoding utf8
  } elseif (Test-Path -LiteralPath $keep) { $jars = @(Get-Content -LiteralPath $keep) } else { return '' }
  $pr = "$keep.$PID.print"; [IO.File]::WriteAllText($pr, (@($jars | ForEach-Object { $fi = [IO.FileInfo]::new($_); "$_|$(if ($fi.Exists) { "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)" })" }) -join "`n"))
  try { (Get-FileHash -LiteralPath $pr -Algorithm MD5).Hash } finally { Remove-Item -LiteralPath $pr -Force -ErrorAction SilentlyContinue }
}
# after a run of $p: the next command (failed incremental -> full; verify -> full + compare), $null when done (good: baseline recorded)
function Step-JavaInc([string]$e, $s, $p, [int]$bc, [string]$log) {
  if ($p.phase -eq 1 -and $p.mode -ne 'full' -and -not $bc) { Merge-JavaIndex $p }
  if ($p.phase -eq 1 -and $p.mode -ne 'full' -and ($bc -or $p.mode -eq 'verify')) {
    $p.phase = 2; if (-not $bc) { $p.sums = Get-JavaIncSums $p.dir }   # before the clean
    Reset-JavaIncStatus $p.dir
    if ($bc) {
      $err = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '(?i)\berror\b' } | Select-Object -First 2) -join ' | '
      $p.mode = 'fallback'; $p.why = "incremental failed (exit $bc): $err"; Write-Host "[$e] $($s.name): incremental compile failed: a full build"
    } else { Write-Host "[$e] $($s.name): verify: a full build to compare" }
    return $p.base
  }
  if ($p.mode -eq 'verify' -and -not $bc) {
    $now = Get-JavaIncSums $p.dir; $diff = @(@($p.sums.Keys) + @($now.Keys) | Select-Object -Unique | Where-Object { $p.sums[$_] -ne $now[$_] })
    $p.diff = $diff.Count
    if ($diff.Count) { Write-Host "[$e] $($s.name): verify MISMATCH: $($diff.Count) file(s) differ from the full build (kept the full one)"; Event $e 'java-incremental-mismatch' @{ service = $s.name; files = $diff.Count; sample = @($diff | Select-Object -First 5); why = $p.why } }
  }
  if (-not $bc) {   # distinct names: Update-State's body loops over $n, $k
    Remove-Item -LiteralPath (Join-Path $p.dir 'target/javainc-full.pending') -Force -ErrorAction SilentlyContinue
    $jiDirty = @(@(git -C $p.wt -c core.quotepath=off diff --name-only HEAD -- $p.src 2>$null) + @(git -C $p.wt -c core.quotepath=off ls-files --others --exclude-standard -- $p.src 2>$null) | Where-Object { $_ -match '\.java$' } | Select-Object -Unique)   # untracked too: deleted later, its class must go
    $jiRec = @{ sha = $p.head; n = $(if ($p.mode -eq 'incremental') { $p.n + 1 } else { 0 }); at = (Now); dirty = $jiDirty; deps = (Get-JavaDepsPrint $e $s $p.wt -Save) }; $jiSvc = $s.name
    Update-State $e { param($x) if ($x.javaInc -isnot [hashtable]) { $x.javaInc = @{} }; $x.javaInc[$jiSvc] = $jiRec }
  }
  $null
}
# relative path -> MD5 of every class file and every processor resource (not .java: they carry dates)
function Get-JavaIncSums([string]$dir) {
  $h = @{}
  foreach ($r in 'target/classes', 'target/generated-sources/annotations') {
    $root = Join-Path $dir $r; if (-not (Test-Path -LiteralPath $root)) { continue }
    $fs = @([IO.DirectoryInfo]::new($root).EnumerateFiles('*', [IO.SearchOption]::AllDirectories) | Where-Object { -not ($r -eq 'target/classes' -and $_.Extension -ne '.class' -or $_.Extension -eq '.java') })
    if ($fs.Count) { foreach ($x in Get-FileHash -LiteralPath $fs.FullName -Algorithm MD5) { $h["$r/$([IO.Path]::GetRelativePath($root, $x.Path))"] = $x.Hash } }
  }
  $h
}
# files and MB a build wrote under <dir>/target (a Maven build's churn; build event fields files, mb)
function Get-BuildWrites([string]$dir, [datetime]$since) {
  $root = Join-Path $dir 'target'; if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
  try {   # a measure never fails a build (a folder gone mid-walk)
    $n = 0; $b = [long]0; $t = $since.ToUniversalTime().AddSeconds(-1)   # file times tick coarser than Get-Date
    foreach ($fi in [IO.DirectoryInfo]::new($root).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { if ($fi.LastWriteTimeUtc -ge $t) { $n++; $b += $fi.Length } }
    @{ files = $n; mb = [math]::Round($b / 1MB, 1) }
  } catch { $null }
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
  $loads = @($names | ForEach-Object { Get-LaneLoad $_ }); $high = @(Get-KitHighAgents); $hi = $agent -in $high   # lane priority: others keep off a high agent's lane, a cold one opens for it at once
  if ($id) { foreach ($n in $names) { if (@((Read-State $n).requests | Where-Object id -eq $id).Count) { return $n } } }   # wait -Id: the lane holding that request
  $mine = @($loads | Where-Object { $agent -in $_.agents -and (-not $pinned -or $_.env -eq $pinned) })[0]; if ($mine) { return $mine.env }   # a named lane: never another
  if ($action -notin 'deploy', 'use', 'task') { return $(if ($pinned) { $pinned } else { $e }) }
  # K58 (owner 2026-11-17): a warm lane (services up or a train) first, even shared; a cold one only past the queue wait
  # localEnv.lanes.openAfterMinutes (learned) with room for all its services; a person opens one with -Env <lane> / -Lane k
  $room = (Get-GateAvailGB (Get-SysMem)) - (KeepFreeGB)
  $fits = { param($n) (@(EnvServices $n | Where-Object { Managed $_ } | ForEach-Object { Need-GB $n $_ }) | Measure-Object -Sum).Sum -le $room }
  $warm = @($loads | Where-Object { $_.up -or $_.train }); if (-not $warm.Count) { $warm = @($loads[0]) }   # all cold: lane 1
  $best = if ($pinned) { @($loads | Where-Object env -eq $pinned)[0] } else { @($warm | Sort-Object @{ Expression = { $_.agents.Count + [int]$_.train + $(if (-not $hi) { 2 * @($_.agents | Where-Object { $_ -in $high }).Count } else { 0 }) } }, @{ Expression = { $_.up }; Descending = $true }, @{ Expression = { [array]::IndexOf($names, $_.env) } })[0] }
  $why = if ($pinned) { 'the lane -Env names' } else { 'warm lane, free' }
  $taken = @($best.leased | Where-Object { $_ -ne $agent })
  if ($pinned -and -not ($action -eq 'deploy' -and $taken.Count)) { return $pinned }   # no pick: the K58 lanePick reason stays
  $free = @($loads | Where-Object { -not @($_.leased | Where-Object { $_ -ne $agent }).Count -and -not $_.train -and ($_.up -or (& $fits $_.env)) } | Sort-Object @{ Expression = { $agent -in $_.agents }; Descending = $true }, @{ Expression = { $_.up -gt 0 }; Descending = $true }, @{ Expression = { $_.agents.Count } }, @{ Expression = { [array]::IndexOf($names, $_.env) } })   # K58: warm first
  if ($action -eq 'deploy' -and $taken.Count -and $free.Count) { $why = "$($best.env) leased by $($taken -join ', '): a free lane instead of waiting for that lease$(if ($pinned) { "; later calls: -Env $($free[0].env)" })"; $best = $free[0] }
  elseif ($pinned) { }
  elseif ($best.agents.Count + [int]$best.train) {
    $wait = [int](@($warm | ForEach-Object { Get-LaneWaitMin $_.env }) | Measure-Object -Minimum).Minimum; $after = if ($hi) { 0.0 } else { [double](Get-KitParam 'localEnv.lanes.openAfterMinutes') }
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
  @($ts | Sort-Object @{ e = { -[int][bool]$_.high } }, @{ e = { [double]$_.cost - ($now - [datetime]$_.since).TotalSeconds } }, @{ e = { [datetime]$_.since } })[0]   # a high lane's start first
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
      if ($cpu0 -and -not $tk) { $tk = Join-Path (StartQueueDir) "$PID-$($s.name).json"; Write-KitAtomic $tk (@{ pid = $PID; pstart = "$(Get-KitPidStart $PID)"; env = $e; service = $s.name; cost = $cost; high = (Test-LaneHigh $e); since = (Get-KitStamp stored $cpu0) } | ConvertTo-Json -Compress) }
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
function LaneEnv([string]$e, $item) { $v = EnvVars $e $item; $v.CLAUDE_AGENT = ''; if (Test-LaneHigh $e -Train) { $v.KIT_PRIORITY = 'high' }; $v }   # a high train's builds: first in the gate
# a build the kit stopped (release, PAUSE) blames no layer: new layers and drops fail with "deploy again", the live release stays
function Set-KilledBuild([string]$why, $kept, [scriptblock]$isNew, $reqs, $cur, [string]$rn, $results) {
  $m = "${why}: not your branch, deploy again"
  foreach ($l in @($kept | Where-Object { & $isNew $_ })) { if ($l.request) { $results[$l.request] = @{ outcome = 'failed'; message = $m } } }
  foreach ($q in @($reqs | Where-Object { $_.kind -eq 'drop' -and @($cur[$rn].branch) -contains $_.branch })) { $results[$q.id] = @{ outcome = 'failed'; message = $m } }
}
# ---- lane priority: envy.ps1 priority high | normal -Run <run> | -Agent <id,..> (no op: the list); a high agent (lib Test-KitHigh,
# params.json priority { <agent>: { run, until } }, 72 h) goes first in the build gate, the start queue, a train's lease wait and the lane pick
# a run's agents: the area ids of its launch record + its live board rows
function Get-PriorityAgents([string]$Run) {
  $ids = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { "$($_.run)" -eq $Run } | ForEach-Object { @($_.args.agents) } | Where-Object { $_ -and $_.id } | ForEach-Object { "$($_.id)" })
  $ids += @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { "$($_.run)" -eq $Run -and "$($_.status)" -ne 'left' } | ForEach-Object { "$($_.agent)" })
  @($ids | Where-Object { $_ } | Select-Object -Unique)
}
function Set-LanePriority([string]$Level, [string[]]$Agents, [string]$Run) {
  $f = Get-KitPath param-state -Create
  Invoke-KitLocked $f { $s = Read-KitParams -Strict; if ($s.priority -isnot [Collections.IDictionary]) { $s.priority = @{} }
    foreach ($pk in @($s.priority.Keys)) { if ([datetime]$s.priority[$pk].until -le (Get-Date)) { $s.priority.Remove($pk) } }   # ended ones go
    $until = Get-KitStamp stored (Get-Date).AddHours(72)   # TODO-PARAM (fixed default)
    foreach ($pa in $Agents) { if ($Level -eq 'high') { $s.priority[$pa] = @{ run = $Run; until = $until } } else { $s.priority.Remove($pa) } }
    if ($s.priorityRuns -isnot [Collections.IDictionary]) { $s.priorityRuns = @{} }   # the run itself: agents that join it later are high too
    foreach ($pk in @($s.priorityRuns.Keys)) { if ([datetime]$s.priorityRuns[$pk] -le (Get-Date)) { $s.priorityRuns.Remove($pk) } }
    if ($Run) { if ($Level -eq 'high') { $s.priorityRuns[$Run] = $until } else { $s.priorityRuns.Remove($Run) } }
    Write-KitAtomic $f ($s | ConvertTo-Json -Depth 8 -Compress) }
  $script:KitParamMemo.Remove('state')   # this process reads it fresh; others within a minute
}
# a lane is high while a high agent has an open request there or (not -Train) a lease
function Test-LaneHigh([string]$e, [switch]$Train) {
  $st = Read-State $e
  $who = @($st.requests | Where-Object { $_.status -in 'queued', 'in-train' } | ForEach-Object agent) + @(if (-not $Train) { $st.leases.Keys | ForEach-Object { if ($st.leases[$_].agent) { $st.leases[$_].agent } else { ($_ -split '/')[0] } } })
  $high = @(Get-KitHighAgents); [bool]@($who | Where-Object { "$_" -in $high }).Count
}
# a train's lease wait (envy.ps1 Wait-Leases) -> idle holders' minutes, a running check's minutes, a note: leaseMinutes and
# maxLeaseMinutes; a high train: holders are told at once, a running check is waited for leaseMinutes (its next release point)
function Get-LeaseWaitMin([string]$e) { if (Test-LaneHigh $e -Train) { 0, $script:LeaseMin, ', high priority' } else { $script:LeaseMin, $script:MaxLeaseMin, '' } }
# a holder a train never swaps under before maxLeaseMinutes: its check runs (gate, browser.mjs with CLAUDE_AGENT: lib
# Test-KitAgentBusy) or its lease is new or saw client traffic on its services (lastTraffic, the loop's tick) in the last
# localEnv.leaseBusyMinutes: a matrix or phone UI run writes no busy file (coordinator 2026-11-26: a deploy swapped a lane
# mid-test); a status or logs call alone is no use
function Test-LeaseBusy([string]$e, [string]$key) {
  if (Test-KitAgentBusy ($key -split '/')[0]) { return $true }
  $l = (Read-State $e).leases[$key]; $used = @(@($l.lastTraffic, $l.at) | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
  [bool]($used -and ((Get-Date) - $used).TotalMinutes -lt [double](Get-KitParam 'localEnv.leaseBusyMinutes'))
}
# train gather (10.5% of requests came during their lane's lease wait and took a train of their own, 2026-11-23..26): deploys,
# drops and refreshes queued while the train waited for leases join it (nothing merged or built yet) -> $true: Run-Train starts
# over with them (one lease clock per train: no second wait)
function Test-LateRequests([string]$e) { [bool]@((Read-State $e).requests | Where-Object { $_.status -eq 'queued' -and $_.kind -in 'deploy', 'drop', 'refresh' }).Count }
function Join-LateRequests([string]$e, [string]$tid) {
  $o = @{ ids = @() }
  Update-State $e { param($x) if (-not $x.train -or $x.train.id -ne $tid) { return }
    $late = @($x.requests | Where-Object { $_.status -eq 'queued' -and $_.kind -in 'deploy', 'drop', 'refresh' }); if (-not $late.Count) { return }
    foreach ($lr in $late) { $lr.status = 'in-train' }; $x.train.requests = @(@($x.train.requests) + @($late | ForEach-Object id)); $o.ids = @($late | ForEach-Object id) }
  if ($o.ids.Count) { Event $e 'train-join' @{ id = $tid; requests = $o.ids }; Write-Host "[$e] train $tid : $($o.ids.Count) request(s) queued during the lease wait join it" }
  [bool]$o.ids.Count
}
Register-KitAdapter envy-verb priority @{ ops = @('high', 'normal', 'list'); run = {
  if ($Op -in 'high', 'normal') {
    if ($env:CLAUDE_AGENT) { throw "priority ${Op}: the coordinator sets it on the owner's word, never an agent ($env:CLAUDE_AGENT)" }
    $pa = @(if ($Name) { Get-PriorityAgents $Name } else { Split-KitList $Agent | Where-Object { $_ -ne 'main' } })
    if (-not $pa.Count) { throw "priority $Op needs -Run <run>$(if ($Name) { " ($Name has no launch record with areas and no live board row)" }) or -Agent <id,..>" }
    Set-LanePriority $Op $pa "$Name"; "priority ${Op}: $($pa -join ', ')$(if ($Op -eq 'high') { ' for 72 h: first in the build gate and the start queue; their train tells holders at once (a running check: leaseMinutes); a cold lane opens without the queue wait' })"; return
  }
  $pr = (Read-KitParams).priority; if ($pr -isnot [Collections.IDictionary]) { $pr = @{} }; $rows = @(Get-KitHighAgents | Sort-Object)
  if (-not $rows.Count) { 'priority: no high agent (envy.ps1 priority high -Run <run>)' } else { foreach ($pa in $rows) { "high $pa$(if ($pr[$pa].run) { " (run $($pr[$pa].run)) until $(([datetime]$pr[$pa].until).ToString('MM-dd HH:mm'))" } else { ' (joined a high run)' })" } }
} }
# ---- static server: services[].static (no start command): serves the staged files, unknown routes get index.html;
# services[].routes (first match): rewrite = another path of the files, cmd = its stdout (a CDN router's other origins)
function StaticServer {
  $f = Join-Path (Get-KitPath localenv -Create) 'run/static-server.mjs'
  $js = @'
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { exec } from 'node:child_process';
const [root, port, host = '::', routesFile] = process.argv.slice(2); const base = path.resolve(root);
const routes = routesFile ? JSON.parse(fs.readFileSync(routesFile, 'utf8').replace(/^\uFEFF/, '')).map((r) => ({ ...r, re: new RegExp(r.match) })) : [];
const fill = (t, m) => t.replace(/\$(\d)/g, (_, i) => m[+i] ?? ''); const cache = new Map();
const run = (res, r, m, p) => {   // captures reach a shell: path characters only
  if (m.slice(1).some((v) => v !== undefined && (!/^[\w.\/-]*$/.test(v) || v.includes('..')))) { res.writeHead(400); return res.end(); }
  const reply = (buf) => { res.writeHead(200, { 'Content-Type': r.type || types[path.extname(p).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-cache' }); res.end(buf); };
  const hit = cache.get(p); if (hit && Date.now() - hit.at < (r.cacheSeconds || 0) * 1000) return reply(hit.buf);
  exec(fill(r.cmd, m), { encoding: 'buffer', maxBuffer: 64 << 20, timeout: (r.timeoutSec || 30) * 1000, windowsHide: true }, (err, out) => { if (err) { res.writeHead(404); return res.end(); } cache.set(p, { buf: out, at: Date.now() }); reply(out); });
};
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.map': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.txt': 'text/plain', '.wasm': 'application/wasm', '.webmanifest': 'application/manifest+json' };
const send = (res, code, f) => fs.readFile(f, (err, buf) => { if (err) { res.writeHead(404); return res.end(); } const x = path.extname(f).toLowerCase(); res.writeHead(code, { 'Content-Type': types[x] || 'application/octet-stream', 'Cache-Control': x === '.html' ? 'no-cache' : 'max-age=3600' }); res.end(buf); });
const srv = http.createServer((req, res) => {
  let p; try { p = decodeURIComponent(new URL(req.url, 'http://x').pathname); } catch { res.writeHead(400); return res.end(); }
  if (p.includes('\0')) { res.writeHead(400); return res.end(); }
  for (const r of routes) { const m = r.re.exec(p); if (!m) continue; if (r.cmd) return run(res, r, m, p); p = fill(r.rewrite ?? p, m) || '/'; break; }
  const f = path.join(base, p); if (f !== base && !f.startsWith(base + path.sep)) { res.writeHead(403); return res.end(); }
  fs.stat(f, (err, st) => { if (!err && st.isFile()) return send(res, 200, f); if (!err && st.isDirectory()) return send(res, 200, path.join(f, 'index.html'));
    if (path.extname(p)) { res.writeHead(404); return res.end(); } send(res, 200, path.join(base, 'index.html')); });
});
const up = (h) => srv.listen(+port, h, () => console.log(`Listening on ${h}:${port} (${base})`));
srv.on('error', (e) => { if (e.code === 'EAFNOSUPPORT' && host === '::') { up('0.0.0.0'); } else { throw e; } }); up(host);
'@
  if (-not (Test-Path -LiteralPath $f) -or (Get-Content -LiteralPath $f -Raw) -ne $js) { New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content -LiteralPath $f $js -NoNewline -Encoding utf8 }
  $f
}
