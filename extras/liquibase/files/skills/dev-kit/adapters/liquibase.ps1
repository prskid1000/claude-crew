#Requires -Version 7
# liquibase (extra): dev.ps1 check -Step migrations on Liquibase XML masters -> devtools.py lbcheck per master (the one under the
# checked folder first); LBCHECK_CHANGED = changelog files touched since -Since. Returns the worst exit code (-Show: prints the commands).
# the repo's changelog masters: XML (lbcheck reads them) or, -Other, the YAML / JSON / SQL ones it cannot (UNRUN)
function Get-LiquibaseMasters([string]$Top, [switch]$Other) {
  @(git -C $Top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' -and ($_ -match '\.xml$') -ne $Other })
}
function Invoke-LiquibaseCheck([string]$Top, [string[]]$Masters, [string]$Since, [switch]$Show) {
  $sinceDate = try { [datetime]::ParseExact($Since.Substring(0, 8), 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { (Get-Date).AddDays(-14).ToString('yyyy-MM-dd') }
  $env:LBCHECK_CHANGED = (@(git -C $Top log --since=$sinceDate --name-only --pretty=format: -- '*.xml') + @(git -C $Top diff --name-only HEAD -- '*.xml') | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique) -join '|'
  $rc = 0
  $mine = @($Masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Top $_)) })
  $under = @($mine | Where-Object { $_.StartsWith($st.dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
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
# local env (extra local-env dot-sources this file): the Liquibase CLI on one env schema. db.migrateSql unset -> update-sql (the
# pending changeSets' SQL: the tables a release slices); db.rollback "liquibase" (opt-in) -> tag release-<n> before a release's
# migrations, rollback to it on restore. The changelog = the repo's master under the service folder (as check finds it).
function Get-LiquibaseMaster([string]$Dir) {
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
  $rel = @(git -C $Dir ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' 2>$null | Where-Object { $_ -match '(?i)liquibase|changelog' })[0]
  if ($rel) { [IO.Path]::GetFullPath((Join-Path $Dir $rel)) }
}
# -> the command line ($null: no master or no CLI); the password comes from LIQUIBASE_COMMAND_PASSWORD
function Get-LiquibaseCmd([string]$Dir, [string]$Jdbc, [string]$User, [string]$Verb) {
  $m = Get-LiquibaseMaster $Dir; $exe = 'liquibase'   # TODO-PARAM (fixed default)
  if (-not $m -or -not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $null }
  "$exe --search-path=`"$(Split-Path $m)`" --changelog-file=`"$(Split-Path $m -Leaf)`" --url=`"$Jdbc`" --username=`"$User`" $Verb"
}
