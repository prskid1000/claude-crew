#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Runs tests/<area>.tests.ps1 files in parallel, one pwsh each; each area file also runs on its own.
Usage: pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area all|<any tests/<area>.tests.ps1>[,...]] [-Full] [-Slow] [-Detail]
 (none): the areas a change since the merge-base with origin/main reaches (Get-ChangedArea); -Full or -Area all (KIT_TESTS_FULL=1): every area.
 -Slow: also the checks that need real tools and take seconds each (KIT_TESTS_SLOW=1, e.g. a real headless Chrome).
 -Detail: every area's full output here too (else a green area is one line; all of it in <runtime>/logs/kit-tests-last.txt).
Outputs: the picked areas and why, per area its time and pass count (a failed or crashed area: its whole output), TEST-DUP lines (one case name in two places), TEST-WRITE lines (a test changed a shared snapshot file), TEST-MYSQLD (the one test mysqld started twice: tests/test-mysql.ps1), a recap of the failed checks, then a total.
 A green full run stamps its tree (<runtime>/cache/kit-tests-green.txt). -Full also runs from the pre-push hook on a push to main
 (a stamped tree skipped) and from supervise -AutoFix once a day while idle (adapters/kit_admin.ps1). One setup per area: a new case
 joins the area that builds its setup, as a table row.
