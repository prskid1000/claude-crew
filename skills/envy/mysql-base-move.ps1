#Requires -Version 7
<#
mysql-base-move.ps1: moves the base envs' MySQL off the OS MySQL service onto one lane-style mysqld each (own datadir, own low-write
ini, envy starts it on a lease and stops it when idle). Source = the service (CLONE LOCAL, online, binlogs not copied).
  pwsh -NoProfile -File mysql-base-move.ps1                      dry run: checks + the plan + the switch-over steps (changes nothing)
  pwsh -NoProfile -File mysql-base-move.ps1 -Apply [-Replace]    clone, point the db_pool at the new port, verify; MYSQL_PWD from the env file
  pwsh -NoProfile -File mysql-base-move.ps1 -Config [-Apply]     the kit.local.json edit (dry run prints it; -Apply writes, .bak-<date> kept)
  pwsh -NoProfile -File mysql-base-move.ps1 -Rename [-Apply|-Rollback]   every lane-scoped name (mysql dirs + inis, envy state, logs, run dirs, cmd files, lane env files) to <product>-<bird>, everything down; journal kept
Targets `<env>:<port>` (default rm:3305 hm:3316: next to the lane ports 3307 / 3317, never the service's 3306). Each keeps only its product's
schemas (-AdminSchema + the names in its -RegistryTable) and kit_journal (the cascade guard's triggers write it in the same server). Names `<service>-<product>-<bird>` (mysql-rm-falcon, search-hm-kestrel), the bird = the lane number's pool name (`{bird}` in the lane
templates); dir `<Lanes>/mysql-rm-falcon`, ini `<Lanes>/mysql-rm-falcon.ini` (copy of -IniFrom with its port and datadir changed).
Never stops, starts or reconfigures the service: the last steps print for the coordinator. -Apply refuses while a client runs a
statement on the donor (-Force: ignore).
Exit codes: 0 ok · 1 refused or failed.
Sections: L28 names · L35 ini and config edit · L107 rename · L182 checks · L220 apply · L257 search data
#>
param([string[]]$Targets = @('rm:3305', 'hm:3316'), [int]$DonorPort = 3306, [string]$Lanes, [string]$IniFrom,
  [string]$Bin = 'C:/Program Files/MySQL/MySQL Server 8.0/bin', [string]$Service = 'MySQL80', [int]$VerifyPort = 3399,
  [string]$ConfigFile, [string]$AdminSchema = '{env}_admin', [string]$RegistryTable = 'mt_datasource_config', [string]$PoolTable = 'db_pool', [switch]$Config, [string]$Runtime, [switch]$Rename, [switch]$Rollback, [string[]]$Birds, [switch]$Apply, [switch]$Replace, [switch]$Force)
$ErrorActionPreference = 'Stop'
$KitDir = Split-Path (Split-Path $PSScriptRoot)
if (-not $Lanes) { $Lanes = Join-Path $KitDir '.state/localenv/lanes' }
$Lanes = $Lanes.Replace('\', '/').TrimEnd('/')
if (-not $IniFrom) { $IniFrom = @(Get-ChildItem $Lanes -Filter 'mysql-*.ini' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1 -ExpandProperty FullName)[0] }
if (-not $Runtime) { $Runtime = Join-Path $KitDir '.runtime' }
if (-not $ConfigFile) { $ConfigFile = Join-Path $KitDir 'skills/crafty/kit.local.json' }

# ---- names: the bird of a lane number
if (-not $Birds) {
  $Birds = try { @((Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50)['pool']['names']) } catch { @() }
  if (-not $Birds -or -not $Birds[0]) { $Birds = @('Falcon', 'Kestrel', 'Osprey', 'Heron', 'Merlin', 'Harrier', 'Kite', 'Swift') }
}
function Get-Bird([int]$N) { if ($N -ge 1 -and $N -le @($Birds).Count) { "$(@($Birds)[$N - 1])".ToLower() } else { "bird$N" } }

# ---- ini and config edit: a lane ini from a template, the kit.local.json edit
# a lane ini made from a template: the port lines and datadir changed, every other (low-write) setting kept
function New-BaseIni([string[]]$Template, [int]$Port, [string]$Dir) {
  @($Template | ForEach-Object { if ($_ -match '^\s*port\s*=') { "port=$Port" } elseif ($_ -match '^\s*datadir\s*=') { "datadir=$Dir" } else { $_ } })
}
# the kit.local.json edit (hashtables, key order kept): each target env runs its own managed mysql (the lane templates with an empty
# {lane}) and its search data and logs move off C:; its lanes clone from it
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
    if ($LanesDir -and $sr -and [string]$sr['start'] -match '(?i)-Epath\.(data|logs)=C:') {
      $sr['start'] = [regex]::Replace([string]$sr['start'], '(?i)-Epath\.data=C:[^ ]+', "-Epath.data=$LanesDir/search-$en-{bird}/data")
      $sr['start'] = [regex]::Replace([string]$sr['start'], '(?i)-Epath\.logs=C:[^ ]+', "-Epath.logs=$LanesDir/search-$en-{bird}/logs")
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

$mysql = Join-Path $Bin 'mysql.exe'; $mysqld = Join-Path $Bin 'mysqld.exe'
function Invoke-Sql([int]$P, [string]$Q) { $o = & $mysql -h 127.0.0.1 -P $P -u root -N -B -e $Q 2>&1; if ($LASTEXITCODE) { throw "mysql :${P}: $o" }; @($o) }
$bad = [System.Collections.Generic.List[string]]::new(); $info = [System.Collections.Generic.List[string]]::new()
function Show-Plan($Rows) { $Rows | ForEach-Object { "  $_" } }

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

if ($Config) {
  $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50
  $ch = Update-BaseMoveConfig $cfg $Targets $DonorPort $Lanes
  $ch | ForEach-Object { "config: $_" }
  if ($Apply) { Copy-Item -LiteralPath $ConfigFile "$ConfigFile.bak-$(Get-Date -Format yyyyMMdd)" -Force; ($cfg | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $ConfigFile -Encoding utf8; "written: $ConfigFile" } else { 'dry run: -Config -Apply writes it' }
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
function Get-LaneSlug([string]$Id) { if ($Id -match '^(\D+)(\d*)$') { "$($Matches[1])-$(Get-Bird $(if ($Matches[2]) { [int]$Matches[2] } else { 1 }))" } else { $Id } }
if ($Rename -or $Rollback) {
  $jf = "$Lanes/rename-journal.json"; $bak = "$Lanes/rename-backup"
  $stateDir = Split-Path $Lanes; $wd = "$Runtime/work/localenv"; $ld = "$Runtime/logs/localenv"
  if ($Rollback) {
    if (-not (Test-Path -LiteralPath $jf)) { 'no journal: nothing to roll back'; exit 1 }
    $j = Get-Content -LiteralPath $jf -Raw | ConvertFrom-Json -AsHashtable
    foreach ($m in @($j['moves'])) { if (Test-Path -LiteralPath $m['to']) { Move-Item -LiteralPath $m['to'] $m['from'] }; "back: $($m['to']) -> $($m['from'])" }
    foreach ($m in @($j['mysql'])) {
      if (Test-Path -LiteralPath $m['newDir']) { Move-Item -LiteralPath $m['newDir'] $m['oldDir'] }
      if (Test-Path -LiteralPath $m['iniBackup']) { Copy-Item -LiteralPath $m['iniBackup'] $m['oldIni'] -Force }
      if (Test-Path -LiteralPath $m['newIni']) { Remove-Item -LiteralPath $m['newIni'] -Force }
      $rd = "$($m['oldDir'])/lane-ready.txt"; if (Test-Path -LiteralPath $rd) { (Get-Content -LiteralPath $rd -Raw).Replace($m['newDir'], $m['oldDir']).Replace($m['newIni'], $m['oldIni']) | Set-Content -LiteralPath $rd -NoNewline }
      "back: $($m['newDir']) -> $($m['oldDir'])"
    }
    Remove-Item -LiteralPath $jf -Force; 'rollback done: restore kit.local.json from its .bak-<date> too'; exit 0
  }
  $cfgR = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50; $envsR = $cfgR['localEnv']['envs']; $mysqlMoves = @(); $moves = @(); $badR = @()
  foreach ($id in @(Get-LaneIds $envsR)) {
    $slug = Get-LaneSlug $id; if ($slug -eq $id) { continue }
    $prod = ($slug -split '-')[0]; $k = if ($id -match '(\d+)$') { [int]$Matches[1] } else { 1 }
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
    $ms = @($envsR[$id]['services'] | Where-Object { $_ -and $_['name'] -eq 'mysql' -and $_['start'] })[0]
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
  'rename plan:'; Show-Plan (@($mysqlMoves | ForEach-Object { "$($_['oldDir']) -> $($_['newDir']) (+ ini rewritten, lane-ready.txt)" }) + @($moves | ForEach-Object { "$($_['from']) -> $($_['to'])" }))
  if ($badR.Count) { 'REFUSED:'; Show-Plan $badR; if ($Apply) { exit 1 } }
  if ($Apply -and ($moves.Count -or $mysqlMoves.Count)) {
    New-Item -ItemType Directory -Force $bak | Out-Null
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
    [ordered]@{ moves = $moves; mysql = $mysqlMoves } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jf -Encoding utf8
    "renamed $($moves.Count) file(s)/dir(s) and $($mysqlMoves.Count) mysql lane(s); journal $jf (-Rollback undoes it)"
  } elseif (-not $Apply) { 'dry run: -Rename -Apply moves them' }
  exit 0
}

# ---- checks: binaries, targets, ports, donor, space, schemas per product
foreach ($f in $mysql, $mysqld) { if (-not (Test-Path -LiteralPath $f)) { $bad.Add("missing $f") } }
if (-not $IniFrom -or -not (Test-Path -LiteralPath $IniFrom)) { $bad.Add("no template ini: pass -IniFrom <a lane ini>") }
$plan = @(foreach ($t in $Targets) {
  if ($t -notmatch '^(\w+):(\d+)$') { $bad.Add("target '$t': use <env>:<port>"); continue }
  $en = $Matches[1]; $pt = [int]$Matches[2]; $dir = "$Lanes/mysql-$en-$(Get-Bird 1)"
  if (Test-Path -LiteralPath $dir) { if (-not $Replace) { $bad.Add("$dir exists: -Replace removes it (only with its lane-ready.txt marker)") } elseif (-not (Test-Path -LiteralPath "$dir/lane-ready.txt")) { $bad.Add("$dir exists without lane-ready.txt: remove it by hand") } }
  if ($pt -ne $DonorPort -and (Test-Listen $pt)) { $bad.Add("port $pt is in use") }
  [pscustomobject]@{ env = $en; port = $pt; dir = $dir; ini = "$dir.ini"; keep = @(); admin = '' }
})
if (@($plan.port | Select-Object -Unique).Count -ne @($plan).Count) { $bad.Add('two targets share a port') }
if ($VerifyPort -eq $DonorPort -or $VerifyPort -in @($plan.port)) { $bad.Add("-VerifyPort $VerifyPort is the donor's or a target's port") }
if (Test-Listen $VerifyPort) { $bad.Add("-VerifyPort $VerifyPort is in use: the verify step drops schemas on it") }
$svc = Get-Service $Service -ErrorAction SilentlyContinue
$info.Add("service $Service : $(if ($svc) { "$($svc.Status), start $($svc.StartType)" } else { 'not found' })")
$donorUp = Test-Listen $DonorPort
if ($env:MYSQL_PWD -and $donorUp) {
  try {
    $mb = [double](Invoke-Sql $DonorPort 'SELECT ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables')[0]
    $busy = @(Invoke-Sql $DonorPort "SELECT COUNT(*) FROM information_schema.processlist WHERE command NOT IN ('Sleep','Daemon') AND id <> CONNECTION_ID()")[0]
    $sleep = @(Invoke-Sql $DonorPort "SELECT COUNT(*) FROM information_schema.processlist WHERE command = 'Sleep'")[0]
    $free = [math]::Round((Get-PSDrive ([string]$Lanes[0])).Free / 1MB)
    $info.Add("donor :$DonorPort data $mb MB, clients: $busy running, $sleep idle; $(([string]$Lanes[0])): free $free MB, need $([int]($mb * @($plan).Count * 1.3)) MB")
    if ($free -lt $mb * @($plan).Count * 1.3) { $bad.Add('not enough free space for the clones') }
    $sys = "'information_schema','performance_schema','mysql','sys','kit_journal'"
    foreach ($p in $plan) { $adm = $AdminSchema.Replace('{env}', $p.env); $p.admin = $adm; $p.keep = @($adm) + @(Invoke-Sql $DonorPort "SELECT name FROM ``$adm``.``$RegistryTable``") }
    $all = @(Invoke-Sql $DonorPort "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($sys)")
    $orphan = @($all | Where-Object { $_ -notin @($plan.keep) })
    foreach ($p in $plan) { $info.Add("$($p.env) keeps: $($p.keep -join ', '), kit_journal") }
    if ($orphan.Count) { $bad.Add("schemas of no target (would be left on the service only): $($orphan -join ', ')") }
    if ($Apply -and [int]$busy -gt 0 -and -not $Force) { $bad.Add("$busy statements running on :${DonorPort}: stop the envs first (envy down), or -Force") }
  } catch { $bad.Add("donor: $($_.Exception.Message)") }
} else { $info.Add("donor :$DonorPort not checked ($(if (-not $env:MYSQL_PWD) { 'MYSQL_PWD unset' } else { 'not listening' }))"); if ($Apply) { $bad.Add('-Apply needs MYSQL_PWD and the donor up') } }

"plan:"; Show-Plan ($plan | ForEach-Object { "$($_.env): clone :$DonorPort -> $($_.dir), ini $($_.ini), port $($_.port)$(if ($_.port -ne $DonorPort) { ", $($AdminSchema.Replace('{env}', $_.env)).$PoolTable -> :$($_.port)" })" })
"checks:"; Show-Plan $info
if ($bad.Count) { "REFUSED:"; Show-Plan $bad; if ($Apply) { exit 1 } }

# ---- apply: clone, drop the other product's schemas, verify, point the pool
if ($Apply) {
  if ($bad.Count) { exit 1 }
  $tmpl = @(Get-Content -LiteralPath $IniFrom)
  if ("$(Invoke-Sql $DonorPort "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name='clone' AND plugin_status='ACTIVE'")".Trim() -ne '1') { Invoke-Sql $DonorPort "INSTALL PLUGIN clone SONAME 'mysql_clone.dll'" | Out-Null }
  $want = Invoke-Sql $DonorPort "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') GROUP BY table_schema ORDER BY 1"
  foreach ($p in $plan) {
    if (Test-Path -LiteralPath $p.dir) { Remove-Item -LiteralPath $p.dir -Recurse -Force }
    $t0 = Get-Date; "cloning :$DonorPort -> $($p.dir)"
    Invoke-Sql $DonorPort "CLONE LOCAL DATA DIRECTORY = '$($p.dir)'" | Out-Null
    "cloned in $([int]((Get-Date) - $t0).TotalSeconds) s"
    Set-Content -LiteralPath $p.ini (New-BaseIni $tmpl $p.port $p.dir) -Encoding ascii
    # start on the verify port (the final one may be the donor's), compare, point the pool, stop
    $hide = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }
    $pr = Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$($p.ini)`"", "--port=$VerifyPort", '--sql-mode=NO_ENGINE_SUBSTITUTION' -PassThru @hide
    try {
      $until = (Get-Date).AddMinutes(5)
      while (-not (Test-Listen $VerifyPort)) { if ($pr.HasExited -or (Get-Date) -gt $until) { throw "mysqld did not start for $($p.env) (see $($p.dir)/lane.err)" }; Start-Sleep 2 }
      $dd = ("$(Invoke-Sql $VerifyPort 'SELECT @@datadir')" -replace '\\', '/' -replace '/+', '/').TrimEnd('/')   # the client prints backslashes doubled
      if ($dd -ne ($p.dir -replace '\\', '/' -replace '/+', '/').TrimEnd('/')) { throw "port $VerifyPort serves $dd, not the clone $($p.dir): nothing dropped" }
      # the other product's schemas go (kit_journal stays: the cascade guard's triggers of the kept tenants write it)
      foreach ($d in @(Invoke-Sql $VerifyPort "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($sys)" | Where-Object { $_ -notin $p.keep })) { Invoke-Sql $VerifyPort "DROP DATABASE ``$d``" | Out-Null; "$($p.env): dropped $d (another product's)" }
      $got = Invoke-Sql $VerifyPort "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') GROUP BY table_schema ORDER BY 1"
      $exp = @($want | Where-Object { ($_ -split "`t")[0] -in ($p.keep + 'kit_journal') })
      if (($got -join '|') -ne ($exp -join '|')) { throw "$($p.env): table counts differ from the donor:`n donor $($exp -join ', ')`n clone $($got -join ', ')" }
      $sc = $AdminSchema.Replace('{env}', $p.env)
      if ($p.port -ne $DonorPort -and "$(Invoke-Sql $VerifyPort "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$sc' AND table_name='$PoolTable'")".Trim() -eq '1') {
        Invoke-Sql $VerifyPort "UPDATE ``$sc``.``$PoolTable`` SET url = REPLACE(url, ':$DonorPort/', ':$($p.port)/') WHERE url LIKE '%:$DonorPort/%'" | Out-Null; "$sc.$PoolTable -> :$($p.port)" }
      "$($p.env): verified $($got.Count) schemas"
    } finally {
      & (Join-Path $Bin 'mysqladmin.exe') -h 127.0.0.1 -P $VerifyPort -u root shutdown 2>&1 | Out-Null
      if (-not $pr.WaitForExit(120000)) { $pr.Kill() }
    }
    Set-Content -LiteralPath "$($p.dir)/lane-ready.txt" "cloned $(Get-Date -Format o) from :$DonorPort (mysql-base-move); port $($p.port); ini $($p.ini)"
  }
}

# ---- search data: off C: (the old folders stay as the rollback)
if ($Apply) {   # search data off C: (the old folders stay as the rollback): copied while that lane's search is down
  $cfgNow = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable -Depth 50
  foreach ($p in $plan) {
    $sr = @($cfgNow['localEnv']['envs'][$p.env]['services'] | Where-Object { $_['name'] -eq 'search' -and $_['start'] })[0]
    if (-not $sr -or [string]$sr['start'] -notmatch '(?i)-Epath\.data=(C:[^ ]+)') { continue }
    $old = $Matches[1]; $sp = $sr['port']
    foreach ($k in '', '2', '3') {
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
  '1. envy.ps1 down for every env and lane (rm, rm2, rm3, hm, hm2): every holder released, nothing writes to the service, lane servers stopped',
  "2. pwsh -NoProfile -File mysql-base-move.ps1 -Apply   (clone + verify + search data; marks of :$DonorPort do not carry over)",
  '3. pwsh -NoProfile -File mysql-base-move.ps1 -Rename -Apply   (lane dirs + inis to bird names; -Rename -Rollback undoes it)',
  "4. net stop $Service ; sc config $Service start= demand   (rollback: sc config $Service start= auto ; net start $Service)",
  '5. pwsh -NoProfile -File mysql-base-move.ps1 -Config -Apply   (kit.local.json; envy resolves {bird}), then envy.ps1 envs / doctor',
  '6. envy.ps1 up -Env rm -Services mysql ; up -Env hm -Services mysql ; then seed -Env rm|hm (re-marks baseline-<date>)',
  "7. the DB MCP config: local/dev port $(@($plan)[0].port) (rm), a second target with port $(@($plan)[-1].port) (hm); each answers only while its env runs")
exit 0
