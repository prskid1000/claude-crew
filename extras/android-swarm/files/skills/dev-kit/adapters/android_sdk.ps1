#Requires -Version 7
# android-swarm (extra): where the Android SDK is (ANDROID_HOME / ANDROID_SDK_ROOT, else the OS default); swarm.ps1 and ios-simulator use it.
function Get-AndroidSdk {
  foreach ($e in $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) { if ($e) { return $e } }
  if ($KitIsWindows) { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
  elseif ($KitIsMac) { Join-Path $HOME 'Library/Android/sdk' }
  else { Join-Path $HOME 'Android/Sdk' }
}
