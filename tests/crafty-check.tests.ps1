#Requires -Version 7
<#
tests/crafty-check.tests.ps1: crafty.ps1 check / gate / stack on one test kit: stack presets detect, the ts-typecheck baseline,
build heap and temp per stack, spec.mjs without esbuild, the container engine check (it leases a runtime), check -Step e2e spec picking (from guard.tests).
Usage: pwsh -NoProfile -File tests/crafty-check.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/stack-presets.ps1', 'skills/crafty/adapters/ts-typecheck.ps1', 'skills/crafty/adapters/build-heap.ps1', 'skills/crafty/spec.mjs',
  'skills/crafty/adapters/container-tests.ps1', 'skills/crafty/adapters/runtimes.ps1')   # copied into the test kit
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
# retro tidy-6: a ledger entry swept while the build runs (supervise, cleanup) ends quietly, no Get-Content error
$glS = TkPath $k build-gate -Create; $gsO = pwsh @np $D gate -Dir $k -Cmd "pwsh -NoProfile -Command Remove-Item $glS/[0-9]*.json" -WaitMinutes 5 2>&1 | Out-String; $gsC = $LASTEXITCODE
Expect "gate: its swept ledger entry is no error ($gsC $(@($gsO -split "`n" | Select-Object -Last 2) -join ' / '))" ($gsC -eq 0 -and $gsO -notmatch 'Cannot find path|PathNotFound')

# stack presets: detect finds Android Gradle, .NET, Go, Rust, CMake and Make projects (crafty.ps1 Invoke-Stack helpers, as there)
$cases = [ordered]@{ 'android-gradle' = @('build.gradle', 'android { productFlavors { create("store") } }'); dotnet = @('a.csproj', '<Project Sdk="Microsoft.NET.Sdk"></Project>'); go = @('go.mod', 'module x'); rust = @('Cargo.toml', '[package]')
  cmake = @('CMakeLists.txt', 'project(x)'); make = @('Makefile', "test:`n`techo ok") }
$sp = & { . (Lib); . (Join-Path $k 'skills/crafty/adapters/stack-presets.ps1')
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
# GB defaults sized for 64 GB scale down with RAM (rounded up to 8 GB); a pin stays as set
$rs = Invoke-PsTest 'ram-scale' @'
. $args[0]; $ErrorActionPreference = 'Stop'
foreach ($ramGB in 63.4, 16, 6) { $script:GateRamScale = $null; function Get-SysMem { [pscustomobject]@{ TotalGB = $ramGB } }
  "${ramGB}:$(Get-GateKindGB 'android-build')/$((Get-GateHeap 'gradle' @() 0 0).heap)/$((Get-GateHeap 'maven' @() 0 0).heap)" }
$env:KIT_PARAM_GATE_KINDGB_ANDROID_BUILD = '9'; "pin:$(Get-GateKindGB 'android-build')"
'@ @((Join-Path $k 'skills/crafty/lib.ps1'))
# repos[].hooksPath: a fresh worktree gets <hooksPath>/_ (default .husky), never another tool's folder
$hk = Invoke-PsTest 'hooks-dir' @'
. $args[0] 6>$null; $ErrorActionPreference = 'Stop'; $hsrc = Join-Path $args[1] 'hsrc'
foreach ($hdn in '.husky', '.githooks') { New-Item -ItemType Directory -Force (Join-Path $hsrc "$hdn/_") | Out-Null; Set-Content (Join-Path $hsrc "$hdn/_/h") 'x' }
foreach ($hcase in @(@{ n = 'def'; rc = $null }, @{ n = 'own'; rc = [pscustomobject]@{ hooksPath = '.githooks' } })) {
  $hdst = Join-Path $args[1] "hdst-$($hcase.n)"; New-Item -ItemType Directory -Force $hdst | Out-Null; $hdir = Get-WtHooksDir $hcase.rc; Copy-HookDirs $hdst @($hsrc) $hdir
  "$($hcase.n):$hdir|$(Test-Path (Join-Path $hdst '.husky/_/h'))|$(Test-Path (Join-Path $hdst '.githooks/_/h'))" }
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Kd))
Expect "wt hooks: default .husky/_ copied; repos[].hooksPath .githooks copies only its own ($($hk -join ' | '))" ((@($hk -match '^(def|own):') -join '|') -eq 'def:.husky|True|False|own:.githooks|False|True')
Expect "build-heap: kindGB and heap defaults scale with RAM (64 GB as is; 16 GB a quarter; 8 GB floor), a pin unscaled ($($rs -join ' | '))" (($rs -join '|') -eq '63.4:7/12/8|16:1.75/3/2|6:0.875/1.5/1|pin:9')
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
# tests.specTimeoutMs: a kit.local.json pin wins over the registry default (5000), KIT_PARAM_ over both
$spK = Join-Path (Kd) 'spk'; New-Item -ItemType Directory -Force "$spK/skills/crafty", "$spK/skills/bossy" | Out-Null; & $J @{ params = @{ 'tests.specTimeoutMs' = 'config default=5000 unit=ms' } } "$spK/skills/bossy/params.registry.json"
$spJ = Join-Path (Kd) 'spk.mjs'; [IO.File]::WriteAllText($spJ, @'
import fs from 'node:fs'; import { join } from 'node:path'
const { readFileSync } = fs, src = readFileSync(process.argv[2], 'utf8'), KIT = process.argv[3]
eval(src.slice(src.indexOf('function kitParam'), src.indexOf('const SPEC_TIMEOUT_MS')).replace('function kitParam', 'globalThis.kitParam = function'))
console.log(kitParam('tests.specTimeoutMs'))
'@)
$spD = node $spJ $spec $spK; & $J @{ tests = @{ specTimeoutMs = 20000 } } "$spK/skills/crafty/kit.local.json"; $spP = node $spJ $spec $spK
$env:KIT_PARAM_TESTS_SPECTIMEOUTMS = '7000'; $spE = node $spJ $spec $spK; $env:KIT_PARAM_TESTS_SPECTIMEOUTMS = $null
Expect "spec.mjs tests.specTimeoutMs: registry default, kit.local.json pin, KIT_PARAM_ env ($spD $spP $spE)" ("$spD|$spP|$spE" -eq '5000|20000|7000')

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
$bs = (pwsh @np $D stack -Dir $sb -Json | ConvertFrom-Json).commands.build; $bpj = pwsh @np $D stack -Dir $pl -Json | ConvertFrom-Json; $bp = $bpj.commands.build
Expect "stack: the core preset names Maven; Spring Boot check build skips the repackage, a plain one does not; no -o unless build.mavenOffline ($bs | $bp)" ($bs -match 'package -DskipTests -Dspring-boot\.repackage\.skip=true$' -and $bp -match 'package -DskipTests$' -and $bpj.stack -eq 'java-maven' -and $bp -notmatch ' -o ')
# an Android Gradle module with root node tooling: the core preset leaves it to the Android preset (no node fall-through)
$an = Join-Path (Kd) 'and-rn'; New-Item -ItemType Directory -Force "$an/src/main" | Out-Null; 'android { }' | Set-Content "$an/build.gradle"; '<manifest/>' | Set-Content "$an/src/main/AndroidManifest.xml"; '{ "name": "x" }' | Set-Content "$an/package.json"
$ans = "$((pwsh @np $D stack -Dir $an -Json | ConvertFrom-Json).stack)"
Expect "stack: Android Gradle + a root package.json = android-gradle, not node ($ans)" ($ans -eq 'android-gradle')
# e2e runners (vocab.json testRunners): a bare playwright suite is refused like a bare cypress run; its package names the e2e step
$pwg = pwsh @np $D gate -Dir $an -Cmd 'npx playwright test' 2>&1 | Out-String; $pwc = $LASTEXITCODE
$pwDir = Join-Path (Kd) 'pw'; New-Item -ItemType Directory -Force $pwDir | Out-Null; '{ "devDependencies": { "@playwright/test": "1" } }' | Set-Content "$pwDir/package.json"
$pwe = "$((pwsh @np $D stack -Dir $pwDir -Json | ConvertFrom-Json).commands.e2e)"
Expect "e2e runners: bare playwright test refused (exit $pwc); @playwright/test -> its e2e step ($pwe)" ($pwc -eq 2 -and $pwg -match 'runs the whole e2e suite' -and $pwe -eq 'npx playwright test {specs}')

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
# digest (owner 2026-11-22: 60 agents pasted whole logs): a 200-line failing run prints its failure line (+2 after), the last 10 and
# the log path, never line 50; a passing run the last 10; a short run whole
$dg = Join-Path (Kd) 'digest-repo'; New-Item -ItemType Directory -Force $dg | Out-Null; '<project></project>' | Set-Content "$dg/pom.xml"
'param($n, $rc) 1..$n | ForEach-Object { if ($_ -eq 100) { "ERROR boom in Foo" } else { "noise $_" } }; exit $rc' | Set-Content "$dg/gen.ps1"
$dgr = foreach ($c in @(@('fail', 200, 1), @('pass', 200, 0), @('short', 5, 0))) {
  "{ ""stack"": ""java-maven"", ""commands"": { ""test"": ""pwsh -NoProfile -File gen.ps1 $($c[1]) $($c[2]) {tests}"" } }" | Set-Content "$dg/.claude-stack.json"
  $o = pwsh @np $D check -Dir $dg -Step test -Tests DigestTest -Force 2>&1 | Out-String
  "$($c[0]):$LASTEXITCODE,$($o -match 'ERROR boom in Foo'),$($o -match 'noise 101\b'),$($o -match 'noise [15]0\b'),$($o -match 'noise (200|5)\b'),$($o -match 'the full log: \S+\.log')" }
Expect "check digest: failure line + 2 after, the last 10, the log path; a pass only the tail; a short run whole ($($dgr -join ' '))" (($dgr -join ' ') -eq 'fail:1,True,True,False,True,True pass:0,False,False,False,True,True short:0,False,False,False,True,False')
Expect "container-tests: an IT test with no answering engine exits 4 ($c1)" ($c1 -eq 4 -and $out -match 'need a container engine')
Expect "container-tests: a plain unit test runs ($c2)" ($c2 -eq 0 -and $out2 -notmatch 'container engine')
Expect "container-tests: a configured engine that is down is leased and started for an IT test, a failing docker info aside ($c3)" ($c3 -eq 0 -and $out3 -match 'runtime docker: started by the kit' -and $ls[0].leases[0].agent -and $ls[0].startedByKit)
# Invoke-KitVerb (moved here for the per-file test caps)
$dashRun = pwsh -NoProfile -Command ". '$(Lib)'; function Invoke-M { param([string]`$Run, [string]`$Message) ""`$Run|`$Message"" }; Invoke-KitVerb Invoke-M @('-Run', '-hm-1121', '-Message', 'm'); Invoke-KitVerb Invoke-M @('-Run', '-Mess', 'x')"
$dashTypo = pwsh -NoProfile -Command ". '$(Lib)'; function Invoke-M { param([string]`$Run) `$Run }; Invoke-KitVerb Invoke-M @('-Run', '-Agnet', 'x')" 2>&1 | Out-String; $dashRc = $LASTEXITCODE
Expect "Invoke-KitVerb: a dash-leading value naming no parameter is the value; a parameter name stays one; a typo exits 2 ($($dashRun -join ' / ') | $dashRc)" (($dashRun -join ' / ') -eq '-hm-1121|m / |x' -and $dashRc -eq 2 -and $dashTypo -match 'unknown or ambiguous parameter -Agnet')
# python -Tests <folder>: its test_*.py scripts run directly, never `unittest <folder>` (0 tests, exit 5: retro 1709)
$pvd = Join-Path (Kd) 'py-val'; New-Item -ItemType Directory -Force "$pvd/validation" | Out-Null; 'x==1' | Set-Content "$pvd/requirements.txt"
'print("ok")' | Set-Content "$pvd/validation/test_alpha.py"; 'print("ok")' | Set-Content "$pvd/validation/helper.py"
New-Item -ItemType Directory -Force "$pvd/cases/sub" | Out-Null; "import unittest`nclass T(unittest.TestCase):`n    def test_a(self): pass" | Set-Content "$pvd/cases/sub/test_c.py"
$pvc = pwsh @np $D check -Dir $pvd -Step test -Tests cases -Show 2>&1 | Out-String
Expect "check python -Tests <folder with test cases>: the runner gets the folder ($($pvc.Trim() -replace '\s+', ' '))" ($pvc -match 'test\s*:.*\bcases\b' -and $pvc -notmatch 'test_c\.py')
$pvo = pwsh @np $D check -Dir $pvd -Step test -Tests validation -Show 2>&1 | Out-String
Expect "check python -Tests <folder>: each test_*.py run with python, no unittest ($($pvo.Trim() -replace '\s+', ' '))" ($pvo -match 'test\s*:.*"validation/test_alpha\.py"' -and $pvo -notmatch 'unittest|helper\.py')
# e2e (from guard.tests: its cap): the changed specs, else the diff's specs (map, folder, name, imports, visits), none = NOT_TESTED, the whole suite only with -AllTests (logged)
$er = Join-Path (Kd) 'e2e-repo'; $ef = @{ 'cypress/e2e/02-orders/01.create.cy.ts' = 'x'; 'cypress/e2e/misc.cy.ts' = "import { a } from '../../src/app/orders/list.component'`nimport d from '../fixtures/d.json'"; 'cypress/fixtures/d.json' = '1'; 'cypress/e2e/pay.cy.ts' = 'x'; 'cypress/e2e/n.cy.ts.snap' = 'x'; 'src/app/pay/components/row/row.ts' = 'a'
  'cypress/e2e/nav.cy.ts' = "cy.visit('/orders?x=1')"; 'cypress/e2e/users.cy.ts' = "cy.visit('/users')"; 'cypress/e2e/invoices/a.cy.ts' = 'x'; 'src/app/orders/list.component.ts' = 'a'; 'src/billing/rate.ts' = 'a' }
