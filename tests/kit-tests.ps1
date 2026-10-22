#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Runs tests/<area>.tests.ps1 files in parallel, one pwsh each; each area file also runs on its own.
Usage: pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area all|orch|devkit|qa|kittool|workflows|extras[,...]] [-Slow]
(extras: each installed extra's tests.ps1 from the extras branch, kittool.py extra test; none installed = 0 checks)
 -Slow: also the checks that need real tools and take seconds each (KIT_TESTS_SLOW=1, e.g. a real headless Chrome).
Outputs: each area's PASS / FAIL lines, its time, TEST-DUP lines (one case name in two places), a recap of the failed checks, then a total.
Exit codes: 0 pass · 1 a check failed or a TEST-DUP · 2 usage error.
#>
param([string[]]$Area = 'all', [switch]$Slow)
$ErrorActionPreference = 'Stop'
if ($Slow) { $env:KIT_TESTS_SLOW = '1' }   # the area processes inherit it
# the real python first on PATH: a shim (pyenv-win python.bat runs chcp) flips the console code page all areas share, and a
# pwsh started meanwhile prints mojibake
$pyReal = foreach ($p in 'python', 'python3') { if (Get-Command $p -ErrorAction SilentlyContinue) { & $p -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1; break } }
if ($pyReal) { $env:PATH = (Split-Path $pyReal) + [IO.Path]::PathSeparator + $env:PATH }
# one file per area; each dot-sources harness.ps1
$files = 'orch.tests.ps1', 'devkit.tests.ps1', 'qa.tests.ps1', 'kittool.tests.ps1', 'workflows.tests.ps1'
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
} | Sort-Object { [array]::IndexOf($areas, $_.area) }   # area order, not finish order: output and TEST-DUP lists stay stable
$fails = 0
foreach ($r in $results) {
  "== $($r.area) ($($r.seconds) s)"
  $r.out
  # a crash before Complete-Tests prints no count: its FAIL lines, at least one
  if ($r.out -match '(?m)^(\d+) failure\(s\)\s*\z') { $fails += [int]$Matches[1] }
  elseif ($r.code) { $fails += [Math]::Max(1, ([regex]::Matches($r.out, '(?m)^FAIL ')).Count) }
}
# TEST-DUP: one behaviour, one case: a case name (its PASS / FAIL line, case and spaces ignored) twice fails the run
$cases = foreach ($r in $results) { $at = $r.area; foreach ($l in $r.out -split '\r?\n') {
  if ($l -match '^== extra (\S+)') { $at = "extra $($Matches[1])" } elseif ($l -match '^(PASS|FAIL) (.+)') { [pscustomobject]@{ name = $Matches[2].Trim().ToLower() -replace '\s+', ' '; at = $at; text = $Matches[2].Trim(); fail = $Matches[1] -eq 'FAIL' } } } }
foreach ($d in $cases | Group-Object name | Where-Object Count -gt 1) { "TEST-DUP $($d.Name): $($d.Group.at -join ', ')"; $fails++ }
# FAIL recap, indented: never counted twice
$failed = @($cases | Where-Object fail); if ($failed.Count) { 'Failed checks:'; $failed | ForEach-Object { "  [$($_.at)] $($_.text)" } }
"$fails failure(s) in $($areas.Count) area(s), $([int]((Get-Date) - $started).TotalSeconds) s"
exit [int]($fails -gt 0)
