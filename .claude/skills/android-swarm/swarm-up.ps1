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
. (Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'dev-kit/scripts/sysinfo.ps1')   # RAM, processes, SDK paths on Windows/Linux/macOS
$adb = $c.adb
$all = @($c.lanes)
if (-not $Lanes) { $Lanes = @($all | Select-Object -First $(if ($Count -gt 0) { $Count } else { $all.Count }) | ForEach-Object name) }
$gate = Join-Path (Split-Path $c.dir) 'dev-kit\scripts\gate.ps1'
$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'; New-Item -ItemType Directory -Force $ledger | Out-Null
function FreeGB { Get-FreeGB }

$out = @()
foreach ($name in $Lanes) {
  $l = $all | Where-Object name -eq $name | Select-Object -First 1
  if (-not $l) { throw "unknown lane $name (swarm.config.json lanes: $($all.name -join ', '))" }
  $serial = "emulator-$($l.port)"
  # leftovers on this port while adb doesn't show it as 'device': still booting (< 8 min) -> just wait for it;
  # older -> crashed/hung (invisible: no console window) -> kill before booting a fresh one on the same port
  $left = @(Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" })
  if ($left.Count -and -not ((& $adb devices) -match "^$serial\s+device")) {
    $age = [int](($left | ForEach-Object { ((Get-Date) - $_.Created).TotalMinutes } | Measure-Object -Minimum).Minimum)
    if ($age -lt 8 -and @($left | Where-Object Name -like 'qemu-system*').Count) { "$name is already booting ($age min) ..."; $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }; continue }
    Write-Warning "$name`: killing a dead/hung emulator on port $($l.port) (adb not 'device' after $age min)"
    $left | ForEach-Object { Stop-SysProcess $_.Id }; Start-Sleep 2
  }
  if (-not ((& $adb devices) -match "^$serial\s+device")) {
    # fair turn + memory check through the machine-wide gate (same queue as builds), then boot
    & $gate -Dir $c.dir -Cmd "exit 0 #emulator $name" -NeedGB 4.5 -WaitMinutes 30 | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { Write-Warning "$name not started: no memory turn within 30 min"; continue }
    $ini = Join-Path $c.avdDir "$name.avd\emulator-user.ini"
    if (Test-Path (Split-Path $ini)) { @('window.scale = 0.220000', 'resizable.config.id = -1', 'posture = 0') | Set-Content $ini -Encoding ascii }   # same window on every boot
    $a = @('-avd', $name, '-port', $l.port, '-no-audio', '-no-boot-anim'); if ($ColdBoot) { $a += '-no-snapshot-load' }
    $noWin = -not $ShowAll -and ($Headless -or $l.headless -or ($c.headless -and $l.headless -ne $false)); if ($noWin) { $a += '-no-window' }
    # start via WMI so the emulator is not a child of this shell (a tool timeout would otherwise kill it).
    # SW_HIDE: no console/terminal window per emulator (they piled up and stayed open after the phone exited). The phone's own
    # window belongs to the qemu child process and still shows unless -no-window. (WMI rejects CREATE_NO_WINDOW: ReturnValue 21.)
    if ($KitIsWindows) {
      $si = New-CimInstance -CimClass (Get-CimClass -ClassName Win32_ProcessStartup) -ClientOnly -Property @{ ShowWindow = [uint16]0 }
      $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('"' + $c.emulator + '" ' + ($a -join ' ')); CurrentDirectory = (Split-Path $c.emulator); ProcessStartupInformation = $si }
      if ($r.ReturnValue -ne 0) { throw "could not start $name ($($r.ReturnValue))" }
    } else {
      # Linux/macOS: setsid/nohup so the emulator is not killed with this shell; its output goes to emulator-<lane>.log
      if (-not (Test-Path $c.emulator)) { throw "no emulator at $($c.emulator) - set ANDROID_HOME (or ANDROID_SDK_ROOT)" }
      Start-Detached -FilePath $c.emulator -ArgumentList ($a | ForEach-Object { [string]$_ }) -WorkingDirectory (Split-Path $c.emulator) -Log (Join-Path $c.dir "emulator-$name.log")
    }
    "$name booting on $serial ..."
    # long-lived gate ledger entry: builds see the emulator's memory as promised while it boots (removed when it exits)
    Start-Sleep 3
    $qemu = Get-SysProcs -Name '^(qemu-system|emulator)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" } | Sort-Object Created -Descending | Select-Object -First 1
    if ($qemu) { @{ pid = $qemu.Id; need = 4.5; kind = 'emulator'; cmd = "emulator $name"; dir = $c.dir; started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $ledger "$($qemu.Id).json") }
  }
  $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }
}
$ready = @()
foreach ($o in $out) {
  # bounded wait (no `adb wait-for-device`: it blocks forever when the emulator dies during boot)
  $booted = $false
  for ($i = 0; $i -lt 120; $i++) { if ((& $adb -s $o.serial shell getprop sys.boot_completed 2>$null) -match '1') { $booted = $true; break }; Start-Sleep 3 }
  if (-not $booted) {
    Write-Warning "$($o.lane) did not finish booting in 6 min: killing it (a hidden emulator would otherwise keep its RAM)"
    Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$($o.port)\b" } | ForEach-Object { Stop-SysProcess $_.Id }
    continue
  }
  $ready += $o
  if (-not ((& $adb -s $o.serial shell 'cat /sdcard/.qa-slimmed 2>/dev/null') -match 'slimmed')) { & (Join-Path $c.dir 'swarm-slim.ps1') -Serial $o.serial }
  foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') { & $adb -s $o.serial shell settings put global $k 0 }
  "$($o.lane) ready: $($o.serial)"
}
$out = $ready
$out | ConvertTo-Json | Set-Content (Join-Path $c.dir 'swarm.json') -Encoding utf8
foreach ($i in 1..3) { Start-Sleep 4; & (Join-Path $c.dir 'swarm-arrange.ps1') | Out-Null }
& (Join-Path $c.dir 'swarm-arrange.ps1')
if ($Mode -eq 'Metro' -and -not (Test-PortListening $c.app.metroPort)) { & (Join-Path $c.dir 'metro-start.ps1') }
if ($Mode -ne 'None' -and $out) { & (Join-Path $c.dir 'app-mode.ps1') -Mode $Mode -Serials $out.serial }
"swarm.json written; free RAM now $(FreeGB) GB"
