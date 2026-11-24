#Requires -Version 7
<#
mysql-base-move.ps1: moves the base envs' MySQL off the OS MySQL service onto one lane-style mysqld each (own datadir, own low-write
ini, envy starts it on a lease and stops it when idle). Writes only what is kept: an empty datadir (--initialize-insecure, the lane
low-write ini), the donor's accounts (hashes), then each kept schema `mysqldump --single-transaction | mysql` (load: flush 0, no binlog,
unique / FK checks off); never clone + drop (that churned 12.9 GB of mysql.ibd for one product).
  pwsh -NoProfile -File mysql-base-move.ps1                      dry run: checks + the plan + the switch-over steps (changes nothing)
  pwsh -NoProfile -File mysql-base-move.ps1 -Apply [-Replace] [-Only <schemas>]   copy, point the db_pool at the new port, verify, MB written;
    MYSQL_PWD from the env file; -Only = a trial with those schemas (no orphan check; use a scratch -Lanes and target port)
  pwsh -NoProfile -File mysql-base-move.ps1 -Config [-Apply]     the kit.local.json edit (dry run prints it; -Apply writes, <file>.bak kept, the one before .bak.prev)
  pwsh -NoProfile -File mysql-base-move.ps1 -Rename [-Apply|-Rollback]   every lane-scoped name (mysql dirs + inis, envy state, logs, run dirs, cmd files, lane env files) to <product>-<bird>, everything down; journal kept
  pwsh -NoProfile -File mysql-base-move.ps1 -Rename -Ids nn [-Apply|-Rollback]   the same to lane-<nn> (N3; mysql dirs keep their {bird} template names) + kit.local.json laneIds nn, lane keys renamed
