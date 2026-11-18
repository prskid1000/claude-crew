#Requires -Version 7
<#
test-mysql.ps1: the ONE kit-test mysqld (K78), dot-sourced by harness.ps1 (Start-TestMySql / Stop-TestMySql) and kit-tests.ps1
(Exit-TestMySqlHolder at the end of a run). One persistent data dir in the main clone's state (`_paths` durable kit-tests-db:
<kit>/.state/kit-tests/), initialised once and never deleted (a new mysqld build or options restart it on the same data), shared by every area, run and worktree: areas take it in
turn (a machine-wide lock), a take drops the last holder's small schemas and resets binlogs and globals; started on first use,
stopped (data kept) when the run that started it or the last run holding it ends (a killed run: kit-tests.ps1 K79). kit-tests.ps1 fails a run that started it more than once (TEST-MYSQLD).
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
# the take is stamped in server.json `lock` {holder, run, at}; a waiter (every 5 s): the holder's run gone (an orphan area, K79) ->
# that holder ends and the lock is taken over; held over -WatchMinutes by a live run -> one WATCH line, still waiting to -Minutes
function Enter-TestMySqlLock([string]$StateDir, [double]$Minutes = 30, [double]$WatchMinutes = 10) {
  $until = (Get-Date).AddMinutes($Minutes); $tmTry = 0; $tmSaid = $false; $tmBy = $null
  while ($true) {
    try { $tmFs = [IO.File]::Open((Join-Path $StateDir 'mysql.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { $tmFs = $null }
    if ($tmFs) {
      $St = Read-TestMySqlState $StateDir; $tmMe = Get-TestProcStamp $PID
      $tmRun = if ($env:KIT_TESTS_RUNNER) { Get-TestProcStamp ([int]$env:KIT_TESTS_RUNNER) }
      $St.lock = @{ holder = $tmMe; run = $(if ($tmRun) { $tmRun } else { $tmMe }); at = (Get-Date).ToString('o') }
      try { Save-TestMySqlState $StateDir $St } catch {}   # the stamp only informs waiters
      return $tmFs
    }
    if ($tmTry++ % 10 -eq 0) {
      $tmBy = (Read-TestMySqlState $StateDir).lock
      if ($tmBy -and (Test-TestProcStamp "$($tmBy.holder)") -and -not (Test-TestProcStamp "$($tmBy.run)")) {
        Write-Warning "test mysqld lock: holder $($tmBy.holder) outlived its run $($tmBy.run): ended, lock taken over (K79)"
        try { (Get-Process -Id ([int]("$($tmBy.holder)" -split ':')[0])).Kill($true) } catch {}; continue }
      $tmAge = if ($tmBy.at) { ([datetimeoffset]::Now - [datetimeoffset]$tmBy.at).TotalMinutes } else { 0 }
      if (-not $tmSaid -and $tmAge -gt $WatchMinutes) { $tmSaid = $true; Write-Warning "WATCH test mysqld lock held $([int]$tmAge) min by $($tmBy.holder) (run $($tmBy.run) alive): waiting up to $Minutes min" }
    }
    if ((Get-Date) -gt $until) { throw "test mysqld: $StateDir/mysql.lock held $Minutes min$(if ($tmBy) { " by $($tmBy.holder) (run $($tmBy.run))" })" }
    Start-Sleep -Milliseconds 500
  }
}
# a process as "<pid>:<start ticks>": a pid reused after a reboot or crash is not the process saved
function Get-TestProcStamp([int]$Id) { $p = Get-Process -Id $Id -ErrorAction SilentlyContinue; if ($p) { "${Id}:$($p.StartTime.ToUniversalTime().Ticks)" } }
function Test-TestProcStamp([string]$Stamp) { if ($Stamp -notmatch '^(\d+):(\d+)$') { return $false }; "$(Get-TestProcStamp ([int]$Matches[1]))" -eq $Stamp }
# a kit-test mysqld that is not the one server (another worktree's old per-area server, a second start): "<pid> <datadir>" each
function Get-TestMySqlStrays($Procs = $null, [string]$Server = '') {
  if ($null -eq $Procs) { if (-not $IsWindows) { return @() }; $Procs = @(Get-CimInstance Win32_Process -Filter "Name='mysqld.exe' OR Name='mariadbd.exe'" -ErrorAction SilentlyContinue) }
  $tmOwn = if ("$Server" -match '^(\d+):') { [int]$Matches[1] } else { -1 }
  @($Procs | Where-Object { "$($_.CommandLine)" -match '--datadir="?[^" ]*([\\/]work[\\/]tests[\\/]mysqld-|[\\/]kit-tests[\\/]mysql\b)' -and [int]$_.ProcessId -ne $tmOwn -and [int]$_.ParentProcessId -ne $tmOwn } |
    ForEach-Object { "$($_.ProcessId) $(if ("$($_.CommandLine)" -match '--datadir="?([^" ]+)') { $Matches[1] })" })
}
# a mysqld on the one data dir that server.json lost (moved aside, reset): ended (data kept), else a new start cannot open ibdata1
function Stop-TestMySqlLost([string]$Data, $Procs = $null) {
  $tmWant = [IO.Path]::GetFullPath($Data).TrimEnd('\', '/')
  foreach ($tmL in @(Get-TestMySqlStrays $Procs)) { $tmLp, $tmLd = $tmL -split ' ', 2
    if ($tmLd -and [IO.Path]::GetFullPath($tmLd).TrimEnd('\', '/') -ieq $tmWant) { $tmLx = Get-Process -Id ([int]$tmLp) -ErrorAction SilentlyContinue
      if ($tmLx) { try { $tmLx.Kill($true); $null = $tmLx.WaitForExit(20000) } catch {}; [int]$tmLp } } }
}
# the state every take starts from, versioned (a change re-seeds those schemas, never a re-init): schemas kept across takes + the SQL
# that seeds them; none today (each area creates and owns its schemas; areas take the server in turn, never sharing a mutable one)
$script:TestMySqlBaseline = @{ schemas = @(); sql = '' }
# a clean shutdown (data kept), else the whole tree (Windows: the started mysqld is a monitor, its worker a child); only the saved process
function Stop-TestMySqlServer($St) {
  if (-not (Test-TestProcStamp "$($St.server)")) { return }
  $tmP = Get-Process -Id ([int]("$($St.server)" -split ':')[0]) -ErrorAction SilentlyContinue; if (-not $tmP -or $tmP.ProcessName -ne 'mysqld') { return }
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
    $tmHolder = Get-TestProcStamp $(if ($env:KIT_TESTS_RUNNER) { [int]$env:KIT_TESTS_RUNNER } else { $PID })   # a suite run holds it for all its areas
    $St = Read-TestMySqlState $tmHome
    $tmOthers = @($St.holders | Where-Object { $_ -and $_ -ne $tmHolder -and (Test-TestProcStamp $_) })
    # a live server is reused; with other runs on it even when its build or options differ (restarted once nobody holds it)
    $tmLive = (Test-TestProcStamp "$($St.server)") -and (Test-TestMySqlPort $St.port) -and ($St.key -eq $tmKey -or $tmOthers.Count)
    if (-not $tmLive) {
      Stop-TestMySqlServer $St; $null = Stop-TestMySqlLost $tmData
      if (-not (Test-Path (Join-Path $tmData 'mysql.ibd'))) {   # once; never deleted after (a new build or option starts on the same data)
        & $tmExe --no-defaults --initialize-insecure "--datadir=$tmData" --skip-log-bin @($script:TestMySqlOpts -split ' ') 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $tmData 'mysql.ibd'))) { throw "Start-TestMySql: mysqld --initialize-insecure failed in $tmData (a partial dir: remove it by hand)" }
      }
      $fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $tmPort = $fp.LocalEndpoint.Port; $fp.Stop()   # an OS-picked free port
      # its own tmpdir: the starting area's %TEMP% is deleted when that area ends, the server outlives it (InnoDB "Cannot create temporary merge file")
      $tmTmp = Join-Path $tmHome 'tmp'; New-Item -ItemType Directory -Force $tmTmp | Out-Null
      $tmProc = Start-Process $tmExe -ArgumentList "--no-defaults `"--datadir=$tmData`" `"--tmpdir=$tmTmp`" --port=$tmPort --bind-address=127.0.0.1 --mysqlx=OFF $tmOpts" -WindowStyle Hidden -PassThru
      for ($i = 0; $i -lt 60 -and -not (Test-TestMySqlPort $tmPort); $i++) { Start-Sleep 1 }
      $St = @{ server = (Get-TestProcStamp $tmProc.Id); port = $tmPort; key = $tmKey; data = $tmData; holders = $tmOthers; owner = $tmHolder; lock = $St.lock; starts = @(@($St.starts) + $tmHolder | Where-Object { "$_" -match '^\d+:\d+$' } | Select-Object -Last 20) }
      Save-TestMySqlState $tmHome $St
      if ($i -ge 60) { Stop-TestMySqlServer $St; throw "Start-TestMySql: mysqld not listening on $tmPort after 60 s" }
    }
    $St.holders = @($tmOthers + $tmHolder | Select-Object -Unique)
    # a second kit-test mysqld seen while this run holds the one: recorded, kit-tests.ps1 fails the run (TEST-MYSQLD)
    $tmStray = @(Get-TestMySqlStrays -Server "$($St.server)"); if ($tmStray.Count) { $St.strays = @(@($St.strays) + @($tmStray | ForEach-Object { "$tmHolder $_" }) | Where-Object { $_ } | Select-Object -Last 50) }
    Save-TestMySqlState $tmHome $St
    # back to the baseline for this area: the last holder's sessions (first: none recreates a schema), its schemas, binlogs back to
    # binlog.000001, globals; the baseline's own schemas re-seeded only when its version changed
    $env:MYSQL_PWD = ''
    $tmQ = { param($q) @(& mysql -h 127.0.0.1 -P $St.port -u root -N -B -e $q 2>&1) }
    $tmKills = @(& $tmQ "SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist WHERE id <> CONNECTION_ID() AND user <> 'event_scheduler'" | Where-Object { $_ -match '^KILL \d+;$' })
    if ($tmKills.Count) { $null = ($tmKills -join "`n") | & mysql -h 127.0.0.1 -P $St.port -u root -f 2>&1 }   # a session gone meanwhile (1094): fine
    $tmSysDbs = "'mysql','information_schema','performance_schema','sys'"
    $tmBase = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes(($script:TestMySqlBaseline | ConvertTo-Json -Compress)))).Substring(0, 12)
    $tmReseed = $St.baseline -ne $tmBase
    $tmDbs = @(& $tmQ "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($tmSysDbs)" | Where-Object { $_ -and ($tmReseed -or $_ -notin $script:TestMySqlBaseline.schemas) })
    $tmSql = @($tmDbs | ForEach-Object { "DROP DATABASE ``$_``;" }) + @(if ($tmReseed -and $script:TestMySqlBaseline.sql) { $script:TestMySqlBaseline.sql }) + 'RESET MASTER;', 'SET GLOBAL max_execution_time = DEFAULT, slow_query_log = DEFAULT;'
    $tmOut = ($tmSql -join "`n") | & mysql -h 127.0.0.1 -P $St.port -u root 2>&1
    if ($LASTEXITCODE) { throw "Start-TestMySql: reset failed: $tmOut" }
    if ($tmReseed) { $St.baseline = $tmBase; Save-TestMySqlState $tmHome $St }
    # consistency: exactly the baseline's schemas and one binlog, or this area does not start
    $tmNow = @(& $tmQ "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($tmSysDbs) ORDER BY 1") -join ','; $tmLogs = @(& $tmQ 'SHOW BINARY LOGS').Count
    if ($tmNow -ne ((@($script:TestMySqlBaseline.schemas) | Sort-Object) -join ',') -or $tmLogs -ne 1) { throw "Start-TestMySql: not at the baseline after the reset (schemas '$tmNow', $tmLogs binlog(s))" }
    [pscustomobject]@{ proc = (Get-Process -Id ([int]("$($St.server)" -split ':')[0])); port = $St.port; data = $tmData; home = $tmHome; holder = $tmHolder; lock = $tmLock }
  } catch { $tmLock.Dispose(); throw }
}
# the area is done: the lock goes to the next area; an area run alone (no suite runner) also ends its hold
function Stop-TestMySql($Server) {
  if (-not $Server) { return }
  try { if ("$($Server.holder)" -eq "$(Get-TestProcStamp $PID)") { $null = Exit-TestMySqlHolder $Server.home $PID -Locked } } finally { $Server.lock.Dispose() }
}
# a run holding the server ends: the server stops (data kept) when no live run holds it; returns how often this holder started it
# and the second kit-test servers it saw (starts, strays)
function Exit-TestMySqlHolder([string]$StateDir, [int]$Holder, [switch]$Locked) {
  if (-not (Test-Path (Join-Path $StateDir 'server.json'))) { return [pscustomobject]@{ starts = 0; strays = @() } }
  # a run that neither holds nor started it, with other live runs on it: nothing to do (the lock wait hung a guard-only run 30 min)
  $tmPeek = Read-TestMySqlState $StateDir; $tmMe0 = Get-TestProcStamp $Holder
  if (-not $Locked -and $tmMe0 -notin @($tmPeek.holders) -and "$($tmPeek.owner)" -ne $tmMe0 -and @($tmPeek.holders | Where-Object { $_ -and (Test-TestProcStamp $_) }).Count) {
    return [pscustomobject]@{ starts = 0; strays = @() } }
  $tmLock = if ($Locked) { $null } else { Enter-TestMySqlLock $StateDir }
  try {
    $tmMe = Get-TestProcStamp $Holder; $St = Read-TestMySqlState $StateDir
    $St.holders = @($St.holders | Where-Object { $_ -and $_ -ne $tmMe -and (Test-TestProcStamp $_) })
    # the run that started it stops it (K79; under the lock no other area uses it: the next take restarts it on the same data)
    if (-not $St.holders.Count -or ($tmMe -and "$($St.owner)" -eq $tmMe)) { Stop-TestMySqlServer $St; $St.server = $null; $St.owner = $null }
    Save-TestMySqlState $StateDir $St
    [pscustomobject]@{ starts = @($St.starts | Where-Object { $_ -and $_ -eq $tmMe }).Count; strays = @($St.strays | Where-Object { "$_".StartsWith("$tmMe ") }) }
  } finally { if ($tmLock) { $tmLock.Dispose() } }
}
