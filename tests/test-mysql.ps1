#Requires -Version 7
<#
test-mysql.ps1: the ONE kit-test mysqld (K78), dot-sourced by harness.ps1 (Start-TestMySql / Stop-TestMySql) and kit-tests.ps1
(Exit-TestMySqlHolder at the end of a run). One persistent data dir in the main clone's state (`_paths` durable kit-tests-db:
<kit>/.state/kit-tests/), initialised once per mysqld build + options, shared by every area, run and worktree: areas take it in
turn (a machine-wide lock), a take drops the last holder's small schemas and resets binlogs and globals; started on first use,
stopped (data kept) when the last run holding it ends. kit-tests.ps1 fails a run that started it more than once (TEST-MYSQLD).
Usage: . (Join-Path $PSScriptRoot 'test-mysql.ps1'); needs $src (the kit under test).
Exit codes: none (functions only).
#>
# writes per start: 8M redo, no doublewrite, lazy log flush, no performance schema; binlog ROW / FULL (the flashback areas read it)
$script:TestMySqlOpts = '--innodb-redo-log-capacity=8M --innodb-doublewrite=OFF --innodb-flush-log-at-trx-commit=0 --performance-schema=OFF --innodb-max-dirty-pages-pct=90 --innodb-io-capacity=100'
$script:TestMySqlLog = '--log-bin=binlog --server-id=1 --binlog-row-metadata=FULL --sync-binlog=0'
function Get-TestMySqlHome([string]$Kit = $src) {   # the main clone's, so every worktree shares it
  $tmMain = "$(git -C $Kit rev-parse --path-format=absolute --git-common-dir 2>$null)" -replace '[\\/]\.git$', ''
  $tmRoot = if ($tmMain -and (Test-Path (Join-Path $tmMain 'skills/crafty/kit.example.json'))) { $tmMain } else { $Kit }
  $tmMap = (Get-Content (Join-Path $Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json)._paths
  Join-Path (Join-Path $tmRoot $tmMap.stateDir) (Split-Path $tmMap.durable.'kit-tests-db')
}
function Test-TestMySqlPort([int]$Port) { $tc = [Net.Sockets.TcpClient]::new(); try { $tc.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $tc.Connected } catch { $false } finally { $tc.Dispose() } }
function Read-TestMySqlState([string]$StateDir) { $f = Join-Path $StateDir 'server.json'; if (Test-Path $f) { try { Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { @{} } } else { @{} } }
function Save-TestMySqlState([string]$StateDir, $St) { $f = Join-Path $StateDir 'server.json'; $St | ConvertTo-Json -Depth 4 | Set-Content "$f.tmp" -Encoding utf8; Move-Item "$f.tmp" $f -Force }
function Enter-TestMySqlLock([string]$StateDir, [int]$Minutes = 30) {
  $until = (Get-Date).AddMinutes($Minutes)
  while ($true) { try { return [IO.File]::Open((Join-Path $StateDir 'mysql.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { if ((Get-Date) -gt $until) { throw "test mysqld: $StateDir/mysql.lock held $Minutes min" }; Start-Sleep -Milliseconds 500 } }
}
# a clean shutdown (data kept), else the whole tree (Windows: the started mysqld is a monitor, its worker a child)
function Stop-TestMySqlServer($St) {
  if (-not $St.pid) { return }
  $tmP = Get-Process -Id $St.pid -ErrorAction SilentlyContinue; if (-not $tmP) { return }
  if ($St.port -and (Test-TestMySqlPort $St.port)) { & mysqladmin -h 127.0.0.1 -P $St.port -u root shutdown 2>&1 | Out-Null }
  if (-not $tmP.WaitForExit(60000)) { try { $tmP.Kill($true) } catch {}; $null = $tmP.WaitForExit(10000) }
}
function Start-TestMySql([switch]$Binlog) {   # -Binlog: kept for callers; the one server always logs ROW / FULL
  $tmExe = (Get-Command mysqld -ErrorAction Stop).Source
  $tmHome = Get-TestMySqlHome; New-Item -ItemType Directory -Force $tmHome | Out-Null
  $tmLock = Enter-TestMySqlLock $tmHome
  try {
    $tmData = Join-Path $tmHome 'mysql'; $tmOpts = "$script:TestMySqlOpts $script:TestMySqlLog"
    $tmKey = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$((Get-Item $tmExe).LastWriteTimeUtc.Ticks) $tmOpts"))).Substring(0, 12)
    $tmHolder = if ($env:KIT_TESTS_RUNNER) { [int]$env:KIT_TESTS_RUNNER } else { $PID }   # a suite run holds it for all its areas
    $St = Read-TestMySqlState $tmHome
    $tmLive = $St.pid -and $St.key -eq $tmKey -and (Get-Process -Id $St.pid -ErrorAction SilentlyContinue) -and (Test-TestMySqlPort $St.port)
    if (-not $tmLive) {
      Stop-TestMySqlServer $St
      if ($St.key -ne $tmKey -or -not (Test-Path (Join-Path $tmData 'mysql.ibd'))) {   # once per mysqld build + options
        Remove-Item $tmData -Recurse -Force -ErrorAction SilentlyContinue
        & $tmExe --no-defaults --initialize-insecure "--datadir=$tmData" --skip-log-bin @($script:TestMySqlOpts -split ' ') 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $tmData 'mysql.ibd'))) { throw "Start-TestMySql: mysqld --initialize-insecure failed in $tmData" }
      }
      $fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $tmPort = $fp.LocalEndpoint.Port; $fp.Stop()   # an OS-picked free port
      # its own tmpdir: the starting area's %TEMP% is deleted when that area ends, the server outlives it (InnoDB "Cannot create temporary merge file")
      $tmTmp = Join-Path $tmHome 'tmp'; New-Item -ItemType Directory -Force $tmTmp | Out-Null
      $tmProc = Start-Process $tmExe -ArgumentList "--no-defaults `"--datadir=$tmData`" `"--tmpdir=$tmTmp`" --port=$tmPort --bind-address=127.0.0.1 --mysqlx=OFF $tmOpts" -WindowStyle Hidden -PassThru
      for ($i = 0; $i -lt 60 -and -not (Test-TestMySqlPort $tmPort); $i++) { Start-Sleep 1 }
      $St = @{ pid = $tmProc.Id; port = $tmPort; key = $tmKey; data = $tmData; holders = @(); starts = @(@($St.starts) + "$tmHolder" | Where-Object { $_ } | Select-Object -Last 50) }
      Save-TestMySqlState $tmHome $St
      if ($i -ge 60) { Stop-TestMySqlServer $St; throw "Start-TestMySql: mysqld not listening on $tmPort after 60 s" }
    }
    $St.holders = @(@($St.holders | Where-Object { $_ -and (Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue) }) + $tmHolder | Select-Object -Unique)
    Save-TestMySqlState $tmHome $St
    # a clean slate for this area: the last holder's schemas and sessions, binlogs back to binlog.000001, changed globals
    $env:MYSQL_PWD = ''
    $tmDbs = @(& mysql -h 127.0.0.1 -P $St.port -u root -N -B -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" 2>&1)
    $tmSql = @($tmDbs | Where-Object { $_ } | ForEach-Object { "DROP DATABASE ``$_``;" }) + @(& mysql -h 127.0.0.1 -P $St.port -u root -N -B -e "SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist WHERE id <> CONNECTION_ID() AND user <> 'event_scheduler'" 2>&1 | Where-Object { $_ -match '^KILL \d+;$' }) +
      'RESET MASTER;', 'SET GLOBAL max_execution_time = DEFAULT, slow_query_log = DEFAULT;'
    $tmOut = ($tmSql -join "`n") | & mysql -h 127.0.0.1 -P $St.port -u root -f 2>&1
    if ($LASTEXITCODE) { throw "Start-TestMySql: reset failed: $tmOut" }
    [pscustomobject]@{ proc = (Get-Process -Id $St.pid); port = $St.port; data = $tmData; home = $tmHome; holder = $tmHolder; lock = $tmLock }
  } catch { $tmLock.Dispose(); throw }
}
# the area is done: the lock goes to the next area; an area run alone (no suite runner) also ends its hold
function Stop-TestMySql($Server) {
  if (-not $Server) { return }
  try { if ($Server.holder -eq $PID) { Exit-TestMySqlHolder $Server.home $PID -Locked } } finally { $Server.lock.Dispose() }
}
# a run holding the server ends: the server stops (data kept) when no live run holds it; returns how often this holder started it
function Exit-TestMySqlHolder([string]$StateDir, [int]$Holder, [switch]$Locked) {
  if (-not (Test-Path (Join-Path $StateDir 'server.json'))) { return 0 }
  $tmLock = if ($Locked) { $null } else { Enter-TestMySqlLock $StateDir }
  try {
    $St = Read-TestMySqlState $StateDir
    $St.holders = @($St.holders | Where-Object { $_ -and [int]$_ -ne $Holder -and (Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue) })
    if (-not $St.holders.Count) { Stop-TestMySqlServer $St; $St.pid = $null }
    Save-TestMySqlState $StateDir $St
    @($St.starts | Where-Object { "$_" -eq "$Holder" }).Count
  } finally { if ($tmLock) { $tmLock.Dispose() } }
}
