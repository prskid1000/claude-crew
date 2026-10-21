#Requires -Version 7
<#
localenv.tests.ps1: localenv.ps1 migrations LIGHT/HEAVY, leases, usage; devtools.py migrations.
Usage: pwsh -NoProfile -File <kit>/tests/localenv.tests.ps1 (or tests/kit-tests.ps1 -Area localenv).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit local; $L = Join-Path $k 'skills/local-env/localenv.ps1'
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
# localenv usage errors exit 2; a start-lock timeout throws, never runs unlocked
$k2 = New-TestKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'PostgreSQL'; name = 'shop'; user = 'u' } } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
Expect 'localenv: db.engine aliases + presets fill unset hooks' ((& { . $L2; "$($script:LE.envs.shop.db.engine) $($script:LE.envs.shop.db.snapshot)" }) -match '^postgres pg_dump -Fc -h 127\.0\.0\.1 -p 5432 -U u -f .+\.dump\" shop$')
$null = Px $L2 bogus 2>&1; $c1 = $LASTEXITCODE
$null = Px $L2 status -Env nope 2>&1; $c2 = $LASTEXITCODE
$null = Px $L2 drop -Env shop 2>&1; $c3 = $LASTEXITCODE
$pr = & { . $L2; $o = (Get-Date).AddMinutes(-11).ToString('o'); $u = (Get-Date).AddHours(1).ToString('o')
  $st = @{ leases = @{ dead = @{ until = $u; holderPid = 999999; seen = $o }; grace = @{ until = $u; holderPid = 999999; seen = (Get-Date).AddMinutes(-3).ToString('o') }; live = @{ until = $u; holderPid = $PID } }
    holds = @{ own = @{ owner = $true; until = (Get-Date).AddMinutes(5).ToString('o') }; old = @{ owner = $true; until = $o }; co = @{ agent = 'main'; seen = $o } }; requests = @() }
  Prune $st; "$(($st.leases.Keys | Sort-Object) -join ',')|$(($st.holds.Keys | Sort-Object) -join ',')|$($st.leases.grace.graceLeft)" }
Expect "leases: no live holder -> kept for the grace, then gone; owner holds keep their minutes; a coordinator hold needs a heartbeat ($pr)" ($pr -eq 'grace,live|own|7')
$lv = & { . $L2; $b = Get-KitPath board -Create; & $J @{ agent = 'B1'; session = 'B1-s'; status = 'working'; beat = (Get-Date).ToString('o') } "$b/B1-s.json"
  & $J @{ at = (Get-Date).ToString('o'); running = @('build:R1'); labels = @('build:R1', 'local:X1') } (Get-KitPath live-steps -Create)
  "$(Test-KitLive @{ session = 'B1-s'; holderPid = 999999 })$(Test-KitLive @{ agent = 'R1' })$(Test-KitLive @{ agent = 'X1'; holderPid = $PID })" }
Expect "leases: live by a board beat or a running workflow step; a finished step is not ($lv)" ($lv -eq 'TrueTrueFalse')
$lf = & { . (Join-Path $k2 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'shop.json' }; '{"holds":{"main":{"services":["api"],"agent":"main"}}}' | Set-Content $lf
$u1 = Px $L2 up -Env shop 2>&1 | Out-String; $c4 = $LASTEXITCODE; $null = Px $L2 unhold -Env shop -Agent main 2>&1
Expect "localenv: up refuses without -Services; unhold ends a hold" ($c4 -eq 1 -and $u1 -match 'up needs -Services' -and -not @((Get-Content $lf -Raw | ConvertFrom-Json).holds.PSObject.Properties).Count)
Expect 'localenv: usage errors exit 2; a start-lock timeout throws' ($c1 -eq 2 -and $c2 -eq 2 -and $c3 -eq 2 -and (Get-Content $L2 -Raw) -match 'if \(-not \$got\) \{ \$mx\.Dispose\(\); throw')
$r3 = & { . $L2; $st = @{ leases = @{ live = @{ agent = 'A'; until = (Get-Date).AddMinutes(-5).ToString('o'); holderPid = $PID }; own = @{ owner = $true; until = (Get-Date).AddMinutes(-1).ToString('o') } }; holds = @{}; requests = @() }; Prune $st
  "$(@('with t as (select 1) select 1;', 'db.o.find({})', 'select 1; drop t', 'select "a"', 'call p()') | ForEach-Object { Test-ReadOnlySql $_ })|$(@('CHANGELOG.md', 'db/m/README.md', 'db/changelog/1.xml', 'migrations/1.sql') -match $script:MigPattern -join ',')|$($st.leases.Keys)|$(Leased 'clients')$(Leased 'clients', 'lease:A')|$(IdleWhy 15 '')" }
Expect "localenv: read-only sql; docs are no migrations; a live holder outlives until; only a lease starts; idle why ($r3)" ($r3 -like 'True True False False False|db/changelog/1.xml,migrations/1.sql|live|FalseTrue|idle: no holder*' -and $r3 -notmatch 'restart')
Remove-TestKit $k2
Remove-TestKit $k
Complete-Tests
