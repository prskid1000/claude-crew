#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Runs tests/<area>.tests.ps1 files in parallel, one pwsh each; each area file also runs on its own.
Usage: pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area all|bossy|crafty|pokey|kitbag|workflows|supervise|params|guard|layout|flow|sessions|tracker|render|dashboard|debate|<any tests/<area>.tests.ps1>[,...]] [-Slow] [-Full]
 -Full: also the scratch-DB areas whose code did not change since origin/main (all skips them; KIT_TESTS_FULL=1).
 -Slow: also the checks that need real tools and take seconds each (KIT_TESTS_SLOW=1, e.g. a real headless Chrome).
Outputs: each area's PASS / FAIL lines, its time, TEST-DUP lines (one case name in two places), TEST-WRITE lines (a test changed a shared snapshot file), a recap of the failed checks, then a total.
Exit codes: 0 pass · 1 a check failed or a TEST-DUP · 2 usage error.
#>
param([string[]]$Area = 'all', [switch]$Slow, [switch]$Full)
$ErrorActionPreference = 'Stop'
if ($Slow) { $env:KIT_TESTS_SLOW = '1' }   # the area processes inherit it
# the real python first on PATH: a shim (pyenv-win python.bat runs chcp) flips the console code page all areas share, and a
# pwsh started meanwhile prints mojibake
$pyReal = foreach ($p in 'python', 'python3') { if (Get-Command $p -ErrorAction SilentlyContinue) { & $p -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1; break } }
if ($pyReal) { $env:PATH = (Split-Path $pyReal) + [IO.Path]::PathSeparator + $env:PATH }
# one file per area; each dot-sources harness.ps1
$files = @(Get-ChildItem $PSScriptRoot -Filter '*.tests.ps1' | Sort-Object Name | ForEach-Object Name)
$all = @($files | ForEach-Object { $_ -replace '\.tests\.ps1$' })
$areas = if ($Area -contains 'all') { $all } else { @($Area | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
$unknown = @($areas | Where-Object { $_ -notin $all })
if (-not $areas -or $unknown) { Write-Error "kit-tests.ps1: unknown or no area(s) '$($unknown -join ', ')'; known: $($all -join ', ')" -ErrorAction Continue; exit 2 }
# areas on a scratch DB server run in 'all' only when a path they test changed since origin/main (-Full / KIT_TESTS_FULL=1: always)
$dbRx = '^(skills/envy/|skills/crafty/(lib\.ps1|adapters/)|tests/(harness\.ps1|kit-tests\.ps1|db-engine-presets))'; $onChange = @{ 'db-engine-presets' = $dbRx; 'db-engine-presets-2' = $dbRx }
if ($Area -contains 'all' -and -not ($Full -or $env:KIT_TESTS_FULL)) {
  $kitDir = Split-Path $PSScriptRoot; $base = "$(git -C $kitDir merge-base HEAD origin/main 2>$null)".Trim()
  $changed = if ($base) { @(git -C $kitDir diff --name-only $base 2>$null) + @(git -C $kitDir ls-files --others --exclude-standard 2>$null) }
  if ($base) { foreach ($a in @($areas | Where-Object { $onChange[$_] -and -not @($changed -match $onChange[$_]).Count })) { "SKIP $a`: no change in what it tests (-Full runs it)"; $areas = @($areas | Where-Object { $_ -ne $a }) } }
}

# one snapshot of the source files for every area (harness.ps1 New-TestKit links to it); scratch of dead area runs removed
$kx = Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/kit.example.json'; $tmpMap = if (Test-Path $kx) { (Get-Content $kx -Raw | ConvertFrom-Json)._paths }
$tmpRoot = if ($tmpMap) { Join-Path (Join-Path (Split-Path $PSScriptRoot) $tmpMap.runtimeDir) $tmpMap.runtime.tmp.TrimEnd('/') } else { [IO.Path]::GetTempPath() }   # a bare tests/ copy (kitbag.tests)
foreach ($old in @(Get-ChildItem -LiteralPath $tmpRoot -Directory -Filter 'kit-tests-*' -ErrorAction SilentlyContinue)) {
  if ($old.Name -match '^kit-tests-(?:src-)?(\d+)$' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
$env:KIT_TESTS_SNAPSHOT = Join-Path $tmpRoot "kit-tests-src-$PID"
$started = Get-Date
$results = $areas | ForEach-Object -ThrottleLimit ([Math]::Min($areas.Count, 2 * [Environment]::ProcessorCount)) -Parallel {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $out = pwsh -NoProfile -File (Join-Path $using:PSScriptRoot "$_.tests.ps1") 2>&1 | Out-String
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
  if ($l -match '^(PASS|FAIL) (.+)') { [pscustomobject]@{ name = $Matches[2].Trim().ToLower() -replace '\s+', ' '; at = $at; text = $Matches[2].Trim(); fail = $Matches[1] -eq 'FAIL' } } } }
foreach ($d in $cases | Group-Object name | Where-Object Count -gt 1) { "TEST-DUP $($d.Name): $($d.Group.at -join ', ')"; $fails++ }
# TEST-WRITE: a snapshot file changed in place (through a hard link) changed every area's kit: copy it first (harness $TestKitWrites, Undo-TestKitLink)
foreach ($sf in @(Get-ChildItem -LiteralPath $env:KIT_TESTS_SNAPSHOT -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]_git[\\/]' })) {
  $rel = [IO.Path]::GetRelativePath($env:KIT_TESTS_SNAPSHOT, $sf.FullName); $s1 = Get-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) $rel) -ErrorAction SilentlyContinue
  if ($s1 -and $s1.LastWriteTimeUtc -lt $started.ToUniversalTime() -and $s1.LastWriteTimeUtc -ne $sf.LastWriteTimeUtc) { "TEST-WRITE $rel`: a test changed it in place through a hard link"; $fails++ } }
Remove-Item -LiteralPath $env:KIT_TESTS_SNAPSHOT -Recurse -Force -ErrorAction SilentlyContinue
# FAIL recap, indented: never counted twice
$failed = @($cases | Where-Object fail); if ($failed.Count) { 'Failed checks:'; $failed | ForEach-Object { "  [$($_.at)] $($_.text)" } }
"$fails failure(s) in $($areas.Count) area(s), $([int]((Get-Date) - $started).TotalSeconds) s"
exit [int]($fails -gt 0)
