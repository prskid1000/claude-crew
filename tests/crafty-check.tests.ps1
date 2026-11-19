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
# gate queue (owner 2026-11-19): an agent's build > QA > background; in a class a 20+ min wait first, then fewer recent starts, the shorter build
$go = Invoke-PsTest 'gate-order' @'
. $args[0] *>$null; $gn = Get-Date; $tk = { param($o, $p, $m, $s) [pscustomobject]@{ owner = $o; prio = $p; since = $gn.AddMinutes(-$m).ToString('o'); sec = $s } }
(@(Get-GateOrder @((& $tk bg 2 30 10), (& $tk qa 1 5 60), (& $tk long 0 5 900), (& $tk short 0 2 60), (& $tk old 0 25 900), (& $tk busy 0 6 30)) @{ busy = 3 } $gn) | ForEach-Object owner) -join ','
'@ @($D)
Expect "gate order: class, then aged, fewer recent starts, shorter ($go)" ("$go" -eq 'old,short,long,busy,qa,bg')
# a board message reaches a workflow step between beats: its next gated build prints it once (marked read); supervise sends the
# build-batching rule once an hour per owner
$Bo = Join-Path $k 'skills/bossy/bossy.ps1'
$null = pwsh @np $Bo board join -Agent W9 -Run r9 2>&1   # off the board (a worktree-name owner): no message
$ib = & { . $Bo 6>$null; $n = Get-Date; $r0 = Send-KitBuildsRule 'wt9' 27 8 $n; $r1 = Send-KitBuildsRule 'W9' 27 8 $n; $r2 = Send-KitBuildsRule 'W9' 30 8 $n.AddMinutes(10)
  "$r0|$r1|$r2|$(@(Get-Content (Get-InboxFile 'W9')).Count)|$(@(Read-KitInboxNew 'W9').Count)|$(Test-Path (Get-InboxFile 'wt9'))" }
$gt = @(& { $env:CLAUDE_AGENT = 'W9b'; . $Bo 6>$null; Send-BoardMsg 'supervise' 'W9b' 'batch your fixes' 'rule' 'gate.buildsPerHour'; foreach ($gi in 1, 2) { pwsh @np $D gate -Dir $k -Cmd 'echo built' -WaitMinutes 0 2>&1 }; $env:CLAUDE_AGENT = $null } | Out-String)
Expect "inbox: the rule sent once an hour per owner; the owner's next gated build prints it once ($ib; $(([regex]::Matches($gt, '\[gate\] MESSAGE for W9b')).Count))" ("$ib" -match '^\|sent \d\d:\d\d\|sent \d\d:\d\d\|1\|1\|False$' -and ([regex]::Matches($gt, '\[gate\] MESSAGE for W9b .*batch your fixes')).Count -eq 1)

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
$cmds = @('echo gradlew build', 'echo mvn -q test & echo %MAVEN_OPTS%', 'echo jest x & echo %NODE_OPTIONS%', 'echo mvn -q test & echo tmp=%TMP%', 'echo gradlew test & echo tmp=%TMP%', 'echo vitest run y && echo tsc z')
$out = @(foreach ($c in $cmds) { pwsh @np $D gate -Dir $bd -Cmd $c 2>&1 | Out-String })
Remove-Item Env:MAVEN_OPTS; $env:CLAUDE_GATE_KEEP_FREE_GB = '0'   # the harness value
Expect 'gate: jest / vitest get --maxWorkers=2 right after the runner word, not on a later tool (K70g)' ($out[2] -match 'jest --maxWorkers=2 x' -and $out[5] -match 'vitest run --maxWorkers=2 y' -and $out[5] -notmatch 'tsc z --maxWorkers')
Expect 'build-heap: gradle gets -Dorg.gradle.jvmargs' ($out[0] -match 'gradlew "?-Dorg\.gradle\.jvmargs=-Xmx\d+g')
$gw = & { $go0 = $env:GRADLE_OPTS; try { foreach ($gwv in '', '2') { $env:GRADLE_OPTS = $null; $env:KIT_PARAM_GATE_GRADLEWORKERS = $(if ($gwv) { $gwv } else { $null }); . (Join-Path $k 'skills/crafty/lib.ps1'); $null = Get-GateHeap 'gradle' @() 0 0; $env:GRADLE_OPTS } } finally { $env:GRADLE_OPTS = $go0; Remove-Item Env:KIT_PARAM_GATE_GRADLEWORKERS -ErrorAction SilentlyContinue } }
Expect "build-heap: gradle workers from gate.gradleWorkers (default 4) ($($gw -join ' | '))" (($gw -join '|') -eq '-Dorg.gradle.workers.max=4|-Dorg.gradle.workers.max=2')
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

