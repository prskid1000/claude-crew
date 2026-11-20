#Requires -Version 7
<#
data-cap.tests.ps1: no large writes (owner, 2026-11-18): the crafty guard rule large-writes (adapters/guard_localenv.ps1) and the
supervise DATA GROWTH flag (skills/bossy/adapters/localenv_supervise.ps1; params data.maxRows, data.maxMB), the WRITES flag and its
card (adapters/supervise_stats.ps1; params writes.softGBPerHour, writes.hardGBPerHour; disk counter, writes.tracerCsv).
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
    @('B', 'python -c "rows = range(10**6)"', $true), @('B', 'for i in {1..2000000}; do echo $i; done > ids.txt', $true), @('B', 'MYSQL_TCP_PORT=3317 mysql -e "CREATE DATABASE x"', $false),
    @('B', 'git -C ../api archive abc123 | tar -x -C x', $true), @('P', 'git archive --format=zip -o r.zip HEAD', $true), @('B', 'git archive HEAD svc/tools.py | tar -x', $false), @('B', 'git archive --list', $false), @('B', 'git log --grep archive', $false), @('B', 'git --no-pager -c a=b archive HEAD > r.tar', $true),
    @('B', 'python -c "for i in range(int(1e6)): pass"', $true), @('B', 'aws wafv2 get-web-acl --id 0b6a1c2d-1e2f-4a3b-93e6-5c4d3e2f1a0b; cat > d.json <<EOF
{"Quantity":2,"PriceClass":"PriceClass_100","CallerReference":"x-$(date +%s)"}
EOF', $false))) {   # K98: a uuid group (93e6) is no 10^6 generator
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; cwd = $gk; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress   # cwd: a run from a drive root denies `> x` for its own reason
  $gOut = pwsh @np (Join-Path $gk 'skills/crafty/crafty.ps1') guard -Json $json | Out-String
  if (($gOut -match '"permissionDecision":"deny"' -and $gOut -match 'writes large data') -ne $c[2]) { $c[1] } })
Expect "guard large-writes: bulk generators, shared-DB scratch schemas, big imports, full dumps, copied trees, whole-repo exports denied; small or scoped ones allowed ($($bad -join ' | '))" (-not $bad.Count)
# disk writes per owner (owner 2026-11-18): fake I/O counters over two beats; a resource / shell owner, the OS root, restarts, exits,
# a wrapper folded into its server (timeout -> mysqld); short labels; hour buckets, the 35-day history file, the view and its card
$wrt = @'
$null = . $args[0] 6>$null
$t0 = [datetime]'2026-11-18T10:00:00'; $old = $t0.AddHours(-2)
$mk = { param($id, $par, $nm, $cmd, $wb, $made) [pscustomobject]@{ Id = $id; ParentId = $par; Name = $nm; CommandLine = $cmd; Created = $made; Write = [double]$wb } }
$own = @(@{ pid = 20; label = 'devy-a'; tag = 'shell' }, @{ pid = 40; label = 'build x'; tag = 'kitty' })
$b1 = @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 10 2 'claude.exe' 'claude' 0 $old), (& $mk 20 10 'pwsh.exe' 'pwsh -c load' 1GB $old), (& $mk 30 20 'mysql.exe' 'mysql bulk' 5GB $old),
  (& $mk 40 10 'robocopy.exe' 'robocopy tree' 9GB $old), (& $mk 50 2 'mysqld.exe' 'mysqld --datadir=x' 50GB $old), (& $mk 60 2 'timeout.exe' 'timeout 600' 0 $old), (& $mk 61 60 'mysqld.exe' 'mysqld --datadir=x' 0 $old))
$s1 = Update-KitWriteStats $null $t0 $b1 $own 100GB
$t1 = $t0.AddMinutes(20)
$b2 = @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 10 2 'claude.exe' 'claude' 0 $old), (& $mk 20 10 'pwsh.exe' 'pwsh -c load' 1.5GB $old), (& $mk 21 20 'mysql.exe' 'mysql bulk2' 2GB $t0.AddMinutes(5)),
  (& $mk 40 10 'robocopy.exe' 'robocopy tree' 15GB $old), (& $mk 50 2 'mysqld.exe' 'mysqld --datadir=x' 1GB $t0.AddMinutes(10)), (& $mk 70 2 'late.exe' 'late' 40GB $old), (& $mk 60 2 'timeout.exe' 'timeout 600' 0 $old), (& $mk 61 60 'mysqld.exe' 'mysqld --datadir=x' 0.5GB $old))
