#Requires -Version 7
<#
tests.ps1 (goody db-engine-presets): db.engine aliases + presets fill unset hooks; with mysqld on PATH, on a scratch server of its
own (never the env's DB): marks, a flashback round trip over 2 schemas (checksums equal the mark's), no binlog writes, a second
restore over an undone range, FK order + orphan check (that table falls back), no-PK duplicates, a cascade without the guard (child
seeded), the guard (3-level tree, SET NULL, ON UPDATE CASCADE, app triggers not fired), teardown, slices (dropped / retyped column,
index, FK, dropped and new table, view / procedure, a trigger table changed by DDL), DDL with no slice (falls back), db.rollback only on opt-in, dry run, mark expiry,
the temp watchdog + doctor rows; the goody check line.
Usage: kitbag.py goody test db-engine-presets, or pwsh -File goodies/db-engine-presets/tests.ps1 -Kit <kit> (needs the goody local-env).
Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
function New-PresetKit([string]$n) {
  $kd = New-TestKit $n; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy/adapters')
  Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $d)
  Copy-Item (Join-Path $PSScriptRoot 'files/skills/envy/adapters/*') $d -Force   # this branch's files, also when run by hand
  $kd
}
if (-not (Test-Path (Join-Path $src 'skills/envy/envy.ps1'))) { 'SKIP db-engine-presets (needs the goody local-env)'; Complete-Tests }
$k2 = New-PresetKit le2; $L2 = Join-Path $k2 'skills/envy/envy.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'PostgreSQL'; name = 'shop'; user = 'u' } }; my = @{ services = @(); db = @{ engine = 'mysql'; user = 'r'; exec = 'own' } } } } } (Join-Path $k2 'skills/crafty/kit.local.json') 6
$pr = & { . $L2; "$($script:LE.envs.shop.db.engine)|$($script:LE.envs.shop.db.query)|$($script:LE.envs.my.db.exec)|$($script:LE.envs.my.db.jdbc)|$(Test-DbMarks shop)$(Test-DbMarks my)" }
Expect "presets: db.engine aliases, unset hooks filled, own hooks kept, marks only for mysql / mariadb ($pr)" ($pr -match '^postgres\|psql -h 127\.0\.0\.1 -p 5432 -U u -d shop -At -c "\{sql\}"\|own\|jdbc:mysql://127\.0\.0\.1:3306/\{schema\}\?.+\|FalseTrue$')
$pk = & { . $L2; "$(Test-DbPosBefore 'h-bin.000002:900' 'h-bin.000010:4')$(Test-DbPosBefore 'b.000003:50' 'b.000003:40')" }
Expect "marks: positions compare in binlog order, file number first ($pk)" ($pk -eq 'TrueFalse')
# the config line: db.engine in kit.local.json asks for this goody (kitbag.py goody check)
$need = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$src/skills/bossy'); import kitbag as k; k.local_config = lambda kit, f: {'localEnv': {'defaults': {'db': {'engine': 'mysql'}}}} if f == 'kit.local.json' else {}; k.installed_extras = lambda kit: {}; print(','.join(n for n, _ in k.extras_needed(r'$src')))" 2>&1
Expect "kitbag goody check: localEnv.defaults.db.engine mysql needs db-engine-presets ($need)" ("$need" -match '(^|,)db-engine-presets(,|$)')
Remove-TestKit $k2

