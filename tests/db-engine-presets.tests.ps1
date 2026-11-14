#Requires -Version 7
<#
tests/db-engine-presets.tests.ps1: db.engine aliases + presets fill unset hooks; with mysqld on PATH, on a scratch server of its
own (never the env's DB): marks, a flashback round trip over 2 schemas (checksums equal the mark's), no binlog writes, a second
restore over an undone range, FK order + orphan check (that table falls back), no-PK duplicates, a cascade without the guard (child
seeded), the guard (3-level tree, SET NULL, ON UPDATE CASCADE, app triggers not fired), teardown, slices (dropped / retyped column,
index, FK, dropped and new table, view / procedure, a trigger table changed by DDL), DDL with no slice (falls back), db.rollback only on opt-in, dry run, mark expiry,
the temp watchdog + doctor rows; a client exit 0 without output (the end marker).
Usage: pwsh -NoProfile -File tests/db-engine-presets.tests.ps1 [-Kit <kit>].
Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
function New-PresetKit([string]$n) {
  $kd = New-TestKit $n; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy/adapters')
  Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $d)
  Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/*') $d -Force   # this branch's files, also when run by hand
  $kd
}
$k2 = New-PresetKit le2; $L2 = Join-Path $k2 'skills/envy/envy.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'PostgreSQL'; name = 'shop'; user = 'u' } }; my = @{ services = @(); db = @{ engine = 'mysql'; user = 'r'; exec = 'own' } } } } } (Join-Path $k2 'skills/crafty/kit.local.json') 6
$pr = & { . $L2; "$($script:LE.envs.shop.db.engine)|$($script:LE.envs.shop.db.query)|$($script:LE.envs.my.db.exec)|$($script:LE.envs.my.db.jdbc)|$(Test-DbMarks shop)$(Test-DbMarks my)" }
Expect "presets: db.engine aliases, unset hooks filled, own hooks kept, marks only for mysql / mariadb ($pr)" ($pr -match '^postgres\|psql -h 127\.0\.0\.1 -p 5432 -U u -d shop -At -c "\{sql\}"\|own\|jdbc:mysql://127\.0\.0\.1:3306/\{schema\}\?.+\|FalseTrue$')
$pk = & { . $L2; "$(Test-DbPosBefore 'h-bin.000002:900' 'h-bin.000010:4')$(Test-DbPosBefore 'b.000003:50' 'b.000003:40')" }
Expect "marks: positions compare in binlog order, file number first ($pk)" ($pk -eq 'TrueFalse')
# touched: a changeSet's <rollback> never runs forward (its DROP COLUMN of an added column made the slice SELECT a missing column)
$clog = Join-Path $k2 'add-col.xml'
Set-Content $clog '<databaseChangeLog><changeSet id="1"><sql>ALTER TABLE t1 ADD COLUMN c2 TEXT NULL</sql><rollback><sql>ALTER TABLE t1 DROP COLUMN c2</sql></rollback></changeSet><changeSet id="2"><dropColumn tableName="t3" columnName="c4"/><rollback><dropColumn tableName="t5" columnName="c6"/></rollback></changeSet><changeSet id="3"><rollback changeSetId="2"/><dropTable tableName="t7"/></changeSet></databaseChangeLog>'
$tch = @((& $py -X utf8 (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/db_flashback.py') touched --files $clog | ConvertFrom-Json).items | ForEach-Object { "$($_.table):$($_.kind):$($_.columns -join '+')" }) -join ','
Expect "touched: an added column is a create; a <rollback> body names nothing ($tch)" ($tch -eq 't1:create:,t3:column:c4,t7:table:')
# mask (tenant import): deterministic per value (one email = one mask in every table and run), logins without @ and keepValues
# kept, password -> passwordHash, varchar lengths kept, emails in text masked, skipData drops rows, DEFINER gone, a cut dump kept nothing
$mdir = Join-Path $k2 'mask'; New-Item -ItemType Directory -Force $mdir | Out-Null; $dump = Join-Path $mdir 'in.sql'; $mprof = Join-Path $mdir 'p.json'
$dumpText = @"
CREATE TABLE ``customer`` (
  ``id`` bigint NOT NULL AUTO_INCREMENT,
  ``name`` varchar(12) DEFAULT NULL,
  ``email`` varchar(254) DEFAULT NULL,
  ``phone`` varchar(20) DEFAULT NULL,
  ``address_id`` bigint DEFAULT NULL,
  ``notes`` text,
  PRIMARY KEY (``id``)
) ENGINE=InnoDB;
INSERT INTO ``customer`` VALUES (1,'Bob O\'Neil Jr','Bob@Shop.co.uk','+44 7700 900123',5,'call bob@shop.co.uk, it\'s ok'),(2,NULL,'keep@example.com','0123',NULL,'a\nb');
CREATE TABLE ``app_user`` (
  ``id`` bigint NOT NULL AUTO_INCREMENT,
  ``login`` varchar(50) NOT NULL,
  ``password_hash`` varchar(60) NOT NULL,
  PRIMARY KEY (``id``)
) ENGINE=InnoDB;
INSERT INTO ``app_user`` VALUES (1,'admin','`$2a`$x'),(2,'bob@shop.co.uk','`$2a`$y'),(3,'jsmith','`$2a`$z');
CREATE TABLE ``mail_audit`` (
  ``id`` bigint NOT NULL,
  ``body`` text,
  PRIMARY KEY (``id``)
) ENGINE=InnoDB;
INSERT INTO ``mail_audit`` VALUES (1,'to bob@shop.co.uk');
/*!50003 CREATE*/ /*!50017 DEFINER=``ro``@``%``*/ /*!50003 TRIGGER ``t1`` BEFORE INSERT ON ``customer`` FOR EACH ROW SET NEW.id = NEW.id */;;
-- Dump completed
"@
[IO.File]::WriteAllText($dump, $dumpText.Replace("`r`n", "`n")); '{ "passwordHash": "H", "keepValues": ["admin"], "skipData": ["mail_*"] }' | Set-Content $mprof
$fbPy = Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/db_flashback.py'
$mj = foreach ($n in 1, 2) { & $py -X utf8 $fbPy mask --in $dump --out (Join-Path $mdir "out$n.sql") --profile $mprof | ConvertFrom-Json }
$o1 = Get-Content (Join-Path $mdir 'out1.sql') -Raw; $o2 = Get-Content (Join-Path $mdir 'out2.sql') -Raw
$em = [regex]::Matches($o1, 'u[0-9a-f]{12}@example\.com') | ForEach-Object Value | Select-Object -Unique
$cu = [regex]::Match($o1, "INSERT INTO ``customer`` VALUES \(1,'([^']*)'").Groups[1].Value
Expect "mask: deterministic (2 runs equal), one email = one mask across tables and text ($(@($em) -join ',')), admin kept, password = H, name cut to varchar(12) ('$cu'), skipData rows gone, DEFINER gone ($($mj[0].masked.'customer.email') / $($mj[0].skippedData -join ','))" ($o1 -eq $o2 -and @($em).Count -eq 1 -and $o1 -notmatch '(?i)shop\.co\.uk' -and $o1 -match "\(1,'admin','H'\)" -and $o1 -match "\(3,'user_[0-9a-f]{10}','H'\)" -and $o1 -match "'keep@example\.com'" -and $cu.Length -le 12 -and $cu -ne 'Bob O\''Neil Jr' -and $o1 -notmatch 'INSERT INTO `mail_audit`' -and $o1 -notmatch 'DEFINER' -and $o1 -match "it\\'s ok" -and $o1 -match ',5,' -and @($mj[0].skippedData) -contains 'mail_audit')
[IO.File]::WriteAllText($dump, ($dumpText -replace '-- Dump completed', '').Replace("`r`n", "`n"))
$cut = & $py -X utf8 $fbPy mask --in $dump --out (Join-Path $mdir 'cut.sql') --profile $mprof | ConvertFrom-Json; $cutc = $LASTEXITCODE
'{ "rules": { "customer.notes": "nosuchkind" } }' | Set-Content $mprof; $bk = & $py -X utf8 $fbPy mask --in $dump --out (Join-Path $mdir 'bk.sql') --profile $mprof | ConvertFrom-Json
Expect "mask: a dump without its end line keeps no file; an unknown kind fails ($cutc | $($bk.error))" ($cutc -eq 1 -and $cut.error -match 'Dump completed' -and -not (Test-Path (Join-Path $mdir 'cut.sql')) -and $bk.error -match 'unknown mask kind')
Remove-TestKit $k2
# an exit 0 with no output (the mysql client under CPU load lost FKs, tables, rows): a read retries then fails, a write fails at once
if ($IsWindows) {
  $k4 = New-PresetKit le4; $fakeBin = Join-Path (Split-Path $k4) 'fakemysql'; New-Item -ItemType Directory -Force $fakeBin | Out-Null; Set-Content (Join-Path $fakeBin 'mysql.cmd') '@exit /b 0'
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = 1; user = 'u'; bin = $fakeBin } } } } } (Join-Path $k4 'skills/crafty/kit.local.json') 6
  $em = & { . (Join-Path $k4 'skills/envy/envy.ps1'); foreach ($q0 in 'SELECT 1', 'DELETE FROM t', 'WITH x AS (SELECT 1) DELETE FROM t') { try { Invoke-DbSql s $q0; 'rows' } catch { "$_" -replace '^mysql: exit 0 without the end marker \((\w+).*', '$1' } } }
  $ep = & $py -X utf8 -c "import sys, types; sys.path.insert(0, r'$(Join-Path $k4 'skills/envy/adapters')'); import db_flashback as f; d = f.Db(types.SimpleNamespace(host='h', port='1', user='u', mysql=r'$fakeBin\mysql.cmd'))`ntry: d.rows('SELECT 1'); print('rows')`nexcept RuntimeError as e: print('no output 3 times' in str(e))"
  Expect "an exit 0 without output is no answer: a read retries then fails, a write fails at once, never 0 rows ($em | $ep)" ("$em" -eq '3 a a' -and "$ep" -eq 'True')
  # the direct SQL-file path (restore apply, structure) fails at once; mysqlbinlog without its end-of-log line is read again, then fails
  # the ok pair: mysql prints the marker; mysqlbinlog loses its first output, prints the end-of-log line from the second call on
  Set-Content (Join-Path $fakeBin 'mysqlbinlog.cmd') '@echo x>>"%~dp0binlog-calls.txt"', '@exit /b 0'; $sqlFile = Join-Path $fakeBin 'x.sql'
  $okBin = Join-Path (Split-Path $k4) 'okmysql'; New-Item -ItemType Directory -Force $okBin | Out-Null; Set-Content (Join-Path $okBin 'mysql.cmd') '@echo __kit_rows_end__'
  Set-Content (Join-Path $okBin 'mysqlbinlog.cmd') '@echo x>>"%~dp0binlog-calls.txt"', '@for %%n in ("%~dp0binlog-calls.txt") do @if %%~zn GTR 3 echo # End of log file'
  $ef = & $py -X utf8 -c "import sys, types, io; sys.path.insert(0, r'$(Join-Path $k4 'skills/envy/adapters')'); import db_flashback as f`nns = lambda b: types.SimpleNamespace(host='h', port='1', user='u', mysql=b + r'\mysql.cmd', mysqlbinlog=b + r'\mysqlbinlog.cmd', start_file='binlog.000001', tool=f.TOOL)`nbad, ok = ns(r'$fakeBin'), ns(r'$okBin'); sp = io.StringIO('stale')`ndef t(fn):`n  open(r'$sqlFile', 'w').write('DELETE FROM t;')`n  try: return 'ran' if fn() is not None else 'none'`n  except RuntimeError as e: return 'lost' if 'end marker' in str(e) or 'End of log file' in str(e) else str(e)`nscan = lambda a: f.scan(a, {'x'}, [], f.key('binlog.000001:4'), None, sp)`nn = lambda b: open(b + r'\binlog-calls.txt').read().count('x')`nprint(t(lambda: f.Db(bad).run_file(r'$sqlFile')), t(lambda: scan(bad)), repr(sp.getvalue()), n(r'$fakeBin'), t(lambda: f.Db(ok).run_file(r'$sqlFile')), repr(open(r'$sqlFile').read().splitlines()[-2:]), t(lambda: scan(ok)), n(r'$okBin'))"
  Expect "the end marker: a SQL file without it fails at once; mysqlbinlog without its end-of-log line is read again (spool emptied): 3 lost = fail, a later whole read = the scan ($ef)" ("$ef" -eq "lost lost '' 3 ran ['DELIMITER ;', `"SELECT '__kit_rows_end__';`"] ran 2")
  # slices (column SELECT, mysqldump): a stream without its end line is read again, 3 lost = fail with no file; the end line never lands in the slice
  Set-Content (Join-Path $fakeBin 'slicelost.cmd') '@echo x>>"%~dp0slice-calls.txt"', '@exit /b 0'
  Set-Content (Join-Path $okBin 'sliceok.cmd') '@echo x>>"%~dp0slice-calls.txt"', "@for %%n in (`"%~dp0slice-calls.txt`") do @if %%~zn GTR 3 (echo 01`t02`t0& echo %~1)"
  $es = & $py -X utf8 -c "import sys, gzip, os; sys.path.insert(0, r'$(Join-Path $k4 'skills/envy/adapters')'); import db_flashback as f`ng = r'$okBin\s.gz'`ndef t(cmd, end):`n  try: f.stream_gz(cmd, g, end, 'slice x'); return gzip.open(g).read().decode().replace('\r', '').replace('\t', ',').strip()`n  except RuntimeError as e: return ('lost' if 'without its end line 3 times' in str(e) else str(e)) + ('+file' if os.path.exists(g) else '')`nn = lambda b: open(b + r'\slice-calls.txt').read().count('x')`nprint(t([r'$fakeBin\slicelost.cmd'], f.ROWS_END.encode()), n(r'$fakeBin'), t([r'$okBin\sliceok.cmd', f.ROWS_END], f.ROWS_END.encode()), n(r'$okBin'), t([r'$okBin\sliceok.cmd', '-- Dump completed'], f.DUMP_END))"
  Expect "slices: a SELECT or mysqldump stream without its end line is read again; 3 lost = fail, no slice kept; a whole read keeps the rows without the end line ($es)" ("$es" -eq 'lost 3 01,02,0 2 01,02,0')
  $ec = & $py -X utf8 -c "import sys, gzip, os; sys.path.insert(0, r'$(Join-Path $k4 'skills/envy/adapters')'); import db_flashback as f`ng, E = r'$okBin\c.gz', f.ROWS_END.encode()`nchild = `"import sys, os; d = bytes.fromhex(sys.argv[1]); s = int(sys.argv[2]); os.write(2, b'w' * 300000); [os.write(1, d[i:i + s]) for i in range(0, len(d), s)]; sys.exit(int(sys.argv[3]))`"`ndef run(body, step, code=0):`n  try: f.stream_gz([sys.executable, '-c', child, body.hex(), str(step), str(code)], g, E, 'c'); return gzip.open(g).read()`n  except RuntimeError as e: return 'fail' + ('+file' if os.path.exists(g) else '')`nbody = b'01\t02\t0\n' * 40`nprint(all(run(body + E + t, s) == body for s in (1, 3, 100) for t in (b'\n', b'\r\n', b'')), run(body + E + b'\n', 100, 2), run(b'01\t' + E + b'\n', 100))"
  Expect "slices: any read size and line break, a 300 KB stderr (no hang); a failed exit or an end text that is not its own line leaves no slice ($ec)" ("$ec" -eq 'True fail fail')
  # a restore with 4237 row changes: its option lists passed the 8191-char cmd.exe limit of a python.bat shim ("The command line is too long")
  $pyShim = Join-Path $fakeBin 'python.cmd'; Set-Content $pyShim "@`"$((Get-Command $py).Source)`" %*"
  $bigSchemas = (1..3000 | ForEach-Object { "tenant_schema_$_" }) -join ','
  $el = & { . (Join-Path $k4 'skills/envy/envy.ps1'); function Get-Python { $pyShim }; try { $null = Invoke-DbFb s 'guard' @('--schemas', $bigSchemas); 'no throw' } catch { "$_" } }
  Expect "flashback options past the command-line limit ($($bigSchemas.Length) chars) reach db_flashback.py through an @file ($el)" ("$el" -match '^db_flashback\.py guard: \w+Error: ' -and "$el" -notmatch 'too long')
  Remove-TestKit $k4
}

# ---- a scratch mysqld (own data dir and port, binlog ROW / FULL): never the env's server
$mysqld = Get-Command mysqld -ErrorAction SilentlyContinue
if (-not $mysqld -or -not (Get-Command mysqlbinlog -ErrorAction SilentlyContinue)) { 'SKIP flashback round trip (no mysqld / mysqlbinlog on PATH)'; Complete-Tests }
$k3 = New-PresetKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'
$fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $port = $fp.LocalEndpoint.Port; $fp.Stop()   # an OS-picked free port: 3390+ raced parallel runs
$data = Join-Path $env:TEMP "mysqld-$PID"
& $mysqld.Source --no-defaults --initialize-insecure "--datadir=$data" 2>&1 | Out-Null
$srv = Start-Process $mysqld.Source -ArgumentList "--no-defaults `"--datadir=$data`" --port=$port --bind-address=127.0.0.1 --mysqlx=OFF --log-bin=binlog --server-id=1 --binlog-row-metadata=FULL" -WindowStyle Hidden -PassThru
try {
  for ($i = 0; $i -lt 60 -and -not (Test-NetConnection 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue); $i++) { Start-Sleep 1 }
  $env:MYSQL_PWD = ''
  function Q([string]$sql) {   # the end marker as in Invoke-DbSql: an exit 0 without output under load is retried, never 0 rows
    foreach ($try in 1..3) { $o = @("$($sql.TrimEnd().TrimEnd(';'));`nSELECT '__kit_rows_end__';" | mysql -h 127.0.0.1 -P $port -u root --default-character-set=utf8mb4 -N -B 2>&1); if ($LASTEXITCODE) { throw "$o" }
      if ($o.Count -and $o[-1] -eq '__kit_rows_end__') { return $o | Select-Object -SkipLast 1 } }
    throw "mysql: no output 3 times: $sql" }
  Q @"
CREATE DATABASE fa; CREATE DATABASE fb;
CREATE TABLE fa.t (id int primary key auto_increment, s varchar(40), d decimal(8,2), f double, dt datetime(3), ts timestamp(2) null, dd date, tm time, j json, e enum('x','y'), st set('a','b','c'), b blob, u int unsigned, bt bit(4), g int as (char_length(s)) virtual, n text) charset utf8mb4;
CREATE TABLE fb.k (a int, b varchar(40));
INSERT INTO fa.t (s, d, f, dt, ts, dd, tm, j, e, st, b, u, bt, n) VALUES ('keep \\ it''s', 1.5, 2.25, '2026-01-01 00:00:00.5', '2026-01-01 10:00:00', '2026-01-01', '01:02:03', '{"k": 1}', 'x', 'b', x'01', 7, b'0001', 'n1'), ('gone é€', -3, 1.1, NULL, NULL, NULL, NULL, NULL, 'y', '', NULL, 4294967295, b'1111', NULL);
INSERT INTO fb.k VALUES (1, 'a'), (1, 'a'), (2, 'b');
CREATE TABLE fb.p (id int primary key, v varchar(10)); CREATE TABLE fb.c (id int primary key auto_increment, pid int, foreign key (pid) references fb.p (id));
CREATE TABLE fb.n (a int, b double, f float); CREATE TABLE fb.cp (id int primary key); CREATE TABLE fb.cc (id int primary key, pid int, foreign key (pid) references fb.cp (id) on delete cascade);
INSERT INTO fb.p VALUES (1, 'p1'), (2, 'p2'); INSERT INTO fb.c VALUES (10, 1), (20, 2); INSERT INTO fb.n VALUES (1, 1.1, 0.1), (1, 1.1, 0.1), (2, 2.5, 0.5); INSERT INTO fb.cp VALUES (1); INSERT INTO fb.cc VALUES (5, 1);
CREATE TABLE fa.o (id int primary key, note varchar(20), qty decimal(6,2), KEY ix_note (note)); CREATE TABLE fa.r (id int primary key, o_id int, txt text, CONSTRAINT fk_r_o FOREIGN KEY (o_id) REFERENCES fa.o (id));
INSERT INTO fa.o VALUES (1, 'a é', 1.5), (2, NULL, 2), (3, 'c', 3); INSERT INTO fa.r VALUES (7, 1, 'x'), (8, 3, 'y');
"@
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $sum = { (Q 'CHECKSUM TABLE fa.t, fb.k') -join ' | ' }
  $c0 = & $sum
  $mk = Px $L3 mark -Env s -Name 'Before Test' 2>&1 | Out-String
  $change = { Q "UPDATE fa.t SET s = 'changed', j = '{`"z`": [1, 2]}', n = CONCAT('a', CHAR(10), 'b''c'), st = 'a,c', u = 0 WHERE id = 1; DELETE FROM fa.t WHERE id = 2; INSERT INTO fa.t (s, e) VALUES ('new', 'y'); DELETE FROM fb.k WHERE a = 1 LIMIT 1; UPDATE fb.k SET b = 'bb' WHERE a = 2; INSERT INTO fb.k VALUES (3, NULL)" }
  & $change
  $dry = Px $L3 restore -Env s -Mark before-test -DryRun 2>&1 | Out-String; $dc = $LASTEXITCODE
  Expect "restore -DryRun: tables + row counts, nothing changes ($dc)" ($dc -eq 0 -and $mk -match 'mark before-test at binlog\.\d+:\d+' -and $dry -match 'rows: 6 change\(s\) undone' -and $dry -match 'fa\.t : 1 insert\(s\) -> delete, 1 update\(s\) -> back, 1 delete\(s\) -> back in' -and (& $sum) -ne $c0)
  # a flashback that never started (python.bat: "The command line is too long") recorded the range undone: the next restore skipped all of it
  $nf = & { . $L3; $m = Find-Mark (Read-State s) 'before-test' 0; $p = Get-RestorePlan s $m @('fa', 'fb') 'nf'; function Invoke-DbFlashback { throw 'db_flashback.py apply failed (exit 1): The command line is too long.' }
    $sp = $p.Clone(); $sp.steps = @(@{ dir = 'x'; tables = @('fa.t'); mark = 'm0' }); function Invoke-DbFb { @{ verified = $false; differs = @('fa.t') } }
    "$(Invoke-RestoreDb s $m @('fa', 'fb') $p)|$(Invoke-RestoreDb s $m @('fa', 'fb') $sp)|$(@((Read-State s).undone | Where-Object { $_ }).Count)|$([bool](Find-Mark (Read-State s) 'before-test' 0))" }
  Expect "a flashback that wrote no row (never started, or a structure step failed first) records no undone range and keeps the marks ($nf)" ($nf -eq 'row flashback failed: db_flashback.py apply failed (exit 1): The command line is too long.|structure back to mark m0 failed: still differs: fa.t|0|True' -and (& $sum) -ne $c0)
  $rt = & { . $L3; $st = Read-State s; $m = Find-Mark $st 'before-test' 0; $p = Get-RestorePlan s $m @('fa', 'fb') 't1'; $p0 = Get-DbPos s; $e1 = Invoke-RestoreDb s $m @('fa', 'fb') $p; "$e1|$((Read-State s).undone)|$p0" }
  Expect "flashback round trip: insert / update / delete over 2 schemas back to the mark's checksums ($rt)" ((& $sum) -eq $c0 -and $rt -match '^\|binlog\.\d+:\d+~binlog\.\d+:\d+\|')
  $p1 = ($rt -split '\|')[2]; $end = ((($rt -split '\|')[1]) -split '~')[1]
  Expect "flashback: sql_log_bin=0, the binlog has no flashback writes ($p1 -> $end)" ($p1 -eq $end)
  Q "INSERT INTO fb.k VALUES (9, 'later')"
  $r2 = & { . $L3; $st = Read-State s; $m = Find-Mark $st 'before-test' 0; $p = Get-RestorePlan s $m @('fa', 'fb') 't2'; "$($p.statements)|$(Invoke-RestoreDb s $m @('fa', 'fb') $p)" }
  Expect "a second restore skips the undone range: only the new change is undone ($r2)" ($r2 -eq '1|' -and (& $sum) -eq $c0)
  # FK RESTRICT: child then parent deleted -> both back in one global order, no orphans; a wrong order is rolled back by the orphan check
  $sum2 = { (Q 'CHECKSUM TABLE fb.p, fb.c, fb.n') -join ' | ' }; $c2 = & $sum2
  $null = Px $L3 mark -Env s -Name fk 2>&1
  Q "DELETE FROM fb.c WHERE pid = 2; DELETE FROM fb.p WHERE id = 2; DELETE FROM fb.n WHERE a = 1 LIMIT 1; UPDATE fb.n SET b = 9 WHERE a = 2"
  $fk = & { . $L3; $m = Find-Mark (Read-State s) 'fk' 0; $p = Get-RestorePlan s $m @('fb') 'fk'; Invoke-RestoreDb s $m @('fb') $p }
  Expect "FK RESTRICT order + a table without a primary key (duplicate rows): exact, 0 orphans ($fk)" (-not $fk -and (& $sum2) -eq $c2 -and "$(Q 'SELECT COUNT(*) FROM fb.c LEFT JOIN fb.p ON fb.p.id = fb.c.pid WHERE fb.p.id IS NULL')" -eq '0')
  $null = Px $L3 mark -Env s -Name fk2 2>&1; Q "DELETE FROM fb.c WHERE pid = 2; DELETE FROM fb.p WHERE id = 2"
  $m2 = & { . $L3; (Find-Mark (Read-State s) 'fk2' 0).pos }
  $wo = & $py -X utf8 (Join-Path $k3 'skills/envy/adapters/db_flashback.py') apply --from $m2 --schemas fb --port $port --user root --order tables --batch 1 | ConvertFrom-Json
  Expect "a batch that grows FK orphans is rolled back; that table falls back, the rest is applied ($(@($wo.fallback | ForEach-Object { "$($_.table): $($_.why)" }) -join '; '))" ($wo.applied -and @($wo.fallback | Where-Object { $_.table -eq 'fb.c' -and $_.why -match 'batch 1 failed on it: orphans fb\.c -> fb\.p' }).Count -and "$(Q 'SELECT COUNT(*) FROM fb.p WHERE id = 2')" -eq '1')
  $null = & { . $L3; $m = Find-Mark (Read-State s) 'fk2' 0; Invoke-RestoreDb s $m @('fb') (Get-RestorePlan s $m @('fb') 'fk2') }
  # a cascade with no guard: its child rows are not in the binlog -> that child table falls back to the seed items naming it
  $seedf = & { . $L3; SeedFile s }; New-Item -ItemType Directory -Force (Split-Path $seedf) | Out-Null
  & $J @{ items = @(@{ name = 'cc-5'; tables = @('fb.cc'); check = @{ sql = 'SELECT COUNT(*) FROM fb.cc WHERE id = 5' }; create = @{ cmd = "mysql -h 127.0.0.1 -P $port -u root -e `"INSERT INTO fb.cc VALUES (5, 1)`"" } }, @{ name = 'other'; tables = @('fa.x'); check = @{ sql = 'SELECT 0' } }) } $seedf 6
  $null = Px $L3 mark -Env s -Name casc 2>&1; Q 'DELETE FROM fb.cp WHERE id = 1'
  $cr = & { . $L3; $m = Find-Mark (Read-State s) 'casc' 0; $p = Get-RestorePlan s $m @('fb') 'c'; $x = Invoke-RestoreDb s $m @('fb') $p; "$(@($p.fallback | ForEach-Object table) -join ',')|$x|$(Invoke-RestoreFallback s)" }
  Expect "ON DELETE CASCADE without the guard: parent back, the child table seeded from the item naming it, said ($cr)" ($cr -match '^fb\.cc\|\|fallback .+fb\.cc \(fb\.cp rows deleted .+no cascade guard.+seed green' -and "$(Q 'SELECT COUNT(*) FROM fb.cp WHERE id = 1')" -eq '1' -and "$(Q 'SELECT COUNT(*) FROM fb.cc WHERE id = 5')" -eq '1')
  # the cascade guard (doctor installs it): a 3-level CASCADE tree, SET NULL, ON UPDATE CASCADE; app triggers never fire on the way back
  Q @'
CREATE TABLE fb.tp (id int primary key, v varchar(10));
CREATE TABLE fb.tc (id int primary key, pid int, x varchar(300), FOREIGN KEY (pid) REFERENCES fb.tp (id) ON DELETE CASCADE ON UPDATE CASCADE);
CREATE TABLE fb.tg (id int primary key auto_increment, cid int, d decimal(9,3), ts datetime(3), j json, b bit(3), e enum('x','y'), st set('a','b'), f float, dd double, t time(2), y year, bl blob, ch char(3), FOREIGN KEY (cid) REFERENCES fb.tc (id) ON DELETE CASCADE);
CREATE TABLE fb.ts (id int primary key, pid int, FOREIGN KEY (pid) REFERENCES fb.tp (id) ON DELETE SET NULL ON UPDATE SET NULL);
CREATE TABLE fb.tlog (n int auto_increment primary key, msg varchar(50));
CREATE TRIGGER fb.tr_tp AFTER UPDATE ON fb.tp FOR EACH ROW INSERT INTO fb.tlog (msg) VALUES (CONCAT('upd ', NEW.id));
CREATE TRIGGER fb.tr_tg BEFORE INSERT ON fb.tg FOR EACH ROW INSERT INTO fb.tlog (msg) VALUES ('tg ins');
INSERT INTO fb.tp VALUES (1, 'one'), (2, 'two'); INSERT INTO fb.tc VALUES (10, 1, 'c10'), (11, 1, 'c11'), (20, 2, 'c20');
INSERT INTO fb.tg (cid, d, ts, j, b, e, st, f, dd, t, y, bl, ch) VALUES (10, 1.5, '2026-01-01 01:02:03.456', '{"a": 1}', b'101', 'y', 'a,b', 1.5, 2.25, '01:02:03.45', 2026, x'00ff', 'ab'), (11, -2.25, NULL, '[1]', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL), (20, 0, NOW(3), NULL, b'1', NULL, '', 0, 0, '-01:00:00', 1999, '', '');
INSERT INTO fb.ts VALUES (100, 1), (200, 2);
'@
  $doc = Px $L3 doctor -Env s 2>&1 | Out-String
  $sum4 = { (Q 'CHECKSUM TABLE fb.tp, fb.tc, fb.tg, fb.ts, fb.tlog') -join ' | ' }; $c4 = & $sum4; $l4 = "$(Q 'SELECT COUNT(*) FROM fb.tlog')"
  $null = Px $L3 mark -Env s -Name tree 2>&1
  Q "UPDATE fb.tp SET v = 'TWO' WHERE id = 2; DELETE FROM fb.tp WHERE id = 1; UPDATE fb.tp SET id = 3 WHERE id = 2; INSERT INTO fb.tg (cid, d) VALUES (20, 9)"
  $gone = "$(Q 'SELECT COUNT(*) FROM fb.tg')|$(Q 'SELECT COUNT(*) FROM fb.ts WHERE pid IS NULL')|$(Q 'SELECT COUNT(*) FROM fb.tlog')"
  $tr = & { . $L3; $m = Find-Mark (Read-State s) 'tree' 0; $p = Get-RestorePlan s $m @('fb') 'tree'; "$(@($p.fallback).Count)|$(Invoke-RestoreDb s $m @('fb') $p)" }
  Expect "cascade guard: doctor installs it; a 3-level CASCADE tree, SET NULL and ON UPDATE CASCADE children back exactly ($($doc -replace '\s+', ' '); $gone -> $tr)" ($doc -match 'cascade guard: 4 trigger\(s\) installed' -and $gone -eq '2|2|6' -and $tr -eq '0|' -and (& $sum4) -eq $c4)
  Expect "app triggers: the undo runs as row events, no trigger fires (log rows $l4 -> $(Q 'SELECT COUNT(*) FROM fb.tlog'))" ("$(Q 'SELECT COUNT(*) FROM fb.tlog')" -eq $l4)
  $td = Px $L3 teardown -Env s 2>&1 | Out-String
  Expect "teardown: the guard's triggers and its journal schema removed ($($td.Trim()))" ($td -match 'removed: 4 trigger' -and "$(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME LIKE 'kit\_cg\_%'")" -eq '0' -and "$(Q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'kit_journal'")" -eq '0')
  # structure: a release mark keeps slices of what its migration destroys; restore = structure back, then rows
  # idempotent: Q re-runs the whole batch when the end marker is lost ("Table 'v1' already exists")
  $obj = "CREATE OR REPLACE VIEW fa.v1 AS SELECT id, note FROM fa.o; DROP PROCEDURE IF EXISTS fa.pr; CREATE PROCEDURE fa.pr() SELECT 1; CREATE TABLE IF NOT EXISTS fa.olog (n int auto_increment primary key, id int); DROP TRIGGER IF EXISTS fa.tr_o; CREATE TRIGGER fa.tr_o AFTER UPDATE ON fa.o FOR EACH ROW INSERT INTO fa.olog (id) VALUES (NEW.id)"
  Q $obj; $rr = try { Q $obj; 'ok' } catch { "$_" }
  Expect "objects setup: a retried batch runs again without error ($rr)" ($rr -eq 'ok')
  $sum3 = { (Q 'CHECKSUM TABLE fa.o, fa.r, fa.olog') -join ' | ' }; $c3 = & $sum3; $cr3 = (Q 'SHOW CREATE TABLE fa.o') -join ''; $ob3 = { "$((Q 'SHOW CREATE VIEW fa.v1') -join '')|$((Q 'SHOW CREATE PROCEDURE fa.pr') -join '')" }; $o3 = & $ob3
  $sv = & { . $L3; $n = New-Mark s 'release-7' 'release'; $sl = Save-Slices s $n @{ api = @{ items = @(@{ table = 'o'; kind = 'column'; columns = @('note', 'qty', 'added_later') }, @{ table = 'r'; kind = 'table'; columns = @() }); unknown = $false } }; "$n|$($sl.bytes)" }
  Q "ALTER TABLE fa.r DROP FOREIGN KEY fk_r_o; DROP VIEW fa.v1; ALTER TABLE fa.o DROP INDEX ix_note, DROP COLUMN note, MODIFY qty int, ADD COLUMN extra int DEFAULT 5; DROP TABLE fa.r; CREATE TABLE fa.neu (id int primary key); INSERT INTO fa.neu VALUES (1); UPDATE fa.o SET qty = 9 WHERE id = 2; INSERT INTO fa.o (id, qty) VALUES (4, 4); DROP PROCEDURE fa.pr; CREATE PROCEDURE fa.pr() SELECT 2; CREATE VIEW fa.v2 AS SELECT 1 AS x"
  $sd = Px $L3 restore -Env s -Release 7 -DryRun 2>&1 | Out-String
  $sr = & { . $L3; $m = Find-Mark (Read-State s) '' 7; $p = Get-RestorePlan s $m @('fa', 'fb') 'r7'; Invoke-RestoreDb s $m @('fa', 'fb') $p }
  Expect "slices: dropped / retyped columns (one added later: no slice, no error), an index, a referenced table and a new table back to the mark; rows after it undone ($sv; $sr)" (-not $sr -and [long]($sv -split '\|')[1] -gt 0 -and (& $sum3) -eq $c3 -and ((Q 'SHOW CREATE TABLE fa.o') -join '') -eq $cr3 -and
    -not "$(Q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'fa' AND TABLE_NAME = 'neu'")".Trim().Equals('1') -and $sd -match 'structure: fa\.o, fa\.r back to mark release-7' -and $sd -match 'fa\.neu dropped')
  Expect "objects: a dropped view and a replaced procedure back from the release mark, a view made after it dropped; a trigger table changed by DDL undone with its trigger suspended" ((& $ob3) -eq $o3 -and "$(Q "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'fa' AND TABLE_NAME = 'v2'")" -eq '0' -and $sd -match 'objects: .*VIEW:fa\.v1.* back to mark release-7' -and "$(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME = 'tr_o'")" -eq '1')
  Q 'ALTER TABLE fb.k ADD COLUMN z int'
  $dd = Px $L3 restore -Env s -Mark release-7 -DryRun 2>&1 | Out-String; $ddc = $LASTEXITCODE
  Expect "DDL after the mark on a table no mark sliced: that table falls back to seed (named, why), exit 0 ($ddc)" ($ddc -eq 0 -and $dd -match 'FALLBACK fb\.k : structure changed after the mark \(alter at .+\) and no mark kept its slice.+-> seed' -and $dd -notmatch 'REFUSED')
  Q 'ALTER TABLE fb.k DROP COLUMN z'
  # the default restore is the kit's own; db.rollback runs only on opt-in
  $rbf = Join-Path (Kd) 'rollback.ran'
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb'); rollback = "echo {mark}> `"$rbf`"" } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $tr = & { . $L3; $n = New-Mark s 'opt' 'owner'; Q "INSERT INTO fb.k VALUES (11, 'x')"; $m = Find-Mark (Read-State s) 'opt' 0
    $a1 = Invoke-RestoreDb s $m @('fa', 'fb') (Get-RestorePlan s $m @('fa', 'fb') 'o1'); $t1 = Test-Path $rbf; Q "INSERT INTO fb.k VALUES (12, 'y')"
    $a2 = Invoke-RestoreDb s $m @('fa', 'fb') (Get-RestorePlan s $m @('fa', 'fb') 'o2') -UseTool; "$a1|$t1|$a2|$(Test-Path $rbf)" }
  Expect "restore: the default never calls db.rollback; -UseTool calls it, then the kit's revert ($tr)" ($tr -eq '|False||True' -and "$(Q 'SELECT COUNT(*) FROM fb.k WHERE a IN (11, 12)')" -eq '0')
} finally {
  if ($srv -and -not $srv.HasExited) { & mysqladmin -h 127.0.0.1 -P $port -u root shutdown 2>&1 | Out-Null; $null = $srv.WaitForExit(30000); if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force } }
  Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
  Remove-TestKit $k3
}
Complete-Tests
