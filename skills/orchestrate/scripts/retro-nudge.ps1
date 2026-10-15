# SessionStart hook: one line, nothing otherwise (no network, well under 1 s):
#  - E14: many learning signals piled up since the last /kit-retro -> run /kit-retro
#  - E21: the last kit audit (kit-audit.py stamp) is older than kit.local.json kitAudit.everyDays (default 7; 0 = off) and no
#    kit-auditor is on the board -> spawn kit-auditor
$ErrorActionPreference = 'SilentlyContinue'
$kit = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/orchestrate/scripts -> <kit>
. (Join-Path $kit 'skills/dev-kit/scripts/kitpaths.ps1')   # Get-KitPath (kitpaths.json)
$msgs = @()

$file = Get-KitPath signals; $mark = Get-KitPath last-retro; $guard = Get-KitPath guard-log
if ((Test-Path $file) -or (Test-Path $guard)) {
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  $n = @(Get-Content $file | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Get-Content $guard | Where-Object { $_ -match '^(\S+)\t' -and [datetime]$Matches[1] -gt $since }).Count
  if (($n + $g) -ge 15) { $msgs += "Kit learning: $n signals + $g guard blocks since the last retro. Run /kit-retro to turn them into lessons and rule updates." }
}

# weekly kit audit (the stamp is durable: <kit>/kit-audit.local.stamp); kit.local.json read directly to keep the hook cheap
$every = 7
try { $c = Get-Content (Join-Path $kit 'skills/dev-kit/kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($null -ne $c.kitAudit.everyDays) { $every = [double]$c.kitAudit.everyDays } } catch {}
if ($every -gt 0) {
  $am = Get-KitPath last-kit-audit
  $last = $null; if (Test-Path $am) { try { $last = [datetime]((Get-Content $am -Raw).Trim()) } catch {} }
  if (-not $last -or ((Get-Date) - $last).TotalDays -ge $every) {
    $busy = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
        Where-Object { $_.agent -eq 'kit-auditor' -and $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 }).Count
    if (-not $busy) { $msgs += "Kit audit due (last $(if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }), every $every days): spawn one kit-auditor agent (orchestrate E21)." }
  }
}

if ($msgs) {
  $text = $msgs -join ' | '
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
