#Requires -Version 7
<#
tests/db-generic.tests.ps1: the db adapters on layouts other than ours, offline (mocked SQL, shims): migration sets (two masters,
admin + tenant scopes: registry first on tag, last on rollback; search path = the resources root), several masters without sets
refused, a flyway-style dir set (files under its dir count as migrations), tenant models none / column / one-DB, postgres never
calls the mysql client, envy verbs a local adapter registers.
Usage: pwsh -NoProfile -File tests/db-generic.tests.ps1 [-Kit <kit>] (or tests/kit-tests.ps1 -Area db-generic).
Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$root = Split-Path $PSScriptRoot
$k = New-TestKit dbgen; $ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy/adapters')
Copy-Item (Join-Path $root 'skills/envy/envy.ps1') (Split-Path $ad)
Copy-Item (Join-Path $root 'skills/envy/adapters/*') $ad -Force
New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters') | Out-Null; Copy-Item (Join-Path $root 'skills/crafty/adapters/liquibase.ps1') (Join-Path $k 'skills/crafty/adapters')
$L = Join-Path $k 'skills/envy/envy.ps1'; $cfg = Join-Path $k 'skills/crafty/kit.local.json'
# a mysql client shim on PATH: any call leaves a file (postgres / no-engine envs must never reach it)
$bin = Join-Path (Kd) 'bin'; New-Item -ItemType Directory -Force $bin | Out-Null; $hit = Join-Path (Kd) 'mysql.called'
if ($IsWindows) { Set-Content (Join-Path $bin 'mysql.cmd') "@echo called> `"$hit`"`r`n@exit /b 1"; Set-Content (Join-Path $bin 'liquibase.cmd') '@echo liquibase' }
else { Set-Content (Join-Path $bin 'mysql') "#!/bin/sh`necho called > '$hit'; exit 1"; Set-Content (Join-Path $bin 'liquibase') "#!/bin/sh`necho liquibase"; chmod +x (Join-Path $bin 'mysql') (Join-Path $bin 'liquibase') }
$flat = { param($s) "$s" -replace '\r?\n\s*\|\s*', ' ' -replace '\s+', ' ' }   # the error view wraps long lines behind "|"
$oldPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"
try {
  # a service folder with two Liquibase masters (admin + tenant), classpath-relative includes under src/main/resources
  $svc = Join-Path (Kd) 'svc'; $lb = Join-Path $svc 'src/main/resources/config/liquibase'; New-Item -ItemType Directory -Force $lb | Out-Null
  '<databaseChangeLog/>' | Set-Content (Join-Path $lb 'admin-master.xml'); '<databaseChangeLog/>' | Set-Content (Join-Path $lb 'master.xml')
  git -C $svc init -q 2>&1 | Out-Null; git -C $svc add -A 2>&1 | Out-Null
  $mock = { param($svcDir) function EnvServices { @([pscustomobject]@{ name = 'api'; repo = 'app' }) }; function RepoOf { 'app' }; function SvcDir { $svcDir }
    function Invoke-DbSql { param($e, $sql) if ($sql -match 'FROM reg') { , @('t1'); , @('t2') } } }
  $sets = @(@{ name = 'admin'; changelog = 'src/main/resources/config/liquibase/admin-master.xml'; schemas = @('adm') }, @{ name = 'tenant'; changelog = 'src/main/resources/config/liquibase/master.xml'; schemasQuery = 'SELECT name FROM reg' })
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; user = 'u'; schemas = @('adm'); jdbc = 'jdbc:x/{schema}'; migrations = @{ tool = 'liquibase'; sets = $sets } }; tenants = @{ model = 'schema'; schema = 'adm' } } } } } $cfg 8
  $r = & { . $L; . $mock $svc
    $global:lbCalls = @(); function Invoke-EnvLiquibase { param($e, $set, $schemas, $verb) $global:lbCalls += "$($set.name):$($schemas -join ',')"; $null }
    $tag = Invoke-MigTagRollback s 'tag' 'release-3'; $t = $global:lbCalls -join ' '; $global:lbCalls = @()
    $rb = Invoke-MigTagRollback s 'rollback' 'release-3'; "$tag$rb|$t|$($global:lbCalls -join ' ')" }
  Expect "migration sets: admin + tenant masters; tag registry set and scope first, rollback them last ($r)" ($r -eq '|admin:adm tenant:t1,t2|tenant:t2,t1 admin:adm')
  $c = & { . $L; Get-LiquibaseCmd (Join-Path $lb 'master.xml') $null 'jdbc:x' 'u' 'tag' }
  Expect "liquibase: --search-path = the resources root, the changelog relative to it ($c)" ($c -match '--search-path="[^"]*[\\/]src[\\/]main[\\/]resources"' -and $c -match '--changelog-file="config/liquibase/master\.xml"')
  # no sets: two masters are ambiguous -> tag / rollback / touched refuse
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; user = 'u'; schemas = @('adm'); migrations = @{ tool = 'liquibase' } } } } } } $cfg 8
  $a = & { . $L; . $mock $svc; function EnvRepos { @{ app = @{ wt = $svc } } }; $x = Invoke-MigTagRollback s 'tag' 'release-3'; $y = try { Get-MigTouched s 'app' 'a' 'b'; 'no throw' } catch { "$_" }; "$x|$y" }
  Expect "several masters and no db.migrations.sets: tag and touched refuse loudly ($a)" ($a -match '^several migration masters \(admin-master\.xml, master\.xml\) and no db\.migrations\.sets: refused' -and $a -match '\|several migration masters .* the touched tables are unknown$')
  # a flyway-style dir set (no kit adapter): a changed file under its dir counts, though no generic pattern names it
  $repo = Join-Path (Kd) 'fw'; New-Item -ItemType Directory -Force "$repo/db/sql" | Out-Null; git -C $repo init -q 2>&1 | Out-Null
  'x' | Set-Content "$repo/readme.txt"; git -C $repo add -A 2>&1 | Out-Null; git -C $repo -c user.name=t -c user.email=t@t commit -q -m a 2>&1 | Out-Null
  'ALTER TABLE orders ADD COLUMN note int;' | Set-Content "$repo/db/sql/V2__note.sql"; git -C $repo add -A 2>&1 | Out-Null; git -C $repo -c user.name=t -c user.email=t@t commit -q -m b 2>&1 | Out-Null
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; user = 'u'; schemas = @('app'); migrations = @{ tool = 'flyway'; sets = @(@{ name = 'main'; dir = 'db/sql'; schemas = @('app') }) } } } } } } $cfg 8
  $f = & { . $L; . $mock $repo; function EnvRepos { @{ app = @{ wt = $repo } } }; $m = Get-MigTouched s 'app' 'HEAD~1' 'HEAD'; "$($m.via)|$(@($m.items | ForEach-Object { "$($_.table):$($_.kind)" }) -join ',')" }
  Expect "flyway-style dir set: a file under its dir is a migration (touched tables from it) ($f)" ($f -match '^1 migration file\(s\)\|.*orders:')
  # tenant models: none refuses tenant verbs, column lists the distinct values, one-DB = db.name scope
  & $J @{ localEnv = @{ envs = @{ s = @{ services = @(); db = @{ engine = 'mysql'; user = 'u'; name = 'shop' } }; c = @{ services = @(); db = @{ engine = 'mysql'; user = 'u'; name = 'shop' }; tenants = @{ model = 'column'; column = @{ table = 'orders'; column = 'org' }; keep = @('a') } } } } } $cfg 8
  $n = & $flat (Px $L tenant list -Env s 2>&1 | Out-String); $nc = $LASTEXITCODE
  Expect "tenants.model unset = none: tenant list refuses, names the models ($nc)" ($nc -ne 0 -and $n -match 'tenant-model none: verb list not implemented \(set envs\.s\.tenants\.model: column \| database \| instance \| schema\)')
  $cl = & { . $L; function Invoke-DbSql { param($e, $sql) if ($sql -eq 'SELECT DISTINCT org FROM orders') { , @('a'); , @('b'); , @('NULL') } }; @(Invoke-TenantModel c 'list' | ForEach-Object { "$($_.name)$(if ($_.keep) { '*' })" }) -join ',' }
  $sc = & { . $L; @(Get-DataScopes s) -join ',' }
  Expect "column model lists the column's values (keep marked); one-DB scopes = db.name ($cl | $sc)" ($cl -eq 'a*,b' -and $sc -eq 'shop')
  $il = & { . $L; function Get-EnvCfg { @{ tenants = @{ model = 'instance'; instances = @(@{ name = 'eu' }, @{ name = 'us' }); keep = @('us') } } }; @(Invoke-TenantModel c 'list' | ForEach-Object { "$($_.name)$(if ($_.keep) { '*' })" }) -join ',' }
  Expect "instance model lists tenants.instances names, keep marked ($il)" ($il -eq 'eu,us*')
  # schema / database models' scopes (parity next): no db.schemas / schemasQuery -> db.name + the registry schema + existing tenant schemas;
  # configured scopes win unchanged; no registry = db.name only, with a warning
  $ssc = & { . $L; $global:sdb = @{ name = 'app' }; function Get-EnvCfg { @{ tenants = @{ model = 'schema' }; db = $global:sdb } }; function Get-TenantRows { [pscustomobject]@{ name = 't1' }; [pscustomobject]@{ name = 'gone' } }
    function Invoke-DbSql { param($e, $sql) if ($sql -match 'SCHEMATA') { , @('adm'); , @('t1'); , @('app') } }; function TenantCfg { @{ schema = 'adm' } }; $x = @(Get-DataScopes x) -join ','
    $global:sdb = @{ name = 'app'; schemas = @('base') }; $y = @(Get-DataScopes x) -join ','; $global:sdb = @{ name = 'app' }; function TenantCfg { throw 'no registry' }
    "$x|$y|$(@(Get-DataScopes x 3>$null) -join ',')|$($KitAdapters['tenant-model']['database'].scopes -is [scriptblock])" }
  Expect "schema model scopes: unconfigured env = db.name + registry + existing tenant schemas (a stale row left out); db.schemas wins; no registry = db.name; database model the same ($ssc)" ($ssc -eq 'app,adm,t1|base|app|True')
  # sql verb (parity): each engine's own client, the statement on stdin (mongodb: --eval), rows split on tabs; redis refuses; the
  # mysql client never runs (also not for a schema tenant model on postgres)
  & $J @{ localEnv = @{ envs = @{ pg = @{ services = @(); db = @{ engine = 'postgresql'; user = 'u'; name = 'app' }; tenants = @{ model = 'schema'; schema = 'adm'; table = 'reg'; key = 'id'; name = 'name' } }; lite = @{ services = @(); db = @{ engine = 'sqlite'; name = 'app.db' } }
    ms = @{ services = @(); db = @{ engine = 'mssql'; user = 'sa'; name = 'app' } }; ora = @{ services = @(); db = @{ engine = 'oracle'; user = 'u'; name = 'XE' } }; mg = @{ services = @(); db = @{ engine = 'mongo'; name = 'app'; uri = 'mongodb://u:s3cret@127.0.0.1:27017/app' } }; rd = @{ services = @(); db = @{ engine = 'redis' } } } } } $cfg 8
  $p = & { . $L; $global:dbx = [Collections.Generic.List[string]]::new(); function Invoke-KitExe { param($Exe, $A, $TimeoutSec, $Raw, $Cwd, $In) $global:dbx.Add("$Exe|$($A -join ' ')|$In|$env:KIT_DB_URI"); [pscustomobject]@{ code = 0; out = "a `tb`n`nc`td"; err = '' } }
    $o = foreach ($en in 'pg', 'lite', 'ms', 'ora', 'mg') { $rows = @(Invoke-DbSql $en 'SELECT 1;'); "$en=$($rows.Count):$($rows[1][1])" }
    $rr = try { Invoke-DbSql rd 'GET x'; 'ran' } catch { "$_" }; "$($o -join ',')|$rr" }
  $dx = $global:dbx; $pt = Px $L tenant list -Env pg 2>&1 | Out-String
  Expect "sql verb: postgres psql, sqlite3, sqlcmd, sqlplus, mongosh; 2 rows each; redis refuses; tenant (schema model) on postgres refuses; mysql never called ($p)" ($p -eq 'pg=2:d,lite=2:d,ms=2:d,ora=2:d,mg=2:d|engine redis: verb sql not implemented' -and
    $dx[0] -match "^psql\|-h 127\.0\.0\.1 -p 5432 -U u -d app .*-F `t .*ON_ERROR_STOP=1\|SELECT 1;" -and $dx[1] -match "^sqlite3\|-batch -bail -noheader -separator `t app\.db\|SELECT 1;" -and $dx[2] -match "^sqlcmd\|-S 127\.0\.0\.1,1433 -U sa -d app -h -1 -W -s `t -b -I\|SET NOCOUNT ON;" -and
    $dx[3] -match "^sqlplus\|-s -l /nolog\|WHENEVER SQLERROR EXIT 1\s+CONNECT u/`"`"@//127\.0\.0\.1:1521/XE" -and $dx[4] -eq "mongosh|--nodb --quiet --eval db = connect(process.env.KIT_DB_URI || 'mongodb://127.0.0.1:27017/app'); SELECT 1;||mongodb://u:s3cret@127.0.0.1:27017/app" -and $pt -match 'tenant needs db\.engine mysql / mariadb' -and -not (Test-Path $hit))
  # envy verbs: a local adapter registers one (ops checked); an unknown verb is refused with the list
  "Register-KitAdapter envy-verb hello @{ ops = @('wave'); run = { `"hello `$Op from `$e`" } }" | Set-Content (Join-Path $ad 'zz_hello.local.ps1')
  $h = Px $L hello wave -Env pg 2>&1 | Out-String; $hc = $LASTEXITCODE
  $hb = & $flat (Px $L hello jump -Env pg 2>&1 | Out-String); $u = & $flat (Px $L nosuchverb 2>&1 | Out-String); $uc = $LASTEXITCODE
  # schemaSizes: each engine's own query (supervise data growth); sqlserver / sqlite / oracle / mongodb (parity): sizes through the
  # engine's own sql verb and catalogue -> scope TAB rows TAB MB; never the mysql client
  $ssq = & { . $L; "$($KitAdapters['db-engine'].mysql.schemaSizes -match 'information_schema\.tables')|$($KitAdapters['db-engine'].postgres.schemaSizes -match 'pg_total_relation_size')" }
  $ssz = & { . $L; $global:szx = [Collections.Generic.List[string]]::new(); function Invoke-KitExe { param($Exe, $A, $TimeoutSec, $Raw, $Cwd, $In) $global:szx.Add("$Exe|$($A -join ' ')|$In"); [pscustomobject]@{ code = 0; out = "app`t30`t2`n"; err = '' } }
    @(foreach ($en in 'ms', 'lite', 'ora', 'mg') { "$en=$(@(& (Get-DbEngine $en).sizes @{ e = $en }) -join ',')" }) -join ' ' }
  $szx = $global:szx -join "`n"
  # jdbc / exec presets (parity) fill what an env leaves unset
  $jp = & { . $L; "$((Get-EnvCfg ms).db.jdbc)|$((Get-EnvCfg lite).db.jdbc)|$((Get-EnvCfg ora).db.jdbc)|$((Get-EnvCfg rd).db.exec)|$($script:DbPresets.elasticsearch.jdbc)|$($script:DbPresets.opensearch.jdbc)|$($script:DbPresets.opensearch.exec)" }
  Expect "jdbc / exec presets: sqlserver, sqlite, oracle jdbc; redis exec from a file; search jdbc + _bulk exec ($jp)" ($jp -eq 'jdbc:sqlserver://127.0.0.1:1433;databaseName=app;encrypt=false|jdbc:sqlite:app.db|jdbc:oracle:thin:@//127.0.0.1:1521/XE|redis-cli -h 127.0.0.1 -p 6379 < "{file}"|jdbc:es://http://{H}:{P}|jdbc:opensearch://http://{H}:{P}|curl -s -H "Content-Type: application/x-ndjson" -X POST http://{H}:{P}/_bulk --data-binary "@{file}"')
  # the migration adapter loads only when config names its tool (here: none)
  $lbOff = & { . $L; [bool](Get-Command Get-LiquibaseCmd -ErrorAction SilentlyContinue) }
  Expect "schemaSizes: mysql information_schema, postgres pg_total_relation_size; liquibase.ps1 not loaded without migrations.tool ($ssq | $lbOff)" ($ssq -eq 'True|True' -and -not (Test-Path $hit) -and -not $lbOff)
  Expect "sizes: sqlserver dm_db_partition_stats, sqlite dbstat, oracle user_segments, mongodb listDatabases, each through its own client ($ssz)" ($ssz -eq "ms=app`t30`t2 lite=app`t30`t2 ora=app`t30`t2 mg=app`t30`t2" -and
    $szx -match '(?m)^sqlcmd\|[^|]*\|SET NOCOUNT ON;\s+SELECT s\.name.*sys\.dm_db_partition_stats' -and $szx -match '(?m)^sqlite3\|.*FROM dbstat d' -and $szx -match '(?m)^sqlplus\|[\s\S]*user_segments' -and $szx -match '(?m)^mongosh\|.*listDatabases' -and -not (Test-Path $hit))
  Expect "envy verbs: a registered verb runs, its ops checked; an unknown verb refused ($hc | $($h.Trim()))" ($hc -eq 0 -and $h -match 'hello wave from pg' -and $hb -match 'hello jump : unknown \(wave\)' -and $uc -ne 0 -and $u -match "unknown verb 'nosuchverb'.*hello")
  # parity db-engine: sqlite snapshot marks for real (VACUUM INTO, .restore), a later mark dropped; refused over data.maxMB
  $lite = Join-Path (Kd) 'marks.db'; $sq = Get-Command sqlite3 -ErrorAction SilentlyContinue
  if ($sq) {
    & $J @{ localEnv = @{ envs = @{ lt = @{ services = @(); db = @{ engine = 'sqlite'; name = $lite } } } } } $cfg 8
    & $sq.Source $lite 'CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1);'
    $smR = & { . $L; $m1 = New-Mark lt 'm1' 'owner'; $null = Invoke-DbSql lt 'INSERT INTO t VALUES (2)'; $m2 = New-Mark lt 'm2' 'owner'; $null = Invoke-DbSql lt 'DELETE FROM t'
      $st = Read-State lt; $m = Find-Mark $st 'm1' 0; $p = Get-RestorePlan lt $m @('main') 'x'; $txt = (RestorePlanText $p) -join ' '
      $err = Invoke-RestoreDb lt $m @('main') $p; $rows = @(Invoke-DbSql lt 'SELECT a FROM t' | ForEach-Object { $_[0] }) -join ','
      "$m1,$m2|$txt|$err|$rows|$(@((Read-State lt).marks.name) -join ',')|$(@(Invoke-DbEngine lt 'binlogs').Count)" }
    Expect "sqlite marks: snapshot per mark, restore -> the rows at m1, later m2 and its file dropped ($smR)" ($smR -match '^m1,m2\|snapshot: main back whole to mark m1 \(kitsnap\d+:0\)\|\|1\|m1\|1$')
  }
  # temp per connection (dbtemp, watchdog) through each engine's tempSql + kill; sqlserver / elasticsearch snapshots, oracle SCN flashback,
  # the query fallback (no db.query: the engine's sql verb), mongodb exec / jdbc presets (mocked SQL / REST)
  & $J @{ localEnv = @{ envs = @{ pg = @{ services = @(); db = @{ engine = 'postgres'; name = 'app'; user = 'u' } }; ms = @{ services = @(); db = @{ engine = 'sqlserver'; name = 'app' } }
        ora = @{ services = @(); db = @{ engine = 'oracle'; name = 'xe'; user = 'u' } }; es = @{ services = @(); db = @{ engine = 'elasticsearch'; schemas = @('orders') } }; mg = @{ services = @(); db = @{ engine = 'mongodb'; name = 'app' } } } } } $cfg 8
  $tpR = & { . $L; $global:dbSqls = @(); function Invoke-DbCliRows { param($e, $Exe, $Argv, $In) $global:dbSqls += "$e|$(@($Argv) -join ' ')|$In"
      if ("$In" -match 'pg_ls_tmpdir|dm_db_session_space_usage|tempseg_usage') { , @('7', '2.5', '30', 'select big') } elseif ("$In" -match 'sys\.database_files') { , @('app_data', 'C:\d\app.mdf') }
      elseif ("$In" -match 'source_database_id') { , @('app_kitsnap1'); , @('app_kitsnap2') } elseif ("$In" -match 'TIMESTAMP_TO_SCN') { , @('4242') } elseif ("$In" -match 'FROM user_tables') { , @('ORDERS'); , @('ITEMS') } elseif ("$In" -match 'FROM user_objects') { , @('ITEMS') } elseif ("$In" -match 'SELECT 1 x') { , @('1', 'x') } }
    $global:esCalls = @(); function Invoke-RestMethod { param($Uri, $Method = 'Get', $Body, $ContentType, $TimeoutSec) $global:esCalls += "$Method $Uri $Body"; if ($Uri -match '_snapshot/kit-marks/kitsnap5$') { [pscustomobject]@{ snapshots = @([pscustomobject]@{ indices = @('orders', '.kibana') }) } } elseif ($Uri -match '_cat/indices') { @([pscustomobject]@{ index = 'orders' }, [pscustomobject]@{ index = 'orders-new' }, [pscustomobject]@{ index = '.x' }) } }
    $o = [ordered]@{}
    $o.temp = @('pg', 'ms', 'ora' | Where-Object { (Get-DbTempUse $_)[0].gb -eq 2.5 }).Count -eq 3 -and (Test-DbTempUse 'es') -eq $false
    Stop-DbConn pg 7; $o.kill = "$($global:dbSqls[-1])" -match 'pg_terminate_backend\(7\)' -and $(try { Stop-DbConn ora 7; $false } catch { "$_" -match 'sid,serial' })
    Invoke-DbEngine ms 'snap' @{ pos = 'kitsnap9:0' }; $o.msSnap = "$($global:dbSqls[-1])" -match "CREATE DATABASE \[app_kitsnap9\] ON \(NAME = \[app_data\], FILENAME = 'C:\\d\\app\.kitsnap9\.ss'\) AS SNAPSHOT OF \[app\]"
    $null = Invoke-DbEngine ms 'revert' @{ pos = 'kitsnap2:0' }; $o.msRevert = ($global:dbSqls -match 'DROP DATABASE \[app_kitsnap1\]').Count -eq 1 -and "$($global:dbSqls[-1])" -match '(?s)-d master .*RESTORE DATABASE \[app\] FROM DATABASE_SNAPSHOT = ''app_kitsnap2'''
    $op = Invoke-DbEngine ora 'pos'; $fr = Invoke-DbEngine ora 'revert' @{ pos = $op }; $o.oracle = $op -eq 'scn:4242' -and "$($global:dbSqls[-1])" -match 'FLASHBACK TABLE "ORDERS" TO SCN 4242' -and $fr.fallback[0].table -eq 'ITEMS'
    $null = Invoke-DbEngine es 'snap' @{ pos = 'kitsnap5:0'; scopes = @('orders') }; $null = Invoke-DbEngine es 'revert' @{ pos = 'kitsnap5:0'; scopes = @('orders') }
    $o.es = $global:esCalls[0] -match '^Put \S+/_snapshot/kit-marks/kitsnap5\?wait_for_completion=true .*"indices":"orders"' -and ($global:esCalls -match '^Delete \S+/orders\s*$').Count -eq 1 -and $global:esCalls[-1] -match '^Post \S+/kitsnap5/_restore\?wait_for_completion=true .*"indices":"orders"'
    $qe = Invoke-Hook ora 'query' @{ sql = 'SELECT 1 x FROM dual' }; $o.query = -not $qe -and "$($script:HookOut)" -eq "1`tx"
    $o.mongo = "$((Get-EnvCfg mg).db.exec)" -match '^mongosh --nodb --quiet --eval "db = connect\(process\.env\.KIT_DB_URI \|\| ''mongodb://127\.0\.0\.1:27017/app''\);" "\{file\}"$' -and "$((Get-EnvCfg mg).db.jdbc)" -eq 'jdbc:mongodb://127.0.0.1:27017/app'
    $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
  Expect-Each $tpR 'db engine parity: #' @('temp', 'kill', 'msSnap', 'msRevert', 'oracle', 'es', 'query', 'mongo') -Show 9
  # tenant model column (parity): footprint = rows per table with the column; drop deletes them, the registry table last, a FK refusal
  # retried next pass; tenants.keep never dropped; dry run counts only
  & $J @{ localEnv = @{ envs = @{ cl = @{ services = @(); db = @{ engine = 'postgres'; name = 'app' }; tenants = @{ model = 'column'; keep = @('base'); column = @{ table = 'public.orgs'; column = 'org_id' } } }
    cm = @{ services = @(); db = @{ engine = 'mysql'; name = 'app' }; tenants = @{ model = 'column'; column = @{ table = 'orgs'; column = 'org_id' } } } } } } $cfg 8
  $tcR = & { . $L; $global:tcSql = @(); $global:tcFk = 1
    function Invoke-DbSql { param($e, $sql) $global:tcSql += $sql; if ($sql -match 'information_schema\.COLUMNS') { , @('public', 'orgs'); , @('public', 'orders') } elseif ($sql -match '^SELECT COUNT') { , @('2') }
      elseif ($sql -match '^DELETE FROM public\.orgs' -and $global:tcFk-- -gt 0) { throw 'violates foreign key constraint' } }
    $dry = @(Invoke-TenantModel cl 'drop' @{ names = @('acme', 'base'); dryRun = $true }) -join ' | '; $n0 = @($global:tcSql -match '^DELETE').Count
    $run = @(Invoke-TenantModel cl 'drop' @{ names = @('acme') }) -join ' | '; $dels = @($global:tcSql -match '^DELETE')
    $global:tcSql = @(); $null = Invoke-TenantModel cm 'footprint' @{ name = 'acme' }
    "$dry#$n0#$run#$($dels -join ';')#$(@($global:tcSql -match 'information_schema') -join '')" }
  Expect "tenant model column: dry run counts, keep refused, delete retried past a FK, registry last ($tcR)" ($tcR -match "would delete 2 row\(s\) from public\.orders, 2 row\(s\) from public\.orgs \| \[cl\] tenant base kept" -and $tcR -match "#0#\[cl\] tenant acme: rows deleted from 2 table\(s\)#DELETE FROM public\.orders WHERE org_id = 'acme';DELETE FROM public\.orgs WHERE org_id = 'acme';DELETE FROM public\.orgs WHERE org_id = 'acme'#.* AND TABLE_SCHEMA IN \('app'\)$")
} finally { $env:PATH = $oldPath }
Remove-TestKit $k
# the test helper: a read without the end marker is asked again; a write batch is never re-run (it may have run: a re-run hides the flake)
$tmq = & { $script:tmCalls = 0; function mysql { $script:tmCalls++; $global:LASTEXITCODE = 0; if ($script:tmCalls -eq 1) { 'lost' } else { 'r'; '__kit_rows_end__' } }
  $tmCut = '\):.*'; "$(Invoke-TestMySql 'SELECT 1' 1):$script:tmCalls"; $script:tmCalls = 0; "$(Invoke-TestMySql 'SHOW CREATE TABLE fa.o' 1):$script:tmCalls"; $script:tmCalls = 0
  try { Invoke-TestMySql 'CREATE TABLE t (a int); INSERT INTO t VALUES (1)' 1 } catch { (("$_" -replace $tmCut, ')') + ":$script:tmCalls") } }
Expect "Invoke-TestMySql: a lost read (SHOW CREATE too) retried once, a lost write throws at once ($($tmq -join ' | '))" (($tmq -join ' | ') -eq 'r:2 | r:2 | mysql: exit 0 without the end marker (a write: not re-run, it may have run):1')
Complete-Tests
