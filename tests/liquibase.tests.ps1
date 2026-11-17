#Requires -Version 7
<#
liquibase.tests.ps1: lbcheck on a small changelog (an existing column added again, a changeSet without rollback, an
empty "not reversible" rollback, a rollback beside tagDatabase) and crafty.ps1 check -Step migrations running it.
Usage: pwsh -NoProfile -File <kit>/tests/liquibase.tests.ps1 [-Kit <kit>] (or tests/kit-tests.ps1 -Area liquibase).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit liquibase
New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters') | Out-Null
Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters') -File | Where-Object { -not (Test-Path (Join-Path $k "skills/crafty/adapters/$($_.Name)")) } | Copy-Item -Destination (Join-Path $k 'skills/crafty/adapters')   # never over New-TestKit's hard links
$repo = Join-Path (Kd) 'lb-repo'; $lb = Join-Path $repo 'config/liquibase'; New-Item -ItemType Directory -Force "$lb/changelog" | Out-Null
@'
<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">
 <include file="changelog/20240101000000_a.xml" relativeToChangelogFile="true"/>
 <include file="changelog/20240102000000_b.xml" relativeToChangelogFile="true"/>
</databaseChangeLog>
'@ | Set-Content "$lb/master.xml"
@'
<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">
 <changeSet id="a1" author="t"><createTable tableName="orders"><column name="id" type="int"/><column name="note" type="text"/></createTable></changeSet>
</databaseChangeLog>
'@ | Set-Content "$lb/changelog/20240101000000_a.xml"
@'
<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">
 <changeSet id="b1" author="t"><addColumn tableName="orders"><column name="note" type="text"/></addColumn></changeSet>
 <changeSet id="b2" author="t"><dropColumn tableName="orders" columnName="note"/></changeSet>
 <changeSet id="b3" author="t"><!-- not reversible --><sql>update orders set id = id</sql><rollback/></changeSet>
 <changeSet id="b4" author="t"><tagDatabase tag="t4"/><rollback/></changeSet>
 <changeSet id="b5" author="t"><tagDatabase tag="t5"/></changeSet>
