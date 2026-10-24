#Requires -Version 7
# Tests of the runtimes container check: no answering engine -> exit 4; a configured runtimes.docker is leased (started when down). Run by tests.ps1
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit ct; $D = Join-Path $k 'skills/crafty/crafty.ps1'
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
