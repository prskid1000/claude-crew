#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none here (its verbs exit through envy.ps1).
# tenant-models.ps1: envs.<env>.tenants.model (kind tenant-model; default none) and the envy verb `tenant` (kind envy-verb).
# Models: schema = one schema per tenant + a registry (adapters/tenant-schema.ps1, tenants.registry); database = the same on an
#   engine whose databases are schemas; column = one shared scope, tenants = the values of tenants.column { table, column } (list
#   only); none = no tenant verbs (every other verb works on the db scope: db.schemas / db.schemasQuery / db.name).
# Verbs: list @{ e } -> { name, registry, keep, mb } · drop @{ e; names; dryRun } -> lines · import @{ e; from; tenant; as; mask;
#   dryRun; refresh } -> lines · footprint @{ e; name } -> { steps, schema, mb } · scopes @{ e } -> extra data scopes (optional).
# A model without a verb refuses it ("tenant-model <m>: verb <v> not implemented"). A local adapter adds a model the same way.
# Sections: L11 models · L59 envy.ps1 tenant
# ---- models: the model lookup and each tenant-model registration
function Get-TenantModel([string]$e) { $m = "$((Get-EnvCfg $e).tenants.model)".ToLower(); if ($m) { $m } else { 'none' } }
function Invoke-TenantModel([string]$e, [string]$Verb, [hashtable]$a = @{}) {
  $m = Get-TenantModel $e; $ad = $KitAdapters['tenant-model'][$m]
  if (-not $ad) { throw "[$e] tenants.model $m : no such tenant model ($(@($KitAdapters['tenant-model'].Keys | Sort-Object) -join ', '))" }
  if (-not ($ad[$Verb] -is [scriptblock])) { throw "[$e] tenant-model ${m}: verb $Verb not implemented$(if ($m -eq 'none') { " (set envs.$e.tenants.model: $(@($KitAdapters['tenant-model'].Keys | Where-Object { $_ -ne 'none' } | Sort-Object) -join ' | '))" })" }
  $a.e = $e; & $ad[$Verb] $a $Verb
}
# none: no tenants (tenant verbs refuse, naming the models); no extra scopes
Register-KitAdapter tenant-model none @{ scopes = { param($a) @() } }
& { $schema = @{
    list      = { param($a) Get-TenantList $a.e }
    footprint = { param($a) Get-TenantPlan $a.e $a.name @() -NoUsers }
    drop      = { param($a) Invoke-TenantDrop $a.e $a.names -DryRun:([bool]$a.dryRun) }
    import    = { param($a) Invoke-TenantImport $a.e -From $a.from -Tenant $a.tenant -As $a.as -Mask $a.mask -DryRun:([bool]$a.dryRun) -Refresh:([bool]$a.refresh) }
    # an env with neither db.schemas nor db.schemasQuery: marks / restores cover the registry schema + every existing registered tenant schema
    scopes    = { param($a) $db = (Get-EnvCfg $a.e).db; if (@($db.schemas | Where-Object { $_ }).Count -or $db.schemasQuery) { return @() }
      try { $t = TenantCfg $a.e; $have = @(Invoke-DbSql $a.e 'SELECT SCHEMA_NAME FROM information_schema.SCHEMATA' | ForEach-Object { "$($_[0])" })
        @(@([string]$t.schema) + @(Get-TenantRows $a.e | ForEach-Object { "$($_.name)" }) | Where-Object { $_ -in $have }) } catch { Write-Warning "[$($a.e)] tenant scopes: $_ (db.name only)"; @() } } }
  Register-KitAdapter tenant-model schema $schema
  Register-KitAdapter tenant-model database $schema.Clone() }
