#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/ (before db-presets.ps1). Exit codes: none here (its verbs exit through envy.ps1).
# db-engines.ps1: the db.engine adapters (kind db-engine). A local-only adapters/*.local.ps1 can add an engine the same way.
# Props: defaultPort, passwordEnv, supportsMarks (binlog marks, restore, cascade guard, schema tenant model), supportsTemp
#   (dbtemp, watchdog, pool), query / exec / jdbc (command presets: {H} {P} {U} {N} {URI}, then {sql} {file} {schema}),
#   schemaSizes (SQL: schema TAB rows TAB MB per schema; envy.ps1 sql -Query schemaSizes, supervise's data-growth check), sizes
#   (the same rows from a scriptblock: the engine's own catalogue through its sql verb, or a store's API). Caps (README "Adapters" data-store): marks = supportsMarks, temp =
#   supportsTemp or tempSql, sizes = schemaSizes or sizes, revert = a revert verb or supportsMarks (binlog flashback, db_flashback.py); a cap that is off drops its feature (no marks: restore by seed; no sizes: no growth check).
#   tempSql: rows id TAB GB TAB seconds TAB query per connection (dbtemp, the watchdog), kill @{ e; id } ends one.
# Verbs: sql @{ e; sql; sec[; db] } -> rows (string[] each; mysql, mariadb, postgres, sqlserver, sqlite, oracle, mongodb: mongosh
#   JavaScript, elasticsearch / opensearch: SQL over REST; redis: none) · pos @{ e } -> "<file>:<pos>" · binlogs @{ e } -> names.
#   Snapshot marks (db-presets.ps1 Test-DbSnap): pos -> "<token>:<n>", snap @{ e; pos; scopes } (optional: an SCN needs none),
#   revert @{ e; pos; scopes } -> @{ fallback; warnings }, binlogs -> live tokens, unsnap @{ e; pos }.
# An engine without a verb refuses it ("engine <x>: verb <v> not implemented"); never another engine's client.
# Sections: L16 engines · L132 mysql / mariadb · L154 other clients (postgres, sqlserver, sqlite, oracle, mongodb)
# ---- engines: one registration each (parity.json db-engine)
& { $q = '-h {H} -p {P} -U {U}'; $my = '-h {H} -P {P} -u {U}'; $ss = 'sqlcmd -S {H},{P} -U {U}'
$mysql = @{ defaultPort = 3306; passwordEnv = 'MYSQL_PWD'; supportsMarks = $true; supportsTemp = $true
  query = "mysql $my -N -B --unbuffered -e `"{sql}`" {N}"; exec = "mysql $my --default-character-set=utf8mb4 {N} < `"{file}`""
  jdbc = 'jdbc:mysql://{H}:{P}/{schema}?useSSL=false&allowPublicKeyRetrieval=true'
  sql = { param($a) Invoke-MySqlStatement $a.e $a.sql $a.sec }
  pos = { param($a) Get-MySqlPos $a.e }
  binlogs = { param($a) @(Invoke-MySqlStatement $a.e 'SHOW BINARY LOGS' 120 | ForEach-Object { $_[0] }) }
  # fresh statistics (MySQL 8 caches them 24 h); rows are InnoDB estimates
  schemaSizes = "SELECT /*+ SET_VAR(information_schema_stats_expiry=0) */ table_schema, COALESCE(SUM(table_rows), 0), ROUND(COALESCE(SUM(data_length + index_length), 0) / 1048576) FROM information_schema.tables WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') GROUP BY table_schema"
  # session temp tablespaces + TempTable mmap files per connection
  tempSql = "SELECT p.ID, ROUND((IFNULL(s.b, 0) + IFNULL(m.b, 0)) / 1073741824, 3), p.TIME, IFNULL(REPLACE(REPLACE(REPLACE(LEFT(p.INFO, 300), '\r', ' '), '\n', ' '), '\t', ' '), CONCAT('(', p.COMMAND, ')')) FROM information_schema.PROCESSLIST p LEFT JOIN (SELECT ID, SUM(SIZE) b FROM information_schema.INNODB_SESSION_TEMP_TABLESPACES WHERE ID > 0 GROUP BY ID) s ON s.ID = p.ID LEFT JOIN (SELECT t.PROCESSLIST_ID id, SUM(m.CURRENT_NUMBER_OF_BYTES_USED) b FROM performance_schema.memory_summary_by_thread_by_event_name m JOIN performance_schema.threads t ON t.THREAD_ID = m.THREAD_ID WHERE m.EVENT_NAME = 'memory/temptable/physical_disk' GROUP BY t.PROCESSLIST_ID) m ON m.id = p.ID WHERE p.ID <> CONNECTION_ID() AND p.USER NOT IN ('system user', 'event_scheduler') ORDER BY 2 DESC, p.TIME DESC LIMIT 20"
  kill = { param($a) if ("$($a.id)" -notmatch '^\d+$') { throw "kill needs a connection id, not '$($a.id)'" }; $null = Invoke-MySqlStatement $a.e "KILL $($a.id)" } }
Register-KitAdapter db-engine mysql $mysql
# mariadb: no mysql 8 temp tables (doctor / pool rest); per connection temp from PROCESSLIST TMP_SPACE_USED (MariaDB 11.5+)
$maria = $mysql.Clone(); $maria.supportsTemp = $false; $maria.tempSql = "SELECT ID, ROUND(TMP_SPACE_USED / 1073741824, 3), TIME, IFNULL(REPLACE(REPLACE(REPLACE(LEFT(INFO, 300), '\r', ' '), '\n', ' '), '\t', ' '), CONCAT('(', COMMAND, ')')) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND USER NOT IN ('system user', 'event_scheduler') ORDER BY 2 DESC, TIME DESC LIMIT 20"
Register-KitAdapter db-engine mariadb $maria
Register-KitAdapter db-engine postgres @{ defaultPort = 5432; passwordEnv = 'PGPASSWORD'; schemaSizes = "SELECT schemaname || chr(9) || COALESCE(SUM(n_live_tup), 0) || chr(9) || ROUND(COALESCE(SUM(pg_total_relation_size(relid)), 0) / 1048576.0) FROM pg_stat_user_tables GROUP BY schemaname"; query = "psql $q -d {N} -At -c `"{sql}`""; exec = "psql $q -d {N} -v ON_ERROR_STOP=1 -f `"{file}`""; jdbc = 'jdbc:postgresql://{H}:{P}/{N}?currentSchema={schema}'
  sql = { param($a) $c = DbConn $a.e; Invoke-DbCliRows $a.e 'psql' @('-h', $c.host, '-p', $c.port, '-U', $c.user, '-d', $c.name, '-X', '-q', '-A', '-t', '-F', "`t", '-v', 'ON_ERROR_STOP=1') "$($a.sql.TrimEnd().TrimEnd(';'));`n" $a.sec }
  # temp files per backend: pg_ls_tmpdir() names them pgsql_tmp<pid>.<n> (pg 12+, pg_monitor)
  tempSql = "SELECT a.pid, ROUND(COALESCE(t.b, 0) / 1073741824.0, 3), COALESCE(EXTRACT(EPOCH FROM now() - a.query_start)::int, 0), LEFT(translate(COALESCE(a.query, '(' || a.state || ')'), chr(13) || chr(10) || chr(9), '   '), 300) FROM pg_stat_activity a LEFT JOIN (SELECT (regexp_match(name, '^pgsql_tmp(\d+)'))[1]::int pid, SUM(size) b FROM pg_ls_tmpdir() GROUP BY 1) t ON t.pid = a.pid WHERE a.pid <> pg_backend_pid() AND a.backend_type = 'client backend' ORDER BY 2 DESC, 3 DESC LIMIT 20"
  kill = { param($a) if ("$($a.id)" -notmatch '^\d+$') { throw "kill needs a backend pid, not '$($a.id)'" }; $null = Invoke-DbSql $a.e "SELECT pg_terminate_backend($($a.id))" } }
Register-KitAdapter db-engine sqlserver @{ defaultPort = 1433; passwordEnv = 'SQLCMDPASSWORD'; query = "$ss -d {N} -h -1 -Q `"{sql}`""; exec = "$ss -d {N} -b -i `"{file}`""; jdbc = 'jdbc:sqlserver://{H}:{P};databaseName={N};encrypt=false'
  sql = { param($a) $c = DbConn $a.e; Invoke-DbCliRows $a.e 'sqlcmd' (@('-S', "$($c.host),$($c.port)") + $(if ($c.user) { @('-U', $c.user) } else { @('-E') }) + @('-d', $(if ($a.db) { $a.db } else { $c.name }), '-h', '-1', '-W', '-s', "`t", '-b', '-I')) "SET NOCOUNT ON;`n$($a.sql)`nGO`n" $a.sec }
  # tempdb pages per session (finished + running tasks), its request's text
  tempSql = "SELECT s.session_id, CAST((ISNULL(su.p, 0) + ISNULL(tu.p, 0)) * 8 / 1048576.0 AS decimal(12, 3)), DATEDIFF(SECOND, COALESCE(r.start_time, s.last_request_start_time), GETDATE()), LEFT(REPLACE(REPLACE(REPLACE(ISNULL(t.text, '(' + s.status + ')'), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 300) FROM sys.dm_exec_sessions s LEFT JOIN (SELECT session_id, SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count + internal_objects_alloc_page_count - internal_objects_dealloc_page_count) p FROM sys.dm_db_session_space_usage GROUP BY session_id) su ON su.session_id = s.session_id LEFT JOIN (SELECT session_id, SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count + internal_objects_alloc_page_count - internal_objects_dealloc_page_count) p FROM sys.dm_db_task_space_usage GROUP BY session_id) tu ON tu.session_id = s.session_id LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.is_user_process = 1 AND s.session_id <> @@SPID ORDER BY 2 DESC, 3 DESC OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY"
  kill = { param($a) if ("$($a.id)" -notmatch '^\d+$') { throw "kill needs a session id, not '$($a.id)'" }; $null = Invoke-DbSql $a.e "KILL $($a.id)" }
  # marks = database snapshots (copy-on-write, https://learn.microsoft.com/sql/relational-databases/databases/database-snapshots-sql-server): <db>_kitsnap<ms>
  pos = { param($a) New-DbSnapPos }
  snap = { param($a) $db = (DbConn $a.e).name; $t = ($a.pos -split ':')[0]
    $on = @(Invoke-DbSql $a.e 'SELECT name, physical_name FROM sys.database_files WHERE type = 0' | ForEach-Object { "(NAME = [$($_[0])], FILENAME = '$([IO.Path]::ChangeExtension($_[1], "$t.ss"))')" }) -join ', '
    $null = Invoke-DbSql $a.e "CREATE DATABASE [$($db)_$t] ON $on AS SNAPSHOT OF [$db]" 600 }
  binlogs = { param($a) $db = (DbConn $a.e).name; @(Invoke-DbSql $a.e "SELECT name FROM sys.databases WHERE source_database_id = DB_ID('$db')" | ForEach-Object { "$($_[0])" -replace "^$([regex]::Escape($db))_" }) }
  unsnap = { param($a) $null = Invoke-DbEngine $a.e 'sql' @{ sql = "DROP DATABASE [$((DbConn $a.e).name)_$(($a.pos -split ':')[0])]"; db = 'master' } }
  # a revert needs the other snapshots of the db gone: earlier marks expire too (the plan says so)
  revert = { param($a) $db = (DbConn $a.e).name; $t = ($a.pos -split ':')[0]
    foreach ($o in @(Invoke-DbEngine $a.e 'binlogs' | Where-Object { $_ -ne $t })) { Invoke-DbEngine $a.e 'unsnap' @{ pos = "${o}:0" } }
    $null = Invoke-DbEngine $a.e 'sql' @{ db = 'master'; sec = 1800; sql = "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [$db] FROM DATABASE_SNAPSHOT = '$($db)_$t'; ALTER DATABASE [$db] SET MULTI_USER" }
    @{ warnings = @('SQL Server keeps one snapshot of a database at a revert: the marks before this one expired') } }
  sizes = { param($a) Get-DbSizeRows $a.e 'SELECT s.name, SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END), CAST(ROUND(SUM(ps.reserved_page_count) * 8 / 1024.0, 0) AS bigint) FROM sys.dm_db_partition_stats ps JOIN sys.objects o ON o.object_id = ps.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE o.is_ms_shipped = 0 GROUP BY s.name' } }
Register-KitAdapter db-engine sqlite @{ query = "sqlite3 `"{N}`" `"{sql}`""; exec = "sqlite3 `"{N}`" `".read {file}`""; jdbc = 'jdbc:sqlite:{N}'
  sql = { param($a) Invoke-DbCliRows $a.e 'sqlite3' @('-batch', '-bail', '-noheader', '-separator', "`t", (DbConn $a.e).name) "$($a.sql.TrimEnd().TrimEnd(';'));`n" $a.sec }
  # one scope (main): rows = leaf cells of the table b-trees (dbstat, in the sqlite3 shell's build; a build without it: 0), MB = page_count x page_size
  sizes = { param($a) $mb = 'CAST(ROUND((SELECT page_count FROM pragma_page_count()) * (SELECT page_size FROM pragma_page_size()) / 1048576.0) AS INTEGER)'
    try { Get-DbSizeRows $a.e "SELECT 'main', COALESCE((SELECT SUM(d.ncell) FROM dbstat d JOIN sqlite_master m ON m.name = d.name AND m.type = 'table' WHERE d.pagetype = 'leaf'), 0), $mb" }
    catch { if ("$_" -notmatch 'no such table: dbstat') { throw }; Get-DbSizeRows $a.e "SELECT 'main', 0, $mb" } }
  # marks = VACUUM INTO copies (online, https://www.sqlite.org/lang_vacuum.html#vacuuminto) under data.maxMB; revert = the shell's .restore
  pos = { param($a) New-DbSnapPos }
  snap = { param($a) $f = Get-DbSnapFile $a.e $a.pos '.db'; $mb = (Get-Item -LiteralPath (DbConn $a.e).name).Length / 1MB; $max = [double](Get-KitParam 'data.maxMB')
    if ($mb -gt $max) { throw "sqlite mark: the db is $([math]::Round($mb)) MB > data.maxMB $max (no large copies): restore by seed" }
    $null = Invoke-DbSql $a.e "VACUUM INTO '$($f.Replace("'", "''"))'" }
  binlogs = { param($a) @(Get-ChildItem -LiteralPath (Split-Path (Get-DbSnapFile $a.e 'x:0' '.db')) -Filter 'kitsnap*.db' -ErrorAction SilentlyContinue | ForEach-Object BaseName) }
  unsnap = { param($a) Remove-Item -LiteralPath (Get-DbSnapFile $a.e $a.pos '.db') -Force -ErrorAction SilentlyContinue }
  revert = { param($a) $null = Invoke-DbCliRows $a.e 'sqlite3' @('-batch', '-bail', (DbConn $a.e).name) ".restore '$((Get-DbSnapFile $a.e $a.pos '.db').Replace("'", "''"))'`n" 1800; @{} } }
# oracle: the password (db.passwordEnv ORACLE_PWD in the env file) goes in on stdin with CONNECT, never on the command line
Register-KitAdapter db-engine oracle @{ defaultPort = 1521; passwordEnv = 'ORACLE_PWD'; exec = "sqlplus -s -l {U}@{H}:{P}/{N} @{file}"; jdbc = 'jdbc:oracle:thin:@//{H}:{P}/{N}'
  sql = { param($a) $c = DbConn $a.e; $pw = (EnvVars $a.e ([pscustomobject]@{}))["$((Get-EnvCfg $a.e).db.passwordEnv)"]
    Invoke-DbCliRows $a.e 'sqlplus' @('-s', '-l', '/nolog') "WHENEVER SQLERROR EXIT 1`nCONNECT $($c.user)/`"$pw`"@//$($c.host):$($c.port)/$($c.name)`nSET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON TAB OFF COLSEP '`t'`n$($a.sql.TrimEnd().TrimEnd(';'));`nEXIT`n" $a.sec -Trim }
  # the connected user's schema (user_tables statistics, user_segments: no DBA grant needed)
  sizes = { param($a) Get-DbSizeRows $a.e 'SELECT USER, (SELECT NVL(SUM(num_rows), 0) FROM user_tables), (SELECT ROUND(NVL(SUM(bytes), 0) / 1048576) FROM user_segments) FROM dual' }
  # temp segments per session (SELECT_CATALOG_ROLE); kill: ALTER SYSTEM (sid,serial#)
  tempSql = "SELECT s.sid || ',' || s.serial#, ROUND(SUM(u.blocks) * MAX(TO_NUMBER(p.value)) / 1073741824, 3), MAX(s.last_call_et), SUBSTR(MAX(TRANSLATE(q.sql_text, CHR(13) || CHR(10) || CHR(9), '   ')), 1, 300) FROM v`$tempseg_usage u JOIN v`$session s ON s.saddr = u.session_addr JOIN v`$parameter p ON p.name = 'db_block_size' LEFT JOIN v`$sql q ON q.sql_id = s.sql_id AND q.child_number = 0 WHERE s.audsid <> SYS_CONTEXT('USERENV', 'SESSIONID') GROUP BY s.sid, s.serial# ORDER BY 2 DESC FETCH FIRST 20 ROWS ONLY"
  kill = { param($a) if ("$($a.id)" -notmatch '^\d+,\d+$') { throw "kill needs sid,serial#, not '$($a.id)'" }; $null = Invoke-DbSql $a.e "ALTER SYSTEM KILL SESSION '$($a.id)' IMMEDIATE" }
  # marks = an SCN (zero bytes); revert = FLASHBACK TABLE of the user's tables (undo retention bounds it,
  # https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/FLASHBACK-TABLE.html); a table with DDL since: seeded
  # row movement (FLASHBACK TABLE needs it) is turned on before the SCN is read: that DDL never lands after a mark
  pos = { param($a) $q = { param($t) '"' + $t.Replace('"', '""') + '"' }
    $off = @(Invoke-DbSql $a.e "SELECT table_name FROM user_tables WHERE temporary = 'N' AND row_movement = 'DISABLED' AND table_name NOT LIKE 'BIN$%'" | ForEach-Object { "$($_[0])" })
    if ($off.Count) { $null = Invoke-DbSql $a.e (@($off | ForEach-Object { "ALTER TABLE $(& $q $_) ENABLE ROW MOVEMENT" }) -join ";`n") 600 }
    "scn:$(@(Invoke-DbSql $a.e 'SELECT TIMESTAMP_TO_SCN(SYSTIMESTAMP) FROM dual')[0][0])" }
  revert = { param($a) $n = [long]($a.pos -split ':')[-1]; $q = { param($t) '"' + $t.Replace('"', '""') + '"' }
    $all = @(Invoke-DbSql $a.e "SELECT table_name FROM user_tables WHERE temporary = 'N' AND table_name NOT LIKE 'BIN$%'" | ForEach-Object { "$($_[0])" })
    $chg = @(Invoke-DbSql $a.e "SELECT object_name FROM user_objects WHERE object_type = 'TABLE' AND (created > SCN_TO_TIMESTAMP($n) OR last_ddl_time > SCN_TO_TIMESTAMP($n))" | ForEach-Object { "$($_[0])" })
    $ok = @($all | Where-Object { $_ -notin $chg })
    if ($ok.Count) { $null = Invoke-DbSql $a.e "FLASHBACK TABLE $(@($ok | ForEach-Object { & $q $_ }) -join ', ') TO SCN $n" 1800 }
    @{ fallback = @($chg | ForEach-Object { @{ table = $_; why = 'created or changed (DDL) after the mark: FLASHBACK TABLE cannot cross it' } }) } } }
# mongodb: the statement is mongosh JavaScript (print rows, fields joined by tabs); kit-built SQL fails there loudly. db.uri
# (credentials) reaches only mongosh, as env KIT_DB_URI (here; the query hook: envy.ps1 Invoke-Hook), never argv; unset: host / port / name
$__mg = "db = connect(process.env.KIT_DB_URI || 'mongodb://{H}:{P}/{N}');"
# exec: --eval runs before the file (mongosh: evals, then files), so the file sees the connected db; jdbc: the MongoDB JDBC driver's URL
Register-KitAdapter db-engine mongodb @{ defaultPort = 27017; query = "mongosh --nodb --quiet --eval `"$__mg {sql}`""; exec = "mongosh --nodb --quiet --eval `"$__mg`" `"{file}`""; jdbc = 'jdbc:mongodb://{H}:{P}/{N}'
  sql = { param($a) $c = DbConn $a.e; $js = "db = connect(process.env.KIT_DB_URI || 'mongodb://$($c.host):$($c.port)/$("$($c.name)" -replace "['\\]", '\$0')'); $($a.sql)"
    With-Env @{ KIT_DB_URI = "$((Get-EnvCfg $a.e).db.uri)" } { Invoke-DbCliRows $a.e 'mongosh' @('--nodb', '--quiet', '--eval', $js) $null $a.sec } }
  sizes = { param($a) Get-DbSizeRows $a.e "db.adminCommand({ listDatabases: 1 }).databases.filter(d => !['admin', 'local', 'config'].includes(d.name)).forEach(d => { const s = db.getSiblingDB(d.name).stats(); print([d.name, s.objects, Math.round((s.dataSize + s.indexSize) / 1048576)].join(String.fromCharCode(9))) })" } }
# key-value and search stores (no marks): sizes = a scriptblock giving the schemaSizes rows (scope TAB rows TAB MB)
Register-KitAdapter db-engine redis @{ defaultPort = 6379; passwordEnv = 'REDISCLI_AUTH'; query = 'redis-cli -h {H} -p {P} {sql}'; exec = 'redis-cli -h {H} -p {P} < "{file}"'
  sizes = { param($a) $c = DbConn $a.e; $r = With-Env (EnvVars $a.e ([pscustomobject]@{})) { Invoke-KitExe 'redis-cli' @('-h', $c.host, '-p', $c.port, 'INFO') 30 }; if ($r.code) { throw "redis-cli: $($r.err)" }
    $um = [regex]::Match("$($r.out)", 'used_memory:(\d+)').Groups[1].Value; $mb = if ($um) { [math]::Round([double]$um / 1MB) } else { 0 }; $ks = @([regex]::Matches("$($r.out)", '(?m)^(db\d+):keys=(\d+)'))
    $all = ($ks | ForEach-Object { [long]$_.Groups[2].Value } | Measure-Object -Sum).Sum
    foreach ($m in $ks) { "$($m.Groups[1].Value)`t$($m.Groups[2].Value)`t$(if ($all) { [math]::Round($mb * [long]$m.Groups[2].Value / $all) } else { 0 })" } } }
$search = @{ defaultPort = 9200; query = 'curl -s http://{H}:{P}/{sql}'; exec = 'curl -s -H "Content-Type: application/x-ndjson" -X POST http://{H}:{P}/_bulk --data-binary "@{file}"'
  sizes = { param($a) $c = DbConn $a.e; foreach ($ix in @(Invoke-RestMethod "http://$($c.host):$($c.port)/_cat/indices?format=json&bytes=mb" -TimeoutSec 30 | Where-Object { "$($_.index)" -notlike '.*' })) { "$($ix.index)`t$($ix.'docs.count')`t$($ix.'store.size')" } }
  # SQL over REST: elasticsearch _sql (json: columns, rows), opensearch the SQL plugin (jdbc: schema, datarows); pages followed by cursor
  sql = { param($a) $c = DbConn $a.e; $os = (Get-DbEngineName $a.e) -eq 'opensearch'
    $u = "http://$($c.host):$($c.port)/$(if ($os) { '_plugins/_sql' } else { '_sql?format=json' })"; $body = @{ query = $a.sql.TrimEnd().TrimEnd(';'); fetch_size = 1000 }
    @(for ($pg = 0; $body -and $pg -lt 100; $pg++) {
      $r = Invoke-RestMethod -Method Post $u -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) -TimeoutSec $(if ($a.sec) { $a.sec } else { 120 })
      $rows = if ($os) { , $r.datarows } else { , $r.rows }   # the comma keeps one row a row (an if result unrolls)
      foreach ($row in @($rows)) { if ($null -ne $row) { , @($row | ForEach-Object { "$_" }) } }
      $body = if ($r.cursor) { @{ cursor = $r.cursor } } }) }
  # marks = snapshots in the repository kit-marks (registered by the owner: an fs repo under path.repo; https://www.elastic.co/guide/en/elasticsearch/reference/current/snapshot-restore.html)
  pos = { param($a) New-DbSnapPos }
  snap = { param($a) $null = Invoke-DbSnapRest $a.e Put "$(($a.pos -split ':')[0])?wait_for_completion=true" @{ indices = $(if (@($a.scopes).Count) { @($a.scopes) -join ',' } else { '*,-.*' }); include_global_state = $false; ignore_unavailable = $true } }
  binlogs = { param($a) @((Invoke-DbSnapRest $a.e Get '_all').snapshots | ForEach-Object { "$($_.snapshot)" }) }
  unsnap = { param($a) $null = Invoke-DbSnapRest $a.e Delete ($a.pos -split ':')[0] }
  # the scope's indices now are deleted (made after the mark, or replaced), then the snapshot's come back
  revert = { param($a) $c = DbConn $a.e; $t = ($a.pos -split ':')[0]; $back = @((Invoke-DbSnapRest $a.e Get $t).snapshots[0].indices | Where-Object { "$_" -notlike '.*' })
    $now = @(Invoke-RestMethod "http://$($c.host):$($c.port)/_cat/indices?format=json&h=index" -TimeoutSec 60 | ForEach-Object { "$($_.index)" } | Where-Object { $_ -notlike '.*' -and (-not @($a.scopes).Count -or $_ -in @($a.scopes) -or $_ -in $back) })
    if ($now.Count) { $null = Invoke-RestMethod -Method Delete "http://$($c.host):$($c.port)/$($now -join ',')" -TimeoutSec 300 }
    if ($back.Count) { $null = Invoke-DbSnapRest $a.e Post "$t/_restore?wait_for_completion=true" @{ indices = $back -join ','; include_global_state = $false } }
    @{} } }
$osearch = $search.Clone(); $search.jdbc = 'jdbc:es://http://{H}:{P}'; $osearch.jdbc = 'jdbc:opensearch://http://{H}:{P}'
Register-KitAdapter db-engine elasticsearch $search; Register-KitAdapter db-engine opensearch $osearch
}
$script:DbAlias = @{ postgresql = 'postgres'; pg = 'postgres'; mssql = 'sqlserver'; mongo = 'mongodb' }