Exit codes: 0 pass · 1 a check failed or a TEST-DUP · 2 usage error.
#>
param([string[]]$Area = @(), [switch]$Slow, [switch]$Full, [switch]$Detail)
$ErrorActionPreference = 'Stop'
if ($Slow) { $env:KIT_TESTS_SLOW = '1' }   # the area processes inherit it
# the areas a change reaches: a test file -> its area; the runner, the harness, a crafty adapter or another non-.md file the harness
# copies into every kit -> all; else the areas naming the file (+ its skill's script for an adapter, kitbag.py for kitbag_*; a
# generated .<dir>/ file: the areas naming .<dir>/); a non-.md file no area names -> all. -Full (pre-push to main) closes the rest.
function Get-ChangedArea([string]$KitDir, [string[]]$Known) {
  $base = "$(git -C $KitDir merge-base HEAD origin/main 2>$null)".Trim()
  if (-not $base) { return [pscustomobject]@{ areas = $Known; why = 'no merge-base with origin/main: all' } }
  $changed = @(@(git -c core.quotepath=off -C $KitDir diff --name-only $base 2>$null) + @(git -c core.quotepath=off -C $KitDir ls-files --others --exclude-standard 2>$null) | Where-Object { $_ } | Select-Object -Unique)
  $harness = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'harness.ps1')); $texts = @{}; foreach ($a in $Known) { $texts[$a] = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "$a.tests.ps1")) }
  $pick = [Collections.Generic.List[string]]::new(); $whyAll = ''
  $names = { param($n) $rn = [regex]::Escape($n); @($Known | Where-Object { $texts[$_] -match "(?<![\w.-])$rn(?![\w-])" }) }
  foreach ($f in $changed) {
    # lib.ps1 loads every crafty adapter into every script; another skill's adapter loads with its skill's script only
    $own = if ($f -match '^skills/(\w+)/adapters/' -and $Matches[1] -ne 'crafty') { "$($Matches[1]).ps1" } elseif ($f -match '^skills/bossy/(kitbag_\w+\.py|lint-vocab\.json)$') { 'kitbag.py' }
    if ($f -match '^tests/(harness|kit-tests|hostverb-shim)\.ps1$|^skills/crafty/adapters/' -or (-not $own -and $f -notmatch '\.md$' -and $harness.Contains("'$f'"))) { $whyAll = $f; break }
    if ($f -match '^tests/(.+)\.tests\.ps1$') { if ($Matches[1] -in $Known) { $pick.Add($Matches[1]) }; continue }
    $hit = @(& $names (Split-Path $f -Leaf)); if ($own) { $hit += & $names $own }
    if (-not $hit.Count -and $f -match '^(\.\w+)/') { $hit = @(& $names "$($Matches[1])/") }   # a generated port (.codex/...): the areas testing that folder
    if ($hit.Count) { $pick.AddRange([string[]]$hit) } elseif ($f -notmatch '\.md$') { $whyAll = "$f (no area names it)"; break }
  }
  if ($whyAll) { return [pscustomobject]@{ areas = $Known; why = "$whyAll changed: all" } }
  [pscustomobject]@{ areas = @($Known | Where-Object { $_ -in $pick }); why = "$($changed.Count) changed file(s) since origin/main" }
}
# the real python first on PATH: a shim (pyenv-win python.bat runs chcp) flips the console code page all areas share, and a
# pwsh started meanwhile prints mojibake
$pyReal = foreach ($p in 'python', 'python3') { if (Get-Command $p -ErrorAction SilentlyContinue) { & $p -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1; break } }
if ($pyReal) { $env:PATH = (Split-Path $pyReal) + [IO.Path]::PathSeparator + $env:PATH }
# one file per area; each dot-sources harness.ps1
$files = @(Get-ChildItem $PSScriptRoot -Filter '*.tests.ps1' | Sort-Object Name | ForEach-Object Name)
$all = @($files | ForEach-Object { $_ -replace '\.tests\.ps1$' })
$Full = $Full -or $Area -contains 'all' -or ([bool]$env:KIT_TESTS_FULL -and -not $Area.Count)
$areas = if ($Full) { $all } elseif ($Area.Count) { @($Area | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
if (-not $Full -and -not $Area.Count) {
  $ch = Get-ChangedArea (Split-Path $PSScriptRoot) $all; $areas = @($ch.areas)
  "areas: $($ch.why) -> $($areas.Count) of $($all.Count)$(if ($areas.Count -lt $all.Count) { ' (-Full runs all)' })"
  if (-not $areas.Count) { 'no area tests what changed: nothing to run'; exit 0 } }
$unknown = @($areas | Where-Object { $_ -notin $all })
if (-not $areas -or $unknown) { Write-Error "kit-tests.ps1: unknown or no area(s) '$($unknown -join ', ')'; known: $($all -join ', ')" -ErrorAction Continue; exit 2 }

# one snapshot of the source files for every area (harness.ps1 New-TestKit links to it); scratch of dead area runs removed
$kx = Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/kit.example.json'; $tmpMap = if (Test-Path $kx) { (Get-Content $kx -Raw | ConvertFrom-Json)._paths }
$tmpRoot = if ($tmpMap) { Join-Path (Join-Path (Split-Path $PSScriptRoot) $tmpMap.runtimeDir) $tmpMap.runtime.tmp.TrimEnd('/') } else { [IO.Path]::GetTempPath() }   # a bare tests/ copy (kitbag.tests)
foreach ($old in @(Get-ChildItem -LiteralPath $tmpRoot -Directory -Filter 'kit-tests-*' -ErrorAction SilentlyContinue)) {
  if ($old.Name -match '^kit-tests-(?:src-)?(\d+)$' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
$env:KIT_TESTS_SNAPSHOT = Join-Path $tmpRoot "kit-tests-src-$PID"
# timing bounds stretch with the load this run puts on the CPU (harness Get-TestBound): 1 alone, at most 3
if (-not $env:KIT_TESTS_SLACK) { $env:KIT_TESTS_SLACK = [Math]::Round([Math]::Min(3, [Math]::Max(1, $areas.Count / [Environment]::ProcessorCount)), 2).ToString([Globalization.CultureInfo]::InvariantCulture) }
$started = Get-Date
$env:KIT_TESTS_RUNNER = $PID   # the one test mysqld's holder for every area of this run (test-mysql.ps1)
$results =$areas | ForEach-Object -ThrottleLimit ([Math]::Min($areas.Count, 2 * [Environment]::ProcessorCount)) -Parallel {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $out = pwsh -NoProfile -File (Join-Path $using:PSScriptRoot "$_.tests.ps1") 2>&1 | Out-String
  Write-Host "  $_ done ($([int]$clock.Elapsed.TotalSeconds) s)"   # progress while the slower areas run
  [pscustomobject]@{ area = $_; out = $out.TrimEnd(); code = $LASTEXITCODE; seconds = [int]$clock.Elapsed.TotalSeconds }
} | Sort-Object { [array]::IndexOf($areas, $_.area) }   # area order, not finish order: output and TEST-DUP lists stay stable
$fails = 0; $logLines = [Collections.Generic.List[string]]::new()
foreach ($r in $results) {
  $f0 = $fails
  # a crash before Complete-Tests prints no count: its FAIL lines, at least one
  if ($r.out -match '(?m)^(\d+) failure\(s\)\s*\z') { $fails += [int]$Matches[1] }
  elseif ($r.code) { $fails += [Math]::Max(1, ([regex]::Matches($r.out, '(?m)^FAIL ')).Count) }
  $logLines.Add("== $($r.area) ($($r.seconds) s)"); $logLines.Add($r.out)
  # a green area is one line here (its output reads tokens, not news); a failed one in full
  if ($Detail -or $fails -gt $f0 -or $r.code) { "== $($r.area) ($($r.seconds) s)"; $r.out } else { $sk = ([regex]::Matches($r.out, '(?m)^SKIP ')).Count; "== $($r.area) ($($r.seconds) s): $(([regex]::Matches($r.out, '(?m)^PASS ')).Count) passed$(if ($sk) { ", $sk skipped" })" }
}
if ($tmpMap) { $lastLog = Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot) $tmpMap.runtimeDir) $tmpMap.runtime.logs) 'kit-tests-last.txt'; try { $null = New-Item -ItemType Directory -Force (Split-Path $lastLog); $logLines | Set-Content -LiteralPath $lastLog; "every area's output: $lastLog" } catch { "every area's output: not written ($($_.Exception.Message)): -Detail prints it" } }
elseif (-not $Detail) { 'no kit.example.json runtime map: no output log (-Detail prints every area)' }
# TEST-DUP: one behaviour, one case: a case name (its PASS / FAIL line, case and spaces ignored) twice fails the run
$cases = foreach ($r in $results) { $at = $r.area; foreach ($l in $r.out -split '\r?\n') {
  if ($l -match '^(PASS|FAIL) (.+)') { [pscustomobject]@{ name = $Matches[2].Trim().ToLower() -replace '\s+', ' '; at = $at; text = $Matches[2].Trim(); fail = $Matches[1] -eq 'FAIL' } } } }
foreach ($d in $cases | Group-Object name | Where-Object Count -gt 1) { "TEST-DUP $($d.Name): $($d.Group.at -join ', ')"; $fails++ }
# TEST-WRITE: a snapshot file changed in place (through a hard link) changed every area's kit: copy it first (harness $TestKitWrites, Undo-TestKitLink)
foreach ($sf in @(Get-ChildItem -LiteralPath $env:KIT_TESTS_SNAPSHOT -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]_git[\\/]' })) {
  $rel = [IO.Path]::GetRelativePath($env:KIT_TESTS_SNAPSHOT, $sf.FullName); $s1 = Get-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) $rel) -ErrorAction SilentlyContinue
  if ($s1 -and $s1.LastWriteTimeUtc -lt $started.ToUniversalTime() -and $s1.LastWriteTimeUtc -ne $sf.LastWriteTimeUtc) { "TEST-WRITE $rel`: a test changed it in place through a hard link"; $fails++ } }
