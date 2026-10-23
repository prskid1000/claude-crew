#Requires -Version 7
# Extra stack-presets: dev.ps1 stack presets for Android Gradle, .NET (SDK and legacy MSBuild), Go, Rust, CMake and Make.
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add stack-presets); dev.ps1 stack calls 'detect'
# when no core stack (maven, gradle, angular, node, python) matches: $a.dir, $a.commands (filled) -> the stack name.
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
