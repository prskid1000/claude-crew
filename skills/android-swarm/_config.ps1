# Loads swarm.config.json (copy swarm.example.json). Returns the config with defaults filled in.
# app.kind: 'react-native' (Release = APK with the JS bundle inside; Metro = Expo dev client + shared Metro)
#           'native'       (Kotlin/Java: Release = whatever buildTask produces; no Metro mode)
$here = Split-Path $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path $here) 'dev-kit/scripts/sysinfo.ps1')
$f = Join-Path $here 'swarm.config.json'
if (-not (Test-Path $f)) { throw "Missing $f - copy swarm.example.json and set 'app'" }
$c = Get-Content $f -Raw | ConvertFrom-Json
if (-not $c.keepFreeGB) { $c | Add-Member -Force keepFreeGB 12 }
if (-not $c.avdDir) { $c | Add-Member -Force avdDir $(if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { (Join-Path $HOME '.android/avd') }) }
if (-not $c.app.metroPort) { $c.app | Add-Member -Force metroPort 8081 }
if (-not $c.app.kind) { $c.app | Add-Member -Force kind 'react-native' }
if (-not $c.app.buildTask) { $c.app | Add-Member -Force buildTask $(if ($c.app.kind -eq 'native') { 'assembleDebug' } else { 'assembleRelease' }) }
if (-not $c.app.apkGlob) { $v = if ($c.app.buildTask -match 'Release') { 'release' } else { 'debug' }; $c.app | Add-Member -Force apkGlob "app/build/outputs/apk/$v/*.apk" }
if (-not $c.app.permissions) { $c.app | Add-Member -Force permissions @() }
$sdk = Get-AndroidSdk   # ANDROID_HOME, ANDROID_SDK_ROOT, else the OS default (%LOCALAPPDATA%/Android/Sdk, ~/Library/Android/sdk, ~/Android/Sdk)
$c | Add-Member -Force adb (Join-Path $sdk (Join-Path 'platform-tools' (Get-ExeName 'adb')))
$c | Add-Member -Force emulator (Join-Path $sdk (Join-Path 'emulator' (Get-ExeName 'emulator')))
$c | Add-Member -Force dir $here
# Runtime output (APKs, build/metro/emulator logs, swarm.json; a rebuildable cache): swarm.config.json "outDir", else
# Get-KitPath android-swarm (<runtime>/cache/android-swarm; kitpaths.json).
. (Join-Path (Split-Path $here) 'dev-kit/scripts/kitpaths.ps1')
$out = if ($c.outDir) { [string]$c.outDir } else { Get-KitPath android-swarm }
$apkDir = Join-Path $out 'apk'
New-Item -ItemType Directory -Force $apkDir | Out-Null
# Backward compatibility: an APK built before the move still sits in <skill>/apk - copy it once so lanes keep their build.
$oldApk = Join-Path $here 'apk'
if (-not (Test-Path (Join-Path $apkDir 'app.apk')) -and (Test-Path (Join-Path $oldApk 'app.apk'))) {
  Get-ChildItem $oldApk -Filter *.apk -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $apkDir $_.Name) }
  if (Test-Path (Join-Path $oldApk 'app.json')) { Copy-Item (Join-Path $oldApk 'app.json') $apkDir }
}
$state = Join-Path $out 'swarm.json'
if (-not (Test-Path $state) -and (Test-Path (Join-Path $here 'swarm.json'))) { Copy-Item (Join-Path $here 'swarm.json') $state }
$c | Add-Member -Force out $out
$c | Add-Member -Force apkDir $apkDir
$c | Add-Member -Force state $state
$c
