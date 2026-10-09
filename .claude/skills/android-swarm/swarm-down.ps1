<#
Stops the swarm emulators cleanly (snapshot saved), removes adb reverse rules and, by default, kills leftover
headless test browsers started by qa-kit\scripts\web\browser.mjs (runtime\chrome-profiles). Nothing else is touched.
#>
param([string[]]$Lanes, [switch]$KeepBrowsers)
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
. (Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'dev-kit/scripts/sysinfo.ps1')   # RAM, processes, SDK paths on Windows/Linux/macOS
$adb = $c.adb
foreach ($l in @($c.lanes) | Where-Object { -not $Lanes -or $Lanes -contains $_.name }) {
  $serial = "emulator-$($l.port)"
  if ((& $adb devices) -match "^$serial\s+device") {
    & $adb -s $serial reverse --remove-all 2>$null
    & $adb -s $serial emu kill | Out-Null
    # `emu kill` is a request (the console can ignore it while busy): verify, then force-stop the emulator process
    for ($i = 0; $i -lt 45 -and ((& $adb devices) -match "^$serial\s"); $i++) { Start-Sleep 2 }
    if ((& $adb devices) -match "^$serial\s") {
      Get-SysProcs -Name '^(qemu-system|emulator)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" } | ForEach-Object { Stop-SysProcess $_.Id }
      Start-Sleep 3
      "$($l.name) ($serial) did not stop on request: process killed$(if ((& $adb devices) -match "^$serial\s") { ' - STILL LISTED, check by hand' })"
    } else { "$($l.name) ($serial) stopped" }
  } else { "$($l.name) not running" }
}
if (-not $KeepBrowsers) {
  $hc = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|google chrome|microsoft edge)(\.exe)?$' | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match 'chrome-profiles' }
  $hc | ForEach-Object { Stop-SysProcess $_.Id }
  "killed $(@($hc).Count) headless test browser processes"
}
"free RAM now $(Get-FreeGB) GB"
