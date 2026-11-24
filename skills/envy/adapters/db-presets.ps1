#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none here (its verbs exit through envy.ps1).
# db-presets.ps1: dot-sourced by envy.ps1. db.engine (an adapters/db-engines.ps1 adapter, kind db-engine) fills the query /
# exec / jdbc / passwordEnv an env leaves unset; an engine with supportsMarks (mysql / mariadb) gives marks (binlog positions),
# flashback restores and the cascade guard (db_flashback.py; db.cascadeGuard true); other engines: marks unsupported.
# Placeholders: {H} {P} {U} {N} {URI} = db.host (127.0.0.1), db.port (the engine's), db.user, db.name, db.uri
# Sections: L19 engine dispatch · L34 marks · L82 snapshot marks (sqlserver, sqlite, oracle, elasticsearch, opensearch ·
#   L119 temp · L164 pool
$script:DbPresets = @{}   # engine -> { port, query, exec, jdbc, passwordEnv, marks } (envy.ps1 checks it is loaded)
foreach ($__en in @($KitAdapters['db-engine'].Keys)) { $__a = $KitAdapters['db-engine'][$__en]; $script:DbPresets[$__en] = @{ port = $__a.defaultPort; query = $__a.query; exec = $__a.exec; jdbc = $__a.jdbc; passwordEnv = $__a.passwordEnv; marks = [bool]$__a.supportsMarks } }
foreach ($n in $(if ($script:LE.envs) { @((Get-KitProps $script:LE.envs).Name) })) {
  $db = (Get-KitMember $script:LE.envs $n).db; if ($db.engine -and $script:DbAlias["$($db.engine)".ToLower()]) { $db.engine = $script:DbAlias["$($db.engine)".ToLower()] }; $p = if ($db.engine) { $script:DbPresets["$($db.engine)".ToLower()] }; if (-not $p) { continue }
  $port = if ($db.port) { $db.port } else { $p.port }; $h = if ($db.host) { $db.host } else { '127.0.0.1' }
  $v = @{ H = $h; P = $port; U = "$($db.user)"; N = "$($db.name)"; URI = $(if ($db.uri) { $db.uri } else { "mongodb://${h}:$port/$($db.name)" }) }
  foreach ($__pk in 'query', 'exec', 'jdbc', 'passwordEnv') { if ((Get-KitMember $p $__pk) -and -not (Get-KitMember $db $__pk)) { $c = (Get-KitMember $p $__pk); foreach ($x in $v.Keys) { $c = $c.Replace("{$x}", "$($v[$x])") }; $db | Add-Member $__pk $c -Force } }   # $__pk: a dot-sourcing test keeps its $k
}

