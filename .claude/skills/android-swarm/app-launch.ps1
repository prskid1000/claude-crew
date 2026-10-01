<#
(Re)starts the app on one phone the right way for its mode (read from /sdcard/.qa-app-mode).
Release: normal launcher start. Metro: Expo dev-client deep link to the shared Metro
(a white screen in Metro mode = dev launcher not attached: run this again).
#>
param([Parameter(Mandatory)][string]$Serial, [switch]$NoForceStop, [switch]$Clear, [switch]$Stop)   # -Stop: close the app (you're done with the phone)
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb; $pkg = $c.app.package; $mp = $c.app.metroPort
if ($Stop) { & $adb -s $Serial shell am force-stop $pkg; "$Serial : app closed"; return }
$mode = ((& $adb -s $Serial shell 'cat /sdcard/.qa-app-mode 2>/dev/null') -join '').Trim()
if (-not $mode) { $mode = 'Release' }
if ($Clear) { & $adb -s $Serial shell pm clear $pkg | Out-Null; foreach ($p in $c.app.permissions) { & $adb -s $Serial shell pm grant $pkg "android.permission.$p" 2>$null } }
if (-not $NoForceStop) { & $adb -s $Serial shell am force-stop $pkg }
if ($mode -eq 'Metro') {
  & $adb -s $Serial reverse "tcp:$mp" "tcp:$mp" | Out-Null
  & $adb -s $Serial shell am start -a android.intent.action.VIEW -d "$($c.app.devClientScheme)://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A$mp" $pkg | Out-Null
} else {
  & $adb -s $Serial shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
}
"$Serial : app launched ($mode mode)"
