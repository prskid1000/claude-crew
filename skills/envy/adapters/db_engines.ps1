#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (before db_presets.ps1). Exit codes: none here (its verbs exit through envy.ps1).
# db_engines.ps1: the db.engine adapters (kind db-engine). A local-only adapters/*.local.ps1 can add an engine the same way.
# Props: defaultPort, passwordEnv, supportsMarks (binlog marks, restore, cascade guard, schema tenant model), supportsTemp
#   (dbtemp, watchdog, pool), query / exec / jdbc (command presets: {H} {P} {U} {N} {URI}, then {sql} {file} {schema}).
# Verbs: sql @{ e; sql; sec } -> rows (string[] each) · pos @{ e } -> "<file>:<pos>" · binlogs @{ e } -> names.
# An engine without a verb refuses it ("engine <x>: verb <v> not implemented"); never another engine's client.
& { $q = '-h {H} -p {P} -U {U}'; $my = '-h {H} -P {P} -u {U}'; $ss = 'sqlcmd -S {H},{P} -U {U}'
$mysql = @{ defaultPort = 3306; passwordEnv = 'MYSQL_PWD'; supportsMarks = $true; supportsTemp = $true
  query = "mysql $my -N -B --unbuffered -e `"{sql}`" {N}"; exec = "mysql $my --default-character-set=utf8mb4 {N} < `"{file}`""
  jdbc = 'jdbc:mysql://{H}:{P}/{schema}?useSSL=false&allowPublicKeyRetrieval=true'
  sql = { param($a) Invoke-MySqlStatement $a.e $a.sql $a.sec }
  pos = { param($a) Get-MySqlPos $a.e }
  binlogs = { param($a) @(Invoke-MySqlStatement $a.e 'SHOW BINARY LOGS' 120 | ForEach-Object { $_[0] }) } }
Register-KitAdapter db-engine mysql $mysql
$maria = $mysql.Clone(); $maria.supportsTemp = $false; Register-KitAdapter db-engine mariadb $maria   # temp / pool read mysql 8 tables
Register-KitAdapter db-engine postgres @{ defaultPort = 5432; passwordEnv = 'PGPASSWORD'; query = "psql $q -d {N} -At -c `"{sql}`""; exec = "psql $q -d {N} -v ON_ERROR_STOP=1 -f `"{file}`""; jdbc = 'jdbc:postgresql://{H}:{P}/{N}?currentSchema={schema}' }
Register-KitAdapter db-engine sqlserver @{ defaultPort = 1433; query = "$ss -d {N} -h -1 -Q `"{sql}`""; exec = "$ss -d {N} -b -i `"{file}`"" }
Register-KitAdapter db-engine sqlite @{ query = "sqlite3 `"{N}`" `"{sql}`""; exec = "sqlite3 `"{N}`" `".read {file}`"" }
Register-KitAdapter db-engine oracle @{ defaultPort = 1521; exec = "sqlplus -s -l {U}@{H}:{P}/{N} @{file}" }
Register-KitAdapter db-engine mongodb @{ defaultPort = 27017; query = "mongosh `"{URI}`" --quiet --eval `"{sql}`"" }
}
$script:DbAlias = @{ postgresql = 'postgres'; pg = 'postgres'; mssql = 'sqlserver'; mongo = 'mongodb' }

# ---- mysql / mariadb: the mysql client; its quoting (tenant schema model, liquibase checksum resets: mysql-family paths only)
function SqlQ([string]$v) { "'" + $v.Replace('\', '\\').Replace("'", "''") + "'" }
function SqlId([string]$n) { '`' + $n.Replace('`', '``') + '`' }
function DbConn([string]$e) {
  $db = (Get-EnvCfg $e).db; $bin = if ($db.bin) { [string]$db.bin } else { '' }
  @{ host = $(if ($db.host) { "$($db.host)" } else { '127.0.0.1' }); port = "$(if ($db.port) { $db.port } else { $(if ((Get-DbEngine $e).defaultPort) { (Get-DbEngine $e).defaultPort } else { 3306 }) })"; user = "$($db.user)"
     mysql = $(if ($bin) { Join-Path $bin 'mysql' } else { 'mysql' }); mysqlbinlog = $(if ($bin) { Join-Path $bin 'mysqlbinlog' } else { 'mysqlbinlog' }); mysqldump = $(if ($bin) { Join-Path $bin 'mysqldump' } else { 'mysqldump' }) }
}
# one statement through the mysql client (password: MYSQL_PWD from the env file) -> rows of tab-separated fields; throws on failure
# under CPU load the Windows client ran the batch, exited 0 and lost its buffered output (6 of 1600; 0 with --unbuffered, 2026-11-16):
# --unbuffered flushes after each statement; the end marker still tells 0 rows from lost ones (a read retries, a write throws)
function Invoke-MySqlStatement([string]$e, [string]$sql, [int]$Sec = 120) {
  $c = DbConn $e; $endMark = '__kit_rows_end__'; $read = $sql -match '^\s*(SELECT|SHOW|WITH)\b' -and $sql -notmatch '(?i)\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|CALL|KILL|SET|OUTFILE|DUMPFILE)\b|;\s*\S'
  for ($try = 1; ; $try++) {
    $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe $c.mysql @('-h', $c.host, '-P', $c.port, '-u', $c.user, '-N', '-B', '--unbuffered') $Sec -In "$($sql.TrimEnd().TrimEnd(';'));`nSELECT '$endMark';`n" }   # stdin, never -e: a long statement overflows the command line
    if ($r.code) { throw "mysql: $(if ($r.err) { $r.err } else { $r.out })" }
    $lines = @("$($r.out)" -split "`r?`n" | Where-Object { $_ })
    if ($lines.Count -and $lines[-1] -eq $endMark) { break }
    if (-not $read -or $try -ge 3) { throw "mysql: exit 0 without the end marker ($(if ($read) { '3 tries' } else { 'a write: not retried, it may have run' })): $($sql.Substring(0, [math]::Min(80, $sql.Length)))" }
  }
  @($lines | Select-Object -SkipLast 1 | ForEach-Object { , @($_ -split "`t") })
}
function Get-MySqlPos([string]$e) {
  $row = try { @(Invoke-MySqlStatement $e 'SHOW MASTER STATUS')[0] } catch { @(Invoke-MySqlStatement $e 'SHOW BINARY LOG STATUS')[0] }   # 8.4+ renamed it
  if (-not $row -or -not $row[0]) { throw 'no binlog position (log_bin is OFF?): envy.ps1 doctor' }
  "$($row[0]):$($row[1])"
}
