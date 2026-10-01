<#
Builds the test APK of the app in swarm.config.json (or -AppDir) through the machine-wide memory gate, and copies it
to apk\app.apk (+ apk\app-<commit>.apk).
- react-native: release build with the JS bundle inside (no Metro / dev menu / LogBox) - steadier automated testing.
- native (Kotlin/Java): runs app.buildTask (default assembleDebug).
Rebuild whenever the app code changes. Always test the APK of the branch under test.
#>
param(
  [string]$AppDir,
  [string]$Task,                   # default app.buildTask
  [string]$BuildArgs,              # default app.buildArgs (e.g. -PreactNativeArchitectures=x86_64)
  [switch]$Clean,
  [string]$JavaHome,               # default: a JDK 17/21 found on the machine (24+ breaks some native steps)
  [switch]$NoUpdate,               # default: fast-forward a clean checkout to its upstream first, so the APK has the latest merges
  [switch]$DevClient               # react-native: build the Expo dev client (debug variant) -> apk\base.apk, used by -Mode Metro
)
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
if (-not $AppDir) { $AppDir = $c.app.appDir }
if ($DevClient) { if ($c.app.kind -ne 'react-native') { throw '-DevClient is for react-native apps' }; if (-not $Task) { $Task = 'assembleDebug' } }
if (-not $Task) { $Task = $c.app.buildTask }
if (-not $PSBoundParameters.ContainsKey('BuildArgs')) { $BuildArgs = [string]$c.app.buildArgs }
$gate = Join-Path (Split-Path $c.dir) 'dev-kit\scripts\gate.ps1'
$android = if (Test-Path "$AppDir\android\gradlew.bat") { "$AppDir\android" } elseif (Test-Path "$AppDir\gradlew.bat") { $AppDir } else { throw "no gradlew.bat in $AppDir or $AppDir\android" }

$branch = (git -C $AppDir rev-parse --abbrev-ref HEAD).Trim()
$dirty = (git -C $AppDir status --porcelain -- . | Measure-Object).Count
# Test the branch as merged, not whatever the checkout last pulled (an APK 10 commits behind re-fails fixed checks)
if (-not $NoUpdate -and $branch -ne 'HEAD') {
  $before = (git -C $AppDir rev-parse HEAD).Trim()
  git -C $AppDir fetch -q origin $branch 2>$null
  if ($dirty) { Write-Warning "checkout has uncommitted changes: not updating; building $branch as it is" }
  elseif ((git -C $AppDir rev-list --count "HEAD..origin/$branch" 2>$null) -gt 0) {
    git -C $AppDir merge -q --ff-only "origin/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE) { Write-Warning "cannot fast-forward $branch to origin/$branch (local commits?): building the local branch" }
    else {
      "updated $branch $($before.Substring(0, 9)) -> $((git -C $AppDir rev-parse --short HEAD).Trim())"
      $lockChanged = git -C $AppDir diff --name-only $before HEAD | Where-Object { $_ -match '(^|/)(yarn\.lock|package-lock\.json|package\.json)$' }
      if ($lockChanged -and $c.app.kind -eq 'react-native') {
        $pkgDir = (Get-Item $AppDir).FullName; while ($pkgDir -and -not (Test-Path "$pkgDir\package.json")) { $pkgDir = Split-Path $pkgDir }
        "dependencies changed ($($lockChanged -join ', ')): installing in $pkgDir"
        Push-Location $pkgDir; try { if (Test-Path 'yarn.lock') { yarn install --frozen-lockfile 2>&1 | Select-Object -Last 2 } else { npm ci 2>&1 | Select-Object -Last 2 } } finally { Pop-Location }
      }
    }
  }
}
$commit = (git -C $AppDir rev-parse --short HEAD).Trim()
"Building $Task from $branch @ $commit$(if ($dirty) { " (+$dirty uncommitted changes)" }) ..."

# Java 24+ breaks the native (CMake/prefab) step, so a JAVA_HOME of 24+ (e.g. a user-level Corretto 25) is ignored here
function JavaMajor($h) { if ($h -and (Test-Path "$h\bin\java.exe")) { $v = (& "$h\bin\java.exe" -version 2>&1 | Select-Object -First 1); if ($v -match 'version "(\d+)') { [int]$Matches[1] } } }
if (-not $JavaHome -and (JavaMajor $env:JAVA_HOME) -in 17, 21) { $JavaHome = $env:JAVA_HOME }
if (-not $JavaHome) {
  $JavaHome = @(Get-ChildItem "$env:USERPROFILE\.gradle\jdks", "$env:USERPROFILE\.jdks", 'C:\Program Files\Android', 'C:\Program Files\Java', 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { if ($_.Name -eq 'Android Studio') { "$($_.FullName)\jbr" } else { $_.FullName } } |
    Where-Object { Test-Path "$_\bin\java.exe" } | Where-Object { ((& "$_\bin\java.exe" -version 2>&1 | Select-Object -First 1) -match 'version "(17|21)\.') })[0]
}
if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
"Using Java: $env:JAVA_HOME"
$env:SENTRY_DISABLE_AUTO_UPLOAD = 'true'
if ($c.app.kind -eq 'react-native') { $env:NODE_ENV = 'production' }
$log = "$($c.dir)\build.log"
$t0 = Get-Date
if ($Clean) { Push-Location $android; & .\gradlew.bat clean --console=plain | Select-Object -Last 3; Pop-Location }
& $gate -Dir $android -Cmd "gradlew.bat $Task $BuildArgs `"-Dorg.gradle.java.home=$env:JAVA_HOME`" --console=plain > `"$log`" 2>&1" -WaitMinutes 120
$rc = $LASTEXITCODE
Select-String -Path $log -Pattern 'BUILD|FAILURE|error:' | Select-Object -Last 15 | ForEach-Object { $_.Line }
Push-Location $android; & .\gradlew.bat --stop --console=plain | Out-Null; Pop-Location   # don't leave a multi-GB daemon idling
if ($rc -ne 0) { throw "Gradle build failed (exit $rc) - see $log" }
# the APK this run built, whatever its variant folder (a task other than the configured one must not copy a stale APK)
$apk = Get-ChildItem (Join-Path $android 'app\build\outputs\apk') -Recurse -Filter *.apk -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 } | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $apk) { throw "no APK built by this run under $android\app\build\outputs\apk" }
New-Item -ItemType Directory -Force "$($c.dir)\apk" | Out-Null
$name = if ($DevClient) { 'base' } elseif ($Task -eq $c.app.buildTask) { 'app' } else { 'app-' + ($Task -replace '^assemble', '').ToLower() }
Copy-Item $apk.FullName "$($c.dir)\apk\$name.apk" -Force
Copy-Item $apk.FullName "$($c.dir)\apk\$name-$commit.apk" -Force
"Done in $([int]((Get-Date) - $t0).TotalMinutes) min: apk\$name.apk ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