foreach ($p in $ef.Keys) { New-Item -Force "$er/$p" -Value $ef[$p] | Out-Null }; '{ "commands": { "e2e": "node -e 0 cypress run --spec \"{specs}\"" }, "stack": "custom" }' | Set-Content "$er/.claude-stack.json"; Save-GitRepo $er i
& $J @{ tests = @{ e2e = @{ map = @(@{ paths = @('src/billing/**'); specs = @('cypress/e2e/invoices/**') }) } } } $kl
$e2 = { param($f, [string[]]$x = @()) git -C $er checkout -q -- .; foreach ($p in @($f)) { Add-Content "$er/$p" 'b' }; Invoke-TestScript $D check -Dir $er -Step e2e @x }
$cy = Join-Path (Kd) 'cy'; $null = mkdir -Force $cy; '{ "devDependencies": { "cypress": "13" } }' | Set-Content "$cy/package.json"; $cs = pwsh @np $D stack -Dir $cy 2>&1 | Out-String
Expect-Cases @(
  , @('check -Step e2e: the map picks its specs', { & $e2 'src/billing/rate.ts' '-Show' }, { param($r) $r.code -eq 0 -and $r.out -match 'invoices/a\.cy\.ts <- map src/billing/\*\*' -and $r.out -match '--spec "cypress/e2e/invoices/a\.cy\.ts"' -and $r.out -notmatch 'orders' })
  , @('check -Step e2e: unmapped -> folder, imports, visits; unrelated specs left out', { & $e2 'src/app/orders/list.component.ts' '-Show' },
      { param($r) $r.out -match '02-orders/01\.create\.cy\.ts <- folder orders' -and $r.out -match 'misc\.cy\.ts <- imports src/app/orders/list\.component\.ts' -and $r.out -match 'nav\.cy\.ts <- visits /orders\?x=1' -and $r.out -notmatch 'users\.cy|invoices' })
  , @('check -Step e2e: nested file -> its nearest named folder; a changed JSON a spec imports; a .snap is no spec', { & $e2 @('src/app/pay/components/row/row.ts', 'cypress/fixtures/d.json') '-Show' }, { param($r) $r.out -match 'pay\.cy\.ts <- folder pay' -and $r.out -match 'misc\.cy\.ts <- imports cypress/fixtures/d\.json' -and $r.out -match '\(of 6\)' })
  , @('check -Step e2e: changed specs only, related ones left out (named)', { & $e2 @('src/billing/rate.ts', 'cypress/e2e/pay.cy.ts') '-Show' }, { param($r) $r.out -match 'the 1 changed spec\(s\) only; 1 related' -and $r.out -match '--spec "cypress/e2e/pay\.cy\.ts"' -and $r.out -notmatch 'invoices/a' })
  , @('check -Step e2e: a changed fixture keeps its related specs next to a changed spec', { & $e2 @('cypress/fixtures/d.json', 'cypress/e2e/pay.cy.ts') '-Show' }, { param($r) $r.out -match 'misc\.cy\.ts <- imports' -and $r.out -notmatch 'changed spec\(s\) only' })
  , @('check -Step e2e: no related spec = NOT_TESTED (exit 5), nothing runs', { & $e2 'README.md' }, { param($r) $r.code -eq 5 -and $r.out -match 'e2e NOT_TESTED: no spec relates to the 1 changed file' -and $r.out -notmatch 'gate' })
  , @('check -Step e2e -AllTests: the whole suite, logged; gate refuses a bare suite; cypress dep = e2e step', { $a = & $e2 'src/billing/rate.ts' '-AllTests'; $g = Invoke-TestScript $D gate -Dir $er -Cmd 'npx cypress run'; $a.out += "|$($g.code)|$(pwsh -NoProfile -Command ". '$(Lib)'; @(Read-KitLog builds | Where-Object event -eq e2e-all).Count")"; $a },
      { param($r) $r.code -eq 0 -and $r.out -match 'WHOLE suite' -and $r.out -match '\|2\|1' -and $cs -match 'e2e\s+npx cypress run --spec "\{specs\}"' })
)
& $J @{ tests = @{ e2e = @{ run = @(@{ dir = ''; cmd = 'x -r0 --spec "{specs}"'; env = @{ CY_L = '1' }; split = 'folder' }) } } } $kl
$er2 = "$((& $e2 'src/app/orders/list.component.ts' '-Show').out)|$((& $e2 'README.md' @('-AllTests', '-Show')).out)"
Expect 'check -Step e2e: tests.e2e.run = cmd + env, one run per spec folder; -AllTests: a folder glob each' ($er2 -match 'env: CY_L=1' -and $er2 -match 'e2e : x -r0 --spec "cypress/e2e/02-orders/01\.create\.cy\.ts"' -and
  $er2 -match '"cypress/e2e/(misc|nav)\.cy\.ts,cypress/e2e/(misc|nav)\.cy\.ts"' -and $er2 -match '"cypress/e2e/invoices/\*\.cy\.\*"' -and @([regex]::Matches($er2, 'e2e : ')).Count -eq 5)
