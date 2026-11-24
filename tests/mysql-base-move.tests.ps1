#Requires -Version 7
<#
tests/mysql-base-move.tests.ps1: skills/envy/mysql-base-move.ps1: the lane ini keeps its low-write settings with a new port and datadir;
the config edit gives each base env its own managed mysql (no port clash, lanes keep theirs, hm's db.port follows); a dry run
changes nothing and refuses an existing target dir; -Apply without a donor is refused. tests/test-mysql.ps1 K79: lock takeover from an
orphan holder, WATCH on a long hold, the starting run stops the server.
Usage: pwsh -NoProfile -File tests/mysql-base-move.tests.ps1 [-Kit <kit>].
Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$mv = Join-Path (Split-Path $PSScriptRoot) 'skills/envy/mysql-base-move.ps1'
. $mv
$tpl = @('[client]', 'port=3317', '[mysqld]', 'sync_binlog=0', 'innodb_doublewrite=OFF', 'port=3317', 'datadir=D:/x/mysql-hm2', 'innodb_buffer_pool_size=1G', 'log-bin=binlog', 'slow-query-log=1', 'innodb_flush_log_at_trx_commit=1', 'innodb_file_per_table=1', 'innodb_io_capacity=2000', 'innodb-io-capacity-max=4000', 'innodb_io_capacity_max=4000', 'innodb-adaptive-flushing=1')
$ini = New-BaseIni $tpl 3316 'D:/x/mysql-hm'
Expect "ini: ports and datadir changed, low-write settings forced under [mysqld] (no general / slow log, doublewrite; flush 2; redo 64M; tables in ibdata1; lazy page flushing), the binlog kept for envy marks, the rest kept ($($ini -join ' '))" ($ini -join ' ' -eq '[client] port=3316 [mysqld] innodb_doublewrite=OFF innodb_flush_log_at_trx_commit=2 general_log=0 slow_query_log=0 innodb_redo_log_capacity=64M binlog_row_metadata=FULL innodb_file_per_table=OFF innodb_adaptive_flushing=OFF innodb_io_capacity=100 innodb_io_capacity_max=200 sync_binlog=0 port=3316 datadir=D:/x/mysql-hm innodb_buffer_pool_size=1G log-bin=binlog')
# the copy writes only what is kept: never a server clone or a schema drop (12.9 GB of mysql.ibd churn per product, 2026-11-18)
$mvText = Get-Content $mv -Raw
Expect 'apply: empty datadir + mysqldump | mysql per kept schema, no CLONE and no DROP DATABASE' ($mvText -match '--initialize-insecure' -and $mvText -match '--single-transaction --no-tablespaces --routines --triggers --events' -and $mvText -notmatch 'CLONE LOCAL|DROP DATABASE|INSTALL PLUGIN')
Expect 'apply: the load keeps the copied tables in own files (the ini puts only later tables in ibdata1)' ($mvText -match "'--skip-log-bin', '--innodb-file-per-table=ON'")

# the config edit on a base + lane layout like the org's, resolved by envy
$lane = { param($n) @{ name = 'mysql'; external = $false; port = $n; start = '"mysqld" --defaults-file="D:/s/lanes/mysql-rm{lane}.ini"'; init = @{ cmd = 'pwsh -File lane.ps1 -Port {port} -Dir "D:/s/lanes/mysql-rm{lane}"'; creates = 'D:/s/lanes/mysql-rm{lane}/lane-ready.txt' } } }
$cfg = @{ localEnv = @{ lanes = @{}; defaults = @{ services = @(@{ name = 'mysql'; external = $true; port = 3306 }); db = @{ engine = 'mysql'; port = 3306; user = 'root'; expect = @{ innodb_buffer_pool_size = '2G' } } }
  envs = @{ rm = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api'; port = 8443 }, @{ name = 'search'; port = 9200; start = 'os.bat -Epath.data=C:/os/rdata{suffix}{lane} -Epath.logs=C:/os/logs-rm{suffix}{lane}' }); env = @{ RM_DbPort = '{port:mysql}' } }; rm2 = @{ services = @(& $lane 3307) }
    hm = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api'; port = 5000 }, @{ name = 'search'; port = 9201; start = 'os.bat -Epath.data=C:/os/rdata{suffix}{lane} -Epath.logs=C:/os/logs-hm{suffix}{lane}' }) }; hm2 = @{ services = @(& $lane 3317) } } } }
$kd = New-TestKit mbm; $dst = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy/adapters')
Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $dst); Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/*') $dst -Force
$cf = Join-Path $kd 'skills/crafty/kit.local.json'; & $J $cfg $cf 12
$before = & { $sdKeep = $env:SystemDrive; $env:SystemDrive = 'C:'; try { . (Join-Path $kd 'skills/envy/envy.ps1'); @('rm', 'hm') | ForEach-Object { Get-LaneStandardRows $_ | ForEach-Object what } } finally { $env:SystemDrive = $sdKeep } }
# the drive rule follows the OS system drive (none on POSIX): another system drive flags no C:/ path
$otherSys = & { $sdKeep = $env:SystemDrive; $env:SystemDrive = 'Q:'; try { . (Join-Path $kd 'skills/envy/envy.ps1'); @(Get-LaneStandardRows 'hm' | Where-Object { $_.what -match 'system drive' }).Count } finally { $env:SystemDrive = $sdKeep } }
Expect "lane standard: an external mysql, search data / logs on C:, a data path shared by two products and an unknown {suffix} are each reported ($($before.Count))" ($before.Count -eq 10 -and @($before | Where-Object { $_ -match '^service search of (rm|hm): \{suffix\} is no envy placeholder' }).Count -eq 2 -and @($before | Where-Object { $_ -match 'external' }).Count -eq 2 -and @($before | Where-Object { $_ -match 'on the system drive C:' }).Count -eq 4 -and $otherSys -eq 0 -and @($before | Where-Object { $_ -match 'shares path.data' }).Count -eq 2)
$obj = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable -Depth 50
$edit = Update-BaseMoveConfig $obj @('rm:3305', 'hm:3316') 3306 'D:/s/lanes'
$obj.localEnv.baseMove = @{ targets = @('rm:3305', 'hm:3316'); service = 'MySQL80'; adminSchema = '{env}_admin'; registryTable = 'reg'; poolTable = 'db_pool' }   # the org values live in config
Set-Content $cf ($obj | ConvertTo-Json -Depth 50) -Encoding utf8
$res = & { . (Join-Path $kd 'skills/envy/envy.ps1'); $E = $script:LE.envs
  $m = { param($n) @($E.$n.services | Where-Object name -eq 'mysql')[0] }
  $init = (& $m 'hm-falcon').init.cmd; $script:hm2init = (& $m 'hm-kestrel').init.cmd
  "rm=$((& $m 'rm-falcon').port)/$($E.'rm-falcon'.db.port)/$((& $m 'rm-falcon').external)|hm=$((& $m 'hm-falcon').port)/$($E.'hm-falcon'.db.port)|rm2=$((& $m 'rm-kestrel').port)/$($E.'rm-kestrel'.db.port)|hm2=$((& $m 'hm-kestrel').port)/$($E.'hm-kestrel'.db.port)|clash=$(@(Test-PortClash).Count)|init=$init|exp=$($E.'hm-falcon'.db.expect.innodb_buffer_pool_size)|dir=$((& $m 'hm-falcon').start)" }
Expect "config edit: rm 3305 managed, hm 3316 (db.port follows), lanes keep 3307 / 3317, no port clash ($res)" ($res -match '^rm=3305/3305/False\|hm=3316/3316\|rm2=3307/3307\|hm2=3317/3317\|clash=0\|')
Expect "config edit: hm init clones from the donor :3306 into its own dir, hm2 clones from :3316, pool expectation 1G ($res)" ($hm2init -match '-DonorPort 3316' -and $res -match '-Port \{port\} -DonorPort 3306 -Dir "D:/s/lanes/mysql-hm-falcon"\|exp=1G\|dir=.*mysql-hm-falcon\.ini')
Expect "config edit: two mysql, two search, two lane-name and one storage.watch line reported; the lane datadirs watched ($($edit.Count))" ($edit.Count -eq 9 -and @($obj.storage.watch) -contains 'D:/s/lanes')
$after = & { . (Join-Path $kd 'skills/envy/envy.ps1'); @('rm-falcon', 'hm-falcon', 'rm-kestrel', 'hm-kestrel') | ForEach-Object { Get-LaneStandardRows $_ | ForEach-Object what }; "S=$((@($script:LE.envs.'rm-falcon'.services | Where-Object name -eq 'search')[0]).start)" }
Expect "lane standard: after the edit no breach, search data under the lane folder ($($after -join ' | '))" (@($after).Count -eq 1 -and $after -match 'S=os.bat -Epath.data=D:/s/lanes/search-rm-falcon/data -Epath.logs=D:/s/lanes/search-rm-falcon/logs')

# dry run: plan printed, nothing created; an existing target dir is refused; -Apply without the donor is refused
$ld = Join-Path $kd 'lanes'; New-Item -ItemType Directory -Force "$ld/mysql-rm-falcon" | Out-Null; Set-Content "$ld/mysql-hm2.ini" ($tpl -join "`n")
$out = @(pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf 2>&1) -join "`n"
Expect "dry run: plan, switch-over steps, existing dir and missing binaries refused ($($out.Length) chars)" ($out -match 'rm: copy its schemas :3306 ->' -and $out -match '\w+_admin\.db_pool -> :3316' -and $out -match 'mysql-rm-falcon exists' -and $out -match 'missing .*mysqld\.exe' -and $out -match 'net stop MySQL80')
Expect 'dry run: nothing created' (-not (Test-Path "$ld/mysql-hm") -and -not (Test-Path "$ld/mysql-hm.ini"))
$null = pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf -Apply 2>&1
Expect "-Apply refused with exit 1 ($LASTEXITCODE)" ($LASTEXITCODE -eq 1)
$trial = @(pwsh -NoProfile -File $mv -Bin $ld -ConfigFile $cf -IniFrom "$ld/mysql-hm2.ini" -Only testtenant 2>&1) -join "`n"
Expect '-Only without a scratch -Lanes is refused (a partial copy never lands in the real lanes dir)' ($trial -match '-Only is a trial: pass a scratch -Lanes')
# no localEnv.baseMove and no args: no built-in targets, service or schema source; refused with the key to set
$cf0 = Join-Path $kd 'bare.local.json'; '{}' | Set-Content $cf0
$bare = @(pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf0 2>&1) -join "`n"; $bareCfg = @(pwsh -NoProfile -File $mv -Config -ConfigFile $cf0 2>&1) -join "`n"
Expect "no baseMove config: targets, schema source and service are not guessed; -Config refused ($LASTEXITCODE)" ($bare -match 'no targets: pass -Targets' -and $bare -match 'no kept-schema source' -and $bare -match 'service: none named' -and $bare -notmatch 'MySQL80|rm:|hm:' -and $bareCfg -match 'REFUSED: no targets' -and $LASTEXITCODE -eq 1)

# laneIds "bird": the lane id is <product>-<bird>; old ids are accepted aliases (warning); old override keys still read; labels follow
$kb = New-TestKit mbm2; $db = New-Item -ItemType Directory -Force (Join-Path $kb 'skills/envy/adapters')
Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $db); Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/*') $db -Force
& $J @{ localEnv = @{ laneIds = 'bird'; envs = @{ shop = @{ lanes = @{ max = 3 }; services = @(@{ name = 'api'; port = 8443 }); env = @{ P = '{port:api}' } }
  shop2 = @{ env = @{ OLDKEY = 'yes' } }; 'shop-osprey' = @{ env = @{ NEWKEY = 'yes' } } } } } (Join-Path $kb 'skills/crafty/kit.local.json') 8
$bird = & { . (Join-Path $kb 'skills/envy/envy.ps1'); $E = $script:LE.envs
  $w = $null; $al = (Get-EnvCfg 'shop2' 3>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'old lane id' })
  "ids=$((EnvNames) -join ',')|ports=$((EnvNames | ForEach-Object { (Get-EnvCfg $_).services[0].port }) -join ',')|k=$((EnvNames | ForEach-Object { (Get-EnvCfg $_).lane }) -join '')|old=$($E.'shop-kestrel'.env.OLDKEY)|new=$($E.'shop-osprey'.env.NEWKEY)|alias=$(Resolve-EnvAlias 'shop' 3>$null)|warn=$(@($al).Count)|label=$(Get-KitPoolLabel env 'shop-kestrel')|names=$((Get-KitLaneNames) -join ',')|slug=$(Get-KitLaneSlug 'shop-osprey')|rows=$((Get-LaneStandardRows 'shop-falcon' | ForEach-Object what) -join ';')" }
Expect "laneIds bird: ids shop-falcon / -kestrel / -osprey, ports offset, overrides from the old and the new key, aliases, labels ($bird)" ($bird -match '^ids=shop-falcon,shop-kestrel,shop-osprey\|ports=8443,8543,8643\|k=123\|old=yes\|new=yes\|alias=shop-falcon\|warn=1\|label=shop·Kestrel\|names=shop-falcon,shop-kestrel,shop-osprey\|slug=shop-osprey\|rows=lane standard: old lane id envs\.shop2')
Remove-Item (Split-Path $kb) -Recurse -Force -ErrorAction SilentlyContinue
# N3 laneIds "nn": envy ids lane-<10 x env index + k>; the bird key's overrides read; older ids alias with a warning; doctor names the key to rename
$kn = New-TestKit mbm3; $dn = New-Item -ItemType Directory -Force (Join-Path $kn 'skills/envy/adapters')
Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $dn); Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/*') $dn -Force
& $J @{ localEnv = @{ laneIds = 'nn'; envs = [ordered]@{ shop = @{ lanes = @{ max = 3 }; services = @(@{ name = 'api'; port = 8443 }) }; 'shop-kestrel' = @{ env = @{ BK = 'yes' } }; desk = @{ services = @(@{ name = 'api'; port = 9443 }) } } } } (Join-Path $kn 'skills/crafty/kit.local.json') 8
$nnE = & { . (Join-Path $kn 'skills/envy/envy.ps1'); $al = (Get-EnvCfg 'shop2' 3>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'old lane id' })
  "ids=$((EnvNames) -join ',')|ports=$((EnvNames | ForEach-Object { (Get-EnvCfg $_).services[0].port }) -join ',')|bk=$($script:LE.envs.'lane-02'.env.BK)|alias=$(Resolve-EnvAlias 'shop-kestrel' 3>$null)/$(Resolve-EnvAlias 'desk' 3>$null)|warn=$(@($al).Count)|rows=$((Get-LaneStandardRows 'lane-01' | ForEach-Object what) -join ';')" }
Expect "laneIds nn: envy ids lane-01..03 + lane-11, ports by lane, the bird key's override read, older ids alias (warning), doctor names the key to rename ($nnE)" ($nnE -match '^ids=lane-01,lane-02,lane-03,lane-11\|ports=8443,8543,8643,9443\|bk=yes\|alias=lane-02/lane-11\|warn=1\|rows=.*old lane id envs\.shop-kestrel: rename the key to lane-02')
Remove-Item (Split-Path $kn) -Recurse -Force -ErrorAction SilentlyContinue

# no hard-coded old lane id (<product><k>) in a path or label of the envy / supervise code
$old = foreach ($f in @(Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) 'skills/envy') -Recurse -Filter '*.ps1' | Where-Object Name -ne 'mysql-base-move.ps1') + @(Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters') -Filter 'localenv*.ps1')) {
  Select-String -LiteralPath $f.FullName -Pattern '["''/\-](rm|hm)[2-9]\b|\b(rm|hm)[2-9][-/.\\"'']' | Where-Object { $_.Line -notmatch '^\s*#' } | ForEach-Object { "$($f.Name):$($_.LineNumber)" } }
Expect "lint: no hard-coded old lane id in envy / supervise code ($(@($old) -join ' '))" (-not @($old).Count)

# -Rename: the lane-scoped names (mysql dir + ini, state, logs, run dir, cmd, lane env file) -> <product>-<bird>; dry run changes nothing; rollback restores
$rnPort = & { $tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $tl.LocalEndpoint.Port; $tl.Stop() }   # a free port: a live lane on 3307 refused the rename
$rt = Join-Path $kd 'rt'; $ln = (Join-Path $kd 'st/lanes')-replace '\\', '/'; $wl = "$rt/work/localenv"; $lg = "$rt/logs/localenv"
foreach ($d in "$ln/mysql-shop2", "$wl/run/shop2/api", $lg, "$wl/tmp") { New-Item -ItemType Directory -Force $d | Out-Null }
Set-Content "$ln/mysql-shop2.ini" "datadir=$ln/mysql-shop2`nport=$rnPort"; Set-Content "$ln/mysql-shop2/lane-ready.txt" "cloned; ini $ln/mysql-shop2.ini"
Set-Content "$wl/shop2.json" '{}'; Set-Content "$wl/run/shop2-api.cmd" 'x'; Set-Content "$lg/shop2-api.log" 'x'; Set-Content "$kd/st/shop2.env" 'A=1'; Set-Content "$kd/st/shop.env" 'A=1'
$rc = Join-Path $kd 'rename.json'; & $J @{ localEnv = @{ envs = @{ shop = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api' }) }; shop2 = @{ services = @(@{ name = 'mysql'; port = $rnPort; start = 'mysqld --defaults-file=x' }) } } } } $rc 8
$pf = Join-Path $kd 'targets.local.json'; & $J @{ targets = @{ 'local-shop' = @{ api = 'http://x:8443' }; 'local-shop2' = @{ api = 'http://x:8543' }; other = @{ api = 'y' } } } $pf 8
$pkBefore = (Get-Content $pf -Raw | ConvertFrom-Json).targets.PSObject.Properties.Name -join ','
$rn = @(pwsh -NoProfile -File $mv -Rename -Lanes $ln -Runtime $rt -ConfigFile $rc -PokeyFile $pf 2>&1) -join "`n"
Expect "rename dry run: the plan lists the dir, state, run, cmd, log and lane env moves, nothing moved ($($rn.Length) chars)" ($rn -match 'mysql-shop2 -> .*mysql-shop-kestrel' -and $rn -match 'shop-kestrel\.json' -and $rn -match 'shop-kestrel-api\.cmd' -and $rn -match 'shop-kestrel-api\.log' -and $rn -match 'shop-kestrel\.env' -and (Test-Path "$ln/mysql-shop2") -and -not (Test-Path "$wl/shop-kestrel.json"))
$null = pwsh -NoProfile -File $mv -Rename -Apply -Lanes $ln -Runtime $rt -ConfigFile $rc -PokeyFile $pf 2>&1
$pkAfter = (Get-Content $pf -Raw | ConvertFrom-Json).targets.PSObject.Properties.Name -join ','
Expect "rename -Apply: pokey target local-shop2 -> local-shop-kestrel, order and the others kept ($pkAfter)" ($pkAfter -eq ($pkBefore -replace 'local-shop2', 'local-shop-kestrel'))
$ini = Get-Content "$ln/mysql-shop-kestrel.ini" -Raw
Expect "rename -Apply: dir, ini (datadir rewritten), lane-ready, state, run dir, cmd, log, env file moved; the base lane's shared shop.env stays ($LASTEXITCODE)" ((Test-Path "$ln/mysql-shop-kestrel/lane-ready.txt") -and $ini -match 'datadir=.*mysql-shop-kestrel' -and (Get-Content "$ln/mysql-shop-kestrel/lane-ready.txt" -Raw) -match 'mysql-shop-kestrel\.ini' -and (Test-Path "$wl/shop-kestrel.json") -and (Test-Path "$wl/run/shop-kestrel/api") -and (Test-Path "$wl/run/shop-kestrel-api.cmd") -and (Test-Path "$lg/shop-kestrel-api.log") -and (Test-Path "$kd/st/shop-kestrel.env") -and (Test-Path "$kd/st/shop.env") -and -not (Test-Path "$ln/mysql-shop2"))
$null = pwsh -NoProfile -File $mv -Rename -Rollback -Lanes $ln -Runtime $rt -ConfigFile $rc -PokeyFile $pf 2>&1
Expect 'rename -Rollback: pokey targets back' ((Get-Content $pf -Raw | ConvertFrom-Json).targets.PSObject.Properties.Name -join ',' -eq $pkBefore)
# a re-run after -Config -Apply (bird keys, a lanes.max lane with no key): no crash, a bird id is never renamed again (hm-falcon-falcon)
$rb = Join-Path $kd 'rename-bird.json'; & $J @{ localEnv = @{ laneIds = 'bird'; envs = @{ shop = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api' }) }; 'shop-kestrel' = @{ services = @(@{ name = 'mysql'; port = $rnPort; start = 'x' }) } } } } $rb 8
$rr = @(pwsh -NoProfile -File $mv -Rename -Lanes $ln -Runtime $rt -ConfigFile $rb -PokeyFile $pf 2>&1) -join "`n"
Expect "rename re-run on a bird config: exit 0, no null-array error, no <bird>-<bird> name ($LASTEXITCODE)" ($LASTEXITCODE -eq 0 -and $rr -notmatch 'null array|kestrel-falcon|falcon-falcon')
Expect 'rename -Rollback: every old name back, the ini as it was' ((Test-Path "$ln/mysql-shop2/lane-ready.txt") -and (Get-Content "$ln/mysql-shop2.ini" -Raw) -match 'datadir=.*mysql-shop2' -and (Test-Path "$wl/shop2.json") -and (Test-Path "$wl/run/shop2-api.cmd") -and (Test-Path "$lg/shop2-api.log") -and (Test-Path "$kd/st/shop2.env") -and -not (Test-Path "$wl/shop-kestrel.json"))
# N3 -Rename -Ids nn: bird ids -> lane-<nn> (state, run, log, lane env file; mysql dirs keep their {bird} names), config laneIds nn + lane keys renamed; ids = wt-pool Get-KitLaneMap's; rollback restores
New-Item -ItemType Directory -Force "$ln/mysql-shop-kestrel" | Out-Null; foreach ($nf in "$wl/shop-kestrel.json", "$wl/desk-falcon.json", "$wl/run/shop-kestrel-api.cmd", "$lg/shop-kestrel-api.log", "$kd/st/shop-kestrel.env") { Set-Content $nf 'x' }
$rnn = Join-Path $kd 'rename-nn.json'; & $J @{ localEnv = @{ laneIds = 'bird'; envs = [ordered]@{ shop = @{ lanes = @{ max = 2 } }; 'shop-kestrel' = @{ env = @{ K = 'v' } }; desk = @{ lanes = @{ max = 1 } } } } } $rnn 8
$nnDry = @(pwsh -NoProfile -File $mv -Rename -Ids nn -Lanes $ln -Runtime $rt -ConfigFile $rnn -PokeyFile $pf 2>&1) -join "`n"
$null = pwsh -NoProfile -File $mv -Rename -Ids nn -Apply -Lanes $ln -Runtime $rt -ConfigFile $rnn -PokeyFile $pf 2>&1; $nnCfg = Get-Content $rnn -Raw | ConvertFrom-Json
$nnIds = & { . (Join-Path $kd 'skills/crafty/lib.ps1'); $__cfg = $nnCfg; (Get-KitLaneNames) -join ',' }
Expect "rename -Ids nn: plan, then lane-02 / lane-11 state, run, log, env file; mysql dir kept; config laneIds nn, envs.shop-kestrel -> lane-02; ids as Get-KitLaneMap ($nnIds)" ($nnDry -match 'laneIds nn, envs\.shop-kestrel -> envs\.lane-02' -and $nnDry -match 'shop-kestrel\.json -> .*lane-02\.json' -and (Test-Path "$wl/lane-02.json") -and (Test-Path "$wl/lane-11.json") -and (Test-Path "$wl/run/lane-02-api.cmd") -and (Test-Path "$lg/lane-02-api.log") -and (Test-Path "$kd/st/lane-02.env") -and (Test-Path "$ln/mysql-shop-kestrel") -and $nnCfg.localEnv.laneIds -eq 'nn' -and $nnCfg.localEnv.envs.'lane-02'.env.K -eq 'v' -and $nnIds -eq 'lane-01,lane-02,lane-11')
$null = pwsh -NoProfile -File $mv -Rename -Rollback -Lanes $ln -Runtime $rt -ConfigFile $rnn -PokeyFile $pf 2>&1
Expect 'rename -Ids nn -Rollback: bird names and the config back' ((Test-Path "$wl/shop-kestrel.json") -and (Test-Path "$wl/desk-falcon.json") -and -not (Test-Path "$wl/lane-02.json") -and (Get-Content $rnn -Raw | ConvertFrom-Json).localEnv.laneIds -eq 'bird')
# pokey: <target>-<bird> resolves (falcon = the base target), an old <target><k> with an explicit <target>-<bird> key warns and resolves
$pks = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/pokey.ps1') -Raw
Expect 'pokey: the bird target name is parsed (falcon = lane 1 = the base target) and an old <target><k> maps to an explicit bird key with a warning' ($pks.Contains('if ($k -eq 1) { return $base }') -and $pks.Contains('old lane target ''$Target'': use $nk'))
Remove-Item (Split-Path $kd) -Recurse -Force -ErrorAction SilentlyContinue
# (cap move from db-engine-presets-2.tests.ps1)
# K79: a lock holder whose run is gone is ended and the lock taken over; one held long by a live run = WATCH, then the timeout names it
$tmLd = New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'lock79'); $tmHs = Join-Path $env:TEMP 'hold79.ps1'; Set-Content $tmHs @'
param($Dir, $Run, $Age, $Lib); . $Lib; $l = Enter-TestMySqlLock $Dir 0
$s = Read-TestMySqlState $Dir; $s.lock.run = $(if ($Run -eq 'self') { $s.lock.holder } else { $Run }); $s.lock.at = (Get-Date).AddMinutes(-[double]$Age).ToString('o'); Save-TestMySqlState $Dir $s
'held' | Set-Content (Join-Path $Dir 'held'); Start-Sleep 60
'@
$tmTake = foreach ($tmCase in @('1:1', 0, 0.5), @('self', 20, 0.05)) {
  Remove-Item (Join-Path $tmLd 'held') -ErrorAction SilentlyContinue
  $tmHp = Start-Process $pwshExe -ArgumentList '-NoProfile', '-File', $tmHs, $tmLd, $tmCase[0], $tmCase[1], (Join-Path $PSScriptRoot 'test-mysql.ps1') -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 100 -and -not (Test-Path (Join-Path $tmLd 'held')); $i++) { Start-Sleep -Milliseconds 200 }
  @(& { try { (Enter-TestMySqlLock $tmLd $tmCase[2]).Dispose(); 'got' } catch { "threw $($_.Exception.Message)" } } 3>&1) -join ' / '
  try { $tmHp.Kill($true) } catch {} }
Expect "test-mysql.ps1: a holder of a gone run is ended and the lock taken; a live run's long hold is one WATCH, the timeout names the holder ($($tmTake -join ' | '))" (
  $tmTake[0] -match 'outlived its run 1:1: ended, lock taken over .*/ got$' -and $tmTake[1] -match '^WATCH test mysqld lock held 2\d min by \d+:\d+ .* / threw .*held 0\.05 min by \d+:\d+')
# K79: the run that started the server stops it at its end even while another run holds it; another starter's server stays; server.json keeps the STATE.md row's keys
$tmOd = New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'own79'); $tmMe = Get-TestProcStamp $PID; $tmPar = Get-TestProcStamp (Get-Process -Id $PID).Parent.Id
$tmOwn = foreach ($tmO in $tmMe, $tmPar) { Save-TestMySqlState $tmOd @{ server = '1:1'; port = 1; key = 'k'; data = 'd'; holders = @($tmMe, $tmPar); owner = $tmO; starts = @() }
  $null = Exit-TestMySqlHolder $tmOd $PID; $tmS = Read-TestMySqlState $tmOd; "$($tmS.server)|$($tmS.holders -join ',')" }
Save-TestMySqlState $tmOd @{ server = '1:1'; port = 1; key = 'k'; data = 'd'; holders = @($tmPar); owner = $tmPar; starts = @() }
$tmHeld2 = Enter-TestMySqlLock $tmOd 0; $tmClk = [Diagnostics.Stopwatch]::StartNew(); try { $null = Exit-TestMySqlHolder $tmOd $PID } finally { $tmHeld2.Dispose() }
$tmOwn += "$((Read-TestMySqlState $tmOd).server)|$([int]$tmClk.Elapsed.TotalSeconds) s"
# K84: the starter's end waits WaitMinutes for a lock another suite holds, then leaves the state and returns (it hung 15+ min)
Save-TestMySqlState $tmOd @{ server = '1:1'; port = 1; key = 'k'; data = 'd'; holders = @($tmMe); owner = $tmMe; starts = @() }
$tmHeld3 = Enter-TestMySqlLock $tmOd 0; $tmClk.Restart(); try { $null = Exit-TestMySqlHolder $tmOd $PID -WaitMinutes 0.02 3>$null } finally { $tmHeld3.Dispose() }
$tmOwn += "$((Read-TestMySqlState $tmOd).server)|$($tmClk.Elapsed.TotalSeconds -lt 30)"
$tmRow = [regex]::Match((Get-Content (Join-Path $src 'skills/bossy/STATE.md') -Raw), '`kit-tests-db` \|[^|]+\| `json v\d+: ([^`]+)`').Groups[1].Value -split ' '
Expect "test-mysql.ps1: its starter stops the server, another starter's stays, a run that never held it ends without the lock; server.json has the schema keys ($($tmOwn -join ' ; ') | $($tmRow -join ' '))" (
  $tmOwn[0] -eq "|$tmPar" -and $tmOwn[1] -eq "1:1|$tmPar" -and $tmOwn[2] -eq '1:1|0 s' -and $tmOwn[3] -eq '1:1|True' -and $tmRow.Count -ge 3 -and -not @($tmRow | Where-Object { -not $tmS.ContainsKey($_) }).Count)
# a server.json that lost its server (moved aside): the mysqld on the same data dir is ended before a start; one on another dir stays
$tmLost = @(1, 2 | ForEach-Object { Start-Process $pwshExe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WindowStyle Hidden -PassThru })
$tmLostP = @($tmLost | ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; ParentProcessId = 1; CommandLine = "mysqld.exe --no-defaults `"--datadir=D:\k$($_.Id -eq $tmLost[1].Id)\.state\kit-tests\mysql`"" } })
$tmGot = @(Stop-TestMySqlLost 'D:/kFalse/.state/kit-tests/mysql/' $tmLostP); Start-Sleep -Milliseconds 300
Expect "test-mysql.ps1: a mysqld on the one data dir that server.json lost is ended, another dir's stays ($($tmGot -join ','))" ($tmGot.Count -eq 1 -and $tmGot[0] -eq $tmLost[0].Id -and $tmLost[0].HasExited -and -not $tmLost[1].HasExited)
$tmLost | ForEach-Object { try { $_.Kill() } catch {} }
# a suite run inside a test kit (its own git clone) uses the outer run's home, never a data dir of its own (a 500 MB init)
$tmNestKit = Join-Path $env:TEMP 'nest78'; $null = New-Item -ItemType Directory -Force (Join-Path $tmNestKit 'skills/crafty'); git -C $tmNestKit init -q
Copy-Item (Join-Path $src 'skills/crafty/kit.example.json') (Join-Path $tmNestKit 'skills/crafty')
$tmNestHome = & $pwshExe -NoProfile -Command ". '$(Join-Path $PSScriptRoot 'test-mysql.ps1')'; `$src = '$tmNestKit'; Get-TestMySqlHome"
Expect "test-mysql.ps1: a nested suite in a test kit inherits the outer home ($tmNestHome)" ("$tmNestHome" -eq (Get-TestMySqlHome) -and "$tmNestHome" -notlike "$tmNestKit*")
# (moved from db-engine-presets-2.tests.ps1: its cap)
# K78 (tests/test-mysql.ps1): one area holds the one server at a time; a second kit-test mysqld is a stray (TEST-MYSQLD)
$tmLk = New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'lock78')   # its own lock dir: the shared one may be held by another run
$tmHeld = Enter-TestMySqlLock $tmLk 0; $tmSecond = try { (Enter-TestMySqlLock $tmLk 0).Dispose(); 'got it' } catch { 'refused' } finally { $tmHeld.Dispose() }
$tmFake = { param($i, $p, $c) [pscustomobject]@{ ProcessId = $i; ParentProcessId = $p; CommandLine = $c } }
$tmStrays = @(Get-TestMySqlStrays @((& $tmFake 10 1 '"mysqld.exe" --no-defaults "--datadir=D:\k\.state\kit-tests\mysql" --port=1'), (& $tmFake 11 10 'mysqld.exe --no-defaults --datadir=D:\k\.state\kit-tests\mysql'),
  (& $tmFake 20 2 "mysqld.exe --no-defaults `"--datadir=D:\w\$($tmpMap.runtimeDir)\work\tests\mysqld-77`" --port=2"), (& $tmFake 30 3 'mysqld.exe --defaults-file=C:\ProgramData\my.ini')) -Server '10:5')
Expect "test-mysql.ps1: one area holds the server at a time (a second take waits: $tmSecond); a second kit-test mysqld (old per-area dir) is a stray, the one server, its worker and the OS service are not ($($tmStrays -join '; '))" ($tmSecond -eq 'refused' -and $tmStrays.Count -eq 1 -and $tmStrays[0] -match '^20 .*mysqld-77$')
if ($script:fails) { exit 1 }
