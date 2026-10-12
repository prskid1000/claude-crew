# SessionStart hook: if many learning signals piled up since the last /kit-retro, tell the user (one line, no context cost otherwise).
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts/kitpaths.ps1')   # Get-KitPath (kitpaths.json)
$file = Get-KitPath signals; $mark = Get-KitPath last-retro; $guard = Get-KitPath guard-log
if (-not (Test-Path $file) -and -not (Test-Path $guard)) { exit 0 }
$since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
$n = @(Get-Content $file | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
$g = @(Get-Content $guard | Where-Object { $_ -match '^(\S+)\t' -and [datetime]$Matches[1] -gt $since }).Count
if (($n + $g) -ge 15) {
  @{ systemMessage = "Kit learning: $n signals + $g guard blocks since the last retro. Run /kit-retro to turn them into lessons and rule updates." } | ConvertTo-Json -Compress
}
exit 0
