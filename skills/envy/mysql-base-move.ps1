#Requires -Version 7
<#
mysql-base-move.ps1: moves the base envs' MySQL off the OS MySQL service onto one lane-style mysqld each (own datadir, own low-write
ini, envy starts it on a lease and stops it when idle). Source = the service (CLONE LOCAL, online, binlogs not copied).
  pwsh -NoProfile -File mysql-base-move.ps1                      dry run: checks + the plan + the switch-over steps (changes nothing)
  pwsh -NoProfile -File mysql-base-move.ps1 -Apply [-Replace]    clone, point the db_pool at the new port, verify; MYSQL_PWD from the env file
  pwsh -NoProfile -File mysql-base-move.ps1 -Config [-Apply]     the kit.local.json edit (dry run prints it; -Apply writes, .bak-<date> kept)
Targets `<env>:<port>` (default rm:3305 hm:3316: next to the lane ports 3307 / 3317, never the service's 3306). Each keeps only its product's
schemas (-AdminSchema + the names in its -RegistryTable) and kit_journal (the cascade guard's triggers write it in the same server). Dirs `<Lanes>/mysql-<env>`, ini
`<Lanes>/mysql-<env>.ini` (copy of -IniFrom with its port and datadir changed), the same names the lane templates use for lane 1.
Never stops, starts or reconfigures the service: the last steps print for the coordinator. -Apply refuses while a client runs a
statement on the donor (-Force: ignore).
Exit codes: 0 ok · 1 refused or failed.
Sections: L26 ini and config edit · L83 checks · L121 apply · L158 search data
#>
param([string[]]$Targets = @('rm:3305', 'hm:3316'), [int]$DonorPort = 3306, [string]$Lanes, [string]$IniFrom,
  [string]$Bin = 'C:/Program Files/MySQL/MySQL Server 8.0/bin', [string]$Service = 'MySQL80', [int]$VerifyPort = 3399,
  [string]$ConfigFile, [string]$AdminSchema = '{env}_admin', [string]$RegistryTable = 'mt_datasource_config', [string]$PoolTable = 'db_pool', [switch]$Config, [switch]$Apply, [switch]$Replace, [switch]$Force)
$ErrorActionPreference = 'Stop'
$KitDir = Split-Path (Split-Path $PSScriptRoot)
if (-not $Lanes) { $Lanes = Join-Path $KitDir '.state/localenv/lanes' }
$Lanes = $Lanes.Replace('\', '/').TrimEnd('/')
if (-not $IniFrom) { $IniFrom = @(Get-ChildItem $Lanes -Filter 'mysql-*.ini' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1 -ExpandProperty FullName)[0] }
if (-not $ConfigFile) { $ConfigFile = Join-Path $KitDir 'skills/crafty/kit.local.json' }

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
    $svc['start'] = ([string]$svc['start']).Replace('mysql-rm{lane}', "mysql-$en{lane}")
    $svc['init']['cmd'] = ([string]$svc['init']['cmd']).Replace('mysql-rm{lane}', "mysql-$en{lane}").Replace('-Port {port}', "-Port {port} -DonorPort $Donor")
    $svc['init']['creates'] = ([string]$svc['init']['creates']).Replace('mysql-rm{lane}', "mysql-$en{lane}")
    if (-not ([string]$svc['start']).Contains("mysql-$en{lane}")) { throw "the template mysql service has no 'mysql-rm{lane}' in its start: edit the template lane first" }
    $e['services'] = @($svc) + @($e['services'] | Where-Object { $_ -and $_['name'] -ne 'mysql' })
    if (-not $e['db']) { $e['db'] = [ordered]@{} }
    $e['db']['port'] = [int]$pt
    if (-not $e['db']['expect']) { $e['db']['expect'] = [ordered]@{} }
    $e['db']['expect']['innodb_buffer_pool_size'] = '1G'
    foreach ($ln in @($envs.Keys | Where-Object { $_ -match "^$en\d+$" })) { foreach ($ls in @($envs[$ln]['services'])) { if ($ls -and $ls['init'] -and $ls['init']['cmd'] -and $ls['init']['cmd'] -notmatch '-DonorPort') { $ls['init']['cmd'] = ([string]$ls['init']['cmd']).Replace('-Port {port}', "-Port {port} -DonorPort $pt") } } }   # a new lane of this env clones from its base server
    $sr = @($e['services'] | Where-Object { $_['name'] -eq 'search' -and $_['start'] })[0]
    if ($LanesDir -and $sr -and [string]$sr['start'] -match '(?i)-Epath\.(data|logs)=C:') {
      $sr['start'] = [regex]::Replace([string]$sr['start'], '(?i)-Epath\.data=C:[^ ]+', "-Epath.data=$LanesDir/search-$en{lane}/data")
      $sr['start'] = [regex]::Replace([string]$sr['start'], '(?i)-Epath\.logs=C:[^ ]+', "-Epath.logs=$LanesDir/search-$en{lane}/logs")
      $changed += "envs.$en.services[search] data + logs -> $LanesDir/search-$en{lane}/"
    }
    $changed += "envs.$en.services[mysql] port $pt managed (init: clone from :$Donor; its lanes from :$pt), envs.$en.db.port $pt, db.expect pool 1G"
  }
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

# ---- checks: binaries, targets, ports, donor, space, schemas per product
foreach ($f in $mysql, $mysqld) { if (-not (Test-Path -LiteralPath $f)) { $bad.Add("missing $f") } }
if (-not $IniFrom -or -not (Test-Path -LiteralPath $IniFrom)) { $bad.Add("no template ini: pass -IniFrom <a lane ini>") }
$plan = @(foreach ($t in $Targets) {
  if ($t -notmatch '^(\w+):(\d+)$') { $bad.Add("target '$t': use <env>:<port>"); continue }
  $en = $Matches[1]; $pt = [int]$Matches[2]; $dir = "$Lanes/mysql-$en"
  if (Test-Path -LiteralPath $dir) { if (-not $Replace) { $bad.Add("$dir exists: -Replace removes it (only with its lane-ready.txt marker)") } elseif (-not (Test-Path -LiteralPath "$dir/lane-ready.txt")) { $bad.Add("$dir exists without lane-ready.txt: remove it by hand") } }
  if ($pt -ne $DonorPort -and (Test-Listen $pt)) { $bad.Add("port $pt is in use") }
  [pscustomobject]@{ env = $en; port = $pt; dir = $dir; ini = "$Lanes/mysql-$en.ini"; keep = @(); admin = '' }
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
      $from = $old.Replace('{lane}', $k); $to = "$Lanes/search-$($p.env)$k/data"
      if (-not (Test-Path -LiteralPath $from)) { if ($k -eq '') { "search $($p.env): no data at $from, nothing to copy" }; continue }
      if (Test-Path -LiteralPath $to) { "search $($p.env): $to exists, kept"; continue }
      if ($k -eq '' -and $sp -and (Test-Listen ([int]$sp))) { "search $($p.env) is up: stop it, then re-run for its data"; continue }
      robocopy $from $to /E /NFL /NDL /NJH /NJS /NP | Out-Null; "search data $from -> $to"
    }
  }
}
"switch-over (the coordinator, in this order):"
Show-Plan @(
  '1. envy.ps1 down -Env rm ; down -Env hm (every holder released, nothing writes to the service)',
  "2. pwsh -NoProfile -File mysql-base-move.ps1 -Apply   (clone + verify; marks of :$DonorPort do not carry over)",
  "3. net stop $Service ; sc config $Service start= demand   (rollback: sc config $Service start= auto ; net start $Service)",
  '4. pwsh -NoProfile -File mysql-base-move.ps1 -Config -Apply   (kit.local.json), then envy.ps1 envs / doctor',
  '5. envy.ps1 up -Env rm -Services mysql ; up -Env hm -Services mysql ; then seed -Env rm|hm (re-marks baseline-<date>)',
  "6. the DB MCP config: local/dev port $(@($plan)[0].port) (rm), a second target with port $(@($plan)[-1].port) (hm); each answers only while its env runs")
exit 0
