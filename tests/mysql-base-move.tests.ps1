#Requires -Version 7
<#
tests/mysql-base-move.tests.ps1: skills/envy/mysql-base-move.ps1: the lane ini keeps its low-write settings with a new port and datadir;
the config edit gives each base env its own managed mysql (no port clash, lanes keep theirs, hm's db.port follows); a dry run
changes nothing and refuses an existing target dir; -Apply without a donor is refused.
Usage: pwsh -NoProfile -File tests/mysql-base-move.tests.ps1 [-Kit <kit>].
Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$mv = Join-Path (Split-Path $PSScriptRoot) 'skills/envy/mysql-base-move.ps1'
. $mv
$tpl = @('[client]', 'port=3317', '[mysqld]', 'sync_binlog=0', 'innodb_doublewrite=OFF', 'port=3317', 'datadir=D:/x/mysql-hm2', 'innodb_buffer_pool_size=1G')
$ini = New-BaseIni $tpl 3316 'D:/x/mysql-hm'
Expect "ini: ports and datadir changed, low-write settings kept ($($ini -join ' '))" ($ini -join ' ' -eq '[client] port=3316 [mysqld] sync_binlog=0 innodb_doublewrite=OFF port=3316 datadir=D:/x/mysql-hm innodb_buffer_pool_size=1G')

# the config edit on a base + lane layout like the org's, resolved by envy
$lane = { param($n) @{ name = 'mysql'; external = $false; port = $n; start = '"mysqld" --defaults-file="D:/s/lanes/mysql-rm{lane}.ini"'; init = @{ cmd = 'pwsh -File lane.ps1 -Port {port} -Dir "D:/s/lanes/mysql-rm{lane}"'; creates = 'D:/s/lanes/mysql-rm{lane}/lane-ready.txt' } } }
$cfg = @{ localEnv = @{ lanes = @{}; defaults = @{ services = @(@{ name = 'mysql'; external = $true; port = 3306 }); db = @{ engine = 'mysql'; port = 3306; user = 'root'; expect = @{ innodb_buffer_pool_size = '2G' } } }
  envs = @{ rm = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api'; port = 8443 }, @{ name = 'search'; port = 9200; start = 'os.bat -Epath.data=C:/os/rdata{suffix}{lane} -Epath.logs=C:/os/logs-rm{suffix}{lane}' }); env = @{ RM_DbPort = '{port:mysql}' } }; rm2 = @{ services = @(& $lane 3307) }
    hm = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api'; port = 5000 }, @{ name = 'search'; port = 9201; start = 'os.bat -Epath.data=C:/os/rdata{suffix}{lane} -Epath.logs=C:/os/logs-hm{suffix}{lane}' }) }; hm2 = @{ services = @(& $lane 3317) } } } }
$kd = New-TestKit mbm; $dst = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy/adapters')
Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $dst); Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/envy/adapters/*') $dst -Force
$cf = Join-Path $kd 'skills/crafty/kit.local.json'; & $J $cfg $cf 12
$before = & { . (Join-Path $kd 'skills/envy/envy.ps1'); @('rm', 'hm') | ForEach-Object { Get-LaneStandardRows $_ | ForEach-Object what } }
Expect "lane standard: an external mysql, search data / logs on C: and a data path shared by two products are each reported ($($before.Count))" ($before.Count -eq 8 -and @($before | Where-Object { $_ -match 'external' }).Count -eq 2 -and @($before | Where-Object { $_ -match 'on C:' }).Count -eq 4 -and @($before | Where-Object { $_ -match 'shares path.data' }).Count -eq 2)
$obj = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable -Depth 50
$edit = Update-BaseMoveConfig $obj @('rm:3305', 'hm:3316') 3306 'D:/s/lanes'
Set-Content $cf ($obj | ConvertTo-Json -Depth 50) -Encoding utf8
$res = & { . (Join-Path $kd 'skills/envy/envy.ps1'); $E = $script:LE.envs
  $m = { param($n) @($E.$n.services | Where-Object name -eq 'mysql')[0] }
  $init = (& $m 'hm-falcon').init.cmd; $script:hm2init = (& $m 'hm-kestrel').init.cmd
  "rm=$((& $m 'rm-falcon').port)/$($E.'rm-falcon'.db.port)/$((& $m 'rm-falcon').external)|hm=$((& $m 'hm-falcon').port)/$($E.'hm-falcon'.db.port)|rm2=$((& $m 'rm-kestrel').port)/$($E.'rm-kestrel'.db.port)|hm2=$((& $m 'hm-kestrel').port)/$($E.'hm-kestrel'.db.port)|clash=$(@(Test-PortClash).Count)|init=$init|exp=$($E.'hm-falcon'.db.expect.innodb_buffer_pool_size)|dir=$((& $m 'hm-falcon').start)" }
Expect "config edit: rm 3305 managed, hm 3316 (db.port follows), lanes keep 3307 / 3317, no port clash ($res)" ($res -match '^rm=3305/3305/False\|hm=3316/3316\|rm2=3307/3307\|hm2=3317/3317\|clash=0\|')
Expect "config edit: hm init clones from the donor :3306 into its own dir, hm2 clones from :3316, pool expectation 1G ($res)" ($hm2init -match '-DonorPort 3316' -and $res -match '-Port \{port\} -DonorPort 3306 -Dir "D:/s/lanes/mysql-hm-falcon"\|exp=1G\|dir=.*mysql-hm-falcon\.ini')
Expect "config edit: two mysql, two search and two lane-name lines reported ($($edit.Count))" ($edit.Count -eq 8)
$after = & { . (Join-Path $kd 'skills/envy/envy.ps1'); @('rm-falcon', 'hm-falcon', 'rm-kestrel', 'hm-kestrel') | ForEach-Object { Get-LaneStandardRows $_ | ForEach-Object what }; "S=$((@($script:LE.envs.'rm-falcon'.services | Where-Object name -eq 'search')[0]).start)" }
Expect "lane standard: after the edit no breach, search data under the lane folder ($($after -join ' | '))" (@($after).Count -eq 1 -and $after -match 'S=os.bat -Epath.data=D:/s/lanes/search-rm-falcon/data -Epath.logs=D:/s/lanes/search-rm-falcon/logs')

# dry run: plan printed, nothing created; an existing target dir is refused; -Apply without the donor is refused
$ld = Join-Path $kd 'lanes'; New-Item -ItemType Directory -Force "$ld/mysql-rm-falcon" | Out-Null; Set-Content "$ld/mysql-hm2.ini" ($tpl -join "`n")
$out = @(pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf 2>&1) -join "`n"
Expect "dry run: plan, switch-over steps, existing dir and missing binaries refused ($($out.Length) chars)" ($out -match 'rm: clone :3306 ->' -and $out -match '\w+_admin\.db_pool -> :3316' -and $out -match 'mysql-rm-falcon exists' -and $out -match 'missing .*mysqld\.exe' -and $out -match 'net stop MySQL80')
Expect 'dry run: nothing created' (-not (Test-Path "$ld/mysql-hm") -and -not (Test-Path "$ld/mysql-hm.ini"))
$null = pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf -Apply 2>&1
Expect "-Apply refused with exit 1 ($LASTEXITCODE)" ($LASTEXITCODE -eq 1)

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

# no hard-coded old lane id (<product><k>) in a path or label of the envy / supervise code
$old = foreach ($f in @(Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) 'skills/envy') -Recurse -Filter '*.ps1' | Where-Object Name -ne 'mysql-base-move.ps1') + @(Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters') -Filter 'localenv*.ps1')) {
  Select-String -LiteralPath $f.FullName -Pattern '["''/\-](rm|hm)[2-9]\b|\b(rm|hm)[2-9][-/.\\"'']' | Where-Object { $_.Line -notmatch '^\s*#' } | ForEach-Object { "$($f.Name):$($_.LineNumber)" } }
Expect "lint: no hard-coded old lane id in envy / supervise code ($(@($old) -join ' '))" (-not @($old).Count)

# -Rename: the lane-scoped names (mysql dir + ini, state, logs, run dir, cmd, lane env file) -> <product>-<bird>; dry run changes nothing; rollback restores
$rt = Join-Path $kd 'rt'; $ln = (Join-Path $kd 'st/lanes')-replace '\\', '/'; $wl = "$rt/work/localenv"; $lg = "$rt/logs/localenv"
foreach ($d in "$ln/mysql-shop2", "$wl/run/shop2/api", $lg, "$wl/tmp") { New-Item -ItemType Directory -Force $d | Out-Null }
Set-Content "$ln/mysql-shop2.ini" "datadir=$ln/mysql-shop2`nport=3307"; Set-Content "$ln/mysql-shop2/lane-ready.txt" "cloned; ini $ln/mysql-shop2.ini"
Set-Content "$wl/shop2.json" '{}'; Set-Content "$wl/run/shop2-api.cmd" 'x'; Set-Content "$lg/shop2-api.log" 'x'; Set-Content "$kd/st/shop2.env" 'A=1'; Set-Content "$kd/st/shop.env" 'A=1'
$rc = Join-Path $kd 'rename.json'; & $J @{ localEnv = @{ envs = @{ shop = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api' }) }; shop2 = @{ services = @(@{ name = 'mysql'; port = 3307; start = 'mysqld --defaults-file=x' }) } } } } $rc 8
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
Expect 'rename -Rollback: every old name back, the ini as it was' ((Test-Path "$ln/mysql-shop2/lane-ready.txt") -and (Get-Content "$ln/mysql-shop2.ini" -Raw) -match 'datadir=.*mysql-shop2' -and (Test-Path "$wl/shop2.json") -and (Test-Path "$wl/run/shop2-api.cmd") -and (Test-Path "$lg/shop2-api.log") -and (Test-Path "$kd/st/shop2.env") -and -not (Test-Path "$wl/shop-kestrel.json"))
# pokey: <target>-<bird> resolves (falcon = the base target), an old <target><k> with an explicit <target>-<bird> key warns and resolves
$pks = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/pokey.ps1') -Raw
Expect 'pokey: the bird target name is parsed (falcon = lane 1 = the base target) and an old <target><k> maps to an explicit bird key with a warning' ($pks.Contains('if ($k -eq 1) { return $base }') -and $pks.Contains('old lane target ''$Target'': use $nk'))
Remove-Item (Split-Path $kd) -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fails) { exit 1 }
