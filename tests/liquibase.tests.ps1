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
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/*') (Join-Path $k 'skills/crafty/adapters')
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
$DT = Join-Path $k 'skills/crafty/devtools.py'
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
Remove-TestKit $k
Complete-Tests
