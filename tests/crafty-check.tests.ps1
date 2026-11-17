#Requires -Version 7
<#
tests/crafty-check.tests.ps1: crafty.ps1 check / gate / stack on one test kit: stack presets detect, the ts-typecheck baseline,
build heap and temp per stack, spec.mjs without esbuild, the container engine check (last: it leases a runtime).
Usage: pwsh -NoProfile -File tests/crafty-check.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/stack_presets.ps1', 'skills/crafty/adapters/ts_typecheck.ps1', 'skills/crafty/adapters/build_heap.ps1', 'skills/crafty/spec.mjs',
  'skills/crafty/adapters/container_tests.ps1', 'skills/crafty/adapters/runtimes.ps1')   # copied into the test kit
$k = New-TestKit check; $D = Join-Path $k 'skills/crafty/crafty.ps1'

# stack presets: detect finds Android Gradle, .NET, Go, Rust, CMake and Make projects (crafty.ps1 Invoke-Stack helpers, as there)
$cases = [ordered]@{ 'android-gradle' = @('build.gradle', 'android { productFlavors { create("store") } }'); dotnet = @('a.csproj', '<Project Sdk="Microsoft.NET.Sdk"></Project>'); go = @('go.mod', 'module x'); rust = @('Cargo.toml', '[package]')
  cmake = @('CMakeLists.txt', 'project(x)'); make = @('Makefile', "test:`n`techo ok") }
$sp = & { . (Lib); . (Join-Path $k 'skills/crafty/adapters/stack_presets.ps1')
  function Wrapper($d, $name, $winExt, $fallback) { $fallback }
  function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
  foreach ($name in $cases.Keys) {
    $stackDir = Join-Path (Kd) "stack-$name"; New-Item -ItemType Directory -Force $stackDir | Out-Null; Set-Content (Join-Path $stackDir $cases[$name][0]) $cases[$name][1]
    if ($name -eq 'android-gradle') { New-Item -ItemType Directory -Force "$stackDir/src/main" | Out-Null; '<manifest/>' | Set-Content "$stackDir/src/main/AndroidManifest.xml" }
    $c = [ordered]@{ compile = $null; test = $null }; $got = & $KitAdapters.stack.presets.detect @{ dir = $stackDir; commands = $c }
    [pscustomobject]@{ name = $name; got = $got; compile = $c.compile; ok = $got -eq $name -and $c.compile -and $c.compile -notmatch '\{sln\}' -and ($name -ne 'android-gradle' -or $c.compile -match 'compileStoreDebugSources') } } }
foreach ($s in $sp) { Expect "$($s.name) -> $($s.got), compile: $($s.compile)" $s.ok }

# ts-typecheck: a huge tsc baseline is UNRUN, an error in a changed file fails
$ud = Join-Path (Kd) 'ts-repo'; New-Item -ItemType Directory -Force "$ud/src" | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
'for (let i = 0; i < 250; i++) console.log(`src/old${i}.ts(1,1): error TS2322: x`); if (require("fs").existsSync("src/new.ts")) console.log("src/new.ts(2,3): error TS2304: y"); process.exit(2)' | Set-Content "$ud/tsc.js"
git -C $ud init -q; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m init
$out = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String; $c1 = $LASTEXITCODE
'let a = b' | Set-Content "$ud/src/new.ts"
$out2 = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String; $c2 = $LASTEXITCODE
Expect "ts-typecheck: > 200 baseline errors = UNRUN, exit 5 ($c1)" ($c1 -eq 5 -and $out -match 'UNRUN' -and $out -match 'BASELINE: 250 errors')
Expect "ts-typecheck: an error in a changed file fails, the baseline does not ($c2)" ($c2 -eq 1 -and $out2 -match 'src/new\.ts\(2,3\)' -and $out2 -match '1 errors in your changed files')

