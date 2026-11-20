#Requires -Version 7
<#
tests/db-engine-presets-2.tests.ps1: on a scratch mysqld of its own: liquibase touched tables, review cases
(shared FK names, statement DML, FLOAT, views, killed-run triggers), the temp watchdog + doctor rows, tenant drop / import, db.bufferPool.
Usage: pwsh -NoProfile -File <kit>/tests/db-engine-presets-2.tests.ps1 (or tests/kit-tests.ps1 -Area db-engine-presets-2).
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
# ---- a scratch mysqld (own data dir and port, binlog ROW / FULL): never the env's server
$mysqld = Get-Command mysqld -ErrorAction SilentlyContinue
if (-not $mysqld -or -not (Get-Command mysqlbinlog -ErrorAction SilentlyContinue)) { 'SKIP flashback round trip (no mysqld / mysqlbinlog on PATH)'; Complete-Tests }
$k3 = New-PresetKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'
$tmSrv = Start-TestMySql -Binlog; $port = $tmSrv.port
try {
  $env:MYSQL_PWD = ''
  function Q([string]$sql) { Invoke-TestMySql $sql $port }
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
  # the state part 1 leaves for these checks: its first mark, the seed file of env s, the doctor run (installs the cascade guard)
  $mk = Px $L3 mark -Env s -Name 'Before Test' 2>&1 | Out-String
  $seedf = & { . $L3; SeedFile s }; New-Item -ItemType Directory -Force (Split-Path $seedf) | Out-Null
  & $J @{ items = @(@{ name = 'cc-5'; tables = @('fb.cc'); check = @{ sql = 'SELECT COUNT(*) FROM fb.cc WHERE id = 5' }; create = @{ cmd = "mysql -h 127.0.0.1 -P $port -u root -e `"INSERT INTO fb.cc VALUES (5, 1)`"" } }, @{ name = 'other'; tables = @('fa.x'); check = @{ sql = 'SELECT 0' } }) } $seedf 6
  $doc = Px $L3 doctor -Env s 2>&1 | Out-String
  # adapters/liquibase.ps1: update-sql (the pending changeSets) -> touched tables; tag / rollback run only on the schemas it manages
  $lbs = Join-Path $src 'skills/crafty/adapters/liquibase.ps1'
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
      $lt = & { . $L3; $pf = Join-Path (Kd) 'pending.sql'
        $set = [pscustomobject]@{ name = 'default'; tool = 'liquibase'; changelog = "$repo/db/changelog/master.xml"; searchPath = $null; schemas = @(LiquibaseSchemas s) }
        $u = Invoke-MigVerb liquibase pendingSql @{ e = 's'; set = $set; out = $pf }
        $t = @((Invoke-DbFb s 'touched' @('--files', $pf)).items); $g = Invoke-MigVerb liquibase tag @{ e = 's'; set = $set; tag = 'release-3' }
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
  Q 'CREATE OR REPLACE VIEW fa.va AS SELECT id FROM fa.o; CREATE OR REPLACE VIEW fa.vb AS SELECT id FROM fa.va'
  $vv = { "$((Q 'SHOW CREATE VIEW fa.va') -join '')|$((Q 'SHOW CREATE VIEW fa.vb') -join '')" }; $v0 = & $vv
  $null = & { . $L3; $n = New-Mark s 'release-9' 'release'; $null = Save-Slices s $n @{} }
  Q 'DROP VIEW fa.vb; DROP VIEW fa.va'
  $vr = & { . $L3; $m = Find-Mark (Read-State s) '' 9; Invoke-RestoreDb s $m @('fa', 'fb') (Get-RestorePlan s $m @('fa', 'fb') 'r9') }
  Expect "objects: a view on a view comes back whatever the order (a failed create goes again after the rest) ($vr)" (-not $vr -and (& $vv) -eq $v0)
  Q 'CREATE TABLE fa.th (id int primary key); CREATE TRIGGER fa.trh BEFORE INSERT ON fa.th FOR EACH ROW SET NEW.id = NEW.id'
  $flashPy = Join-Path $k3 'skills/envy/adapters/db_flashback.py'
  & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $flashPy)'); import db_flashback as f; a = type('A', (), {'host': '127.0.0.1', 'port': '$port', 'user': 'root', 'mysql': 'mysql'})(); f.triggers_off(f.Db(a), {'fa.th'})" 2>&1 | Out-Null
  $gone = "$(Q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_NAME = 'trh'")"
  $null = Px $L3 mark -Env s -Name heal 2>&1; $null = & $py -X utf8 $flashPy apply --from (& { . $L3; (Find-Mark (Read-State s) 'heal' 0).pos }) --schemas fa --port $port --user root
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
  Q "SET GLOBAL max_execution_time = 600000; SET GLOBAL log_output = 'NONE'"
  & $J @{ storage = @{ watch = @('', "$((Q 'SELECT @@datadir') -join '')".Replace('\\', '/').TrimEnd('/')) }; localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $dt = @(& { . $L3; Get-DbTempDoctor s } | ForEach-Object what)
  Q "SET GLOBAL log_output = DEFAULT"
  Expect "doctor: after the caps only ibtmp1 is left; K103: slow log off + log_output NONE = no row ($($dt -join ' / '))" ($dt.Count -eq 1 -and $dt[0] -match 'ibtmp1 has no max')
  # tenant drop: registry row + FK children (a cycle too) + listed tables by id / name column, users no staying tenant has, the schema;
  # kept tenants and a lease refuse it; a dry run changes nothing; 0 references left; db.expect doctor rows
  Q @"
CREATE DATABASE adm; CREATE DATABASE t1; CREATE DATABASE t2; CREATE DATABASE t3keep; CREATE DATABASE orph;
CREATE TABLE adm.reg (id int primary key, name varchar(40), det_id int null);
CREATE TABLE adm.det (id int primary key, reg_id int, foreign key (reg_id) references adm.reg (id));
ALTER TABLE adm.reg ADD FOREIGN KEY (det_id) REFERENCES adm.det (id);
CREATE TABLE adm.det_prof (id int primary key, det_id int, foreign key (det_id) references adm.det (id));
CREATE TABLE adm.log (id int primary key auto_increment, org_label varchar(40)); CREATE TABLE adm.stat (id int primary key auto_increment, org_ref int);
CREATE TABLE adm.users (id int primary key, login varchar(40)); CREATE TABLE adm.user_auth (user_id int, role varchar(10), foreign key (user_id) references adm.users (id));
INSERT INTO adm.reg (id, name) VALUES (1, 't1'), (2, 't2'), (3, 't3keep'); INSERT INTO adm.det VALUES (11, 1), (12, 2); UPDATE adm.reg SET det_id = 11 WHERE id = 1; UPDATE adm.reg SET det_id = 12 WHERE id = 2;
INSERT INTO adm.det_prof VALUES (21, 11), (22, 12); INSERT INTO adm.log (org_label) VALUES ('t1'), ('t2'); INSERT INTO adm.stat (org_ref) VALUES (1), (2), (3);
INSERT INTO adm.users VALUES (1, 'alice'), (2, 'bob'), (3, 'carol'); INSERT INTO adm.user_auth VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE TABLE t1.u (login varchar(40)); INSERT INTO t1.u VALUES ('alice'), ('bob'); CREATE TABLE t2.u (login varchar(40)); INSERT INTO t2.u VALUES ('bob');
CREATE TABLE t3keep.u (login varchar(40)); INSERT INTO t3keep.u VALUES ('carol'); CREATE TABLE orph.x (a int);
"@
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb'); expect = @{ max_connections = '151'; sort_buffer_size = '1M' } }
          tenants = @{ model = 'schema'; idColumns = @('org_ref'); nameColumns = @('org_label'); schema = 'adm'; table = 'reg'; key = 'id'; name = 'name'; tables = @('log', 'stat', 'nosuch'); users = @{ table = 'users'; key = 'login'; tenantTable = 'u' }; keep = @('t3keep'); verify = 'echo {tenant}' } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $tl = Px $L3 tenant list -Env s 2>&1 | Out-String
  $kr = Px $L3 tenant drop -Env s -Name t3keep 2>&1 | Out-String; $krc = $LASTEXITCODE
  $dry = Px $L3 tenant drop -Env s -Name t1 -DryRun 2>&1 | Out-String; $cnt = { "$(Q 'SELECT (SELECT COUNT(*) FROM adm.reg) + (SELECT COUNT(*) FROM adm.det) + (SELECT COUNT(*) FROM adm.det_prof) + (SELECT COUNT(*) FROM adm.log) + (SELECT COUNT(*) FROM adm.stat) + (SELECT COUNT(*) FROM adm.users) + (SELECT COUNT(*) FROM adm.user_auth)')" }
  $c0 = & $cnt
  $sf3 = & { . (Join-Path $k3 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 's.json' }; $s0 = if (Test-Path $sf3) { Get-Content $sf3 -Raw }
  '{"leases":{"L9":{"services":["api"],"agent":"L9","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $sf3
  $lr = Px $L3 tenant drop -Env s -Name t1 2>&1 | Out-String; $lrc = $LASTEXITCODE; Remove-Item $sf3
  $d1 = Px $L3 tenant drop -Env s -Name t1 2>&1 | Out-String; $d1c = $LASTEXITCODE
  $after = "$(Q "SELECT GROUP_CONCAT(name ORDER BY id) FROM adm.reg")|$(Q 'SELECT GROUP_CONCAT(id ORDER BY id) FROM adm.det')|$(Q 'SELECT GROUP_CONCAT(id ORDER BY id) FROM adm.det_prof')|$(Q "SELECT GROUP_CONCAT(org_label) FROM adm.log")|$(Q 'SELECT GROUP_CONCAT(org_ref ORDER BY org_ref) FROM adm.stat')|$(Q 'SELECT GROUP_CONCAT(login ORDER BY id) FROM adm.users')|$(Q 'SELECT GROUP_CONCAT(user_id ORDER BY user_id) FROM adm.user_auth')|$(Q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 't1'")"
  $d2 = Px $L3 tenant drop -Env s -Name t2 2>&1 | Out-String; $users2 = "$(Q 'SELECT GROUP_CONCAT(login ORDER BY id) FROM adm.users')"
  $ex = @(& { . $L3; Get-DbExpectDoctor s } | ForEach-Object what)
  # refusals that keep data: a composite FK to a planned table, a staying tenant whose users cannot be read, a keepFrom file missing
  Q "CREATE TABLE adm.cp (id int primary key, n varchar(40), unique key (id, n)); CREATE TABLE adm.cc (a int, b varchar(40), foreign key (a, b) references adm.cp (id, n)); INSERT INTO adm.reg (id, name) VALUES (5, 'tc'); CREATE DATABASE tc; CREATE TABLE adm.cpref (id int primary key, reg_id int, foreign key (reg_id) references adm.reg (id)); INSERT INTO adm.cpref VALUES (1, 5)"
  Q "ALTER TABLE adm.cp ADD COLUMN reg_id int, ADD FOREIGN KEY (reg_id) REFERENCES adm.reg (id); INSERT INTO adm.cp VALUES (7, 'x', 5)"
  $cf = (Px $L3 tenant drop -Env s -Name tc 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $cfc = $LASTEXITCODE; $tcLeft = "$(Q "SELECT COUNT(*) FROM adm.reg WHERE name = 'tc'")"
  Q "DROP TABLE adm.cc; CREATE DATABASE tu; RENAME TABLE t3keep.u TO t3keep.u0; CREATE VIEW t3keep.u AS SELECT login FROM t3keep.u0; DROP TABLE t3keep.u0"
  $uf = (Px $L3 tenant drop -Env s -Name tc 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $ufc = $LASTEXITCODE
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') }; tenants = @{ model = 'schema'; idColumns = @('org_ref'); nameColumns = @('org_label'); schema = 'adm'; table = 'reg'; key = 'id'; name = 'name'; keepFrom = @('{kit}/no-such-file.txt') } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $kf = (Px $L3 tenant list -Env s 2>&1 | Out-String) -replace '\s*\|?\s+', ' '; $kfc = $LASTEXITCODE
  Expect "tenant drop refuses (data kept): a composite FK ($cfc, tc rows $tcLeft), unreadable users of a staying tenant ($ufc), a missing keepFrom file ($kfc)" ($cfc -eq 1 -and $cf -match 'composite key' -and $tcLeft -eq '1' -and $ufc -eq 1 -and $uf -match 'users of t3keep are unreadable' -and $kfc -eq 1 -and $kf -match 'tenants\.keepFrom .*does not exist')
  Expect "tenant list: keep / drop with sizes, a schema without a registry row shown ($(($tl -split "`n" | Where-Object { $_ -match 't1|t3keep|orph' }) -join ' / '))" ($tl -match 'DROP\s+t1\s' -and $tl -match 'KEEP\s+t3keep\s.*tenants\.keep' -and $tl -match 'DROP\s+orph\s.*schema without a registry row' -and $tl -notmatch '\sadm\s|\sfa\s.*registry')
  Expect "tenant drop: a kept tenant and a lease refuse it (exit $krc/$lrc); a dry run changes nothing ($c0)" ($krc -eq 1 -and $kr -match 'kept \(tenants\.keep\)' -and $lrc -eq 1 -and $lr -match 'in use \(L9\)' -and $dry -match 'tenant t1 : schema .* admin rows: reg 1.*det 1.*det_prof 1' -and $dry -match 'not in adm : nosuch' -and $c0 -eq '18')
  Expect "tenant drop: registry + FK children (cycle) + listed tables + only users no staying tenant has + schema; 0 left; kept tenants verified ($after)" ($d1c -eq 0 -and $after -eq 't2,t3keep|12|22|t2|2,3|bob,carol|2,3|0' -and $d1 -match '0 references left' -and $d1 -match 'kept tenant t3keep : verify ok')
  Expect "tenant drop: a user goes once no staying tenant has it ($users2)" ($users2 -eq 'carol' -and $d2 -match 'tenant t2 dropped')
  Expect "doctor: db.expect differs -> WARN with the server setting; equal -> nothing ($($ex -join ' / '))" ($ex.Count -eq 1 -and $ex[0] -match 'db sort_buffer_size = 262144, db\.expect 1M')
  # tenant import: prod / writable sources refused, a dry run reads no data, then a masked copy loaded and registered from the
  # template (new ids, FK cycle and idColumns followed, name columns, set + {source:..}, skipTables), a taken name refused, the dump reused;
  # det / mig hold a unique tenant key (the real registries' uk_*_tenant_id): the new id goes in at insert, never after
  Q @"
CREATE DATABASE iadm; CREATE DATABASE srcadm; CREATE DATABASE srct; CREATE DATABASE tpl;
CREATE TABLE iadm.reg (id int primary key auto_increment, name varchar(40), pool_id int, det_id int null, marker varchar(40));
CREATE TABLE iadm.det (id int primary key auto_increment, org_ref int, prof int, label varchar(40), unique key (org_ref), foreign key (org_ref) references iadm.reg (id));
ALTER TABLE iadm.reg ADD FOREIGN KEY (det_id) REFERENCES iadm.det (id);
CREATE TABLE iadm.mig (id int primary key auto_increment, org_ref int, org_label varchar(40), cl varchar(40), unique key (org_ref));
CREATE TABLE iadm.log (id int primary key auto_increment, org_ref int, foreign key (org_ref) references iadm.reg (id));
INSERT INTO iadm.reg (id, name, pool_id) VALUES (5, 'tpl', 7); INSERT INTO iadm.det VALUES (9, 5, 3, 'tpl'); UPDATE iadm.reg SET det_id = 9; INSERT INTO iadm.mig VALUES (2, 5, 'tpl', 'c-old'); INSERT INTO iadm.log VALUES (1, 5);
CREATE TABLE srcadm.reg (id int primary key, name varchar(40)); CREATE TABLE srcadm.mig (id int primary key, org_ref int, org_label varchar(40), cl varchar(40));
INSERT INTO srcadm.reg VALUES (40, 'srct'); INSERT INTO srcadm.mig VALUES (1, 40, 'srct', 'c-src');
CREATE TABLE srct.customer (id int primary key auto_increment, name varchar(12), email varchar(80), notes text);
CREATE TABLE srct.app_user (id int primary key auto_increment, login varchar(50), password_hash varchar(60));
INSERT INTO srct.customer VALUES (1, 'Ann Real', 'Ann@Real.org', 'mail ann@real.org'), (2, 'Bo', NULL, NULL); INSERT INTO srct.app_user VALUES (1, 'admin', 'x'), (2, 'ann@real.org', 'y');
CREATE VIEW srct.v AS SELECT c.id, c.name FROM srct.customer c;
"@
  # routine / trigger / event bodies with a line that starts like dump data (INSERT INTO `) load as written, DEFINER dropped
  Q @"
DELIMITER //
CREATE PROCEDURE srct.p_add(IN n varchar(12))
BEGIN
INSERT INTO ``customer`` (name) VALUES (n);
END//
CREATE FUNCTION srct.f_one() RETURNS int DETERMINISTIC RETURN 1//
CREATE TRIGGER srct.tr_cu BEFORE INSERT ON srct.customer FOR EACH ROW SET NEW.notes = IFNULL(NEW.notes, 'via trigger')//
CREATE EVENT srct.ev_noop ON SCHEDULE EVERY 1 DAY DISABLE DO
INSERT INTO ``customer`` (name) VALUES ('ev')//
DELIMITER ;
"@
  $src1 = @{ host = '127.0.0.1'; port = $port; user = 'root'; requireReadOnly = $false; adminSchema = 'srcadm' }
  & $J @{ masking = @{ rules = @{ 'customer.name' = 'name' } }; localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; schemas = @('fa', 'fb') }
          tenants = @{ model = 'schema'; idColumns = @('org_ref'); nameColumns = @('org_label'); schema = 'iadm'; table = 'reg'; key = 'id'; name = 'name'; tables = @('mig'); keep = @('tpl'); verify = 'echo {tenant}'
            import = @{ template = 'tpl'; skipTables = @('log'); set = @{ 'mig.cl' = '{source:mig.cl}'; 'reg.marker' = 'x-{tenant}' }; profiles = @{ p = @{ passwordHash = 'H'; keepValues = @('admin') } }
              sources = @{ s1 = $src1; wr = @{ host = '127.0.0.1'; port = $port; user = 'root' }; mk = @{ host = '127.0.0.1'; port = $port; user = 'root'; prod = $true }; 'rm-prod' = $src1
                cr = @{ creds = "echo {`"host`":`"127.0.0.1`",`"port`":$port,`"user`":`"nouser`",`"password`":`"pw-secret-x`"}" } } } } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $icr = Px $L3 tenant import -Env s -From cr -Tenant srct -As crt -Mask p -DryRun 2>&1 | Out-String; $icrc = $LASTEXITCODE
  Expect "tenant import: a creds command's JSON is the login (it reached the server as nouser), its password never shown ($icrc | $($icr.Trim()))" ($icrc -eq 1 -and $icr -match "Access denied for user 'nouser'" -and $icr -notmatch 'pw-secret-x')
  $ip = foreach ($f0 in 'mk', 'rm-prod', 'wr') { $o = Px $L3 tenant import -Env s -From $f0 -Tenant srct -As newt -Mask p 2>&1 | Out-String; "$LASTEXITCODE $(if ($o -match 'production') { 'prod' } elseif ($o -match 'writable') { 'writable' } else { $o })" }
  $idry = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt -Mask p -DryRun 2>&1 | Out-String; $idryc = $LASTEXITCODE; $nodata = "$(Q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'newt'")"
  '{"leases":{"L9":{"services":["api"],"agent":"L9","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $sf3
  $ilr = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt -Mask p 2>&1 | Out-String; $ilrc = $LASTEXITCODE; Remove-Item $sf3
  Expect "tenant import refuses a prod source (prod: true, a prod name), a writable one, and while a lease is on; a dry run plans with no data read ($($ip -join ' / ') | $ilrc)" ("$ip" -eq '1 prod 1 prod 1 writable' -and $ilrc -eq 1 -and $ilr -match 'in use \(L9\)' -and $idryc -eq 0 -and $idry -match 'srct -> newt .* registry rows from tpl \(' -and $idry -match 'det 1' -and $idry -match 'mig 1' -and $idry -notmatch 'log \d' -and $nodata -eq '0')
  $im = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt -Mask p 2>&1 | Out-String; $imc = $LASTEXITCODE
  $nid = "$(Q "SELECT id FROM iadm.reg WHERE name = 'newt'")"
  $vw = "$(Q 'SELECT GROUP_CONCAT(name ORDER BY id) = (SELECT GROUP_CONCAT(name ORDER BY id) FROM newt.customer) FROM newt.v')|$(Q "SELECT GROUP_CONCAT(DISTINCT TABLE_SCHEMA) FROM information_schema.VIEW_TABLE_USAGE WHERE VIEW_SCHEMA = 'newt'")"
  $reg = "$(Q "SELECT CONCAT_WS(',', r.pool_id, r.marker, d.org_ref = r.id, d.prof, d.label, m.org_ref = r.id, m.org_label, m.cl) FROM iadm.reg r JOIN iadm.det d ON d.id = r.det_id JOIN iadm.mig m ON m.org_ref = r.id WHERE r.name = 'newt'")|$(Q "SELECT COUNT(*) FROM iadm.log")|$(Q "SELECT CONCAT_WS(',', r.det_id, m.cl) FROM iadm.reg r JOIN iadm.mig m ON m.org_ref = r.id WHERE r.name = 'tpl'")"
  $cdat = @(Q "SELECT CONCAT_WS(',', c.name, c.email, c.notes) FROM newt.customer c ORDER BY id"); $udat = @(Q 'SELECT CONCAT_WS(",", login, password_hash) FROM newt.app_user ORDER BY id')
  $ce = ($cdat[0] -split ',')[1]
  Expect "tenant import: masked copy loaded, registered from the template (cycle, idColumns, name columns, set, {source:..}; skipTables not cloned; template kept), a template-name value renamed, a view under -As reads the copy, verify ran, then seed -Check (its own fixtures miss: exit 1) ($imc | $vw | $reg | $($cdat -join ' ; ') | $($udat -join ' ; '))" ($imc -eq 1 -and $im -match 'tenant newt imported: 2 table\(s\)' -and $im -match 'tenant newt : verify ok' -and $im -match 'seed -Check: 1/2 ok' -and $im -match 'seed -Check not green' -and $vw -eq '1|newt' -and $reg -eq '7,x-newt,1,3,newt,1,newt,c-src|1|9,c-old' -and $ce -match '^u[0-9a-f]{12}@example\.com$' -and $cdat[0] -match "mail $([regex]::Escape($ce))$" -and $udat[1] -eq "$ce,H" -and $udat[0] -eq 'admin,H' -and "$cdat$udat" -notmatch '(?i)real\.org|Ann Real')
  $again = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt -Mask p 2>&1 | Out-String; $againc = $LASTEXITCODE
  $im2 = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt2 -Mask p 2>&1 | Out-String
  $same = "$(Q 'SELECT GROUP_CONCAT(email ORDER BY id) FROM newt.customer')" -eq "$(Q 'SELECT GROUP_CONCAT(email ORDER BY id) FROM newt2.customer')"
  Expect "tenant import: a taken name is refused ($againc); a second import reuses the masked dump, same masks ($same)" ($againc -eq 1 -and $again -match 'newt exists here' -and $im2 -match 'masked dump reused' -and $im2 -match 'tenant newt2 imported' -and $same)
  # the saved copy outlives a masker (kit) change; a changed profile config warns and reuses it; -Refresh reads the source again, one copy kept
  Add-Content (Join-Path $k3 'skills/envy/adapters/db_flashback.py') '# a kit update'
  $imp = { param($as) Px $L3 tenant import -Env s -From s1 -Tenant srct -As $as -Mask p @args 2>&1 | Out-String }
  $cdir = if ($im2 -match 'reused: (.+?\.sql) ') { Split-Path $Matches[1] }; Remove-Item (Join-Path $cdir '*.meta.json')   # a copy saved before meta files: reused, its first load writes one
  $ikit = & $imp newt5; $ikit += "meta $(@(Get-ChildItem $cdir -Filter '*.meta.json').Count)"
  $kjp = Join-Path $k3 'skills/crafty/kit.local.json'; $kcp = Get-Content $kjp -Raw | ConvertFrom-Json; $kcp.localEnv.envs.s.tenants.import.profiles.p | Add-Member keepDomains @('example.org'); $kcp | ConvertTo-Json -Depth 20 | Set-Content $kjp
  $iwarn = & $imp newt6; $irefr = & $imp newt7 -Refresh
  $nsave = @(Get-ChildItem $cdir -Filter 's1-srct-p-*.sql').Count
  Expect "tenant import: a masker change reuses the copy (no meta: its load writes it), a profile change warns and reuses it, -Refresh re-reads ($nsave | $ikit | $iwarn | $irefr)" ($ikit -match 'dump reused[^\n]+\n(.|\n)+newt5 imported(.|\n)+meta 1$' -and $iwarn -match 'another config of profile p(.|\n)+dump reused(.|\n)+newt6 imported' -and $irefr -notmatch 'reused' -and $irefr -match 'masked dump: \d+ table(.|\n)+newt7 imported' -and $nsave -eq 1)
  $objs = "$(Q "SELECT CONCAT_WS(',', (SELECT GROUP_CONCAT(ROUTINE_NAME ORDER BY ROUTINE_NAME) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'newt'), (SELECT GROUP_CONCAT(TRIGGER_NAME) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'newt'), (SELECT GROUP_CONCAT(EVENT_NAME) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'newt' AND EVENT_DEFINITION LIKE '%''ev''%'))")"
  $call = "$(Q "CALL newt.p_add('Zed'); SELECT CONCAT_WS(',', notes, newt.f_one()) FROM newt.customer WHERE name = 'Zed'")"
  Expect "tenant import: routines, triggers and events come with the schema; a body line starting INSERT INTO `` loads as code, its literals unmasked ($objs | $call)" ($objs -eq 'f_one,p_add,tr_cu,ev_noop' -and $call -eq 'via trigger,1')
  # a registration that fails (a set column the table lacks) rolls the registry back and drops the new schema
  $kj = Join-Path $k3 'skills/crafty/kit.local.json'; $kc = Get-Content $kj -Raw | ConvertFrom-Json; $kc.localEnv.envs.s.tenants.import.set | Add-Member 'reg.nosuch' 'x'; $kc | ConvertTo-Json -Depth 20 | Set-Content $kj
  $ifl = Px $L3 tenant import -Env s -From s1 -Tenant srct -As newt3 -Mask p 2>&1 | Out-String; $iflc = $LASTEXITCODE
  $gone3 = "$(Q "SELECT (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'newt3') + (SELECT COUNT(*) FROM iadm.reg WHERE name = 'newt3') + (SELECT COUNT(*) FROM iadm.mig WHERE org_label = 'newt3')")"
  Expect "tenant import: a failed registration leaves no schema and no registry row ($iflc | $gone3)" ($iflc -eq 1 -and $ifl -match 'failed, its schema dropped again, its registry rows rolled back' -and $gone3 -eq '0')
  # a registration that fails after commit, its new id held by another tenant's row (an id clash): only the rows it inserted go
  Q "ALTER TABLE iadm.reg AUTO_INCREMENT = 90; INSERT INTO iadm.mig (org_ref, org_label, cl) VALUES (90, 'other', 'keep-me')"
  $kc.localEnv.envs.s.tenants.import | Add-Member register "mysql -h 127.0.0.1 -P $port -u root -e `"INSERT INTO iadm.reg (name) VALUES ('newt4')`" && exit 1"; $kc | ConvertTo-Json -Depth 20 | Set-Content $kj
  $icl = & $imp newt4; $kept4 = "$(Q "SELECT CONCAT_WS(',', (SELECT COUNT(*) FROM iadm.reg WHERE name = 'newt4'), (SELECT COUNT(*) FROM iadm.mig WHERE cl = 'keep-me'))")"
  Expect "tenant import: a failed import with an id clash deletes its own registry row, the other tenant's row stays ($kept4 | $icl)" ($icl -match 'dropped again, its registry rows deleted' -and $kept4 -eq '0,1')
  # the template's plan reaching another tenant's row (a row of tpl's id pointing at newt's det): refused, nothing copied
  Q "CREATE TABLE iadm.lnk (id int primary key auto_increment, org_ref int, det_ref int, foreign key (det_ref) references iadm.det (id)); INSERT INTO iadm.lnk (org_ref, det_ref) SELECT 5, det_id FROM iadm.reg WHERE name = 'newt'"
  $kc.localEnv.envs.s.tenants.import.PSObject.Properties.Remove('register'); $kc.localEnv.envs.s.tenants.tables = @('mig', 'lnk'); $kc | ConvertTo-Json -Depth 20 | Set-Content $kj
  $icg = & $imp newt8 -DryRun
  Expect "tenant import: a template plan reaching another tenant's row is refused ($icg)" ($icg -match 'plan reaches rows of other tenants \(lnk 1')
  # db.bufferPool: a live lease grows the pool (chunk-aligned), idle shrinks it back; db.expect leaves the pool to it; the doctor row
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; port = $port; user = 'root'; bufferPool = @{ busyMB = 200; idleMB = 128 }; expect = @{ innodb_buffer_pool_size = '1G' } } } } } } (Join-Path $k3 'skills/crafty/kit.local.json') 8
  $poolMB = { param($w) for ($i = 0; $i -lt 40 -and -not ([double](Q 'SELECT @@innodb_buffer_pool_size / 1048576') -eq $w -and "$(Q "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_resize_status'")" -notmatch 'Resiz'); $i++) { Start-Sleep -Milliseconds 250 }; [double](Q 'SELECT @@innodb_buffer_pool_size / 1048576') }
  '{"leases":{"L9":{"services":["api"],"agent":"L9","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $sf3
  $pg = & { . $L3; Invoke-DbPool s }; $pb = & $poolMB 256; Remove-Item $sf3
  $pi = @(& { . $L3; Invoke-DbPool s; Invoke-DbPool s -Now; @(Get-DbExpectDoctor s).Count; (Get-DbPoolDoctor s).what }); $ps = & $poolMB 128
  Expect "db.bufferPool: a lease grows the pool to busyMB (chunk-aligned), idle shrinks it to idleMB only past the grace (-Now: loop exit); db.expect skips the pool; doctor row ($pg | $($pi -join ' | '))" ($pg -match '128 -> 256 MB \(a lease' -and $pb -eq 256 -and $pi[0] -match '256 -> 128 MB \(idle\)' -and $pi[1] -eq 0 -and $pi[2] -match 'innodb_buffer_pool_size 128 MB \(db\.bufferPool busy 200 / idle 128 MB\); server RAM \d+ MB' -and $ps -eq 128)
} finally {
  Stop-TestMySql $tmSrv
  Remove-TestKit $k3
}
# K78 (tests/test-mysql.ps1): one area holds the one server at a time; a second kit-test mysqld is a stray (TEST-MYSQLD)
$tmLk = New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'lock78')   # its own lock dir: the shared one may be held by another run
$tmHeld = Enter-TestMySqlLock $tmLk 0; $tmSecond = try { (Enter-TestMySqlLock $tmLk 0).Dispose(); 'got it' } catch { 'refused' } finally { $tmHeld.Dispose() }
$tmFake = { param($i, $p, $c) [pscustomobject]@{ ProcessId = $i; ParentProcessId = $p; CommandLine = $c } }
$tmStrays = @(Get-TestMySqlStrays @((& $tmFake 10 1 '"mysqld.exe" --no-defaults "--datadir=D:\k\.state\kit-tests\mysql" --port=1'), (& $tmFake 11 10 'mysqld.exe --no-defaults --datadir=D:\k\.state\kit-tests\mysql'),
  (& $tmFake 20 2 "mysqld.exe --no-defaults `"--datadir=D:\w\$($tmpMap.runtimeDir)\work\tests\mysqld-77`" --port=2"), (& $tmFake 30 3 'mysqld.exe --defaults-file=C:\ProgramData\my.ini')) -Server '10:5')
Expect "test-mysql.ps1: one area holds the server at a time (a second take waits: $tmSecond); a second kit-test mysqld (old per-area dir) is a stray, the one server, its worker and the OS service are not ($($tmStrays -join '; '))" ($tmSecond -eq 'refused' -and $tmStrays.Count -eq 1 -and $tmStrays[0] -match '^20 .*mysqld-77$')
Complete-Tests