# the run's lane (retro 2026-11-25: specs hit lane 1 :8443 while the branch was live on lane 2): the lane holding the branch's layer, its ports in cmd + env; -Lane names one
$elE = Join-Path $k 'skills/envy/envy.ps1'; New-Item -ItemType Directory -Force (Split-Path $elE) | Out-Null   # a stub of envy.ps1 envs -Json (env, group, lane, ports)
"'[{`"env`":`"shop`",`"group`":`"shop`",`"lane`":1,`"ports`":{`"web`":4200,`"api`":8443}},{`"env`":`"shop2`",`"group`":`"shop`",`"lane`":2,`"ports`":{`"web`":4300,`"api`":8543}}]'" | Set-Content $elE
& $J @{ tests = @{ e2e = @{ run = @(@{ dir = ''; cmd = 'x --grep t:4200 --config baseUrl=http://127.0.0.1:4200 --spec "{specs}"'; env = @{ CY_API = 'http://127.0.0.1:{port:api}' } }) } } } $kl
$elS = Join-Path (TkPath $k localenv -Create) 'shop2.json'; & $J @{ release = @{ repos = @{ web = @{ layers = @(@{ branch = "$(git -C $er branch --show-current)"; agent = 'a1' }) } } } } $elS
$el = (& $e2 'src/app/orders/list.component.ts' '-Show').out; $elN = (& $e2 'src/app/orders/list.component.ts' @('-Show', '-Lane', 'shop')).out
Expect "check -Step e2e: the branch's lane ports in cmd + env; -Lane shop = lane 1 ($(($el -split "`n" | Where-Object { $_ -match 'lane|e2e (env|:)' }) -join ' / '))" ($el -match 'lane shop2 \(holds .+\): its ports in the recipe' -and $el -match 'baseUrl=http://127\.0\.0\.1:4300 ' -and $el -match '--grep t:4200 ' -and $el -match 'CY_API=http://127\.0\.0\.1:8543' -and $elN -match 'baseUrl=http://127\.0\.0\.1:4200 ' -and $elN -match 'CY_API=http://127\.0\.0\.1:8443')
Remove-Item $elS, $elE
Remove-Item $kl
# a Maven test step builds the reactor modules it depends on (transitively) whose sources are newer than their local-repo artefact,
# and those between, in one reactor with the tests (retro: stale sibling jar); never installs into the shared local repository
$rx = Invoke-PsTest 'reactor-deps' @'
$r = Join-Path $args[1] 'reactor'; $repo = Join-Path $args[1] 'm2'; $env:MAVEN_REPO_LOCAL = $repo
$pom = { param($d, $a, $deps, $mods) New-Item -ItemType Directory -Force "$d/src/main" | Out-Null; 'x' | Set-Content "$d/src/main/X.java"
  "<project><groupId>org.example</groupId><artifactId>$a</artifactId><version>1.0</version>$(if ($mods) { "<modules>$(-join ($mods | ForEach-Object { "<module>$_</module>" }))</modules>" })<dependencies>$(-join ($deps | ForEach-Object { "<dependency><groupId>`${project.groupId}</groupId><artifactId>$_</artifactId></dependency>" }))</dependencies></project>" | Set-Content "$d/pom.xml" }
& $pom $r 'root' @() @('core', 'mid', 'app', 'other'); & $pom "$r/core" 'core' @() @(); & $pom "$r/mid" 'mid' @('core') @(); & $pom "$r/app" 'app' @('mid') @(); & $pom "$r/other" 'other' @() @()
New-Item -ItemType Directory -Force "$repo/org/example/mid/1.0" | Out-Null; 'j' | Set-Content "$repo/org/example/mid/1.0/mid-1.0.jar"   # mid fresh, core missing
$script:calls = @(); $KitCmd = @{ dev = 'fake' }; function fake { $script:calls += , @($args); $global:LASTEXITCODE = 0 }; function Get-CheckLog { 'log' }
. $args[0]; $st = @{ dir = "$r/app"; commands = @{ test = 'mvn test' } }; $Show = $false
$m2Before = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
$fl = Add-KitReactorTestFlags 'mvn -q test -Dtest=AppTest' 6>$null; $agg = Join-Path $r 'target/crafty-reactor-app.xml'
$m2After = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
"first:$fl|agg:$(if (Test-Path -LiteralPath $agg) { Get-Content -LiteralPath $agg -Raw })|m2:$($m2Before -eq $m2After)|gate:$($script:calls.Count)"
"ownpl:[$(@(Add-KitReactorTestFlags 'mvn test -pl app' 6>&1) -join ' / ')]"
"all:[$(@(Add-KitReactorTestFlags 'mvn test' 6>&1) -join ' / ')]"
$Show = $true; "show:[$(Add-KitReactorTestFlags 'mvn test' 6>$null)]"; $Show = $false; "gradle:[$(Add-KitReactorTestFlags './gradlew test' 6>$null)]"
New-Item -ItemType Directory -Force "$repo/org/example/core/1.0" | Out-Null; 'j' | Set-Content "$repo/org/example/core/1.0/core-1.0.jar"
"fresh:[$(Add-KitReactorTestFlags 'mvn test' 6>$null)]"
'@ @((Join-Path $k 'skills/crafty/adapters/container-tests.ps1'), (Kd))
$rxAgg = '<modules><module>../app</module><module>../core</module><module>../mid</module></modules>'
Expect "check -Step test (maven): a missing reactor dep (core) and the module between (mid), not an unrelated one, join the test run's reactor (-f <aggregator> -pl :app -am); the local repository and the gate untouched; no filter: their suites run, said; an own -pl: warned, unchanged; -Show, Gradle or fresh jars: unchanged ($rx)" (
  "$rx" -match 'first:mvn -f "\S*crafty-reactor-app\.xml" -pl :app -am -Dsurefire\.failIfNoSpecifiedTests=false -Dit\.failIfNoSpecifiedTests=false -q test -Dtest=AppTest\|' -and "$rx".Contains($rxAgg) -and "$rx" -notmatch 'other' -and
  "$rx" -match 'm2:True\|gate:0' -and "$rx" -match 'ownpl:\[\[check\] [^\]]*artefact: core; [^\]]*own -pl / -f, so the tests see the stale local-repo jars[^\]]* / mvn test -pl app\]' -and
  "$rx" -match 'all:\[\[check\] [^\]]*no test filter: their own suites run too / mvn -f ' -and "$rx" -match 'show:\[mvn test\]' -and "$rx" -match 'gradle:\[\./gradlew test\]' -and "$rx" -match 'fresh:\[mvn test\]')
$cfx = Get-Content (Join-Path $PSScriptRoot '../skills/crafty/crafty.ps1') -Raw
Expect 'check: crafty.ps1 adds the reactor flags to every Maven step but lint (compile too: a stale in-repo dep jar broke devy builds)' ($cfx -match "if \(\`$s -ne 'lint' -and \(Get-Command Add-KitReactorTestFlags[^
]*\{ \`$cmd = Add-KitReactorTestFlags \`$cmd \}" -and $cfx -notmatch 'exit \$rc \}; \$cmd = Add-KitReactorTestFlags')
Remove-TestKit $k
Complete-Tests
