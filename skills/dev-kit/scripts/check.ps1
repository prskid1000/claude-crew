<#
One command for "does my change build and pass?" in any repo. Detects the stack (stack.ps1), fills in the
command and runs it through the memory gate (gate.ps1).

  $K = '<workspace>/.claude/skills/dev-kit/scripts'
  & $K/check.ps1 -Dir <dir>                                   # quick: compile + typecheck + lint (whatever the stack has)
  & $K/check.ps1 -Dir <dir> -Step test -Tests "FooTest,BarTest"
  & $K/check.ps1 -Dir <dir> -Step test -Tests "src/a.spec.ts"
  & $K/check.ps1 -Dir <dir> -Step lint -Files "src/a.ts src/b.ts"
  & $K/check.ps1 -Dir <dir> -Step build                       # full build (heavy, use before shipping only)
  & $K/check.ps1 -Dir <dir> -Step migrations                  # Liquibase sanity check, if the repo has master.xml
  & $K/check.ps1 -Dir <dir> -Show                             # print what would run

-Dir is the folder with the build file (pom.xml, package.json, *.sln, pyproject.toml, ...), or anything below it.
Tests are targeted: -Step test needs -Tests unless you pass -AllTests (full suites are slow and eat RAM).
A web project with no unit-test target runs its specs with node-spec.mjs (specs under node, DOM specs under the project's jsdom, no TestBed).
Quick lint checks the files changed on the branch plus untracked ones. TypeScript typecheck output goes to
<runtime>/logs/typecheck-<repo>-<time>.log; on TS5103 (an ignoreDeprecations value the installed TypeScript rejects) it retries
once with a temp tsconfig and then prints only the errors in your changed files plus one BASELINE line, failing only on yours.
A per-project marker (<runtime>/cache/tsbuild/ts5103.<hash>.flag, keyed on the ignoreDeprecations value and the TypeScript version)
makes later runs skip the first tsc run that is bound to fail; a baseline-only fallback run is recorded as ok in the gate history.
A node-spec test run uses the real @angular/core with -RealAngular (auto-on when a named spec imports @angular/forms). Container tests
(*ContainerTest / *IT, or Testcontainers in the module) first need `docker info` to answer within 5 s, else exit 4 with a start hint.
A fallback typecheck whose baseline exceeds 200 errors is reported UNRUN (linked node_modules do not match the branch), not ok.
Exit code: 0 ok, non-zero = the first failing step's exit code (3 = the gate could not start it in time, 4 = Docker not running).
#>
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$Since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),   # migrations: only report changelog files named with a timestamp >= this
  [switch]$Show,
  [switch]$RealAngular   # test with node-spec.mjs: real @angular/core instead of the stub (auto-on when a named spec imports @angular/forms)
)
$ErrorActionPreference = 'Stop'
$K = Split-Path $MyInvocation.MyCommand.Path
. (Join-Path $K 'sysinfo.ps1')
$st = & (Join-Path $K 'stack.ps1') -Dir $Dir -Json | ConvertFrom-Json
Write-Host "[check] $($st.stack) in $($st.dir)"