# check stamps: a step that passed on the same sources with the same command is not rerun; a doc edit keeps the stamp, a
# source edit, other tests, -Force or a failed run rerun it
$sd = Join-Path (Kd) 'stamp-repo'; $cnt = Join-Path (Kd) 'stamp-count.js'; $runs = Join-Path (Kd) 'stamp-runs.txt'; $failFlag = Join-Path (Kd) 'stamp-fail.flag'
New-Item -ItemType Directory -Force "$sd/src" | Out-Null; 'a' | Set-Content "$sd/src/a.txt"; 'doc' | Set-Content "$sd/README.md"
"const fs = require('fs'); fs.appendFileSync(String.raw``$runs``, 'x'); process.exit(fs.existsSync(String.raw``$failFlag``) ? 1 : 0)" | Set-Content $cnt
(@{ stack = 'custom'; commands = @{ test = "node `"$cnt`" {tests}" } } | ConvertTo-Json) | Set-Content "$sd/.claude-stack.json"
git -C $sd init -q; git -C $sd add -A; git -C $sd -c user.name=t -c user.email=t@t commit -q -m init
$stampRun = { param([string[]]$More) $o = pwsh @np $D check -Dir $sd -Step test @More 2>&1 | Out-String; "${LASTEXITCODE}:$((Get-Content $runs -Raw -ErrorAction SilentlyContinue).Length):$([int]($o -match 'not rerun'))" }
$sr = @(& $stampRun '-Tests', 'A'; & $stampRun '-Tests', 'A'; ('doc 2' | Set-Content "$sd/README.md"); & $stampRun '-Tests', 'A'; & $stampRun '-Tests', 'A', '-Force'
  ('b' | Set-Content "$sd/src/b.txt"); & $stampRun '-Tests', 'A'; & $stampRun '-Tests', 'B'; (New-Item -Force $failFlag | Out-Null); ('c' | Set-Content "$sd/src/a.txt"); & $stampRun '-Tests', 'A'; & $stampRun '-Tests', 'A')
Expect "check stamps: rerun skipped on the same sources, doc edit kept, -Force / source edit / other tests / failed run rerun ($($sr -join ' '))" (
  ($sr -join ' ') -eq '0:1:0 0:1:1 0:1:1 0:2:0 0:3:0 0:4:0 1:5:0 1:6:0')
# source key: 400 untracked long names (past the Windows command line) still hash and see an edit; a .md under src/ counts,
# a top-level doc does not; a quoted name (not on Windows) is unescaped
$keyOf = { pwsh -NoProfile -Command ". '$(Lib)'; Get-CheckSourceKey '$sd'" }
$k0 = & $keyOf; New-Item -ItemType Directory -Force "$sd/gen" | Out-Null; foreach ($i in 1..400) { 'x' | Set-Content ("$sd/gen/" + ('n' * 90) + "$i.txt") }
$k1 = & $keyOf; 'y' | Set-Content ("$sd/gen/" + ('n' * 90) + '7.txt'); $k2 = & $keyOf; Remove-Item -Recurse -Force "$sd/gen"
'm' | Set-Content "$sd/src/tpl.md"; $k3 = & $keyOf; 'n' | Set-Content "$sd/NOTES.md"; $k4 = & $keyOf
$q = if (-not $IsWindows) { 'q1' | Set-Content "$sd/src/we`"ird.txt"; $q1 = & $keyOf; 'q2' | Set-Content "$sd/src/we`"ird.txt"; [int]($q1 -ne (& $keyOf)) } else { 1 }
Expect "check stamps: source key over many long untracked names, an edit among them, a src/ .md counted, a top-level doc not, a quoted name ($k0 $k1 $k2 $k3 $k4 $q)" (
  $k0 -match '^[0-9a-f]{40}$' -and $k1 -match '^[0-9a-f]{40}$' -and $k1 -ne $k0 -and $k2 -ne $k1 -and $k3 -ne $k0 -and $k4 -eq $k3 -and $q -eq 1)
# a Spring Boot Maven module's check build skips the repackage (no fat jar a lane never stages); a plain one keeps package
$sb = Join-Path (Kd) 'sb'; $pl = Join-Path (Kd) 'plain'; New-Item -ItemType Directory -Force $sb, $pl | Out-Null
'<project><parent><artifactId>spring-boot-starter-parent</artifactId></parent></project>' | Set-Content "$sb/pom.xml"; '<project/>' | Set-Content "$pl/pom.xml"
$bs = (pwsh @np $D stack -Dir $sb -Json | ConvertFrom-Json).commands.build; $bp = (pwsh @np $D stack -Dir $pl -Json | ConvertFrom-Json).commands.build
Expect "stack: Spring Boot check build skips the repackage, a plain Maven build does not ($bs | $bp)" ($bs -match 'package -DskipTests -Dspring-boot\.repackage\.skip=true$' -and $bp -match 'package -DskipTests$')

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
