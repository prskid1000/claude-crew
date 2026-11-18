#Requires -Version 7
<#
data-cap.tests.ps1: no large writes (owner, 2026-11-18): the crafty guard rule large-writes (adapters/guard_localenv.ps1) and the
supervise DATA GROWTH flag (skills/bossy/adapters/localenv_supervise.ps1; params data.maxRows, data.maxMB).
Usage: pwsh -NoProfile -File <kit>/tests/data-cap.tests.ps1 (or tests/kit-tests.ps1 -Area data-cap). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit dcap; $gk = $k; $supBossy = Join-Path $k 'skills/bossy/bossy.ps1'
$dcAd = New-Item -ItemType Directory -Force (Join-Path $k 'skills/bossy/adapters'); Copy-Item (Join-Path $src 'skills/bossy/adapters/localenv_supervise.ps1') $dcAd
New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy') | Out-Null; '# stub: the hooks only need it present' | Set-Content (Join-Path $k 'skills/envy/envy.ps1')
$dcCad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters')
if (-not (Test-Path (Join-Path $dcCad 'guard_localenv.ps1'))) { Copy-Item (Join-Path $src 'skills/crafty/adapters/guard_localenv.ps1') $dcCad }
# no large writes: a schema grown past data.maxRows / data.maxMB since its baseline = one WATCH (first sight sets baselines; flagged once)
$dg = @(foreach ($dgSizes in @("shop`t100`t1"), @("shop`t5000`t2", "scratch_ie1`t2100000`t1200"), @("shop`t5100`t2", "scratch_ie1`t2100000`t1200"), @("shop`t5100`t80")) {
  (& { . $supBossy; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[],"leases":[],"holds":[],"seed":{"ok":true},"marks":{"count":1,"baseline":"b","baselineAgeDays":1,"expired":[],"binlogDays":30}}]' } }
    function Invoke-KitBackground { $dgSizes }; @(Get-KitSuperviseFlagsLocalEnv) | Where-Object { $_.what -match '^DATA GROWTH' } | ForEach-Object { $_.what -replace ' since .*' } }) -join ';' })
Expect "supervise DATA GROWTH: first sight = baselines, a new 2.1M-row schema flags once, growth under the caps none, +79 MB flags ($($dg -join ' | '))" (
  $dg[0] -eq '' -and $dg[1] -eq 'DATA GROWTH: shop scratch_ie1 +2100000 rows / +1200 MB' -and $dg[2] -eq '' -and $dg[3] -eq 'DATA GROWTH: shop shop +5000 rows / +79 MB')
# large writes (owner 2026-11-18): bulk generators past data.maxRows, scratch schemas on a shared DB, big imports, full dumps, copied trees
$lwBigF = Join-Path $gk 'big.sql'; $lwFs = [IO.File]::Create($lwBigF); $lwFs.SetLength(60MB); $lwFs.Dispose(); 'select 1;' | Set-Content (Join-Path $gk 'small.sql')
$bad = @(foreach ($c in @(@('B', 'mysql -u root -e "CREATE DATABASE scratch_ie1"', $true), @('B', 'mysql -h 127.0.0.1 -P 3306 -u root -e "create schema if not exists bench"', $true),
    @('P', 'mysql -h 127.0.0.1 -P 53118 -u root -e "CREATE DATABASE t_area"', $false), @('B', 'mysqladmin -u root create bench', $true),
    @('B', 'mysql -P 3317 -e "INSERT INTO t (n) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 2000000) SELECT n FROM s"', $true),
    @('B', 'mysql -P 3317 -e "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 50) SELECT n FROM s"', $false),
    @('B', 'python -X utf8 -c "cur.executemany(q, [(i,) for i in range(1_000_000)])"', $true), @('B', 'psql -c "insert into t select generate_series(1, 500000)"', $true),
    @('B', "mysql -P 3317 db < $lwBigF", $true), @('B', "mysql -P 3317 db < $(Join-Path $gk 'small.sql')", $false), @('B', 'mysqldump -u root --all-databases > all.sql', $true),
    @('B', 'mysqldump -u root shop orders > o.sql', $false), @('P', 'Copy-Item D:/w/api/node_modules D:/w2/api/node_modules -Recurse', $true), @('B', 'cp -r ../_deps/node_modules .', $true),
    @('B', 'cp -r src/fixtures tests/', $false), @('B', 'git log --grep "CREATE DATABASE" --oneline', $false), @('B', 'gh api repos/x/pulls/123456789', $false))) {
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress
  $gOut = pwsh @np (Join-Path $gk 'skills/crafty/crafty.ps1') guard -Json $json | Out-String
  if (($gOut -match '"permissionDecision":"deny"' -and $gOut -match 'writes large data') -ne $c[2]) { $c[1] } })
Expect "guard large-writes: bulk generators, shared-DB scratch schemas, big imports, full dumps, copied trees denied; small or scoped ones allowed ($($bad -join ' | '))" (-not $bad.Count)
Remove-TestKit $k
Complete-Tests
