param([Parameter(Mandatory)][string]$Serial)
# One-time slimming of a swarm phone (run after first boot; the quick-boot snapshot keeps it).
# Keeps what apps under test usually need (Play services, GPS, camera, maps, browser, phone, SMS, file picker, keyboard); disables heavy/background Google extras.
# Every change is reversible: adb -s <serial> shell pm enable <package>
$adb = (& (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')).adb
function A { & $adb -s $Serial shell @args 2>&1 }

# KEEP (never touched): com.google.android.gms (Play services), com.google.android.gsf,
# the app under test (swarm.config.json "package"), com.android.camera2 / camera, com.google.android.apps.maps, com.android.chrome,
# com.google.android.dialer / com.android.phone, com.google.android.apps.messaging,
# com.google.android.documentsui, com.google.android.inputmethod.latin (Gboard), SystemUI, Settings.
$disable = @(
  'com.google.android.googlequicksearchbox',   # Google app / Assistant (heaviest)
  'com.google.android.as',                     # Android System Intelligence
  'com.google.android.as.oss',                 # Private Compute Services
  'com.android.vending',                       # Play Store (stops background app updates)
  'com.google.android.youtube',
  'com.google.android.apps.youtube.music',
  'com.google.android.apps.youtube.kids',
  'com.google.android.gm',                     # Gmail
  'com.google.android.apps.photos',
  'com.google.android.apps.docs',              # Drive
  'com.google.android.apps.tachyon',           # Meet
  'com.google.android.calendar',
  'com.google.android.apps.subscriptions.red', # Google One
  'com.google.android.apps.wellbeing',
  'com.google.android.apps.turbo',             # Device Health Services
  'com.google.android.projection.gearhead',    # Android Auto
  'com.google.android.apps.safetyhub',         # Personal Safety
  'com.google.android.feedback',
  'com.google.android.printservice.recommendation',
  'com.google.android.apps.wallpaper',
  'com.google.android.apps.nbu.files',         # Files by Google (system file picker stays)
  'com.google.android.videos',
  'com.google.android.apps.restore',
  'com.google.android.apps.pixelmigrate'
)
$installed = (A pm list packages) -replace '^package:', ''
$done = @()
foreach ($p in $disable) {
  if ($installed -contains $p) { $r = A pm disable-user --user 0 $p; if ($r -match 'disabled') { $done += $p } }
}

# Behaviour for automation: no animations, screen always on, no lock, quiet radios, precise location.
A settings put global window_animation_scale 0 | Out-Null
A settings put global transition_animation_scale 0 | Out-Null
A settings put global animator_duration_scale 0 | Out-Null
A settings put global stay_on_while_plugged_in 7 | Out-Null
A settings put system screen_off_timeout 1800000 | Out-Null
A locksettings set-disabled true | Out-Null
A settings put global bluetooth_on 0 | Out-Null
A svc bluetooth disable | Out-Null
A settings put global wifi_scan_always_enabled 0 | Out-Null
A settings put global ble_scan_always_enabled 0 | Out-Null
A settings put secure location_mode 3 | Out-Null          # high accuracy (GPS + network)
A settings put global package_verifier_enable 0 | Out-Null
A 'echo slimmed > /sdcard/.qa-slimmed' | Out-Null

"$Serial slimmed: disabled $($done.Count) packages ($($done -join ', '))"
