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
  Expect "tenants.model unset = none: tenant list refuses, names the models ($nc)" ($nc -ne 0 -and $n -match 'tenant-model none: verb list not implemented \(set envs\.s\.tenants\.model: column \| database \| schema\)')
  $cl = & { . $L; function Invoke-DbSql { param($e, $sql) if ($sql -eq 'SELECT DISTINCT org FROM orders') { , @('a'); , @('b'); , @('NULL') } }; @(Invoke-TenantModel c 'list' | ForEach-Object { "$($_.name)$(if ($_.keep) { '*' })" }) -join ',' }
  $sc = & { . $L; @(Get-DataScopes s) -join ',' }
  Expect "column model lists the column's values (keep marked); one-DB scopes = db.name ($cl | $sc)" ($cl -eq 'a*,b' -and $sc -eq 'shop')
  # postgres: the engine adapter has no sql verb -> refused, the mysql client never runs (also not for a schema tenant model)
  & $J @{ localEnv = @{ envs = @{ pg = @{ services = @(); db = @{ engine = 'postgresql'; user = 'u'; name = 'app' }; tenants = @{ model = 'schema'; schema = 'adm'; table = 'reg'; key = 'id'; name = 'name' } } } } } $cfg 8
  $p = & { . $L; try { Invoke-DbSql pg 'SELECT 1'; 'ran' } catch { "$_" } }
  $pt = Px $L tenant list -Env pg 2>&1 | Out-String
  Expect "postgres: Invoke-DbSql refuses, tenant (schema model) refuses, mysql never called ($p)" ($p -eq 'engine postgres: verb sql not implemented' -and $pt -match 'tenant needs db\.engine mysql / mariadb' -and -not (Test-Path $hit))
  # envy verbs: a local adapter registers one (ops checked); an unknown verb is refused with the list
  "Register-KitAdapter envy-verb hello @{ ops = @('wave'); run = { `"hello `$Op from `$e`" } }" | Set-Content (Join-Path $ad 'zz_hello.local.ps1')
  $h = Px $L hello wave -Env pg 2>&1 | Out-String; $hc = $LASTEXITCODE
  $hb = & $flat (Px $L hello jump -Env pg 2>&1 | Out-String); $u = & $flat (Px $L nosuchverb 2>&1 | Out-String); $uc = $LASTEXITCODE
  Expect "envy verbs: a registered verb runs, its ops checked; an unknown verb refused ($hc | $($h.Trim()))" ($hc -eq 0 -and $h -match 'hello wave from pg' -and $hb -match 'hello jump : unknown \(wave\)' -and $uc -ne 0 -and $u -match "unknown verb 'nosuchverb'.*hello")
} finally { $env:PATH = $oldPath }
Remove-TestKit $k
Complete-Tests
