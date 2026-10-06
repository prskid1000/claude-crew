<#
One command for "does my change build and pass?" in any repo. Detects the stack (stack.ps1), fills in the
command and runs it through the memory gate (gate.ps1).

  $K = '<workspace>\.claude\skills\dev-kit\scripts'
  & $K\check.ps1 -Dir <dir>                                   # quick: compile + typecheck + lint (whatever the stack has)
  & $K\check.ps1 -Dir <dir> -Step test -Tests "FooTest,BarTest"
  & $K\check.ps1 -Dir <dir> -Step test -Tests "src/a.spec.ts"
  & $K\check.ps1 -Dir <dir> -Step lint -Files "src/a.ts src/b.ts"
  & $K\check.ps1 -Dir <dir> -Step build                       # full build (heavy, use before shipping only)
  & $K\check.ps1 -Dir <dir> -Step migrations                  # Liquibase sanity check, if the repo has master.xml
  & $K\check.ps1 -Dir <dir> -Show                             # print what would run

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
$st = & "$K\stack.ps1" -Dir $Dir -Json | ConvertFrom-Json
Write-Host "[check] $($st.stack) in $($st.dir)"

if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $masters = git -C $top ls-files '*master.xml' | Where-Object { $_ -match 'liquibase' }
  if (-not $masters) { Write-Host '[check] no Liquibase master.xml in this repo - nothing to check'; exit 0 }
  $rc = 0
  $mine = @($masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) })
  $under = @($mine | Where-Object { $_.StartsWith($st.dir + '\', [StringComparison]::OrdinalIgnoreCase) })
  if ($under.Count) { $mine = $under }   # module has its own changelog: check only that one
  foreach ($full in $mine) {
    $a = @("$K\lbcheck.py", $full, $Since)
    if ($Show) { "python $($a -join ' ')"; continue }
    Write-Host "[check] liquibase: $full (files since $Since)"
    python @a; if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
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
    if (-not $Files -and $s -eq 'lint' -and $Step -eq 'quick') {
      # quick lint = files changed against the merge base, so it stays fast
      $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
      $base = (git -C $st.dir merge-base HEAD '@{upstream}' 2>$null)
      $changed = git -C $st.dir diff --name-only --diff-filter=ACMR $(if ($base) { $base } else { 'HEAD' }) -- . 2>$null
      $changed = @($changed | Where-Object { $_ -match '\.(ts|tsx|js|jsx|mjs|py)$' } | ForEach-Object { Join-Path $top $_ } | Where-Object { Test-Path $_ })
      if (-not $changed.Count) { Write-Host '[check] lint: no changed files'; continue }
      $Files = ($changed | ForEach-Object { '"' + $_ + '"' }) -join ' '
    }
    $cmd = $cmd -replace '\{files\}', $(if ($Files) { $Files } else { '.' })
  }
  if ($st.solution) { $cmd = $cmd -replace '\{sln\}', $st.solution }
  # Speed-ups that don't change results:
  if ($cmd -match '^(\.\\mvnw\.cmd|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $cmd = $cmd -replace '^(\.\\mvnw\.cmd|mvn)\s', 'mvnd ' }   # warm Maven daemon
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {                                                                  # incremental type-check
    $rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($K -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($st.dir.ToLower()))).Replace('-', '').Substring(0, 12)
    New-Item -ItemType Directory -Force "$rt\tsbuild" | Out-Null
    $cmd += " --incremental --tsBuildInfoFile `"$rt\tsbuild\$hash.tsbuildinfo`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }                                                       # Gradle build cache
  if ($Show) { "$s : $cmd"; continue }
  & "$K\gate.ps1" -Dir $st.dir -Cmd $cmd
  $ran++
  if ($LASTEXITCODE) { Write-Host "[check] $s FAILED (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
  Write-Host "[check] $s ok"
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
exit 0
