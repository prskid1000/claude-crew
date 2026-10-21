#Requires -Version 7
<#
tests.ps1 (extra liquibase): lbcheck on a small changelog (an existing column added again, a changeSet without rollback, an
empty "not reversible" rollback) and dev.ps1 check -Step migrations running it.
Usage: pwsh -NoProfile -File extras/liquibase/tests.ps1 -Kit <kit> (the plugin comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit liquibase
New-Item -ItemType Directory -Force (Join-Path $k 'skills/dev-kit/adapters') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'files/skills/dev-kit/adapters/liquibase.py') (Join-Path $k 'skills/dev-kit/adapters')
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
</databaseChangeLog>
'@ | Set-Content "$lb/changelog/20240102000000_b.xml"
$DT = Join-Path $k 'skills/dev-kit/devtools.py'
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 20240102000000 2>&1 | Out-String
Expect 'lbcheck: re-added column, missing rollback, empty "not reversible" rollback' ($LASTEXITCODE -eq 1 -and $out -match 'b1: addColumn orders\.note already exists' -and
  $out -match 'b2: dropColumn without a <rollback>' -and $out -match 'b3: marked not reversible' -and $out -match 'ISSUES 3')
$out = & $py -X utf8 $DT lbcheck "$lb/master.xml" 20250101000000 2>&1 | Out-String
Expect 'lbcheck: older files are replayed, not reported' ($LASTEXITCODE -eq 0 -and $out -match 'ISSUES 0')
$out = & $py -X utf8 $DT lbcheck 2>&1 | Out-String
Expect 'lbcheck without a master: usage, exit 2' ($LASTEXITCODE -eq 2 -and $out -match 'lbcheck <master.xml>')
'{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$repo/.claude-stack.json"
git -C $repo init -q; git -C $repo -c core.autocrlf=false add -A; git -C $repo -c user.name=t -c user.email=t@t commit -q -m lb
$out = pwsh -NoProfile -File (Join-Path $k 'skills/dev-kit/dev.ps1') check -Dir $repo -Step migrations -Since 20240102000000 2>&1 | Out-String
Expect 'check -Step migrations runs lbcheck through the extra' ($LASTEXITCODE -eq 1 -and $out -match '\[check\] liquibase:' -and $out -match 'ISSUES 3')
Remove-TestKit $k
Complete-Tests