</databaseChangeLog>
'@ | Set-Content "$lb/changelog/20240102000000_b.xml"
$DT = Join-Path $k 'skills/crafty/devtools.py'; $cfgf = Join-Path $k 'skills/crafty/kit.local.json'
# default (migrations.lbcheck unset): lenient, only a table / column created again without <preConditions>; no stamp pattern: since 0 = all
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 0 2>&1 | Out-String
Expect "lbcheck default: only the re-added column, no rollback / tagDatabase rules ($(($out -split "`n" | Select-Object -Last 1).Trim()))" ($LASTEXITCODE -eq 1 -and $out -match 'b1: addColumn orders\.note already exists' -and $out -notmatch 'b2:|b3:|b4:' -and $out -match 'ISSUES 1')
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 20240102000000 2>&1 | Out-String
Expect 'lbcheck default: no stamp pattern and nothing changed -> nothing reported' ($LASTEXITCODE -eq 0 -and $out -match 'ISSUES 0')
# the legacy rule set (what kitbag.py migrate writes for an older kit.local.json)
& $J @{ migrations = @{ tool = 'liquibase'; lbcheck = @{ requireRollback = $true; tagDatabaseAlone = $true; stampPattern = '(\d{14})'; roots = @('^(.*?)[\\/]config[\\/]liquibase[\\/]', '^(.*[\\/]resources)[\\/]') } } } $cfgf 8
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 20240102000000 2>&1 | Out-String
Expect 'lbcheck: re-added column, missing rollback, empty "not reversible" rollback, a rollback beside tagDatabase (alone: fine)' ($LASTEXITCODE -eq 1 -and $out -match 'b1: addColumn orders\.note already exists' -and
  $out -match 'b2: dropColumn without a <rollback>' -and $out -match 'b3: marked not reversible' -and
  $out -match 'b4: <tagDatabase> beside <rollback>' -and $out -notmatch 'b5:' -and $out -match 'ISSUES 4')
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 20250101000000 2>&1 | Out-String
Expect 'lbcheck: older files are replayed, not reported' ($LASTEXITCODE -eq 0 -and $out -match 'ISSUES 0')
$out = & $py -X utf8 $DT lbcheck 2>&1 | Out-String
Expect 'lbcheck without a master: usage, exit 2' ($LASTEXITCODE -eq 2 -and $out -match 'lbcheck <master.xml>')
'{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$repo/.claude-stack.json"
git -C $repo init -q; git -C $repo -c core.autocrlf=false add -A; git -C $repo -c user.name=t -c user.email=t@t commit -q -m lb
$out = pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') check -Dir $repo -Step migrations -Since 20240102000000 2>&1 | Out-String
Expect 'check -Step migrations runs lbcheck through the plugin' ($LASTEXITCODE -eq 1 -and $out -match '\[check\] liquibase:' -and $out -match 'ISSUES 4')
Set-Content $cfgf '{}'
$out = pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') check -Dir $repo -Step migrations -Since 20240102000000 2>&1 | Out-String
Expect 'check -Step migrations: migrations.tool unset = none, not checked, exit 0' ($LASTEXITCODE -eq 0 -and $out -match 'no migration tool configured' -and $out -notmatch 'ISSUES')
& $J @{ migrations = @{ tool = 'flyway' } } $cfgf 8
$out = pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') check -Dir $repo -Step migrations -Since 20240102000000 2>&1 | Out-String
Expect 'check -Step migrations: a tool with no kit adapter = UNRUN, exit 5' ($LASTEXITCODE -eq 5 -and $out -match 'migration tool flyway has no kit check')
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $dkl = $cfgf; Remove-Item $dkl -ErrorAction SilentlyContinue
# other tools' migration files (tool none: not checked, above); the liquibase adapter (legacy migrations.tool) lists them UNRUN
$ud = Join-Path (Kd) 'unrun-repo'; New-Item -ItemType Directory -Force $ud | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
Save-GitRepo $ud init
$mig = { param([hashtable]$f) foreach ($p in $f.Keys) { New-Item -Force "$ud/$p" -Value $f[$p] | Out-Null }; Save-GitRepo $ud add; Invoke-TestScript $D check -Dir $ud -Step migrations }
# the liquibase adapter (migrations.tool liquibase, the legacy value): other tools' files are UNRUN
$dk0 = if (Test-Path $dkl) { Get-Content $dkl -Raw }; $dkj = if ($dk0) { $dk0 | ConvertFrom-Json -AsHashtable } else { @{} }; $dkj.migrations = @{ tool = 'liquibase' }; & $J $dkj $dkl 8
Expect-Cases @(
  , @('check: migrations without a kit check or tool are UNRUN (exit 5), docs skipped', { & $mig @{ 'db/migrate/20240101000000_x.rb' = 'def change; end'; 'CHANGELOG.md' = 'x'; 'database/migrations/2024_01_01_000000_x.php' = '<?php' } },
      { param($r) $r.code -eq 5 -and $r.out -match 'UNRUN: 2 migration file\(s\) of another tool' -and $r.out -match '000000_x\.php' -and $r.out -notmatch 'CHANGELOG' })
  , @('check: Flyway, Alembic and Prisma files are UNRUN too', { & $mig @{ 'alembic/versions/a1_x.py' = 'x'; 'prisma/migrations/1_x/migration.sql' = 'x'; 'db/migration/V1__x.sql' = 'x' } },
      { param($r) $r.code -eq 5 -and $r.out -match 'UNRUN: 5 migration file\(s\) of another tool' })
)
if ($dk0) { Set-Content $dkl $dk0 } else { Remove-Item $dkl -ErrorAction SilentlyContinue }
Remove-TestKit $k
Complete-Tests