# build-heap: Gradle gets -Dorg.gradle.jvmargs, Maven MAVEN_OPTS, Node NODE_OPTIONS; a gated build's temp
$bd = Join-Path (Kd) 'b'; New-Item -ItemType Directory -Force $bd | Out-Null
$env:CLAUDE_GATE_KEEP_FREE_GB = '0'; $env:MAVEN_OPTS = '-Xmx1g -Dkeep=1'
$cmds = @('echo gradlew build', 'echo mvn -q test & echo %MAVEN_OPTS%', 'echo jest x & echo %NODE_OPTIONS%', 'echo mvn -q test & echo tmp=%TMP%', 'echo gradlew test & echo tmp=%TMP%')
$out = @(foreach ($c in $cmds) { pwsh @np $D gate -Dir $bd -Cmd $c 2>&1 | Out-String })
Remove-Item Env:MAVEN_OPTS; $env:CLAUDE_GATE_KEEP_FREE_GB = '0'   # the harness value
Expect 'build-heap: gradle gets -Dorg.gradle.jvmargs' ($out[0] -match 'gradlew "?-Dorg\.gradle\.jvmargs=-Xmx\d+g')
if ($IsWindows) {
  Expect 'build-heap: maven gets -Xmx in MAVEN_OPTS, its own -D kept, the old -Xmx gone' ($out[1] -match '-Dkeep=1 -Xmx\d+g' -and $out[1] -notmatch '-Xmx1g')
  Expect 'build-heap: node gets --max-old-space-size' ($out[2] -match '--max-old-space-size=\d+')
  $kt = TkPath $k tmp; Expect "build-heap: a gated build's temp is <runtime>/tmp/build/<checkout>, gradle keeps the OS temp (its daemon)" (
    $out[3] -match "tmp=$([regex]::Escape($kt))[\\/]build[\\/]kit-test-check-\d+-b\s" -and $out[4] -match 'tmp=' -and $out[4] -notmatch [regex]::Escape($kt))
}

# spec.mjs: without the project's esbuild it exits 2 and says why; --help prints its header
$spec = Join-Path $k 'skills/crafty/spec.mjs'; $proj = Join-Path (Kd) 'node-spec'
New-Item -ItemType Directory -Force (Join-Path $proj 'src') | Out-Null
'{ "name": "p", "devDependencies": { "typescript": "5" } }' | Set-Content (Join-Path $proj 'package.json')
'{ "compilerOptions": {} }' | Set-Content (Join-Path $proj 'tsconfig.json')
"describe('a', () => it('b', () => expect(1).toBe(1)))" | Set-Content (Join-Path $proj 'src/a.spec.ts')
$out = node $spec --dir $proj a.spec 2>&1 | Out-String
Expect 'spec.mjs: no esbuild -> exit 2 with the reason' ($LASTEXITCODE -eq 2 -and $out -match 'no esbuild')
$out = node $spec --help 2>&1 | Out-String
Expect 'spec.mjs --help prints its header' ($LASTEXITCODE -eq 0 -and $out -match 'Exit codes')

# container-tests: no answering engine -> exit 4; a configured runtimes.docker is leased (started when down)
$jd = Join-Path (Kd) 'jvm-repo'; $bin = Join-Path (Kd) 'bin'; New-Item -ItemType Directory -Force $jd, $bin | Out-Null
'<project><dependency>org.testcontainers</dependency></project>' | Set-Content "$jd/pom.xml"; '{ "stack": "java-maven", "commands": { "test": "echo {tests}" } }' | Set-Content "$jd/.claude-stack.json"
if ($IsWindows) { '@exit /b 1' | Set-Content "$bin/docker.cmd"; '@exit /b 1' | Set-Content "$bin/podman.cmd" } else { foreach ($x in 'docker', 'podman') { "#!/bin/sh`nexit 1" | Set-Content "$bin/$x"; chmod +x "$bin/$x" } }
$path0 = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"
$out = pwsh @np $D check -Dir $jd -Step test -Tests OrderIT 2>&1 | Out-String; $c1 = $LASTEXITCODE
$out2 = pwsh @np $D check -Dir $jd -Step test -Tests OrderTest 2>&1 | Out-String; $c2 = $LASTEXITCODE
$kl = Join-Path $k 'skills/crafty/kit.local.json'; $fl = Join-Path (Kd) 'eng.up'; & $J @{ runtimes = @{ docker = @{ isUp = "if (Test-Path '$fl') { 'up' }"; up = "New-Item -Force '$fl' | Out-Null" } } } $kl
$out3 = pwsh @np $D check -Dir $jd -Step test -Tests OrderIT 2>&1 | Out-String; $c3 = $LASTEXITCODE; $ls = pwsh @np $D runtime status -Name docker -Json | Out-String | ConvertFrom-Json; Remove-Item $kl
$env:PATH = $path0
Expect "container-tests: an IT test with no answering engine exits 4 ($c1)" ($c1 -eq 4 -and $out -match 'need a container engine')
Expect "container-tests: a plain unit test runs ($c2)" ($c2 -eq 0 -and $out2 -notmatch 'container engine')
Expect "container-tests: a configured engine that is down is leased and started for an IT test, a failing docker info aside ($c3)" ($c3 -eq 0 -and $out3 -match 'runtime docker: started by the kit' -and $ls[0].leases[0].agent -and $ls[0].startedByKit)
Remove-TestKit $k
Complete-Tests
