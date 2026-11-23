#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (before db_presets.ps1). Exit codes: none here (its verbs exit through envy.ps1).
# db_engines.ps1: the db.engine adapters (kind db-engine). A local-only adapters/*.local.ps1 can add an engine the same way.
# Props: defaultPort, passwordEnv, supportsMarks (binlog marks, restore, cascade guard, schema tenant model), supportsTemp
#   (dbtemp, watchdog, pool), query / exec / jdbc (command presets: {H} {P} {U} {N} {URI}, then {sql} {file} {schema}),
#   schemaSizes (SQL: schema TAB rows TAB MB per schema; envy.ps1 sql -Query schemaSizes, supervise's data-growth check), sizes
#   (the same rows from a scriptblock: non-SQL stores). Caps (README "Adapters" data-store): marks = supportsMarks, temp =
#   supportsTemp, sizes = schemaSizes or sizes; a cap that is off drops its feature (no marks: restore by seed; no sizes: no growth check).
# Verbs: sql @{ e; sql; sec } -> rows (string[] each) · pos @{ e } -> "<file>:<pos>" · binlogs @{ e } -> names.
# An engine without a verb refuses it ("engine <x>: verb <v> not implemented"); never another engine's client.
& { $q = '-h {H} -p {P} -U {U}'; $my = '-h {H} -P {P} -u {U}'; $ss = 'sqlcmd -S {H},{P} -U {U}'
$mysql = @{ defaultPort = 3306; passwordEnv = 'MYSQL_PWD'; supportsMarks = $true; supportsTemp = $true
  query = "mysql $my -N -B --unbuffered -e `"{sql}`" {N}"; exec = "mysql $my --default-character-set=utf8mb4 {N} < `"{file}`""
  jdbc = 'jdbc:mysql://{H}:{P}/{schema}?useSSL=false&allowPublicKeyRetrieval=true'
  sql = { param($a) Invoke-MySqlStatement $a.e $a.sql $a.sec }
  pos = { param($a) Get-MySqlPos $a.e }
  binlogs = { param($a) @(Invoke-MySqlStatement $a.e 'SHOW BINARY LOGS' 120 | ForEach-Object { $_[0] }) }
  # fresh statistics (MySQL 8 caches them 24 h); rows are InnoDB estimates
  schemaSizes = "SELECT /*+ SET_VAR(information_schema_stats_expiry=0) */ table_schema, COALESCE(SUM(table_rows), 0), ROUND(COALESCE(SUM(data_length + index_length), 0) / 1048576) FROM information_schema.tables WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') GROUP BY table_schema" }
Register-KitAdapter db-engine mysql $mysql
$maria = $mysql.Clone(); $maria.supportsTemp = $false; Register-KitAdapter db-engine mariadb $maria   # temp / pool read mysql 8 tables
Register-KitAdapter db-engine postgres @{ defaultPort = 5432; passwordEnv = 'PGPASSWORD'; schemaSizes = "SELECT schemaname || chr(9) || COALESCE(SUM(n_live_tup), 0) || chr(9) || ROUND(COALESCE(SUM(pg_total_relation_size(relid)), 0) / 1048576.0) FROM pg_stat_user_tables GROUP BY schemaname"; query = "psql $q -d {N} -At -c `"{sql}`""; exec = "psql $q -d {N} -v ON_ERROR_STOP=1 -f `"{file}`""; jdbc = 'jdbc:postgresql://{H}:{P}/{N}?currentSchema={schema}' }
Register-KitAdapter db-engine sqlserver @{ defaultPort = 1433; query = "$ss -d {N} -h -1 -Q `"{sql}`""; exec = "$ss -d {N} -b -i `"{file}`"" }
Register-KitAdapter db-engine sqlite @{ query = "sqlite3 `"{N}`" `"{sql}`""; exec = "sqlite3 `"{N}`" `".read {file}`"" }
Register-KitAdapter db-engine oracle @{ defaultPort = 1521; exec = "sqlplus -s -l {U}@{H}:{P}/{N} @{file}" }
Register-KitAdapter db-engine mongodb @{ defaultPort = 27017; query = "mongosh `"{URI}`" --quiet --eval `"{sql}`"" }
# key-value and search stores (no SQL, no marks): sizes = a scriptblock giving the schemaSizes rows (scope TAB rows TAB MB)
Register-KitAdapter db-engine redis @{ defaultPort = 6379; passwordEnv = 'REDISCLI_AUTH'; query = 'redis-cli -h {H} -p {P} {sql}'
  sizes = { param($a) $c = DbConn $a.e; $r = With-Env (EnvVars $a.e ([pscustomobject]@{})) { Invoke-KitExe 'redis-cli' @('-h', $c.host, '-p', $c.port, 'INFO') 30 }; if ($r.code) { throw "redis-cli: $($r.err)" }
    $um = [regex]::Match("$($r.out)", 'used_memory:(\d+)').Groups[1].Value; $mb = if ($um) { [math]::Round([double]$um / 1MB) } else { 0 }; $ks = @([regex]::Matches("$($r.out)", '(?m)^(db\d+):keys=(\d+)'))
    $all = ($ks | ForEach-Object { [long]$_.Groups[2].Value } | Measure-Object -Sum).Sum
    foreach ($m in $ks) { "$($m.Groups[1].Value)`t$($m.Groups[2].Value)`t$(if ($all) { [math]::Round($mb * [long]$m.Groups[2].Value / $all) } else { 0 })" } } }
$search = @{ defaultPort = 9200; query = 'curl -s http://{H}:{P}/{sql}'
  sizes = { param($a) $c = DbConn $a.e; foreach ($ix in @(Invoke-RestMethod "http://$($c.host):$($c.port)/_cat/indices?format=json&bytes=mb" -TimeoutSec 30 | Where-Object { "$($_.index)" -notlike '.*' })) { "$($ix.index)`t$($ix.'docs.count')`t$($ix.'store.size')" } } }
Register-KitAdapter db-engine elasticsearch $search; Register-KitAdapter db-engine opensearch $search.Clone()
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
