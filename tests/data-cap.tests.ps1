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
# beats (rows | between): baselines; no sizes (busy / DB down: kept); a 2.1M-row schema; the same; +78 MB; +24900 rows, no MB (an estimate swing)
$dgWarn = 'mysql: [Warning] Using a password on the command line interface can be insecure.'
$dg = @(foreach ($dgBeat in "shop`t100`t1", '', "$dgWarn|shop`t5000`t2|scratch_ie1`t2100000`t1200", "shop`t5100`t2|scratch_ie1`t2100000`t1200", "shop`t5100`t80", "shop`t30000`t80") {
  $dgSizes = @($dgBeat -split '\|' | Where-Object { $_ })
  (& { . $supBossy; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[],"leases":[],"holds":[],"seed":{"ok":true},"marks":{"count":1,"baseline":"b","baselineAgeDays":1,"expired":[],"binlogDays":30}}]' } }
    function Invoke-KitBackground { $dgSizes }; @(Get-KitSuperviseFlagsLocalEnv) | Where-Object { $_.what -match '^DATA GROWTH' } | ForEach-Object { $_.what -replace ' since .*' } }) -join ';' })
# the size query passes envy's read-only check (the function from envy.ps1, not the script)
$dgFn = [Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'skills/envy/envy.ps1'), [ref]$null, [ref]$null).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ReadOnlySql' }, $true)[0].Extent.Text
$dgSql = [regex]::Match((Get-Content (Join-Path $src 'skills/bossy/adapters/localenv_supervise.ps1') -Raw), '\$dcSql = "([^"]+)"').Groups[1].Value
$dgRo = & { Invoke-Expression $dgFn; Test-ReadOnlySql $dgSql }
Expect "supervise DATA GROWTH: first sight = baselines, a beat with no sizes keeps them, a new 2.1M-row schema flags once, +79 MB flags, a row estimate swing alone none; envy accepts the query ($($dg -join ' | ') | $dgRo)" (
  $dg[0] -eq '' -and $dg[1] -eq '' -and $dg[2] -eq 'DATA GROWTH: shop scratch_ie1 +2100000 rows / +1200 MB' -and $dg[3] -eq '' -and $dg[4] -eq 'DATA GROWTH: shop shop +5000 rows / +79 MB' -and $dg[5] -eq '' -and $dgRo -eq $true)
# large writes (owner 2026-11-18): bulk generators past data.maxRows, scratch schemas on a shared DB, big imports, full dumps, copied trees
$lwBigF = Join-Path $gk 'big.sql'; $lwFs = [IO.File]::Create($lwBigF); $lwFs.SetLength(60MB); $lwFs.Dispose(); 'select 1;' | Set-Content (Join-Path $gk 'small.sql')
$bad = @(foreach ($c in @(@('B', 'mysql -u root -e "CREATE DATABASE scratch_ie1"', $true), @('B', 'mysql -h 127.0.0.1 -P 3306 -u root -e "create schema if not exists bench"', $true),
    @('P', 'mysql -h 127.0.0.1 -P 53118 -u root -e "CREATE DATABASE t_area"', $false), @('B', 'mysqladmin -u root create bench', $true),
    @('B', 'mysql -P 3317 -e "INSERT INTO t (n) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 2000000) SELECT n FROM s"', $true),
    @('B', 'mysql -P 3317 -e "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 50) SELECT n FROM s"', $false),
    @('B', 'python -X utf8 -c "cur.executemany(q, [(i,) for i in range(1_000_000)])"', $true), @('B', 'psql -c "insert into t select generate_series(1, 500000)"', $true),
    @('B', "mysql -P 3317 db < $lwBigF", $true), @('B', "mysql -P 3317 db < $(Join-Path $gk 'small.sql')", $false), @('B', 'mysqldump -u root --all-databases > all.sql', $true),
    @('B', 'mysqldump -u root shop orders > o.sql', $false), @('P', 'Copy-Item D:/w/api/node_modules D:/w2/api/node_modules -Recurse', $true), @('B', 'cp -r ../_deps/node_modules .', $true),
    @('B', 'cp -r src/fixtures tests/', $false), @('B', 'git log --grep "CREATE DATABASE" --oneline', $false), @('B', 'gh api repos/x/pulls/123456789', $false),
    @('B', 'for i in $(seq 1 5); do curl -s --port 53118 x; done', $false), @('B', 'bossy.ps1 learn -Text "bench made 2100000 rows via generate_series"', $false),
    @('B', 'rg -n "CREATE DATABASE|mysql " skills', $false), @('B', 'cp -r docs/mysql-notes docs2/', $false), @('B', 'cp -r app/build.gradle bak/', $false),
    @('P', '& "C:\Program Files\MySQL\bin\mysql.exe" -u root -e "CREATE DATABASE scratch"', $true), @('B', 'envy.ps1 status; mysql -e "CREATE DATABASE x"', $true),
    @('B', 'python -c "rows = range(10**6)"', $true), @('B', 'for i in {1..2000000}; do echo $i; done > ids.txt', $true), @('B', 'MYSQL_TCP_PORT=3317 mysql -e "CREATE DATABASE x"', $false))) {
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress
  $gOut = pwsh @np (Join-Path $gk 'skills/crafty/crafty.ps1') guard -Json $json | Out-String
  if (($gOut -match '"permissionDecision":"deny"' -and $gOut -match 'writes large data') -ne $c[2]) { $c[1] } })
Expect "guard large-writes: bulk generators, shared-DB scratch schemas, big imports, full dumps, copied trees denied; small or scoped ones allowed ($($bad -join ' | '))" (-not $bad.Count)
Remove-TestKit $k
Complete-Tests
