#Requires -Version 7
<#
local-env-5.tests.ps1: envy.ps1 thin artifacts (services[].classpathFile): per-release classpath.txt + java.args, {javaArgs}.
Usage: pwsh -NoProfile -File <kit>/tests/local-env-5.tests.ps1 (tests/kit-tests.ps1 -Area local-env-5 runs it with the other areas).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # a kit to test; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit le5; $ed = New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy/adapters'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $ed)
Copy-Item @((Join-Path $src 'skills/envy/adapters/shared_builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane_standard.ps1')) $ed
$L5 = Join-Path $k 'skills/envy/envy.ps1'
$api = @{ name = 'api'; repo = 'r'; dir = 'api'; port = 41051; artifact = 'target/app-*.jar'; classpathFile = 'target/classpath.txt'; start = 'java @"{javaArgs}" a.Main' }
& $J @{ localEnv = @{ envs = @{ t = @{ services = @($api) } } } } (Join-Path $k 'skills/crafty/kit.local.json') 8
# owner 2026-11-19: each release gets classpath.txt + java.args (-cp artifact;libraries); the repo's own module jars copied into
# <release>/lib, Maven local repository jars referenced; {javaArgs} = that release's argfile; a later build never changes it
$ud = Kd; $wtd = Join-Path $ud 'wt'
$tj = & { . $L5; function RepoOf { 'r' }; function EnvRepos { @{ r = [pscustomobject]@{ wt = $wtd } } }; function EnvServices { [pscustomobject]$api }; $sep = [IO.Path]::PathSeparator
  $tgt = Join-Path $wtd 'api/target'; $cpf = Join-Path $tgt 'classpath.txt'
  $repoJar = Join-Path $ud 'm2/org/x/1.0/x-1.0.jar'; $modJar = Join-Path $wtd 'lib/m1/target/m1-1.jar'
  New-Item -ItemType Directory -Force (Split-Path $repoJar), (Split-Path $modJar), $tgt | Out-Null; 'r' | Set-Content $repoJar; 'm' | Set-Content $modJar
  'thin' | Set-Content (Join-Path $tgt 'app-5.jar'); Set-Content $cpf "$repoJar$sep$modJar" -NoNewline
  $r1 = (Stage-Artifacts t r 'cp1').api; $a1 = Get-Content (JavaArgsFile $r1) -Raw
  'thin2' | Set-Content (Join-Path $tgt 'app-6.jar'); Set-Content $cpf $repoJar -NoNewline; $null = Stage-Artifacts t r 'cp2'
  $want = '-cp "' + ((@($r1, $repoJar, (Join-Path (Split-Path $r1) 'lib/m1-1.jar')) | ForEach-Object { $_.Replace('\', '/') }) -join $sep) + '"'
  $sc = StartCmd t ([pscustomobject]$api) $r1; $used = -not (Test-Path $cpf); 'thin3' | Set-Content (Join-Path $tgt 'app-7.jar')
  $miss = try { $null = Stage-Artifacts t r 'cp3'; 'staged' } catch { "$_" -match 'no classpath file' }
  $old = try { $null = StartCmd t ([pscustomobject]$api) (Join-Path $tgt 'app-7.jar'); 'started' } catch { "$_" -match 'deploy again' }
  $chk = $null -eq (Find-CheckBuild t ([pscustomobject]@{ name = 'api'; build = 'mvn package'; artifact = 'target/app-*.jar'; classpathFile = 'target/classpath.txt' }))
  "$($a1 -eq $want)|$((Get-Content (JavaArgsFile $r1) -Raw) -eq $a1)|$(Test-Path (Join-Path (Split-Path $r1) 'lib/m1-1.jar'))|$($sc -eq ('java @"' + (JavaArgsFile $r1) + '" a.Main'))|$miss|$old|$chk|$used" }
Expect "stage: classpathFile -> java.args per release (artifact + local-repository jars + the repo's module jars copied to lib), {javaArgs} = it, a later build leaves it, no classpath file / no java.args fail clearly, no check-build reuse, the classpath file consumed ($tj)" ($tj -eq 'True|True|True|True|True|True|True|True')
Remove-TestKit $k
Complete-Tests