# Files changed on this branch (full paths, existing, under the stack dir): the diff against where the branch left its target
# plus untracked files git does not ignore. Base = the worktree's recorded target (wt.ps1 new), else the remote's default branch
# (origin/HEAD), else the upstream. (@{upstream} alone is the pushed branch itself, so after a push or commit quick lint used to
# see only uncommitted files.)
function Get-ChangedFiles {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $gd = (git -C $st.dir rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
  $tgt = if (Test-Path (Join-Path $gd 'claude-target')) { "origin/$((Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim())" }
  $refs = @($tgt, ((git -C $st.dir symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null) | Select-Object -First 1), '@{upstream}') | Where-Object { $_ }
  $base = $null; foreach ($r in $refs) { $base = (git -C $st.dir merge-base HEAD $r 2>$null); if ($LASTEXITCODE -eq 0 -and $base) { break }; $base = $null }
  $list = @(git -C $st.dir diff --name-only --diff-filter=ACMR $(if ($base) { $base } else { 'HEAD' }) -- . 2>$null) +
          @(git -C $st.dir ls-files --others --exclude-standard --full-name -- . 2>$null)
  @($list | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

# tsc typecheck through the gate with its output in <runtime>/logs. On TS5103 (or a cached TS5103 marker) retry once with a temp tsconfig (runtime cache, deleted
# after) that extends the project's and sets a valid ignoreDeprecations, using the repo's own node_modules/.bin/tsc; then print only
# the errors in changed files plus a BASELINE line for the rest, and fail only on changed files (and on config errors, TS5xxx/TS6xxx).
function Invoke-Typecheck([string]$TcCmd) {
  . (Join-Path $K 'kitpaths.ps1')
  $top = git -C $st.dir rev-parse --show-toplevel 2>$null
  $top = if ($top) { [IO.Path]::GetFullPath("$top".Trim()) } else { $null }
  $repo = Split-Path $(if ($top) { $top } else { $st.dir }) -Leaf
  $log = Join-Path (Get-KitPath logs -Create) "typecheck-$repo-$(Get-Date -Format yyyyMMdd-HHmmss).log"
  $proj = if ($TcCmd -match '\s-p\s+"?([^"\s]+)"?') { $Matches[1] } else { 'tsconfig.json' }
  $base = [IO.Path]::GetFullPath((Join-Path $st.dir $proj))
  # the repo's own tsc: nearest node_modules/.bin going up to the git root (a worktree links node_modules from its main checkout)
  $bin = $null; $d = $st.dir
  while ($d) {
    $p = Join-Path $d "node_modules/.bin/$(if ($KitIsWindows) { 'tsc.cmd' } else { 'tsc' })"
    if (Test-Path -LiteralPath $p) { $bin = $p; break }
    if (-not $top -or $d -eq $top) { break }
    $parent = Split-Path $d; if (-not $parent -or $parent -eq $d) { break }; $d = $parent
  }
  $ver = '5.0'; $tsVer = ''
  if ($bin) { try { $tsVer = [string](Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $bin)) 'typescript/package.json') -Raw | ConvertFrom-Json).version; if ([int](($tsVer -split '\.')[0]) -ge 6) { $ver = '6.0' } } catch {} }
  $raw = try { Get-Content -LiteralPath $base -Raw } catch { '' }
  # TS5103 is decided by the project's ignoreDeprecations value and the installed TypeScript: once hit, a marker keyed on both skips
  # the first tsc run (bound to fail, ~10-15 s and ~1 GB each time); a changed value or TypeScript version gives a new key
  $igd = if ($raw -match '"ignoreDeprecations"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
  $md5 = { param($s) [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '').Substring(0, 12) }
  $flag = Join-Path (Get-KitPath tsbuild -Create) "ts5103.$(& $md5 "$($base.ToLower())|$igd|$tsVer").flag"
  if (Test-Path -LiteralPath $flag) {
    $out = @()
    Write-Host "[check] TS5103 known for this project (marker $(Split-Path $flag -Leaf)): skipping the first tsc run"
  } else {
    & (Join-Path $K 'gate.ps1') -Dir $st.dir -Cmd "$TcCmd > `"$log`" 2>&1"
    $rc = $LASTEXITCODE
    $out = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $nErr = @($out -match '^(.+?\(\d+,\d+\): )?error TS\d+').Count
    if (-not @($out -match 'error TS5103').Count) {
      # hundreds of errors on a plain run: split them like the fallback below (yours fail; a huge baseline is UNRUN)
      if ($rc -and $nErr -gt $script:TypecheckUnrunAbove) { return (Split-TypecheckErrors $out $rc $null $null) }
      $out | ForEach-Object { Write-Host $_ }
      if ($rc -and $out.Count) { Write-Host "[check] typecheck log: $log" }
      return $rc
    }
    Set-Content -LiteralPath $flag -Value "$base | ignoreDeprecations '$igd' | typescript $tsVer"
  }
  $cfg = [ordered]@{ extends = $base.Replace('\', '/'); compilerOptions = @{ ignoreDeprecations = $ver } }
  # without files/include in the project's config, tsc's default include is the folder of the -p config (the temp one): pin it
  if ($raw -notmatch '"(files|include)"\s*:') {
    $pd = (Split-Path $base).Replace('\', '/')
    $ex = @('node_modules', 'bower_components', 'jspm_packages')
    try { $j = $raw | ConvertFrom-Json; if ($j.exclude) { $ex = @($j.exclude) } } catch {}
    $cfg.include = @("$pd/**/*")
    $cfg.exclude = @($ex | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { "$pd/$_" } })
  }
  $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($st.dir.ToLower()))).Replace('-', '').Substring(0, 12)
  $tmp = Join-Path (Get-KitPath cache -Create) "tsconfig.ts5103.$hash.$PID.json"
  $tsb = Join-Path (Get-KitPath tsbuild -Create) "$hash.ts5103.tsbuildinfo"
  $tsc = if ($bin) { "`"$bin`"" } else { 'npx tsc' }
  Write-Host "[check] typecheck TS5103 (ignoreDeprecations) fallback: running with a temp tsconfig (ignoreDeprecations $ver) and $(if ($bin) { $bin } else { 'npx tsc' })"
  $fbCmd = "$tsc -p `"$tmp`" --noEmit --pretty false --incremental --tsBuildInfoFile `"$tsb`" >> `"$log`" 2>&1"
  $fbStart = [DateTimeOffset]::Now
  try {
    $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    & (Join-Path $K 'gate.ps1') -Dir $st.dir -Cmd $fbCmd
    $rc = $LASTEXITCODE
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  $out2 = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Skip $out.Count })
  if ($rc -eq 3 -and -not $out2.Count) { return 3 }   # the gate could not start it
  if (@($out2 -match 'error TS5103').Count) { Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue }   # the fallback is no cure here: next run starts over
  return (Split-TypecheckErrors $out2 $rc $fbCmd $fbStart)
}

# Errors in changed files (and config errors) fail the check; the rest is the BASELINE. A baseline above $TypecheckUnrunAbove means
# the node_modules do not match the branch: UNRUN. $GateCmd/$Since mark the gate sample ok when only baseline errors remain.
function Split-TypecheckErrors($out2, [int]$rc, [string]$GateCmd, $Since) {
  $changed = @(Get-ChangedFiles | ForEach-Object { $_.ToLower() })
  $mine = [Collections.Generic.List[string]]::new(); $mineN = 0; $baseN = 0; $baseFiles = @{}; $cur = $null; $blocks = 0
  foreach ($l in $out2) {
    if ($l -match '^(?<f>.+?)\(\d+,\d+\): error TS(?<code>\d+)' -or $l -match '^error TS(?<code>\d+)') {
      $blocks++
      $f = $Matches.f; $isCfg = (-not $f) -or $Matches.code -match '^[56]\d{3}$' -or $Matches.code -eq '18003'   # config/option errors always count
      $full = if ($f) { [IO.Path]::GetFullPath((Join-Path $st.dir $f)).ToLower() } else { $null }
      if ($isCfg -or $changed -contains $full) { $cur = 'mine'; $mineN++ } else { $cur = 'base'; $baseN++; $baseFiles[$full] = 1 }
    }
    elseif (-not ($cur -and $l -match '^\s')) { $cur = $null }
    if ($cur -eq 'mine') { $mine.Add($l) }
  }
  $mine | ForEach-Object { Write-Host $_ }
  Write-Host "BASELINE: $baseN errors outside your changes (in $($baseFiles.Count) files; not failing this check; full log: $log)"
  if ($mineN) { Write-Host "[check] typecheck: $mineN errors in your changed files (or in the config)"; return 1 }
  if ($rc -and -not $blocks) { $out2 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }; return $rc }   # tsc failed without diagnostics
  # A huge baseline means the linked node_modules do not match this branch (missing or wrong-version packages): every file errors,
  # so an error your change causes in an unchanged file hides in it. That run checked nothing: UNRUN, not a pass (no gate ok either).
  if ($baseN -gt $script:TypecheckUnrunAbove) {
    $gd = (git -C $st.dir rev-parse --git-dir 2>$null); if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
    $tgt = if ($gd -and (Test-Path (Join-Path $gd 'claude-target'))) { (Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim() } else { '<target>' }
    Write-Host "[check] typecheck UNRUN: $baseN baseline errors (> $script:TypecheckUnrunAbove) - the linked node_modules do not match this branch, so real errors hide in the baseline. Say 'typecheck unrun' in the MR; the lead can set kit.local.json linkFromByTarget.$tgt to a checkout whose node_modules match $tgt (dev-kit reference/configuration.md)."
    return 'unrun'
  }
  if ($rc -and $GateCmd) { Set-GateSampleOk $GateCmd $Since }   # baseline errors only: this check passed, so its gate sample is a pass too
  return 0
}
$script:TypecheckUnrunAbove = 200

# gate.ps1 records ok = (exit code 0) per run in its history.json; a fallback typecheck that failed only on baseline errors passed
# this check, so its sample (newest one of this command since the run started) is turned into ok (marked baseline), under the
# gate's own mutex. Best effort: nothing changes when the sample or the file is missing or unreadable.
function Set-GateSampleOk([string]$GateCmd, [DateTimeOffset]$Since) {
  $hf = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'history.json'
  if (-not (Test-Path -LiteralPath $hf)) { return }
  $pre = if ($GateCmd.Length -gt 60) { $GateCmd.Substring(0, 60) } else { $GateCmd }
  $fromUtc = $Since.UtcDateTime.AddSeconds(-2)
  $mx = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate'); $got = $false
  try {
    try { $got = $mx.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { return }
    $h = Get-Content -LiteralPath $hf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($h -isnot [hashtable]) { return }
    $best = $null; $bestAt = [datetime]::MinValue
    foreach ($k in @($h.Keys)) { foreach ($s in @($h[$k])) {
      if (-not $s -or $s.ok -or -not $s.at -or -not ([string]$s.cmd).StartsWith($pre)) { continue }
      $at = ([datetime]$s.at).ToUniversalTime()
      if ($at -ge $fromUtc -and $at -gt $bestAt) { $best = $s; $bestAt = $at } } }
    if (-not $best) { return }
    $best.ok = $true; $best.baseline = $true
    $h | ConvertTo-Json -Depth 3 | Set-Content "$hf.tmp" -ErrorAction Stop
    Move-Item "$hf.tmp" $hf -Force -ErrorAction Stop
  } catch {} finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
}

# Container tests (Testcontainers) need a running Docker: without it each one burns minutes in Maven/Gradle and then fails looking
# like a code bug. Judged before the gate: a test named *ContainerTest / *IT, or a named test class (or -AllTests) in a module whose
# build file references testcontainers and whose source uses it. `docker info` gets 5 s; on failure exit 4 with a start hint.
function Test-DockerForContainerTests {
  $names = @($Tests -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { (($_ -split '#')[0] -split '\.')[-1] })
  $need = @($names | Where-Object { $_ -match '(Container|IT)(Test)?$' }).Count -gt 0
  if (-not $need) {
    $bf = @('pom.xml', 'build.gradle', 'build.gradle.kts') | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bf -and (Get-Content -LiteralPath $bf -Raw) -match 'testcontainers') {
      if ($AllTests -and -not $names.Count) { $need = $true }
      else {
        $roots = @('src/test', 'src/integrationTest') | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($n in $names) {
          $src = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Include "$n.java", "$n.kt" -ErrorAction SilentlyContinue } | Select-Object -First 1)
          if ($src.Count -and (Get-Content -LiteralPath $src[0].FullName -Raw) -match '@Testcontainers|@Container\b|import\s+org\.testcontainers|extends\s+\w*Container\w*Test\b') { $need = $true; break }
        }
      }
    }
  }
  if (-not $need) { return 0 }
  $docker = Get-Command docker -ErrorAction SilentlyContinue | Select-Object -First 1
  $ok = $false; $why = 'docker is not on PATH'
  if ($docker) {
    try {
      $psi = [Diagnostics.ProcessStartInfo]::new($docker.Source, 'info --format "{{.ServerVersion}}"')
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
      $p = [Diagnostics.Process]::Start($psi)
      $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
      if (-not $p.WaitForExit(5000)) { try { $p.Kill($true) } catch {}; $why = 'docker info did not answer within 5 s' }
      elseif ($p.ExitCode -eq 0 -and "$($outTask.Result)".Trim()) { $ok = $true }
      else { $why = "docker info failed: $((("$($errTask.Result)" -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1))" }
    } catch { $why = "docker info could not run: $($_.Exception.Message)" }
  }
  if ($ok) { Write-Host '[check] container tests: Docker is running'; return 0 }
  Write-Host "[check] container tests need Docker, and it is not available ($why)."
  Write-Host "[check] Start it (Windows/macOS: Docker Desktop; Linux: the docker service), poll 'docker info' until it answers, then re-run. A container test that fails because Docker was down is not a code failure."
  return 4
}

