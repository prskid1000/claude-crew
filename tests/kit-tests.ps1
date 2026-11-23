#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Runs tests/<area>.tests.ps1 files in parallel, one pwsh each; each area file also runs on its own.
Usage: pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area all|<any tests/<area>.tests.ps1>[,...]] [-Full] [-Slow] [-Detail] [-Detached]
 (none): the areas a change since the merge-base with origin/main reaches (Get-ChangedArea); -Full or -Area all (KIT_TESTS_FULL=1): every area.
 -Slow: also the checks that need real tools and take seconds each (KIT_TESTS_SLOW=1, e.g. a real headless Chrome).
 -Detail: every area's full output here too (else a green area is one line; all of it in <runtime>/logs/kit-tests-last.txt).
 K79: a run ends with what started it (a process of its parent chain gone: the run, its areas and their children stop) and,
 on Windows, its areas die with it (a kill-on-close job); -Detached: no parent watch (the nightly run, started by a short beat).
Outputs: the picked areas and why, per area its time and pass count (a failed or crashed area: its whole output), TEST-DUP lines (one case name in two places), TEST-WRITE lines (a test changed a shared snapshot file), TEST-ROOT lines (a new entry at a drive root), TEST-MYSQLD (the one test mysqld started twice: tests/test-mysql.ps1), a recap of the failed checks, then a total.
 A green full run of a clean tree stamps its tree and date in the main clone's cache (kit-tests-green.txt). No git hook runs it: the agent runs the touched areas before it
 commits and pushes; -Full runs from supervise -AutoFix while idle, every kitTests.fullEveryDays, a stamped tree skipped (adapters/kit_admin.ps1). One setup per area: a new case
 joins the area that builds its setup, as a table row.
Exit codes: 0 pass · 1 a check failed or a TEST-DUP · 2 usage error.
#>
param([string[]]$Area = @(), [switch]$Slow, [switch]$Full, [switch]$Detail, [switch]$Detached)
$ErrorActionPreference = 'Stop'
if ($Slow) { $env:KIT_TESTS_SLOW = '1' }   # the area processes inherit it
Set-Location -LiteralPath (Split-Path $PSScriptRoot)   # areas run in the kit under test: a cwd in another clone (the live kit) failed local-env-3, runtimes
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
    if ($f -match '^tests/(harness|kit-tests|hostverb-shim|test-mysql)\.ps1$|^skills/crafty/adapters/' -or (-not $own -and $f -notmatch '\.md$' -and $harness.Contains("'$f'"))) { $whyAll = $f; break }
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
# a harness that does not parse loads no helpers (Kd, Assert-TestPath): an area then writes "$empty/app" at the drive root (D:\app, 2026-11-23)
$unparsed = foreach ($pf in @('harness.ps1') + @($areas | ForEach-Object { "$_.tests.ps1" }) | Where-Object { Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) }) { $pe = $null; $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $pf), [ref]$null, [ref]$pe); if ($pe) { "$pf`:$($pe[0].Extent.StartLineNumber) $($pe[0].Message)" } }
if ($unparsed) { Write-Error "kit-tests.ps1: no area runs, parse errors: $($unparsed -join ' · ')" -ErrorAction Continue; exit 2 }

