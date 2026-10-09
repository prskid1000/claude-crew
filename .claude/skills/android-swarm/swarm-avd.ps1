<#
Create the swarm emulators in one go, and reset/restore a broken one. All lanes are identical copies of avd-template.ini
(Pixel 10 Pro skin, 1280x2856 @ 480 dpi, Android 36.1 Google Play x86_64, 4 GB RAM, 4 cores, 16 GB data, GPU host,
GPS on, back camera = virtual scene, device frame on). Keep the resolution: ui.ps1 notes and coordinates assume it.

  $A = '<workspace>\.claude\skills\android-swarm\swarm-avd.ps1'
  & $A list                                   # lanes, AVD present?, running?, leased by?
  & $A create [-Lanes Falcon,Kestrel,Osprey]  # create every missing lane AVD (all lanes in swarm.config.json by default)
  & $A reset -Lanes Osprey -Level cold        # 1. stuck boot / "offline" in adb: cold boot, ignore the quick-boot snapshot
  & $A reset -Lanes Osprey -Level snapshots   # 2. snapshot corrupt (boots into a broken state every time): delete snapshots, cold boot
  & $A reset -Lanes Osprey -Level wipe        # 3. phone itself broken (storage full, settings mangled): factory reset (wipe data)
  & $A reset -Lanes Osprey -Level recreate    # 4. AVD files corrupt / won't start at all: delete the AVD and create it again from the template

After wipe/recreate the phone is new: on the next boot swarm-up slims it again, and phone.ps1 acquire reinstalls the test APK
(the app's login is gone - log in again). A lane leased by an agent is refused unless -Force.
No Android command-line tools needed: an AVD is <name>.ini + <name>.avd\config.ini; the emulator builds the disks on first boot.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'create', 'reset')][string]$Action,
  [string[]]$Lanes,
  [ValidateSet('cold', 'snapshots', 'wipe', 'recreate')][string]$Level = 'cold',
  [switch]$NoBoot,                  # create/reset: don't boot afterwards
  [switch]$Force                    # act on a lane even if an agent holds its lease
)
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb
$sdk = Split-Path (Split-Path $c.adb)
$avdHome = if ($c.avdDir) { $c.avdDir } elseif ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { "$env:USERPROFILE\.android\avd" }
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($PSCommandPath -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }
$template = Join-Path $c.dir 'avd-template.ini'
$all = @($c.lanes | Where-Object { -not $Lanes -or $Lanes -contains $_.name })
if ($Lanes) { $bad = @($Lanes | Where-Object { $c.lanes.name -notcontains $_ }); if ($bad) { throw "unknown lane(s) $($bad -join ', ') (lanes: $($c.lanes.name -join ', '))" } }
function Running($l) { [bool]((& $adb devices) -match "^emulator-$($l.port)\s+device") }
function Holder($l) { $f = Join-Path $rt "phones\$($l.name).json"; if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).agent } }

function New-Avd($name) {
  $tpl = Get-Content $template -Raw
  $sys = if ($tpl -match 'image\.sysdir\.1=(.+)') { Join-Path $sdk $Matches[1].Trim() } else { throw 'template has no image.sysdir.1' }
  if (-not (Test-Path $sys)) { throw "system image missing: $sys - install it in Android Studio (SDK Manager > SDK Platforms > Android 36.1 > Google Play x86_64)" }
  $d = Join-Path $avdHome "$name.avd"
  New-Item -ItemType Directory -Force $d | Out-Null
  $tpl.Replace('{{NAME}}', $name).Replace('{{SDK}}', $sdk) | Set-Content (Join-Path $d 'config.ini') -Encoding ascii -NoNewline
  $target = if ($tpl -match '(?m)^target=(.+)$') { $Matches[1].Trim() } else { 'android-36.1' }
  @('avd.ini.encoding=UTF-8', "path=$d", "path.rel=avd\$name.avd", "target=$target") | Set-Content (Join-Path $avdHome "$name.ini") -Encoding ascii
  "$name created in $avdHome (first boot builds its disks: a few minutes)"
}
function Stop-Lane($l) { if (Running $l) { & "$($c.dir)\swarm-down.ps1" -Lanes $l.name -KeepBrowsers | Select-Object -First 1 } }

switch ($Action) {
  'list' {
    foreach ($l in $all) {
      '{0,-8} {1,-14} avd={2,-8} {3,-5} {4}' -f $l.name, "emulator-$($l.port)", $(if (Test-Path (Join-Path $avdHome "$($l.name).avd\config.ini")) { 'present' } else { 'MISSING' }),
        $(if (Running $l) { 'up' } else { 'down' }), $(if ($h = Holder $l) { "leased by $h" } else { '' })
    }
  }
  'create' {
    $made = @()
    foreach ($l in $all) {
      if (Test-Path (Join-Path $avdHome "$($l.name).avd\config.ini")) { "$($l.name) exists - kept (use reset -Level recreate to rebuild it)"; continue }
      New-Avd $l.name; $made += $l.name
    }
    if ($made -and -not $NoBoot) { & "$($c.dir)\swarm-up.ps1" -Lanes $made -Mode None -ColdBoot | Select-Object -Last 3 }
  }
  'reset' {
    if (-not $Lanes) { throw 'reset needs -Lanes (it never resets every phone by accident)' }
    foreach ($l in $all) {
      $h = Holder $l
      if ($h -and $h -ne 'manual' -and -not $Force) { Write-Warning "$($l.name) is leased by agent $h - skipped (wait for it, or -Force)"; continue }
      Stop-Lane $l
      $d = Join-Path $avdHome "$($l.name).avd"
      switch ($Level) {
        'snapshots' { Remove-Item (Join-Path $d 'snapshots') -Recurse -Force -ErrorAction SilentlyContinue; "$($l.name): snapshots deleted" }
        'wipe' {
          # factory reset: user data + snapshots + caches go; the emulator recreates them from the system image
          foreach ($f in 'userdata-qemu.img', 'userdata-qemu.img.qcow2', 'cache.img', 'cache.img.qcow2', 'encryptionkey.img', 'encryptionkey.img.qcow2', 'snapshots', 'multiinstance.lock', 'hardware-qemu.ini.lock') {
            Remove-Item (Join-Path $d $f) -Recurse -Force -ErrorAction SilentlyContinue
          }
          "$($l.name): wiped (factory reset)"
        }
        'recreate' {
          Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $avdHome "$($l.name).ini") -Force -ErrorAction SilentlyContinue
          New-Avd $l.name
        }
      }
      Remove-Item (Join-Path $rt "phones\$($l.name).json") -Force -ErrorAction SilentlyContinue   # any lease on a reset phone is void
      if (-not $NoBoot) { & "$($c.dir)\swarm-up.ps1" -Lanes $l.name -Mode None -ColdBoot | Select-Object -Last 2 }
    }
  }
}
