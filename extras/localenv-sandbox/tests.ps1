#Requires -Version 7
<#
tests.ps1 (extra localenv-sandbox): LIGHT/HEAVY classes, revert plans, db.applied check, goose tool, against the full
variant localenv-sandbox.ps1 (needs extra migration-classify for devtools.py migrations).
Usage: copy next to <kit>/tests/harness.ps1 after kittool.py extra add localenv-sandbox migration-classify; pwsh -File it.
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit local; $L = Join-Path $k 'skills/local-env/localenv-sandbox.ps1'
$t = @'
$ErrorActionPreference = 'Stop'
. $args[0]
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null
$repo = Join-Path $tmp 'repo'; $cl = 'api/src/main/resources/config/liquibase/changelog'
git init -q -b main $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
$x = { param($body) "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<databaseChangeLog xmlns=`"http://www.liquibase.org/xml/ns/dbchangelog`">`n$body</databaseChangeLog>`n" }
$put = { param($rel, $text) $p = Join-Path $repo $rel; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; [IO.File]::WriteAllText($p, $text) }
& $put "$cl/20260101000000_base.xml" (& $x '<changeSet id="b-1" author="dev"><createTable tableName="orders"><column name="id" type="BIGINT"/></createTable></changeSet>')
git -C $repo add -A; git -C $repo commit -q -m base; git -C $repo update-ref refs/remotes/origin/main main
$branch = { param($name, $file, $body) git -C $repo checkout -q -b $name main; & $put "$cl/$file" (& $x $body); git -C $repo add -A; git -C $repo commit -q -m $name; $s = "$(git -C $repo rev-parse HEAD)".Trim(); git -C $repo checkout -q main; $s }
$light = & $branch 'light' '20260201000000_light.xml' ('<changeSet id="l-0" author="dev"><tagDatabase tag="l"/></changeSet>' +
  '<changeSet id="l-1" author="dev"><addColumn tableName="orders"><column name="note" type="VARCHAR(80)"/></addColumn><rollback><dropColumn tableName="orders" columnName="note"/></rollback></changeSet>' +
  '<changeSet id="l-2" author="dev"><createTable tableName="order_status"><column name="id" type="INT"/></createTable></changeSet>')
$heavy = & $branch 'heavy' '20260301000000_heavy.xml' '<changeSet id="h-1" author="dev"><dropColumn tableName="orders" columnName="id"/><rollback><addColumn tableName="orders"><column name="id" type="BIGINT"/></addColumn></rollback></changeSet>'
$fake = Join-Path $tmp 'fake-db.ps1'
Set-Content $fake @"
param([string]`$Action, [string]`$Manifest, [string]`$SearchPath, [string]`$Changelog, [int]`$Count, [string]`$Branch, [string]`$Out)
if (`$Action -eq 'rollback') { "`$Count|`$Branch|`$Changelog|`$(Test-Path (Join-Path `$SearchPath `$Changelog))" | Set-Content `$Out; exit 0 }
if (`$Action -eq 'applied' -and (Test-Path "`$Out.still")) { (Get-Content `$Manifest -Raw | ConvertFrom-Json).revert | ForEach-Object { "schema1 `$(`$_.file)::`$(`$_.id)::`$(`$_.author)" } }
"@
$outF = Join-Path $tmp 'rollback.out'; $hook = "pwsh -NoProfile -File `"$fake`" -Out `"$outF`""
$script:LE = [pscustomobject]@{ envs = [pscustomobject]@{ t = [pscustomobject]@{ services = @(); db = [pscustomobject]@{
rollback = "$hook -Action rollback -Manifest `"{manifest}`" -SearchPath `"{searchPath}`" -Changelog {changelog} -Count {count} -Branch {branch}"
applied = "$hook -Action applied -Manifest `"{manifest}`"" } } } }
$r = [pscustomobject]@{ name = 'api'; cfg = [pscustomobject]@{ checkout = $repo }; target = 'main' }
$mc = Get-MigClass 't' $r $light; "light:$($mc.effective -eq 'light' -and $mc.count -eq 3)"
$mh = Get-MigClass 't' $r $heavy; "heavy:$($mh.effective -eq 'heavy' -and "$($mh.why)" -match 'h-1 drop-data')"
$layer = @{ branch = 'light'; sha = $light; migrations = $true; mclass = $mc }
$p = Get-MigRevertPlan 't' 'api' @($layer) @() '' 'test1'; "plan:$($p.count -eq 3 -and (@($p.revert.id) -join ',') -eq 'l-2,l-1,l-0')"
"revert:$($null -eq (Invoke-MigRevertPlan 't' $p) -and (Get-Content $outF) -eq '3|light|localenv-revert.xml|True')"
New-Item -ItemType File "$outF.still" | Out-Null; "applied:$("$(Invoke-MigRevertPlan 't' $p)" -match 'still lists')"
$script:LE.envs.t.db = [pscustomobject]@{}; $m2 = Get-MigClass 't' $r $light; "nohook:$($m2.class -eq 'light' -and $m2.effective -eq 'heavy')"
git -C $repo checkout -q -b tool main; & $put 'db/m/00002_b.sql' "-- +goose Up`nCREATE TABLE b (id INT);`n-- +goose Down`nDROP TABLE b;`n"; git -C $repo add -A; git -C $repo commit -q -m tool; $tl = "$(git -C $repo rev-parse HEAD)".Trim(); git -C $repo checkout -q main
$mt = Get-MigClass 't' $r $tl; $pt = Get-MigRevertPlan 't' 'api' @(@{ branch = 'tool'; sha = $tl; migrations = $true; mclass = $mt }) @() '' 'test2'; "tool:$($mt.effective -eq 'light' -and $pt.cmd -match 'goose -dir ""db/m"" down-to 0$')"
"missing-sha:$(HasMigrations $repo 'main' 'deadbeef')"
Remove-Item (MigRoot 't') -Recurse -Force -ErrorAction SilentlyContinue
'@
$res = Invoke-PsTest 'revert-test' $t @($L, (Join-Path (Kd) 'le'))
foreach ($x in 'light', 'heavy', 'plan', 'revert', 'applied', 'nohook', 'tool', 'missing-sha') { Expect "local env: $x" ($res -contains "${x}:True") }
$out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') migrations selftest 2>&1 | Out-String
Expect 'devtools.py migrations selftest' ($LASTEXITCODE -eq 0)
Remove-TestKit $k
Complete-Tests
