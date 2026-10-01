<#
Boots N emulators (lanes from swarm.config.json) for parallel app testing, one agent per phone:
boot (quick-boot snapshot) -> wait -> slim once -> grant the app's permissions -> install the app in the chosen mode
-> write swarm.json (lane, serial). Agents then target their phone with $env:ANDROID_SERIAL=<serial>.

  & <workspace>\.claude\skills\android-swarm\swarm-up.ps1 -Count 3 -Mode Release
  -Mode Release : the built APK (app-build.ps1). Preferred for automated testing.
  -Mode Metro   : React Native dev client + one shared Metro (while the app code is still changing).
  -Mode None    : boot + slim only.   (-Mode Embedded = Release, the old name)
  -Headless      : no emulator windows (less GPU/desktop clutter; adb, screenshots and ui.ps1 work the same).
                   Default comes from swarm.config.json "headless" (per lane or top level); otherwise windows are shown.
#>
param(
  [int]$Count = 0,                 # 0 = all lanes
  [string[]]$Lanes,                # or name them
  [switch]$ColdBoot,               # ignore the snapshot (a lane stuck "offline" in adb)
  [ValidateSet('Release', 'Metro', 'None', 'Embedded')][string]$Mode = 'Release',
  [switch]$Headless,               # no windows (see above)
  [switch]$ShowAll                 # force windows even where the config says headless
)
if ($Mode -eq 'Embedded') { $Mode = 'Release' }
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb
$all = @($c.lanes)
if (-not $Lanes) { $Lanes = @($all | Select-Object -First $(if ($Count -gt 0) { $Count } else { $all.Count }) | ForEach-Object name) }
$gate = Join-Path (Split-Path $c.dir) 'dev-kit\scripts\gate.ps1'
$ledger = Join-Path $env:TEMP 'claude-build-gate'; New-Item -ItemType Directory -Force $ledger | Out-Null
function FreeGB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1) }

$out = @()
foreach ($name in $Lanes) {
  $l = $all | Where-Object name -eq $name | Select-Object -First 1
  if (-not $l) { throw "unknown lane $name (swarm.config.json lanes: $($all.name -join ', '))" }
  $serial = "emulator-$($l.port)"
  if (-not ((& $adb devices) -match "^$serial\s+device")) {
    # fair turn + memory check through the machine-wide gate (same queue as builds), then boot
    & $gate -Dir $c.dir -Cmd "exit 0 #emulator $name" -NeedGB 4.5 -WaitMinutes 30 | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { Write-Warning "$name not started: no memory turn within 30 min"; continue }
    $ini = Join-Path $c.avdDir "$name.avd\emulator-user.ini"
    if (Test-Path (Split-Path $ini)) { @('window.scale = 0.220000', 'resizable.config.id = -1', 'posture = 0') | Set-Content $ini -Encoding ascii }   # same window on every boot
    $a = @('-avd', $name, '-port', $l.port, '-no-audio', '-no-boot-anim'); if ($ColdBoot) { $a += '-no-snapshot-load' }
    $noWin = -not $ShowAll -and ($Headless -or $l.headless -or ($c.headless -and $l.headless -ne $false)); if ($noWin) { $a += '-no-window' }
    # start via WMI so the emulator is not a child of this shell (a tool timeout would otherwise kill it)
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('"' + $c.emulator + '" ' + ($a -join ' ')); CurrentDirectory = (Split-Path $c.emulator) }
    if ($r.ReturnValue -ne 0) { throw "could not start $name ($($r.ReturnValue))" }
    "$name booting on $serial ..."
    # long-lived gate ledger entry: builds see the emulator's memory as promised while it boots (removed when it exits)
    Start-Sleep 3
    $qemu = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(qemu-system|emulator)' -and $_.CommandLine -match "-port\s+$($l.port)\b" } | Sort-Object CreationDate -Descending | Select-Object -First 1
    if ($qemu) { @{ pid = $qemu.ProcessId; need = 4.5; kind = 'emulator'; cmd = "emulator $name"; dir = $c.dir; started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $ledger "$($qemu.ProcessId).json") }
  }
  $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }
}
foreach ($o in $out) {
  & $adb -s $o.serial wait-for-device
  for ($i = 0; $i -lt 120; $i++) { if ((& $adb -s $o.serial shell getprop sys.boot_completed 2>$null) -match '1') { break }; Start-Sleep 3 }
  if (-not ((& $adb -s $o.serial shell 'cat /sdcard/.qa-slimmed 2>/dev/null') -match 'slimmed')) { & "$($c.dir)\swarm-slim.ps1" -Serial $o.serial }
  foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') { & $adb -s $o.serial shell settings put global $k 0 }
  "$($o.lane) ready: $($o.serial)"
}
$out | ConvertTo-Json | Set-Content "$($c.dir)\swarm.json" -Encoding utf8
foreach ($i in 1..3) { Start-Sleep 4; & "$($c.dir)\swarm-arrange.ps1" | Out-Null }
& "$($c.dir)\swarm-arrange.ps1"
if ($Mode -eq 'Metro' -and -not (Get-NetTCPConnection -LocalPort $c.app.metroPort -State Listen -ErrorAction SilentlyContinue)) { & "$($c.dir)\metro-start.ps1" }
if ($Mode -ne 'None') { & "$($c.dir)\app-mode.ps1" -Mode $Mode -Serials $out.serial }
"swarm.json written; free RAM now $(FreeGB) GB"