# one snapshot of the source files for every area (harness.ps1 New-TestKit links to it); scratch of dead area runs removed
$kx = Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/kit.example.json'; $tmpMap = if (Test-Path $kx) { (Get-Content $kx -Raw | ConvertFrom-Json)._paths }
$tmpRoot = if ($tmpMap) { Join-Path (Join-Path (Split-Path $PSScriptRoot) $tmpMap.runtimeDir) $tmpMap.runtime.tmp.TrimEnd('/') } else { [IO.Path]::GetTempPath() }   # a bare tests/ copy (kitbag.tests)
foreach ($old in @(Get-ChildItem -LiteralPath $tmpRoot -Directory -Filter 'kit-tests-*' -ErrorAction SilentlyContinue)) {
  if ($old.Name -match '^kit-tests-(?:src-)?(\d+)$' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
$env:KIT_TESTS_SNAPSHOT = Join-Path $tmpRoot "kit-tests-src-$PID"; $null = New-Item -ItemType Directory -Force $env:KIT_TESTS_SNAPSHOT; Set-Content -LiteralPath (Join-Path $env:KIT_TESTS_SNAPSHOT '.owner') $PID   # harness: a snapshot whose owner is gone is stale
# timing bounds stretch with the load this run puts on the CPU (harness Get-TestBound): 1 alone, at most 3
if (-not $env:KIT_TESTS_SLACK) { $env:KIT_TESTS_SLACK = [Math]::Round([Math]::Min(3, [Math]::Max(1, $areas.Count / [Environment]::ProcessorCount)), 2).ToString([Globalization.CultureInfo]::InvariantCulture) }
$started = Get-Date
# TEST-ROOT: what each drive root holds now ("$empty/x" = "/x" wrote origin.git, repo, one.txt at D:\, 2026-11-22)
$driveRoots = @((Get-Location).Path, $tmpRoot | ForEach-Object { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)) } | Select-Object -Unique)   # the cwd's and the tests' temp drive: where "/x" lands
$rootsBefore = @{}; foreach ($dr in $driveRoots) { $rootsBefore[$dr] = @(Get-ChildItem -LiteralPath $dr -Force -Name -ErrorAction SilentlyContinue) }
$env:KIT_TESTS_RUNNER = $PID   # the one test mysqld's holder for every area of this run (test-mysql.ps1)
$src = Split-Path $PSScriptRoot; $myMysqlRun = [pscustomobject]@{ starts = 0; strays = @() }; $myMysqlErr = ''
$myMysql = (Test-Path (Join-Path $PSScriptRoot 'test-mysql.ps1')) -and (Test-Path (Join-Path $src 'skills/crafty/kit.example.json'))   # a bare tests/ copy (kitbag.tests): none
if ($myMysql) { . (Join-Path $PSScriptRoot 'test-mysql.ps1') }
# K79 (finished agents left 2-5 h test trees; a push hung 25 min): areas and their children join a kill-on-close job (Windows)
if ($IsWindows -and -not [AppDomain]::CurrentDomain.GetData('kit-tests-job')) {
  try {
    if (-not ('KitTestJob' -as [type])) {   # compiled once per runtime (1.7 s), loaded after
      $jobCs = @'
using System; using System.Runtime.InteropServices;
public static class KitTestJob {
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long a, b; public uint Flags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
  [StructLayout(LayoutKind.Sequential)] struct Io { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct Ext { public Basic B; public Io I; public UIntPtr p, j, pp, jp; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref Ext i, uint l);
  [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  public static IntPtr Bind() {   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: the handle closes with this process, the job's processes end
    IntPtr j = CreateJobObject(IntPtr.Zero, null); Ext x = new Ext(); x.B.Flags = 0x2000;
    if (j == IntPtr.Zero || !SetInformationJobObject(j, 9, ref x, (uint)Marshal.SizeOf(typeof(Ext))) || !AssignProcessToJobObject(j, GetCurrentProcess())) throw new System.ComponentModel.Win32Exception();
    return j;
  }
}
'@
      if (-not $env:KIT_TESTS_JOB_DIR) { $env:KIT_TESTS_JOB_DIR = $tmpRoot }   # a nested run (kitbag's copied runner) loads it, no cold compile under load (K95)
      $jobDll = Join-Path (New-Item -ItemType Directory -Force $env:KIT_TESTS_JOB_DIR) "kit-test-job-$([Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($jobCs))).Substring(0, 8)).dll"   # a changed source: a new file
      if (-not (Test-Path -LiteralPath $jobDll)) { $jobTmp = "$jobDll.$PID"; Add-Type -OutputAssembly $jobTmp -TypeDefinition $jobCs
        try { Move-Item -LiteralPath $jobTmp $jobDll -ErrorAction Stop } catch { Remove-Item -LiteralPath $jobTmp -ErrorAction SilentlyContinue } }   # a parallel run's copy won
      Add-Type -LiteralPath $jobDll }
    [AppDomain]::CurrentDomain.SetData('kit-tests-job', [KitTestJob]::Bind())
  } catch { "kit-tests: no kill-on-close job ($($_.Exception.Message)): a killed run may leave its areas running" }
}
# the parent chain (pid:start ticks, at most 8 up); one gone -> a thread ends this run's tree, lets the test mysqld go, then this process
$watch = @(if (-not $Detached -and -not [AppDomain]::CurrentDomain.GetData('kit-tests-watch')) {
  $wc = Get-Process -Id $PID
  for ($wi = 0; $wi -lt 8; $wi++) { $wp = try { $wc.Parent } catch { $null }; $ws = try { $wp.StartTime } catch { $null }
    if (-not $wp -or -not $ws -or $wp.Id -le 4 -or $ws -gt $wc.StartTime) { break }   # a reused parent id starts after its child
    "$($wp.Id):$($ws.ToUniversalTime().Ticks)"; $wc = $wp } })
if ($watch.Count) {
  [AppDomain]::CurrentDomain.SetData('kit-tests-watch', $true)
  $wd = [powershell]::Create(); $null = $wd.AddScript({ param($Watch, $Me, $MysqlFile, $Kit)
    $alive = { param($s) $s -match '^(\d+):(\d+)$' -and "$(try { (Get-Process -Id $Matches[1] -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch {})" -eq $Matches[2] }
    while (-not ($gone = @($Watch | Where-Object { -not (& $alive $_) })[0])) { Start-Sleep 5 }
    [Console]::Out.WriteLine("kit-tests: process $gone that started this run is gone: the run, its areas and their children stop (K79)")
    $mine = (Get-Process -Id $Me).StartTime
    foreach ($kid in @(Get-Process | Where-Object { $(try { $_.Parent.Id -eq $Me -and $_.StartTime -ge $mine } catch { $false }) })) { try { $kid.Kill($true) } catch {} }
    if ($MysqlFile) { try { . $MysqlFile; $src = $Kit; $null = Exit-TestMySqlHolder (Get-TestMySqlHome) $Me } catch {} }   # areas gone: the lock is free
    [Diagnostics.Process]::GetCurrentProcess().Kill()
  }).AddArgument($watch).AddArgument($PID).AddArgument($(if ($myMysql) { Join-Path $PSScriptRoot 'test-mysql.ps1' })).AddArgument($src).BeginInvoke()
}
# area slots machine-wide (2 x cores, the shared test home): parallel runs share the CPU one run's timing bounds assume (K95)
$slotDir = if ($env:KIT_TESTS_SLOT_DIR) { $env:KIT_TESTS_SLOT_DIR } elseif ($myMysql) { New-Item -ItemType Directory -Force (Join-Path (Get-TestMySqlHome) 'area-slots') }
try {
$results = $areas | ForEach-Object -ThrottleLimit ([Math]::Min($areas.Count, 2 * [Environment]::ProcessorCount)) -Parallel {
  # a slot = an open file no one else may open; a killed run's slots free with its process. poll-ok: bounded, 30 min
  $slot = $null; $told = $false; $due = (Get-Date).AddMinutes(30)
  while ($using:slotDir -and -not $slot -and (Get-Date) -lt $due) {
    foreach ($si in 1..(2 * [Environment]::ProcessorCount)) { try { $slot = [IO.File]::Open((Join-Path $using:slotDir "$si.slot"), 'OpenOrCreate', 'ReadWrite', 'None'); break } catch {} }
    if (-not $slot -and -not $told) { $told = $true; Write-Host "  $_ waits for a test slot (other kit-tests runs hold all)"; try { [IO.File]::WriteAllText((Join-Path $using:slotDir 'waiting'), $_) } catch {} }
    if (-not $slot) { Start-Sleep -Milliseconds 500 } }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try { $out = pwsh -NoProfile -File (Join-Path $using:PSScriptRoot "$_.tests.ps1") 2>&1 | Out-String } finally { if ($slot) { $slot.Dispose() } }
  Write-Host "  $_ done ($([int]$clock.Elapsed.TotalSeconds) s)"   # progress while the slower areas run
  [pscustomobject]@{ area = $_; out = $out.TrimEnd(); code = $LASTEXITCODE; seconds = [int]$clock.Elapsed.TotalSeconds }
} | Sort-Object { [array]::IndexOf($areas, $_.area) }   # area order, not finish order: output and TEST-DUP lists stay stable
} finally {   # Ctrl-C or a crash too: this run lets the test mysqld go (it stops, data kept, when no other run holds it)
  if ($myMysql) { try { $myMysqlRun = Exit-TestMySqlHolder (Get-TestMySqlHome) $PID } catch { $myMysqlErr = $_.Exception.Message } }
}
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
if ($myMysqlErr) { "TEST-MYSQLD the test mysqld did not stop: $myMysqlErr" }
if ($myMysqlRun.starts -gt 1) { "TEST-MYSQLD this run started the test mysqld $($myMysqlRun.starts) times (at most 1: tests/test-mysql.ps1)"; $fails++ }
foreach ($sy in @($myMysqlRun.strays)) { "TEST-MYSQLD a second kit-test mysqld ran during this run (one at a time machine-wide): $(($sy -split " ", 2)[1])"; $fails++ }
foreach ($dr in $driveRoots) { foreach ($nw in @(Get-ChildItem -LiteralPath $dr -Force -Name -ErrorAction SilentlyContinue | Where-Object { $_ -notin $rootsBefore[$dr] -and $_ -notmatch '^\$|\.sys$' })) {
  "TEST-ROOT $(Join-Path $dr $nw): new at a drive root during this run (a test or another process; a test's `"`$empty/<name>`": build it with harness Assert-TestPath)"; $fails++ } }
# FAIL recap, indented: never counted twice
$failed = @($cases | Where-Object fail); if ($failed.Count) { 'Failed checks:'; $failed | ForEach-Object { "  [$($_.at)] $($_.text)" } }
"$fails failure(s) in $($areas.Count) area(s), $([int]((Get-Date) - $started).TotalSeconds) s"
# a green full run of a clean tree: "<tree id> <date>" in the main clone's cache (a worktree's cache goes with it): the weekly full
# run skips a stamped tree; health names the date of the kit's tree as its last green
$kitDir = Split-Path $PSScriptRoot
if ($Full -and -not $fails -and $tmpMap -and -not (git -C $kitDir status --porcelain 2>$null)) {
  $gMain = "$(git -C $kitDir rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim() -replace '[\\/]\.git$', ''
  $gRoot = if ($gMain -and (Test-Path (Join-Path $gMain 'skills/crafty/kit.example.json'))) { $gMain } else { $kitDir }
  $tree = "$(git -C $kitDir rev-parse 'HEAD^{tree}' 2>$null)".Trim(); $gf = Join-Path (Join-Path (Join-Path $gRoot $tmpMap.runtimeDir) $tmpMap.runtime.cache) 'kit-tests-green.txt'
  if ($tree) { $null = New-Item -ItemType Directory -Force (Split-Path $gf); @(@(Get-Content -LiteralPath $gf -ErrorAction SilentlyContinue) + "$tree $((Get-Date).ToString('o'))" | Select-Object -Last 20) | Set-Content -LiteralPath $gf; "green full run: tree $tree stamped ($gf)" } }
exit [int]($fails -gt 0)
