# Loads swarm.config.json (copy swarm.example.json). Returns the config with defaults filled in.
# app.kind: 'react-native' (Release = APK with the JS bundle inside; Metro = Expo dev client + shared Metro)
#           'native'       (Kotlin/Java: Release = whatever buildTask produces; no Metro mode)
$here = Split-Path $MyInvocation.MyCommand.Path
$f = Join-Path $here 'swarm.config.json'
if (-not (Test-Path $f)) { throw "Missing $f - copy swarm.example.json and set 'app'" }
$c = Get-Content $f -Raw | ConvertFrom-Json
if (-not $c.keepFreeGB) { $c | Add-Member -Force keepFreeGB 12 }
if (-not $c.avdDir) { $c | Add-Member -Force avdDir $(if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { "$env:USERPROFILE\.android\avd" }) }
if (-not $c.app.metroPort) { $c.app | Add-Member -Force metroPort 8081 }
if (-not $c.app.kind) { $c.app | Add-Member -Force kind 'react-native' }
if (-not $c.app.buildTask) { $c.app | Add-Member -Force buildTask $(if ($c.app.kind -eq 'native') { 'assembleDebug' } else { 'assembleRelease' }) }
if (-not $c.app.apkGlob) { $v = if ($c.app.buildTask -match 'Release') { 'release' } else { 'debug' }; $c.app | Add-Member -Force apkGlob "app\build\outputs\apk\$v\*.apk" }
if (-not $c.app.permissions) { $c.app | Add-Member -Force permissions @() }
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$c | Add-Member -Force adb "$sdk\platform-tools\adb.exe"
$c | Add-Member -Force emulator "$sdk\emulator\emulator.exe"
$c | Add-Member -Force dir $here
$c
