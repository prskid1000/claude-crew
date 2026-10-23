#Requires -Version 7
# db-engine-presets (extra): dot-sourced by localenv.ps1. db.engine fills the query / exec hooks an env leaves unset and, for
# mysql / mariadb, gives marks (binlog positions), flashback restores and the cascade guard (db_flashback.py); other
# engines: marks unsupported.
# Placeholders: {H} {P} {U} {N} {URI} = db.host (127.0.0.1), db.port (the engine's), db.user, db.name, db.uri
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
function Invoke-DbSql([string]$e, [string]$sql) {
  $c = DbConn $e
  $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe $c.mysql @('-h', $c.host, '-P', $c.port, '-u', $c.user, '-N', '-B', '-e', $sql) 120 }
  if ($r.code) { throw "mysql: $(if ($r.err) { $r.err } else { $r.out })" }
  @("$($r.out)" -split "`r?`n" | Where-Object { $_ } | ForEach-Object { , @($_ -split "`t") })
}
function Get-DbPos([string]$e) {
  $row = try { @(Invoke-DbSql $e 'SHOW MASTER STATUS')[0] } catch { @(Invoke-DbSql $e 'SHOW BINARY LOG STATUS')[0] }   # 8.4+ renamed it
  if (-not $row -or -not $row[0]) { throw 'no binlog position (log_bin is OFF?): localenv.ps1 doctor' }
  "$($row[0]):$($row[1])"
}
function Get-DbBinlogs([string]$e) { @(Invoke-DbSql $e 'SHOW BINARY LOGS' | ForEach-Object { $_[0] }) }
# "<file>:<pos>" -> [long[]] (file number, position): marks compare in binlog order
function DbPosKey([string]$fp) { $f, $p = $fp -split ':(?=\d+$)'; @([long]([regex]::Match($f, '\d+$').Value), [long]$p) }
function Test-DbPosBefore([string]$a, [string]$b) { $x = DbPosKey $a; $y = DbPosKey $b; $x[0] -lt $y[0] -or ($x[0] -eq $y[0] -and $x[1] -lt $y[1]) }
# db_flashback.py <verb> (plan / apply / slice / structure / touched) -> its JSON; -Fail: a refusal or error throws
function Invoke-DbFb([string]$e, [string]$Verb, [string[]]$Rest, [switch]$Fail) {
  $c = DbConn $e
  $a = @('-X', 'utf8', $script:DbFlashbackPy, $Verb) + $Rest + @('--host', $c.host, '--port', $c.port, '--user', $c.user, '--mysql', $c.mysql, '--mysqlbinlog', $c.mysqlbinlog, '--mysqldump', $c.mysqldump)
  $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe (Get-Python) $a 7200 }
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
