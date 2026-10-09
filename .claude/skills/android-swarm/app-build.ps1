<#
Builds the test APK of the app in swarm.config.json (or -AppDir) through the machine-wide memory gate, and copies it
to apk/app.apk (+ apk/app-<commit>.apk). apk/app.apk is installed on every lane by phone.ps1, so a build of any other
checkout (-AppDir pointing at a worktree / feature branch) only writes apk/app-<branch>-<commit>.apk unless -Shared.
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
  [switch]$DevClient,              # react-native: build the Expo dev client (debug variant) -> apk/base.apk, used by -Mode Metro
  [switch]$Shared                  # with -AppDir on a side checkout: still publish it as apk/app.apk for every lane
)
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
if (-not $AppDir) { $AppDir = $c.app.appDir }
if ($DevClient) { if ($c.app.kind -ne 'react-native') { throw '-DevClient is for react-native apps' }; if (-not $Task) { $Task = 'assembleDebug' } }
if (-not $Task) { $Task = $c.app.buildTask }
if (-not $PSBoundParameters.ContainsKey('BuildArgs')) { $BuildArgs = [string]$c.app.buildArgs }
$gate = Join-Path (Split-Path $c.dir) 'dev-kit/scripts/gate.ps1'
. (Join-Path (Split-Path $c.dir) 'dev-kit/scripts/sysinfo.ps1')
$gw = if ($KitIsWindows) { 'gradlew.bat' } else { 'gradlew' }   # the gate runs it as .\gradlew.bat (Windows) or ./gradlew
$android = if (Test-Path (Join-Path $AppDir "android/$gw")) { Join-Path $AppDir 'android' } elseif (Test-Path (Join-Path $AppDir $gw)) { $AppDir } else { throw "no $gw in $AppDir or $(Join-Path $AppDir 'android')" }

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
        $pkgDir = (Get-Item $AppDir).FullName; while ($pkgDir -and -not (Test-Path (Join-Path $pkgDir 'package.json'))) { $pkgDir = Split-Path $pkgDir }
        "dependencies changed ($($lockChanged -join ', ')): installing in $pkgDir"
        Push-Location $pkgDir; try { if (Test-Path 'yarn.lock') { yarn install --frozen-lockfile 2>&1 | Select-Object -Last 2 } else { npm ci 2>&1 | Select-Object -Last 2 } } finally { Pop-Location }
      }
    }
  }
}
$commit = (git -C $AppDir rev-parse --short HEAD).Trim()
"Building $Task from $branch @ $commit$(if ($dirty) { " (+$dirty uncommitted changes)" }) ..."

# Java 24+ breaks the native (CMake/prefab) step, so a JAVA_HOME of 24+ (e.g. a user-level Corretto 25) is ignored here
$javaExe = Join-Path 'bin' (Get-ExeName 'java')
function JavaMajor($h) { if ($h -and (Test-Path (Join-Path $h $javaExe))) { $v = (& (Join-Path $h $javaExe) -version 2>&1 | Select-Object -First 1); if ($v -match 'version "(\d+)') { [int]$Matches[1] } } }
if (-not $JavaHome -and (JavaMajor $env:JAVA_HOME) -in 17, 21) { $JavaHome = $env:JAVA_HOME }
if (-not $JavaHome) {
  # JDK folders per OS (Android Studio's bundled jbr included); macOS JDKs keep java under Contents/Home
  $roots = @((Join-Path $HOME '.gradle/jdks'), (Join-Path $HOME '.jdks'))
  $roots += if ($KitIsWindows) { 'C:\Program Files\Android', 'C:\Program Files\Java', 'C:\Program Files\Eclipse Adoptium' }
            elseif ($KitIsMac) { '/Library/Java/JavaVirtualMachines', '/Applications' }
            else { '/usr/lib/jvm', '/opt', (Join-Path $HOME 'android-studio') }
  $JavaHome = @(Get-ChildItem $roots -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { if ($_.Name -match '^Android Studio') { if ($KitIsMac) { Join-Path $_.FullName 'Contents/jbr/Contents/Home' } else { Join-Path $_.FullName 'jbr' } } elseif ($_.Name -eq 'android-studio') { Join-Path $_.FullName 'jbr' } elseif (Test-Path (Join-Path $_.FullName 'Contents/Home')) { Join-Path $_.FullName 'Contents/Home' } else { $_.FullName } } |
    Where-Object { Test-Path (Join-Path $_ $javaExe) } | Where-Object { ((& (Join-Path $_ $javaExe) -version 2>&1 | Select-Object -First 1) -match 'version "(17|21)\.') })[0]
}
if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
"Using Java: $env:JAVA_HOME"
$env:SENTRY_DISABLE_AUTO_UPLOAD = 'true'
if ($c.app.kind -eq 'react-native') { $env:NODE_ENV = 'production' }
$log = Join-Path $c.dir 'build.log'
$t0 = Get-Date
if ($Clean) { Push-Location $android; & (Join-Path . $gw) clean --console=plain | Select-Object -Last 3; Pop-Location }
& $gate -Dir $android -Cmd "$gw $Task $BuildArgs `"-Dorg.gradle.java.home=$env:JAVA_HOME`" --console=plain > `"$log`" 2>&1" -WaitMinutes 120
$rc = $LASTEXITCODE
Select-String -Path $log -Pattern 'BUILD|FAILURE|error:' | Select-Object -Last 15 | ForEach-Object { $_.Line }
Push-Location $android; & (Join-Path . $gw) --stop --console=plain | Out-Null; Pop-Location   # don't leave a multi-GB daemon idling
if ($rc -ne 0) { throw "Gradle build failed (exit $rc) - see $log" }
# the APK this run built, whatever its variant folder (a task other than the configured one must not copy a stale APK)
$apk = Get-ChildItem (Join-Path $android 'app/build/outputs/apk') -Recurse -Filter *.apk -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 } | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $apk) { throw "no APK built by this run under $(Join-Path $android 'app/build/outputs/apk')" }
$apkDir = Join-Path $c.dir 'apk'; New-Item -ItemType Directory -Force $apkDir | Out-Null
$name = if ($DevClient) { 'base' } elseif ($Task -eq $c.app.buildTask) { 'app' } else { 'app-' + ($Task -replace '^assemble', '').ToLower() }
# apk/app.apk is what phone.ps1 installs on EVERY lane: only a build of the configured checkout may replace it.
# A side checkout (another worktree / feature branch) gets its own file, so it can't push an older app onto the other lanes.
$sideBuild = (Resolve-Path $AppDir).Path.TrimEnd('\', '/') -ne (Resolve-Path $c.app.appDir).Path.TrimEnd('\', '/')
if ($sideBuild -and -not $Shared) {
  $own = "$name-$(($branch -replace '[^\w.-]', '_'))-$commit.apk"
  Copy-Item $apk.FullName (Join-Path $apkDir $own) -Force
  "Done in $([int]((Get-Date) - $t0).TotalMinutes) min: apk\$own ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
  "Side-checkout build: NOT published as apk\$name.apk (the lanes keep their build). Install it on YOUR leased phone only: adb -s <serial> install -r `"$(Join-Path $apkDir $own)`"  (-Shared to publish it to every lane)"
  return
}
Copy-Item $apk.FullName (Join-Path $apkDir "$name.apk") -Force
Copy-Item $apk.FullName (Join-Path $apkDir "$name-$commit.apk") -Force
"Done in $([int]((Get-Date) - $t0).TotalMinutes) min: apk\$name.apk ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