Remove-Item -LiteralPath $env:KIT_TESTS_SNAPSHOT -Recurse -Force -ErrorAction SilentlyContinue
# TEST-MYSQLD (K78): at most one test mysqld start per run; it stops here (data kept) unless another run still holds it
$src = Split-Path $PSScriptRoot; . (Join-Path $PSScriptRoot 'test-mysql.ps1')
$myStarts = 0; try { $myStarts = Exit-TestMySqlHolder (Get-TestMySqlHome) $PID } catch { "TEST-MYSQLD the test mysqld did not stop: $($_.Exception.Message)" }
if ($myStarts -gt 1) { "TEST-MYSQLD this run started the test mysqld $myStarts times (at most 1: tests/test-mysql.ps1)"; $fails++ }
# FAIL recap, indented: never counted twice
$failed = @($cases | Where-Object fail); if ($failed.Count) { 'Failed checks:'; $failed | ForEach-Object { "  [$($_.at)] $($_.text)" } }
"$fails failure(s) in $($areas.Count) area(s), $([int]((Get-Date) - $started).TotalSeconds) s"
# a green full run of a clean tree: its tree id stamped (the pre-push hook skips a stamped tree)
$kitDir = Split-Path $PSScriptRoot
if ($Full -and -not $fails -and $tmpMap -and -not (git -C $kitDir status --porcelain 2>$null)) {
  $tree = "$(git -C $kitDir rev-parse 'HEAD^{tree}' 2>$null)".Trim(); $gf = Join-Path (Join-Path (Join-Path $kitDir $tmpMap.runtimeDir) $tmpMap.runtime.cache) 'kit-tests-green.txt'
  if ($tree) { $null = New-Item -ItemType Directory -Force (Split-Path $gf); @(@(Get-Content -LiteralPath $gf -ErrorAction SilentlyContinue) + $tree | Select-Object -Last 20) | Set-Content -LiteralPath $gf; "green full run: tree $tree stamped" } }
exit [int]($fails -gt 0)
