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
# retro 2026-11-19 (84 failed crafty.ps1 stack calls): a lane worktree not made yet or a relative repo-less dir is never handed to stack
$so = & { . $L5; $script:calls = 0; $KitCmd.dev = 'stack-fake'; function stack-fake { $script:calls++; '{"stack":"node"}' }
  function RepoOf { 'r' }; function EnvRepos { @{ r = [pscustomobject]@{ wt = $wtd } } }
  $gone = Join-Path $wtd 'no-such-lane'; $a = StackOf $gone; $b = StackOf 'app/web-ui'
  $msg = try { $null = StartCmd t ([pscustomobject]@{ name = 'web'; repo = 'r'; dir = 'no-such-lane' }) $null; 'started' } catch { "$_" -match 'no start command' }
  "$($null -eq $a)|$($null -eq $b)|$($script:calls)|$msg" }
Expect "stack: a missing or relative dir -> no stack call, StartCmd still says no start command ($so)" ($so -eq 'True|True|0|True')
# ENV-FIX 2026-11-19: wt new refused a second-target lane worktree (a dep source missing); Sync-Repo then crashed "not its own git
# worktree (toplevel: )". Now: the wt new error is thrown, a plain folder is moved aside, a list of dep sources stays a list, doctor -Fix
$co = Join-Path $ud 'co'; git init -q -b main $co; 'x' | Set-Content "$co/x.txt"; Save-GitRepo $co init; $s1 = New-Item -ItemType Directory -Force (Join-Path $ud 's1'); $s2 = Join-Path $ud 's2'
$lw = & { . $L5 6>$null; $global:wtFail = $true; $wt = Join-Path $ud 'lane-t-main-co'
  $KitCmd.dev = 'wt-fake'; function Get-LaneBusy { '' }
  function wt-fake { if ("$global:wtFail" -eq 'quiet') { return }; if ($global:wtFail) { 'Wt FAILED: dep source s2 is missing'; return }; git -C $co worktree add -q --detach $wt main 2>$null }
  $r = [pscustomobject]@{ name = 'co@main'; cfg = [pscustomobject]@{ checkout = $co; linkFromByTarget = [pscustomobject]@{ main = @("$s1", $s2) } }; target = 'main'; wt = $wt; branch = 'lane/t-main'; wtName = 'lane-t-main' }
  New-Item -ItemType Directory -Force $wt | Out-Null; 'stray' | Set-Content "$wt/f.txt"
  $err = try { Ensure-Worktree t $r 6>$null 3>$null; 'made' } catch { "$_" -match 'not created: Wt FAILED: dep source s2' }
  $aside = @(Get-ChildItem $ud -Directory -Filter 'lane-t-main-co.stale-*').Count; $global:wtFail = $false; Ensure-Worktree t $r 6>$null 3>$null
  $srcs = @(Get-LaneDepSources $r); $w1 = @(Get-LaneWorktreeRows t -Repos @($r) | ForEach-Object level) -join ','
  git -C $co worktree remove --force $wt 2>$null; New-Item -ItemType Directory -Force $wt | Out-Null
  $f1 = @(Get-LaneWorktreeRows t -Repos @($r) -Fix | ForEach-Object level) -join ','; New-Item -ItemType Directory -Force $s2 | Out-Null
  $f2 = @(Get-LaneWorktreeRows t -Repos @($r) -Fix | ForEach-Object level) -join ','
  # a live .git (git finds another tree) is never moved; a wt new with no output still names its exit
  $global:wtFail = 'quiet'; $w3 = Join-Path $ud 'lane-t-live-co'; New-Item -ItemType Directory -Force "$w3/.git" | Out-Null; $r3 = [pscustomobject]@{ name = 'co'; cfg = [pscustomobject]@{ checkout = $co }; target = 'main'; wt = $w3 }
  $live = try { Ensure-Worktree t $r3 6>$null; 'made' } catch { "$_" -match 'live \.git' -and (Test-Path "$w3/.git") }; $f3 = @(Get-LaneWorktreeRows t -Repos @($r3) | ForEach-Object level) -join ','
  Remove-Item $w3 -Recurse -Force; $quiet = try { Ensure-Worktree t $r3 6>$null; 'made' } catch { "$_" -match 'wt new exit .*, no output' }
  "$err|$aside|$(Test-LaneWorktree $wt)|$($srcs.Count)|$w1|$f1|$f2|$(@(Get-LaneWorktreeRows t -Repos @($r)).Count)|$live|$f3|$quiet" }
Expect "lane worktree: wt new's error (or exit) thrown, a plain folder moved aside then made, a live .git never moved (FAIL), 2 dep sources, doctor WARN / -Fix ($lw)" ($lw -eq 'True|1|True|2|WARN|FAIL,WARN|OK|0|True|FAIL|True')
# ENV-FIX 2026-11-19: rm api r469 (fat jar, no java.args) counted as unchanged after classpathFile was switched on: rebuilt now
$ra = & { . $L5 6>$null; $rd = New-Item -ItemType Directory -Force (Join-Path $ud 'rel1'); $j = Join-Path $rd 'app.jar'; 'x' | Set-Content $j
  $b = Test-ReleaseArtifact ([pscustomobject]$api) $j; $c = Test-ReleaseArtifact ([pscustomobject]@{ name = 'w' }) $j; 'a' | Set-Content (JavaArgsFile $j)
  "$b|$c|$(Test-ReleaseArtifact ([pscustomobject]$api) $j)|$(Test-ReleaseArtifact ([pscustomobject]$api) '')" }