$script:DbFlashbackPy = Join-Path $PSScriptRoot 'db_flashback.py'
# ---- engine dispatch: the env's db.engine adapter; a verb it lacks refuses (never the mysql client for another engine)
function Get-DbEngineName([string]$e) { "$((Get-EnvCfg $e).db.engine)".ToLower() }
function Get-DbEngine([string]$e) { $n = Get-DbEngineName $e; if ($n) { $KitAdapters['db-engine'][$n] } }
function Invoke-DbEngine([string]$e, [string]$Verb, [hashtable]$a = @{}) {
  $n = Get-DbEngineName $e; $ad = Get-DbEngine $e
  if (-not $ad -or -not ($ad[$Verb] -is [scriptblock])) { throw "engine $(if ($n) { $n } else { '(db.engine unset)' }): verb $Verb not implemented" }
  $a.e = $e; & $ad[$Verb] $a $Verb
}
function Invoke-DbSql([string]$e, [string]$sql, [int]$Sec = 120) { Invoke-DbEngine $e 'sql' @{ sql = $sql; sec = $Sec } }
# envy.ps1 Invoke-Hook query with no db.query line (oracle: no one-line client): the engine's sql verb -> $null | the error; rows in HookOut
function Invoke-DbQueryVerb([string]$e, [string]$Sql) {
  try { $script:HookOut = @(Invoke-DbSql $e $Sql (HookTimeout $e 'query') | ForEach-Object { @($_) -join "`t" }); $null } catch { $script:HookOut = @("$_"); "db.query (engine sql) failed: $("$_".Split("`n")[0])" }
}
function Get-DbPos([string]$e) { Invoke-DbEngine $e 'pos' }
function Get-DbBinlogs([string]$e) { @(Invoke-DbEngine $e 'binlogs') }
# ---- marks: binlog positions (mysql / mariadb); a mark costs zero bytes, the binlog keeps the changes after it
function Test-DbMarks([string]$e) { [bool](Get-DbEngine $e).supportsMarks }
# db.cascadeGuard (default false): the cascade guard's triggers on this env (doctor, after migrations, a tenant import, before a mark)
function Test-CascadeGuard([string]$e) { "$((Get-EnvCfg $e).db.cascadeGuard)" -eq 'True' -and (Test-DbMarks $e) }
# "<file>:<pos>" -> [long[]] (file number, position): marks compare in binlog order
function DbPosKey([string]$fp) { $f, $p = $fp -split ':(?=\d+$)'; @([long]([regex]::Match($f, '\d+$').Value), [long]$p) }
function Test-DbPosBefore([string]$a, [string]$b) { $x = DbPosKey $a; $y = DbPosKey $b; $x[0] -lt $y[0] -or ($x[0] -eq $y[0] -and $x[1] -lt $y[1]) }
# db_flashback.py <verb> (plan / apply / slice / structure / touched) -> its JSON; -Fail: a refusal or error throws
function Invoke-DbFb([string]$e, [string]$Verb, [string[]]$Rest, [switch]$Fail) {
  $c = DbConn $e; $ht = @(Get-KitSetting 'migrations.historyTables' @() | Where-Object { $_ }); if ($ht.Count) { $Rest = @($Rest) + @('--tool', "(?i)^($(@($ht | ForEach-Object { [regex]::Escape("$_") }) -join '|'))$") }   # migration history tables: never flashed back
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
  if ($w.log_bin -ne 'ON' -or -not (Test-CascadeGuard $e)) { return }
  try { $g = Install-DbGuard $e; if ($g.installed -or $g.removed) { [pscustomobject]@{ level = 'OK'; what = "cascade guard: $($g.installed) trigger(s) installed, $($g.removed) removed, $($g.kept) kept on $($g.parents) parent table(s)" } } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "cascade guard not installed: a restore past a cascading delete seeds the child tables ($("$_".Split("`n")[0]))" } }
}
# ---- snapshot marks (sqlserver, sqlite, oracle, elasticsearch, opensearch: an engine with a revert verb): the mark's pos names its
# snapshot (or SCN); restore = the engine's revert of the scopes, later marks dropped; marks of the binlog engines: above
function Test-DbSnap([string]$e) { (Get-DbEngine $e).revert -is [scriptblock] }
function New-DbSnapPos { "kitsnap$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()):0" }
function Get-DbSnapFile([string]$e, [string]$Pos, [string]$Ext) { $d = Join-Path (MigRoot $e) 'snaps'; $null = New-Item -ItemType Directory -Force $d; Join-Path $d "$(($Pos -split ':')[0])$Ext" }
function Invoke-DbSnapRest([string]$e, [string]$Method, [string]$Path, $Body) {
  $c = DbConn $e; $p = @{ Method = $Method; Uri = "http://$($c.host):$($c.port)/_snapshot/kit-marks/$Path"; TimeoutSec = 900 }
  if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Compress; $p.ContentType = 'application/json' }
  try { Invoke-RestMethod @p } catch { throw "snapshot repository kit-marks: $("$_".Split("`n")[0]) (register it: PUT _snapshot/kit-marks { type: fs, settings: { location } } under path.repo)" }
}
function Add-DbSnap([string]$e, [string]$Pos, [string[]]$Scopes) { if ((Get-DbEngine $e).snap -is [scriptblock]) { Invoke-DbEngine $e 'snap' @{ pos = $Pos; scopes = $Scopes } } }
# daily: marks whose snapshot is gone expire; snapshots no mark holds (pruned past marks.max) are dropped
function Update-SnapMarks([string]$e) {
  $ad = Get-DbEngine $e; if (-not ($ad.binlogs -is [scriptblock])) { return "[$e] marks: $(@((Read-State $e).marks).Count) kept (an SCN mark past the undo retention is refused at restore)" }
  $live = @(Invoke-DbEngine $e 'binlogs'); $o = @{ gone = @(); held = @() }
  Update-State $e { param($x) $o.gone = @(@($x.marks) | Where-Object { $_ -and ($_.pos -split ':')[0] -notin $live }); $o.held = @(@($x.marks) | Where-Object { $_ } | ForEach-Object { ($_.pos -split ':')[0] })
    if ($o.gone.Count) { $x.expiredMarks = @(@($x.expiredMarks) + @($o.gone.name) | Where-Object { $_ } | Select-Object -Last 10); $x.marks = @(@($x.marks) | Where-Object { $_ -and $_.name -notin $o.gone.name }) } }
  $young = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds()   # a snapshot New-Mark has not recorded yet is no orphan
  foreach ($t in @($live | Where-Object { $_ -match '^kitsnap(\d+)$' -and [long]$Matches[1] -lt $young -and $_ -notin $o.held })) { try { Invoke-DbEngine $e 'unsnap' @{ pos = "${t}:0" } } catch { } }
  "[$e] marks: $(@((Read-State $e).marks).Count) kept$(if ($o.gone.Count) { ", expired (snapshot gone): $(@($o.gone.name) -join ', ')" })"
}
# a snapshot restore's plan (RestorePlanText shape): the scopes back whole; refused when its snapshot is gone
function Get-SnapRestorePlan([string]$e, $m, [string[]]$Schemas) {
  $p = @{ statements = 0; tables = @{}; steps = @(); drops = @(); renames = @(); objects = @(); objectDrops = @(); fallback = @(); warnings = @(); refused = @(); bytes = 0; to = ''; snapshot = "$(@($Schemas) -join ', ') back whole to mark $($m.name) ($($m.pos))" }
  if ((Get-DbEngine $e).binlogs -is [scriptblock] -and ($m.pos -split ':')[0] -notin @(Invoke-DbEngine $e 'binlogs')) { $p.refused = @("mark $($m.name): its snapshot is gone") }
  $p
}
# writers stopped: the engine's revert; its fallback tables seed (Invoke-RestoreFallback); marks after it dropped; $null = ok
function Invoke-SnapRestoreDb([string]$e, $m, [string[]]$Schemas) {
  $r = try { Invoke-DbEngine $e 'revert' @{ pos = $m.pos; scopes = $Schemas } } catch { return "snapshot revert failed: $("$_".Split("`n")[0])" }
  $script:RestoreFallback = @(@($r.fallback) | Where-Object { $_ })
  $later = @(@((Read-State $e).marks) | Where-Object { $_ -and (Test-DbPosBefore $m.pos $_.pos) })
  foreach ($x in $later) { try { if ((Get-DbEngine $e).unsnap -is [scriptblock]) { Invoke-DbEngine $e 'unsnap' @{ pos = $x.pos } } } catch { } }
  Update-State $e { param($x) $x.marks = @(@($x.marks) | Where-Object { $_ -and $_.name -notin @($later.name) }) }
  Event $e 'restore-db' @{ mark = $m.name; snapshot = $true; fallback = @($script:RestoreFallback | ForEach-Object table); warnings = @($r.warnings) }
  $null
}
# ---- temp: per connection temp on disk (the engine's tempSql: mysql session temp tablespaces + TempTable mmap files, mariadb
# TMP_SPACE_USED, postgres pg_ls_tmpdir, sqlserver tempdb pages, oracle temp segments), the watchdog; server caps (mysql)
function Test-DbTemp([string]$e) { [bool](Get-DbEngine $e).supportsTemp }
$script:DbTempOff = @{}   # env -> why: the server lacks the engine's temp columns (mariadb < 11.5): no watchdog, said once
function Test-DbTempUse([string]$e) { [bool](Get-DbEngine $e).tempSql -and -not $script:DbTempOff[$e] }
# -> { id, gb, secs, query } per connection, most temp first (sleeping ones too: a session keeps its temp tablespace until it ends)
function Get-DbTempUse([string]$e) {
  if (-not (Test-DbTempUse $e)) { return @() }
  $rows = @(try { Invoke-DbSql $e ([string](Get-DbEngine $e).tempSql) } catch { if ("$_" -notmatch 'Unknown column|does not exist|Invalid column|invalid identifier') { throw }; $script:DbTempOff[$e] = "$_".Split("`n")[0]; Write-Warning "[$e] db temp: $($script:DbTempOff[$e]): no per-connection temp here" })   # @(try): one row stays a row
  @($rows | ForEach-Object { [pscustomobject]@{ id = "$($_[0])".Trim(); gb = [double]$_[1]; secs = [int]$_[2]; query = "$($_[3])" } })
}
function Stop-DbConn([string]$e, [string]$Id) { Invoke-DbEngine $e 'kill' @{ id = $Id } }
# the controller's watchdog: the connection using the most temp above db.tempMaxGB (default localEnv.db.tempMaxGB) is killed -> its line, else nothing
function Invoke-DbTempWatch([string]$e) {
  $max = [double]$(if ((Get-EnvCfg $e).db.tempMaxGB) { (Get-EnvCfg $e).db.tempMaxGB } else { Get-KitParam 'localEnv.db.tempMaxGB' })
  $top = @(Get-DbTempUse $e)[0]; if (-not $top -or $top.gb -le $max) { return }
  Stop-DbConn $e $top.id
  "killed db connection $($top.id): $($top.gb) GB temp > db.tempMaxGB $max, $($top.secs) s: $(Protect-KitText $top.query)"
}
# doctor rows: the server's temp caps (a query's temp has a ceiling below the watchdog's line), SELECT timeout, slow log, the datadir watched
function Get-DbTempDoctor([string]$e) {
  if (-not (Test-DbTemp $e)) { return }
  $w = @{}
  try { foreach ($row in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('temptable_max_ram', 'temptable_max_mmap', 'innodb_temp_data_file_path', 'max_execution_time', 'slow_query_log', 'log_output', 'datadir')") { $w[$row[0]] = $row[1] } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "db temp: $("$_".Split("`n")[0])" }; return }
  $max = [double]$(if ((Get-EnvCfg $e).db.tempMaxGB) { (Get-EnvCfg $e).db.tempMaxGB } else { Get-KitParam 'localEnv.db.tempMaxGB' }); $gb = { param($b) [math]::Round([double]$b / 1GB, 2) }
  $ib = if ("$($w.innodb_temp_data_file_path)" -match ':max:(\d+)([KMG])') { [double]$Matches[1] * @{ K = 1KB; M = 1MB; G = 1GB }[$Matches[2]] } elseif ("$($w.innodb_temp_data_file_path)" -notmatch 'autoextend') { 0 } else { -1 }
  $bad = @()
  if ($ib -lt 0) { $bad += "ibtmp1 has no max: it grows until the disk is full (server config [mysqld] innodb_temp_data_file_path = ibtmp1:12M:autoextend:max:1G, restart)" }
  elseif ((& $gb $ib) -gt $max) { $bad += "ibtmp1 max $(& $gb $ib) GB > db.tempMaxGB $max" }
  if ((& $gb $w.temptable_max_mmap) -gt $max) { $bad += "temptable_max_mmap $(& $gb $w.temptable_max_mmap) GB > db.tempMaxGB $max (SET PERSIST temptable_max_mmap = $([long]([math]::Min(4, $max) * 1GB)))" }
  $ram = try { [double](Get-SysMem).TotalGB } catch { 0 }   # TODO-PARAM: 1/8 of RAM (fixed default)
  if ($ram -and (& $gb $w.temptable_max_ram) -gt $ram / 8) { $bad += "temptable_max_ram $(& $gb $w.temptable_max_ram) GB > 1/8 of RAM (SET PERSIST temptable_max_ram = 1073741824)" }
  if ("$($w.max_execution_time)" -eq '0') { $bad += 'max_execution_time 0: a SELECT runs unbounded (SET PERSIST max_execution_time = 600000)' }
  # K103: lanes run low-write (log-output=NONE, slow log off by decision): off on purpose is no WARN
  $slowOff = "$($w.log_output)" -eq 'NONE' -or "$((Get-EnvCfg $e).db.expect.slow_query_log)" -in 'OFF', '0'
  if ($w.slow_query_log -ne 'ON' -and -not $slowOff) { $bad +="slow_query_log $($w.slow_query_log): no record of the query that filled the disk (SET PERSIST slow_query_log = ON)" }
  $nz = { param($p) "$p".Replace('\\', '\').Replace('/', '\').TrimEnd('\') + '\' }   # batch output escapes backslashes; a folder ends in one
  $dd = if ("$($w.datadir)".Trim()) { & $nz $w.datadir }; $wt = @(Get-KitSetting 'storage.watch' @() | Where-Object { "$_".Trim() } | ForEach-Object { & $nz $_ })
  if ($dd -and -not @($wt | Where-Object { $dd.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { $bad += "storage.watch lacks the db datadir $($dd.TrimEnd('\')) (kit.local.json storage.watch): the disk guard does not size it" }
  $pv = try { "$(@(Invoke-DbSql $e "SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE IN ('PROCESS', 'SUPER')")[0])" } catch { '' }
  if ($pv -eq '0') { $bad += 'the db user lacks PROCESS: dbtemp and the watchdog see only their own connection (GRANT PROCESS, CONNECTION_ADMIN)' }
  foreach ($b in $bad) { [pscustomobject]@{ level = 'WARN'; what = "db temp: $b" } }
  if (-not $bad.Count) { [pscustomobject]@{ level = 'OK'; what = "db temp: temptable_max_ram $(& $gb $w.temptable_max_ram) GB, temptable_max_mmap $(& $gb $w.temptable_max_mmap) GB, ibtmp1 $(if ($ib) { "max $(& $gb $ib) GB" } else { 'fixed size' }), max_execution_time $([int]$w.max_execution_time / 1000) s, slow log $(if ($w.slow_query_log -eq 'ON') { 'on' } else { 'off (low-write)' }), watchdog at $max GB" } }
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
  $want = @{}; foreach ($p in @((Get-KitProps $x) | Where-Object { $_.Name -notlike '_*' -and -not ($_.Name -eq 'innodb_buffer_pool_size' -and (Get-EnvCfg $e).db.bufferPool) })) { $want[$p.Name] = "$($p.Value)" }   # db.bufferPool owns the pool
  if (-not $want.Count) { return }
  $cur = @{}; try { foreach ($r in Invoke-DbSql $e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ($(@($want.Keys | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '))") { $cur[$r[0]] = $r[1] } }
  catch { [pscustomobject]@{ level = 'WARN'; what = "db.expect: $("$_".Split("`n")[0])" }; return }
  $num = { param($v) if ("$v" -match '^(\d+(?:\.\d+)?)([KMG])$') { [double]$Matches[1] * @{ K = 1KB; M = 1MB; G = 1GB }[$Matches[2].ToUpper()] } elseif ("$v" -match '^\d+(\.\d+)?$') { [double]$v } else { "$v".ToUpper() } }
  foreach ($k in @($want.Keys | Sort-Object)) { if ("$(& $num $cur[$k])" -ne "$(& $num $want[$k])") { [pscustomobject]@{ level = 'WARN'; what = "db $k = $(if ($null -ne $cur[$k]) { $cur[$k] } else { 'unknown' }), db.expect $($want[$k]) (server config [mysqld] $k = $($want[$k]); restart with no lease)" } } }
}