Register-KitAdapter tenant-model column @{
  list = { param($a) $e = $a.e; $t = (Get-EnvCfg $e).tenants; $c = $t.column
    if (-not $c.table -or -not $c.column -or "$($c.table)$($c.column)" -notmatch '^[\w.]+$') { throw "[$e] tenants.model column needs tenants.column { table, column } (plain names)" }
    @(Invoke-DbSql $e "SELECT DISTINCT $($c.column) FROM $($c.table)" | ForEach-Object { "$($_[0])" } | Where-Object { $_ -and $_ -ne 'NULL' } | ForEach-Object {
        [pscustomobject]@{ name = $_; registry = $true; keep = $(if ($_ -in @($t.keep)) { 'tenants.keep' }); mb = 0 } }) }
  # footprint: rows per table holding the column; drop: those rows deleted, the registry table last, passes until foreign keys allow
  footprint = { param($a) $c = (Get-EnvCfg $a.e).tenants.column; if ("$($c.column)" -notmatch '^\w+$') { throw "[$($a.e)] tenants.model column needs tenants.column { table, column } (plain names)" }; $v = "'$("$($a.name)".Replace("'", "''"))'"
    @{ steps = @(Get-TenantColumnTables $a.e | ForEach-Object { @{ table = $_; where = "$($c.column) = $v"; rows = [long]@(Invoke-DbSql $a.e "SELECT COUNT(*) FROM $_ WHERE $($c.column) = $v")[0][0] } }); schema = $null; mb = 0 } }
  drop = { param($a) $e = $a.e; $t = (Get-EnvCfg $e).tenants
    foreach ($n in @($a.names)) {
      if ($n -in @($t.keep)) { "[$e] tenant $n kept (tenants.keep): not dropped"; continue }
      $fp = Invoke-TenantModel $e 'footprint' @{ name = $n }; $todo = @($fp.steps | Where-Object { $_.rows } | Sort-Object { $_.table -eq "$($t.column.table)" })
      if ($a.dryRun) { "[$e] tenant ${n}: would delete $(@($todo | ForEach-Object { "$($_.rows) row(s) from $($_.table)" }) -join ', ')"; continue }
      for ($pass = 0; $todo.Count -and $pass -lt 5; $pass++) { $todo = @($todo | Where-Object { $s = $_; try { $null = Invoke-DbSql $e "DELETE FROM $($s.table) WHERE $($s.where)" 600; $false } catch { $true } }) }
      if ($todo.Count) { "[$e] tenant ${n}: rows left in $(@($todo.table) -join ', ') (foreign keys from tables without $($t.column.column)): delete them, then drop again" } else { "[$e] tenant ${n}: rows deleted from $(@($fp.steps | Where-Object { $_.rows }).Count) table(s)" } } }
  scopes = { param($a) @() } }
# the tables holding tenants.column.column: tenants.column.tables, else information_schema.COLUMNS (mysql, mariadb, postgres, sqlserver)
function Get-TenantColumnTables([string]$e) {
  $c = (Get-EnvCfg $e).tenants.column; if (@($c.tables | Where-Object { $_ }).Count) { return @($c.tables | Where-Object { "$_" -match '^[\w.$]+$' }) }
  @(Invoke-DbSql $e "SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.COLUMNS WHERE COLUMN_NAME = '$($c.column)' AND TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys', 'pg_catalog')" | ForEach-Object { "$($_[0]).$($_[1])" } | Where-Object { $_ -match '^[\w.$]+$' })
}
# instance = one server per tenant: tenants.instances [{ name, db }]; drop / import / footprint: on the tenant's own env (fallback)
Register-KitAdapter tenant-model instance @{
  list = { param($a) $t = (Get-EnvCfg $a.e).tenants
    @(@($t.instances) | Where-Object { $_.name } | ForEach-Object { [pscustomobject]@{ name = "$($_.name)"; registry = $true; keep = $(if ("$($_.name)" -in @($t.keep)) { 'tenants.keep' }); mb = 0 } }) }
  scopes = { param($a) @() } }

