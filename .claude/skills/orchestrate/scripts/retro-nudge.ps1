# SessionStart hook: if many learning signals piled up since the last /kit-retro, tell the user (one line, no context cost otherwise).
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($PSCommandPath -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }
$file = Join-Path $rt 'learning\signals.jsonl'; $mark = Join-Path $rt 'learning\last-retro.txt'; $guard = Join-Path $rt 'guard.log'
if (-not (Test-Path $file) -and -not (Test-Path $guard)) { exit 0 }
$since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
$n = @(Get-Content $file | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
$g = @(Get-Content $guard | Where-Object { $_ -match '^(\S+)\t' -and [datetime]$Matches[1] -gt $since }).Count
if (($n + $g) -ge 15) {
  @{ systemMessage = "Kit learning: $n signals + $g guard blocks since the last retro. Run /kit-retro to turn them into lessons and rule updates." } | ConvertTo-Json -Compress
}
exit 0