# ---- a scratch mysqld (own data dir and port, binlog ROW / FULL): never the env's server
$mysqld = Get-Command mysqld -ErrorAction SilentlyContinue
if (-not $mysqld -or -not (Get-Command mysqlbinlog -ErrorAction SilentlyContinue)) { 'SKIP flashback round trip (no mysqld / mysqlbinlog on PATH)'; Complete-Tests }
$k3 = New-PresetKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'
$port = 3390; while (Test-NetConnection 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) { $port++ }
$data = Join-Path $env:TEMP "mysqld-$PID"
& $mysqld.Source --no-defaults --initialize-insecure "--datadir=$data" 2>&1 | Out-Null
$srv = Start-Process $mysqld.Source -ArgumentList "--no-defaults `"--datadir=$data`" --port=$port --bind-address=127.0.0.1 --mysqlx=OFF --log-bin=binlog --server-id=1 --binlog-row-metadata=FULL" -WindowStyle Hidden -PassThru
try {
  for ($i = 0; $i -lt 60 -and -not (Test-NetConnection 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue); $i++) { Start-Sleep 1 }
  $env:MYSQL_PWD = ''
  function Q([string]$sql) { $o = $sql | mysql -h 127.0.0.1 -P $port -u root --default-character-set=utf8mb4 -N -B 2>&1; if ($LASTEXITCODE) { throw "$o" }; $o }
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
  Q "CREATE VIEW fa.v1 AS SELECT id, note FROM fa.o; CREATE PROCEDURE fa.pr() SELECT 1; CREATE TABLE fa.olog (n int auto_increment primary key, id int); CREATE TRIGGER fa.tr_o AFTER UPDATE ON fa.o FOR EACH ROW INSERT INTO fa.olog (id) VALUES (NEW.id)"
  $sum3 = { (Q 'CHECKSUM TABLE fa.o, fa.r, fa.olog') -join ' | ' }; $c3 = & $sum3; $cr3 = (Q 'SHOW CREATE TABLE fa.o') -join ''; $ob3 = { "$((Q 'SHOW CREATE VIEW fa.v1') -join '')|$((Q 'SHOW CREATE PROCEDURE fa.pr') -join '')" }; $o3 = & $ob3
  $sv = & { . $L3; $n = New-Mark s 'release-7' 'release'; $sl = Save-Slices s $n @{ api = @{ items = @(@{ table = 'o'; kind = 'column'; columns = @('note', 'qty') }, @{ table = 'r'; kind = 'table'; columns = @() }); unknown = $false } }; "$n|$($sl.bytes)" }
  Q "ALTER TABLE fa.r DROP FOREIGN KEY fk_r_o; DROP VIEW fa.v1; ALTER TABLE fa.o DROP INDEX ix_note, DROP COLUMN note, MODIFY qty int, ADD COLUMN extra int DEFAULT 5; DROP TABLE fa.r; CREATE TABLE fa.neu (id int primary key); INSERT INTO fa.neu VALUES (1); UPDATE fa.o SET qty = 9 WHERE id = 2; INSERT INTO fa.o (id, qty) VALUES (4, 4); DROP PROCEDURE fa.pr; CREATE PROCEDURE fa.pr() SELECT 2; CREATE VIEW fa.v2 AS SELECT 1 AS x"
  $sd = Px $L3 restore -Env s -Release 7 -DryRun 2>&1 | Out-String
  $sr = & { . $L3; $m = Find-Mark (Read-State s) '' 7; $p = Get-RestorePlan s $m @('fa', 'fb') 'r7'; Invoke-RestoreDb s $m @('fa', 'fb') $p }
  Expect "slices: dropped / retyped columns, an index, a referenced table and a new table back to the mark; rows after it undone ($sv; $sr)" (-not $sr -and [long]($sv -split '\|')[1] -gt 0 -and (& $sum3) -eq $c3 -and ((Q 'SHOW CREATE TABLE fa.o') -join '') -eq $cr3 -and
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
  # goody liquibase: update-sql (the pending changeSets) -> touched tables; tag / rollback run only on the schemas it manages
  $lbs = Join-Path $PSScriptRoot '../liquibase/files/skills/crafty/adapters/liquibase.ps1'
  if (Test-Path $lbs) {
    New-Item -ItemType Directory -Force (Join-Path $k3 'skills/crafty/adapters') | Out-Null; Copy-Item $lbs (Join-Path $k3 'skills/crafty/adapters')
    $bin = Join-Path (Kd) 'lbbin'; $lbl = Join-Path (Kd) 'lb.log'; New-Item -ItemType Directory -Force $bin | Out-Null
    if ($IsWindows) { Set-Content (Join-Path $bin 'liquibase.cmd') "@echo %* pw=%LIQUIBASE_COMMAND_PASSWORD%>> `"$lbl`"`r`n@echo ALTER TABLE o DROP COLUMN qty;" }
    else { Set-Content (Join-Path $bin 'liquibase') "#!/bin/sh`necho `"`$* pw=`$LIQUIBASE_COMMAND_PASSWORD`" >> '$lbl'`necho 'ALTER TABLE o DROP COLUMN qty;'"; chmod +x (Join-Path $bin 'liquibase') }
    $repo = Join-Path (Kd) 'lbrepo'; New-Item -ItemType Directory -Force "$repo/db/changelog" | Out-Null; git -C $repo init -q 2>&1 | Out-Null
    Set-Content "$repo/db/changelog/master.xml" '<databaseChangeLog/>'; git -C $repo add -A 2>&1 | Out-Null
    Q 'CREATE TABLE fa.DATABASECHANGELOG (id varchar(255))'
    $oldPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"
    try {
      $lt = & { . $L3; $pf = Join-Path (Kd) 'pending.sql'; $u = Invoke-EnvLiquibase s $repo @(LiquibaseSchemas s) 'update-sql' $pf
        $t = @((Invoke-DbFb s 'touched' @('--files', $pf)).items); $g = Invoke-EnvLiquibase s $repo @(LiquibaseSchemas s) 'tag --tag=release-3'
        "$(@(LiquibaseSchemas s) -join ',')|$u|$($t.table):$($t.kind):$($t.columns)|$g" }
    } finally { $env:PATH = $oldPath }
    $ll = @(Get-Content $lbl -ErrorAction SilentlyContinue)
    Expect "liquibase: update-sql of the first managed schema -> the touched tables; tag only on schemas with a DATABASECHANGELOG; ($lt; $($ll -join ' / '))" ($lt -eq 'fa||o:column:qty|' -and $ll.Count -eq 2 -and $ll[0] -match 'changelog-file="master\.xml".+url="jdbc:mysql://127\.0\.0\.1:\d+/fa\?.+update-sql pw=' -and $ll[1] -match 'tag --tag=release-3')
    Q 'DROP TABLE fa.DATABASECHANGELOG'
  }
  # review cases: an FK name shared by two schemas, statement-format DML, FLOAT bytes, a view on a view, triggers a killed run left dropped
  Q 'CREATE TABLE fa.sp (id int primary key); CREATE TABLE fa.sc (id int primary key, pid int, CONSTRAINT fk_same FOREIGN KEY (pid) REFERENCES fa.sp (id) ON DELETE CASCADE); CREATE TABLE fb.sp (id int primary key); CREATE TABLE fb.sc (id int primary key, pid int, CONSTRAINT fk_same FOREIGN KEY (pid) REFERENCES fb.sp (id) ON DELETE CASCADE); INSERT INTO fa.sp VALUES (1); INSERT INTO fa.sc VALUES (1, 1); INSERT INTO fb.sp VALUES (1); INSERT INTO fb.sc VALUES (1, 1)'
  $null = Px $L3 mark -Env s -Name same 2>&1; Q 'DELETE FROM fa.sc WHERE pid = 1; DELETE FROM fb.sp WHERE id = 1'
  $sm = & { . $L3; $m = Find-Mark (Read-State s) 'same' 0; @((Get-RestorePlan s $m @('fa', 'fb') 'same').fallback | ForEach-Object table) -join ',' }
  Expect "cascade gaps: an FK name in two schemas is two FKs (fb's gap seen though fa deleted that key by hand) ($sm)" ($sm -eq 'fb.sc')
  $null = & { . $L3; $m = Find-Mark (Read-State s) 'same' 0; Invoke-RestoreDb s $m @('fa', 'fb') (Get-RestorePlan s $m @('fa', 'fb') 'same') }; Q 'INSERT IGNORE INTO fb.sc VALUES (1, 1)'
  $null = Px $L3 mark -Env s -Name stmt 2>&1; Q "SET SESSION binlog_format = 'STATEMENT'; INSERT INTO fb.k VALUES (77, 'st')"
  $st1 = & { . $L3; $m = Find-Mark (Read-State s) 'stmt' 0; @((Get-RestorePlan s $m @('fa', 'fb') 'stmt').refused) -join ';' }
  Expect "statement-format DML in the range: refused by position (its rows are not in the binlog) ($st1)" ($st1 -match 'statement-format DML at binlog\.\d+:\d+')
  Q 'DELETE FROM fb.k WHERE a = 77'
  Q 'CREATE TABLE fb.fl (id int primary key, f float, d double); INSERT INTO fb.fl VALUES (1, 123456.789, 0.1), (2, 0.1, 1e-300)'
  $cf = (Q 'CHECKSUM TABLE fb.fl') -join ''; $null = Px $L3 mark -Env s -Name fl 2>&1; Q 'UPDATE fb.fl SET f = 1, d = 2; DELETE FROM fb.fl WHERE id = 2'
  $fl = & { . $L3; $m = Find-Mark (Read-State s) 'fl' 0; Invoke-RestoreDb s $m @('fb') (Get-RestorePlan s $m @('fb') 'fl') }
  Expect "FLOAT: undone as row events, the exact bytes back (the binlog text has 6 digits) ($fl)" (-not $fl -and ((Q 'CHECKSUM TABLE fb.fl') -join '') -eq $cf)
  Q 'CREATE VIEW fa.va AS SELECT id FROM fa.o; CREATE VIEW fa.vb AS SELECT id FROM fa.va'
  $vv = { "$((Q 'SHOW CREATE VIEW fa.va') -join '')|$((Q 'SHOW CREATE VIEW fa.vb') -join '')" }; $v0 = & $vv
  $null = & { . $L3; $n = New-Mark s 'release-9' 'release'; $null = Save-Slices s $n @{} }
  Q 'DROP VIEW fa.vb; DROP VIEW fa.va'
  $vr = & { . $L3; $m = Find-Mark (Read-State s) '' 9; Invoke-RestoreDb s $m @('fa', 'fb') (Get-RestorePlan s $m @('fa', 'fb') 'r9') }
  Expect "objects: a view on a view comes back whatever the order (a failed create goes again after the rest) ($vr)" (-not $vr -and (& $vv) -eq $v0)
  Q 'CREATE TABLE fa.th (id int primary key); CREATE TRIGGER fa.trh BEFORE INSERT ON fa.th FOR EACH ROW SET NEW.id = NEW.id'
  $fbpy = Join-Path $k3 'skills/envy/adapters/db_flashback.py'
  & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $fbpy)'); import db_flashback as f; a = type('A', (), {'host': '127.0.0.1', 'port': '$port', 'user': 'root', 'mysql': 'mysql'})(); f.triggers_off(f.Db(a), {'fa.th'})" 2>&1 | Out-Null
  $gone = "$(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME = 'trh'")"
  $null = Px $L3 mark -Env s -Name heal 2>&1; $null = & $py -X utf8 $fbpy apply --from (& { . $L3; (Find-Mark (Read-State s) 'heal' 0).pos }) --schemas fa --port $port --user root
  Expect "triggers a killed run left dropped: the next apply creates them again ($gone -> $(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME = 'trh'"))" ($gone -eq '0' -and "$(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME = 'trh'")" -eq '1')
  $ex = & { . $L3; Update-State s { param($x) $x.marks = @(@($x.marks) + @{ name = 'old'; kind = 'owner'; at = '2020-01-01T00:00:00'; pos = 'binlog.000000:4'; release = 0; repos = @{} }) }; $null = Update-Marks s; $st = Read-State s; "$(@($st.marks.name) -contains 'before-test')|$($st.expiredMarks)|$($st.binlog.days)" }
  Expect "marks older than the oldest binlog expire, shown expired; retention recorded ($ex)" ($ex -eq 'True|old|30')
  # the temp watchdog: a session holding temp (an InnoDB temp table) is listed by dbtemp and killed above db.tempMaxGB; doctor rows
  Expect "doctor: ibtmp1 without a max, max_execution_time 0, slow log off, the datadir outside storage.watch = WARN ($(($doc -split "`n" | Where-Object { $_ -match 'db temp' }) -join ' / '))" ($doc -match 'db temp: ibtmp1 has no max' -and $doc -match 'db temp: max_execution_time 0' -and $doc -match 'db temp: slow_query_log OFF' -and $doc -match 'db temp: storage.watch lacks the db datadir (/|[A-Za-z]:\\[^\\])')
  $tq = Join-Path $k3 'temp.sql'; "CREATE TEMPORARY TABLE fa.tt (id int primary key auto_increment, p varchar(1000)) ENGINE=InnoDB; INSERT INTO fa.tt (p) SELECT REPEAT('x', 1000) FROM information_schema.COLUMNS a, information_schema.COLUMNS b LIMIT 20000; SELECT SLEEP(120);" | Set-Content $tq
  $hold = Start-Process mysql -ArgumentList "-h 127.0.0.1 -P $port -u root" -RedirectStandardInput $tq -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 30 -and -not ("$(Q "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP%'")" -eq '1'); $i++) { Start-Sleep 1 }
  $ls = @(Px $L3 dbtemp -Env s 2>&1); $top = @($ls | Where-Object { $_ -match '^\d+ \d' })[0]
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb'); tempMaxGB = 0.005 } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $wk = & { . $L3; Invoke-DbTempWatch s }; Start-Sleep 1
  $left = "$(Q "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP%'")"
  Expect "dbtemp: '<id> <GB> <s> <query>', the temp session first; the watchdog kills it above db.tempMaxGB ($top -> $wk; left $left)" ($top -match '^\d+ 0\.0[1-9]\d* \d+ SELECT SLEEP\(120\)' -and $wk -match '^killed db connection \d+: 0\.0\d+ GB temp > db.tempMaxGB 0.005' -and $left -eq '0')
  $wk2 = & { . $L3; Invoke-DbTempWatch s }
  Expect "watchdog: nothing above the line = no kill ($wk2)" (-not $wk2)
  if (-not $hold.HasExited) { Stop-Process -Id $hold.Id -Force -ErrorAction SilentlyContinue }
  Q "SET GLOBAL max_execution_time = 600000; SET GLOBAL slow_query_log = ON"
  & $J @{ storage = @{ watch = @('', "$((Q 'SELECT @@datadir') -join '')".Replace('\\', '/').TrimEnd('/')) }; localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $dt = @(& { . $L3; Get-DbTempDoctor s } | ForEach-Object what)
  Expect "doctor: after the caps only ibtmp1 (a restart setting) is left ($($dt -join ' / '))" ($dt.Count -eq 1 -and $dt[0] -match 'ibtmp1 has no max')
  # tenant drop: registry row + FK children (a cycle too) + listed tables by id / name column, users no staying tenant has, the schema;
  # kept tenants and a lease refuse it; a dry run changes nothing; 0 references left; db.expect doctor rows
  Q @"
CREATE DATABASE adm; CREATE DATABASE t1; CREATE DATABASE t2; CREATE DATABASE t3keep; CREATE DATABASE orph;
CREATE TABLE adm.reg (id int primary key, name varchar(40), det_id int null);
CREATE TABLE adm.det (id int primary key, reg_id int, foreign key (reg_id) references adm.reg (id));
ALTER TABLE adm.reg ADD FOREIGN KEY (det_id) REFERENCES adm.det (id);
CREATE TABLE adm.det_prof (id int primary key, det_id int, foreign key (det_id) references adm.det (id));
CREATE TABLE adm.log (id int primary key auto_increment, tenant_name varchar(40)); CREATE TABLE adm.stat (id int primary key auto_increment, tenant_id int);
CREATE TABLE adm.users (id int primary key, login varchar(40)); CREATE TABLE adm.user_auth (user_id int, role varchar(10), foreign key (user_id) references adm.users (id));
INSERT INTO adm.reg (id, name) VALUES (1, 't1'), (2, 't2'), (3, 't3keep'); INSERT INTO adm.det VALUES (11, 1), (12, 2); UPDATE adm.reg SET det_id = 11 WHERE id = 1; UPDATE adm.reg SET det_id = 12 WHERE id = 2;
INSERT INTO adm.det_prof VALUES (21, 11), (22, 12); INSERT INTO adm.log (tenant_name) VALUES ('t1'), ('t2'); INSERT INTO adm.stat (tenant_id) VALUES (1), (2), (3);
INSERT INTO adm.users VALUES (1, 'alice'), (2, 'bob'), (3, 'carol'); INSERT INTO adm.user_auth VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE TABLE t1.u (login varchar(40)); INSERT INTO t1.u VALUES ('alice'), ('bob'); CREATE TABLE t2.u (login varchar(40)); INSERT INTO t2.u VALUES ('bob');
CREATE TABLE t3keep.u (login varchar(40)); INSERT INTO t3keep.u VALUES ('carol'); CREATE TABLE orph.x (a int);
"@
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb'); expect = @{ max_connections = '151'; sort_buffer_size = '1M' } }
          tenants = @{ schema = 'adm'; table = 'reg'; key = 'id'; name = 'name'; tables = @('log', 'stat', 'nosuch'); users = @{ table = 'users'; key = 'login'; tenantTable = 'u' }; keep = @('t3keep'); verify = 'echo {tenant}' } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $tl = Px $L3 tenant list -Env s 2>&1 | Out-String
  $kr = Px $L3 tenant drop -Env s -Name t3keep 2>&1 | Out-String; $krc = $LASTEXITCODE
  $dry = Px $L3 tenant drop -Env s -Name t1 -DryRun 2>&1 | Out-String; $cnt = { "$(Q 'SELECT (SELECT COUNT(*) FROM adm.reg) + (SELECT COUNT(*) FROM adm.det) + (SELECT COUNT(*) FROM adm.det_prof) + (SELECT COUNT(*) FROM adm.log) + (SELECT COUNT(*) FROM adm.stat) + (SELECT COUNT(*) FROM adm.users) + (SELECT COUNT(*) FROM adm.user_auth)')" }
  $c0 = & $cnt
  $sf3 = & { . (Join-Path $k3 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 's.json' }; $s0 = if (Test-Path $sf3) { Get-Content $sf3 -Raw }
  '{"leases":{"L9":{"services":["api"],"agent":"L9","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $sf3
  $lr = Px $L3 tenant drop -Env s -Name t1 2>&1 | Out-String; $lrc = $LASTEXITCODE; Remove-Item $sf3
  $d1 = Px $L3 tenant drop -Env s -Name t1 2>&1 | Out-String; $d1c = $LASTEXITCODE
  $after = "$(Q "SELECT GROUP_CONCAT(name ORDER BY id) FROM adm.reg")|$(Q 'SELECT GROUP_CONCAT(id ORDER BY id) FROM adm.det')|$(Q 'SELECT GROUP_CONCAT(id ORDER BY id) FROM adm.det_prof')|$(Q "SELECT GROUP_CONCAT(tenant_name) FROM adm.log")|$(Q 'SELECT GROUP_CONCAT(tenant_id ORDER BY tenant_id) FROM adm.stat')|$(Q 'SELECT GROUP_CONCAT(login ORDER BY id) FROM adm.users')|$(Q 'SELECT GROUP_CONCAT(user_id ORDER BY user_id) FROM adm.user_auth')|$(Q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 't1'")"
  $d2 = Px $L3 tenant drop -Env s -Name t2 2>&1 | Out-String; $users2 = "$(Q 'SELECT GROUP_CONCAT(login ORDER BY id) FROM adm.users')"
  $ex = @(& { . $L3; Get-DbExpectDoctor s } | ForEach-Object what)
  # refusals that keep data: a composite FK to a planned table, a staying tenant whose users cannot be read, a keepFrom file missing
  Q "CREATE TABLE adm.cp (id int primary key, n varchar(40), unique key (id, n)); CREATE TABLE adm.cc (a int, b varchar(40), foreign key (a, b) references adm.cp (id, n)); INSERT INTO adm.reg (id, name) VALUES (5, 'tc'); CREATE DATABASE tc; CREATE TABLE adm.cpref (id int primary key, reg_id int, foreign key (reg_id) references adm.reg (id)); INSERT INTO adm.cpref VALUES (1, 5)"
  Q "ALTER TABLE adm.cp ADD COLUMN reg_id int, ADD FOREIGN KEY (reg_id) REFERENCES adm.reg (id); INSERT INTO adm.cp VALUES (7, 'x', 5)"
  $cf = (Px $L3 tenant drop -Env s -Name tc 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $cfc = $LASTEXITCODE; $tcLeft = "$(Q "SELECT COUNT(*) FROM adm.reg WHERE name = 'tc'")"
  Q "DROP TABLE adm.cc; CREATE DATABASE tu; RENAME TABLE t3keep.u TO t3keep.u0; CREATE VIEW t3keep.u AS SELECT login FROM t3keep.u0; DROP TABLE t3keep.u0"
  $uf = (Px $L3 tenant drop -Env s -Name tc 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $ufc = $LASTEXITCODE
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') }; tenants = @{ schema = 'adm'; table = 'reg'; keepFrom = @('{kit}/no-such-file.txt') } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $kf = (Px $L3 tenant list -Env s 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $kfc = $LASTEXITCODE
  Expect "tenant drop refuses (data kept): a composite FK ($cfc, tc rows $tcLeft), unreadable users of a staying tenant ($ufc), a missing keepFrom file ($kfc)" ($cfc -eq 1 -and $cf -match 'composite key' -and $tcLeft -eq '1' -and $ufc -eq 1 -and $uf -match 'users of t3keep are unreadable' -and $kfc -eq 1 -and $kf -match 'tenants\.keepFrom .*does not exist')
  Expect "tenant list: keep / drop with sizes, a schema without a registry row shown ($(($tl -split "`n" | Where-Object { $_ -match 't1|t3keep|orph' }) -join ' / '))" ($tl -match 'DROP\s+t1\s' -and $tl -match 'KEEP\s+t3keep\s.*tenants\.keep' -and $tl -match 'DROP\s+orph\s.*schema without a registry row' -and $tl -notmatch '\sadm\s|\sfa\s.*registry')
  Expect "tenant drop: a kept tenant and a lease refuse it (exit $krc/$lrc); a dry run changes nothing ($c0)" ($krc -eq 1 -and $kr -match 'kept \(tenants\.keep\)' -and $lrc -eq 1 -and $lr -match 'in use \(L9\)' -and $dry -match 'tenant t1 : schema .* admin rows: reg 1.*det 1.*det_prof 1' -and $dry -match 'not in adm : nosuch' -and $c0 -eq '18')
  Expect "tenant drop: registry + FK children (cycle) + listed tables + only users no staying tenant has + schema; 0 left; kept tenants verified ($after)" ($d1c -eq 0 -and $after -eq 't2,t3keep|12|22|t2|2,3|bob,carol|2,3|0' -and $d1 -match '0 references left' -and $d1 -match 'kept tenant t3keep : verify ok')
  Expect "tenant drop: a user goes once no staying tenant has it ($users2)" ($users2 -eq 'carol' -and $d2 -match 'tenant t2 dropped')
  Expect "doctor: db.expect differs -> WARN with the server setting; equal -> nothing ($($ex -join ' / '))" ($ex.Count -eq 1 -and $ex[0] -match 'db sort_buffer_size = 262144, db\.expect 1M')
} finally {
  if ($srv -and -not $srv.HasExited) { & mysqladmin -h 127.0.0.1 -P $port -u root shutdown 2>&1 | Out-Null; $null = $srv.WaitForExit(30000); if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force } }
  Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
  Remove-TestKit $k3
}
Complete-Tests
