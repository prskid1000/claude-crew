# app-kinds (extra): swarm.ps1 build presets for app.kind flutter, maui, capacitor, and the Expo prebuild (android/ generated
# when missing). Dot-sourced by swarm.ps1 from adapters/; app.buildCmd + app.artifact override a preset.
function Set-AppKindPreset($app) {
  $pre = @{ flutter = 'flutter build apk --release|build/app/outputs/flutter-apk/app-release.apk'; maui = 'dotnet publish -f {tfm} -c Release|bin/Release/*/publish/*-Signed.apk'
    capacitor = 'npx cap sync android && cd android && {gw} assembleRelease|android/app/build/outputs/apk/release/*.apk' }
  if (-not $pre[$app.kind]) { throw "app.kind $($app.kind) has no preset ($($pre.Keys -join ', ')): set app.buildCmd and app.artifact" }
  $bc, $ar = $pre[$app.kind] -split '\|'
  if (-not $app.buildCmd) { $app | Add-Member -Force buildCmd $bc }
  if (-not $app.artifact) { $app | Add-Member -Force artifact $ar }
  $app.buildCmd = ([string]$app.buildCmd).Replace('{tfm}', $(if ($app.tfm) { [string]$app.tfm } else { 'net9.0-android' }))
}
function Invoke-AppPrebuild([string]$AppDir, [string]$gw) {
  # Expo CNG: prebuild when android/ is missing
  if (-not (Test-Path (Join-Path $AppDir "android/$gw")) -and -not (Test-Path (Join-Path $AppDir $gw)) -and (Test-Path (Join-Path $AppDir 'package.json')) -and
      ((Get-Content (Join-Path $AppDir 'package.json') -Raw) -match '"expo"\s*:')) {
    "no android/ in $AppDir (Expo app): npx expo prebuild --platform android --no-install"
    Push-Location $AppDir
    $ci = $env:CI
    try { $env:CI = '1'; & npx expo prebuild --platform android --no-install 2>&1 | Select-Object -Last 5; if ($LASTEXITCODE) { throw "expo prebuild failed (exit $LASTEXITCODE)" } } finally { $env:CI = $ci; Pop-Location }
  }
}
