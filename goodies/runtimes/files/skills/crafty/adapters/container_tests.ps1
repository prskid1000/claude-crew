#Requires -Version 7
# runtimes (goody): before JVM tests that use Testcontainers (a *Container* / *IT* test, or testcontainers in the build file with
# -AllTests), crafty.ps1 check leases a configured runtimes.<docker|podman> (started when down), else asks `<engine> info`; none -> exit 4.
# Dot-sourced from skills/crafty/adapters/; runs inside Invoke-Check and uses its $st, $Tests, $AllTests.
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
