#Requires -Version 7
# liquibase (extra): dev.ps1 check -Step migrations on Liquibase XML masters -> devtools.py lbcheck per master (the one under the
# checked folder first); LBCHECK_CHANGED = changelog files touched since -Since. Returns the worst exit code (-Show: prints the commands).
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
