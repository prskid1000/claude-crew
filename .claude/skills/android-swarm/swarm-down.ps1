<#
Stops the swarm emulators cleanly (snapshot saved), removes adb reverse rules and, by default, kills leftover
headless test browsers started by qa-kit\scripts\web\browser.mjs (runtime\chrome-profiles). Nothing else is touched.
#>
param([string[]]$Lanes, [switch]$KeepBrowsers)
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb
foreach ($l in @($c.lanes) | Where-Object { -not $Lanes -or $Lanes -contains $_.name }) {
  $serial = "emulator-$($l.port)"
  if ((& $adb devices) -match "^$serial\s+device") {
    & $adb -s $serial reverse --remove-all 2>$null
    & $adb -s $serial emu kill | Out-Null
    # `emu kill` is a request (the console can ignore it while busy): verify, then force-stop the emulator process
    for ($i = 0; $i -lt 45 -and ((& $adb devices) -match "^$serial\s"); $i++) { Start-Sleep 2 }
    if ((& $adb devices) -match "^$serial\s") {
      Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(qemu-system|emulator)' -and $_.CommandLine -match "-port\s+$($l.port)\b" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Start-Sleep 3
      "$($l.name) ($serial) did not stop on request: process killed$(if ((& $adb devices) -match "^$serial\s") { ' - STILL LISTED, check by hand' })"
    } else { "$($l.name) ($serial) stopped" }
  } else { "$($l.name) not running" }
}
if (-not $KeepBrowsers) {
  $hc = Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match 'chrome-profiles' }
  $hc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  "killed $(@($hc).Count) headless test browser processes"
}
"free RAM now $([math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)) GB"
