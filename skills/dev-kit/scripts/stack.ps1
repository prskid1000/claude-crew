<#
Detects the build stack of a directory from its marker files and returns the commands for it.
Works for any repo — nothing project-specific lives here.

  & <workspace>/.claude/skills/dev-kit/scripts/stack.ps1 -Dir <dir>            # table: stack, dir, commands
  & <workspace>/.claude/skills/dev-kit/scripts/stack.ps1 -Dir <dir> -Json      # same, as JSON (for agents/scripts)

Looks in -Dir first, then walks up to the git root, and uses the nearest match.
Commands use placeholders filled by check.ps1: {tests} (test filter), {files} (paths), {sln} (solution file).

Override for one repo/folder: put `.claude-stack.json` next to the marker file, e.g.
  { "stack": "custom", "commands": { "compile": "make", "test": "make test T={tests}" } }
Keys you set replace the detected ones; the rest stay.
#>
param([string]$Dir = (Get-Location).Path, [switch]$Json)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
if (Test-Path -LiteralPath $Dir -PathType Leaf) { $Dir = Split-Path $Dir }   # -Dir <file> (a .sln, pom.xml ...) = its folder
. (Join-Path $PSScriptRoot 'sysinfo.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
# Repo-local wrappers: .\mvnw.cmd / .\gradlew.bat on Windows, ./mvnw / ./gradlew elsewhere
function Wrapper($d, $name, $winExt, $fallback) {
  if ($KitIsWindows) { if (Test-Path (Join-Path $d "$name.$winExt")) { return ".\$name.$winExt" } }
  elseif (Test-Path (Join-Path $d $name)) { return "./$name" }
  $fallback
}

function Has($d, $pattern) { [bool](Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1) }
function First($d, $pattern) { Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
function ReadText($f) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue } else { '' } }
# Package manager of a Node project: the lockfile in its folder or above it (monorepo), up to the git root. npm by default.
function Get-NodePm($d) {
  $top = (git -C $d rev-parse --show-toplevel 2>$null); if ($top) { $top = (Resolve-Path $top).Path }
  $x = $d
  while ($x) {
    if (Test-Path (Join-Path $x 'pnpm-lock.yaml')) { return 'pnpm' }
    if (Test-Path (Join-Path $x 'yarn.lock')) { return 'yarn' }
    if ((Test-Path (Join-Path $x 'bun.lockb')) -or (Test-Path (Join-Path $x 'bun.lock'))) { return 'bun' }
    if ((Test-Path (Join-Path $x 'package-lock.json')) -or -not $top -or $x -eq $top) { break }
    $p = Split-Path $x; if (-not $p -or $p -eq $x) { break }; $x = $p
  }
  'npm'
}
# <pm> run <script> [args] in the form each package manager passes arguments through
function NodeRun($pm, $script, $argText) {
  $a = if ($argText) { " $argText" } else { '' }
  switch ($pm) { 'npm' { "npm $(if ($script -ne 'test') { 'run ' })$script$(if ($a) { ' --' + $a })" } 'yarn' { "yarn $script$a" } default { "$pm run $script$a" } }
}
# tsconfig.json that only holds project references ("files": [] + "references", the Vite/Nx layout) type-checks nothing with
# -p tsconfig.json: use tsconfig.app.json when there is one
function TsProject($d) {
  $t = ReadText (Join-Path $d 'tsconfig.json')
  if ((Test-Path (Join-Path $d 'tsconfig.app.json')) -and $t -match '"references"\s*:\s*\[\s*\{' -and $t -match '"files"\s*:\s*\[\s*\]') { return 'tsconfig.app.json' }
  $null
}

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
    # offline (-o) = no network round-trips and no remote-repo lock contention between parallel builds; it needs the
    # dependencies in the local repo, so it is used only when ~/.m2/repository exists (kit.local.json build.mavenOffline: false = never)
    $off = if ((Get-KitSetting 'build.mavenOffline' $true) -ne $false -and "$(Get-KitSetting 'build.mavenOffline' $true)" -ne 'false' -and (Test-Path (Join-Path $HOME '.m2/repository'))) { '-o ' } else { '' }
    $c.compile = "$mvn $off-q compile"
    $c.test = "$mvn $off-q test -Dtest={tests} -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
    $c.build = "$mvn $off-q package -DskipTests"
  }
  elseif ((Has $d 'build.gradle') -or (Has $d 'build.gradle.kts') -or (Has $d 'settings.gradle*')) {
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    $android = (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($android) {
      $s = 'android-gradle'
      # Variant: .claude-stack.json "androidVariant" (e.g. "freeDebug"), else Debug, or <first product flavor>Debug when the
      # app module declares productFlavors (then compileDebugSources / testDebugUnitTest do not exist and Gradle fails)
      $var = [string](ReadJson (Join-Path $d '.claude-stack.json')).androidVariant
      if (-not $var) {
        $var = 'Debug'
        foreach ($bf in @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -Include build.gradle, build.gradle.kts -File -ErrorAction SilentlyContinue)) {
          $bt = ReadText $bf.FullName
          if ($bt -match '(?s)productFlavors\s*\{\s*(?:create\(\s*"|register\(\s*"|maybeCreate\(\s*")?([A-Za-z]\w*)') { $var = $Matches[1].Substring(0, 1).ToUpper() + $Matches[1].Substring(1) + 'Debug'; break }
        }
      } else { $var = $var.Substring(0, 1).ToUpper() + $var.Substring(1) }
      $c.compile = "$gw compile${var}Sources -q"
      $c.test = "$gw test${var}UnitTest --tests {tests}"
      $c.lint = "$gw lint$var"
      $c.build = "$gw assemble$var"
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
      # msbuild / vstest.console are on PATH only in a Developer prompt: otherwise find them with vswhere (Visual Studio / Build Tools)
      $msb = 'msbuild'; $vst = 'vstest.console.exe'
      $vswhere = if ($KitIsWindows -and ${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
      if ($vswhere -and (Test-Path $vswhere)) {
        if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null)[0]; if ($f) { $msb = "`"$f`"" } }
        if (-not (Get-Command vstest.console.exe -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -find '**\TestPlatform\vstest.console.exe' 2>$null)[0]; if ($f) { $vst = "`"$f`"" } }
      }
      $c.compile = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Debug"
      $c.build = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Release"
      $c.test = "$vst {tests}"   # .NET Framework test runner: Windows only
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
    # test only when a project has a 'test' target; the flags depend on its builder (Karma takes --browsers, the
    # @angular/build:unit-test / Vitest runner does not). No target -> check.ps1 says "has no 'test' step".
    # build: --configuration production only when the build target defines a 'production' configuration.
    $ngTest = $null
    try {
      $aj = Get-Content (Join-Path $d 'angular.json') -Raw | ConvertFrom-Json
      $bt = foreach ($p in $aj.projects.PSObject.Properties) { $b = if ($p.Value.architect.build) { $p.Value.architect.build } else { $p.Value.targets.build }; if ($b) { $b; break } }
      if ($bt -and -not ($bt.configurations -and $bt.configurations.PSObject.Properties.Name -contains 'production')) { $c.build = 'npx ng build' }
      foreach ($p in $aj.projects.PSObject.Properties) {
        $t = if ($p.Value.architect.test) { $p.Value.architect.test } elseif ($p.Value.targets.test) { $p.Value.targets.test } else { $null }
        if ($t) { $ngTest = [string]$t.builder; break }
      }
    } catch { $ngTest = 'karma' }
    if ($ngTest -match 'karma') { $c.test = 'npx ng test --watch=false --browsers=ChromeHeadless --include {tests}' }
    elseif ($ngTest) { $c.test = 'npx ng test --watch=false --include {tests}' }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
  }
  elseif (Test-Path (Join-Path $d 'package.json')) {
    $n = Get-NodeTools $d; $deps = @('node_modules')
    $s = if ($n.Deps -contains 'react-native') { 'react-native' } elseif ($n.Deps -contains 'next') { 'node-next' } elseif ($n.Deps -contains 'react') { 'node-react' } else { 'node' }
    $pm = Get-NodePm $d   # npm / yarn / pnpm / bun, from the lockfile
    if ($n.Ts) { $tp = TsProject $d; $c.typecheck = if ($tp) { "npx tsc -p $tp --noEmit" } else { 'npx tsc --noEmit' } }
    if ($n.Vitest) { $c.test = 'npx vitest run {tests}' }
    elseif ($n.Jest) { $c.test = 'npx jest ' + $(if ($n.JestCfg) { "--config $($n.JestCfg) " } else { '' }) + '{tests} --no-watchman --forceExit' }
    elseif ($n.Scripts -contains 'test') { $c.test = NodeRun $pm 'test' '{tests}' }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    if ($s -ne 'react-native' -and $n.Scripts -contains 'build') { $c.build = NodeRun $pm 'build' '' }
    $agw = Wrapper (Join-Path $d 'android') 'gradlew' 'bat' $null
    if ($s -eq 'react-native' -and $agw) { $c.build = "cd android && $agw assembleRelease" }
  }
  elseif ((Has $d 'pyproject.toml') -or (Has $d 'requirements*.txt') -or (Has $d 'setup.py') -or (Has $d 'Pipfile')) {
    $s = 'python'; $deps = @('.venv')
    $py = if ($KitIsWindows -and (Test-Path (Join-Path $d '.venv\Scripts\python.exe'))) { '.venv\Scripts\python.exe' }
          elseif (-not $KitIsWindows -and (Test-Path (Join-Path $d '.venv/bin/python'))) { '.venv/bin/python' }
          elseif ($KitIsWindows -or -not (Resolve-Tool python3)) { 'python' } else { 'python3' }
    $c.compile = "$py -m compileall -q -x `"[\\/](\.venv|venv|node_modules|\.git)[\\/]`" {files}"   # never walk a linked .venv
    # lint/test tools the project really has: ruff (else flake8) and pytest (else the standard library's unittest). Asked of
    # the project's interpreter in one call; if it cannot be asked, the config files decide (ruff + pytest as before).
    $cfgText = @('pyproject.toml', 'setup.cfg', 'tox.ini') | ForEach-Object { ReadText (Join-Path $d $_) }
    $have = $null
    $pyExe = if ($py -match '^\.venv') { Join-Path $d $py } else { (Resolve-Tool $py) }
    if ($pyExe -and (Test-Path $pyExe)) {
      $have = @(& $pyExe -c "import importlib.util as u; print(' '.join(m for m in ('ruff','flake8','pytest') if u.find_spec(m)))" 2>$null) -join ' '
      if ($LASTEXITCODE) { $have = $null }
    }
    $ruffCfg = (Has $d 'ruff.toml') -or (Has $d '.ruff.toml') -or ("$cfgText" -match '\[tool\.ruff')
    $flakeCfg = (Has $d '.flake8') -or ("$cfgText" -match '\[flake8\]')
    $pytestCfg = (Has $d 'pytest.ini') -or (Has $d 'conftest.py') -or ("$cfgText" -match '\[tool\.pytest|\[pytest\]|\[tool:pytest\]')
    if ($null -eq $have) { $c.lint = if ($flakeCfg -and -not $ruffCfg) { "$py -m flake8 {files}" } else { "$py -m ruff check {files}" }; $c.test = "$py -m pytest {tests} -q" }
    else {
      $c.lint = if ($have -match 'ruff' -and ($ruffCfg -or -not ($flakeCfg -and $have -match 'flake8'))) { "$py -m ruff check {files}" } elseif ($have -match 'flake8') { "$py -m flake8 {files}" } else { $null }
      $c.test = if ($have -match 'pytest' -or $pytestCfg) { "$py -m pytest {tests} -q" } else { "$py -m unittest {tests}" }
    }
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
    $c.compile = 'make'
    if ((ReadText (Join-Path $d 'Makefile')) -match '(?m)^test\s*:') { $c.test = 'make test' }   # only when the Makefile has a test target
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
