<#
Detects the build stack of a directory from its marker files and returns the commands for it.
Works for any repo — nothing project-specific lives here.

  & <workspace>\.claude\skills\dev-kit\scripts\stack.ps1 -Dir <dir>            # table: stack, dir, commands
  & <workspace>\.claude\skills\dev-kit\scripts\stack.ps1 -Dir <dir> -Json      # same, as JSON (for agents/scripts)

Looks in -Dir first, then walks up to the git root, and uses the nearest match.
Commands use placeholders filled by check.ps1: {tests} (test filter), {files} (paths), {sln} (solution file).

Override for one repo/folder: put `.claude-stack.json` next to the marker file, e.g.
  { "stack": "custom", "commands": { "compile": "make", "test": "make test T={tests}" } }
Keys you set replace the detected ones; the rest stay.
#>
param([string]$Dir = (Get-Location).Path, [switch]$Json)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
. (Join-Path $PSScriptRoot 'sysinfo.ps1')
# Repo-local wrappers: .\mvnw.cmd / .\gradlew.bat on Windows, ./mvnw / ./gradlew elsewhere
function Wrapper($d, $name, $winExt, $fallback) {
  if ($KitIsWindows) { if (Test-Path (Join-Path $d "$name.$winExt")) { return ".\$name.$winExt" } }
  elseif (Test-Path (Join-Path $d $name)) { return "./$name" }
  $fallback
}

function Has($d, $pattern) { [bool](Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1) }
function First($d, $pattern) { Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }

function Get-NodeTools($d) {
  $pkg = ReadJson (Join-Path $d 'package.json')
  $deps = @()
  foreach ($k in 'dependencies', 'devDependencies') { if ($pkg.$k) { $deps += $pkg.$k.PSObject.Properties.Name } }
  $scripts = if ($pkg.scripts) { $pkg.scripts.PSObject.Properties.Name } else { @() }
  $jestCfg = @('jest-unit.config.json', 'jest.config.js', 'jest.config.ts', 'jest.config.json', 'jest.config.cjs', 'jest.config.mjs') | Where-Object { Test-Path (Join-Path $d $_) } | Select-Object -First 1
  [pscustomobject]@{
    Deps    = $deps; Scripts = $scripts
    Ts      = Test-Path (Join-Path $d 'tsconfig.json')
    Jest    = ($deps -contains 'jest') -or [bool]$jestCfg
    JestCfg = $jestCfg
    Vitest  = $deps -contains 'vitest'
    Eslint  = ($deps -contains 'eslint') -or (Has $d 'eslint.config.*') -or (Has $d '.eslintrc*')
  }
}

