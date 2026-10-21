#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Runs tests/<area>.tests.ps1 files in parallel, one pwsh each; each area file also runs on its own.
Usage: pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area all|orch|devkit|qa|localenv|swarm|kittool|workflows|extras[,...]]
(extras: each installed extra's tests.ps1 from the extras branch, kittool.py extra test; none installed = 0 checks)
Outputs: each area's PASS / FAIL lines, its time, then a total. Exit codes: 0 pass · 1 a check failed · 2 usage error.
#>
param([string[]]$Area = 'all')
$ErrorActionPreference = 'Stop'
# one file per area; each dot-sources harness.ps1
$files = 'orch.tests.ps1', 'devkit.tests.ps1', 'qa.tests.ps1', 'localenv.tests.ps1', 'swarm.tests.ps1', 'kittool.tests.ps1', 'workflows.tests.ps1'
$all = @($files | ForEach-Object { $_ -replace '\.tests\.ps1$' }) + 'extras'
$areas = if ($Area -contains 'all') { $all } else { @($Area | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
$unknown = @($areas | Where-Object { $_ -notin $all })
if (-not $areas -or $unknown) { Write-Error "kit-tests.ps1: unknown or no area(s) '$($unknown -join ', ')'; known: $($all -join ', ')" -ErrorAction Continue; exit 2 }

$started = Get-Date
$results = $areas | ForEach-Object -ThrottleLimit $areas.Count -Parallel {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $out = if ($_ -eq 'extras') { python -X utf8 (Join-Path (Split-Path $using:PSScriptRoot) 'skills/orchestrate/kittool.py') extra test 2>&1 | Out-String }
    else { pwsh -NoProfile -File (Join-Path $using:PSScriptRoot "$_.tests.ps1") 2>&1 | Out-String }
  Write-Host "  $_ done ($([int]$clock.Elapsed.TotalSeconds) s)"   # progress while the slower areas run
  [pscustomobject]@{ area = $_; out = $out.TrimEnd(); code = $LASTEXITCODE; seconds = [int]$clock.Elapsed.TotalSeconds }
}
$fails = 0
foreach ($r in $results | Sort-Object { [array]::IndexOf($areas, $_.area) }) {
  "== $($r.area) ($($r.seconds) s)"
  $r.out
  # a crash before Complete-Tests prints no count: its FAIL lines, at least one
  if ($r.out -match '(?m)^(\d+) failure\(s\)\s*\z') { $fails += [int]$Matches[1] }
  elseif ($r.code) { $fails += [Math]::Max(1, ([regex]::Matches($r.out, '(?m)^FAIL ')).Count) }
}
"$fails failure(s) in $($areas.Count) area(s), $([int]((Get-Date) - $started).TotalSeconds) s"
exit [int]($fails -gt 0)
