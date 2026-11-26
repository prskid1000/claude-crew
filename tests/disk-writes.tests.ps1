#Requires -Version 7
<#
tests/disk-writes.tests.ps1: the kit's SSD-write cuts on one test kit: the Maven main-compile skip of crafty.ps1 check
(adapters/check-stamps.ps1 Get-KitMainSkip / Save-KitMainKey / Get-KitMainSlot, adapters/container-tests.ps1 Add-KitReactorTestFlags).
Usage: pwsh -NoProfile -File tests/disk-writes.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/check-stamps.ps1', 'skills/crafty/adapters/container-tests.ps1')   # copied into the test kit
$k = New-TestKit diskwrites
# main skip: a Maven step compiles main once per set of non-test inputs (2026-11-26: every step rewrote 8940 classes + 4289 files)
$mr = Join-Path (Kd) 'mvn-repo'; New-Item -ItemType Directory -Force "$mr/src/main/java/e2e", "$mr/src/test/java", "$mr/target/classes" | Out-Null
'<project><artifactId>invented-app</artifactId></project>' | Set-Content "$mr/pom.xml"; 'class A {}' | Set-Content "$mr/src/main/java/A.java"; 'class ATest {}' | Set-Content "$mr/src/test/java/ATest.java"
'target/' | Set-Content "$mr/.gitignore"; Save-GitRepo $mr 'first'
$ms = Invoke-PsTest 'main-skip' @'
param($lib, $repo)
. $lib *>$null
$cmd0 = 'mvn -o -q test -Dtest=ATest'; $log = Join-Path $repo 'target/run.log'; $out = [Collections.Generic.List[string]]::new()
$get = { param($c = $cmd0, [switch]$F) "$(Get-KitMainSkip $repo $c -Force:$F)" -replace '-Dmaven.main.skip=true', 'skip' }; $rec = { $null = & $get; Save-KitMainKey 0 }
$out.Add("first:[$(& $get)]"); Save-KitMainKey 0
$out.Add("same:[$(& $get)]"); Save-KitMainKey 0
'class ATest { int x; }' | Set-Content "$repo/src/test/java/ATest.java"; $out.Add("test-edit:[$(& $get)]")
$out.Add("force:[$(& $get -F)]"); Save-KitMainKey 0
$out.Add("own-pl:[$(& $get "$cmd0 -pl x")]"); $out.Add("after-pl:[$(& $get)]"); Save-KitMainKey 0; $out.Add("clean:[$(& $get 'mvn clean test')]"); $out.Add("no-maven:[$(& $get 'gradle test')]"); & $rec
# a step that compiles nothing records nothing; a failed compile, then the edit reverted: the old key is gone (the classes are the edit's)
'class A { int y; }' | Set-Content "$repo/src/main/java/A.java"; $null = & $get 'mvn -q validate'; Save-KitMainKey 0; $out.Add("validate-then-test:[$(& $get)]")
'BUILD FAILURE: cannot find symbol' | Set-Content $log; Save-KitMainKey 1 $log; 'class A {}' | Set-Content "$repo/src/main/java/A.java"; $out.Add("revert-after-failed:[$(& $get)]")
'Tests run: 3, Failures: 1' | Set-Content $log; Save-KitMainKey 1 $log; $out.Add("failed-tests:[$(& $get)]")
'class B {}' | Set-Content "$repo/src/main/java/B.java"; $out.Add("new-main-file:[$(& $get)]"); Save-KitMainKey 0
'class E {}' | Set-Content "$repo/src/main/java/e2e/E.java"; $out.Add("main-package-e2e:[$(& $get)]"); Save-KitMainKey 0
$out.Add("profile:[$(& $get 'mvn -Pfast -o -q test')]"); Save-KitMainKey 0; $out.Add("other-profile:[$(& $get)]"); Save-KitMainKey 0
$null = & $get -F; 'class B { int z; }' | Set-Content "$repo/src/main/java/B.java"; Save-KitMainKey 0; $out.Add("edit-during-run:[$(& $get)]"); Save-KitMainKey 0
$sk = & $get; 'class B { int w; }' | Set-Content "$repo/src/main/java/B.java"; $said = "$(Save-KitMainKey 0 6>&1)"; $out.Add("edit-while-skipped:[$sk>$(& $get)]$($said -match 'old classes; rerun')"); Save-KitMainKey 0
# the compile mark: the compiler plugin's lists, rewritten by any compile (a hand-run one too)
$md = New-Item -ItemType Directory -Force "$repo/target/maven-status/maven-compiler-plugin/compile/default-compile"; 'a' | Set-Content "$md/inputFiles.lst"; 'a' | Set-Content "$md/createdFiles.lst"
$null = & $get -F; Save-KitMainKey 0; $out.Add("mark-same:[$(& $get)]"); (Get-Item "$md/createdFiles.lst").LastWriteTime = (Get-Date).AddHours(1); $out.Add("hand-compile:[$(& $get)]"); Save-KitMainKey 0
Remove-Item "$repo/target/classes" -Recurse; $out.Add("no-classes:[$(& $get)]"); $null = New-Item -ItemType Directory "$repo/target/classes"; & $rec
$st = @{ dir = $repo }; $Show = $false; $Force = $false; $out.Add("step:[$(Add-KitReactorTestFlags '.\mvnw.cmd -o -q test -Dtest=ATest' 6>$null)]")
function Hash12($x) { "h$("$x".Length)" }; $cmd = '.\mvnw.cmd -Dmaven.main.skip=true -o test'; $s1 = Get-KitMainSlot 'test|zz'; $cmd = 'mvn test'; $out.Add("slot:[$s1,$(Get-KitMainSlot 'test|zz')]")
$out -join ' '
'@ @((Lib), $mr)
$want = 'first:[] same:[skip] test-edit:[skip] force:[] own-pl:[] after-pl:[] clean:[] no-maven:[] validate-then-test:[] revert-after-failed:[] failed-tests:[skip] new-main-file:[] ' +
  'main-package-e2e:[] profile:[] other-profile:[] edit-during-run:[] edit-while-skipped:[skip>]True mark-same:[skip] hand-compile:[] no-classes:[] ' +
  'step:[.\mvnw.cmd -Dmaven.main.skip=true -o -q test -Dtest=ATest] slot:[test|h18,test|zz]'
Expect "check main skip: on when only tests changed since a recorded compile; off (key dropped) on a main edit, a new file, a main package named e2e, another profile, a failed compile then a revert, an edit during the run, a hand-run compile, no classes, -Force, an own -pl, clean; a skipped step keeps its stamp slot ($ms)" ("$ms" -eq $want)
Remove-TestKit $k
Complete-Tests
