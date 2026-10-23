#Requires -Version 7
# Tests of the goody build-heap: Gradle gets -Dorg.gradle.jvmargs, Maven MAVEN_OPTS, Node NODE_OPTIONS. Run: kitbag.py goody test build-heap
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit heap; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $bd = Join-Path (Kd) 'b'; New-Item -ItemType Directory -Force $bd | Out-Null
$env:CLAUDE_GATE_KEEP_FREE_GB = '0'; $env:MAVEN_OPTS = '-Xmx1g -Dkeep=1'
$cmds = @('echo gradlew build', 'echo mvn -q test & echo %MAVEN_OPTS%', 'echo jest x & echo %NODE_OPTIONS%')
$out = @(foreach ($c in $cmds) { pwsh @np $D gate -Dir $bd -Cmd $c 2>&1 | Out-String })
Remove-Item Env:MAVEN_OPTS, Env:CLAUDE_GATE_KEEP_FREE_GB
Expect 'build-heap: gradle gets -Dorg.gradle.jvmargs' ($out[0] -match 'gradlew "?-Dorg\.gradle\.jvmargs=-Xmx\d+g')
if ($IsWindows) {
  Expect 'build-heap: maven gets -Xmx in MAVEN_OPTS, its own -D kept, the old -Xmx gone' ($out[1] -match '-Dkeep=1 -Xmx\d+g' -and $out[1] -notmatch '-Xmx1g')
  Expect 'build-heap: node gets --max-old-space-size' ($out[2] -match '--max-old-space-size=\d+')
}
Remove-TestKit $k
Complete-Tests
