<#
Installs the app under test on the swarm phones in the chosen mode:
  Release - apk/app.apk (build it with app-build.ps1).
  Metro   - react-native only: apk/base.apk (Expo dev client) + adb reverse to the shared Metro (metro-start.ps1).
Both should be signed with the same key, so switching keeps the app's data.
#>
param(
  [Parameter(Mandatory)][ValidateSet('Release', 'Metro', 'Embedded')][string]$Mode,   # Embedded = Release (old name)
  [string[]]$Serials,              # default: every lane in swarm.json
  [switch]$Launch
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Embedded') { $Mode = 'Release' }
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb; $pkg = $c.app.package; $mp = $c.app.metroPort
if ($Mode -eq 'Metro' -and $c.app.kind -ne 'react-native') { throw 'Metro mode is only for react-native apps' }
if (-not $Serials) { $Serials = (Get-Content (Join-Path $c.dir 'swarm.json') -Raw | ConvertFrom-Json).serial }
$apk = Join-Path $c.dir $(if ($Mode -eq 'Release') { 'apk/app.apk' } else { 'apk/base.apk' })
if (-not (Test-Path $apk)) { throw "$apk missing$(if ($Mode -eq 'Release') { ' - run app-build.ps1' } else { ' - put the dev-client APK there' })" }
foreach ($s in $Serials) {
  $r = & $adb -s $s install -r -g $apk 2>&1 | Select-Object -Last 1
  if ($r -notmatch 'Success') { & $adb -s $s uninstall $pkg | Out-Null; $r = & $adb -s $s install -g $apk 2>&1 | Select-Object -Last 1 }
  foreach ($p in $c.app.permissions) { & $adb -s $s shell pm grant $pkg "android.permission.$p" 2>$null }
  if ($Mode -eq 'Metro') { & $adb -s $s reverse "tcp:$mp" "tcp:$mp" | Out-Null } else { & $adb -s $s reverse --remove "tcp:$mp" 2>$null | Out-Null }
  & $adb -s $s shell "echo $Mode > /sdcard/.qa-app-mode"
  "$s : $Mode app installed ($r)"
  if ($Launch) { & (Join-Path $c.dir 'app-launch.ps1') -Serial $s }
}
