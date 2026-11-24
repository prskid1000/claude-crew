#Requires -Version 7
# Usage: dot-sourced by envy.ps1 from adapters/. Exit codes: none here (its verbs exit through envy.ps1).
# tenant-schema.ps1: the schema tenant model (one schema per tenant + a registry; mysql / mariadb)
# Sections: L5 tenants · L152 tenant import
# ---- tenants: local tenants nobody keeps dropped (envs.<env>.tenants; mysql / mariadb): admin rows (the registry row, its FK
#      children found in information_schema, tenants.tables by idColumns / nameColumns), users no other tenant has, the schema
# tenants.registry { schema, table, key, name, idColumns, nameColumns } (flat tenants.* keys: the older shape); no default column names
function TenantCfg([string]$e) {
  $t = (Get-EnvCfg $e).tenants; $r = if ($t.registry) { $t.registry } else { $t }
  if (-not (Test-DbMarks $e) -or -not $r.schema -or -not $r.table) { throw "[$e] tenant needs db.engine mysql / mariadb and envs.$e.tenants.registry { schema, table, key, name } (envy SKILL.md)" }
  $miss = @(@('key', 'name') | Where-Object { -not (Get-KitMember $r $_) }); if ($miss.Count) { throw "[$e] tenants.registry needs $($miss -join ', '): the registry's id and name columns (no defaults)" }
  $o = $t | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  foreach ($k in 'schema', 'table', 'key', 'name') { $o | Add-Member $k ([string](Get-KitMember $r $k)) -Force }
  foreach ($k in 'idColumns', 'nameColumns') { $o | Add-Member $k @((Get-KitMember $r $k) | Where-Object { $_ } | ForEach-Object { "$_" }) -Force }
  $o
}
function SqlIn([string]$col, $vals) { if (-not @($vals).Count) { return '1 = 0' }; "$(SqlId $col) IN ($((@($vals) | Select-Object -Unique | ForEach-Object { SqlQ "$_" }) -join ', '))" }
# id -> name of every registry row
function Get-TenantRows([string]$e) {
  $t = TenantCfg $e; $key = $t.key; $nm = $t.name
  @(Invoke-DbSql $e "SELECT $(SqlId $key), $(SqlId $nm) FROM $(SqlId $t.schema).$(SqlId $t.table)" | ForEach-Object { [pscustomobject]@{ id = $_[0]; name = $_[1] } })
}
# why a tenant stays: tenants.keep, or its name as a word in a tenants.keepFrom file (default none; builtin:kit-config,
# builtin:targets, builtin:seed = kit.local.json, targets.local.json, the seed file, skipped when missing; { file, keys } = only
# the top-level keys matching that regex) -> name -> reason
function Get-TenantKeep([string]$e, [string[]]$names) {
  $t = TenantCfg $e; $why = @{}
  foreach ($n in @($t.keep | Where-Object { $_ })) { $why["$n"] = 'tenants.keep' }
  $builtin = @{ 'builtin:kit-config' = { $KitConf.ConfigFile }; 'builtin:targets' = { Join-Path $KitConf.Kit 'skills/pokey/targets.local.json' }; 'builtin:seed' = { SeedFile $e } }
  $none = [pscustomobject]@{ port = '' }; $read = 0
  foreach ($src in @($t.keepFrom) | Where-Object { $_ }) {
    $bi = $src -is [string] -and $src -like 'builtin:*'
    if ($bi -and -not $builtin[$src]) { throw "[$e] tenants.keepFrom $src : no such builtin ($(@($builtin.Keys | Sort-Object) -join ', '))" }
    $file = if ($bi) { & $builtin[$src] } else { Expand-Placeholders ([string]$(if ($src -is [string]) { $src } else { $src.file })) $e $none $KitConf.Workspace '' }
    if (-not (Test-Path -LiteralPath $file)) { if (-not $bi) { throw "[$e] tenants.keepFrom $file does not exist: fix the path (a keep source must be readable)" }; continue }
    $read++
    $text = Get-Content -LiteralPath $file -Raw
    if ($src -isnot [string] -and $src.keys) { $j = $text | ConvertFrom-Json; $text = (@((Get-KitProps $j) | Where-Object Name -match ([string]$src.keys) | ForEach-Object { $_.Value | ConvertTo-Json -Depth 20 }) -join "`n") }
    foreach ($n in $names) { if (-not $why[$n] -and $text -match "(?i)(?<![\w-])$([regex]::Escape($n))(?![\w-])") { $why[$n] = "named in $(Split-Path $file -Leaf)" } }
  }
  if (-not $read -and -not @($t.keep | Where-Object { $_ }).Count) { throw "[$e] tenant: no keep source (tenants.keep empty, no keepFrom file readable): refused, nothing would be kept" }
  $why
}
# the delete plan of one tenant: [ { table, where } ] parents first (children reached by information_schema foreign keys from
# the registry, the users table and tenants.tables), + the schema; $others = tenant schemas that stay (users they have are kept)
function Get-TenantPlan([string]$e, [string]$name, [string[]]$others, [switch]$NoUsers) {
  $t = TenantCfg $e; $adm = [string]$t.schema; $key = $t.key; $nm = $t.name
  $q = { param($sql) @(Invoke-DbSql $e $sql 600) }   # TODO-PARAM (fixed default)
  $fks = @(& $q "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_NAME IS NOT NULL")
  $multi = @{}; foreach ($g in $fks | Group-Object { "$($_[0])|$($_[4])" } | Where-Object Count -gt 1) { $multi[$g.Name] = $true }   # a composite FK: a one-column match would over-delete
  $ids = @(& $q "SELECT $(SqlId $key) FROM $(SqlId $adm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $name)" | ForEach-Object { $_[0] })
  $steps = [Collections.Generic.List[object]]::new(); $seen = @{}; $todo = [Collections.Generic.Queue[object]]::new()
  $push = { param($tb, $where) $k = "$tb|$where"; if (-not $seen[$k] -and $where -ne '1 = 0') { $seen[$k] = $true; $todo.Enqueue(@{ table = $tb; where = $where }) } }
  if ($ids.Count) { & $push $t.table (SqlIn $key $ids) }
  $cols = @{}; foreach ($r in & $q "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $adm)") { if (-not $cols[$r[0]]) { $cols[$r[0]] = @() }; $cols[$r[0]] += $r[1] }
  $idc = @($t.idColumns); $nmc = @($t.nameColumns)
  foreach ($tb in @($t.tables | Where-Object { $_ -and $_ -ne $t.table })) {
    $other = @($fks | Where-Object { $_[0] -eq $tb -and $_[2] -ne $t.table } | ForEach-Object { $_[1] })   # an id column whose FK points at another table holds that table's ids, not registry ids: the FK walk reaches it
    $w = @(@($cols[$tb] | Where-Object { $_ -in $idc -and $_ -notin $other } | ForEach-Object { SqlIn $_ $ids }) + @($cols[$tb] | Where-Object { $_ -in $nmc } | ForEach-Object { SqlIn $_ @($name) }) | Where-Object { $_ -ne '1 = 0' })
    if ($w.Count) { & $push $tb ($w -join ' OR ') } elseif (-not $cols[$tb]) { $steps.Add(@{ table = $tb; missing = $true }) }
  }
  if ($t.users -and $t.users.table -and -not $NoUsers) {   # admin users of this tenant's own user table that no staying tenant schema has
    $uk = if ($t.users.key) { [string]$t.users.key } else { 'login' }; $tt = if ($t.users.tenantTable) { [string]$t.users.tenantTable } else { [string]$t.users.table }; $tk = if ($t.users.tenantKey) { [string]$t.users.tenantKey } else { $uk }
    $has = { param($sc) try { @(& $q "SELECT DISTINCT $(SqlId $tk) FROM $(SqlId $sc).$(SqlId $tt)" | ForEach-Object { $_[0] }) } catch { if ("$_" -match '\b1146\b') { @() } else { throw "[$e] tenant: the users of $sc are unreadable ($("$_".Split("`n")[0])): refused, a kept user could go" } } }   # 1146: no such table
    $mine = @(& $has $name); $kept = @{}; foreach ($o in $others) { foreach ($u in & $has $o) { $kept["$u"] = $true } }
    & $push $t.users.table (SqlIn $uk @($mine | Where-Object { -not $kept["$_"] }))
  }
  for ($i = 0; $todo.Count -and $i -lt 500; $i++) {   # TODO-PARAM (fixed default)
    $n = $todo.Dequeue(); $steps.Add($n)
    foreach ($fk in $fks | Where-Object { $_[2] -eq $n.table }) {
      if ($multi["$($fk[0])|$($fk[4])"]) { throw "[$e] tenant: $($fk[0]) references $($n.table) by the composite key $($fk[4]): not supported, drop by hand" }
      $vals = @(& $q "SELECT DISTINCT $(SqlId $fk[3]) FROM $(SqlId $adm).$(SqlId $n.table) WHERE $($n.where)" | ForEach-Object { $_[0] } | Where-Object { $_ -ne 'NULL' })
      & $push $fk[0] (SqlIn $fk[1] $vals)
    }
  }
  foreach ($s in $steps | Where-Object { -not $_.missing }) { $s.rows = [int]@(& $q "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $s.table) WHERE $($s.where)")[0][0] }
  $mb = @(& $q "SELECT ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1), COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $name)")[0]
  $schema = [bool]@(& $q "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $name)").Count
  @{ name = $name; ids = $ids; steps = @($steps); schema = $schema; mb = [double]$mb[0]; tables = [int]$mb[1] }
}
# rows of $steps whose every FK into a table $all deletes from points at a row that stays (another tenant's row) -> 'table n (why)'
function Get-TenantForeign([string]$e, $steps, $all) {
  $adm = [string](TenantCfg $e).schema; $planned = @($all | Where-Object { -not $_.missing })
  $fks = @(Invoke-DbSql $e "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_NAME IS NOT NULL" 600)
  $multi = @{}; foreach ($g in $fks | Group-Object { "$($_[0])|$($_[4])" } | Where-Object Count -gt 1) { $multi[$g.Name] = $true }
  @(foreach ($s in $steps | Where-Object { -not $_.missing -and $_.rows }) {
    $nn = @(); $in = @(); $why = @()
    foreach ($fk in $fks | Where-Object { $_[0] -eq $s.table -and -not $multi["$($_[0])|$($_[4])"] }) {
      $pw = @($planned | Where-Object table -eq $fk[2] | ForEach-Object { "($($_.where))" }); if (-not $pw.Count) { continue }
      $c = SqlId $fk[1]; $nn += "$c IS NOT NULL"; $why += "$($fk[1]) -> $($fk[2])"
      $in += "COALESCE($c IN (SELECT $(SqlId $fk[3]) FROM $(SqlId $adm).$(SqlId $fk[2]) WHERE ($($pw -join ' OR ')) AND $(SqlId $fk[3]) IS NOT NULL), 0)"
    }
    if (-not $in.Count) { continue }   # one FK to a planned row is enough (a link row of this tenant and a shared user stays deletable)
    $nf = [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $s.table) WHERE ($($s.where)) AND ($($nn -join ' OR ')) AND NOT ($($in -join ' OR '))" 600)[0][0]
    if ($nf) { "$($s.table) $nf ($($why -join ', '): a row that stays)" }
  })
}
# every tenant of the env (the registry + schemas no env's registry or admin names) with its keep reason and size
function Get-TenantList([string]$e) {
  $t = TenantCfg $e; $rows = @(Get-TenantRows $e)
  $mine = @($rows.name); $taken = @(foreach ($n in EnvNames) { $db = (Get-EnvCfg $n).db; "$($db.name)"; @($db.schemas | Where-Object { $_ }); $c = (Get-EnvCfg $n).tenants; if ($c.registry) { $c = $c.registry }; if ($c.schema) { [string]$c.schema; if ($n -ne $e) { try { @(Get-TenantRows $n).name } catch { } } } })   # every env's own schemas and admin schema
  $sys = @('mysql', 'sys', 'information_schema', 'performance_schema')
  $orph = @(Invoke-DbSql $e 'SELECT SCHEMA_NAME FROM information_schema.SCHEMATA' | ForEach-Object { $_[0] } | Where-Object { $_ -notin $sys -and $_ -notin $mine -and $_ -notin $taken -and $_ -notlike 'kit_*' })
  $keep = Get-TenantKeep $e (@($mine) + @($orph))
  $size = @{}; foreach ($r in Invoke-DbSql $e "SELECT TABLE_SCHEMA, ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1) FROM information_schema.TABLES GROUP BY TABLE_SCHEMA") { $size[$r[0]] = [double]$r[1] }
  @(@($mine | ForEach-Object { [pscustomobject]@{ name = $_; registry = $true; keep = $keep[$_]; mb = [double]$size[$_] } }) + @($orph | ForEach-Object { [pscustomobject]@{ name = $_; registry = $false; keep = $keep[$_]; mb = [double]$size[$_] } }))
}
# drop: refused for a kept tenant, a system or admin schema, or while any lease, hold or train is on the env; per tenant one
# transaction (children first, foreign key checks off inside it: the registry and its children reference each other), the
# schema after it commits; then every planned table counted again (0 left) and the env's smoke checks + tenants.verify ({tenant})
function Invoke-TenantDrop([string]$e, [string[]]$names, [switch]$DryRun) {
  $t = TenantCfg $e; $adm = [string]$t.schema; $list = @(Get-TenantList $e); $bad = @()
  foreach ($n in $names) {
    $x = @($list | Where-Object name -eq $n)[0]
    if (-not $x) { $bad += "$n : no such tenant (registry row or schema)" } elseif ($x.keep) { $bad += "$n : kept ($($x.keep))" }
  }
  if ($bad.Count) { throw "[$e] tenant drop refused: $($bad -join '; ')" }
  $st = Read-State $e
  if (-not $DryRun -and ($st.train -or $st.leases.Count -or $st.holds.Count)) { throw "[$e] tenant drop refused: the env is in use ($(@(@($st.leases.Keys) + @($st.holds.Keys) + @($(if ($st.train) { "train $($st.train.id)" }))) -join ', ')): run it with no lease, hold or train" }
  $stay = @($list | Where-Object { $_.name -notin $names } | ForEach-Object name)
  $plans = @{}; foreach ($n in $names) { $plans[$n] = Get-TenantPlan $e $n $stay }   # every plan before any delete: one blocked tenant stops them all
  $all = @(foreach ($n in $names) { $plans[$n].steps }); foreach ($n in $names) { $plans[$n].foreign = @(Get-TenantForeign $e $plans[$n].steps $all) }   # rows of tenants dropped together are not foreign
  foreach ($n in $names) {
    $p = $plans[$n]; $del = @($p.steps | Where-Object { -not $_.missing })
    "[$e] tenant $n : schema $(if ($p.schema) { "$($p.mb) MB in $($p.tables) table(s)" } else { 'gone' }); admin rows: $(if ($del.Count) { @($del | ForEach-Object { "$($_.table) $($_.rows)" }) -join ', ' } else { 'none' })$(if (@($p.steps | Where-Object missing).Count) { "; not in $adm : $(@($p.steps | Where-Object missing | ForEach-Object table) -join ', ')" })$(if ($p.foreign.Count) { "; BLOCKED, rows of staying tenants: $($p.foreign -join ', ')" })"
  }
  $blk = @($names | Where-Object { $plans[$_].foreign.Count })
  if ($blk.Count) { throw "[$e] tenant drop refused, nothing deleted: the plan of $($blk -join ', ') reaches rows pointing at rows that stay (a tenants.idColumns column holding another table's ids?): fix tenants.tables / idColumns or drop by hand" }
  if ($DryRun) { return }
  $mk = try { New-Mark $e "before-tenant-drop-$($names -join '-')" 'owner' } catch { $null }; if ($mk) { "[$e] mark ${mk}: envy.ps1 restore -Env $e -Mark $mk brings the dropped tenant(s) back" }
  foreach ($n in $names) {
    $p = $plans[$n]; $del = @($p.steps | Where-Object { -not $_.missing })
    $sql = (@('SET FOREIGN_KEY_CHECKS = 0', 'START TRANSACTION') + @(for ($i = $del.Count - 1; $i -ge 0; $i--) { "DELETE FROM $(SqlId $adm).$(SqlId $del[$i].table) WHERE $($del[$i].where)" }) + @('COMMIT', 'SET FOREIGN_KEY_CHECKS = 1')) -join '; '
    $null = Invoke-DbSql $e $sql 1800   # one transaction: an error rolls it all back (the client exits before COMMIT)
    if ($p.schema) { $null = Invoke-DbSql $e "DROP DATABASE IF EXISTS $(SqlId $n)" 1800 }
    $left = @($del | Where-Object { [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $_.table) WHERE $($_.where)")[0][0] } | ForEach-Object table)
    $gone = -not @(Invoke-DbSql $e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $n)").Count
    Event $e 'tenant-drop' @{ tenant = $n; mb = $p.mb; rows = @($del | ForEach-Object { "$($_.table)=$($_.rows)" }); left = $left; schemaGone = $gone }
    if ($left.Count -or -not $gone) { throw "[$e] tenant $n : references left in $($left -join ', ')$(if (-not $gone) { '; the schema is still there' })" }
    "[$e] tenant $n dropped: $(@($del | Measure-Object rows -Sum).Sum) admin row(s), $($p.mb) MB; 0 references left"
  }
  $sf = Test-Smoke $e; if ($sf) { throw "[$e] tenant drop: smoke check failed after it: $sf" }
  $okv = [Collections.Generic.List[string]]::new()
  $bad = @(foreach ($k in @($list | Where-Object { $t.verify -and $_.keep -and $_.registry } | ForEach-Object name)) {
    $code = Invoke-Shell (Expand-Placeholders ([string]$t.verify) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '').Replace('{tenant}', $k) (LogFile $e 'tenant') (EnvVars $e ([pscustomobject]@{})) 120
    if ($code) { "$k ($(Get-ShellWhy $code): $((@($script:ShellOut) | Select-Object -Last 1) -join ' | '))" } else { $okv.Add("[$e] kept tenant $k : verify ok") }
  })
  $okv
  if ($bad.Count) { throw "[$e] tenant drop done, but kept tenant(s) fail tenants.verify: $($bad -join '; ')" }
}

# ---- tenant import: one tenant schema from a read-only, non-production source (tenants.import.sources), masked by a profile
#      (db_flashback.py mask, saved per source + tenant + profile config, reused until -Refresh), loaded as a new schema, registered by cloning the registry
#      rows of tenants.import.template (new ids, name columns = the new name, tenants.import.set on top)
function Get-ImportCfg([string]$e) { $t = TenantCfg $e; if (-not $t.import -or -not $t.import.sources) { throw "[$e] tenant import needs envs.$e.tenants.import { sources, template, profiles, register } (envy SKILL.md)" }; $t.import }
function Get-ImportProdRe($ic) { if ($ic.prodPattern) { [string]$ic.prodPattern } else { '(?i)(^|[^a-z])(prod|production|live)([^a-z]|$)' } }
# source credentials by name: creds = a command printing JSON { host, port, user | username, password } (never shown), or host /
# port / user + passwordEnv (a variable of the env file); refused when marked prod or its name / host matches prodPattern
function Get-ImportSource([string]$e, [string]$from) {
  $ic = Get-ImportCfg $e; $s = (Get-KitMember $ic.sources $from); $pp = Get-ImportProdRe $ic
  if (-not $s) { throw "[$e] no import source '$from' (tenants.import.sources: $(@((Get-KitProps $ic.sources).Name) -join ', '))" }
  if ($s.prod -or $from -match $pp) { throw "[$e] tenant import refused: source '$from' is production (prod: true or the name matches prodPattern); only test / staging copies are imported" }
  $c = @{ host = "$($s.host)"; port = "$($s.port)"; user = "$($s.user)"; password = ''; cfg = $s }
  if ($s.creds) {
    $r = if ($KitIsWindows) { Invoke-KitExe 'cmd.exe' @() 120 -Raw "/d /s /c `"$($s.creds)`"" } else { Invoke-KitExe '/bin/sh' @('-c', [string]$s.creds) 120 }   # TODO-PARAM (fixed default)
    if ($r.code) { throw "[$e] import source '$from': its creds command failed (exit $($r.code))" }   # its output may hold the secret: never shown
    $j = try { $r.out | ConvertFrom-Json } catch { $null }
    if (-not $j -or -not $j.password) { throw "[$e] import source '$from': its creds command printed no JSON object with host, user, password" }
    if (-not $c.host) { $c.host = "$($j.host)" }; if (-not $c.port) { $c.port = "$($j.port)" }; if (-not $c.user) { $c.user = "$(if ($j.user) { $j.user } else { $j.username })" }
    $c.password = "$($j.password)"
  } elseif ($s.passwordEnv) { $c.password = "$((EnvVars $e ([pscustomobject]@{}))[[string]$s.passwordEnv])" }
  if (-not $c.port) { $c.port = "$((Get-DbEngine $e).defaultPort)" }
  if (-not $c.host -or -not $c.user) { throw "[$e] import source '$from': no host / user (set them, or a creds command that prints them)" }
  if ($c.host -match $pp) { throw "[$e] tenant import refused: source '$from' host is production (matches prodPattern)" }
  $c
}
# read-only statements on the source -> rows (the end marker as in Invoke-DbSql)
function Invoke-SrcSql($c, [string]$e, [string]$sql) {
  $r = With-Env @{ MYSQL_PWD = $c.password } { Invoke-KitExe (DbConn $e).mysql @('-h', $c.host, '-P', $c.port, '-u', $c.user, '--default-character-set=utf8mb4', '-N', '-B', '--unbuffered') 300 -In "$($sql.TrimEnd().TrimEnd(';'));`nSELECT '__kit_rows_end__';`n" }   # TODO-PARAM (fixed default); stdin: no command-line cap
  if ($r.code) { throw "source mysql: $(Protect-KitText "$($r.err)".Split("`n")[-1])" }
  $lines = @("$($r.out)" -split "`r?`n" | Where-Object { $_ })
  if (-not $lines.Count -or $lines[-1] -ne '__kit_rows_end__') { throw "source mysql: exit 0 without the end marker: $($sql.Substring(0, [math]::Min(80, $sql.Length)))" }
  @($lines | Select-Object -SkipLast 1 | ForEach-Object { , @($_ -split "`t") })
}
# Register-Tenant, builtin:clone: the registry rows of a new tenant $as, cloned from $tpl's: one transaction, foreign key checks off inside it; each row a new
# auto-increment id; FK and idColumns values that point at a cloned row follow it; name columns = $as; $set { table.column: value }
function Get-TenantCloneSql([string]$e, [string]$tpl, [string]$as, $set) {
  $t = TenantCfg $e; $ic = Get-ImportCfg $e; $adm = [string]$t.schema; $key = $t.key; $nm = $t.name
  $idc = @($t.idColumns); $nmc = @($t.nameColumns)
  $steps = @((Get-TenantPlan $e $tpl @() -NoUsers).steps | Where-Object { -not $_.missing -and $_.table -notin @($ic.skipTables) -and $_.rows } | Sort-Object -Stable { $_.table -ne $t.table })   # the tenant row first: a child's unique tenant FK gets the new id at insert
  $fr = @(Get-TenantForeign $e $steps $steps); if ($fr.Count) { throw "[$e] tenant import refused: the template $tpl's plan reaches rows of other tenants ($($fr -join ', ')): an id clash in tenants.tables / idColumns; fix them or skipTables" }   # never copy another tenant's rows
  $fks = @(Invoke-DbSql $e "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_SCHEMA = $(SqlQ $adm) AND REFERENCED_TABLE_NAME IS NOT NULL")
  $rows = [Collections.Generic.List[object]]::new(); $map = @{}; $sql = [Collections.Generic.List[string]]::new(); $sql.Add('SET FOREIGN_KEY_CHECKS = 0'); $sql.Add('START TRANSACTION')
  foreach ($s in $steps) {
    $cols = @(Invoke-DbSql $e "SELECT COLUMN_NAME, EXTRA, COLUMN_KEY, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $adm) AND TABLE_NAME = $(SqlQ $s.table) ORDER BY ORDINAL_POSITION")
    $pk = @($cols | Where-Object { $_[2] -eq 'PRI' }); $ai = @($pk | Where-Object { $_[1] -match 'auto_increment' })
    if ($pk.Count -ne 1 -or $ai.Count -ne 1) { throw "[$e] tenant import: $adm.$($s.table) has no single auto-increment primary key: its rows cannot be cloned (add it to tenants.import.skipTables)" }
    $pc = [string]$pk[0][0]; $plain = @($cols | Where-Object { $_[0] -ne $pc -and $_[1] -notmatch 'GENERATED' } | ForEach-Object { [string]$_[0] })
    $txt = @($cols | Where-Object { $_[3] -match 'char|text' } | ForEach-Object { [string]$_[0] })   # a text value equal to the template's name names the new tenant
    $old = @(Invoke-DbSql $e "SELECT $(SqlId $pc) FROM $(SqlId $adm).$(SqlId $s.table) WHERE $($s.where)" | ForEach-Object { $_[0] })
    if ($rows.Count + $old.Count -gt 200) { throw "[$e] tenant import: the template $tpl has over 200 registry rows to clone ($($s.table)): add log / history tables to tenants.import.skipTables" }   # TODO-PARAM (fixed default)
    $refs = @(foreach ($fk in $fks | Where-Object { $_[0] -eq $s.table }) { , @($fk[1], $fk[2]) })   # FK and idColumns values follow the cloned rows they point at
    $refs += @($plain | Where-Object { $_ -in $idc -and $_ -notin @($refs | ForEach-Object { $_[0] }) } | ForEach-Object { , @($_, [string]$t.table) })
    foreach ($o in $old | Where-Object { -not $map["$($s.table)|$_"] }) {   # a table reached twice (an FK and tenants.tables): each row once
      $v = "@kit_k$($rows.Count)"; $map["$($s.table)|$o"] = $v; $seen = @{}
      $sel = @(foreach ($pcol in $plain) {
        $ref = $null; foreach ($rf in $refs) { if ($rf[0] -eq $pcol) { $ref = $rf; break } }
        $to = @(if ($ref) { $rows | Where-Object table -eq $ref[1] })
        if ($pcol -in $nmc -or ($s.table -eq $t.table -and $pcol -eq $nm)) { SqlQ $as }
        elseif ($to.Count) { $seen[$pcol] = $to.Count; "CASE $(SqlId $pcol) $(@($to | ForEach-Object { "WHEN $(SqlQ $_.old) THEN $($_.var)" }) -join ' ') ELSE $(SqlId $pcol) END" }   # at insert: a unique key on it never sees the template's id
        elseif ($pcol -in $txt) { "IF($(SqlId $pcol) = $(SqlQ $tpl), $(SqlQ $as), $(SqlId $pcol))" } else { SqlId $pcol }
      })
      $sql.Add("INSERT INTO $(SqlId $adm).$(SqlId $s.table) ($(@($plain | ForEach-Object { SqlId $_ }) -join ', ')) SELECT $($sel -join ', ') FROM $(SqlId $adm).$(SqlId $s.table) WHERE $(SqlId $pc) = $(SqlQ $o)")
      $sql.Add("SET $v = LAST_INSERT_ID()"); $rows.Add(@{ table = $s.table; pk = $pc; old = $o; var = $v; cols = $plain; refs = $refs; seen = $seen })
    }
  }
  if (-not @($rows | Where-Object table -eq $t.table).Count) { throw "[$e] tenant import: template $tpl has no $adm.$($t.table) row" }
  foreach ($r in $rows) {   # references to rows cloned after this one (a cycle): an update; rows known at insert are mapped already, never twice
    foreach ($ref in $r.refs) {
      $to = @($rows | Where-Object table -eq $ref[1] | Select-Object -Skip ([int]$r.seen[$ref[0]])); if (-not $to.Count) { continue }
      $sql.Add("UPDATE $(SqlId $adm).$(SqlId $r.table) SET $(SqlId $ref[0]) = CASE $(SqlId $ref[0]) $(@($to | ForEach-Object { "WHEN $(SqlQ $_.old) THEN $($_.var)" }) -join ' ') ELSE $(SqlId $ref[0]) END WHERE $(SqlId $r.pk) = $($r.var)")
    }
  }
  foreach ($k in @($set.Keys)) {
    $tb, $col = $k -split '\.', 2; $to = @($rows | Where-Object table -eq $tb)
    if (-not $to.Count -or -not $col) { throw "[$e] tenants.import.set $k : no cloned $adm table $tb (cloned: $(@($rows.table | Select-Object -Unique) -join ', '))" }
    $sql.Add("UPDATE $(SqlId $adm).$(SqlId $tb) SET $(SqlId $col) = $(if ($null -eq $set[$k]) { 'NULL' } else { SqlQ "$($set[$k])" }) WHERE $(SqlId $to[0].pk) IN ($(@($to.var) -join ', '))")
  }
  $sql.Add('COMMIT'); $sql.Add('SET FOREIGN_KEY_CHECKS = 1')
  @{ sql = $sql -join '; '; rows = @($rows); counts = @($rows | Group-Object { $_.table } | ForEach-Object { "$($_.Name) $($_.Count)" }) }
}
# import: refused for a production or writable source, a taken name, a missing template, a schema over maxMB, or while any lease,
# hold or train is on; -DryRun: the checks and the plan, no data read; a failed load or registration drops the new schema again
function Invoke-TenantImport([string]$e, [string]$From, [string]$Tenant, [string]$As, [string]$Mask, [switch]$DryRun, [switch]$Refresh) {
  if (-not $From -or -not $Tenant -or -not $Mask) { throw 'tenant import needs -From <source> -Tenant <schema> -Mask <profile> [-As <name>]' }
  if (-not $As) { $As = $Tenant }
  foreach ($x in $Tenant, $As) { if ($x -notmatch '^[A-Za-z0-9_]{1,64}\z') { throw "tenant import: '$x' is no plain schema name (letters, digits, _)" } }
  $t = TenantCfg $e; $ic = Get-ImportCfg $e; $adm = [string]$t.schema; $key = $t.key; $nm = $t.name
  $prof = if ((Get-KitMember $ic.profiles $Mask)) { (Get-KitMember $ic.profiles $Mask) } elseif ($Mask -eq 'personal') { [pscustomobject]@{} } else { throw "[$e] no mask profile '$Mask' (tenants.import.profiles: $(@((Get-KitProps $ic.profiles).Name) -join ', '); built in: personal)" }
  $tpl = [string]$ic.template; if (-not $tpl) { throw "[$e] tenant import needs tenants.import.template (a local tenant whose registry rows are cloned)" }
  $c = Get-ImportSource $e $From
  $reg = @(Get-TenantRows $e)
  if (@(Invoke-DbSql $e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $As)").Count -or @($reg | Where-Object name -eq $As).Count) { throw "[$e] tenant import refused: $As exists here (schema or registry row): envy.ps1 tenant drop -Env $e -Name $As first, or -As <another name>" }
  if (-not @($reg | Where-Object name -eq $tpl).Count) { throw "[$e] tenant import: the template tenant $tpl has no registry row here (tenants.import.template)" }
  $busy = { $st = Read-State $e; if ($st.train -or $st.leases.Count -or $st.holds.Count) { throw "[$e] tenant import refused: the env is in use ($(@(@($st.leases.Keys) + @($st.holds.Keys) + @($(if ($st.train) { "train $($st.train.id)" }))) -join ', ')): run it with no lease, hold or train" } }
  if (-not $DryRun) { & $busy }
  $ro = @(Invoke-SrcSql $c $e 'SELECT @@read_only')[0][0]
  if ($c.cfg.requireReadOnly -ne $false -and "$ro" -ne '1') { throw "[$e] tenant import refused: source '$From' is writable (@@read_only = $ro): import only from a read-only replica (requireReadOnly: false for a scratch copy)" }
  $sz = @(Invoke-SrcSql $c $e "SELECT COUNT(*), ROUND(IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH), 0) / 1048576, 1), SUM(TABLE_TYPE = 'BASE TABLE') FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $Tenant)")[0]
  $cs = @(Invoke-SrcSql $c $e "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $(SqlQ $Tenant)")
  if (-not $cs.Count -or -not [int]$sz[0]) { throw "[$e] tenant import: no schema $Tenant with tables on source '$From'" }
  $max = if ($c.cfg.maxMB) { [double]$c.cfg.maxMB } else { 500 }   # TODO-PARAM (fixed default)
  if ([double]$sz[1] -gt $max) { throw "[$e] tenant import refused: $Tenant is $($sz[1]) MB on '$From', over maxMB $max (a smaller tenant, or raise the source's maxMB)" }
  $idc = @($t.idColumns); $nmc = @($t.nameColumns)
  $set = [ordered]@{}; $srcAdm = if ($c.cfg.adminSchema) { [string]$c.cfg.adminSchema } else { $adm }
  $sid = @(Invoke-SrcSql $c $e "SELECT $(SqlId $key) FROM $(SqlId $srcAdm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $Tenant)" | ForEach-Object { $_[0] })
  foreach ($p in @((Get-KitProps $ic.set))) {   # {tenant} = the new name; {source:<table>.<column>} = that value of the tenant's source registry rows
    $v = $p.Value
    if ($v -is [string] -and $v -match '^\{source:(\w+)\.(\w+)\}$') {
      $tb = $Matches[1]; $col = $Matches[2]
      $w = if ($tb -eq $t.table) { "$(SqlId $nm) = $(SqlQ $Tenant)" } else { $sc = @(Invoke-SrcSql $c $e "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $srcAdm) AND TABLE_NAME = $(SqlQ $tb)" | ForEach-Object { $_[0] }); @(@($sc | Where-Object { $_ -in $idc } | ForEach-Object { SqlIn $_ $sid }) + @($sc | Where-Object { $_ -in $nmc } | ForEach-Object { SqlIn $_ @($Tenant) }) | Where-Object { $_ -ne '1 = 0' }) -join ' OR ' }
      $got = @(); if ($w) { $got = @(Invoke-SrcSql $c $e "SELECT $(SqlId $col) FROM $(SqlId $srcAdm).$(SqlId $tb) WHERE $w ORDER BY 1 DESC LIMIT 1") }   # an if as the value would unroll the one row
      if (-not $got.Count) { throw "[$e] tenants.import.set $($p.Name): no $srcAdm.$tb row of $Tenant on '$From'" }
      $v = if ($got[0][0] -eq 'NULL') { $null } else { $got[0][0] }
    } elseif ($v -is [string]) { $v = $v.Replace('{tenant}', $As) }
    $set[$p.Name] = $v
  }
  $plan = Get-TenantCloneSql $e $tpl $As $set
  "[$e] tenant import $From/$Tenant -> $As : $($sz[1]) MB in $($sz[0]) table(s), source read_only $ro; mask $Mask; registry rows from $tpl ($($plan.counts -join ', '))$(if ($set.Count) { "; set $(@($set.Keys) -join ', ')" })"
  if ($DryRun) { return }
  $dir = Join-Path (Get-KitPath cache -Create) 'tenant-import'; New-Item -ItemType Directory -Force $dir | Out-Null
  $pk = $prof | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $mcf = Get-KitSetting 'masking' $null; if ($mcf) { $pk | Add-Member _kit $mcf -Force }   # masking.rules / logins / names: the org's columns and values
  if (-not $mcf.rules) { Write-Warning "[$e] tenant import: no kit.local.json masking.rules: only the generic column names (password, token, email, phone, name, address ...) are masked; add the app's own (audit columns, name columns of exact tables) there (envy db.md)" }
  $pj = $pk | ConvertTo-Json -Depth 10 -Compress   # the cache key: source + tenant + the profile and masking config only (a kit or masker update reuses the copy; migrations bring its schema up to date)
  $ph = (Get-KitHash $pj SHA256).Substring(0, 8).ToLower()
  $pre = "$From-$Tenant-$Mask-"; $file = Join-Path $dir "$pre$ph.sql"; $hours = [double]$(if ($ic.cacheHours) { $ic.cacheHours } else { 0 })   # 0: never expires
  $usable = { param($f) (Test-Path -LiteralPath $f) -and (-not $hours -or ((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalHours -lt $hours) }
  $saved = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match "^$([regex]::Escape($pre))[0-9a-f]{8}\.sql\z" } | Sort-Object LastWriteTime -Descending)
  $use = if ($Refresh) { $null } elseif (& $usable $file) { $file } else { @($saved | Where-Object { & $usable $_.FullName } | ForEach-Object FullName)[0] }
  if ($use) {
    if ($use -ne $file) { Write-Warning "[$e] tenant import: the saved copy $(Split-Path $use -Leaf) was masked with another config of profile $Mask or an older kit (no unmasked copy is kept to re-mask from): reused as is; -Refresh reads $From again with the current profile" }
    $file = $use; $mf = "$file.meta.json"; $sz[2] = if (Test-Path -LiteralPath $mf) { [int](Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).tables } else { -1 }   # the copy's own table count (the source may have drifted); -1: none saved yet, the load sets it
    "[$e] masked dump reused: $file (the source is not read again; -Refresh re-reads it)"
  } else {
    $pf = "$file.profile.json"; [IO.File]::WriteAllText($pf, $pj, [Text.UTF8Encoding]::new($false))
    $r = With-Env @{ KIT_SRC_PWD = $c.password } { Invoke-KitExe (Get-Python) @('-X', 'utf8', $script:DbFlashbackPy, 'mask', '--schema', $Tenant, '--out', $file, '--profile', $pf, '--host', $c.host, '--port', $c.port, '--user', $c.user, '--mysqldump', (DbConn $e).mysqldump) 7200 }   # TODO-PARAM (fixed default)
    $m = try { $r.out | ConvertFrom-Json } catch { $null }
    if ($r.code -or -not $m -or $m.error) { throw "[$e] tenant import: dump + mask failed: $(if ($m.error) { $m.error } else { "exit $($r.code) $(@("$($r.err)" -split "`n")[-1])" })" }
    foreach ($o in $saved | Where-Object FullName -ne $file) { Remove-Item -LiteralPath $o.FullName, "$($o.FullName).profile.json", "$($o.FullName).meta.json" -Force -ErrorAction SilentlyContinue }   # one copy per source + tenant + profile
    "[$e] masked dump: $($m.tables) table(s), $($m.rows) row(s), $([math]::Round($m.bytes / 1MB, 1)) MB; masked $(@((Get-KitProps $m.masked)).Count) column(s), $($m.emailsInText) text value(s) with emails$(if (@($m.skippedData).Count) { "; data skipped: $(@($m.skippedData) -join ', ')" })"
  }
  $want = [int]$sz[2]; $db = DbConn $e
  & $busy   # the dump can take minutes: a lease may have started since
  $mk = try { New-Mark $e "before-tenant-import-$As" 'owner' } catch { $null }; if ($mk) { "[$e] mark ${mk}: envy.ps1 restore -Env $e -Mark $mk takes the import back" }
  $regCmd = if ($ic.register -and "$($ic.register)" -ne 'builtin:clone') { (Expand-Placeholders ([string]$ic.register) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '').Replace('{tenant}', $As).Replace('{template}', $tpl).Replace('{source}', "$From/$Tenant") }
  $ai = @(Invoke-DbSql $e "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = $(SqlQ $adm) AND COLUMN_KEY = 'PRI' AND EXTRA LIKE '%auto_increment%'")
  $top = @{}; if ($ai.Count) { foreach ($r in Invoke-DbSql $e (@($ai | ForEach-Object { "SELECT $(SqlQ $_[0]), $(SqlQ $_[1]), IFNULL(MAX($(SqlId $_[1])), 0) FROM $(SqlId $adm).$(SqlId $_[0])" }) -join ' UNION ALL ')) { $top[$r[0]] = @{ pk = $r[1]; max = $r[2] } } }   # rows above these ids are the ones this import inserts
  try {
    $null = Invoke-DbSql $e "CREATE DATABASE $(SqlId $As) CHARACTER SET $(SqlQ $cs[0][0]) COLLATE $(SqlQ $cs[0][1])"
    $ld = With-Env (EnvVars $e ([pscustomobject]@{})) { Invoke-KitExe $db.mysql @('-h', $db.host, '-P', $db.port, '-u', $db.user, '--default-character-set=utf8mb4', $As, '-e', "source $($file.Replace('\', '/'))") 7200 }   # TODO-PARAM (fixed default)
    if ($ld.code) { throw "load failed: $(@("$($ld.err)" -split "`n" | Where-Object { $_ })[-1])" }
    $have = [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = $(SqlQ $As) AND TABLE_TYPE = 'BASE TABLE'")[0][0]
    if ($have -ne $want -and ($want -ge 0 -or -not $have)) { throw "load incomplete: $have of $want table(s)" }
    if (-not (Test-Path -LiteralPath "$file.meta.json")) { [IO.File]::WriteAllText("$file.meta.json", (@{ tables = $have } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); $want = $have }   # the copy's table count, from a verified load
    if ($regCmd) { $rc = Invoke-Shell $regCmd (LogFile $e 'tenant') (EnvVars $e ([pscustomobject]@{})) 600; if ($rc) { throw "tenants.import.register failed ($(Get-ShellWhy $rc)): $((@($script:ShellOut) | Select-Object -Last 2) -join ' | ')" } }   # TODO-PARAM (fixed default)
    else { $null = Invoke-DbSql $e $plan.sql 600 }   # TODO-PARAM (fixed default)
    $nid = @(Invoke-DbSql $e "SELECT $(SqlId $key) FROM $(SqlId $adm).$(SqlId $t.table) WHERE $(SqlId $nm) = $(SqlQ $As)")
    if ($nid.Count -ne 1) { throw "registration: $($nid.Count) $adm.$($t.table) row(s) named $As" }
  } catch {
    $why = "$_".Split("`n")[0]
    $left = 'its registry rows rolled back'
    try {   # registry rows that committed (a failed check after COMMIT): only rows this import inserted (id above the max before it), never one another tenant has or points at
      if (@(Get-TenantRows $e | Where-Object name -eq $As).Count) {
        $plan0 = @((Get-TenantPlan $e $As @() -NoUsers).steps | Where-Object { -not $_.missing -and $_.rows })
        $del = @(foreach ($s in $plan0 | Where-Object { $top[$_.table] }) { $w = "($($s.where)) AND $(SqlId $top[$s.table].pk) > $($top[$s.table].max)"; @{ table = $s.table; where = $w; rows = [int]@(Invoke-DbSql $e "SELECT COUNT(*) FROM $(SqlId $adm).$(SqlId $s.table) WHERE $w")[0][0] } })
        $fr = @(Get-TenantForeign $e $del $del)
        if ($fr.Count) { throw "rows of staying tenants in its plan ($($fr -join ', '))" }
        $del = @($del | Where-Object rows)
        $null = Invoke-DbSql $e ((@('SET FOREIGN_KEY_CHECKS = 0', 'START TRANSACTION') + @(for ($i = $del.Count - 1; $i -ge 0; $i--) { "DELETE FROM $(SqlId $adm).$(SqlId $del[$i].table) WHERE $($del[$i].where)" }) + @('COMMIT', 'SET FOREIGN_KEY_CHECKS = 1')) -join '; ') 600
        $rest = @((Get-TenantPlan $e $As @() -NoUsers).steps | Where-Object { -not $_.missing -and $_.rows } | ForEach-Object table)
        $left = "its registry rows deleted$(if ($rest.Count) { " but rows in $($rest -join ', ') (not inserted above the ids before it, or no auto-increment key): check them by hand" })"
      }
    } catch { $left = "its registry rows are left: envy.ps1 tenant drop -Env $e -Name $As ($("$_".Split("`n")[0]))" }
    try { $null = Invoke-DbSql $e "DROP DATABASE IF EXISTS $(SqlId $As)" 600 } catch { }   # only the schema this import created
    throw "[$e] tenant import of $As failed, its schema dropped again, ${left}: $why"
  }
  Event $e 'tenant-import' @{ tenant = $As; from = "$From/$Tenant"; mask = $Mask; tables = $want; registry = $plan.counts }
  # routines come with the dump; one the source itself lacks while its history says it ran is made pending, before the migration run below
  try { foreach ($n in @(Reset-MissingRoutines $e $As)) { "[$e] $n" } } catch { "[$e] missing routines of $As not checked: $("$_".Split("`n")[0]) (seed -Check lists them)" }
  foreach ($n in @(Invoke-RestoreAfter $e "tenant-import-$As" -Migrations)) { "[$e] $n" }   # e.g. a migration skip marker the template's rows carried
  if (Test-CascadeGuard $e) { try { $g = Install-DbGuard $e; "[$e] cascade guard: $($g.installed) trigger(s) installed, $($g.kept) kept" } catch { "[$e] cascade guard not installed on $As : $("$_".Split("`n")[0])" } }
  "[$e] tenant $As imported: $want table(s), registry $adm.$($t.table) id $($nid[0][0]) ($($plan.counts -join ', '))"
}
