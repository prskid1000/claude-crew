#Requires -Version 7
<#
tests/deploy-restart.tests.ps1: a fake ssh on PATH answers busy / free; deploy kind verbs (plan, lastDeploy, isRunning, deploy); supervise deploy holds; offline.
Usage: pwsh -NoProfile -File tests/deploy-restart.tests.ps1 (its tests.ps1 runs this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs
$TestKitFiles = @('skills/bossy/adapters/deploy-merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed-checks.ps1')   # copied into every New-TestKit kit
$k = New-TestKit deploy-restart; $O = Join-Path $k 'skills/bossy/bossy.ps1'
foreach ($f in 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/adapters/deploy-merge.ps1', 'skills/pokey/adapters/deployed-checks.ps1') {
  $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) $f) $d
}
# fake ssh: logs each decoded host script; a script with a busy check: mode busy = always BUSY, once = BUSY on the first call, then the restarts
$bin = Join-Path (Kd) 'sshbin'; $null = New-Item -ItemType Directory -Force $bin; $sshLog = Join-Path (Kd) 'ssh.log'
Set-Content (Join-Path $bin 'fakessh.ps1') @'
$b64 = (("$($args[-1])" -split ' ')[1]); $sh = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
$n = @(Get-ChildItem (Split-Path $env:FAKE_SSH_LOG) -Filter 'ssh.log.*').Count; Set-Content "$env:FAKE_SSH_LOG.$n" $sh
if ($sh -match 'BUSY=1' -and ($env:FAKE_SSH_MODE -eq 'busy' -or ($env:FAKE_SSH_MODE -eq 'once' -and $n -eq 0))) { 'BUSY=1'; 'LIVE=4242 00:21 claude -p run' }
else { foreach ($m in [regex]::Matches($sh, "(?:systemctl|docker) restart '([^']+)'")) { $v = $m.Groups[1].Value; "DONE=$v 0"; "ACTIVE=$v active" }; 'END=1' }
'@
if ($KitIsWindows -or $IsWindows) { Set-Content (Join-Path $bin 'ssh.cmd') "@`"$pwshExe`" -NoProfile -File `"%~dp0fakessh.ps1`" %*" }
else { $sp = Join-Path $bin 'ssh'; [IO.File]::WriteAllText($sp, "#!/bin/sh`nexec `"$pwshExe`" -NoProfile -File `"`$(dirname `"`$0`")/fakessh.ps1`" `"`$@`"`n"); chmod +x $sp }
$path0 = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FAKE_SSH_LOG = $sshLog
$kl = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ repos = @(@{ name = 'svc'; deploys = @(@{ target = 'svc-stage'; ssh = @{ host = 'u@h1'; key = 'k.pem'; service = 'app,app-worker'; busy = 'pgrep -fa agent-turn' } }, @{ target = 'nobusy'; ssh = @{ host = 'u@h2'; service = 'app' } },
  @{ target = 'dock'; ssh = @{ host = 'u@h3'; service = 'web'; manager = 'docker'; sudo = $false } }, @{ target = 'bare'; ssh = @{ host = 'u@h4'; service = 'web'; manager = 'none' } },
  @{ target = 'kube'; production = $false; command = @{ restart = "`"$pwshExe`" -NoProfile -Command Write-Output rolled-{service}" } },
  @{ target = 'probed'; probe = 'echo x'; command = @{ restart = "`"$pwshExe`" -NoProfile -Command Write-Output bounced-{service}"; deploy = "`"$pwshExe`" -NoProfile -Command Write-Output shipped-{repo}" } }, @{ target = 'stacked'; kind = 'awsStack'; awsStack = 'shop'; command = @{ restart = "`"$pwshExe`" -NoProfile -Command Write-Output stack-{service}" } }, @{ target = 'lanecmd'; kind = 'laneApk'; laneApk = $true; command = @{ restart = "`"$pwshExe`" -NoProfile -Command Write-Output lane-{service}" } },@{ target = 'quiet'; probe = 'echo x'; command = @{ deploy ="`"$pwshExe`" -NoProfile -Command exit 0" } }) }); deploy = @{ ssh = @{ manager = 'systemd'; sudo = $true } } } $kl   # LEGACY deploy.ssh
$logs = { @(Get-ChildItem (Kd) -Filter 'ssh.log.*' | Sort-Object Name | ForEach-Object { Get-Content $_.FullName -Raw }) }
$clear = { Get-ChildItem (Kd) -Filter 'ssh.log.*' | Remove-Item }

$env:FAKE_SSH_MODE = 'busy'
$rb = Px $O deploy restart -Env svc-stage -WaitMinutes 0 2>&1 | Out-String; $rbc = $LASTEXITCODE; $lb = @(& $logs)
Expect "deploy restart: a live turn on the host = REFUSED exit 3, nothing restarted ($($rb.Trim()) $rbc)" ($rbc -eq 3 -and $rb -match 'REFUSED deploy restart svc-stage: live work on u@h1' -and $rb -match 'claude -p run' -and $rb -match 'not restarted: app, app-worker')
$bi = if ($lb.Count) { $lb[0].IndexOf('pgrep -fa agent-turn') } else { -1 }; $ri = if ($lb.Count) { $lb[0].IndexOf('systemctl restart') } else { -1 }
Expect "deploy restart: the busy check runs in the same host script, right before each restart ($bi $ri)" ($bi -ge 0 -and $ri -gt $bi -and ([regex]::Matches($lb[0], 'pgrep -fa agent-turn')).Count -eq 2)

& $clear; $env:FAKE_SSH_MODE = 'once'
$ro = Px $O deploy restart -Env svc-stage -WaitMinutes 1 -RecheckSeconds 1 2>&1 | Out-String; $roc = $LASTEXITCODE
Expect "deploy restart: busy then free = waits, re-checks, restarts both ($($ro.Trim()) $roc)" ($roc -eq 0 -and $ro -match 'BUSY svc-stage: live work' -and $ro -match 'RESTARTED svc-stage: app, app-worker on u@h1' -and @(& $logs).Count -eq 2)

& $clear
$rn = Px $O deploy restart -Env nobusy 2>&1 | Out-String; $rnc = $LASTEXITCODE
$ru = Px $O deploy restart -Env nobusy -Ungated 2>&1 | Out-String; $ruc = $LASTEXITCODE
Expect "deploy restart: no ssh.busy = REFUSED exit 2 without ssh; -Ungated restarts ($($rn.Trim()) $rnc | $($ru.Trim()) $ruc)" ($rnc -eq 2 -and $rn -match 'no deploys\[\]\.ssh\.busy' -and @(& $logs).Count -eq 1 -and $ruc -eq 0 -and $ru -match 'RESTARTED nobusy: app on u@h2 .*\(ungated\)')
Expect 'deploy restart: a failed restart stops the host script before the next service; the busy command reads no stdin' ($lb[0] -match '\[ \$R -eq 0 \] \|\| exit 0' -and $lb[0] -match "sh -c 'pgrep -fa agent-turn' </dev/null")
# ssh.manager docker: docker restart / inspect, no systemctl, no sudo; manager none: refused; kind command (kubectl-like): its restart line, no ssh
& $clear
$rd = Px $O deploy restart -Env dock -Ungated 2>&1 | Out-String; $rdc = $LASTEXITCODE; $ld = @(& $logs)
Expect "deploy restart: ssh.manager docker restarts with docker, no systemctl, no sudo ($($rd.Trim()) $rdc)" ($rdc -eq 0 -and $rd -match 'RESTARTED dock: web on u@h3' -and $ld.Count -eq 1 -and $ld[0] -match "docker restart 'web'" -and $ld[0] -match 'docker inspect' -and $ld[0] -notmatch 'systemctl|sudo -n')
$rbr = Px $O deploy restart -Env bare -Ungated 2>&1 | Out-String; $rbrc = $LASTEXITCODE
Expect "deploy restart: ssh.manager none = REFUSED exit 2, no ssh ($($rbr.Trim()))" ($rbrc -eq 2 -and $rbr -match 'has no manager' -and @(& $logs).Count -eq 1)
$rk = Px $O deploy restart -Env kube -Service web 2>&1 | Out-String; $rkc = $LASTEXITCODE
Expect "deploy restart: kind command runs its restart line, no ssh ($($rk.Trim()) $rkc)" ($rkc -eq 0 -and $rk -match 'RESTARTED kube \(deploy kind command\): rolled-web' -and @(& $logs).Count -eq 1)
$rx = Px $O deploy restart -Env nope 2>&1 | Out-String; $rxc = $LASTEXITCODE
Expect "deploy restart: an unknown target or one without ssh = usage, exit 2 ($($rx.Trim()))" ($rxc -eq 2 -and $rx -match 'nope has no repos\[\]\.deploys\[\]\.ssh')
# parity deploy-kind: a kind with no restart / deploy of its own runs the row's command.restart / command.deploy (fallback)
$rp = Px $O deploy restart -Env probed -Service api 2>&1 | Out-String; $rpc = $LASTEXITCODE
$pW = if ((Px $O decide record -Gate deploy -Item probed -Question 'deploy probed?' -Answer 'yes, deploy probed' -Source chat 2>&1 | Out-String) -match 'RECORDED (\S+)') { $Matches[1] }
$pd = Px $O deploy run -To probed -Decision $pW 2>&1 | Out-String
$qW = if ((Px $O decide record -Gate deploy -Item quiet -Question 'deploy quiet?' -Answer 'yes, deploy quiet' -Source chat 2>&1 | Out-String) -match 'RECORDED (\S+)') { $Matches[1] }; $pq = Px $O deploy run -To quiet -Decision $qW 2>&1 | Out-String
Expect "deploy kinds: probe restarts and deploys through its command.restart / command.deploy lines, no ssh ($($rp.Trim()) $rpc | $($pd.Trim()))" ($rpc -eq 0 -and $rp -match 'RESTARTED probed \(deploy kind probe, command\.restart\): bounced-api' -and $pd -match 'DEPLOY svc -> probed \(probe\): shipped-svc' -and $pq -match 'DEPLOY svc -> quiet \(probe\): command\.deploy' -and @(& $logs).Count -eq 1 -and -not (Test-Path (Join-Path (TkPath $k 'deploys') 'running-probed.json')))
$rsk = Px $O deploy restart -Env stacked -Service web 2>&1 | Out-String; $rskc = $LASTEXITCODE; $rlc = Px $O deploy restart -Env lanecmd -Service app 2>&1 | Out-String
Expect "deploy restart: a row's command.restart wins over its kind's own restart (awsStack, laneApk) ($($rsk.Trim()) $rskc | $($rlc.Trim()))" ($rskc -eq 0 -and $rsk -match 'RESTARTED stacked \(deploy kind awsStack, command\.restart\): stack-web' -and $rlc -match 'RESTARTED lanecmd \(deploy kind laneApk, command\.restart\): lane-app')
# isRunning: branch-mr = an open MR into its branch, tag = the newest matching tag's CI run, else a live deploy run marker; deploy: awsStack
# from its template at the deploy head, laneApk refused without a checkout (fixtures: no host, AWS or phone here)
$dkI = & { . (Join-Path $k 'skills/crafty/lib.ps1'); . (Join-Path $k 'skills/pokey/adapters/deployed-checks.ps1'); . (Join-Path $k 'skills/bossy/adapters/deploys.ps1')
  function Invoke-HostVerb { param($Verb, $A) if ($Verb -eq 'mr.list') { if ($A.target_branch -eq 'rel') { [pscustomobject]@{ iid = 3; target_branch = 'rel' } } } elseif ($Verb -eq 'ci.runs') { [pscustomobject]@{ ref = 'v1.4.0'; status = 'running' }, [pscustomobject]@{ ref = 'v1.3.0'; status = 'success' } } }
  $script:awsArgs = ''; function aws { $script:awsArgs = "$args"; $global:LASTEXITCODE = 0; 'Successfully created/updated stack' }
  $g = Join-Path (Kd) 'stackrepo'; $null = New-Item -ItemType Directory -Force $g; git -C $g init -q 2>$null; Set-Content (Join-Path $g 'infra.yml') 'Resources: {}'; git -C $g add . 2>$null; git -C $g -c user.email=t@t -c user.name=t commit -qm i 2>$null
  $dkO = [ordered]@{}
  $dkO.mr = (Invoke-KitDeployKind @{ kind = 'branch-mr'; branch = 'rel'; target = 't' } 'isRunning' @{ repo = 'g/a' }) -eq $true -and (Invoke-KitDeployKind @{ kind = 'branch-mr'; branch = 'main'; target = 't' } 'isRunning' @{ repo = 'g/a' }) -eq $false
  git -C $g tag v1.4.0 2>$null; $dkGkv = ${function:Get-KitValue}; function Get-KitValue($Name, $Default) { if ($Name -eq 'repos') { @(@{ name = 'a'; checkout = $g }) } else { & $dkGkv $Name $Default } }
  $dkO.tag = (Invoke-KitDeployKind @{ tag = '^v\d'; target = 't' } 'isRunning' @{ repo = 'g/a'; name = 'a' }) -eq $true
  $rf = Join-Path (Get-KitPath deploys -Create) 'running-tx.json'; @{ pid = $PID } | ConvertTo-Json | Set-Content $rf; $live = Test-KitDeployRunning 'tx'
  @{ pid = 999999 } | ConvertTo-Json | Set-Content $rf; $dkO.marker = $live -and -not (Test-KitDeployRunning 'tx') -and -not (Test-KitDeployRunning 'nothing'); Remove-Item $rf
  $sd = Invoke-KitDeployKind @{ awsStack = 'shop'; template = 'infra.yml'; region = 'eu-west-1'; target = 't' } 'deploy' @{ repo = @{ name = 'a'; checkout = $g } }
  $dkO.stack = $sd.id -like 'stack shop at *' -and $script:awsArgs -match '^cloudformation deploy --region eu-west-1 --stack-name shop --template-file \S+ --no-fail-on-empty-changeset' -and (Invoke-KitDeployKind @{ awsStack = 'shop'; target = 't' } 'deploy' @{ repo = @{ name = 'a' } }).note -match 'no deploys\[\]\.template'
  $dkO.apk = (Invoke-KitDeployKind @{ laneApk = $true; target = 't' } 'deploy' @{ repo = @{ name = 'app' } }).note -match 'repos\[\]\.checkout of app unset'
  $dkO.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $dkI 'deploy kind isRunning / deploy: #' @('mr', 'tag', 'marker', 'stack', 'apk') -Show 6
# deploy kinds (parity): a plan hint on every kind; lastDeploy from the stack, the lane APK stamp and the deploy branch head (fixtures:
# no AWS, phone lane or git host here); isRunning = a stack update in progress
$dkR = & { . (Join-Path $k 'skills/crafty/lib.ps1'); . (Join-Path $k 'skills/pokey/adapters/deployed-checks.ps1')
  function aws { "2026-11-20T10:00:00.000Z`tUPDATE_IN_PROGRESS`t2026-01-01T00:00:00Z" }
  function LaneApk { [pscustomobject]@{ commit = 'abc1234'; built = '2026-11-21T09:00:00' } }
  function Invoke-HostVerb { param($Verb, $A) if ($Verb -eq 'repo.commit' -and $A.ref -eq 'release') { [pscustomobject]@{ id = 'f00'; committed_date = '2026-11-22T08:00:00Z' } }
    # run rows without ref (most hosts): the tag verbs ask per tag
    if ($Verb -eq 'ci.runs') { $global:dkRefs += @("$($A.ref)"); @{ 'v1.3' = @([pscustomobject]@{ status = 'running' }); 'v1.2' = @([pscustomobject]@{ status = 'success'; updated_at = '2026-11-23T07:00:00Z' }) }["$($A.ref)"] } }
  # tags in the checkout, newest first by date: v1.3, then v1.2; 'nightly' does not match ^v\d
  $tgr = Join-Path (Kd) 'tagrepo'; $null = New-Item -ItemType Directory -Force $tgr; git -C $tgr init -q 2>$null
  foreach ($tv in @(@('v1.2', '2026-11-01T10:00:00Z'), @('v1.3', '2026-11-10T10:00:00Z'), @('nightly', '2026-11-20T10:00:00Z'))) { $env:GIT_COMMITTER_DATE = $tv[1]; git -C $tgr -c user.email=t@t -c user.name=t commit -q --allow-empty -m $tv[0] 2>$null; git -C $tgr tag $tv[0] 2>$null }
  Remove-Item Env:GIT_COMMITTER_DATE; $dkGkv = ${function:Get-KitValue}; function Get-KitValue($Name, $Default) { if ($Name -eq 'repos') { @(@{ name = 'shop'; checkout = $tgr }) } else { & $dkGkv $Name $Default } }
  # ssh lastDeploy: shaFile stat (sudo when set), else the HEAD reflog time; the remote command is what the host runs; no answer = none
  function Invoke-BoundedSsh($A, $Sec) { $global:dkSsh = $A[-1]; if ($A -contains 'dead') { return @() }; if ($A[-1] -match 'stat -c') { '1763884800' } else { 'HEAD@{1763971200}' } }
  $dkK = [ordered]@{}; $st = @{ awsStack = 'shop-api'; target = 't' }; $ld = Invoke-KitDeployKind $st 'lastDeploy'
  $dkK.stack = $ld.source -eq 'stack shop-api' -and $ld.at.ToUniversalTime().Hour -eq 10 -and (Invoke-KitDeployKind $st 'isRunning') -eq $true
  $dkK.apk = (Invoke-KitDeployKind @{ laneApk = $true; target = 't' } 'lastDeploy').source -eq 'lane APK abc1234'
  $dkK.branch = (Invoke-KitDeployKind @{ kind = 'branch-mr'; branch = 'release'; target = 't' } 'lastDeploy' @{ repo = 'g/shop' }).source -eq 'branch release head'
  $global:dkRefs = @(); $tk = @{ tag = '^v\d'; target = 't' }; $tg = Invoke-KitDeployKind $tk 'lastDeploy' @{ repo = 'g/shop'; name = 'shop' }; $tgRefs = $global:dkRefs -join ','
  $dkK.tag = $tg.source -eq 'CI tag v1.2' -and $tg.at.ToUniversalTime().Hour -eq 7 -and $tgRefs -eq 'v1.3,v1.2' -and (Invoke-KitDeployKind $tk 'isRunning' @{ repo = 'g/shop'; name = 'shop' }) -eq $true -and
    $null -eq (Invoke-KitDeployKind $tk 'lastDeploy' @{ repo = 'g/x'; name = 'nocheckout' })
  $s1 = Invoke-KitDeployKind @{ ssh = @{ host = 'h1'; repoDir = '/srv/app/'; shaFile = '/srv/app/REVISION'; sudo = $true }; target = 't' } 'lastDeploy'; $c1 = $global:dkSsh
  $s2 = Invoke-KitDeployKind @{ ssh = @{ host = 'h1'; repoDir = '/srv/app' }; target = 't' } 'lastDeploy'
  $dkK.ssh = $s1.source -eq 'ssh h1 /srv/app/REVISION' -and $c1 -match "^sudo -n stat -c %Y '/srv/app/REVISION'" -and ([DateTimeOffset]$s1.at).ToUnixTimeSeconds() -eq 1763884800 -and
    $s2.source -eq 'ssh h1 HEAD moved' -and $global:dkSsh -match "^git -C '/srv/app' log -g" -and ([DateTimeOffset]$s2.at).ToUnixTimeSeconds() -eq 1763971200 -and
    $null -eq (Invoke-KitDeployKind @{ ssh = @{ host = 'dead'; repoDir = '/srv/app' }; target = 't' } 'lastDeploy')
  $dks = @(@{ command = @{ deploy = 'x' }; target = 't' }, @{ ssh = @{ host = 'h1' }; target = 't' }, @{ probe = 'echo x'; target = 't' }, $st, @{ laneApk = $true; target = 't' })
  $dkK.plan = @($dks | Where-Object { -not "$(Invoke-KitDeployKind $_ 'plan')" }).Count -eq 0 -and "$(Invoke-KitDeployKind $dks[1] 'plan')" -match 'a person deploys on h1'
  # restart: awsStack = a new ECS deployment when the row sets ecsService (else skip: command.restart / ssh run); laneApk = the app stopped on leased phones up
  function aws { $global:dkAws = "$args"; $global:LASTEXITCODE = 0; 'ecs-svc/123' }
  $dkK.ecs = (Invoke-KitDeployKind @{ awsStack = 's'; ecsService = 'api'; ecsCluster = 'main'; region = 'eu-west-1'; target = 't' } 'restart') -eq 'ecs service api: new deployment ecs-svc/123' -and
    $global:dkAws -match '^ecs update-service --region eu-west-1 --cluster main --service api --force-new-deployment' -and (Invoke-KitDeployKind $st 'restart').skip -match 'ecsService'
  $fph = Join-Path (Kd) 'fakephoney.ps1'; $env:FAKE_PH_LOG = Join-Path (Kd) 'phoney.log'; $KitCmd.swarm = $fph
  Set-Content $fph "if (`$args[0] -eq 'status') { 'lane1    emulator-5554  up       leased by t-1 since x'; 'lane2    emulator-5556  down     free'; 'lane3    emulator-5558  up       free'; 'lane4    emulator-5560  up       leased by opsy-1 since x' } else { Add-Content `$env:FAKE_PH_LOG `"`$args`" }"
  # two holders: the deploying agent's phone and a free one stop; another agent's phone (t-1 tests on it) is never touched
  $ra = Invoke-KitDeployKind @{ laneApk = $true; target = 't' } 'restart' @{ agent = 'opsy-1' }; $rl = (Get-Content $env:FAKE_PH_LOG) -join '|'; Remove-Item $env:FAKE_PH_LOG
  $rn = Invoke-KitDeployKind @{ laneApk = $true; target = 't' } 'restart'
  $dkK.phones = $ra -eq 'app stopped on 2 of 2 free or own phone(s): emulator-5558, emulator-5560; 1 phone(s) of other holders left alone' -and
    $rl -eq 'launch -Serial emulator-5558 -Stop|launch -Serial emulator-5560 -Stop' -and $rn -match '^app stopped on 1 of 1 .*: emulator-5558; 2 phone' -and (Get-Content $env:FAKE_PH_LOG) -join '|' -eq 'launch -Serial emulator-5558 -Stop'
  # ssh: deploy holds the host lock (its shell's pid, removed on exit); isRunning reads it: a live pid = yes, none = no, no answer = unknown
  function Invoke-BoundedSsh($A, $Sec) { $global:dkSsh = $A[-1]; if ($A -contains 'dead') { return @() }; if ($A[-1] -match 'base64') { return 'KIT_DEPLOY_OK' }; if ($A -contains 'busy') { 'KIT_RUN=yes' } else { 'KIT_RUN=no' } }
  $sl = @{ ssh = @{ host = 'busy'; deployCmd = './ship.sh' }; target = 'Stage 1' }; $dp = Invoke-KitDeployKind $sl 'deploy' @{ repo = @{ name = 'a' } }
  $dsh = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($global:dkSsh -split ' ')[1])))
  $dkK.lock = $dp.id -eq 'ssh busy' -and $dsh -ceq "echo `$`$ > '/tmp/kit-deploy-stage-1.lock'; trap `"rm -f '/tmp/kit-deploy-stage-1.lock'`" EXIT`n./ship.sh" -and
    (Invoke-KitDeployKind $sl 'isRunning') -eq $true -and $global:dkSsh -match "^p=\`$\(cat '/tmp/kit-deploy-stage-1.lock'" -and
    (Invoke-KitDeployKind @{ ssh = @{ host = 'h1'; lockFile = '/run/app.lock' }; target = 't' } 'isRunning') -eq $false -and $global:dkSsh -match "cat '/run/app.lock'" -and
    $null -eq (Invoke-KitDeployKind @{ ssh = @{ host = 'dead' }; target = 't' } 'isRunning')
  $dkK.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $dkR 'deploy kind: #' @('stack', 'apk', 'branch', 'tag', 'ssh', 'plan', 'ecs', 'phones', 'lock') -Show 10

$env:PATH = $path0; Remove-Item Env:FAKE_SSH_LOG, Env:FAKE_SSH_MODE
# supervise deploy holds (moved from deploys.tests.ps1: its token cap)
$ht = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Within($n) { $true }; function Invoke-Bounded { @() }
$gs = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'; $now = Get-Date
$cacheOf = { param([string[]]$m) @{ at = $now.ToString('o'); asked = $now.ToString('o'); ready = @("stage ($($m.Count) MR(s))"); ask = @("stage: $($m.Count) MR(s) ($($m -join ', '))"); mrsOf = @{ stage = $m } } | ConvertTo-Json -Depth 4 | Set-Content $pc }
$word = { param($id, $ans, $q = 'deploy stage', $min = 1) Write-KitLog decisions-log answered ([ordered]@{ id = $id; kind = 'decision'; item = 'stage,other'; gate = 'deploy'; question = $q; answer = $ans; by = 'owner'; answeredAt = $now.AddMinutes(-$min).ToString('o'); mrs = @() }) }
$acts = { param($r) @($r | Where-Object level -eq 'ACT' | ForEach-Object what) -join ';' }
& $cacheOf @('api!1'); & $word 'd-20260101000000-coordinator-aa11' 'dont deploy stage' 'deploy stage' 3
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"held:$(-not (& $acts $r) -and ($r.info -join ';') -eq 'deploy stage held by owner: aa11' -and (Get-Content $pc -Raw | ConvertFrom-Json).held.stage.id -eq 'd-20260101000000-coordinator-aa11')"
& $cacheOf @('api!1', 'api!2'); $held = (Get-Content $pc -Raw | ConvertFrom-Json); $held | Add-Member -Force NoteProperty held ([pscustomobject]@{ stage = @{ id = 'd-20260101000000-coordinator-aa11'; mrs = @('api!1') } }); $held | ConvertTo-Json -Depth 5 | Set-Content $pc
$r1 = @(Get-KitSuperviseFlagsDeploys -AutoFix); $r2 = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"fresh:$((& $acts $r1) -match '^DEPLOY ASK stage: 2 MR\(s\) .*new since hold aa11: api!2' -and -not (& $acts $r2) -and ($r2.info -join ';') -match 'held by owner: aa11')"
& $word 'd-20260101000100-coordinator-bb22' 'yes, deploy stage'; $r = @(Get-KitSuperviseFlagsDeploys)
"yes:$((& $acts $r) -match '^DEPLOY GO stage: approved \(bb22, owner\)' -and (& $acts $r) -notmatch 'DEPLOY ASK' -and @($r.info -match '^deploy ready: stage').Count -eq 1)"
& $word 'd-20260101000200-opsy-stage-cc33' "wait: retry $($now.AddMinutes(30).ToString('HH:mm'))" 'host stayed busy' 0; $r = @(Get-KitSuperviseFlagsDeploys)
"wait:$(-not (& $acts $r) -and ($r.info -join ';') -eq "deploy stage waiting: host busy, retry $($now.AddMinutes(30).ToString('HH:mm')) (cc33)")"
$now = $now.AddMinutes(31); $r = @(Get-KitSuperviseFlagsDeploys)
"due:$((& $acts $r) -match '^DEPLOY RETRY stage: host busy, wait cc33 due since' -and (& $acts $r) -notmatch 'DEPLOY ASK')"
& $word 'd-20260101000300-coordinator-dd44' 'yes: standing rule' 'deploy stage' 0; $r = @(Get-KitSuperviseFlagsDeploys)   # a yes after a wait of the last 12 h: still that retry
"retry:$((& $acts $r) -match '^DEPLOY RETRY stage: host busy, wait cc33' -and (& $acts $r) -notmatch 'DEPLOY (ASK|GO)')"
& $cacheOf @('api!1', 'api!2', 'api!3'); & $word 'd-20260101000400-coordinator-ee55' 'keep stage hanges held' 'deploy stage' -1; $r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"all:$(-not (& $acts $r) -and ($r.info -join ';') -match 'deploy stage held by owner: ee55')"
$gs2 = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.hold') { @('stage') } else { & $gs2 @args } }.GetNewClosure())
& $word 'd-20260101000500-coordinator-ff66' 'yes' 'deploy stage' -2; $r = @(Get-KitSuperviseFlagsDeploys)
"cfg:$(-not (& $acts $r) -and ($r.info -join ';') -match 'deploy stage held by config: deploy.hold')"
"kinds:$((@('dont deploy hm', 'No', 'hold it', 'wait: not urgent, never cut a live turn', 'Deploy tomorrow', 'yes: standing rule', 'deploy if needed', 'Sure, no problem', 'Please deploy now, no need to hold', 'test prod pipelines also', 'keep hm hanges held', 'dnt deploy hm', 'no deploy for hm yet', 'HM: merge and promote, never deploy', 'No problem, go ahead', 'do not wait, deploy', 'No problem, but hold hm') | ForEach-Object { Get-KitDeployWordKind $_ }) -join ',')"
Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.answerWords') { [pscustomobject]@{ yes = @('ja'); no = @('nein'); noAll = @('nie'); wait = @('später') } } else { & $gs2 @args } }.GetNewClosure())
"words:$((@('Ja, bitte', 'nein', 'nie wieder', 'später', 'janky', 'yes') | ForEach-Object { Get-KitDeployWordKind $_ }) -join ',')"
# WAIT-COND: a no on a condition = muted until it holds, then one DEPLOY ASK under any trigger (trigger owner here)
Set-Item function:Get-KitSetting $gs; $lnd = Get-KitPath launches -Create; Set-Content (Join-Path $lnd 'args-buildy-w9-wave1.json') '{"run":"w9-wave1"}'
$lnf = Join-Path $lnd 'self-buildy-w9-wave1-aa.json'; @{ run = 'w9-wave1'; script = 'buildy.js'; at = $now.ToString('o'); completed = $null } | ConvertTo-Json | Set-Content $lnf
& $cacheOf @('api!1'); & $word 'd-20260101000600-coordinator-gg77' 'no: keep stage held until all of w9 wave 1 is merged (owner)' 'deploy stage before w9 wave 1?' -3
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix); "until:$(-not (& $acts $r) -and ($r.info -join ';') -eq 'deploy stage held until run w9-wave1 done (gg77)')"
@{ run = 'w9-wave1'; script = 'buildy.js'; at = $now.ToString('o'); completed = $now.ToString('o') } | ConvertTo-Json | Set-Content $lnf
@{ run = 'w9-wave1'; script = 'buildy.js'; at = $now.AddHours(-1).ToString('o'); completed = $null } | ConvertTo-Json | Set-Content (Join-Path $lnd 'self-buildy-w9-wave1-00.json')   # superseded by the relaunch
$r1 = @(Get-KitSuperviseFlagsDeploys -AutoFix); $r2 = @(Get-KitSuperviseFlagsDeploys -AutoFix)
$pcO = Get-Content $pc -Raw | ConvertFrom-Json; $pcO.at = $now.AddHours(-5).ToString('o'); $pcO | ConvertTo-Json -Depth 5 | Set-Content $pc   # a plan refresh keeps condAsked
function Invoke-Bounded { '[{"target":"stage","status":"READY","mrs":[{"mr":"api!1"}]}]' }; $r3 = @(Get-KitSuperviseFlagsDeploys -AutoFix); function Invoke-Bounded { @() }
"met:$((& $acts $r1) -match '^DEPLOY ASK stage: run w9-wave1 done \(wait gg77\)' -and -not (& $acts $r2) -and ($r2.info -join ';') -eq 'deploy stage condition met: run w9-wave1 done (gg77), owner asked' -and -not (& $acts $r3) -and (Get-Content $pc -Raw | ConvertFrom-Json).condAsked.stage -eq 'd-20260101000600-coordinator-gg77')"
& $word 'd-20260101000700-coordinator-hh88' 'wait until tasks t-1, t-2 merged' 'deploy stage' -4; Update-KitTracking { param($tk) $tk.tasks['t-1'] = @{ task = 't-1'; allMergedAt = $now.ToString('o') } }
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix); $t0 = -not (& $acts $r) -and ($r.info -join ';') -eq 'deploy stage held until tasks t-1, t-2 merged (hh88)'
Update-KitTracking { param($tk) $tk.tasks['t-2'] = @{ task = 't-2'; done = $true } }; $r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"tasks:$($t0 -and (& $acts $r) -match '^DEPLOY ASK stage: tasks t-1, t-2 merged \(wait hh88\)' -and $null -eq (Get-KitDeployCondition 'no: hold until the moon is merged') -and (Get-KitDeployCondition 'wait until run r-2 done').id -eq 'r-2')"
# a yes is single-use, a pin covers only its own (owner 2026-11-25): dec-56 = pinned at a commit, !6827 out, already used -> no GO
Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())   # env web: no wait word of the cases above
@{ at = $now.ToString('o'); asked = $now.ToString('o'); ready = @('web (2 MR(s))'); ask = @('web: 2 MR(s) (web!6823, web!6827)'); mrsOf = @{ web = @('web!6823', 'web!6827') } } | ConvertTo-Json -Depth 4 | Set-Content $pc
$word = { param($id, $ans, $q, $min) Write-KitLog decisions-log answered ([ordered]@{ id = $id; kind = 'decision'; item = 'web'; gate = 'deploy'; question = $q; answer = $ans; by = 'owner'; answeredAt = $now.AddMinutes(-$min).ToString('o'); mrs = @() }) }
& $word 'dec-56' 'Yes: web half of dec-24, pinned at 4af19298ce; wave 3 and !6827 not included' 'web pinned?' -5
$p = Get-KitDeployWordPin ([pscustomobject]@{ answer = 'Yes: web half of dec-24, pinned at 4af19298ce; wave 3 and !6827 not included'; mrs = @() })
"pin:$($p.commit -eq '4af19298ce' -and "$($p.not)" -eq '!6827' -and -not $p.mrs.Count -and -not (Test-KitDeployPinCovers $p 'shop!6827') -and (Test-KitDeployPinCovers $p 'shop!6823'))"
$pins = @('yes: deploy web!6823, not !6827', 'yes, do not wait, deploy web!6823', 'yes: standing rule', 'wait: retry 14:30', 'yes, commit effaced', 'yes: acme/web!6823', 'yes except https://git.x/acme/web/-/merge_requests/6827') | ForEach-Object { $q = Get-KitDeployWordPin ([pscustomobject]@{ answer = $_ }); "$($q.mrs -join '+')/$($q.not -join '+')" }
"parse:$(($pins -join ' ') -eq 'web!6823/!6827 web!6823/ / / / web!6823/ /web!6827')"
$r = @(Get-KitSuperviseFlagsDeploys); $g56 = & $acts $r
Write-KitLog decisions-log used ([ordered]@{ id = 'dec-56'; gate = 'deploy'; usedBy = 'opsy-stage-2' }); $r = @(Get-KitSuperviseFlagsDeploys)
"used:$($g56 -match '^DEPLOY GO web: approved \(56, owner\) pinned at 4af19298ce: only MRs at or before it, never web!6827' -and (& $acts $r) -notmatch 'DEPLOY GO' -and (& $acts $r) -match '^DEPLOY ASK web: 2 MR')"
& $word 'dec-57' 'yes' 'deploy web' -6; @{ id = 'dec-57'; usedAt = $now.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path (Get-KitPath decisions -Create) 'dec-57.json')
$r = @(Get-KitSuperviseFlagsDeploys); "usedFile:$((& $acts $r) -notmatch 'DEPLOY GO' -and (& $acts $r) -match 'DEPLOY ASK web')"
& $word 'dec-58' 'yes: deploy web!6823 only' 'deploy web' -7; $r = @(Get-KitSuperviseFlagsDeploys)
"pinMrs:$((& $acts $r) -match '^DEPLOY GO web: approved \(58, owner\) pinned: covers 1 MR\(s\) \(web!6823\); not covered, a new yes: web!6827')"
& $word 'dec-59' 'yes, deploy stage' 'deploy web' -8; $r = @(Get-KitSuperviseFlagsDeploys); "freshYes:$((& $acts $r) -match '^DEPLOY GO web: approved \(59, owner\), 2 MR\(s\)')"
'@
$hr = Invoke-PsTest 'deploy-holds' $ht @($O)
Expect-Each $hr 'supervise deploy holds: an env''s newest no = one muted "held by <by>: <id>" line, no ACT, until a later yes or an MR it did not cover (one fresh ask, then covered); a yes = DEPLOY GO; env-wide no / deploy.hold: held; a wait = "waiting: <why>, retry HH:mm", then DEPLOY RETRY (a yes after it too); a no until a run / tasks: muted, then one DEPLOY ASK; a used yes (log event or record file) = an ask; a pin covers only its commit / MRs (#)' @('held', 'fresh', 'yes', 'wait', 'due', 'retry', 'all', 'cfg', 'until', 'met', 'tasks', 'pin', 'used', 'usedFile', 'pinMrs', 'freshYes', 'parse')
# decide check: a used word stays used when its record lost usedAt (the log event counts); a pin refuses another commit and shows on WORD
$pid56 = (Px $O decide record -Gate deploy -Item rmx -Question q -Answer 'Yes: web half, pinned at 4af19298ce; wave 3 and !6827 not included' -Source askuser | Out-String) -replace '(?s).*RECORDED (\S+) .*', '$1'
$pinWord = Px $O decide check -Gate deploy -Id $pid56 -Item rmx | Out-String; $pcm = Px $O decide check -Gate deploy -Id $pid56 -Item rmx -Commit 99999999ab | Out-String
$pu = Px $O decide check -Gate deploy -Id $pid56 -Item rmx -Use -Agent op9 | Out-String
$pf = Get-ChildItem $k -Recurse -Filter "$pid56.json" | Select-Object -First 1; $pj = Read-Json $pf.FullName; $pj.PSObject.Properties.Remove('usedAt'); & $J $pj $pf.FullName
$pa = Px $O decide check -Gate deploy -Item rmx | Out-String
$fid = (Px $O decide record -Gate deploy -Item rmx -Question q -Answer 'yes' -Source chat | Out-String) -replace '(?s).*RECORDED (\S+) .*', '$1'; $fw = Px $O decide check -Gate deploy -Item rmx | Out-String
Expect "decide check: pinned word shows its pin, refuses another commit; used once (the log event counts); a fresh word passes ($($pa.Trim()))" ($pinWord -match "WORD $pid56 .*\| pin: 4af19298ce; not !6827 only" -and $pcm -match "NO-WORD.*$pid56 pinned \(4af19298ce\), not 99999999ab" -and
  $pu -match "WORD $pid56" -and $pa -match "NO-WORD.*$pid56 already used" -and $fw -match "WORD $fid ")
