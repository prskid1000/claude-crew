#Requires -Version 7
<#
Dry run of the LIGHT/HEAVY wiring in localenv-lib.ps1 on a throwaway git repo and a fake env (no services, no DB):
classification per deploy, revert plan + db.rollback command assembly, the hook run and the db.applied check.
  pwsh -NoProfile -File skills/local-env/tests/test-revert.ps1        (exit 1 on a failure)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'scripts/localenv-lib.ps1')
$fail = 0
function Check([string]$what, [bool]$ok, $got) { if ($ok) { "ok   $what" } else { "FAIL $what -> $got"; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "le-revert-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
try {
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
  Set-Content $fake @'
param([string]$Action, [string]$Manifest, [string]$SearchPath, [string]$Changelog, [int]$Count, [string]$Branch, [string]$Out)
if ($Action -eq 'rollback') { "$Count|$Branch|$Changelog|$(Test-Path (Join-Path $SearchPath $Changelog))" | Set-Content $Out; exit 0 }
if ($Action -eq 'applied' -and (Test-Path "$Out.still")) { (Get-Content $Manifest -Raw | ConvertFrom-Json).revert | ForEach-Object { "schema1 $($_.file)::$($_.id)::$($_.author)" } }
'@
  $outF = Join-Path $tmp 'rollback.out'
  $hook = "pwsh -NoProfile -File `"$fake`" -Out `"$outF`""
  $script:LE = [pscustomobject]@{ envs = [pscustomobject]@{ t = [pscustomobject]@{ services = @(); db = [pscustomobject]@{
          rollback = "$hook -Action rollback -Manifest `"{manifest}`" -SearchPath `"{searchPath}`" -Changelog {changelog} -Count {count} -Branch {branch}"
          applied  = "$hook -Action applied -Manifest `"{manifest}`"" } } } }
  $r = [pscustomobject]@{ name = 'api'; cfg = [pscustomobject]@{ checkout = $repo }; target = 'main' }

  $mc = Get-MigClass 't' $r $light
  Check 'light branch is LIGHT' ($mc.effective -eq 'light' -and $mc.count -eq 3) ($mc | ConvertTo-Json -Compress)
  Check 'deploy text names LIGHT' ((MigText $mc) -like 'MIGRATIONS LIGHT (3 changeSets*') (MigText $mc)
  $mh = Get-MigClass 't' $r $heavy
  Check 'heavy branch is HEAVY with its rule' ($mh.effective -eq 'heavy' -and "$($mh.why)" -match 'h-1 drop-data') "$($mh.why)"
  Check 'request routing: HEAVY goes to sandbox/snapshot' ((ReqHeavy @{ migrations = @{ api = $true }; mclass = @{ api = $mh } } 'api') -and -not (ReqHeavy @{ migrations = @{ api = $true }; mclass = @{ api = $mc } } 'api')) ''

  $layer = @{ branch = 'light'; sha = $light; migrations = $true; mclass = $mc }
  $p = Get-MigRevertPlan 't' 'api' @($layer) @() '' 'test1'
  Check 'plan reverts 3 changeSets newest first' ($p.count -eq 3 -and (@($p.revert.id) -join ',') -eq 'l-2,l-1,l-0') (@($p.revert.id) -join ',')
  Check 'command assembled' ($p.cmd -match [regex]::Escape($p.manifest) -and $p.cmd -match '-Count 3 -Branch light' -and $p.cmd -match 'localenv-revert.xml') $p.cmd
  "     cmd: $($p.cmd)"
  Check 'revert runs and verifies' ($null -eq (Invoke-MigRevertPlan 't' $p) -and (Get-Content $outF) -eq '3|light|localenv-revert.xml|True') "$(Get-Content $outF)"
  New-Item -ItemType File "$outF.still" | Out-Null
  $err = Invoke-MigRevertPlan 't' $p
  Check 'db.applied still listing a changeSet fails the revert' ("$err" -match 'still lists') "$err"

  $kept = Get-MigRevertPlan 't' 'api' @($layer) @($layer) '' 'test2'
  Check 'same changeSets in a staying layer: nothing to revert' ($kept.count -eq 0 -and -not $kept.cmd) $kept.count
  $dep = Get-MigClass 't' $r (& $branch 'dep' '20260401000000_dep.xml' '<changeSet id="d-1" author="dev"><createIndex tableName="order_status" indexName="ix_s"><column name="id"/></createIndex></changeSet>')
  $b = Get-MigRevertPlan 't' 'api' @($layer) @(@{ branch = 'dep'; migrations = $true; mclass = $dep }) '' 'test3'
  Check 'dependent staying layer blocks the revert' ($b.blocked.Count -eq 1 -and (MigPlanText $b) -like 'revert blocked:*order_status*') (MigPlanText $b)

  $script:LE.envs.t.db = [pscustomobject]@{}
  $m2 = Get-MigClass 't' $r $light
  Check 'no db.rollback hook: LIGHT handled as HEAVY' ($m2.class -eq 'light' -and $m2.effective -eq 'heavy') ($m2 | ConvertTo-Json -Compress)
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (MigRoot 't') -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "$fail check(s) failed"; exit 1 }
'all checks passed'
