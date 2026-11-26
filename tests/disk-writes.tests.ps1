#Requires -Version 7
<#
tests/disk-writes.tests.ps1: the kit's SSD-write cuts on one test kit: the Maven main-compile skip of crafty.ps1 check
(adapters/check-stamps.ps1 Get-KitMainSkip / Save-KitMainKey, adapters/container-tests.ps1 Add-KitReactorTestFlags).
Usage: pwsh -NoProfile -File tests/disk-writes.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/check-stamps.ps1', 'skills/crafty/adapters/container-tests.ps1')   # copied into the test kit
$k = New-TestKit diskwrites
# main skip: a Maven step compiles main once per set of non-test inputs (2026-11-26: every step rewrote 8940 classes + 4289 files)
$mr = Join-Path (Kd) 'mvn-repo'; New-Item -ItemType Directory -Force "$mr/src/main/java", "$mr/src/test/java", "$mr/target/classes" | Out-Null
'<project><artifactId>invented-app</artifactId></project>' | Set-Content "$mr/pom.xml"; 'class A {}' | Set-Content "$mr/src/main/java/A.java"; 'class ATest {}' | Set-Content "$mr/src/test/java/ATest.java"
'target/' | Set-Content "$mr/.gitignore"; Save-GitRepo $mr 'first'
$ms = Invoke-PsTest 'main-skip' @'
param($lib, $repo)
. $lib *>$null
$cmd = 'mvn -o -q test -Dtest=ATest'; $log = Join-Path $repo 'target/run.log'; $out = [Collections.Generic.List[string]]::new()
$out.Add("first:[$(Get-KitMainSkip $repo $cmd)]"); Save-KitMainKey 0
$out.Add("same:[$(Get-KitMainSkip $repo $cmd)]"); Save-KitMainKey 0
'class ATest { int x; }' | Set-Content "$repo/src/test/java/ATest.java"; $out.Add("test-edit:[$(Get-KitMainSkip $repo $cmd)]")
$out.Add("force:[$(Get-KitMainSkip $repo $cmd -Force)]"); $out.Add("own-pl:[$(Get-KitMainSkip $repo "$cmd -pl x")]"); $out.Add("clean:[$(Get-KitMainSkip $repo 'mvn clean test')]"); $out.Add("no-maven:[$(Get-KitMainSkip $repo 'gradle test')]")
'class A { int y; }' | Set-Content "$repo/src/main/java/A.java"; $out.Add("main-edit:[$(Get-KitMainSkip $repo $cmd)]")
'BUILD FAILURE: cannot find symbol' | Set-Content $log; Save-KitMainKey 1 $log; $out.Add("failed-compile:[$(Get-KitMainSkip $repo $cmd)]")
'Tests run: 3, Failures: 1' | Set-Content $log; Save-KitMainKey 1 $log; $out.Add("failed-tests:[$(Get-KitMainSkip $repo $cmd)]")
'class B {}' | Set-Content "$repo/src/main/java/B.java"; $out.Add("new-main-file:[$(Get-KitMainSkip $repo $cmd)]")
$null = Get-KitMainSkip $repo $cmd; 'class B { int z; }' | Set-Content "$repo/src/main/java/B.java"; Save-KitMainKey 0; $out.Add("edit-during-run:[$(Get-KitMainSkip $repo $cmd)]"); Save-KitMainKey 0
Remove-Item "$repo/target/classes" -Recurse; $out.Add("no-classes:[$(Get-KitMainSkip $repo $cmd)]"); $null = New-Item -ItemType Directory "$repo/target/classes"
$st = @{ dir = $repo }; $Show = $false; $Force = $false; $out.Add("step:[$(Add-KitReactorTestFlags '.\mvnw.cmd -o -q test -Dtest=ATest' 6>$null)]")
$out -join ' '
'@ @((Lib), $mr)
$want = 'first:[] same:[-Dmaven.main.skip=true] test-edit:[-Dmaven.main.skip=true] force:[] own-pl:[] clean:[] no-maven:[] main-edit:[] failed-compile:[] ' +
  'failed-tests:[-Dmaven.main.skip=true] new-main-file:[] edit-during-run:[] no-classes:[] step:[.\mvnw.cmd -Dmaven.main.skip=true -o -q test -Dtest=ATest]'
Expect "check main skip: on when only tests changed since a compiled run; off on a main edit, a new main file, a failed compile, an edit during the run, no classes, -Force, an own -pl, clean ($ms)" ("$ms" -eq $want)
Remove-TestKit $k
Complete-Tests
