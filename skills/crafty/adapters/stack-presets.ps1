#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# stack-presets: crafty.ps1 stack presets: core (Maven, Gradle, Angular, Node, Python) and presets (Android Gradle, .NET (SDK and
# legacy MSBuild), Go, Rust, CMake, Make). crafty.ps1 stack calls each 'detect' in turn, core first, until one names the stack:
# $a.dir, $a.commands (filled), $a.deps -> the stack name. A local adapters/*.local.ps1 registers more the same way.
# Sections: L7 core · L99 presets
# ---- core: Maven, Gradle (not Android), Angular, Node and Python; always tried first (stack.presets filters the others). Runs inside
# crafty.ps1 stack: its helpers (Wrapper, Has, ReadText, Get-NodeTools, Get-NodePm, NodeRun, TsProject, NodeSpecCmd) resolve there.
# $a.deps <- the dependency folders wt lease links.
# e2e test runners (crafty.ps1 stack, check, wt commit): kit.local.json tests.runners, else vocab.json testRunners [{ name, deps, files, cmd, wholeSuiteRx, specGlobs, ignore }]
function Get-KitTestRunners { $r = Get-KitSetting 'tests.runners' $null; @($(if ($r) { $r } else { $script:KitVocab.testRunners }) | Where-Object { $_ }) }
Register-KitAdapter 'stack' 'core' @{ 'detect' = { param($a)
  $d = $a.dir; $c = $a.commands; $s = $null
  if (Test-Path (Join-Path $d 'pom.xml')) {
    $s = 'java-maven'
    $mvn = Wrapper $d 'mvnw' 'cmd' 'mvn'
    # build.mavenOffline true: -o (no repo lock fights between parallel builds)
    $off = if ("$(Get-KitSetting 'build.mavenOffline' $false)" -match '^(true|1|yes)$' -and (Test-Path (Join-Path $HOME '.m2/repository'))) { '-o ' } else { '' }
    $c.compile = "$mvn $off-q compile"
    $c.test = "$mvn $off-q test -Dtest={tests} -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
    $c.build = "$mvn $off-q package -DskipTests"
    if ((ReadText (Join-Path $d 'pom.xml')) -match 'spring-boot') { $c.build += ' -Dspring-boot.repackage.skip=true'; $c.run = "$mvn $($off)spring-boot:run" }
  }
  elseif (Has $d 'build.gradle', 'build.gradle.kts', 'settings.gradle*') {
    # Android: no core stack and no node / python fall-through (a root package.json): the presets Android adapter names it
    if (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $null }
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    $s = 'gradle'
    $c.compile = "$gw classes -q"
    $c.test = "$gw test --tests {tests}"
    $c.build = "$gw assemble"
    $c.run = if ((@(Get-ChildItem -LiteralPath $d -Filter 'build.gradle*' -File -ErrorAction SilentlyContinue | ForEach-Object { ReadText $_.FullName }) -join ' ') -match 'org\.springframework\.boot') { "$gw bootRun" } else { "$gw run" }
  }
  elseif (Test-Path (Join-Path $d 'angular.json')) {
    $s = 'angular'; $n = Get-NodeTools $d; $a.deps = @('node_modules')
    $tsc = if (Test-Path (Join-Path $d 'tsconfig.app.json')) { 'tsconfig.app.json' } else { 'tsconfig.json' }
    if ($script:TscNoOutput) { $c.typecheck = "npx tsc -p $tsc $script:TscNoOutput" }
    $c.build = 'npx ng build --configuration production'
    $ngTest = $null
    try {
      $aj = Get-Content (Join-Path $d 'angular.json') -Raw | ConvertFrom-Json
      $bt = foreach ($p in (Get-KitProps $aj.projects)) { $b = if ($p.Value.architect.build) { $p.Value.architect.build } else { $p.Value.targets.build }; if ($b) { $b; break } }
      if ($bt -and -not ($bt.configurations -and (Get-KitProps $bt.configurations).Name -contains 'production')) { $c.build = 'npx ng build' }
      foreach ($p in (Get-KitProps $aj.projects)) {
        $t = if ($p.Value.architect.test) { $p.Value.architect.test } elseif ($p.Value.targets.test) { $p.Value.targets.test } else { $null }
        if ($t) { $ngTest = [string]$t.builder; break }
      }
    } catch { $ngTest = 'karma' }
    if ($ngTest -match 'karma') { $c.test = 'npx ng test --watch=false --browsers=ChromeHeadless --include {tests}' }
    elseif ($ngTest) { $c.test = 'npx ng test --watch=false --include {tests}' }
    else { $c.test = NodeSpecCmd }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    $c.e2e = $n.E2e
    $c.run = 'npx ng serve --host 127.0.0.1 --port {port}'   # localhost = ::1 on Windows: envy's IPv4 check never saw it up (restart loop)
  }
  elseif (Test-Path (Join-Path $d 'package.json')) {
    $n = Get-NodeTools $d; $a.deps = @('node_modules')
    $s = if ($n.Deps -contains 'react-native') { 'react-native' } elseif ($n.Deps -contains 'next') { 'node-next' } elseif ($n.Deps -contains 'react') { 'node-react' } else { 'node' }
    $pm = Get-NodePm $d
    if ($n.Ts -and $script:TscNoOutput) { $tp = TsProject $d; $c.typecheck = if ($tp) { "npx tsc -p $tp $script:TscNoOutput" } else { "npx tsc $script:TscNoOutput" } }
    if ($n.Vitest) { $c.test = 'npx vitest run {tests}' }
    elseif ($n.Jest) { $c.test = 'npx jest ' + $(if ($n.JestCfg) { "--config $($n.JestCfg) " } else { '' }) + '{tests} --no-watchman --forceExit' }
    elseif ($n.Scripts -contains 'test') { $c.test = NodeRun $pm 'test' '{tests}' }
    elseif ($n.Ts -and $s -ne 'react-native') { $c.test = NodeSpecCmd }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    $c.e2e = $n.E2e
    if ($s -ne 'react-native' -and $n.Scripts -contains 'build') { $c.build = NodeRun $pm 'build' '' }
    $agw = Wrapper (Join-Path $d 'android') 'gradlew' 'bat' $null
    if ($s -eq 'react-native' -and $agw) { $c.build = "cd android && $agw assembleRelease" }
    $c.run = if ($s -eq 'react-native') { if ($n.Deps -contains 'expo') { 'npx expo start --port {port}' } else { 'npx react-native start --port {port}' } }
            elseif ($n.Scripts -contains 'dev') { NodeRun $pm 'dev' '' } elseif ($n.Scripts -contains 'start') { NodeRun $pm 'start' '' } else { $null }
  }
  elseif (Has $d 'pyproject.toml', 'requirements*.txt', 'setup.py', 'Pipfile') {
    $s = 'python'; $a.deps = @('.venv')
    $py = if ($KitIsWindows -and (Test-Path (Join-Path $d '.venv\Scripts\python.exe'))) { '.venv\Scripts\python.exe' }
          elseif (-not $KitIsWindows -and (Test-Path (Join-Path $d '.venv/bin/python'))) { '.venv/bin/python' }
          elseif ($KitIsWindows -or -not (Resolve-Tool python3)) { 'python' } else { 'python3' }
    $c.compile = "$py -m compileall -q -x `"[\\/](\.venv|venv|node_modules|\.git)[\\/]`" {files}"
    $cfgText = @('pyproject.toml', 'setup.cfg', 'tox.ini') | ForEach-Object { ReadText (Join-Path $d $_) }
    $have = $null
    $pyExe = if ($py -match '^\.venv') { Join-Path $d $py } else { (Resolve-Tool $py) }
    if ($pyExe -and (Test-Path $pyExe)) {
      $have = @(& $pyExe -c "import importlib.util as u; print(' '.join(m for m in ('ruff','flake8','pytest') if u.find_spec(m)))" 2>$null) -join ' '
      if ($LASTEXITCODE) { $have = $null }
    }
    $ruffCfg = (Has $d 'ruff.toml', '.ruff.toml') -or ("$cfgText" -match '\[tool\.ruff')
    $flakeCfg = (Has $d '.flake8') -or ("$cfgText" -match '\[flake8\]')
    $pytestCfg = (Has $d 'pytest.ini', 'conftest.py') -or ("$cfgText" -match '\[tool\.pytest|\[pytest\]|\[tool:pytest\]')
    if ($null -eq $have) { $c.lint = if ($flakeCfg -and -not $ruffCfg) { "$py -m flake8 {files}" } else { "$py -m ruff check {files}" }; $c.test = "$py -m pytest {tests} -q" }
    else {
      $c.lint = if ($have -match 'ruff' -and ($ruffCfg -or -not ($flakeCfg -and $have -match 'flake8'))) { "$py -m ruff check {files}" } elseif ($have -match 'flake8') { "$py -m flake8 {files}" } else { $null }
      $c.test = if ($have -match 'pytest' -or $pytestCfg) { "$py -m pytest {tests} -q" } else { "$py -m unittest {tests}" }
    }
    if (Test-Path (Join-Path $d 'manage.py')) { $c.run = "$py manage.py runserver {port}" }
    if ((Has $d 'mypy.ini') -or (Select-String -LiteralPath (Join-Path $d 'pyproject.toml') -Pattern '\[tool\.mypy\]' -Quiet -ErrorAction SilentlyContinue)) { $c.typecheck = "$py -m mypy {files}" }
  }
  $s
} }
# ---- presets: Android Gradle, .NET, Go, Rust, CMake, Make (stack.presets names which run)
Register-KitAdapter 'stack' 'presets' @{ 'detect' = { param($a)
  $d = $a.dir; $c = $a.commands; $s = $null
  function Has($d, [string[]]$pattern) { foreach ($p in $pattern) { if (Get-ChildItem -LiteralPath $d -Filter $p -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true } }; $false }
  function ReadText($f) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue } else { '' } }
  # Android: a Gradle module with an AndroidManifest.xml; the variant: .claude-stack.json androidVariant, else the first flavor + Debug
  if ((Has $d 'build.gradle', 'build.gradle.kts', 'settings.gradle*') -and (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    $s = 'android-gradle'
    $var = [string](ReadJson (Join-Path $d '.claude-stack.json')).androidVariant
    if (-not $var) {
      $var = 'Debug'
      foreach ($bf in @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -Include build.gradle, build.gradle.kts -File -ErrorAction SilentlyContinue)) {
        $bt = ReadText $bf.FullName
        if ($bt -match '(?s)productFlavors\s*\{\s*(?:create\(\s*"|register\(\s*"|maybeCreate\(\s*")?([A-Za-z]\w*)') { $m1 = $Matches[1]; $var = $(if ($m1.Length -ge 1) { $m1.Substring(0, 1).ToUpper() + $m1.Substring(1) } else { $m1 }) + 'Debug'; break }
      }
    } else { $var = if ($var.Length -ge 1) { $var.Substring(0, 1).ToUpper() + $var.Substring(1) } else { $var } }
    $c.compile = "$gw compile${var}Sources -q"
    $c.test = "$gw test${var}UnitTest --tests {tests}"
    $c.lint = "$gw lint$var"
    $c.build = "$gw assemble$var"
  }
  elseif (Has $d '*.sln', '*.csproj', '*.fsproj', '*.vbproj') {
    $projs = Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Include *.csproj, *.fsproj, *.vbproj -File -ErrorAction SilentlyContinue | Select-Object -First 50
    $legacy = [bool]($projs | Where-Object { -not (Select-String -LiteralPath $_.FullName -Pattern '<Project\s+Sdk=' -Quiet) } | Select-Object -First 1)
    if ($legacy) {
      $s = 'dotnet-msbuild'
      # msbuild: on PATH only in a Developer prompt
      $msb = 'msbuild'; $vst = 'vstest.console.exe'
      $vswhere = if ($KitIsWindows -and ${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
      if ($vswhere -and (Test-Path $vswhere)) {
        if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null)[0]; if ($f) { $msb = "`"$f`"" } }
        if (-not (Get-Command vstest.console.exe -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -find '**\TestPlatform\vstest.console.exe' 2>$null)[0]; if ($f) { $vst = "`"$f`"" } }
      }
      $c.compile = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Debug"
      $c.build = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Release"
      $c.test = "$vst {tests}"
    } else {
      $s = 'dotnet'
      $c.compile = 'dotnet build "{sln}" -nologo -v q -m:2'
      $c.test = 'dotnet test "{sln}" -nologo --filter "{tests}"'
      $c.format = 'dotnet format "{sln}" --verify-no-changes'
      $c.build = 'dotnet build "{sln}" -nologo -v q -c Release'
      if (Has $d '*.csproj', '*.fsproj') { $c.run = 'dotnet run --urls http://localhost:{port}' }
    }
    $sln = @(Get-ChildItem -LiteralPath $d -Filter *.sln -File -ErrorAction SilentlyContinue)
    if (-not $sln.Count) { $sln = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' }) }
    if ($sln.Count -ne 1) { Write-Warning "[stack] ${d}: $($sln.Count) .sln / project files: {sln} stays unresolved; check -Dir the folder of one" }
    else { foreach ($k in @($c.Keys)) { if ($c[$k]) { $c[$k] = ([string]$c[$k]).Replace('{sln}', $sln[0].FullName) } } }
  }
  elseif (Test-Path (Join-Path $d 'go.mod')) {
    $s = 'go'
    $c.compile = 'go build ./...'; $c.run = 'go run .'; $c.test = 'go test ./... -run "{tests}"'; $c.lint = 'go vet ./...'; $c.format = 'gofmt -l .'
  }
  elseif (Test-Path (Join-Path $d 'Cargo.toml')) {
    $s = 'rust'
    $c.compile = 'cargo check -q'; $c.test = 'cargo test {tests}'; $c.lint = 'cargo clippy -q'; $c.build = 'cargo build --release'; $c.run = 'cargo run'; $c.format = 'cargo fmt --check'
  }
  elseif (Test-Path (Join-Path $d 'CMakeLists.txt')) {
    $s = 'cmake'
    $c.compile = 'cmake -S . -B build && cmake --build build -j 2'; $c.test = 'ctest --test-dir build -R "{tests}"'
  }
  elseif (Test-Path (Join-Path $d 'Makefile')) {
    $s = 'make'
    $c.compile = 'make'
    if ((ReadText (Join-Path $d 'Makefile')) -match '(?m)^test\s*:') { $c.test = 'make test' }
  }
  $s
} }