# ---- mysql / mariadb: the mysql client; its quoting (tenant schema model, liquibase checksum resets: mysql-family paths only)
function SqlQ([string]$v) { "'" + $v.Replace('\', '\\').Replace("'", "''") + "'" }
function SqlId([string]$n) { '`' + $n.Replace('`', '``') + '`' }
function DbConn([string]$e) {
  $db = (Get-EnvCfg $e).db; $bin = if ($db.bin) { [string]$db.bin } else { '' }
  @{ host = $(if ($db.host) { "$($db.host)" } else { '127.0.0.1' }); port = "$(if ($db.port) { $db.port } else { $(if ((Get-DbEngine $e).defaultPort) { (Get-DbEngine $e).defaultPort } else { 3306 }) })"; user = "$($db.user)"; name = "$($db.name)"
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
# ---- other clients (postgres, sqlserver, sqlite, oracle, mongodb): the statement on stdin (-In; $null = argv only), rows = output
# lines split on tabs (-Trim: padded columns); the env file's variables (passwords) set for the call; throws on failure
function Invoke-DbCliRows([string]$e, [string]$Exe, [string[]]$Argv, $In, [int]$Sec = 120, [switch]$Trim) {
  $x = @{ Exe = $Exe; A = $Argv; TimeoutSec = $(if ($Sec) { $Sec } else { 120 }) }; if ($null -ne $In) { $x.In = "$In" }
  $r = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe @x }
  if ($r.code) { throw "${Exe}: $(if ($r.err) { $r.err } else { $r.out })" }
  @("$($r.out)" -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { , @($_ -split "`t" | ForEach-Object { if ($Trim) { $_.Trim() } else { $_ } }) })
}
# sizes through the engine's own sql verb -> "scope TAB rows TAB MB" lines (the schemaSizes shape)
function Get-DbSizeRows([string]$e, [string]$Statement) { @(Invoke-DbSql $e $Statement | ForEach-Object { @($_) -join "`t" }) }
function Get-MySqlPos([string]$e) {
  $row = try { @(Invoke-MySqlStatement $e 'SHOW MASTER STATUS')[0] } catch { @(Invoke-MySqlStatement $e 'SHOW BINARY LOG STATUS')[0] }   # 8.4+ renamed it
  if (-not $row -or -not $row[0]) { throw 'no binlog position (log_bin is OFF?): envy.ps1 doctor' }
  "$($row[0]):$($row[1])"
}