Expect "train: a classpathFile release with no java.args is not kept as unchanged ($ra)" ($ra -eq 'False|True|True|False')
$jv = & { . $L5 6>$null; function EnvServices { [pscustomobject]@{ name = 'x'; start = 'java @"{javaArgs}" {nope}' } }
  "$(@(Get-LaneStandardRows t | Where-Object what -match 'javaArgs').Count)|$(@(Get-LaneStandardRows t | Where-Object what -match 'nope').Count)" }
Expect "doctor: {javaArgs} is an envy placeholder, {nope} is not ($jv)" ($jv -eq '0|1')
# retro 2026-11-19: a train's DB step started a lane DB with no state row ("The property 'status' cannot be found")
$sr = & { . $L5 6>$null; New-Item -ItemType Directory -Force (Join-Path $wtd 'api') | Out-Null; function RepoOf { 'r' }; function EnvRepos { @{ r = [pscustomobject]@{ wt = $wtd } } }
  function Wait-Room { throw "row:$((Read-State t).services['api'].status)" }; function StartCmd { 'x' }
  try { Start-SvcOnce t ([pscustomobject]$api) 0 '' 6>$null; 'started' } catch { "$_" } }
Expect "start: a service with no state row gets one before its room wait ($sr)" ($sr -eq 'row:down')
# K97: -All (alias of AllServices) leases every managed service (the refusal without either: local-env.tests.ps1, a real run)
$uAst = [Management.Automation.Language.Parser]::ParseFile($L5, [ref]$null, [ref]$null)
$use = ($uAst.FindAll({ $args[0] -is [Management.Automation.Language.SwitchStatementAst] }, $true) | ForEach-Object Clauses | Where-Object { "$($_.Item1)" -eq "'use'" } | Select-Object -First 1).Item2.Extent.Text
$ua = & { . $L5 6>$null; $e = 'uz'; $Agent = 'B'; $Services = @(); $AllServices = $true; $LeaseMin = 30; $MaxLeaseMin = 60; $Wait = 0
  foreach ($f in 'Ensure-Loop', 'Show-Status', 'Event', 'Wake-Deferred', 'Prune', 'Svc') { Set-Item "function:$f" {} }; function Closure { @($args[1]) }; function MarksOn { $false }; function Wait-Up { $true }; function All-Managed { 'api', 'web' }
  $null = . ([scriptblock]::Create($use.Substring(1, $use.Length - 2))); "$(@((Read-State uz).leases.B.services) -join ',')" }
$uAlias = @($uAst.FindAll({ $args[0] -is [Management.Automation.Language.ParameterAst] -and $args[0].Name.VariablePath.UserPath -eq 'AllServices' }, $true) | ForEach-Object { "$($_.Attributes)" }) -join ''
Expect "envy use: -All leases every managed service; -All is AllServices' alias ($ua | $uAlias)" ($ua -eq 'api,web' -and $uAlias -match "Alias\('All'\)")
$kd = New-TestKit le5d; $dd = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy/adapters'); Copy-Item $L5 (Split-Path $dd); Copy-Item (Join-Path $src 'skills/envy/adapters/*') $dd
& $J @{ localEnv = @{ envs = @{ t = @{ db = @{ engine = 'mysql'; port = 41999 }; services = @(@{ name = 'db'; port = 41999; start = 'x' }) } } } } (Join-Path $kd 'skills/crafty/kit.local.json') 8
$dt = @(pwsh -NoProfile -File (Join-Path $kd 'skills/envy/envy.ps1') dbtemp -Env t 2>&1); $dtc = $LASTEXITCODE
Expect "dbtemp: a lane DB at rest is skipped with one line, exit 0, no refused error (exit $dtc; $($dt -join ' / '))" ($dtc -eq 0 -and "$dt" -match 'dbtemp: db rests' -and "$dt" -notmatch 'refused|error')
# K99 (retro 2026-11-20, 3x ERROR 2003): a db.port no managed service owns and nothing listens on: a start hint, never the raw client error
& $J @{ localEnv = @{ envs = @{ t = @{ db = @{ engine = 'mysql'; port = 41998 }; services = @(@{ name = 'api'; port = 41997; start = 'x' }) } } } } (Join-Path $kd 'skills/crafty/kit.local.json') 8
$dx = @(pwsh -NoProfile -File (Join-Path $kd 'skills/envy/envy.ps1') dbtemp -Env t 2>&1); $dxc = $LASTEXITCODE
Expect "dbtemp: an unowned DB port with no listener prints the start hint, exit 0, no client error (exit $dxc; $($dx -join ' / '))" ($dxc -eq 0 -and "$dx" -match 'nothing listens on the env DB port 41998' -and "$dx" -notmatch 'ERROR 2003|refused')
& $J @{ localEnv = @{ envs = @{ t = @{ db = @{ engine = 'mysql'; host = 'db.invalid'; port = 41998 }; services = @(@{ name = 'api'; port = 41997; start = 'x' }) } } } } (Join-Path $kd 'skills/crafty/kit.local.json') 8
$dh = @(pwsh -NoProfile -File (Join-Path $kd 'skills/envy/envy.ps1') dbtemp -Env t 2>&1) -join ' / '
Expect "dbtemp: a remote db.host is queried, no local-port hint ($dh)" ($dh -notmatch 'nothing listens')
Remove-TestKit $kd
Remove-TestKit $k
Complete-Tests