Targets `<env>:<port>` (next to the lane ports, never the service's). -Targets, -DonorPort, -VerifyPort (a free port the copy loads on), -Bin,
-Service, -AdminSchema, -RegistryTable, -PoolTable:
unset = kit.local.json localEnv.baseMove {targets, donorPort, verifyPort, bin, service, adminSchema, registryTable, poolTable}; -Bin else mysqld on PATH. Each keeps only its product's
schemas (-AdminSchema + the names in its -RegistryTable) and kit_journal (the cascade guard's triggers write it in the same server). Names `<service>-<product>-<bird>` (mysql-shop-falcon, search-docs-kestrel), the bird = the lane number's pool name (`{bird}` in the lane
templates); dir `<Lanes>/mysql-shop-falcon`, ini `<Lanes>/mysql-shop-falcon.ini` (copy of -IniFrom with its port and datadir changed).
Never stops, starts or reconfigures the service: the last steps print for the coordinator. -Apply refuses while a client runs a
statement on the donor (-Force: ignore).
Exit codes: 0 ok · 1 refused or failed.
Sections: L44 names · L51 ini and config edit · L147 rename · L250 checks · L300 apply · L363 search data
#>
param([string[]]$Targets, [int]$DonorPort, [string]$Lanes, [string]$IniFrom,
  [string]$Bin, [string]$Service, [int]$VerifyPort,
  [string]$ConfigFile, [string]$AdminSchema, [string]$RegistryTable, [string]$PoolTable, [string[]]$Only, [switch]$Config, [string]$Runtime, [string]$PokeyFile, [switch]$Rename, [switch]$Rollback, [string[]]$Birds, [ValidateSet('bird', 'nn')][string]$Ids = 'bird', [switch]$Apply, [switch]$Replace, [switch]$Force)
$ErrorActionPreference = 'Stop'
$SysDrive = if ($env:SystemDrive) { [regex]::Escape($env:SystemDrive) } else { '(?!)' }   # search data moves off it (none on POSIX)
$KitDir = Split-Path (Split-Path $PSScriptRoot)
if (-not $Lanes) { $Lanes = Join-Path $KitDir '.state/localenv/lanes' }
$Lanes = $Lanes.Replace('\', '/').TrimEnd('/')
if (-not $IniFrom) { $IniFrom = @(Get-ChildItem $Lanes -Filter 'mysql-*.ini' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1 -ExpandProperty FullName)[0] }
if (-not $Runtime) { $Runtime = Join-Path $KitDir '.runtime' }
if (-not $PokeyFile) { $PokeyFile = Join-Path $KitDir 'skills/pokey/targets.local.json' }
if (-not $ConfigFile) { $ConfigFile = Join-Path $KitDir 'skills/crafty/kit.local.json' }
# org values: args, else localEnv.baseMove (no built-in product, port or service)
$bm = try { (Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50)['localEnv']['baseMove'] } catch { $null }
if ($bm) {
  if (-not $Targets) { $Targets = @($bm['targets'] | Where-Object { $_ }) }
  foreach ($bmKey in 'DonorPort', 'VerifyPort', 'Bin', 'Service', 'AdminSchema', 'RegistryTable', 'PoolTable') { $bmVal = $bm[$bmKey.Substring(0, 1).ToLower() + $bmKey.Substring(1)]; if (-not (Get-Variable $bmKey -ValueOnly) -and $bmVal) { Set-Variable $bmKey ([string]$bmVal) } }
}
$Targets = @($Targets | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $Bin -and ($mysqldCmd = Get-Command mysqld -ErrorAction SilentlyContinue)) { $Bin = Split-Path $mysqldCmd.Source }

# ---- names: the bird of a lane number
if (-not $Birds) {
  $Birds = try { @((Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50)['pool']['names']) } catch { @() }
  if (-not $Birds -or -not $Birds[0]) { $Birds = @('Falcon', 'Kestrel', 'Osprey', 'Heron', 'Merlin', 'Harrier', 'Kite', 'Swift') }
}
function Get-Bird([int]$N) { if ($N -ge 1 -and $N -le @($Birds).Count) { "$(@($Birds)[$N - 1])".ToLower() } else { "bird$N" } }

# ---- ini and config edit: a lane ini from a template, the kit.local.json edit
# a lane ini made from a template: the port lines and datadir changed, the low-write settings forced under [mysqld], every other line kept
function New-BaseIni([string[]]$Template, [int]$Port, [string]$Dir) {
  # redo: mysqld 8.0.30+ rewrites its whole capacity at every start (start: 64M 80 MB, 128M 142, 256M 266; a tenant restore only -1..-4%)
  # a tenant restore (drop + create ~830 tables) measured 2026-11-20: 521 MB; file_per_table OFF 272 (no per-table file init; ibdata1 +31 MB
  # once, reused, never shrinks); adaptive flushing OFF + io_capacity 100 / 200: -5%; both 253; trx_commit 0, dirty pct, lru depth, binlog: noise
  # file_per_table OFF: new and rebuilt (ALTER) tables land in ibdata1, reclaimed only by a lane re-init; partitioned / compressed tables refused (none today)
  # the binlog stays as the template has it: envy marks and restores read it (db-presets.ps1: log_bin OFF = no marks); the load runs without it
  # binlog_row_metadata FULL: the donor's SET PERSIST (mysqld-auto.cnf) stays behind; envy restores by column name need it
  $force = @('innodb_doublewrite=OFF', 'innodb_flush_log_at_trx_commit=2', 'general_log=0', 'slow_query_log=0', 'innodb_redo_log_capacity=64M', 'binlog_row_metadata=FULL', 'innodb_file_per_table=OFF', 'innodb_adaptive_flushing=OFF', 'innodb_io_capacity=100', 'innodb_io_capacity_max=200')
  $drop = '^\s*(innodb[-_]doublewrite|innodb[-_]flush[-_]log[-_]at[-_]trx[-_]commit|innodb[-_]redo[-_]log[-_]capacity|general[-_]log|slow[-_]query[-_]log|binlog[-_]row[-_]metadata|innodb[-_]file[-_]per[-_]table|innodb[-_]adaptive[-_]flushing|innodb[-_]io[-_]capacity(?:[-_]max)?)\s*(=|$)'
  @(foreach ($l in $Template) {
    if ($l -match '^\s*port\s*=') { "port=$Port" } elseif ($l -match '^\s*datadir\s*=') { "datadir=$Dir" } elseif ($l -match $drop) { continue } else { $l }
    if ($l -match '^\s*\[mysqld\]\s*$') { $force }
  })
}
# the kit.local.json edit (hashtables, key order kept): each target env runs its own managed mysql (the lane templates with an empty
# {lane}) and its search data and logs move off the system drive; its lanes clone from it
function Copy-Deep($Obj) { $Obj | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
function Update-BaseMoveConfig($Cfg, [string[]]$Spec, [int]$Donor, [string]$LanesDir = '') {
  $envs = $Cfg['localEnv']['envs']; $tpl = $null
  foreach ($n in @($envs.Keys)) { foreach ($s in @($envs[$n]['services'])) { if (-not $tpl -and $s -and $s['name'] -eq 'mysql' -and $s['start'] -and $s['init']) { $tpl = Copy-Deep $s } } }
  if (-not $tpl) { throw 'no lane mysql service (start + init) in localEnv.envs to copy: nothing to base this on' }
  $tpl['init']['cmd'] = ([string]$tpl['init']['cmd']) -replace ' -DonorPort \d+', ''
  $changed = @()
  foreach ($t in $Spec) {
    $en, $pt = $t -split ':'; $e = $envs[$en]; if (-not $e) { throw "env '$en' is not in localEnv.envs" }
    $svc = Copy-Deep $tpl; $svc['port'] = [int]$pt; $svc['external'] = $false
    $svc['start'] = [regex]::Replace([string]$svc['start'], 'mysql-[a-z]+(?:-\{bird\}|\{lane\})', "mysql-$en-{bird}")
    $svc['init']['cmd'] = ([regex]::Replace([string]$svc['init']['cmd'], 'mysql-[a-z]+(?:-\{bird\}|\{lane\})', "mysql-$en-{bird}")).Replace('-Port {port}', "-Port {port} -DonorPort $Donor")
    $svc['init']['creates'] = [regex]::Replace([string]$svc['init']['creates'], 'mysql-[a-z]+(?:-\{bird\}|\{lane\})', "mysql-$en-{bird}")
    if (-not ([string]$svc['start']).Contains("mysql-$en-{bird}")) { throw "the template mysql service has no 'mysql-<product>{lane}' in its start: edit the template lane first" }
    $e['services'] = @($svc) + @($e['services'] | Where-Object { $_ -and $_['name'] -ne 'mysql' })
    if (-not $e['db']) { $e['db'] = [ordered]@{} }
    $e['db']['port'] = [int]$pt
    if (-not $e['db']['expect']) { $e['db']['expect'] = [ordered]@{} }
    $e['db']['expect']['innodb_buffer_pool_size'] = '1G'
    foreach ($ln in @($envs.Keys | Where-Object { $_ -match "^$en\d+$" })) { foreach ($ls in @($envs[$ln]['services'])) { if ($ls -and $ls['init'] -and $ls['init']['cmd'] -and $ls['init']['cmd'] -notmatch '-DonorPort') { $ls['init']['cmd'] = ([string]$ls['init']['cmd']).Replace('-Port {port}', "-Port {port} -DonorPort $pt") } } }   # a new lane of this env clones from its base server
    $sr = @($e['services'] | Where-Object { $_['name'] -eq 'search' -and $_['start'] })[0]
    if ($LanesDir -and $sr -and [string]$sr['start'] -match "(?i)-Epath\.(data|logs)=$SysDrive") {
      $sr['start'] = [regex]::Replace([string]$sr['start'], "(?i)-Epath\.data=$SysDrive[^ ]+", "-Epath.data=$LanesDir/search-$en-{bird}/data")
      $sr['start'] = [regex]::Replace([string]$sr['start'], "(?i)-Epath\.logs=$SysDrive[^ ]+", "-Epath.logs=$LanesDir/search-$en-{bird}/logs")
      $changed += "envs.$en.services[search] data + logs -> $LanesDir/search-$en-{bird}/"
    }
    $changed += "envs.$en.services[mysql] port $pt managed (init: clone from :$Donor; its lanes from :$pt), envs.$en.db.port $pt, db.expect pool 1G"
  }
  foreach ($n in @($envs.Keys)) {
    foreach ($s in @($envs[$n]['services'])) {
      if (-not $s -or $s['name'] -ne 'mysql') { continue }
      $before = ($s | ConvertTo-Json -Depth 10 -Compress)
      foreach ($k in 'start') { if ($s[$k]) { $s[$k] = [regex]::Replace([string]$s[$k], 'mysql-([a-z]+)\{lane\}', 'mysql-$1-{bird}') } }
      if ($s['init']) { foreach ($k in 'cmd', 'creates') { if ($s['init'][$k]) { $s['init'][$k] = [regex]::Replace([string]$s['init'][$k], 'mysql-([a-z]+)\{lane\}', 'mysql-$1-{bird}') } } }
      if (($s | ConvertTo-Json -Depth 10 -Compress) -ne $before) { $changed += "envs.$n.services[mysql] names -> bird ({bird} in the lane templates)" }
    }
  }
  # the disk guard sizes only storage.watch paths (envy doctor: "storage.watch lacks the db datadir")
  if ($LanesDir) {
    if (-not $Cfg['storage']) { $Cfg['storage'] = [ordered]@{} }
    $watch = @($Cfg['storage']['watch'] | Where-Object { $_ }); $lanesNorm = $LanesDir.Replace('\', '/').TrimEnd('/')
    if (-not @($watch | Where-Object { ($lanesNorm + '/').StartsWith("$_".Replace('\', '/').TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase) }).Count) { $Cfg['storage']['watch'] = @($watch) + $lanesNorm; $changed += "storage.watch + $lanesNorm (the lane datadirs)" }
  }
  $Cfg['localEnv']['laneIds'] = 'bird'   # lane ids <product>-<bird>; the old <product><k> keys become the new ids, the old ids stay accepted aliases
  $renamed = [ordered]@{}
  foreach ($n in @($envs.Keys)) {
    if ($n -match '^(?<b>.+?)(?<k>\d+)$' -and $envs.Contains($Matches.b)) { $nn = "$($Matches.b)-$(Get-Bird ([int]$Matches.k))"; $renamed[$nn] = $envs[$n]; $changed += "envs.$n -> envs.$nn (localEnv.laneIds bird)" } else { $renamed[$n] = $envs[$n] }
  }
  $Cfg['localEnv']['envs'] = $renamed
  $changed
}
function Test-Listen([int]$Port) {
  $c = [Net.Sockets.TcpClient]::new()
  try { $c.ConnectAsync('127.0.0.1', $Port).Wait(1500) -and $c.Connected } catch { $false } finally { $c.Dispose() }
}

$exe = if ($IsWindows) { '.exe' } else { '' }
$mysql, $mysqld, $mysqldump = foreach ($tool in "mysql$exe", "mysqld$exe", "mysqldump$exe") { if ($Bin) { Join-Path $Bin $tool } else { $tool } }
function Invoke-Sql([int]$P, [string]$Q, [switch]$Raw) { $o = & $mysql -h 127.0.0.1 -P $P -u root -N -B $(if ($Raw) { '-r' }) -e $Q 2>&1; if ($LASTEXITCODE) { throw "mysql :${P}: $o" }; @($o) }
$bad = [System.Collections.Generic.List[string]]::new(); $info = [System.Collections.Generic.List[string]]::new()
function Show-Plan($Rows) { $Rows | ForEach-Object { "  $_" } }
# MB a process and its children wrote (mysqld on Windows runs the server in a child of its monitor process)
function Get-TreeWriteMb([int]$Id) { if (-not $IsWindows) { return 0 }; [math]::Round((@(Get-CimInstance Win32_Process -Filter "ProcessId=$Id OR ParentProcessId=$Id") | Measure-Object WriteTransferCount -Sum).Sum / 1MB) }

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

if ($Config) {
  $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50
  if (-not $Targets) { 'REFUSED: no targets: pass -Targets <env>:<port>,... or set localEnv.baseMove.targets'; exit 1 }
  if (-not $DonorPort) { 'REFUSED: no donor port: pass -DonorPort <port> or set localEnv.baseMove.donorPort'; exit 1 }
  $ch = Update-BaseMoveConfig $cfg $Targets $DonorPort $Lanes
  $ch | ForEach-Object { "config: $_" }
  if ($Apply) { $bakF = "$ConfigFile.bak"   # owner 2026-11-24: <file>.bak (latest) + .bak.prev, no counter or date
    if (Test-Path -LiteralPath $bakF) { Move-Item -LiteralPath $bakF "$bakF.prev" -Force }
    Copy-Item -LiteralPath $ConfigFile $bakF; ($cfg | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $ConfigFile -Encoding utf8; "written: $ConfigFile" } else { 'dry run: -Config -Apply writes it' }
  exit 0
}

# ---- rename: every lane-scoped name on disk to <product>-<bird> (services and loops down); the journal feeds -Rollback
# mysql dirs + inis (inis rewritten), envy state / log / run / tmp / slices names, a lane's own <id>.env; lease keys and config ids stay
function Get-LaneIds($Envs) {
  foreach ($n in @($Envs.Keys)) {
    if ($n -match '^(\D+)(\d+)$' -and $Envs.Contains($Matches[1])) { continue }
    $max = 1; if ($Envs[$n]['lanes'] -and $Envs[$n]['lanes']['max']) { $max = [int]$Envs[$n]['lanes']['max'] }
    $n; for ($k = 2; $k -le $max; $k++) { "$n$k" }
  }
}
function Get-LaneSlug([string]$Id) { if ($Id -match "-($(@($Birds) -join '|'))$") { return $Id }; if ($Id -match '^(\D+)(\d*)$') { "$($Matches[1])-$(Get-Bird $(if ($Matches[2]) { [int]$Matches[2] } else { 1 }))" } else { $Id } }
# -Ids nn: the rule of wt-pool.ps1 Get-KitLaneMap (tests/mysql-base-move compares both): lane k of the i-th base env = lane-<10i+k> (one env: k)
function Get-NnPairs($Envs) {
  $all = @($Envs.Keys); $bn = @(1..40 | ForEach-Object { Get-Bird $_ })
  $base = @($all | Where-Object { -not (($_ -match '^(?<b>.+?)\d+$' -and $Matches.b -in $all) -or ($_ -match '^(?<b>.+)-(?<d>[a-z]+)$' -and $Matches.d -in $bn -and $Matches.b -in $all) -or $_ -match '^lane-\d{2,}$') })
  for ($i = 0; $i -lt $base.Count; $i++) { $e = $base[$i]; $max = 1; if ($Envs[$e]['lanes'] -and $Envs[$e]['lanes']['max']) { $max = [int]$Envs[$e]['lanes']['max'] }
    for ($k = 1; $k -le $max; $k++) { [pscustomobject]@{ id = 'lane-{0:d2}' -f ($(if ($base.Count -gt 1) { 10 * $i } else { 0 }) + $k); k = $k; old = $(if ($k -gt 1) { "$e$k" } else { $e }); bird = "$e-$(Get-Bird $k)" } } }
}
if ($Rename -or $Rollback) {
  $jf = "$Lanes/rename-journal.json"; $bak = "$Lanes/rename-backup"
  $stateDir = Split-Path $Lanes; $wd = "$Runtime/work/localenv"; $ld = "$Runtime/logs/localenv"
  if ($Rollback) {
    if (-not (Test-Path -LiteralPath $jf)) { 'no journal: nothing to roll back'; exit 1 }
    $j = Get-Content -LiteralPath $jf -Raw | ConvertFrom-Json -AsHashtable
    foreach ($jb in @($j['pokey'], $j['config'] | Where-Object { $_ -and (Test-Path -LiteralPath $_['backup']) })) { Copy-Item -LiteralPath $jb['backup'] $jb['file'] -Force; "back: $($jb['file'])" }
    foreach ($m in @($j['moves'])) { if (Test-Path -LiteralPath $m['to']) { Move-Item -LiteralPath $m['to'] $m['from'] }; "back: $($m['to']) -> $($m['from'])" }
    foreach ($m in @($j['mysql'])) {
      if (Test-Path -LiteralPath $m['newDir']) { Move-Item -LiteralPath $m['newDir'] $m['oldDir'] }
      if (Test-Path -LiteralPath $m['iniBackup']) { Copy-Item -LiteralPath $m['iniBackup'] $m['oldIni'] -Force }
      if (Test-Path -LiteralPath $m['newIni']) { Remove-Item -LiteralPath $m['newIni'] -Force }
      $rd = "$($m['oldDir'])/lane-ready.txt"; if (Test-Path -LiteralPath $rd) { (Get-Content -LiteralPath $rd -Raw).Replace($m['newDir'], $m['oldDir']).Replace($m['newIni'], $m['oldIni']) | Set-Content -LiteralPath $rd -NoNewline }
      "back: $($m['newDir']) -> $($m['oldDir'])"
    }
    Remove-Item -LiteralPath $jf -Force; 'rollback done: restore kit.local.json from its .bak too'; exit 0
  }
  $cfgR = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50; $envsR = $cfgR['localEnv']['envs']; $mysqlMoves = @(); $moves = @(); $badR = @()
  $nnRows = @(if ($Ids -eq 'nn') { Get-NnPairs $envsR }); $fromBird = "$($cfgR['localEnv']['laneIds'])" -eq 'bird'   # nn: from today's ids (bird or old)
  $renames = if ($Ids -eq 'nn') { @($nnRows | ForEach-Object { [pscustomobject]@{ id = $(if ($fromBird) { $_.bird } else { $_.old }); slug = $_.id; k = $_.k } }) }
    else { @(Get-LaneIds $envsR | ForEach-Object { [pscustomobject]@{ id = $_; slug = (Get-LaneSlug $_); k = $(if ($_ -match '(\d+)$') { [int]$Matches[1] } else { 1 }) } }) }
  foreach ($rn in $renames) {
    $id = $rn.id; $slug = $rn.slug; $k = $rn.k; if ($slug -eq $id) { continue }
    # envy's own state, logs, run dirs, cmd launchers, tmp, slices, and a lane's own env file
    $sj = "$wd/$id.json"
    if (Test-Path -LiteralPath $sj) { $lp = try { (Get-Content -LiteralPath $sj -Raw | ConvertFrom-Json).loop.pid } catch { $null }; if ($lp -and (Get-Process -Id ([int]$lp) -ErrorAction SilentlyContinue)) { $badR += "${id}: its envy loop (pid $lp) is running: envy down -Env $id" } }
    foreach ($pair in @(@("$wd/$id.json", "$wd/$slug.json"), @("$wd/$id.json.lock", "$wd/$slug.json.lock"), @("$wd/run/$id", "$wd/run/$slug"), @("$wd/slices/$id", "$wd/slices/$slug"), @("$stateDir/$id.env", "$stateDir/$slug.env"))) {
      if ($pair[0] -match '\.env$' -and $k -eq 1) { continue }   # the base lane's <product>.env is shared by its lanes
      if (Test-Path -LiteralPath $pair[0]) { if (Test-Path -LiteralPath $pair[1]) { $badR += "$($pair[1]) exists" } else { $moves += @{ from = $pair[0]; to = $pair[1] } } }
    }
    foreach ($dirName in @("$wd/run", $ld, "$wd/tmp")) {
      foreach ($f in @(Get-ChildItem -LiteralPath $dirName -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith("$id-") })) {
        $to = "$dirName/$slug-$($f.Name.Substring($id.Length + 1))"
        if (Test-Path -LiteralPath $to) { $badR += "$to exists" } else { $moves += @{ from = "$dirName/$($f.Name)"; to = $to } }
      }
    }
    # the lane's mysql server
    $ms = if ($envsR[$id] -and $Ids -ne 'nn') { @($envsR[$id]['services'] | Where-Object { $_ -and $_['name'] -eq 'mysql' -and $_['start'] })[0] }   # after -Config -Apply: lane keys are bird names
    $old = "$Lanes/mysql-$id"; $new = "$Lanes/mysql-$slug"
    if ($ms -and (Test-Path -LiteralPath $old)) {
      if ((Test-Path -LiteralPath $new) -or (Test-Path -LiteralPath "$new.ini")) { $badR += "$new exists" }
      else {
        if ($ms['port'] -and (Test-Listen ([int]$ms['port']))) { $badR += "$id mysql :$($ms['port']) is up: envy down -Env $id" }
        if ($IsWindows -and @(Get-CimInstance Win32_Process -Filter "Name='mysqld.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".Replace('\', '/') -like "*$old*" }).Count) { $badR += "$id has a mysqld running on $old" }
        $mysqlMoves += @{ env = $id; oldDir = $old; newDir = $new; oldIni = "$old.ini"; newIni = "$new.ini"; iniBackup = "$bak/mysql-$id.ini" }
      }
    }
  }
  # pokey targets: an explicit lane key (local-docs2) -> <base>-<bird> (the derived <target><k> names need no key; pokey accepts the old ones)
  $tgKeys = @(); $pk = $null
  if (Test-Path -LiteralPath $PokeyFile) {
    $pk = Get-Content -LiteralPath $PokeyFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    foreach ($n in @($pk['targets'].Keys)) { if ($n -match '^(?<b>.+?)(?<k>\d+)$' -and $pk['targets'].Contains($Matches.b)) { $tgKeys += @{ from = $n; to = "$($Matches.b)-$(Get-Bird ([int]$Matches.k))" } } }
  }
  $keyMoves = @(foreach ($r in @($nnRows | Where-Object { $_.k -gt 1 })) { foreach ($ok in @($r.bird, $r.old)) { if ($envsR.Contains($ok) -and -not $envsR.Contains($r.id)) { @{ from = $ok; to = $r.id }; break } } })
  'rename plan:'; Show-Plan (@(if ($nnRows.Count) { "${ConfigFile}: localEnv.laneIds nn$(@($keyMoves | ForEach-Object { ", envs.$($_['from']) -> envs.$($_['to'])" }) -join '')" }) + @($tgKeys | ForEach-Object { "${PokeyFile}: target $($_['from']) -> $($_['to'])" }) + @($mysqlMoves | ForEach-Object { "$($_['oldDir']) -> $($_['newDir']) (+ ini rewritten, lane-ready.txt)" }) + @($moves | ForEach-Object { "$($_['from']) -> $($_['to'])" }))
  if ($badR.Count) { 'REFUSED:'; Show-Plan $badR; if ($Apply) { exit 1 } }
  if ($Apply -and ($moves.Count -or $mysqlMoves.Count -or $tgKeys.Count -or $nnRows.Count)) {
    New-Item -ItemType Directory -Force $bak | Out-Null; $cj = $null; $pj = $null
    # backups and the journal before the first change: a failed step leaves -Rollback all it needs (it undoes only what happened)
    if ($nnRows.Count) { Copy-Item -LiteralPath $ConfigFile "$bak/kit.local.json" -Force; $cj = @{ file = $ConfigFile; backup = "$bak/kit.local.json" } }
    if ($tgKeys.Count) { Copy-Item -LiteralPath $PokeyFile "$bak/targets.local.json" -Force; $pj = @{ file = $PokeyFile; backup = "$bak/targets.local.json" } }
    [ordered]@{ moves = $moves; mysql = $mysqlMoves; pokey = $pj; config = $cj } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jf -Encoding utf8
    foreach ($m in $moves) { Move-Item -LiteralPath $m['from'] $m['to'] }
    foreach ($m in $mysqlMoves) {
      Move-Item -LiteralPath $m['oldDir'] $m['newDir']
      if (Test-Path -LiteralPath $m['oldIni']) {
        Copy-Item -LiteralPath $m['oldIni'] $m['iniBackup'] -Force
        (Get-Content -LiteralPath $m['oldIni'] -Raw).Replace($m['oldDir'], $m['newDir']).Replace($m['oldDir'].Replace('/', '\'), $m['newDir'].Replace('/', '\')) | Set-Content -LiteralPath $m['newIni'] -Encoding ascii -NoNewline
        Remove-Item -LiteralPath $m['oldIni'] -Force
      }
      $rd = "$($m['newDir'])/lane-ready.txt"; if (Test-Path -LiteralPath $rd) { (Get-Content -LiteralPath $rd -Raw).Replace($m['oldDir'], $m['newDir']).Replace($m['oldIni'], $m['newIni']) | Set-Content -LiteralPath $rd -NoNewline }
    }
    if ($tgKeys.Count) {
      $nt = [ordered]@{}; foreach ($n in @($pk['targets'].Keys)) { $hit = @($tgKeys | Where-Object { $_['from'] -eq $n })[0]; $nt[$(if ($hit) { $hit['to'] } else { $n })] = $pk['targets'][$n] }
      $pk['targets'] = $nt; $pk | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $PokeyFile -Encoding utf8
    }
    if ($nnRows.Count) {   # the config last: the ids, then the keys envy reads them by
      $ne = [ordered]@{}; foreach ($n in @($envsR.Keys)) { $hit = @($keyMoves | Where-Object { $_['from'] -eq $n })[0]; $ne[$(if ($hit) { $hit['to'] } else { $n })] = $envsR[$n] }
      $cfgR['localEnv']['envs'] = $ne; $cfgR['localEnv']['laneIds'] = 'nn'; $cfgR | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigFile -Encoding utf8
    }
    "renamed $($moves.Count) file(s)/dir(s) and $($mysqlMoves.Count) mysql lane(s); journal $jf (-Rollback undoes it)"
  } elseif (-not $Apply) { 'dry run: -Rename -Apply moves them' }
  exit 0
}

# ---- checks: binaries, targets, ports, donor, space, schemas per product
if (-not $Bin) { $bad.Add('no MySQL bin folder: pass -Bin or set localEnv.baseMove.bin (mysqld is not on PATH)') } else { foreach ($f in $mysql, $mysqld, $mysqldump) { if (-not (Test-Path -LiteralPath $f)) { $bad.Add("missing $f") } } }
if (-not $Targets) { $bad.Add('no targets: pass -Targets <env>:<port>,... or set localEnv.baseMove.targets') }
if (-not $DonorPort -or -not $VerifyPort) { $bad.Add('no donor / verify port: pass -DonorPort and -VerifyPort or set localEnv.baseMove.donorPort / verifyPort') }
if (-not $AdminSchema -or -not $RegistryTable) { $bad.Add('no kept-schema source: pass -AdminSchema <name, {env} = the env> and -RegistryTable <its table of schema names> or set localEnv.baseMove') }
if (-not $IniFrom -or -not (Test-Path -LiteralPath $IniFrom)) { $bad.Add("no template ini: pass -IniFrom <a lane ini>") }
$plan = @(foreach ($t in $Targets) {
  if ($t -notmatch '^(\w+):(\d+)$') { $bad.Add("target '$t': use <env>:<port>"); continue }
  $en = $Matches[1]; $pt = [int]$Matches[2]; $dir = "$Lanes/mysql-$en-$(Get-Bird 1)"
  if (Test-Path -LiteralPath $dir) { if (-not $Replace) { $bad.Add("$dir exists: -Replace removes it (only with its lane-ready.txt or $dir.base-move.txt marker)") } elseif (-not (Test-Path -LiteralPath "$dir/lane-ready.txt") -and -not (Test-Path -LiteralPath "$dir.base-move.txt")) { $bad.Add("$dir exists without lane-ready.txt: remove it by hand") } }
  if ($pt -ne $DonorPort -and (Test-Listen $pt)) { $bad.Add("port $pt is in use") }
  [pscustomobject]@{ env = $en; port = $pt; dir = $dir; ini = "$dir.ini"; keep = @(); admin = ''; mb = 0 }
})
if ($Only -and -not $PSBoundParameters.ContainsKey('Lanes')) { $bad.Add('-Only is a trial: pass a scratch -Lanes (a partial copy must never look like a base)') }
if (@($plan.port | Select-Object -Unique).Count -ne @($plan).Count) { $bad.Add('two targets share a port') }
if ($VerifyPort -and ($VerifyPort -eq $DonorPort -or $VerifyPort -in @($plan.port))) { $bad.Add("-VerifyPort $VerifyPort is the donor's or a target's port") }
if ($VerifyPort -and (Test-Listen $VerifyPort)) { $bad.Add("-VerifyPort $VerifyPort is in use: the copy loads on it") }
if ($Service) { $svc = Get-Service $Service -ErrorAction SilentlyContinue
  $info.Add("service $Service : $(if ($svc) { "$($svc.Status), start $($svc.StartType)" } else { 'not found' })") } else { $info.Add('service: none named (-Service or localEnv.baseMove.service)') }
$donorUp = $DonorPort -and (Test-Listen $DonorPort)
if ($env:MYSQL_PWD -and $donorUp -and $AdminSchema -and $RegistryTable) {
  try {
    $sizes = @{}; foreach ($r in @(Invoke-Sql $DonorPort "SELECT table_schema, ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables GROUP BY table_schema")) { $k, $v = $r -split "`t"; $sizes[$k] = [double]$v }
    $busy = @(Invoke-Sql $DonorPort "SELECT COUNT(*) FROM information_schema.processlist WHERE command NOT IN ('Sleep','Daemon') AND id <> CONNECTION_ID()")[0]
    $sleep = @(Invoke-Sql $DonorPort "SELECT COUNT(*) FROM information_schema.processlist WHERE command = 'Sleep'")[0]
    $sys = "'information_schema','performance_schema','mysql','sys','kit_journal'"
    foreach ($p in $plan) {
      $adm = $AdminSchema.Replace('{env}', $p.env); $p.admin = $adm; $p.keep = @($adm) + @(Invoke-Sql $DonorPort "SELECT name FROM ``$adm``.``$RegistryTable``") + 'kit_journal'
      if ($Only) { $p.keep = @($p.keep | Where-Object { $_ -in $Only }) }
      $gone = @($p.keep | Where-Object { -not $sizes.ContainsKey($_) })
      if (-not $p.keep.Count -or $gone.Count) { $bad.Add("$($p.env): $(if ($gone.Count) { "kept schemas missing (or without tables) on the donor: $($gone -join ', ')" } else { 'nothing to keep (-Only matches none of its schemas)' })") }
      $p.mb =[double](($p.keep | ForEach-Object { $sizes[$_] } | Measure-Object -Sum).Sum)
    }
    # need: the kept data once, its redo (innodb_redo_log_capacity, 512M) and the empty server (~200 MB) per target
    $need = [int](@($plan | ForEach-Object { $_.mb * 1.3 + 800 } | Measure-Object -Sum).Sum)
    $free = [math]::Round((Get-PSDrive ([string]$Lanes[0])).Free / 1MB)
    $info.Add("donor :$DonorPort clients: $busy running, $sleep idle; $(([string]$Lanes[0])): free $free MB, need $need MB")
    if ($free -lt $need) { $bad.Add('not enough free space for the copies') }
    $all = @(Invoke-Sql $DonorPort "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($sys)")
    $orphan = @($all | Where-Object { $_ -notin @($plan.keep) })
    foreach ($p in $plan) { $info.Add("$($p.env) keeps: $($p.keep -join ', ') ($($p.mb) MB data + index)") }
    if ($orphan.Count -and -not $Only) { $bad.Add("schemas of no target (would be left on the service only): $($orphan -join ', ')") }
    if ($Apply -and [int]$busy -gt 0 -and -not $Force) { $bad.Add("$busy statements running on :${DonorPort}: stop the envs first (envy down), or -Force") }
  } catch { $bad.Add("donor: $($_.Exception.Message)") }
} else { $info.Add("donor :$DonorPort not checked ($(if (-not $env:MYSQL_PWD) { 'MYSQL_PWD unset' } else { 'not listening' }))"); if ($Apply) { $bad.Add('-Apply needs MYSQL_PWD and the donor up') } }

"plan:"; Show-Plan ($plan | ForEach-Object { "$($_.env): copy its schemas :$DonorPort -> $($_.dir) (empty datadir + mysqldump), ini $($_.ini), port $($_.port)$(if ($_.port -ne $DonorPort -and $PoolTable) { ", $("$AdminSchema".Replace('{env}', $_.env)).$PoolTable -> :$($_.port)" })" })
"checks:"; Show-Plan $info
if ($bad.Count) { "REFUSED:"; Show-Plan $bad; if ($Apply) { exit 1 } }

# ---- apply: an empty datadir with the lane ini, the donor's accounts, only the kept schemas (mysqldump | mysql), verify, point the pool
if ($Apply) {
  if ($bad.Count) { exit 1 }
  $tmpl = @(Get-Content -LiteralPath $IniFrom)
  $hide = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }
  $want = Invoke-Sql $DonorPort "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') GROUP BY table_schema ORDER BY 1"
  # the donor's accounts as statements (auth as hex hashes, never a password): the copy answers the same logins and trigger definers
  $acct = [System.Collections.Generic.List[string]]::new()
  foreach ($u in @(Invoke-Sql $DonorPort "SELECT CONCAT(QUOTE(user), '@', QUOTE(host)) FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema')" -Raw)) {
    $acct.Add("CREATE USER IF NOT EXISTS $u;"); $acct.Add((@(Invoke-Sql $DonorPort "SET SESSION print_identified_with_as_hex = ON; SHOW CREATE USER $u" -Raw)[0] -replace '^CREATE USER', 'ALTER USER') + ';')
    foreach ($g in @(Invoke-Sql $DonorPort "SHOW GRANTS FOR $u" -Raw)) { $acct.Add("$g;") }
  }
  foreach ($p in $plan) {
    if (Test-Path -LiteralPath $p.dir) { Remove-Item -LiteralPath $p.dir -Recurse -Force }
    # until lane-ready.txt: a half copy that -Replace may remove (envy never starts it: it waits for lane-ready.txt)
    Set-Content -LiteralPath "$($p.dir).base-move.txt" "started $(Get-Date -Format o)"
    Set-Content -LiteralPath $p.ini (New-BaseIni $tmpl $p.port $p.dir) -Encoding ascii
    $t0 = Get-Date; "$($p.env): empty datadir $($p.dir)"
    $ip = Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$($p.ini)`"", '--initialize-insecure', '--innodb-redo-log-capacity=8M' -PassThru @hide   # the ini's redo files come once, at the load start (not twice)
    $initMb = 0; $until = (Get-Date).AddMinutes(10)
    while (-not $ip.HasExited -and (Get-Date) -lt $until) { $initMb = [math]::Max($initMb, (Get-TreeWriteMb $ip.Id)); Start-Sleep -Milliseconds 500 }
    if (-not $ip.HasExited) { $ip.Kill(); throw "mysqld --initialize-insecure hung for $($p.env) (see $($p.dir)/lane.err)" }
    if ($ip.ExitCode) { throw "mysqld --initialize-insecure failed for $($p.env) (exit $($ip.ExitCode), see $($p.dir)/lane.err)" }
    # start on the verify port (the final one may be the donor's) with the load settings, copy, compare, point the pool, stop
    $pr = Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$($p.ini)`"", "--port=$VerifyPort", '--sql-mode=NO_ENGINE_SUBSTITUTION', '--innodb-flush-log-at-trx-commit=0', '--skip-log-bin', '--innodb-file-per-table=ON' -PassThru @hide   # the kept data in own files (droppable); later tables go to ibdata1
    try {
      $until = (Get-Date).AddMinutes(5)
      while (-not (Test-Listen $VerifyPort)) { if ($pr.HasExited -or (Get-Date) -gt $until) { throw "mysqld did not start for $($p.env) (see $($p.dir)/lane.err)" }; Start-Sleep 2 }
      $pwKeep = $env:MYSQL_PWD; $env:MYSQL_PWD = $null   # the new root has no password until the donor's accounts land
      try {
        $dd = ("$(Invoke-Sql $VerifyPort 'SELECT @@datadir')" -replace '\\', '/' -replace '/+', '/').TrimEnd('/')   # the client prints backslashes doubled
        if ($dd -ne ($p.dir -replace '\\', '/' -replace '/+', '/').TrimEnd('/')) { throw "port $VerifyPort serves $dd, not the new $($p.dir): nothing loaded" }
        $o = ($acct -join "`n") | & $mysql -h 127.0.0.1 -P $VerifyPort -u root 2>&1; if ($LASTEXITCODE) { throw "$($p.env): accounts: $("$o" -replace '0x[0-9A-Fa-f]+', '0x<hash>')" }
      } finally { $env:MYSQL_PWD = $pwKeep }
      $dumpErr = "$($p.dir).dump.err"
      foreach ($s in @($p.keep | Where-Object { $_ -in @($want | ForEach-Object { ($_ -split "`t")[0] }) })) {
        & $mysqldump -h 127.0.0.1 -P $DonorPort -u root --single-transaction --no-tablespaces --routines --triggers --events --hex-blob --set-gtid-purged=OFF --databases $s 2>$dumpErr |
          & $mysql -h 127.0.0.1 -P $VerifyPort -u root '--init-command=SET unique_checks=0, foreign_key_checks=0, sql_log_bin=0'
        # $LASTEXITCODE is the load side's; a dump that died mid-way shows in its stderr
        if ($LASTEXITCODE -or (Get-Item -LiteralPath $dumpErr).Length) { throw "$($p.env): copy of $s failed (load exit $LASTEXITCODE; dump: $(Get-Content -LiteralPath $dumpErr -Raw))" }
        "$($p.env): copied $s"
      }
      $got = Invoke-Sql $VerifyPort "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') GROUP BY table_schema ORDER BY 1"
      $exp = @($want | Where-Object { ($_ -split "`t")[0] -in $p.keep })
      if (($got -join '|') -ne ($exp -join '|')) { throw "$($p.env): table counts differ from the donor:`n donor $($exp -join ', ')`n copy $($got -join ', ')" }
      $sc =$AdminSchema.Replace('{env}', $p.env)
      if ($PoolTable -and $p.port -ne $DonorPort -and "$(Invoke-Sql $VerifyPort "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$sc' AND table_name='$PoolTable'")".Trim() -eq '1') {
        Invoke-Sql $VerifyPort "UPDATE ``$sc``.``$PoolTable`` SET url = REPLACE(url, ':$DonorPort/', ':$($p.port)/') WHERE url LIKE '%:$DonorPort/%'" | Out-Null; "$sc.$PoolTable -> :$($p.port)" }
      "$($p.env): verified $($got.Count) schemas"
    } finally {
      $loadMb = Get-TreeWriteMb $pr.Id
      & (Join-Path $Bin "mysqladmin$exe") -h 127.0.0.1 -P $VerifyPort -u root shutdown 2>&1 | Out-Null
      $until = (Get-Date).AddMinutes(2)
      while (-not $pr.HasExited -and (Get-Date) -lt $until) { $loadMb = [math]::Max($loadMb, (Get-TreeWriteMb $pr.Id)); Start-Sleep -Milliseconds 300 }
      if (-not $pr.HasExited) { $pr.Kill() }
    }
    $dirMb = [math]::Round((Get-ChildItem -LiteralPath $p.dir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
    "$($p.env): written: initialise ~$initMb MB (polled) + load and shutdown ~$loadMb MB (mysqld file I/O); datadir $dirMb MB; $([int]((Get-Date) - $t0).TotalSeconds) s"
    Remove-Item -LiteralPath "$($p.dir).base-move.txt", "$($p.dir).dump.err" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$($p.dir)/lane-ready.txt" "copied $(Get-Date -Format o) from :$DonorPort (mysql-base-move: $($p.keep -join ', ')); port $($p.port); ini $($p.ini)"
  }
}

# ---- search data: off the system drive (the old folders stay as the rollback)
if ($Apply -and -not $Only) {   # copied while that lane's search is down; not in a trial
  $cfgNow = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50
  foreach ($p in $plan) {
    $sr = @($cfgNow['localEnv']['envs'][$p.env]['services'] | Where-Object { $_['name'] -eq 'search' -and $_['start'] })[0]
    if (-not $sr -or [string]$sr['start'] -notmatch "(?i)-Epath\.data=($SysDrive[^ ]+)") { continue }
    $old = $Matches[1]; $sp = $sr['port']
    $lmx = [int](@($(try { $cfgNow['localEnv']['envs'][$p.env]['lanes']['max'] } catch { }), $(try { $cfgNow['localEnv']['defaults']['lanes']['max'] } catch { }), 3) | Where-Object { $_ } | Select-Object -First 1)   # lane 1 = '', lane k = k; unset: 3 as before
    foreach ($k in @('') + @(if ($lmx -ge 2) { 2..$lmx | ForEach-Object { "$_" } })) {
      $from = $old.Replace('{lane}', $k); $to = "$Lanes/search-$($p.env)-$(Get-Bird $(if ($k) { [int]$k } else { 1 }))/data"
      if (-not (Test-Path -LiteralPath $from)) { if ($k -eq '') { "search $($p.env): no data at $from, nothing to copy" }; continue }
      if (Test-Path -LiteralPath $to) { "search $($p.env): $to exists, kept"; continue }
      if ($k -eq '' -and $sp -and (Test-Listen ([int]$sp))) { "search $($p.env) is up: stop it, then re-run for its data"; continue }
      robocopy $from $to /E /NFL /NDL /NJH /NJS /NP | Out-Null; "search data $from -> $to"
    }
  }
}
"switch-over (the coordinator, in this order):"
Show-Plan @(
  "1. envy.ps1 down for every env and lane of $(@($plan.env) -join ', '): every holder released, nothing writes to the service, lane servers stopped",
  "2. pwsh -NoProfile -File mysql-base-move.ps1 -Apply   (copy + verify + search data; marks of :$DonorPort do not carry over)",
  '3. pwsh -NoProfile -File mysql-base-move.ps1 -Rename -Apply   (lane dirs + inis to bird names; -Rename -Rollback undoes it)',
  $(if ($Service) { "4. net stop $Service ; sc config $Service start= demand   (rollback: sc config $Service start= auto ; net start $Service)" } else { '4. stop the OS MySQL service and set it to manual start (none named: -Service)' }),
  '5. pwsh -NoProfile -File mysql-base-move.ps1 -Config -Apply   (kit.local.json; envy resolves {bird}), then envy.ps1 envs / doctor',
  "6. $((@($plan.env) | ForEach-Object { "envy.ps1 up -Env $_ -Services mysql" }) -join ' ; ') ; then seed each (re-marks baseline-<nnnn>)",
  "7. the DB client config: $((@($plan) | ForEach-Object { "$($_.env) port $($_.port)" }) -join ', '); each answers only while its env runs")
exit 0