if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  # Liquibase master changelogs: *master.xml under a liquibase/ or changelog/ folder (JHipster config/liquibase/master.xml,
  # Spring Boot db/changelog/db.changelog-master.xml). A YAML/JSON/SQL master is not checked (said so, not silently passed).
  $all = @(git -C $top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' })
  $masters = @($all | Where-Object { $_ -match '\.xml$' })
  foreach ($o in @($all | Where-Object { $_ -notmatch '\.xml$' })) { Write-Host "[check] $o is not an XML changelog - lbcheck reads XML only, not checked" }
  if (-not $masters) { Write-Host '[check] no Liquibase XML master changelog in this repo - nothing to check'; exit 0 }
  # changelog files without a yyyyMMddHHmmss name prefix are judged by git instead: the ones changed in the last 14 days (or
  # since -Since) are reported too (lbcheck.py reads LBCHECK_CHANGED, basenames separated by '|')
  $sinceDate = try { [datetime]::ParseExact($Since.Substring(0, 8), 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { (Get-Date).AddDays(-14).ToString('yyyy-MM-dd') }
  $env:LBCHECK_CHANGED = (@(git -C $top log --since=$sinceDate --name-only --pretty=format: -- '*.xml') + @(git -C $top diff --name-only HEAD -- '*.xml') | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique) -join '|'
  $rc = 0
  $mine = @($masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) })
  $under = @($mine | Where-Object { $_.StartsWith($st.dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
  if ($under.Count) { $mine = $under }   # module has its own changelog: check only that one
  foreach ($full in $mine) {
    $a = @((Join-Path $K 'lbcheck.py'), $full, $Since)
    $py = Get-Python
    if ($Show) { "$py $($a -join ' ')"; continue }
    Write-Host "[check] liquibase: $full (files since $Since)"
    & $py @a; if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
  }
  exit $rc
}

$steps = if ($Step -eq 'quick') { 'compile', 'typecheck', 'lint' } else { @($Step) }
$ran = 0
foreach ($s in $steps) {
  $cmd = $st.commands.$s
  # a web project without a unit-test target (e.g. a stack override that sets none): node-spec.mjs runs the specs under node
  if (-not $cmd -and $s -eq 'test' -and (Test-Path -LiteralPath (Join-Path $st.dir 'package.json'))) { $cmd = "node `"$(Join-Path $K 'node-spec.mjs')`" {tests}" }
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($s -eq 'test' -and $cmd -match 'node-spec\.mjs') { Write-Host '[check] no unit-test target: running node-spec.mjs (specs under node; DOM specs under the project''s jsdom if it has one; TestBed/fakeAsync specs are reported NOT RUN)' }
  if ($cmd -match '\{tests\}') {
    if (-not $Tests -and -not $AllTests) { throw "-Step test needs -Tests '<names or paths>' (or -AllTests for the whole suite)" }
    $cmd = $cmd -replace '\{tests\}', $Tests
    if ($AllTests -and -not $Tests) { $cmd = $cmd -replace ' --tests\s*(?=\s|$)', '' -replace ' -Dtest=\s', ' ' -replace ' --include\s*(?=\s|$)', '' -replace ' -run ""', '' -replace ' --filter ""', '' }
  }
  if ($s -eq 'test' -and $cmd -match 'node-spec\.mjs' -and $cmd -notmatch '--real-angular') {
    # the @angular/core stub breaks @angular/forms (FormControl & co. need real core exports): such specs run on the real core
    $why = if ($RealAngular) { '-RealAngular' } else {
      $hit = @(@($Tests -split '[,\s]+' | Where-Object { $_ }) | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { $_ -match '\.(spec|test)\.\w+$' -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
               Where-Object { (Get-Content -LiteralPath $_ -Raw) -match '[''"]@angular/forms[''"]' } | Select-Object -First 1)
      if ($hit.Count) { "$(Split-Path $hit[0] -Leaf) imports @angular/forms" }
    }
    if ($why) { $cmd += ' --real-angular'; Write-Host "[check] node-spec with the real @angular/core ($why)" }
  }
  if ($s -eq 'test' -and $st.stack -match 'maven|gradle|java|kotlin') {   # -Show reports the Docker check without stopping
    $rc = Test-DockerForContainerTests
    if ($rc -and -not $Show) { exit $rc }
  }
  if ($cmd -match '\{sln\}') {
    # .NET: the solution in the stack dir, else the single project there (a test project folder has only its .csproj)
    $sln = @(Get-ChildItem -LiteralPath $st.dir -Filter *.sln -File -ErrorAction SilentlyContinue)
    if (-not $sln.Count) { $sln = @(Get-ChildItem -LiteralPath $st.dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' }) }
    if ($sln.Count -ne 1) { throw "[check] $($st.dir): expected one .sln (or one project file), found $($sln.Count) - pass -Dir to the folder that has it" }
    $cmd = $cmd.Replace('{sln}', $sln[0].FullName)
  }
  if ($cmd -match '\{files\}') {
    if (-not $Files -and $Step -eq 'quick' -and ($s -eq 'lint' -or ($s -eq 'compile' -and $st.stack -eq 'python'))) {
      # quick lint (and Python's compileall) = files changed on the branch + untracked ones, so it stays fast
      # only files the stack's linter reads (ruff/flake8 get .py, eslint gets JS/TS)
      $ext = if ($st.stack -eq 'python') { '\.(py|pyi)$' } else { '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$' }
      # paths relative to the stack dir (the gate runs there): absolute paths made a 200-file merge overflow cmd.exe's 8191 chars
      Push-Location $st.dir
      $changed = @(Get-ChangedFiles | Where-Object { $_ -match $ext } | ForEach-Object { Resolve-Path -Relative $_ })
      Pop-Location
      if (-not $changed.Count) { Write-Host "[check] ${s}: no changed files"; continue }
      $Files = ($changed | ForEach-Object { '"' + $_ + '"' }) -join ' '
    }
  }
  # still too long for one command line (cmd.exe stops at 8191 chars): run the step in batches of files
  $batches = @($cmd)
  if ($cmd -match '\{files\}') {
    $batches = @()
    $list = if ($Files) { @([regex]::Matches($Files, '"[^"]*"|\S+') | ForEach-Object Value) } else { @('.') }
    $room = 7000 - $cmd.Length; $cur = @()
    foreach ($f in $list) {
      if ($cur.Count -and (($cur -join ' ').Length + $f.Length + 1) -gt $room) { $batches += $cmd -replace '\{files\}', ($cur -join ' '); $cur = @() }
      $cur += $f
    }
    if ($cur.Count) { $batches += $cmd -replace '\{files\}', ($cur -join ' ') }
  }
  for ($bi = 0; $bi -lt $batches.Count; $bi++) {
  $cmd = $batches[$bi]
  if ($batches.Count -gt 1) { Write-Host "[check] $s batch $($bi + 1)/$($batches.Count)" }
  if ($st.solution) { $cmd = $cmd -replace '\{sln\}', $st.solution }
  # Speed-ups that don't change results:
  if ($cmd -match '^(\.[\\/]mvnw(\.cmd)?|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $cmd = $cmd -replace '^(\.[\\/]mvnw(\.cmd)?|mvn)\s', 'mvnd ' }   # warm Maven daemon
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {                                                                  # incremental type-check
    . (Join-Path $K 'kitpaths.ps1')
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($st.dir.ToLower()))).Replace('-', '').Substring(0, 12)
    $tsb = Get-KitPath tsbuild -Create
    $cmd += " --incremental --tsBuildInfoFile `"$(Join-Path $tsb "$hash.tsbuildinfo")`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }                                                       # Gradle build cache
  if ($Show) { "$s : $cmd"; continue }
  $unrun = $false
  if ($s -eq 'typecheck' -and $cmd -match '\btsc\b') { $r = @(Invoke-Typecheck $cmd)[-1]; if ($r -eq 'unrun') { $unrun = $true; $rc = 0 } else { $rc = [int]$r } }
  else { & (Join-Path $K 'gate.ps1') -Dir $st.dir -Cmd $cmd; $rc = $LASTEXITCODE }
  $ran++
  if ($rc) { Write-Host "[check] $s FAILED (exit $rc)"; exit $rc }
  }
  if (-not $Show) { Write-Host "[check] $s $(if ($unrun) { 'UNRUN (not a pass: see above)' } else { 'ok' })" }
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
exit 0