# ---- envy.ps1 tenant: list = keep / drop with sizes; drop -Name a,b [-DryRun]; import -From -Tenant [-As] -Mask [-DryRun] [-Refresh]
#      (runs inside Invoke-LocalEnv: its parameters and helpers are in scope)
Register-KitAdapter envy-verb tenant @{ ops = @('list', 'drop', 'import'); run = {
  if ($Op -eq 'drop') {
    $tn = @(Split-KitList $Name); if (-not $tn.Count) { throw 'tenant drop needs -Name <tenant>[,<tenant>]' }
    Invoke-TenantModel $e 'drop' @{ names = $tn; dryRun = [bool]$DryRun }; return
  }
  if ($Op -eq 'import') {   # then migrations for the new tenant (db.migrations.runAt: start = tenants.import.restart services, cmd = db.migrations.cmd), tenants.verify, seed -Check
    Invoke-TenantModel $e 'import' @{ from = $From; tenant = $Tenant; as = $As; mask = $Mask; dryRun = [bool]$DryRun; refresh = [bool]$Refresh }
    if ($DryRun) { return }
    $nt = if ($As) { $As } else { $Tenant }; $tc = (Get-EnvCfg $e).tenants; $mg = (Get-EnvCfg $e).db.migrations
    $rs = @($tc.import.restart | Where-Object { $_ })
    $runAt = if ($mg.runAt) { "$($mg.runAt)".ToLower() } elseif ($rs.Count) { 'start' } else { 'none' }
    if ($runAt -eq 'cmd') {
      if (-not $mg.cmd) { throw "[$e] db.migrations.runAt cmd needs db.migrations.cmd ({tenant} = the new tenant)" }
      $code = Invoke-Shell (Expand-Placeholders ([string]$mg.cmd) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '').Replace('{tenant}', $nt) (LogFile $e 'migrations') (EnvVars $e ([pscustomobject]@{})) 1800
      if ($code) { throw "[$e] tenant $nt imported, but db.migrations.cmd failed ($(Get-ShellWhy $code): $((@($script:ShellOut) | Select-Object -Last 2) -join ' | '))" }
      "[$e] db.migrations.cmd ran for $nt"
    } elseif ($runAt -eq 'start' -and $rs.Count) {
      $names = @(Closure $e $rs); $Wait = [math]::Max($Wait, 30)   # TODO-PARAM (fixed default): migrations of every tenant run at start
      foreach ($s in @(EnvServices $e | Where-Object { $_.name -in $rs -and (Managed $_) -and (Healthy $e $_) })) { Stop-Svc $e $s 'tenant import: migrations run at start' }
      Update-State $e { param($x) foreach ($s in $rs) { Clear-StartBackoff $x.services[$s] 'tenant import' }; $x.holds[$Agent] = @{ services = $names } + (New-KitLease $Agent $Session); $x.suppress = $null }
      Ensure-Loop
      try { $up = Wait-Up $names } finally { Update-State $e { param($x) $x.holds.Remove($Agent) } }
      if (-not $up) { throw "[$e] tenant $nt imported, but $($rs -join ', ') did not come up: envy.ps1 logs -Env $e -Service $($rs[0])" }
      "[$e] $($rs -join ', ') restarted: migrations ran for $nt"
      if (Test-CascadeGuard $e) { try { $null = Install-DbGuard $e } catch { "[$e] cascade guard after the migrations failed: $("$_".Split("`n")[0])" } }
    } elseif ($runAt -eq 'start') { "[$e] tenants.import.restart unset: restart the services that run migrations (envy.ps1 restart -Env $e -Services <svc>)" }
    else { "[$e] db.migrations.runAt none: run the migrations for $nt yourself" }
    if ($tc.verify) {
      $code = Invoke-Shell (Expand-Placeholders ([string]$tc.verify) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '').Replace('{tenant}', $nt) (LogFile $e 'tenant') (EnvVars $e ([pscustomobject]@{})) 120
      if ($code) { throw "[$e] tenant $nt imported, but tenants.verify fails ($(Get-ShellWhy $code): $((@($script:ShellOut) | Select-Object -Last 1) -join ' | '))" }; "[$e] tenant $nt : verify ok"
    }
    if (-not (Test-Path -LiteralPath (SeedFile $e))) { "[$e] no seed file $(SeedFile $e): seed -Check skipped"; return }
    Invoke-Seed $e -Check; if ($script:SeedBad) { "[$e] tenant $nt imported; seed -Check not green: point the seed file at it, then envy.ps1 seed -Env $e"; exit 1 }
    return
  }
  if ($Op -and $Op -ne 'list') { throw "tenant $Op : unknown (list, drop, import)" }
  foreach ($x in Invoke-TenantModel $e 'list') { '  {0,-5} {1,-28} {2,9:N1} MB  {3}' -f $(if ($x.keep) { 'KEEP' } else { 'DROP' }), $x.name, $x.mb, $(if ($x.keep) { $x.keep } elseif (-not $x.registry) { 'schema without a registry row' } else { 'nobody keeps it' }) }
} }
