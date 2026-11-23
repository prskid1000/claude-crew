#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/ (a test: by hand). Exit codes: none here (its verbs exit through their callers).
# liquibase.ps1: the Liquibase migration adapter (kind migration, name liquibase; selected by migrations.tool,
# repos[].migrations.tool or localEnv db.migrations.tool / sets[].tool).
# Verbs: check @{ top; dir; since; show } -> exit code (crafty.ps1 check -Step migrations: devtools.py lbcheck per master)
#   discover @{ e; dirs; registry } -> one set (several masters: ambiguous) · pendingSql @{ e; set; out } -> $null | error
#   tag / rollback @{ e; set; tag } -> $null | error · resetEdited @{ e; envRepos; cur; newLayers } -> notes
#   missingRoutines @{ e; schema } -> { schema, names, files, changeSets } · rerunRoutines @{ e; schema } -> notes (their history rows deleted)
#   historyScopes @{ e } -> the env scopes holding DATABASECHANGELOG
# A set: { name, tool, repo, base, changelog, dir, searchPath, schemas, registry, ambiguous }; searchPath default: the nearest
# 'resources' folder above the changelog (classpath-relative includes), else the changelog's folder.
# Sections: L15 crafty.ps1 check · L49 local env (envy.ps1)
# loaded by lib.ps1 only when config names the tool (a "tool" or db "rollback" value liquibase, anywhere): no config, no adapter
if ($__plugin -eq $PSCommandPath -and ($__cfg | ConvertTo-Json -Depth 30 -Compress) -notmatch '"(?:tool|rollback)":"liquibase"') { return }
# ---- crafty.ps1 check: the repo's changelog masters: XML (lbcheck reads them) or, -Other, the YAML / JSON / SQL ones it cannot (UNRUN)
function Get-LiquibaseMasters([string]$Top, [switch]$Other) {
  @(git -C $Top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' -and ($_ -match '\.xml$') -ne $Other })
}
# LBCHECK_CHANGED = changelog files (repo-relative paths) touched since -Since; the masters under -Dir (the checked folder) first
function Invoke-LiquibaseCheck([string]$Top, [string[]]$Masters, [string]$Since, [string]$Dir, [switch]$Show) {
  $sinceDate = try { [datetime]::ParseExact($Since.Substring(0, 8), 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { (Get-Date).AddDays(-14).ToString('yyyy-MM-dd') }
  $env:LBCHECK_CHANGED = (@(git -C $Top log --since=$sinceDate --name-only --pretty=format: -- '*.xml') + @(git -C $Top diff --name-only HEAD -- '*.xml') | Where-Object { $_ } | Select-Object -Unique) -join '|'
  $rc = 0
  $mine = @($Masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Top $_)) })
  $under = if ($Dir) { @($mine | Where-Object { $_.StartsWith([IO.Path]::GetFullPath($Dir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }) } else { @() }
  if ($under.Count) { $mine = $under }
  foreach ($full in $mine) {
    $a = @($KitCmd.devtools, 'lbcheck', $full, $Since)
    $py = Get-Python
    if ($Show) { "$py $($a -join ' ')"; continue }
    Write-Host "[check] liquibase: $full (files since $Since)"
    & $py @a | Out-Host; if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
  }
  if (-not $Show) { $rc }
}
# the check verb: masters lbcheck reads, other tools' files and YAML / SQL masters = UNRUN (exit 5 when nothing else ran)
function Invoke-LiquibaseRepoCheck($a) {
  $top = $a.top
  $masters = @(Get-LiquibaseMasters $top)
  $tool = @(git -C $top ls-files | Where-Object { $_ -match '(?i)(^|/)(migrations?|migrate|flyway|alembic|prisma)/(.+/)?[^/]+\.(sql|py|[cm]?[jt]s|rb|php|exs?|cs|go|java|kt)$' -and $_ -notmatch '(?i)liquibase|changelog|__init__\.py$|\.Designer\.cs$|ModelSnapshot\.cs$' })
  $other = @(Get-LiquibaseMasters $top -Other) + @(if ($tool.Count) { "$($tool.Count) migration file(s) of another tool ($(($tool | Select-Object -First 3) -join ', ')$(if ($tool.Count -gt 3) { ', ...' }))" })
  if ($other.Count) { Write-Host "[check] migrations UNRUN: $($other -join ', ') has no kit check: set kit.local.json repos[].migrations.check (its validate / dry run); say 'migrations unrun' in the MR." }
  if (-not $masters) { if ($other.Count) { return 5 }; Write-Host '[check] no migrations in this repo - nothing to check'; return 0 }
  if ($a.show) { Invoke-LiquibaseCheck -Top $top -Masters $masters -Since $a.since -Dir $a.dir -Show; return 0 }
  $rc = Invoke-LiquibaseCheck -Top $top -Masters $masters -Since $a.since -Dir $a.dir
  if (-not $rc -and $other.Count) { 5 } else { $rc }
}

# ---- local env (envy.ps1): the Liquibase CLI per set and schema
# every changelog master under $Dir (git-tracked), full paths
function Get-LiquibaseMasterFiles([string]$Dir) {
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
  @(git -C $Dir ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' 2>$null | Where-Object { $_ -match '(?i)liquibase|changelog' } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Dir $_)) })
}
function Get-LiquibaseSearchPath([string]$Master) {
  $d = Split-Path $Master
  for ($p = $d; $p -and (Split-Path $p); $p = Split-Path $p) { if ((Split-Path $p -Leaf) -ieq 'resources') { return $p } }
  $d
}
# -> the command line ($null: no master or no CLI); --changelog-file relative to --search-path; the password from LIQUIBASE_COMMAND_PASSWORD
function Get-LiquibaseCmd([string]$Master, [string]$SearchPath, [string]$Jdbc, [string]$User, [string]$Verb) {
  $exe = 'liquibase'   # TODO-PARAM (fixed default)
  if (-not $Master -or -not (Test-Path -LiteralPath $Master) -or -not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $null }
  if (-not $SearchPath) { $SearchPath = Get-LiquibaseSearchPath $Master }
  $rel = [IO.Path]::GetRelativePath($SearchPath, $Master).Replace('\', '/')
  "$exe --search-path=`"$SearchPath`" --changelog-file=`"$rel`" --url=`"$Jdbc`" --username=`"$User`" $Verb"
}
# the env scopes Liquibase manages (a DATABASECHANGELOG table)
function LiquibaseSchemas([string]$e) {
  $in = @(EnvSchemas $e | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '; if (-not $in) { return @() }
  @(Invoke-DbSql $e "SELECT TABLE_SCHEMA FROM information_schema.TABLES WHERE LOWER(TABLE_NAME) = 'databasechangelog' AND TABLE_SCHEMA IN ($in) ORDER BY 1" | ForEach-Object { $_[0] })
}
# the Liquibase CLI with one set's changelog on each schema (in order); -Out: stdout of the first schema to that file -> $null or the error
function Invoke-EnvLiquibase([string]$e, $set, [string[]]$schemas, [string]$verb, [string]$out) {
  $db = (Get-EnvCfg $e).db; $v = EnvVars $e ([pscustomobject]@{})
  if ($db.passwordEnv -and $v[[string]$db.passwordEnv]) { $v['LIQUIBASE_COMMAND_PASSWORD'] = $v[[string]$db.passwordEnv] }
  $done = @()
  foreach ($sc in $schemas) {
    $cmd = Get-LiquibaseCmd $set.changelog $set.searchPath ("$($db.jdbc)".Replace('{schema}', $sc)) "$($db.user)" $verb
    if (-not $cmd) { return "liquibase: changelog $($set.changelog) missing or no liquibase CLI on PATH" }
    $log = LogFile $e 'db'; Add-Content $log "== $(Now) liquibase $verb ($sc, set $($set.name))"
    $redir = if ($out) { " > `"$out`"" } else { '' }
    $code = Invoke-Shell "$cmd$redir" $log $v 1800
    if ($code) { return "liquibase $verb on $sc failed ($(Get-ShellWhy $code)): $((@($script:ShellOut) | Select-Object -Last 3) -join ' | ')$(if ($done.Count) { "; PARTLY: already done on $($done -join ', ')" })" }
    $out = ''; $done += $sc
  }
  $null
}
# discovery without db.migrations.sets: one set over every master the env's service folders hold; several -> ambiguous
function Get-LiquibaseDiscoveredSet($a) {
  $e = $a.e; $m = @(@($a.dirs) | ForEach-Object { Get-LiquibaseMasterFiles $_.dir } | Select-Object -Unique)
  if (-not $m.Count) { return @() }
  $base = @(@($a.dirs) | Where-Object { $m[0].StartsWith([IO.Path]::GetFullPath($_.dir), [StringComparison]::OrdinalIgnoreCase) })[0]
  $sc = @(LiquibaseSchemas $e)
  [pscustomobject]@{ name = 'default'; tool = 'liquibase'; repo = $base.repo; base = $base.dir; changelog = $m[0]; dir = $null; searchPath = Get-LiquibaseSearchPath $m[0]; schemas = $sc
    registry = [bool]($a.registry -and $a.registry -in $sc); ambiguous = $(if ($m.Count -gt 1) { @($m | ForEach-Object { Split-Path $_ -Leaf }) } else { @() }); masters = $m }
}
# Liquibase changeSets of one file text: "<author>:<id>" -> body, whitespace collapsed (XML and formatted SQL)
function Get-ChangeSetBlocks([string]$Text) {
  $sets = @{}
  foreach ($m in [regex]::Matches("$Text", '(?s)<changeSet\b(?<a>[^>]*?)(?:/>|>(?<b>.*?)</changeSet>)')) {
    $a = $m.Groups['a'].Value; $id = if ($a -match '\bid\s*=\s*"(?<v>[^"]*)"') { $Matches.v }; $au = if ($a -match '\bauthor\s*=\s*"(?<v>[^"]*)"') { $Matches.v }
    if ($id) { $sets["${au}:$id"] = ($m.Value -replace '>\s+<', '><' -replace '\s+', ' ').Trim() }
  }
  $parts = [regex]::Split("$Text", '(?im)^(?=--\s*changeset\s)')
  foreach ($p in $parts) { if ($p -match '(?i)^--\s*changeset\s+(?<au>[^:\s]+):(?<id>\S+)') { $sets["$($Matches.au):$($Matches.id)"] = ($p -replace '\s+', ' ').Trim() } }
  $sets
}
# changeSets whose text differs between two builds of a layer and that the target does not hold yet (unmerged)
function Get-EditedChangeSets([string]$Old, [string]$New, [string]$Merged) {
  $o = Get-ChangeSetBlocks $Old; $n = Get-ChangeSetBlocks $New; $t = Get-ChangeSetBlocks $Merged
  @($n.Keys | Where-Object { $o.ContainsKey($_) -and $o[$_] -ne $n[$_] -and -not $t.ContainsKey($_) } | Sort-Object | ForEach-Object { $k = $_ -split ':', 2; [pscustomobject]@{ author = $k[0]; id = $k[1] } })
}
# a rebuilt layer edited an applied changeSet: Liquibase would stop on the checksum; MD5SUM NULL (recomputed on the next run) -> notes
function Reset-LiquibaseEdited([string]$e, $envRepos, $cur, $newLayers) {
  foreach ($rn in @($newLayers.Keys)) {
    $wt = $envRepos[$rn].wt; $tgt = "origin/$($envRepos[$rn].target)"
    foreach ($l in @($newLayers[$rn] | Where-Object { $_.migrations })) {
      $prev = @($cur[$rn] | Where-Object { $_.branch -eq $l.branch -and $_.sha -and $_.sha -ne $l.sha })[0]; if (-not $prev) { continue }
      foreach ($f in @(git -C $wt diff --name-only $prev.sha $l.sha 2>$null | Where-Object { $_ -match $script:MigPattern -or $_ -match '\.sql$' })) {
        $ids = @(Get-EditedChangeSets "$(git -C $wt show "$($prev.sha):$f" 2>$null)" "$(git -C $wt show "$($l.sha):$f" 2>$null)" "$(git -C $wt show "${tgt}:$f" 2>$null)")
        if (-not $ids.Count) { continue }
        if (-not (Get-Command Invoke-DbSql -ErrorAction SilentlyContinue)) { "checksums of edited changeSets in $f ($($l.branch)) not reset: needs adapters/db_presets.ps1"; continue }
        $leaf = Split-Path $f -Leaf; $like = '%/' + ($leaf -replace '([\\%_])', '\$1'); $bad = @()
        $scs = @(@(try { Resolve-MigSets $e } catch { @() }) | ForEach-Object { @($_.schemas) } | Where-Object { $_ } | Select-Object -Unique); if (-not $scs.Count) { $scs = @(LiquibaseSchemas $e) }
        foreach ($sc in $scs) {
          try { foreach ($c in $ids) { $null = Invoke-DbSql $e "UPDATE $(SqlId $sc).DATABASECHANGELOG SET MD5SUM = NULL WHERE ID = $(SqlQ $c.id) AND AUTHOR = $(SqlQ $c.author) AND (FILENAME = $(SqlQ $leaf) OR FILENAME LIKE $(SqlQ $like))" } }
          catch { $bad += "$sc ($("$_".Split("`n")[0]))" }
        }
        "$rn $($l.branch): changeSet(s) $(@($ids | ForEach-Object { "$($_.author):$($_.id)" }) -join ', ') of $leaf changed since the last build (unmerged): MD5SUM reset; the edited DDL is NOT re-applied (restore -Release, or a new changeSet, when its effect changed)$(if ($bad.Count) { "; FAILED on $($bad -join ', ')" })"
      }
    }
  }
}
# a DATABASECHANGELOG FILENAME as a key: lower case, '/' separators, no classpath: prefix or leading '/'
function ConvertTo-LiquibaseFileKey([string]$f) { ($f.Replace('\', '/') -replace '^(?i)classpath\*?:', '').TrimStart('/').ToLower() }
# routines a schema's executed changeSet files create (rollback blocks left out) that it lacks -> @{ schema; names; files; changeSets }, per
# set (-Schema: that one only): its files keyed by their path under the set's search path, matched to FILENAME by the full path (one leaf
# name in two folders differs); changeSets = @{ file; author; id } of the changeSets whose text creates a missing routine
function Get-LiquibaseMissingRoutines([string]$e, [string]$Schema) {
  foreach ($ms in @(Resolve-MigSets $e | Where-Object { $_.tool -eq 'liquibase' })) {
    $roots = if (@($ms.masters).Count -gt 1) { @($ms.masters | ForEach-Object { Get-LiquibaseSearchPath $_ } | Select-Object -Unique) } elseif ($ms.searchPath) { @($ms.searchPath) } elseif ($ms.changelog) { @(Get-LiquibaseSearchPath $ms.changelog) } elseif ($ms.dir) { @($ms.dir) } else { @() }
    $made = @{}; $rc = '(?i)\bCREATE\s+(?:DEFINER\s*=\s*\S+\s+)?(?:PROCEDURE|FUNCTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?`?(\w+)`?\s*\('; $rd = '(?i)\bDROP\s+(?:PROCEDURE|FUNCTION)\s+(?:IF\s+EXISTS\s+)?`?(\w+)'
    $ro = '(?is)^\s*(?:<!\[CDATA\[)?\s*(?:DROP\s+(?:PROCEDURE|FUNCTION)\s+(?:IF\s+EXISTS\s+)?`?\w+`?\s*;?\s*)*(?:CREATE\s+(?:DEFINER\s*=\s*\S+\s+)?(?:PROCEDURE|FUNCTION)\b.*)?(?:\]\]>)?\s*$'
    foreach ($root in @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
      # the parse per root is cached by the last commit under it and this parser's code (seed -Check re-read the whole tree each run); uncommitted or untracked changes: no cache
      $lbVer = (Get-KitHash ("$((Get-Command Get-LiquibaseMissingRoutines).ScriptBlock)") SHA256).Substring(0, 12)
      $lbSha = "$(git -C $root log -1 --format=%H -- . 2>$null)".Trim(); if ($LASTEXITCODE -or "$(git -C $root status --porcelain -- . 2>$null)".Trim()) { $lbSha = '' }
      $lbCacheFile = Join-Path (Get-KitPath cache -Create) "liquibase-routines-$((Get-KitHash (([IO.Path]::GetFullPath($root)).ToLower()) SHA256).Substring(0, 12)).json"
      $lbHit = if ($lbSha) { try { $lbJson = Read-KitText $lbCacheFile | ConvertFrom-Json -AsHashtable; if ($lbJson.key -eq "$lbVer|$lbSha") { $lbJson.made } } catch { $null } }
      if ($null -ne $lbHit) { foreach ($lbKv in $lbHit.GetEnumerator()) { $made[$lbKv.Key] = $lbKv.Value }; continue }
      $lbMine = @{}
      foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Include *.xml, *.sql, *.yaml, *.yml) {
        $t = [IO.File]::ReadAllText($f.FullName); if ($t -notmatch '(?i)\b(PROCEDURE|FUNCTION)\b') { continue }
        $t = $t -replace '(?is)<rollback>.*?</rollback>|--rollback[^\n]*', ''
        $last = [ordered]@{}   # in file order: a backfill procedure created, called, then dropped is no routine the schema keeps
        foreach ($m in [regex]::Matches($t, '(?i)\b(CREATE)\s+(?:DEFINER\s*=\s*\S+\s+)?(?:PROCEDURE|FUNCTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?`?(\w+)`?\s*\(|\bDROP\s+(?:PROCEDURE|FUNCTION)\s+(?:IF\s+EXISTS\s+)?`?(\w+)')) {
          if ($m.Groups[1].Success) { $last[$m.Groups[2].Value.ToLower()] = 'c' } else { $last[$m.Groups[3].Value.ToLower()] = 'd' } }
        $c = @($last.Keys | Where-Object { $last[$_] -eq 'c' }); $d = @($last.Keys | Where-Object { $last[$_] -eq 'd' })
        $by = @{}   # routine -> the last XML changeSet creating it: key, creates, drops, only (nothing but routine DROP / CREATE: safe to re-run)
        foreach ($b in [regex]::Matches($t, '(?is)<changeSet\b([^>]*)>(.*?)</changeSet>')) {
          $id = if ($b.Groups[1].Value -match '\bid\s*=\s*"([^"]*)"') { $Matches[1] }; $au = if ($b.Groups[1].Value -match '\bauthor\s*=\s*"([^"]*)"') { $Matches[1] }
          $cr = @([regex]::Matches($b.Groups[2].Value, $rc) | ForEach-Object { $_.Groups[1].Value.ToLower() }); if (-not $id -or -not $cr.Count) { continue }
          $rest = $b.Groups[2].Value -replace '(?is)<comment>.*?</comment>|<validCheckSum>.*?</validCheckSum>|<preConditions\b.*?</preConditions>', ''
          $rest = [regex]::Replace($rest, '(?is)<(sql|createProcedure)\b[^>]*>(.*?)</\1>', { param($x) if ($x.Groups[2].Value -match $ro) { '' } else { $x.Value } })
          $cs = @{ key = "${au}:$id"; creates = $cr; drops = @([regex]::Matches($b.Groups[2].Value, $rd) | ForEach-Object { $_.Groups[1].Value.ToLower() }); only = -not $rest.Trim() }
          foreach ($n in $cr) { $by[$n] = $cs }
        }
        if ($c.Count -or $d.Count) { $lbMine[(ConvertTo-LiquibaseFileKey ([IO.Path]::GetRelativePath($root, $f.FullName)))] = @{ create = $c; drop = $d; by = $by } }
      }
      foreach ($lbKv in $lbMine.GetEnumerator()) { $made[$lbKv.Key] = $lbKv.Value }
      if ($lbSha) { try { [ordered]@{ key = "$lbVer|$lbSha"; root = $root; made = $lbMine } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $lbCacheFile -Encoding utf8 } catch {} }
    }
    if (-not $made.Count) { continue }
    $find = { param([string]$fn) $k = ConvertTo-LiquibaseFileKey $fn; if ($made.ContainsKey($k)) { return $made[$k] }
      $hit = @($made.Keys | Where-Object { $k.EndsWith("/$_") -or $_.EndsWith("/$k") }); if ($hit.Count -eq 1) { $made[$hit[0]] } }   # absolute or shorter recorded paths
    foreach ($s in @($ms.schemas | Where-Object { -not $Schema -or $_ -eq $Schema })) {
      $want = [ordered]@{}; $from = @{}
      foreach ($r in @(Invoke-DbSql $e "SELECT FILENAME, MAX(ORDEREXECUTED) o FROM ``$s``.DATABASECHANGELOG WHERE EXECTYPE IN ('EXECUTED', 'RERAN') GROUP BY FILENAME ORDER BY o")) {
        $m = & $find ([string]$r[0]); if (-not $m) { continue }
        foreach ($n in $m.create) { $want[$n] = [string]$r[0]; $from[$n] = $m.by[$n] }; foreach ($n in $m.drop) { $want.Remove($n) }
      }
      $have = @(Invoke-DbSql $e "SELECT LOWER(ROUTINE_NAME) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$($s.Replace("'", "''"))'" | ForEach-Object { $_[0] })
      $gone = @($want.Keys | Where-Object { $_ -notin $have })
      # a changeSet re-runs whole: only one that holds nothing but routine DROP / CREATE, each routine it creates missing or dropped first
      $cs = [ordered]@{}; $keep = [ordered]@{}
      foreach ($n in $gone) {
        $x = $from[$n]; if (-not $x) { $keep[$n] = 'no XML changeSet creates it'; continue }
        $busy = @($x.creates | Where-Object { $_ -notin $gone -and $_ -notin $x.drops })
        if (-not $x.only) { $keep[$n] = "$($x.key) holds more than routine DDL" } elseif ($busy.Count) { $keep[$n] = "$($x.key) also creates $($busy -join ', ') (present)" }
        else { $au, $id = $x.key -split ':', 2; $cs["$($want[$n])|$($x.key)"] = [pscustomobject]@{ file = $want[$n]; author = $au; id = $id } }
      }
      if ($gone.Count) { @{ schema = $s; names = $gone; files = @($gone | ForEach-Object { $want[$_] } | Select-Object -Unique); changeSets = @($cs.Values); kept = $keep } }
    }
  }
}
# one schema's missing routines: the history rows of the changeSets that create them deleted, so the next migration run creates them
# again (a copy whose source lacks them while its DATABASECHANGELOG says they ran) -> notes
function Reset-LiquibaseMissingRoutines([string]$e, [string]$Schema) {
  foreach ($g in @(Get-LiquibaseMissingRoutines $e $Schema)) {
    foreach ($n in @($g.kept.Keys)) { "routine $n missing in $($g.schema): its history row kept ($($g.kept[$n])): create it by hand or with a new changeSet" }
    $w = @($g.changeSets | ForEach-Object { "(FILENAME = $(SqlQ $_.file) AND AUTHOR = $(SqlQ $_.author) AND ID = $(SqlQ $_.id))" }); if (-not $w.Count) { continue }
    $null = Invoke-DbSql $e "DELETE FROM $(SqlId $g.schema).DATABASECHANGELOG WHERE $($w -join ' OR ')"
    "routines $(@($g.names | Where-Object { $_ -notin @($g.kept.Keys) }) -join ', ') missing in $($g.schema): $($w.Count) changeSet row(s) deleted from DATABASECHANGELOG; the next migration run creates them"
  }
}
Register-KitAdapter migration liquibase @{
  check           = { param($a) Invoke-LiquibaseRepoCheck $a }
  discover        = { param($a) Get-LiquibaseDiscoveredSet $a }
  pendingSql      = { param($a) Invoke-EnvLiquibase $a.e $a.set @(@($a.set.schemas)[0]) 'update-sql' $a.out }
  tag             = { param($a) Invoke-EnvLiquibase $a.e $a.set @($a.set.schemas) "tag --tag=$($a.tag)" }
  rollback        = { param($a) Invoke-EnvLiquibase $a.e $a.set @($a.set.schemas) "rollback --tag=$($a.tag)" }
  resetEdited     = { param($a) Reset-LiquibaseEdited $a.e $a.envRepos $a.cur $a.newLayers }
  missingRoutines = { param($a) Get-LiquibaseMissingRoutines $a.e $a.schema }
  rerunRoutines   = { param($a) Reset-LiquibaseMissingRoutines $a.e $a.schema }
  historyScopes   = { param($a) LiquibaseSchemas $a.e }
}
