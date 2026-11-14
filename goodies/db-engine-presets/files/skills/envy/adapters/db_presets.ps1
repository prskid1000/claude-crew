#Requires -Version 7
# db-engine-presets (goody): dot-sourced by envy.ps1. db.engine fills the query / exec hooks an env leaves unset and, for
# mysql / mariadb, gives marks (binlog positions), flashback restores and the cascade guard (db_flashback.py); other
# engines: marks unsupported.
# Placeholders: {H} {P} {U} {N} {URI} = db.host (127.0.0.1), db.port (the engine's), db.user, db.name, db.uri
# Sections: L27 marks · L97 temp · L137 pool · L173 tenants · L290 tenant import
& { $q = '-h {H} -p {P} -U {U}'; $my = '-h {H} -P {P} -u {U}'; $ss = 'sqlcmd -S {H},{P} -U {U}'
$script:DbPresets = @{
  postgres  = @{ port = 5432; query = "psql $q -d {N} -At -c `"{sql}`""; exec = "psql $q -d {N} -v ON_ERROR_STOP=1 -f `"{file}`""; jdbc = 'jdbc:postgresql://{H}:{P}/{N}?currentSchema={schema}'; passwordEnv = 'PGPASSWORD' }
  mysql     = @{ port = 3306; query = "mysql $my -N -B -e `"{sql}`" {N}"; exec = "mysql $my --default-character-set=utf8mb4 {N} < `"{file}`""; marks = $true
                jdbc = 'jdbc:mysql://{H}:{P}/{schema}?useSSL=false&allowPublicKeyRetrieval=true'; passwordEnv = 'MYSQL_PWD' }
  sqlserver = @{ port = 1433; query = "$ss -d {N} -h -1 -Q `"{sql}`""; exec = "$ss -d {N} -b -i `"{file}`"" }
  sqlite    = @{ query = "sqlite3 `"{N}`" `"{sql}`""; exec = "sqlite3 `"{N}`" `".read {file}`"" }
  oracle    = @{ port = 1521; exec = "sqlplus -s -l {U}@{H}:{P}/{N} @{file}" }
  mongodb   = @{ port = 27017; query = "mongosh `"{URI}`" --quiet --eval `"{sql}`"" }
}
$script:DbPresets.mariadb = $script:DbPresets.mysql
$script:DbAlias = @{ postgresql = 'postgres'; pg = 'postgres'; mssql = 'sqlserver'; mongo = 'mongodb' }
foreach ($n in $(if ($script:LE.envs) { @($script:LE.envs.PSObject.Properties.Name) })) {
  $db = $script:LE.envs.$n.db; if ($db.engine -and $script:DbAlias["$($db.engine)".ToLower()]) { $db.engine = $script:DbAlias["$($db.engine)".ToLower()] }; $p = if ($db.engine) { $script:DbPresets["$($db.engine)".ToLower()] }; if (-not $p) { continue }
  $port = if ($db.port) { $db.port } else { $p.port }; $h = if ($db.host) { $db.host } else { '127.0.0.1' }
  $v = @{ H = $h; P = $port; U = "$($db.user)"; N = "$($db.name)"; URI = $(if ($db.uri) { $db.uri } else { "mongodb://${h}:$port/$($db.name)" }) }
  foreach ($k in 'query', 'exec', 'jdbc', 'passwordEnv') { if ($p.$k -and -not $db.$k) { $c = $p.$k; foreach ($x in $v.Keys) { $c = $c.Replace("{$x}", "$($v[$x])") }; $db | Add-Member $k $c -Force } }
} }

$script:DbFlashbackPy = Join-Path $PSScriptRoot 'db_flashback.py'
# ---- marks: binlog positions (mysql / mariadb); a mark costs zero bytes, the binlog keeps the changes after it
function Test-DbMarks([string]$e) { $en = "$((Get-EnvCfg $e).db.engine)".ToLower(); [bool]($en -and $script:DbPresets[$en].marks) }
function DbConn([string]$e) {
  $db = (Get-EnvCfg $e).db; $bin = if ($db.bin) { [string]$db.bin } else { '' }
  @{ host = $(if ($db.host) { "$($db.host)" } else { '127.0.0.1' }); port = "$(if ($db.port) { $db.port } else { 3306 })"; user = "$($db.user)"
     mysql = $(if ($bin) { Join-Path $bin 'mysql' } else { 'mysql' }); mysqlbinlog = $(if ($bin) { Join-Path $bin 'mysqlbinlog' } else { 'mysqlbinlog' }); mysqldump = $(if ($bin) { Join-Path $bin 'mysqldump' } else { 'mysqldump' }) }
}
# one statement through the mysql client (password: MYSQL_PWD from the env file) -> rows of tab-separated fields; throws on failure
# under CPU load the client can exit 0 with no output at all: an end marker tells 0 rows from lost ones (a read retries, a write throws)
function Invoke-DbSql([string]$e, [string]$sql, [int]$Sec = 120) {
  $c = DbConn $e; $endMark = '__kit_rows_end__'; $read = $sql -match '^\s*(SELECT|SHOW|WITH)\b' -and $sql -notmatch '(?i)\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|CALL|KILL|SET|OUTFILE|DUMPFILE)\b|;\s*\S'
  for ($try = 1; ; $try++) {
    $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe $c.mysql @('-h', $c.host, '-P', $c.port, '-u', $c.user, '-N', '-B', '-e', "$($sql.TrimEnd().TrimEnd(';')); SELECT '$endMark'") $Sec }
    if ($r.code) { throw "mysql: $(if ($r.err) { $r.err } else { $r.out })" }
    $lines = @("$($r.out)" -split "`r?`n" | Where-Object { $_ })
    if ($lines.Count -and $lines[-1] -eq $endMark) { break }
    if (-not $read -or $try -ge 3) { throw "mysql: exit 0 without the end marker ($(if ($read) { '3 tries' } else { 'a write: not retried, it may not have run' })): $($sql.Substring(0, [math]::Min(80, $sql.Length)))" }
  }
  @($lines | Select-Object -SkipLast 1 | ForEach-Object { , @($_ -split "`t") })
}
function Get-DbPos([string]$e) {
  $row = try { @(Invoke-DbSql $e 'SHOW MASTER STATUS')[0] } catch { @(Invoke-DbSql $e 'SHOW BINARY LOG STATUS')[0] }   # 8.4+ renamed it
  if (-not $row -or -not $row[0]) { throw 'no binlog position (log_bin is OFF?): envy.ps1 doctor' }
  "$($row[0]):$($row[1])"
}
function Get-DbBinlogs([string]$e) { @(Invoke-DbSql $e 'SHOW BINARY LOGS' | ForEach-Object { $_[0] }) }
# "<file>:<pos>" -> [long[]] (file number, position): marks compare in binlog order
function DbPosKey([string]$fp) { $f, $p = $fp -split ':(?=\d+$)'; @([long]([regex]::Match($f, '\d+$').Value), [long]$p) }
function Test-DbPosBefore([string]$a, [string]$b) { $x = DbPosKey $a; $y = DbPosKey $b; $x[0] -lt $y[0] -or ($x[0] -eq $y[0] -and $x[1] -lt $y[1]) }
# db_flashback.py <verb> (plan / apply / slice / structure / touched) -> its JSON; -Fail: a refusal or error throws
function Invoke-DbFb([string]$e, [string]$Verb, [string[]]$Rest, [switch]$Fail) {
  $c = DbConn $e
  # the options go in an @file (argparse, one per line): a restore's skip / exclude lists outgrow the 8191-char cmd.exe limit of a python.bat shim
  $argFile = Join-Path (Get-KitTemp) "kit-dbfb-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8)).args"
  [IO.File]::WriteAllLines($argFile, [string[]](@($Rest) + @('--host', $c.host, '--port', $c.port, '--user', $c.user, '--mysql', $c.mysql, '--mysqlbinlog', $c.mysqlbinlog, '--mysqldump', $c.mysqldump)), [Text.UTF8Encoding]::new($false))
  try { $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe (Get-Python) @('-X', 'utf8', $script:DbFlashbackPy, $Verb, "@$argFile") 7200 } }
  finally { Remove-Item -LiteralPath $argFile -Force -ErrorAction SilentlyContinue }
  $j = try { $r.out | ConvertFrom-Json -AsHashtable } catch { $null }
  if (-not $j) { throw "db_flashback.py $Verb failed (exit $($r.code)): $(@("$($r.err)" -split "`n" | Select-Object -Last 3) -join ' | ')" }
  if ($j.error -and ($Fail -or $Verb -notin 'apply', 'structure')) { throw "db_flashback.py ${Verb}: $($j.error)" }
  $j
}
function Invoke-DbFlashback([string]$e, [string]$From, [string]$To, [string[]]$Schemas, [string[]]$Skip, [string[]]$Exclude, [switch]$Apply) {
  $a = @('--from', $From, '--schemas', ($Schemas -join ','))
  if ($To) { $a += @('--to', $To) }; if ($Skip) { $a += @('--skip', ($Skip -join ',')) }; if (@($Exclude | Where-Object { $_ }).Count) { $a += @('--exclude', (@($Exclude | Where-Object { $_ }) -join ',')) }
  Invoke-DbFb $e $(if ($Apply) { 'apply' } else { 'plan' }) $a
}
# the cascade guard (db_flashback.py guard): triggers on parents of CASCADE / SET NULL foreign keys journal the child rows the
# binlog would miss; -Remove: triggers and the journal schema gone. -> its JSON (installed, kept, removed, parents)
function Install-DbGuard([string]$e, [switch]$Remove) {
  $a = @('--schemas', (@(EnvSchemas $e) -join ',')); if ($Remove) { $a += '--remove' }
  Invoke-DbFb $e 'guard' $a -Fail
}
# doctor rows for marks: binlog on, ROW, FULL images, column names (FULL metadata), retention vs the marks kept; installs the guard
function Get-DbMarkDoctor([string]$e) {
  if (-not (Test-DbMarks $e)) { return }
  $w = @{}
  try { foreach ($row in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('log_bin', 'binlog_format', 'binlog_row_image', 'binlog_row_metadata', 'binlog_expire_logs_seconds')") { $w[$row[0]] = $row[1] } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "db marks: $("$_".Split("`n")[0])" }; return }
  if ($w.log_bin -ne 'ON') { [pscustomobject]@{ level = 'WARN'; what = 'db marks: log_bin is OFF: no marks or restores (enable log-bin in the server config, restart it)' } }
  if ($w.binlog_format -ne 'ROW') { [pscustomobject]@{ level = 'WARN'; what = "db marks: binlog_format $($w.binlog_format): restores need ROW (SET PERSIST binlog_format = 'ROW')" } }
  if ($w.binlog_row_image -ne 'FULL') { [pscustomobject]@{ level = 'WARN'; what = "db marks: binlog_row_image $($w.binlog_row_image): restores need FULL (SET PERSIST binlog_row_image = 'FULL')" } }
  if ($w.binlog_row_metadata -and $w.binlog_row_metadata -ne 'FULL') { [pscustomobject]@{ level = 'WARN'; what = "db marks: binlog_row_metadata $($w.binlog_row_metadata): a table changed after a mark cannot be restored by column name (SET PERSIST binlog_row_metadata = 'FULL')" } }
  $days = [double]$w.binlog_expire_logs_seconds / 86400; $need = [double](Opt 'marks.keepDays' 30)   # TODO-PARAM (fixed default)
  if ($days -gt 0 -and $days -lt $need) { [pscustomobject]@{ level = 'WARN'; what = "db marks: the binlog keeps $([math]::Round($days, 1)) d < marks.keepDays $need d: older marks expire (SET PERSIST binlog_expire_logs_seconds = $([int]($need * 86400)))" } }
  $c = DbConn $e; if (-not (Get-Command $c.mysqlbinlog -ErrorAction SilentlyContinue)) { [pscustomobject]@{ level = 'FAIL'; what = "db marks: $($c.mysqlbinlog) not found (db.bin = the client folder)" } }
  if ($w.log_bin -ne 'ON') { return }
  try { $g = Install-DbGuard $e; if ($g.installed -or $g.removed) { [pscustomobject]@{ level = 'OK'; what = "cascade guard: $($g.installed) trigger(s) installed, $($g.removed) removed, $($g.kept) kept on $($g.parents) parent table(s)" } } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "cascade guard not installed: a restore past a cascading delete seeds the child tables ($("$_".Split("`n")[0]))" } }
}
# ---- temp: per connection temp on disk (mysql: session temp tablespaces + TempTable mmap files), the watchdog, server caps
$script:DbTempSql = "SELECT p.ID, ROUND((IFNULL(s.b, 0) + IFNULL(m.b, 0)) / 1073741824, 3), p.TIME, IFNULL(REPLACE(REPLACE(REPLACE(LEFT(p.INFO, 300), '\r', ' '), '\n', ' '), '\t', ' '), CONCAT('(', p.COMMAND, ')')) FROM information_schema.PROCESSLIST p LEFT JOIN (SELECT ID, SUM(SIZE) b FROM information_schema.INNODB_SESSION_TEMP_TABLESPACES WHERE ID > 0 GROUP BY ID) s ON s.ID = p.ID LEFT JOIN (SELECT t.PROCESSLIST_ID id, SUM(m.CURRENT_NUMBER_OF_BYTES_USED) b FROM performance_schema.memory_summary_by_thread_by_event_name m JOIN performance_schema.threads t ON t.THREAD_ID = m.THREAD_ID WHERE m.EVENT_NAME = 'memory/temptable/physical_disk' GROUP BY t.PROCESSLIST_ID) m ON m.id = p.ID WHERE p.ID <> CONNECTION_ID() AND p.USER NOT IN ('system user', 'event_scheduler') ORDER BY 2 DESC, p.TIME DESC LIMIT 20"
function Test-DbTemp([string]$e) { "$((Get-EnvCfg $e).db.engine)".ToLower() -eq 'mysql' }
# -> { id, gb, secs, query } per connection, most temp first (sleeping ones too: a session keeps its temp tablespace until it ends)
function Get-DbTempUse([string]$e) {
  if (-not (Test-DbTemp $e)) { return @() }
  @(Invoke-DbSql $e $script:DbTempSql | ForEach-Object { [pscustomobject]@{ id = $_[0]; gb = [double]$_[1]; secs = [int]$_[2]; query = "$($_[3])" } })
}
function Stop-DbConn([string]$e, [string]$Id) { if ($Id -notmatch '^\d+$') { throw "kill needs a connection id, not '$Id'" }; $null = Invoke-DbSql $e "KILL $Id" }
# the controller's watchdog: the connection using the most temp above db.tempMaxGB (default 5) is killed -> its line, else nothing
function Invoke-DbTempWatch([string]$e) {
  $max = [double]$(if ((Get-EnvCfg $e).db.tempMaxGB) { (Get-EnvCfg $e).db.tempMaxGB } else { 5 })   # owner: no query above 5 GB of temp
  $top = @(Get-DbTempUse $e)[0]; if (-not $top -or $top.gb -le $max) { return }
  Stop-DbConn $e $top.id
  "killed db connection $($top.id): $($top.gb) GB temp > db.tempMaxGB $max, $($top.secs) s: $(Protect-KitText $top.query)"
}
# doctor rows: the server's temp caps (a query's temp has a ceiling below the watchdog's line), SELECT timeout, slow log, the datadir watched
function Get-DbTempDoctor([string]$e) {
  if (-not (Test-DbTemp $e)) { return }
  $w = @{}
  try { foreach ($row in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('temptable_max_ram', 'temptable_max_mmap', 'innodb_temp_data_file_path', 'max_execution_time', 'slow_query_log', 'datadir')") { $w[$row[0]] = $row[1] } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "db temp: $("$_".Split("`n")[0])" }; return }
  $max = [double]$(if ((Get-EnvCfg $e).db.tempMaxGB) { (Get-EnvCfg $e).db.tempMaxGB } else { 5 }); $gb = { param($b) [math]::Round([double]$b / 1GB, 2) }
  $ib = if ("$($w.innodb_temp_data_file_path)" -match ':max:(\d+)([KMG])') { [double]$Matches[1] * @{ K = 1KB; M = 1MB; G = 1GB }[$Matches[2]] } elseif ("$($w.innodb_temp_data_file_path)" -notmatch 'autoextend') { 0 } else { -1 }
  $bad = @()
  if ($ib -lt 0) { $bad += "ibtmp1 has no max: it grows until the disk is full (server config [mysqld] innodb_temp_data_file_path = ibtmp1:12M:autoextend:max:1G, restart)" }
  elseif ((& $gb $ib) -gt $max) { $bad += "ibtmp1 max $(& $gb $ib) GB > db.tempMaxGB $max" }
  if ((& $gb $w.temptable_max_mmap) -gt $max) { $bad += "temptable_max_mmap $(& $gb $w.temptable_max_mmap) GB > db.tempMaxGB $max (SET PERSIST temptable_max_mmap = $([long]([math]::Min(4, $max) * 1GB)))" }
  $ram = try { [double](Get-SysMem).TotalGB } catch { 0 }   # TODO-PARAM: 1/8 of RAM (fixed default)
  if ($ram -and (& $gb $w.temptable_max_ram) -gt $ram / 8) { $bad += "temptable_max_ram $(& $gb $w.temptable_max_ram) GB > 1/8 of RAM (SET PERSIST temptable_max_ram = 1073741824)" }
  if ("$($w.max_execution_time)" -eq '0') { $bad += 'max_execution_time 0: a SELECT runs unbounded (SET PERSIST max_execution_time = 600000)' }
  if ($w.slow_query_log -ne 'ON') { $bad += "slow_query_log $($w.slow_query_log): no record of the query that filled the disk (SET PERSIST slow_query_log = ON)" }
  $nz = { param($p) "$p".Replace('\\', '\').Replace('/', '\').TrimEnd('\') + '\' }   # batch output escapes backslashes; a folder ends in one
  $dd = if ("$($w.datadir)".Trim()) { & $nz $w.datadir }; $wt = @(Get-KitSetting 'storage.watch' @() | Where-Object { "$_".Trim() } | ForEach-Object { & $nz $_ })
  if ($dd -and -not @($wt | Where-Object { $dd.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { $bad += "storage.watch lacks the db datadir $($dd.TrimEnd('\')) (kit.local.json storage.watch): the disk guard does not size it" }
  $pv = try { "$(@(Invoke-DbSql $e "SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE IN ('PROCESS', 'SUPER')")[0])" } catch { '' }
  if ($pv -eq '0') { $bad += 'the db user lacks PROCESS: dbtemp and the watchdog see only their own connection (GRANT PROCESS, CONNECTION_ADMIN)' }
  foreach ($b in $bad) { [pscustomobject]@{ level = 'WARN'; what = "db temp: $b" } }
  if (-not $bad.Count) { [pscustomobject]@{ level = 'OK'; what = "db temp: temptable_max_ram $(& $gb $w.temptable_max_ram) GB, temptable_max_mmap $(& $gb $w.temptable_max_mmap) GB, ibtmp1 $(if ($ib) { "max $(& $gb $ib) GB" } else { 'fixed size' }), max_execution_time $([int]$w.max_execution_time / 1000) s, slow log on, watchdog at $max GB" } }
}
# ---- pool: db.bufferPool (mysql) = innodb_buffer_pool_size busyMB (2048) while a lease or train is live on any env of this db
#      server, idleMB (256) once none was for idle.graceMinutes; online, chunk-aligned, one resize at a time, never mid switch-over
$script:DbPoolIdleSince = $null
function Get-DbPoolVars([string]$e) { $v = @{}; foreach ($r in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size', 'innodb_buffer_pool_chunk_size', 'innodb_buffer_pool_instances')") { $v[$r[0]] = [long]$r[1] }; $v }
function Invoke-DbPool([string]$e, [switch]$Now) {
  $b = (Get-EnvCfg $e).db.bufferPool; if (-not $b -or -not (Test-DbTemp $e)) { return }
  $me = DbConn $e; $sts = @(EnvNames | Where-Object { (Test-DbTemp $_) -and "$((DbConn $_).host):$((DbConn $_).port)" -eq "$($me.host):$($me.port)" } | ForEach-Object { Read-State $_ })
  if (@($sts | Where-Object { "$($_.train.phase)" -like 'switching*' }).Count) { return }   # a train switching over: never under it
  $busy = [bool]@($sts | Where-Object { $_.leases.Count -or $_.train }).Count
  if ($busy) { $script:DbPoolIdleSince = $null } elseif (-not $script:DbPoolIdleSince) { $script:DbPoolIdleSince = Get-Date }
  if (-not $busy -and -not $Now -and ((Get-Date) - $script:DbPoolIdleSince).TotalMinutes -lt [double](Get-KitParam 'idle.graceMinutes' 10)) { return }
  $mb = [double]$(if ($busy) { if ($b.busyMB) { $b.busyMB } else { 2048 } } elseif ($b.idleMB) { $b.idleMB } else { 256 })
  $v = Get-DbPoolVars $e; $unit = [math]::Max(1, $v.innodb_buffer_pool_chunk_size) * [math]::Max(1, $v.innodb_buffer_pool_instances)
  $want = [long]([math]::Ceiling($mb * 1MB / $unit) * $unit); if ($want -eq $v.innodb_buffer_pool_size) { return }
  $rs = @{}; foreach ($r in Invoke-DbSql $e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_resize_status%'") { $rs[$r[0]] = "$($r[1])" }
  if ($(if ($rs.Contains('Innodb_buffer_pool_resize_status_code')) { $rs.Innodb_buffer_pool_resize_status_code -notin '0', '' } else { $rs.Innodb_buffer_pool_resize_status -and $rs.Innodb_buffer_pool_resize_status -notmatch '^Completed' })) { return }
  $null = Invoke-DbSql $e "SET GLOBAL innodb_buffer_pool_size = $want"
  "db pool: innodb_buffer_pool_size $([long]($v.innodb_buffer_pool_size / 1MB)) -> $([long]($want / 1MB)) MB ($(if ($busy) { 'a lease or train is live' } else { 'idle' }))"
}
# doctor row: the pool now, its two sizes, the server's RAM (Windows: the freed pool can stay in mysqld's working set until a restart)
function Get-DbPoolDoctor([string]$e) {
  $b = (Get-EnvCfg $e).db.bufferPool; if (-not $b -or -not (Test-DbTemp $e)) { return }
  $v = try { Get-DbPoolVars $e } catch { return [pscustomobject]@{ level = 'WARN'; what = "db pool: $("$_".Split("`n")[0])" } }
  $ws = (@(Get-Process mysqld, mariadbd -ErrorAction SilentlyContinue | ForEach-Object WorkingSet64) | Measure-Object -Sum).Sum
  [pscustomobject]@{ level = 'OK'; what = "db pool: innodb_buffer_pool_size $([long]($v.innodb_buffer_pool_size / 1MB)) MB (db.bufferPool busy $(if ($b.busyMB) { $b.busyMB } else { 2048 }) / idle $(if ($b.idleMB) { $b.idleMB } else { 256 }) MB); server RAM $(if ($ws) { "$([long]($ws / 1MB)) MB" } else { 'unknown (no local mysqld)' })" }
}
# doctor rows: db.expect { <server variable>: <value> } = the server settings the env wants (buffer pool, redo log, flush, ...)
function Get-DbExpectDoctor([string]$e) {
  $x = (Get-EnvCfg $e).db.expect; if (-not (Test-DbMarks $e) -or -not $x) { return }
  $want = @{}; foreach ($p in @($x.PSObject.Properties | Where-Object { $_.Name -notlike '_*' -and -not ($_.Name -eq 'innodb_buffer_pool_size' -and (Get-EnvCfg $e).db.bufferPool) })) { $want[$p.Name] = "$($p.Value)" }   # db.bufferPool owns the pool
  if (-not $want.Count) { return }
  $cur = @{}; try { foreach ($r in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ($(@($want.Keys | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '))") { $cur[$r[0]] = $r[1] } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "db.expect: $("$_".Split("`n")[0])" }; return }
  $num = { param($v) if ("$v" -match '^(\d+(?:\.\d+)?)([KMG])$') { [double]$Matches[1] * @{ K = 1KB; M = 1MB; G = 1GB }[$Matches[2].ToUpper()] } elseif ("$v" -match '^\d+(\.\d+)?$') { [double]$v } else { "$v".ToUpper() } }
  foreach ($k in @($want.Keys | Sort-Object)) { if ("$(& $num $cur[$k])" -ne "$(& $num $want[$k])") { [pscustomobject]@{ level = 'WARN'; what = "db $k = $(if ($null -ne $cur[$k]) { $cur[$k] } else { 'unknown' }), db.expect $($want[$k]) (server config [mysqld] $k = $($want[$k]); restart with no lease)" } } }
}
# ---- tenants: local tenants nobody keeps dropped (envs.<env>.tenants; mysql / mariadb): admin rows (the registry row, its FK
#      children found in information_schema, tenants.tables by idColumns / nameColumns), users no other tenant has, the schema
function TenantCfg([string]$e) {
  $t = (Get-EnvCfg $e).tenants
  if (-not (Test-DbMarks $e) -or -not $t.schema -or -not $t.table) { throw "[$e] tenant needs db.engine mysql / mariadb and envs.$e.tenants { schema, table, key, name } (envy SKILL.md)" }
  $t
}
function SqlQ([string]$v) { "'" + $v.Replace('\', '\\').Replace("'", "''") + "'" }
function SqlId([string]$n) { '`' + $n.Replace('`', '``') + '`' }
function SqlIn([string]$col, $vals) { if (-not @($vals).Count) { return '1 = 0' }; "$(SqlId $col) IN ($((@($vals) | Select-Object -Unique | ForEach-Object { SqlQ "$_" }) -join ', '))" }
# id -> name of every registry row
function Get-TenantRows([string]$e) {
  $t = TenantCfg $e; $key = if ($t.key) { [string]$t.key } else { 'id' }; $nm = if ($t.name) { [string]$t.name } else { 'name' }
  @(Invoke-DbSql $e "SELECT $(SqlId $key), $(SqlId $nm) FROM $(SqlId $t.schema).$(SqlId $t.table)" | ForEach-Object { [pscustomobject]@{ id = $_[0]; name = $_[1] } })
}
# why a tenant stays: tenants.keep, or its name as a word in a keepFrom file (default: kit.local.json, targets.local.json, the
# seed file; { file, keys } = only the top-level keys matching that regex) -> name -> reason
function Get-TenantKeep([string]$e, [string[]]$names) {
  $t = TenantCfg $e; $why = @{}
  foreach ($n in @($t.keep | Where-Object { $_ })) { $why["$n"] = 'tenants.keep' }
  $from = if ($t.keepFrom) { @($t.keepFrom) } else { @($KitConf.ConfigFile, (Join-Path $KitConf.Kit 'skills/pokey/targets.local.json'), (SeedFile $e)) }
  $none = [pscustomobject]@{ port = '' }; $read = 0
  foreach ($src in $from | Where-Object { $_ }) {
    $file = Expand-Placeholders ([string]$(if ($src -is [string]) { $src } else { $src.file })) $e $none $KitConf.Workspace ''
    if (-not (Test-Path -LiteralPath $file)) { if ($t.keepFrom) { throw "[$e] tenants.keepFrom $file does not exist: fix the path (a keep source must be readable)" }; continue }
    $read++
    $text = Get-Content -LiteralPath $file -Raw
    if ($src -isnot [string] -and $src.keys) { $j = $text | ConvertFrom-Json; $text = (@($j.PSObject.Properties | Where-Object Name -match ([string]$src.keys) | ForEach-Object { $_.Value | ConvertTo-Json -Depth 20 }) -join "`n") }
    foreach ($n in $names) { if (-not $why[$n] -and $text -match "(?i)(?<![\w-])$([regex]::Escape($n))(?![\w-])") { $why[$n] = "named in $(Split-Path $file -Leaf)" } }
  }
  if (-not $read -and -not @($t.keep | Where-Object { $_ }).Count) { throw "[$e] tenant: no keep source (tenants.keep empty, no keepFrom file readable): refused, nothing would be kept" }
  $why
}
# the delete plan of one tenant: [ { table, where } ] parents first (children reached by information_schema foreign keys from
# the registry, the users table and tenants.tables), + the schema; $others = tenant schemas that stay (users they have are kept)
function Get-TenantPlan([string]$e, [string]$name, [string[]]$others, [switch]$NoUsers) {
  $t = TenantCfg $e; $adm = [string]$t.schema; $key = if ($t.key) { [string]$t.key } else { 'id' }; $nm = if ($t.name) { [string]$t.name } else { 'name' }
  $q = { param($sql) @(Invoke-DbSql $e $sql 600) }   # TODO-PARAM (fixed default)
  $fks = @(& $q "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_NAME IS NOT NULL")
  $multi = @{}; foreach ($g in $fks | Group-Object { "$($_[0])|$($_[4])" } | Where-Object Count -gt 1) { $multi[$g.Name] = $true }   # a composite FK: a one-column match would over-delete
  $ids = @(& $q "SELECT $(SqlId $key) FROM $(SqlId $adm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $name)" | ForEach-Object { $_[0] })
  $steps = [Collections.Generic.List[object]]::new(); $seen = @{}; $todo = [Collections.Generic.Queue[object]]::new()
  $push = { param($tb, $where) $k = "$tb|$where"; if (-not $seen[$k] -and $where -ne '1 = 0') { $seen[$k] = $true; $todo.Enqueue(@{ table = $tb; where = $where }) } }
  if ($ids.Count) { & $push $t.table (SqlIn $key $ids) }
  $cols = @{}; foreach ($r in & $q "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $adm)") { if (-not $cols[$r[0]]) { $cols[$r[0]] = @() }; $cols[$r[0]] += $r[1] }
  $idc = if ($t.idColumns) { @($t.idColumns) } else { @('tenant_id') }; $nmc = if ($t.nameColumns) { @($t.nameColumns) } else { @('tenant_name') }
  foreach ($tb in @($t.tables | Where-Object { $_ -and $_ -ne $t.table })) {
    $w = @(@($cols[$tb] | Where-Object { $_ -in $idc } | ForEach-Object { SqlIn $_ $ids }) + @($cols[$tb] | Where-Object { $_ -in $nmc } | ForEach-Object { SqlIn $_ @($name) }) | Where-Object { $_ -ne '1 = 0' })
    if ($w.Count) { & $push $tb ($w -join ' OR ') } elseif (-not $cols[$tb]) { $steps.Add(@{ table = $tb; missing = $true }) }
  }
  if ($t.users -and $t.users.table -and -not $NoUsers) {   # admin users of this tenant's own user table that no staying tenant schema has
    $uk = if ($t.users.key) { [string]$t.users.key } else { 'login' }; $tt = if ($t.users.tenantTable) { [string]$t.users.tenantTable } else { [string]$t.users.table }; $tk = if ($t.users.tenantKey) { [string]$t.users.tenantKey } else { $uk }
    $has = { param($sc) try { @(& $q "SELECT DISTINCT $(SqlId $tk) FROM $(SqlId $sc).$(SqlId $tt)" | ForEach-Object { $_[0] }) } catch { if ("$_" -match '\b1146\b') { @() } else { throw "[$e] tenant: the users of $sc are unreadable ($("$_".Split("`n")[0])): refused, a kept user could go" } } }   # 1146: no such table
    $mine = @(& $has $name); $kept = @{}; foreach ($o in $others) { foreach ($u in & $has $o) { $kept["$u"] = $true } }
    & $push $t.users.table (SqlIn $uk @($mine | Where-Object { -not $kept["$_"] }))
  }
  for ($i = 0; $todo.Count -and $i -lt 500; $i++) {   # TODO-PARAM (fixed default)
    $n = $todo.Dequeue(); $steps.Add($n)
    foreach ($fk in $fks | Where-Object { $_[2] -eq $n.table }) {
      if ($multi["$($fk[0])|$($fk[4])"]) { throw "[$e] tenant: $($fk[0]) references $($n.table) by the composite key $($fk[4]): not supported, drop by hand" }
      $vals = @(& $q "SELECT DISTINCT $(SqlId $fk[3]) FROM $(SqlId $adm).$(SqlId $n.table) WHERE $($n.where)" | ForEach-Object { $_[0] } | Where-Object { $_ -ne 'NULL' })
      & $push $fk[0] (SqlIn $fk[1] $vals)
    }
  }
  foreach ($s in $steps | Where-Object { -not $_.missing }) { $s.rows = [int]@(& $q "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $s.table) WHERE $($s.where)")[0][0] }
  $mb = @(& $q "SELECT ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1), COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $name)")[0]
  $schema = [bool]@(& $q "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $name)").Count
  @{ name = $name; ids = $ids; steps = @($steps); schema = $schema; mb = [double]$mb[0]; tables = [int]$mb[1] }
}
# every tenant of the env (the registry + schemas no env's registry or admin names) with its keep reason and size
function Get-TenantList([string]$e) {
  $t = TenantCfg $e; $rows = @(Get-TenantRows $e)
  $mine = @($rows.name); $taken = @(foreach ($n in EnvNames) { $db = (Get-EnvCfg $n).db; "$($db.name)"; @($db.schemas | Where-Object { $_ }); $c = (Get-EnvCfg $n).tenants; if ($c.schema) { [string]$c.schema; if ($n -ne $e) { try { @(Get-TenantRows $n).name } catch { } } } })   # every env's own schemas and admin schema
  $sys = @('mysql', 'sys', 'information_schema', 'performance_schema')
  $orph = @(Invoke-DbSql $e 'SELECT SCHEMA_NAME FROM information_schema.SCHEMATA' | ForEach-Object { $_[0] } | Where-Object { $_ -notin $sys -and $_ -notin $mine -and $_ -notin $taken -and $_ -notlike 'kit_*' })
  $keep = Get-TenantKeep $e (@($mine) + @($orph))
  $size = @{}; foreach ($r in Invoke-DbSql $e "SELECT TABLE_SCHEMA, ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1) FROM information_schema.TABLES GROUP BY TABLE_SCHEMA") { $size[$r[0]] = [double]$r[1] }
  @(@($mine | ForEach-Object { [pscustomobject]@{ name = $_; registry = $true; keep = $keep[$_]; mb = [double]$size[$_] } }) + @($orph | ForEach-Object { [pscustomobject]@{ name = $_; registry = $false; keep = $keep[$_]; mb = [double]$size[$_] } }))
}
# drop: refused for a kept tenant, a system or admin schema, or while any lease, hold or train is on the env; per tenant one
# transaction (children first, foreign key checks off inside it: the registry and its children reference each other), the
# schema after it commits; then every planned table counted again (0 left) and the env's smoke checks + tenants.verify ({tenant})
function Invoke-TenantDrop([string]$e, [string[]]$names, [switch]$DryRun) {
  $t = TenantCfg $e; $adm = [string]$t.schema; $list = @(Get-TenantList $e); $bad = @()
  foreach ($n in $names) {
    $x = @($list | Where-Object name -eq $n)[0]
    if (-not $x) { $bad += "$n : no such tenant (registry row or schema)" } elseif ($x.keep) { $bad += "$n : kept ($($x.keep))" }
  }
  if ($bad.Count) { throw "[$e] tenant drop refused: $($bad -join '; ')" }
  $st = Read-State $e
  if (-not $DryRun -and ($st.train -or $st.leases.Count -or $st.holds.Count)) { throw "[$e] tenant drop refused: the env is in use ($(@(@($st.leases.Keys) + @($st.holds.Keys) + @($(if ($st.train) { "train $($st.train.id)" }))) -join ', ')): run it with no lease, hold or train" }
  $stay = @($list | Where-Object { $_.name -notin $names } | ForEach-Object name)
  foreach ($n in $names) {
    $p = Get-TenantPlan $e $n $stay; $del = @($p.steps | Where-Object { -not $_.missing })
    "[$e] tenant $n : schema $(if ($p.schema) { "$($p.mb) MB in $($p.tables) table(s)" } else { 'gone' }); admin rows: $(if ($del.Count) { @($del | ForEach-Object { "$($_.table) $($_.rows)" }) -join ', ' } else { 'none' })$(if (@($p.steps | Where-Object missing).Count) { "; not in $adm : $(@($p.steps | Where-Object missing | ForEach-Object table) -join ', ')" })"
    if ($DryRun) { continue }
    $sql = (@('SET FOREIGN_KEY_CHECKS = 0', 'START TRANSACTION') + @(for ($i = $del.Count - 1; $i -ge 0; $i--) { "DELETE FROM $(SqlId $adm).$(SqlId $del[$i].table) WHERE $($del[$i].where)" }) + @('COMMIT', 'SET FOREIGN_KEY_CHECKS = 1')) -join '; '
    $null = Invoke-DbSql $e $sql 1800   # one transaction: an error rolls it all back (the client exits before COMMIT)
    if ($p.schema) { $null = Invoke-DbSql $e "DROP DATABASE IF EXISTS $(SqlId $n)" 1800 }
    $left = @($del | Where-Object { [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $_.table) WHERE $($_.where)")[0][0] } | ForEach-Object table)
    $gone = -not @(Invoke-DbSql $e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $n)").Count
    Event $e 'tenant-drop' @{ tenant = $n; mb = $p.mb; rows = @($del | ForEach-Object { "$($_.table)=$($_.rows)" }); left = $left; schemaGone = $gone }
    if ($left.Count -or -not $gone) { throw "[$e] tenant $n : references left in $($left -join ', ')$(if (-not $gone) { '; the schema is still there' })" }
    "[$e] tenant $n dropped: $(@($del | Measure-Object rows -Sum).Sum) admin row(s), $($p.mb) MB; 0 references left"
    $stay = @($stay | Where-Object { $_ -ne $n })
  }
  if ($DryRun) { return }
  $sf = Test-Smoke $e; if ($sf) { throw "[$e] tenant drop: smoke check failed after it: $sf" }
  $okv = [Collections.Generic.List[string]]::new()
  $bad = @(foreach ($k in @($list | Where-Object { $t.verify -and $_.keep -and $_.registry } | ForEach-Object name)) {
    $code = Invoke-Shell (Expand-Placeholders ([string]$t.verify) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '').Replace('{tenant}', $k) (LogFile $e 'tenant') (EnvVars $e ([pscustomobject]@{})) 120
    if ($code) { "$k ($(Get-ShellWhy $code): $((@($script:ShellOut) | Select-Object -Last 1) -join ' | '))" } else { $okv.Add("[$e] kept tenant $k : verify ok") }
  })
  $okv
  if ($bad.Count) { throw "[$e] tenant drop done, but kept tenant(s) fail tenants.verify: $($bad -join '; ')" }
}

# ---- tenant import: one tenant schema from a read-only, non-production source (tenants.import.sources), masked by a profile
#      (db_flashback.py mask, cached per source + tenant + profile), loaded as a new schema, registered by cloning the registry
#      rows of tenants.import.template (new ids, name columns = the new name, tenants.import.set on top)
function Get-ImportCfg([string]$e) { $t = TenantCfg $e; if (-not $t.import -or -not $t.import.sources) { throw "[$e] tenant import needs envs.$e.tenants.import { sources, template, profiles } (envy SKILL.md)" }; $t.import }
function Get-ImportProdRe($ic) { if ($ic.prodPattern) { [string]$ic.prodPattern } else { '(?i)(^|[^a-z])(prod|production|live)([^a-z]|$)' } }
# source credentials by name: creds = a command printing JSON { host, port, user | username, password } (never shown), or host /
# port / user + passwordEnv (a variable of the env file); refused when marked prod or its name / host matches prodPattern
function Get-ImportSource([string]$e, [string]$from) {
  $ic = Get-ImportCfg $e; $s = $ic.sources.$from; $pp = Get-ImportProdRe $ic
  if (-not $s) { throw "[$e] no import source '$from' (tenants.import.sources: $(@($ic.sources.PSObject.Properties.Name) -join ', '))" }
  if ($s.prod -or $from -match $pp) { throw "[$e] tenant import refused: source '$from' is production (prod: true or the name matches prodPattern); only test / staging copies are imported" }
  $c = @{ host = "$($s.host)"; port = "$($s.port)"; user = "$($s.user)"; password = ''; cfg = $s }
  if ($s.creds) {
    $r = if ($KitIsWindows) { Invoke-KitExe 'cmd.exe' @() 120 -Raw "/d /s /c `"$($s.creds)`"" } else { Invoke-KitExe '/bin/sh' @('-c', [string]$s.creds) 120 }   # TODO-PARAM (fixed default)
    if ($r.code) { throw "[$e] import source '$from': its creds command failed (exit $($r.code))" }   # its output may hold the secret: never shown
    $j = try { $r.out | ConvertFrom-Json } catch { $null }
    if (-not $j -or -not $j.password) { throw "[$e] import source '$from': its creds command printed no JSON object with host, user, password" }
    if (-not $c.host) { $c.host = "$($j.host)" }; if (-not $c.port) { $c.port = "$($j.port)" }; if (-not $c.user) { $c.user = "$(if ($j.user) { $j.user } else { $j.username })" }
    $c.password = "$($j.password)"
  } elseif ($s.passwordEnv) { $c.password = "$((EnvVars $e ([pscustomobject]@{}))[[string]$s.passwordEnv])" }
  if (-not $c.port) { $c.port = '3306' }
  if (-not $c.host -or -not $c.user) { throw "[$e] import source '$from': no host / user (set them, or a creds command that prints them)" }
  if ($c.host -match $pp) { throw "[$e] tenant import refused: source '$from' host is production (matches prodPattern)" }
  $c
}
# read-only statements on the source -> rows (the end marker as in Invoke-DbSql)
function Invoke-SrcSql($c, [string]$e, [string]$sql) {
  $r = With-Env @{ MYSQL_PWD = $c.password } { Invoke-KitExe (DbConn $e).mysql @('-h', $c.host, '-P', $c.port, '-u', $c.user, '--default-character-set=utf8mb4', '-N', '-B', '-e', "$sql; SELECT '__kit_rows_end__'") 300 }   # TODO-PARAM (fixed default)
  if ($r.code) { throw "source mysql: $(Protect-KitText "$($r.err)".Split("`n")[-1])" }
  $lines = @("$($r.out)" -split "`r?`n" | Where-Object { $_ })
  if (-not $lines.Count -or $lines[-1] -ne '__kit_rows_end__') { throw "source mysql: exit 0 without the end marker: $($sql.Substring(0, [math]::Min(80, $sql.Length)))" }
  @($lines | Select-Object -SkipLast 1 | ForEach-Object { , @($_ -split "`t") })
}
# the registry rows of a new tenant $as, cloned from $tpl's: one transaction, foreign key checks off inside it; each row a new
# auto-increment id; FK and idColumns values that point at a cloned row follow it; name columns = $as; $set { table.column: value }
function Get-TenantCloneSql([string]$e, [string]$tpl, [string]$as, $set) {
  $t = TenantCfg $e; $ic = Get-ImportCfg $e; $adm = [string]$t.schema; $key = if ($t.key) { [string]$t.key } else { 'id' }; $nm = if ($t.name) { [string]$t.name } else { 'name' }
  $idc = if ($t.idColumns) { @($t.idColumns) } else { @('tenant_id') }; $nmc = if ($t.nameColumns) { @($t.nameColumns) } else { @('tenant_name') }
  $steps = @((Get-TenantPlan $e $tpl @() -NoUsers).steps | Where-Object { -not $_.missing -and $_.table -notin @($ic.skipTables) -and $_.rows })
  $fks = @(Invoke-DbSql $e "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_NAME IS NOT NULL")
  $rows = [Collections.Generic.List[object]]::new(); $map = @{}; $sql = [Collections.Generic.List[string]]::new(); $sql.Add('SET FOREIGN_KEY_CHECKS = 0'); $sql.Add('START TRANSACTION')
  foreach ($s in $steps) {
    $cols = @(Invoke-DbSql $e "SELECT COLUMN_NAME, EXTRA, COLUMN_KEY, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $adm) AND TABLE_NAME = $(SqlQ $s.table) ORDER BY ORDINAL_POSITION")
    $pk = @($cols | Where-Object { $_[2] -eq 'PRI' }); $ai = @($pk | Where-Object { $_[1] -match 'auto_increment' })
    if ($pk.Count -ne 1 -or $ai.Count -ne 1) { throw "[$e] tenant import: $adm.$($s.table) has no single auto-increment primary key: its rows cannot be cloned (add it to tenants.import.skipTables)" }
    $pc = [string]$pk[0][0]; $plain = @($cols | Where-Object { $_[0] -ne $pc -and $_[1] -notmatch 'GENERATED' } | ForEach-Object { [string]$_[0] })
    $txt = @($cols | Where-Object { $_[3] -match 'char|text' } | ForEach-Object { [string]$_[0] })   # a text value equal to the template's name names the new tenant
    $old = @(Invoke-DbSql $e "SELECT $(SqlId $pc) FROM $(SqlId $adm).$(SqlId $s.table) WHERE $($s.where)" | ForEach-Object { $_[0] })
    if ($rows.Count + $old.Count -gt 200) { throw "[$e] tenant import: the template $tpl has over 200 registry rows to clone ($($s.table)): add log / history tables to tenants.import.skipTables" }   # TODO-PARAM (fixed default)
    foreach ($o in $old | Where-Object { -not $map["$($s.table)|$_"] }) {   # a table reached twice (an FK and tenants.tables): each row once
      $v = "@kit_k$($rows.Count)"; $map["$($s.table)|$o"] = $v
      $sel = @($plain | ForEach-Object { if ($_ -in $nmc -or ($s.table -eq $t.table -and $_ -eq $nm)) { SqlQ $as } elseif ($_ -in $txt) { "IF($(SqlId $_) = $(SqlQ $tpl), $(SqlQ $as), $(SqlId $_))" } else { SqlId $_ } })
      $sql.Add("INSERT INTO $(SqlId $adm).$(SqlId $s.table) ($(@($plain | ForEach-Object { SqlId $_ }) -join ', ')) SELECT $($sel -join ', ') FROM $(SqlId $adm).$(SqlId $s.table) WHERE $(SqlId $pc) = $(SqlQ $o)")
      $sql.Add("SET $v = LAST_INSERT_ID()"); $rows.Add(@{ table = $s.table; pk = $pc; old = $o; var = $v; cols = $plain })
    }
  }
  if (-not @($rows | Where-Object table -eq $t.table).Count) { throw "[$e] tenant import: template $tpl has no $adm.$($t.table) row" }
  foreach ($r in $rows) {   # references to cloned rows follow them (the template's values were copied)
    $refs = @(foreach ($fk in $fks | Where-Object { $_[0] -eq $r.table }) { , @($fk[1], $fk[2]) })
    $refs += @($r.cols | Where-Object { $_ -in $idc -and $_ -notin @($refs | ForEach-Object { $_[0] }) } | ForEach-Object { , @($_, [string]$t.table) })
    foreach ($ref in $refs) {
      $to = @($rows | Where-Object table -eq $ref[1]); if (-not $to.Count) { continue }
      $sql.Add("UPDATE $(SqlId $adm).$(SqlId $r.table) SET $(SqlId $ref[0]) = CASE $(SqlId $ref[0]) $(@($to | ForEach-Object { "WHEN $(SqlQ $_.old) THEN $($_.var)" }) -join ' ') ELSE $(SqlId $ref[0]) END WHERE $(SqlId $r.pk) = $($r.var)")
    }
  }
  foreach ($k in @($set.Keys)) {
    $tb, $col = $k -split '\.', 2; $to = @($rows | Where-Object table -eq $tb)
    if (-not $to.Count -or -not $col) { throw "[$e] tenants.import.set $k : no cloned $adm table $tb (cloned: $(@($rows.table | Select-Object -Unique) -join ', '))" }
    $sql.Add("UPDATE $(SqlId $adm).$(SqlId $tb) SET $(SqlId $col) = $(if ($null -eq $set[$k]) { 'NULL' } else { SqlQ "$($set[$k])" }) WHERE $(SqlId $to[0].pk) IN ($(@($to.var) -join ', '))")
  }
  $sql.Add('COMMIT'); $sql.Add('SET FOREIGN_KEY_CHECKS = 1')
  @{ sql = $sql -join '; '; rows = @($rows); counts = @($rows | Group-Object { $_.table } | ForEach-Object { "$($_.Name) $($_.Count)" }) }
}
# import: refused for a production or writable source, a taken name, a missing template, a schema over maxMB, or while any lease,
# hold or train is on; -DryRun: the checks and the plan, no data read; a failed load or registration drops the new schema again
function Invoke-TenantImport([string]$e, [string]$From, [string]$Tenant, [string]$As, [string]$Mask, [switch]$DryRun) {
  if (-not $From -or -not $Tenant -or -not $Mask) { throw 'tenant import needs -From <source> -Tenant <schema> -Mask <profile> [-As <name>]' }
  if (-not $As) { $As = $Tenant }
  foreach ($x in $Tenant, $As) { if ($x -notmatch '^[A-Za-z0-9_]{1,64}\z') { throw "tenant import: '$x' is no plain schema name (letters, digits, _)" } }
  $t = TenantCfg $e; $ic = Get-ImportCfg $e; $adm = [string]$t.schema; $key = if ($t.key) { [string]$t.key } else { 'id' }; $nm = if ($t.name) { [string]$t.name } else { 'name' }
  $prof = if ($ic.profiles.$Mask) { $ic.profiles.$Mask } elseif ($Mask -eq 'personal') { [pscustomobject]@{} } else { throw "[$e] no mask profile '$Mask' (tenants.import.profiles: $(@($ic.profiles.PSObject.Properties.Name) -join ', '); built in: personal)" }
  $tpl = [string]$ic.template; if (-not $tpl) { throw "[$e] tenant import needs tenants.import.template (a local tenant whose registry rows are cloned)" }
  $c = Get-ImportSource $e $From
  $reg = @(Get-TenantRows $e)
  if (@(Invoke-DbSql $e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $As)").Count -or @($reg | Where-Object name -eq $As).Count) { throw "[$e] tenant import refused: $As exists here (schema or registry row): envy.ps1 tenant drop -Env $e -Name $As first, or -As <another name>" }
  if (-not @($reg | Where-Object name -eq $tpl).Count) { throw "[$e] tenant import: the template tenant $tpl has no registry row here (tenants.import.template)" }
  $busy = { $st = Read-State $e; if ($st.train -or $st.leases.Count -or $st.holds.Count) { throw "[$e] tenant import refused: the env is in use ($(@(@($st.leases.Keys) + @($st.holds.Keys) + @($(if ($st.train) { "train $($st.train.id)" }))) -join ', ')): run it with no lease, hold or train" } }
  if (-not $DryRun) { & $busy }
  $ro = @(Invoke-SrcSql $c $e 'SELECT @@read_only')[0][0]
  if ($c.cfg.requireReadOnly -ne $false -and "$ro" -ne '1') { throw "[$e] tenant import refused: source '$From' is writable (@@read_only = $ro): import only from a read-only replica (requireReadOnly: false for a scratch copy)" }
  $sz = @(Invoke-SrcSql $c $e "SELECT COUNT(*), ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1), SUM(TABLE_TYPE = 'BASE TABLE') FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $Tenant)")[0]
  $cs = @(Invoke-SrcSql $c $e "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $Tenant)")
  if (-not $cs.Count -or -not [int]$sz[0]) { throw "[$e] tenant import: no schema $Tenant with tables on source '$From'" }
  $max = if ($c.cfg.maxMB) { [double]$c.cfg.maxMB } else { 500 }   # TODO-PARAM (fixed default)
  if ([double]$sz[1] -gt $max) { throw "[$e] tenant import refused: $Tenant is $($sz[1]) MB on '$From', over maxMB $max (a smaller tenant, or raise the source's maxMB)" }
  $idc = if ($t.idColumns) { @($t.idColumns) } else { @('tenant_id') }; $nmc = if ($t.nameColumns) { @($t.nameColumns) } else { @('tenant_name') }
  $set = [ordered]@{}; $srcAdm = if ($c.cfg.adminSchema) { [string]$c.cfg.adminSchema } else { $adm }
  $sid = @(Invoke-SrcSql $c $e "SELECT $(SqlId $key) FROM $(SqlId $srcAdm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $Tenant)" | ForEach-Object { $_[0] })
  foreach ($p in @($ic.set.PSObject.Properties)) {   # {tenant} = the new name; {source:<table>.<column>} = that value of the tenant's source registry rows
    $v = $p.Value
    if ($v -is [string] -and $v -match '^\{source:(\w+)\.(\w+)\}$') {
      $tb = $Matches[1]; $col = $Matches[2]
      $w = if ($tb -eq $t.table) { "$(SqlId $nm) = $(SqlQ $Tenant)" } else { $sc = @(Invoke-SrcSql $c $e "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $srcAdm) AND TABLE_NAME = $(SqlQ $tb)" | ForEach-Object { $_[0] }); @(@($sc | Where-Object { $_ -in $idc } | ForEach-Object { SqlIn $_ $sid }) + @($sc | Where-Object { $_ -in $nmc } | ForEach-Object { SqlIn $_ @($Tenant) }) | Where-Object { $_ -ne '1 = 0' }) -join ' OR ' }
      $got = @(); if ($w) { $got = @(Invoke-SrcSql $c $e "SELECT $(SqlId $col) FROM $(SqlId $srcAdm).$(SqlId $tb) WHERE $w ORDER BY 1 DESC LIMIT 1") }   # an if as the value would unroll the one row
      if (-not $got.Count) { throw "[$e] tenants.import.set $($p.Name): no $srcAdm.$tb row of $Tenant on '$From'" }
      $v = if ($got[0][0] -eq 'NULL') { $null } else { $got[0][0] }
    } elseif ($v -is [string]) { $v = $v.Replace('{tenant}', $As) }
    $set[$p.Name] = $v
  }
  $plan = Get-TenantCloneSql $e $tpl $As $set
  "[$e] tenant import $From/$Tenant -> $As : $($sz[1]) MB in $($sz[0]) table(s), source read_only $ro; mask $Mask; registry rows from $tpl ($($plan.counts -join ', '))$(if ($set.Count) { "; set $(@($set.Keys) -join ', ')" })"
  if ($DryRun) { return }
  $dir = Join-Path (Get-KitPath cache -Create) 'tenant-import'; New-Item -ItemType Directory -Force $dir | Out-Null
  $pj = $prof | ConvertTo-Json -Depth 10 -Compress   # the cache key: the profile + the masker's own code (a kit update masks again)
  $ph = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pj + (Get-FileHash -LiteralPath $script:DbFlashbackPy).Hash))).Substring(0, 8).ToLower()
  $file = Join-Path $dir "$From-$Tenant-$Mask-$ph.sql"; $hours = if ($ic.cacheHours) { [double]$ic.cacheHours } else { 24 }   # TODO-PARAM (fixed default)
  if ((Test-Path -LiteralPath $file) -and ((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime).TotalHours -lt $hours) { "[$e] masked dump reused: $file (under $hours h old; the source is not read again)" }
  else {
    $pf = "$file.profile.json"; [IO.File]::WriteAllText($pf, $pj, [Text.UTF8Encoding]::new($false))
    $r = With-Env @{ KIT_SRC_PWD = $c.password } { Invoke-KitExe (Get-Python) @('-X', 'utf8', $script:DbFlashbackPy, 'mask', '--schema', $Tenant, '--out', $file, '--profile', $pf, '--host', $c.host, '--port', $c.port, '--user', $c.user, '--mysqldump', (DbConn $e).mysqldump) 7200 }   # TODO-PARAM (fixed default)
    $m = try { $r.out | ConvertFrom-Json } catch { $null }
    if ($r.code -or -not $m -or $m.error) { throw "[$e] tenant import: dump + mask failed: $(if ($m.error) { $m.error } else { "exit $($r.code) $(@("$($r.err)" -split "`n")[-1])" })" }
    "[$e] masked dump: $($m.tables) table(s), $($m.rows) row(s), $([math]::Round($m.bytes / 1MB, 1)) MB; masked $(@($m.masked.PSObject.Properties).Count) column(s), $($m.emailsInText) text value(s) with emails$(if (@($m.skippedData).Count) { "; data skipped: $(@($m.skippedData) -join ', ')" })"
  }
  $want = [int]$sz[2]; $db = DbConn $e
  & $busy   # the dump can take minutes: a lease may have started since
  try {
    $null = Invoke-DbSql $e "CREATE DATABASE $(SqlId $As) CHARACTER SET $(SqlQ $cs[0][0]) COLLATE $(SqlQ $cs[0][1])"
    $ld = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe $db.mysql @('-h', $db.host, '-P', $db.port, '-u', $db.user, '--default-character-set=utf8mb4', $As, '-e', "source $($file.Replace('\', '/'))") 7200 }   # TODO-PARAM (fixed default)
    if ($ld.code) { throw "load failed: $(@("$($ld.err)" -split "`n" | Where-Object { $_ })[-1])" }
    $have = [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $As) AND TABLE_TYPE = 'BASE TABLE'")[0][0]
    if ($have -ne $want) { throw "load incomplete: $have of $want table(s)" }
    $null = Invoke-DbSql $e $plan.sql 600   # TODO-PARAM (fixed default)
    $nid = @(Invoke-DbSql $e "SELECT $(SqlId $key) FROM $(SqlId $adm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $As)")
    if ($nid.Count -ne 1) { throw "registration: $($nid.Count) $adm.$($t.table) row(s) named $As" }
  } catch {
    $why = "$_".Split("`n")[0]
    $left = 'its registry rows rolled back'
    try {   # registry rows that committed (a failed check after COMMIT) go the way tenant drop takes them; only what this import made
      if (@(Get-TenantRows $e | Where-Object name -eq $As).Count) {
        $del = @((Get-TenantPlan $e $As @() -NoUsers).steps | Where-Object { -not $_.missing -and $_.rows })
        $null = Invoke-DbSql $e ((@('SET FOREIGN_KEY_CHECKS = 0', 'START TRANSACTION') + @(for ($i = $del.Count - 1; $i -ge 0; $i--) { "DELETE FROM $(SqlId $adm).$(SqlId $del[$i].table) WHERE $($del[$i].where)" }) + @('COMMIT', 'SET FOREIGN_KEY_CHECKS = 1')) -join '; ') 600
        $left = 'its registry rows deleted'
      }
    } catch { $left = "its registry rows are left: envy.ps1 tenant drop -Env $e -Name $As ($("$_".Split("`n")[0]))" }
    try { $null = Invoke-DbSql $e "DROP DATABASE IF EXISTS $(SqlId $As)" 600 } catch { }   # only the schema this import created
    throw "[$e] tenant import of $As failed, its schema dropped again, ${left}: $why"
  }
  Event $e 'tenant-import' @{ tenant = $As; from = "$From/$Tenant"; mask = $Mask; tables = $want; registry = $plan.counts }
  "[$e] tenant $As imported: $want table(s), registry $adm.$($t.table) id $($nid[0][0]) ($($plan.counts -join ', '))"
}