# deploy run / schedule under an MR-pinned word: no -Mrs or an MR it excludes = refused, nothing runs
$mw = (Px $O decide record -Gate deploy -Item svc-stage -Question q -Answer 'yes: deploy svc!7, not svc!8' -Source chat | Out-String) -replace '(?s).*RECORDED (\S+) .*', '$1'
$dra = Px $O deploy run -To svc-stage -Decision $mw 2>&1 | Out-String; $drb = Px $O deploy run -To svc-stage -Mrs 'svc!8' -Decision $mw 2>&1 | Out-String
$dsa = Px $O deploy schedule -Env svc-stage -Decision $mw 2>&1 | Out-String
Expect "deploy run / schedule: an MR-pinned word needs -Mrs inside it ($($dra.Trim()) | $($drb.Trim()))" ($dra -match "REFUSED deploy run -To svc-stage: word $mw is pinned \(pass -Mrs" -and $drb -match 'pinned \(not svc!8\)' -and $dsa -match 'is pinned: pass -Mrs')
Expect "deploy word kinds: no / wait / yes from the answer ($(@($hr) -match '^kinds:'))" (@($hr) -contains 'kinds:no,no,no,wait,wait,yes,yes,yes,yes,unclear,noAll,no,no,noAll,yes,yes,no')
Expect "deploy.answerWords: an org's own leading words first, whole words only, English still read ($(@($hr) -match '^words:'))" (@($hr) -contains 'words:yes,no,noAll,wait,unclear,yes')
# deploy request (retro tidy-20261124-01: a batch's plan ran 58 KB): a summary out, the full plan in crafty.ps1 dir -Agent <run>
$rqFx = Join-Path (Kd) 'rq-fixture.json'; & $J @{ mrs = @{ 'api!5' = @{ rows = @(@{ target = 'stage'; state = 'UNKNOWN'; detail = 'cannot reach the host' }) } } } $rqFx
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } (Join-Path $k 'skills/crafty/kit.local.json')
$rqT = Px $O deploy request -Mrs 'api!5' -Run w4 -Offline $rqFx | Out-String; $rqJ = @(Px $O deploy request -Mrs 'api!5' -Run w4 -Offline $rqFx -Json | ConvertFrom-Json)
Expect "deploy request: a summary (-Json: target, status, trigger, mrs, file), the full plan in the run's agent folder ($($rqJ.Count))" ($rqT -match 'DEPLOY stage: UNKNOWN: the deploy check failed: api!5: cannot reach the host' -and $rqT -match 'full plan: .*w4[\\/]deploy-request\.json' -and
  $rqJ.Count -eq 1 -and $rqJ[0].status -eq 'UNKNOWN' -and (Test-Path -LiteralPath $rqJ[0].file) -and @(Get-Content -Raw -LiteralPath $rqJ[0].file | ConvertFrom-Json)[0].why -match 'cannot reach')
Remove-TestKit $k
Complete-Tests
