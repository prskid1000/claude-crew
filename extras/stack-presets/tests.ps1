# Tests of the extra stack-presets: dev.ps1 stack finds Android Gradle, .NET, Go, Rust, CMake and Make projects. Run from a kit clone:
#   pwsh extras/stack-presets/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per stack; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/dev-kit/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/dev-kit/adapters/stack_presets.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) "stack-presets-$PID"; $fail = 0
# detect runs inside dev.ps1's Invoke-Stack: its helpers, as there
function Wrapper($d, $name, $winExt, $fallback) { $fallback }
function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
$cases = [ordered]@{ 'android-gradle' = @('build.gradle', 'android { productFlavors { create("store") } }'); dotnet = @('a.csproj', '<Project Sdk="Microsoft.NET.Sdk"></Project>'); go = @('go.mod', 'module x'); rust = @('Cargo.toml', '[package]')
  cmake = @('CMakeLists.txt', 'project(x)'); make = @('Makefile', "test:`n`techo ok") }
foreach ($name in $cases.Keys) {
  $d = Join-Path $root $name; New-Item -ItemType Directory -Force $d | Out-Null; Set-Content (Join-Path $d $cases[$name][0]) $cases[$name][1]
  if ($name -eq 'android-gradle') { New-Item -ItemType Directory -Force "$d/src/main" | Out-Null; '<manifest/>' | Set-Content "$d/src/main/AndroidManifest.xml" }
  $c = [ordered]@{ compile = $null; test = $null }
  $got = & $KitAdapters.stack.presets.detect @{ dir = $d; commands = $c }
  $ok = $got -eq $name -and $c.compile -and $c.compile -notmatch '\{sln\}' -and ($name -ne 'android-gradle' -or $c.compile -match 'compileStoreDebugSources'); if (-not $ok) { $fail++ }
  "$(if ($ok) { 'PASS' } else { 'FAIL' }) $name -> $got, compile: $($c.compile)"
}
Remove-Item -Recurse -Force $root
exit [int]($fail -gt 0)