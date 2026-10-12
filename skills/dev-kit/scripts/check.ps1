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
Exit code: 0 ok, non-zero = the first failing step's exit code (3 = the gate could not start it in time).
#>
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$Since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),   # migrations: only report changelog files named with a timestamp >= this
  [switch]$Show
)
$ErrorActionPreference = 'Stop'
$K = Split-Path $MyInvocation.MyCommand.Path
. (Join-Path $K 'sysinfo.ps1')
$st = & (Join-Path $K 'stack.ps1') -Dir $Dir -Json | ConvertFrom-Json
Write-Host "[check] $($st.stack) in $($st.dir)"

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
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($cmd -match '\{tests\}') {
    if (-not $Tests -and -not $AllTests) { throw "-Step test needs -Tests '<names or paths>' (or -AllTests for the whole suite)" }
    $cmd = $cmd -replace '\{tests\}', $Tests
    if ($AllTests -and -not $Tests) { $cmd = $cmd -replace ' --tests\s*(?=\s|$)', '' -replace ' -Dtest=\s', ' ' -replace ' --include\s*(?=\s|$)', '' -replace ' -run ""', '' -replace ' --filter ""', '' }
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
      # quick lint (and Python's compileall) = files changed against the merge base, so it stays fast
      $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
      # base = where this branch left its target: the worktree's recorded target (wt.ps1 new), else the remote's default
      # branch (origin/HEAD), else the upstream. (@{upstream} alone is the pushed branch itself, so after a push or
      # commit quick lint used to see only uncommitted files.)
      $gd = (git -C $st.dir rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
      $tgt = if (Test-Path (Join-Path $gd 'claude-target')) { "origin/$((Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim())" }
      $refs = @($tgt, ((git -C $st.dir symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null) | Select-Object -First 1), '@{upstream}') | Where-Object { $_ }
      $base = $null; foreach ($r in $refs) { $base = (git -C $st.dir merge-base HEAD $r 2>$null); if ($LASTEXITCODE -eq 0 -and $base) { break }; $base = $null }
      $changed = git -C $st.dir diff --name-only --diff-filter=ACMR $(if ($base) { $base } else { 'HEAD' }) -- . 2>$null
      # only files the stack's linter reads (ruff/flake8 get .py, eslint gets JS/TS)
      $ext = if ($st.stack -eq 'python') { '\.(py|pyi)$' } else { '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$' }
      # paths relative to the stack dir (the gate runs there): absolute paths made a 200-file merge overflow cmd.exe's 8191 chars
      Push-Location $st.dir
      $changed = @($changed | Where-Object { $_ -match $ext } | ForEach-Object { Join-Path $top $_ } | Where-Object { Test-Path $_ } | ForEach-Object { Resolve-Path -Relative $_ })
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
  & (Join-Path $K 'gate.ps1') -Dir $st.dir -Cmd $cmd
  $ran++
  if ($LASTEXITCODE) { Write-Host "[check] $s FAILED (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
  }
  if (-not $Show) { Write-Host "[check] $s ok" }
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
exit 0
