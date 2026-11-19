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
    @('B', 'git -C ../api archive abc123 | tar -x -C x', $true), @('P', 'git archive --format=zip -o r.zip HEAD', $true), @('B', 'git archive HEAD svc/tools.py | tar -x', $false), @('B', 'git archive --list', $false), @('B', 'git log --grep archive', $false), @('B', 'git --no-pager -c a=b archive HEAD > r.tar', $true))) {
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
"soft:$(@($s2.flags | Where-Object { $_.level -eq 'WATCH' -and $_.what -match '^WRITES mysqld · x: est\. 1\.5 GB to disk .*\(all disks 10 GB; soft 1 / hard 2 GB; not kit-owned\)' }).Count -eq 1)"
"hard:$(@($s2.flags | Where-Object { $_.level -eq 'ACT' -and $_.what -match '^WRITES (build x \(kitty\): est\. 6 GB .*top: robocopy|devy-a \(shell\): est\. 2\.5 GB .*top: mysql)' -and $_.action -match '^Check whether it is a one-off' }).Count -eq 2)"
"fold:$($hr['mysqld · x'] -eq 1.5 -and @($s2.flags).Count -eq 3 -and @($hr.Keys).Count -eq 3 -and $s2.samples[-1].m -eq 10)"
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
"notkit:$(-not @($o2.flags).Count -and @($o2.hour)[0].gb -eq 1.8 -and @($o3.flags).Count -eq 1 -and $o3.flags[0].level -eq 'WATCH' -and $o3.flags[0].what -match 'Edge \(CDP 9222\): est\. 4 GB .*not kit-owned')"
$o4 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 5GB $old)) @() 4GB @{ msedge = 0.32 }
$o5 = Update-KitWriteStats ($o0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 80 2 'msedge.exe' 'msedge.exe --remote-debugging-port=9222' 5GB $old)) @() 4GB @{ chrome = 0.1 }
$k4 = Update-KitWriteStats ($s1 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 $b2 $own 102GB @{ robocopy = 0.01; mysqld = 0.05 }; $kh = @{}; foreach ($h in $k4.hour) { $kh[$h.label] = $h.gb }
$tf = Join-Path $args[1] 'tracer.csv'
Set-Content $tf @('"Time","Kind","Process","Folder","TopFile","WriteMB"', "`"$($t1.AddMinutes(-70).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"C:\x`",`"f`",`"900`"",
  "`"$($t1.AddMinutes(-15).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"C:\x`",`"f`",`"200.5`"", "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"msedge`",`"D:\y`",`"g`",`"127.5`"",
  "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"net`",`"msedge`",`"D:\y`",`"g`",`"5000`"", "`"$($t1.AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"Slack.exe`",`"C:\s`",`"s`",`"10.24`"",
  "`"$($t1.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss'))`",`"disk`",`"chrome`",`"C:\z`",`"h`",`"")
$tr = Read-KitWriteTracer $tf $t1; $trOld = Read-KitWriteTracer $tf $t1.AddHours(2); $th = Join-Path $args[1] 'tracer-head.csv'; Set-Content $th '"Time","Process","WriteMB"'
"tracer:$(@($o4.hour)[0].gb -eq 0.32 -and @($o5.hour)[0].gb -eq 4 -and @($o5.flags).Count -eq 1 -and $kh['build x'] -eq 1.2 -and $kh['mysqld · x'] -eq 0.05 -and -not @($o4.flags).Count -and [math]::Abs($tr['msedge'] - 0.3203) -lt 0.001 -and [math]::Abs($tr['Slack'] - 0.01) -lt 0.0001 -and -not $tr.ContainsKey('chrome') -and $null -eq $trOld -and $null -eq (Read-KitWriteTracer '' $t1) -and $null -eq (Read-KitWriteTracer $th $t1))"
# D14: a kit row's estimate is capped by the tracer's GB for the folders its command names (a browser profile: System flushes it)
$null = Read-KitWriteTracer $tf $t1; $tfo = $script:KitTracerFolders; $ko = @(@{ pid = 90; label = 'browser stg·a'; tag = 'test:T1' }); $kc = 'chrome.exe --user-data-dir="D:\k\chrome-profiles\stg__a" --remote-debugging-port=9333'
$pb = { param($wb) @((& $mk 2 0 'services.exe' '' 0 $old), (& $mk 90 2 'chrome.exe' $kc $wb $old)) }; $p0 = Update-KitWriteStats $null $t0 (& $pb 1GB) $ko 0
$p1 = Update-KitWriteStats ($p0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 (& $pb 4GB) $ko 3GB $null @{ 'D:\k\chrome-profiles\stg__a\Default' = 0.084; 'D:\other' = 5 }
$p2 = Update-KitWriteStats ($p0 | ConvertTo-Json -Depth 6 | ConvertFrom-Json) $t1 (& $pb 4GB) $ko 3GB
"folders:$(@($p1.hour)[0].gb -eq 0.08 -and -not @($p1.flags).Count -and @($p2.hour)[0].gb -eq 3 -and @($p2.flags | Where-Object level -eq 'ACT').Count -eq 1 -and [math]::Abs([double]$tfo['D:\y'] - 0.1245) -lt 0.001 -and -not $tfo.ContainsKey('D:\x'))"
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
"card:$($card -match "^<f sub st wr" -and $card -match 'day · hour' -and $card -match "class='gs hm sp ws'" -and $pg -match "data-g='rg-build'>.*?>build x<small>kitty</small>.*?<span data-mv=w class='gs hm ws'" -and $pg -match '>other processes<')"
'@
Expect-Each (Invoke-PsTest 'writes' $wrt @($supBossy, (Kd))) 'disk writes per owner: #' @('first', 'soft', 'hard', 'fold', 'unseen', 'over', 'scaled', 'nodisk', 'mixed', 'notkit', 'tracer', 'folders', 'labels', 'buckets', 'history', 'view', 'card') -Show 8
# a holder record with several pids (a lane group, a shared lease) must not crash the writes hook ([int] of an array)
$mpt = @'
$null = . $args[0] 6>$null; $KitShellRows = @(); $res = @([pscustomobject]@{ pid = @(4, 8); by = 'x'; name = 'svc' })
$r = try { $null = Get-KitSuperviseFlagsWrites; 'ok' } catch { "crash $($_.Exception.Message)" }
"multipid:$($r -eq 'ok')"
'@
Expect-Each (Invoke-PsTest 'multipid' $mpt @($supBossy)) 'writes hook, holder with several pids: #' @('multipid') -Show 8
Remove-TestKit $k
Complete-Tests