function Get-Stack($d) {
  $c = [ordered]@{ compile = $null; typecheck = $null; lint = $null; test = $null; build = $null; format = $null }
  $s = $null; $deps = @()

  if (Test-Path (Join-Path $d 'pom.xml')) {
    $s = 'java-maven'
    $mvn = Wrapper $d 'mvnw' 'cmd' 'mvn'
    $c.compile = "$mvn -o -q compile"
    $c.test = "$mvn -o -q test -Dtest={tests} -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
    $c.build = "$mvn -o -q package -DskipTests"
  }
  elseif ((Has $d 'build.gradle') -or (Has $d 'build.gradle.kts') -or (Has $d 'settings.gradle*')) {
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    $android = (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($android) {
      $s = 'android-gradle'
      $c.compile = "$gw compileDebugSources -q"
      $c.test = "$gw testDebugUnitTest --tests {tests}"
      $c.lint = "$gw lintDebug"
      $c.build = "$gw assembleDebug"
    } else {
      $s = 'gradle'
      $c.compile = "$gw classes -q"
      $c.test = "$gw test --tests {tests}"
      $c.build = "$gw assemble"
    }
  }
  elseif ((Has $d '*.sln') -or (Has $d '*.csproj') -or (Has $d '*.fsproj') -or (Has $d '*.vbproj')) {
    # any old-style (non-SDK) project in the solution -> MSBuild, which also builds SDK-style projects
    $projs = Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Include *.csproj, *.fsproj, *.vbproj -File -ErrorAction SilentlyContinue | Select-Object -First 50
    $legacy = [bool]($projs | Where-Object { -not (Select-String -LiteralPath $_.FullName -Pattern '<Project\s+Sdk=' -Quiet) } | Select-Object -First 1)
    if ($legacy) {
      $s = 'dotnet-msbuild'
      $c.compile = 'msbuild "{sln}" /m:2 /v:q /nologo /p:Configuration=Debug'
      $c.build = 'msbuild "{sln}" /m:2 /v:q /nologo /p:Configuration=Release'
      $c.test = 'vstest.console.exe {tests}'   # .NET Framework test runner: Windows only
    } else {
      $s = 'dotnet'
      $c.compile = 'dotnet build "{sln}" -nologo -v q -m:2'
      $c.test = 'dotnet test "{sln}" -nologo --filter "{tests}"'
      $c.format = 'dotnet format "{sln}" --verify-no-changes'
      $c.build = 'dotnet build "{sln}" -nologo -v q -c Release'
    }
  }
  elseif (Test-Path (Join-Path $d 'angular.json')) {
    $s = 'angular'; $n = Get-NodeTools $d; $deps = @('node_modules')
    $tsc = if (Test-Path (Join-Path $d 'tsconfig.app.json')) { 'tsconfig.app.json' } else { 'tsconfig.json' }
    $c.typecheck = "npx tsc -p $tsc --noEmit"
    $c.build = 'npx ng build --configuration production'
    $c.test = 'npx ng test --watch=false --browsers=ChromeHeadless --include {tests}'
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
  }
  elseif (Test-Path (Join-Path $d 'package.json')) {
    $n = Get-NodeTools $d; $deps = @('node_modules')
    $s = if ($n.Deps -contains 'react-native') { 'react-native' } elseif ($n.Deps -contains 'next') { 'node-next' } elseif ($n.Deps -contains 'react') { 'node-react' } else { 'node' }
    if ($n.Ts) { $c.typecheck = 'npx tsc --noEmit' }
    if ($n.Vitest) { $c.test = 'npx vitest run {tests}' }
    elseif ($n.Jest) { $c.test = 'npx jest ' + $(if ($n.JestCfg) { "--config $($n.JestCfg) " } else { '' }) + '{tests} --no-watchman --forceExit' }
    elseif ($n.Scripts -contains 'test') { $c.test = 'npm test -- {tests}' }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    if ($s -ne 'react-native' -and $n.Scripts -contains 'build') { $c.build = 'npm run build' }
    $agw = Wrapper (Join-Path $d 'android') 'gradlew' 'bat' $null
    if ($s -eq 'react-native' -and $agw) { $c.build = "cd android && $agw assembleRelease" }
  }
  elseif ((Has $d 'pyproject.toml') -or (Has $d 'requirements*.txt') -or (Has $d 'setup.py') -or (Has $d 'Pipfile')) {
    $s = 'python'; $deps = @('.venv')
    $py = if ($KitIsWindows -and (Test-Path (Join-Path $d '.venv\Scripts\python.exe'))) { '.venv\Scripts\python.exe' }
          elseif (-not $KitIsWindows -and (Test-Path (Join-Path $d '.venv/bin/python'))) { '.venv/bin/python' }
          elseif ($KitIsWindows -or -not (Resolve-Tool python3)) { 'python' } else { 'python3' }
    $c.compile = "$py -m compileall -q {files}"
    $c.lint = "$py -m ruff check {files}"
    $c.test = "$py -m pytest {tests} -q"
    if ((Has $d 'mypy.ini') -or (Select-String -LiteralPath (Join-Path $d 'pyproject.toml') -Pattern '\[tool\.mypy\]' -Quiet -ErrorAction SilentlyContinue)) { $c.typecheck = "$py -m mypy {files}" }
  }
  elseif (Test-Path (Join-Path $d 'go.mod')) {
    $s = 'go'
    $c.compile = 'go build ./...'; $c.test = 'go test ./... -run "{tests}"'; $c.lint = 'go vet ./...'; $c.format = 'gofmt -l .'
  }
  elseif (Test-Path (Join-Path $d 'Cargo.toml')) {
    $s = 'rust'
    $c.compile = 'cargo check -q'; $c.test = 'cargo test {tests}'; $c.lint = 'cargo clippy -q'; $c.build = 'cargo build --release'; $c.format = 'cargo fmt --check'
  }
  elseif (Test-Path (Join-Path $d 'CMakeLists.txt')) {
    $s = 'cmake'
    $c.compile = 'cmake -S . -B build && cmake --build build -j 2'; $c.test = 'ctest --test-dir build -R "{tests}"'
  }
  elseif (Test-Path (Join-Path $d 'Makefile')) {
    $s = 'make'
    $c.compile = 'make'; $c.test = 'make test'
  }
  if (-not $s) { return $null }

  $ovr = ReadJson (Join-Path $d '.claude-stack.json')
  if ($ovr) {
    if ($ovr.stack) { $s = $ovr.stack }
    if ($ovr.commands) { foreach ($p in $ovr.commands.PSObject.Properties) { $c[$p.Name] = $p.Value } }
    if ($ovr.deps) { $deps = @($ovr.deps) }
  }
  $sln = if ($s -like 'dotnet*') { (First $d '*.sln').Name } else { $null }
  [pscustomobject]@{ stack = $s; dir = $d; solution = $sln; deps = $deps; commands = [pscustomobject]$c }
}

$top = (git -C $Dir rev-parse --show-toplevel 2>$null)
if ($top) { $top = (Resolve-Path $top).Path }
$d = $Dir; $hit = $null
while ($d) {
  $hit = Get-Stack $d
  if ($hit -or -not $top -or $d -eq $top) { break }
  $parent = Split-Path $d
  if (-not $parent -or $parent -eq $d) { break }
  $d = $parent
}
if (-not $hit) { throw "No known stack under $Dir (looked up to the git root). Add a .claude-stack.json there." }
if ($Json) { $hit | ConvertTo-Json -Depth 4 }
else {
  "stack: $($hit.stack)   dir: $($hit.dir)$(if ($hit.solution) { "   solution: $($hit.solution)" })"
  $hit.commands.PSObject.Properties | Where-Object Value | ForEach-Object { '  {0,-9} {1}' -f $_.Name, $_.Value }
}
