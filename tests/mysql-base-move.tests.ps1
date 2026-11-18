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
  $init = (& $m 'hm').init.cmd; $script:hm2init = (& $m 'hm2').init.cmd
  "rm=$((& $m 'rm').port)/$($E.rm.db.port)/$((& $m 'rm').external)|hm=$((& $m 'hm').port)/$($E.hm.db.port)|rm2=$((& $m 'rm2').port)/$($E.rm2.db.port)|hm2=$((& $m 'hm2').port)/$($E.hm2.db.port)|clash=$(@(Test-PortClash).Count)|init=$init|exp=$($E.hm.db.expect.innodb_buffer_pool_size)|dir=$((& $m 'hm').start)" }
Expect "config edit: rm 3305 managed, hm 3316 (db.port follows), lanes keep 3307 / 3317, no port clash ($res)" ($res -match '^rm=3305/3305/False\|hm=3316/3316\|rm2=3307/3307\|hm2=3317/3317\|clash=0\|')
Expect "config edit: hm init clones from the donor :3306 into its own dir, hm2 clones from :3316, pool expectation 1G ($res)" ($hm2init -match '-DonorPort 3316' -and $res -match '-Port \{port\} -DonorPort 3306 -Dir "D:/s/lanes/mysql-hm"\|exp=1G\|dir=.*mysql-hm\.ini')
Expect "config edit: two mysql lines and two search lines reported ($($edit.Count))" ($edit.Count -eq 4)
$after = & { . (Join-Path $kd 'skills/envy/envy.ps1'); @('rm', 'hm', 'rm2', 'hm2') | ForEach-Object { Get-LaneStandardRows $_ | ForEach-Object what }; "S=$((@($script:LE.envs.rm.services | Where-Object name -eq 'search')[0]).start)" }
Expect "lane standard: after the edit no breach, search data under the lane folder ($($after -join ' | '))" (@($after).Count -eq 1 -and $after -match 'S=os.bat -Epath.data=D:/s/lanes/search-rm/data -Epath.logs=D:/s/lanes/search-rm/logs')

# dry run: plan printed, nothing created; an existing target dir is refused; -Apply without the donor is refused
$ld = Join-Path $kd 'lanes'; New-Item -ItemType Directory -Force "$ld/mysql-rm" | Out-Null; Set-Content "$ld/mysql-hm2.ini" ($tpl -join "`n")
$out = @(pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf 2>&1) -join "`n"
Expect "dry run: plan, switch-over steps, existing dir and missing binaries refused ($($out.Length) chars)" ($out -match 'rm: clone :3306 ->' -and $out -match '\w+_admin\.db_pool -> :3316' -and $out -match 'mysql-rm exists' -and $out -match 'missing .*mysqld\.exe' -and $out -match 'net stop MySQL80')
Expect 'dry run: nothing created' (-not (Test-Path "$ld/mysql-hm") -and -not (Test-Path "$ld/mysql-hm.ini"))
$null = pwsh -NoProfile -File $mv -Lanes $ld -Bin $ld -ConfigFile $cf -Apply 2>&1
Expect "-Apply refused with exit 1 ($LASTEXITCODE)" ($LASTEXITCODE -eq 1)
Remove-Item (Split-Path $kd) -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fails) { exit 1 }
