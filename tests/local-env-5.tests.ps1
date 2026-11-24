#Requires -Version 7
<#
local-env-5.tests.ps1: envy.ps1 thin artifacts (services[].classpathFile): per-release classpath.txt + java.args, {javaArgs};
a QA tester's lease needs its run.json item's localParts / localEnv; an open PAUSE on an agent's run keeps its layers; lanes -Sync; down without -Env / -All; deploy -Dir a,b.
Usage: pwsh -NoProfile -File <kit>/tests/local-env-5.tests.ps1 (tests/kit-tests.ps1 -Area local-env-5 runs it with the other areas).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # a kit to test; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit le5; $ed = New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy/adapters'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $ed)
Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) $ed
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
# 2026-11-20: a staging item's tester (no localParts / localEnv in run.json) leased two lanes for a suite's tenant restores (4.7 GB)
& $J @{ localEnv = @{ envs = @{ q = @{ services = @(@{ name = 'ui'; port = 41059 }) } } } } (Join-Path $k 'skills/crafty/kit.local.json') 8
$tqDir = New-Item -ItemType Directory -Force (Join-Path $k "$($tmpMap.runtimeDir)/work/qa-runs/2026-11-20-123456-stg")
@{ target = 'stg'; items = @(@{ code = 'T3'; target = 'stg' }, @{ code = 'T4'; target = 'stg'; localParts = @('!12') }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $tqDir 'run.json')
# the same tag a day earlier (its T3 local) never decides for today's run
$tqOld = New-Item -ItemType Directory -Force (Join-Path (Split-Path $tqDir) '2026-11-19-123456-stg'); @{ items = @(@{ code = 'T3'; localEnv = 'q' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $tqOld 'run.json')
$tqNo = Invoke-TestScript $L5 use -Env q -Services ui -Agent 'test:T3@123456' -Wait 0
$tqOk = Invoke-TestScript $L5 use -Env q -Services ui -Agent 'test:T4@123456' -Wait 0
Expect "envy use: a tester whose run.json item has no localParts / localEnv is refused, exit 1; one with localParts passes the check ($($tqNo.out.Trim()) | $($tqOk.out -split "`n" | Select-Object -First 1))" ($tqNo.code -eq 1 -and $tqNo.out -match 'item T3 tests target stg' -and $tqOk.out -match 'lease for test:T4')
# an owner PAUSE: the agent releases before board leave -Status paused; an open pause on its run keeps its layers (retro 2026-11-21)
& $J @{ agent = 'PQ'; session = 'PQ-s'; run = 'rq'; status = 'working'; beat = (Get-Date).ToString('o') } (Join-Path (TkPath $k board -Create) 'PQ-s.json')
$pqNo = Px $L5 drop -Env q -Agent PQ 2>&1 | Out-String; & $J @{ run = 'rq'; state = 'paused'; reason = 'owner'; at = (Get-Date).ToString('o') } (Join-Path (TkPath $k pauses -Create) 'pause-pq.json')
$pqYes = Px $L5 drop -Env q -Agent PQ 2>&1 | Out-String
& $J @{ agent = 'PQ'; session = 'PQ-s'; run = 'rq'; status = 'left'; beat = (Get-Date).ToString('o') } (Join-Path (TkPath $k board) 'PQ-s.json'); $pqLeft = Px $L5 drop -Env q -Agent PQ 2>&1 | Out-String
Expect "release under an open PAUSE of the agent's run: layers kept, before board leave -Status paused; a finished (left) agent's go ($($pqNo.Trim()) / $($pqYes.Trim()) / $($pqLeft.Trim()))" ($pqNo -match 'PQ has no layer' -and $pqYes -match 'layers of PQ kept: it paused' -and $pqLeft -match 'PQ has no layer')
# retro 2026-11-23: release without -Env (2 envs) frees the one env the agent leases
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @() }; mig = @{ services = @() } } } } (Join-Path $k 'skills/crafty/kit.local.json') 6
& { . $L5; Update-State shop { param($x) $x.leases.rl1 = @{ until = (Get-Date).AddHours(1).ToString('o'); holderPid = $PID } } }
$rlo = Px $L5 release -Agent rl1 2>&1 | Out-String; $rlc = $LASTEXITCODE; $rln = Px $L5 release -Agent rl2 2>&1 | Out-String
Expect "localenv: release with no -Env picks the leased env; no lease anywhere still needs -Env ($rlc)" ($rlc -eq 0 -and $rlo -match '\[shop\] lease of rl1 released' -and $rln -match '-Env needed')
$lfKit = New-TestKit le5lanes; $lfE = New-Item -ItemType Directory -Force (Join-Path $lfKit 'skills/envy/adapters'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $lfE)
Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) $lfE; $lfL = Join-Path $lfKit 'skills/envy/envy.ps1'
& $J @{ localEnv = @{ lanes = @{ openAfterMinutes = 15 }; envs = @{ shop = @{ lanes = @{ max = 3 }; services = @(@{ name = 'api'; port = 41071; start = 'echo' }) } } } } (Join-Path $lfKit 'skills/crafty/kit.local.json') 8
# v2-wave1 JCF: a deploy onto a lane another agent leases (picked or named) waits for that lease; a free lane of the group instead
$lf = & { . $lfL
  function Get-GateAvailGB { 50 }; function KeepFreeGB { 10 }; function Need-GB { 1 }
  foreach ($n in 'shop', 'shop2', 'shop3') { Update-State $n { param($x) $x.leases = @{}; $x.holds = @{}; $x.requests = @(); $x.train = $null; if ($x.release) { $x.release.repos = @{} } } }
  Update-State shop2 { param($x) $x.services = @{ api = @{ status = 'up' } }; $x.leases.WA = @{ services = @('api'); agent = 'WA' } }
  $picked = Select-Lane shop J1 0 'deploy'; $named = Select-Lane shop2 J2 0 'deploy' '' 'shop2'; $nw = (Read-State shop).lanePick.why -match 'shop2 leased by WA: a free lane'; $logs = Select-Lane shop2 J3 0 'logs' '' 'shop2'
  Update-State shop { param($x) $x.release.repos.r = @{ layers = @(@{ branch = 'b'; agent = 'J5' }) } }; $stick = "$(Select-Lane shop2 J5 0 'deploy' '' 'shop2')/$(Select-Lane shop2 J5 0 'use' '' 'shop2')"
  function Get-GateAvailGB { 10.5 }; $none = Select-Lane shop2 J4 0 'deploy' '' 'shop2'
  Update-State shop3 { param($x) $x.services = @{ api = @{ status = 'up' } } }; $warmF = Select-Lane shop2 J6 0 'deploy' '' 'shop2'
  "$picked|$named|$logs|$stick|$warmF|$none|$nw" } 6>$null
Expect "lanes: a deploy onto a lane another agent leases (picked or named) goes to a free lane (its own first, then warm); other verbs keep the named lane; none free (no room): the leased lane, its wait bounded by leaseMinutes ($lf)" ($lf -eq 'shop|shop|shop2|shop/shop2|shop3|shop2|True')
Remove-TestKit $lfKit
Remove-TestKit $k
# moved from local-env-4.tests.ps1 (its token cap)
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) (New-Item -ItemType Directory -Force (Join-Path $d 'adapters')); $kd }
# lanes -Sync (wt pool -Sync): an idle lane = origin/<target> + its open layers re-merged, a merged layer dropped (state), no upstream;
# a layer that conflicts with the new target: the lane stays as it was; lanes.json: behind 0, merges
$syKit = New-LocalEnvKit lesync; $syL = Join-Path $syKit 'skills/envy/envy.ps1'; $k = $syKit; $sq2 = Assert-TestPath (Kd); $so2 = Join-Path $sq2 'so.git'; $sc = Join-Path $sq2 'sc'; $sw2 = Join-Path $sq2 'sw'
git init -q --bare -b main $so2; git clone -q $so2 $sc 2>$null; 'a' | Set-Content "$sc/a.txt"; Save-GitRepo $sc init; git -C $sc push -q origin main 2>$null; New-Item -ItemType Directory -Force $sw2 | Out-Null
$lyr = { param($b, $f, $v) git -C $sc checkout -q -b $b main; $v | Set-Content "$sc/$f"; Save-GitRepo $sc $b; git -C $sc checkout -q main; "$(git -C $sc rev-parse $b)".Trim() }
$shO = & $lyr 'feat-open' 'o.txt' 'o'; $shM = & $lyr 'feat-merged' 'm.txt' 'm'; $shC = & $lyr 'feat-conf' 'a.txt' 'mine'
$lw = Join-Path $sw2 'lane-shop-falcon-sc'; git -C $sc worktree add -q -b lane/shop-falcon $lw main 2>$null; git -C $lw branch -q --set-upstream-to=origin/main 2>$null
git -C $sc merge -q --no-ff -m 'merge m' feat-merged 2>$null; 'a2' | Set-Content "$sc/n.txt"; Save-GitRepo $sc next; git -C $sc push -q origin main 2>$null
Set-JsonFile (Join-Path $syKit 'skills/crafty/kit.local.json') @{ worktreeRoots = @($sw2); repos = @(@{ name = 'sc'; checkout = $sc; target = 'main' }); localEnv = @{ envs = @{ shop = @{ services = @(@{ name = 'api'; repo = 'sc'; port = 18711 }) } } } }
$syo = & { . $syL help 6>$null *> $null; $null = Assert-TestPath $sc; $null = Assert-TestPath $lw; $sf = Join-Path (Get-KitPath localenv -Create) 'shop.json'
  Set-JsonFile $sf @{ release = @{ n = 1; repos = @{ sc = @{ layers = @(@{ branch = 'feat-open'; sha = $shO; agent = 'a1' }, @{ branch = 'feat-merged'; sha = $shM; agent = 'a2' }) } } } }
  $o1 = @(Invoke-LocalEnv lanes -Sync 6>$null); $st1 = Get-Content $sf -Raw | ConvertFrom-Json; $h1 = "$(git -C $lw rev-parse HEAD)".Trim()
  $anc = { param($x) git -C $lw merge-base --is-ancestor $x HEAD; -not $LASTEXITCODE }
  $ok = (& $anc origin/main) -and (& $anc $shO) -and -not "$(git -C $lw config branch.lane/shop-falcon.merge)"
  $lj = Get-Content (Get-KitLaneSyncFile) -Raw | ConvertFrom-Json; $ljOut = -not (Test-Path (Join-Path (Get-KitPath wt-slots) 'lanes.json'))
  'c2' | Set-Content "$sc/a.txt"; Save-GitRepo $sc conf; git -C $sc push -q origin main 2>$null
  Set-JsonFile $sf @{ release = @{ n = 1; repos = @{ sc = @{ layers = @(@{ branch = 'feat-conf'; sha = $shC; agent = 'a3' }) } } } }
  $o2 = @(Invoke-LocalEnv lanes -Sync 6>$null); $h2 = "$(git -C $lw rev-parse HEAD)".Trim()
  # K41: a squash-merged layer (its MR merged on the host, its commit not in main) that conflicts with main: dropped, never re-merged
  $shS = & $lyr 'feat-sq' 'a.txt' 'sq'; 'sq' | Set-Content "$sc/a.txt"; Save-GitRepo $sc 'squash feat-sq'; 'sq2' | Set-Content "$sc/a.txt"; Save-GitRepo $sc after; git -C $sc push -q origin main 2>$null
  function Get-MergedMrs([string]$Dir, [string]$Branch, [string]$Target) { if ($Branch -eq 'feat-sq') { @([pscustomobject]@{ iid = 8995; sha = $shS }) } }
  Set-JsonFile $sf @{ release = @{ n = 1; repos = @{ sc = @{ layers = @(@{ branch = 'feat-sq'; sha = $shS; agent = 'a4' }) } } } }
  $o3 = @(Invoke-LocalEnv lanes -Sync -DryRun 6>$null); $o4 = @(Invoke-LocalEnv lanes -Sync 6>$null); $st4 = Get-Content $sf -Raw | ConvertFrom-Json
  # a layer recorded before a rebase (its MR merged the rebased copy, a hook marker added): dropped; one with a commit the MR lacks: kept
  $shR = & $lyr 'feat-rb' 'r.txt' 'r'; git -C $sc checkout -q -b feat-rb2 main; 'r' | Set-Content "$sc/r.txt"; 'z' | Set-Content "$sc/z.txt"; Save-GitRepo $sc 'feat-rb +hook'; $shR2 = "$(git -C $sc rev-parse HEAD)".Trim(); git -C $sc checkout -q main
  git -C $sc checkout -q feat-rb; 'x' | Set-Content "$sc/x.txt"; Save-GitRepo $sc 'extra after the MR'; $shRx = "$(git -C $sc rev-parse HEAD)".Trim(); git -C $sc checkout -q main
  function Get-MergedMrs([string]$Dir, [string]$Branch, [string]$Target) { if ($Branch -eq 'feat-sq') { @([pscustomobject]@{ iid = 8995; sha = $shS }) } elseif ($Branch -in 'feat-rb', 'feat-rbx') { @([pscustomobject]@{ iid = 8988; sha = $shR2 }) } }
  $sqSt = Get-Content $sf -Raw; Set-JsonFile $sf @{ release = @{ n = 1; repos = @{ sc = @{ layers = @(@{ branch = 'feat-rb'; sha = $shR; agent = 'a5' }, @{ branch = 'feat-rbx'; sha = $shRx; agent = 'a6' }) } } } }
  $o5 = @(Invoke-LocalEnv lanes -Sync -DryRun 6>$null); [IO.File]::WriteAllText($sf, $sqSt)
  $rbOk = @($o5 -match '^plan \[shop\] sc: origin/main \+ 1 layer\(s\); drop feat-rb \(merged into main \(MR 8988\)\)$').Count -eq 1
  $sqOk = $rbOk -and @($o3 -match '^plan \[shop\] sc: origin/main \+ 0 layer\(s\); drop feat-sq \(merged into main \(MR 8995\)\)').Count -eq 1 -and @($o4 -match '^synced \[shop\] sc: .*dropped feat-sq \(merged into main \(MR 8995\)\)').Count -eq 1 -and -not @($st4.release.repos.sc.layers).Count -and "$(git -C $lw rev-parse HEAD)".Trim() -eq "$(git -C $sc rev-parse main)".Trim()
  $rx1 = '^synced \[shop\] sc: .*1 layer\(s\) re-merged; dropped feat-merged \(merged into main'; $rx2 = '^kept \[shop\] sc: layer feat-conf conflicts'
  "$($ok -and $ljOut -and $sqOk)|$(@($st1.release.repos.sc.layers.branch) -join ',')|$(@($lj)[0].behind)/$(@($lj)[0].merges)|$(@($o1 -match $rx1).Count)|$(@($o2 -match $rx2).Count)|$($h2 -eq $h1)" }
Expect "lanes -Sync: idle lane rebuilt on origin/main + its open layer, the merged one dropped, no upstream, behind 0; a conflicting layer leaves the lane as it was ($syo)" ($syo -eq 'True|feat-open|0/1|1|1|True')
Remove-TestKit $syKit
# K2X: the sync scratch (a.txt, m-z.txt) stays under the test home, never at a drive root
$leNew = @(foreach ($dr in $script:rootsAt.Keys) { Get-ChildItem -LiteralPath $dr -Force -Name -ErrorAction SilentlyContinue | Where-Object { $_ -notin $script:rootsAt[$dr] -and $_ -in 'a.txt', 'm.txt', 'n.txt', 'o.txt', 'r.txt', 'x.txt', 'z.txt' } })
Expect "lanes -Sync scratch under the test home: no new drive-root entry ($($leNew -join ', '))" (-not $leNew.Count -and $sc.StartsWith([IO.Path]::GetTempPath().TrimEnd('\', '/')))
$kd2 = New-TestKit le5d; $ed2 = New-Item -ItemType Directory -Force (Join-Path $kd2 'skills/envy/adapters'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $ed2)
Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) $ed2; $L2 = Join-Path $kd2 'skills/envy/envy.ps1'; $k2 = $kd2
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @() }; mig = @{ services = @() } } } } (Join-Path $kd2 'skills/crafty/kit.local.json') 6
# down with no -Env: usage + env list, exit 2; -All stops every env; deploy -Dir takes a list (a 2-dir call failed binding [string])
$dn = Px $L2 down 2>&1 | Out-String; $dnc = $LASTEXITCODE; $da = Px $L2 down -All 2>&1 | Out-String; $dac = $LASTEXITCODE
$dd1 = New-Item -ItemType Directory -Force (Join-Path $k2 'wt-a'); $dd2 = New-Item -ItemType Directory -Force (Join-Path $k2 'wt-b')
$dx = (Px $L2 deploy -Env shop -Dir "$dd1,$dd2" 2>&1 | Out-String) -replace '\s*\|?\s+', ' '
Expect "localenv: down without -Env prints usage + envs, exit 2 ($dnc); down -All runs on each env, exit 0 ($dac); deploy -Dir a,b binds and checks each dir" ($dnc -eq 2 -and $dn -match 'usage: envy\.ps1 down -Env' -and $dn -match 'shop' -and $dn -match 'mig' -and $dn -notmatch 'At .*char:' -and $dac -eq 0 -and $da -notmatch 'usage:|-Env needed' -and $dx -notmatch 'argument transformation' -and $dx -match 'wt-a is not a git worktree')
Complete-Tests
