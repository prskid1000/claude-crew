#Requires -Version 7
<#
Sync a workspace's live kit from a clone of this repo (the clone is the single source; never edit the live copy by hand).

  pwsh -File <clone>/.claude/skills/dev-kit/scripts/sync-kit.ps1 -To <workspace>/.claude [-Clean] [-DryRun]

- Copies every file of the clone's .claude into -To (new + changed files only).
- Never touches LOCAL files: *.local.* (kit.local.json, targets.local.json, settings.local.json, rules/*.local.md),
  swarm.config.json, and any path listed in kit.local.json "localOnly" (org-only skills, project profiles, extra rules).
- -Clean also deletes files in -To that are not in the clone (except LOCAL ones and runtime leftovers listed below), so the
  live kit is an exact copy plus its local overlay. Without -Clean nothing is ever deleted.
- -DryRun prints what would change.
Ignored in both trees: node_modules, __pycache__, *.log, *.apk, scheduled_tasks.lock (machine-local state, reinstall/rebuild it).
#>
param(
  [Parameter(Mandatory)][string]$To,
  [string]$From = (Split-Path (Split-Path (Split-Path $PSScriptRoot))),   # <clone>/.claude
  [switch]$Clean, [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$From = (Resolve-Path $From).Path; New-Item -ItemType Directory -Force $To | Out-Null; $To = (Resolve-Path $To).Path
if ($From -eq $To) { throw 'From and To are the same folder' }

function Rel($root, $full) { $full.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/' }
$ignore = '(^|/)(node_modules|__pycache__)(/|$)|\.log$|\.apk$|(^|/)scheduled_tasks\.lock$|(^|/)nul$'
$localOnly = @()
$kl = Join-Path $To 'skills/dev-kit/kit.local.json'
if (Test-Path $kl) { $localOnly = @((Get-Content $kl -Raw | ConvertFrom-Json).localOnly | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') }) }
function IsLocal($rel) {
  if ($rel -match '(^|/)[^/]*\.local(\.[^/]*)?$' -or $rel -match '(^|/)swarm\.config\.json$') { return $true }
  foreach ($p in $localOnly) { if ($rel -eq $p -or $rel.StartsWith("$p/")) { return $true } }
  $false
}

$src = Get-ChildItem $From -Recurse -File -Force | ForEach-Object { Rel $From $_.FullName } | Where-Object { $_ -notmatch $ignore }
$copied = 0; $deleted = 0; $skipped = 0
foreach ($r in $src) {
  if (IsLocal $r) { $skipped++; continue }
  $s = Join-Path $From $r; $d = Join-Path $To $r
  if ((Test-Path $d) -and (Get-FileHash $s).Hash -eq (Get-FileHash $d).Hash) { continue }
  if ($DryRun) { "copy   $r" } else { New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item $s $d -Force }
  $copied++
}
if ($Clean) {
  $have = @{}; foreach ($r in $src) { $have[$r] = $true }
  foreach ($f in Get-ChildItem $To -Recurse -File -Force) {
    $r = Rel $To $f.FullName
    if ($have[$r] -or (IsLocal $r) -or $r -match $ignore) { continue }
    if ($DryRun) { "delete $r" } else { Remove-Item -LiteralPath $f.FullName -Force }
    $deleted++
  }
  if (-not $DryRun) {   # drop folders left empty (never ones holding local files)
    Get-ChildItem $To -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending |
      Where-Object { -not (Get-ChildItem $_.FullName -Force) } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  }
}
"$(if ($DryRun) { 'DRY RUN: ' })$copied copied/updated, $deleted deleted, $skipped local file(s) in the clone left alone; local overlay in $To kept"
