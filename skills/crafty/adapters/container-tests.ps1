#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# Sections: L9 poms · L44 reactor · L69 engine
# runtimes: before JVM tests that use Testcontainers (a *Container* / *IT* test, or testcontainers in the build file with
# -AllTests), crafty.ps1 check leases a configured runtimes.<docker|podman> (started when down), else asks `<engine> info`; none -> exit 4.
# Dot-sourced from skills/crafty/adapters/; runs inside Invoke-Check and uses its $st, $Tests, $AllTests, $Show.
# Maven: reactor modules this module depends on (transitively) whose sources are newer than their local-repo jar are built in
# one reactor with the tests (Add-KitReactorTestFlags), never installed: the local repository is shared by every agent and lane.
# ---- poms: reactor walk shared with envy lane builds (Get-KitReactorPoms, Get-KitReactorNeeds, Get-KitReactorBetween, Add-ToolFlags)
function Get-KitPomInfo([string]$Pom) {
  $x = try { ([xml](Get-Content -LiteralPath $Pom -Raw)).project } catch { return $null }
  $g = if ($x.groupId) { "$($x.groupId)" } else { "$($x.parent.groupId)" }; $v = if ($x.version) { "$($x.version)" } else { "$($x.parent.version)" }
  # keyed by artifactId (a dependency's groupId is often ${project.groupId}); deps = "<groupId>|<artifactId>"
  [pscustomobject]@{ dir = Split-Path $Pom; key = "$($x.artifactId)"; g = $g; a = "$($x.artifactId)"; v = $v; pk = "$($x.packaging)"
    deps = @($x.dependencies.dependency | Where-Object { $_ } | ForEach-Object { "$($_.groupId)|$($_.artifactId)" }); mods = @($x.modules.module | Where-Object { $_ } | ForEach-Object { "$_" }) }
}
# the topmost aggregator above module folder $Dir (up to the repo root) -> @{ root; all = its modules by artifactId } (envy lane builds too)
function Get-KitReactorPoms([string]$Dir) {
  $root = $null; $d = Split-Path $Dir; $all = @{}
  # up to the git root; a folder without a pom between (<repo>/<product>/<module>, parent ../../pom.xml) does not stop it
  for ($i = 0; $d -and $i -lt 12; $i++) { $pf = Join-Path $d 'pom.xml'; if ((Test-Path -LiteralPath $pf) -and (Get-Content -LiteralPath $pf -Raw) -match '<modules>') { $root = $d }; if (Test-Path -LiteralPath (Join-Path $d '.git')) { break }; $d = Split-Path $d }
  $q = [Collections.Generic.Queue[string]]::new(); if ($root) { $q.Enqueue($root) }
  while ($q.Count -and $all.Count -lt 400) { $p = Get-KitPomInfo (Join-Path $q.Dequeue() 'pom.xml'); if (-not $p -or $all[$p.key]) { continue }; $all[$p.key] = $p; foreach ($m in $p.mods) { $md = Join-Path $p.dir $m; if (Test-Path -LiteralPath (Join-Path $md 'pom.xml')) { $q.Enqueue($md) } } }
  @{ root = $root; all = $all }
}
# the modules of $All that $Mine depends on (transitively) -> artifactId -> pom info
function Get-KitReactorNeeds($Mine, [hashtable]$All) {
  $need = @{}; $todo = [Collections.Generic.Queue[string]]::new(); foreach ($k in $Mine.deps) { $todo.Enqueue($k) }
  # an outside library sharing a module's artifactId (core, api) has another literal groupId: not a reactor module
  while ($todo.Count) { $dg, $k = $todo.Dequeue() -split '\|', 2; if ($need[$k] -or -not $All[$k] -or ($dg -and $dg -notmatch '^\$' -and $dg -ne $All[$k].g)) { continue }; $need[$k] = $All[$k]; foreach ($k2 in $All[$k].deps) { $todo.Enqueue($k2) } }
  $need
}
# the keys of $Need in $Mods (same folder) or depending, within $Need, on one: built together, none from the local repository
function Get-KitReactorBetween([hashtable]$Need, [hashtable]$Mods) {
  $keep = @{}; $visit = { param($k) if ($keep.ContainsKey($k)) { return $keep[$k] }; $keep[$k] = $false
    $v = $Mods[$k] -and $Mods[$k].dir -eq $Need[$k].dir; foreach ($dk in @($Need[$k].deps | ForEach-Object { ($_ -split '\|', 2)[1] })) { if ($Need[$dk] -and (& $visit $dk)) { $v = $true } }; $keep[$k] = [bool]$v; [bool]$v }
  @($Need.Keys | Where-Object { & $visit $_ })
}
# $flags after every mvn / mvnw / mvnd / gradle(w) that starts a command step (a folder named so, an echo argument: untouched)
function Add-ToolFlags([string]$cmd, [string]$flags) {
  $re = '(?<=(?:^|&&|\|\||;|\||\()\s*(?:call\s+)?(?:cmd(?:\.exe)?\s+/[cs]\s+)?(?:"[^"]*[\\/]|"|[^\s"&|;()]*[\\/])?)(mvnw|mvnd|mvn|gradlew|gradle)(\.cmd|\.bat)?"?(?=[\s)]|$)'
  [regex]::new($re).Replace($cmd, { param($m) "$($m.Value) $flags" })
}
# ---- reactor: a Maven test step's $Cmd + '-f <aggregator in <root>/target> -pl :<module> -am' over the stale reactor deps and
# those between; unchanged: none stale, -Show (it prints the command without them), or an own -pl / -f (warned: local-repo jars)
function Add-KitReactorTestFlags([string]$Cmd) {
  $me = Join-Path $st.dir 'pom.xml'
  if ($Show -or $Cmd -notmatch '\b(mvn|mvnw|mvnd)\b' -or -not (Test-Path -LiteralPath $me)) { return $Cmd }
  $rp = Get-KitReactorPoms $st.dir; $root = $rp.root; if (-not $root) { return $Cmd }
  $mine = Get-KitPomInfo $me; if (-not $mine) { return $Cmd }
  $need = Get-KitReactorNeeds $mine $rp.all
  $repo = if ($env:MAVEN_REPO_LOCAL) { $env:MAVEN_REPO_LOCAL } else { Join-Path $HOME '.m2/repository' }
  $stale = @{}; foreach ($p in $need.Values) {
    if (-not $p.v -or $p.v -match '\$') { continue }   # a ${revision} version: its artefact path is unknown here
    $art = Join-Path $repo "$($p.g -replace '\.', '/')/$($p.a)/$($p.v)/$($p.a)-$($p.v).$(if ($p.pk -eq 'pom') { 'pom' } else { 'jar' })"
    $src = @(@(Get-Item -LiteralPath (Join-Path $p.dir 'pom.xml')) + @(Get-ChildItem -LiteralPath (Join-Path $p.dir 'src/main') -Recurse -File -ErrorAction SilentlyContinue) | Sort-Object LastWriteTimeUtc -Descending)[0]
    $jar = Get-Item -LiteralPath $art -ErrorAction SilentlyContinue
    if (-not $jar -or ($src -and $src.LastWriteTimeUtc -gt $jar.LastWriteTimeUtc)) { $stale[$p.key] = $p } }
  if (-not $stale.Count) { return $Cmd }
  $staleRel = @($stale.Values | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.dir).Replace('\', '/') } | Sort-Object) -join ', '
  if ($Cmd -match '(^|\s)(-pl|--projects|-f|--file)(\s|=|$)') { Write-Host "[check] reactor module(s) newer than their local-repo artefact: $staleRel; the test command has its own -pl / -f, so the tests see the stale local-repo jars: add them to its -pl with -am"; return $Cmd }
  $out =New-Item -ItemType Directory -Force (Join-Path $root 'target'); $f = Join-Path $out.FullName "crafty-reactor-$($mine.a).xml"
  $use = @(@(Get-KitReactorBetween $need $stale | ForEach-Object { $need[$_].dir }) + $mine.dir | ForEach-Object { [IO.Path]::GetRelativePath($out.FullName, $_).Replace('\', '/') } | Sort-Object -Unique)
  Set-Content -LiteralPath $f "<project xmlns=`"http://maven.apache.org/POM/4.0.0`"><modelVersion>4.0.0</modelVersion><groupId>crafty</groupId><artifactId>reactor-$($mine.a)</artifactId><version>0</version><packaging>pom</packaging><modules>$(($use | ForEach-Object { "<module>$_</module>" }) -join '')</modules></project>" -Encoding utf8
  Write-Host "[check] reactor module(s) newer than their local-repo artefact: $staleRel`: built in one reactor with the tests, never installed$(if ($Cmd -notmatch '-D(it\.)?test=\S') { '; no test filter: their own suites run too' })"
  # the deps' own suites: no test matches a -Dtest / -Dit.test filter there
  Add-ToolFlags $Cmd "-f `"$f`" -pl :$($mine.a) -am -Dsurefire.failIfNoSpecifiedTests=false -Dit.failIfNoSpecifiedTests=false"
}
# ---- engine: a container engine answers before Testcontainers tests (a configured runtime is leased)
function Invoke-KitJvmTestPrep { Test-DockerForContainerTests }
function Test-DockerForContainerTests {
  $names = @($Tests -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { (($_ -split '#')[0] -split '\.')[-1] })
  $need = @($names | Where-Object { $_ -match '(Container|IT)(Test)?$' }).Count -gt 0
  if (-not $need) {
    $bf = @(@('pom.xml', 'build.gradle', 'build.gradle.kts', 'package.json', 'pyproject.toml', 'requirements.txt', 'go.mod') | ForEach-Object { Join-Path $st.dir $_ }) + @(Get-ChildItem -LiteralPath $st.dir -Filter *.csproj -File -ErrorAction SilentlyContinue | ForEach-Object FullName) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bf -and (Get-Content -LiteralPath $bf -Raw) -match 'testcontainers') {
      if ($AllTests -and -not $names.Count) { $need = $true }
      else {
        $roots = @('src/test', 'src/integrationTest', 'test', 'tests', '__tests__') | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($n in $names) {
          $inc = @('.java', '.kt', '.py', '.ts', '.js', '.go', '.cs') | ForEach-Object { "$n$_"; "$n.*$_" }
          $src = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Include $inc -ErrorAction SilentlyContinue } | Select-Object -First 1)
          if ($src.Count -and (Get-Content -LiteralPath $src[0].FullName -Raw) -match '(?i)@Testcontainers|@Container\b|testcontainers|extends\s+\w*Container\w*Test\b') { $need = $true; break }
        }
      }
    }
  }
  if (-not $need) { return 0 }
  $why = 'neither docker nor podman is on PATH'   # Colima: the docker CLI; Podman for Testcontainers: DOCKER_HOST = its socket
  foreach ($x in 'docker', 'podman') {
    if ((Get-Command Use-KitRuntime -ErrorAction SilentlyContinue) -and (Get-KitSetting "runtimes.$x.isUp" '')) {   # a configured runtime: leased (started when down)
      $u = try { Use-KitRuntime $x $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }) } catch { "$_" }
      if ($u -match ': (running|started)') { Write-Host "[check] container tests: $u (release when done: crafty.ps1 runtime release -Name $x)"; return 0 }
      $why = $u; continue
    }
    if (-not (Get-Command $x -ErrorAction SilentlyContinue)) { continue }
    $r = Invoke-KitExe $x @('info') 5; if (-not $r.code) { Write-Host "[check] container tests: $x is running"; return 0 }
    $why = "$x info failed: $(@("$($r.err)" -split "`n" | Where-Object { $_.Trim() })[0])"
  }
  Write-Host "[check] container tests need a container engine, and none answers ($why)."
  Write-Host "[check] Start it (Docker Desktop / docker service / podman machine start / colima start), wait until '<engine> info' answers, re-run; a test failing on a down engine is no code failure."
  return 4
}