$s2 = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $b2 $own 110GB
$hr = @{}; foreach ($h in $s2.hour) { $hr[$h.label] = $h.gb }
"first:$(-not @($s1.flags).Count -and -not @($s1.hour).Count)"
"soft:$(-not @($s2.flags | Where-Object { $_.what -match 'mysqld' }).Count -and @($s2.hour | Where-Object { $_.label -eq 'mysqld · x' -and $_.est }).Count -eq 1)"
"hard:$(@($s2.flags | Where-Object { $_.level -eq 'ACT' -and $_.what -match '^WRITES (build x \(kitty\): est\. 6 GB .*top: robocopy|devy-a \(shell\): est\. 2\.5 GB .*top: mysql)' -and $_.action -match '^Check whether it is a one-off' }).Count -eq 2)"
"fold:$($hr['mysqld · x'] -eq 1.5 -and @($s2.flags).Count -eq 2 -and @($hr.Keys).Count -eq 3 -and $s2.samples[-1].m -eq 10)"
"unseen:$(-not $hr.ContainsKey('late'))"
# robocopy exited, the rest idle two sweeps: its hour stays on the card, its flag goes (an exited burst flagged ACT for its whole hour)
$s3 = Update-KitWriteStats ($s2 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(10) @($b2 | Where-Object Id -ne 40) $own 110GB
$s3 = Update-KitWriteStats ($s3 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(20) @($b2 | Where-Object Id -ne 40) $own 110GB   # two idle sweeps: one is no end
"over:$(@($s3.hour | Where-Object label -eq 'build x').Count -eq 1 -and -not @($s3.flags | Where-Object { $_.what -match 'build x' }).Count)"
# K94: the disks wrote 2 GB while process I/O (pipes, sockets) counted 10: each GB x 0.2, capped at the disks; no disk counter -> no flag;
# not kit-owned -> never ACT, no WATCH while the disks stay under hard; the tracer CSV caps a row by its process name
$e2 = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $b2 $own 102GB; $eh = @{}; foreach ($h in $e2.hour) { $eh[$h.label] = $h.gb }
"scaled:$($e2.samples[-1].e -eq 1 -and $e2.samples[-1].m -eq 2 -and $eh['build x'] -eq 1.2 -and $eh['devy-a'] -eq 0.5 -and $eh['mysqld · x'] -eq 0.3 -and @($e2.flags).Count -eq 1 -and $e2.flags[0].level -eq 'WATCH' -and $e2.flags[0].what -match 'build x \(kitty\): est\. 1\.2 GB')"
$n2 = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $b2 $own
"nodisk:$(-not @($n2.flags).Count -and -not $n2.samples[-1].e -and -not @($n2.hour).Count)"
# a raw sample (no prior disk value) and a scaled one in the same hour: only the scaled one counts (robocopy +1 GB, disks +0.5 GB)
$m1 = Update-KitWriteStats ($n2 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(10) $b2 $own 110GB
$m2 = Update-KitWriteStats ($m1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(20) @($b2 | ForEach-Object { if ($_.Id -eq 40) { & $mk 40 10 'robocopy.exe' 'robocopy tree' 16GB $old } else { $_ } }) $own 110.5GB
"mixed:$(@($m2.hour).Count -eq 1 -and @($m2.hour)[0].label -eq 'build x' -and @($m2.hour)[0].gb -eq 0.5 -and -not @($m2.flags).Count)"
$o1 = @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 1GB $old))
$o0 = Update-KitWriteStats $null $t0 $o1 @() 0
$o2 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 2.8GB $old)) @() 1.8GB
$o3 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 5GB $old)) @() 4GB
"notkit:$(-not @($o2.flags).Count -and @($o2.hour)[0].gb -eq 1.8 -and -not @($o3.flags).Count -and @($o3.hour)[0].gb -eq 4 -and @($o3.hour)[0].est)"
# owner 2026-11-19: with a tracer every row is its disk MB (tracer rows in the beat: process, folder, MB): Edge 0.32 GB, no flag; Edge absent
# from the tracer = 0 (est. 4 GB was network); 1.5 GB on disk -> WATCH without "est."; a kit row without folders: its process's MB
$tro = { param($rows) @{ oldest = $t0.AddHours(-3); newest = $t1; rows = @($rows | ForEach-Object { @{ t = $t1.AddMinutes(-1); p = $_[0]; f = $_[1]; mb = [double]$_[2] } }) } }
$eb = @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 5GB $old))
$o4 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $eb @() 4GB (& $tro @(, @('msedge', 'C:\e', 327.68)))
$o5 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $eb @() 4GB (& $tro @(, @('chrome', 'C:\c', 102.4)))
$o6 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $eb @() 4GB (& $tro @(@('msedge', 'C:\e', 1024), @('msedge', 'C:\f', 512)))
$k4 = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $b2 $own 102GB (& $tro @(@('robocopy', 'D:\t', 10.24), @('mysqld', 'D:\m', 51.2), @('System', 'D:\$Mft', 900))); $kh = @{}; foreach ($h in $k4.hour) { $kh[$h.label] = $h.gb }
$tf = Join-Path $args[1] 'tracer.csv'
Set-Content $tf @('"Time","Kind","Process","Folder","TopFile","WriteMB"', "`"$($t1.AddMinutes(-70).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"C:\x`",`"f`",`"900`"",
  "`"$($t1.AddMinutes(-15).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"C:\x`",`"f`",`"200.5`"", "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"D:\y`",`"g`",`"127.5`"",
  "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"net`",`"msedge`",`"D:\y`",`"g`",`"5000`"", "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"Slack.exe`",`"C:\s`",`"s`",`"10.24`"",
  "`"$($t1.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"chrome`",`"C:\z`",`"h`",`"")
$tr = Read-KitWriteTracer $tf $t1; $trOld = Read-KitWriteTracer $tf $t1.AddHours(2); $th = Join-Path $args[1] 'tracer-head.csv'; Set-Content $th '"Time","Process","WriteMB"'
$tsum = { param($x, $p) [double](@($x.rows | Where-Object { $_.p -eq $p } | ForEach-Object { $_.mb }) + 0 | Measure-Object -Sum).Sum }
# writes.tracer columns renamed and reordered, a new kind value skipped, no folder column; no kind column: every row is disk; no MB column: no tracer
$tn = Join-Path $args[1] 'tracer-new.csv'; $ts = $t1.AddMinutes(-2).ToString('yyyy-MM-dd HH:mm:ss')
Set-Content $tn @('"MB","When","Proc","Type"', "`"64`",`"$ts`",`"java.exe`",`"disk`"", "`"999`",`"$ts`",`"java`",`"cache`"")
$tk = Join-Path $args[1] 'tracer-nokind.csv'; Set-Content $tk @('Time,Process,WriteMB', "$ts,node,32")
$tm = Join-Path $args[1] 'tracer-nomb.csv'; Set-Content $tm @('Time,Process,Bytes', "$ts,node,32")
$trN = Read-KitWriteTracer @{ csv = $tn; time = 'When'; kind = 'Type'; process = 'Proc'; folder = 'Folder'; mb = 'MB'; disk = 'disk' } $t1; $trK = Read-KitWriteTracer $tk $t1
"tracer:$(@($o4.hour)[0].gb -eq 0.32 -and -not @($o4.flags).Count -and -not @($o4.hour)[0].est -and $o4.samples[-1].t -eq 1 -and -not @($o5.hour).Count -and -not @($o5.flags).Count -and
  @($o6.flags).Count -eq 1 -and $o6.flags[0].level -eq 'WATCH' -and $o6.flags[0].what -match '^WRITES Edge \(CDP 9222\): 1\.5 GB to disk .*not kit-owned' -and
  $kh['build x'] -eq 0.01 -and -not $kh.ContainsKey('mysqld · x') -and -not $kh.ContainsKey('devy-a') -and (& $tsum $tr 'msedge') -eq 328 -and (& $tsum $tr 'Slack') -eq 10.24 -and -not @($tr.rows | Where-Object p -eq 'chrome').Count -and
  $null -eq $trOld -and $null -eq (Read-KitWriteTracer '' $t1) -and $null -eq (Read-KitWriteTracer $th $t1) -and (& $tsum $trN 'java') -eq 64 -and @($trN.rows).Count -eq 1 -and $trN.rows[0].f -eq '' -and
  (& $tsum $trK 'node') -eq 32 -and $null -eq (Read-KitWriteTracer $tm $t1))"
# D14: a write under a kit row's folders is its own whatever the process (a browser profile: System flushes it); other System writes: none
$ko = @(@{ pid = 90; label = 'browser stg·a'; tag = 'test:T1' }); $kc = 'chrome.exe --user-data-dir="D:\k\chrome-profiles\stg__a" --remote-debugging-port=9333'
$pb = { param($wb) @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 90 2 'chrome.exe' $kc $wb $old)) }; $p0 = Update-KitWriteStats $null $t0 (& $pb 1GB) $ko 0
$p1 = Update-KitWriteStats ($p0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 (& $pb 4GB) $ko 3GB (& $tro @(@('System', 'D:\k\chrome-profiles\stg__a\Default\...', 61.44), @('chrome', 'D:\k\chrome-profiles\stg__a', 24.58), @('System', 'D:\other', 5120)))
$p2 = Update-KitWriteStats ($p0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 (& $pb 4GB) $ko 3GB
"folders:$(@($p1.hour)[0].gb -eq 0.08 -and -not @($p1.flags).Count -and @($p2.hour)[0].gb -eq 3 -and @($p2.flags | Where-Object level -eq 'ACT').Count -eq 1)"
# re-render: est. samples of the day re-attributed once a tracer covers them (t = 1), their closed hours written again in the history file
$rp = $p0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $rq = Update-KitWriteStats $rp $t1 (& $pb 4GB) $ko 3GB; $rr = Update-KitWriteStats ($rq | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(10) (& $pb 4.1GB) $ko 3.1GB (& $tro @(, @('System', 'D:\k\chrome-profiles\stg__a', 102.4)))
$rf = Join-Path $args[1] 'redo.jsonl'; Set-Content $rf (([ordered]@{ at = ([datetimeoffset]$t0.Date.AddHours($t0.Hour)).ToString('o'); m = 3; k = 3; o = @{ 'browser stg·a' = 3 } }) | ConvertTo-Json -Compress)
Update-KitWriteHistory $rf $rr.samples $t1.AddHours(1) $rr.redo; $rh = @(Get-Content $rf | ConvertFrom-Json)
$r2 = Update-KitWriteStats ($rr | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(20) (& $pb 4.2GB) $ko 3.2GB (& $tro @(, @('System', 'D:\k\chrome-profiles\stg__a', 102.4)))
$late = & $tro @(); $late.oldest = $t1.AddMinutes(5); $rx = Update-KitWriteStats ($rq | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1.AddMinutes(10) (& $pb 4.1GB) $ko 3.1GB $late
"redo:$(@($rr.redo).Count -eq 1 -and @($rr.samples | Where-Object { -not $_.t }).Count -eq 0 -and [math]::Abs([double]$rh[0].o.'browser stg·a' - 0.1) -lt 0.001 -and $rh.Count -eq 1 -and
  -not @($r2.redo).Count -and [math]::Abs([double](@($r2.hour)[0].gb) - 0.1) -lt 0.001 -and -not @($rx.redo).Count -and $rx.samples[0].x -eq 1 -and -not $rx.samples[0].t)"
# the shared database (an external env service, no pid) is its env resource row by its port; a root under a kit folder (the kit-tests
# mysqld's data dir) is kit-owned
function Get-KitTcpRows { [pscustomobject]@{ LocalPort = 3306; RemoteAddress = '0.0.0.0'; RemotePort = 0; State = 'LISTENING'; OwningProcess = 50 } }
$ow = @(Get-KitWriteOwners @([pscustomobject]@{ kind = 'env'; name = 'mysql (rm, hm)'; by = 'devy-a, W1 (grace 3 min)'; port = 3306; shared = $true }))
$ok0 = @($b2 | ForEach-Object { if ($_.Id -eq 61) { & $mk 61 2 'mysqld.exe' 'mysqld --datadir=D:\kit\.state\kit-tests\db' 0.5GB $old } else { $_ } })
$kt = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $ok0 (@($own) + $ow) 102GB $null @('D:/kit'); $kth = @{}; foreach ($h in $kt.hour) { $kth[$h.label] = $h }
"owners:$($ow.Count -eq 1 -and $ow[0].pid -eq 50 -and $ow[0].tag -eq 'devy-a, W1' -and $kth['mysql (rm, hm)'].k -eq 1 -and $kth['mysql (rm, hm)'].tag -eq 'devy-a, W1' -and $kth['mysqld · kit-tests'].k -eq 1 -and -not $kth.ContainsKey('mysqld · x'))"
# two mysqld (kit-tests --datadir, a lane --defaults-file): each row = the tracer MB under its own data folder; the machine MySQL's
# writes go to neither (2026-11-19: kit-tests showed 5.55 GB, 1.70 GB traced there)
$m2 = { param($wb) @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 81 2 'mysqld.exe' 'mysqld --no-defaults --datadir=D:\kit\.state\kit-tests\mysql' $wb $old), (& $mk 82 2 'mysqld.exe' '"C:/P/mysqld.exe" --defaults-file=D:/kit/.state/localenv/lanes/mysql-a/my.ini' $wb $old)) }
$q0 = Update-KitWriteStats $null $t0 (& $m2 1GB) @() 0 $null @('D:/kit')
$q1 = Update-KitWriteStats ($q0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 (& $m2 3GB) @() 4GB (& $tro @(@('mysqld', 'D:\kit\.state\kit-tests\mysql\db1', 102.4), @('mysqld', 'D:\kit\.state\localenv\lanes\mysql-a\data', 51.2), @('mysqld', 'C:\ProgramData\MySQL\Data', 1024))) @('D:/kit')
$qh = @{}; foreach ($h in $q1.hour) { $qh[$h.label] = $h.gb }
"twomysqld:$($qh['mysqld · kit-tests'] -eq 0.1 -and $qh['mysqld'] -eq 0.05 -and @($q1.hour).Count -eq 2 -and -not @(Get-KitWriteDirs 'mysqld --defaults-file=C:\my.ini').Count -and -not @(Get-KitWriteDirs 'mysqld --datadir=data').Count)"
"bound:$(-not (Test-KitWriteFolderIn 'D:\a\app2\x' @('D:\a\app')) -and (Test-KitWriteFolderIn 'D:\a\app\x' @('D:\a\app')) -and (Test-KitWriteFolderIn 'D:\a\app' @('D:\a\app\')) -and (Test-KitWriteFolderIn 'D:\k\p\q' @('D:\k\p\q\r')))"
$lb = @((Get-KitWriteLabel 'msedge.exe' 'msedge.exe --headless --remote-debugging-port=9222'), (Get-KitWriteLabel 'mysqld.exe' '"C:\m\mysqld.exe" --no-defaults --datadir=D:\s\kit-tests\my'),
  (Get-KitWriteLabel 'node.exe' 'node "C:\n\npx-cli.js" -y vite build'), (Get-KitWriteLabel 'java.exe' 'java -jar D:\t\api-1.0.jar'), (Get-KitWriteLabel 'Slack.exe' 'Slack.exe --x'), (Get-KitWriteLabel 'python.exe' 'python -m http.server 8000'), (Get-KitWriteLabel 'java.exe' 'java -cp x org.acme.Main'))
"labels:$(($lb -join '|') -ceq 'Edge (CDP 9222)|mysqld · kit-tests|npx · vite|java · api-1.0|Slack|python · http.server|java · Main')"
# one sample 09:50-10:10 splits half and half; 6 more beats make hours 10 and 11
$sm = @(for ($i = 0; $i -lt 7; $i++) { [ordered]@{ at = [datetime]'2026-11-18T10:10:00' + [timespan]::FromMinutes(20 * $i) | ForEach-Object { $_.ToString('o') }; s = 1200; m = 1.2; w = @([ordered]@{ n = 'mysqld · x'; a = ''; g = 0.8; c = 'mysqld'; k = 0 }, [ordered]@{ n = 'build x'; a = 'kitty'; g = 0.4; c = 'mvn'; k = 1 }) } })
$hs = @{}; Add-KitWriteHours @($sm[0]) $hs
"buckets:$([math]::Round($hs['2026111809'].m, 3) -eq 0.6 -and [math]::Round($hs['2026111810'].k, 3) -eq 0.2 -and $hs['2026111810'].t['build x'] -eq 'kitty')"
$hf = Join-Path $args[1] 'disk-writes.jsonl'; $now = [datetime]'2026-11-18T12:05:00'
Set-Content $hf @(@(-40, -10, -10, -1) | ForEach-Object { [ordered]@{ at = $now.Date.AddDays($_).AddHours(5).ToString('o'); m = 2; k = 1; o = @{ Edge = 1.5 } } | ConvertTo-Json -Compress })
Update-KitWriteHistory $hf $sm $now; $cnt1 = @(Get-Content $hf).Count; Update-KitWriteHistory $hf $sm $now
$hl = @(Get-Content $hf | ConvertFrom-Json)
"history:$($cnt1 -eq 5 -and @(Get-Content $hf).Count -eq 5 -and $hl[0].d -eq 1 -and $hl[0].m -eq 4 -and ([datetime]$hl[-1].at).Hour -eq 11 -and [math]::Abs($hl[-1].m - 3.6) -lt 0.001)"
$v = Get-KitWriteView $sm $hl $now 1; $r = @{}; foreach ($x in $v.rows) { $r[$x.n] = $x }
"view:$($v.rows[0].n -eq 'whole machine' -and $r['mysqld · x'] -and $r.others.d30 -eq 8.8 -and $r['kit-owned'].day -eq 2.8 -and $r['whole machine'].d7 -eq 10.4 -and $v.rows[0].h[23] -eq 0.6 -and @($v.days).Count -eq 7)"
$global:n1 = { param($x) "$x" }; $global:e = { param($x) "$x" }; $global:fold = { param($id, $t, $c, $in, [switch]$Open, $tag, $cls) "<f $cls>$in</f>" }
$card = Format-KitWritesCard ($v | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
$pg = Format-KitSuperviseHtml ([pscustomobject]@{ at = $now.ToString('o'); resources = @([pscustomobject]@{ name = 'build x'; by = 'kitty'; gb = 1 }); stats = [pscustomobject]@{ writes = ($v | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } })
$vt = $v | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $vt.src = 'tracer'
$pgT = Format-KitSuperviseHtml ([pscustomobject]@{ at = $now.ToString('o'); resources = @([pscustomobject]@{ name = 'build x'; by = 'kitty'; gb = 1 }); stats = [pscustomobject]@{ writes = $vt } })
"label:$($v.src -eq 'est' -and $pg -match '>Writes GB est\.</button>' -and $pg -match 'a cell = est\. GB written' -and $pgT -match '>Writes GB</button>' -and $pgT -match 'a cell = GB written')"
"card:$($card -match "^<f sub st wr" -and $card -match 'day · hour' -and $card -match "class='gs hm sp ws'" -and $pg -match "data-g='rg-build'>.*?>build x<small>kitty</small>.*?<span data-mv=w class='gs hm ws'" -and $pg -match '>other processes<')"
'@
Expect-Each (Invoke-PsTest 'writes' $wrt @($supBossy, (Kd))) 'disk writes per owner: #' @('first', 'soft', 'hard', 'fold', 'unseen', 'over', 'scaled', 'nodisk', 'mixed', 'notkit', 'tracer', 'folders', 'redo', 'owners', 'twomysqld', 'bound', 'labels', 'buckets', 'history', 'view', 'label', 'card') -Show 8
# the hour counts each second once: a 2 h window by its part in the hour, two sweeps' overlapping tracer windows once, never above all
# disks; kit-owned when any sample saw it so; a process below the tree's root naming a kit folder makes the tree the kit's
$ovl = Invoke-PsTest 'overlap' @'
$null = . $args[0] 6>$null; $n = [datetime]'2026-11-18T12:00:00'; $kc = 'mysqld --datadir=D:\k\.state\kit-tests\mysql'
$sm = { param($m, $s, $g, $k, $mach) [ordered]@{ at = $n.AddMinutes(-$m).ToString('o'); s = $s; m = $mach; t = 1; w = @([ordered]@{ n = 'mysqld · kit-tests'; a = $(if ($k) { 'kit' } else { '' }); g = $g; c = $kc; k = $k }) } }
$pr = [pscustomobject]@{ at = $n.AddMinutes(-1).ToString('o'); acc = @{}; samples = @((& $sm 30 7200 4.0 0 4.0), (& $sm 20 600 1.0 1 1.0), (& $sm 15 600 1.0 0 0.1)) }
$h = (Update-KitWriteStats $pr $n @() @() $null $null @('D:\k')).hour[0]
$pk = [pscustomobject]@{ at = $n.AddMinutes(-10).ToString('o'); acc = [pscustomobject]@{ '7|' = 0; '6|' = 0 }; samples = @() }
$kd = Update-KitWriteStats $pk $n @([pscustomobject]@{ Id = 7; ParentId = 6; Name = 'mysqld.exe'; CommandLine = $kc; Write = 1GB }, [pscustomobject]@{ Id = 6; ParentId = 2; Name = 'pwsh.exe'; CommandLine = 'pwsh -c run'; Write = 1GB }) @() $null $null @('D:\k')
"$($h.gb) $($h.k) $($h.tag) $(@($kd.samples[-1].w | Where-Object { $_.n -eq 'mysqld · kit-tests' -and $_.k -eq 1 }).Count)"
'@ @($supBossy)
Expect "writes hour: overlapping and 2 h windows counted once, capped at all disks, kit-owned once seen, a kit folder below the root ($ovl)" ("$ovl".Trim() -eq '2.05 1 kit 1')
# a holder record with several pids (a lane group, a shared lease) must not crash the writes hook ([int] of an array)
$mpt = @'
$null = . $args[0] 6>$null; $KitShellRows = @(); $res = @([pscustomobject]@{ pid = @(4, 8); by = 'x'; name = 'svc' })
$r = try { $null = Get-KitSuperviseFlagsWrites; 'ok' } catch { "crash $($_.Exception.Message)" }
"multipid:$($r -eq 'ok')"
'@
Expect-Each (Invoke-PsTest 'multipid' $mpt @($supBossy)) 'writes hook, holder with several pids: #' @('multipid') -Show 8
# a holder with several pids (retro 2026-11-19: [int] of an array crashed supervise): every pid's tree counts, no crash
$cpm = & { . $supBossy; $c = [math]::Max(1, [Environment]::ProcessorCount); $n = Get-Date
  function Get-KitSweepProcs { foreach ($p in @(@(200, 250, 540), @(250, 1, 0), @(300, 1, 6), @(0, 0, 300))) { [pscustomobject]@{ Id = $p[0]; ParentId = $p[1]; Name = "p$($p[0]).exe"; Cpu = 1000 + $p[2] * $c } } }
  $acc = [pscustomobject]@{ '200|' = 1000; '250|' = 1000; '300|' = 1000; idle = 1000 }
  try { "$((Update-KitCpuStats ([pscustomobject]@{ at = $n.AddSeconds(-600).ToString('o'); acc = $acc; samples = @() }) $n @() @(@{ name = 'browser x'; pid = @(300, 250, 0) })).samples[-1].g.'browser x')" } catch { "crash $($_.Exception.Message)" } }
Expect "cpu: a holder with pids 300, 250 sums both trees (1 + 90), pid 0 skipped ($cpm)" ("$cpm" -eq '91')
# owner 2026-11-19: Disk free, Disk writes, Repos now fold closed, a one-line summary in the header; Trends inside Kit internals
$fo = & { . $supBossy 6>$null; $n = Get-Date; $lv = @(@{ at = $n.AddDays(-1).ToString('o'); disks = @{ 'C:' = 50.5 } }, @{ at = $n.AddMinutes(-10).ToString('o'); disks = @{ 'C:' = 48.2 } })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ live = $lv; disks = @(@{ drive = 'C:'; free = 48.2; rate = 0; total = 100 }); now = [pscustomobject]@{ disks = @(@{ drive = 'C:'; free = 48.2; rate = 0 }) }
      repos = @{ repos = @(@{ repo = 'web'; branches = 3; worktrees = 2; kept = 1 }) }; writes = @{ at = $n.ToString('o'); days = @(@{ d = $n.Date.ToString('o'); m = 2.5; k = 1; h = @(, @(1, 0.5)) }) } } })
  @(@{ id = 'disk-free'; s = 'now C: 48.2 GB' }, @{ id = 'writes'; s = '2.5 GB in 7 days · today 2.5 GB (1 GB kit)' }, @{ id = 'repos-now'; s = '3 branches · 2 worktrees' }) | ForEach-Object { $h -match "id=sec-$($_.id)><summary><h4>[^<]*</h4>(<span class=cnt>[^<]*</span>)?<span class=fsm>$([regex]::Escape($_.s))</span>" }
  $h.IndexOf("<details class='sec top' id=sec-internals>") -lt $h.IndexOf("id=sec-trends open>") }
Expect "page: disk free / writes / repos folded closed with a header summary; Trends inside the closed Kit internals ($fo)" ("$fo" -eq 'True True True True')
# supervise's forced tick reuses a db list under 5 min old while every drive is OK and no query held 1 GB; a drive not OK or a 1 GB query: asked again
$reu = Invoke-PsTest storage-reuse @'
$null = . $args[0] 6>$null; Set-KitStorageState { param($s) $s.Remove('dbAt') }; $global:dbc = 0; $global:gb = 0.2; $global:lvl = 'OK'; $__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ db = [pscustomobject]@{ use = 'x' } } }
function Get-KitDbQueries($C) { $global:dbc++; @([pscustomobject]@{ id = '9'; gb = $global:gb; secs = 1; query = 'q' }) }
function Get-KitDrives { @([pscustomobject]@{ name = 'R'; root = 'R:\'; free = 500; size = 900; kit = $true }) }; function Get-KitDiskVerdict { [pscustomobject]@{ level = $global:lvl; anomaly = $false; rescue = $false; rate = 0; ttf = 1e9; free = 500; normal = 0.1 } }
$t = { $null = Invoke-KitStorageTick -Force }; & $t; & $t; $a = $global:dbc; $global:gb = 3; $global:lvl = 'WATCH'; & $t; $global:lvl = 'OK'; & $t; "reuse:$a`:$global:dbc"
# 10 min old: reused while no drive fills at minRateGBh (5), asked again once one does
$global:gb = 0.2; & $t; $ageDb = { Set-KitStorageState { param($s) $s.dbAt = (Get-Date).AddMinutes(-10).ToString('o') } }; $b = $global:dbc; & $ageDb; & $t; $c1 = $global:dbc
function Get-KitDiskVerdict { [pscustomobject]@{ level = 'OK'; anomaly = $false; rescue = $false; rate = 6; ttf = 80; free = 500; normal = 0.1 } }; & $ageDb; & $t; "stable:$($c1 - $b):$($global:dbc - $c1)"
'@ @($supBossy)
Expect "storage tick: a forced tick reuses a fresh db list while drives are OK and no query holds 1 GB; 15 min while no drive fills, 5 min while one does ($(@($reu) -join ' '))" (@($reu)[-2] -eq 'reuse:1:3' -and @($reu)[-1] -eq 'stable:0:1')
# laneIds bird: samples, writes and waits under an old lane id (shop · api, written before the rename) join the bird id's row
$lanePage = & { . $supBossy; $n = Get-Date; $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ laneIds = 'bird'; envs = [pscustomobject]@{ shop = [pscustomobject]@{ lanes = [pscustomobject]@{ max = 2 } } } } }
  $sOld = @{ at = $n.AddMinutes(-30).ToString('o'); s = 600; all = 20; g = @{ 'shop · api' = 4 }; m = @{ 'shop · api' = 1 }; top = @() }; $sNew = @{ at = $n.AddMinutes(-5).ToString('o'); s = 600; all = 20; g = @{ 'shop-falcon · api' = 6 }; m = @{ 'shop-falcon · api' = 1 }; top = @() }
  $wr = { param($nm, $gb) [pscustomobject]@{ n = $nm; a = ''; c = ''; h = @(@(0) * 23 + $gb); now = $gb; peak = $gb; avg = $gb / 24; day = $gb; d7 = $gb } }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ cpu = @{ samples = @($sOld, $sNew) }; writes = [pscustomobject]@{ rows = @((& $wr 'lane shop' 1), (& $wr 'lane shop-falcon' 2)) }
      waits = @{ rows = @([pscustomobject]@{ name = 'shop · api'; n = 2; min = 3; max = 2; hours = @() }, [pscustomobject]@{ name = 'shop-falcon · api'; n = 1; min = 1; max = 1; hours = @() }) } } })
  "$([regex]::Matches($h, "<span class=gn title='shop-falcon &#183; api").Count)/$([regex]::Matches($h, "<span class=gn title='shop &#183; api").Count) $([regex]::Matches($h, "<span class=gn title='lane shop-falcon").Count)/$([regex]::Matches($h, "<span class=gn title='lane shop[:']").Count) $($h -match "data-mv=q>3</span>")" }
Expect "lane ids bird: CPU, writes and waits of an old lane id on the bird id's row, none left under the old id ($lanePage)" ("$lanePage" -eq '1/0 1/0 True')
Remove-TestKit $k
Complete-Tests
