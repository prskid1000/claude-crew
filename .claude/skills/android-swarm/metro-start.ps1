<#
React Native only (Metro mode): ONE shared Metro for all phones, no file watching (CI=1), capped workers, hidden
with a log, then the Android bundle is pre-built once so every phone loads it from cache.
Stops only whatever listens on the Metro port.
#>
param([string]$AppDir, [int]$Port, [int]$MaxWorkers = 4, [switch]$ClearCache)   # -Port: default swarm.config.json app.metroPort
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
. (Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'dev-kit/scripts/sysinfo.ps1')   # RAM, processes, SDK paths on Windows/Linux/macOS
if (-not $AppDir) { $AppDir = $c.app.appDir }
if (-not $Port) { $Port = $c.app.metroPort }
$log = Join-Path $c.dir 'metro.log'
Get-PortPids $Port | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue; "stopped old Metro pid $_" }
$flags = "--port $Port --max-workers $MaxWorkers" + $(if ($ClearCache) { ' --clear' } else { '' })
$cmd = "Set-Location '$AppDir'; `$env:CI='1'; npx expo start $flags *>&1 | Out-File -FilePath '$log' -Encoding utf8"
Start-Detached -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', $cmd -WorkingDirectory $AppDir   # hidden on Windows, setsid/nohup elsewhere
"Metro starting (workers $MaxWorkers, log $log) ..."
$ready = $false
for ($i = 0; $i -lt 90; $i++) { try { if ((Invoke-WebRequest "http://localhost:$Port/status" -TimeoutSec 3 -UseBasicParsing).Content -match 'running') { $ready = $true; break } } catch {}; Start-Sleep 2 }
if (-not $ready) { throw "Metro did not come up - see $log" }
$t0 = Get-Date
try {
  $m = Invoke-RestMethod "http://localhost:$Port/" -Headers @{ 'expo-platform' = 'android'; 'accept' = 'application/expo+json,application/json' } -TimeoutSec 60
  $b = Invoke-WebRequest ($m.launchAsset.url -replace '^https?://[^/]+', "http://localhost:$Port") -TimeoutSec 600 -UseBasicParsing
  "Bundle warmed: $([math]::Round($b.RawContentLength / 1MB, 1)) MB in $([int]((Get-Date) - $t0).TotalSeconds) s"
} catch { "Metro running on $Port (bundle not pre-warmed: $($_.Exception.Message))" }
